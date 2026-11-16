//go:build e2e

package exiftool

import (
	"bytes"
	"strings"
	"testing"
)

func TestServerRestart(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}

	if err := e.Close(); err != nil {
		t.Fatal(err)
	}

	e.restart()

	if !e.done {
		t.Error("expected server to still be done after restart")
	}
}

func TestServerCommandAfterKill(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}

	out, err := e.Command("-ver")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("Before kill: %s", bytes.TrimSpace(out))

	proc := &processStub{server: e}
	if killErr := proc.Kill(); killErr != nil {
		t.Logf("Kill error: %v", killErr)
	}

	_, err = e.Command("-ver")
	if err != nil {
		t.Logf("Command after kill (expected error): %v", err)
	}

	if err := e.Close(); err != nil {
		t.Fatal(err)
	}
}

// TestServerStayOpenLargeStdoutThroughPipe verifies stay_open Command responses
// larger than bufio.Scanner's default 64KiB token limit are delivered intact.
func TestServerStayOpenLargeStdoutThroughPipe(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	const payloadLen = 70000
	payload := strings.Repeat("A", payloadLen)

	out, err := e.Command("-echo3", payload)
	if err != nil {
		t.Fatalf("large stdout through stay_open pipe: %v", err)
	}
	if !bytes.Contains(out, []byte(payload)) {
		t.Fatalf("response missing %d-byte payload; got %d bytes", payloadLen, len(out))
	}
}
