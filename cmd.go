package exiftool

import (
	"context"
	"errors"
	"io"
	"os"
)

// Command runs a single ExifTool invocation. The caller's working directory is
// preopened writable at "/host" (wasihost.WithHostDirectoryPreopen), and
// [os.TempDir] is preopened the same way for ExifTool side effects. stdin is
// forwarded to guest fd 0 via guestIO; pass nil if no input is required.
//
// It uses [context.Background]; for cancellation see [CommandContext].
func Command(stdin io.Reader, arg ...string) ([]byte, error) {
	return CommandContext(context.Background(), stdin, arg...)
}

// CommandContext is like [Command] but returns ctx.Err immediately if ctx is already
// cancelled when the call begins. Once WASM evaluation starts, ctx cancellation is
// not honored; the guest runs to completion or proc_exit.
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
