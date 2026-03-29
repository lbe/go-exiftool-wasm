package exiftool

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestCommand(t *testing.T) {
	// ask for version number
	out, err := Command(nil, "-ver")
	if err != nil {
		t.Fatal(err)
	} else if ver, err := strconv.ParseFloat(string(bytes.TrimSpace(out)), 64); err != nil {
		t.Error(err)
	} else {
		t.Log(ver)
	}
}

func TestCommandReadTags(t *testing.T) {
	out, err := Command(nil, "-Artist", "-Copyright", "testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if got, want := string(m["Artist"]), "Test Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
	if got, want := string(m["Copyright"]), "Test Copyright 2024"; got != want {
		t.Errorf("Copyright: got %q, want %q", got, want)
	}
}

func TestCommandReadAllTags(t *testing.T) {
	out, err := Command(nil, "testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	// Verify some expected tags are present
	expectedTags := []string{"Artist", "Copyright", "Make", "Camera Model Name", "Software"}
	for _, tag := range expectedTags {
		if _, ok := m[tag]; !ok {
			t.Errorf("expected tag %q not found in output", tag)
		}
	}
	t.Logf("Found %d tags", len(m))
}

func TestCommandReadGPSTags(t *testing.T) {
	out, err := Command(nil, "-GPSLatitude", "-GPSLongitude", "-GPSAltitude", "testdata/sample_gps.jpg")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if _, ok := m["GPS Latitude"]; !ok {
		t.Error("expected GPS Latitude tag")
	}
	if _, ok := m["GPS Longitude"]; !ok {
		t.Error("expected GPS Longitude tag")
	}
	if _, ok := m["GPS Altitude"]; !ok {
		t.Error("expected GPS Altitude tag")
	}
}

func TestCommandReadNoExif(t *testing.T) {
	out, err := Command(nil, "testdata/sample_noexif.jpg")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	// Should have file system tags but not Artist/Copyright
	if _, ok := m["Artist"]; ok {
		t.Error("unexpected Artist tag in no-exif file")
	}
	if _, ok := m["Copyright"]; ok {
		t.Error("unexpected Copyright tag in no-exif file")
	}
	// Should still have file-level tags
	if _, ok := m["File Name"]; !ok {
		t.Error("expected File Name tag")
	}
}

func TestCommandReadNonexistentFile(t *testing.T) {
	_, err := Command(nil, "testdata/nonexistent.jpg")
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
}

func TestCommandReadPNG(t *testing.T) {
	out, err := Command(nil, "testdata/sample.png")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if got, want := string(m["File Type"]), "PNG"; got != want {
		t.Errorf("File Type: got %q, want %q", got, want)
	}
}

func TestCommandReadTIFF(t *testing.T) {
	out, err := Command(nil, "-Artist", "-Copyright", "testdata/sample.tiff")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if got, want := string(m["Artist"]), "TIFF Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
}

func TestCommandShortFormat(t *testing.T) {
	out, err := Command(nil, "-s", "-Artist", "testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if got, want := string(m["Artist"]), "Test Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
}

func TestCommandWithStdin(t *testing.T) {
	// Use -@ to read arguments from stdin
	out, err := Command(strings.NewReader("-ver\n"), "-@", "-")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(out, []byte(".")) {
		t.Errorf("expected version output, got %q", out)
	}
}

func TestCommandMultipleFiles(t *testing.T) {
	out, err := Command(nil, "-FileName", "-Artist", "testdata/sample.jpg", "testdata/sample_gps.jpg")
	if err != nil {
		t.Fatal(err)
	}

	// Should contain data for both files
	if !bytes.Contains(out, []byte("sample.jpg")) {
		t.Error("expected sample.jpg in output")
	}
	if !bytes.Contains(out, []byte("sample_gps.jpg")) {
		t.Error("expected sample_gps.jpg in output")
	}
}

func TestCommandContext(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	out, err := CommandContext(ctx, nil, "-ver")
	if err != nil {
		t.Fatal(err)
	}
	if ver, err := strconv.ParseFloat(string(bytes.TrimSpace(out)), 64); err != nil {
		t.Error(err)
	} else {
		t.Logf("ExifTool version: %.2f", ver)
	}
}

func TestCommandContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel immediately

	_, err := CommandContext(ctx, nil, "-ver")
	if err == nil {
		t.Error("expected error due to cancelled context")
	}
}

func TestCommandContextTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Nanosecond)
	defer cancel()

	_, err := CommandContext(ctx, nil, "-ver")
	if err == nil {
		t.Error("expected error due to context timeout")
	}
}

func TestCommandWriteTag(t *testing.T) {
	// Create a temp copy of sample.jpg
	src, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "write_test.jpg")
	if err := os.WriteFile(tmpFile, src, 0644); err != nil {
		t.Fatal(err)
	}

	// Write a new tag
	out, err := Command(nil, "-Artist=New Artist", "-overwrite_original", tmpFile)
	if err != nil {
		t.Fatalf("write failed: %v, output: %s", err, out)
	}

	// Verify the tag was written
	out, err = Command(nil, "-Artist", tmpFile)
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if got, want := string(m["Artist"]), "New Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
}

func TestCommandDeleteTag(t *testing.T) {
	src, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "delete_test.jpg")
	if err := os.WriteFile(tmpFile, src, 0644); err != nil {
		t.Fatal(err)
	}

	// Delete the Artist tag
	out, err := Command(nil, "-Artist=", "-overwrite_original", tmpFile)
	if err != nil {
		t.Fatalf("delete failed: %v, output: %s", err, out)
	}

	// Verify the tag was deleted
	out, err = Command(nil, "-Artist", tmpFile)
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if _, ok := m["Artist"]; ok {
		t.Error("Artist tag should have been deleted")
	}
}

func TestCommandCopyTags(t *testing.T) {
	src, err := os.ReadFile("testdata/sample_noexif.jpg")
	if err != nil {
		t.Fatal(err)
	}

	tmpDir := t.TempDir()
	dstFile := filepath.Join(tmpDir, "copy_dst.jpg")
	if err := os.WriteFile(dstFile, src, 0644); err != nil {
		t.Fatal(err)
	}

	// Copy tags from sample.jpg to the no-exif file
	out, err := Command(nil, "-TagsFromFile", "testdata/sample.jpg", "-Artist", "-Copyright", "-overwrite_original", dstFile)
	if err != nil {
		t.Fatalf("copy failed: %v, output: %s", err, out)
	}

	// Verify tags were copied
	out, err = Command(nil, "-Artist", "-Copyright", dstFile)
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if got, want := string(m["Artist"]), "Test Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
	if got, want := string(m["Copyright"]), "Test Copyright 2024"; got != want {
		t.Errorf("Copyright: got %q, want %q", got, want)
	}
}

func TestCommandJSONOutput(t *testing.T) {
	out, err := Command(nil, "-json", "-Artist", "-Copyright", "testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	// Should be valid JSON
	if !bytes.Contains(out, []byte(`"Artist"`)) {
		t.Error("expected JSON with Artist key")
	}
	if !bytes.Contains(out, []byte(`"Test Artist"`)) {
		t.Error("expected JSON with Test Artist value")
	}
}

func TestCommandXMLOutput(t *testing.T) {
	out, err := Command(nil, "-X", "-Artist", "testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Contains(out, []byte("<rdf:RDF")) && !bytes.Contains(out, []byte("Artist")) {
		t.Error("expected XML/RDF output")
	}
}
