package wasihost

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"syscall"
)

type State struct {
	mem func() []byte
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
