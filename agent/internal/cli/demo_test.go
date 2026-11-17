package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The demo is the one place where the project's central claim is executed rather than described, so
// these tests assert the claim, not the output format: an interrupted run must not repeat work, and a
// demo that cannot show that must fail.

func TestDemoCompletesAndReportsNoRepeatedWork(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := Run([]string{"demo", "--inputs", "8", "--stop-after", "3"}, &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout.String(), stderr.String())
	}

	out := stdout.String()
	if !strings.Contains(out, "interrupted after 3 of 8") {
		t.Errorf("transcript does not report the interruption:\n%s", out)
	}
	if !strings.Contains(out, "0 inputs executed twice") {
		t.Errorf("transcript does not state the verified property:\n%s", out)
	}
	if !strings.Contains(out, "PASS") {
		t.Errorf("transcript has no verdict:\n%s", out)
	}
	if strings.Contains(out, "FAIL") {
		t.Errorf("transcript contains a failure line:\n%s", out)
	}
}

func TestDemoKeepsItsWorkWhenAsked(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := Run([]string{"demo", "--inputs", "4", "--stop-after", "1", "--keep"}, &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr.String())
	}

	// The path it prints is a promise: with --keep, it has to still exist afterwards.
	var kept string
	for _, line := range strings.Split(stdout.String(), "\n") {
		if strings.Contains(line, "kept:") {
			kept = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "kept:"))
		}
	}
	if kept == "" {
		t.Fatalf("no kept path in transcript:\n%s", stdout.String())
	}
	defer os.RemoveAll(kept)

	if _, err := os.Stat(kept); err != nil {
		t.Fatalf("kept directory does not exist: %v", err)
	}

	// One journal per shard, and it records every input: this is the artefact the guarantee rests on.
	if _, err := os.Stat(filepath.Join(kept, "journal", "demo-shard.jsonl")); err != nil {
		t.Errorf("journal missing from kept directory: %v", err)
	}
	outputs, err := filepath.Glob(filepath.Join(kept, "out", "demo-shard", "*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(outputs) != 4 {
		t.Errorf("%d outputs in kept directory, want 4", len(outputs))
	}
}

func TestDemoCleansUpByDefault(t *testing.T) {
	var stdout, stderr bytes.Buffer

	if code := Run([]string{"demo", "--inputs", "4", "--stop-after", "1"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}

	var workDir string
	for _, line := range strings.Split(stdout.String(), "\n") {
		if strings.Contains(line, "workdir") {
			workDir = strings.TrimSpace(strings.SplitN(line, "workdir", 2)[1])
		}
	}
	if workDir == "" {
		t.Fatalf("transcript does not name the work directory:\n%s", stdout.String())
	}
	if _, err := os.Stat(workDir); !os.IsNotExist(err) {
		t.Errorf("work directory %s survived a run without --keep", workDir)
	}
}

func TestDemoRejectsImpossibleOptions(t *testing.T) {
	cases := [][]string{
		{"demo", "--inputs", "5", "--stop-after", "5"}, // nothing left to resume
		{"demo", "--inputs", "1"},                      // fewer than the minimum
		{"demo", "--inputs", "nope"},
		{"demo", "--frobnicate"},
	}

	for _, args := range cases {
		var stdout, stderr bytes.Buffer
		if code := Run(args, &stdout, &stderr); code != exitUsage {
			t.Errorf("%v: exit = %d, want %d (a usage mistake, not a failure)", args, code, exitUsage)
		}
	}
}

func TestDemoWorkerRequiresTheContract(t *testing.T) {
	// The worker is the demo's child process. Without the environment contract it must refuse rather
	// than do something surprising.
	t.Setenv("HAND_INPUT", "")
	t.Setenv("HAND_OUTPUT", "")

	var stdout, stderr bytes.Buffer
	if code := demoWorker(&stdout, &stderr); code != exitFailure {
		t.Fatalf("exit = %d, want %d", code, exitFailure)
	}
	if !strings.Contains(stderr.String(), "HAND_INPUT") {
		t.Errorf("stderr = %q, want it to name the missing variable", stderr.String())
	}
}
