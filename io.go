package exiftool

import (
	"bytes"
	"io"
)

// guestIO is the guest's stdio backend. initWASIState connects these methods to
// the module's stdin, stdout and stderr. directIO serves one-shot commands with
// in-memory buffers, and serverIO serves a Server with pipes.
type guestIO interface {
	ReadStdin(buf []byte) (int, error)
	WriteStdout(buf []byte) (int, error)
	WriteStderr(buf []byte) (int, error)
	CloseStdin()
	CloseAll()
}

// directIO reads stdin from an io.Reader and keeps stdout and stderr in memory.
// Command and CommandContext use it.
type directIO struct {
	StdinR  io.Reader
	StdoutB *bytes.Buffer
	StderrB *bytes.Buffer
}

// newDirectIO returns a directIO that reads from stdin. A nil stdin reads as empty.
func newDirectIO(stdin io.Reader) *directIO {
	if stdin == nil {
		stdin = bytes.NewReader(nil)
	}
	return &directIO{
		StdinR:  stdin,
		StdoutB: bytes.NewBuffer(nil),
		StderrB: bytes.NewBuffer(nil),
	}
}

func (d *directIO) ReadStdin(buf []byte) (int, error)   { return d.StdinR.Read(buf) }
func (d *directIO) WriteStdout(buf []byte) (int, error) { return d.StdoutB.Write(buf) }
func (d *directIO) WriteStderr(buf []byte) (int, error) { return d.StderrB.Write(buf) }

// CloseStdin does nothing, because directIO does not own the reader.
func (d *directIO) CloseStdin() {}

// CloseAll does nothing, because the buffers need no cleanup.
func (d *directIO) CloseAll() {}

// guestStdoutOnExit returns a copy of the stdout a directIO captured, or nil for
// any other backend. Callers use it after the guest exits with a non-zero status.
func guestStdoutOnExit(gio guestIO) []byte {
	dio, ok := gio.(*directIO)
	if !ok {
		return nil
	}
	return append([]byte(nil), dio.StdoutB.Bytes()...)
}
