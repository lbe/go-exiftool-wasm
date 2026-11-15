package exiftool

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"

	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
)

// boundary delimits commands in the ExifTool -stay_open protocol.
const boundary = "1854673209"

const (
	stayOpenScannerInitBuf = 64 * 1024                   // initial stdout scanner buffer
	maxStayOpenStdoutToken = 1024 * 1024                 // largest stdout response
	maxServerStderrPayload = 64 * 1024                   // stderr kept per command
	stderrFramingToken     = "{ready" + boundary + "}\n" // -echo4 line that ends a command's stderr
)

// readyFramingToken marks the end of a command's stdout.
var readyFramingToken = []byte("{ready" + boundary + "}")

// Server is one ExifTool interpreter that keeps running between commands, using
// ExifTool's -stay_open protocol. Commands run one at a time. Do not call
// [Server.Close] or [Server.Shutdown] while a [Server.Command] is running.
// Shutdown stops the interpreter and waits for it. Close stops it at its next
// host I/O call and returns without waiting.
type Server struct {
	srvMtx     sync.Mutex // guards done, generation and restarts
	cmdMtx     sync.Mutex // serializes Command and Shutdown
	args       []string   // startup argv for every generation
	cwd        string     // host working directory for every generation
	done       bool       // set by Close or Shutdown
	restartErr error      // error from the last failed restart
	generation *serverGeneration
}

// serverGeneration holds one interpreter and everything its evaluator can reach.
// A restart replaces the whole generation. The evaluator never refers back to
// Server, and it reports its result by closing evalDone.
type serverGeneration struct {
	mod      *wasm2go.Module
	wasi     *wasiState
	stdinW   io.WriteCloser
	stdoutR  io.Closer
	stdout   *bufio.Scanner
	sio      *serverIO
	evalDone chan struct{}
	evalErr  error
}

// serverIO is the stdio backend for a Server. Stdin and stdout are pipes. Stderr
// goes to a buffer capped at maxServerStderrPayload, and WriteStderr separately
// watches for stderrFramingToken, which ends each command's stderr. It finds the
// token even when a write splits it or the buffer has overflowed.
type serverIO struct {
	stdinR         *os.File
	stdinW         *os.File
	stdoutR        *os.File
	stdoutW        *os.File
	stopped        atomic.Bool
	stderrB        bytes.Buffer
	stderrMu       sync.Mutex
	stderrPending  [len(stderrFramingToken)]byte
	stderrPendingN int
	stderrOverflow bool
	stderrReady    chan struct{}
}

// newServerIO creates the stdin and stdout pipes.
func newServerIO() (*serverIO, error) {
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		_ = closeAll(stdinR, stdinW)
		return nil, err
	}
	return &serverIO{
		stdinR: stdinR, stdinW: stdinW, stdoutR: stdoutR, stdoutW: stdoutW,
		stderrB:     *bytes.NewBuffer(make([]byte, 0, maxServerStderrPayload)),
		stderrReady: make(chan struct{}, 1),
	}, nil
}

func (s *serverIO) ReadStdin(buf []byte) (int, error)   { return s.stdinR.Read(buf) }
func (s *serverIO) WriteStdout(buf []byte) (int, error) { return s.stdoutW.Write(buf) }

// appendStderr adds b to the stderr buffer, or records an overflow if the buffer
// is full. The caller holds stderrMu.
func (s *serverIO) appendStderr(b byte) {
	if s.stderrB.Len() < maxServerStderrPayload {
		_ = s.stderrB.WriteByte(b)
	} else {
		s.stderrOverflow = true
	}
}

// WriteStderr stores guest stderr and signals stderrReady when it sees
// stderrFramingToken. Bytes that could start the token wait in stderrPending
// until they either complete it or stop matching.
func (s *serverIO) WriteStderr(buf []byte) (int, error) {
	s.stderrMu.Lock()
	defer s.stderrMu.Unlock()
	for _, b := range buf {
		s.stderrPending[s.stderrPendingN] = b
		s.stderrPendingN++
		for s.stderrPendingN > 0 && !bytes.HasPrefix([]byte(stderrFramingToken), s.stderrPending[:s.stderrPendingN]) {
			s.appendStderr(s.stderrPending[0])
			copy(s.stderrPending[:], s.stderrPending[1:s.stderrPendingN])
			s.stderrPendingN--
		}
		if s.stderrPendingN == len(stderrFramingToken) {
			s.stderrPendingN = 0
			select {
			case s.stderrReady <- struct{}{}:
			default:
			}
		}
	}
	return len(buf), nil
}

// CloseStdin closes the guest's read end of stdin.
func (s *serverIO) CloseStdin() { _ = s.stdinR.Close() }

// CloseAll marks the backend stopped and closes the guest's ends of both pipes.
func (s *serverIO) CloseAll() {
	s.stopped.Store(true)
	_ = closeAll(s.stdinR, s.stdoutW)
}

