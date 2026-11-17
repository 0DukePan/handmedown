package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/0DukePan/handmedown/agent/internal/jobrun"
)

const demoUsage = `usage: hand demo [flags]

Proves the recovery guarantee on this machine, with no brain and no second device.

It generates a handful of inputs in a temporary directory, runs them through the same engine as
'hand run', interrupts itself part way, and then resumes. Before printing a verdict it checks the thing
the interruption is supposed to preserve: that no input was executed twice, and that every input has
exactly one output. If that check fails, 'hand demo' exits non-zero.

flags:
  --inputs <n>       how many inputs to generate (default 12)
  --stop-after <n>   how many inputs to finish before interrupting (default 4)
  --keep             keep the work directory instead of deleting it

The transcript is plain and stable on purpose: the README's demo GIF is generated from this output, so
the picture cannot drift away from what the tool actually does.
`

// The demo's work unit is the hand binary invoking itself: no shell, no PowerShell, no assumption about
// what is installed on the machine that is trying the tool for the first time.
const demoWorkerCommand = "__demo-worker"

const defaultDemoInputs = 12
const defaultDemoStopAfter = 4

type demoOptions struct {
	inputs    int
	stopAfter int
	keep      bool
}

func runDemo(args []string, stdout, stderr io.Writer) int {
	opts := demoOptions{inputs: defaultDemoInputs, stopAfter: defaultDemoStopAfter}

	for index := 0; index < len(args); index++ {
		switch {
		case args[index] == "--keep":
			opts.keep = true
		case args[index] == "--inputs":
			value, ok := nextArg(args, &index)
			if !ok {
				return usageError("hand demo: --inputs wants a number\n", stderr)
			}
			parsed, err := strconv.Atoi(value)
			if err != nil || parsed < 2 {
				return usageError("hand demo: --inputs wants a number >= 2\n", stderr)
			}
			opts.inputs = parsed
		case args[index] == "--stop-after":
			value, ok := nextArg(args, &index)
			if !ok {
				return usageError("hand demo: --stop-after wants a number\n", stderr)
			}
			parsed, err := strconv.Atoi(value)
			if err != nil || parsed < 1 {
				return usageError("hand demo: --stop-after wants a number >= 1\n", stderr)
			}
			opts.stopAfter = parsed
		case args[index] == "--help" || args[index] == "-h":
			fmt.Fprint(stdout, demoUsage)
			return exitOK
		default:
			fmt.Fprintf(stderr, "hand demo: unexpected argument %q\n\n%s", args[index], demoUsage)
			return exitUsage
		}
	}

	if opts.stopAfter >= opts.inputs {
		return usageError("hand demo: --stop-after must be smaller than --inputs, or nothing is left to resume\n", stderr)
	}

	executable, err := os.Executable()
	if err != nil {
		fmt.Fprintf(stderr, "hand demo: cannot find my own binary: %v\n", err)
		return exitFailure
	}

	workDir, err := os.MkdirTemp("", "hand-demo-")
	if err != nil {
		fmt.Fprintf(stderr, "hand demo: cannot create a work directory: %v\n", err)
		return exitFailure
	}
	if !opts.keep {
		defer os.RemoveAll(workDir)
	}

	inputDir := filepath.Join(workDir, "in")
	outDir := filepath.Join(workDir, "out")
	journalDir := filepath.Join(workDir, "journal")
	counter := filepath.Join(workDir, "executions.txt")
	for _, dir := range []string{inputDir, outDir, journalDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fmt.Fprintf(stderr, "hand demo: %v\n", err)
			return exitFailure
		}
	}

	inputs := make([]string, 0, opts.inputs)
	for index := 1; index <= opts.inputs; index++ {
		path := filepath.Join(inputDir, fmt.Sprintf("take-%02d.txt", index))
		if err := os.WriteFile(path, []byte(fmt.Sprintf("frame %d\n", index)), 0o644); err != nil {
			fmt.Fprintf(stderr, "hand demo: %v\n", err)
			return exitFailure
		}
		inputs = append(inputs, path)
	}

	fmt.Fprintln(stdout, "hand demo")
	fmt.Fprintf(stdout, "  workdir  %s\n", workDir)
	fmt.Fprintf(stdout, "  inputs   %d generated\n", len(inputs))
	fmt.Fprintf(stdout, "  plan     run %d, interrupt, resume the rest, check nothing ran twice\n", opts.inputs)
	fmt.Fprintln(stdout)

	runOpts := jobrun.Options{
		Command:     []string{executable, demoWorkerCommand},
		Inputs:      inputs,
		OutDir:      outDir,
		ShardID:     "demo-shard",
		JobID:       "demo-job",
		JournalPath: filepath.Join(journalDir, "demo-shard.jsonl"),
		Env: map[string]string{
			"HAND_COUNTER": counter,
		},
	}

	// --- first run, interrupted -------------------------------------------------
	fmt.Fprintln(stdout, "run 1")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	finishedFirstRun := 0
	_, firstErr := jobrun.Run(ctx, runOpts, func(event jobrun.Event) {
		renderDemoEvent(stdout, event)
		if event.Index+1 >= opts.stopAfter {
			// Cancel from the observer, which runs between inputs: the interruption lands on a clean
			// boundary, so the demonstration is deterministic rather than a race with a timer.
			finishedFirstRun = event.Index + 1
			cancel()
		}
	})

	if firstErr == nil {
		fmt.Fprintln(stderr, "hand demo: the first run was supposed to be interrupted but completed")
		return exitFailure
	}
	if finishedFirstRun != opts.stopAfter {
		fmt.Fprintf(stderr, "hand demo: expected %d finished inputs before the interruption, saw %d\n", opts.stopAfter, finishedFirstRun)
		return exitFailure
	}

	fmt.Fprintf(stdout, "  interrupted after %d of %d - kill -9 in production, a cancelled context here\n\n", finishedFirstRun, len(inputs))

	// --- second run, resumed ----------------------------------------------------
	fmt.Fprintln(stdout, "run 2")

	// A fresh context: the point is that the *work* survives, not that the same context does.
	resumeCtx, resumeCancel := context.WithCancel(context.Background())
	defer resumeCancel()

	result, resumeErr := jobrun.Run(resumeCtx, runOpts, func(event jobrun.Event) {
		renderDemoEvent(stdout, event)
	})
	if resumeErr != nil {
		fmt.Fprintf(stderr, "\nhand demo: the resumed run failed: %v\n", resumeErr)
		return exitFailure
	}

	fmt.Fprintf(stdout, "  done in %s: %d ran, %d skipped\n\n", result.Duration.Round(time.Millisecond), result.Done, result.Skipped)

	// --- verdict ----------------------------------------------------------------
	failures := checkDemo(workDir, outDir, counter, inputs, finishedFirstRun)

	fmt.Fprintln(stdout, "verdict")
	if len(failures) > 0 {
		for _, failure := range failures {
			fmt.Fprintf(stdout, "  FAIL  %s\n", failure)
		}
		fmt.Fprintf(stderr, "\nhand demo: the recovery guarantee did not hold on this machine\n")
		return exitFailure
	}

	fmt.Fprintf(stdout, "  PASS  %d inputs, %d outputs, 0 inputs executed twice\n", len(inputs), len(inputs))
	fmt.Fprintf(stdout, "  PASS  the %d finished before the interruption were not repeated\n", finishedFirstRun)
	fmt.Fprintf(stdout, "  the journal on disk is what made that true: %s\n", filepath.Join(journalDir, "demo-shard.jsonl"))
	if opts.keep {
		fmt.Fprintf(stdout, "  kept: %s\n", workDir)
	}
	return exitOK
}

