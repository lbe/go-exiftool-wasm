# Plan: Improve Test Coverage for package wasihost

Current coverage: **38.6%**  
Target coverage: **≥ 75%**

Two problems are addressed together because they are related:

1. Seven tests that belong in `package wasihost` are stranded in
   `go-exiftool-wasm/helpers_test.go`. Moving them here removes the need for
   four exported test-support methods on `State` that exist only to bridge the
   package boundary.

2. The ten most complex functions in the package — the core fd I/O group
   (`Xfd_close`, `Xfd_read`, `Xfd_write`, `Xfd_seek`, `Xfd_readdir`,
   `Xfd_filestat_get`, `Xpath_filestat_get`, `Xpath_open`, `Xpath_rename`,
   `Xpoll_oneoff`) — have 0% standalone coverage. Several helpers they depend
   on (`writeFilestat`, `allocFD`, `Mem`) are also uncovered. Partial gaps
   remain in a further eight functions.

---

## Phase 1 — Migrate seven tests from package exiftool

### Why these tests are in the wrong package

During the Cycle 7 TDD migration the correction agent added four exported
wrappers (`ResolvePath`, `ReadBytes`, `AssertSingleOwner`, `LogTrace`) to
`wasihost.State` so that tests stranded in `package exiftool` could reach
internal state across the package boundary. The tests themselves construct
`wasihost.New(...)` directly and assert on `wasihost` types — they are
`wasihost` tests in all but location.

### Tests to move (all from `go-exiftool-wasm/helpers_test.go`)

| Test | What it covers |
|---|---|
| `TestWASIStubs` | No-op and ENOSYS stubs, `Xfd_renumber`, path-mutation EROFS |
| `TestAssertSingleOwner` | `WithOwnerAssertion`, `assertSingleOwner`, `currentGID` |
| `TestLogTrace` | `WithTracing`, `logTrace` |
| `TestWASIReadBytesNilPaths` | `readBytes` nil-guard branches |
| `TestResolvePath` | `resolvePath` longest-prefix match, nil-mount case |
| `TestDirEntriesFile` | `DirEntriesFile` all methods, `wasiDirInfo` all methods |
| `TestFsFileWrapSeekNoSeeker` | `FSFileWrap.Seek` no-seeker error branch |

### Changes required

**New file: `wasi-wasm2go/helpers_test.go`**

- Package declaration: `package wasihost`
- Copy the seven tests listed above
- In each test, replace `ws.AssertSingleOwner()` → `ws.assertSingleOwner()`,
  `ws.LogTrace(...)` → `ws.logTrace(...)`, `ws.ReadBytes(...)` →
  `ws.readBytes(...)`, `ws.ResolvePath(...)` → `ws.resolvePath(...)`, and
  `wasihost.WasiESuccess` etc. → `wasiESuccess` etc. (all now in-package)
- Replace `ws := &wasiState{State: wasihost.New(...)}` with `s :=
  wasihost.New(...)` and call methods directly on `s`
- `TestFsFileWrapSeekNoSeeker` uses `devNullFile` from `package exiftool` (not
  exported). Replace with a local no-seeker stub defined at the top of
  `helpers_test.go`:

```go
// noSeekerFile is a minimal fs.File that does not implement io.Seeker.
// Used by TestFsFileWrapSeekNoSeeker.
type noSeekerFile struct{}

func (*noSeekerFile) Read([]byte) (int, error)   { return 0, io.EOF }
func (*noSeekerFile) Close() error               { return nil }
func (*noSeekerFile) Stat() (fs.FileInfo, error) { return nil, nil }
```

**Edit: `go-exiftool-wasm/helpers_test.go`**

Remove the seven tests listed above. No other changes to this file.

**Edit: `wasi-wasm2go/wasihost.go`**

Remove the four exported test-support wrappers — they exist only to serve
the tests being moved:

```go
// DELETE these four methods:
func (s *State) ResolvePath(guestPath string) (*mountEntry, string)
func (s *State) ReadBytes(ptr, length int32) []byte
func (s *State) AssertSingleOwner()
func (s *State) LogTrace(format string, args ...interface{})
```

Also remove the exported errno constants block:

```go
// DELETE — no longer needed after TestWASIStubs moves in-package:
const (
    WasiESuccess = wasiESuccess
    WasiEBadf    = wasiEBadf
    WasiENoSys   = wasiENoSys
    WasiEROFS    = wasiEROFS
)
```

### Coverage gained by Phase 1

