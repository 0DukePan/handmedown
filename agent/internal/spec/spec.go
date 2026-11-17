// Package spec turns `hand run ...` arguments into a validated job.
//
// The job id is derived from the command and the input list, not from a timestamp or a random
// number. That is what makes `hand run` twice with the same arguments resume instead of starting
// over: same invocation, same id, same journal, same work skipped.
package spec

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Mode is how the agent decides what to run.
type Mode int

const (
	// ModeFiles runs the command once per input, with the HAND_* environment contract. This is the
	// mode with a real resume guarantee: the agent knows which inputs finished.
	ModeFiles Mode = iota

	// ModeCommand runs the command once, with no input list. Retry only: if it dies, it starts over.
	ModeCommand
)

func (m Mode) String() string {
	if m == ModeFiles {
		return "files"
	}
	return "command"
}

// Options is a validated run.
type Options struct {
	Mode       Mode
	Command    []string
	Inputs     []string // this shard's slice: absolute, sorted, unique; empty in ModeCommand
	AllInputs  []string // the full sorted list before --shard, so every shard of one job shares a job id
	OutDir     string
	JournalDir string
	ShardIndex int // 0-based
	ShardCount int
	Retries    int
	Verbose    bool
}

// Usage is the help text for `hand run`. It lives next to the parser so the two cannot drift.
const Usage = `usage: hand run [flags] -- <command...>

Runs <command> over a list of inputs, checkpointing after every one. Stop it however you like -
ctrl-c, kill -9, closing the laptop - and run the same command again to resume.

flags:
  --inputs <path|glob>   input list; repeatable. absence means "run <command> once"
  --outdir <dir>         where outputs are written, content-addressed (default: ./out)
  --shard <i/n>          run the i-th of n slices, 1-based (default 1/1)
  --retries <n>          retries per input before giving up (default 0)
  --journal <dir>        journal directory (default: ./.hand/journal)
  --verbose, -v          stream command output as it runs

per-input environment:
  HAND_INPUT   absolute path to the input
  HAND_OUTPUT  path the command must write its result to
  HAND_INDEX   index within this shard      HAND_TOTAL   inputs in this shard
  HAND_JOB_ID  stable id for this invocation
  HAND_SHARD_ID  stable id for this shard

example:
  hand run --inputs '*.mov' --outdir out -- ./transcode --in "$HAND_INPUT" --out "$HAND_OUTPUT"
`

// Parse validates run arguments (everything after the `run` subcommand).
func Parse(args []string) (Options, error) {
	opts := Options{ShardCount: 1, JournalDir: defaultJournalDir(), OutDir: "out"}

	var rawInputs []string
	seenOut := false

	for i := 0; i < len(args); i++ {
		arg := args[i]

		// Everything after `--` is the command, verbatim: no flag-looking arguments are interpreted.
		if arg == "--" {
			opts.Command = args[i+1:]
			break
		}

		switch {
		case arg == "--verbose" || arg == "-v":
			opts.Verbose = true

		case arg == "--inputs" || strings.HasPrefix(arg, "--inputs="):
			value, next, err := takeValue(args, i, "--inputs")
			if err != nil {
				return Options{}, err
			}
			i = next
			rawInputs = append(rawInputs, value)

		case arg == "--outdir" || strings.HasPrefix(arg, "--outdir="):
			value, next, err := takeValue(args, i, "--outdir")
			if err != nil {
				return Options{}, err
			}
			i = next
			opts.OutDir = value
			seenOut = true

		case arg == "--journal" || strings.HasPrefix(arg, "--journal="):
			value, next, err := takeValue(args, i, "--journal")
			if err != nil {
				return Options{}, err
			}
			i = next
			opts.JournalDir = value

		case arg == "--shard" || strings.HasPrefix(arg, "--shard="):
			value, next, err := takeValue(args, i, "--shard")
			if err != nil {
				return Options{}, err
			}
			i = next
			index, count, err := parseShard(value)
			if err != nil {
				return Options{}, err
			}
			opts.ShardIndex, opts.ShardCount = index, count

		case arg == "--retries" || strings.HasPrefix(arg, "--retries="):
			value, next, err := takeValue(args, i, "--retries")
			if err != nil {
				return Options{}, err
			}
			i = next
			retries, err := strconv.Atoi(value)
			if err != nil || retries < 0 {
				return Options{}, fmt.Errorf("--retries wants a number >= 0, got %q", value)
			}
			opts.Retries = retries

		case arg == "--help" || arg == "-h":
			return Options{}, errors.New(Usage)

		case strings.HasPrefix(arg, "-"):
			return Options{}, fmt.Errorf("unknown flag %q\n\n%s", arg, Usage)

		default:
			return Options{}, fmt.Errorf("unexpected argument %q before `--`\n\nthe command must come after `--`, so that hand never swallows one of its arguments:\n  hand run --inputs '*.mov' -- ./transcode\n\n%s", arg, Usage)
		}
	}

	if len(opts.Command) == 0 {
		return Options{}, fmt.Errorf("no command given: put it after `--`\n\n%s", Usage)
	}

	opts.Mode = ModeCommand
	if len(rawInputs) > 0 {
		opts.Mode = ModeFiles
	}

	if opts.Mode == ModeFiles {
		inputs, err := expand(rawInputs)
		if err != nil {
			return Options{}, err
		}
		if len(inputs) == 0 {
			return Options{}, fmt.Errorf("--inputs matched no files")
		}

		// --shard slices the expanded, sorted list, so two devices handed the same list select
		// identical, non-overlapping work without negotiating.
		total := len(inputs)
		opts.AllInputs = inputs
		opts.Inputs = selectShard(inputs, opts.ShardIndex, opts.ShardCount)
		if len(opts.Inputs) == 0 {
			return Options{}, fmt.Errorf("shard %d/%d of %d inputs selects nothing: ask for a smaller n", opts.ShardIndex+1, opts.ShardCount, total)
		}
	}

	// An outdir is only meaningful when something gets written. Defaulting it silently for
	// ModeCommand would scatter empty directories next to the user's files.
	if !seenOut && opts.Mode == ModeCommand {
		opts.OutDir = ""
	}

	return opts, nil
}

