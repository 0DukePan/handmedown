package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/0DukePan/handmedown/agent/internal/spec"
)

const submitUsage = `usage: hand submit --brain <url> --token <token> --inputs <glob> [--shards N] [--outdir dir] -- <command...>

Sends a job to the brain and prints where to watch it. The inputs are expanded and sorted here, on the
machine you are typing on, so the brain never has to guess what a glob meant.

This is a convenience over POST /api/jobs - the API is the interface, this is the ergonomics.
`

// submitCommand posts a job to the brain. It exists so the first five minutes do not involve curl.
func submitCommand(args []string, stdout, stderr io.Writer) int {
	brain := "http://127.0.0.1:4100"
	token := os.Getenv("HAND_TOKEN")
	shards := 1
	outDir := "out"

	var specArgs []string
	commandStart := -1

	for index := 0; index < len(args); index++ {
		arg := args[index]

		if arg == "--" {
			commandStart = index + 1
			break
		}

		switch {
		case arg == "--brain":
			brain = next(args, &index)
		case strings.HasPrefix(arg, "--brain="):
			brain = strings.TrimPrefix(arg, "--brain=")
		case arg == "--token":
			token = next(args, &index)
		case strings.HasPrefix(arg, "--token="):
			token = strings.TrimPrefix(arg, "--token=")
		case arg == "--shards":
			if _, err := fmt.Sscanf(next(args, &index), "%d", &shards); err != nil {
				fmt.Fprintf(stderr, "hand submit: --shards wants a number\n")
				return exitUsage
			}
		case arg == "--outdir":
			outDir = next(args, &index)
		case arg == "--inputs":
			specArgs = append(specArgs, "--inputs", next(args, &index))
		case strings.HasPrefix(arg, "--inputs="):
			specArgs = append(specArgs, "--inputs", strings.TrimPrefix(arg, "--inputs="))
		case arg == "--help" || arg == "-h":
			fmt.Fprint(stdout, submitUsage)
			return exitOK
		default:
			fmt.Fprintf(stderr, "hand submit: unexpected argument %q before `--`\n\n%s", arg, submitUsage)
			return exitUsage
		}
	}

	if commandStart < 0 || commandStart >= len(args) {
		fmt.Fprintf(stderr, "hand submit: no command. Put it after `--`.\n\n%s", submitUsage)
		return exitUsage
	}
	if len(specArgs) == 0 {
		fmt.Fprintf(stderr, "hand submit: no --inputs.\n\n%s", submitUsage)
		return exitUsage
	}
	if token == "" {
		fmt.Fprintf(stderr, "hand submit: no token. Pass --token, or set HAND_TOKEN.\n")
		return exitUsage
	}

	// Reuse the local parser so a glob means exactly what it means for `hand run`.
	parsed, err := spec.Parse(append(specArgs, append([]string{"--outdir", outDir, "--"}, args[commandStart:]...)...))
	if err != nil {
		fmt.Fprintf(stderr, "hand submit: %v\n", err)
		return exitUsage
	}

	body, err := json.Marshal(map[string]any{
		"cmd":    parsed.Command,
		"inputs": parsed.AllInputs,
		"shards": shards,
		"outdir": outDir,
	})
	if err != nil {
		fmt.Fprintf(stderr, "hand submit: %v\n", err)
		return exitFailure
	}

	url := strings.TrimSuffix(brain, "/") + "/api/jobs"
	request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		fmt.Fprintf(stderr, "hand submit: %v\n", err)
		return exitFailure
	}
	request.Header.Set("content-type", "application/json")
	request.Header.Set("authorization", "Bearer "+token)

	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		fmt.Fprintf(stderr, "hand submit: cannot reach %s: %v\nIs the brain running? `hand up`\n", url, err)
		return exitFailure
	}
	defer response.Body.Close()

	payload, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusCreated {
		fmt.Fprintf(stderr, "hand submit: brain said %s: %s\n", response.Status, strings.TrimSpace(string(payload)))
		return exitFailure
	}

	var created struct {
		ID     string `json:"id"`
		Shards int    `json:"shards"`
	}
	if err := json.Unmarshal(payload, &created); err != nil {
		fmt.Fprintf(stderr, "hand submit: could not read the brain's answer: %v\n", err)
		return exitFailure
	}

	fmt.Fprintf(stdout, "job %s: %d inputs in %d shards\n", created.ID, len(parsed.AllInputs), created.Shards)
	fmt.Fprintf(stdout, "watch: %s\n", strings.TrimSuffix(brain, "/"))
	return exitOK
}

func next(args []string, index *int) string {
	if *index+1 >= len(args) {
		return ""
	}
	*index++
	return args[*index]
}
