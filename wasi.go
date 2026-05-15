package exiftool

import (
	"io/fs"
	"os"

	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasi-wasm2go"
)

// exitPanic is recovered at eval boundaries to model WASI proc_exit.
// code 0 means success, non-zero means failure.
type exitPanic struct{ code int32 }

func (exitPanic) Error() string { return "proc_exit" }

// wasiState wraps the standalone WASI host module with a guestIO for I/O bridging.
type wasiState struct {
	*wasihost.State
	guestIO guestIO
}

// Xproc_exit panics with exitPanic so evalModule/initModule can recover it.
// This overrides wasihost.State.Xproc_exit (which panics with ExitError).
func (w *wasiState) Xproc_exit(code int32) {
	panic(exitPanic{code: code})
}

// mem returns the guest memory slice. Delegates to wasihost.State.Mem().
func (w *wasiState) mem() []byte {
	return w.State.Mem()
}

// mountEntry mirrors the standalone module's mountEntry for use in exiftool.go.
type mountEntry struct {
	guestPath string
	root      fs.FS
	writable  bool
	hostRoot  string
}

// stdinAdapter bridges guestIO.ReadStdin to io.Reader.
type stdinAdapter struct{ gio guestIO }

func (a *stdinAdapter) Read(p []byte) (int, error) { return a.gio.ReadStdin(p) }

// ioWriterFunc bridges a write func to io.Writer.
type ioWriterFunc func([]byte) (int, error)

func (f ioWriterFunc) Write(p []byte) (int, error) { return f(p) }

// initWASIState initialises ws using the standalone wasihost module.
func initWASIState(ws *wasiState, mod *wasm2go.Module, gio guestIO, mounts []mountEntry) {
	opts := []wasihost.Option{
		wasihost.WithStdin(&stdinAdapter{gio}),
		wasihost.WithStdout(ioWriterFunc(func(p []byte) (int, error) { return gio.WriteStdout(p) })),
		wasihost.WithStderr(ioWriterFunc(func(p []byte) (int, error) { return gio.WriteStderr(p) })),
	}
	for _, m := range mounts {
		if m.writable {
			opts = append(opts, wasihost.WithWritableMount(m.guestPath, m.hostRoot, m.root))
		} else {
			opts = append(opts, wasihost.WithMount(m.guestPath, m.root))
		}
	}
	ws.State = wasihost.New(func() []byte { return *mod.Xmemory().Slice() }, opts...)
	ws.guestIO = gio
	if os.Getenv("EXIFTOOL_WASI_TRACE") == "1" {
		wasihost.WithTracing()(ws.State)
	}
	if os.Getenv("EXIFTOOL_WASI_ASSERT_OWNER") == "1" {
		wasihost.WithOwnerAssertion()(ws.State)
	}
}
