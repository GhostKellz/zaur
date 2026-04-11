#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== ZAUR Docker Test Environment ==="

# Build with host networking to avoid DNS issues
echo "Building test image with host networking..."
docker build --network=host -t zaur-test -f Dockerfile.test .

# Run tests
case "${1:-basic}" in
    basic)
        echo "Running basic tests..."
        docker run --rm --network=host \
            -v "$(pwd)/..:/workspace:rw" \
            -v "/opt/zig-0.16.0-dev:/opt/zig:ro" \
            -e "PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            -w /workspace \
            zaur-test bash /workspace/docker/scripts/test.sh
        ;;
    full)
        echo "Running full integration tests..."
        docker run --rm --network=host \
            -v "$(pwd)/..:/workspace:rw" \
            -v "/opt/zig-0.16.0-dev:/opt/zig:ro" \
            -e "PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            -w /workspace \
            zaur-test bash /workspace/docker/scripts/test-full.sh
        ;;
    build)
        echo "Running build only..."
        docker run --rm --network=host \
            -v "$(pwd)/..:/workspace:rw" \
            -v "/opt/zig-0.16.0-dev:/opt/zig:ro" \
            -e "PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            -w /workspace \
            zaur-test bash /workspace/docker/scripts/build.sh
        ;;
    shell)
        echo "Starting interactive shell..."
        docker run --rm -it --network=host \
            -v "$(pwd)/..:/workspace:rw" \
            -v "/opt/zig-0.16.0-dev:/opt/zig:ro" \
            -e "PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            -w /workspace \
            zaur-test
        ;;
    *)
        echo "Usage: $0 [basic|full|build|shell]"
        echo "  basic  - Run basic integration tests (default)"
        echo "  full   - Run full integration tests with network"
        echo "  build  - Build and run unit tests only"
        echo "  shell  - Start interactive shell in container"
        exit 1
        ;;
esac

echo "=== Done ==="
