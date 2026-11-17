package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The test binary is also the command under test, so these end-to-end tests need no shell and no
// external tool: `hand run -- <test binary>` is a real subprocess doing real file writes.
func TestMain(m *testing.M) {
	// The demo re-invokes this binary as its unit of work. During tests that binary is the test
	// executable, so the same dispatch has to exist here or `hand demo` cannot be tested end to end.
	if len(os.Args) > 1 && os.Args[1] == demoWorkerCommand {
		os.Exit(demoWorker(os.Stdout, os.Stderr))
	}
	if mode := os.Getenv("HAND_CLI_HELPER"); mode != "" {
		os.Exit(helper(mode))
	}
	os.Exit(m.Run())
}

func helper(mode string) int {
	input := os.Getenv("HAND_INPUT")
	output := os.Getenv("HAND_OUTPUT")

	switch mode {
	case "copy":
		content, err := os.ReadFile(input)
		if err != nil {
			os.Stderr.WriteString(err.Error())
			return 3
		}
		if err := os.WriteFile(output, append([]byte("out:"), content...), 0o644); err != nil {
			os.Stderr.WriteString(err.Error())
			return 4
		}
		recordExecution(filepath.Base(input))
		return 0

	case "fail":
		os.Stderr.WriteString("cannot read the input: it is a directory")
		return 5

	case "noop":
		return 0
	}
	return 99
}

// recordExecution appends one line per command execution. It is how a test proves that a resumed run
// did not re-run finished work: the count must not grow.
func recordExecution(name string) {
	counter := os.Getenv("HAND_COUNTER")
	if counter == "" {
		return
	}
	file, err := os.OpenFile(counter, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer file.Close()
	file.WriteString(name + "\n")
}

func selfExecutable(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	return exe
}

func writeInputs(t *testing.T, dir string, names ...string) string {
	t.Helper()
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("payload-"+name), 0o644); err != nil {
			t.Fatalf("write input %s: %v", name, err)
		}
	}
	return filepath.Join(dir, "*.txt")
}

func runArgs(t *testing.T, glob, outDir, journalDir, command string) []string {
	t.Helper()
	return []string{"run", "--inputs", glob, "--outdir", outDir, "--journal", journalDir, "--", command}
}

