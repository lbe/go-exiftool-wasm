//go:build integration

package exiftool

import (
	"os"
	"strings"
	"testing"
)

// TestMountPreopenDoesNotAliasSplitMounts verifies that the writable /host
// host-directory preopen does not resolve relative paths into the read-only
// /lib and /bin mounts. Split preopens must stay isolated: embedded assets are
// reachable only through their dedicated mount prefixes.
func TestMountPreopenDoesNotAliasSplitMounts(t *testing.T) {
	if _, err := os.Stat("bin/exiftool"); err == nil {
		t.Skip("host cwd contains bin/exiftool; split-preopen isolation cannot be verified")
	}
	if _, err := os.Stat("lib/perl5/Image/ExifTool.pm"); err == nil {
		t.Skip("host cwd contains lib/perl5/Image/ExifTool.pm; split-preopen isolation cannot be verified")
	}

	const script = `
print "rel_bin:" . (-e 'bin/exiftool' ? "yes" : "no") . "\n";
print "abs_bin:" . (-e '/bin/exiftool' ? "yes" : "no") . "\n";
print "rel_lib:" . (-e 'lib/perl5/Image/ExifTool.pm' ? "yes" : "no") . "\n";
print "abs_lib:" . (-e '/lib/perl5/Image/ExifTool.pm' ? "yes" : "no") . "\n";
`

	out, err := evalTestPerl(script)
	if err != nil {
		t.Fatalf("eval perl: %v", err)
	}

	got := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		key, val, ok := strings.Cut(line, ":")
		if !ok {
			t.Fatalf("unexpected output line %q", line)
		}
		got[key] = val
	}

	want := map[string]string{
		"rel_bin": "no",
		"abs_bin": "yes",
		"rel_lib": "no",
		"abs_lib": "yes",
	}
	for key, wantVal := range want {
		if got[key] != wantVal {
			t.Errorf("%s: got %q, want %q", key, got[key], wantVal)
		}
	}
}
