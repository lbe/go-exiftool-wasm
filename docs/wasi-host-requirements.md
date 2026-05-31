# WASI Host Requirements for zeroperl

This document specifies the exact WASI and host imports that a runtime must
implement in order to host `zeroperl.wasm`. The import list was derived
analytically from `wasm-objdump` on a built `zeroperl.wasm` binary — it
reflects what the linker actually emitted, not what the WASI preview1 spec
defines in full.

## Build-time note

The import surface is the same regardless of build arguments
(`ZEROPERL_SHRINK`, `ZEROPERL_EMBED_PREFIX`, `ZEROPERL_SFS_COMPRESS`). What
varies is what the filesystem calls must actually serve:

| Build | What the host filesystem must provide |
|---|---|
| `ZEROPERL_EMBED_PREFIX=true` (default) | stdin/stdout/stderr + user-visible paths only. The Perl module library is embedded in the wasm via SFS and served internally — the host filesystem is never asked for `/zeroperl/...` paths. |
| `ZEROPERL_EMBED_PREFIX=false` | The full Perl module library (`perl-wasi-prefix/`) must be mounted and `PERL5LIB` must be set so Perl can find it via `path_open`. |

## `env` module — custom host import

This module is **not** part of WASI preview1. It is the zeroperl-specific
callback mechanism.

| Function | Signature | Required |
|---|---|---|
| `call_host_function` | `(func_id i32, argc i32, argv i32) → i32` | **Yes** |

`call_host_function` is invoked whenever Perl calls a subroutine or method
registered via `zeroperl_register_function` or `zeroperl_register_method`. If
the embedding does not use host callbacks, a stub returning `0` is sufficient.
However, the symbol must be present or instantiation will fail.

`call_host_function` is also listed as an **Asyncify boundary** (see below).

## `wasi_snapshot_preview1` — required imports

These are the 30 functions present in the binary's import section. The host
runtime must provide all of them. Functions that are not exercised by a
particular workload may return `ERRNO_NOSYS` (52), but they must be present.

### Environment

| Function | Signature |
|---|---|
| `environ_get` | `(environ i32, environ_buf i32) → i32` |
| `environ_sizes_get` | `(environ_count i32, environ_buf_size i32) → i32` |

Used by wasi-libc at startup to populate `%ENV`. Must return the full
environment including `PERL5LIB` when the host needs to influence module
search paths.

### Clock

| Function | Signature |
|---|---|
| `clock_time_get` | `(clock_id i32, precision i64, time i32) → i32` |

`clock_res_get` is **not** imported. The binary only requests
`CLOCK_REALTIME` (0) and `CLOCK_MONOTONIC` (1). Other clock IDs may return
`ERRNO_NOSYS`.

### File descriptor I/O

| Function | Signature |
|---|---|
| `fd_read` | `(fd i32, iovs i32, iovs_len i32, nread i32) → i32` |
| `fd_write` | `(fd i32, iovs i32, iovs_len i32, nwritten i32) → i32` |
| `fd_close` | `(fd i32) → i32` |
| `fd_seek` | `(fd i32, offset i64, whence i32, newoffset i32) → i32` |
| `fd_tell` | `(fd i32, offset i32) → i32` |
| `fd_sync` | `(fd i32) → i32` |
| `fd_renumber` | `(fd i32, to i32) → i32` |
| `fd_readdir` | `(fd i32, buf i32, buf_len i32, cookie i64, bufused i32) → i32` |

`fd_read` is an **Asyncify boundary** (see below). `fd_sync` may safely return
`ESUCCESS` without performing any actual sync. `fd_renumber` implements `dup2`
semantics; Perl uses it for file handle manipulation.

### File descriptor metadata

| Function | Signature |
|---|---|
| `fd_fdstat_get` | `(fd i32, buf i32) → i32` |
| `fd_fdstat_set_flags` | `(fd i32, flags i32) → i32` |
| `fd_filestat_get` | `(fd i32, buf i32) → i32` |
| `fd_filestat_set_size` | `(fd i32, size i64) → i32` |

`fd_fdstat_get` is called by wasi-libc on stdin/stdout/stderr at startup to
determine file type and rights. It must return a valid `fdstat` struct for fds
0, 1, and 2. `fd_filestat_set_size` implements `ftruncate`; may return
`ERRNO_NOSYS` if write support is not needed.

### Preopens

| Function | Signature |
|---|---|
| `fd_prestat_get` | `(fd i32, buf i32) → i32` |
| `fd_prestat_dir_name` | `(fd i32, path i32, path_len i32) → i32` |

