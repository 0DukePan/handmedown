package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/0DukePan/handmedown/agent/internal/facts"
	"github.com/0DukePan/handmedown/agent/internal/jobrun"
	"github.com/0DukePan/handmedown/agent/internal/link"
	"github.com/0DukePan/handmedown/agent/internal/version"
)

const joinUsage = `usage: hand join --brain <url> --token <token> [--verbose]

Enrols this machine and stays connected, running whatever the brain leases.

flags:
  --brain <url>    http://host:port or ws://host:port/ws   (default http://127.0.0.1:4100)
  --token <token>  the join token the brain printed at boot (or HAND_TOKEN)
  --verbose, -v    stream command output, and say what is happening

Stop with ctrl-c. Shards in progress are cancelled but their checkpoints stay on disk, so the work is
recovered - here or on another device - without repeating what already finished.
`

// joinCommand implements `hand join`: dial out, stay connected, run leases.
func joinCommand(args []string, stdout, stderr io.Writer) int {
	brain := "http://127.0.0.1:4100"
	token := os.Getenv("HAND_TOKEN")
	verbose := false

	for index := 0; index < len(args); index++ {
		switch {
		case args[index] == "--brain":
			if index+1 >= len(args) {
				fmt.Fprintf(stderr, "hand join: --brain wants a URL\n")
				return exitUsage
			}
			brain = args[index+1]
			index++
		case args[index] == "--token":
			if index+1 >= len(args) {
				fmt.Fprintf(stderr, "hand join: --token wants a value\n")
				return exitUsage
			}
			token = args[index+1]
			index++
		case args[index] == "--verbose" || args[index] == "-v":
			verbose = true
		case args[index] == "--help" || args[index] == "-h":
			fmt.Fprint(stdout, joinUsage)
			return exitOK
		default:
			fmt.Fprintf(stderr, "hand join: unexpected argument %q\n\n%s", args[index], joinUsage)
			return exitUsage
		}
	}

	if token == "" {
		fmt.Fprintf(stderr, "hand join: no token. Pass --token, or set HAND_TOKEN.\n\n%s", joinUsage)
		return exitUsage
	}

	ctx, stop := signalContext()
	defer stop()

	client := &link.Client{
		URL:   socketURL(brain),
		Token: token,
		Facts: func() map[string]any {
			current := facts.Collect()
			return map[string]any{
				"host":          current.Host,
				"os":            current.OS,
				"arch":          current.Arch,
				"cores":         current.Cores,
				"mem_mb":        current.MemMB,
				"disk_free_mb":  current.DiskFreeMB,
				"battery":       current.Battery,
				"thermal":       current.Thermal,
				"agent_version": version.Version,
			}
		},
		Log: stdout,
		Run: shardRunner(stdout, verbose),
	}

	current := facts.Collect()
	fmt.Fprintf(stdout, "hand %s (%s) joining %s\n", version.Version, version.Runtime(), brain)
	fmt.Fprintf(stdout, "  %s\n", current.Summary())
	fmt.Fprintln(stdout, "  ctrl-c to leave; work in progress is checkpointed and can be resumed anywhere")

	if err := client.ConnectAndServe(ctx); err != nil {
		if errors.Is(err, link.ErrUnauthorized) {
			fmt.Fprintf(stderr, "hand join: %v\nThe token must match the one printed by the brain.\n", err)
			return exitFailure
		}
		fmt.Fprintf(stderr, "hand join: %v\n", err)
		return exitFailure
	}

	return exitOK
}

// shardRunner adapts the shared job engine into the shape the socket client expects.
func shardRunner(stdout io.Writer, verbose bool) link.Executor {
	return func(ctx context.Context, lease link.Lease, progress func(done, total int)) (link.Done, error) {
		outDir := lease.OutDir
		if outDir == "" {
			outDir = "out"
		}

		journalPath := filepath.Join(".hand", "journal", lease.JobID, lease.ShardID+".jsonl")
		started := time.Now()

		result, err := jobrun.Run(ctx, jobrun.Options{
			Command:     lease.Cmd,
			Inputs:      lease.Inputs,
			OutDir:      outDir,
			ShardID:     lease.ShardID,
			JobID:       lease.JobID,
			JournalPath: journalPath,
			Verbose:     verbose,
		}, func(event jobrun.Event) {
			if event.Outcome == jobrun.OutcomeFail {
				fmt.Fprintf(stdout, "  %s failed: %v\n", event.Name, event.Err)
			}
			progress(event.Index+1, event.Total)
		})

		if err != nil {
			return link.Done{}, err
		}

		duration := time.Since(started)
		return link.Done{
			ShardID:    lease.ShardID,
			Digest:     result.Digest,
			InputsDone: result.Done,
			DurationMS: duration.Milliseconds(),
		}, nil
	}
}

// socketURL accepts what a human would type and produces what the websocket needs.
func socketURL(brain string) string {
	brain = strings.TrimSuffix(brain, "/")
	switch {
	case strings.HasPrefix(brain, "ws://"), strings.HasPrefix(brain, "wss://"):
		if strings.HasSuffix(brain, "/ws") {
			return brain
		}
		return brain + "/ws"
	case strings.HasPrefix(brain, "http://"):
		return "ws://" + strings.TrimPrefix(brain, "http://") + "/ws"
	case strings.HasPrefix(brain, "https://"):
		return "wss://" + strings.TrimPrefix(brain, "https://") + "/ws"
	default:
		return "ws://" + brain + "/ws"
	}
}
