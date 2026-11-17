package out

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTemp(t *testing.T, store *Store, shard, name, content string) string {
	t.Helper()
	temp, err := store.TempPath(shard, name)
	if err != nil {
		t.Fatalf("TempPath: %v", err)
	}
	if err := os.WriteFile(temp, []byte(content), 0o644); err != nil {
		t.Fatalf("write temp: %v", err)
	}
	return temp
}

func TestCommitIsContentAddressed(t *testing.T) {
	store := New(t.TempDir())
	temp := writeTemp(t, store, "s-1", "a.mov", "hello")

	final, digest, err := store.Commit(temp, "s-1", "a.mov")
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}

	sum := strings.TrimPrefix(digest, "sha256:")
	if len(sum) != 64 {
		t.Fatalf("digest = %q, want sha256:<64 hex>", digest)
	}
	if want := filepath.Join(store.Dir(), "s-1", "a.mov."+sum[:12]); final != want {
		t.Errorf("final = %q, want %q", final, want)
	}
	if _, err := os.Stat(final); err != nil {
		t.Fatalf("final file missing: %v", err)
	}
	// The temp directory must not be left behind.
	if _, err := os.Stat(filepath.Dir(temp)); !os.IsNotExist(err) {
		t.Error("temp directory survived the commit")
	}
}

func TestCommitTwiceWithSameBytesIsANoOp(t *testing.T) {
	store := New(t.TempDir())

	first := writeTemp(t, store, "s-1", "a.mov", "hello")
	final1, digest1, err := store.Commit(first, "s-1", "a.mov")
	if err != nil {
		t.Fatalf("first Commit: %v", err)
	}

	second := writeTemp(t, store, "s-1", "a.mov", "hello")
	final2, digest2, err := store.Commit(second, "s-1", "a.mov")
	if err != nil {
		t.Fatalf("second Commit: %v", err)
	}

	if final1 != final2 || digest1 != digest2 {
		t.Errorf("retry produced %q/%q, want the same %q/%q", final1, digest1, final2, digest2)
	}
	entries, err := os.ReadDir(filepath.Join(store.Dir(), "s-1"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Errorf("shard directory has %d entries, want 1: %v", len(entries), entries)
	}
}

func TestDifferentBytesLandSideBySide(t *testing.T) {
	store := New(t.TempDir())

	// A non-deterministic command is exactly the case the conflict check exists for: both results
	// must survive so the brain can compare them.
	a := writeTemp(t, store, "s-1", "a.mov", "version one")
	finalA, _, err := store.Commit(a, "s-1", "a.mov")
	if err != nil {
		t.Fatalf("Commit a: %v", err)
	}

	b := writeTemp(t, store, "s-1", "a.mov", "version two")
	finalB, _, err := store.Commit(b, "s-1", "a.mov")
	if err != nil {
		t.Fatalf("Commit b: %v", err)
	}

	if finalA == finalB {
		t.Fatalf("both versions committed to the same path %q", finalA)
	}
	for _, path := range []string{finalA, finalB} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("missing %s: %v", path, err)
		}
	}
}

func TestVerifyDetectsTampering(t *testing.T) {
	store := New(t.TempDir())
	temp := writeTemp(t, store, "s-1", "a.mov", "hello")
	final, digest, err := store.Commit(temp, "s-1", "a.mov")
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}

	if err := Verify(final, digest); err != nil {
		t.Fatalf("Verify on an untouched file: %v", err)
	}

	if err := os.WriteFile(final, []byte("tampered"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Verify(final, digest); err == nil {
		t.Fatal("Verify accepted a modified file")
	}
}

func TestTempPathRejectsEscapingNames(t *testing.T) {
	store := New(t.TempDir())
	if _, err := store.TempPath("s-1", "../../etc/passwd"); err != nil {
		t.Fatalf("TempPath should have flattened the path, got error: %v", err)
	}

	temp, err := store.TempPath("s-1", "../evil")
	if err != nil {
		t.Fatalf("TempPath: %v", err)
	}
	if strings.Contains(filepath.Base(temp), "..") {
		t.Errorf("temp path %q kept the traversal", temp)
	}
}
