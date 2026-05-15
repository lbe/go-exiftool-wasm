package wasihost

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	wasiESuccess  int32 = 0
	wasiEExist    int32 = 20
	wasiEBadf     int32 = 8
	wasiEInval    int32 = 28
	wasiEIo       int32 = 29
	wasiEIsdir    int32 = 31
	wasiENoEnt    int32 = 44
	wasiENoSys    int32 = 52
	wasiENotDir   int32 = 54
	wasiENotEmpty int32 = 55
	wasiEROFS     int32 = 66

	fdDir byte = 3
)

type State struct {
	mem       func() []byte
	fds       []fdEntry
	preopens  []fdEntry
	mounts    []mountEntry
	env       []string
	args      []string
	startTime time.Time
}

// fsFile is the read/stat/close interface for fd table entries.
type fsFile interface {
	Read([]byte) (int, error)
	Stat() (fs.FileInfo, error)
	Close() error
}

// osFile wraps *os.File for WASI fd entries backed by real host files.
type osFile struct{ *os.File }

// fsFileWrap adapts fs.File to fsFile for read-only embedded-FS entries.
type fsFileWrap struct{ fs.File }

// fdEntry is one slot in the WASI file-descriptor table.
type fdEntry struct {
	file    fsFile
	path    string
	fdType  byte
	offset  int64
	mount   int
	preopen bool
}

// mountEntry maps a guest path prefix to a host filesystem.
type mountEntry struct {
	guestPath string
	writable  bool
	hostRoot  string
}

type Option func(*State)
type ExitError struct{ Code int32 }

