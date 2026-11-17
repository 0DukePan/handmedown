// Package runner executes one command for one input.
//
// It keeps the last few KB of output instead of streaming everything: a job can run thousands of
// times, and the useful part of a failure is the end of it. `--verbose` streams everything as well.
package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"time"
)

// tailLimit is how much output is kept per stream, in bytes.
const tailLimit = 4096

// Task is one command invocation.
type Task struct {
	Cmd     []string
	Dir     string
	Env     map[string]string
	Verbose bool
}

// Result is what happened. An error return means the command could not be run or was cancelled;
// a normal non-zero exit is reported in ExitCode with a nil error, because "your tool failed" is a
// job outcome, not a hand failure.
type Result struct {
	ExitCode   int
	Duration   time.Duration
	StdoutTail string
	StderrTail string
}

// Run executes the task. Cancelling ctx terminates the command.
//
// On Windows this kills the direct child only: a build tool that spawns grandchildren can outlive a
// cancel. Process-tree termination is tracked in docs/DESIGN.md as a known gap, not an oversight.
func Run(ctx context.Context, task Task) (Result, error) {
	if len(task.Cmd) == 0 {
		return Result{}, errors.New("runner: empty command")
	}

	cmd := exec.CommandContext(ctx, task.Cmd[0], task.Cmd[1:]...)
	cmd.Dir = task.Dir
	cmd.Env = append(os.Environ(), envPairs(task.Env)...)

	outTail := &tailBuffer{limit: tailLimit}
	errTail := &tailBuffer{limit: tailLimit}

	if task.Verbose {
		outTail.tee = os.Stdout
		errTail.tee = os.Stderr
	}
	cmd.Stdout = outTail
	cmd.Stderr = errTail

	start := time.Now()
	err := cmd.Run()
	result := Result{
		Duration:   time.Since(start),
		StdoutTail: outTail.String(),
		StderrTail: errTail.String(),
	}

	if err == nil {
		return result, nil
	}

	// Cancellation has to be checked before the exit-code path: a killed process also reports an
	// ExitError, and reporting that as "your command exited -1" would hide why it stopped.
	if ctxErr := ctx.Err(); ctxErr != nil {
		return result, fmt.Errorf("command cancelled: %w", ctxErr)
	}

	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		result.ExitCode = exitErr.ExitCode()
		return result, nil
	}

	return result, fmt.Errorf("run %s: %w", task.Cmd[0], err)
}

// envPairs renders the extra environment deterministically, so a logged command line reproduces.
func envPairs(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	pairs := make([]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, key+"="+env[key])
	}
	return pairs
}

// tailBuffer keeps the last `limit` bytes written to it, and optionally tees everything onward.
type tailBuffer struct {
	buf   bytes.Buffer
	limit int
	tee   io.Writer
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	if t.tee != nil {
		if _, err := t.tee.Write(p); err != nil {
			return 0, err
		}
	}

	t.buf.Write(p)
	if t.buf.Len() > t.limit {
		keep := append([]byte(nil), t.buf.Bytes()[t.buf.Len()-t.limit:]...)
		t.buf.Reset()
		t.buf.Write(keep)
	}
	return len(p), nil
}

func (t *tailBuffer) String() string { return t.buf.String() }
