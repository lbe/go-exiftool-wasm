package exiftool

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/binary"
	"fmt"
	"io"
	"io/fs"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/lbe/cfsread"
	wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasm2go-wasi-host"
)

// perlFSRoot is the embedded perl-wasi-prefix tree. Its files are LZ4-compressed;
// read them through [perlFS], which decompresses them.
//
//go:embed all:embed/perl-wasi-prefix
var perlFSRoot embed.FS

// perlCachedFS is the cachedFS that perlFS creates once per process.
var (
	perlCachedFS     *cachedFS
	perlCachedFSOnce sync.Once
)

// exiftoolScriptPath is the guest path of the embedded exiftool script.
const exiftoolScriptPath = "/bin/exiftool"

// exiftoolEvalWrapper returns the Perl program that runs ExifTool in the guest.
// It turns on autoflush for STDOUT and STDERR, changes to cwd, adds the embedded
// library directories to @INC, sets $0, and runs exiftoolScriptPath with do. It
// dies if the script fails to compile or cannot be read.
func exiftoolEvalWrapper(cwd string) string {
	return "BEGIN { my $old = select(STDOUT); $| = 1; select(STDERR); $| = 1; select($old); chdir " + perlQuote(cwd) + " or die $!; unshift @INC, '/lib/perl5', '/lib/perl5/wasm32-wasi'; $0 = '/bin/exiftool'; } my $ok = do '" + exiftoolScriptPath + "'; die $@ if $@; die $! if !defined $ok;\n"
}

// perlQuote returns s as a Perl single-quoted string literal.
func perlQuote(s string) string {
	return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(s) + "'"
}

// devNullFS is the read-only file system mounted at /dev. It holds one empty
// file, null, so the guest can open /dev/null.
type devNullFS struct{}

// Open returns the root directory for ".", the null file for "null", and
// fs.ErrNotExist for any other name.
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

// devNullDir is the root directory of devNullFS. It implements fs.ReadDirFile.
type devNullDir struct{ read bool }

func (*devNullDir) Stat() (fs.FileInfo, error) { return devNullDirInfo{}, nil }
func (*devNullDir) Read([]byte) (int, error)   { return 0, io.EOF }
func (*devNullDir) Close() error               { return nil }

// ReadDir returns the null entry on the first call and io.EOF after that. It
// ignores n.
func (d *devNullDir) ReadDir(n int) ([]fs.DirEntry, error) {
	if d.read {
		return nil, io.EOF
	}
	d.read = true
	return []fs.DirEntry{fs.FileInfoToDirEntry(devNullFileInfo{})}, nil
}

// devNullDirInfo describes the devNullFS root directory.
type devNullDirInfo struct{}

func (devNullDirInfo) Name() string       { return "." }
func (devNullDirInfo) Size() int64        { return 0 }
func (devNullDirInfo) Mode() fs.FileMode  { return fs.ModeDir | 0o555 }
func (devNullDirInfo) ModTime() time.Time { return time.Time{} }
func (devNullDirInfo) IsDir() bool        { return true }
func (devNullDirInfo) Sys() any           { return nil }

// devNullFile is the open /dev/null file. Reads return io.EOF.
type devNullFile struct{}

func (*devNullFile) Stat() (fs.FileInfo, error) { return devNullFileInfo{}, nil }
func (*devNullFile) Read([]byte) (int, error)   { return 0, io.EOF }
func (*devNullFile) Close() error               { return nil }

// devNullFileInfo describes /dev/null.
type devNullFileInfo struct{}

func (devNullFileInfo) Name() string       { return "null" }
func (devNullFileInfo) Size() int64        { return 0 }
func (devNullFileInfo) Mode() fs.FileMode  { return 0 }
func (devNullFileInfo) ModTime() time.Time { return time.Time{} }
func (devNullFileInfo) IsDir() bool        { return false }
func (devNullFileInfo) Sys() any           { return nil }

// perlFS returns the process-wide cachedFS over the embedded perl-wasi-prefix
// tree. The first call creates it with a 2000-entry LRU cache. cachedFS
// decompresses each LZ4 file on its first read and serves later reads from the
// cache. perlFS panics if the embedded tree is missing.
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

// commandArgs returns the argv for a one-shot command: [Arg1] and [Config] if
// set, then "-charset filename=utf8", then arg.
func commandArgs(arg []string) []string {
	args := packageArgs()
	args = append(args, "-charset", "filename=utf8")
	args = append(args, arg...)
	return args
}

