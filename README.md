<p align="center">
  <img src="assets/zaur.png" alt="ZAUR Logo" width="200"/>
</p>

<h1 align="center">ZAUR</h1>

<p align="center">
  <strong>Zig-native AUR builder and repository server for Arch Linux</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/Arch_Linux-1793D1?style=for-the-badge&logo=arch-linux&logoColor=white" alt="Arch Linux">
  <img src="https://img.shields.io/badge/AUR-1793D1?style=for-the-badge&logo=arch-linux&logoColor=white" alt="AUR">
  <img src="https://img.shields.io/badge/SQLite-003B57?style=for-the-badge&logo=sqlite&logoColor=white" alt="SQLite">
  <img src="https://img.shields.io/badge/HTTP_Server-4CAF50?style=for-the-badge&logo=fastapi&logoColor=white" alt="HTTP Server">
</p>

---

ZAUR is a self-hosted AUR package builder and repository server built in Zig. It provides a complete workflow for building AUR packages, managing custom repositories, and optionally mirroring official Arch repositories.

---

## Features

- **AUR Integration** - Add packages from AUR, download PKGBUILDs, build with makepkg
- **Repository Management** - Generate pacman-compatible repos (.db.tar.zst, .files.tar.zst)
- **HTTP Server** - Serve repositories directly to pacman clients
- **Source Management** - Support for AUR, GitHub, and local sources
- **Mirror Support** - Act as a caching proxy for official Arch packages with on-demand downloading
- **ZQLite Backend** - Package metadata and build tracking via [zqlite](https://github.com/ghostkellz/zqlite)
- **Zig/Rust Builders** - Generate PKGBUILDs for Zig and Rust projects

---

## Quick Start

### Prerequisites

- Zig 0.16.0-dev or later
- Arch Linux
- `makepkg` and `repo-add` (from pacman)

### Build

```bash
git clone https://github.com/ghostkellz/zaur.git
cd zaur
zig build
```

### Initialize

```bash
./zig-out/bin/zaur init
```

---

## Usage

```bash
# Add a package from AUR
zaur source add aur/yay

# Add from GitHub
zaur source add github:user/repo

# List sources
zaur source list

# Update sources
zaur source update all

# Build packages
zaur build all
zaur build <package-name>

# View build logs
zaur build logs <package-name>

# Generate repository database
zaur repo publish

# Start HTTP server
zaur serve --port 9004

# Check system status
zaur status
zaur doctor

# Mirror operations
zaur mirror status       # Show mirror status
zaur mirror sync         # Sync all repos
zaur mirror smart-sync   # Sync databases only
zaur mirror verify       # Verify mirror files
```

---

## Pacman Configuration

Add to `/etc/pacman.conf`:

```ini
[aur]
SigLevel = Optional TrustAll
Server = http://localhost:9004/aur/

[custom]
SigLevel = Optional TrustAll
Server = http://localhost:9004/custom/
```

---

## Project Structure

```
src/
├── main.zig        # CLI entry point
├── root.zig        # Library exports
├── config.zig      # Configuration management
├── database.zig    # ZQLite package metadata
├── aur.zig         # AUR API client
├── builder.zig     # Package building (makepkg)
├── repo.zig        # Repository generation
├── server.zig      # HTTP server and API
├── mirror.zig      # Arch mirror support
├── source.zig      # Source management
├── deps.zig        # Dependency resolution
├── gpg.zig         # GPG signing support
├── zigbuilder.zig  # Zig project PKGBUILD generation
└── rustbuilder.zig # Rust project PKGBUILD generation
```

---

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/status` | GET | System status |
| `/api/packages` | GET | List packages |
| `/api/sources` | GET/POST/DELETE | Manage sources |
| `/api/builds` | GET/POST | Build info and triggers |
| `/api/repos` | GET | Repository info |
| `/api/repos/publish` | POST | Regenerate repo databases |
| `/api/mirror` | GET | Mirror status (upstream, policy, cache) |
| `/api/mirror/sync` | POST | Trigger mirror sync |
| `/api/security/packages` | GET | Security status of packages |
| `/api/security/advisories` | GET | List security advisories |

---

## Development

### Testing

```bash
cd docker
./run-tests.sh basic   # Basic tests
./run-tests.sh full    # Full integration tests
./run-tests.sh shell   # Interactive shell
```

---

## Documentation

- [Installation](docs/installation.md)
- [Configuration](docs/configuration.md)
- [Deployment](docs/deployment.md)
- [Mirror Setup](docs/mirror.md)
- [Changelog](CHANGELOG.md)
- [Security](SECURITY.md)

---

## License

MIT License - see [LICENSE](LICENSE)

---

Maintained by [GhostKellz](https://github.com/ghostkellz)
