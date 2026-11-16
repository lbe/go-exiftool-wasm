# Testing

Build tags add files to the default set. Untagged tests always compile, and `-tags=integration,e2e`
adds the integration and e2e files.

## Tags

| Tag               | Command                               | What runs                             |
| ----------------- | ------------------------------------- | ------------------------------------- |
| _(none)_          | `go test ./...`                       | Unit tests only, with no Perl or WASM |
| `integration`     | `go test -tags=integration ./...`     | Unit and integration tests            |
| `integration,e2e` | `go test -tags=integration,e2e ./...` | Unit, integration and e2e tests       |

## File naming

The file name suffix names the test kind and must match the build tag.

| Kind        | File name                       | Build tag                |
| ----------- | ------------------------------- | ------------------------ |
| Unit        | `<subject>_test.go`             | _(none)_                 |
| Integration | `<subject>_integration_test.go` | `//go:build integration` |
| E2e         | `<subject>_e2e_test.go`         | `//go:build e2e`         |

`<subject>` names the source file or behavior under test. For example, `cmd_integration_test.go`
tests `cmd.go` by running the guest. `cachefs_metrics_test.go` has no build tag and no `Test`
functions. It holds shared test fixtures.

Files under `conformance/` follow their own rules; see Conformance suite.

## Local commands

```bash
go test ./... -count=1
go test -tags=integration,e2e ./... -count=1
go test -tags=integration,e2e -race ./... -count=1
```

The Makefile has matching targets: `make test`, `make test-all`, `make test-race` and `make lint`.

The benchmarks need the integration tag and take a long time:

```bash
go test -tags=integration -bench=. -run=^$ -timeout 30m
```

## CI

GitHub Actions runs the full suite under `-race` with coverage on every push and pull request to
`main`:

```bash
go test -tags=integration,e2e -race ./... -count=1 \
  -coverprofile=coverage.out \
  -coverpkg=github.com/lbe/go-exiftool-wasm,github.com/lbe/go-exiftool-wasm/internal/testutil
```

Coverage leaves out `internal/zeroperl`, the generated wasm2go output. CI uploads the report to
[Codecov](https://codecov.io/gh/lbe/go-exiftool-wasm).

## Conformance suite

`conformance/` is a separate Go module that checks this package against
github.com/ncruces/go-exiftool v0.4.2. Its tests use only the public API. The same tests run against
both implementations:

```bash
make conformance          # this package
make conformance-ncruces  # ncruces/go-exiftool with ExifTool 13.55 from conformance/fetch-exiftool.sh
```

A test that fails against ncruces is wrong. A test that fails only against this package is a
deviation to fix. A test that skips in the default run is a divergence the owner has approved.

Every file under `conformance/` is immutable. `TestConformanceFilesUnchanged` in the root package
fails if any of them changes. A change needs the owner's approval, a regenerated
`conformance/MANIFEST.sha256` and a new `conformanceManifestSHA256` in `conformance_guard_test.go`.

## Where to add tests

- Put pure Go logic, with no guest and no subprocess, in an untagged `<subject>_test.go`. Use
  table-driven tests when inputs repeat.
- Put tests that run the guest in `<subject>_integration_test.go` with `//go:build integration`.
  That covers `Command`, WASI, mounts, Server internals and lifecycle, and tests that run the `go`
  toolchain as a subprocess.
- Put tests of public Server and stay_open behavior in `<subject>_e2e_test.go` with
  `//go:build e2e`.

[`internal/testutil`](internal/testutil/) has the shared helpers `Root` and `SampleJPEG`.
[`helpers_integration_test.go`](helpers_integration_test.go) has the integration helpers, and
[`eval_integration_test.go`](eval_integration_test.go) runs arbitrary Perl in the guest.

Do not add meta-tests that check whether strings exist in other test sources. Test behavior instead.
