package exiftool

import (
	"errors"
	"io"
	"io/fs"
	"strings"
	"testing"
	"testing/fstest"

	wasihost "github.com/lbe/wasi-wasm2go"
)

type errFS struct{ err error }

func (e errFS) Open(name string) (fs.File, error) {
	return nil, &fs.PathError{Op: "open", Path: name, Err: e.err}
}

type stubWriteCloser struct {
	closeErr error
	closed   bool
}

func (s *stubWriteCloser) Write(p []byte) (int, error) {
	return len(p), nil
}

func (s *stubWriteCloser) Close() error {
	s.closed = true
	return s.closeErr
}

type errCloser struct {
	err    error
	closed bool
}

func (e *errCloser) Close() error {
	e.closed = true
	return e.err
}

func TestOverlayFSOpen(t *testing.T) {
	t.Parallel()

	t.Run("found in later layer", func(t *testing.T) {
		o := &overlayFS{layers: []fs.FS{
			fstest.MapFS{},
			fstest.MapFS{"a.txt": &fstest.MapFile{Data: []byte("ok")}},
		}}

		f, err := o.Open("a.txt")
		if err != nil {
			t.Fatalf("Open failed: %v", err)
		}
		defer f.Close()

		b, err := io.ReadAll(f)
		if err != nil {
			t.Fatalf("ReadAll failed: %v", err)
		}
		if got, want := string(b), "ok"; got != want {
			t.Errorf("content = %q, want %q", got, want)
		}
	})

	t.Run("non-not-exist error is propagated", func(t *testing.T) {
		wantErr := fs.ErrPermission
		o := &overlayFS{layers: []fs.FS{errFS{err: wantErr}, fstest.MapFS{}}}

		_, err := o.Open("blocked.txt")
		if err == nil {
			t.Fatal("expected error")
		}
		if !errors.Is(err, wantErr) {
			t.Fatalf("error = %v, want to contain %v", err, wantErr)
		}
	})

	t.Run("all not found returns fs.ErrNotExist", func(t *testing.T) {
		o := &overlayFS{layers: []fs.FS{fstest.MapFS{}, fstest.MapFS{}}}

		_, err := o.Open("missing.txt")
		if !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("error = %v, want fs.ErrNotExist", err)
		}
	})
}

func TestDevNullFS(t *testing.T) {
	t.Parallel()

	t.Run("root directory supports ReadDir once", func(t *testing.T) {
		f, err := (devNullFS{}).Open(".")
		if err != nil {
			t.Fatalf("Open root failed: %v", err)
		}
		defer f.Close()

		info, err := f.Stat()
		if err != nil {
			t.Fatalf("Stat failed: %v", err)
		}
		if !info.IsDir() {
			t.Fatalf("IsDir = false, want true")
		}
		if info.Name() != "." {
			t.Fatalf("Name = %q, want .", info.Name())
		}
		if info.Mode()&fs.ModeDir == 0 {
			t.Fatalf("Mode = %v, want directory mode", info.Mode())
		}
		if info.Size() != 0 {
			t.Fatalf("Size = %d, want 0", info.Size())
		}
		if !info.ModTime().IsZero() {
			t.Fatalf("ModTime = %v, want zero", info.ModTime())
		}
		if info.Sys() != nil {
			t.Fatalf("Sys = %v, want nil", info.Sys())
		}

		// Read on a directory should return 0, io.EOF.
		buf := make([]byte, 4)
		n, readErr := f.Read(buf)
		if n != 0 || !errors.Is(readErr, io.EOF) {
			t.Fatalf("Read on dir = (%d, %v), want (0, io.EOF)", n, readErr)
		}

		rdf, ok := f.(fs.ReadDirFile)
		if !ok {
			t.Fatal("root does not implement fs.ReadDirFile")
		}

		entries, err := rdf.ReadDir(-1)
		if err != nil {
			t.Fatalf("ReadDir first call failed: %v", err)
		}
		if len(entries) != 1 || entries[0].Name() != "null" {
			t.Fatalf("entries = %v, want one entry named null", entries)
		}

		entries, err = rdf.ReadDir(-1)
		if !errors.Is(err, io.EOF) {
			t.Fatalf("ReadDir second call err = %v, want io.EOF", err)
		}
		if entries != nil {
			t.Fatalf("entries on second ReadDir = %v, want nil", entries)
		}
	})

	t.Run("null file always reads EOF", func(t *testing.T) {
		f, err := (devNullFS{}).Open("null")
		if err != nil {
			t.Fatalf("Open null failed: %v", err)
		}
		defer f.Close()

		info, err := f.Stat()
		if err != nil {
			t.Fatalf("Stat failed: %v", err)
		}
		if info.Name() != "null" {
			t.Fatalf("Name = %q, want null", info.Name())
		}
		if info.IsDir() {
			t.Fatal("IsDir = true, want false")
		}
		if info.Mode() != 0 {
			t.Fatalf("Mode = %v, want 0", info.Mode())
		}
		if info.Size() != 0 {
			t.Fatalf("Size = %d, want 0", info.Size())
		}
		if !info.ModTime().IsZero() {
			t.Fatalf("ModTime = %v, want zero", info.ModTime())
		}
		if info.Sys() != nil {
			t.Fatalf("Sys = %v, want nil", info.Sys())
		}

		buf := make([]byte, 8)
		n, err := f.Read(buf)
		if n != 0 || !errors.Is(err, io.EOF) {
			t.Fatalf("Read = (%d, %v), want (0, io.EOF)", n, err)
		}
	})

	t.Run("missing path", func(t *testing.T) {
		_, err := (devNullFS{}).Open("missing")
		if !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("error = %v, want fs.ErrNotExist", err)
		}
	})
}

