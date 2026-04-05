package exiftool

import (
	"bytes"
	"context"
	"embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/experimental"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
	"github.com/tetratelabs/wazero/sys"
)

//go:embed embed/zeroperl.wasm
var wasmBinary []byte

//go:embed all:embed/perl-wasi-prefix
var perlFSRoot embed.FS

//go:embed embed/exiftool.min.pl
var exiftoolScript []byte

const scriptPreamble = "use IO::Handle; STDOUT->autoflush(1); STDERR->autoflush(1);\n"

const (
	runtimeModeEnv      = "GO_EXIFTOOL_WAZERO_RUNTIME_MODE"
	runtimeDebugInfoEnv = "GO_EXIFTOOL_WAZERO_DEBUG_INFO"
	runtimeWorkersEnv   = "GO_EXIFTOOL_WAZERO_COMPILATION_WORKERS"
)

type runtimeConfigKey struct {
	cacheDir           string
	mode               string
	debugInfoEnabled   bool
	compilationWorkers int
}

var (
	runtimeConfigs sync.Map
	cachedPerlFS   = sync.OnceValue(func() fs.FS {
		sub, err := fs.Sub(perlFSRoot, "embed/perl-wasi-prefix")
		if err != nil {
			panic("exiftool: embedded perl filesystem unavailable: " + err.Error())
		}
		return sub
	})
	cachedDefaultRootFS = sync.OnceValue(func() fs.FS {
		return &overlayFS{layers: []fs.FS{perlFS(), os.DirFS(".")}}
	})
	cachedWrappedExiftoolScript = sync.OnceValue(func() []byte {
		wrapped := make([]byte, len(scriptPreamble)+len(exiftoolScript))
		copy(wrapped, scriptPreamble)
		copy(wrapped[len(scriptPreamble):], exiftoolScript)
		return wrapped
	})
)

func runtimeConfigMode() string {
	switch mode := os.Getenv(runtimeModeEnv); mode {
	case "compiler", "interpreter":
		return mode
	default:
		return "compiler"
	}
}

func runtimeDebugInfoEnabled() bool {
	return os.Getenv(runtimeDebugInfoEnv) == "1"
}

func runtimeConfigKeyForProcess() runtimeConfigKey {
	return runtimeConfigKey{
		cacheDir:           resolvedCacheDir(),
		mode:               runtimeConfigMode(),
		debugInfoEnabled:   runtimeDebugInfoEnabled(),
		compilationWorkers: runtimeCompilationWorkers(),
	}
}

func runtimeCompilationWorkers() int {
	if v := os.Getenv(runtimeWorkersEnv); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return max(runtime.GOMAXPROCS(0)/2, 1)
}

func buildRuntimeConfig(key runtimeConfigKey) wazero.RuntimeConfig {
	var config wazero.RuntimeConfig
	switch key.mode {
	case "interpreter":
		config = wazero.NewRuntimeConfigInterpreter()
	default:
		config = wazero.NewRuntimeConfigCompiler()
	}
	config = config.WithDebugInfoEnabled(key.debugInfoEnabled)

	cache := wazero.NewCompilationCache()
	if key.cacheDir != "" {
		persistentCache, err := wazero.NewCompilationCacheWithDir(filepath.Join(key.cacheDir, "wazero"))
		if err == nil {
			cache = persistentCache
		}
	}
	return config.WithCompilationCache(cache)
}

// overlayFS implements [fs.FS] by opening name on each layer in order until one succeeds.
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

// devNullFS provides a minimal /dev tree ("." listing and file "null") for WASI mounts
// without importing [testing/fstest].
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

type devNullDir struct{ read bool }

func (*devNullDir) Stat() (fs.FileInfo, error) { return devNullDirInfo{}, nil }
func (*devNullDir) Read([]byte) (int, error)   { return 0, io.EOF }
func (*devNullDir) Close() error               { return nil }

func (d *devNullDir) ReadDir(n int) ([]fs.DirEntry, error) {
	if d.read {
		return nil, io.EOF
	}
	d.read = true
	info := devNullFileInfo{}
	return []fs.DirEntry{fs.FileInfoToDirEntry(info)}, nil
}

type devNullDirInfo struct{}

