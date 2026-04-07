package exiftool

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	wasm2go "github.com/lbe/go-exiftool/zeroperl"
)

// WASI error codes returned to the guest. Values follow the WASI snapshot-preview1
// specification.
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
)

// fdCharDev, fdDir, and fdFile are WASI file descriptor type tags used in
// fdstat and filestat responses.
const (
	fdCharDev byte = 2
	fdDir     byte = 3
	fdFile    byte = 4

	rightFDRead         uint64 = 1 << 0
	rightFDWrite        uint64 = 1 << 1
	rightFDSeek         uint64 = 1 << 2
	rightFdstatGet      uint64 = 1 << 5
	rightFdstatSetFlags uint64 = 1 << 6
	rightFilestatGet    uint64 = 1 << 7
	rightPollOneoff     uint64 = 1 << 14
)

var (
	rightsRegular = rightFDRead | rightFDWrite | rightFDSeek | rightFdstatGet | rightFdstatSetFlags | rightFilestatGet
	rightsDir     = rightFDRead | rightFDSeek | rightFdstatGet | rightFilestatGet
	rightsCharDev = rightFDRead | rightFDWrite | rightFdstatGet

	oflagCreat uint32 = 1 << 0
	oflagDir   uint32 = 1 << 1
	oflagExcl  uint32 = 1 << 2
	oflagTrunc uint32 = 1 << 3
)

// exitPanic is recovered at eval boundaries to model WASI proc_exit. The code
// field carries the exit status: 0 means success, non-zero means failure.
type exitPanic struct{ code int32 }

func (exitPanic) Error() string { return "proc_exit" }

// fdEntry is one slot in the WASI file-descriptor table. For preopen entries
// file is nil and mount indexes into wasiState.mounts; for regular files file
// holds the open fs.File.
type fdEntry struct {
	file    fsFile
	path    string
	fdType  byte
	offset  int64
	dirFile fs.ReadDirFile
	dirOff  int64
	mount   int
	preopen bool
}

// fsFile is the read/stat/close interface required by fdEntry.file. It is
// satisfied by both fsFileWrap and osFile.
type fsFile interface {
	Read(p []byte) (int, error)
	Stat() (fs.FileInfo, error)
	Close() error
}

// mountEntry maps a guest path prefix to a host fs.FS. If writable is true
// and hostRoot is set, path operations that need real OS access (e.g. rename,
// open for writing) resolve through hostRoot on the host filesystem.
type mountEntry struct {
	guestPath string
	root      fs.FS
	writable  bool
	hostRoot  string
}

// wasiState implements the WASI snapshot-preview1 host functions expected by
// the zeroperl guest module (Xfd_read, Xfd_write, Xpath_open, etc.) as well
// as the Xenv and Xcall_host_function stubs. It owns the file-descriptor
// table, mount list, and the GuestIO adapter for stdin/stdout/stderr.
type wasiState struct {
	module   *wasm2go.Module
	fds      []fdEntry
	fdsMu    sync.Mutex
	mounts   []mountEntry
	guestIO  GuestIO
	preopens []fdEntry
	trace    bool
}

func newWASIState(mod *wasm2go.Module, guestIO GuestIO, mounts []mountEntry) *wasiState {
	ws := &wasiState{
		module:  mod,
		mounts:  mounts,
		guestIO: guestIO,
	}
	ws.fds = make([]fdEntry, 3+len(mounts), 8+len(mounts))
	ws.fds[0] = fdEntry{fdType: fdCharDev, path: "stdin"}
	ws.fds[1] = fdEntry{fdType: fdCharDev, path: "stdout"}
	ws.fds[2] = fdEntry{fdType: fdCharDev, path: "stderr"}
	for i, m := range mounts {
		ws.preopens = append(ws.preopens, fdEntry{path: m.guestPath, fdType: fdDir, mount: i, preopen: true})
		ws.fds[3+i] = fdEntry{path: m.guestPath, fdType: fdDir, mount: i, preopen: true}
	}
	return ws
}

func (w *wasiState) mem() []byte {
	return *w.module.Xmemory().Slice()
}

func (w *wasiState) logTrace(format string, args ...interface{}) {
	if w.trace {
		fmt.Printf(format+"\n", args...)
	}
}

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

