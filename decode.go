package exiftool

import (
	"bytes"
	"errors"
)

// Unmarshal parses ExifTool's line-oriented text output into m. Each line must end
// with a newline and contain a key, ": " and a value. Unmarshal trims spaces
// around the key and a trailing carriage return from the value. This covers the
// default format and -s short output, but not -json, -X or other structured
// formats.
//
// Unmarshal returns an error for a line without ": " or a last line without a
// newline. Empty data adds nothing and returns nil.
//
// The values in m are subslices of data. If data is reused or modified, copy each
// value you keep, for example with append([]byte(nil), v...).
func Unmarshal(data []byte, m map[string][]byte) error {
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			return errors.New("exiftool: unexpected end of output")
		}

		j := bytes.Index(data[:i], []byte(": "))
		if j < 0 {
			return errors.New("exiftool: missing separator")
		}

		key := bytes.TrimSpace(data[:j])
		val := bytes.TrimSuffix(data[j+2:i], []byte("\r"))
		m[string(key)] = val
		data = data[i+1:]
	}
	return nil
}
