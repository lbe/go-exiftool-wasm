package exiftool

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
)

// ExitError reports a non-zero ExifTool exit status. Out may contain stdout
// (for example -json output with per-file Error fields) when the guest exited
// before the Go caller could read it from a successful return path.
type ExitError struct {
	Code int
	Msg  string
}

func (e *ExitError) Error() string {
	if e.Msg != "" {
		return e.Msg
	}
	return fmt.Sprintf("exiftool exited with code %d", e.Code)
}

// Command runs a single ExifTool invocation via a one-shot eval module. The
// caller's working directory is preopened writable at "/host"; [os.TempDir] and
// parent directories of file operands outside cwd/temp are preopened via
// [commandWritableDirs] (writable mounts; see package docs). File operands are
// rewritten to host-absolute paths before ExifTool runs. stdin is forwarded to
// guest fd 0; pass nil if unused.
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

	return commandEvalModule(stdin, arg...)
}

// usesEvalModulePath reports whether args use -@ - to read ExifTool arguments from
// stdin. [Command] always evaluates the module once with direct stdio; this helper
// identifies the -@ - argv pattern used by tests and stay_open startup framing.
func usesEvalModulePath(stdin io.Reader, arg []string) bool {
	for i := 0; i < len(arg); i++ {
		if arg[i] != "-@" {
			continue
		}
		if i+1 < len(arg) && arg[i+1] == "-" {
			return stdin != nil
		}
	}
	return false
}

func commandEvalModule(stdin io.Reader, arg ...string) ([]byte, error) {
	guestIO := newDirectIO(stdin)
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	writableDirs, argv := prepareCommandEval(cwd, arg)
	mod, ws, err := newModuleAt(guestIO, cwd, nil, writableDirs)
	if err != nil {
		return nil, err
	}
	out, err := evalModule(mod, ws, argv...)
	if err != nil {
		if out, finishErr := finishCommandResult(out, arg); finishErr != nil {
			return out, finishErr
		}
		return out, err
	}

	if dio, ok := ws.guestIO.(*directIO); ok && dio.StderrB.Len() > 0 {
		return out, errors.New("exiftool: " + dio.StderrB.String())
	}
	return finishCommandResult(out, arg)
}

func finishCommandResult(out []byte, arg []string) ([]byte, error) {
	if code := jsonRecordsExitCode(out, arg); code != 0 {
		return out, &ExitError{
			Code: code,
			Msg:  "exiftool exited with code 1",
		}
	}
	return out, nil
}

// jsonRecordsExitCode returns 1 when -json output includes a per-file Error
// field, matching system exiftool exit status for those files.
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

func hasJSONFlag(args []string) bool {
	for _, a := range args {
		if a == "-json" || a == "-j" || a == "-json=" {
			return true
		}
	}
	return false
}
