package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/0DukePan/handmedown/agent/internal/jobrun"
	"github.com/0DukePan/handmedown/agent/internal/journal"
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

	// Read, do not own: jobrun owns the writer for this run. Two open handles on one journal would
	// duplicate sequence numbers, and sequence numbers are how a replay detects tampering.
	state, err := journal.Load(opts.JournalPath())
	if err != nil {
		fmt.Fprintf(stderr, "hand run: %v\n", err)
		return exitFailure
	}

	fmt.Fprintf(stdout, "job %s  shard %s  %d %s\n",
		opts.JobID(), opts.ShardID(), opts.Count(), plural(opts.Count(), "input", "inputs"))
	if len(state.Items) > 0 {
		// Saying this out loud is the whole user-visible payoff of the journal.
		fmt.Fprintf(stdout, "resuming: %d of %d already finished in a previous run\n", len(state.Items), opts.Count())
	}

	if opts.Mode == spec.ModeCommand {
		return runCommandOnce(ctx, opts, stdout, stderr)
	}
	return runEachInput(ctx, opts, stdout, stderr)
}

// runCommandOnce is mode A: no input list, so there is nothing to checkpoint per item.
func runCommandOnce(ctx context.Context, opts spec.Options, stdout, stderr io.Writer) int {
	record, _, err := journal.Open(opts.JournalPath(), opts.JobID(), opts.ShardID(), 1)
	if err != nil {
		fmt.Fprintf(stderr, "hand run: %v\n", err)
		return exitFailure
	}
	defer record.Close()

	started := time.Now()

	result, err := runner.Run(ctx, runner.Task{
		Cmd:     opts.Command,
		Env:     baseEnv(opts),
		Verbose: opts.Verbose,
	})
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
func runEachInput(ctx context.Context, opts spec.Options, stdout, stderr io.Writer) int {
	total := len(opts.Inputs)

	result, err := jobrun.Run(ctx, jobrun.Options{
		Command:     opts.Command,
		Inputs:      opts.Inputs,
		OutDir:      opts.OutDir,
		ShardID:     opts.ShardID(),
		JobID:       opts.JobID(),
		JournalPath: opts.JournalPath(),
		Retries:     opts.Retries,
		Verbose:     opts.Verbose,
	}, func(event jobrun.Event) {
		label := fmt.Sprintf("[%*d/%d] %s", width(total), event.Index+1, event.Total, pad(event.Name, 44))
		if event.Outcome == jobrun.OutcomeFail {
			fmt.Fprintf(stderr, "%s failed: %v\n", label, event.Err)
			return
		}
		detail := map[jobrun.Outcome]string{
			jobrun.OutcomeOK:   "ok   " + round(event.Duration).String(),
			jobrun.OutcomeSkip: "skip (finished in a previous run)",
			jobrun.OutcomeRedo: "redo (recorded output is missing or changed)",
		}[event.Outcome]
		fmt.Fprintf(stdout, "%s %s\n", label, detail)
	})

	if errors.Is(err, context.Canceled) {
		fmt.Fprintln(stderr, "the journal is intact; run the same command again to resume")
		return exitInterrupted
	}

	if err != nil {
		fmt.Fprintf(stderr, "\nhand run: %v\n", err)
		fmt.Fprintln(stderr, "Re-run the same command to retry only the failures.")
		return exitFailure
	}

	fmt.Fprintf(stdout, "\ndone in %s: %d ran, %d skipped\n",
		round(result.Duration), result.Done, result.Skipped)
	return exitOK
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
