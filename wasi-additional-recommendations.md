# WASI host — additional recommendations

This document captures follow-up improvements for the zeroperl WASI host in
`wasi.go`, beyond what is strictly required for the current import surface and
tests. It is derived from comparing `wasi-host-requirements.md` to the
implementation and from behavioral review of edge cases.

## High value

### 1. `clock_time_get` — honor `clock_id`

Return `ERRNO_NOSYS` (52) for unsupported clock IDs. For `CLOCK_REALTIME` (0)
and `CLOCK_MONOTONIC` (1), use distinct semantics: wall-clock time vs a
monotonic timeline (for example anchored at interpreter init with
`time.Since`, or another explicit policy). Today every ID receives
`time.Now().UnixNano()` with `ESUCCESS`, which is wrong if anything relies on
monotonic behavior.

### 2. `poll_oneoff` — fd subscriptions vs clock-only minimal host

Either:

- Return `ERRNO_NOSYS` for `fd_read` / `fd_write` subscriptions when real
  readiness is not implemented (matches the “minimal implementation” story in
  `wasi-host-requirements.md` and fails loudly if Perl uses `select`/`poll` on
  fds), or

- Implement a small, explicit readiness model (for example: stdin readable when
  buffered data exists; regular files readable/writable for open fds as
  appropriate).

The middle ground—reporting `ESUCCESS` for valid fds without modeling
readiness—makes misbehavior harder to diagnose.

### 3. No-op mutators should not pretend success

`fd_filestat_set_size` and `path_filestat_set_times` currently return `ESUCCESS`
without performing truncate or timestamp updates. Prefer `ERRNO_NOSYS` or
`ERRNO_ROFS` when the operation is intentionally unsupported, so Perl does not
assume `ftruncate` / `utime` succeeded unless the host actually did the work.

## Medium value

### 4. Environment (`environ_get` / `environ_sizes_get`)

If workloads need a real `%ENV` (for example `TZ`, locale variables, or custom
`PERL_*` flags), merge caller-supplied entries with the fixed `PERL5LIB` line,
or apply overrides atop `os.Environ()`. For embedded-only use, documenting
that only synthetic `PERL5LIB` is visible may be enough without code changes.

### 5. `Xfd_filestat_set_times` on `wasiState`

This method exists in `wasi.go` but is not part of the generated
`Xwasi_snapshot_preview1` interface in `internal/zeroperl/zeroperl.go`; the
current wasm import set does not call it. Remove it to reduce confusion, or
retain it only with a clear comment or build tag explaining why it is kept.

### 6. `fd_write` when `WriteAt` is absent

If an open file does not support `WriteAt`, the write loop can contribute zero
bytes while still returning success. Consider rejecting write opens for such
handles, or falling back to sequential `Write` while advancing `entry.offset`,
with documented limitations.

## Lower priority

### 7. `fd_readdir` and cookies

Re-reading the full directory on each call is acceptable until large directories
or concurrent host changes matter. A cursor-based implementation aligned with
WASI cookie semantics would be more spec-faithful and more efficient.

### 8. Asyncify and `fd_read`

If stdin or other `fd_read` paths ever become asynchronous or yield to the host
scheduler, keep side effects compatible with Binaryen Asyncify rewinds (see
`wasi-host-requirements.md`). The current synchronous Go host is fine for
today’s model if tests cover the intended workloads.
