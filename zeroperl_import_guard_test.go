package exiftool

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestLegacyZeroperlImportPathRemoved guards that the wasm2go-generated module
// is not importable at the historical github.com/lbe/go-exiftool-wasm/zeroperl path.
// Consumers must use the main package API only.
func TestLegacyZeroperlImportPathRemoved(t *testing.T) {
	t.Parallel()

	if runtime.GOOS == "js" || runtime.GOOS == "wasip1" {
		t.Skip("subprocess go build not supported")
	}

	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Fatalf("lookpath go: %v", err)
	}

	rootDir := findModuleRoot(t)
	consumerDir := filepath.Join(rootDir, "testdata", "legacyzeroperlconsumer")

	cmd := exec.Command(goBin, "build", ".")
	cmd.Dir = consumerDir
	cmd.Env = append(os.Environ(), "GOWORK=off")

	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("expected go build to fail (legacy zeroperl path must not be importable), output:\n%s", string(out))
	}

	combined := string(out)
	if !strings.Contains(combined, "zeroperl") &&
		!strings.Contains(combined, "no required module") &&
		!strings.Contains(combined, "cannot find module") &&
		!strings.Contains(combined, "missing") {
		t.Fatalf("unexpected build failure output:\n%s", combined)
	}
}

func findModuleRoot(t *testing.T) string {
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
