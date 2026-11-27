// IMMUTABLE: conformance test for drop-in compatibility with
// github.com/ncruces/go-exiftool v0.4.2. Do not edit, rename, reformat or delete
// anything in this file. A change needs the repository owner's explicit
// approval, a regenerated testdata/conformance/MANIFEST.sha256 and a new
// conformanceManifestSHA256 in conformance_guard_test.go.

//go:build integration || ncruces

package exiftool_test

import (
	"bytes"
	"strconv"
	"testing"
)

func TestCommand(t *testing.T) {
	// ask for version number
	out, err := Command(nil, "-ver")
	if err != nil {
		t.Fatal(err)
	} else if ver, err := strconv.ParseFloat(string(bytes.TrimSpace(out)), 64); err != nil {
		t.Error(err)
	} else {
		t.Log(ver)
	}
}

func TestServer(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}

	// ask for version number
	out, err := e.Command("-ver")
	if err != nil {
		t.Error(err)
	} else if ver, parseErr := strconv.ParseFloat(string(bytes.TrimSpace(out)), 64); parseErr != nil {
		t.Error(parseErr)
	} else {
		t.Log(ver)
	}

	// shutdown the server
	err = e.Shutdown()
	if err != nil {
		t.Error(err)
	}

	// shutdown should not be called twice
	err = e.Shutdown()
	if err == nil {
		t.Error("repeated shutdown")
	}

	// commands should fail now
	_, err = e.Command("-ver")
	if err == nil {
		t.Error("command after shutdown")
	}

	// close should be fine at any time
	err = e.Close()
	if err != nil {
		t.Error(err)
	}
}
