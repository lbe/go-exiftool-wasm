// IMMUTABLE: conformance test for drop-in compatibility with
// github.com/ncruces/go-exiftool v0.4.2. Do not edit, rename, reformat or delete
// anything in this file. A change needs the repository owner's explicit
// approval, a regenerated testdata/conformance/MANIFEST.sha256 and a new
// conformanceManifestSHA256 in conformance_guard_test.go.

//go:build integration || ncruces

package exiftool_test

import (
	"bytes"
	"context"
	stderrors "errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

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
	if writeErr := os.WriteFile(tmpFile, src, 0644); writeErr != nil {
		t.Fatal(writeErr)
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
	if writeErr := os.WriteFile(tmpFile, src, 0644); writeErr != nil {
		t.Fatal(writeErr)
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
	if writeErr := os.WriteFile(dstFile, src, 0644); writeErr != nil {
		t.Fatal(writeErr)
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

func TestServerReadTags(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("-Artist", "-Copyright", "-Make", "-Model", "testdata/sample.jpg")
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
	if got, want := string(m["Make"]), "TestMaker"; got != want {
		t.Errorf("Make: got %q, want %q", got, want)
	}
	if got, want := string(m["Camera Model Name"]), "TestModel"; got != want {
		t.Errorf("Camera Model Name: got %q, want %q", got, want)
	}
}

func TestServerReadAllTags(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	expectedTags := []string{"Artist", "Copyright", "Make", "Camera Model Name", "Software", "File Name"}
	for _, tag := range expectedTags {
		if _, ok := m[tag]; !ok {
			t.Errorf("expected tag %q not found", tag)
		}
	}
	t.Logf("Found %d tags", len(m))
}

func TestServerGPSTags(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("-GPSLatitude", "-GPSLongitude", "-GPSAltitude", "testdata/sample_gps.jpg")
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

func TestServerMultipleCommands(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	// Execute multiple sequential commands
	for i := 0; i < 5; i++ {
		out, err := e.Command("-ver")
		if err != nil {
			t.Fatalf("command %d: %v", i, err)
		}
		if len(bytes.TrimSpace(out)) == 0 {
			t.Errorf("command %d: empty output", i)
		}
	}
}

func TestServerMultipleFiles(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("-FileName", "-Artist", "testdata/sample.jpg", "testdata/sample_gps.jpg")
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Contains(out, []byte("sample.jpg")) {
		t.Error("expected sample.jpg in output")
	}
	if !bytes.Contains(out, []byte("sample_gps.jpg")) {
		t.Error("expected sample_gps.jpg in output")
	}
}

func TestServerNonexistentFile(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	_, err = e.Command("testdata/nonexistent.jpg")
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
	t.Logf("Error (expected): %v", err)
}

func TestServerShortFormat(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("-s", "-Artist", "testdata/sample.jpg")
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

func TestServerWriteTag(t *testing.T) {
	src, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "write_test.jpg")
	if writeErr := os.WriteFile(tmpFile, src, 0644); writeErr != nil {
		t.Fatal(writeErr)
	}

	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	// Write a new tag
	_, err = e.Command("-Artist=Server Artist", "-overwrite_original", tmpFile)
	if err != nil {
		t.Fatal(err)
	}

	// Verify the tag was written
	out, err := e.Command("-Artist", tmpFile)
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if got, want := string(m["Artist"]), "Server Artist"; got != want {
		t.Errorf("Artist: got %q, want %q", got, want)
	}
}

func TestServerDeleteTag(t *testing.T) {
	src, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "delete_test.jpg")
	if writeErr := os.WriteFile(tmpFile, src, 0644); writeErr != nil {
		t.Fatal(writeErr)
	}

	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	// Delete the Artist tag
	_, err = e.Command("-Artist=", "-overwrite_original", tmpFile)
	if err != nil {
		t.Fatal(err)
	}

	// Verify the tag was deleted
	out, err := e.Command("-Artist", tmpFile)
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

func TestServerCopyTags(t *testing.T) {
	src, err := os.ReadFile("testdata/sample_noexif.jpg")
	if err != nil {
		t.Fatal(err)
	}

	tmpDir := t.TempDir()
	dstFile := filepath.Join(tmpDir, "copy_dst.jpg")
	if writeErr := os.WriteFile(dstFile, src, 0644); writeErr != nil {
		t.Fatal(writeErr)
	}

	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	// Copy tags
	_, err = e.Command("-TagsFromFile", "testdata/sample.jpg", "-Artist", "-Copyright", "-overwrite_original", dstFile)
	if err != nil {
		t.Fatal(err)
	}

	// Verify tags were copied
	out, err := e.Command("-Artist", "-Copyright", dstFile)
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

func TestServerJSONOutput(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("-json", "-Artist", "-Copyright", "testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Contains(out, []byte(`"Artist"`)) {
		t.Error("expected JSON with Artist key")
	}
	if !bytes.Contains(out, []byte(`"Test Artist"`)) {
		t.Error("expected JSON with Test Artist value")
	}
}

func TestServerClose(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}

	// Force close
	err = e.Close()
	if err != nil {
		t.Error(err)
	}

	// Double close should be fine
	err = e.Close()
	if err != nil {
		t.Error(err)
	}
}

func TestServerConcurrentCommands(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	var wg sync.WaitGroup
	errs := make(chan error, 10)

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			out, err := e.Command("-ver")
			if err != nil {
				errs <- err
				return
			}
			if len(bytes.TrimSpace(out)) == 0 {
				errs <- stderrors.New("empty output")
			}
		}(i)
	}

	wg.Wait()
	close(errs)

	for err := range errs {
		t.Error(err)
	}
}

func TestServerConcurrentReads(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	var wg sync.WaitGroup
	errs := make(chan error, 5)

	files := []string{
		"testdata/sample.jpg",
		"testdata/sample_gps.jpg",
		"testdata/sample_noexif.jpg",
		"testdata/sample.png",
		"testdata/sample.tiff",
	}

	for _, f := range files {
		wg.Add(1)
		go func(file string) {
			defer wg.Done()
			_, err := e.Command("-FileType", file)
			if err != nil {
				errs <- err
			}
		}(f)
	}

	wg.Wait()
	close(errs)

	for err := range errs {
		if err != nil {
			t.Error(err)
		}
	}
}

func TestServerCommonArgs(t *testing.T) {
	// Create server with common args
	e, err := NewServer("-fast")
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}

	m := make(map[string][]byte)
	if err := Unmarshal(out, m); err != nil {
		t.Fatal(err)
	}

	if len(m) == 0 {
		t.Error("expected some tags")
	}
}

func TestServerPNG(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("-FileType", "testdata/sample.png")
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

func TestServerTIFF(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if shutdownErr := e.Shutdown(); shutdownErr != nil {
			t.Logf("Shutdown error: %v", shutdownErr)
		}
	}()

	out, err := e.Command("-Artist", "testdata/sample.tiff")
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

func TestServerWithConfig(t *testing.T) {
	savedExec, savedArg1, savedConfig := Exec, Arg1, Config
	defer func() { Exec, Arg1, Config = savedExec, savedArg1, savedConfig }()

	Config = "/nonexistent/config/file.cfg"
	e, err := NewServer()
	if err != nil {
		t.Logf("NewServer with bad config (acceptable): %v", err)
		return
	}
	if err := e.Shutdown(); err != nil {
		t.Logf("Shutdown error (acceptable): %v", err)
	}
}
