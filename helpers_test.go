package exiftool

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"strings"
	"testing"
)

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

func TestJSONRecordsExitCode(t *testing.T) {
	t.Parallel()

	out, _ := json.Marshal([]map[string]any{
		{"FileName": "x.jpg", "Error": "File is empty"},
	})
	if got := jsonRecordsExitCode(out, []string{"-json", "x.jpg"}); got != 1 {
		t.Errorf("jsonRecordsExitCode = %d, want 1", got)
	}
	if got := jsonRecordsExitCode(out, []string{"-ver"}); got != 0 {
		t.Errorf("without -json: got %d, want 0", got)
	}
}

func TestUsesEvalModulePath(t *testing.T) {
	t.Parallel()

	if !usesEvalModulePath(strings.NewReader("-ver\n"), []string{"-@", "-"}) {
		t.Error("expected true for -@ - with stdin")
	}
	if usesEvalModulePath(nil, []string{"-json", "file.jpg"}) {
		t.Error("expected false for normal args")
	}
}
