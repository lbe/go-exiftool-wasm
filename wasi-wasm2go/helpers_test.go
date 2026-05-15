package wasihost

import (
	"errors"
	"io"
	"io/fs"
	"testing"
	"testing/fstest"
)

// noSeekerFile is a minimal fs.File that does not implement io.Seeker.
// Used by TestFsFileWrapSeekNoSeeker.
type noSeekerFile struct{}

func (*noSeekerFile) Read([]byte) (int, error)   { return 0, io.EOF }
func (*noSeekerFile) Close() error               { return nil }
func (*noSeekerFile) Stat() (fs.FileInfo, error) { return nil, nil }

// TestWASIStubs covers the WASI syscall stubs that unconditionally return a
// fixed error code without accessing guest memory.
func TestWASIStubs(t *testing.T) {
	t.Parallel()

	s := New(nil)

	// No-op stubs returning ESuccess.
	if rc := s.Xfd_fdstat_set_flags(0, 0); rc != wasiESuccess {
		t.Errorf("Xfd_fdstat_set_flags = %d, want ESuccess", rc)
	}
	if rc := s.Xfd_filestat_set_size(0, 0); rc != wasiESuccess {
		t.Errorf("Xfd_filestat_set_size = %d, want ESuccess", rc)
	}
	if rc := s.Xfd_filestat_set_times(0, 0, 0, 0); rc != wasiESuccess {
		t.Errorf("Xfd_filestat_set_times = %d, want ESuccess", rc)
	}
	if rc := s.Xfd_sync(0); rc != wasiESuccess {
		t.Errorf("Xfd_sync = %d, want ESuccess", rc)
	}
	if rc := s.Xpath_filestat_set_times(0, 0, 0, 0, 0, 0, 0); rc != wasiESuccess {
		t.Errorf("Xpath_filestat_set_times = %d, want ESuccess", rc)
	}
	if rc := s.Xcall_host_function(0, 0, 0); rc != 0 {
		t.Errorf("Xcall_host_function = %d, want 0", rc)
	}

	// No-op stubs returning ENoSys (not implemented).
	for name, rc := range map[string]int32{
		"Xproc_raise": s.Xproc_raise(0),
	} {
		if rc != wasiENoSys {
			t.Errorf("%s = %d, want ENoSys", name, rc)
		}
	}

	// Xfd_renumber: out-of-range fd returns EBadf; valid renumber succeeds.
	if rc := s.Xfd_renumber(-1, 0); rc != wasiEBadf {
		t.Errorf("Xfd_renumber(-1, 0) = %d, want EBadf", rc)
	}
	if rc := s.Xfd_renumber(0, 100); rc != wasiEBadf {
		t.Errorf("Xfd_renumber(0, 100) = %d, want EBadf", rc)
	}

	// Xfd_renumber success: fds 0 and 2 are both valid in a 3-fd table.
	if rc := s.Xfd_renumber(0, 2); rc != wasiESuccess {
		t.Errorf("Xfd_renumber(0, 2) = %d, want ESuccess", rc)
	}

	// Path mutation functions: with no mounts configured, all return EROFS.
	for name, rc := range map[string]int32{
		"Xpath_create_directory": s.Xpath_create_directory(0, 0, 0),
		"Xpath_link":             s.Xpath_link(0, 0, 0, 0, 0, 0, 0),
		"Xpath_readlink":         s.Xpath_readlink(0, 0, 0, 0, 0, 0),
		"Xpath_remove_directory": s.Xpath_remove_directory(0, 0, 0),
		"Xpath_symlink":          s.Xpath_symlink(0, 0, 0, 0, 0),
	} {
		if rc != wasiEROFS {
			t.Errorf("%s with no mounts = %d, want EROFS (%d)", name, rc, wasiEROFS)
		}
	}
}

// TestAssertSingleOwner covers the assertOwner invariant paths including the
// panic on cross-goroutine access.
func TestAssertSingleOwner(t *testing.T) {
	t.Parallel()

	t.Run("disabled by default", func(t *testing.T) {
		s := New(nil)
		s.assertSingleOwner()
		s.assertSingleOwner() // no panic
	})

	t.Run("same goroutine ok", func(t *testing.T) {
		s := New(nil, WithOwnerAssertion())
		s.assertSingleOwner() // sets ownerGID
		s.assertSingleOwner() // same goroutine – ok
	})

	t.Run("different goroutine panics", func(t *testing.T) {
		s := New(nil, WithOwnerAssertion())
		s.assertSingleOwner() // set owner to current goroutine

		result := make(chan bool, 1)
		go func() {
			defer func() {
				result <- recover() != nil
			}()
			s.assertSingleOwner() // different goroutine – must panic
		}()
		if panicked := <-result; !panicked {
			t.Error("expected panic on cross-goroutine assertSingleOwner")
		}
	})
}

