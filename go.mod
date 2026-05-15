module github.com/lbe/go-exiftool-wasm

go 1.26.3

require (
	github.com/lbe/cfsread v0.1.0
	github.com/lbe/wasi-wasm2go v0.0.0-00010101000000-000000000000
	github.com/pierrec/lz4/v4 v4.1.26
)

replace github.com/lbe/wasi-wasm2go => ./wasi-wasm2go

require golang.org/x/sync v0.20.0 // indirect
