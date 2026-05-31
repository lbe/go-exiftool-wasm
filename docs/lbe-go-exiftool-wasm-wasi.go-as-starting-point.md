# Porting Go wazero's WASI Implementation to wasm2go: A Feasibility Discussion

---

## Original Question

> What is the feasibility of porting the Go wazero WASI implementation to Go wasm2go?

## Response

Short answer: **conceptually quite feasible, mechanically tedious, and partly already in motion** — but the two projects have such different host-integration models that "porting" is closer to a rewrite of the glue than a code transplant.

### What you're actually asking to bridge

**wazero's WASI** (`imports/wasi_snapshot_preview1`) is a *host module* of Go functions plugged into wazero's runtime. Each function receives a `context.Context` and an `api.Module` whose `Memory()` accessor reads and writes the guest's linear memory. Supporting state (fd table, preopens, args, env, clocks, random source) lives in an internal `sys.Context` attached to each `api.Module`. The real implementation logic sits in `internal/wasip1`, `internal/sys`, and `internal/sysfs`.

**wasm2go** is the opposite shape: an AOT translator that emits a single self-contained Go file. The output is a `Module` struct whose methods are the wasm exports; imports become Go *interfaces* that `New` consumes. Linear memory is just a `[]byte` field inside the generated struct. There is no runtime, no `api.Module`, no host-module builder — your import implementations are just Go method receivers.

So the porting work is essentially: take wazero's ~40 WASI function bodies and re-host them against an interface that wasm2go's generator expects, with memory access plumbed through a different mechanism.

### What makes it feasible

- Both are pure Go, no cgo, compatible licenses (Apache 2.0 and MIT).
- WASI snapshot-preview1 is a fixed surface — about 40 functions, well documented, and most of its logic (errno mapping, path resolution, fdtable, clock semantics, preopens) is just POSIX wrapping that has nothing to do with how wasm itself is executed.
- wazero's `wasip1` internals are written in fairly self-contained Go; they're not deeply entangled with the interpreter or compiler.
- There's strong prior art from the same author: ncruces maintains both wasm2go *and* `ncruces/go-sqlite3`, which currently uses wazero and is (per the pkg.go.dev description) being migrated toward wasm2go. SQLite uses only a tiny WASI stub (most I/O goes through SQLite's own VFS), so that project doesn't fully validate a complete WASI port, but it proves the host-side plumbing pattern works.

### What makes it tedious

1. **The function-signature ABI is different.** wazero's WASI uses typed wrappers over `(ctx, mod, params...uint64)`; wasm2go imports are typed Go interface methods (`func FdWrite(fd, iovs, iovsLen, nwrittenPtr int32) int32`). Every function needs a shim, and several use pointer parameters that wazero reads through `api.Memory` but wasm2go would expect to read through the generated module's memory slice directly.

2. **Memory access has no equivalent abstraction.** This is the biggest design point. wazero gives the host an `api.Memory` per call; wasm2go gives the host nothing — the memory lives inside the generated `Module`. You'd need to either pass the memory (or a back-reference to the module) into the import implementation on construction, or have the import implementation hold a `*Module` and read its memory field. Either way, the wazero functions that look like `mem.ReadUint32Le(offset)` get rewritten to `m.Memory[offset:offset+4]` accesses.

3. **Internal packages.** The reusable WASI logic lives under `internal/` in wazero, so you can't import it directly — you'd fork, vendor, or copy. The public `imports/wasi_snapshot_preview1` package is too tightly coupled to wazero's runtime types to lift wholesale.

4. **The hard WASI functions stay hard.** `poll_oneoff`, `fd_readdir`, `path_open`, and the `sock_*` extensions are where wazero has spent most of its WASI engineering effort, and they touch wazero's `sysfs` abstraction for non-blocking I/O and Windows path handling. Porting those is the long tail; the args/env/clocks/random/stdio core can be done in an afternoon.

5. **No `proc_exit` trap mechanism.** wazero uses its runtime's trap path to unwind on `proc_exit`. With wasm2go you'd implement it as a panic with a sentinel that the entry point recovers — straightforward but a behavioral difference to be aware of.