Functions reaching > 0% for the first time: `logTrace`, `currentGID`,
`assertSingleOwner` (full), all six `wasiDirInfo` methods, all four
`DirEntriesFile` methods (`Read`, `Close`, `Stat`, `ReadDir`), both
`FSFileWrap` methods (`Stat`, `Seek`), `Xfd_fdstat_set_flags`, `Xfd_sync`,
`Xcall_host_function`.

**Estimated coverage after Phase 1: ~52%**

---

## Phase 2 — New file: `group_a_fd_test.go`

This file covers the ten completely-untested core fd I/O functions, plus
`writeFilestat`, `allocFD`, and `Mem`. It uses the same Level 2 harness
pattern as `group_c_test.go` and `group_e_test.go`.

### Standard harness

```go
buf := make([]byte, 65536)
tmpDir := t.TempDir()
s := New(func() []byte { return buf },
    WithWritableMount("/", tmpDir, os.DirFS(tmpDir)),
)
// fd 3 is the preopen for "/"
const dirfd = 3
```

Path strings are written into `buf` at a fixed offset (e.g. 1024). The fd
returned by `Xpath_open` is read from `buf` at the result pointer.

### Test function: `TestMem`

- Construct `New(func() []byte { return buf }, ...)`, call `s.Mem()`, assert
  the returned slice is `buf`.

### Test function: `TestAllocFD`

- Construct a state with two writable-mount preopens. Call `Xpath_open` three
  times in succession to allocate fds 5, 6, 7 (fds 3 and 4 are preopens).
- Call `Xfd_close` on fd 5. Call `Xpath_open` again; assert the returned fd is
  5 (slot reuse).
- Also exercises `allocFD` slice growth: call `Xpath_open` enough times that
  the initial capacity is exceeded; assert no panic.

### Test function: `TestWriteFilestat`

The 64-byte filestat struct layout is tested via `Xfd_filestat_get`:

- Create a file of known content in `tmpDir`. Open it via `Xpath_open`. Call
  `Xfd_filestat_get(fd, bufPtr)`. Read back the struct fields at their fixed
  offsets:
  - `buf[bufPtr+16:+8]` as uint64 == `fdFile` (4)
  - `buf[bufPtr+32:+8]` as uint64 == file size
  - `buf[bufPtr+40:+8]` as uint64 > 0 (mtime)
- Open a preopen dir fd (fd 3). Call `Xfd_filestat_get`. Assert filetype field
  == `fdDir` (3).
- Call with an invalid fd; assert `wasiEBadf`.

### Test function: `TestFdClose`

- Open a file via `Xpath_open`; assert returned fd > 0.
- Call `Xfd_close(fd)`; assert `wasiESuccess`.
- Call `Xfd_close(fd)` again; assert `wasiEBadf` (slot cleared).
- Call `Xfd_close(3)` (preopen); assert `wasiEBadf` (preopens cannot close).
- Call `Xfd_close(-1)`; assert `wasiEBadf`.

### Test function: `TestFdRead`

- **stdin path**: construct with `WithStdin(strings.NewReader("hello"))`.
  Write a 1-iovec at `buf[1024:]` pointing to `buf[2048:2053]`. Call
  `Xfd_read(0, 1024, 1, 512)`. Assert `buf[2048:2053]` == `"hello"` and
  `uint32(buf[512:]) == 5`.
- **stdin nil**: construct with no `WithStdin`. Call `Xfd_read(0, ...)`.
  Assert returns `wasiESuccess` with nread = 0.
- **osFile path (ReadAt)**: create a 10-byte file `"ABCDEFGHIJ"`. Open
  read-only via `Xpath_open`. Call `Xfd_read` with a 4-byte iovec. Assert
  correct bytes read and `entry.offset` advanced (verify via `Xfd_tell`).
- **second read continues from offset**: call `Xfd_read` again; assert next 4
  bytes.
- **EBADF**: invalid fd and fd with nil file.

### Test function: `TestFdWrite`

- **stdout path**: construct with `WithStdout(&bytes.Buffer{})`. Write
  `"hello"` into `buf[2048:]`. Write a 1-iovec at `buf[1024:]` pointing there.
  Call `Xfd_write(1, 1024, 1, 512)`. Assert buffer contains `"hello"` and
  nwritten = 5.
- **stderr path**: same pattern with fd 2 and `WithStderr`.
- **stdout nil**: construct with no `WithStdout`. Call `Xfd_write(1, ...)`.
  Assert returns `wasiESuccess` with nwritten = 0 (no panic).
- **osFile path (WriteAt)**: create an empty file. Open with write rights via
  `Xpath_open` (set `oflagCreat|oflagTrunc`). Write `"XYZ"`. Call
  `Xfd_write(fd, ...)`. Assert `os.ReadFile` returns `"XYZ"` and
  `Xfd_tell` returns 3.
