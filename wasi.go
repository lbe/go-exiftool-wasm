package exiftool

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"io"
	"io/fs"
	"os"
	"reflect"
	"sync"
	"time"
	"unsafe"

	wasm2go "github.com/lbe/go-exiftool/zeroperl"
)

const (
	wasiESuccess  uint32 = 0
	wasiEBadf     uint32 = 8
	wasiEExist    uint32 = 17
	wasiEInval    uint32 = 28
	wasiEIo       uint32 = 29
	wasiEIsdir    uint32 = 31
	wasiENoEnt    uint32 = 44
	wasiENoSys    uint32 = 52
	wasiENotDir   uint32 = 54
	wasiENotEmpty uint32 = 55
	wasiEROFS     uint32 = 66

	fdCharDev byte = 2
	fdDir     byte = 3
	fdFile    byte = 4
)

type exitPanic struct{ code int32 }

func (exitPanic) Error() string { return "proc_exit" }

type fdEntry struct {
	file    fsFile
	path    string
	fdType  byte
	offset  int64
	dirFile fs.ReadDirFile
	dirOff  int64
}

type fsFile interface {
	Read(p []byte) (int, error)
	Stat() (fs.FileInfo, error)
	Close() error
}

type mountEntry struct {
	guestPath string
	root      fs.FS
	writable  bool
}

type wasiState struct {
	module   *wasm2go.Module
	memory   []byte
	fds      []fdEntry
	fdsMu    sync.Mutex
	mounts   []mountEntry
	guestIO  GuestIO
	preopens []fdEntry
}

func moduleMemory(mod *wasm2go.Module) []byte {
	v := reflect.ValueOf(mod).Elem()
	f := v.FieldByName("memory")
	p := unsafe.Pointer(f.UnsafeAddr())
	return unsafe.Slice((*byte)(p), f.Len())
}

func newWASIState(mod *wasm2go.Module, guestIO GuestIO, mounts []mountEntry) *wasiState {
	ws := &wasiState{
		module:  mod,
		memory:  moduleMemory(mod),
		mounts:  mounts,
		guestIO: guestIO,
	}
	ws.fds = make([]fdEntry, 3, 8)
	ws.fds[0] = fdEntry{fdType: fdCharDev, path: "stdin"}
	ws.fds[1] = fdEntry{fdType: fdCharDev, path: "stdout"}
	ws.fds[2] = fdEntry{fdType: fdCharDev, path: "stderr"}
	for _, m := range mounts {
		ws.preopens = append(ws.preopens, fdEntry{path: m.guestPath, fdType: fdDir})
	}
	return ws
}

func (w *wasiState) mem() []byte { return w.memory }

func (w *wasiState) readString(ptr int32) string {
	if ptr == 0 {
		return ""
	}
	mem := w.mem()
	end := int32(bytes.IndexByte(mem[ptr:], 0))
	if end < 0 {
		return string(mem[ptr:])
	}
	return string(mem[ptr : ptr+end])
}

func (w *wasiState) allocFD() int32 {
	w.fdsMu.Lock()
	defer w.fdsMu.Unlock()
	for i := range w.fds {
		if w.fds[i].file == nil && w.fds[i].fdType == 0 && i >= 3 {
			return int32(i)
		}
	}
	idx := int32(len(w.fds))
	w.fds = append(w.fds, fdEntry{})
	return idx
}

func (w *wasiState) resolvePath(guestPath string) (*mountEntry, string) {
	var best *mountEntry
	var bestLen int
	var bestRel string
	for i := range w.mounts {
		m := &w.mounts[i]
		if m.guestPath == "/" {
			rel := guestPath
			for len(rel) > 0 && rel[0] == '/' {
				rel = rel[1:]
			}
			if len(m.guestPath) > bestLen {
				best = m
				bestLen = len(m.guestPath)
				bestRel = rel
			}
		}
	}
	return best, bestRel
}

func (w *wasiState) Xcall_host_function(v0, v1, v2 int32) int32 { return 0 }

func (w *wasiState) Xenviron_sizes_get(countPtr, bufSizePtr int32) int32 {
	env := []string{"PERL5LIB=/lib/5.42.0:/lib/5.42.0/wasm32-wasi"}
	mem := w.mem()
	binary.LittleEndian.PutUint32(mem[countPtr:], uint32(len(env)))
	var total uint32
	for _, e := range env {
		total += uint32(len(e)) + 1
	}
	binary.LittleEndian.PutUint32(mem[bufSizePtr:], total)
	return int32(wasiESuccess)
}

