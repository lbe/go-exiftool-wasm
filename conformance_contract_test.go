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
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// wantAPI is the exported API of github.com/ncruces/go-exiftool v0.4.2.
var wantAPI = []string{
	"func Command(io.Reader, ...string) ([]byte, error)",
	"func CommandContext(context.Context, io.Reader, ...string) ([]byte, error)",
	"func NewServer(...string) (*Server, error)",
	"func Unmarshal([]byte, map[string][]byte) error",
	"method (*Server) Close() error",
	"method (*Server) Command(...string) ([]byte, error)",
	"method (*Server) Shutdown() error",
	"type Server",
	"var Arg1",
	"var Config",
	"var Exec",
}

func TestExportedAPI(t *testing.T) {
	out, err := exec.Command("go", "list", "-f", "{{.Dir}}", implPath).Output()
	if err != nil {
		t.Fatalf("go list %s: %v", implPath, err)
	}
	dir := strings.TrimSpace(string(out))
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var got []string
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, filepath.Join(dir, name), nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, exportedDecls(file)...)
	}
	slices.Sort(got)
	if !slices.Equal(got, wantAPI) {
		t.Errorf("exported API of %s:\n got: %q\nwant: %q", implPath, got, wantAPI)
	}
}

func exportedDecls(file *ast.File) []string {
	var decls []string
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if !d.Name.IsExported() {
				continue
			}
			sig := d.Name.Name + signature(d.Type)
			if d.Recv == nil {
				decls = append(decls, "func "+sig)
				continue
			}
			recv := types.ExprString(d.Recv.List[0].Type)
			if ast.IsExported(strings.TrimPrefix(recv, "*")) {
				decls = append(decls, "method ("+recv+") "+sig)
			}
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				switch s := spec.(type) {
				case *ast.TypeSpec:
					if s.Name.IsExported() {
						decls = append(decls, "type "+s.Name.Name)
					}
				case *ast.ValueSpec:
					for _, n := range s.Names {
						if n.IsExported() {
							decls = append(decls, d.Tok.String()+" "+n.Name)
						}
					}
				}
			}
		}
	}
	return decls
}

func signature(ft *ast.FuncType) string {
	params := fieldTypes(ft.Params)
	results := fieldTypes(ft.Results)
	sig := "(" + strings.Join(params, ", ") + ")"
	switch len(results) {
	case 0:
	case 1:
		sig += " " + results[0]
	default:
		sig += " (" + strings.Join(results, ", ") + ")"
	}
	return sig
}

func fieldTypes(fields *ast.FieldList) []string {
	if fields == nil {
		return nil
	}
	var out []string
	for _, f := range fields.List {
		for range max(len(f.Names), 1) {
			out = append(out, types.ExprString(f.Type))
		}
	}
	return out
}

func TestCommandWarningIsNotError(t *testing.T) {
	out, err := Command(nil, "-echo2", "conformance warning", "-ver")
	if err != nil {
		t.Fatalf("warning on stderr with exit status 0 returned error: %v", err)
	}
	if _, err := strconv.ParseFloat(string(bytes.TrimSpace(out)), 64); err != nil {
		t.Errorf("stdout = %q, want the version", out)
	}
}

func TestCommandFailureReturnsStdoutAndError(t *testing.T) {
	empty := filepath.Join(t.TempDir(), "empty.jpg")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := Command(nil, "-json", empty)
	if err == nil {
		t.Fatal("empty file returned no error")
	}
	if !bytes.Contains(out, []byte(`"Error": "File is empty"`)) {
		t.Errorf("stdout = %q, want JSON with Error: File is empty", out)
	}
}

func TestCommandMissingFileHasEmptyStdout(t *testing.T) {
	out, err := Command(nil, "-json", "testdata/nonexistent.jpg")
	if err == nil {
		t.Fatal("missing file returned no error")
	}
	if len(out) != 0 {
		t.Errorf("stdout = %q, want empty", out)
	}
}

func TestCommandFailureIsExecExitError(t *testing.T) {
	if target == "wasm" {
		t.Skip("approved divergence: in-process ExifTool cannot return *exec.ExitError")
	}
	_, err := Command(nil, "testdata/nonexistent.jpg")
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("error = %T %v, want *exec.ExitError", err, err)
	}
	if code := exitErr.ExitCode(); code != 1 {
		t.Errorf("ExitCode() = %d, want 1", code)
	}
	if !bytes.Contains(exitErr.Stderr, []byte("File not found")) {
		t.Errorf("Stderr = %q, want File not found", exitErr.Stderr)
	}
}

func TestCommandContextCancelStopsRunningCommand(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	start := time.Now()
	go func() {
		_, err := CommandContext(ctx, nil, "-if", "sleep 20; 1", "testdata/sample.jpg")
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil {
			t.Error("cancelled command returned no error")
		}
		if elapsed := time.Since(start); elapsed > 10*time.Second {
			t.Errorf("cancelled command returned after %v", elapsed)
		}
	case <-time.After(10 * time.Second):
		t.Error("cancelled command still running after 10s")
	}
}

func TestServerCloseDuringCommand(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := e.Command("-if", "sleep 5; 1", "testdata/sample.jpg")
		done <- err
	}()
	time.Sleep(500 * time.Millisecond)
	if err := e.Close(); err != nil {
		t.Errorf("Close during Command: %v", err)
	}
	select {
	case err := <-done:
		if err == nil {
			t.Error("Command interrupted by Close returned no error")
		}
	case <-time.After(10 * time.Second):
		t.Error("Command still running 10s after Close")
	}
}

func TestServerStderrIsError(t *testing.T) {
	e, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := e.Shutdown(); err != nil {
			t.Error(err)
		}
	}()
	out, err := e.Command("-echo2", "conformance warning", "-ver")
	if err == nil || err.Error() != "exiftool: conformance warning" {
		t.Errorf("error = %v, want exiftool: conformance warning", err)
	}
	if out != nil {
		t.Errorf("stdout = %q, want nil", out)
	}
}

func TestExecSelectsBinary(t *testing.T) {
	if target == "wasm" {
		t.Skip("approved divergence: Exec cannot select a binary for in-process ExifTool")
	}
	saved := Exec
	defer func() { Exec = saved }()
	Exec = filepath.Join(t.TempDir(), "missing-exiftool")
	if _, err := Command(nil, "-ver"); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("Command error = %v, want fs.ErrNotExist", err)
	}
	if _, err := NewServer(); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("NewServer error = %v, want fs.ErrNotExist", err)
	}
}
