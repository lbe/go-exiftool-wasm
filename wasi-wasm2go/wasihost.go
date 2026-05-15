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
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	wasiESuccess  int32 = 0
	wasiEBadf     int32 = 8
	wasiEExist    int32 = 20
	wasiEInval    int32 = 28
	wasiEIo       int32 = 29
	wasiEIsdir    int32 = 31
	wasiENoEnt    int32 = 44
	wasiENoSys    int32 = 52
	wasiENotDir   int32 = 54
	wasiENotEmpty int32 = 55
	wasiEROFS     int32 = 66

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
	rightsCharDev = rightFDRead | rightFDWrite | rightFdstatGet

	oflagCreat uint32 = 1 << 0
	oflagDir   uint32 = 1 << 1
	oflagExcl  uint32 = 1 << 2
	oflagTrunc uint32 = 1 << 3
)

type State struct {
	mem         func() []byte
	fds         []fdEntry
	preopens    []fdEntry
	mounts      []mountEntry
	env         []string
	args        []string
	startTime   time.Time
	stdin       io.Reader
	stdout      io.Writer
	stderr      io.Writer
	trace       bool
	assertOwner bool
	ownerMu     sync.Mutex
	ownerGID    uint64
}

// fsFile is the read/stat/close interface for fd table entries.
type fsFile interface {
	Read([]byte) (int, error)
	Stat() (fs.FileInfo, error)
	Close() error
}

// osFile wraps *os.File for WASI fd entries backed by real host files.
type osFile struct{ *os.File }

// fdEntry is one slot in the WASI file-descriptor table.
type fdEntry struct {
	file    fsFile
	path    string
	fdType  byte
	offset  int64
	mount   int
	preopen bool
	dirFile fs.ReadDirFile
	dirOff  int64
}

// mountEntry maps a guest path prefix to a host filesystem.
type mountEntry struct {
	guestPath string
	writable  bool
	hostRoot  string
	root      fs.FS
}

type Option func(*State)
type ExitError struct{ Code int32 }