func (w *wasiState) Xenviron_get(envPtr, envBufPtr int32) int32 {
	env := []string{"PERL5LIB=/lib/5.42.0:/lib/5.42.0/wasm32-wasi"}
	mem := w.mem()
	bufOff := uint32(envBufPtr)
	for i, e := range env {
		binary.LittleEndian.PutUint32(mem[envPtr+int32(i*4):], bufOff)
		n := copy(mem[bufOff:], e)
		mem[bufOff+uint32(n)] = 0
		bufOff += uint32(n) + 1
	}
	return int32(wasiESuccess)
}

func (w *wasiState) Xclock_time_get(clockID int32, precision int64, resultPtr int32) int32 {
	mem := w.mem()
	binary.LittleEndian.PutUint64(mem[resultPtr:], uint64(time.Now().UnixNano()))
	return int32(wasiESuccess)
}

func (w *wasiState) Xrandom_get(bufPtr int32, bufLen int32) int32 {
	mem := w.mem()
	rand.Read(mem[bufPtr : bufPtr+bufLen])
	return int32(wasiESuccess)
}

func (w *wasiState) Xproc_exit(code int32) { panic(exitPanic{code: code}) }

func (w *wasiState) Xfd_prestat_get(fd int32, prestat int32) int32 {
	idx := fd - 3
	if idx < 0 || idx >= int32(len(w.preopens)) {
		return int32(wasiEBadf)
	}
	mem := w.mem()
	binary.LittleEndian.PutUint32(mem[prestat:], uint32(len(w.preopens[idx].path)))
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_prestat_dir_name(fd int32, pathPtr int32, pathLen int32) int32 {
	idx := fd - 3
	if idx < 0 || idx >= int32(len(w.preopens)) {
		return int32(wasiEBadf)
	}
	mem := w.mem()
	name := w.preopens[idx].path
	if int32(len(name)) > pathLen {
		name = name[:pathLen]
	}
	copy(mem[pathPtr:], name)
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_close(fd int32) int32 {
	w.fdsMu.Lock()
	defer w.fdsMu.Unlock()
	if fd < 0 || int(fd) >= len(w.fds) {
		return int32(wasiEBadf)
	}
	if w.fds[fd].file != nil {
		w.fds[fd].file.Close()
	}
	w.fds[fd] = fdEntry{}
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_read(fd int32, iovsPtr int32, iovsCount int32, nreadPtr int32) int32 {
	mem := w.mem()
	if fd == 0 {
		var total uint32
		for i := int32(0); i < iovsCount; i++ {
			off := iovsPtr + i*8
			bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
			bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
			if bufLen == 0 {
				continue
			}
			n, err := w.guestIO.ReadStdin(mem[bufPtr : bufPtr+bufLen])
			total += uint32(n)
			if err != nil {
				binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
				return int32(wasiESuccess)
			}
			if n < int(bufLen) {
				break
			}
		}
		binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
		return int32(wasiESuccess)
	}
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil {
		return int32(wasiEBadf)
	}
	var total uint32
	for i := int32(0); i < iovsCount; i++ {
		off := iovsPtr + i*8
		bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
		bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
		if bufLen == 0 {
			continue
		}
		n, err := entry.file.Read(mem[bufPtr : bufPtr+bufLen])
		total += uint32(n)
		if err != nil {
			binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
			return int32(wasiESuccess)
		}
	}
	binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_write(fd int32, iovsPtr int32, iovsCount int32, nwrittenPtr int32) int32 {
	mem := w.mem()
	if fd == 1 || fd == 2 {
		var total uint32
		for i := int32(0); i < iovsCount; i++ {
			off := iovsPtr + i*8
			bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
			bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
			data := mem[bufPtr : bufPtr+bufLen]
			var n int
			if fd == 1 {
				n, _ = w.guestIO.WriteStdout(data)
			} else {
				n, _ = w.guestIO.WriteStderr(data)
			}
			total += uint32(n)
		}
		binary.LittleEndian.PutUint32(mem[nwrittenPtr:], total)
		return int32(wasiESuccess)
	}
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil {
		return int32(wasiEBadf)
	}
	var total uint32
	for i := int32(0); i < iovsCount; i++ {
		off := iovsPtr + i*8
		bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
		bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
		f, ok := entry.file.(interface {
			WriteAt([]byte, int64) (int, error)
		})
		if ok {
			n, _ := f.WriteAt(mem[bufPtr:bufPtr+bufLen], entry.offset)
			entry.offset += int64(n)
			total += uint32(n)
		}
	}
	w.fds[fd] = entry
	binary.LittleEndian.PutUint32(mem[nwrittenPtr:], total)
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_seek(fd int32, offset int64, whence int32, newOffsetPtr int32) int32 {
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil {
		return int32(wasiEBadf)
	}
	s, ok := entry.file.(io.Seeker)
	if !ok {
		return int32(wasiEInval)
	}
	n, err := s.Seek(offset, int(whence))
	if err != nil {
		return int32(wasiEIo)
	}
	binary.LittleEndian.PutUint64(w.mem()[newOffsetPtr:], uint64(n))
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_tell(fd int32, offsetPtr int32) int32 {
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil {
		return int32(wasiEBadf)
	}
	s, ok := entry.file.(io.Seeker)
	if !ok {
		return int32(wasiEInval)
	}
	n, err := s.Seek(0, io.SeekCurrent)
	if err != nil {
		return int32(wasiEIo)
	}
	binary.LittleEndian.PutUint64(w.mem()[offsetPtr:], uint64(n))
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_fdstat_get(fd int32, statPtr int32) int32 {
	mem := w.mem()
	if fd >= 0 && fd <= 2 {
		mem[statPtr] = fdCharDev
		return int32(wasiESuccess)
	}
	preopenIdx := fd - 3
	if preopenIdx >= 0 && int(preopenIdx) < len(w.preopens) {
		mem[statPtr] = fdDir
		return int32(wasiESuccess)
	}
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil && entry.fdType == 0 {
		return int32(wasiEBadf)
	}
	mem[statPtr] = entry.fdType
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_fdstat_set_flags(fd int32, flags int32) int32 {
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_filestat_get(fd int32, bufPtr int32) int32 {
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil {
		return int32(wasiEBadf)
	}
	fi, err := entry.file.Stat()
	if err != nil {
		return int32(wasiEIo)
	}
	mem := w.mem()
	binary.LittleEndian.PutUint64(mem[bufPtr+32:], uint64(fi.Size()))
	binary.LittleEndian.PutUint64(mem[bufPtr+40:], uint64(fi.ModTime().UnixNano()))
	binary.LittleEndian.PutUint64(mem[bufPtr+48:], uint64(fi.ModTime().UnixNano()))
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_filestat_set_size(fd int32, size int64) int32 {
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_filestat_set_times(fd int32, atim, mtim int64, fstFlags int32) int32 {
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_readdir(fd int32, bufPtr int32, bufLen int32, cookie int64, bufUsedPtr int32) int32 {
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil {
		return int32(wasiEBadf)
	}
	if entry.dirFile == nil {
		df, ok := entry.file.(fs.ReadDirFile)
		if !ok {
			return int32(wasiENotDir)
		}
		entry.dirFile = df
	}
	mem := w.mem()
	if cookie != entry.dirOff {
		entry.dirOff = 0
		for entry.dirOff < cookie {
			_, err := entry.dirFile.ReadDir(1)
			if err != nil {
				binary.LittleEndian.PutUint32(mem[bufUsedPtr:], 0)
				return int32(wasiESuccess)
			}
			entry.dirOff++
		}
	}
	entries, err := entry.dirFile.ReadDir(1)
	if err != nil || len(entries) == 0 {
		binary.LittleEndian.PutUint32(mem[bufUsedPtr:], 0)
		w.fds[fd] = entry
		return int32(wasiESuccess)
	}
	name := entries[0].Name()
	dNameLen := uint32(len(name))
	dEntryLen := uint32(24 + dNameLen)
	if dEntryLen > uint32(bufLen) {
		dEntryLen = uint32(bufLen)
		if dEntryLen < 24 {
			binary.LittleEndian.PutUint32(mem[bufUsedPtr:], 0)
			w.fds[fd] = entry
			return int32(wasiESuccess)
		}
	}
	entry.dirOff++
	binary.LittleEndian.PutUint64(mem[bufPtr:], uint64(entry.dirOff))
	binary.LittleEndian.PutUint64(mem[bufPtr+8:], uint64(dNameLen))
	var ftype byte
	if entries[0].IsDir() {
		ftype = fdDir
	} else {
		ftype = fdFile
	}
	binary.LittleEndian.PutUint32(mem[bufPtr+16:], uint32(ftype))
	if dEntryLen > 24 {
		copy(mem[bufPtr+24:], name[:dEntryLen-24])
	}
	w.fds[fd] = entry
	binary.LittleEndian.PutUint32(mem[bufUsedPtr:], dEntryLen)
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_renumber(fd, to int32) int32 {
	w.fdsMu.Lock()
	defer w.fdsMu.Unlock()
	if fd < 0 || int(fd) >= len(w.fds) || to < 0 || int(to) >= len(w.fds) {
		return int32(wasiEBadf)
	}
	w.fds[to] = w.fds[fd]
	w.fds[fd] = fdEntry{}
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_sync(fd int32) int32 { return int32(wasiESuccess) }

func (w *wasiState) Xpath_filestat_get(dirfd int32, flags int32, pathPtr int32, pathLen int32, bufPtr int32) int32 {
	guestPath := w.readString(pathPtr)
	mount, relPath := w.resolvePath(guestPath)
	if mount == nil {
		return int32(wasiENoEnt)
	}
	fi, err := fs.Stat(mount.root, relPath)
	if err != nil {
		return int32(wasiENoEnt)
	}
	mem := w.mem()
	binary.LittleEndian.PutUint64(mem[bufPtr+32:], uint64(fi.Size()))
	binary.LittleEndian.PutUint64(mem[bufPtr+40:], uint64(fi.ModTime().UnixNano()))
	binary.LittleEndian.PutUint64(mem[bufPtr+48:], uint64(fi.ModTime().UnixNano()))
	return int32(wasiESuccess)
}

func (w *wasiState) Xpath_open(dirfd int32, lookupFlags int32, pathPtr int32, pathLen int32, oflags int32, fdRightsBase int64, fdRightsInheriting int64, fdFlags int32, fdPtr int32) int32 {
	guestPath := w.readString(pathPtr)
	mem := w.mem()

	if guestPath == "/dev/null" {
		fd := w.allocFD()
		w.fds[fd] = fdEntry{fdType: fdCharDev, path: "/dev/null"}
		binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
		return int32(wasiESuccess)
	}

	mount, relPath := w.resolvePath(guestPath)
	if mount == nil {
		return int32(wasiENoEnt)
	}

	var f fs.File
	var err error
	if oflags&0x0100 != 0 && mount.writable {
		hostFile, osErr := os.OpenFile(relPath, os.O_RDWR|os.O_CREATE, 0666)
		if osErr != nil {
			return int32(wasiENoEnt)
		}
		fi, _ := hostFile.Stat()
		fd := w.allocFD()
		w.fds[fd] = fdEntry{file: &osFile{File: hostFile}, path: guestPath, fdType: fdFile}
		if fi != nil && fi.IsDir() {
			w.fds[fd].fdType = fdDir
		}
		binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
		return int32(wasiESuccess)
	}

	f, err = mount.root.Open(relPath)
	if err != nil {
		return int32(wasiENoEnt)
	}
	fi, _ := f.Stat()
	fdType := fdFile
	if fi != nil && fi.IsDir() {
		fdType = fdDir
	}
	fd := w.allocFD()
	entry := fdEntry{file: &fsFileWrap{File: f}, path: guestPath, fdType: fdType}
	if fdType == fdDir {
		if df, ok := f.(fs.ReadDirFile); ok {
			entry.dirFile = df
		}
	}
	w.fds[fd] = entry
	binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
	return int32(wasiESuccess)
}

func (w *wasiState) Xpath_create_directory(dirfd int32, pathPtr int32, pathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpath_filestat_set_times(dirfd int32, flags int32, pathPtr int32, pathLen int32, atim int64, mtim int64, fstFlags int32) int32 {
	return int32(wasiESuccess)
}

func (w *wasiState) Xpath_link(oldDirfd int32, oldFlags int32, oldPathPtr int32, oldPathLen int32, newDirfd int32, newPathPtr int32, newPathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpath_readlink(dirfd int32, pathPtr int32, pathLen int32, bufPtr int32, bufLen int32, nreadPtr int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpath_remove_directory(dirfd int32, pathPtr int32, pathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpath_rename(oldDirfd int32, oldPathPtr int32, oldPathLen int32, newDirfd int32, newPathPtr int32, newPathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpath_symlink(oldPathPtr int32, oldPathLen int32, dirfd int32, newPathPtr int32, newPathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpath_unlink_file(dirfd int32, pathPtr int32, pathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpoll_oneoff(inPtr int32, outPtr int32, nsubscriptions int32, neventsPtr int32) int32 {
	binary.LittleEndian.PutUint32(w.mem()[neventsPtr:], 0)
	return int32(wasiESuccess)
}

type fsFileWrap struct{ fs.File }

func (f *fsFileWrap) Stat() (fs.FileInfo, error) {
	return f.File.Stat()
}

type osFile struct{ *os.File }
