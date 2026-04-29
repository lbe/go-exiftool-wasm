package exiftool

import (
	"encoding/binary"
	"fmt"
	"os"
	"strings"
	"testing"
)

// evalTestPerl evaluates an arbitrary Perl script through the zeroperl wasm2go
// module and returns stdout output. The script is prepended with autoflush
// directives. args are passed as @ARGV to the script. os.TempDir() is mounted
// read-write so the script can perform file I/O there.
func evalTestPerl(script string, args ...string) (stdout []byte, err error) {
	guestIO := NewDirectIO(nil)
	mod, ws, err := newModule(guestIO, defaultRootFS(), nil, []string{os.TempDir()})
	if err != nil {
		return nil, err
	}

	defer func() {
		if r := recover(); r != nil {
			if ep, ok := r.(exitPanic); ok {
				if ep.code == 0 {
					if dio, ok := ws.guestIO.(*DirectIO); ok {
						stdout = append([]byte(nil), dio.StdoutB.Bytes()...)
					}
					return
				}
				dio := ws.guestIO.(*DirectIO)
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
	// If we get here, Perl returned without calling proc_exit.
	// Capture stdout anyway.
	if dio, ok := ws.guestIO.(*DirectIO); ok {
		stdout = append([]byte(nil), dio.StdoutB.Bytes()...)
	}
	return stdout, nil
}

// TestWASISeekTell verifies that WASI fd_seek, fd_tell, and fd_write maintain
// correct offset tracking. Perl's seek(), tell(), and print() exercise the
// Xfd_seek, Xfd_tell, and Xfd_write WASI host functions respectively.
//
// The test creates a 10-byte file of 'A's, seeks to offset 5, writes 'BBB',
// and reads back to verify the write landed at the correct position.
//
// Expected file content: AAAAABBBAA (BBB at positions 5,6,7)
// Expected tell values:  0 after open, 5 after seek, 8 after write
func TestWASISeekTell(t *testing.T) {
	tmpDir := t.TempDir()

	script := `
my $file = $ARGV[0] . "/seektest.bin";

open(my $fh, '>', $file) or die "create: $!";
binmode($fh);
print $fh "AAAAAAAAAA";
close($fh);

open($fh, '+<', $file) or die "reopen: $!";
binmode($fh);

print "tell_open:" . tell($fh) . "\n";

seek($fh, 5, 0) or die "seek: $!";
print "tell_seek:" . tell($fh) . "\n";

print $fh "BBB";
print "tell_write:" . tell($fh) . "\n";

seek($fh, 0, 0) or die "seek_start: $!";
my $data;
read($fh, $data, 10);
print "content:" . $data . "\n";

close($fh);
unlink($file);
`

	out, err := evalTestPerl(script, tmpDir)
	if err != nil {
		t.Fatal(err)
	}

	expected := []string{
		"tell_open:0",
		"tell_seek:5",
		"tell_write:8",
		"content:AAAAABBBAA",
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for i, exp := range expected {
		if i >= len(lines) {
			t.Fatalf("missing output line %d: expected %q, got %d lines: %q", i, exp, len(lines), lines)
		}
		if lines[i] != exp {
			t.Errorf("line %d: got %q, want %q", i, lines[i], exp)
		}
	}
}

// TestWASISequentialOffset verifies that repeated writes advance the offset
// correctly without seeking. Three writes of 3 bytes each should produce
// offsets 3, 6, and a final file of "AAABBBCCC".
func TestWASISequentialOffset(t *testing.T) {
	tmpDir := t.TempDir()

	script := `
my $file = $ARGV[0] . "/seqtest.bin";

open(my $fh, '>', $file) or die "create: $!";
binmode($fh);

print $fh "AAA";
print "tell1:" . tell($fh) . "\n";

print $fh "BBB";
print "tell2:" . tell($fh) . "\n";

print $fh "CCC";
print "tell3:" . tell($fh) . "\n";

close($fh);

open($fh, '<', $file) or die "read: $!";
binmode($fh);
my $data;
read($fh, $data, 9);
print "content:" . $data . "\n";
close($fh);
unlink($file);
`

	out, err := evalTestPerl(script, tmpDir)
	if err != nil {
		t.Fatal(err)
	}

	expected := []string{
		"tell1:3",
		"tell2:6",
		"tell3:9",
		"content:AAABBBCCC",
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for i, exp := range expected {
		if i >= len(lines) {
			t.Fatalf("missing output line %d: expected %q, got %d lines: %q", i, exp, len(lines), lines)
		}
		if lines[i] != exp {
			t.Errorf("line %d: got %q, want %q", i, lines[i], exp)
		}
	}
}

// TestWASISeekFromEnd verifies SEEK_END (whence=2) works correctly by seeking
// to 4 bytes before the end of a 10-byte file and reading the last 4 bytes.
func TestWASISeekFromEnd(t *testing.T) {
	tmpDir := t.TempDir()

	script := `
my $file = $ARGV[0] . "/seekend.bin";

open(my $fh, '>', $file) or die "create: $!";
binmode($fh);
print $fh "ABCDEFGHIJ";
close($fh);

open($fh, '<', $file) or die "open: $!";
binmode($fh);

seek($fh, -4, 2) or die "seek_end: $!";
print "tell:" . tell($fh) . "\n";

my $data;
read($fh, $data, 4);
print "content:" . $data . "\n";

close($fh);
unlink($file);
`

	out, err := evalTestPerl(script, tmpDir)
	if err != nil {
		t.Fatal(err)
	}

	expected := []string{
		"tell:6",
		"content:GHIJ",
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for i, exp := range expected {
		if i >= len(lines) {
			t.Fatalf("missing output line %d: expected %q, got %d lines: %q", i, exp, len(lines), lines)
		}
		if lines[i] != exp {
			t.Errorf("line %d: got %q, want %q", i, lines[i], exp)
		}
	}
}
