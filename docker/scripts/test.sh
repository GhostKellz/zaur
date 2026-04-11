#!/bin/bash
set -e

cd /workspace

echo "=== ZAUR Integration Tests ==="

# Use fresh test directory
export ZAUR_DATA_ROOT="/tmp/zaur-test"
rm -rf "$ZAUR_DATA_ROOT"

# Build first
echo "[1/6] Building..."
zig build

ZAUR="./zig-out/bin/zaur"

# Test init
echo "[2/6] Testing init..."
$ZAUR init

# Test status
echo "[3/6] Testing status..."
$ZAUR status

# Test doctor
echo "[4/6] Testing doctor..."
$ZAUR doctor

# Test source list (should be empty)
echo "[5/6] Testing source list..."
$ZAUR source list

# Test help
echo "[6/6] Testing help..."
$ZAUR help

echo "=== All integration tests passed ==="
