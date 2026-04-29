package exiftool

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"sync"

	wasm2go "github.com/lbe/go-exiftool-wasm/zeroperl"
)

// boundary is the unique token used in the ExifTool -stay_open protocol to
// delimit command responses. It appears in -echo4 "{ready<boundary>}" output
// and -execute<boundary> input framing.
const boundary = "1854673209"

// processStub adapts Server to the process-like interface expected by the
// original go-exiftool API. Killing the stub closes the server's stdin pipe.
type processStub struct {
	server *Server
}

func (p *processStub) Kill() error {
	if p.server.stdinW != nil {
		return p.server.stdinW.Close()
	}
	return nil
}

func (p *processStub) Release() error {
	return nil
}

// cmdStub is a minimal shim satisfying the cmd-like interface required by the
// legacy go-exiftool compatibility layer.
type cmdStub struct {
	Process *processStub
}

// Server is a persistent, in-process ExifTool instance using the -stay_open
// protocol. It amortises the one-time Perl/ExifTool startup cost across many
// [Server.Command] calls. Concurrency safety: Command calls are serialised
// internally; lifecycle methods (Close, Shutdown) may be called concurrently.
//
// Use [NewServer] to create an instance and call [Server.Shutdown] or
// [Server.Close] when finished to release resources.
type Server struct {
	srvMtx     sync.Mutex
	cmdMtx     sync.Mutex
	rootFS     fs.FS
	args       []string
	done       bool
	cmd        *cmdStub
	restartErr error

	mod      *wasm2go.Module
	wasi     *wasiState
	stdinW   io.WriteCloser
	stdoutR  io.Closer
	stdout   *bufio.Scanner
	sio      *serverIO
	evalDone chan struct{}
	evalErr  error
}

// serverIO is the [GuestIO] adapter for Server mode. It uses real [os.Pipe]
// pairs for stdin and stdout so that the long-running zeroperl eval goroutine
// can stream data to/from [Server.Command] callers. stderr is captured
// in-memory and drained on each command for error reporting.
type serverIO struct {
	stdinR   *os.File
	stdinW   *os.File
	stdoutR  *os.File
	stdoutW  *os.File
	stderrB  bytes.Buffer
	stderrMu sync.Mutex
}

func newServerIO() (*serverIO, error) {
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		stdinR.Close()
		stdinW.Close()
		return nil, err
	}
	return &serverIO{
		stdinR: stdinR, stdinW: stdinW,
		stdoutR: stdoutR, stdoutW: stdoutW,
	}, nil
}

func (s *serverIO) ReadStdin(buf []byte) (int, error) {
	return s.stdinR.Read(buf)
}

func (s *serverIO) WriteStdout(buf []byte) (int, error) {
	return s.stdoutW.Write(buf)
}

func (s *serverIO) WriteStderr(buf []byte) (int, error) {
	s.stderrMu.Lock()
	defer s.stderrMu.Unlock()
	return s.stderrB.Write(buf)
}

func (s *serverIO) CloseStdin() {
	s.stdinR.Close()
}

func (s *serverIO) CloseAll() {
	s.stdinR.Close()
	s.stdoutW.Close()
}

func (s *serverIO) DrainStderr(from int) []byte {
	s.stderrMu.Lock()
	defer s.stderrMu.Unlock()
	b := s.stderrB.Bytes()
	if from >= len(b) {
		return nil
	}
	result := make([]byte, len(b)-from)
	copy(result, b[from:])
	return result
}

