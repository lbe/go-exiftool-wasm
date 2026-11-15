package testutil

import (
	"path/filepath"
	"testing"
)

// SampleJPEG returns the absolute path of testdata/sample.jpg in the module root.
func SampleJPEG(t *testing.T) string {
	t.Helper()
	return filepath.Join(Root(t), "testdata", "sample.jpg")
}