// takeStderr returns a copy of the stderr buffer from offset from, reports
// whether it overflowed, and then clears both.
func (s *serverIO) takeStderr(from int) ([]byte, bool) {
	s.stderrMu.Lock()
	defer s.stderrMu.Unlock()
	for _, b := range s.stderrPending[:s.stderrPendingN] {
		s.appendStderr(b)
	}
	s.stderrPendingN = 0
	var result []byte
	if from >= 0 && from < s.stderrB.Len() {
		result = append([]byte(nil), s.stderrB.Bytes()[from:]...)
	}
	overflow := s.stderrOverflow
	s.stderrB.Reset()
	s.stderrOverflow = false
	return result, overflow
}

// closeAll closes every closer and joins their errors.
func closeAll(closers ...io.Closer) error {
	var errs []error
	for _, c := range closers {
		if err := c.Close(); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// NewServer starts an interpreter that runs ExifTool with -stay_open. Its startup
// arguments are [Arg1] and [Config] if set, then the stay_open options, then
// commonArg after -common_args, so ExifTool applies commonArg to every command.
// Relative paths in later commands resolve against the working directory at the
// time of this call. Call [Server.Shutdown] or [Server.Close] when done.
func NewServer(commonArg ...string) (*Server, error) {
	e := &Server{}
	if Arg1 != "" {
		e.args = append(e.args, Arg1)
	}
	if Config != "" {
		e.args = append(e.args, "-config", Config)
	}
	e.args = append(e.args, "-stay_open", "true", "-@", "-", "-common_args",
		"-echo4", "{ready"+boundary+"}", "-charset", "filename=utf8")
	e.args = append(e.args, commonArg...)
	if err := e.start(); err != nil {
		return nil, err
	}
	return e, nil
}

// start creates a generation and starts its evaluator goroutine. The first call
// records the working directory, and restarts reuse it.
func (e *Server) start() error {
	sio, err := newServerIO()
	if err != nil {
		return fmt.Errorf("failed to create pipes: %w", err)
	}
	if e.cwd == "" {
		e.cwd, err = os.Getwd()
		if err != nil {
			_ = closeAll(sio.stdinR, sio.stdinW, sio.stdoutR, sio.stdoutW)
			return fmt.Errorf("exiftool: getwd: %w", err)
		}
	}
	mod, ws, err := newModuleAt(sio, e.cwd, nil)
	if err != nil {
		_ = closeAll(sio.stdinR, sio.stdinW, sio.stdoutR, sio.stdoutW)
		return fmt.Errorf("failed to create module: %w", err)
	}
	if err := initModule(mod, sio); err != nil {
		_ = closeAll(sio.stdinR, sio.stdinW, sio.stdoutR, sio.stdoutW)
		return err
	}
	g := &serverGeneration{
		mod: mod, wasi: ws, sio: sio, stdinW: sio.stdinW, stdoutR: sio.stdoutR,
		stdout: newStayOpenStdoutScanner(sio.stdoutR), evalDone: make(chan struct{}),
	}
	e.generation = g
	args := append([]string(nil), e.args...)
	go func() {
		defer close(g.evalDone)
		defer func() {
			_ = closeAll(sio.stdinR, sio.stdoutW)
			g.mod = nil
			g.wasi = nil
		}()
		defer func() {
			if r := recover(); r != nil {
				if ep, ok := r.(exitPanic); ok {
					if ep.code != 0 {
						g.evalErr = fmt.Errorf("exiftool exited with code %d", ep.code)
					}
				} else {
					panic(r)
				}
			}
		}()
		evaluateServerModule(mod, ws, args)
	}()
	return nil
}

// evaluateServerModule copies the wrapper and args into guest memory and runs
// ExifTool. It returns when ExifTool leaves the stay_open loop; the caller
// recovers exitPanic.
func evaluateServerModule(mod *wasm2go.Module, ws *wasiState, args []string) {
	mem := ws.mem()
	wrapper := []byte(exiftoolEvalWrapper(ws.cwd))
	scriptPtr := mod.Xmalloc(int32(len(wrapper) + 1))
	copy(mem[scriptPtr:], wrapper)
	mem[scriptPtr+int32(len(wrapper))] = 0
	defer mod.Xfree(scriptPtr)
	argPtrs := make([]int32, len(args))
	for i, arg := range args {
		b := append([]byte(arg), 0)
		argPtrs[i] = mod.Xmalloc(int32(len(b)))
		copy(mem[argPtrs[i]:], b)
	}
	defer func() {
		for _, p := range argPtrs {
			mod.Xfree(p)
		}
	}()
	var argvPtr int32
	if len(argPtrs) > 0 {
		argvPtr = mod.Xmalloc(int32(len(argPtrs) * 4))
		for i, p := range argPtrs {
			binary.LittleEndian.PutUint32(mem[argvPtr+int32(i*4):], uint32(p))
		}
		defer mod.Xfree(argvPtr)
	}
	mod.Xzeroperl_eval(scriptPtr, 0, int32(len(args)), argvPtr)
}

// forceStop closes the generation's pipes so its evaluator exits at its next host
// I/O call. It does not wait.
func (g *serverGeneration) forceStop() {
	g.sio.CloseAll()
	_ = g.stdinW.Close()
	_ = g.stdoutR.Close()
}

// restart stops the current generation, waits for its evaluator to exit, and
// starts a new one. It stores any start error in restartErr. After Close or
// Shutdown it does nothing.
func (e *Server) restart() {
	e.srvMtx.Lock()
	defer e.srvMtx.Unlock()
	if e.done {
		return
	}
	if g := e.generation; g != nil {
		g.forceStop()
		<-g.evalDone
		e.generation = nil
	}
	e.restartErr = e.start()
}

// Command sends arg to ExifTool as one command and returns its stdout. Calls run
// one at a time.
//
// If ExifTool writes anything to stderr, Command returns an error that holds the
// text, and no stdout. If the stderr text exceeds 64 KiB, the error reports the
// overflow, and later commands still work. If a pipe fails or the interpreter
// exits, Command restarts the interpreter before it returns the error. If that
// restart fails, every later call returns the restart error.
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
		return nil, fmt.Errorf("server had a previous restart error: %w", err)
	}
	g := e.generation
	// Drop stderr left over from earlier activity in this generation.
	_, _ = g.sio.takeStderr(0)
	for _, a := range arg {
		if _, err := fmt.Fprintf(g.stdinW, "%s\n", a); err != nil {
			e.restart()
			return nil, err
		}
	}
	if _, err := fmt.Fprintf(g.stdinW, "-execute%s\n", boundary); err != nil {
		e.restart()
		return nil, err
	}
	if !g.stdout.Scan() {
		err := g.stdout.Err()
		if err == nil {
			select {
			case <-g.evalDone:
				err = g.evalErr
			default:
			}
			if err == nil {
				err = fmt.Errorf("exiftool: server closed unexpectedly: %w", io.EOF)
			}
		}
		e.restart()
		return nil, err
	}
	select {
	case <-g.sio.stderrReady:
	case <-g.evalDone:
		if g.evalErr != nil {
			e.restart()
			return nil, g.evalErr
		}
	}
	stderrData, overflow := g.sio.takeStderr(0)
	if overflow {
		return nil, fmt.Errorf("exiftool: stderr overflow (truncated at %d bytes): %s", maxServerStderrPayload, bytes.TrimSpace(stderrData))
	}
	if len(bytes.TrimSpace(stderrData)) > 0 {
		return nil, errors.New("exiftool: " + string(bytes.TrimSpace(stderrData)))
	}
	return append([]byte(nil), g.stdout.Bytes()...), nil
}

