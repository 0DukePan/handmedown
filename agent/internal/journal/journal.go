// Package journal is the agent's append-only log for one shard.
//
// It is the only thing standing between "the laptop slept" and "your work is gone", so it is
// deliberately boring: one JSON object per line, fsync after every record, and a replay that trusts
// nothing it cannot verify.
//
// The three replay rules are the whole contract:
//
//  1. A torn final line (crash mid-write) is ignored, not an error.
//  2. A gap in `seq` is an error: something rewrote the file, and resuming would silently skip work.
//  3. Only records with a digest count as finished input. "We started it" is not "it is done".
package journal

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Op values. They are spelled out rather than numeric so a journal stays readable in a bug report.
const (
	OpStart = "start"
	OpItem  = "item"
	OpDone  = "done"
	OpFail  = "fail"
)

// Record is one line of the journal.
type Record struct {
	Seq    int64  `json:"seq"`
	Op     string `json:"op"`
	Job    string `json:"job"`
	Shard  string `json:"shard"`
	Ts     string `json:"ts"`
	Key    string `json:"key,omitempty"`
	Out    string `json:"out,omitempty"`
	Digest string `json:"digest,omitempty"`
	Total  int    `json:"total,omitempty"`
	Err    string `json:"err,omitempty"`
}

// State is what a replay recovered.
type State struct {
	// Items maps input key -> output digest, for inputs that actually committed an output.
	Items map[string]string
	// Done is true only when a done record was written, which happens after every input committed.
	Done bool
	// LastSeq is the highest sequence number read, so the next append continues the file.
	LastSeq int64
	// Total is the input count recorded at start, or 0 if the journal is empty.
	Total int
	// FailErr is the message from the last fail record, if any.
	FailErr string
}

// Journal appends to one shard's file.
type Journal struct {
	file  *os.File
	job   string
	shard string
	seq   int64
}

// Open replays any existing journal at path and returns a writer positioned after its last record.
// A missing file is not an error: it is a first run.
func Open(path, job, shard string, total int) (*Journal, State, error) {
	state, err := Load(path)
	if err != nil {
		return nil, State{}, err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, State{}, fmt.Errorf("create journal directory: %w", err)
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, State{}, fmt.Errorf("open journal %s: %w", path, err)
	}

	j := &Journal{file: file, job: job, shard: shard, seq: state.LastSeq}

	// Only a fresh journal gets a header. Appending a second start record to a resumed run would make
	// the file lie about how the work began.
	if state.LastSeq == 0 {
		if err := j.append(Record{Op: OpStart, Total: total}); err != nil {
			_ = file.Close()
			return nil, State{}, err
		}
	}

	return j, state, nil
}

// Item records a committed input. The digest is what makes the input skippable next time.
func (j *Journal) Item(key, out, digest string) error {
	return j.append(Record{Op: OpItem, Key: key, Out: out, Digest: digest})
}

// Done records that every input finished.
func (j *Journal) Done(total int) error {
	return j.append(Record{Op: OpDone, Total: total})
}

// Fail records why the run stopped. Written immediately before a non-zero exit, so the next run
// explains itself instead of just being slower than expected.
func (j *Journal) Fail(message string) error {
	return j.append(Record{Op: OpFail, Err: message})
}

// Close flushes and closes the file. The journal is already fsynced per record, so this is cleanup.
func (j *Journal) Close() error {
	if j.file == nil {
		return nil
	}
	err := j.file.Close()
	j.file = nil
	return err
}

func (j *Journal) append(rec Record) error {
	rec.Seq = j.seq + 1
	rec.Job = j.job
	rec.Shard = j.shard
	rec.Ts = time.Now().UTC().Format(time.RFC3339Nano)

	line, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("encode journal record: %w", err)
	}
	line = append(line, '\n')

	if _, err := j.file.Write(line); err != nil {
		return fmt.Errorf("write journal: %w", err)
	}

	// fsync per record. At a few hundred inputs a second this is noise, and it is the difference
	// between "the journal knows" and "the journal might know" after a power cut.
	if err := j.file.Sync(); err != nil {
		return fmt.Errorf("flush journal: %w", err)
	}

	j.seq = rec.Seq
	return nil
}

// Load replays a journal without acquiring a writer.
func Load(path string) (State, error) {
	state := State{Items: make(map[string]string)}

	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return state, nil
	}
	if err != nil {
		return State{}, fmt.Errorf("read journal %s: %w", path, err)
	}

	lines := strings.Split(string(raw), "\n")

	for i, line := range lines {
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			continue
		}

		isLast := i == len(lines)-1
		// A file that ends without a newline has a final line that may have been cut mid-write by a
		// crash. That one is ignorable; anything earlier must parse.
		hasNewline := !isLast || strings.HasSuffix(string(raw), "\n")

		var rec Record
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			if isLast && !hasNewline {
				return state, nil
			}
			return State{}, fmt.Errorf("journal %s line %d is corrupt: %w", path, i+1, err)
		}

		if rec.Seq != state.LastSeq+1 {
			return State{}, fmt.Errorf(
				"journal %s line %d: sequence jumped from %d to %d; refusing to resume, because work may have been dropped",
				path, i+1, state.LastSeq, rec.Seq)
		}
		state.LastSeq = rec.Seq

		switch rec.Op {
		case OpStart:
			state.Total = rec.Total
		case OpItem:
			// A record without a digest is a torn or hand-edited line; it must not count as done.
			if rec.Key != "" && rec.Digest != "" {
				state.Items[rec.Key] = rec.Digest
			}
		case OpDone:
			state.Done = true
		case OpFail:
			state.FailErr = rec.Err
		}
	}

	return state, nil
}
