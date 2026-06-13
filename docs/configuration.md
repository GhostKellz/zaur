# ZAUR Configuration

ZAUR uses environment variables for configuration. All variables have sensible defaults.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAUR_DATA_ROOT` | `.zaur` | Root directory for all ZAUR data |
| `ZAUR_REPO_ROOT` | `$ZAUR_DATA_ROOT/repos` | Directory for repository files |
| `ZAUR_MIRROR_ROOT` | `$ZAUR_DATA_ROOT/mirror` | Directory for mirrored packages |
| `ZAUR_BUILD_ROOT` | `$ZAUR_DATA_ROOT/build` | Directory for build workspaces |
| `ZAUR_SOURCE_ROOT` | `$ZAUR_DATA_ROOT/sources` | Directory for source checkouts |
| `ZAUR_LOG_ROOT` | `$ZAUR_DATA_ROOT/logs` | Directory created but unused (logs stored in DB) |
| `ZAUR_DB_NAME` | `zaur` | SQLite database name prefix (repo databases use fixed names: `aur.db`, `custom.db`) |
| `ZAUR_DB_PATH` | `$ZAUR_DATA_ROOT/zaur.db` | SQLite database file path |
| `ZAUR_BIND` | `127.0.0.1` | HTTP server bind address |
| `ZAUR_PORT` | `9004` | HTTP server port |
| `ZAUR_API_TOKEN` | (none) | API authentication token for protected endpoints |
| `ZAUR_GPG_KEY` | (none) | GPG key ID for signing packages and repo databases |
| `ZAUR_CORS_ORIGIN` | (none) | CORS origin header (omit for no CORS headers) |

### Security Hardening

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAUR_SCAN_POLICY` | `warn` | PKGBUILD static-analysis gate: `off`, `warn` (log only), or `enforce` (block builds on critical/high findings) |
| `ZAUR_CHECKSUM_PINNING` | `true` | Embed computed `sha256sums` in generated PKGBUILDs and record resolved git commits |
| `ZAUR_REQUIRE_SIGNED_COMMITS` | `false` | Require git sources to have a signed HEAD commit from a trusted key |
| `ZAUR_BUILD_ISOLATION` | `none` | Build backend: `none`, `chroot` (devtools `makechrootpkg`), or `container` |
| `ZAUR_CONTAINER_RUNTIME` | `podman` | Container runtime when isolation is `container` (`podman` or `docker`) |
| `ZAUR_CONTAINER_IMAGE` | `archlinux:base-devel` | Container image used for `container` isolation |
| `ZAUR_CHROOT_DIR` | `$ZAUR_DATA_ROOT/chroot` | Chroot location used for `chroot` isolation |

## External Tool Dependencies

ZAUR requires the following tools to be available in PATH:

| Tool | Package | Used For |
|------|---------|----------|
| `makepkg` | `pacman` | Building packages from PKGBUILDs |
| `repo-add` | `pacman` | Generating repository databases |
| `git` | `git` | Cloning AUR and GitHub sources |
| `gpg` | `gnupg` | Signing packages (optional) |
| `tar` | `tar` | Extracting mirror database files |

## Directory Structure

After initialization, ZAUR creates:

```
$ZAUR_DATA_ROOT/
├── repos/
│   ├── aur/           # AUR package repository
│   └── custom/        # Custom package repository
├── mirror/            # Cached Arch mirror packages
├── build/             # Package build workspaces
├── sources/           # Source checkouts (PKGBUILDs)
├── logs/              # Build logs
└── zaur.db            # SQLite database
```

## Example Configurations

### Local Development

```bash
export ZAUR_DATA_ROOT="$HOME/.zaur"
zaur init
zaur serve --port 9004
```

### System-wide Installation

```bash
export ZAUR_DATA_ROOT="/var/lib/zaur"
export ZAUR_BIND="0.0.0.0"
export ZAUR_PORT="9004"
export ZAUR_API_TOKEN="your-secret-token"
zaur init
zaur serve
```

### Docker Deployment

```bash
export ZAUR_DATA_ROOT="/var/lib/zaur"
export ZAUR_BIND="0.0.0.0"
export ZAUR_PORT="9004"
zaur init
zaur serve
```

## API Authentication

When `ZAUR_API_TOKEN` is set, the following endpoints require the `Authorization: Bearer <token>` header:

- `POST /api/sources`
- `DELETE /api/sources`
- `POST /api/builds`
- `POST /api/repos/publish`
- `POST /api/mirror/sync`
- `POST /api/security/scan-pkgbuild`
- `GET /api/security/keys`
- `POST /api/security/keys`
- `DELETE /api/security/keys`
- `POST /api/security/pin`

Public endpoints (no auth required):
- `GET /api/health`
- `GET /api/status`
- `GET /api/packages`
- `GET /api/sources`
- `GET /api/builds`
- `GET /api/repos`
- `GET /api/mirror`
- `GET /api/security/findings`
- All repository file serving (`/aur/*`, `/custom/*`, `/mirror/*`)

## API Request Requirements

Admin write endpoints require:
- `Content-Type: application/json` header (returns `415` if missing)
- Valid JSON body (returns `400` on malformed JSON)
- Explicit intent (e.g., `{"all":true}` for build-all, not empty body)

## GPG Signing

To enable package signing:

```bash
export ZAUR_GPG_KEY="YOUR_KEY_ID"
```

The key must be available in the user's GPG keyring. Signed packages will have `.sig` files generated alongside them.

## Repository Naming

ZAUR creates two repositories with fixed database names:

| Repository | Path | Database | pacman.conf section |
|------------|------|----------|---------------------|
| AUR packages | `/aur/` | `aur.db.tar.zst` | `[aur]` |
| Custom packages | `/custom/` | `custom.db.tar.zst` | `[custom]` |

Example pacman.conf:

```ini
[aur]
SigLevel = Optional TrustAll
Server = http://localhost:9004/aur/

[custom]
SigLevel = Optional TrustAll
Server = http://localhost:9004/custom/
```

## Empty Repository Behavior

When `zaur repo publish` is run:
- Empty repositories (no `.pkg.tar.zst` files) print "No packages found" and succeed
- No database file is created for empty repositories
- This is normal behavior - add packages before publishing
