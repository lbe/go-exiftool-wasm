//go:build integration

package exiftool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCommand_tagsFromFile verifies that Command copies metadata between two files
// given as paths relative to the working directory, with -tagsFromFile and
// -overwrite_original.
func TestCommand_tagsFromFile(t *testing.T) {
	// Arrange: copy test.jpg to dst in a temporary directory under the working
	// directory.
	tmpDir, err := os.MkdirTemp(".", "write_test_*")
	if err != nil {
		t.Fatalf("MkdirTemp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(tmpDir) })

	srcRel := "testdata/test.jpg"
	dstRel := filepath.Join(tmpDir, "dst.jpg")

	srcData, err := os.ReadFile(srcRel)
	if err != nil {
		t.Fatalf("read src: %v", err)
	}
	if err = os.WriteFile(dstRel, srcData, 0o644); err != nil {
		t.Fatalf("write dst: %v", err)
	}

	// Act: -tagsFromFile copies metadata; -overwrite_original rewrites dst in-place.
	// -m suppresses minor ExifTool errors, such as IPTC length truncation.
	out, err := Command(nil, "-m", "-tagsFromFile", srcRel, "-overwrite_original", dstRel)

	// Assert: allow ExifTool warnings, such as an IPTC digest mismatch. They
	// appear in stderr but do not mean the write failed.
	if err != nil && !strings.Contains(err.Error(), "Warning:") {
		t.Fatalf("Command: %v\noutput: %s", err, out)
	}
	if !strings.Contains(string(out), "image files updated") {
		t.Fatalf("expected 'image files updated' in output, got:\n%s", out)
	}
}