func (devNullDirInfo) Name() string       { return "." }
func (devNullDirInfo) Size() int64        { return 0 }
func (devNullDirInfo) Mode() fs.FileMode  { return fs.ModeDir | 0o555 }
func (devNullDirInfo) ModTime() time.Time { return time.Time{} }
func (devNullDirInfo) IsDir() bool        { return true }
func (devNullDirInfo) Sys() any           { return nil }

type devNullFile struct{}

func (*devNullFile) Stat() (fs.FileInfo, error) { return devNullFileInfo{}, nil }
func (*devNullFile) Read([]byte) (int, error)   { return 0, io.EOF }
func (*devNullFile) Close() error               { return nil }

type devNullFileInfo struct{}

func (devNullFileInfo) Name() string       { return "null" }
func (devNullFileInfo) Size() int64        { return 0 }
func (devNullFileInfo) Mode() fs.FileMode  { return 0 }
func (devNullFileInfo) ModTime() time.Time { return time.Time{} }
func (devNullFileInfo) IsDir() bool        { return false }
func (devNullFileInfo) Sys() any           { return nil }

// perlFS returns the embedded Perl tree (stdlib + wasm32-wasi) as an [fs.FS]. It panics
// if the embed path is wrong; that indicates a broken build, not a runtime user error.
func perlFS() fs.FS {
	return cachedPerlFS()
}

// defaultRootFS returns an overlay filesystem with embedded Perl libraries and
// the host's current working directory. This allows Command() to access host
// filesystem paths. Be aware that files accessible from the process CWD will
// be visible to the WASM sandbox.
func defaultRootFS() fs.FS {
	return cachedDefaultRootFS()
}

// newRuntime builds a wazero runtime with the zeroperl env import stub and WASI snapshot1.
func newRuntime(ctx context.Context) (wazero.Runtime, error) {
	key := runtimeConfigKeyForProcess()
	runtimeConfigAny, _ := runtimeConfigs.LoadOrStore(key, buildRuntimeConfig(key))
	runtimeConfig := runtimeConfigAny.(wazero.RuntimeConfig)
	r := wazero.NewRuntimeWithConfig(ctx, runtimeConfig)
	var err error
	_, err = r.NewHostModuleBuilder("env").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, m api.Module, funcID, argc, argv uint32) uint32 {
			return 0
		}).
		Export("call_host_function").
		Instantiate(ctx)
	if err != nil {
		if closeErr := r.Close(ctx); closeErr != nil {
			return nil, fmt.Errorf("failed to instantiate env module: %w (close error: %v)", err, closeErr)
		}
		return nil, fmt.Errorf("failed to instantiate env module: %w", err)
	}
	wasi_snapshot_preview1.MustInstantiate(ctx, r)
	return r, nil
}

func compileContext(ctx context.Context) context.Context {
	return experimental.WithCompilationWorkers(ctx, runtimeCompilationWorkers())
}

