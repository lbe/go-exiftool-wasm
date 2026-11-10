package exiftool

import (
	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasm2go-wasi-host"
)

// exitPanic is recovered at eval boundaries to model WASI proc_exit.
// code 0 means success, non-zero means failure.
type exitPanic struct{ code int32 }

func (exitPanic) Error() string { return "proc_exit" }

// wasiState embeds wasihost.State and is passed to wasm2go.New(ws, ws) as both
// the env and wasi_snapshot_preview1 import handlers. initWASIState constructs
// the embedded State via wasihost.New with a per-syscall memory callback and
// the ModuleConfig from buildModuleConfig. Xproc_exit is overridden to panic
// with exitPanic instead of wasihost.ExitError so eval boundaries can recover
// guest exit codes consistently.
type wasiState struct {
	*wasihost.State
	guestIO guestIO
}

// Xproc_exit panics with exitPanic so evalModule/initModule can recover it.
// This overrides wasihost.State.Xproc_exit (which panics with ExitError).
func (w *wasiState) Xproc_exit(code int32) {
	panic(exitPanic{code: code})
}

// mem returns the guest memory slice from the embedded wasihost.State.
func (w *wasiState) mem() []byte {
	return w.Mem()
}

// stdinAdapter adapts guestIO.ReadStdin to io.Reader.
type stdinAdapter struct{ gio guestIO }

func (a *stdinAdapter) Read(p []byte) (int, error) {
	server, owned := a.gio.(*serverIO)
	if owned && server.stopped.Load() {
		panic(exitPanic{code: 0})
	}
	n, err := a.gio.ReadStdin(p)
	if owned && (server.stopped.Load() || (len(p) > 0 && n == 0 && err != nil)) {
		// EOF and closed pipes must leave the stay_open evaluator, not feed its
		// warning/poll loop. One-shot stdin retains ordinary Reader semantics.
		panic(exitPanic{code: 0})
	}
	return n, err
}

// ioWriterFunc adapts a write func to io.Writer.
type ioWriterFunc func([]byte) (int, error)

func (f ioWriterFunc) Write(p []byte) (int, error) { return f(p) }

// initWASIState attaches stdio adapters to moduleCfg, then constructs
// wasihost.State with a memory callback that re-reads mod.Xmemory().Slice() on
// each syscall (required after guest memory growth). guestIO is retained for
// stdout/stderr capture in directIO and serverIO modes.
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
