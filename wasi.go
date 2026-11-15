package exiftool

import (
	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasm2go-wasi-host"
)

// exitPanic is the panic value Xproc_exit raises for WASI proc_exit. Every place
// that runs the guest recovers it. code is the exit status, and 0 means success.
type exitPanic struct{ code int32 }

// Error lets exitPanic satisfy the error interface.
func (exitPanic) Error() string { return "proc_exit" }

// wasiState handles a zeroperl module's imports. wasm2go.New(ws, ws) uses it for
// both the env and the wasi_snapshot_preview1 imports. The embedded
// wasihost.State, which initWASIState creates, implements WASI. wasiState
// overrides Xproc_exit so that every exit panics with exitPanic.
type wasiState struct {
	*wasihost.State
	guestIO guestIO
	cwd     string // host cwd the guest chdirs to
}

// Xproc_exit panics with exitPanic{code} for the caller that runs the guest to
// recover. It replaces wasihost.State.Xproc_exit, which panics with
// wasihost.ExitError.
func (w *wasiState) Xproc_exit(code int32) {
	panic(exitPanic{code: code})
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
		WithStderr(writer(gio.WriteStderr))
	ws.State = wasihost.New(func() []byte { return *mod.Xmemory().Slice() }, moduleCfg)
	ws.guestIO = gio
}
