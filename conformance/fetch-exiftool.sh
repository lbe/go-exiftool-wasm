#!/bin/bash
# IMMUTABLE: conformance infrastructure. Installs ExifTool 13.55 into
# conformance/dist for the ncruces run. Do not edit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
rm -rf dist
mkdir dist
curl -fsSL https://github.com/exiftool/exiftool/archive/refs/tags/13.55.tar.gz |
	tar xz -C dist --strip-components=1
test "$(dist/exiftool -ver)" = "13.55"
