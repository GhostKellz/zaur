#!/bin/bash
set -e

cd /workspace

echo "=== Building ZAUR ==="
zig build

echo "=== Running tests ==="
zig build test

echo "=== Build complete ==="
ls -la zig-out/bin/