// Count is how many times the command runs.
func (o Options) Count() int {
	if o.Mode == ModeCommand {
		return 1
	}
	return len(o.Inputs)
}

// ShardID is stable across invocations, because it is derived from the slice, not from the clock.
func (o Options) ShardID() string {
	return fmt.Sprintf("%d-of-%d", o.ShardIndex+1, o.ShardCount)
}

// JobID hashes the invocation. Two identical `hand run` commands must produce the same id, or a
// rerun would silently start a second journal and repeat all the work.
//
// It hashes the full input list, not this shard's slice: every shard of one job must share a job id,
// and they are told apart by ShardID.
func (o Options) JobID() string {
	sum := sha256.New()
	fmt.Fprintf(sum, "mode=%s\n", o.Mode)
	for _, part := range o.Command {
		fmt.Fprintf(sum, "cmd=%s\n", part)
	}
	fmt.Fprintf(sum, "out=%s\n", o.OutDir)
	// Inputs are sorted, so the id does not depend on glob ordering from the filesystem.
	for _, in := range o.AllInputs {
		fmt.Fprintf(sum, "in=%s\n", in)
	}
	return "loc-" + hex.EncodeToString(sum.Sum(nil))[:12]
}

// JournalPath is where this job's journal lives. The local runner uses one shard, so one file.
func (o Options) JournalPath() string {
	return filepath.Join(o.JournalDir, o.JobID(), o.ShardID()+".jsonl")
}

func defaultJournalDir() string {
	return filepath.Join(".hand", "journal")
}

func takeValue(args []string, i int, flag string) (string, int, error) {
	if eq := strings.IndexByte(args[i], '='); eq >= 0 {
		value := args[i][eq+1:]
		if value == "" {
			return "", i, fmt.Errorf("%s wants a value", flag)
		}
		return value, i, nil
	}
	if i+1 >= len(args) {
		return "", i, fmt.Errorf("%s wants a value", flag)
	}
	return args[i+1], i + 1, nil
}

func parseShard(value string) (int, int, error) {
	parts := strings.Split(value, "/")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("--shard wants i/n (1-based), got %q", value)
	}
	index, err1 := strconv.Atoi(parts[0])
	count, err2 := strconv.Atoi(parts[1])
	if err1 != nil || err2 != nil || count < 1 || index < 1 || index > count {
		return 0, 0, fmt.Errorf("--shard wants i/n with 1 <= i <= n, got %q", value)
	}
	return index - 1, count, nil
}

// expand resolves every --inputs value: a glob, a file, or a directory (one level).
func expand(values []string) ([]string, error) {
	seen := make(map[string]struct{})
	var out []string

	// Declared before its literal because add recurses into directories. `add := func(...)` would
	// not be able to call itself.
	var add func(path string) error
	add = func(path string) error {
		abs, err := filepath.Abs(path)
		if err != nil {
			return fmt.Errorf("resolve %s: %w", path, err)
		}
		if _, ok := seen[abs]; ok {
			return nil
		}
		info, err := os.Stat(abs)
		if err != nil {
			return fmt.Errorf("--inputs %s: %w", path, err)
		}
		if info.IsDir() {
			entries, err := os.ReadDir(abs)
			if err != nil {
				return fmt.Errorf("read directory %s: %w", path, err)
			}
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				if err := add(filepath.Join(abs, entry.Name())); err != nil {
					return err
				}
			}
			return nil
		}
		seen[abs] = struct{}{}
		out = append(out, abs)
		return nil
	}

	for _, value := range values {
		// On Windows a backslash path and a glob are told apart by the presence of wildcard runes,
		// which is also how filepath.Glob decides.
		if strings.ContainsAny(value, "*?[") {
			matches, err := filepath.Glob(value)
			if err != nil {
				return nil, fmt.Errorf("--inputs %s: %w", value, err)
			}
			if len(matches) == 0 {
				return nil, fmt.Errorf("--inputs %q matched no files (quote it in your shell if it is meant literally)", value)
			}
			for _, match := range matches {
				if err := add(match); err != nil {
					return nil, err
				}
			}
			continue
		}
		if err := add(value); err != nil {
			return nil, err
		}
	}

	sort.Strings(out)
	return out, nil
}

// selectShard returns the i-th contiguous slice of a sorted list. Contiguous beats round-robin here
// because it keeps each device reading a sequential run of files, which is friendlier on spinning
// disks and on directory cache.
func selectShard(inputs []string, index, count int) []string {
	if count <= 1 || len(inputs) == 0 {
		return inputs
	}
	if index < 0 || index >= count {
		return nil
	}
	size := (len(inputs) + count - 1) / count
	start := index * size
	if start >= len(inputs) {
		return nil
	}
	end := start + size
	if end > len(inputs) {
		end = len(inputs)
	}
	return inputs[start:end]
}
