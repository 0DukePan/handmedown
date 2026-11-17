// Package cli is the whole command surface of the agent.
//
// Run takes its streams as arguments rather than reading os.Stdout directly, so the tests exercise
// real command behaviour (exit codes, which stream text lands on) without touching the process.
package cli

import (
	"fmt"
	"io"

	"github.com/0DukePan/handmedown/agent/internal/version"
)

// exitUsage matches the convention most CLIs use for "you called me wrong".
const (
	exitOK    = 0
	exitUsage = 2
)

const usage = `hand - run one command across the hardware you already own

usage:
  hand run [flags] -- <command...>   run once per input, resumable and content-addressed
  hand submit [flags] -- <command...>  send a job to a brain and watch it there
  hand join [flags]                  enrol this machine and run whatever it is leased
  hand demo [flags]                  prove the recovery guarantee on this machine alone
  hand version                       print the version and build target
  hand help                          print this text

run ` + "`hand <command> --help`" + ` for the flags of any of them.

The brain and the distributed half land milestone by milestone; two rules hold throughout:
you always get a one-line explanation of what failed, and the suggested next command.
See docs/DESIGN.md for what is already proven.
`

// Run dispatches one invocation and returns the process exit code.
func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		// No arguments is a mistake, not a no-op: nothing here is safe to run blind.
		fmt.Fprint(stderr, usage)
		return exitUsage
	}

	switch args[0] {
	case "run":
		return runJob(args[1:], stdout, stderr)
	case "submit":
		return submitCommand(args[1:], stdout, stderr)
	case "join":
		return joinCommand(args[1:], stdout, stderr)
	case "demo":
		return runDemo(args[1:], stdout, stderr)
	case demoWorkerCommand:
		// Internal: the demo re-invokes this same binary as its unit of work. Deliberately absent from
		// the usage text, because it is an implementation detail of the demo.
		return demoWorker(stdout, stderr)
	case "version", "--version", "-v":
		fmt.Fprintf(stdout, "hand %s (%s)\n", version.Version, version.Runtime())
		return exitOK
	case "help", "--help", "-h":
		fmt.Fprint(stdout, usage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "hand: unknown command %q\n\n", args[0])
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
}
