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
	"time"

	wasm2go "github.com/lbe/go-exiftool/zeroperl"
)

//go:embed all:embed/perl-wasi-prefix
var perlFSRoot embed.FS

//go:embed embed/exiftool.min.pl
var exiftoolScript []byte

const scriptPreamble = "use IO::Handle; STDOUT->autoflush(1); STDERR->autoflush(1);\n"

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
	return []fs.DirEntry{fs.FileInfoToDirEntry(devNullFileInfo{})}, nil
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

func perlFS() fs.FS {
	sub, err := fs.Sub(perlFSRoot, "embed/perl-wasi-prefix")
	if err != nil {
		panic("exiftool: embedded perl filesystem unavailable: " + err.Error())
	}
	return sub
}

func defaultRootFS() fs.FS {
	return &overlayFS{layers: []fs.FS{perlFS(), os.DirFS(".")}}
}

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

func newModule(guestIO GuestIO, rootFS fs.FS, workFS fs.FS, writableDirs []string) (*wasm2go.Module, *wasiState, error) {
	mounts := []mountEntry{
		{guestPath: "/", root: rootFS, writable: false},
		{guestPath: "/dev", root: devNullFS{}, writable: false},
	}
	if workFS != nil {
		mounts = append(mounts, mountEntry{guestPath: "/work", root: workFS, writable: false})
	}
	for _, dir := range writableDirs {
		mounts = append(mounts, mountEntry{guestPath: dir, root: os.DirFS(dir), writable: true})
	}

	ws := &wasiState{}
	mod := wasm2go.New(ws, ws)
	ws.module = mod
	ws.memory = moduleMemory(mod)
	ws.mounts = mounts
	ws.guestIO = guestIO
	ws.fds = make([]fdEntry, 3, 8)
	ws.fds[0] = fdEntry{fdType: fdCharDev, path: "stdin"}
	ws.fds[1] = fdEntry{fdType: fdCharDev, path: "stdout"}
	ws.fds[2] = fdEntry{fdType: fdCharDev, path: "stderr"}
	for _, m := range mounts {
		ws.preopens = append(ws.preopens, fdEntry{path: m.guestPath, fdType: fdDir})
	}

	mod.X_initialize()

	return mod, ws, nil
}

func evalModule(mod *wasm2go.Module, ws *wasiState, args ...string) (result []byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			if ep, ok := r.(exitPanic); ok {
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
		return dio.StdoutB.Bytes(), nil
	}
	return nil, nil
}

func Run(ctx context.Context, workFS fs.FS, args ...string) (out []byte, err error) {
	guestIO := NewDirectIO(nil)
	mod, ws, err := newModule(guestIO, perlFS(), workFS, nil)
	if err != nil {
		return nil, err
	}
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

func RunDebug(ctx context.Context, workFS fs.FS, args ...string) (out []byte, err error) {
	guestIO := NewDirectIO(nil)
	mod, ws, err := newModule(guestIO, perlFS(), workFS, nil)
	if err != nil {
		return nil, err
	}
	_ = mod
	out, err = evalModule(mod, ws, args...)
	if dio, ok := ws.guestIO.(*DirectIO); ok && dio.StderrB.Len() > 0 {
		fmt.Fprintf(os.Stderr, "STDERR: %s\n", dio.StderrB.String())
	}
	return out, err
}
