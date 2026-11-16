//go:build integration

package exiftool

import (
	"testing"
)

func TestCommandZeroByteFileJSON(t *testing.T) {
	out, err := Command(nil, "-json", "testdata/empty.jpg")
	assertJSONFileEmptyError(t, out, err)
}
