package exiftool

import (
	"bytes"
	"io"
)

// guestIO abstracts stdin, stdout, and stderr for the Perl guest. The WASI
// host layer calls these methods instead of using real file descriptors so
// that different execution modes (single-shot vs. server stay_open) can plug
// in their own I/O backends.
type guestIO interface {
	ReadStdin(buf []byte) (int, error)
	WriteStdout(buf []byte) (int, error)
	WriteStderr(buf []byte) (int, error)
	CloseStdin()
	CloseAll()
}

// directIO buffers stdout and stderr in memory and reads stdin from an arbitrary
// io.Reader. Used by single-shot Command/CommandContext.
type directIO struct {
	StdinR  io.Reader
	StdoutB *bytes.Buffer
	StderrB *bytes.Buffer
}

// newDirectIO returns a directIO that reads from stdin. If stdin is nil,
// reads immediately return (0, io.EOF).
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
func (d *directIO) CloseStdin()                         {}
func (d *directIO) CloseAll()                           {}
