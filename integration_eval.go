//go:build integration

package exiftool

import (
	"encoding/binary"
	"fmt"
	"os"
)

// scriptPreamble is prepended to arbitrary Perl in integration tests. It enables
// autoflush on STDOUT and STDERR, chdirs to hostWorkDir, and restores the default
// output handle. Production ExifTool paths use exiftoolEvalWrapper instead.
const scriptPreamble = "BEGIN { my $old = select(STDOUT); $| = 1; select(STDERR); $| = 1; select($old); chdir '" + hostWorkDir + "' or die $!; }\n"

// evalTestPerl evaluates an arbitrary Perl script through the zeroperl wasm2go
// module and returns stdout output. The script is prepended with scriptPreamble
// (chdir to /host). args are passed as @ARGV. os.TempDir() is preopened
// writable via wasihost.WithHostDirectoryPreopen for file I/O in tests.
func evalTestPerl(script string, args ...string) (stdout []byte, err error) {
	guestIO := newDirectIO(nil)
	mod, ws, err := newModule(guestIO, nil, []string{os.TempDir()})
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
				dio := ws.guestIO.(*directIO)
				err = fmt.Errorf("perl exit %d\nstderr: %s", ep.code, dio.StderrB.String())
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
	fullScript := scriptPreamble + script
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
