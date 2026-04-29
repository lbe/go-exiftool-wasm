package exiftool

import (
	"context"
	"embed"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"sync"
	"time"

	"github.com/lbe/cfsread"
	wasm2go "github.com/lbe/go-exiftool-wasm/zeroperl"
)

// perlFSRoot holds the LZ4-compressed Perl standard library and wasm32-wasi
// modules rooted at embed/perl-wasi-prefix. Use [perlFS] to obtain an fs.FS
// with transparent decompression.
//
//go:embed all:embed/perl-wasi-prefix
var perlFSRoot embed.FS

var (
	perlCachedFS     *cachedFS
	perlCachedFSOnce sync.Once
)

// exiftoolScript holds the minified ExifTool Perl driver script loaded at
// compile time from embed/exiftool.min.pl.
//
//go:embed embed/exiftool.min.pl
var exiftoolScript []byte

// scriptPreamble is prepended to exiftoolScript before eval. It enables
// autoflush on STDOUT and STDERR so the host sees output immediately
// without waiting for Perl's default block buffering.
const scriptPreamble = "use IO::Handle; STDOUT->autoflush(1); STDERR->autoflush(1);\n"

// overlayFS implements fs.FS by trying each layer in order; the first layer
// that can open the name wins. Earlier layers (lower index) shadow later
// ones for any given path.
type overlayFS struct {
	layers []fs.FS
}

func (o *overlayFS) Open(name string) (fs.File, error) {
	for _, layer := range o.layers {
		if f, err := layer.Open(name); err == nil {
			return f, nil
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
	}
	return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
}

// devNullFS is a read-only fs.FS that contains only a root directory (".") and
// a "null" file that always returns EOF. It is mounted at /dev inside the
// guest sandbox so Perl's built-in /dev/null open succeeds.
type devNullFS struct{}

func (devNullFS) Open(name string) (fs.File, error) {
	switch name {
	case ".":
		return &devNullDir{}, nil
	case "null":
		return &devNullFile{}, nil
	default:
		return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
	}
}

// devNullDir implements fs.File and fs.ReadDirFile for the devNullFS root.
type devNullDir struct{ read bool }

func (*devNullDir) Stat() (fs.FileInfo, error) { return devNullDirInfo{}, nil }
func (*devNullDir) Read([]byte) (int, error)   { return 0, io.EOF }
func (*devNullDir) Close() error               { return nil }
func (d *devNullDir) ReadDir(n int) ([]fs.DirEntry, error) {
	if d.read {
		return nil, io.EOF
	}
	d.read = true
	return []fs.DirEntry{fs.FileInfoToDirEntry(devNullFileInfo{})}, nil
}

// devNullDirInfo implements fs.FileInfo for the devNullFS root directory.
type devNullDirInfo struct{}

func (devNullDirInfo) Name() string       { return "." }
func (devNullDirInfo) Size() int64        { return 0 }
func (devNullDirInfo) Mode() fs.FileMode  { return fs.ModeDir | 0o555 }
func (devNullDirInfo) ModTime() time.Time { return time.Time{} }
func (devNullDirInfo) IsDir() bool        { return true }
func (devNullDirInfo) Sys() any           { return nil }

// devNullFile implements fs.File for the synthetic /dev/null entry.
type devNullFile struct{}

func (*devNullFile) Stat() (fs.FileInfo, error) { return devNullFileInfo{}, nil }
func (*devNullFile) Read([]byte) (int, error)   { return 0, io.EOF }
func (*devNullFile) Close() error               { return nil }

// devNullFileInfo implements fs.FileInfo for the synthetic /dev/null entry.
type devNullFileInfo struct{}

func (devNullFileInfo) Name() string       { return "null" }
func (devNullFileInfo) Size() int64        { return 0 }
func (devNullFileInfo) Mode() fs.FileMode  { return 0 }
func (devNullFileInfo) ModTime() time.Time { return time.Time{} }
func (devNullFileInfo) IsDir() bool        { return false }
func (devNullFileInfo) Sys() any           { return nil }

// perlFS returns the process-level singleton cachedFS rooted at the embedded
// perl-wasi-prefix directory. On first call the cachedFS is constructed with
// a 2000-entry LRU; newCachedFS auto-registers LZ4 decompression support when
// no registry is provided. Subsequent calls return the same instance.
// The embedded tree is stored LZ4-compressed; perlFS transparently decompresses
// files on first access and serves subsequent reads from the in-memory cache.
func perlFS() fs.FS {
	perlCachedFSOnce.Do(func() {
		sub, err := fs.Sub(perlFSRoot, "embed/perl-wasi-prefix")
		if err != nil {
			panic("exiftool: embedded perl filesystem unavailable: " + err.Error())
		}
		perlCachedFS = newCachedFS("perl-wasi-prefix", sub, cfsread.Options{
			MaxEntries: 2000,
		})
	})
	return perlCachedFS
}

// defaultRootFS returns an overlay of the embedded Perl stdlib on top of the
// host process working directory. This is the filesystem used by [Command],
// [CommandContext], and [NewServer].
func defaultRootFS() fs.FS {
	return &overlayFS{layers: []fs.FS{perlFS(), os.DirFS(".")}}
}

// commandArgs builds the full ExifTool argument list by prepending the
// package-level [Arg1] and [Config] variables and appending a UTF-8 charset
// flag, followed by the caller-supplied args.
func commandArgs(arg []string) []string {
	var args []string
	if Arg1 != "" {
		args = append(args, Arg1)
	}
	if Config != "" {
		args = append(args, "-config", Config)
	}
	args = append(args, "-charset", "filename=utf8")
	args = append(args, arg...)
	return args
}

// newModule creates a zeroperl wasm2go module with a WASI host layer wired to
// the provided I/O adapter, filesystem mounts, and optional writable host
// directories. It calls X_initialize on the module to set up memory and stack
// but does not evaluate any Perl script.
func newModule(guestIO GuestIO, rootFS fs.FS, workFS fs.FS, writableDirs []string) (*wasm2go.Module, *wasiState, error) {
	mounts := []mountEntry{
		{guestPath: "/", root: rootFS, writable: false},
		{guestPath: "/dev", root: devNullFS{}, writable: false},
	}
	if workFS != nil {
		mounts = append(mounts, mountEntry{guestPath: "/work", root: workFS, writable: false})
	}
	for _, dir := range writableDirs {
		mounts = append(mounts, mountEntry{guestPath: dir, root: os.DirFS(dir), writable: true, hostRoot: dir})
	}

	ws := &wasiState{}
	mod := wasm2go.New(ws, ws)
	initWASIState(ws, mod, guestIO, mounts)
	ws.trace = os.Getenv("EXIFTOOL_WASI_TRACE") == "1"

	mod.X_initialize()

	return mod, ws, nil
}

// initModule calls Xzeroperl_init on the module and converts any non-zero
// return or proc_exit panic into a Go error. On failure the provided pipe
// closers are released and the caller should not attempt to use them. On
// success the caller retains ownership of all resources.
func initModule(mod *wasm2go.Module, sio *serverIO) error {
	err := func() (initErr error) {
		defer func() {
			if r := recover(); r != nil {
				if ep, ok := r.(exitPanic); ok {
					if ep.code != 0 {
						_ = closeAll(sio.stdinR, sio.stdoutW)
						initErr = fmt.Errorf("zeroperl_init exited with code %d", ep.code)
					}
				} else {
					initErr = fmt.Errorf("zeroperl_init panic: %v", r)
				}
			}
		}()
		rc := mod.Xzeroperl_init()
		if rc != 0 {
			_ = closeAll(sio.stdinR, sio.stdoutW)
			return fmt.Errorf("zeroperl_init returned %d", rc)
		}
		return nil
	}()
	return err
}

// evalModule initialises the Perl interpreter inside the module, loads the
// ExifTool script into guest memory, and evaluates it with the given
// arguments. When the guest calls proc_exit(0) the captured stdout content is
// returned; a non-zero exit code produces an error wrapping any stderr output.
//
// The caller is responsible for recovering the exitPanic that proc_exit
// produces. In single-shot paths this function is called directly; in Server
// mode the eval runs in a background goroutine.
//
// Note: this function calls Xzeroperl_init internally, which is fine for the
// single-shot Command/Run path. The Server path in server.go calls initModule
// separately and then invokes Xzeroperl_eval directly (bypassing this
// function) to keep the interpreter alive across multiple commands.
func evalModule(mod *wasm2go.Module, ws *wasiState, args ...string) (result []byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			if ep, ok := r.(exitPanic); ok {
				if ep.code == 0 {
					if dio, ok := ws.guestIO.(*DirectIO); ok {
						result = append([]byte(nil), dio.StdoutB.Bytes()...)
					}
					return
				}
				if ep.code != 0 {
					stderrStr := ""
					if dio, ok := ws.guestIO.(*DirectIO); ok {
						stderrStr = dio.StderrB.String()
					}
					err = fmt.Errorf("exiftool exited with code %d\nstderr: %s", ep.code, stderrStr)
				}
			} else {
				panic(r)
			}
		}
	}()

	rc := mod.Xzeroperl_init()
	if rc != 0 {
		return nil, fmt.Errorf("zeroperl_init returned %d", rc)
	}

	mem := ws.mem()
	wrapper := scriptPreamble + string(exiftoolScript)
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

	mod.Xzeroperl_eval(scriptPtr, 1, int32(len(args)), argvPtr)

	if dio, ok := ws.guestIO.(*DirectIO); ok {
		return append([]byte(nil), dio.StdoutB.Bytes()...), nil
	}
	return nil, nil
}

