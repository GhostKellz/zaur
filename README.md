# ZAUR: Zig Arch User Repository

> **ZAUR** is a lightweight, Zig-native self-hosted AUR system for building and hosting Arch packages. This is currently a **scaffolding version** with the core structure implemented and ready for feature development.

![Arch Linux](https://img.shields.io/badge/arch%20linux-supported-blue?logo=arch-linux&logoColor=white)
[![AUR](https://img.shields.io/badge/AUR-planned-orange?logo=arch-linux)](#)
![Zig v0.15](https://img.shields.io/badge/Zig-v0.15-yellow?logo=zig)
![Status](https://img.shields.io/badge/status-scaffolding-yellow)

---

## 🚧 Current Status (Scaffolding)

**What's Working:**
* ✅ CLI framework with all commands (`init`, `add`, `build`, `serve`, `sync`, `help`)
* ✅ Configuration management and directory setup
* ✅ SQLite database with proper schema and package tracking
* ✅ AUR integration with JSON parsing and PKGBUILD download
* ✅ Package building with makepkg wrapper
* ✅ Repository generation with repo-add integration
* ✅ Build system (compiles successfully)
* ✅ Basic project structure and module organization

**What's Stubbed (Ready for Implementation):**
* ⚠️ HTTP server (needs modern Zig std.http APIs)

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

## 🧪 Current Usage (Scaffolding)

```bash
# Initialize directories and database
zaur init

# Test commands (show stubs)
zaur add aur/firefox
zaur build all
zaur serve --port 8080

# All commands show what they would do
# and log their intended functionality
```

---

## 🗃️ Project Structure

```
~/GhostCTL/          # Default repo directory
├── packages/        # Built .pkg.tar.zst files (future)
├── build/           # Build workspace
└── zaur.db          # Package metadata database
```

**Source Code:**
```
src/
├── main.zig         # CLI entry point and command routing
├── root.zig         # Library exports
├── config.zig       # Configuration management ✅
├── database.zig     # Package metadata (stub)
├── aur.zig          # AUR API client (partial)
├── builder.zig      # Package building (stub)
├── repo.zig         # Repository generation (stub)
└── server.zig       # HTTP server (stub)
```

---

## 🚀 Next Implementation Priority

### Phase 1: Core Functionality
1. **SQLite Database** - Replace in-memory stub with real persistence
2. **AUR Package Fetching** - Complete JSON parsing and PKGBUILD download
3. **Package Building** - Implement makepkg integration
4. **Repository Generation** - Add repo-add wrapper for pacman compatibility

### Phase 2: HTTP Server
1. **Modern HTTP API** - Update to current Zig std.http
2. **File Serving** - Serve packages to pacman clients
3. **Web Interface** - Browse packages via web

### Phase 3: Advanced Features
1. **GitHub Integration** - Sync from GitHub PKGBUILDs
2. **Build Isolation** - Sandboxing with Docker/systemd
3. **Monitoring & Automation** - Logs, metrics, scheduled rebuilds

---

## 📚 Documentation

* [DOCS.md](DOCS.md) - Detailed documentation and development notes
* [License](LICENSE) - MIT License

---

## 👻 Maintained by [GhostKellz](https://github.com/ghostkellz)

**Contributing:** This project is in active scaffolding phase. Core features need implementation before accepting contributions.