func TestDirectIOBasics(t *testing.T) {
	t.Parallel()

	d := newDirectIO(strings.NewReader("abc"))

	buf := make([]byte, 3)
	n, err := d.ReadStdin(buf)
	if err != nil {
		t.Fatalf("ReadStdin failed: %v", err)
	}
	if n != 3 || string(buf) != "abc" {
		t.Fatalf("ReadStdin = (%d, %q), want (3, abc)", n, string(buf))
	}

	if _, err := d.WriteStdout([]byte("out")); err != nil {
		t.Fatalf("WriteStdout failed: %v", err)
	}
	if _, err := d.WriteStderr([]byte("err")); err != nil {
		t.Fatalf("WriteStderr failed: %v", err)
	}

	if got := d.StdoutB.String(); got != "out" {
		t.Fatalf("StdoutB = %q, want out", got)
	}
	if got := d.StderrB.String(); got != "err" {
		t.Fatalf("StderrB = %q, want err", got)
	}

	// No-op methods should be safe and side-effect free.
	d.CloseStdin()
	d.CloseAll()
}

func TestProcessStubKill(t *testing.T) {
	t.Parallel()

	t.Run("nil stdin writer", func(t *testing.T) {
		p := &processStub{server: &Server{}}
		if err := p.Kill(); err != nil {
			t.Fatalf("Kill failed: %v", err)
		}
	})

	t.Run("closes writer and returns close error", func(t *testing.T) {
		wantErr := errors.New("close failure")
		wc := &stubWriteCloser{closeErr: wantErr}
		p := &processStub{server: &Server{stdinW: wc}}

		err := p.Kill()
		if !wc.closed {
			t.Fatal("expected writer to be closed")
		}
		if !errors.Is(err, wantErr) {
			t.Fatalf("Kill error = %v, want %v", err, wantErr)
		}
	})

	if err := (&processStub{}).Release(); err != nil {
		t.Fatalf("Release failed: %v", err)
	}
}

func TestServerIOHelpers(t *testing.T) {
	t.Parallel()

	s, err := newServerIO()
	if err != nil {
		t.Fatalf("newServerIO failed: %v", err)
	}
	defer func() {
		_ = s.stdinW.Close()
		_ = s.stdoutR.Close()
	}()

	if n, err := s.WriteStderr([]byte("abcdef")); err != nil || n != 6 {
		t.Fatalf("WriteStderr = (%d, %v), want (6, nil)", n, err)
	}
	if got := string(s.DrainStderr(2)); got != "cdef" {
		t.Fatalf("DrainStderr(2) = %q, want cdef", got)
	}
	if got := s.DrainStderr(999); got != nil {
		t.Fatalf("DrainStderr(999) = %v, want nil", got)
	}

	if n, err := s.stdinW.Write([]byte("xy")); err != nil || n != 2 {
		t.Fatalf("stdin write = (%d, %v), want (2, nil)", n, err)
	}
	buf := make([]byte, 2)
	if n, err := s.ReadStdin(buf); err != nil || n != 2 || string(buf) != "xy" {
		t.Fatalf("ReadStdin = (%d, %v, %q), want (2, nil, xy)", n, err, string(buf))
	}

	// CloseStdin closes the read end of stdin.
	s2, err2 := newServerIO()
	if err2 != nil {
		t.Fatalf("newServerIO #2 failed: %v", err2)
	}
	defer s2.stdoutR.Close()
	defer s2.stdinW.Close()
	s2.CloseStdin()

	s.CloseAll()
	if _, err := s.WriteStdout([]byte("z")); err == nil {
		t.Fatal("expected WriteStdout error after CloseAll")
	}
}