6. **Whatever wasm2go can't translate, you can't run.** wasm2go targets "a useful subset of Wasm produced by clang" — most of 1.0 plus some 2.0 features, but not SIMD, threads, exceptions, or the component model. A WASI-preview1 module built with wasi-sdk/clang is squarely in scope; a WASI-preview2 component is not.

### Worth considering instead

If you specifically want the wasm2go-style import-interface model, **`stealthrocket/wasi-go`** is a better starting point than wazero. It explicitly separates the WASI ABI shim from a `wasi.System` interface that "doesn't have to concern itself with ABI details nor access the guest's memory" — which is much closer to the abstraction wasm2go's generated interfaces expect. Bridging that to wasm2go-generated code is a noticeably shorter path than untangling wazero's host-module wiring.

### Rough effort estimate

For one developer who knows both codebases: a working subset (args, env, clocks, random, stdio, basic fd_read/fd_write/fd_close, proc_exit) in **days**; full preview1 with correct `poll_oneoff`, `fd_readdir`, and cross-platform `path_*` semantics matching wazero's behavior in **weeks**, and most of that time is the test corpus and Windows edge cases rather than the porting itself.

---

## Follow-up Question: lbe/go-exiftool-wasm as a Starting Point

> Let me add one more input for you. Look at lbe/go-exiftool-wasm. This is a Go package to provide access to exiftool running in a perl interpreter compiled to wasm. It contains a partial wasi.go implementation. Can/should this be a starting point to cover the remaining 23 or so wasi functions?

After being given the repository URL — `https://github.com/lbe/go-exiftool-wasm` — and fetching `wasi.go`:

## Response (After Reading the Source)

This isn't "a partial WASI implementation that could become a starting point." It's already a complete wasm2go host integration. Specifically:

- Import is `wasm2go "github.com/lbe/go-exiftool-wasm/internal/zeroperl"` — the wasm2go-generated zeroperl module, not wazero.
- Memory access is `*w.module.Xmemory().Slice()` — wasm2go's native API, direct slice into linear memory.
- Methods use the `X` prefix (`Xpath_open`, `Xfd_readdir`, …), meaning `wasiState` *is* the import-interface implementation that the generated module consumes.
- The state struct (fds, preopens, overlay mounts, guestIO) is exactly the shape sketched in the first response as "what you'd build."

So the earlier framing — "port wazero's WASI to a wasm2go-shaped interface" — is the wrong frame for the question. That structural retargeting work isn't ahead of you; it's been done. What's ahead is finishing function coverage on a working base.

### Reading wasi.go, the current state is:

**Implemented for real (~20):** environ_get/sizes_get, clock_time_get, random_get, proc_exit, fd_prestat_get/dir_name, fd_close, fd_read, fd_write, fd_seek, fd_tell, fd_fdstat_get, fd_filestat_get, fd_readdir, fd_renumber, path_filestat_get, path_open (with embedded-prefix + writable-host overlay), path_rename, poll_oneoff (at least clock subscriptions; the rest is past the fetch cutoff).

**Currently returning ENOSYS:** path_create_directory, path_link, path_readlink, path_remove_directory, path_symlink, path_unlink_file.

**Currently returning silent success (correct for exiftool, suspect for general use):** fd_filestat_set_size, fd_filestat_set_times, path_filestat_set_times, fd_fdstat_set_flags, fd_sync, call_host_function.

