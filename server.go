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

	wasm2go "github.com/lbe/go-exiftool/zeroperl"
)

const boundary = "1854673209"

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

type cmdStub struct {
	Process *processStub
}

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

	func() {
		defer func() {
			if r := recover(); r != nil {
				if ep, ok := r.(exitPanic); ok {
					if ep.code != 0 {
						_ = closeAll(sio.stdinR, sio.stdoutW)
						panic(fmt.Errorf("zeroperl_init exited with code %d", ep.code))
					}
				} else {
					panic(r)
				}
			}
		}()
		rc := mod.Xzeroperl_init()
		if rc != 0 {
			_ = closeAll(sio.stdinR, sio.stdoutW)
			panic(fmt.Errorf("zeroperl_init returned %d", rc))
		}
	}()

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

func (e *Server) stop() {
	if e.stdinW != nil {
		_ = e.stdinW.Close()
	}
	if e.evalDone != nil {
		<-e.evalDone
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
	e.stop()
	e.restartErr = e.start()
}

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

func (e *Server) Close() error {
	e.srvMtx.Lock()
	defer e.srvMtx.Unlock()
	if e.done {
		return nil
	}
	if e.stdinW != nil {
		_ = e.stdinW.Close()
	}
	if e.evalDone != nil {
		<-e.evalDone
	}
	return e.finalize()
}

func (e *Server) Shutdown() error {
	e.cmdMtx.Lock()
	defer e.cmdMtx.Unlock()

	e.srvMtx.Lock()
	if e.done {
		e.srvMtx.Unlock()
		return errors.New("exiftool: server is closed")
	}
	e.srvMtx.Unlock()

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
