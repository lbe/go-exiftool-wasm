package wasihost

import (
    "io"
    "io/fs"
)

type State struct{}
type Option func(*State)
type ExitError struct{ Code int32 }

func (e ExitError) Error() string { return "" }  // stub: returns empty — test will fail

func New(mem func() []byte, opts ...Option) *State { return nil }  // stub: returns nil — test will fail

func WithArgs(args ...string) Option          { return func(*State) {} }
func WithEnv(env ...string) Option            { return func(*State) {} }
func WithMount(path string, root fs.FS) Option { return func(*State) {} }
func WithWritableMount(path, hostRoot string, root fs.FS) Option { return func(*State) {} }
func WithStdin(r io.Reader) Option            { return func(*State) {} }
func WithStdout(w io.Writer) Option           { return func(*State) {} }
func WithStderr(w io.Writer) Option           { return func(*State) {} }
func WithTracing() Option                     { return func(*State) {} }
func WithOwnerAssertion() Option              { return func(*State) {} }

func mapOSError(err error) uint32 { return 0 }  // stub: returns 0 — test will fail
