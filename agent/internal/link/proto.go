// Package link is the agent's side of protocol v1: JSON over one WebSocket.
//
// The seam at ws://<brain>/ws is deliberately dumb — no shared memory, no code generation, no Erlang
// distribution reaching the device. Either tier could be rewritten in another language without the
// other noticing, which is the only real proof that the split is architectural.
//
// Compatibility rules that are enforced here:
//
//   - Every message carries "v". A mismatched version is refused with a message that says what to
//     upgrade, not a mystery timeout.
//   - Unknown *fields* are ignored, so a newer brain can add data to a message an older agent reads.
//   - Unknown message *types* are an error, because silently ignoring an instruction ("revoke this
//     shard") is worse than dropping the connection.
package link

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Version is the protocol version. Bump it when a message changes meaning, not when it grows a field.
const Version = "v1"

// Message types, as they appear on the wire.
const (
	TypeHello    = "hello"
	TypeWelcome  = "welcome"
	TypeBeat     = "beat"
	TypeLease    = "lease"
	TypeAck      = "ack"
	TypeProgress = "progress"
	TypeDone     = "done"
	TypeFail     = "fail"
	TypeRevoke   = "revoke"
	TypeCancel   = "cancel"
)

// Envelope wraps every message. Data stays raw until the type is known, so a message can be routed
// before it is decoded.
type Envelope struct {
	V    string          `json:"v"`
	Type string          `json:"type"`
	Data json.RawMessage `json:"data,omitempty"`
}

// Hello is the first frame an agent sends. It carries the token, so the brain must validate it
// before trusting anything else in the connection.
type Hello struct {
	AgentVersion string `json:"agent_version"`
	Host         string `json:"host"`
	OS           string `json:"os"`
	Arch         string `json:"arch"`
	Cores        int    `json:"cores"`
	MemMB        int    `json:"mem_mb"`
	DiskFreeMB   int    `json:"disk_free_mb"`
	Battery      int    `json:"battery"` // percent, or -1 when the device has no battery reading
	Thermal      string `json:"thermal"` // nominal | warm | hot | unknown
	Token        string `json:"token"`
}

// Welcome tells the agent it is enrolled and how often to beat.
type Welcome struct {
	NodeID       string `json:"node_id"`
	BrainVersion string `json:"brain_version"`
	BeatMS       int    `json:"beat_ms"`
}

// Beat is the heartbeat. Seq reports how far each running shard has got, which is what lets the brain
// tell "working slowly" from "gone".
type Beat struct {
	TS      string           `json:"ts"`
	Running []string         `json:"running"`
	Battery int              `json:"battery"`
	Thermal string           `json:"thermal"`
	Load    float64          `json:"load"`
	Seq     map[string]int64 `json:"seq,omitempty"`
}

// Lease grants one shard to this agent for TTLMS. It is the only way work arrives.
type Lease struct {
	ShardID string            `json:"shard_id"`
	JobID   string            `json:"job_id"`
	Attempt int               `json:"attempt"`
	Cmd     []string          `json:"cmd"`
	Env     map[string]string `json:"env,omitempty"`
	Inputs  []string          `json:"inputs"`
	Index   int               `json:"index"`
	Total   int               `json:"total"`
	TTLMS   int               `json:"ttl_ms"`
}

// Ack is the agent accepting a lease and saying where it will resume from.
type Ack struct {
	ShardID   string `json:"shard_id"`
	ResumeSeq int64  `json:"resume_seq"`
}

// Progress is periodic, so the dashboard moves without waiting for a whole shard.
type Progress struct {
	ShardID string `json:"shard_id"`
	Seq     int64  `json:"seq"`
	Done    int    `json:"done"`
	Total   int    `json:"total"`
}

// Done reports a finished shard with the digest of its inputs' outputs, so a duplicate completion can
// be compared rather than trusted.
type Done struct {
	ShardID    string `json:"shard_id"`
	Digest     string `json:"digest"`
	InputsDone int    `json:"inputs_done"`
	DurationMS int64  `json:"duration_ms"`
}

// Fail reports a shard that will not work here.
type Fail struct {
	ShardID  string `json:"shard_id"`
	Error    string `json:"error"`
	ExitCode int    `json:"exit_code"`
}

// Revoke takes a lease back (the brain noticed a duplicate, or is rebalancing).
type Revoke struct {
	ShardID string `json:"shard_id"`
}

// Cancel stops everything for one job.
type Cancel struct {
	JobID string `json:"job_id"`
}

// Encode builds a frame for one payload.
func Encode(messageType string, payload any) ([]byte, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encode %s: %w", messageType, err)
	}
	frame, err := json.Marshal(Envelope{V: Version, Type: messageType, Data: data})
	if err != nil {
		return nil, fmt.Errorf("encode envelope for %s: %w", messageType, err)
	}
	return frame, nil
}

// Decode validates the envelope and leaves the payload raw.
func Decode(frame []byte) (Envelope, error) {
	var envelope Envelope
	if err := json.Unmarshal(frame, &envelope); err != nil {
		return Envelope{}, fmt.Errorf("decode frame: %w", err)
	}
	if envelope.V == "" {
		return Envelope{}, errors.New("message has no protocol version: refusing to guess")
	}
	if envelope.V != Version {
		return Envelope{}, fmt.Errorf("protocol %s, this build speaks %s: upgrade the %s",
			envelope.V, Version, "older side")
	}
	if envelope.Type == "" {
		return Envelope{}, errors.New("message has no type")
	}
	return envelope, nil
}

// Into decodes an envelope's payload into a typed message.
func Into(envelope Envelope, payload any) error {
	if len(envelope.Data) == 0 {
		return fmt.Errorf("%s message carried no payload", envelope.Type)
	}
	if err := json.Unmarshal(envelope.Data, payload); err != nil {
		return fmt.Errorf("decode %s payload: %w", envelope.Type, err)
	}
	return nil
}

// KnownType reports whether this build understands a message type. Used for the directions the agent
// must not silently ignore.
func KnownType(messageType string) bool {
	switch messageType {
	case TypeHello, TypeWelcome, TypeBeat, TypeLease, TypeAck, TypeProgress,
		TypeDone, TypeFail, TypeRevoke, TypeCancel:
		return true
	default:
		return false
	}
}
