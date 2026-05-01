package exiftool

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"testing"
	"testing/fstest"
)

func TestExiftoolVersion(t *testing.T) {
	ctx := context.Background()
	workDir := os.DirFS("testdata")

	out, err := Run(ctx, workDir, "-ver")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	ver := string(bytes.TrimSpace(out))
	t.Logf("exiftool version: %s", ver)
	if ver == "" {
		t.Fatal("empty version output")
	}
}

func TestExiftoolJSON(t *testing.T) {
	ctx := context.Background()
	workDir := os.DirFS("testdata")

	out, err := Run(ctx, workDir, "-json", "/work/test.jpg")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(out) == 0 {
		t.Fatal("no output from exiftool")
	}

	var result []map[string]interface{}
	if err := json.Unmarshal(out, &result); err != nil {
		t.Fatalf("invalid JSON: %v\nraw: %s", err, string(out))
	}

	if len(result) != 1 {
		t.Fatalf("expected 1 image result, got %d", len(result))
	}

	fields := result[0]
	t.Logf("Got %d fields from test.jpg", len(fields))

	if v, ok := fields["ExifToolVersion"]; !ok {
		t.Error("missing ExifToolVersion field")
	} else {
		t.Logf("ExifToolVersion: %v", v)
	}

	if v, ok := fields["Make"]; !ok {
		t.Error("missing Make field")
	} else if v != "samsung" {
		t.Errorf("expected Make=samsung, got %v", v)
	}

	if v, ok := fields["Model"]; !ok {
		t.Error("missing Model field")
	} else if v != "SM-G930P" {
		t.Errorf("expected Model=SM-G930P, got %v", v)
	}
}

func TestExiftoolMultipleArgs(t *testing.T) {
	ctx := context.Background()
	workDir := os.DirFS("testdata")

	out, err := Run(ctx, workDir, "-json", "-Make", "-Model", "/work/test.jpg")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	var result []map[string]interface{}
	if err := json.Unmarshal(out, &result); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}

	fields := result[0]
	if len(fields) < 3 {
		t.Errorf("expected at least 3 fields (SourceFile, Make, Model), got %d", len(fields))
	}
	t.Logf("fields: %v", fields)
}

func TestPerl5LibEnv(t *testing.T) {
	want := "/zeroperl/lib/5.16.3:/zeroperl/lib/5.16.3/wasm32-wasi"
	if got := perl5LibEnv("5.16.3"); got != want {
		t.Fatalf("perl5LibEnv mismatch: got %q want %q", got, want)
	}
}

func TestDetectPerlLibVersion(t *testing.T) {
	fsys := fstest.MapFS{
		"lib/5.16.3/placeholder": &fstest.MapFile{Data: []byte("x")},
		"lib/site_perl/placeholder": &fstest.MapFile{Data: []byte("x")},
	}
	got, ok := detectPerlLibVersion(fsys)
	if !ok {
		t.Fatal("expected perl lib version to be detected")
	}
	if got != "5.16.3" {
		t.Fatalf("unexpected perl lib version: got %q", got)
	}
}

func TestDetectPerlLibVersionMissing(t *testing.T) {
	fsys := fstest.MapFS{
		"lib/site_perl/placeholder": &fstest.MapFile{Data: []byte("x")},
	}
	if got, ok := detectPerlLibVersion(fsys); ok || got != "" {
		t.Fatalf("expected missing version, got %q ok=%v", got, ok)
	}
}

func TestResolveExiftoolScriptPrefersRootFS(t *testing.T) {
	rootFS := fstest.MapFS{
		"exiftool.min.pl": &fstest.MapFile{Data: []byte("print qq(root);")},
	}
	workFS := fstest.MapFS{
		"exiftool.min.pl": &fstest.MapFile{Data: []byte("print qq(work);")},
	}
	got := resolveExiftoolScript(rootFS, workFS)
	want := wrapExiftoolScript([]byte("print qq(root);"))
	if !bytes.Equal(got, want) {
		t.Fatalf("resolved script mismatch: got %q want %q", string(got), string(want))
	}
}

func TestResolveExiftoolScriptFallsBackToWorkFS(t *testing.T) {
	workFS := fstest.MapFS{
		"exiftool.min.pl": &fstest.MapFile{Data: []byte("print qq(work);")},
	}
	got := resolveExiftoolScript(nil, workFS)
	want := wrapExiftoolScript([]byte("print qq(work);"))
	if !bytes.Equal(got, want) {
		t.Fatalf("resolved script mismatch: got %q want %q", string(got), string(want))
	}
}

func TestResolveExiftoolScriptFindsEmbeddedPath(t *testing.T) {
	rootFS := fstest.MapFS{
		"embed/exiftool.min.pl": &fstest.MapFile{Data: []byte("print qq(embed-root);")},
	}
	got := resolveExiftoolScript(rootFS, nil)
	want := wrapExiftoolScript([]byte("print qq(embed-root);"))
	if !bytes.Equal(got, want) {
		t.Fatalf("resolved script mismatch: got %q want %q", string(got), string(want))
	}
}

func TestResolveExiftoolScriptFallsBackToEmbedded(t *testing.T) {
	rootFS := fstest.MapFS{
		"exiftool.min.pl": &fstest.MapFile{Data: []byte("   \n\t")},
	}
	got := resolveExiftoolScript(rootFS, nil)
	want := cachedWrappedEmbeddedExiftoolScript()
	if !bytes.Equal(got, want) {
		t.Fatal("expected embedded script fallback")
	}
}

func TestResolveExiftoolScriptFallsBackOnPerlFS(t *testing.T) {
	got := resolveExiftoolScript(perlFS(), nil)
	want := cachedWrappedEmbeddedExiftoolScript()
	if !bytes.Equal(got, want) {
		t.Fatal("expected embedded script fallback for perlFS")
	}
}

func TestResolveExiftoolScriptFallsBackOnDefaultRootFS(t *testing.T) {
	got := resolveExiftoolScript(defaultRootFS(), nil)
	want := cachedWrappedEmbeddedExiftoolScript()
	if !bytes.Equal(got, want) {
		t.Fatal("expected embedded script fallback for defaultRootFS")
	}
}