- **EBADF**: invalid fd.

### Test function: `TestFdSeek`

- Create a 10-byte file `"ABCDEFGHIJ"`. Open via `Xpath_open`. 
- **SEEK_SET**: `Xfd_seek(fd, 4, 0, resultPtr)`. Assert result written to
  `buf[resultPtr:]` == 4 and `Xfd_tell` == 4.
- **SEEK_CUR**: from offset 4, `Xfd_seek(fd, 2, 1, resultPtr)`. Assert result
  == 6.
- **SEEK_END**: `Xfd_seek(fd, -3, 2, resultPtr)`. Assert result == 7.
- **EISDIR**: open a directory fd via `Xpath_open`; call `Xfd_seek`; assert
  `wasiEIsdir`.
- **EINVAL**: open an fs.FS-backed file (read-only mount, `FSFileWrap`); call
  `Xfd_seek`; assert `wasiEInval` (FSFileWrap does not implement io.Seeker for
  non-seeker underlying files — use a non-seeker `fstest.MapFS` entry).
- **EBADF**: invalid fd.

### Test function: `TestFdReaddir`

- Create a directory `tmpDir/sub/` containing files `a.txt` and `b.txt`.
  Open `sub` via `Xpath_open`. Call `Xfd_readdir(fd, bufPtr, bufLen, 0,
  usedPtr)`.
- Parse the written dirent structs: each is 24 + nameLen bytes. Assert entry
  names and types match the directory contents.
- **cookie**: call `Xfd_readdir` again with cookie=1; assert only one entry
  returned (the second one).
- **buffer too small**: set `bufLen` smaller than one dirent; assert `bufUsed`
  == 0 (nothing fits).
- **preopen lazy load**: call `Xfd_readdir` on fd 3 (preopen for `/`); assert
  no panic, `bufUsed` >= 0.
- **EBADF**: invalid fd.

### Test function: `TestXpathFilestatGet`

- **read-only mount**: use `WithMount("/", fstest.MapFS{"a.txt": ...})`. Write
  `"a.txt"` to `buf`. Call `Xpath_filestat_get(3, 0, pathPtr, pathLen,
  statPtr)`. Assert filetype field == `fdFile`.
- **writable mount, host file exists**: create `tmpDir/real.txt`. Write
  `"real.txt"` to `buf`. Call `Xpath_filestat_get`. Assert size field matches
  `os.Stat`.
- **writable mount, host missing, overlay hit**: use an overlay `fstest.MapFS`
  with `"lib/perl.pm"` embedded. Write `"lib/perl.pm"` to buf. Call
  `Xpath_filestat_get`. Assert succeeds (overlay fallback path).
- **ENOENT**: path not in host or overlay.

### Test function: `TestXpathOpen`

- **`/dev/null`**: write `"/dev/null"` to buf. Call `Xpath_open`. Assert
  returned fd has `fdType == fdCharDev`.
- **read-only mount**: open `"a.txt"` from a `fstest.MapFS`. Assert
  `Xfd_filestat_get` on the returned fd shows size > 0.
- **writable mount, existing host file**: create `tmpDir/host.txt`. Open it.
  Assert the returned fd is backed by an osFile (verify via
  `Xfd_filestat_get` size).
- **writable mount, oflagCreat**: write `"new.txt"` to buf with
  `oflagCreat` set. Assert `os.Stat(filepath.Join(tmpDir, "new.txt"))` succeeds
  after the call.
- **writable mount, no host file, no create, overlay hit**: embed a file in the
  overlay `fs.FS`; call without `oflagCreat`; assert opens successfully.
- **directory open**: open a real directory under `tmpDir`. Assert returned fd
  has `fdType == fdDir` and `entry.path` is the absolute guest path.
- **ENOENT**: path not found anywhere.

### Test function: `TestXpathRename`

- **success**: create `tmpDir/src.txt`. Write both `"src.txt"` and `"dst.txt"`
  into `buf`. Call `Xpath_rename(3, srcPtr, srcLen, 3, dstPtr, dstLen)`.
  Assert `os.Stat(src)` returns `ErrNotExist` and `os.Stat(dst)` succeeds.
- **EROFS**: call on a read-only `WithMount`; assert `wasiEROFS`.
- **ENOENT**: both mounts nil (zero dirfd, no matching path).

### Test function: `TestXpollOneoff`

Construct with a synthetic 48-byte subscription struct and 32-byte event
struct at known offsets.

- **clock subscription**: write one clock subscription (`eventType=0`) with
  timeout = 1 nanosecond. Call `Xpoll_oneoff`. Assert `nevents` == 1, errno
  field in output event == 0.
