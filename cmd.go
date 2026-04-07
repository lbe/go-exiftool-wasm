package exiftool

import (
	"context"
	"errors"
	"io"
	"os"
)

// Command runs a single ExifTool invocation. Host paths are visible read-only
// under "/" inside the sandbox and [os.TempDir] is mounted read-write for any
// side effects ExifTool needs to perform. stdin is forwarded to ExifTool's
// standard input; pass nil if no input is required.
//
// It uses [context.Background]; for cancellation see [CommandContext].
func Command(stdin io.Reader, arg ...string) ([]byte, error) {
	return CommandContext(context.Background(), stdin, arg...)
}

// CommandContext is like [Command] but respects context cancellation. If ctx
// is already done when the call begins, it returns ctx.Err immediately.
func CommandContext(ctx context.Context, stdin io.Reader, arg ...string) (out []byte, err error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	guestIO := NewDirectIO(stdin)
	mod, ws, err := newModule(guestIO, defaultRootFS(), nil, []string{os.TempDir()})
	if err != nil {
		return nil, err
	}
	_ = mod

	args := commandArgs(arg)
	out, err = evalModule(mod, ws, args...)
	if err != nil {
		return out, err
	}

	if dio, ok := ws.guestIO.(*DirectIO); ok && dio.StderrB.Len() > 0 {
		return out, errors.New("exiftool: " + dio.StderrB.String())
	}
	return out, nil
}
