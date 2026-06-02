package exiftool

import (
	"os"
	"path/filepath"
	"strings"
)

// operandPreopenDirs returns host directories that must be preopened for file
// operands outside cwd and os.TempDir(). Operands are resolved against cwd so
// relative paths and .. segments reach host locations outside /host.
//
// Each returned directory is registered as a writable host preopen (see
// registerHostDirPreopenAliases). Callers must only pass argv they intend
// ExifTool to read; do not use arbitrary host paths as operands unless the
// widened writable mount is acceptable.
func operandPreopenDirs(cwd string, arg []string) []string {
	cwd = filepath.Clean(cwd)
	tempDir := filepath.Clean(os.TempDir())

	var dirs []string
	seen := make(map[string]struct{})

	add := func(dir string) {
		dir = filepath.Clean(dir)
		if dir == "" || dir == string(filepath.Separator) {
			return
		}
		if real, err := filepath.EvalSymlinks(dir); err == nil {
			dir = real
		}
		if pathWithinDir(dir, cwd) || pathWithinDir(dir, tempDir) {
			return
		}
		if _, ok := seen[dir]; ok {
			return
		}
		seen[dir] = struct{}{}
		dirs = append(dirs, dir)
	}

	scanFileOperands(cwd, arg, func(_ int, absPath string) {
		dir := filepath.Dir(absPath)
		if info, err := os.Stat(absPath); err == nil && info.IsDir() {
			dir = absPath
		}
		add(dir)
	})
	return dirs
}

// commandWritableDirs returns host directories preopened for Command side effects:
// os.TempDir plus any operand parent directories outside cwd/temp.
func commandWritableDirs(cwd string, arg []string) []string {
	return append([]string{os.TempDir()}, operandPreopenDirs(cwd, arg)...)
}

// prepareCommandEval resolves argv for a one-shot Command: combined package and
// user args are scanned for operand preopens and rewritten to host-absolute paths.
func prepareCommandEval(cwd string, userArg []string) (writableDirs []string, argv []string) {
	pkg := packageArgs()
	combined := append(append([]string{}, pkg...), userArg...)
	writableDirs = commandWritableDirs(cwd, combined)
	abs := absolutizeOperands(cwd, combined)
	return writableDirs, insertCharsetAfterPrefix(abs, len(pkg))
}

func insertCharsetAfterPrefix(arg []string, prefixLen int) []string {
	if prefixLen == 0 {
		return append([]string{"-charset", "filename=utf8"}, arg...)
	}
	out := make([]string, 0, len(arg)+2)
	out = append(out, arg[:prefixLen]...)
	out = append(out, "-charset", "filename=utf8")
	out = append(out, arg[prefixLen:]...)
	return out
}

// absolutizeOperands rewrites file operands for the WASI guest: paths outside cwd
// and os.TempDir() stay host-absolute (operand preopens); paths under cwd keep the
// caller's relative spelling when possible so ExifTool output matches native CLI.
func absolutizeOperands(cwd string, arg []string) []string {
	return guestOperandPaths(cwd, arg)
}

// guestOperandPaths applies [guestPathForOperand] to each file operand in arg.
func guestOperandPaths(cwd string, arg []string) []string {
	if len(arg) == 0 {
		return arg
	}
	out := make([]string, len(arg))
	copy(out, arg)
	scanFileOperands(cwd, out, func(i int, absPath string) {
		out[i] = guestPathForOperand(cwd, out[i], absPath)
	})
	return out
}

// guestPathForOperand picks the argv spelling ExifTool should see for one operand.
func guestPathForOperand(cwd, original, absPath string) string {
	tempDir := filepath.Clean(os.TempDir())
	if !pathWithinDir(absPath, cwd) && !pathWithinDir(absPath, tempDir) {
		return absPath
	}
	if pathWithinDir(absPath, tempDir) && !pathWithinDir(absPath, cwd) {
		return absPath
	}
	if !filepath.IsAbs(original) {
		return original
	}
	if rel, err := filepath.Rel(cwd, absPath); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
		return rel
	}
	return absPath
}

