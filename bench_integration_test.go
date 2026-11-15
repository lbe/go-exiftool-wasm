//go:build integration

package exiftool

import (
	"bytes"
	"os"
	"testing"
)

// ---------------------------------------------------------------------------
// Category 1: Cold Start (full lifecycle inside b.N loop)
// ---------------------------------------------------------------------------

// BenchmarkCommand_Version measures the full cold-start cost of a single-shot
// Command invocation: wasm2go native module setup, Perl init, execution,
// and teardown.
func BenchmarkCommand_Version(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkNewServer measures full server lifecycle: creation + shutdown.
func BenchmarkNewServer(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		e, err := NewServer()
		if err != nil {
			b.Fatal(err)
		}
		if err := e.Shutdown(); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 2: Warm Server Operations (server created once)
// ---------------------------------------------------------------------------

// BenchmarkServerCommand_Version measures a warm-server version query.
func BenchmarkServerCommand_Version(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_ReadTags reads specific tags from a small JPEG.
func BenchmarkServerCommand_ReadTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-Artist", "-Copyright", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_AllTags dumps all tags from a small JPEG.
func BenchmarkServerCommand_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_JSON dumps all tags as JSON from a small JPEG.
func BenchmarkServerCommand_JSON(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_MultipleFiles reads tags from two files in one call.
func BenchmarkServerCommand_MultipleFiles(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-FileName", "-Artist", "testdata/sample.jpg", "testdata/sample_gps.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 3: Single-shot File Reading (full lifecycle inside b.N loop)
// ---------------------------------------------------------------------------

// BenchmarkCommand_ReadTags reads specific tags via single-shot Command.
func BenchmarkCommand_ReadTags(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-Artist", "-Copyright", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_AllTags dumps all tags via single-shot Command.
func BenchmarkCommand_AllTags(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_JSON dumps all tags as JSON via single-shot Command.
func BenchmarkCommand_JSON(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-json", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 4: stdin Image Streaming
// ---------------------------------------------------------------------------

// BenchmarkCommand_StdinImage pipes image bytes via stdin for JSON extraction.
func BenchmarkCommand_StdinImage(b *testing.B) {
	imgBytes, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(bytes.NewReader(imgBytes), "-json", "-"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_StdinImage_Tags pipes image bytes via stdin for specific tags.
func BenchmarkCommand_StdinImage_Tags(b *testing.B) {
	imgBytes, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(bytes.NewReader(imgBytes), "-Artist", "-Copyright", "-"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServer_TempFileImage measures the temp-file workaround for
// in-memory images with a persistent server.
func BenchmarkServer_TempFileImage(b *testing.B) {
	imgBytes, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		b.Fatal(err)
	}

	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tmp, err := os.CreateTemp("", "bench-*.jpg")
		if err != nil {
			b.Fatal(err)
		}
		if _, err := tmp.Write(imgBytes); err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
			b.Fatal(err)
		}
		tmp.Close()

		if _, err := e.Command("-json", tmp.Name()); err != nil {
			os.Remove(tmp.Name())
			b.Fatal(err)
		}
		os.Remove(tmp.Name())
	}
}

// ---------------------------------------------------------------------------
// Category 5: Throughput Comparison
// ---------------------------------------------------------------------------

// BenchmarkCommand_SequentialVersion runs N cold-start version queries.
func BenchmarkCommand_SequentialVersion(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServer_SequentialVersion runs N warm-server version queries.
func BenchmarkServer_SequentialVersion(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_SequentialRead runs N cold-start tag reads.
func BenchmarkCommand_SequentialRead(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-Artist", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServer_SequentialRead runs N warm-server tag reads.
func BenchmarkServer_SequentialRead(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-Artist", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 6: File Size / Type Variation (warm server, -json)
// ---------------------------------------------------------------------------

// BenchmarkServerCommand_SmallJPG reads a 203B JPEG via warm server.
func BenchmarkServerCommand_SmallJPG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/base.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_MediumJPG reads a 3.5KB JPEG via warm server.
func BenchmarkServerCommand_MediumJPG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_LargeJPG reads a 133KB JPEG via warm server.
func BenchmarkServerCommand_LargeJPG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/test.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_PNG reads a 284B PNG via warm server.
func BenchmarkServerCommand_PNG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.png"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_TIFF reads a 60KB TIFF via warm server.
func BenchmarkServerCommand_TIFF(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.tiff"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkServerCommand_MediumJPG_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_LargeJPG reads a 133KB JPEG via warm server.
func BenchmarkServerCommand_LargeJPG_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/test.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_PNG reads a 284B PNG via warm server.
func BenchmarkServerCommand_PNG_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.png"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_TIFF reads a 60KB TIFF via warm server.
func BenchmarkServerCommand_TIFF_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.tiff"); err != nil {
			b.Fatal(err)
		}
	}
}
