#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== ZAUR Docker Test Environment ==="

# Host path to the Zig dev toolchain. Mounted read-only into the container at
# /opt/zig and placed first on PATH. Override with ZIG_HOST_DIR if your install
# lives elsewhere.
ZIG_HOST_DIR="${ZIG_HOST_DIR:-/opt/zig-dev}"
IMAGE="zaur-test"

if [ ! -x "$ZIG_HOST_DIR/zig" ]; then
    echo "error: no zig binary at $ZIG_HOST_DIR/zig" >&2
    echo "set ZIG_HOST_DIR to your Zig dev install (e.g. ZIG_HOST_DIR=/opt/zig-dev)" >&2
    exit 1
fi

echo "Building test image with host networking..."
docker build --network=host -t "$IMAGE" -f Dockerfile .

# run_in_container <script-path> [extra docker args...]
run_in_container() {
    local script="$1"
    shift
    docker run --rm "$@" --network=host \
        -v "$(pwd)/..:/workspace:rw" \
        -v "$ZIG_HOST_DIR:/opt/zig:ro" \
        -e "PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        -w /workspace \
        "$IMAGE" ${script:+bash "$script"}
}

case "${1:-basic}" in
    basic)
        echo "Running basic tests..."
        run_in_container /workspace/docker/scripts/test.sh
        ;;
    full)
        echo "Running full integration tests..."
        run_in_container /workspace/docker/scripts/test-full.sh
        ;;
    build)
        echo "Running build and unit tests..."
        run_in_container /workspace/docker/scripts/build.sh
        ;;
    memory)
        echo "Running Valgrind memory audit..."
        run_in_container /workspace/docker/scripts/test-memory.sh
        ;;
    security)
        echo "Running security feature tests..."
        run_in_container /workspace/docker/scripts/test-security.sh
        ;;
    all)
        echo "Running build, full, security, and memory suites..."
        run_in_container /workspace/docker/scripts/build.sh
        run_in_container /workspace/docker/scripts/test-full.sh
        run_in_container /workspace/docker/scripts/test-security.sh
        run_in_container /workspace/docker/scripts/test-memory.sh
        ;;
    shell)
        echo "Starting interactive shell..."
        run_in_container "" -it
        ;;
    *)
        echo "Usage: $0 [basic|full|build|memory|security|all|shell]"
        echo "  basic    - Run basic CLI smoke tests (default)"
        echo "  full     - Run full HTTP/API integration tests"
        echo "  build    - Build and run zig unit tests only"
        echo "  memory   - Valgrind leak audit over the binary lifecycle"
        echo "  security - CLI + API coverage for supply-chain security features"
        echo "  all      - build + full + security + memory"
        echo "  shell    - Start interactive shell in container"
        exit 1
        ;;
esac

echo "=== Done ==="
