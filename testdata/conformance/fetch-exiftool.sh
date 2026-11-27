#!/bin/bash
# IMMUTABLE: conformance infrastructure. Makes ExifTool available for the
# ncruces run, which, like github.com/ncruces/go-exiftool, runs the exiftool
# found on $PATH. Installs ExifTool 13.55 into testdata/conformance/dist only
# when no exiftool is on $PATH (testdata/conformance/dist included). Do not edit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if PATH="$PWD/dist:$PATH" command -v exiftool >/dev/null; then
	exit 0
fi
rm -rf dist
mkdir dist
curl -fsSL https://github.com/exiftool/exiftool/archive/refs/tags/13.55.tar.gz |
	tar xz -C dist --strip-components=1
test "$(dist/exiftool -ver)" = "13.55"