// checkDemo is the part that makes this a demonstration rather than a claim.
func checkDemo(workDir, outDir, counter string, inputs []string, finishedFirstRun int) []string {
	var failures []string

	// Every input must have exactly one output. Count files rather than trusting the engine's summary.
	outputs, err := filepath.Glob(filepath.Join(outDir, "demo-shard", "*"))
	if err != nil {
		return append(failures, fmt.Sprintf("cannot list outputs: %v", err))
	}
	if len(outputs) != len(inputs) {
		failures = append(failures, fmt.Sprintf("%d outputs for %d inputs", len(outputs), len(inputs)))
	}

	executions := readLines(counter)
	counts := map[string]int{}
	for _, line := range executions {
		counts[line]++
	}

	repeated := make([]string, 0)
	for _, input := range inputs {
		if counts[input] > 1 {
			repeated = append(repeated, fmt.Sprintf("%s x%d", filepath.Base(input), counts[input]))
		}
		if counts[input] == 0 {
			failures = append(failures, fmt.Sprintf("%s never ran", filepath.Base(input)))
		}
	}
	if len(repeated) > 0 {
		failures = append(failures, "inputs executed twice: "+strings.Join(repeated, ", "))
	}

	// The specific claim: the work that finished before the interruption was not redone.
	firstRunInputs := inputs[:finishedFirstRun]
	for _, input := range firstRunInputs {
		if counts[input] != 1 {
			failures = append(failures, fmt.Sprintf("%s ran %d times despite finishing before the interruption", filepath.Base(input), counts[input]))
		}
	}

	return failures
}

