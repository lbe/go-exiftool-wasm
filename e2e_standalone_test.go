package exiftool_test

import (
	"os"
	"testing"

	zeroperl "github.com/lbe/go-exiftool-wasm/internal/zeroperl"
	wasihost "github.com/lbe/wasi-wasm2go"
)

// Compile-time verification that *wasihost.State satisfies the zeroperl interfaces.
// If this file compiles, the interface contract is met.
var (
	_ zeroperl.Xwasi_snapshot_preview1 = (*wasihost.State)(nil)
	_ zeroperl.Xenv                    = (*wasihost.State)(nil)
)

// TestE2EStandaloneWASIHost is the acceptance test for Cycle 7.
// It verifies that the standalone wasihost module fully implements the WASI
// host interface required by go-exiftool-wasm.
//
// RED PHASE: Xpath_open stub returns ENOSYS — test fails until Green phase
// completes the implementation and wires the standalone module.
func TestE2EStandaloneWASIHost(t *testing.T) {
	buf := make([]byte, 65536*16)

	// Get the working directory (repo root) to configure the root mount.
	// This mirrors how exiftool.go sets up the WASI sandbox.
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}

	s := wasihost.New(func() []byte { return buf },
		wasihost.WithArgs("exiftool", "-json", "testdata/test.jpg"),
		wasihost.WithWritableMount("/", cwd, os.DirFS(cwd)),
	)

	// Write the path into the guest buffer at offset 100.
	path := "testdata/test.jpg"
	copy(buf[100:], path)

	// Attempt to open "testdata/test.jpg" via Xpath_open.
	// dirfd=3 is the root preopen fd (configured by WithWritableMount above).
	// RED phase: Xpath_open stub returns ENOSYS (52) — fails because:
	//   1. WithWritableMount is a no-op (no preopen created)
	//   2. Xpath_open stub always returns ENOSYS
	// GREEN phase: WithWritableMount and Xpath_open are implemented — passes.
	errno := s.Xpath_open(3, 0, 100, int32(len(path)), 0, 0, 0, 0, 200)
	if errno != 0 {
		t.Errorf("Xpath_open returned %d, want 0 (ESUCCESS)", errno)
	}
}
