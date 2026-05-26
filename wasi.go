package exiftool

import (
	"os"

	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasm2go-wasi-host"
)

// exitPanic is recovered at eval boundaries to model WASI proc_exit.
// code 0 means success, non-zero means failure.
type exitPanic struct{ code int32 }

func (exitPanic) Error() string { return "proc_exit" }

// wasiState wraps the external wasm2go-wasi-host module with a guestIO for I/O bridging.
// The WASI implementation is provided by github.com/lbe/wasm2go-wasi-host.
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

func (a *stdinAdapter) Read(p []byte) (int, error) { return a.gio.ReadStdin(p) }

// ioWriterFunc adapts a write func to io.Writer.
type ioWriterFunc func([]byte) (int, error)

func (f ioWriterFunc) Write(p []byte) (int, error) { return f(p) }

// initWASIState initialises ws using the external wasihost module. The caller
// supplies pre-built mount and I/O options; initWASIState prepends stdin/stdout/stderr
// adapters and activates optional tracing or owner-assertion via environment variables.
func initWASIState(ws *wasiState, mod *wasm2go.Module, gio guestIO, opts []wasihost.Option) {
	opts = append(opts,
		wasihost.WithStdin(&stdinAdapter{gio}),
		wasihost.WithStdout(ioWriterFunc(func(p []byte) (int, error) { return gio.WriteStdout(p) })),
		wasihost.WithStderr(ioWriterFunc(func(p []byte) (int, error) { return gio.WriteStderr(p) })),
	)
	ws.State = wasihost.New(func() []byte { return *mod.Xmemory().Slice() }, opts...)
	ws.guestIO = gio
	if os.Getenv("EXIFTOOL_WASI_TRACE") == "1" {
		wasihost.WithTracing()(ws.State)
	}
	if os.Getenv("EXIFTOOL_WASI_ASSERT_OWNER") == "1" {
		wasihost.WithOwnerAssertion()(ws.State)
	}
}
