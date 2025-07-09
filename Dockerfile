FROM archlinux:latest

# Install dependencies
RUN pacman -Syu --noconfirm && \
    pacman -S --needed --noconfirm \
        zig \
        git \
        base-devel \
        sqlite \
        pacman-contrib \
        gnupg \
        curl \
        ca-certificates && \
    pacman -Scc --noconfirm

# Create zaur user
RUN useradd -r -s /bin/false -d /var/lib/zaur -c "ZAUR service user" zaur

# Create directories with proper permissions
RUN mkdir -p /var/lib/zaur/{packages,build,GhostCTL/packages} && \
    chown -R zaur:zaur /var/lib/zaur

# Copy source code
COPY . /app
WORKDIR /app

# Build ZAUR
RUN zig build -Doptimize=ReleaseSafe

# Install binary
RUN install -Dm755 zig-out/bin/zaur /usr/bin/zaur && \
    install -Dm644 README.md /usr/share/doc/zaur/README.md && \
    install -Dm644 LICENSE /usr/share/licenses/zaur/LICENSE

# Create entrypoint script
COPY <<EOF /entrypoint.sh
#!/bin/bash
set -e

echo "🚀 Starting ZAUR container..."

# Switch to zaur user for initialization
sudo -u zaur bash -c '
cd /var/lib/zaur

# Initialize ZAUR if not already done
if [ ! -f /var/lib/zaur/.initialized ]; then
    echo "🔧 Initializing ZAUR..."
    zaur init
    touch /var/lib/zaur/.initialized
    echo "✓ ZAUR initialized"
fi

# Generate GPG key if not exists and ZAUR_GPG_EMAIL is set
if [ ! -z "${ZAUR_GPG_EMAIL}" ] && [ ! -f /var/lib/zaur/.gpg_initialized ]; then
    echo "🔑 Setting up GPG signing..."
    zaur gpg-init "${ZAUR_GPG_NAME:-ZAUR Docker}" "${ZAUR_GPG_EMAIL}"
    touch /var/lib/zaur/.gpg_initialized
    echo "✓ GPG key generated"
fi

# Create empty repository if no packages exist
if [ ! -f /var/lib/zaur/GhostCTL/packages/zaur.db.tar.zst ]; then
    echo "📦 Creating empty repository database..."
    mkdir -p /var/lib/zaur/GhostCTL/packages
    repo-add /var/lib/zaur/GhostCTL/packages/zaur.db.tar.zst
    echo "✓ Empty repository created"
fi
'

echo "🌐 Starting ZAUR HTTP server..."
echo "📦 Repository: /var/lib/zaur/GhostCTL/packages"
echo "🔗 Server will be available on: \${ZAUR_BIND:-0.0.0.0}:\${ZAUR_PORT:-8080}"

# Start ZAUR server as zaur user
exec sudo -u zaur zaur serve --bind "\${ZAUR_BIND:-0.0.0.0}" --port "\${ZAUR_PORT:-8080}"
EOF

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# Install sudo for user switching in entrypoint
RUN pacman -S --needed --noconfirm sudo && \
    echo "zaur ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Set up volume directories
VOLUME ["/var/lib/zaur"]

# Expose default port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${ZAUR_PORT:-8080}/api/packages || exit 1

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
