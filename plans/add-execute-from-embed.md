---
name: External ExifTool Entrypoint
overview: Replace hard-coded Perl include paths with `Perl5Lib` and make all execution paths prefer an external `exiftool.min.pl` when present, falling back to embedded script.
todos:
  - id: wire-perl5lib-constant
    content: Replace hard-coded PERL5LIB strings with helper based on Perl5Lib constant.
    status: pending
  - id: external-script-fallback
    content: Implement root-FS script resolver and fallback to embedded bytes.
    status: pending
  - id: apply-all-apis
    content: Use script resolver in both single-shot evalModule and Server start path.
    status: pending
  - id: docs-sync
    content: Update README and ARCHITECTURE to remove hard-coded-version guidance and describe fallback behavior.
    status: pending
  - id: tests-coverage
    content: Add or update tests covering external script preference and embedded fallback paths.
    status: pending
  - id: verification-gate
    content: Verify all existing tests pass unchanged and treat failures as blockers.
    status: pending
isProject: false
---

# Plan: External ExifTool Script + Versioned PERL5LIB

## Scope
Implement two runtime behavior changes across all APIs (`Command`, `Run`, `Server`):
- Replace hard-coded `PERL5LIB` version segments with the constant from [`/Users/whgi/src/go-exiftool-wasm/perlversion.go`](/Users/whgi/src/go-exiftool-wasm/perlversion.go).
- Prefer loading `exiftool.min.pl` from the mounted guest filesystem when present; otherwise use embedded script bytes.

## Current state to change
- Hard-coded `PERL5LIB` appears in:
  - [`/Users/whgi/src/go-exiftool-wasm/exiftool.go`](/Users/whgi/src/go-exiftool-wasm/exiftool.go)
  - [`/Users/whgi/src/go-exiftool-wasm/server.go`](/Users/whgi/src/go-exiftool-wasm/server.go)
- Script source is always embedded (`cachedWrappedExiftoolScript`) in both single-shot and server paths.

## Implementation steps
1. **Centralize `PERL5LIB` construction from `Perl5Lib`**
   - In [`/Users/whgi/src/go-exiftool-wasm/exiftool.go`](/Users/whgi/src/go-exiftool-wasm/exiftool.go), add a helper that builds:
     - `/lib/<Perl5Lib>`
     - `/lib/<Perl5Lib>/wasm32-wasi`
   - Replace all module config `WithEnv("PERL5LIB", ...)` hard-coded strings with this helper (including server startup path in [`/Users/whgi/src/go-exiftool-wasm/server.go`](/Users/whgi/src/go-exiftool-wasm/server.go)).

2. **Add runtime script resolver with fallback**
   - In [`/Users/whgi/src/go-exiftool-wasm/exiftool.go`](/Users/whgi/src/go-exiftool-wasm/exiftool.go), add a function that attempts to read `exiftool.min.pl` from the guest root filesystem used for that invocation.
   - Wrap resolved script with existing `scriptPreamble`.
   - Fallback order:
     - external `exiftool.min.pl` from mounted FS (if readable)
     - embedded `exiftoolScript` (current behavior)

3. **Use resolver in all API paths**
   - Update single-shot flow (`evalModule`) to resolve script using the provided runtime root FS before packing guest memory.
   - Update server startup path (`start`) similarly, so long-lived `-stay_open` uses external script when present.
   - Preserve current argument packing and eval flow; only script source changes.

4. **Document new behavior**
   - Update references that currently require manual hard-coded `PERL5LIB` edits in:
     - [`/Users/whgi/src/go-exiftool-wasm/README.md`](/Users/whgi/src/go-exiftool-wasm/README.md)
     - [`/Users/whgi/src/go-exiftool-wasm/ARCHITECTURE.md`](/Users/whgi/src/go-exiftool-wasm/ARCHITECTURE.md)
   - Clarify that `Perl5Lib` controls path versioning and external `exiftool.min.pl` is preferred when mounted.

5. **Test strategy (without changing existing tests)**
   - Add/adjust targeted tests in:
     - [`/Users/whgi/src/go-exiftool-wasm/exiftool_test.go`](/Users/whgi/src/go-exiftool-wasm/exiftool_test.go)
     - [`/Users/whgi/src/go-exiftool-wasm/server_test.go`](/Users/whgi/src/go-exiftool-wasm/server_test.go)
   - Verify both script-source branches:
     - external script present (loaded from FS)
     - external script absent (embedded fallback)
   - Constraint: existing tests must remain unchanged; only additive tests are allowed if new coverage is needed.

6. **Verification gate (required for completion)**
   - Confirm no edits were made to pre-existing test logic other than optional additive test cases.
   - Run unit tests only and require pass:
     - `go test ./...`
   - Performance expectation: unit test run should complete in under 1 minute.
   - Do not add an explicit timeout flag; use Go test defaults.
   - Treat any failure in existing tests as a blocker; do not consider implementation complete until resolved.

## Assumptions
- `Perl5Lib` in [`/Users/whgi/src/go-exiftool-wasm/perlversion.go`](/Users/whgi/src/go-exiftool-wasm/perlversion.go) is authoritative (`"5.16.3"`).
- External script path target is `exiftool.min.pl` at guest root (`/exiftool.min.pl`) as seen by wazero mounts.

## Acceptance criteria
- All existing tests pass without requiring modifications to their assertions or behavior.
- New behavior is validated for both script-source branches (external preferred, embedded fallback).
- `PERL5LIB` path versioning comes exclusively from `Perl5Lib` (no hard-coded version literals in runtime config paths).
