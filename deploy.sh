#!/bin/bash
set -e

echo "🚀 ZAUR Docker Deployment Script"
echo "================================"

# Configuration
ZAUR_DOMAIN="${ZAUR_DOMAIN:-localhost}"
ZAUR_PORT="${ZAUR_PORT:-8080}"
ZAUR_EMAIL="${ZAUR_EMAIL:-aur@example.com}"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Create data directory
echo "📁 Creating data directory..."
mkdir -p ./zaur-data
chmod 755 ./zaur-data

# Set environment variables
export ZAUR_GPG_EMAIL="$ZAUR_EMAIL"
export ZAUR_GPG_NAME="ZAUR Docker Repository"

echo "🔧 Configuration:"
echo "   Domain: $ZAUR_DOMAIN"
echo "   Port: $ZAUR_PORT"
echo "   GPG Email: $ZAUR_EMAIL"
echo ""

# Build and start containers
echo "🏗️  Building ZAUR container..."
docker-compose build

echo "🚀 Starting ZAUR..."
docker-compose up -d

# Wait for service to be ready
echo "⏳ Waiting for ZAUR to start..."
sleep 10

# Check if service is running
if docker-compose ps | grep -q "Up"; then
    echo "✅ ZAUR is running successfully!"
    echo ""
    echo "🌐 Access your ZAUR repository at:"
    echo "   Local: http://localhost:$ZAUR_PORT"
    echo "   LAN: http://$(hostname -I | awk '{print $1}'):$ZAUR_PORT"
    echo ""
    echo "📦 Add to your /etc/pacman.conf:"
    echo "[zaur]"
    echo "SigLevel = Optional TrustAll"
    echo "Server = http://$(hostname -I | awk '{print $1}'):$ZAUR_PORT/"
    echo ""
    echo "🔧 Useful commands:"
    echo "   View logs: docker-compose logs -f zaur"
    echo "   Stop: docker-compose down"
    echo "   Restart: docker-compose restart"
    echo "   Add package: docker-compose exec zaur zaur add aur/package-name"
    echo "   Build packages: docker-compose exec zaur zaur build all"
    echo "   Status: docker-compose exec zaur zaur status"
else
    echo "❌ Failed to start ZAUR. Check logs with: docker-compose logs zaur"
    exit 1
fi
