package exiftool

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"testing"
	"testing/fstest"

	"github.com/lbe/cfsread"
	lz4frame "github.com/pierrec/lz4/v4"
)

// TestNewCachedFS_PlainFile verifies that cachedFS correctly reads and returns
// the contents of a plain (non-compressed) file from an fstest.MapFS source.
func TestNewCachedFS_PlainFile(t *testing.T) {
	// Create a simple MapFS with a plain text file
	mapFS := fstest.MapFS{
		"hello.txt": &fstest.MapFile{
			Data: []byte("hello world"),
		},
	}

	// Wrap with cachedFS
	cfs := newCachedFS("test-plain", mapFS, cfsread.Options{MaxEntries: 10})
	defer cfs.Close()

	// Open and read the file
	f, err := cfs.Open("hello.txt")
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer f.Close()

	data, err := io.ReadAll(f)
	if err != nil {
		t.Fatalf("ReadAll failed: %v", err)
	}

	expected := "hello world"
	if string(data) != expected {
		t.Errorf("got %q, want %q", string(data), expected)
	}
}

// TestNewCachedFS_LZ4File verifies transparent LZ4 decompression using a
// hermetic in-memory fixture. The compressed payload is generated at test time.
func TestNewCachedFS_LZ4File(t *testing.T) {
	content := []byte("package Carp\n")
	var compressed bytes.Buffer
	writer := lz4frame.NewWriter(&compressed)
	if _, err := writer.Write(content); err != nil {
		t.Fatalf("compress fixture failed: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("finalize compressed fixture failed: %v", err)
	}

	mapFS := fstest.MapFS{
		"Carp.pm": &fstest.MapFile{Data: compressed.Bytes()},
	}

	// Create cachedFS. newCachedFS auto-registers LZ4 support.
	cfs := newCachedFS("test-lz4", mapFS, cfsread.Options{MaxEntries: 10})
	defer cfs.Close()

	// Open and read the LZ4-compressed file
	f, err := cfs.Open("Carp.pm")
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer f.Close()

	data, err := io.ReadAll(f)
	if err != nil {
		t.Fatalf("ReadAll failed: %v", err)
	}

	// Verify decompressed content starts with "package Carp"
	expected := "package Carp"
	if len(data) < len(expected) {
		t.Fatalf("file too short: got %d bytes", len(data))
	}
	if got := string(data[:len(expected)]); got != expected {
		t.Errorf("got %q, want prefix %q", got, expected)
	}
}

// TestNewCachedFS_CacheHit verifies cache-hit and cache-miss semantics.
// It uses testMetrics to observe that the first Open triggers a cache miss and
// the second Open of the same path triggers a cache hit, with data identical
// across both reads.
func TestNewCachedFS_CacheHit(t *testing.T) {
	// Create a simple MapFS with a plain text file
	mapFS := fstest.MapFS{
		"cache.txt": &fstest.MapFile{
			Data: []byte("cached content"),
		},
	}

	// Create testMetrics to track cache behavior
	tm := &testMetrics{}

	// Wrap with cachedFS
	cfs := newCachedFS("test-cache", mapFS, cfsread.Options{
		MaxEntries: 10,
		Metrics:    tm,
	})
	defer cfs.Close()

	// First read - should be a cache miss
	f1, err := cfs.Open("cache.txt")
	if err != nil {
		t.Fatalf("First Open failed: %v", err)
	}
	data1, err := io.ReadAll(f1)
	f1.Close()
	if err != nil {
		t.Fatalf("First ReadAll failed: %v", err)
	}

	// Check metrics after first read
	if tm.misses.Load() != 1 {
		t.Errorf("after first read: misses = %d, want 1", tm.misses.Load())
	}
	if tm.hits.Load() != 0 {
		t.Errorf("after first read: hits = %d, want 0", tm.hits.Load())
	}

	// Second read - should be a cache hit
	f2, err := cfs.Open("cache.txt")
	if err != nil {
		t.Fatalf("Second Open failed: %v", err)
	}
	data2, err := io.ReadAll(f2)
	f2.Close()
	if err != nil {
		t.Fatalf("Second ReadAll failed: %v", err)
	}

	// Check metrics after second read
	if tm.misses.Load() != 1 {
		t.Errorf("after second read: misses = %d, want 1", tm.misses.Load())
	}
	if tm.hits.Load() != 1 {
		t.Errorf("after second read: hits = %d, want 1", tm.hits.Load())
	}

	// Verify both reads returned the same data
	if string(data1) != string(data2) {
		t.Errorf("data mismatch: first=%q, second=%q", data1, data2)
	}
}

// TestNewCachedFS_DirectoryOpen verifies that opening a directory path via
// cachedFS returns an fs.ReadDirFile that correctly lists directory entries.
// Directory opens are delegated directly to the underlying FS, bypassing the
// cfsread cache.
func TestNewCachedFS_DirectoryOpen(t *testing.T) {
	// Create a MapFS with a subdirectory structure
	mapFS := fstest.MapFS{
		"subdir/file.txt": &fstest.MapFile{
			Data: []byte("content"),
		},
	}

	// Wrap with cachedFS
	cfs := newCachedFS("test-dir", mapFS, cfsread.Options{MaxEntries: 10})
	defer cfs.Close()

	// Open the directory
	f, err := cfs.Open("subdir")
	if err != nil {
		t.Fatalf("Open directory failed: %v", err)
	}
	defer f.Close()

	// Assert it's a ReadDirFile
	dirFile, ok := f.(fs.ReadDirFile)
	if !ok {
		t.Fatalf("directory file does not implement fs.ReadDirFile")
	}

	// Read directory entries
	entries, err := dirFile.ReadDir(-1)
	if err != nil {
		t.Fatalf("ReadDir failed: %v", err)
	}

	// Check that file.txt is listed
	found := false
	for _, entry := range entries {
		if entry.Name() == "file.txt" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("file.txt not found in directory listing")
	}
}

// TestNewCachedFS_FileNotFound verifies that opening a non-existent path returns
// an error satisfying errors.Is(err, fs.ErrNotExist).
func TestNewCachedFS_FileNotFound(t *testing.T) {
	// Create an empty MapFS
	mapFS := fstest.MapFS{}

	// Wrap with cachedFS
	cfs := newCachedFS("test-notfound", mapFS, cfsread.Options{MaxEntries: 10})
	defer cfs.Close()

	// Try to open a nonexistent file
	_, err := cfs.Open("nonexistent.txt")
	if err == nil {
		t.Fatal("Open should have failed for nonexistent file")
	}

	// Check that it's an ErrNotExist error
	if !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("got error %v, want fs.ErrNotExist", err)
	}
}

