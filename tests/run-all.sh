#!/usr/bin/env bash
# Every suite, with the failures counted rather than the first one ending the
# run: a shim that broke because the engine changed is worth knowing about at
# the same time as the one that broke because its spec did.
set -uo pipefail

cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" || exit 1

failed=0
for suite in ./*-test.sh; do
    printf '\n=== %s ===\n' "${suite#./}"
    bash "$suite" || failed=$((failed + 1))
done

printf '\n'
if [ "$failed" = 0 ]; then
    printf 'all suites passed\n'
else
    printf '%s suite(s) failed\n' "$failed"
    exit 1
fi
