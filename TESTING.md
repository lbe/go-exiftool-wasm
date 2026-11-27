# Testing

Build tags add files to the default set. Untagged tests always compile, and `-tags=integration,e2e`
adds the integration and e2e files.

## Tags

| Tag               | Command                               | What runs                                                                       |
| ----------------- | ------------------------------------- | ------------------------------------------------------------------------------- |
| _(none)_          | `go test ./...`                       | Unit tests only, with no Perl or WASM                                           |
| `integration`     | `go test -tags=integration ./...`     | Unit and integration tests, and the conformance suite against this package      |
| `integration,e2e` | `go test -tags=integration,e2e ./...` | Unit, integration and e2e tests, and the conformance suite against this package |
| `ncruces`         | `go test -tags=ncruces .`             | Unit tests, and the conformance suite against github.com/ncruces/go-exiftool    |

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

The conformance suite files, `conformance_*_test.go`, follow their own rules; see Conformance suite.

## Local commands

```bash
go test ./... -count=1
go test -tags=integration,e2e ./... -count=1
go test -tags=integration,e2e -race ./... -count=1
```

The Makefile has matching targets: `make test`, `make test-all`, `make test-race` and `make lint`.
`make conformance-ncruces` runs the conformance suite against github.com/ncruces/go-exiftool.

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
[Codecov](https://codecov.io/gh/lbe/go-exiftool-wasm). CI then runs `make conformance-ncruces`.

## Conformance suite

The conformance suite checks this package against github.com/ncruces/go-exiftool v0.4.2. It is the
`conformance_*_test.go` files in package `exiftool_test`, and it uses only the public API. The same
tests run against both implementations:

```bash
make test-all             # this package (also make test-race)
make conformance-ncruces  # github.com/ncruces/go-exiftool and the exiftool on $PATH
```

`conformance_target_inprocess_test.go` (`integration`, not `ncruces`) and
`conformance_target_ncruces_test.go` (`ncruces`) select the implementation under test. ncruces runs
the `exiftool` found on `$PATH`. When there is none, `testdata/conformance/fetch-exiftool.sh`
installs ExifTool 13.55 into `testdata/conformance/dist`.

A test that fails against ncruces is wrong. A test that fails only against this package is a
deviation to fix. A test that skips in the default run is a divergence the owner has approved.

The suite is immutable. `testdata/conformance/MANIFEST.sha256` lists its files: the
`conformance_*_test.go` files other than `conformance_guard_test.go`, everything under
`testdata/conformance/` other than `dist`, and the shared `testdata/sample*` files it reads.
`TestConformanceFilesUnchanged` fails if a listed file changes or goes missing, or an unlisted
conformance file appears. A change needs the owner's approval, a regenerated manifest and a new
`conformanceManifestSHA256` in `conformance_guard_test.go`.

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
