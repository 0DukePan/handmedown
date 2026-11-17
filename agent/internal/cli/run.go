package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/0DukePan/handmedown/agent/internal/journal"
	"github.com/0DukePan/handmedown/agent/internal/out"
	"github.com/0DukePan/handmedown/agent/internal/runner"
	"github.com/0DukePan/handmedown/agent/internal/spec"
)

// exitFailure means the job itself failed: a command exited non-zero, or it was cancelled. It is
// distinct from exitUsage so a script can tell "you called me wrong" from "your tool failed".
const exitFailure = 1

// exitInterrupted is the conventional 128 + SIGINT.
const exitInterrupted = 130

// runJob implements `hand run`: the resumable, content-addressed local runner.
func runJob(args []string, stdout, stderr io.Writer) int {
	opts, err := spec.Parse(args)
	if err != nil {
		fmt.Fprintf(stderr, "hand run: %v\n", err)
		return exitUsage
	}

	ctx, stop := signalContext()
	defer stop()

	record, state, err := journal.Open(opts.JournalPath(), opts.JobID(), opts.ShardID(), opts.Count())
	if err != nil {
		fmt.Fprintf(stderr, "hand run: %v\n", err)
		return exitFailure
	}
	defer func() {
		if closeErr := record.Close(); closeErr != nil {
			fmt.Fprintf(stderr, "hand run: closing journal: %v\n", closeErr)
		}
	}()

	fmt.Fprintf(stdout, "job %s  shard %s  %d %s\n",
		opts.JobID(), opts.ShardID(), opts.Count(), plural(opts.Count(), "input", "inputs"))
	if len(state.Items) > 0 {
		// Saying this out loud is the entire user-visible payoff of the journal.
		fmt.Fprintf(stdout, "resuming: %d of %d already finished in a previous run\n", len(state.Items), opts.Count())
	}

	if opts.Mode == spec.ModeCommand {
		return runCommandOnce(ctx, opts, record, stdout, stderr)
	}
	return runEachInput(ctx, opts, record, state, stdout, stderr)
}

// runCommandOnce is mode A: no input list, so there is nothing to checkpoint per item.
func runCommandOnce(ctx context.Context, opts spec.Options, record *journal.Journal, stdout, stderr io.Writer) int {
	env := baseEnv(opts)
	started := time.Now()

	result, err := runner.Run(ctx, runner.Task{Cmd: opts.Command, Env: env, Verbose: opts.Verbose})
	if err != nil {
		_ = record.Fail(err.Error())
		fmt.Fprintf(stderr, "hand run: %v\n", err)
		if errors.Is(err, context.Canceled) {
			fmt.Fprintln(stderr, "interrupted; the journal is intact - run the same command to resume")
			return exitInterrupted
		}
		return exitFailure
	}

	if result.ExitCode != 0 {
		message := fmt.Sprintf("command exited %d", result.ExitCode)
		_ = record.Fail(message)
		fmt.Fprintf(stderr, "hand run: %s after %s\n", message, round(result.Duration))
		writeTail(stderr, result.StderrTail)
		return exitFailure
	}

	if err := record.Done(1); err != nil {
		fmt.Fprintf(stderr, "hand run: %v\n", err)
		return exitFailure
	}
	fmt.Fprintf(stdout, "done in %s\n", round(time.Since(started)))
	return exitOK
}

// runEachInput is mode B: the mode with the actual resume guarantee.
func runEachInput(ctx context.Context, opts spec.Options, record *journal.Journal, state journal.State, stdout, stderr io.Writer) int {
	store := out.New(opts.OutDir)
	total := len(opts.Inputs)
	started := time.Now()

	var ran, skipped, failed int

	for index, input := range opts.Inputs {
		name := filepath.Base(input)
		label := fmt.Sprintf("[%*d/%d] %s", width(total), index+1, total, pad(name, 44))

		if digest, ok := state.Items[input]; ok {
			path, pathErr := store.PathFor(opts.ShardID(), name, digest)
			// Verify, do not trust: a journal entry whose file was deleted or edited is not
			// finished work, and skipping it would produce a silently incomplete job.
			if pathErr == nil && out.Verify(path, digest) == nil {
				skipped++
				fmt.Fprintf(stdout, "%s skip (finished in a previous run)\n", label)
				continue
			}
			fmt.Fprintf(stdout, "%s redo (recorded output is missing or changed)\n", label)
		}

		result, final, digest, err := runInput(ctx, opts, store, input, index, total)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				fmt.Fprintf(stderr, "%s interrupted\n", label)
				fmt.Fprintln(stderr, "the journal is intact; run the same command again to resume")
				_ = record.Fail("interrupted")
				return exitInterrupted
			}

			failed++
			message := fmt.Sprintf("%s: %v", name, err)
			_ = record.Fail(message)
			fmt.Fprintf(stderr, "%s failed %v\n", label, err)
			writeTail(stderr, result.StderrTail)
			continue
		}

		if itemErr := record.Item(input, final, digest); itemErr != nil {
			fmt.Fprintf(stderr, "hand run: %v\n", itemErr)
			return exitFailure
		}

		ran++
		fmt.Fprintf(stdout, "%s ok   %s\n", label, round(result.Duration))
	}

	elapsed := time.Since(started)

	if failed > 0 {
		message := fmt.Sprintf("%d of %d inputs failed", failed, total)
		_ = record.Fail(message)
		fmt.Fprintf(stderr, "\n%s: %s after %s. Re-run the same command to retry only the failures.\n",
			"hand run", message, round(elapsed))
		return exitFailure
	}

	if err := record.Done(total); err != nil {
		fmt.Fprintf(stderr, "hand run: %v\n", err)
		return exitFailure
	}

	fmt.Fprintf(stdout, "\ndone in %s: %d ran, %d skipped\n", round(elapsed), ran, skipped)
	return exitOK
}

