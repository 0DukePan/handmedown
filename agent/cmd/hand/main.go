// Command hand is the device-side agent: one static binary, no runtime, no install.
//
// Keeping main this small is deliberate. Everything testable lives in internal/cli, so the whole
// command surface runs in a test without spawning a process.
package main

import (
	"os"

	"github.com/0DukePan/handmedown/agent/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