- **fd_read subscription, valid fd**: write one fd_read subscription
  (`eventType=1`) with fd=0 (stdin). Assert errno field == 0.
- **fd_read subscription, invalid fd**: write one fd_read subscription with
  fd=99. Assert errno field == `wasiEBadf`.
- **multiple subscriptions**: two subscriptions (one clock, one fd_read).
  Assert `nevents` == 2.

---

## Phase 3 — Fill partial gaps in existing test files

These are targeted additions to existing test functions, not new test
functions.

### `group_a_test.go` — `TestGroupAFoundation`

**`resolveDirfdPath` (58.3% → ~90%)**: the uncovered branch is a non-preopen
directory fd. After opening a subdirectory via `Xpath_open` (which stores its
absolute guest path in the fd entry), call `resolveDirfdPath` with that fd and
a relative child path. Assert the resolved mount-relative path is the
concatenation of the directory fd's stored path and the relative input.

**`mountHostPaths` (62.5% → 100%)**: the uncovered branch is a non-root
writable mount where primary and joined paths are identical (no fallback).
Construct a state with `WithWritableMount("/work", tmpDir, ...)` and call
`mountHostPaths` with a relative path; assert fallback is `""`.

**`readBytes` (66.7% → 100%)**: add a call with `ptr=0` and assert nil
return (the ptr==0 branch is untested).

### `group_c_test.go` — `TestFilestatMutations`

**`Xfd_filestat_set_times` fstFlags=0 (70% → 100%)**: add a sub-test that
calls with `fstFlags=0` on an osFile-backed fd. Assert returns `wasiESuccess`
and `os.Stat` mtime is unchanged.

**`Xpath_filestat_set_times` fstFlags=0 (66.7% → 100%)**: same — call with
`fstFlags=0`, assert returns `wasiESuccess`.

**`applyMtim` error path (80% → 100%)**: call `applyMtim` with a path that
does not exist (e.g. `tmpDir + "/deleted.txt"`). Assert returns non-zero
errno.

### `group_e_test.go` — `TestGroupEPositionedIO`

**`Xfd_pread` ReadAt-not-supported branch (82.1% → 100%)**: open a file from a
read-only `fstest.MapFS` (`FSFileWrap`, which does not support `ReadAt`). Call
`Xfd_pread`. Assert returns `wasiESuccess` with nread = 0 (the
`!ok` break path).

**`Xfd_pwrite` WriteAt-not-supported branch (80.8% → 100%)**: open a file from
a read-only `fstest.MapFS`. Call `Xfd_pwrite`. Assert returns `wasiESuccess`
with nwritten = 0.

---

## Coverage projection

| After | Estimated coverage |
|---|---|
| Baseline (current) | 38.6% |
| Phase 1 (move 7 tests) | ~52% |
| Phase 2 (group_a_fd_test.go) | ~72% |
| Phase 3 (gap fills) | ~78% |

The remaining ~22% is dominated by error and branch paths inside `Xfd_read`,
`Xfd_write`, and `Xpath_open` that require specific I/O failure conditions
(e.g., simulating a `ReadAt` error mid-iovec). These are not targeted here
because the benefit is marginal relative to the scaffolding required.

---

## File inventory

| Action | File |
|---|---|
| Create | `wasi-wasm2go/helpers_test.go` |
| Create | `wasi-wasm2go/group_a_fd_test.go` |
| Edit (add sub-tests) | `wasi-wasm2go/group_a_test.go` |
| Edit (add sub-tests) | `wasi-wasm2go/group_c_test.go` |
| Edit (add sub-tests) | `wasi-wasm2go/group_e_test.go` |
| Edit (remove 7 tests) | `go-exiftool-wasm/helpers_test.go` |
| Edit (remove 4 exported methods + const block) | `wasi-wasm2go/wasihost.go` |

---

## Sequencing

Phase 1 must come first because it removes the exported wrappers
(`ResolvePath`, `ReadBytes`, `AssertSingleOwner`, `LogTrace`) from
`wasihost.go`. If Phase 2 or Phase 3 are done first, those methods still
exist, which is acceptable, but doing Phase 1 first keeps the public API
surface correct throughout.

Within Phase 1 the edit to `go-exiftool-wasm/helpers_test.go` (remove tests)
and the edit to `wasi-wasm2go/wasihost.go` (remove wrappers) must be done
atomically with the creation of `wasi-wasm2go/helpers_test.go`, otherwise
either the `exiftool` package or the `wasihost` package will fail to compile
mid-change.

Phases 2 and 3 are independent of each other and can be done in any order.
