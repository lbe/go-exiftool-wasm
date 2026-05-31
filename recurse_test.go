//go:build integration

package exiftool

import (
	"strings"
	"testing"
)

// TestCommandRecurse verifies that the WASI guest correctly enumerates
// nested directories when ExifTool is invoked with -r -ext jpg.
func TestCommandRecurse(t *testing.T) {
	out, err := Command(nil, "-r", "-ext", "jpg", "-T", "-Filename", "testdata/tree")
	if err != nil {
		t.Fatalf("Command: %v", err)
	}
	got := strings.TrimSpace(string(out))
	if got == "" {
		t.Fatal("expected non-empty output: -r recursion returned nothing")
	}
	lines := strings.Split(got, "\n")
	if len(lines) != 3 {
		t.Fatalf("expected 3 jpg files, got %d lines:\n%s", len(lines), got)
	}
}
