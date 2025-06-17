# 📚 ZAUR Documentation

## 🛰️ Overview

ZAUR (Zig Arch User Repository) is a lightweight self-hosted AUR backend written in Zig. This is a **production-ready** system with complete functionality for building and hosting Arch packages.

### Current Status (Production Ready)
* ✅ **CLI Framework** - Complete command structure (`init`, `add`, `build`, `serve`, `sync`, `list`, `clean`, `status`, `help`)
* ✅ **Configuration Management** - Directory setup and config handling
* ✅ **SQLite Database** - Full SQLite implementation with proper schema and package tracking
* ✅ **AUR Integration** - JSON parsing and PKGBUILD download working
* ✅ **Build System** - Zig build configuration working and compiles successfully
* ✅ **Package Building** - makepkg wrapper implementation complete
* ✅ **Repository Generation** - repo-add integration working
* ✅ **HTTP Server** - Complete implementation with file serving and JSON API
* ✅ **System Monitoring** - Status, list, and clean commands for maintenance

## 🔧 Requirements

* Zig v0.15+
* Git (for package sources)
* makepkg (for building packages)
* repo-add (for repository generation)
* sqlite3 (system library)

---

## 🚀 Production Usage

### Initialize ZAUR
```bash
zaur init
```
Creates directory structure and initializes the SQLite database.

### Complete Workflow
```bash
# Add packages from AUR
zaur add aur/yay
zaur add aur/firefox-developer-edition

# Build all packages
zaur build all

# List packages and status
zaur list

# Check system health
zaur status

# Clean old builds (keep 3 versions)
zaur clean 3

# Start HTTP server for LAN access
zaur serve --port 8080 --bind 0.0.0.0
```

### Configuration
Default directories:
- Repository: `~/GhostCTL/packages`
- Build: `~/GhostCTL/build`
- Database: `~/GhostCTL/zaur.db`

### Command Reference
| Command | Description | Example |
|---------|-------------|---------|
| `init` | Initialize repository and database | `zaur init` |
| `add` | Add package from AUR or GitHub | `zaur add aur/yay` |
| `build` | Build packages (default: all) | `zaur build firefox` |
| `serve` | Start HTTP server | `zaur serve --bind 0.0.0.0` |
| `list` | Show packages and repository status | `zaur list` |
| `clean` | Clean old builds (default: keep 3) | `zaur clean 5` |
| `status` | System health and statistics | `zaur status` |
| `sync` | Sync from remote (planned) | `zaur sync <url>` |

---

## 🌐 Production Deployment

### NGINX Reverse Proxy
```nginx
upstream zaur {
    server 192.168.1.100:8080;  # Your ZAUR server IP
}

server {
    listen 80;
    server_name aur.yourdomain.com;
    
    # Proxy to ZAUR HTTP server
    location /zaur/ {
        proxy_pass http://zaur/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    
    # Or direct file serving (better performance)
    location /zaur-files/ {
        alias /path/to/GhostCTL/packages/;
        autoindex on;
        autoindex_exact_size off;
    }
}
```

### Pacman Configuration
```ini
[zaur]
SigLevel = Optional TrustAll
Server = http://aur.yourdomain.com/zaur/
```

### Integration with AUR Helpers
For your "reap" CLI tool and other AUR helpers:
```bash
# Base URL for API access
export ZAUR_BASE_URL="http://your-server:8080"

# Package list endpoint
curl http://your-server:8080/api/packages
```

---

## 🔧 Advanced Configuration

### Systemd Service
Create `/etc/systemd/system/zaur.service`:
```ini
[Unit]
Description=ZAUR - Zig Arch User Repository
After=network.target

[Service]
Type=simple
User=zaur
WorkingDirectory=/home/zaur/zaur
ExecStart=/home/zaur/zaur/zig-out/bin/zaur serve --bind 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Automated Builds
Set up a cron job for automatic rebuilds:
```bash
# Rebuild packages daily at 2 AM
0 2 * * * /home/zaur/zaur/zig-out/bin/zaur build all
```

---

## 📝 Development Notes

### Architecture
- **CLI**: Command-line interface with subcommands - Complete ✅
- **Config**: Directory and database path management - Complete ✅
- **Database**: SQLite package metadata with full schema - Complete ✅
- **AUR Client**: HTTP client for AUR API with JSON parsing - Complete ✅
- **Builder**: makepkg wrapper with build result handling - Complete ✅
- **Repository**: repo-add wrapper for pacman compatibility - Complete ✅
- **Server**: HTTP file server with API endpoints - Complete ✅

### Code Organization
```
src/
├── main.zig      # CLI entry point and command routing ✅
├── root.zig      # Library exports ✅
├── config.zig    # Configuration management ✅
├── database.zig  # SQLite package metadata ✅
├── aur.zig       # AUR API client ✅
├── builder.zig   # Package building ✅
├── repo.zig      # Repository generation ✅
└── server.zig    # HTTP server ✅
```

### API Endpoints
- `GET /` - Web interface with repository overview
- `GET /api/packages` - JSON list of available packages
- `GET /{filename}` - Direct file serving for packages and repository databases

This is a complete, production-ready AUR management system ready for deployment.
