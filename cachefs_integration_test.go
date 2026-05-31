//go:build integration

package exiftool

import (
	"io"
	"io/fs"
	"testing"

	"github.com/lbe/cfsread"
)

// TestCachedFSIntegration is an end-to-end test that exercises cachedFS with
// the real embedded perlFSRoot. It verifies that:
//  1. LZ4-compressed Carp.pm decompresses to valid Perl (starts with "package Carp").
//  2. A second read of the same file results in a cache hit (verified via testMetrics).
func TestCachedFSIntegration(t *testing.T) {
	// Check if embed assets are compressed
	subFS, err := fs.Sub(perlFSRoot, "embed/perl-wasi-prefix")
	if err != nil {
		t.Fatalf("fs.Sub failed: %v", err)
	}

	carpPath := findEmbeddedCarpPath(t, subFS)

	rawFile, err := subFS.Open(carpPath)
	if err != nil {
		t.Skipf("Carp.pm not found: %v", err)
	}

	magic := make([]byte, 4)
	if _, err = io.ReadFull(rawFile, magic); err != nil {
		rawFile.Close()
		t.Skipf("Cannot read magic bytes: %v", err)
	}
	rawFile.Close()

	expectedMagic := []byte{0x04, 0x22, 0x4D, 0x18}
	for i, b := range expectedMagic {
		if magic[i] != b {
			t.Skip("embed assets not yet compressed")
		}
	}

	tm := &testMetrics{}
	cfs := newCachedFS("test-integration", subFS, cfsread.Options{
		MaxEntries: 100,
		Metrics:    tm,
	})
	defer cfs.Close()

	// First read - should decompress and cache
	f1, err := cfs.Open(carpPath)
	if err != nil {
		t.Fatalf("First Open failed: %v", err)
	}

	data1, err := io.ReadAll(f1)
	f1.Close()
	if err != nil {
		t.Fatalf("First ReadAll failed: %v", err)
	}

	// Verify decompressed content
	expected := "package Carp"
	if len(data1) < len(expected) {
		t.Fatalf("file too short: got %d bytes", len(data1))
	}
	if string(data1[:len(expected)]) != expected {
		t.Errorf("got %q, want prefix %q", string(data1[:50]), expected)
	}

	// Check cache miss on first read
	if tm.misses.Load() != 1 {
		t.Errorf("after first read: misses = %d, want 1", tm.misses.Load())
	}
	if tm.hits.Load() != 0 {
		t.Errorf("after first read: hits = %d, want 0", tm.hits.Load())
	}

	// Second read - should be a cache hit
	f2, err := cfs.Open(carpPath)
	if err != nil {
		t.Fatalf("Second Open failed: %v", err)
	}

	data2, err := io.ReadAll(f2)
	f2.Close()
	if err != nil {
		t.Fatalf("Second ReadAll failed: %v", err)
	}

	// Check cache hit on second read
	if tm.misses.Load() != 1 {
		t.Errorf("after second read: misses = %d, want 1", tm.misses.Load())
	}
	if tm.hits.Load() != 1 {
		t.Errorf("after second read: hits = %d, want 1", tm.hits.Load())
	}

	// Verify both reads returned the same data
	if string(data1) != string(data2) {
		t.Errorf("data mismatch between first and second read")
	}
}

func findEmbeddedCarpPath(t *testing.T, fsys fs.FS) string {
	t.Helper()

	var carpPath string
	err := fs.WalkDir(fsys, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Name() == "Carp.pm" {
			carpPath = path
			return fs.SkipAll
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk embed tree: %v", err)
	}
	if carpPath == "" {
		t.Skip("Carp.pm not found in embedded perl-wasi-prefix")
	}
	return carpPath
}