func TestCloseAll(t *testing.T) {
	t.Parallel()

	t.Run("joins errors", func(t *testing.T) {
		errA := errors.New("a")
		errB := errors.New("b")
		a := &errCloser{err: errA}
		b := &errCloser{err: errB}

		err := closeAll(a, b)
		if !a.closed || !b.closed {
			t.Fatal("expected both closers to be closed")
		}
		if !errors.Is(err, errA) || !errors.Is(err, errB) {
			t.Fatalf("joined error = %v, want both a and b", err)
		}
	})

	t.Run("all nil errors", func(t *testing.T) {
		a := &errCloser{}
		b := &errCloser{}

		err := closeAll(a, b)
		if err != nil {
			t.Fatalf("closeAll error = %v, want nil", err)
		}
	})
}

func TestExitPanicError(t *testing.T) {
	t.Parallel()
	if got, want := (exitPanic{code: 0}).Error(), "proc_exit"; got != want {
		t.Errorf("Error() = %q, want %q", got, want)
	}
	if got, want := (exitPanic{code: 1}).Error(), "proc_exit"; got != want {
		t.Errorf("Error() = %q, want %q", got, want)
	}
}

// TestWASIStubs covers the WASI syscall stubs that unconditionally return a
// fixed error code without accessing guest memory.
func TestWASIStubs(t *testing.T) {
	t.Parallel()

	ws := &wasiState{}
	ws.State = wasihost.New(nil)

	// No-op stubs returning ESuccess.
	if rc := ws.Xfd_fdstat_set_flags(0, 0); rc != int32(wasihost.WasiESuccess) {
		t.Errorf("Xfd_fdstat_set_flags = %d, want ESuccess", rc)
	}
	if rc := ws.Xfd_filestat_set_size(0, 0); rc != int32(wasihost.WasiESuccess) {
		t.Errorf("Xfd_filestat_set_size = %d, want ESuccess", rc)
	}
	if rc := ws.Xfd_filestat_set_times(0, 0, 0, 0); rc != int32(wasihost.WasiESuccess) {
		t.Errorf("Xfd_filestat_set_times = %d, want ESuccess", rc)
	}
	if rc := ws.Xfd_sync(0); rc != int32(wasihost.WasiESuccess) {
		t.Errorf("Xfd_sync = %d, want ESuccess", rc)
	}
	if rc := ws.Xpath_filestat_set_times(0, 0, 0, 0, 0, 0, 0); rc != int32(wasihost.WasiESuccess) {
		t.Errorf("Xpath_filestat_set_times = %d, want ESuccess", rc)
	}
	if rc := ws.Xcall_host_function(0, 0, 0); rc != 0 {
		t.Errorf("Xcall_host_function = %d, want 0", rc)
	}

	// No-op stubs returning ENoSys (not implemented).
	for name, rc := range map[string]int32{
		"Xproc_raise": ws.Xproc_raise(0),
	} {
		if rc != int32(wasihost.WasiENoSys) {
			t.Errorf("%s = %d, want ENoSys", name, rc)
		}
	}

	// Xfd_renumber: out-of-range fd returns EBadf; valid renumber succeeds.
	if rc := ws.Xfd_renumber(-1, 0); rc != int32(wasihost.WasiEBadf) {
		t.Errorf("Xfd_renumber(-1, 0) = %d, want EBadf", rc)
	}
	if rc := ws.Xfd_renumber(0, 100); rc != int32(wasihost.WasiEBadf) {
		t.Errorf("Xfd_renumber(0, 100) = %d, want EBadf", rc)
	}

	// Xfd_renumber success: fds 0 and 2 are both valid in a 3-fd table.
	if rc := ws.Xfd_renumber(0, 2); rc != int32(wasihost.WasiESuccess) {
		t.Errorf("Xfd_renumber(0, 2) = %d, want ESuccess", rc)
	}

	// Path mutation functions: with no mounts configured, all return EROFS.
	for name, rc := range map[string]int32{
		"Xpath_create_directory": ws.Xpath_create_directory(0, 0, 0),
		"Xpath_link":             ws.Xpath_link(0, 0, 0, 0, 0, 0, 0),
		"Xpath_readlink":         ws.Xpath_readlink(0, 0, 0, 0, 0, 0),
		"Xpath_remove_directory": ws.Xpath_remove_directory(0, 0, 0),
		"Xpath_symlink":          ws.Xpath_symlink(0, 0, 0, 0, 0),
	} {
		if rc != int32(wasihost.WasiEROFS) {
			t.Errorf("%s with no mounts = %d, want EROFS (%d)", name, rc, wasihost.WasiEROFS)
		}
	}
}