func (e ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

func New(mem func() []byte, opts ...Option) *State {
	s := &State{mem: mem, startTime: time.Now()}
	for _, opt := range opts {
		opt(s)
	}
	// Initialize fd table
	s.fds = make([]fdEntry, 3+len(s.mounts), 8+len(s.mounts))
	s.fds[0] = fdEntry{fdType: fdCharDev, path: "stdin"}
	s.fds[1] = fdEntry{fdType: fdCharDev, path: "stdout"}
	s.fds[2] = fdEntry{fdType: fdCharDev, path: "stderr"}
	for i, m := range s.mounts {
		s.preopens = append(s.preopens, fdEntry{path: m.guestPath, fdType: fdDir, mount: i, preopen: true})
		s.fds[3+i] = fdEntry{path: m.guestPath, fdType: fdDir, mount: i, preopen: true}
	}
	return s
}

func WithArgs(args ...string) Option { return func(s *State) { s.args = append(s.args, args...) } }
func WithEnv(env ...string) Option   { return func(s *State) { s.env = append(s.env, env...) } }
func WithMount(guestPath string, root fs.FS) Option {
	return func(s *State) {
		s.mounts = append(s.mounts, mountEntry{guestPath: guestPath, root: root})
	}
}
func WithWritableMount(guestPath, hostRoot string, root fs.FS) Option {
	return func(s *State) {
		s.mounts = append(s.mounts, mountEntry{guestPath: guestPath, hostRoot: hostRoot, root: root, writable: true})
	}
}
func WithStdin(r io.Reader) Option  { return func(s *State) { s.stdin = r } }
func WithStdout(w io.Writer) Option { return func(s *State) { s.stdout = w } }
func WithStderr(w io.Writer) Option { return func(s *State) { s.stderr = w } }
func WithTracing() Option           { return func(s *State) { s.trace = true } }
func WithOwnerAssertion() Option    { return func(s *State) { s.assertOwner = true } }

func (s *State) Mem() []byte { return s.mem() }

func (s *State) allocFD() int32 {
	s.assertSingleOwner()
	start := 3 + len(s.preopens)
	for i := start; i < len(s.fds); i++ {
		if s.fds[i].file == nil && s.fds[i].fdType == 0 {
			return int32(i)
		}
	}
	idx := int32(len(s.fds))
	s.fds = append(s.fds, fdEntry{})
	return idx
}

func (s *State) logTrace(format string, args ...interface{}) {
	if s.trace {
		fmt.Printf(format+"\n", args...)
	}
}

func (s *State) assertSingleOwner() {
	if !s.assertOwner {
		return
	}
	gid := currentGID()
	s.ownerMu.Lock()
	defer s.ownerMu.Unlock()
	if s.ownerGID == 0 {
		s.ownerGID = gid
		return
	}
	if s.ownerGID != gid {
		panic(fmt.Sprintf("wasiState single-owner invariant violated: owner goroutine=%d current goroutine=%d", s.ownerGID, gid))
	}
}

func currentGID() uint64 {
	var b [64]byte
	n := runtime.Stack(b[:], false)
	line := string(b[:n])
	const prefix = "goroutine "
	if !strings.HasPrefix(line, prefix) {
		panic("unable to parse goroutine id: missing prefix")
	}
	line = line[len(prefix):]
	end := strings.IndexByte(line, ' ')
	if end < 0 {
		panic("unable to parse goroutine id: missing delimiter")
	}
	id, err := strconv.ParseUint(line[:end], 10, 64)
	if err != nil {
		panic(fmt.Sprintf("unable to parse goroutine id: %v", err))
	}
	return id
}

type wasiDirInfo struct{}

func (wasiDirInfo) Name() string       { return "." }
func (wasiDirInfo) Size() int64        { return 0 }
func (wasiDirInfo) Mode() fs.FileMode  { return fs.ModeDir | 0o555 }
func (wasiDirInfo) ModTime() time.Time { return time.Time{} }
func (wasiDirInfo) IsDir() bool        { return true }
func (wasiDirInfo) Sys() any           { return nil }

// DirEntriesFile adapts a []fs.DirEntry to fs.ReadDirFile for Xfd_readdir.
type DirEntriesFile struct {
	Entries []fs.DirEntry
	idx     int
}

func (d *DirEntriesFile) Read(_ []byte) (int, error) { return 0, io.EOF }
func (d *DirEntriesFile) Close() error               { return nil }
func (d *DirEntriesFile) Stat() (fs.FileInfo, error) { return wasiDirInfo{}, nil }
func (d *DirEntriesFile) ReadDir(n int) ([]fs.DirEntry, error) {
	if d.idx >= len(d.Entries) {
		return nil, io.EOF
	}
	if n <= 0 || d.idx+n > len(d.Entries) {
		n = len(d.Entries) - d.idx
	}
	out := d.Entries[d.idx : d.idx+n]
	d.idx += n
	return out, nil
}

// FSFileWrap adapts fs.File to fsFile for read-only embedded-FS entries.
type FSFileWrap struct{ fs.File }

func (f *FSFileWrap) Stat() (fs.FileInfo, error) {
	return f.File.Stat()
}

func (f *FSFileWrap) Seek(offset int64, whence int) (int64, error) {
	if s, ok := f.File.(io.Seeker); ok {
		return s.Seek(offset, whence)
	}
	return 0, fmt.Errorf("seek not supported")
}


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
	s.assertSingleOwner()
	if fd >= 0 && fd <= 2 {
		writeFdstat(s.mem(), statPtr, fdCharDev, rightsCharDev, rightsCharDev)
		return wasiESuccess
	}
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil && entry.fdType == 0 {
		return wasiEBadf
	}
	writeFdstat(s.mem(), statPtr, entry.fdType, rightsRegular, rightsRegular)
	return wasiESuccess
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

func (s *State) Xfd_renumber(fd, to int32) int32 {
	s.assertSingleOwner()
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
		if clean == mp {
			match = true
		} else if mp == "/" {
			match = true
		} else if strings.HasPrefix(clean, mp+"/") {
			match = true
		}
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

func (s *State) resolveDirfdPath(dirfd, pathPtr, pathLen int32) (*mountEntry, string) {
	pathBytes := s.readBytes(pathPtr, pathLen)
	guestPath := string(pathBytes)
	if strings.HasPrefix(guestPath, "/") {
		return s.resolvePath(guestPath)
	}
	if dirfd >= 0 && int(dirfd) < len(s.fds) {
		entry := s.fds[dirfd]
		if entry.preopen && entry.mount >= 0 && entry.mount < len(s.mounts) {
			return &s.mounts[entry.mount], path.Clean(guestPath)
		}
		if entry.fdType == fdDir && entry.path != "" {
			full := path.Join(entry.path, guestPath)
			return s.resolvePath(full)
		}
	}
	return nil, ""
}

func isRootMount(m *mountEntry) bool {
	return path.Clean("/"+m.guestPath) == "/"
}

func mountHostPaths(m *mountEntry, rel string) (primary, fallback string) {
	if m == nil || !m.writable || m.hostRoot == "" {
		return "", ""
	}
	joined := filepath.Join(m.hostRoot, filepath.FromSlash(rel))
	if isRootMount(m) {
		abs := "/" + filepath.FromSlash(rel)
		if abs != joined {
			return abs, joined
		}
	}
	return joined, ""
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

func (s *State) Xfd_close(fd int32) int32 {
	s.assertSingleOwner()
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	if s.fds[fd].preopen {
		return wasiEBadf
	}
	if s.fds[fd].file != nil {
		s.fds[fd].file.Close()
	}
	s.fds[fd] = fdEntry{}
	return wasiESuccess
}

func (s *State) Xfd_read(fd int32, iovsPtr int32, iovsCount int32, nreadPtr int32) int32 {
	s.assertSingleOwner()
	mem := s.mem()
	if fd == 0 {
		var total uint32
		for i := int32(0); i < iovsCount; i++ {
			off := iovsPtr + i*8
			bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
			bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
			if bufLen == 0 {
				continue
			}
			var n int
			var err error
			if s.stdin != nil {
				n, err = s.stdin.Read(mem[bufPtr : bufPtr+bufLen])
			} else {
				n, err = 0, io.EOF
			}
			total += uint32(n)
			if err != nil {
				binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
				if err != io.EOF {
					return wasiEIo
				}
				return wasiESuccess
			}
			if n < int(bufLen) {
				break
			}
		}
		binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
		return wasiESuccess
	}
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil {
		return wasiEBadf
	}
	var total uint32
	for i := int32(0); i < iovsCount; i++ {
		off := iovsPtr + i*8
		bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
		bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
		if bufLen == 0 {
			continue
		}
		var n int
		var err error
		if ra, ok := entry.file.(interface {
			ReadAt([]byte, int64) (int, error)
		}); ok {
			n, err = ra.ReadAt(mem[bufPtr:bufPtr+bufLen], entry.offset)
		} else {
			n, err = entry.file.Read(mem[bufPtr : bufPtr+bufLen])
		}
		total += uint32(n)
		entry.offset += int64(n)
		if err != nil {
			if err == io.EOF {
				break
			}
			s.fds[fd] = entry
			binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
			return wasiEIo
		}
		if n < int(bufLen) {
			break
		}
	}
	s.fds[fd] = entry
	binary.LittleEndian.PutUint32(mem[nreadPtr:], total)
	return wasiESuccess
}

func (s *State) Xfd_write(fd int32, iovsPtr int32, iovsCount int32, nwrittenPtr int32) int32 {
	s.assertSingleOwner()
	mem := s.mem()
	if fd == 1 || fd == 2 {
		var total uint32
		for i := int32(0); i < iovsCount; i++ {
			off := iovsPtr + i*8
			bufPtr := int32(binary.LittleEndian.Uint32(mem[off:]))
			bufLen := int32(binary.LittleEndian.Uint32(mem[off+4:]))
			data := mem[bufPtr : bufPtr+bufLen]
			var n int
			if fd == 1 {
				if s.stdout != nil {
					n, _ = s.stdout.Write(data)
				}
			} else {
				if s.stderr != nil {
					n, _ = s.stderr.Write(data)
				}
			}
			total += uint32(n)
		}
		binary.LittleEndian.PutUint32(mem[nwrittenPtr:], total)
		return wasiESuccess
	}
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil {
		return wasiEBadf
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
	s.fds[fd] = entry
	binary.LittleEndian.PutUint32(mem[nwrittenPtr:], total)
	return wasiESuccess
}

func (s *State) Xfd_seek(fd int32, offset int64, whence, newOffsetPtr int32) int32 {
	s.assertSingleOwner()
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.file == nil || entry.preopen {
		return wasiEBadf
	}
	if entry.fdType == fdDir {
		return wasiEIsdir
	}
	sk, ok := entry.file.(io.Seeker)
	if !ok {
		return wasiEInval
	}
	n, err := sk.Seek(offset, int(whence))
	if err != nil {
		return wasiEIo
	}
	entry.offset = n
	s.fds[fd] = entry
	binary.LittleEndian.PutUint64(s.mem()[newOffsetPtr:], uint64(n))
	return wasiESuccess
}

func (s *State) Xfd_readdir(fd int32, bufPtr int32, bufLen int32, cookie int64, bufUsedPtr int32) int32 {
	s.assertSingleOwner()
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := &s.fds[fd]
	if entry.preopen {
		if entry.mount < 0 || entry.mount >= len(s.mounts) {
			return wasiEBadf
		}
		if entry.file == nil {
			if d, ok := s.mounts[entry.mount].root.(fs.ReadDirFS); ok {
				entries, err := d.ReadDir(".")
				if err != nil {
					return wasiEIo
				}
				entry.file = &DirEntriesFile{Entries: entries}
			}
		}
	}
	if entry.file == nil {
		return wasiEBadf
	}
	if entry.dirFile == nil {
		df, ok := entry.file.(fs.ReadDirFile)
		if !ok {
			return wasiENotDir
		}
		entry.dirFile = df
	}
	mem := s.mem()
	entries, err := entry.dirFile.ReadDir(-1)
	if err != nil && err != io.EOF {
		return wasiEIo
	}
	if len(entries) == 0 {
		binary.LittleEndian.PutUint32(mem[bufUsedPtr:], 0)
		return wasiESuccess
	}
	var dUsed uint32
	for i := int(cookie); i < len(entries); i++ {
		name := entries[i].Name()
		dNameLen := uint32(len(name))
		dEntryLen := uint32(24 + dNameLen)
		if dUsed+dEntryLen > uint32(bufLen) {
			break
		}
		off := bufPtr + int32(dUsed)
		binary.LittleEndian.PutUint64(mem[off:], uint64(i+1))
		binary.LittleEndian.PutUint64(mem[off+8:], 0)
		binary.LittleEndian.PutUint32(mem[off+16:], dNameLen)
		var ftype byte
		if entries[i].IsDir() {
			ftype = fdDir
		} else {
			ftype = fdFile
		}
		binary.LittleEndian.PutUint32(mem[off+20:], uint32(ftype))
		copy(mem[off+24:], name)
		dUsed += dEntryLen
	}
	binary.LittleEndian.PutUint32(mem[bufUsedPtr:], dUsed)
	return wasiESuccess
}

func (s *State) Xfd_filestat_get(fd, bufPtr int32) int32 {
	s.assertSingleOwner()
	if fd < 0 || int(fd) >= len(s.fds) {
		return wasiEBadf
	}
	entry := s.fds[fd]
	if entry.preopen {
		if entry.mount < 0 || entry.mount >= len(s.mounts) {
			return wasiEBadf
		}
		fi, err := fs.Stat(s.mounts[entry.mount].root, ".")
		if err != nil {
			return wasiEIo
		}
		writeFilestat(s.mem(), bufPtr, fdDir, fi.Size(), fi.ModTime().UnixNano())
		return wasiESuccess
	}
	if entry.file == nil {
		return wasiEBadf
	}
	fi, err := entry.file.Stat()
	if err != nil {
		return wasiEIo
	}
	writeFilestat(s.mem(), bufPtr, entry.fdType, fi.Size(), fi.ModTime().UnixNano())
	return wasiESuccess
}

func (s *State) Xpath_filestat_get(dirfd, flags, pathPtr, pathLen, bufPtr int32) int32 {
	mount, relPath := s.resolveDirfdPath(dirfd, pathPtr, pathLen)
	if mount == nil {
		return wasiENoEnt
	}
	var fi fs.FileInfo
	if mount.writable && mount.hostRoot != "" {
		primary, cwdFallback := mountHostPaths(mount, relPath)
		var osErr error
		fi, osErr = os.Stat(primary)
		if osErr != nil && cwdFallback != "" {
			fi, osErr = os.Stat(cwdFallback)
		}
		if osErr != nil {
			var fsErr error
			fi, fsErr = fs.Stat(mount.root, relPath)
			if fsErr != nil {
				return wasiENoEnt
			}
		}
	} else {
		var fsErr error
		fi, fsErr = fs.Stat(mount.root, relPath)
		if fsErr != nil {
			return wasiENoEnt
		}
	}
	fdType := fdFile
	if fi.IsDir() {
		fdType = fdDir
	}
	writeFilestat(s.mem(), bufPtr, fdType, fi.Size(), fi.ModTime().UnixNano())
	return wasiESuccess
}

func (s *State) Xpath_open(dirfd int32, lookupFlags int32, pathPtr int32, pathLen int32, oflags int32, fdRightsBase int64, fdRightsInheriting int64, fdFlags int32, fdPtr int32) int32 {
	s.assertSingleOwner()
	pathBytes := s.readBytes(pathPtr, pathLen)
	guestPath := string(pathBytes)
	mem := s.mem()
	if guestPath == "/dev/null" {
		fd := s.allocFD()
		s.fds[fd] = fdEntry{fdType: fdCharDev, path: "/dev/null"}
		binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
		return wasiESuccess
	}
	mount, relPath := s.resolveDirfdPath(dirfd, pathPtr, pathLen)
	if mount == nil {
		return wasiENoEnt
	}
	var f fs.File
	var err error
	if mount.writable {
		primary, cwdFallback := mountHostPaths(mount, relPath)
		if primary == "" {
			primary = relPath
		}
		hostPath := primary
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
		if osErr != nil && cwdFallback != "" {
			hostFile, osErr = os.OpenFile(cwdFallback, osFlags, 0o666)
		}
		if osErr != nil {
			if uint32(oflags)&(oflagCreat|oflagTrunc|oflagExcl) == 0 {
				f, err = mount.root.Open(relPath)
				if err != nil {
					return wasiENoEnt
				}
				fi, _ := f.Stat()
				fdType := fdFile
				if fi != nil && fi.IsDir() {
					fdType = fdDir
				}
				fd := s.allocFD()
				entryPath := guestPath
				if fdType == fdDir {
					entryPath = path.Clean("/" + mount.guestPath + "/" + relPath)
				}
				entry := fdEntry{file: &FSFileWrap{File: f}, path: entryPath, fdType: fdType}
				if fdType == fdDir {
					if df, ok := f.(fs.ReadDirFile); ok {
						entry.dirFile = df
					}
				}
				s.fds[fd] = entry
				binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
				return wasiESuccess
			}
			return wasiENoEnt
		}
		fi, _ := hostFile.Stat()
		fd := s.allocFD()
		entryPath := guestPath
		if fi != nil && fi.IsDir() {
			entryPath = path.Clean("/" + mount.guestPath + "/" + relPath)
		}
		s.fds[fd] = fdEntry{file: &osFile{File: hostFile}, path: entryPath, fdType: fdFile}
		if fi != nil && fi.IsDir() {
			s.fds[fd].fdType = fdDir
		}
		binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
		return wasiESuccess
	}
	f, err = mount.root.Open(relPath)
	if err != nil {
		return wasiENoEnt
	}
	fi, _ := f.Stat()
	fdType := fdFile
	if fi != nil && fi.IsDir() {
		fdType = fdDir
	}
	fd := s.allocFD()
	savedPath := guestPath
	if !strings.HasPrefix(savedPath, "/") {
		if dirfd >= 0 && int(dirfd) < len(s.fds) {
			parent := s.fds[dirfd]
			if parent.path != "" {
				savedPath = path.Join(parent.path, guestPath)
			}
		}
	}
	entry := fdEntry{file: &FSFileWrap{File: f}, path: savedPath, fdType: fdType}
	if fdType == fdDir {
		if df, ok := f.(fs.ReadDirFile); ok {
			entry.dirFile = df
		}
	}
	s.fds[fd] = entry
	binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
	return wasiESuccess
}

func (s *State) Xpath_rename(oldDirfd, oldPathPtr, oldPathLen, newDirfd, newPathPtr, newPathLen int32) int32 {
	oldMount, oldRel := s.resolveDirfdPath(oldDirfd, oldPathPtr, oldPathLen)
	newMount, newRel := s.resolveDirfdPath(newDirfd, newPathPtr, newPathLen)
	if oldMount == nil || newMount == nil {
		return wasiENoEnt
	}
	oldPrimary, oldFallback := mountHostPaths(oldMount, oldRel)
	newPrimary, newFallback := mountHostPaths(newMount, newRel)
	if oldPrimary == "" || newPrimary == "" {
		return wasiEROFS
	}
	if oldFallback != "" {
		if _, err := os.Stat(oldPrimary); err != nil {
			oldPrimary, newPrimary = oldFallback, newFallback
		}
	}
	if err := os.Rename(oldPrimary, newPrimary); err != nil {
		return wasiEIo
	}
	return wasiESuccess
}

func (s *State) Xpoll_oneoff(inPtr int32, outPtr int32, nsubscriptions int32, neventsPtr int32) int32 {
	s.assertSingleOwner()
	mem := s.mem()
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
			if fd < 0 || fd >= int32(len(s.fds)) {
				errno = uint32(wasiEBadf)
			}
		case 2: // fd_write
			fd := int32(binary.LittleEndian.Uint32(mem[subOff+8:]))
			if fd < 0 || fd >= int32(len(s.fds)) {
				errno = uint32(wasiEBadf)
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
	return wasiESuccess
}

// Xenv interface — returns 0 (no-op for the host function call bridge)
func (s *State) Xcall_host_function(v0, v1, v2 int32) int32 { return 0 }

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
			break
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
func (s *State) Xfd_sync(fd int32) int32                                       { return wasiESuccess }
func (s *State) Xfd_fdstat_set_flags(fd, flags int32) int32                    { return wasiESuccess }
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
	if entry.fdType == 0 {
		return wasiEBadf
	}
	if of, ok := entry.file.(*osFile); ok {
		if err := of.Truncate(size); err != nil {
			return int32(mapOSError(err))
		}
	}
	return wasiESuccess
}
func (s *State) Xfd_filestat_set_times(fd int32, atim, mtim int64, fstFlags int32) int32 {
	if fstFlags&2 == 0 {
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
	atime := time.Now()
	if err := os.Chtimes(path, atime, mtime); err != nil {
		return int32(mapOSError(err))
	}
	return wasiESuccess
}

func (s *State) ResolvePath(guestPath string) (*mountEntry, string) {
	return s.resolvePath(guestPath)
}

func (s *State) ReadBytes(ptr, length int32) []byte {
	return s.readBytes(ptr, length)
}

func (s *State) AssertSingleOwner() {
	s.assertSingleOwner()
}

func (s *State) LogTrace(format string, args ...interface{}) {
	s.logTrace(format, args...)
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

const (
	WasiESuccess = wasiESuccess
	WasiEBadf    = wasiEBadf
	WasiENoSys   = wasiENoSys
	WasiEROFS    = wasiEROFS
)



