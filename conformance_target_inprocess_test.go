// IMMUTABLE: conformance infrastructure. It selects the implementation under
// test: this package with -tags integration, github.com/ncruces/go-exiftool with
// -tags ncruces.
// Do not edit; see the header of conformance_contract_test.go.

//go:build integration && !ncruces

package exiftool_test

import (
	"context"
	"io"

	impl "github.com/lbe/go-exiftool-wasm"
)

const (
	target   = "wasm"
	implPath = "github.com/lbe/go-exiftool-wasm"
)

var (
	Exec   = "exiftool"
	Arg1   string
	Config string
)

type Server = impl.Server

func syncVars() { impl.Exec, impl.Arg1, impl.Config = Exec, Arg1, Config }

func Command(stdin io.Reader, arg ...string) ([]byte, error) {
	syncVars()
	return impl.Command(stdin, arg...)
}

func CommandContext(ctx context.Context, stdin io.Reader, arg ...string) ([]byte, error) {
	syncVars()
	return impl.CommandContext(ctx, stdin, arg...)
}

func Unmarshal(data []byte, m map[string][]byte) error { return impl.Unmarshal(data, m) }

func NewServer(commonArg ...string) (*Server, error) {
	syncVars()
	return impl.NewServer(commonArg...)
}
