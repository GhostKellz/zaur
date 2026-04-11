# Mirror Setup Guide

ZAUR can act as a caching proxy for official Arch Linux repositories, allowing you to use it as a local mirror.

## How Mirror Mode Works

ZAUR mirrors official Arch repositories (core, extra, multilib) in two modes:

| Mode | Description | Use Case |
|------|-------------|----------|
| `metadata` | Syncs database files only | Low bandwidth, just need package search |
| `ondemand` | Downloads packages when requested | Caching proxy for local network |

## Configuration

Set these environment variables to configure mirror behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAUR_MIRROR_ROOT` | `.zaur/mirror` | Local storage directory |
| `ZAUR_MIRROR_UPSTREAM` | `https://mirrors.kernel.org/archlinux` | Upstream mirror URL |
| `ZAUR_MIRROR_POLICY` | `metadata` | Caching policy: `metadata` or `ondemand` |

## Quick Start

### 1. Sync Repository Databases

First, sync the repository metadata:

```bash
# Smart sync - databases only (recommended)
zaur mirror smart-sync

# Or sync all repos with full mirror mode
zaur mirror sync
```

### 2. Start the Server

```bash
zaur serve
```

### 3. Configure pacman

Add ZAUR as a mirror in `/etc/pacman.conf`. Replace existing `[core]`, `[extra]`, and `[multilib]` sections:

```ini
[core]
SigLevel = Required DatabaseOptional TrustedOnly
Server = http://localhost:9004/mirror/$repo/os/$arch

[extra]
SigLevel = Required DatabaseOptional TrustedOnly
Server = http://localhost:9004/mirror/$repo/os/$arch

[multilib]
SigLevel = Required DatabaseOptional TrustedOnly
Server = http://localhost:9004/mirror/$repo/os/$arch
```

### 4. Test the Configuration

```bash
# Sync package databases
sudo pacman -Sy

# Search for a package
pacman -Ss zlib

# Install a package (will download via ZAUR in ondemand mode)
sudo pacman -S zlib
```

## Mirror Commands

```bash
# Show mirror status
zaur mirror status

# Sync specific repository
zaur mirror sync core

# Smart sync (databases only)
zaur mirror smart-sync

# Verify mirror files
zaur mirror verify

# Check for updates
zaur mirror auto-update
```

## On-Demand Caching

When `ZAUR_MIRROR_POLICY=ondemand`:

1. pacman requests a package from ZAUR
2. If the package is cached locally, ZAUR serves it immediately
3. If not cached, ZAUR downloads it from the upstream mirror, caches it, then serves it
4. Subsequent requests for the same package are served from cache

This mode is useful for:
- Reducing bandwidth for multiple machines on a local network
- Creating a shared package cache for build servers
- Serving as a local mirror when upstream connectivity is limited

## Directory Structure

ZAUR uses the standard Arch mirror path layout:

```
$ZAUR_MIRROR_ROOT/
├── core/os/x86_64/
│   ├── core.db.tar.gz
│   ├── core.files.tar.gz
│   └── *.pkg.tar.zst
├── extra/os/x86_64/
│   ├── extra.db.tar.gz
│   ├── extra.files.tar.gz
│   └── *.pkg.tar.zst
└── multilib/os/x86_64/
    ├── multilib.db.tar.gz
    ├── multilib.files.tar.gz
    └── *.pkg.tar.zst
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/mirror` | Mirror status (upstream, policy, repo stats) |
| POST | `/api/mirror/sync` | Trigger sync (requires auth) |
| GET | `/mirror/$repo/os/x86_64/$file` | Serve cached files |

## Status Output

The `zaur mirror status` command shows:

```
Mirror upstream: https://mirrors.kernel.org/archlinux
Caching policy: ondemand

core: synced (284 packages, 42 cached, 524.3 MB)
extra: synced (14523 packages, 128 cached, 1.2 GB)
multilib: synced (381 packages, 15 cached, 89.4 MB)

Total: 15188 packages available, 185 cached (1.8 GB)
```

## Choosing an Upstream Mirror

For best performance, choose a mirror close to your location. See the [Arch Linux mirrorlist](https://archlinux.org/mirrorlist/) for options.

Example with a regional mirror:

```bash
export ZAUR_MIRROR_UPSTREAM="https://mirrors.kernel.org/archlinux"
```

## Limitations

- Only x86_64 architecture is supported
- Only core, extra, and multilib repositories are mirrored
- Full offline mirror requires manual package pre-caching (not yet implemented)
