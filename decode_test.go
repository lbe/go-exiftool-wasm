package exiftool

import (
	"bytes"
	"testing"
)

func TestUnmarshalStandard(t *testing.T) {
	data := []byte("Artist : John Doe\nCopyright : CC BY 4.0\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if len(m) != 2 {
		t.Fatalf("expected 2 keys, got %d", len(m))
	}
	if got, want := string(m["Artist"]), "John Doe"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
	if got, want := string(m["Copyright"]), "CC BY 4.0"; got != want {
		t.Errorf("Copyright: got %q, want %q", got, want)
	}
}

func TestUnmarshalShortFormat(t *testing.T) {
	// Short format uses ": " separator (same as standard but without padding)
	data := []byte("Artist: John Doe\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if got, want := string(m["Artist"]), "John Doe"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnmarshalEmpty(t *testing.T) {
	data := []byte("")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if len(m) != 0 {
		t.Errorf("expected empty map, got %d keys", len(m))
	}
}

func TestUnmarshalNoNewline(t *testing.T) {
	data := []byte("Artist : John Doe")
	m := make(map[string][]byte)
	err := Unmarshal(data, m)
	if err == nil {
		t.Fatal("expected error for missing newline")
	}
	if got, want := err.Error(), "exiftool: unexpected end of output"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnmarshalNoSeparator(t *testing.T) {
	data := []byte("Artist John Doe\n")
	m := make(map[string][]byte)
	err := Unmarshal(data, m)
	if err == nil {
		t.Fatal("expected error for missing separator")
	}
	if got, want := err.Error(), "exiftool: missing separator"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnmarshalMultibyte(t *testing.T) {
	data := []byte("Artist : 日本語\nTitle : Ünïcödé\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if got, want := string(m["Artist"]), "日本語"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if got, want := string(m["Title"]), "Ünïcödé"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnmarshalCarriageReturn(t *testing.T) {
	data := []byte("Artist : John Doe\r\nCopyright : CC\r\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if got, want := string(m["Artist"]), "John Doe"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if got, want := string(m["Copyright"]), "CC"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnmarshalColonInValue(t *testing.T) {
	data := []byte("Description : Time: 12:00\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if got, want := string(m["Description"]), "Time: 12:00"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnmarshalEmptyValue(t *testing.T) {
	data := []byte("Artist : \n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if got := m["Artist"]; len(got) != 0 {
		t.Errorf("expected empty value, got %q", got)
	}
}

func TestUnmarshalMultipleValues(t *testing.T) {
	data := []byte("Artist : A\nCopyright : B\nTitle : C\nDescription : D\nSoftware : E\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if len(m) != 5 {
		t.Fatalf("expected 5 keys, got %d", len(m))
	}
	for _, kv := range []struct{ k, v string }{
		{"Artist", "A"}, {"Copyright", "B"}, {"Title", "C"},
		{"Description", "D"}, {"Software", "E"},
	} {
		if got := string(m[kv.k]); got != kv.v {
			t.Errorf("%s: got %q, want %q", kv.k, got, kv.v)
		}
	}
}

func TestUnmarshalWhitespaceInKey(t *testing.T) {
	data := []byte("Create Date : 2024:01:15 12:00:00\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if got, want := string(m["Create Date"]), "2024:01:15 12:00:00"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnmarshalPreservesExistingMap(t *testing.T) {
	m := map[string][]byte{"Existing": []byte("value")}
	data := []byte("New Key : new value\n")
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if len(m) != 2 {
		t.Fatalf("expected 2 keys, got %d", len(m))
	}
	if got, want := string(m["Existing"]), "value"; got != want {
		t.Errorf("Existing: got %q, want %q", got, want)
	}
	if got, want := string(m["New Key"]), "new value"; got != want {
		t.Errorf("New Key: got %q, want %q", got, want)
	}
}

func TestUnmarshalRealExifToolOutput(t *testing.T) {
	// Simulates real ExifTool output
	data := []byte("ExifTool Version Number         : 12.76\nFile Name                       : sample.jpg\nDirectory                       : testdata\nFile Size                       : 1.2 kB\nFile Modification Date/Time     : 2024:01:15 12:00:00+00:00\nFile Access Date/Time           : 2024:01:15 12:00:00+00:00\n")
	m := make(map[string][]byte)
	if err := Unmarshal(data, m); err != nil {
		t.Fatal(err)
	}
	if len(m) != 6 {
		t.Fatalf("expected 6 keys, got %d", len(m))
	}
	// Verify values are trimmed correctly (ExifTool pads keys with spaces)
	if got := string(m["ExifTool Version Number"]); !bytes.Contains(m["ExifTool Version Number"], []byte("12.76")) {
		t.Errorf("ExifTool Version Number: got %q", got)
	}
}
