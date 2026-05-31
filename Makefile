SHELL := /bin/bash

# Default package for tests. Override: make test-race PKG=./...
PKG ?= ./...

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make test          - Unit tests only (fast; no Perl/WASM), package $(PKG)"
	@echo "  make test-all      - Full suite: unit + integration + e2e (./...)"
	@echo "  make test-race     - Same as CI: -tags=integration,e2e -race on $(PKG)"
	@echo "  make cover         - Coverage report (coverage.html)"
	@echo "  make lint          - golangci-lint (includes go vet)"
	@echo "  make format        - gofmt, goimports, Prettier (see .prettierignore)"
	@echo "  make clean         - Remove coverage artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  PKG=<path>         - Package for test / test-race (default: $(PKG))"
	@echo "  ARGS='...'         - Extra flags, e.g. ARGS=\"-count=1 -v\""
	@echo ""
	@echo "Tools: go, golangci-lint, goimports (format), npx+prettier (format)"
	@echo ""
	@echo "Build tags are additive: -tags=integration,e2e adds integration and e2e tests"
	@echo "to the default unit set. See TESTING.md."

.PHONY: test
test:
	# Unit tests only; pass ARGS="-count=1 -v" as needed
	go test $(PKG) $(ARGS)

.PHONY: test-all
test-all:
	# Full suite without race detector
	go test -tags=integration,e2e ./... $(ARGS)

.PHONY: test-race
test-race:
	# Matches GitHub Actions: full suite under -race
	go test -tags=integration,e2e $(PKG) -race $(ARGS)

.PHONY: lint
lint:
	golangci-lint run --max-same-issues 0 ./...

.PHONY: cover
cover:
	go test -tags=integration,e2e ./... -coverprofile=coverage.out -count=1 \
		-coverpkg=github.com/lbe/go-exiftool-wasm,github.com/lbe/go-exiftool-wasm/internal/testutil
	go tool cover -html=coverage.out -o coverage.html
	go tool cover -func=coverage.out | tail -n 1
	@echo "Coverage report: coverage.html"

.PHONY: clean
clean:
	rm -f coverage.out coverage.html
	@echo "Cleaned build artifacts"

.PHONY: format fmt
format fmt:
	@git ls-files '*.go' | xargs gofmt -w
	@git ls-files '*.go' | xargs goimports -w
	npx --yes prettier --write .
