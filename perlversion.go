//go:generate go run github.com/lbe/cfsread/cmd/cfsread-lz4 ./embed/perl-wasi-prefix

package exiftool

// perl5Lib is the Perl library directory segment used to construct PERL5LIB
// paths and locate the embedded standard library under
// embed/perl-wasi-prefix/lib/<perl5Lib>/.
//
// When switching to a different Perl build:
//  1. Update this constant.
//  2. Replace the embed/perl-wasi-prefix/ tree.
//  3. Regenerate internal/zeroperl/zeroperl.go via wasm2go.
//  4. Run go generate ./... to recompress.
const perl5Lib = "5.16.3"
