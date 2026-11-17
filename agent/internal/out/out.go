// Package out stores job outputs by content, not by name.
//
// Every output lands at <dir>/<shard>/<name>.<sha256[:12]>. That single choice removes a whole class
// of bugs: a retried input either reproduces the same digest (so the file already exists and the
// retry is a no-op), or it produces different bytes, which lands under a different name where the
// brain's conflict check can see it. Nothing is silently overwritten with different content.
package out

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// shortLen is how much of the digest goes in the filename. 12 hex chars is 48 bits: far beyond the
// number of files any user will have in one shard, and still readable in a directory listing.
const shortLen = 12

// Store writes into one output root.
type Store struct {
	dir string
}

// New returns a store rooted at dir.
func New(dir string) *Store { return &Store{dir: dir} }

// Dir is the store root.
func (s *Store) Dir() string { return s.dir }

// TempPath is where a command should write its output. It is on the same filesystem as the final
// path (both under the store root), because a rename across filesystems is a copy, not an atomic
// replace.
func (s *Store) TempPath(shard, name string) (string, error) {
	base, err := safeName(name)
	if err != nil {
		return "", err
	}

	suffix := make([]byte, 6)
	if _, err := rand.Read(suffix); err != nil {
		return "", fmt.Errorf("random temp name: %w", err)
	}

	// One temp directory per attempt keeps two concurrent attempts at the same input from colliding,
	// which matters the moment shards run in parallel.
	dir := filepath.Join(s.dir, shard, ".tmp-"+hex.EncodeToString(suffix))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create output temp directory: %w", err)
	}
	return filepath.Join(dir, base), nil
}

// Commit hashes a finished temp file and moves it to its content-addressed home.
//
// It is idempotent: committing identical bytes twice returns the same final path and leaves one file.
func (s *Store) Commit(tempPath, shard, name string) (final, digest string, err error) {
	digest, err = DigestOf(tempPath)
	if err != nil {
		return "", "", err
	}

	base, err := safeName(name)
	if err != nil {
		return "", "", err
	}

	final, err = s.PathFor(shard, base, digest)
	if err != nil {
		return "", "", err
	}

	existing, err := DigestOf(final)
	switch {
	case err == nil:
		// Already there. Same bytes: this retry is a no-op, which is the desired outcome.
		if existing == digest {
			_ = os.RemoveAll(filepath.Dir(tempPath))
			return final, digest, nil
		}
		// Different bytes under the same 48-bit prefix. Astronomically unlikely, and worth
		// reporting rather than overwriting.
		return "", "", fmt.Errorf("output %s already exists with digest %s, refusing to overwrite with %s", final, existing, digest)

	case errors.Is(err, os.ErrNotExist):
		// Expected: first time this content is produced.

	default:
		return "", "", err
	}

	if err := os.MkdirAll(filepath.Dir(final), 0o755); err != nil {
		return "", "", fmt.Errorf("create output directory: %w", err)
	}

	if err := os.Rename(tempPath, final); err != nil {
		// A Windows rename fails if the target appeared in the meantime; the loser of that race
		// should see the winner's file, not an error.
		if current, verifyErr := DigestOf(final); verifyErr == nil && current == digest {
			_ = os.RemoveAll(filepath.Dir(tempPath))
			return final, digest, nil
		}
		return "", "", fmt.Errorf("commit output: %w", err)
	}

	// Best effort: persist the directory entry. On Windows this is not a thing and the error is
	// meaningless, so it is ignored there rather than failing a successful commit.
	syncDir(filepath.Dir(final))

	_ = os.RemoveAll(filepath.Dir(tempPath))
	return final, digest, nil
}

// PathFor is where a given digest for a given input name lives. A resume uses this to find the file
// the journal claims exists, so it can verify the bytes instead of trusting the record.
func (s *Store) PathFor(shard, name, digest string) (string, error) {
	base, err := safeName(name)
	if err != nil {
		return "", err
	}
	sum := strings.TrimPrefix(digest, "sha256:")
	if len(sum) < shortLen {
		return "", fmt.Errorf("digest %q is too short to address a file", digest)
	}
	return filepath.Join(s.dir, shard, base+"."+sum[:shortLen]), nil
}

// DigestOf returns "sha256:<hex>" for a file.
func DigestOf(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", fmt.Errorf("hash %s: %w", path, err)
	}
	return "sha256:" + hex.EncodeToString(sum.Sum(nil)), nil
}

// Verify checks that a file still has the digest the journal recorded for it. This is how a resume
// decides whether a committed output is trustworthy or needs redoing.
func Verify(path, digest string) error {
	actual, err := DigestOf(path)
	if err != nil {
		return err
	}
	if actual != digest {
		return fmt.Errorf("%s: journal says %s, file is %s", path, digest, actual)
	}
	return nil
}

// safeName rejects anything that would escape the shard directory.
func safeName(name string) (string, error) {
	base := filepath.Base(filepath.Clean(name))
	if base == "." || base == string(filepath.Separator) || base == ".." || base == "" {
		return "", fmt.Errorf("refusing to use %q as an output name", name)
	}
	return base, nil
}

func syncDir(dir string) {
	handle, err := os.Open(dir)
	if err != nil {
		return
	}
	defer handle.Close()
	_ = handle.Sync()
}
