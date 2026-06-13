# ZAUR Deployment Guide

## Docker Compose Deployment

### Prerequisites

- Docker and Docker Compose
- Nginx on host (for reverse proxy)
- Domain names configured (DNS)

### Quick Start

```bash
cd docker/prod

# Build (requires host networking for package downloads)
docker build --network=host -t zaur:latest -f Dockerfile ../..

# Start
docker compose up -d

# Check logs
docker compose logs -f

# Stop
docker compose down
```

The `deploy.sh` helper wraps these steps: `./deploy.sh up|down|logs|shell|status|rebuild`.

### Directory Structure

```
docker/
├── Dockerfile          # Local/test image (Arch + Zig dev, valgrind, gnupg)
├── compose.yml         # Local/test compose (host networking)
├── run-tests.sh        # Test runner: basic|full|build|memory|security|all|shell
├── scripts/            # build.sh, test.sh, test-full.sh, test-memory.sh, test-security.sh
└── prod/
    ├── Dockerfile      # Multi-stage release build
    ├── compose.yml     # Production compose file
    ├── deploy.sh       # up/down/logs/shell/status/rebuild helper
    ├── zaur.conf       # Nginx reverse proxy config
    └── pacman.conf     # Client pacman configuration
```

### Local Testing

```bash
cd docker

# Smoke test (CLI lifecycle)
./run-tests.sh basic

# Full HTTP/API integration suite
./run-tests.sh full

# Security feature coverage (scanner, pinning, key trust, API routes)
./run-tests.sh security

# Valgrind leak audit
./run-tests.sh memory

# Everything
./run-tests.sh all
```

The runner mounts the host Zig dev toolchain from `/opt/zig-dev` (override with
`ZIG_HOST_DIR=/path/to/zig`).

## Nginx Setup

1. Copy the nginx config into `conf.d`:
```bash
sudo cp docker/prod/zaur.conf /etc/nginx/conf.d/zaur.conf
```

2. Provide the shared `*.cktechnology.io` certificate at the paths referenced in
   `zaur.conf`:
```bash
/etc/nginx/certs/cktechnology/fullchain.pem
/etc/nginx/certs/cktechnology/privkey.pem
```

3. Reload nginx:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

## Domain Routing

Each subdomain root maps directly to a ZAUR repo (clients use the bare domain).

| Domain | ZAUR Path | Purpose |
|--------|-----------|---------|
| aur.cktechnology.io | /aur/ | AUR-built packages |
| pkg.cktechnology.io | /custom/ | Custom packages |
| mirror.cktechnology.io | /mirror/ | Arch repo metadata (databases only) |

## Client Configuration

Add to `/etc/pacman.conf` on client machines:

```ini
[aur]
SigLevel = Optional TrustAll
Server = https://aur.cktechnology.io

[custom]
SigLevel = Optional TrustAll
Server = https://pkg.cktechnology.io
```

With repo-database signing enabled (a GPG key configured on the server), clients
can use `SigLevel = Required` after importing the signing key with
`pacman-key --recv-keys <KEY_ID>` and `pacman-key --lsign-key <KEY_ID>`.

## Managing Packages

```bash
# Enter the container
docker exec -it zaur bash

# Add AUR package
zaur source add aur/yay

# Build all packages
zaur build all

# Publish repository
zaur repo publish

# Sync Arch mirror metadata (databases only, not full packages)
zaur mirror sync
```

**Note:** Mirror sync downloads repository databases only. ZAUR does not currently cache or serve individual Arch packages - use official mirrors for package downloads.

## Volumes

The `zaur_data` volume persists:
- `/var/lib/zaur/repos/` - Package repositories
- `/var/lib/zaur/sources/` - Source checkouts
- `/var/lib/zaur/build/` - Build workspaces
- `/var/lib/zaur/mirror/` - Cached mirror packages
- `/var/lib/zaur/zaur.db` - Database

## Health Check

```bash
curl http://localhost:9004/api/health
# {"status":"ok","version":"0.1.2"}
```

## Troubleshooting

### Container won't start
```bash
docker compose logs zaur
```

### Build failures
```bash
docker exec -it zaur zaur build logs <package>
```

### Reset everything
```bash
docker compose down -v  # Removes volumes too
docker compose up -d
```
