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

type State struct {
	mem       func() []byte
	fds       []fdEntry
	preopens  []fdEntry
	mounts    []mountEntry
	env       []string
	startTime time.Time // for Cycle 3 — declare here
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

func WithArgs(args ...string) Option                             { return func(*State) {} }
func WithEnv(env ...string) Option                               { return func(*State) {} }
func WithMount(guestPath string, root fs.FS) Option                   { return func(*State) {} }
func WithWritableMount(guestPath, hostRoot string, root fs.FS) Option { return func(*State) {} }
func WithStdin(r io.Reader) Option                               { return func(*State) {} }
func WithStdout(w io.Writer) Option                              { return func(*State) {} }
func WithStderr(w io.Writer) Option                              { return func(*State) {} }
func WithTracing() Option                                        { return func(*State) {} }
func WithOwnerAssertion() Option                                 { return func(*State) {} }

func (s *State) getMem() []byte { return s.mem() }

func (s *State) Xenviron_sizes_get(countPtr, bufSizePtr int32) int32 {
	mem := s.mem()
	binary.LittleEndian.PutUint32(mem[countPtr:], uint32(len(s.env)))
	var total uint32
	for _, e := range s.env {
		total += uint32(len(e)) + 1
	}
	binary.LittleEndian.PutUint32(mem[bufSizePtr:], total)
	return 0
}
func (s *State) Xenviron_get(envPtr, envBufPtr int32) int32 {
	mem := s.mem()
	bufOff := uint32(envBufPtr)
	for i, e := range s.env {
		binary.LittleEndian.PutUint32(mem[envPtr+int32(i*4):], bufOff)
		n := copy(mem[bufOff:], e)
		mem[bufOff+uint32(n)] = 0
		bufOff += uint32(n) + 1
	}
	return 0
}
func (s *State) Xfd_prestat_get(fd, prestatPtr int32) int32 {
	idx := fd - 3
	if idx < 0 || idx >= int32(len(s.preopens)) {
		return 8 // EBADF
	}
	mem := s.mem()
	pathLen := uint32(len(s.preopens[idx].path))
	binary.LittleEndian.PutUint32(mem[prestatPtr:], 0)
	binary.LittleEndian.PutUint32(mem[prestatPtr+4:], pathLen)
	return 0
}
func (s *State) Xfd_prestat_dir_name(fd, pathPtr, pathLen int32) int32 {
	idx := fd - 3
	if idx < 0 || idx >= int32(len(s.preopens)) {
		return 8
	}
	mem := s.mem()
	name := s.preopens[idx].path
	copy(mem[pathPtr:], name)
	return 0
}
func (s *State) Xfd_fdstat_get(fd, statPtr int32) int32 {
	if fd < 0 || int(fd) >= len(s.fds) {
		return 8 // EBADF
	}
	entry := s.fds[fd]
	if entry.file == nil && entry.fdType == 0 {
		return 8 // EBADF
	}
	mem := s.mem()
	var buf [24]byte
	binary.LittleEndian.PutUint16(buf[0:], uint16(entry.fdType))
	copy(mem[statPtr:], buf[:])
	return 0
}
func (s *State) Xfd_renumber(fd, to int32) int32 {
	if fd < 0 || int(fd) >= len(s.fds) || to < 0 || int(to) >= len(s.fds) {
		return 8
	}
	s.fds[to] = s.fds[fd]
	s.fds[fd] = fdEntry{}
	return 0
}
func (s *State) Xproc_exit(code int32) {
	panic(ExitError{Code: code})
}
func (s *State) Xrandom_get(bufPtr, bufLen int32) int32 {
	mem := s.mem()
	rand.Read(mem[bufPtr : bufPtr+bufLen])
	return 0
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
