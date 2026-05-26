package exiftool_test

import (
	"bytes"
	"strconv"
	"testing"

	"github.com/lbe/go-exiftool-wasm"
)

// TestCycle2_CommandVer verifies that ExifTool starts and reports a version
// using the new mount configuration (separate read-only /lib, /bin mounts and
// writable host directory preopen at /).
func TestCycle2_CommandVer(t *testing.T) {
	out, err := exiftool.Command(nil, "-ver")
	if err != nil {
		t.Fatalf("Command -ver: %v", err)
	}
	ver, err := strconv.ParseFloat(string(bytes.TrimSpace(out)), 64)
	if err != nil {
		t.Fatalf("parse version %q: %v", string(out), err)
	}
	if ver < 1 {
		t.Fatalf("unexpected version: %f", ver)
	}
}

// TestCycle2_CommandReadTags verifies that ExifTool can read metadata tags
// from a file using the new mount configuration.
func TestCycle2_CommandReadTags(t *testing.T) {
	out, err := exiftool.Command(nil, "-Artist", "-Copyright", "testdata/sample.jpg")
	if err != nil {
		t.Fatalf("Command read tags: %v", err)
	}
	m := make(map[string][]byte)
	if err := exiftool.Unmarshal(out, m); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if got, want := string(m["Artist"]), "Test Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
	if got, want := string(m["Copyright"]), "Test Copyright 2024"; got != want {
		t.Errorf("Copyright: got %q, want %q", got, want)
	}
}
