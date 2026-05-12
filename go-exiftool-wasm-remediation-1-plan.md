# go-exiftool-wasm Remediation Plan 1: WASI Filesystem Parity (Revised)

**Date:** May 11, 2026
**Repository:** `github.com/lbe/go-exiftool-wasm`
**Issues:** Directory recursion (Issue #1) · File write API (Issue #2)
**Status:** Ready for implementation

---

## 1. Verified Root Causes

### Issue #1 — Directory Recursion (`-r -ext`)

**Symptom:** `exiftool -r -ext jpg -T -Filename testdata/tree` returns empty stdout.

**Root cause:** `resolveDirfdPath` in `wasi.go` only handles preopen file-descriptor entries. When
`path_open` opens a subdirectory (yielding a new, non-preopen fd), passing that fd as `dirfd` for
subsequent `path_open` or `fd_readdir` calls causes `resolveDirfdPath` to return `nil`. The entire
subtree then fails silently.

The fix is confined to two places in `wasi.go`:
1. `resolveDirfdPath` — add a branch for non-preopen directory fds that resolves relative paths
   using the stored absolute guest path from `fdEntry.path`.
2. `Xpath_open` — store the **resolved absolute guest path** (not the raw input string) in
   `fdEntry.path` for every directory fd, so the fix above has a reliable base path.

> `Xfd_readdir`, `Xfd_write`, and `Xpath_rename` are all fully implemented and are **not** the
> root cause. The original plan was incorrect on this point.

---

### Issue #2 — File Metadata Writing (`-tagsFromFile`)

**Symptom:** `exiftool -tagsFromFile src.jpg -overwrite_original dst.jpg` fails when `dst.jpg`
lives in CWD or any directory other than `os.TempDir()`.

**Root cause:** `newModule` mounts `/` (backed by `os.DirFS(".")`) with `writable: false` and no
`hostRoot`. ExifTool writes a side-car temp file adjacent to the destination, then renames it
atomically via `path_rename`. Because `/` has no `hostRoot`, `mountHostPath` returns `("", false)`
and `path_open` with write flags returns `EROFS`. The rename then also fails.

**Fix:** Mount `/` writable by default, using `os.Getwd()` as `hostRoot`. This matches the
access a native subprocess or CGo call would have. WASI is used here as an FFI transport, not
a security boundary — CWD write access is the correct baseline.

Change in `newModule` (`exiftool.go`):
```go
// before
{guestPath: "/", root: rootFS, writable: false}

// after
cwd, _ := os.Getwd()
{guestPath: "/", root: rootFS, writable: true, hostRoot: cwd}
```

> `fd_write`, `path_open` write-flag handling, and `path_rename` are all fully implemented.
> The gap is solely the missing `hostRoot` on the root mount.

---

## 2. Fix Summary (API-Compatible)

The ncruces public API (`Command`, `CommandContext`, `NewServer`, `Server.Command`, `Exec`, `Arg1`,
`Config`) is immutable. Neither fix adds exported symbols or changes function signatures.

| Issue | File | Change |
|-------|------|--------|
| #1 — Recursion | `wasi.go` | `resolveDirfdPath` non-preopen branch; `Xpath_open` absolute path storage |
| #2 — Write | `exiftool.go` | Root mount `/` gets `writable: true, hostRoot: cwd` |

Note: a `WritableDirs` package variable for out-of-CWD absolute paths is documented in
`Enhancement-WritableDirs.md` as a deferred future enhancement.

---

## 3. Mandatory Execution Rules

These rules govern every step. Violation is a hard stop.

| Rule | Requirement |
|------|-------------|
| **Primary agent** | Orchestration only. The primary agent reads the plan, invokes sub-agents, sequences commits and reviews. It makes no direct code changes. |
| **Recommended model** | Set the primary agent to **Claude Sonnet** or equivalent reasoning-grade model to ensure reliable orchestration and review judgement. |
| **Sub-agent model** | All implementation and review sub-agents use **Gemini Flash 3 Preview**. **Haiku is prohibited at every level.** |
| **TDD discipline** | Each implementation step is split into explicit **RED → GREEN → REFACTOR** sub-phases. Each sub-phase is one sub-agent invocation. Do not combine phases. |
| **Commit cadence** | Commit after REFACTOR completes. One commit per complete TDD cycle. Do not batch multiple cycles into one commit. |
| **Review protocol** | See §8. A review sub-agent runs immediately after every commit. |
| **Comments** | All changed or created Go code must carry: (a) Go doc comments on every exported symbol, (b) inline comments explaining non-obvious logic. |
| **Documentation** | `README.md` and `ARCHITECTURE.md` must be updated in the step where the impacted code changes land. Documentation is part of that step's REFACTOR phase, not a separate step. |
| **Sequencing** | Steps execute in the order defined. No step may begin until its predecessors are committed and reviewed. |
| **Communications** | All sub-agent prompts and review responses must be concise. No filler, no summaries of what was done that are obvious from the diff. |

---

## 4. Test Data Setup (Step 0) — Prerequisite

**Goal:** Create `testdata/tree/` with a nested directory structure containing valid JPEG files.
Required by Phase 1 tests before any code changes.

**Sub-agent task (Gemini Flash 3 Preview):**

1. Create the following structure under `testdata/tree/`:
   ```
   testdata/tree/
     a.jpg          # copy of testdata/test.jpg
     b.txt          # non-JPEG; must be ignored by -ext jpg
     subdir1/
       c.jpg        # copy of testdata/test.jpg
       subdir2/
         d.jpg      # copy of testdata/test.jpg
   ```
2. `a.jpg`, `c.jpg`, `d.jpg` must be byte-for-byte copies of `testdata/test.jpg` (which already
   exists and is a well-formed JPEG). Do NOT create synthetic stubs — minimal 4-byte JPEGs
   trigger ExifTool stderr warnings about truncated structure, which causes `Command` to return
   an error and all recursion tests to fail.
3. `b.txt` is a plain text file containing `"not an image"`.
4. Do not modify any Go source files.

**Commit message:** `testdata: add tree/ directory structure for recursion tests`

**Review:** Verify tree structure matches spec, no source files modified.
Review sub-agent amends commit with `Review Performed: Work Approved`.

---

## 5. Phase 1 — Fix Directory Recursion (Issue #1)

Dependencies: Step 0 committed and approved.

### Step 1.1 — RED

**Sub-agent task (Gemini Flash 3 Preview):**

Add a new file `recurse_test.go` in package `exiftool` containing a single test:

```go
// TestCommandRecurse verifies that the WASI guest correctly enumerates
// nested directories when ExifTool is invoked with -r -ext jpg.
func TestCommandRecurse(t *testing.T) {
    out, err := Command(nil, "-r", "-ext", "jpg", "-T", "-Filename", "testdata/tree")
    if err != nil {
        t.Fatalf("Command: %v", err)
    }
    got := strings.TrimSpace(string(out))
    if got == "" {
        t.Fatal("expected non-empty output: -r recursion returned nothing")
    }
    lines := strings.Split(got, "\n")
    if len(lines) != 3 {
        t.Fatalf("expected 3 jpg files, got %d lines:\n%s", len(lines), got)
    }
}
```

Run `go test -run TestCommandRecurse ./...` — the test **must fail** (empty output).
Confirm failure before proceeding. Do not change any other files.

**Commit:** `test(recurse): RED — TestCommandRecurse fails with empty output`

---

### Step 1.2 — GREEN

**Sub-agent task (Gemini Flash 3 Preview):**

Fix `wasi.go` only. No other files.

**Change 1 — `Xpath_open`:** `Xpath_open` has two separate `fdEntry` construction sites — one
inside the `if mount.writable {` block and one in the read-only path below it. **Both must be
updated.** For each site, when the entry is a directory (`fdType == fdDir`), store the resolved
absolute guest path instead of the raw `guestPath` input string:

```go
absGuestPath := path.Clean("/" + mount.guestPath + "/" + relPath)
```

**Site A — writable path** (inside `if mount.writable {`). Current code:
```go
w.fds[fd] = fdEntry{file: &osFile{File: hostFile}, path: guestPath, fdType: fdFile}
if fi != nil && fi.IsDir() {
    w.fds[fd].fdType = fdDir
}
```
Replace with:
```go
entryPath := guestPath
if fi != nil && fi.IsDir() {
    entryPath = path.Clean("/" + mount.guestPath + "/" + relPath)
}
w.fds[fd] = fdEntry{file: &osFile{File: hostFile}, path: entryPath, fdType: fdFile}
if fi != nil && fi.IsDir() {
    w.fds[fd].fdType = fdDir
}
```

**Site B — read-only path** (below the `if mount.writable` block). Current code:
```go
entry := fdEntry{file: &fsFileWrap{File: f}, path: guestPath, fdType: fdType}
```
Replace with:
```go
entryPath := guestPath
if fdType == fdDir {
    entryPath = path.Clean("/" + mount.guestPath + "/" + relPath)
}
entry := fdEntry{file: &fsFileWrap{File: f}, path: entryPath, fdType: fdType}
```

Both sites must be changed. If only one is changed, the Phase 1 review will fail criterion 3.

**Change 2 — `resolveDirfdPath`:** After the existing `entry.preopen` branch, add:
```go
// Non-preopen directory fd: resolve the relative caller path against the
// stored absolute guest path so nested path_open calls work correctly
// during directory recursion (e.g., ExifTool -r).
if entry.fdType == fdDir && entry.path != "" {
    return w.resolvePath(path.Join(entry.path, guestPath))
}
```

Run `go test -run TestCommandRecurse ./...` — the test **must pass**.
Run `go test ./...` — no regressions.

**Commit:** `fix(wasi): GREEN — resolveDirfdPath supports non-preopen directory fds`

---

### Step 1.3 — REFACTOR

**Sub-agent task (Gemini Flash 3 Preview):**

1. Add Go doc comments to `resolveDirfdPath` explaining the new branch.
2. Add an inline comment in `Xpath_open` explaining why `absGuestPath` is used instead of the
   raw input for directory entries.
3. Remove any debug or trace additions introduced during GREEN.
4. Run `go test ./...` — must pass with no changes to test assertions.
5. Update `ARCHITECTURE.md` — in the "WASI host implementation" section, add a bullet:
   > Non-preopen directory fds store the resolved absolute guest path in `fdEntry.path`,
   > enabling `resolveDirfdPath` to resolve relative paths for nested `path_open` calls
   > (required for ExifTool `-r` recursion).

**Commit:** `refactor(wasi): REFACTOR — document resolveDirfdPath non-preopen branch`

---

### Step 1.4 — Review (Phase 1)

**Review sub-agent task (Gemini Flash 3 Preview, separate invocation):**

Review the three commits from Phase 1 against these criteria:

1. `TestCommandRecurse` exists, asserts non-empty output, and asserts exactly 3 lines.
2. `resolveDirfdPath` has a correct non-preopen directory branch.
3. `Xpath_open` stores absolute guest path for directory fds in both writable and read-only paths.
4. No other functions were modified unnecessarily.
5. All changed code has Go doc and inline comments as required.
6. `ARCHITECTURE.md` is updated.
7. `go test ./...` passes.

**If any criterion fails:** Report specific failures. Primary agent re-invokes the Phase 1
implementation sub-agent with the correction list. The corrected code is committed, then this
review sub-agent re-runs.

**If all criteria pass:** Amend the REFACTOR commit with the message suffix:
`Review Performed: Work Approved`

---

## 6. Phase 2 — CWD Writable by Default (Issue #2)

Dependencies: Phase 1 committed and approved.

### Step 2.1 — RED

**Sub-agent task (Gemini Flash 3 Preview):**

Add a new file `write_test.go` in package `exiftool` containing a single test.

**Important design constraints — read before writing the test:**

- Do NOT use `filepath.Abs` or absolute paths for src/dst. The WASI sandbox resolves guest
  paths against `hostRoot` (CWD) via `filepath.Join(cwd, relPath)`. Absolute guest paths
  produce a mangled host path (`filepath.Join("/work/cwd", "/abs/path")` = `/abs/path` on
  Linux but breaks cross-platform). Use paths relative to CWD throughout.
- Do NOT use `t.TempDir()` or `os.Chdir`. Create a sub-directory under CWD with
  `os.MkdirTemp(".", "write_test_*")` so it falls under the sandbox root mount. Clean up
  with `t.Cleanup(func() { os.RemoveAll(tmpDir) })`.

```go
// TestCommand_tagsFromFile verifies that Command can copy metadata between files
// under the process working directory using -tagsFromFile -overwrite_original.
// Both src and dst are relative paths so the WASI sandbox hostRoot join resolves
// them correctly without absolute-path ambiguity.
func TestCommand_tagsFromFile(t *testing.T) {
    // Arrange: create a temp subdir under CWD; copy test.jpg there as dst.
    // Relative paths are used throughout so filepath.Join(cwd, rel) is correct.
    tmpDir, err := os.MkdirTemp(".", "write_test_*")
    if err != nil {
        t.Fatalf("MkdirTemp: %v", err)
    }
    t.Cleanup(func() { os.RemoveAll(tmpDir) })

    srcRel := "testdata/test.jpg"
    dstRel := filepath.Join(tmpDir, "dst.jpg")

    srcData, err := os.ReadFile(srcRel)
    if err != nil {
        t.Fatalf("read src: %v", err)
    }
    if err := os.WriteFile(dstRel, srcData, 0o644); err != nil {
        t.Fatalf("write dst: %v", err)
    }

    // Act: -tagsFromFile copies metadata; -overwrite_original rewrites dst in-place.
    out, err := Command(nil, "-tagsFromFile", srcRel, "-overwrite_original", dstRel)

    // Assert
    if err != nil {
        t.Fatalf("Command: %v\noutput: %s", err, out)
    }
    if !strings.Contains(string(out), "image files updated") {
        t.Fatalf("expected 'image files updated' in output, got:\n%s", out)
    }
}
```

Run `go test -run TestCommand_tagsFromFile ./...` — must fail (write to CWD fails; EROFS or
similar). Do not change any other files.

**Commit:** `test(write): RED — TestCommand_tagsFromFile fails, root mount read-only`

---

### Step 2.2 — GREEN

**Sub-agent task (Gemini Flash 3 Preview):**

Two files change: `exiftool.go` and `wasi.go`. No other files.

**Change 1 — `exiftool.go`, `newModule`:**

Replace the root mount entry:
```go
// before
mounts := []mountEntry{
    {guestPath: "/", root: rootFS, writable: false},
```
with:
```go
// Mount "/" writable so the guest can write files in the process working
// directory. WASI is used here as an FFI transport, not a security boundary;
// CWD write access matches what a subprocess or CGo call would have.
cwd, err := os.Getwd()
if err != nil {
    return nil, nil, fmt.Errorf("exiftool: getwd: %w", err)
}
mounts := []mountEntry{
    {guestPath: "/", root: rootFS, writable: true, hostRoot: cwd},
```

**Change 2 — `wasi.go`, `Xpath_open` writable branch:**

**Critical constraint:** `Xpath_open` was modified in Phase 1 to store the resolved absolute
guest path in `fdEntry.path` for directory entries. Do not modify that logic or
`resolveDirfdPath` — they must be preserved exactly as Phase 1 left them.

The current writable branch calls `os.OpenFile` and returns `wasiENoEnt` on any error. With the
root mount now writable, every read of an embedded Perl file (e.g. `/lib/perl5/Image/ExifTool.pm`)
reaches this branch, calls `os.OpenFile(filepath.Join(cwd, "lib/perl5/..."))`, finds nothing on
disk, and fails. The Perl interpreter cannot load.

Fix: when `os.OpenFile` fails **and** the open is purely read-only (no write/create flags), fall
back to `mount.root.Open` so embedded files are still served from the overlay FS.

Locate the writable branch inside `Xpath_open` (around the existing `hostFile, osErr :=
os.OpenFile(...)` call) and replace:
```go
hostFile, osErr := os.OpenFile(hostPath, osFlags, 0o666)
if osErr != nil {
    return int32(wasiENoEnt)
}
```
with:
```go
hostFile, osErr := os.OpenFile(hostPath, osFlags, 0o666)
if osErr != nil {
    // For pure read-only opens, fall back to the overlay FS so embedded
    // Perl files are still served even when the root mount is writable.
    if osFlags == os.O_RDONLY {
        // IMPORTANT: `f` and `err` are declared with `var` in the outer scope
        // of Xpath_open. Use plain assignment (=), NOT short declaration (:=).
        // Re-declaring with := here would shadow the outer variables and fail
        // to compile (or silently discard the value). The outer `var f fs.File`
        // and `var err error` declarations exist precisely for this reuse.
        f, err = mount.root.Open(relPath)
        if err != nil {
            return int32(wasiENoEnt)
        }
        fi, _ := f.Stat()
        fdType := fdFile
        if fi != nil && fi.IsDir() {
            fdType = fdDir
        }
        fd := w.allocFD()
        // Use absGuestPath for directory entries so resolveDirfdPath can
        // resolve relative paths against this fd in subsequent calls.
        // Phase 1 established this invariant for all directory fdEntry values.
        entryPath := guestPath
        if fdType == fdDir {
            entryPath = path.Clean("/" + mount.guestPath + "/" + relPath)
        }
        entry := fdEntry{file: &fsFileWrap{File: f}, path: entryPath, fdType: fdType}
        if fdType == fdDir {
            if df, ok := f.(fs.ReadDirFile); ok {
                entry.dirFile = df
            }
        }
        w.fds[fd] = entry
        binary.LittleEndian.PutUint32(mem[fdPtr:], uint32(fd))
        return int32(wasiESuccess)
    }
    return int32(wasiENoEnt)
}
```

Run `go test -run TestCommand_tagsFromFile ./...` — must pass.
Run `go test ./...` — no regressions (embedded Perl files still load; all prior tests pass).

**Commit:** `fix(exiftool,wasi): GREEN — writable root mount with overlay read fallback`

---

### Step 2.3 — REFACTOR

**Sub-agent task (Gemini Flash 3 Preview):**

1. Add an inline comment on the root mount entry in `newModule` explaining the FFI rationale
   (the GREEN step already includes this; verify it is present and accurate).
2. Update the `newModule` Go doc comment to state that the root mount is writable.
3. Update the package doc in `init.go` — the existing note that `os.TempDir` is mounted
   read-write should be updated to reflect that CWD (and thus all relative paths) is also
   writable.
4. Update `README.md` — update or add a "Writing Files" section documenting that write
   operations work without any special configuration, and referencing
   `Enhancement-WritableDirs.md` for out-of-CWD absolute path use cases.
5. Update `ARCHITECTURE.md` — in "Filesystem/mount model", change the `/` mount description
   to reflect `writable: true, hostRoot: cwd`, and note the `Xpath_open` read-only fallback.
6. Run `go test ./...` — must pass.

**Commit:** `refactor(exiftool,wasi): REFACTOR — docs, README, ARCHITECTURE for writable root mount`

---

### Step 2.4 — Review (Phase 2)

**Review sub-agent task (Gemini Flash 3 Preview, separate invocation):**

Review the three Phase 2 commits against these criteria:

1. `newModule` root mount has `writable: true` and `hostRoot` set to `os.Getwd()` result.
2. `os.Getwd()` error is propagated — not silently ignored.
3. `Xpath_open` writable branch has the `os.O_RDONLY` fallback to `mount.root.Open`.
4. The fallback path sets `fdType` correctly for directories and wires `dirFile` for
   `ReadDirFile` implementors. For directory fds, `fdEntry.path` must be set to the resolved
   absolute guest path (`path.Clean("/" + mount.guestPath + "/" + relPath)`) — not the raw
   `guestPath` input — consistent with the Phase 1 invariant in `Xpath_open`.
5. No new exported symbols. `Command` and `CommandContext` signatures unchanged.
6. `TestCommand_tagsFromFile` passes; no existing tests regressed.
7. Test uses relative paths and `os.MkdirTemp(".", ...)` — no `os.Chdir`, no `filepath.Abs`.
8. `README.md` "Writing Files" section references `Enhancement-WritableDirs.md`.
9. `ARCHITECTURE.md` root mount description is updated.
10. `init.go` package doc reflects writable CWD.
11. Only `exiftool.go` and `wasi.go` changed among Go source files (plus test file).

**If any criterion fails:** Report failures. Primary agent re-invokes Phase 2 implementation
sub-agent with correction list. Corrected code is committed, then this review sub-agent re-runs.

**If all criteria pass:** Amend the REFACTOR commit:
`Review Performed: Work Approved`

---

## 7. Final Verification

After both phases are approved, the primary agent runs:

```
go test ./...
go vet ./...
```

Both must exit 0. Report results verbatim. No further changes unless a failure is found.

---

## 8. Review Protocol (Reference)

| Outcome | Action |
|---------|--------|
| All criteria pass | Review sub-agent amends REFACTOR commit adding line: `Review Performed: Work Approved` |
| One or more criteria fail | Review sub-agent lists each failure precisely. Primary agent sends correction list to the **same implementation sub-agent model** used for that phase. Corrections are committed. Review sub-agent re-runs in the **same review sub-agent session**. |
| Review sub-agent cannot determine pass/fail | Primary agent escalates to user. Do not guess. |

---

## 9. Files Modified

| File | Change |
|------|--------|
| `wasi.go` | Phase 1: `resolveDirfdPath` non-preopen dir branch; `Xpath_open` absolute path storage. Phase 2: `Xpath_open` read-only fallback to overlay FS for writable mounts |
| `exiftool.go` | `newModule` root mount: `writable: true, hostRoot: cwd` |
| `recurse_test.go` | New — `TestCommandRecurse` |
| `write_test.go` | New — `TestCommand_tagsFromFile` |
| `testdata/tree/` | New tree structure with minimal JPEG stubs |
| `README.md` | "Writing Files" section referencing `Enhancement-WritableDirs.md` |
| `ARCHITECTURE.md` | Recursion fix note; updated root mount description |
| `Enhancement-WritableDirs.md` | New — deferred enhancement specification |

**Not modified:** `cmd.go`, `init.go`, `server.go`, `server_test.go`, `internal/zeroperl/`, embed assets.
**API guarantee:** No exported function signature changed. No new exported types or functions.

---

## 10. Success Criteria

- `go test ./...` passes with zero failures.
- `go vet ./...` exits 0.
- `TestCommandRecurse` returns exactly 3 lines (a.jpg, c.jpg, d.jpg).
- `TestCommand_tagsFromFile` succeeds with "image files updated" in output.
- All commits in both phases carry `Review Performed: Work Approved` in their message.
- No exported function signature changed. No new exported types or functions.
- `Enhancement-WritableDirs.md` committed as a deferred specification.