// TestAssertSingleOwner covers the assertOwner invariant paths including the
// panic on cross-goroutine access.
func TestAssertSingleOwner(t *testing.T) {
	t.Parallel()

	t.Run("disabled by default", func(t *testing.T) {
		ws := &wasiState{State: wasihost.New(nil)} // assertOwner false
		ws.AssertSingleOwner()
		ws.AssertSingleOwner() // no panic
	})

	t.Run("same goroutine ok", func(t *testing.T) {
		ws := &wasiState{State: wasihost.New(nil, wasihost.WithOwnerAssertion())}
		ws.AssertSingleOwner() // sets ownerGID
		ws.AssertSingleOwner() // same goroutine – ok
	})

	t.Run("different goroutine panics", func(t *testing.T) {
		ws := &wasiState{State: wasihost.New(nil, wasihost.WithOwnerAssertion())}
		ws.AssertSingleOwner() // set owner to current goroutine

		result := make(chan bool, 1)
		go func() {
			defer func() {
				result <- recover() != nil
			}()
			ws.AssertSingleOwner() // different goroutine – must panic
		}()
		if panicked := <-result; !panicked {
			t.Error("expected panic on cross-goroutine assertSingleOwner")
		}
	})
}

// TestLogTrace covers the trace-enabled branch of logTrace.
func TestLogTrace(t *testing.T) {
	t.Parallel()
	ws := &wasiState{State: wasihost.New(nil, wasihost.WithTracing())}
	ws.LogTrace("test value %d", 42) // should not panic
	ws2 := &wasiState{State: wasihost.New(nil)}
	ws2.LogTrace("should not print") // early return branch
}

// TestWASIReadBytesNilPaths covers the nil-return branches of readBytes.
func TestWASIReadBytesNilPaths(t *testing.T) {
	t.Parallel()
	ws := &wasiState{State: wasihost.New(nil)}
	if got := ws.ReadBytes(0, 10); got != nil {
		t.Errorf("readBytes(0, 10) = %v, want nil", got)
	}
	if got := ws.ReadBytes(10, 0); got != nil {
		t.Errorf("readBytes(10, 0) = %v, want nil", got)
	}
}

// TestResolvePath covers the mount-resolution logic.
func TestResolvePath(t *testing.T) {
	t.Parallel()

	ws := &wasiState{State: wasihost.New(nil,
		wasihost.WithMount("/", fstest.MapFS{}),
		wasihost.WithMount("/lib", fstest.MapFS{}),
	)}

	tests := []struct {
		input   string
		wantRel string
		wantIdx int // index in mounts slice
	}{
		{"/lib/5.16.3/Carp.pm", "5.16.3/Carp.pm", 1},
		{"/lib", "", 1},
		{"/", "", 0},
	}

	for _, tt := range tests {
		mount, rel := ws.ResolvePath(tt.input)
		if mount == nil {
			t.Errorf("resolvePath(%q): mount is nil", tt.input)
			continue
		}
		if rel != tt.wantRel {
			t.Errorf("resolvePath(%q): rel = %q, want %q", tt.input, rel, tt.wantRel)
		}
	}

	// Path that matches no mount → nil.
	ws2 := &wasiState{State: wasihost.New(nil, wasihost.WithMount("/lib", fstest.MapFS{}))}
	m, _ := ws2.ResolvePath("/usr/bin")
	if m != nil {
		t.Errorf("expected nil mount for unmatched path, got non-nil")
	}
}


// TestDirEntriesFile covers the dirEntriesFile adapter used by Xfd_readdir.
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

	d := &wasihost.DirEntriesFile{Entries: allEntries}

	// Read always returns EOF.
	n, readErr := d.Read(make([]byte, 4))
	if n != 0 || !errors.Is(readErr, io.EOF) {
		t.Errorf("Read = (%d, %v), want (0, io.EOF)", n, readErr)
	}

	// Close is a no-op.
	if closeErr := d.Close(); closeErr != nil {
		t.Errorf("Close = %v, want nil", closeErr)
	}

	// Stat returns devNullDirInfo.
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

// TestFsFileWrapSeekNoSeeker covers the error branch in fsFileWrap.Seek when
// the underlying fs.File does not implement io.Seeker.
func TestFsFileWrapSeekNoSeeker(t *testing.T) {
	t.Parallel()

	f := &wasihost.FSFileWrap{File: &devNullFile{}}
	_, err := f.Seek(0, 0)
	if err == nil {
		t.Fatal("expected Seek error, got nil")
	}
	if err.Error() != "seek not supported" {
		t.Errorf("Seek error = %q, want %q", err.Error(), "seek not supported")
	}
}
