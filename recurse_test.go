//go:build integration

package exiftool

import (
	"errors"
	"slices"
	"strings"
	"testing"
)

// TestCommandDirectory verifies that ExifTool processes every file in a
// directory argument without recursing into subdirectories (-r not used).
func TestCommandDirectory(t *testing.T) {
	out, err := Command(nil, "-T", "-Filename", "testdata")
	assertCommandFilenameList(t, out, err, []string{
			"base.jpg",
			"empty.jpg",
			"sample.jpg",
			"sample.png",
			"sample.tiff",
			"sample_gps.jpg",
			"sample_noexif.jpg",
			"test.jpg",
	}, func(t *testing.T, lines []string) {
		for _, line := range lines {
			if strings.Contains(line, "/") {
				t.Fatalf("directory scan must not recurse; got path %q", line)
			}
		}
	})
}

// TestCommandRecurse verifies that the WASI guest correctly enumerates
// nested directories when ExifTool is invoked with -r -ext jpg.
func TestCommandRecurse(t *testing.T) {
	out, err := Command(nil, "-r", "-ext", "jpg", "-T", "-Filename", "testdata/tree")
	assertCommandFilenameList(t, out, err, []string{"a.jpg", "empty.jpg", "c.jpg", "d.jpg"}, nil)
}

// assertCommandFilenameList checks Command stdout for -T -Filename output: one
// line per expected basename. Exit code 1 is allowed when empty.jpg is present.
func assertCommandFilenameList(t *testing.T, out []byte, err error, want []string, extra func(*testing.T, []string)) {
	t.Helper()

	got := strings.TrimSpace(string(out))
	if got == "" {
		t.Fatalf("expected non-empty output (err=%v)", err)
	}
	if err != nil {
		var exitErr *ExitError
		if !errors.As(err, &exitErr) || exitErr.Code != 1 {
			t.Fatalf("Command: %v\noutput:\n%s", err, got)
		}
	}

	lines := strings.Split(got, "\n")
	if len(lines) != len(want) {
		t.Fatalf("expected %d filename lines, got %d:\n%s", len(want), len(lines), got)
	}
	for _, name := range want {
		if !slices.Contains(lines, name) {
			t.Fatalf("missing %q in output lines %v", name, lines)
		}
	}
	if extra != nil {
		extra(t, lines)
	}
}
