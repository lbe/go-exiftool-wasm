package exiftool

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/lbe/go-exiftool-wasm/internal/testutil"
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

	rootDir := testutil.Root(t)
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
