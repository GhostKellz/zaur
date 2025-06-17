# ZAUR

> **ZAUR** is a lightweight, Zig-native self-hosted AUR system for building and hosting Arch packages. This is currently a **scaffolding version** with the core structure implemented and ready for feature development.

![Arch Linux](https://img.shields.io/badge/arch%20linux-supported-blue?logo=arch-linux&logoColor=white)
[![AUR](https://img.shields.io/badge/AUR-planned-orange?logo=arch-linux)](#)
![Zig v0.15](https://img.shields.io/badge/Zig-v0.15-yellow?logo=zig)
[![Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)](https://github.com/ghostkellz/zaur)

---

## � Current Status

**What's Working:**
* ✅ CLI framework with all commands (`init`, `add`, `build`, `serve`, `sync`, `list`, `clean`, `status`, `help`)
* ✅ Configuration management and directory setup
* ✅ SQLite database with proper schema and package tracking
* ✅ AUR integration with JSON parsing and PKGBUILD download
* ✅ Package building with makepkg wrapper
* ✅ Repository generation with repo-add integration
* ✅ HTTP server with file serving and JSON API
* ✅ System monitoring and maintenance commands
* ✅ Build system (compiles successfully)
* ✅ Complete project structure and module organization

**Ready for Production:**
* 🌐 LAN deployment with nginx integration
* 📦 Pacman-compatible repository serving
* 🔧 Integration with AUR helpers like "reap"

---

## 🎯 Planned Features

* 🔧 **Self-hosted AUR builder** with Git and makepkg integration
* 📦 **Pacman-compatible repo generator** (`.db.tar.zst`, `.files.tar.zst`)
* 🗄️ **SQLite backend** for package metadata and build tracking
* 🔄 **Auto-update + rebuild** from AUR and GitHub
* 🖥️ **Built-in HTTP server** to serve your repo directly to `pacman`
* 🔒 **Optional isolation** via Docker or systemd
* 🔌 Easily extensible (sync hooks, CI integration)

---

## 📦 Install & Test

```bash
# Clone the repo
git clone https://github.com/ghostkellz/zaur.git
cd zaur

# Build with Zig
zig build

# Test the scaffolding
./zig-out/bin/zaur help
./zig-out/bin/zaur init
```

---

## 🧪 Current Usage (Production Ready)

```bash
# Initialize directories and database
zaur init

# Add packages from AUR
zaur add aur/yay
zaur add aur/firefox

# Build all packages
zaur build all

# List repository status
zaur list

# Check system health
zaur status

# Clean old build files (keep 3 versions)
zaur clean 3

# Start HTTP server for LAN access
zaur serve --port 8080 --bind 0.0.0.0
```

### Integration with AUR Helpers
```bash
# Configure your "reap" CLI tool to use ZAUR
export ZAUR_BASE_URL="http://your-server:8080"

# Or use direct pacman configuration
echo '[zaur]
Server = http://your-server:8080/' >> /etc/pacman.conf
```

---

## 🗃️ Project Structure

```
~/GhostCTL/          # Default repo directory
├── packages/        # Built .pkg.tar.zst files
├── build/           # Build workspace
└── zaur.db          # Package metadata database
```

**Source Code:**
```
src/
├── main.zig         # CLI entry point and command routing
├── root.zig         # Library exports
├── config.zig       # Configuration management ✅
├── database.zig     # SQLite package metadata ✅
├── aur.zig          # AUR API client ✅
├── builder.zig      # Package building ✅
├── repo.zig         # Repository generation ✅
└── server.zig       # HTTP server ✅
```

---

## 🌐 Network Architecture

```
Internet → Nginx (Port 80/443) → ZAUR HTTP Server (Port 8080) → File System
```

### Nginx Integration
```nginx
upstream zaur {
    server 192.168.1.100:8080;  # Your ZAUR server IP
}

server {
    listen 80;
    server_name aur.yourdomain.com;
    
    location /zaur/ {
        proxy_pass http://zaur/;
        proxy_set_header Host $host;
    }
}
```

### Pacman Configuration
```ini
[zaur]
SigLevel = Optional TrustAll
Server = http://aur.yourdomain.com/zaur/
```

---

## 🚀 Advanced Features (Future Roadmap)

### Phase 1: Enhanced Automation
1. **GitHub Integration** - Sync from GitHub-hosted PKGBUILDs
2. **Auto-update Scheduler** - Automated rebuilds from AUR updates
3. **Dependency Resolution** - Smart build ordering
4. **Parallel Building** - Multi-package concurrent builds

### Phase 2: Enterprise Features  
1. **Build Isolation** - Docker/systemd sandboxing for safe builds
2. **User Management** - Multi-user repository access
3. **Build Caching** - Incremental builds and artifact caching
4. **Metrics & Monitoring** - Prometheus integration, build analytics

### Phase 3: Ecosystem Integration
1. **CI/CD Hooks** - GitHub Actions, GitLab CI integration
2. **Package Signing** - GPG signing for security
3. **Mirror Support** - Multiple mirror endpoints
4. **Plugin System** - Extensible architecture for custom hooks

---

## 📚 Documentation

* [DOCS.md](DOCS.md) - Detailed documentation and development notes
* [License](LICENSE) - MIT License

---

## 👻 Maintained by [GhostKellz](https://github.com/ghostkellz)

**Contributing:** This project is production-ready! Core features are complete. Contributions welcome for advanced features and optimizations.

