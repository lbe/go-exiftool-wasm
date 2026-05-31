package exiftool

import (
	"bytes"
	"io"
)

// guestIO abstracts guest stdio for the wasm2go-wasi-host layer. initWASIState
// wires these methods into wasihost.ModuleConfig via WithStdin, WithStdout, and
// WithStderr so single-shot Command and Server stay_open modes can use different
// backends (in-memory buffers vs os.Pipe).
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

// CloseStdin is a no-op; directIO does not own the stdin reader.
func (d *directIO) CloseStdin() {}

// CloseAll is a no-op; directIO buffers are in-memory and need no cleanup.
func (d *directIO) CloseAll() {}
