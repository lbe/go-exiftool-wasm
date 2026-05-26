package exiftool

import (
	"bytes"
	"errors"
)

// Unmarshal parses line-oriented ExifTool text output into a map. Each line must
// contain a key, the substring ": ", and a value. This covers the default format and
// -s / short output. It does not parse JSON (-json), XML (-X), or other structured
// outputs. Returns an error if data is empty or a line is malformed.
//
// Values stored in m are subslices of data; if data is reused or modified after the
// call, entries in m may change. Copy with append([]byte(nil), v...) when retaining
// values past the lifetime of data.
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
