package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestVersionWritesToStdoutAndExitsZero(t *testing.T) {
	var stdout, stderr bytes.Buffer

	if code := Run([]string{"version"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("exit = %d, want %d (stderr: %q)", code, exitOK, stderr.String())
	}
	if stderr.Len() != 0 {
		t.Errorf("stderr = %q, want empty", stderr.String())
	}

	got := stdout.String()
	// Shape matters because scripts parse it: "hand <version> (<os>/<arch>)".
	if !strings.HasPrefix(got, "hand ") {
		t.Fatalf("output = %q, want it to start with \"hand \"", got)
	}
	if !strings.HasSuffix(strings.TrimSpace(got), ")") || !strings.Contains(got, "(") {
		t.Fatalf("output = %q, want a trailing (os/arch)", got)
	}
}

func TestNoArgumentsIsAUsageError(t *testing.T) {
	var stdout, stderr bytes.Buffer

	if code := Run(nil, &stdout, &stderr); code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout = %q, want empty: usage for an error belongs on stderr", stdout.String())
	}
	if !strings.Contains(stderr.String(), "usage:") {
		t.Errorf("stderr = %q, want it to contain the usage text", stderr.String())
	}
}

func TestUnknownCommandNamesTheCommand(t *testing.T) {
	var stdout, stderr bytes.Buffer

	if code := Run([]string{"frobnicate"}, &stdout, &stderr); code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "frobnicate") {
		t.Errorf("stderr = %q, want it to quote the unknown command", stderr.String())
	}
}

func TestHelpGoesToStdout(t *testing.T) {
	for _, arg := range []string{"help", "--help", "-h"} {
		var stdout, stderr bytes.Buffer

		if code := Run([]string{arg}, &stdout, &stderr); code != exitOK {
			t.Fatalf("%s: exit = %d, want %d", arg, code, exitOK)
		}
		if !strings.Contains(stdout.String(), "usage:") {
			t.Errorf("%s: stdout = %q, want the usage text", arg, stdout.String())
		}
	}
}