// packageArgs returns the arguments that [Arg1] and [Config] contribute.
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

// guestRoot splits the host working directory cwd into the host directory that
// the guest's "/" preopen maps to and the guest path of cwd. On Linux, macOS and
// FreeBSD the host root is "/" and the guest path is cwd. On Windows the host
// root is the volume of cwd, such as `C:\` or `\\server\share\`, and the guest
// path is the rest of cwd with forward slashes, because the guest rejects paths
// that contain ':' or '\'.
func guestRoot(cwd string) (hostRoot, guestCwd string) {
	vol := filepath.VolumeName(cwd)
	return vol + string(filepath.Separator), filepath.ToSlash(cwd[len(vol):])
}

// buildModuleConfig returns the WASI configuration for a zeroperl guest. It
// mounts:
//   - "/": a writable preopen of hostRoot (see guestRoot); on Linux, macOS and
//     FreeBSD hostRoot is "/", so a guest path is the host path
//   - "/lib" and "/bin": libFS and binFS, read-only; they hide the host
//     directories with the same names
//   - "/dev": devNullFS, read-only
//   - "/work": workFS, read-only, if workFS is not nil
//
// It also enables the wall and monotonic clocks, nanosleep and crypto/rand.
func buildModuleConfig(hostRoot string, libFS, binFS fs.FS, workFS fs.FS) *wasihost.ModuleConfig {
	moduleCfg := wasihost.NewModuleConfig().
		WithReadOnlyFS("/lib", libFS).
		WithReadOnlyFS("/bin", binFS).
		WithHostDirectoryPreopen("/", hostRoot).
		WithReadOnlyFS("/dev", devNullFS{}).
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithRandSource(rand.Reader)

	if workFS != nil {
		moduleCfg = moduleCfg.WithReadOnlyFS("/work", workFS)
	}
	return moduleCfg
}

// newModuleAt creates and initializes a zeroperl module that uses gio for stdio.
// cwd is a host directory. Its Perl wrapper changes the guest to the guest path
// of cwd before ExifTool runs.
func newModuleAt(gio guestIO, cwd string, workFS fs.FS) (*wasm2go.Module, *wasiState, error) {
	hostRoot, guestCwd := guestRoot(filepath.Clean(cwd))
	libFS, err := fs.Sub(perlFS(), "lib")
	if err != nil {
		return nil, nil, fmt.Errorf("exiftool: sub lib: %w", err)
	}
	binFS, err := fs.Sub(perlFS(), "bin")
	if err != nil {
		return nil, nil, fmt.Errorf("exiftool: sub bin: %w", err)
	}

	ws := &wasiState{cwd: guestCwd, ctx: context.Background()}
	mod := wasm2go.New(ws, ws)
	initWASIState(ws, mod, gio, buildModuleConfig(hostRoot, libFS, binFS, workFS))

	mod.X_initialize()

	return mod, ws, nil
}

// initModule runs Xzeroperl_init and returns an error for a non-zero return, a
// non-zero proc_exit or any other panic. After a non-zero return or exit it has
// closed sio.stdinR and sio.stdoutW. The caller still owns everything else.
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

// evalModule runs Xzeroperl_init, then runs ExifTool with args through
// exiftoolEvalWrapper, and returns the stdout a directIO captured. The guest
// exits through proc_exit, which panics with exitPanic, and evalModule recovers
// it. Exit 0 returns stdout. A non-zero exit returns stdout and an *exitError
// whose Msg includes stderr. If ws.ctx is done during the run, it returns the
// stdout so far and ws.ctx.Err(). Any other panic propagates.
//
// Only the one-shot path uses evalModule. A Server calls initModule and runs
// Xzeroperl_eval in its own goroutine (see evaluateServerModule), so its
// interpreter stays alive between commands.
func evalModule(mod *wasm2go.Module, ws *wasiState, args ...string) (result []byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(cancelPanic); ok {
				result = guestStdoutOnExit(ws.guestIO)
				err = ws.ctx.Err()
				return
			}
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
					err = &exitError{
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

	if dio, ok := ws.guestIO.(*directIO); ok {
		return append([]byte(nil), dio.StdoutB.Bytes()...), nil
	}
	return nil, nil
}
