package exiftool

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
)

// ExitError reports that ExifTool exited with a non-zero status, or that its -json
// output has a per-file Error field, for which native exiftool exits with status
// 1. The function that returns an ExitError also returns the stdout ExifTool
// wrote.
type ExitError struct {
	Code int    // exit status
	Msg  string // error text; after a non-zero exit it includes stderr
}

// Error returns Msg, or a message with Code if Msg is empty.
func (e *ExitError) Error() string {
	if e.Msg != "" {
		return e.Msg
	}
	return fmt.Sprintf("exiftool exited with code %d", e.Code)
}

// Command runs one ExifTool command in a new interpreter and returns its stdout.
// ExifTool receives arg unchanged, after [Arg1], [Config] and
// "-charset filename=utf8". stdin becomes ExifTool's standard input; pass nil if
// the command does not read it.
//
// A non-zero exit returns stdout and an [*ExitError]. With -json, a per-file Error
// field also returns an *ExitError with Code 1. If ExifTool exits with status 0
// but writes to stderr, Command returns stdout and an error that holds the stderr
// text.
//
// Command uses [context.Background]. See [CommandContext].
func Command(stdin io.Reader, arg ...string) ([]byte, error) {
	return CommandContext(context.Background(), stdin, arg...)
}

// CommandContext is like [Command], but if ctx is already done it returns ctx.Err()
// without running ExifTool. Once the interpreter starts, it ignores ctx and runs
// until ExifTool exits.
func CommandContext(ctx context.Context, stdin io.Reader, arg ...string) (out []byte, err error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	return commandEvalModule(stdin, arg...)
}

// commandEvalModule runs one command in a new module whose guest cwd is the
// process working directory, and turns the result into Command's return values.
func commandEvalModule(stdin io.Reader, arg ...string) ([]byte, error) {
	guestIO := newDirectIO(stdin)
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	mod, ws, err := newModuleAt(guestIO, cwd, nil)
	if err != nil {
		return nil, err
	}
	out, err := evalModule(mod, ws, commandArgs(arg)...)
	if err != nil {
		if finished, finishErr := finishCommandResult(out, arg); finishErr != nil {
			return finished, finishErr
		}
		return out, err
	}

	if dio, ok := ws.guestIO.(*directIO); ok && dio.StderrB.Len() > 0 {
		return out, errors.New("exiftool: " + dio.StderrB.String())
	}
	return finishCommandResult(out, arg)
}

// finishCommandResult returns out with an *ExitError with Code 1 when -json output
// reports a per-file error, and with a nil error otherwise.
func finishCommandResult(out []byte, arg []string) ([]byte, error) {
	if code := jsonRecordsExitCode(out, arg); code != 0 {
		return out, &ExitError{
			Code: code,
			Msg:  "exiftool exited with code 1",
		}
	}
	return out, nil
}

// jsonRecordsExitCode returns 1 when args request JSON and a record in out has an
// Error field, as native exiftool's exit status does. Otherwise it returns 0.
func jsonRecordsExitCode(out []byte, args []string) int {
	if !hasJSONFlag(args) || len(out) == 0 {
		return 0
	}
	var records []map[string]any
	if err := json.Unmarshal(out, &records); err != nil {
		return 0
	}
	for _, rec := range records {
		if _, ok := rec["Error"]; ok {
			return 1
		}
	}
	return 0
}

// hasJSONFlag reports whether args contain -json, -j or -json=.
func hasJSONFlag(args []string) bool {
	for _, a := range args {
		if a == "-json" || a == "-j" || a == "-json=" {
			return true
		}
	}
	return false
}
