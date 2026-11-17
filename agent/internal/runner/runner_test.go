package runner

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// The test binary doubles as the command under test, so these tests need no shell, no external
// program and no OS-specific quoting.
func TestMain(m *testing.M) {
	if mode := os.Getenv("HAND_RUNNER_HELPER"); mode != "" {
		os.Exit(helper(mode))
	}
	os.Exit(m.Run())
}

func helper(mode string) int {
	switch mode {
	case "ok":
		os.Stdout.WriteString("fine")
		return 0
	case "fail":
		os.Stderr.WriteString("boom: input is not a real file")
		return 7
	case "echo-env":
		os.Stdout.WriteString(os.Getenv("HAND_INPUT") + "|" + os.Getenv("HAND_OUTPUT"))
		return 0
	case "sleep":
		time.Sleep(30 * time.Second)
		return 0
	case "flood":
		// More than tailLimit, to prove the tail keeps the end and not the start.
		os.Stdout.WriteString(strings.Repeat("A", 5000) + "LAST")
		return 0
	}
	return 99
}

func self(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	return exe
}

func TestSuccess(t *testing.T) {
	result, err := Run(context.Background(), Task{
		Cmd: []string{self(t)},
		Env: map[string]string{"HAND_RUNNER_HELPER": "ok"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.ExitCode != 0 {
		t.Errorf("ExitCode = %d, want 0", result.ExitCode)
	}
	if result.StdoutTail != "fine" {
		t.Errorf("StdoutTail = %q, want %q", result.StdoutTail, "fine")
	}
}

func TestNonZeroExitIsAResultNotAnError(t *testing.T) {
	result, err := Run(context.Background(), Task{
		Cmd: []string{self(t)},
		Env: map[string]string{"HAND_RUNNER_HELPER": "fail"},
	})
	if err != nil {
		t.Fatalf("Run returned an error for a normal failure exit: %v", err)
	}
	if result.ExitCode != 7 {
		t.Errorf("ExitCode = %d, want 7", result.ExitCode)
	}
	if !strings.Contains(result.StderrTail, "boom") {
		t.Errorf("StderrTail = %q, want it to contain the tool's message", result.StderrTail)
	}
}

func TestEnvReachesTheCommand(t *testing.T) {
	result, err := Run(context.Background(), Task{
		Cmd: []string{self(t)},
		Env: map[string]string{
			"HAND_RUNNER_HELPER": "echo-env",
			"HAND_INPUT":         "/in/a.mov",
			"HAND_OUTPUT":        "/out/a.mov.abc",
		},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if want := "/in/a.mov|/out/a.mov.abc"; result.StdoutTail != want {
		t.Errorf("StdoutTail = %q, want %q", result.StdoutTail, want)
	}
}

func TestCancellationKillsTheCommand(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := Run(ctx, Task{
		Cmd: []string{self(t)},
		Env: map[string]string{"HAND_RUNNER_HELPER": "sleep"},
	})
	if err == nil {
		t.Fatal("Run returned nil error for a cancelled command")
	}
	if !strings.Contains(err.Error(), "cancelled") {
		t.Errorf("error = %v, want it to say cancelled", err)
	}
	// The helper sleeps 30s; if cancellation did not work this test would hang instead of failing.
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("cancellation took %s, want well under 5s", elapsed)
	}
}

func TestTailKeepsTheEnd(t *testing.T) {
	result, err := Run(context.Background(), Task{
		Cmd: []string{self(t)},
		Env: map[string]string{"HAND_RUNNER_HELPER": "flood"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(result.StdoutTail) > tailLimit {
		t.Errorf("tail is %d bytes, want at most %d", len(result.StdoutTail), tailLimit)
	}
	if !strings.HasSuffix(result.StdoutTail, "LAST") {
		t.Error("tail kept the start of the output instead of the end")
	}
}

func TestEmptyCommandIsAnError(t *testing.T) {
	if _, err := Run(context.Background(), Task{}); err == nil {
		t.Fatal("Run accepted an empty command")
	}
}