// TestNewCachedFS_Stat verifies that Stat() on a file opened through cachedFS
// returns correct metadata: the base name, the decompressed byte size, and
// IsDir() == false.
func TestNewCachedFS_Stat(t *testing.T) {
	// Create a MapFS with a plain text file
	content := "stat test"
	mode := fs.FileMode(0o640)
	mapFS := fstest.MapFS{
		"stat.txt": &fstest.MapFile{
			Data: []byte(content),
			Mode: mode,
		},
	}

	// Wrap with cachedFS
	cfs := newCachedFS("test-stat", mapFS, cfsread.Options{MaxEntries: 10})
	defer cfs.Close()

	// Open the file
	f, err := cfs.Open("stat.txt")
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer f.Close()

	// Get file info via Stat
	info, err := f.Stat()
	if err != nil {
		t.Fatalf("Stat failed: %v", err)
	}

	// Verify file info
	if info.Name() != "stat.txt" {
		t.Errorf("Name() = %q, want %q", info.Name(), "stat.txt")
	}
	if info.Size() != int64(len(content)) {
		t.Errorf("Size() = %d, want %d", info.Size(), len(content))
	}
	if info.IsDir() {
		t.Error("IsDir() = true, want false")
	}
	if info.Mode() != mode {
		t.Errorf("Mode() = %v, want %v", info.Mode(), mode)
	}
	if info.Sys() != nil {
		t.Errorf("Sys() = %v, want nil", info.Sys())
	}
}

// TestNewCachedFS_ClosePreventsOpen verifies Open fails with fs.ErrClosed
// after the cachedFS is closed, for both file and directory paths.
func TestNewCachedFS_ClosePreventsOpen(t *testing.T) {
	mapFS := fstest.MapFS{
		"file.txt":        &fstest.MapFile{Data: []byte("x")},
		"subdir/file.txt": &fstest.MapFile{Data: []byte("x")},
	}

	cfs := newCachedFS("test-close", mapFS, cfsread.Options{MaxEntries: 10})
	if err := cfs.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	for _, name := range []string{"file.txt", "subdir"} {
		_, err := cfs.Open(name)
		if !errors.Is(err, fs.ErrClosed) {
			t.Errorf("Open(%q) error = %v, want fs.ErrClosed", name, err)
		}
	}
}

// TestCachedFSDoubleClose verifies that calling Close twice is safe and that
// the second call is a no-op (returns nil).
func TestCachedFSDoubleClose(t *testing.T) {
	mapFS := fstest.MapFS{
		"x.txt": &fstest.MapFile{Data: []byte("x")},
	}
	cfs := newCachedFS("test-double-close", mapFS, cfsread.Options{MaxEntries: 10})

	if err := cfs.Close(); err != nil {
		t.Fatalf("first Close failed: %v", err)
	}
	if err := cfs.Close(); err != nil {
		t.Fatalf("second Close failed: %v", err)
	}
}
