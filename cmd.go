package exiftool

import (
	"context"
	"errors"
	"io"
	"os"
)

// Command runs a single ExifTool invocation. The caller's working directory is
// mounted writable at "/" via a WASI host directory preopen, and [os.TempDir] is
// mounted read-write for ExifTool side effects. stdin is forwarded to ExifTool's
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

	guestIO := newDirectIO(stdin)
	mod, ws, err := newModule(guestIO, nil, []string{os.TempDir()})
	if err != nil {
		return nil, err
	}
	args := commandArgs(arg)
	out, err = evalModule(mod, ws, args...)
	if err != nil {
		return out, err
	}

	if dio, ok := ws.guestIO.(*directIO); ok && dio.StderrB.Len() > 0 {
		return out, errors.New("exiftool: " + dio.StderrB.String())
	}
	return out, nil
}
