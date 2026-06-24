# Configuration

ZAUR is configured entirely through environment variables. Every variable has a
sensible default, so an unconfigured `zaur init` works out of the box.

## Core Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAUR_DATA_ROOT` | `.zaur` | Root directory for all ZAUR data |
| `ZAUR_REPO_ROOT` | `$ZAUR_DATA_ROOT/repos` | Directory for repository files |
| `ZAUR_MIRROR_ROOT` | `$ZAUR_DATA_ROOT/mirror` | Directory for mirrored packages |
| `ZAUR_BUILD_ROOT` | `$ZAUR_DATA_ROOT/build` | Directory for build workspaces |
| `ZAUR_SOURCE_ROOT` | `$ZAUR_DATA_ROOT/sources` | Directory for source checkouts |
| `ZAUR_LOG_ROOT` | `$ZAUR_DATA_ROOT/logs` | Created but unused (logs are stored in the database) |
| `ZAUR_DB_NAME` | `zaur` | Database name prefix (repo databases use fixed names: `aur.db`, `custom.db`) |
| `ZAUR_DB_PATH` | `$ZAUR_DATA_ROOT/zaur.db` | Database file path |
| `ZAUR_BIND` | `127.0.0.1` | HTTP server bind address |
| `ZAUR_PORT` | `9004` | HTTP server port |
| `ZAUR_API_TOKEN` | (none) | Bearer token required for protected endpoints |
| `ZAUR_GPG_KEY` | (none) | GPG key ID for signing packages and repo databases |
| `ZAUR_CORS_ORIGIN` | (none) | CORS origin header (omit for no CORS headers) |

## Security Hardening

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAUR_SCAN_POLICY` | `warn` | PKGBUILD static-analysis gate: `off`, `warn` (log only), or `enforce` (block builds on critical/high findings) |
| `ZAUR_CHECKSUM_PINNING` | `true` | Embed computed `sha256sums` in generated PKGBUILDs and record resolved git commits |
| `ZAUR_REQUIRE_SIGNED_COMMITS` | `false` | Require git sources to have a signed HEAD commit from a trusted key |
| `ZAUR_BUILD_ISOLATION` | `none` | Build backend: `none`, `chroot` (devtools `makechrootpkg`), or `container` |
| `ZAUR_CONTAINER_RUNTIME` | `podman` | Container runtime when isolation is `container` (`podman` or `docker`) |
| `ZAUR_CONTAINER_IMAGE` | `archlinux:base-devel` | Container image used for `container` isolation |
| `ZAUR_CHROOT_DIR` | `$ZAUR_DATA_ROOT/chroot` | Chroot location used for `chroot` isolation |
| `ZAUR_SECURITY_REQUIRE_SIGNATURES` | `false` | Treat unsigned packages as a security concern in status reporting |
| `ZAUR_SECURITY_STALE_DAYS` | `30` | Age in days after which a package is reported stale |

See [Supply-Chain Hardening](../security/supply-chain.md) for how these gates fit
into the build pipeline.

## Mirror Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAUR_MIRROR_ROOT` | `$ZAUR_DATA_ROOT/mirror` | Local mirror storage directory |
| `ZAUR_MIRROR_UPSTREAM` | `https://mirrors.kernel.org/archlinux` | Upstream mirror URL |
| `ZAUR_MIRROR_POLICY` | `metadata` | Caching policy: `metadata` or `ondemand` |

See [Mirror](mirror.md) for details.

## External Tool Dependencies

ZAUR shells out to standard Arch tooling, which must be available in `PATH`:

| Tool | Package | Used for |
|------|---------|----------|
| `makepkg` | `pacman` | Building packages from PKGBUILDs |
| `repo-add` | `pacman` | Generating repository databases |
| `git` | `git` | Cloning AUR and GitHub sources |
| `gpg` | `gnupg` | Signing packages and verifying commits (optional) |
| `tar` | `tar` | Extracting mirror database files |

## Directory Structure

After initialization, the data root contains:

```text
$ZAUR_DATA_ROOT/
├── repos/
│   ├── aur/           # AUR package repository
│   └── custom/        # Custom package repository
├── mirror/            # Cached Arch mirror packages
├── build/             # Package build workspaces
├── sources/           # Source checkouts (PKGBUILDs)
├── logs/              # Created but unused (logs live in the database)
└── zaur.db            # ZQLite database
```

## Example Configurations

### Local Development

```bash
export ZAUR_DATA_ROOT="$HOME/.zaur"
zaur init
zaur serve --port 9004
```

### System-Wide

```bash
export ZAUR_DATA_ROOT="/var/lib/zaur"
export ZAUR_BIND="0.0.0.0"
export ZAUR_PORT="9004"
export ZAUR_API_TOKEN="your-secret-token"
zaur init
zaur serve
```

## Repository Naming

ZAUR publishes two repositories with fixed database names:

| Repository | Path | Database | pacman.conf section |
|------------|------|----------|---------------------|
| AUR packages | `/aur/` | `aur.db.tar.zst` | `[aur]` |
| Custom packages | `/custom/` | `custom.db.tar.zst` | `[custom]` |

See [Repositories](repositories.md) for client configuration and signing.
