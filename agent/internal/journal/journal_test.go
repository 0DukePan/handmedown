package journal

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "s-1-of-1.jsonl")
}

func TestRoundTrip(t *testing.T) {
	path := testPath(t)

	j, state, err := Open(path, "job-1", "s-1", 3)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if len(state.Items) != 0 {
		t.Fatalf("fresh journal has items: %v", state.Items)
	}

	if err := j.Item("/tmp/a", "/out/a.abc", "sha256:aaa"); err != nil {
		t.Fatalf("Item: %v", err)
	}
	if err := j.Item("/tmp/b", "/out/b.def", "sha256:bbb"); err != nil {
		t.Fatalf("Item: %v", err)
	}
	if err := j.Done(3); err != nil {
		t.Fatalf("Done: %v", err)
	}
	if err := j.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	got, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !got.Done {
		t.Error("Done = false, want true")
	}
	if got.Total != 3 {
		t.Errorf("Total = %d, want 3", got.Total)
	}
	if got.LastSeq != 4 {
		t.Errorf("LastSeq = %d, want 4 (start + 2 items + done)", got.LastSeq)
	}
	if got.Items["/tmp/a"] != "sha256:aaa" || got.Items["/tmp/b"] != "sha256:bbb" {
		t.Errorf("Items = %v, want both digests", got.Items)
	}
}

func TestResumeContinuesTheSequence(t *testing.T) {
	path := testPath(t)

	j, _, err := Open(path, "job-1", "s-1", 2)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := j.Item("/tmp/a", "/out/a.abc", "sha256:aaa"); err != nil {
		t.Fatalf("Item: %v", err)
	}
	_ = j.Close()

	// Second run: same file. It must pick up the sequence, not restart it, and must not write a
	// second start record (which would misreport the run's total).
	j2, state, err := Open(path, "job-1", "s-1", 2)
	if err != nil {
		t.Fatalf("re-Open: %v", err)
	}
	if state.LastSeq != 2 {
		t.Errorf("resumed LastSeq = %d, want 2", state.LastSeq)
	}
	if _, ok := state.Items["/tmp/a"]; !ok {
		t.Error("resumed state lost the committed item")
	}
	if err := j2.Item("/tmp/b", "/out/b.def", "sha256:bbb"); err != nil {
		t.Fatalf("Item after resume: %v", err)
	}
	_ = j2.Close()

	final, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if final.LastSeq != 3 {
		t.Errorf("LastSeq = %d, want 3", final.LastSeq)
	}

	starts := 0
	raw, _ := os.ReadFile(path)
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.Contains(line, `"op":"start"`) {
			starts++
		}
	}
	if starts != 1 {
		t.Errorf("start records = %d, want exactly 1", starts)
	}
}

func TestTornLastLineIsIgnored(t *testing.T) {
	path := testPath(t)
	content := `{"seq":1,"op":"start","job":"j","shard":"s","ts":"t","total":1}` + "\n" +
		`{"seq":2,"op":"item","job":"j","shard":"s","ts":"t","key":"/a","digest":"sha256:aa"}` + "\n" +
		`{"seq":3,"op":"item","job":"j","sha`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	state, err := Load(path)
	if err != nil {
		t.Fatalf("Load with torn final line: %v", err)
	}
	if state.LastSeq != 2 {
		t.Errorf("LastSeq = %d, want 2", state.LastSeq)
	}
	if _, ok := state.Items["/a"]; !ok {
		t.Error("lost the committed item because of the torn line")
	}
}

func TestCorruptMiddleLineIsAnError(t *testing.T) {
	path := testPath(t)
	content := `{"seq":1,"op":"start","job":"j","shard":"s","ts":"t","total":1}` + "\n" +
		`not json at all` + "\n" +
		`{"seq":3,"op":"done","job":"j","shard":"s","ts":"t","total":1}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := Load(path); err == nil {
		t.Fatal("Load accepted a corrupt middle line")
	}
}

func TestSequenceGapIsAnError(t *testing.T) {
	path := testPath(t)
	content := `{"seq":1,"op":"start","job":"j","shard":"s","ts":"t","total":2}` + "\n" +
		`{"seq":3,"op":"item","job":"j","shard":"s","ts":"t","key":"/a","digest":"sha256:aa"}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := Load(path)
	if err == nil {
		t.Fatal("Load accepted a sequence gap")
	}
	if !strings.Contains(err.Error(), "sequence jumped") {
		t.Errorf("error = %v, want it to explain the gap", err)
	}
}

func TestItemWithoutDigestDoesNotCount(t *testing.T) {
	path := testPath(t)
	content := `{"seq":1,"op":"start","job":"j","shard":"s","ts":"t","total":1}` + "\n" +
		`{"seq":2,"op":"item","job":"j","shard":"s","ts":"t","key":"/a"}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	state, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if _, ok := state.Items["/a"]; ok {
		t.Error("an item without a digest was treated as finished work")
	}
}

func TestMissingFileIsAnEmptyState(t *testing.T) {
	state, err := Load(filepath.Join(t.TempDir(), "nope.jsonl"))
	if err != nil {
		t.Fatalf("Load missing: %v", err)
	}
	if state.LastSeq != 0 || state.Done || len(state.Items) != 0 {
		t.Errorf("missing file produced %+v, want zero state", state)
	}
}
