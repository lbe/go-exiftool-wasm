# Testing

Build tags are **additive**: untagged tests always compile; `-tags=integration,e2e` adds integration
and e2e files to that default set.

## Tags

| Tag               | Command                               | What runs                             |
| ----------------- | ------------------------------------- | ------------------------------------- |
| _(none)_          | `go test ./...`                       | Unit tests only (fast; no Perl/WASM)  |
| `integration`     | `go test -tags=integration ./...`     | Unit + integration                    |
| `integration,e2e` | `go test -tags=integration,e2e ./...` | Unit + integration + e2e (full suite) |

## File naming

The file name suffix states the test kind and must match the build tag:

| Kind        | File name                       | Build tag                |
| ----------- | ------------------------------- | ------------------------ |
| Unit        | `<subject>_test.go`             | _(none)_                 |
| Integration | `<subject>_integration_test.go` | `//go:build integration` |
| E2e         | `<subject>_e2e_test.go`         | `//go:build e2e`         |

`<subject>` names the source file or behavior under test (for example `cmd_integration_test.go`
covers `cmd.go` through the guest). Untagged files without `Test` functions
(`cachefs_metrics_test.go`) hold shared test fixtures.

## Local commands

```bash
go test ./... -count=1
go test -tags=integration,e2e ./... -count=1
go test -tags=integration,e2e -race ./... -count=1
```

Or via Makefile: `make test`, `make test-all`, `make test-race`, `make lint`.

Benchmarks (integration tag; long-running):

```bash
go test -tags=integration -bench=. -run=^$ -timeout 30m
```

## CI

GitHub Actions runs the full suite under `-race` with coverage on every push/PR to `main`:

```bash
go test -tags=integration,e2e -race ./... -count=1 \
  -coverprofile=coverage.out \
  -coverpkg=github.com/lbe/go-exiftool-wasm,github.com/lbe/go-exiftool-wasm/internal/testutil
```

Coverage excludes `internal/zeroperl` (generated wasm2go output). Upload goes to
[Codecov](https://codecov.io/gh/lbe/go-exiftool-wasm).

## Where to add tests

- **Pure Go logic** (no guest, no subprocess): untagged `<subject>_test.go` files; use table-driven
  tests when inputs repeat.
- **Guest execution** (Command, WASI, mounts, Server internals and lifecycle) or `go` toolchain
  subprocesses: `<subject>_integration_test.go` with `//go:build integration`.
- **Public Server / stay_open behavior**: `<subject>_e2e_test.go` with `//go:build e2e`.

Shared helpers: [`internal/testutil`](internal/testutil/) (`Root`, `SampleJPEG`). Integration
helpers: [`helpers_integration_test.go`](helpers_integration_test.go); Perl eval:
[`eval_integration_test.go`](eval_integration_test.go).

Do not add meta-tests that assert other test source strings exist. Prefer behavioral checks.