func TestRunProcessesEveryInputAndResumes(t *testing.T) {
	work := t.TempDir()
	inDir := filepath.Join(work, "in")
	outDir := filepath.Join(work, "out")
	journalDir := filepath.Join(work, "journal")
	counter := filepath.Join(work, "counter.txt")
	for _, dir := range []string{inDir, outDir, journalDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	glob := writeInputs(t, inDir, "a.txt", "b.txt", "c.txt", "d.txt", "e.txt")
	exe := selfExecutable(t)

	t.Setenv("HAND_CLI_HELPER", "copy")
	t.Setenv("HAND_COUNTER", counter)

	args := runArgs(t, glob, outDir, journalDir, exe)

	var stdout, stderr bytes.Buffer
	if code := Run(args, &stdout, &stderr); code != exitOK {
		t.Fatalf("first run exit = %d, want 0\nstderr: %s", code, stderr.String())
	}
	if got := countLines(t, counter); got != 5 {
		t.Fatalf("command ran %d times, want 5", got)
	}
	if got := countOutputs(t, outDir); got != 5 {
		t.Fatalf("%d outputs, want 5", got)
	}

	// Second run: same command, same journal. Everything must be skipped, and the command must not
	// run again. This is the property the whole project is built to guarantee.
	stdout.Reset()
	stderr.Reset()
	if code := Run(args, &stdout, &stderr); code != exitOK {
		t.Fatalf("resume exit = %d, want 0\nstderr: %s", code, stderr.String())
	}
	if got := countLines(t, counter); got != 5 {
		t.Errorf("command ran %d times after resume, want still 5", got)
	}
	if !strings.Contains(stdout.String(), "skip") {
		t.Errorf("resume output does not mention skipping:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "resuming") {
		t.Errorf("resume output does not announce the resume:\n%s", stdout.String())
	}
}

func TestResumeRedoesInputsWhoseOutputWasDeleted(t *testing.T) {
	work := t.TempDir()
	inDir := filepath.Join(work, "in")
	outDir := filepath.Join(work, "out")
	journalDir := filepath.Join(work, "journal")
	counter := filepath.Join(work, "counter.txt")
	for _, dir := range []string{inDir, outDir, journalDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	glob := writeInputs(t, inDir, "a.txt", "b.txt")
	exe := selfExecutable(t)
	t.Setenv("HAND_CLI_HELPER", "copy")
	t.Setenv("HAND_COUNTER", counter)

	args := runArgs(t, glob, outDir, journalDir, exe)
	var stdout, stderr bytes.Buffer
	if code := Run(args, &stdout, &stderr); code != exitOK {
		t.Fatalf("first run exit = %d: %s", code, stderr.String())
	}

	// Delete one committed output. The journal still claims it is done; the run must not believe it.
	outputs, err := filepath.Glob(filepath.Join(outDir, "1-of-1", "*.txt.*"))
	if err != nil || len(outputs) == 0 {
		t.Fatalf("no outputs to delete: %v", err)
	}
	if err := os.Remove(outputs[0]); err != nil {
		t.Fatal(err)
	}

	stdout.Reset()
	stderr.Reset()
	if code := Run(args, &stdout, &stderr); code != exitOK {
		t.Fatalf("resume exit = %d: %s", code, stderr.String())
	}
	if got := countLines(t, counter); got != 3 {
		t.Errorf("command ran %d times, want 3 (2 + the 1 redone)", got)
	}
	if !strings.Contains(stdout.String(), "redo") {
		t.Errorf("resume did not explain the redo:\n%s", stdout.String())
	}
}

func TestFailingCommandIsReportedAndExitsNonZero(t *testing.T) {
	work := t.TempDir()
	inDir := filepath.Join(work, "in")
	if err := os.MkdirAll(inDir, 0o755); err != nil {
		t.Fatal(err)
	}
	glob := writeInputs(t, inDir, "a.txt")

	t.Setenv("HAND_CLI_HELPER", "fail")

	var stdout, stderr bytes.Buffer
	code := Run(runArgs(t, glob, filepath.Join(work, "out"), filepath.Join(work, "journal"), selfExecutable(t)), &stdout, &stderr)

	if code != exitFailure {
		t.Fatalf("exit = %d, want %d", code, exitFailure)
	}
	if !strings.Contains(stderr.String(), "cannot read the input") {
		t.Errorf("stderr does not include the tool's own message:\n%s", stderr.String())
	}
	if !strings.Contains(stderr.String(), "Re-run the same command") {
		t.Errorf("stderr does not say what to do next:\n%s", stderr.String())
	}
}

func TestCommandModeRunsOnceWithoutInputs(t *testing.T) {
	t.Setenv("HAND_CLI_HELPER", "noop")

	// The journal must go to a temp dir. Without --journal it defaults to .hand/journal relative to
	// the working directory, which during `go test` is the package directory: the test would write
	// state into the source tree, and that state would then get committed.
	journalDir := filepath.Join(t.TempDir(), "journal")

	var stdout, stderr bytes.Buffer
	code := Run([]string{"run", "--journal", journalDir, "--", selfExecutable(t)}, &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "done in") {
		t.Errorf("output = %q, want a completion line", stdout.String())
	}
}

func TestUsageErrorGoesToStderrWithExitTwo(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := Run([]string{"run", "--outdir", "out"}, &stdout, &stderr); code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout = %q, want empty", stdout.String())
	}
}

func countLines(t *testing.T, path string) int {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		t.Fatalf("read %s: %v", path, err)
	}
	return len(strings.Split(strings.TrimSpace(string(content)), "\n"))
}

func countOutputs(t *testing.T, outDir string) int {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(outDir, "1-of-1", "*"))
	if err != nil {
		t.Fatalf("glob outputs: %v", err)
	}
	count := 0
	for _, file := range files {
		info, err := os.Stat(file)
		if err == nil && !info.IsDir() {
			count++
		}
	}
	return count
}