// runInput runs one input with retries and commits its output.
func runInput(ctx context.Context, opts spec.Options, store *out.Store, input string, index, total int) (runner.Result, string, string, error) {
	name := filepath.Base(input)
	attempts := opts.Retries + 1
	var last runner.Result

	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		if ctx.Err() != nil {
			return last, "", "", fmt.Errorf("cancelled: %w", ctx.Err())
		}

		temp, err := store.TempPath(opts.ShardID(), name)
		if err != nil {
			return last, "", "", err
		}

		env := baseEnv(opts)
		env["HAND_INPUT"] = input
		env["HAND_OUTPUT"] = temp
		env["HAND_INDEX"] = strconv.Itoa(index)
		env["HAND_TOTAL"] = strconv.Itoa(total)

		result, runErr := runner.Run(ctx, runner.Task{
			Cmd:     opts.Command,
			Env:     env,
			Verbose: opts.Verbose,
		})
		if runErr != nil {
			discardTemp(temp)
			return result, "", "", runErr
		}
		last = result

		if result.ExitCode == 0 {
			final, digest, commitErr := store.Commit(temp, opts.ShardID(), name)
			if commitErr != nil {
				return result, "", "", commitErr
			}
			return result, final, digest, nil
		}

		discardTemp(temp)
		lastErr = fmt.Errorf("exited %d", result.ExitCode)
		if attempt < attempts {
			// Small, fixed pause: the common retry cause is a transient lock or a flaky network
			// mount, and both are gone within a second or two. Not worth a backoff curve yet.
			select {
			case <-ctx.Done():
				return last, "", "", fmt.Errorf("cancelled: %w", ctx.Err())
			case <-time.After(250 * time.Millisecond):
			}
		}
	}

	return last, "", "", lastErr
}

// baseEnv is the part of the contract that does not depend on the input.
func baseEnv(opts spec.Options) map[string]string {
	return map[string]string{
		"HAND_JOB_ID":   opts.JobID(),
		"HAND_SHARD_ID": opts.ShardID(),
	}
}

func signalContext() (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)

	go func() {
		select {
		case <-ch:
			cancel()
		case <-ctx.Done():
		}
	}()

	return ctx, func() {
		signal.Stop(ch)
		cancel()
	}
}

func discardTemp(path string) {
	if path == "" {
		return
	}
	// Remove the per-attempt directory, not just the file: a command may have written siblings.
	_ = os.RemoveAll(filepath.Dir(path))
}

func writeTail(w io.Writer, tail string) {
	if tail == "" {
		return
	}
	fmt.Fprintf(w, "  command output:\n")
	for _, line := range splitLines(tail) {
		fmt.Fprintf(w, "  | %s\n", line)
	}
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

func width(n int) int {
	digits := 1
	for n >= 10 {
		n /= 10
		digits++
	}
	return digits
}

func pad(s string, n int) string {
	if len(s) > n {
		return s[:n-1] + "~"
	}
	for len(s) < n {
		s += " "
	}
	return s
}

func round(d time.Duration) time.Duration {
	if d < time.Second {
		return d.Round(time.Millisecond)
	}
	return d.Round(10 * time.Millisecond)
}

func splitLines(s string) []string {
	var lines []string
	current := ""
	for _, r := range s {
		if r == '\n' {
			lines = append(lines, current)
			current = ""
			continue
		}
		current += string(r)
	}
	if current != "" {
		lines = append(lines, current)
	}
	return lines
}
