# 📚 ZAUR Documentation

## 🛰️ Overview

ZAUR (Zig Arch User Repository) is a lightweight self-hosted AUR backend written in Zig. This is currently a **scaffolding version** with basic structure in place.

### Current Status (Scaffolding)
* ✅ **CLI Framework** - Complete command structure (`init`, `add`, `build`, `serve`, `sync`, `help`)
* ✅ **Configuration Management** - Directory setup and config handling
* ✅ **SQLite Database** - Full SQLite implementation with proper schema
* ✅ **AUR Integration** - JSON parsing and PKGBUILD download working
* ✅ **Build System** - Zig build configuration working
* ✅ **Package Building** - makepkg wrapper implementation complete
* ✅ **Repository Generation** - repo-add integration working
* ⚠️ **HTTP Server** - Stub implementation (needs modern Zig std.http API)

## 🔧 Requirements

* Zig v0.15+
* Git (for package sources)
* makepkg (for building packages - future implementation)
* repo-add (for repository generation - future implementation)

---

## 🚀 Current Usage (Scaffolding)

### Initialize ZAUR
```bash
zaur init
```
Creates directory structure and initializes the database.

### Test Commands
```bash
# Show help
zaur help

# Add package (stub - logs only)
zaur add aur/firefox

# Build packages (stub - logs only)  
zaur build all

# Start server (stub - shows what would happen)
zaur serve --port 8080 --bind 0.0.0.0
```

### Configuration
Default directories:
- Repository: `~/GhostCTL/packages`
- Build: `~/GhostCTL/build`
- Database: `~/GhostCTL/zaur.db`

---

## 🚧 Next Implementation Phases

### Phase 1: Core Functionality (High Priority)
1. **Real Database Storage** - Replace stub with actual SQLite implementation
2. **AUR Package Fetching** - Complete HTTP client and JSON parsing
3. **Package Building** - Implement makepkg wrapper and build process
4. **Repository Generation** - Integrate repo-add for pacman-compatible repos

### Phase 2: HTTP Server (Medium Priority)
1. **Modern HTTP Server** - Update to current Zig std.http APIs
2. **File Serving** - Serve repository files to pacman
3. **Repository Listing** - Web interface for browsing packages

### Phase 3: Advanced Features (Future)
1. **GitHub Integration** - Sync from GitHub-hosted PKGBUILDs
2. **Build Isolation** - Docker/systemd integration for safe builds
3. **Monitoring** - Build logs, metrics, and health checks
4. **Auto-updates** - Scheduled rebuilds from AUR/GitHub

---

## 🌐 Production Deployment (Future)

### NGINX Reverse Proxy
When the HTTP server is implemented, you can use NGINX:

```nginx
server {
    listen 443 ssl;
    server_name aur.example.com;
    
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### Pacman Configuration
```ini
[zaur]
SigLevel = Optional TrustAll
Server = https://aur.example.com/
```

---

## 📝 Development Notes

### Architecture
- **CLI**: Command-line interface with subcommands
- **Config**: Directory and database path management  
- **Database**: Package metadata storage (currently stub)
- **AUR Client**: HTTP client for AUR API (partial)
- **Builder**: makepkg wrapper (stub)
- **Repository**: repo-add wrapper (stub)
- **Server**: HTTP file server (stub)

### Code Organization
```
src/
├── main.zig      # CLI entry point and command routing
├── root.zig      # Library exports
├── config.zig    # Configuration management
├── database.zig  # Package metadata (stub)
├── aur.zig       # AUR API client (partial)
├── builder.zig   # Package building (stub)
├── repo.zig      # Repository generation (stub)
└── server.zig    # HTTP server (stub)
```

This scaffolding provides a solid foundation for implementing a complete AUR management system.
