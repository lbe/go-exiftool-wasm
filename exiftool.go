package exiftool

import (
	"crypto/rand"
	"embed"
	"encoding/binary"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/lbe/cfsread"
	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasm2go-wasi-host"
)

// perlFSRoot holds the embedded perl-wasi-prefix tree (LZ4-compressed on disk).
// Use [perlFS] to obtain an fs.FS with transparent decompression.
//
//go:embed all:embed/perl-wasi-prefix
var perlFSRoot embed.FS

var (
	perlCachedFS     *cachedFS
	perlCachedFSOnce sync.Once
)

const exiftoolScriptPath = "/bin/exiftool"

// Guest mount contract: the writable host working directory is always preopened at
// hostWorkDir, never at guest root (/). Perl preamble chdirs to hostWorkDir before
// ExifTool runs so relative paths resolve against that mount instead of /.
const hostWorkDir = "/host"

// exiftoolEvalWrapper executes the embedded /bin/exiftool script via do().
// It prepares autoflush, script name, @INC, and chdir to hostWorkDir for the perl-wasi-prefix tree.
const exiftoolEvalWrapper = "BEGIN { my $old = select(STDOUT); $| = 1; select(STDERR); $| = 1; select($old); chdir '" + hostWorkDir + "' or die $!; unshift @INC, '/lib/perl5', '/lib/perl5/wasm32-wasi'; $0 = '/bin/exiftool'; } my $ok = do '" + exiftoolScriptPath + "'; die $@ if $@; die $! if !defined $ok;\n"

// devNullFS is a read-only fs.FS mounted at /dev via wasihost.WithReadOnlyFS.
// It exposes a synthetic "null" file so guest opens of /dev/null succeed.
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

// commandArgs builds the full ExifTool argument list by prepending the
// package-level [Arg1] and [Config] variables and appending a UTF-8 charset
// flag, followed by the caller-supplied args.
func commandArgs(arg []string) []string {
	args := packageArgs()
	args = append(args, "-charset", "filename=utf8")
	args = append(args, arg...)
	return args
}

// packageArgs returns argv prefix from package-level [Arg1] and [Config].
func packageArgs() []string {
	var args []string
	if Arg1 != "" {
		args = append(args, Arg1)
	}
	if Config != "" {
		args = append(args, "-config", Config)
	}
	return args
}

// hostDirPreopenGuestPaths returns guest-side absolute path spellings that must map
// to the same host directory preopen. filepath.EvalSymlinks may resolve hostDir to a
// different spelling (for example /var vs /private/var on macOS); every spelling
// needs a wasihost.WithHostDirectoryPreopen alias so WASI path_open resolves
// through the same writable mount.
func hostDirPreopenGuestPaths(hostDir string) []string {
	paths := []string{hostDir}
	symlinkResolved, err := filepath.EvalSymlinks(hostDir)
	if err != nil || symlinkResolved == hostDir {
		return paths
	}
	return append(paths, symlinkResolved)
}

// registerHostDirPreopenAliases adds a writable preopen for every spelling
// returned by [hostDirPreopenGuestPaths], each via wasihost.WithHostDirectoryPreopen.
func registerHostDirPreopenAliases(moduleCfg *wasihost.ModuleConfig, hostDir string) *wasihost.ModuleConfig {
	for _, guestPath := range hostDirPreopenGuestPaths(hostDir) {
		moduleCfg = moduleCfg.WithHostDirectoryPreopen(guestPath, hostDir)
	}
	return moduleCfg
}

// buildModuleConfig assembles a wasihost.ModuleConfig for a zeroperl guest.
//
// Mount layout:
//   - [hostWorkDir]: primary writable preopen for host cwd (never guest /)
//   - /lib, /bin: read-only FS mounts (wasihost.WithReadOnlyFS) over embedded Perl tree
//   - /dev: synthetic /dev/null (read-only FS)
//   - /work: optional read-only workFS
//   - host cwd aliases, os.TempDir, and operand dirs: writable preopens via registerHostDirPreopenAliases
//
// Also enables wall/nano clocks, nanosleep, and crypto/rand for WASI syscalls.
func buildModuleConfig(cwd string, libFS, binFS fs.FS, workFS fs.FS, writableDirs []string) *wasihost.ModuleConfig {
	moduleCfg := wasihost.NewModuleConfig().
		WithReadOnlyFS("/lib", libFS).
		WithReadOnlyFS("/bin", binFS).
		WithHostDirectoryPreopen(hostWorkDir, cwd).
		WithReadOnlyFS("/dev", devNullFS{}).
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithRandSource(rand.Reader)

	moduleCfg = registerHostDirPreopenAliases(moduleCfg, cwd)
	if workFS != nil {
		moduleCfg = moduleCfg.WithReadOnlyFS("/work", workFS)
	}
	for _, dir := range writableDirs {
		moduleCfg = registerHostDirPreopenAliases(moduleCfg, dir)
	}
	return moduleCfg
}

// newModule creates a zeroperl module using the process working directory for
// the /host preopen. Prefer [newModuleAt] when cwd is already known.
func newModule(gio guestIO, workFS fs.FS, writableDirs []string) (*wasm2go.Module, *wasiState, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, nil, fmt.Errorf("exiftool: getwd: %w", err)
	}
	return newModuleAt(gio, cwd, workFS, writableDirs)
}

// newModuleAt is like [newModule] but uses the supplied cwd for the /host
// preopen so it matches operand resolution in [commandEvalModule].
func newModuleAt(gio guestIO, cwd string, workFS fs.FS, writableDirs []string) (*wasm2go.Module, *wasiState, error) {
	cwd = filepath.Clean(cwd)
	libFS, err := fs.Sub(perlFS(), "lib")
	if err != nil {
		return nil, nil, fmt.Errorf("exiftool: sub lib: %w", err)
	}
	binFS, err := fs.Sub(perlFS(), "bin")
	if err != nil {
		return nil, nil, fmt.Errorf("exiftool: sub bin: %w", err)
	}

	ws := &wasiState{}
	mod := wasm2go.New(ws, ws)
	initWASIState(ws, mod, gio, buildModuleConfig(cwd, libFS, binFS, workFS, writableDirs))

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
// proc_exit panics are recovered here as exitPanic (see wasiState.Xproc_exit).
// The Server path in server.go calls initModule separately and invokes
// Xzeroperl_eval in a background goroutine with its own recover (bypassing
// this function) so the interpreter stays alive across multiple commands.
//
// Note: this function calls Xzeroperl_init internally, which is appropriate for
// the single-shot Command path only.
func evalModule(mod *wasm2go.Module, ws *wasiState, args ...string) (result []byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			if ep, ok := r.(exitPanic); ok {
				if ep.code == 0 {
					if dio, ok := ws.guestIO.(*directIO); ok {
						result = append([]byte(nil), dio.StdoutB.Bytes()...)
					}
					return
				}
				if ep.code != 0 {
					result = guestStdoutOnExit(ws.guestIO)
					stderrStr := ""
					if dio, ok := ws.guestIO.(*directIO); ok {
						stderrStr = dio.StderrB.String()
					}
					err = &ExitError{
						Code: int(ep.code),
						Msg:  fmt.Sprintf("exiftool exited with code %d\nstderr: %s", ep.code, stderrStr),
					}
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

	if dio, ok := ws.guestIO.(*directIO); ok {
		return append([]byte(nil), dio.StdoutB.Bytes()...), nil
	}
	return nil, nil
}
