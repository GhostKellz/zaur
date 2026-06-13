#!/bin/bash
# Valgrind leak audit over the ZAUR binary lifecycle. Zig's GeneralPurposeAllocator
# already catches leaks in `zig build test`; this exercises the real binary's
# finite command paths under Valgrind to catch leaks the test suite doesn't cover.
set -e

cd /workspace

echo "=== ZAUR Valgrind Memory Audit ==="

if ! command -v valgrind >/dev/null 2>&1; then
    echo "error: valgrind not installed in this image" >&2
    exit 1
fi

export ZAUR_DATA_ROOT="/tmp/zaur-mem-test"
rm -rf "$ZAUR_DATA_ROOT"

# Debug build keeps symbols for readable Valgrind traces. Pin a baseline CPU
# (x86_64_v2) so the binary avoids native AVX-512/newer opcodes that Valgrind
# cannot execute on this host (otherwise it SIGILLs in TLS setup before main).
echo "[1/2] Building (Debug, x86_64_v2 for Valgrind)..."
zig build -Dcpu=x86_64_v2

ZAUR="./zig-out/bin/zaur"
VALGRIND=(valgrind
    --leak-check=full
    --show-leak-kinds=definite,indirect
    --errors-for-leak-kinds=definite
    --error-exitcode=99
    --track-origins=yes
    --quiet)

FAILED=0
run_audit() {
    local name="$1"
    shift
    echo "--- valgrind: $name ---"
    if "${VALGRIND[@]}" "$@" >/dev/null; then
        echo "PASS: $name (no definite leaks)"
    else
        echo "FAIL: $name (Valgrind reported definite leaks/errors)"
        FAILED=1
    fi
}

echo "[2/2] Auditing finite command paths..."
run_audit "init"        "$ZAUR" init
run_audit "status"      "$ZAUR" status
run_audit "doctor"      "$ZAUR" doctor
run_audit "source list" "$ZAUR" source list
run_audit "security list-keys" "$ZAUR" security list-keys
run_audit "help"        "$ZAUR" help

rm -rf "$ZAUR_DATA_ROOT"

echo ""
if [ $FAILED -eq 0 ]; then
    echo "=== Memory audit PASSED (no definite leaks) ==="
    exit 0
else
    echo "=== Memory audit FAILED ==="
    exit 1
fi
