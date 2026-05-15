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