func (w *wasiState) readBytes(ptr int32, len int32) []byte {
	if ptr == 0 || len == 0 {
		return nil
	}
	mem := w.mem()
	return mem[ptr : ptr+len]
}

func (w *wasiState) allocFD() int32 {
	w.fdsMu.Lock()
	defer w.fdsMu.Unlock()
	start := 3 + len(w.preopens)
	for i := start; i < len(w.fds); i++ {
		if w.fds[i].file == nil && w.fds[i].fdType == 0 {
			return int32(i)
		}
	}
	idx := int32(len(w.fds))
	w.fds = append(w.fds, fdEntry{})
	return idx
}

func (w *wasiState) resolvePath(guestPath string) (*mountEntry, string) {
	clean := path.Clean("/" + guestPath)
	if clean == "." {
		clean = "/"
	}

	var best *mountEntry
	bestLen := -1
	bestRel := ""
	for i := range w.mounts {
		m := &w.mounts[i]
		mp := path.Clean("/" + m.guestPath)
		if mp == "." {
			mp = "/"
		}

		match := clean == mp || strings.HasPrefix(clean, mp+"/")
		if !match {
			continue
		}

		rel := strings.TrimPrefix(clean, mp)
		rel = strings.TrimPrefix(rel, "/")
		if len(mp) > bestLen {
			best = m
			bestLen = len(mp)
			bestRel = rel
		}
	}
	return best, bestRel
}

func (w *wasiState) resolveDirfdPath(dirfd int32, pathPtr int32, pathLen int32) (*mountEntry, string) {
	pathBytes := w.readBytes(pathPtr, pathLen)
	guestPath := string(pathBytes)
	if strings.HasPrefix(guestPath, "/") {
		return w.resolvePath(guestPath)
	}

	if dirfd >= 0 && int(dirfd) < len(w.fds) {
		entry := w.fds[dirfd]
		if entry.preopen && entry.mount >= 0 && entry.mount < len(w.mounts) {
			return &w.mounts[entry.mount], path.Clean(guestPath)
		}
	}
	return nil, ""
}

func (w *wasiState) Xcall_host_function(v0, v1, v2 int32) int32 { return 0 }

