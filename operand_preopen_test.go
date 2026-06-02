package exiftool

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/lbe/go-exiftool-wasm/internal/testutil"
)

func TestOperandPreopenDirs_U1_skipFlags(t *testing.T) {
	t.Parallel()
	got := operandPreopenDirs(t.TempDir(), []string{"-json", "-q"})
	assertPreopenDirs(t, got, nil)
}

func TestOperandPreopenDirs_U2_skipRelativeUnderCwd(t *testing.T) {
	t.Parallel()
	root := testutil.Root(t)
	cwd := filepath.Join(root, "testdata")
	got := operandPreopenDirs(cwd, []string{"-json", "testdata/a.jpg"})
	assertPreopenDirs(t, got, nil)
}

func TestOperandPreopenDirs_U3_absoluteFile(t *testing.T) {
	t.Parallel()
	got := operandPreopenDirs(t.TempDir(), []string{"-json", "/Users/x/Pictures/a.jpg"})
	assertPreopenDirs(t, got, []string{"/Users/x/Pictures"})
}

func TestOperandPreopenDirs_U4_relativeDotDot(t *testing.T) {
	t.Parallel()
	root := testutil.Root(t)
	work := filepath.Join(root, "testdata", "dotdot", "work")
	got := operandPreopenDirs(work, []string{"-json", "../outside/x.jpg"})
	outside := filepath.Join(root, "testdata", "dotdot", "outside")
	assertPreopenDirs(t, got, []string{outside})
}

func TestOperandPreopenDirs_U5_dedupSameParent(t *testing.T) {
	t.Parallel()
	got := operandPreopenDirs(t.TempDir(), []string{
		"/Users/x/Pictures/a.jpg",
		"/Users/x/Pictures/b.jpg",
	})
	assertPreopenDirs(t, got, []string{"/Users/x/Pictures"})
}

func TestOperandPreopenDirs_U6_twoParents(t *testing.T) {
	t.Parallel()
	got := operandPreopenDirs(t.TempDir(), []string{
		"/Users/x/Pictures/a.jpg",
		"/Users/x/Docs/b.pdf",
	})
	assertPreopenDirs(t, got, []string{"/Users/x/Pictures", "/Users/x/Docs"})
}

func TestOperandPreopenDirs_U7_missingFileStillDerivesParent(t *testing.T) {
	t.Parallel()
	got := operandPreopenDirs(t.TempDir(), []string{"/nonexistent/path/missing.jpg"})
	assertPreopenDirs(t, got, []string{"/nonexistent/path"})
}

func TestOperandPreopenDirs_U8_directoryOperand(t *testing.T) {
	t.Parallel()
	root := testutil.Root(t)
	work := filepath.Join(root, "testdata", "dotdot", "work")
	outside := filepath.Join(root, "testdata", "dotdot", "outside")
	got := operandPreopenDirs(work, []string{outside})
	assertPreopenDirs(t, got, []string{outside})
}

func TestAbsolutizeOperands_skipsExtValue(t *testing.T) {
	t.Parallel()
	cwd := t.TempDir()
	got := absolutizeOperands(cwd, []string{"-ext", "jpg", "file.txt"})
	if got[1] != "jpg" {
		t.Errorf("ext value: got %q, want jpg", got[1])
	}
	if got[2] != "file.txt" {
		t.Errorf("file operand under cwd: got %q, want %q", got[2], "file.txt")
	}
}

func TestAbsolutizeOperands_endOfOptions(t *testing.T) {
	t.Parallel()
	cwd := t.TempDir()
	flagLike := filepath.Join(cwd, "-looks-like-flag.jpg")
	if err := os.WriteFile(flagLike, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := absolutizeOperands(cwd, []string{"--", "-looks-like-flag.jpg"})
	if got[1] != "-looks-like-flag.jpg" {
		t.Errorf("after --: got %q, want %q", got[1], "-looks-like-flag.jpg")
	}
	_ = flagLike
}

func TestAbsolutizeOperands_atStdinDash(t *testing.T) {
	t.Parallel()
	cwd := t.TempDir()
	got := absolutizeOperands(cwd, []string{"-@", "-"})
	if len(got) != 2 || got[0] != "-@" || got[1] != "-" {
		t.Fatalf("got %v, want [-@ -]", got)
	}
}

func TestOperandPreopenDirs_includesConfigPath(t *testing.T) {
	t.Parallel()
	saved := Config
	defer func() { Config = saved }()

	root := testutil.Root(t)
	work := filepath.Join(root, "testdata", "dotdot", "work")
	outside := filepath.Join(root, "testdata", "dotdot", "outside")
	Config = filepath.Join(outside, "sample.jpg")

	combined := append(packageArgs(), "-ver")
	got := operandPreopenDirs(work, combined)
	assertPreopenDirs(t, got, []string{outside})
}

func assertPreopenDirs(t *testing.T, got, want []string) {
	t.Helper()

	norm := func(paths []string) []string {
		if len(paths) == 0 {
			return nil
		}
		out := make([]string, len(paths))
		for i, p := range paths {
			p = filepath.Clean(p)
			if real, err := filepath.EvalSymlinks(p); err == nil {
				p = real
			}
			out[i] = p
		}
		slices.Sort(out)
		return out
	}

	gotNorm := norm(got)
	wantNorm := norm(want)
	if !slices.Equal(gotNorm, wantNorm) {
		t.Errorf("operandPreopenDirs = %v, want %v", got, want)
	}
}