func closeAll(closers ...io.Closer) error {
	var errs []error
	for _, c := range closers {
		if err := c.Close(); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// NewServer starts a persistent ExifTool process using -stay_open true.
// commonArg is prepended to every subsequent [Server.Command] invocation
// (for example "-fast", "-api", "LargeFileSupport=1").
// The package-level [Arg1] and [Config] variables are also included.
// Call [Server.Shutdown] or [Server.Close] when done to release resources.
func NewServer(commonArg ...string) (*Server, error) {
	e := &Server{
		rootFS: defaultRootFS(),
	}
	e.cmd = &cmdStub{Process: &processStub{server: e}}

	if Arg1 != "" {
		e.args = append(e.args, Arg1)
	}
	if Config != "" {
		e.args = append(e.args, "-config", Config)
	}
	e.args = append(e.args,
		"-stay_open", "true", "-@", "-",
		"-common_args",
		"-echo4", "{ready"+boundary+"}",
		"-charset", "filename=utf8",
	)
	e.args = append(e.args, commonArg...)

	if err := e.start(); err != nil {
		return nil, err
	}
	return e, nil
}

func (e *Server) start() error {
	e.mod = nil
	e.wasi = nil
	e.stdinW = nil
	e.stdoutR = nil
	e.sio = nil
	e.evalDone = nil
	e.evalErr = nil

	sio, err := newServerIO()
	if err != nil {
		return fmt.Errorf("failed to create pipes: %w", err)
	}

	mod, ws, err := newModule(sio, e.rootFS, nil, []string{os.TempDir()})
	if err != nil {
		_ = closeAll(sio.stdinR, sio.stdinW, sio.stdoutR, sio.stdoutW)
		return fmt.Errorf("failed to create module: %w", err)
	}

	e.mod = mod
	e.wasi = ws
	e.stdinW = sio.stdinW
	e.stdoutR = sio.stdoutR
	e.sio = sio

	e.stdout = bufio.NewScanner(sio.stdoutR)
	e.stdout.Split(splitReadyToken)

	mem := ws.mem()

	if err := initModule(mod, sio); err != nil {
		return err
	}

	wrapper := scriptPreamble + string(exiftoolScript)
	scriptPtr := mod.Xmalloc(int32(len(wrapper) + 1))
	copy(mem[scriptPtr:], wrapper)
	mem[scriptPtr+int32(len(wrapper))] = 0

	argPtrs := make([]int32, len(e.args))
	for i, arg := range e.args {
		b := append([]byte(arg), 0)
		argPtrs[i] = mod.Xmalloc(int32(len(b)))
		copy(mem[argPtrs[i]:], b)
	}

	var argvPtr int32
	if len(argPtrs) > 0 {
		argvPtr = mod.Xmalloc(int32(len(argPtrs) * 4))
		for i, p := range argPtrs {
			binary.LittleEndian.PutUint32(mem[argvPtr+int32(i*4):], uint32(p))
		}
	}

	evalDone := make(chan struct{})
	e.evalDone = evalDone
	e.evalErr = nil

	go func() {
		defer close(evalDone)
		defer func() { _ = sio.stdoutW.Close() }()
		defer func() { _ = sio.stdinR.Close() }()
		defer func() {
			if r := recover(); r != nil {
				if ep, ok := r.(exitPanic); ok {
					if ep.code != 0 {
						e.evalErr = fmt.Errorf("exiftool exited with code %d", ep.code)
					}
				} else {
					panic(r)
				}
			}
		}()

		mod.Xzeroperl_eval(scriptPtr, 1, int32(len(e.args)), argvPtr)

		mod.Xfree(scriptPtr)
		for _, p := range argPtrs {
			mod.Xfree(p)
		}
		if argvPtr != 0 {
			mod.Xfree(argvPtr)
		}
	}()

	return nil
}

// stopForceClose tears down the server without waiting for the eval goroutine.
// It sends the -stay_open false signal, closes both ends of the stdin and
// stdout pipes (so Perl's next I/O attempt fails), and releases the stdout
// reader.
//
// This is the correct shutdown path when Perl may be in an uninterruptible
// computation phase (e.g. during initial module loading) where it is not
// reading from stdin. Xzeroperl_eval is synchronous native code — it cannot
// be preempted or interrupted. The eval goroutine will eventually encounter
// a pipe error on its next I/O attempt and exit, at which point evalDone is
// closed. Under -count=1 each test gets a fresh process, so orphaned
// goroutines die with the process.
func (e *Server) stopForceClose() {
	if e.stdinW != nil {
		_, _ = fmt.Fprint(e.stdinW, "-stay_open\nfalse\n")
		_ = e.stdinW.Close()
	}
	if e.sio != nil {
		// Close stdinR and stdoutW. This forces any in-flight Perl I/O to fail.
		// The eval goroutine's deferred cleanup also closes these, but closing
		// here ensures failure is immediate rather than delayed.
		e.sio.CloseAll()
	}
	if e.stdoutR != nil {
		_ = e.stdoutR.Close()
		e.stdoutR = nil
	}
}

func (e *Server) restart() {
	e.srvMtx.Lock()
	defer e.srvMtx.Unlock()
	if e.done {
		return
	}
	e.stopForceClose()
	e.restartErr = e.start()
}

// Command sends one ExifTool command via the stay_open protocol and blocks
// until the response (delimited by the {ready} token) is received. If
// ExifTool writes to stderr, it is returned as an error and the response is
// nil. On any I/O failure the server restarts automatically.
func (e *Server) Command(arg ...string) ([]byte, error) {
	e.cmdMtx.Lock()
	defer e.cmdMtx.Unlock()

	e.srvMtx.Lock()
	done := e.done
	e.srvMtx.Unlock()
	if done {
		return nil, errors.New("exiftool: server is closed")
	}

	if err := e.restartErr; err != nil {
		e.restartErr = nil
		return nil, fmt.Errorf("server had a previous restart error: %w", err)
	}

	e.sio.stderrMu.Lock()
	stderrBefore := e.sio.stderrB.Len()
	e.sio.stderrMu.Unlock()

	for _, a := range arg {
		if _, err := fmt.Fprintf(e.stdinW, "%s\n", a); err != nil {
			e.restart()
			return nil, err
		}
	}
	if _, err := fmt.Fprintf(e.stdinW, "-execute%s\n", boundary); err != nil {
		e.restart()
		return nil, err
	}

	if !e.stdout.Scan() {
		err := e.stdout.Err()
		if err == nil {
			select {
			case <-e.evalDone:
				if e.evalErr != nil {
					err = e.evalErr
				} else {
					err = fmt.Errorf("exiftool: server closed unexpectedly: %w", io.EOF)
				}
			default:
				err = fmt.Errorf("exiftool: server closed unexpectedly: %w", io.EOF)
			}
		}
		e.restart()
		return nil, err
	}

	stderrData := e.sio.DrainStderr(stderrBefore)
	if len(stderrData) > 0 {
		scanner := bufio.NewScanner(bytes.NewReader(stderrData))
		scanner.Split(splitReadyToken)
		if scanner.Scan() {
			if len(scanner.Bytes()) > 0 {
				return nil, errors.New("exiftool: " + string(bytes.TrimSpace(scanner.Bytes())))
			}
		}
	}

	return append([]byte(nil), e.stdout.Bytes()...), nil
}

func (e *Server) finalize() error {
	e.done = true
	if e.stdoutR != nil {
		_ = e.stdoutR.Close()
		e.stdoutR = nil
	}
	return nil
}

// Close forcibly stops the server by closing all I/O pipes. It does NOT
// wait for the eval goroutine to finish — this is necessary because
// Xzeroperl_eval is synchronous native code that may be in an
// uninterruptible computation phase (e.g. Perl module loading) where it
// is not reading from stdin. The goroutine will exit on its next failed
// I/O attempt. It is safe to call Close multiple times.
func (e *Server) Close() error {
	e.srvMtx.Lock()
	defer e.srvMtx.Unlock()
	if e.done {
		return nil
	}
	e.stopForceClose()
	return e.finalize()
}

// Shutdown performs a graceful shutdown: it sends the -stay_open false
// signal, closes stdin, and waits for the eval goroutine to complete
// before releasing resources.
//
// This is safe ONLY when the server has completed initialization and
// Perl is in the -stay_open read loop. If Perl is still initializing
// (loading modules, not reading stdin), this will block indefinitely
// because Xzeroperl_eval is synchronous native code that cannot be
// interrupted.
//
// For a force-quit that works at any point in the server lifecycle, use
// [Server.Close] instead.
//
// Returns an error if called after the server is already closed.
func (e *Server) Shutdown() error {
	e.cmdMtx.Lock()
	defer e.cmdMtx.Unlock()

	e.srvMtx.Lock()
	if e.done {
		e.srvMtx.Unlock()
		return errors.New("exiftool: server is closed")
	}
	e.srvMtx.Unlock()

	// Send shutdown signal and wait for Perl to process it.
	// Perl MUST be in the -stay_open read loop for this to complete.
	fmt.Fprintf(e.stdinW, "-stay_open\nfalse\n")
	if err := e.stdinW.Close(); err != nil {
		return fmt.Errorf("failed to close stdin: %w", err)
	}
	<-e.evalDone

	e.srvMtx.Lock()
	defer e.srvMtx.Unlock()
	if e.done {
		return nil
	}
	return e.finalize()
}

// splitReadyToken is a bufio.SplitFunc that scans until the ExifTool
// "{ready<boundary>}" response token followed by a newline. The token and
// newline are consumed but not included in the returned token data.
func splitReadyToken(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if i := bytes.Index(data, []byte("{ready"+boundary+"}")); i >= 0 {
		if n := bytes.IndexByte(data[i:], '\n'); n >= 0 {
			if atEOF && len(data) == (n+i+1) {
				return n + i + 1, data[:i], bufio.ErrFinalToken
			} else {
				return n + i + 1, data[:i], nil
			}
		}
	}
	if atEOF {
		return 0, data, io.EOF
	}
	return 0, nil, nil
}
