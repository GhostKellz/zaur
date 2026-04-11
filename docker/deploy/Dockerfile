# Build stage
FROM archlinux:latest AS builder

# Install latest Zig 0.16-dev (required for this codebase)
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm curl xz jq && \
    ZIG_URL=$(curl -s https://ziglang.org/download/index.json | jq -r '.master."x86_64-linux".tarball') && \
    curl -L "$ZIG_URL" | tar -xJ && \
    mv zig-x86_64-linux-* /opt/zig && \
    pacman -Scc --noconfirm

ENV PATH="/opt/zig:$PATH"

WORKDIR /build
COPY . .

RUN zig build -Doptimize=ReleaseSafe

# Runtime stage
FROM archlinux:latest

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    base-devel \
    git \
    curl \
    pacman-contrib \
    && pacman -Scc --noconfirm && \
    useradd -m -s /bin/bash zaur && \
    mkdir -p /var/lib/zaur && \
    chown -R zaur:zaur /var/lib/zaur

COPY --from=builder /build/zig-out/bin/zaur /usr/local/bin/zaur

ENV ZAUR_DATA_ROOT=/var/lib/zaur
ENV ZAUR_BIND=0.0.0.0
ENV ZAUR_PORT=9004

WORKDIR /var/lib/zaur
USER zaur

EXPOSE 9004

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:9004/api/health || exit 1

CMD ["sh", "-c", "zaur init 2>/dev/null; zaur serve"]
