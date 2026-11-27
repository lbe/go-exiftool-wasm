package exiftool

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// conformanceManifest lists every file of the conformance suite with its SHA-256.
const conformanceManifest = "testdata/conformance/MANIFEST.sha256"

// conformanceManifestSHA256 pins conformanceManifest. Change it only when the
// repository owner approves a change to the conformance suite.
const conformanceManifestSHA256 = "ce70a8ed62314f392ca98d8d38e52b4b21128d896e7ce887bf4f941db9ff06d1"

// TestConformanceFilesUnchanged fails if a conformance file is added, removed or
// changed without a matching conformanceManifest and manifest hash. The suite is
// the conformance_*_test.go files (other than this one), everything under
// testdata/conformance (other than dist) and the shared testdata files the
// manifest lists.
func TestConformanceFilesUnchanged(t *testing.T) {
	manifest, err := os.ReadFile(conformanceManifest)
	if err != nil {
		t.Fatal(err)
	}
	if got := sha256Hex(manifest); got != conformanceManifestSHA256 {
		t.Fatalf("%s hash = %s, want %s", conformanceManifest, got, conformanceManifestSHA256)
	}
	want := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSpace(string(manifest)), "\n") {
		sum, name, ok := strings.Cut(line, "  ")
		if !ok {
			t.Fatalf("malformed manifest line %q", line)
		}
		want[name] = sum
	}
	for name, sum := range want {
		data, err := os.ReadFile(filepath.FromSlash(name))
		if err != nil {
			t.Errorf("%s is missing: %v", name, err)
		} else if sha256Hex(data) != sum {
			t.Errorf("%s has changed", name)
		}
	}
	for _, name := range conformanceFiles(t) {
		if _, ok := want[name]; !ok {
			t.Errorf("%s is not in %s", name, conformanceManifest)
		}
	}
}

// conformanceFiles returns the conformance_*_test.go files other than this one
// and the files under testdata/conformance other than the manifest and dist.
func conformanceFiles(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob("conformance_*_test.go")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, f := range files {
		if f != "conformance_guard_test.go" {
			names = append(names, f)
		}
	}
	dir := filepath.Dir(filepath.FromSlash(conformanceManifest))
	err = filepath.WalkDir(dir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		name := filepath.ToSlash(path)
		if d.IsDir() {
			if name == "testdata/conformance/dist" {
				return filepath.SkipDir
			}
			return nil
		}
		if name != conformanceManifest {
			names = append(names, name)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return names
}

// sha256Hex returns the hex SHA-256 of data.
func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