func (e ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

func New(mem func() []byte, opts ...Option) *State {
	s := &State{mem: mem}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func WithArgs(args ...string) Option                                  { return func(*State) {} }
func WithEnv(env ...string) Option                                    { return func(*State) {} }
func WithMount(guestPath string, root fs.FS) Option                   { return func(*State) {} }
func WithWritableMount(guestPath, hostRoot string, root fs.FS) Option { return func(*State) {} }
func WithStdin(r io.Reader) Option                                    { return func(*State) {} }
func WithStdout(w io.Writer) Option                                   { return func(*State) {} }
func WithStderr(w io.Writer) Option                                   { return func(*State) {} }
func WithTracing() Option                                             { return func(*State) {} }
func WithOwnerAssertion() Option                                      { return func(*State) {} }

func (s *State) Xenviron_sizes_get(countPtr, bufSizePtr int32) int32 {
	writeStringTableSizes(s.mem(), countPtr, bufSizePtr, s.env)
	return wasiESuccess
}
func (s *State) Xenviron_get(envPtr, envBufPtr int32) int32 {
	writeStringTable(s.mem(), envPtr, envBufPtr, s.env)
	return wasiESuccess
}
func (s *State) Xfd_prestat_get(fd, prestatPtr int32) int32 {
	idx := fd - 3
	if idx < 0 || idx >= int32(len(s.preopens)) {
		return wasiEBadf
	}
	mem := s.mem()
	pathLen := uint32(len(s.preopens[idx].path))
	binary.LittleEndian.PutUint32(mem[prestatPtr:], 0)
	binary.LittleEndian.PutUint32(mem[prestatPtr+4:], pathLen)
	return wasiESuccess
}
func (s *State) Xfd_prestat_dir_name(fd, pathPtr, pathLen int32) int32 {
	idx := fd - 3
	if idx < 0 || idx >= int32(len(s.preopens)) {
		return wasiEBadf
	}
	mem := s.mem()
	name := s.preopens[idx].path
	copy(mem[pathPtr:], name)
	return wasiESuccess
}
func (s *State) Xfd_fdstat_get(fd, statPtr int32) int32 {
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil && entry.fdType == 0 {
		return wasiEBadf
	}
	mem := s.mem()
	writeFdstat(mem, statPtr, entry.fdType)
	return wasiESuccess
}

func writeFdstat(mem []byte, statPtr int32, fdType byte) {
	var buf [24]byte
	binary.LittleEndian.PutUint16(buf[0:], uint16(fdType))
	// Other fields (fs_flags, fs_rights_base, fs_rights_inheriting) remain 0 for now.
	copy(mem[statPtr:], buf[:])
}

func (s *State) Xfd_renumber(fd, to int32) int32 {
	if fd < 0 || int(fd) >= len(s.fds) || to < 0 || int(to) >= len(s.fds) {
		return wasiEBadf
	}
	s.fds[to] = s.fds[fd]
	s.fds[fd] = fdEntry{}
	return wasiESuccess
}
func (s *State) Xproc_exit(code int32) {
	panic(ExitError{Code: code})
}
func (s *State) Xrandom_get(bufPtr, bufLen int32) int32 {
	mem := s.mem()
	rand.Read(mem[bufPtr : bufPtr+bufLen])
	return wasiESuccess
}

func (s *State) Xclock_time_get(clockID int32, precision int64, resultPtr int32) int32 {
	mem := s.mem()
	switch clockID {
	case 0: // realtime
		binary.LittleEndian.PutUint64(mem[resultPtr:], uint64(time.Now().UnixNano()))
		return wasiESuccess
	case 1: // monotonic
		var t int64
		if s.startTime.IsZero() {
			t = time.Now().UnixNano()
		} else {
			t = time.Since(s.startTime).Nanoseconds()
		}
		binary.LittleEndian.PutUint64(mem[resultPtr:], uint64(t))
		return wasiESuccess
	default:
		return wasiENoSys
	}
}

func (s *State) Xclock_res_get(clockID int32, resultPtr int32) int32 {
	switch clockID {
	case 0, 1:
		binary.LittleEndian.PutUint64(s.mem()[resultPtr:], 1)
		return wasiESuccess
	default:
		return wasiENoSys
	}
}

func (s *State) Xargs_sizes_get(argcPtr, argvSizePtr int32) int32 {
	writeStringTableSizes(s.mem(), argcPtr, argvSizePtr, s.args)
	return wasiESuccess
}

func (s *State) Xargs_get(argvPtr, argvBufPtr int32) int32 {
	writeStringTable(s.mem(), argvPtr, argvBufPtr, s.args)
	return wasiESuccess
}

func (s *State) readBytes(ptr, length int32) []byte {
	if ptr == 0 || length == 0 {
		return nil
	}
	return s.mem()[ptr : ptr+length]
}

func (s *State) resolveDirfdPath(dirfd, pathPtr, pathLen int32) (*mountEntry, string) {
	pathBytes := s.readBytes(pathPtr, pathLen)
	guestPath := string(pathBytes)
	if dirfd >= 0 && int(dirfd) < len(s.fds) {
		entry := s.fds[dirfd]
		if entry.preopen && entry.mount >= 0 && entry.mount < len(s.mounts) {
			return &s.mounts[entry.mount], path.Clean(guestPath)
		}
	}
	return nil, ""
}

func mountHostPaths(m *mountEntry, rel string) (primary, fallback string) {
	if m == nil || !m.writable || m.hostRoot == "" {
		return "", ""
	}
	return filepath.Join(m.hostRoot, filepath.FromSlash(rel)), ""
}

func (s *State) resolvePrimary(dirfd, pathPtr, pathLen int32) string {
	m, rel := s.resolveDirfdPath(dirfd, pathPtr, pathLen)
	primary, _ := mountHostPaths(m, rel)
	return primary
}

func (s *State) Xpath_create_directory(dirfd, pathPtr, pathLen int32) int32 {
	primary := s.resolvePrimary(dirfd, pathPtr, pathLen)
	if primary == "" {
		return wasiEROFS
	}
	if err := os.Mkdir(primary, 0755); err != nil {
		return int32(mapOSError(err))
	}
	return wasiESuccess
}

func (s *State) Xpath_remove_directory(dirfd, pathPtr, pathLen int32) int32 {
	primary := s.resolvePrimary(dirfd, pathPtr, pathLen)
	if primary == "" {
		return wasiEROFS
	}
	fi, err := os.Lstat(primary)
	if err != nil {
		return int32(mapOSError(err))
	}
	if !fi.IsDir() {
		return wasiENotDir
	}
	if err := os.Remove(primary); err != nil {
		return int32(mapOSError(err))
	}
	return wasiESuccess
}

func (s *State) Xpath_unlink_file(dirfd, pathPtr, pathLen int32) int32 {
	primary := s.resolvePrimary(dirfd, pathPtr, pathLen)
	if primary == "" {
		return wasiEROFS
	}
	fi, err := os.Lstat(primary)
	if err != nil {
		return int32(mapOSError(err))
	}
	if fi.IsDir() {
		return wasiEIsdir
	}
	if err := os.Remove(primary); err != nil {
		return int32(mapOSError(err))
	}
	return wasiESuccess
}

func (s *State) Xpath_readlink(dirfd, pathPtr, pathLen, bufPtr, bufLen, nreadPtr int32) int32 {
	primary := s.resolvePrimary(dirfd, pathPtr, pathLen)
	if primary == "" {
		return wasiEROFS
	}
	target, err := os.Readlink(primary)
	if err != nil {
		return int32(mapOSError(err))
	}
	mem := s.mem()
	n := copy(mem[bufPtr:bufPtr+bufLen], target)
	binary.LittleEndian.PutUint32(mem[nreadPtr:], uint32(n))
	return wasiESuccess
}

func (s *State) Xpath_symlink(oldPathPtr, oldPathLen, dirfd, newPathPtr, newPathLen int32) int32 {
	// oldPath is the symlink target (literal, not resolved via mount)
	target := string(s.readBytes(oldPathPtr, oldPathLen))
	primary := s.resolvePrimary(dirfd, newPathPtr, newPathLen)
	if primary == "" {
		return wasiEROFS
	}
	if err := os.Symlink(target, primary); err != nil {
		return int32(mapOSError(err))
	}
	return wasiESuccess
}

func (s *State) Xpath_link(oldDirfd, oldFlags, oldPathPtr, oldPathLen, newDirfd, newPathPtr, newPathLen int32) int32 {
	oldMount, oldRel := s.resolveDirfdPath(oldDirfd, oldPathPtr, oldPathLen)
	newMount, newRel := s.resolveDirfdPath(newDirfd, newPathPtr, newPathLen)
	oldPrimary, _ := mountHostPaths(oldMount, oldRel)
	newPrimary, _ := mountHostPaths(newMount, newRel)
	if oldPrimary == "" || newPrimary == "" {
		return wasiEROFS
	}
	if err := os.Link(oldPrimary, newPrimary); err != nil {
		return int32(mapOSError(err))
	}
	return wasiESuccess
}

func writeStringTableSizes(mem []byte, countPtr, bufSizePtr int32, items []string) {
	binary.LittleEndian.PutUint32(mem[countPtr:], uint32(len(items)))
	var total uint32
	for _, s := range items {
		total += uint32(len(s)) + 1
	}
	binary.LittleEndian.PutUint32(mem[bufSizePtr:], total)
}

func writeStringTable(mem []byte, ptrBase, bufBase int32, items []string) {
	bufOff := uint32(bufBase)
	for i, s := range items {
		binary.LittleEndian.PutUint32(mem[ptrBase+int32(i*4):], bufOff)
		n := copy(mem[bufOff:], s)
		mem[bufOff+uint32(n)] = 0
		bufOff += uint32(n) + 1
	}
}

func (s *State) Xfd_pread(fd, iovsPtr, iovsCount int32, offset int64, nreadPtr int32) int32 {
	if fd <= 2 {
		return wasiEInval
	}
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil {
		return wasiEBadf
	}
	mem := s.mem()
	var total uint32
	curOff := offset
	for i := int32(0); i < iovsCount; i++ {
		off := iovsPtr + i*8
		bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
		bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
		if bufLen == 0 {
			continue
		}
		var n int
		var err error
		ra, ok := entry.file.(interface {
			ReadAt([]byte, int64) (int, error)
		})
		if !ok {
			break
		}
		n, err = ra.ReadAt(mem[bufPtr:bufPtr+bufLen], curOff)
		total += uint32(n)
		curOff += int64(n)
		if err != nil {
			break
		}
	}
	binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
	return wasiESuccess
}

func (s *State) Xfd_pwrite(fd, iovsPtr, iovsCount int32, offset int64, nwrittenPtr int32) int32 {
	if fd <= 2 {
		return wasiEInval
	}
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil {
		return wasiEBadf
	}
	mem := s.mem()
	var total uint32
	curOff := offset
	for i := int32(0); i < iovsCount; i++ {
		off := iovsPtr + i*8
		bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
		bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
		if bufLen == 0 {
			continue
		}
		wa, ok := entry.file.(interface {
			WriteAt([]byte, int64) (int, error)
		})
		if !ok {
			break // file doesn't support WriteAt
		}
		n, err := wa.WriteAt(mem[bufPtr:bufPtr+bufLen], curOff)
		total += uint32(n)
		curOff += int64(n)
		if err != nil {
			break
		}
	}
	binary.LittleEndian.PutUint32(mem[nwrittenPtr:], total)
	return wasiESuccess
}

func (s *State) Xfd_tell(fd, offsetPtr int32) int32 {
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil && entry.fdType == 0 {
		return wasiEBadf
	}
	binary.LittleEndian.PutUint64(s.mem()[offsetPtr:], uint64(entry.offset))
	return wasiESuccess
}

func (s *State) Xsched_yield() int32                                           { return wasiESuccess }
func (s *State) Xfd_datasync(fd int32) int32                                   { return wasiESuccess }
func (s *State) Xfd_advise(fd int32, offset, length int64, advice int32) int32 { return wasiESuccess }
func (s *State) Xfd_allocate(fd int32, offset, length int64) int32             { return wasiESuccess }
func (s *State) Xfd_fdstat_set_rights(fd int32, base, inheriting int64) int32  { return wasiESuccess }
func (s *State) Xproc_raise(signal int32) int32                                { return wasiENoSys }
func (s *State) Xsock_accept(fd, flags, resultPtr int32) int32                 { return wasiENoSys }
func (s *State) Xsock_recv(fd, iovsPtr, iovsLen, riFlags, nreadPtr, roFlagsPtr int32) int32 {
	return wasiENoSys
}
func (s *State) Xsock_send(fd, iovsPtr, iovsLen, siFlags, nsentPtr int32) int32 { return wasiENoSys }
func (s *State) Xsock_shutdown(fd, how int32) int32                             { return wasiENoSys }

func (s *State) Xfd_filestat_set_size(fd int32, size int64) int32 {
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil {
		return wasiEBadf
	}
	// Only truncate if backed by a real OS file (osFile)
	if of, ok := entry.file.(*osFile); ok {
		if err := of.Truncate(size); err != nil {
			return int32(mapOSError(err))
		}
	}
	// For fs.FS-backed files: no-op, return ESUCCESS
	return wasiESuccess
}
func (s *State) Xfd_filestat_set_times(fd int32, atim, mtim int64, fstFlags int32) int32 {
	if fstFlags&2 == 0 {
		// No-op: MTIM bit not set
		return wasiESuccess
	}
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil {
		return wasiEBadf
	}
	if of, ok := entry.file.(*osFile); ok {
		return applyMtim(of.Name(), mtim)
	}
	return wasiESuccess
}
func (s *State) Xpath_filestat_set_times(dirfd, flags, pathPtr, pathLen int32, atim, mtim int64, fstFlags int32) int32 {
	if fstFlags&2 == 0 {
		return wasiESuccess
	}
	primary := s.resolvePrimary(dirfd, pathPtr, pathLen)
	if primary == "" {
		return wasiEROFS
	}
	return applyMtim(primary, mtim)
}

func applyMtim(path string, mtim int64) int32 {
	mtime := time.Unix(0, mtim)
	atime := time.Now() // preserve access time
	if err := os.Chtimes(path, atime, mtime); err != nil {
		return int32(mapOSError(err))
	}
	return wasiESuccess
}

func (s *State) resolvePath(guestPath string) (*mountEntry, string) {
	clean := path.Clean("/" + guestPath)
	if clean == "." {
		clean = "/"
	}
	var best *mountEntry
	bestLen := -1
	bestRel := ""
	for i := range s.mounts {
		m := &s.mounts[i]
		mp := path.Clean("/" + m.guestPath)
		if mp == "." {
			mp = "/"
		}
		match := false
		var rel string
		if clean == mp {
			match = true
			rel = "."
		} else if mp == "/" {
			match = true
			rel = strings.TrimPrefix(clean, "/")
		} else if strings.HasPrefix(clean, mp+"/") {
			match = true
			rel = strings.TrimPrefix(clean, mp+"/")
		}
		if !match {
			continue
		}
		if len(mp) > bestLen {
			bestLen = len(mp)
			best = m
			bestRel = rel
		}
	}
	return best, bestRel
}

func mapOSError(err error) uint32 {
	if errors.Is(err, os.ErrNotExist) {
		return 44
	}
	if errors.Is(err, syscall.ENOTEMPTY) {
		return 55
	}
	if errors.Is(err, os.ErrExist) {
		return 20
	}
	return 29
}
