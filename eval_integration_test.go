//go:build integration

package exiftool

import (
	"encoding/binary"
	"fmt"
	"os"
)

// scriptPreamble returns the prefix for arbitrary Perl in integration tests. It
// enables autoflush on STDOUT and STDERR, chdirs to the guest path cwd, and
// restores the default output handle. Production ExifTool paths use
// exiftoolEvalWrapper instead.
func scriptPreamble(cwd string) string {
	return "BEGIN { my $old = select(STDOUT); $| = 1; select(STDERR); $| = 1; select($old); chdir " + perlQuote(cwd) + " or die $!; }\n"
}

// evalTestPerl evaluates an arbitrary Perl script through the zeroperl wasm2go
// module and returns stdout output. The script is prepended with scriptPreamble
// (chdir to the guest path of the host cwd). args are passed as @ARGV. Host
// paths are reachable through the root preopen.
func evalTestPerl(script string, args ...string) (stdout []byte, err error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	guestIO := newDirectIO(nil)
	mod, ws, err := newModuleAt(guestIO, cwd, nil)
	if err != nil {
		return nil, err
	}

	defer func() {
		if r := recover(); r != nil {
			if ep, ok := r.(exitPanic); ok {
				if ep.code == 0 {
					if dio, ok := ws.guestIO.(*directIO); ok {
						stdout = append([]byte(nil), dio.StdoutB.Bytes()...)
					}
					return
				}
				stdout = guestStdoutOnExit(ws.guestIO)
				stderrStr := ""
				if dio, ok := ws.guestIO.(*directIO); ok {
					stderrStr = dio.StderrB.String()
				}
				err = &exitError{
					Code: int(ep.code),
					Msg:  fmt.Sprintf("perl exit %d\nstderr: %s", ep.code, stderrStr),
				}
			} else {
				panic(r)
			}
		}
	}()

	rc := mod.Xzeroperl_init()
	if rc != 0 {
		return nil, fmt.Errorf("zeroperl_init returned %d", rc)
	}

	mem := ws.mem()
	fullScript := scriptPreamble(ws.cwd) + script
	scriptPtr := mod.Xmalloc(int32(len(fullScript) + 1))
	copy(mem[scriptPtr:], fullScript)
	mem[scriptPtr+int32(len(fullScript))] = 0
	defer mod.Xfree(scriptPtr)

	argPtrs := make([]int32, len(args))
	for i, arg := range args {
		b := append([]byte(arg), 0)
		argPtrs[i] = mod.Xmalloc(int32(len(b)))
		copy(mem[argPtrs[i]:], b)
	}
	defer func() {
		for _, p := range argPtrs {
			mod.Xfree(p)
		}
	}()

	var argvPtr int32
	if len(argPtrs) > 0 {
		argvPtr = mod.Xmalloc(int32(len(argPtrs) * 4))
		for i, p := range argPtrs {
			binary.LittleEndian.PutUint32(mem[argvPtr+int32(i*4):], uint32(p))
		}
		defer mod.Xfree(argvPtr)
	}

	mod.Xzeroperl_eval(scriptPtr, 1, int32(len(args)), argvPtr)
	if dio, ok := ws.guestIO.(*directIO); ok {
		stdout = append([]byte(nil), dio.StdoutB.Bytes()...)
	}
	return stdout, nil
}
