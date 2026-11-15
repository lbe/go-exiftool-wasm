//go:build integration

package exiftool

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// copySample writes src to path, creating parent directories as needed.
func copySample(t *testing.T, src []byte, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, src, 0o600); err != nil {
		t.Fatal(err)
	}
}

// commandRecord runs a one-shot JSON Command and returns its single record.
func commandRecord(t *testing.T, args ...string) map[string]any {
	t.Helper()
	out, err := Command(nil, args...)
	if err != nil {
		t.Fatalf("Command(%v): %v", args, err)
	}
	var records []map[string]any
	if err := json.Unmarshal(out, &records); err != nil {
		t.Fatalf("Command(%v) output is not JSON: %v\n%s", args, err, out)
	}
	if len(records) != 1 {
		t.Fatalf("Command(%v): got %d records, want 1", args, len(records))
	}
	return records[0]
}

func TestCommandSourceFileMatchesOperand(t *testing.T) {
	sample, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	copySample(t, sample, filepath.Join(root, "cwd", "in.jpg"))
	copySample(t, sample, filepath.Join(root, "outside", "out.jpg"))
	t.Chdir(filepath.Join(root, "cwd"))

	for _, op := range []string{
		"in.jpg",
		"./in.jpg",
		filepath.Join(root, "cwd", "in.jpg"),
		filepath.Join(root, "outside", "out.jpg"),
		"../outside/out.jpg",
	} {
		rec := commandRecord(t, "-json", "-G1", "-n", op)
		if rec["SourceFile"] != op {
			t.Errorf("operand %q: SourceFile = %v", op, rec["SourceFile"])
		}
		if rec["IFD0:Make"] != "TestMaker" {
			t.Errorf("operand %q: IFD0:Make = %v", op, rec["IFD0:Make"])
		}
	}
}

func TestCommandRelativeSymlinkOutsideCwd(t *testing.T) {
	sample, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	copySample(t, sample, filepath.Join(root, "outside", "out.jpg"))
	if err := os.MkdirAll(filepath.Join(root, "cwd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(root, "cwd", "link")); err != nil {
		t.Fatal(err)
	}
	t.Chdir(filepath.Join(root, "cwd"))

	rec := commandRecord(t, "-json", "-G1", "-n", "link/out.jpg")
	if rec["SourceFile"] != "link/out.jpg" {
		t.Errorf("SourceFile = %v", rec["SourceFile"])
	}
	if rec["IFD0:Make"] != "TestMaker" {
		t.Errorf("IFD0:Make = %v", rec["IFD0:Make"])
	}
}

func TestCommandCwdWithQuoteAndBackslash(t *testing.T) {
	sample, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), `it's \dir`)
	copySample(t, sample, filepath.Join(dir, "in.jpg"))
	t.Chdir(dir)

	rec := commandRecord(t, "-json", "-G1", "-n", "in.jpg")
	if rec["IFD0:Make"] != "TestMaker" {
		t.Errorf("IFD0:Make = %v", rec["IFD0:Make"])
	}
}

func TestServerNoRestartAcrossDirectories(t *testing.T) {
	sample, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	// Keep operands outside both cwd and os.TempDir so no preexisting mount covers them.
	tmp := filepath.Join(root, "tmp")
	if err = os.MkdirAll(tmp, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", tmp)
	for _, rel := range []string{"a/one.jpg", "b/two.jpg", "c/three.jpg"} {
		copySample(t, sample, filepath.Join(root, rel))
	}

	s, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	first := s.generation

	commands := [][]string{
		{"-json", "-G1", "-n", filepath.Join(root, "a", "one.jpg")},
		{"-json", "-G1", "-n", filepath.Join(root, "b", "two.jpg")},
		{"-overwrite_original", "-Artist=NoRestart", filepath.Join(root, "c", "three.jpg")},
		{"-o", filepath.Join(root, "d", "copy.jpg"), filepath.Join(root, "a", "one.jpg")},
		{"-m", "-tagsFromFile", filepath.Join(root, "a", "one.jpg"), "-overwrite_original", filepath.Join(root, "b", "two.jpg")},
	}
	for i, args := range commands {
		if _, err = s.Command(args...); err != nil {
			t.Fatalf("command %d: %v", i, err)
		}
		if s.generation != first {
			t.Fatalf("command %d restarted the server", i)
		}
	}

	out, err := s.Command("-json", "-Artist", filepath.Join(root, "c", "three.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	var records []map[string]any
	if err := json.Unmarshal(out, &records); err != nil || len(records) != 1 {
		t.Fatalf("records: %v, %s", err, out)
	}
	if records[0]["Artist"] != "NoRestart" {
		t.Errorf("Artist = %v, want NoRestart", records[0]["Artist"])
	}
	if _, err := os.Stat(filepath.Join(root, "d", "copy.jpg")); err != nil {
		t.Error(err)
	}
	if err := s.Shutdown(); err != nil {
		t.Fatal(err)
	}
}
