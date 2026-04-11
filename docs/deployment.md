# ZAUR Deployment Guide

## Docker Compose Deployment

### Prerequisites

- Docker and Docker Compose
- Nginx on host (for reverse proxy)
- Domain names configured (DNS)

### Quick Start

```bash
cd docker/deploy

# Build (requires host networking for package downloads)
docker build --network=host -t zaur:latest -f Dockerfile ../..

# Start
docker compose up -d

# Check logs
docker compose logs -f

# Stop
docker compose down
```

### Directory Structure

```
docker/deploy/
├── docker-compose.yml      # Production compose file
├── Dockerfile              # Multi-stage build
├── nginx.conf.example      # Nginx reverse proxy config
└── pacman.conf.example     # Client pacman configuration
```

## Nginx Setup

1. Copy the nginx config:
```bash
sudo cp docker/deploy/nginx.conf.example /etc/nginx/sites-available/zaur
sudo ln -s /etc/nginx/sites-available/zaur /etc/nginx/sites-enabled/
```

2. Get SSL certificates:
```bash
sudo certbot certonly --nginx -d aur.cktech.org
sudo certbot certonly --nginx -d pkg.cktech.org
sudo certbot certonly --nginx -d mirror.cktech.org
```

3. Reload nginx:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

## Domain Routing

| Domain | ZAUR Path | Purpose |
|--------|-----------|---------|
| aur.cktech.org | /aur/ | AUR-built packages |
| pkg.cktech.org | /custom/ | Custom packages |
| mirror.cktech.org | /mirror/ | Arch repo metadata (databases only) |

## Client Configuration

Add to `/etc/pacman.conf` on client machines:

```ini
[aur]
SigLevel = Optional TrustAll
Server = https://aur.cktech.org/

[custom]
SigLevel = Optional TrustAll
Server = https://pkg.cktech.org/
```

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
