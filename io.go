package exiftool

import (
	"bytes"
	"io"
)

// GuestIO abstracts stdin, stdout, and stderr for the Perl guest. The WASI
// host layer calls these methods instead of using real file descriptors so
// that different execution modes (single-shot vs. server) can plug in their
// own I/O back-ends.
type GuestIO interface {
	ReadStdin(buf []byte) (int, error)
	WriteStdout(buf []byte) (int, error)
	WriteStderr(buf []byte) (int, error)
	CloseStdin()
	CloseAll()
}

// DirectIO is a GuestIO implementation that buffers stdout and stderr in
// memory and reads stdin from an arbitrary io.Reader. It is used by the
// single-shot [Command], [Run], and [RunDebug] entry points.
type DirectIO struct {
	StdinR  io.Reader
	StdoutB *bytes.Buffer
	StderrB *bytes.Buffer
}

// NewDirectIO returns a DirectIO that reads from stdin. If stdin is nil, reads
// immediately return 0, io.EOF.
func NewDirectIO(stdin io.Reader) *DirectIO {
	if stdin == nil {
		stdin = bytes.NewReader(nil)
	}
	return &DirectIO{
		StdinR:  stdin,
		StdoutB: bytes.NewBuffer(nil),
		StderrB: bytes.NewBuffer(nil),
	}
}

func (d *DirectIO) ReadStdin(buf []byte) (int, error)   { return d.StdinR.Read(buf) }
func (d *DirectIO) WriteStdout(buf []byte) (int, error) { return d.StdoutB.Write(buf) }
func (d *DirectIO) WriteStderr(buf []byte) (int, error) { return d.StderrB.Write(buf) }
func (d *DirectIO) CloseStdin()                         {}
func (d *DirectIO) CloseAll()                           {}
