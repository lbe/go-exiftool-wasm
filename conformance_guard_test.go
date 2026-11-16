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

// conformanceManifestSHA256 pins conformance/MANIFEST.sha256. Change it only when
// the repository owner approves a change to the conformance suite.
const conformanceManifestSHA256 = "ab4bfd22ac01970f0b97c5e796663ce57d6b3c2f27cf491d12112c12cf19c3e3"

// TestConformanceFilesUnchanged fails if a file under conformance/ is added,
// removed or changed without a matching MANIFEST.sha256 and manifest hash.
func TestConformanceFilesUnchanged(t *testing.T) {
	manifest, err := os.ReadFile(filepath.Join("conformance", "MANIFEST.sha256"))
	if err != nil {
		t.Fatal(err)
	}
	if got := sha256Hex(manifest); got != conformanceManifestSHA256 {
		t.Fatalf("conformance/MANIFEST.sha256 hash = %s, want %s", got, conformanceManifestSHA256)
	}
	want := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSpace(string(manifest)), "\n") {
		sum, name, ok := strings.Cut(line, "  ")
		if !ok {
			t.Fatalf("malformed manifest line %q", line)
		}
		want[name] = sum
	}
	got := make(map[string]string)
	err = filepath.WalkDir("conformance", func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, relErr := filepath.Rel("conformance", path)
		if relErr != nil {
			return relErr
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if rel == "dist" {
				return filepath.SkipDir
			}
			return nil
		}
		if rel == "MANIFEST.sha256" {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		got[rel] = sha256Hex(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for name, sum := range want {
		if g, ok := got[name]; !ok {
			t.Errorf("conformance/%s is missing", name)
		} else if g != sum {
			t.Errorf("conformance/%s has changed", name)
		}
	}
	for name := range got {
		if _, ok := want[name]; !ok {
			t.Errorf("conformance/%s is not in MANIFEST.sha256", name)
		}
	}
}

// sha256Hex returns the hex SHA-256 of data.
func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
