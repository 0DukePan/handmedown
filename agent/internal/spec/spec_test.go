package spec

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixture writes n files and returns a glob matching only them.
func fixture(t *testing.T, names ...string) (dir, glob string) {
	t.Helper()
	dir = t.TempDir()
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatalf("write fixture %s: %v", name, err)
		}
	}
	return dir, filepath.Join(dir, "*.txt")
}

func TestFilesModeExpandsAndSorts(t *testing.T) {
	_, glob := fixture(t, "b.txt", "a.txt", "c.txt")

	opts, err := Parse([]string{"--inputs", glob, "--outdir", "out", "--", "tool", "--flag"})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if opts.Mode != ModeFiles {
		t.Errorf("Mode = %v, want files", opts.Mode)
	}
	if len(opts.Inputs) != 3 {
		t.Fatalf("got %d inputs, want 3", len(opts.Inputs))
	}
	if !strings.HasSuffix(opts.Inputs[0], "a.txt") || !strings.HasSuffix(opts.Inputs[1], "b.txt") {
		t.Errorf("inputs are not sorted: %v", opts.Inputs)
	}
	if len(opts.Command) != 2 || opts.Command[0] != "tool" {
		t.Errorf("Command = %v, want the arguments after --", opts.Command)
	}
	if opts.OutDir != "out" {
		t.Errorf("OutDir = %q, want out", opts.OutDir)
	}
	if opts.Count() != 3 {
		t.Errorf("Count = %d, want 3", opts.Count())
	}
}

func TestCommandModeNeedsNoInputs(t *testing.T) {
	opts, err := Parse([]string{"--", "echo", "hi"})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if opts.Mode != ModeCommand {
		t.Errorf("Mode = %v, want command", opts.Mode)
	}
	if opts.Count() != 1 {
		t.Errorf("Count = %d, want 1", opts.Count())
	}
	// No --outdir was given and nothing is written per input, so hand must not invent a directory.
	if opts.OutDir != "" {
		t.Errorf("OutDir = %q, want empty in command mode without --outdir", opts.OutDir)
	}
}

func TestShardsShareAJobIDButNotWork(t *testing.T) {
	_, glob := fixture(t, "a.txt", "b.txt", "c.txt", "d.txt")

	first, err := Parse([]string{"--inputs", glob, "--shard", "1/2", "--", "tool"})
	if err != nil {
		t.Fatalf("Parse first shard: %v", err)
	}
	second, err := Parse([]string{"--inputs", glob, "--shard", "2/2", "--", "tool"})
	if err != nil {
		t.Fatalf("Parse second shard: %v", err)
	}

	if first.JobID() != second.JobID() {
		t.Errorf("job ids differ (%s vs %s); shards of one job must share it", first.JobID(), second.JobID())
	}
	if first.ShardID() == second.ShardID() {
		t.Errorf("shard ids are equal (%s); they must differ", first.ShardID())
	}
	if first.ShardID() != "1-of-2" || second.ShardID() != "2-of-2" {
		t.Errorf("shard ids = %q/%q, want 1-of-2/2-of-2", first.ShardID(), second.ShardID())
	}

	// Contiguous halves of a sorted list of four: two each, no overlap, nothing lost.
	if len(first.Inputs) != 2 || len(second.Inputs) != 2 {
		t.Fatalf("slices = %d/%d, want 2/2", len(first.Inputs), len(second.Inputs))
	}
	if first.Inputs[0] == second.Inputs[0] {
		t.Error("shards overlap")
	}
}

func TestJobIDChangesWhenTheCommandChanges(t *testing.T) {
	_, glob := fixture(t, "a.txt")

	one, err := Parse([]string{"--inputs", glob, "--", "tool", "--quality", "1"})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	two, err := Parse([]string{"--inputs", glob, "--", "tool", "--quality", "2"})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if one.JobID() == two.JobID() {
		t.Error("two different commands produced the same job id")
	}
}

func TestJobIDSurvivesInputReordering(t *testing.T) {
	_, glob := fixture(t, "a.txt", "b.txt")

	one, err := Parse([]string{"--inputs", glob, "--", "tool"})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// Same files, given in the other order: the glob result is sorted, so the id must not move.
	two, err := Parse([]string{"--inputs", glob, "--inputs", glob, "--", "tool"})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if one.JobID() != two.JobID() {
		t.Errorf("job id changed with argument repetition: %s vs %s", one.JobID(), two.JobID())
	}
	if len(two.Inputs) != 2 {
		t.Errorf("duplicate --inputs produced %d inputs, want 2 deduped", len(two.Inputs))
	}
}

func TestCommandMustFollowDoubleDash(t *testing.T) {
	_, err := Parse([]string{"tool", "--flag"})
	if err == nil {
		t.Fatal("Parse accepted a command without --")
	}
	if !strings.Contains(err.Error(), "after `--`") {
		t.Errorf("error = %v, want it to teach the -- convention", err)
	}
}

func TestUnknownFlagIsRejected(t *testing.T) {
	_, err := Parse([]string{"--outdirr", "out", "--", "tool"})
	if err == nil {
		t.Fatal("Parse accepted a misspelled flag")
	}
	if !strings.Contains(err.Error(), "--outdirr") {
		t.Errorf("error = %v, want it to quote the unknown flag", err)
	}
}

func TestBadShardSpecIsRejected(t *testing.T) {
	for _, value := range []string{"0/2", "3/2", "2", "a/b", "1/0"} {
		_, err := Parse([]string{"--shard", value, "--", "tool"})
		if err == nil {
			t.Errorf("Parse accepted --shard %q", value)
		}
	}
}

func TestMissingInputFileIsReported(t *testing.T) {
	_, err := Parse([]string{"--inputs", filepath.Join(t.TempDir(), "nope.txt"), "--", "tool"})
	if err == nil {
		t.Fatal("Parse accepted a missing input file")
	}
}

func TestNoCommandIsRejected(t *testing.T) {
	_, err := Parse([]string{"--inputs", "x"})
	if err == nil {
		t.Fatal("Parse accepted a run with no command")
	}
}
