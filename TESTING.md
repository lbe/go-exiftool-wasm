# Testing

Build tags are **additive**: untagged tests always compile; `-tags=integration,e2e` adds integration and e2e files to that default set.

## Tags

| Tag | Command | What runs |
|-----|---------|-----------|
| *(none)* | `go test ./...` | Unit tests only (fast; no Perl/WASM) |
| `integration` | `go test -tags=integration ./...` | Unit + integration |
| `integration,e2e` | `go test -tags=integration,e2e ./...` | Unit + integration + e2e (full suite) |

Integration-tagged files: `cmd_test.go`, `wasi_test.go`, `mount_test.go`, `write_test.go`, `recurse_test.go`, `bench_test.go`, `cachefs_integration_test.go`, `integration_eval.go`.

E2e-tagged files: `server_test.go`, `exiftool_test.go`.

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

Coverage excludes `internal/zeroperl` (generated wasm2go output). Upload goes to [Codecov](https://codecov.io/gh/lbe/go-exiftool-wasm).

## Where to add tests

- **Pure Go logic** (no guest): untagged `_test.go` files; use table-driven tests when inputs repeat.
- **Command / WASI / mounts**: `//go:build integration`.
- **Server / stay_open**: `//go:build e2e`.

Shared helpers: [`internal/testutil`](internal/testutil/) (`Root`, `SampleJPEG`). Perl eval: [`integration_eval.go`](integration_eval.go) (`integration` tag).

Do not add meta-tests that assert other test source strings exist. Prefer behavioral checks.