// Run executes a single ExifTool invocation with the embedded Perl stdlib as
// the only visible filesystem. workFS is mounted read-only at /work inside the
// sandbox, so pass guest paths such as "/work/photo.jpg" in args. Any stderr
// output from ExifTool is returned as an error.
func Run(ctx context.Context, workFS fs.FS, args ...string) (out []byte, err error) {
	guestIO := NewDirectIO(nil)
	mod, ws, err := newModule(guestIO, perlFS(), workFS, nil)
	if err != nil {
		return nil, err
	}
	// mod is stored inside ws; the eval functions access it through ws methods.
	_ = mod
	out, err = evalModule(mod, ws, args...)
	if err != nil {
		return out, err
	}
	if dio, ok := ws.guestIO.(*DirectIO); ok && dio.StderrB.Len() > 0 {
		return out, fmt.Errorf("exiftool stderr: %s", dio.StderrB.String())
	}
	return out, nil
}

// RunDebug is like [Run] but prints ExifTool's stderr to the host's stderr
// instead of returning it as an error. Useful for interactive debugging.
func RunDebug(ctx context.Context, workFS fs.FS, args ...string) (out []byte, err error) {
	guestIO := NewDirectIO(nil)
	mod, ws, err := newModule(guestIO, perlFS(), workFS, nil)
	if err != nil {
		return nil, err
	}
	// mod is stored inside ws; the eval functions access it through ws methods.
	_ = mod
	out, err = evalModule(mod, ws, args...)
	if dio, ok := ws.guestIO.(*DirectIO); ok && dio.StderrB.Len() > 0 {
		fmt.Fprintf(os.Stderr, "STDERR: %s\n", dio.StderrB.String())
	}
	return out, err
}
