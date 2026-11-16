package exiftool

import (
	"context"
	"time"

	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasm2go-wasi-host"
)

// exitPanic is the panic value Xproc_exit raises for WASI proc_exit. Every place
// that runs the guest recovers it. code is the exit status, and 0 means success.
type exitPanic struct{ code int32 }

// cancelPanic is the panic value a one-shot command's WASI calls raise once its
// context is done. evalModule recovers it and returns ctx.Err().
type cancelPanic struct{}

// wasiState handles a zeroperl module's imports. wasm2go.New(ws, ws) uses it for
// both the env and the wasi_snapshot_preview1 imports. The embedded
// wasihost.State, which initWASIState creates, implements WASI. wasiState
// overrides Xproc_exit so that every exit panics with exitPanic. It also stops a
// one-shot command once ctx is done.
type wasiState struct {
	*wasihost.State
	guestIO guestIO
	cwd     string          // host cwd the guest chdirs to
	ctx     context.Context // one-shot command context; context.Background for a Server
}

// Xproc_exit panics with exitPanic{code} for the caller that runs the guest to
// recover. It replaces wasihost.State.Xproc_exit, which panics with
// wasihost.ExitError.
func (w *wasiState) Xproc_exit(code int32) {
	panic(exitPanic{code: code})
}

// checkCanceled panics with cancelPanic if w.ctx is done.
func (w *wasiState) checkCanceled() {
	select {
	case <-w.ctx.Done():
		panic(cancelPanic{})
	default:
	}
}

// nanosleep is the WASI clock sleep. It sleeps for ns nanoseconds, or panics
// with cancelPanic as soon as w.ctx is done.
func (w *wasiState) nanosleep(ns int64) {
	timer := time.NewTimer(time.Duration(ns))
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-w.ctx.Done():
		panic(cancelPanic{})
	}
}

// Xfd_read calls wasihost.State.Xfd_read after checkCanceled.
func (w *wasiState) Xfd_read(fd, iovsPtr, iovsCount, nreadPtr int32) int32 {
	w.checkCanceled()
	return w.State.Xfd_read(fd, iovsPtr, iovsCount, nreadPtr)
}

// Xfd_write calls wasihost.State.Xfd_write after checkCanceled.
func (w *wasiState) Xfd_write(fd, iovsPtr, iovsCount, nwrittenPtr int32) int32 {
	w.checkCanceled()
	return w.State.Xfd_write(fd, iovsPtr, iovsCount, nwrittenPtr)
}

// mem returns the guest memory slice from the embedded wasihost.State.
func (w *wasiState) mem() []byte {
	return w.Mem()
}

// stdinAdapter makes guestIO.ReadStdin an io.Reader.
type stdinAdapter struct{ gio guestIO }

// Read reads guest stdin. For a serverIO, a stopped server, EOF or a closed pipe
// makes the guest exit with status 0, so a stay_open evaluator leaves instead of
// looping in ExifTool's poll loop. One-shot stdin returns errors like any
// io.Reader.
func (a *stdinAdapter) Read(p []byte) (int, error) {
	server, owned := a.gio.(*serverIO)
	if owned && server.stopped.Load() {
		panic(exitPanic{code: 0})
	}
	n, err := a.gio.ReadStdin(p)
	if owned && (server.stopped.Load() || (len(p) > 0 && n == 0 && err != nil)) {
		panic(exitPanic{code: 0})
	}
	return n, err
}

// ioWriterFunc makes a write function an io.Writer.
type ioWriterFunc func([]byte) (int, error)

func (f ioWriterFunc) Write(p []byte) (int, error) { return f(p) }

// initWASIState connects gio to the module's stdin, stdout and stderr, and creates
// ws.State from moduleCfg. The memory callback reads mod.Xmemory() on every
// system call, because guest memory can grow. For a serverIO, a stopped server or
// a failed write makes the guest exit with status 0.
func initWASIState(ws *wasiState, mod *wasm2go.Module, gio guestIO, moduleCfg *wasihost.ModuleConfig) {
	writer := func(write func([]byte) (int, error)) ioWriterFunc {
		return func(p []byte) (int, error) {
			server, owned := gio.(*serverIO)
			if owned && server.stopped.Load() {
				panic(exitPanic{code: 0})
			}
			n, err := write(p)
			if owned && (server.stopped.Load() || err != nil) {
				panic(exitPanic{code: 0})
			}
			return n, err
		}
	}
	moduleCfg = moduleCfg.
		WithStdin(&stdinAdapter{gio}).
		WithStdout(writer(gio.WriteStdout)).
		WithStderr(writer(gio.WriteStderr)).
		WithNanosleep(ws.nanosleep)
	ws.State = wasihost.New(func() []byte { return *mod.Xmemory().Slice() }, moduleCfg)
	ws.guestIO = gio
}
