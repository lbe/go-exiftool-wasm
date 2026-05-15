package wasihost

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFilestatMutations(t *testing.T) {
	// Use a fixed past time far enough from "now" to distinguish clearly
	// (any real implementation would set mtime to this; stub won't)
	targetMtim := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	targetMtimNs := targetMtim.UnixNano()

	t.Run("Xfd_filestat_set_size truncates osFile to 5 bytes", func(t *testing.T) {
		s, _ := newTestState()
		filePath := setupOsFileFd(t, s, 5, []byte("ABCDEFGHIJ"))

		errno := s.Xfd_filestat_set_size(5, 5)
		if errno != wasiESuccess {
			t.Fatalf("filestat_set_size returned %d, want ESUCCESS", errno)
		}
		data, err := os.ReadFile(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if len(data) != 5 {
			t.Errorf("file size = %d, want 5", len(data))
		}
		fi, err := os.Stat(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Size() != 5 {
			t.Errorf("os.Stat size = %d, want 5", fi.Size())
		}
	})

	t.Run("Xfd_filestat_set_size on FSFileWrap returns ESUCCESS with no mutation", func(t *testing.T) {
		s, _ := newTestState()
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "ro.txt"), []byte("HELLO"), 0644); err != nil {
			t.Fatal(err)
		}
		fsys := os.DirFS(dir)
		f, err := fsys.Open("ro.txt")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { f.Close() })
		for len(s.fds) <= 5 {
			s.fds = append(s.fds, fdEntry{})
		}
		s.fds[5] = fdEntry{fdType: 4, file: &FSFileWrap{File: f}}

		errno := s.Xfd_filestat_set_size(5, 99)
		if errno != wasiESuccess {
			t.Errorf("got errno %d, want ESUCCESS", errno)
		}
		// Verify no mutation
		data, err := os.ReadFile(filepath.Join(dir, "ro.txt"))
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != "HELLO" {
			t.Errorf("file was mutated: got %q, want %q", data, "HELLO")
		}
	})

	t.Run("Xfd_filestat_set_times fstFlags=2 updates mtime on osFile", func(t *testing.T) {
		s, _ := newTestState()
		filePath := setupOsFileFd(t, s, 5, []byte("data"))

		errno := s.Xfd_filestat_set_times(5, 0, targetMtimNs, 2)
		if errno != wasiESuccess {
			t.Fatalf("filestat_set_times returned %d, want ESUCCESS", errno)
		}
		fi, err := os.Stat(filePath)
		if err != nil {
			t.Fatal(err)
		}
		diff := fi.ModTime().Sub(targetMtim)
		if diff < 0 {
			diff = -diff
		}
		if diff > 2*time.Second {
			t.Errorf("mtime = %v, want within 2s of %v (diff=%v)", fi.ModTime(), targetMtim, diff)
		}
	})

	t.Run("Xfd_filestat_set_times fstFlags=0 does not mutate mtime", func(t *testing.T) {
		s, _ := newTestState()
		filePath := setupOsFileFd(t, s, 5, []byte("data"))
		fi0, err := os.Stat(filePath)
		if err != nil {
			t.Fatal(err)
		}
		before := fi0.ModTime()

		errno := s.Xfd_filestat_set_times(5, 0, targetMtimNs, 0)
		if errno != wasiESuccess {
			t.Fatalf("filestat_set_times returned %d, want ESUCCESS", errno)
		}
		fi1, err := os.Stat(filePath)
		if err != nil {
			t.Fatal(err)
		}
		// mtime should be unchanged
		if !fi1.ModTime().Equal(before) {
			t.Errorf("mtime changed unexpectedly: before=%v after=%v", before, fi1.ModTime())
		}
	})

	t.Run("Xpath_filestat_set_times fstFlags=2 updates mtime by path", func(t *testing.T) {
		s, buf := newTestState()
		hostDir := setupWritableMount(t, s, buf)
		fname := "testfile.txt"
		if err := os.WriteFile(filepath.Join(hostDir, fname), []byte("content"), 0644); err != nil {
			t.Fatal(err)
		}
		pathOff, pathLen := writePath(buf, 500, fname)

		errno := s.Xpath_filestat_set_times(3, 0, pathOff, pathLen, 0, targetMtimNs, 2)
		if errno != wasiESuccess {
			t.Fatalf("xpath_filestat_set_times returned %d, want ESUCCESS", errno)
		}
		fi, err := os.Stat(filepath.Join(hostDir, fname))
		if err != nil {
			t.Fatal(err)
		}
		diff := fi.ModTime().Sub(targetMtim)
		if diff < 0 {
			diff = -diff
		}
		if diff > 2*time.Second {
			t.Errorf("mtime = %v, want within 2s of %v (diff=%v)", fi.ModTime(), targetMtim, diff)
		}
	})

	t.Run("Xpath_filestat_set_times fstFlags=0 is no-op", func(t *testing.T) {
		s, buf := newTestState()
		hostDir := setupWritableMount(t, s, buf)
		fname := "noop.txt"
		if err := os.WriteFile(filepath.Join(hostDir, fname), []byte("x"), 0644); err != nil {
			t.Fatal(err)
		}
		fi0, err := os.Stat(filepath.Join(hostDir, fname))
		if err != nil {
			t.Fatal(err)
		}
		before := fi0.ModTime()
		pathOff, pathLen := writePath(buf, 500, fname)

		errno := s.Xpath_filestat_set_times(3, 0, pathOff, pathLen, 0, targetMtimNs, 0)
		if errno != wasiESuccess {
			t.Fatalf("Xpath_filestat_set_times fstFlags=0 = %d, want ESUCCESS", errno)
		}
		fi1, err := os.Stat(filepath.Join(hostDir, fname))
		if err != nil {
			t.Fatal(err)
		}
		if !fi1.ModTime().Equal(before) {
			t.Errorf("mtime changed: before=%v after=%v", before, fi1.ModTime())
		}
	})

	t.Run("applyMtim error on nonexistent path", func(t *testing.T) {
		errno := applyMtim("/nonexistent/path/deleted.txt", targetMtimNs)
		if errno == wasiESuccess {
			t.Error("applyMtim on missing path returned ESUCCESS, want error")
		}
	})
}