// TestLogTrace covers the trace-enabled branch of logTrace.
func TestLogTrace(t *testing.T) {
	t.Parallel()
	s := New(nil, WithTracing())
	s.logTrace("test value %d", 42) // should not panic
	s2 := New(nil)
	s2.logTrace("should not print") // early return branch
}

// TestWASIReadBytesNilPaths covers the nil-return branches of readBytes.
func TestWASIReadBytesNilPaths(t *testing.T) {
	t.Parallel()
	s := New(nil)
	if got := s.readBytes(0, 10); got != nil {
		t.Errorf("readBytes(0, 10) = %v, want nil", got)
	}
	if got := s.readBytes(10, 0); got != nil {
		t.Errorf("readBytes(10, 0) = %v, want nil", got)
	}
}

// TestResolvePath covers the mount-resolution logic.
func TestResolvePath(t *testing.T) {
	t.Parallel()

	s := New(nil,
		WithMount("/", fstest.MapFS{}),
		WithMount("/lib", fstest.MapFS{}),
	)

	tests := []struct {
		input   string
		wantRel string
	}{
		{"/lib/5.16.3/Carp.pm", "5.16.3/Carp.pm"},
		{"/lib", ""},
		{"/", ""},
	}

	for _, tt := range tests {
		mount, rel := s.resolvePath(tt.input)
		if mount == nil {
			t.Errorf("resolvePath(%q): mount is nil", tt.input)
			continue
		}
		if rel != tt.wantRel {
			t.Errorf("resolvePath(%q): rel = %q, want %q", tt.input, rel, tt.wantRel)
		}
	}

	// Path that matches no mount → nil.
	s2 := New(nil, WithMount("/lib", fstest.MapFS{}))
	m, _ := s2.resolvePath("/usr/bin")
	if m != nil {
		t.Errorf("expected nil mount for unmatched path, got non-nil")
	}
}

// TestDirEntriesFile covers the DirEntriesFile adapter used by Xfd_readdir.
func TestDirEntriesFile(t *testing.T) {
	t.Parallel()

	mapFS := fstest.MapFS{
		"alpha.txt": &fstest.MapFile{},
		"beta.txt":  &fstest.MapFile{},
	}
	allEntries, err := fs.ReadDir(mapFS, ".")
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}

	d := &DirEntriesFile{Entries: allEntries}

	// Read always returns EOF.
	n, readErr := d.Read(make([]byte, 4))
	if n != 0 || !errors.Is(readErr, io.EOF) {
		t.Errorf("Read = (%d, %v), want (0, io.EOF)", n, readErr)
	}

	// Close is a no-op.
	if closeErr := d.Close(); closeErr != nil {
		t.Errorf("Close = %v, want nil", closeErr)
	}

	// Stat returns wasiDirInfo.
	info, statErr := d.Stat()
	if statErr != nil {
		t.Fatalf("Stat = %v", statErr)
	}
	if !info.IsDir() {
		t.Errorf("Stat.IsDir = false, want true")
	}

	// ReadDir(1) returns one entry at a time.
	got, rdErr := d.ReadDir(1)
	if rdErr != nil || len(got) != 1 {
		t.Errorf("ReadDir(1) = (%v, %v), want (1 entry, nil)", got, rdErr)
	}

	// ReadDir(-1) returns all remaining.
	rest, rdErr := d.ReadDir(-1)
	if rdErr != nil || len(rest) != len(allEntries)-1 {
		t.Errorf("ReadDir(-1) = (%v, %v), want (%d entries, nil)", rest, rdErr, len(allEntries)-1)
	}

	// ReadDir after exhaustion returns io.EOF.
	_, rdErr = d.ReadDir(1)
	if !errors.Is(rdErr, io.EOF) {
		t.Errorf("ReadDir after exhaustion = %v, want io.EOF", rdErr)
	}
}

// TestFsFileWrapSeekNoSeeker covers the error branch in FSFileWrap.Seek when
// the underlying fs.File does not implement io.Seeker.
func TestFsFileWrapSeekNoSeeker(t *testing.T) {
	t.Parallel()

	f := &FSFileWrap{File: &noSeekerFile{}}
	_, err := f.Seek(0, 0)
	if err == nil {
		t.Fatal("expected Seek error, got nil")
	}
	if err.Error() != "seek not supported" {
		t.Errorf("Seek error = %q, want %q", err.Error(), "seek not supported")
	}
}
