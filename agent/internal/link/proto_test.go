package link

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRoundTripEveryMessage(t *testing.T) {
	cases := []struct {
		name    string
		payload any
		into    func() any
	}{
		{"hello", Hello{Host: "pixel", OS: "android", Arch: "arm64", Cores: 8, Battery: 74, Thermal: "warm", Token: "t"}, func() any { return &Hello{} }},
		{"welcome", Welcome{NodeID: "n-1", BrainVersion: "0.1.0", BeatMS: 5000}, func() any { return &Welcome{} }},
		{"beat", Beat{TS: "2026-11-17T17:00:00Z", Running: []string{"s-1"}, Battery: 12, Thermal: "hot", Load: 0.4, Seq: map[string]int64{"s-1": 7}}, func() any { return &Beat{} }},
		{"lease", Lease{ShardID: "s-1", JobID: "j-1", Attempt: 2, Cmd: []string{"tool", "--x"}, Env: map[string]string{"A": "b"}, Inputs: []string{"/in/a"}, Index: 1, Total: 3, TTLMS: 30000}, func() any { return &Lease{} }},
		{"ack", Ack{ShardID: "s-1", ResumeSeq: 9}, func() any { return &Ack{} }},
		{"progress", Progress{ShardID: "s-1", Seq: 4, Done: 4, Total: 10}, func() any { return &Progress{} }},
		{"done", Done{ShardID: "s-1", Digest: "sha256:aa", InputsDone: 10, DurationMS: 1234}, func() any { return &Done{} }},
		{"fail", Fail{ShardID: "s-1", Error: "exited 3", ExitCode: 3}, func() any { return &Fail{} }},
		{"revoke", Revoke{ShardID: "s-1"}, func() any { return &Revoke{} }},
		{"cancel", Cancel{JobID: "j-1"}, func() any { return &Cancel{} }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frame, err := Encode(tc.name, tc.payload)
			if err != nil {
				t.Fatalf("Encode: %v", err)
			}

			envelope, err := Decode(frame)
			if err != nil {
				t.Fatalf("Decode: %v", err)
			}
			if envelope.Type != tc.name {
				t.Fatalf("Type = %q, want %q", envelope.Type, tc.name)
			}
			if envelope.V != Version {
				t.Fatalf("V = %q, want %q", envelope.V, Version)
			}

			target := tc.into()
			if err := Into(envelope, target); err != nil {
				t.Fatalf("Into: %v", err)
			}

			// Re-encoding the decoded value must produce the same JSON, which catches a tag typo
			// that would otherwise silently drop a field.
			first, _ := json.Marshal(tc.payload)
			second, _ := json.Marshal(target)
			if string(first) != string(second) {
				t.Errorf("payload changed through the round trip:\n sent: %s\n got: %s", first, second)
			}
		})
	}
}

func TestUnknownFieldsAreTolerated(t *testing.T) {
	// Forward compatibility: a newer brain adds a field, an older agent must still work.
	frame := []byte(`{"v":"v1","type":"welcome","data":{"node_id":"n-1","beat_ms":5000,"shiny_new_field":{"a":1}}}`)

	envelope, err := Decode(frame)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}

	var welcome Welcome
	if err := Into(envelope, &welcome); err != nil {
		t.Fatalf("Into: %v", err)
	}
	if welcome.NodeID != "n-1" || welcome.BeatMS != 5000 {
		t.Errorf("known fields lost: %+v", welcome)
	}
}

func TestVersionMismatchIsRefusedClearly(t *testing.T) {
	_, err := Decode([]byte(`{"v":"v9","type":"welcome"}`))
	if err == nil {
		t.Fatal("Decode accepted a future protocol version")
	}
	if !strings.Contains(err.Error(), "v9") || !strings.Contains(err.Error(), Version) {
		t.Errorf("error = %v, want both versions named so the user knows what to upgrade", err)
	}
}

func TestMissingVersionIsRefused(t *testing.T) {
	_, err := Decode([]byte(`{"type":"welcome"}`))
	if err == nil {
		t.Fatal("Decode accepted a message with no version")
	}
}

func TestMissingTypeIsRefused(t *testing.T) {
	_, err := Decode([]byte(`{"v":"v1","data":{}}`))
	if err == nil {
		t.Fatal("Decode accepted a message with no type")
	}
}

func TestPayloadIsRequired(t *testing.T) {
	envelope, err := Decode([]byte(`{"v":"v1","type":"lease"}`))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	var lease Lease
	if err := Into(envelope, &lease); err == nil {
		t.Fatal("Into accepted a lease with no payload")
	}
}

func TestKnownType(t *testing.T) {
	for _, messageType := range []string{TypeHello, TypeWelcome, TypeBeat, TypeLease, TypeDone} {
		if !KnownType(messageType) {
			t.Errorf("KnownType(%q) = false", messageType)
		}
	}
	if KnownType("self_destruct") {
		t.Error("KnownType accepted an invented type")
	}
}
