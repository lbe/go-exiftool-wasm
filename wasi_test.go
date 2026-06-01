//go:build integration

package exiftool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lbe/go-exiftool-wasm/internal/testutil"
)

func TestWASISeekTell(t *testing.T) {
	runSeekTellScript(t, t.TempDir(), []string{
		"tell_open:0",
		"tell_seek:5",
		"tell_write:8",
		"content:AAAAABBBAA",
	})
}

func TestWASISeekTellEvalSymlinksPreopenPath(t *testing.T) {
	tmpDir := t.TempDir()
	canonical, err := filepath.EvalSymlinks(tmpDir)
	if err != nil {
		t.Fatalf("EvalSymlinks temp dir: %v", err)
	}
	if canonical == tmpDir {
		t.Skip("EvalSymlinks does not alter temp dir path on this platform")
	}

	runSeekTellScript(t, canonical, []string{
		"tell_open:0",
		"tell_seek:5",
		"tell_write:8",
		"content:AAAAABBBAA",
	})
}

const seekTellScript = `
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

func runSeekTellScript(t *testing.T, hostDir string, wantLines []string) {
	t.Helper()

	out, err := evalTestPerl(seekTellScript, hostDir)
	if err != nil {
		t.Fatal(err)
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for i, want := range wantLines {
		if i >= len(lines) {
			t.Fatalf("missing output line %d: want %q, got %d lines: %q", i, want, len(lines), lines)
		}
		if lines[i] != want {
			t.Errorf("line %d: got %q, want %q", i, lines[i], want)
		}
	}
}

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

	want := []string{"tell1:3", "tell2:6", "tell3:9", "content:AAABBBCCC"}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for i, exp := range want {
		if i >= len(lines) || lines[i] != exp {
			t.Fatalf("line %d: got %v, want %q", i, lines, exp)
		}
	}
}

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

	want := []string{"tell:6", "content:GHIJ"}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for i, exp := range want {
		if i >= len(lines) || lines[i] != exp {
			t.Fatalf("line %d: got %v, want %q", i, lines, exp)
		}
	}
}

func TestCommandAbsolutePathOutsideCwd(t *testing.T) {
	dir := t.TempDir()
	dst := filepath.Join(dir, "sample.jpg")

	src, err := os.ReadFile(testutil.SampleJPEG(t))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if err = os.WriteFile(dst, src, 0o644); err != nil {
		t.Fatalf("write fixture copy: %v", err)
	}

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	cwdReal, _ := filepath.EvalSymlinks(cwd)
	dstReal, _ := filepath.EvalSymlinks(dst)
	if strings.HasPrefix(dstReal, cwdReal+string(filepath.Separator)) {
		t.Skipf("t.TempDir() %q is under cwd %q; not-under-cwd case cannot be verified", dst, cwd)
	}

	out, err := Command(nil, "-Artist", "-Copyright", dst)
	assertArtistCopyright(t, out, err)
}

func TestCommandAbsolutePathUnderCwd(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(cwd, "testdata", "sample.jpg")
	out, err := Command(nil, "-Artist", "-Copyright", dst)
	assertArtistCopyright(t, out, err)
}

func TestCommandAbsolutePathMultipleFiles(t *testing.T) {
	dir := t.TempDir()
	outside := filepath.Join(dir, "sample.jpg")
	src, err := os.ReadFile(testutil.SampleJPEG(t))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if err = os.WriteFile(outside, src, 0o644); err != nil {
		t.Fatalf("write fixture copy: %v", err)
	}

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	under := filepath.Join(cwd, "testdata", "sample.jpg")

	if _, err := Command(nil, "-Artist", outside, under); err != nil {
		t.Fatalf("Command with mixed absolute paths: %v", err)
	}
}

func assertArtistCopyright(t *testing.T, out []byte, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("Command: %v", err)
	}
	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if got, want := string(m["Artist"]), "Test Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
	if got, want := string(m["Copyright"]), "Test Copyright 2024"; got != want {
		t.Errorf("Copyright: got %q, want %q", got, want)
	}
}

func TestEvalPerlStdoutOnNonZeroExit(t *testing.T) {
	out, err := evalTestPerl("print \"payload\\n\"; exit 1;")
	if len(out) == 0 || !strings.Contains(string(out), "payload") {
		t.Fatalf("expected stdout payload on non-zero exit, got out=%q err=%v", out, err)
	}
	if err == nil {
		t.Fatal("expected error for non-zero exit")
	}
	if !strings.Contains(err.Error(), "exit") {
		t.Errorf("error = %v, want exit-related message", err)
	}
}
