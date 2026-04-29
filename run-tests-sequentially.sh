#!/bin/bash
set -euo pipefail

# Build the test binary once
echo "Building test binary..."
go test -c -o exiftool.test ./

# Collect test function names via ripgrep
mapfile -t tests < <(rg -o 'func (Test\w+)\b' -r '$1' -n --no-filename ./*.go | sort -u)

total=${#tests[@]}
echo "Running ${total} tests sequentially..."
echo ""

passed=0
failed=0
failures=()

for test in "${tests[@]}"; do
	start=$(date +%s)
	printf '%(%H:%M:%S)T %s Started\n' -1 "$test"

	if ./exiftool.test -test.run "^${test}$" -count=1 -v 2>&1 | sed "s/^/  /"; then
		end=$(date +%s)
		elapsed=$((end - start))
		printf '%(%H:%M:%S)T %s Ended (%d secs)\n' -1 "$test" "$elapsed"
		((passed++))
	else
		end=$(date +%s)
		elapsed=$((end - start))
		printf '%(%H:%M:%S)T %s FAILED (%d secs)\n' -1 "$test" "$elapsed"
		((failed++))
		failures+=("$test")
	fi
	echo ""
done

echo "========================================"
echo "Results: ${passed} passed, ${failed} failed, ${total} total"
if [ ${#failures[@]} -gt 0 ]; then
	echo "Failures:"
	for f in "${failures[@]}"; do
		echo "  - $f"
	done
	exit 1
fi
