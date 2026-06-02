//go:build integration

package exiftool

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
)

func chdirTo(t *testing.T, dir string) {
	t.Helper()

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })

	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Chdir(%q): %v", dir, err)
	}
}

func assertJSONFileEmptyError(t *testing.T, out []byte, err error) {
	t.Helper()

	if len(out) == 0 {
		t.Fatal("expected JSON on stdout, got empty output")
	}

	var records []map[string]any
	if uerr := json.Unmarshal(out, &records); uerr != nil {
		t.Fatalf("invalid JSON: %v\nraw: %s", uerr, out)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(records))
	}
	errVal, ok := records[0]["Error"]
	if !ok {
		t.Fatalf("expected Error field in JSON, got keys: %v", records[0])
	}
	got, ok := errVal.(string)
	if !ok {
		t.Fatalf("Error field type = %T, want string", errVal)
	}
	if got != "File is empty" {
		t.Errorf("Error: got %q, want %q", got, "File is empty")
	}

	assertExitErrorCode(t, err, 1)
}

func assertExitErrorCode(t *testing.T, err error, want int) {
	t.Helper()

	if err == nil {
		t.Fatalf("expected *ExitError with code %d, got nil", want)
	}
	var exitErr *ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("expected *ExitError, got %T: %v", err, err)
	}
	if exitErr.Code != want {
		t.Errorf("exit code: got %d, want %d", exitErr.Code, want)
	}
}

func assertJSONSourceFileAbsolute(t *testing.T, out []byte, wantAbs string) {
	t.Helper()

	var records []map[string]any
	if err := json.Unmarshal(out, &records); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(records))
	}
	for _, key := range []string{"SourceFile", "FileName"} {
		if v, ok := records[0][key]; ok {
			if got := fmt.Sprint(v); got == wantAbs {
				return
			}
		}
	}
	t.Fatalf("expected JSON SourceFile/FileName %q in %v", wantAbs, records[0])
}