// Close stops the server without waiting. It closes the pipes, and the
// interpreter exits at its next host I/O call; Close cannot interrupt guest code
// while it computes. Calling Close again does nothing. Do not call it while a
// Command or Shutdown is running.
func (e *Server) Close() error {
	e.srvMtx.Lock()
	defer e.srvMtx.Unlock()
	if !e.done {
		if e.generation != nil {
			e.generation.forceStop()
		}
		e.done = true
	}
	return nil
}

// Shutdown asks ExifTool to exit with -stay_open false, closes stdin, and waits
// for the interpreter to exit. Guest code that is still computing delays it.
// Shutdown returns an error if Close or Shutdown already ran, and so does every
// Command after either one.
func (e *Server) Shutdown() error {
	e.cmdMtx.Lock()
	defer e.cmdMtx.Unlock()
	e.srvMtx.Lock()
	defer e.srvMtx.Unlock()
	if e.done {
		return errors.New("exiftool: server is closed")
	}
	g := e.generation
	if g == nil {
		e.done = true
		return fmt.Errorf("exiftool: no running generation: %w", e.restartErr)
	}
	_, writeErr := fmt.Fprint(g.stdinW, "-stay_open\nfalse\n")
	closeErr := g.stdinW.Close()
	if writeErr != nil || closeErr != nil {
		g.forceStop()
	}
	<-g.evalDone
	_ = g.stdoutR.Close()
	e.done = true
	return errors.Join(writeErr, closeErr)
}

// newStayOpenStdoutScanner returns a scanner that splits stdout at each ready
// token and accepts responses up to maxStayOpenStdoutToken bytes.
func newStayOpenStdoutScanner(r io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, stayOpenScannerInitBuf), maxStayOpenStdoutToken)
	scanner.Split(splitReadyToken)
	return scanner
}

// splitReadyToken is a bufio.SplitFunc. Each token is the output before
// readyFramingToken, and the split consumes the rest of the token's line.
func splitReadyToken(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if i := bytes.Index(data, readyFramingToken); i >= 0 {
		if n := bytes.IndexByte(data[i:], '\n'); n >= 0 {
			if atEOF && len(data) == (n+i+1) {
				return n + i + 1, data[:i], bufio.ErrFinalToken
			}
			return n + i + 1, data[:i], nil
		}
	}
	if atEOF {
		return 0, data, io.EOF
	}
	return 0, nil, nil
}