**Probably truly missing:** args_get/sizes_get (almost certainly there — Perl wouldn't start otherwise; just past the read cutoff), clock_res_get, fd_advise, fd_allocate, fd_datasync, fd_pread, fd_pwrite, proc_raise, sched_yield, sock_accept/recv/send/shutdown.

### Should this be the basis for completing the remaining ~23? Yes, unambiguously — with three calibrations:

**The "23 remaining" framing overstates the work.** The truly missing functions are dominated by trivial cases. `sock_*` and `proc_raise`/`sched_yield` are one-line ENOSYS or no-op stubs (nothing here calls them anyway). `fd_advise`/`fd_allocate`/`fd_datasync` are no-op success. `clock_res_get` is two lines. `fd_pread`/`fd_pwrite` are ~30 lines each, following the `fd_read`/`fd_write` pattern with explicit offsets. The whole "missing entirely" batch is maybe a couple of hours.

**The real work, if you care about it, is upgrading the ENOSYS path_\* stubs**, but only as the use case demands. Look at what's stubbed: `path_create_directory`, `path_remove_directory`, `path_unlink_file`, `path_link`, `path_symlink`, `path_readlink`. exiftool in read mode works without any of these — the project shipping is proof. The cases that actually need them:

- ExifTool tag-write workflows and `-overwrite_original`: needs `path_unlink_file` (`path_rename` is already done).
- `-o newdir/file.jpg` with auto-mkdir: needs `path_create_directory`.
- Perl module path resolution that follows symlinks aggressively: might need `path_readlink`. Probably already not hit because the embedded prefix is symlink-free.
- `path_link` and `path_symlink` are realistically never needed for any exiftool workflow.

Each is a one-screen function delegating to `os.Remove` / `os.Mkdir` / `os.Readlink`, mirroring the primary/fallback dance already present in `Xpath_rename` and `mountHostPaths`. The hard part of that pattern is already worked out.

**The silent-success stubs deserve a second look** before this is called "complete." Returning ESUCCESS from `fd_filestat_set_times` lies to the guest — Perl's `utime` appears to succeed without the mtime actually changing. For exiftool that's fine; ExifTool's `-P` preserves mtime via the tempfile-rename dance, not via `utime`. But the moment the use case expands beyond exiftool, those lies become correctness bugs. Worth a TODO at minimum, or just wiring them to `os.Chtimes` / `os.Truncate`.

### Concrete order of operations, by effort-to-value:

1. **15 minutes:** add the missing trivial cases — `args_get`/`sizes_get` if absent, `clock_res_get`, `fd_advise`/`allocate`/`datasync` as no-ops, `proc_raise`/`sched_yield`/`sock_*` as ENOSYS. Coverage jumps from ~30 to ~42 functions for nearly nothing.
2. **1–2 hours:** `fd_pread`, `fd_pwrite`. Real workloads using `IO::Seekable`'s `sysread`/`syswrite` with offsets will hit these.
3. **Half a day:** convert `path_unlink_file`, `path_create_directory`, `path_remove_directory` from ENOSYS to real implementations, following the `path_rename` pattern. Unlocks exiftool in-place writes and `-o newdir/`.
4. **Half a day, only if needed:** `path_readlink`, `path_symlink`, `path_link`.
5. **Ongoing/optional:** replace the silent-success stubs with real `os` calls. Matters for non-exiftool workloads.

After that batch you have a complete-enough preview1 for clang/wasi-sdk binaries that aren't named "perl," and you'd have an interesting reusable artifact in its own right: the first WASI implementation written against wasm2go's import-interface model natively rather than retrofitted from wazero's host-module model. That's worth a tiny pure-Go module of its own, decoupled from the exiftool package and from the specific generated zeroperl import.

One thing worth calling out about what's already there: the single-owner goroutine assertion, the `entry.offset` vs kernel-position note in `fd_seek`/`fd_tell`, the writable-overlay logic with primary/fallback path resolution — these are exactly the subtle correctness issues that take real wall-clock time to discover the hard way. Whoever wrote this has done the fiddly part. The remaining functions are uniformly easier than what's already done; "finishing" this is mostly typing.

---

## Referenced Projects

- **wazero** — https://github.com/wazero/wazero (also https://wazero.io)
- **wasm2go** — https://github.com/ncruces/wasm2go
- **ncruces/go-sqlite3** — https://github.com/ncruces/go-sqlite3 (prior art for the wazero→wasm2go transition)
- **stealthrocket/wasi-go** — https://github.com/stealthrocket/wasi-go (alternative WASI implementation with cleaner separation)
- **lbe/go-exiftool-wasm** — https://github.com/lbe/go-exiftool-wasm (working wasm2go-native WASI implementation discussed in the follow-up)
- **6over3/zeroperl** — https://github.com/6over3/zeroperl (Perl-to-WASM build used by go-exiftool-wasm)