func (w *wasiState) Xenviron_sizes_get(countPtr, bufSizePtr int32) int32 {
	env := []string{"PERL5LIB=/lib/5.42.0:/lib/5.42.0/wasm32-wasi"}
	w.logTrace("environ_sizes_get -> count=%d", len(env))
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

func (w *wasiState) Xproc_exit(code int32) {
	w.logTrace("proc_exit code=%d", code)
	panic(exitPanic{code: code})
}

func (w *wasiState) Xfd_prestat_get(fd int32, prestat int32) int32 {
	idx := fd - 3
	if idx < 0 || idx >= int32(len(w.preopens)) {
		w.logTrace("fd_prestat_get fd=%d -> EBADF", fd)
		return int32(wasiEBadf)
	}
	mem := w.mem()
	pathLen := uint32(len(w.preopens[idx].path))
	binary.LittleEndian.PutUint32(mem[prestat:], 0)
	binary.LittleEndian.PutUint32(mem[prestat+4:], pathLen)
	w.logTrace("fd_prestat_get fd=%d path=%q prestat=%d wrote_len=%d verify=%d", fd, w.preopens[idx].path, prestat, pathLen, binary.LittleEndian.Uint32(mem[prestat+4:]))
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_prestat_dir_name(fd int32, pathPtr int32, pathLen int32) int32 {
	w.logTrace("fd_prestat_dir_name ENTER fd=%d pathLen=%d", fd, pathLen)
	idx := fd - 3
	if idx < 0 || idx >= int32(len(w.preopens)) {
		w.logTrace("fd_prestat_dir_name fd=%d -> EBADF", fd)
		return int32(wasiEBadf)
	}
	mem := w.mem()
	name := w.preopens[idx].path
	if int32(len(name)) > pathLen {
		return int32(wasiEInval)
	}
	copy(mem[pathPtr:], name)
	w.logTrace("fd_prestat_dir_name fd=%d -> %q", fd, name)
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_close(fd int32) int32 {
	w.fdsMu.Lock()
	defer w.fdsMu.Unlock()
	if fd < 0 || int(fd) >= len(w.fds) {
		return int32(wasiEBadf)
	}
	if w.fds[fd].preopen {
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
	w.logTrace("fd_read fd=%d iovsCount=%d", fd, iovsCount)
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
				if err != io.EOF {
					return int32(wasiEIo)
				}
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
		w.logTrace("fd_read fd=%d read %d bytes", fd, n)
		if err != nil {
			if err == io.EOF {
				break
			}
			binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
			return int32(wasiEIo)
		}
		if n < int(bufLen) {
			break
		}
	}
	binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
	return int32(wasiESuccess)
}

func mountHostPath(m *mountEntry, rel string) (string, bool) {
	if m == nil || !m.writable || m.hostRoot == "" {
		return "", false
	}
	return filepath.Join(m.hostRoot, filepath.FromSlash(rel)), true
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
				w.logTrace("fd_write fd=stdout data=%q", string(data))
			} else {
				n, _ = w.guestIO.WriteStderr(data)
				w.logTrace("fd_write fd=stderr data=%q", string(data))
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
	if entry.file == nil || entry.preopen {
		return int32(wasiEBadf)
	}
	if entry.fdType == fdDir {
		return int32(wasiEIsdir)
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
	if entry.file == nil || entry.preopen {
		return int32(wasiEBadf)
	}
	if entry.fdType == fdDir {
		return int32(wasiEIsdir)
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

func writeFdstat(mem []byte, statPtr int32, fdType byte, rightsBase, rightsInheriting uint64) {
	var buf [24]byte
	binary.LittleEndian.PutUint16(buf[0:], uint16(fdType))
	binary.LittleEndian.PutUint16(buf[2:], 0)
	binary.LittleEndian.PutUint32(buf[4:], 0)
	binary.LittleEndian.PutUint64(buf[8:], rightsBase)
	binary.LittleEndian.PutUint64(buf[16:], rightsInheriting)
	copy(mem[statPtr:], buf[:])
}

func (w *wasiState) Xfd_fdstat_get(fd int32, statPtr int32) int32 {
	if fd >= 0 && fd <= 2 {
		w.logTrace("fd_fdstat_get fd=%d -> chardev", fd)
		writeFdstat(w.mem(), statPtr, fdCharDev, rightsCharDev, rightsCharDev)
		return int32(wasiESuccess)
	}
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.file == nil && entry.fdType == 0 {
		w.logTrace("fd_fdstat_get fd=%d -> EBadf", fd)
		return int32(wasiEBadf)
	}
	w.logTrace("fd_fdstat_get fd=%d -> type=%d path=%q", fd, entry.fdType, entry.path)
	writeFdstat(w.mem(), statPtr, entry.fdType, rightsRegular, rightsRegular)
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_fdstat_set_flags(fd int32, flags int32) int32 {
	return int32(wasiESuccess)
}

func writeFilestat(mem []byte, bufPtr int32, fdType byte, size int64, mtimeNs int64) {
	var buf [64]byte
	binary.LittleEndian.PutUint64(buf[0:], 0)
	binary.LittleEndian.PutUint64(buf[8:], 0)
	binary.LittleEndian.PutUint64(buf[16:], uint64(fdType))
	binary.LittleEndian.PutUint64(buf[24:], 1)
	binary.LittleEndian.PutUint64(buf[32:], uint64(size))
	binary.LittleEndian.PutUint64(buf[40:], uint64(mtimeNs))
	binary.LittleEndian.PutUint64(buf[48:], uint64(mtimeNs))
	binary.LittleEndian.PutUint64(buf[56:], uint64(mtimeNs))
	copy(mem[bufPtr:], buf[:])
}

func (w *wasiState) Xfd_filestat_get(fd int32, bufPtr int32) int32 {
	if fd < 0 || int(fd) >= len(w.fds) {
		return int32(wasiEBadf)
	}
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.preopen {
		if entry.mount < 0 || entry.mount >= len(w.mounts) {
			return int32(wasiEBadf)
		}
		fi, err := fs.Stat(w.mounts[entry.mount].root, ".")
		if err != nil {
			return int32(wasiEIo)
		}
		writeFilestat(w.mem(), bufPtr, fdDir, fi.Size(), fi.ModTime().UnixNano())
		return int32(wasiESuccess)
	}
	if entry.file == nil {
		return int32(wasiEBadf)
	}
	fi, err := entry.file.Stat()
	if err != nil {
		return int32(wasiEIo)
	}
	writeFilestat(w.mem(), bufPtr, entry.fdType, fi.Size(), fi.ModTime().UnixNano())
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_filestat_set_size(fd int32, size int64) int32 {
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_filestat_set_times(fd int32, atim, mtim int64, fstFlags int32) int32 {
	return int32(wasiESuccess)
}

func (w *wasiState) Xfd_readdir(fd int32, bufPtr int32, bufLen int32, cookie int64, bufUsedPtr int32) int32 {
	if fd < 0 || int(fd) >= len(w.fds) {
		return int32(wasiEBadf)
	}
	w.fdsMu.Lock()
	entry := w.fds[fd]
	w.fdsMu.Unlock()
	if entry.preopen {
		if entry.mount < 0 || entry.mount >= len(w.mounts) {
			return int32(wasiEBadf)
		}
		if d, ok := w.mounts[entry.mount].root.(fs.ReadDirFS); ok {
			entries, err := d.ReadDir(".")
			if err != nil {
				return int32(wasiEIo)
			}
			entry.file = &dirEntriesFile{entries: entries}
		}
	}
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
	binary.LittleEndian.PutUint64(mem[bufPtr+8:], 0)
	binary.LittleEndian.PutUint32(mem[bufPtr+16:], dNameLen)
	var ftype byte
	if entries[0].IsDir() {
		ftype = fdDir
	} else {
		ftype = fdFile
	}
	binary.LittleEndian.PutUint32(mem[bufPtr+20:], uint32(ftype))
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
	pathBytes := w.readBytes(pathPtr, pathLen)
	guestPath := string(pathBytes)
	w.logTrace("path_filestat_get dirfd=%d path=%q", dirfd, guestPath)
	mount, relPath := w.resolveDirfdPath(dirfd, pathPtr, pathLen)
	if mount == nil {
		return int32(wasiENoEnt)
	}
	fi, err := fs.Stat(mount.root, relPath)
	if err != nil {
		return int32(wasiENoEnt)
	}
	fdType := fdFile
	if fi.IsDir() {
		fdType = fdDir
	}
	writeFilestat(w.mem(), bufPtr, fdType, fi.Size(), fi.ModTime().UnixNano())
	return int32(wasiESuccess)
}

func (w *wasiState) Xpath_open(dirfd int32, lookupFlags int32, pathPtr int32, pathLen int32, oflags int32, fdRightsBase int64, fdRightsInheriting int64, fdFlags int32, fdPtr int32) int32 {
	pathBytes := w.readBytes(pathPtr, pathLen)
	guestPath := string(pathBytes)
	mem := w.mem()
	w.logTrace("path_open dirfd=%d path=%q oflags=%#x", dirfd, guestPath, oflags)

	if guestPath == "/dev/null" {
		fd := w.allocFD()
		w.fds[fd] = fdEntry{fdType: fdCharDev, path: "/dev/null"}
		binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
		return int32(wasiESuccess)
	}

	mount, relPath := w.resolveDirfdPath(dirfd, pathPtr, pathLen)
	if mount == nil {
		return int32(wasiENoEnt)
	}

	var f fs.File
	var err error
	if mount.writable {
		hostPath := relPath
		if mount.hostRoot != "" {
			hostPath = filepath.Join(mount.hostRoot, filepath.FromSlash(relPath))
		}
		osFlags := os.O_RDONLY
		if (uint64(fdRightsBase)&rightFDWrite) != 0 || (uint32(oflags)&(oflagCreat|oflagTrunc|oflagExcl)) != 0 {
			osFlags = os.O_RDWR
		}
		if uint32(oflags)&oflagCreat != 0 {
			osFlags |= os.O_CREATE
		}
		if uint32(oflags)&oflagTrunc != 0 {
			osFlags |= os.O_TRUNC
		}
		if uint32(oflags)&oflagExcl != 0 {
			osFlags |= os.O_EXCL
		}
		if uint32(oflags)&oflagDir != 0 {
			osFlags = os.O_RDONLY
		}

		hostFile, osErr := os.OpenFile(hostPath, osFlags, 0o666)
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
	oldMount, oldRel := w.resolveDirfdPath(oldDirfd, oldPathPtr, oldPathLen)
	newMount, newRel := w.resolveDirfdPath(newDirfd, newPathPtr, newPathLen)
	if oldMount == nil || newMount == nil {
		return int32(wasiENoEnt)
	}
	oldHost, okOld := mountHostPath(oldMount, oldRel)
	newHost, okNew := mountHostPath(newMount, newRel)
	if !okOld || !okNew {
		return int32(wasiEROFS)
	}
	if err := os.Rename(oldHost, newHost); err != nil {
		return int32(wasiEIo)
	}
	return int32(wasiESuccess)
}

func (w *wasiState) Xpath_symlink(oldPathPtr int32, oldPathLen int32, dirfd int32, newPathPtr int32, newPathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpath_unlink_file(dirfd int32, pathPtr int32, pathLen int32) int32 {
	return int32(wasiENoSys)
}

func (w *wasiState) Xpoll_oneoff(inPtr int32, outPtr int32, nsubscriptions int32, neventsPtr int32) int32 {
	mem := w.mem()
	var minTimeout int64 = -1
	for i := int32(0); i < nsubscriptions; i++ {
		subOff := inPtr + i*48
		userdata := binary.LittleEndian.Uint64(mem[subOff:])
		eventType := binary.LittleEndian.Uint32(mem[subOff+40:])

		var errno uint32 = 0
		switch eventType {
		case 0: // clock
			timeout := int64(binary.LittleEndian.Uint64(mem[subOff+8+8:]))
			if timeout > 0 && (minTimeout < 0 || timeout < minTimeout) {
				minTimeout = timeout
			}
		case 1: // fd_read
			fd := int32(binary.LittleEndian.Uint32(mem[subOff+8:]))
			if fd < 0 || fd >= int32(len(w.fds)) {
				errno = wasiEBadf
			}
		case 2: // fd_write
			fd := int32(binary.LittleEndian.Uint32(mem[subOff+8:]))
			if fd < 0 || fd >= int32(len(w.fds)) {
				errno = wasiEBadf
			}
		}

		evOff := outPtr + i*32
		binary.LittleEndian.PutUint64(mem[evOff:], userdata)
		binary.LittleEndian.PutUint16(mem[evOff+8:], uint16(errno))
		binary.LittleEndian.PutUint16(mem[evOff+10:], 0)
		binary.LittleEndian.PutUint32(mem[evOff+12:], eventType)
		binary.LittleEndian.PutUint64(mem[evOff+16:], 0)
		binary.LittleEndian.PutUint64(mem[evOff+24:], 0)
	}

	if minTimeout > 0 {
		time.Sleep(time.Duration(minTimeout))
	}

	binary.LittleEndian.PutUint32(mem[neventsPtr:], uint32(nsubscriptions))
	return int32(wasiESuccess)
}

// fsFileWrap adapts a standard fs.File to the fsFile interface by adding
// explicit Stat and Seek methods (Seek delegates if the underlying file
// implements io.Seeker).
type fsFileWrap struct{ fs.File }

func (f *fsFileWrap) Stat() (fs.FileInfo, error) {
	return f.File.Stat()
}

func (f *fsFileWrap) Seek(offset int64, whence int) (int64, error) {
	if s, ok := f.File.(io.Seeker); ok {
		return s.Seek(offset, whence)
	}
	return 0, fmt.Errorf("seek not supported")
}

// dirEntriesFile adapts a slice of fs.DirEntry to the fs.ReadDirFile
// interface for use by Xfd_readdir when serving preopen mounts backed by
// an fs.ReadDirFS.
type dirEntriesFile struct {
	entries []fs.DirEntry
	idx     int
}

func (d *dirEntriesFile) Read(_ []byte) (int, error) { return 0, io.EOF }
func (d *dirEntriesFile) Close() error               { return nil }
func (d *dirEntriesFile) Stat() (fs.FileInfo, error) { return devNullDirInfo{}, nil }

func (d *dirEntriesFile) ReadDir(n int) ([]fs.DirEntry, error) {
	if d.idx >= len(d.entries) {
		return nil, io.EOF
	}
	if n <= 0 || d.idx+n > len(d.entries) {
		n = len(d.entries) - d.idx
	}
	out := d.entries[d.idx : d.idx+n]
	d.idx += n
	return out, nil
}

// osFile wraps an *os.File to satisfy the fsFile interface for writable mount
// entries that need real host file-descriptor operations (ReadAt, WriteAt, etc.).
type osFile struct{ *os.File }
