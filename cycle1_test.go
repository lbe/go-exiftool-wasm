package exiftool

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestCycle1_WasiWasm2GoReplaced verifies that the wasi-wasm2go dependency has
// been fully replaced with wasm2go-wasi-host (acceptance criteria for Cycle 1).
func TestCycle1_WasiWasm2GoReplaced(t *testing.T) {
	projectRoot := "."

	// Criterion 1: go.mod requires github.com/lbe/wasm2go-wasi-host
	// Criterion 2: go.mod no longer requires or replaces github.com/lbe/wasi-wasm2go
	// Criterion 3: go.mod has no replace lines
	//
	// We read go.mod at runtime to verify the dependency swap.
	gomodBytes, err := os.ReadFile(projectRoot + "/go.mod")
	if err != nil {
		t.Fatalf("failed to read go.mod: %v", err)
	}
	gomod := string(gomodBytes)

	t.Run("go_mod_requires_wasm2go_wasi_host", func(t *testing.T) {
		if !strings.Contains(gomod, "github.com/lbe/wasm2go-wasi-host") {
			t.Error("go.mod does not require github.com/lbe/wasm2go-wasi-host")
		}
	})

	t.Run("go_mod_no_wasi_wasm2go_requirement", func(t *testing.T) {
		if strings.Contains(gomod, "github.com/lbe/wasi-wasm2go") {
			t.Error("go.mod still contains a reference to github.com/lbe/wasi-wasm2go")
		}
	})

	t.Run("go_mod_no_replace_directives", func(t *testing.T) {
		for _, line := range strings.Split(gomod, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "replace ") {
				t.Errorf("go.mod still contains replace directive: %s", trimmed)
			}
		}
	})

	// Criterion 4: wasi.go imports wasihost "github.com/lbe/wasm2go-wasi-host"
	wasigoBytes, err := os.ReadFile(projectRoot + "/wasi.go")
	if err != nil {
		t.Fatalf("failed to read wasi.go: %v", err)
	}
	wasigo := string(wasigoBytes)

	t.Run("wasi_go_imports_wasm2go_wasi_host", func(t *testing.T) {
		if !strings.Contains(wasigo, `"github.com/lbe/wasm2go-wasi-host"`) {
			t.Error("wasi.go does not import wasihost from github.com/lbe/wasm2go-wasi-host")
		}
	})

	t.Run("wasi_go_no_wasi_wasm2go_import", func(t *testing.T) {
		if strings.Contains(wasigo, `"github.com/lbe/wasi-wasm2go"`) {
			t.Error("wasi.go still imports from github.com/lbe/wasi-wasm2go")
		}
	})

	// Criterion 5: go build ./... exits 0; go vet ./... exits 0
	t.Run("go_build_succeeds", func(t *testing.T) {
		cmd := exec.Command("go", "build", "./...")
		cmd.Dir = projectRoot
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Errorf("go build ./... failed: %v\n%s", err, out)
		}
	})

	t.Run("go_vet_succeeds", func(t *testing.T) {
		cmd := exec.Command("go", "vet", "./...")
		cmd.Dir = projectRoot
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Errorf("go vet ./... failed: %v\n%s", err, out)
		}
	})

	// Criterion 6: internal/zeroperl package is unaffected (no import path change)
	t.Run("zeroperl_import_unchanged", func(t *testing.T) {
		if !strings.Contains(wasigo, `"github.com/lbe/go-exiftool-wasm/internal/zeroperl"`) {
			t.Error("wasi.go zeroperl import path was unexpectedly changed")
		}
	})
}
