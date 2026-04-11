#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== ZAUR Deployment ==="

case "${1:-up}" in
    up)
        echo "Building and starting ZAUR..."
        docker compose build
        docker compose up -d
        echo "Waiting for startup..."
        sleep 5
        if curl -sf http://localhost:9004/api/health > /dev/null; then
            echo "ZAUR is running at http://localhost:9004"
            echo ""
            echo "Next steps:"
            echo "  1. Configure nginx (see nginx.conf.example)"
            echo "  2. Add to client pacman.conf (see pacman.conf.example)"
        else
            echo "Failed to start. Check: docker compose logs"
            exit 1
        fi
        ;;
    down)
        echo "Stopping ZAUR..."
        docker compose down
        ;;
    logs)
        docker compose logs -f
        ;;
    shell)
        docker exec -it zaur bash
        ;;
    status)
        docker compose ps
        curl -s http://localhost:9004/api/health | jq .
        ;;
    rebuild)
        echo "Rebuilding ZAUR..."
        docker compose down
        docker compose build --no-cache
        docker compose up -d
        ;;
    *)
        echo "Usage: $0 [up|down|logs|shell|status|rebuild]"
        exit 1
        ;;
esac