wasi-libc calls these sequentially starting at fd 3 at startup to discover
mounted directories. Return `ERRNO_BADF` once all preopened fds are exhausted.
This is how `path_open` knows which fds to use as directory handles.

### Path operations

| Function | Signature |
|---|---|
| `path_open` | `(dirfd i32, dirflags i32, path i32, path_len i32, oflags i32, fs_rights_base i64, fs_rights_inheriting i64, fdflags i32, opened_fd i32) → i32` |
| `path_filestat_get` | `(fd i32, flags i32, path i32, path_len i32, buf i32) → i32` |
| `path_filestat_set_times` | `(fd i32, flags i32, path i32, path_len i32, atim i64, mtim i64, fst_flags i32) → i32` |
| `path_create_directory` | `(fd i32, path i32, path_len i32) → i32` |
| `path_remove_directory` | `(fd i32, path i32, path_len i32) → i32` |
| `path_unlink_file` | `(fd i32, path i32, path_len i32) → i32` |
| `path_rename` | `(fd i32, old_path i32, old_path_len i32, new_fd i32, new_path i32, new_path_len i32) → i32` |
| `path_link` | `(old_fd i32, old_flags i32, old_path i32, old_path_len i32, new_fd i32, new_path i32, new_path_len i32) → i32` |
| `path_symlink` | `(old_path i32, old_path_len i32, fd i32, new_path i32, new_path_len i32) → i32` |
| `path_readlink` | `(fd i32, path i32, path_len i32, buf i32, buf_len i32, bufused i32) → i32` |

`path_open` is the primary mechanism for opening files by name. All paths are
relative to a preopen fd. `path_filestat_get` implements `stat`/`lstat`.
The mutating operations (`path_create_directory`, `path_remove_directory`,
`path_unlink_file`, `path_rename`, `path_link`, `path_symlink`) may return
`ERRNO_NOSYS` or `ERRNO_ROFS` if the filesystem is read-only, provided the
Perl scripts being run do not require write access. `path_readlink` and
`path_filestat_set_times` may similarly return `ERRNO_NOSYS` for read-only
embeddings.

### Poll

| Function | Signature |
|---|---|
| `poll_oneoff` | `(in i32, out i32, nsubscriptions i32, nevents i32) → i32` |

Used by wasi-libc for `select`/`poll` and by `Time::HiRes` for `usleep`. A
minimal implementation that handles clock subscriptions (for sleep) and returns
`ERRNO_NOSYS` for fd subscriptions is sufficient for most Perl workloads.

### Process

| Function | Signature |
|---|---|
| `proc_exit` | `(rval i32) → nil` |

Must terminate execution of the wasm instance (or unwind it). In a reactor
model the host typically catches the `proc_exit` trap and records the exit
code rather than terminating the host process.

### Random

| Function | Signature |
|---|---|
| `random_get` | `(buf i32, buf_len i32) → i32` |

Used to seed Perl's hash randomization and `rand()`. Must fill the buffer with
cryptographically random bytes.

## Asyncify boundaries

Binaryen's Asyncify transformation instruments the binary so that the call
stack can be unwind/rewound at two specific import boundaries. This is how
Perl's `setjmp`/`longjmp` exception mechanism works through WASM frames.

```
--pass-arg=asyncify-imports@wasi_snapshot_preview1.fd_read,env.call_host_function
```

**Implication for the host runtime:** both `fd_read` and `call_host_function`
may be invoked multiple times during a single logical Perl operation as
Asyncify rewinds the stack. The host implementation of these two functions must
be idempotent with respect to the rewind — on a rewind call, Asyncify passes
through the function immediately without actually re-executing I/O. The host
does not need to detect or handle this itself; Asyncify manages it internally.
However, the host runtime must support async/coroutine-style execution if it
needs to yield during `fd_read` (e.g. to await data from a Go channel).

## Functions explicitly NOT imported

The following WASI preview1 functions are **absent** from the import section
and do not need to be implemented:

- `args_get`, `args_sizes_get` — zeroperl does not use WASI argv; arguments
  are passed through the `zeroperl_run_file` / `zeroperl_eval` API
- `clock_res_get`
- `fd_advise`, `fd_allocate`, `fd_datasync`, `fd_fdstat_set_rights`,
  `fd_pread`, `fd_pwrite`
- `proc_raise`, `sched_yield`
- `sock_accept`, `sock_recv`, `sock_send`, `sock_shutdown`