// scanFileOperands invokes visit for each argv element that is a file operand
// (not an ExifTool flag, not a non-path flag value such as the extension after
// -ext, and not before a bare "--" end-of-options marker).
func scanFileOperands(cwd string, arg []string, visit func(index int, absPath string)) {
	skipNext := false
	nextIsPath := false
	afterEndOpts := false
	for i, a := range arg {
		if skipNext {
			skipNext = false
			if nextIsPath && a != "-" {
				visit(i, resolveOperandPath(cwd, a))
			}
			continue
		}
		if !afterEndOpts {
			if a == "--" {
				afterEndOpts = true
				continue
			}
			if isExiftoolFlag(a) {
				if exiftoolFlagTakesNextArg(a) {
					skipNext = true
					nextIsPath = exiftoolFlagValueIsPath(a)
				}
				continue
			}
		}
		visit(i, resolveOperandPath(cwd, a))
	}
}

func isExiftoolFlag(arg string) bool {
	return len(arg) > 0 && arg[0] == '-'
}

func exiftoolFlagTakesNextArg(flag string) bool {
	if name, _, ok := strings.Cut(flag, "="); ok && name != "" {
		flag = name
	}
	switch flag {
	case "-ext", "-ext2", "-ext3", "-config", "-o", "-out",
		"-TagsFromFile", "-tagsFromFile", "-@", "-common_args",
		"-charset", "-lang", "-sep", "-struct", "-fileOrder", "-progresslevel",
		"-geotag", "-csv":
		return true
	}
	return false
}

func exiftoolFlagValueIsPath(flag string) bool {
	if name, val, ok := strings.Cut(flag, "="); ok && name != "" {
		flag = name
		if val != "" {
			return exiftoolFlagValueIsPath(flag)
		}
	}
	switch flag {
	case "-ext", "-ext2", "-ext3", "-lang", "-charset", "-sep", "-struct",
		"-fileOrder", "-progresslevel", "-common_args":
		return false
	}
	return exiftoolFlagTakesNextArg(flag)
}

func resolveOperandPath(cwd, operand string) string {
	if filepath.IsAbs(operand) {
		return filepath.Clean(operand)
	}
	abs, err := filepath.Abs(filepath.Join(cwd, operand))
	if err != nil {
		return operand
	}
	return abs
}

func mergePreopenDirLists(existing, add []string) (merged []string, changed bool) {
	seen := make(map[string]struct{}, len(existing)+len(add))
	for _, d := range existing {
		d = cleanPreopenDir(d)
		if d == "" {
			continue
		}
		seen[d] = struct{}{}
		merged = append(merged, d)
	}
	for _, d := range add {
		d = cleanPreopenDir(d)
		if d == "" {
			continue
		}
		if _, ok := seen[d]; ok {
			continue
		}
		seen[d] = struct{}{}
		merged = append(merged, d)
		changed = true
	}
	if !changed {
		return existing, false
	}
	return merged, true
}

func cleanPreopenDir(dir string) string {
	dir = filepath.Clean(dir)
	if real, err := filepath.EvalSymlinks(dir); err == nil {
		return real
	}
	return dir
}

func pathWithinDir(path, dir string) bool {
	path = filepath.Clean(path)
	dir = filepath.Clean(dir)
	if ap, err := filepath.Abs(path); err == nil {
		path = ap
	}
	if ad, err := filepath.Abs(dir); err == nil {
		dir = ad
	}
	if rd, err := filepath.EvalSymlinks(dir); err == nil {
		dir = rd
	}
	if rp, err := filepath.EvalSymlinks(path); err == nil {
		path = rp
	} else if parent, err := filepath.EvalSymlinks(filepath.Dir(path)); err == nil {
		path = filepath.Join(parent, filepath.Base(path))
	}
	if path == dir {
		return true
	}
	rel, err := filepath.Rel(dir, path)
	if err != nil {
		return strings.HasPrefix(path, dir+string(filepath.Separator))
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
