package exiftool

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
)

// boundary delimits commands in the ExifTool -stay_open protocol.
const boundary = "1854673209"

const (
	stayOpenScannerInitBuf = 64 * 1024
	maxStayOpenStdoutToken = 1024 * 1024
	maxServerStderrPayload = 64 * 1024
	stderrFramingToken     = "{ready" + boundary + "}\n"
)

var readyFramingToken = []byte("{ready" + boundary + "}")

type processStub struct{ server *Server }

func (p *processStub) Kill() error {
	if p.server.generation != nil && p.server.generation.stdinW != nil {
		return p.server.generation.stdinW.Close()
	}
	return nil
}

func (p *processStub) Release() error { return nil }

type cmdStub struct{ Process *processStub }

// Server is a persistent, in-process ExifTool instance using the -stay_open
// protocol. Command calls serialize. Do not call Close or Shutdown concurrently
// with an in-flight Command. Use Shutdown for an orderly join or Close to stop
// at the next host-I/O boundary without waiting for native guest computation.
type Server struct {
	srvMtx          sync.Mutex
	cmdMtx          sync.Mutex
	args            []string
	cwd             string
	done            bool
	cmd             *cmdStub
	restartErr      error
	operandPreopens []string
	generation      *serverGeneration
}

// serverGeneration owns everything an evaluator can access. Its evaluator never
// refers back to Server, and publishes its result by closing evalDone.
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

// serverIO keeps stderr payload bounded while independently recognizing framing,
// including frames split across writes or arriving after payload overflow.
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

func (s *serverIO) appendStderr(b byte) {
	if s.stderrB.Len() < maxServerStderrPayload {
		_ = s.stderrB.WriteByte(b)
	} else {
		s.stderrOverflow = true
	}
}

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

func (s *serverIO) CloseStdin() { _ = s.stdinR.Close() }

func (s *serverIO) CloseAll() {
	s.stopped.Store(true)
	_ = closeAll(s.stdinR, s.stdoutW)
}

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

func (s *serverIO) DrainStderr(from int) []byte {
	data, _ := s.takeStderr(from)
	return data
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

// NewServer starts a persistent ExifTool interpreter. commonArg is prepended to
// commands, along with package-level Arg1 and Config. Call Shutdown after use.
func NewServer(commonArg ...string) (*Server, error) {
	e := &Server{}
	e.cmd = &cmdStub{Process: &processStub{server: e}}
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
	mod, ws, err := newModuleAt(sio, e.cwd, nil, serverWritableDirs(e.cwd, e.operandPreopens))
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

func evaluateServerModule(mod *wasm2go.Module, ws *wasiState, args []string) {
	mem := ws.mem()
	wrapper := []byte(exiftoolEvalWrapper)
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

func (g *serverGeneration) forceStop() {
	g.sio.CloseAll()
	_ = g.stdinW.Close()
	_ = g.stdoutR.Close()
}

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

// Command sends one serialized command and waits for both response frames.
// Diagnostics are drained per command; overflow is an explicit error. I/O
// failures join the old evaluator before starting a replacement.
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
	scanArgs := append(append([]string{}, packageArgs()...), arg...)
	if err := e.ensureOperandPreopens(commandWritableDirs(e.cwd, scanArgs)); err != nil {
		return nil, err
	}
	g := e.generation
	// Any preceding diagnostics belong to this generation, never an old offset.
	_, _ = g.sio.takeStderr(0)
	argv := guestOperandPaths(e.cwd, arg)
	for _, a := range argv {
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

// Close force-closes the current generation's pipes without waiting for native
// computation. Its next server-owned host-I/O operation exits the evaluator.
// Close is idempotent; callers must not race it with Command or Shutdown.
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

// Shutdown sends -stay_open false, closes stdin and joins its generation before
// releasing resources. Native computation may delay the next host-I/O boundary.
// Repeated Shutdown and commands after either shutdown method return an error.
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

func newStayOpenStdoutScanner(r io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, stayOpenScannerInitBuf), maxStayOpenStdoutToken)
	scanner.Split(splitReadyToken)
	return scanner
}

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

func serverWritableDirs(cwd string, operandPreopens []string) []string {
	return append([]string{os.TempDir()}, operandPreopens...)
}

func neededOperandPreopens(cwd string, writableDirs []string) []string {
	tempDir := filepath.Clean(os.TempDir())
	var out []string
	for _, d := range writableDirs {
		d = filepath.Clean(d)
		if d == tempDir || pathWithinDir(d, cwd) {
			continue
		}
		out = append(out, d)
	}
	return out
}

func (e *Server) ensureOperandPreopens(writableDirs []string) error {
	need := neededOperandPreopens(e.cwd, writableDirs)
	if len(need) == 0 {
		return nil
	}
	merged, changed := mergePreopenDirLists(e.operandPreopens, need)
	if !changed {
		return nil
	}
	e.operandPreopens = merged
	e.restart()
	if e.restartErr != nil {
		return fmt.Errorf("exiftool: remount operand dirs: %w", e.restartErr)
	}
	return nil
}
