package exiftool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCommand_tagsFromFile verifies that Command can copy metadata between files
// under the process working directory using -tagsFromFile -overwrite_original.
// Both src and dst are relative paths so the WASI sandbox hostRoot join resolves
// them correctly without absolute-path ambiguity.
func TestCommand_tagsFromFile(t *testing.T) {
	// Arrange: create a temp subdir under CWD; copy test.jpg there as dst.
	// Relative paths are used throughout so filepath.Join(cwd, rel) is correct.
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
	// -m suppresses minor ExifTool errors (e.g., IPTC length truncation).
	out, err := Command(nil, "-m", "-tagsFromFile", srcRel, "-overwrite_original", dstRel)

	// Assert: allow non-fatal ExifTool warnings (e.g., IPTC digest mismatch) which
	// appear in stderr but do not indicate a write failure.
	if err != nil && !strings.Contains(err.Error(), "Warning:") {
		t.Fatalf("Command: %v\noutput: %s", err, out)
	}
	if !strings.Contains(string(out), "image files updated") {
		t.Fatalf("expected 'image files updated' in output, got:\n%s", out)
	}
}
