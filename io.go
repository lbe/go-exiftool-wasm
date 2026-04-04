package exiftool

import (
	"bytes"
	"io"
	"sync"
)

type GuestIO interface {
	ReadStdin(buf []byte) (int, error)
	WriteStdout(buf []byte) (int, error)
	WriteStderr(buf []byte) (int, error)
	CloseStdin()
	CloseAll()
}

type DirectIO struct {
	StdinR  io.Reader
	StdoutB *bytes.Buffer
	StderrB *bytes.Buffer
}

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

type ChannelIO struct {
	stdinCh   chan []byte
	stdoutCh  chan []byte
	stderrCh  chan []byte
	stdinBuf  bytes.Buffer
	stdinMu   sync.Mutex
	stdinDone chan struct{}
}

func NewChannelIO() *ChannelIO {
	return &ChannelIO{
		stdinCh:   make(chan []byte, 64),
		stdoutCh:  make(chan []byte, 64),
		stderrCh:  make(chan []byte, 64),
		stdinDone: make(chan struct{}),
	}
}

func (c *ChannelIO) ReadStdin(buf []byte) (int, error) {
	c.stdinMu.Lock()
	defer c.stdinMu.Unlock()

	if c.stdinBuf.Len() > 0 {
		return c.stdinBuf.Read(buf)
	}

	select {
	case data, ok := <-c.stdinCh:
		if !ok {
			return 0, io.EOF
		}
		c.stdinBuf.Write(data)
		return c.stdinBuf.Read(buf)
	case <-c.stdinDone:
		return 0, io.EOF
	}
}

func (c *ChannelIO) WriteStdout(buf []byte) (int, error) {
	c.stdoutCh <- buf
	return len(buf), nil
}

func (c *ChannelIO) WriteStderr(buf []byte) (int, error) {
	c.stderrCh <- buf
	return len(buf), nil
}

func (c *ChannelIO) WriteStdin(data []byte) {
	c.stdinCh <- data
}

func (c *ChannelIO) CloseStdin() {
	close(c.stdinDone)
}

func (c *ChannelIO) CloseAll() {
	close(c.stdinDone)
	close(c.stdoutCh)
	close(c.stderrCh)
}