func renderDemoEvent(stdout io.Writer, event jobrun.Event) {
	label := fmt.Sprintf("  [%2d] %-14s", event.Index+1, event.Name)
	switch event.Outcome {
	case jobrun.OutcomeSkip:
		fmt.Fprintf(stdout, "%s skip  (already done, output verified)\n", label)
	case jobrun.OutcomeRedo:
		fmt.Fprintf(stdout, "%s redo  (recorded output was missing)\n", label)
	case jobrun.OutcomeFail:
		fmt.Fprintf(stdout, "%s FAIL  %v\n", label, event.Err)
	default:
		fmt.Fprintf(stdout, "%s ok    %s\n", label, event.Duration.Round(time.Millisecond))
	}
}

// demoWorker is the demo's unit of work, invoked as a child of this same binary.
//
// It is deliberately not in the usage text: it is an implementation detail of the demo, and a user
// calling it directly gets nothing they could not get from `hand run`.
func demoWorker(stdout, stderr io.Writer) int {
	input := os.Getenv("HAND_INPUT")
	output := os.Getenv("HAND_OUTPUT")
	if input == "" || output == "" {
		fmt.Fprint(stderr, "hand __demo-worker: HAND_INPUT and HAND_OUTPUT are required\n")
		return exitFailure
	}

	content, err := os.ReadFile(input)
	if err != nil {
		fmt.Fprintf(stderr, "hand __demo-worker: %v\n", err)
		return exitFailure
	}

	// Slow enough that the transcript is readable, fast enough that the demo stays snappy.
	if delay := parseDelay(os.Getenv("HAND_DEMO_DELAY_MS")); delay > 0 {
		time.Sleep(delay)
	}

	if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
		fmt.Fprintf(stderr, "hand __demo-worker: %v\n", err)
		return exitFailure
	}
	if err := os.WriteFile(output, append([]byte("processed:"), content...), 0o644); err != nil {
		fmt.Fprintf(stderr, "hand __demo-worker: %v\n", err)
		return exitFailure
	}

	// One line per execution. The demo's verdict is computed from this file, so it cannot claim a
	// property it did not observe.
	if counter := os.Getenv("HAND_COUNTER"); counter != "" {
		file, err := os.OpenFile(counter, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err == nil {
			_, _ = file.WriteString(input + "\n")
			_ = file.Close()
		}
	}

	return exitOK
}

func parseDelay(value string) time.Duration {
	if value == "" {
		return 120 * time.Millisecond
	}
	millis, err := strconv.Atoi(value)
	if err != nil || millis < 0 {
		return 120 * time.Millisecond
	}
	return time.Duration(millis) * time.Millisecond
}

func readLines(path string) []string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var lines []string
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

func nextArg(args []string, index *int) (string, bool) {
	if *index+1 >= len(args) {
		return "", false
	}
	*index++
	return args[*index], true
}

func usageError(message string, stderr io.Writer) int {
	fmt.Fprint(stderr, message)
	return exitUsage
}
