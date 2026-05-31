package testutil

import (
	"path/filepath"
	"testing"
)

// SampleJPEG returns the path to testdata/sample.jpg relative to the module root.
func SampleJPEG(t *testing.T) string {
	t.Helper()
	return filepath.Join(Root(t), "testdata", "sample.jpg")
}