// commandArgs builds argv for [Command]: optional [Arg1], optional "-config" [Config],
// "-charset filename=utf8", then caller arguments.
func commandArgs(arg []string) []string {
	capHint := len(arg) + 2
	if Arg1 != "" {
		capHint++
	}
	if Config != "" {
		capHint += 2
	}
	args := make([]string, 0, capHint)
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

func mallocGuest(ctx context.Context, mallocFn api.Function, size int) (uint32, error) {
	res, err := mallocFn.Call(ctx, uint64(size))
	if err != nil {
		return 0, fmt.Errorf("malloc failed for %d bytes: %w", size, err)
	}
	return uint32(res[0]), nil
}

func freeGuest(ctx context.Context, freeFn api.Function, ptr uint32) error {
	_, err := freeFn.Call(ctx, uint64(ptr))
	return err
}

func writeGuestCString(ctx context.Context, mallocFn, freeFn api.Function, mem api.Memory, s string) (uint32, error) {
	ptr, err := mallocGuest(ctx, mallocFn, len(s)+1)
	if err != nil {
		return 0, err
	}
	if !mem.WriteString(ptr, s) || !mem.WriteByte(ptr+uint32(len(s)), 0) {
		if freeErr := freeGuest(ctx, freeFn, ptr); freeErr != nil {
			return 0, fmt.Errorf("failed to write %d-byte string at address %d (free also failed: %w)", len(s), ptr, freeErr)
		}
		return 0, fmt.Errorf("failed to write %d-byte string at address %d", len(s), ptr)
	}
	return ptr, nil
}

func writeGuestNULTerminatedBytes(ctx context.Context, mallocFn, freeFn api.Function, mem api.Memory, b []byte) (uint32, error) {
	ptr, err := mallocGuest(ctx, mallocFn, len(b)+1)
	if err != nil {
		return 0, err
	}
	if !mem.Write(ptr, b) || !mem.WriteByte(ptr+uint32(len(b)), 0) {
		if freeErr := freeGuest(ctx, freeFn, ptr); freeErr != nil {
			return 0, fmt.Errorf("failed to write %d bytes at address %d (free also failed: %w)", len(b), ptr, freeErr)
		}
		return 0, fmt.Errorf("failed to write %d bytes at address %d", len(b), ptr)
	}
	return ptr, nil
}

func alignGuestOffset(offset, align uint32) uint32 {
	mask := align - 1
	return (offset + mask) &^ mask
}

func packGuestEvalData(ctx context.Context, mallocFn, freeFn api.Function, mem api.Memory, script []byte, args []string) (scriptPtr, argvPtr, allocPtr uint32, err error) {
	offset := uint32(0)
	scriptOff := offset
	offset += uint32(len(script) + 1)

	var argvOff uint32
	if len(args) > 0 {
		offset = alignGuestOffset(offset, 4)
		argvOff = offset
		offset += uint32(len(args) * 4)
	}

	argOffs := make([]uint32, len(args))
	for i, arg := range args {
		argOffs[i] = offset
		offset += uint32(len(arg) + 1)
	}

	allocPtr, err = mallocGuest(ctx, mallocFn, int(offset))
	if err != nil {
		return 0, 0, 0, err
	}

	fail := func(msg string, args ...any) (uint32, uint32, uint32, error) {
		if freeErr := freeGuest(ctx, freeFn, allocPtr); freeErr != nil {
			return 0, 0, 0, fmt.Errorf(msg+" (free also failed: %w)", append(args, freeErr)...)
		}
		return 0, 0, 0, fmt.Errorf(msg, args...)
	}

	if !mem.Write(allocPtr+scriptOff, script) || !mem.WriteByte(allocPtr+scriptOff+uint32(len(script)), 0) {
		return fail("failed to write script into guest memory")
	}

	for i, arg := range args {
		argPtr := allocPtr + argOffs[i]
		if !mem.WriteString(argPtr, arg) || !mem.WriteByte(argPtr+uint32(len(arg)), 0) {
			return fail("failed to write argv[%d] into guest memory", i)
		}
		if len(args) > 0 && !mem.WriteUint32Le(allocPtr+argvOff+uint32(i*4), argPtr) {
			return fail("failed to write argv pointer %d into guest memory", i)
		}
	}

	scriptPtr = allocPtr + scriptOff
	if len(args) > 0 {
		argvPtr = allocPtr + argvOff
	}
	return scriptPtr, argvPtr, allocPtr, nil
}

// evalModule instantiates a WASM module, runs zeroperl_init, copies the embedded ExifTool
// script and argv into guest memory, and calls zeroperl_eval. Exit code 0 from Perl is
// treated as success ([sys.ExitError]).
func evalModule(ctx context.Context, r wazero.Runtime, compiled wazero.CompiledModule,
	rootFS fs.FS, workFS fs.FS, writableDirs []string, stdin io.Reader, stdout, stderr *bytes.Buffer, args ...string) (result []byte, err error) {

	devFS := devNullFS{}
	if stdin == nil {
		stdin = bytes.NewReader(nil)
	}

	fsConfig := wazero.NewFSConfig().
		WithFSMount(rootFS, "/").
		WithFSMount(devFS, "/dev")
	if workFS != nil {
		fsConfig = fsConfig.WithFSMount(workFS, "/work")
	}
	for _, dir := range writableDirs {
		fsConfig = fsConfig.WithDirMount(dir, dir)
	}

	config := wazero.NewModuleConfig().
		WithStdout(stdout).
		WithStderr(stderr).
		WithStdin(stdin).
		WithName("zeroperl").
		WithArgs("zeroperl").
		WithStartFunctions().
		WithEnv("PERL5LIB", "/lib/5.42.0:/lib/5.42.0/wasm32-wasi").
		WithFSConfig(fsConfig)

	mod, err := r.InstantiateModule(ctx, compiled, config)
	if err != nil {
		return nil, fmt.Errorf("wasm instantiate failed: %w", err)
	}
	defer func() { _ = mod.Close(ctx) }()

	initFn := mod.ExportedFunction("zeroperl_init")
	if initFn == nil {
		return nil, fmt.Errorf("zeroperl_init not found")
	}
	results, err := initFn.Call(ctx)
	if err != nil {
		return nil, fmt.Errorf("zeroperl_init failed: %w", err)
	}
	if results[0] != 0 {
		return nil, fmt.Errorf("zeroperl_init returned %d", results[0])
	}

	mallocFn := mod.ExportedFunction("malloc")
	freeFn := mod.ExportedFunction("free")
	mem := mod.Memory()
	if mallocFn == nil || freeFn == nil || mem == nil {
		return nil, fmt.Errorf("required wasm exports not found")
	}

	scriptPtr, argvPtr, allocPtr, err := packGuestEvalData(ctx, mallocFn, freeFn, mem, cachedWrappedExiftoolScript(), args)
	if err != nil {
		return nil, fmt.Errorf("failed to allocate script memory: %w", err)
	}
	defer func() {
		_ = freeGuest(ctx, freeFn, allocPtr)
	}()

	evalFn := mod.ExportedFunction("zeroperl_eval")
	if evalFn == nil {
		return nil, fmt.Errorf("zeroperl_eval not found")
	}

	_, err = evalFn.Call(ctx, uint64(scriptPtr), uint64(1), uint64(len(args)), uint64(argvPtr))
	if err != nil {
		var exitErr *sys.ExitError
		if errors.As(err, &exitErr) {
			if exitErr.ExitCode() != 0 {
				return stdout.Bytes(), fmt.Errorf("exiftool exited with code %d\nstderr: %s",
					exitErr.ExitCode(), stderr.String())
			}
		} else {
			return stdout.Bytes(), fmt.Errorf("wasm eval failed: %w\nstderr: %s",
				err, stderr.String())
		}
	}

	return stdout.Bytes(), nil
}

// Run executes ExifTool once with embedded Perl at "/" and workFS (if non-nil) mounted
// at "/work". Pass file paths in args as "/work/..." for files that live in workFS.
// Any non-empty stderr after a successful eval is reported as an error.
func Run(ctx context.Context, workFS fs.FS, args ...string) (out []byte, err error) {
	var stderr bytes.Buffer
	r, err := newRuntime(ctx)
	if err != nil {
		return nil, err
	}
	defer func() {
		if closeErr := r.Close(ctx); closeErr != nil && err == nil {
			err = closeErr
		}
	}()
	compiled, err := r.CompileModule(compileContext(ctx), wasmBinary)
	if err != nil {
		return nil, fmt.Errorf("failed to compile wasm: %w", err)
	}
	var stdout bytes.Buffer
	out, err = evalModule(ctx, r, compiled, perlFS(), workFS, nil, nil, &stdout, &stderr, args...)
	if err != nil {
		return out, err
	}
	if stderr.Len() > 0 {
		return out, fmt.Errorf("exiftool stderr: %s", stderr.String())
	}
	return out, nil
}

// RunDebug is like [Run] but prints stderr to the host process's standard error and
// does not treat stderr alone as a failure after a successful WASM eval.
func RunDebug(ctx context.Context, workFS fs.FS, args ...string) (out []byte, err error) {
	var stderr bytes.Buffer
	r, err := newRuntime(ctx)
	if err != nil {
		return nil, err
	}
	defer func() {
		if closeErr := r.Close(ctx); closeErr != nil && err == nil {
			err = closeErr
		}
	}()
	compiled, err := r.CompileModule(compileContext(ctx), wasmBinary)
	if err != nil {
		return nil, fmt.Errorf("failed to compile wasm: %w", err)
	}
	var stdout bytes.Buffer
	out, err = evalModule(ctx, r, compiled, perlFS(), workFS, nil, nil, &stdout, &stderr, args...)
	if stderr.Len() > 0 {
		fmt.Fprintf(os.Stderr, "STDERR: %s\n", stderr.String())
	}
	return out, err
}
