package wasihost

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
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

func (s *State) Xenviron_sizes_get(countPtr, bufSizePtr int32) int32 { return 0 }
func (s *State) Xenviron_get(envPtr, envBufPtr int32) int32          { return 0 }
func (s *State) Xfd_prestat_get(fd, prestatPtr int32) int32          { return 0 }
func (s *State) Xfd_prestat_dir_name(fd, pathPtr, pathLen int32) int32 { return 0 }
func (s *State) Xfd_fdstat_get(fd, statPtr int32) int32              { return 0 }
func (s *State) Xfd_renumber(fd, to int32) int32                     { return 0 }
func (s *State) Xproc_exit(code int32)                               {} // stub: does NOT panic
func (s *State) Xrandom_get(bufPtr, bufLen int32) int32              { return 0 }
func (s *State) resolvePath(guestPath string) (*mountEntry, string)  { return nil, "" }

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
