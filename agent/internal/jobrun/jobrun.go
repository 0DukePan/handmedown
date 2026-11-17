// Package jobrun is the engine that actually does work on a device.
//
// Both ways in use it: `hand run` for a local job, and the socket client when the brain leases a
// shard. Keeping one implementation is not tidiness for its own sake - the resume guarantee only
// holds if the leased path and the local path write the same journal, in the same order, with the
// same skip rule.
package jobrun

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/0DukePan/handmedown/agent/internal/journal"
	"github.com/0DukePan/handmedown/agent/internal/out"
	"github.com/0DukePan/handmedown/agent/internal/runner"
)

// Options describes one shard of work.
type Options struct {
	Command     []string
	Inputs      []string
	OutDir      string
	ShardID     string
	JobID       string
	JournalPath string
	Retries     int
	Verbose     bool
	Env         map[string]string
}

// Outcome is what happened to one input.
type Outcome string

const (
	OutcomeOK   Outcome = "ok"
	OutcomeSkip Outcome = "skip" // finished in an earlier run, and the output still verifies
	OutcomeRedo Outcome = "redo" // the journal claims it is done, but the output is missing or changed
	OutcomeFail Outcome = "fail"
)

// Event is one input's result, for whoever is drawing the progress.
type Event struct {
	Index    int
	Total    int
	Name     string
	Outcome  Outcome
	Duration time.Duration
	Err      error
}

// Observer receives one event per input. Nil is allowed.
type Observer func(Event)

// Result summarises a finished shard.
type Result struct {
	Digest   string
	Done     int
	Skipped  int
	Failures []string
	Duration time.Duration
	// TotalSkippedIncludingRedo counts both skips and redos, for the summary line.
	Redone int
}

// Run executes every input of the shard, resuming from the journal if one exists.
func Run(ctx context.Context, opts Options, observe Observer) (Result, error) {
	started := time.Now()
	store := out.New(opts.OutDir)

	record, state, err := journal.Open(opts.JournalPath, opts.JobID, opts.ShardID, len(opts.Inputs))
	if err != nil {
		return Result{}, err
	}
	defer record.Close()

	result := Result{}
	digests := make([]string, 0, len(opts.Inputs))

	for index, input := range opts.Inputs {
		if ctx.Err() != nil {
			return result, fmt.Errorf("cancelled: %w", ctx.Err())
		}

		name := filepath.Base(input)

		if digest, ok := state.Items[input]; ok {
			path, pathErr := store.PathFor(opts.ShardID, name, digest)

			if pathErr == nil && out.Verify(path, digest) == nil {
				result.Skipped++
				digests = append(digests, digest)
				notify(observe, Event{Index: index, Total: len(opts.Inputs), Name: name, Outcome: OutcomeSkip})
				continue
			}

			// The journal is not evidence on its own: verify, then redo if the bytes are gone.
			notify(observe, Event{Index: index, Total: len(opts.Inputs), Name: name, Outcome: OutcomeRedo})
		}

		startedInput := time.Now()
		digest, final, exitErr := runInput(ctx, opts, store, input, index, len(opts.Inputs))
		if exitErr != nil {
			if ctx.Err() != nil {
				return result, fmt.Errorf("cancelled: %w", ctx.Err())
			}
			// One bad input does not abandon the shard: the brain decides whether to retry, and the
			// inputs that did work stay checkpointed either way.
			result.Failures = append(result.Failures, fmt.Sprintf("%s: %v", name, exitErr))
			notify(observe, Event{
				Index: index, Total: len(opts.Inputs), Name: name,
				Outcome: OutcomeFail, Duration: time.Since(startedInput), Err: exitErr,
			})
			continue
		}

		if err := record.Item(input, final, digest); err != nil {
			return result, err
		}

		result.Done++
		digests = append(digests, digest)
		notify(observe, Event{
			Index: index, Total: len(opts.Inputs), Name: name,
			Outcome: OutcomeOK, Duration: time.Since(startedInput),
		})
	}

	result.Duration = time.Since(started)
	result.Digest = aggregateDigest(digests)

	if len(result.Failures) > 0 {
		return result, fmt.Errorf("%d of %d inputs failed: %s",
			len(result.Failures), len(opts.Inputs), strings.Join(result.Failures, "; "))
	}

	if err := record.Done(len(opts.Inputs)); err != nil {
		return result, err
	}
	return result, nil
}

// aggregateDigest is the shard's identity for conflict detection: the same inputs produce the same
// digest, so two devices reporting different ones means the command is not deterministic.
func aggregateDigest(digests []string) string {
	sorted := append([]string(nil), digests...)
	sort.Strings(sorted)

	sum := sha256.Sum256([]byte(strings.Join(sorted, "\n")))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func runInput(ctx context.Context, opts Options, store *out.Store, input string, index, total int) (string, string, error) {
	name := filepath.Base(input)
	attempts := opts.Retries + 1
	var lastErr error

	for attempt := 1; attempt <= attempts; attempt++ {
		temp, err := store.TempPath(opts.ShardID, name)
		if err != nil {
			return "", "", err
		}

		env := map[string]string{
			"HAND_JOB_ID":   opts.JobID,
			"HAND_SHARD_ID": opts.ShardID,
			"HAND_INPUT":    input,
			"HAND_OUTPUT":   temp,
			"HAND_INDEX":    strconv.Itoa(index),
			"HAND_TOTAL":    strconv.Itoa(total),
		}
		for key, value := range opts.Env {
			env[key] = value
		}

		run, err := runner.Run(ctx, runner.Task{Cmd: opts.Command, Env: env, Verbose: opts.Verbose})
		if err != nil {
			discard(temp)
			return "", "", err
		}

		if run.ExitCode == 0 {
			final, digest, err := store.Commit(temp, opts.ShardID, name)
			return digest, final, err
		}

		discard(temp)
		lastErr = fmt.Errorf("exited %d: %s", run.ExitCode, firstLine(run.StderrTail))
		if attempt < attempts {
			select {
			case <-ctx.Done():
				return "", "", ctx.Err()
			case <-time.After(250 * time.Millisecond):
			}
		}
	}

	return "", "", lastErr
}

func notify(observe Observer, event Event) {
	if observe != nil {
		observe(event)
	}
}

func discard(path string) {
	if path == "" {
		return
	}
	// Remove the per-attempt directory: a command may have written siblings next to its output.
	_ = os.RemoveAll(filepath.Dir(path))
}

func firstLine(text string) string {
	text = strings.TrimSpace(text)
	if index := strings.IndexByte(text, '\n'); index >= 0 {
		text = text[:index]
	}
	if len(text) > 200 {
		text = text[:200]
	}
	return text
}
