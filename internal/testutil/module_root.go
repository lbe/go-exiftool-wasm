// Package testutil holds helpers shared by this module's tests.
package testutil

import (
	"os"
	"path/filepath"
	"testing"
)

// Root returns the nearest directory at or above the working directory that
// contains go.mod. It fails the test if there is none.
func Root(t *testing.T) string {
	t.Helper()

	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	for {
		if _, statErr := os.Stat(filepath.Join(dir, "go.mod")); statErr == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found")
		}
		dir = parent
	}
}
