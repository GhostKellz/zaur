# ZAUR: Zig Arch User Repository

> **ZAUR** is a lightweight, Zig-native self-hosted AUR system that makes building and hosting Arch packages effortless. Think of it as your private AUR server with automation, Git sync, metadata storage, and HTTP repo generation built-in — powered by `zqlite`.

![Arch Linux](https://img.shields.io/badge/arch%20linux-supported-blue?logo=arch-linux&logoColor=white)
[![AUR](https://img.shields.io/badge/AUR-available-orange?logo=arch-linux)](https://aur.archlinux.org/)
![Zig v0.15](https://img.shields.io/badge/Zig-v0.15-yellow?logo=zig)

---

## 🚀 Features

* 🔧 **Self-hosted AUR builder** with Git and makepkg integration
* 📦 **Pacman-compatible repo generator** (`.db.tar.zst`, `.files.tar.zst`)
* 🧠 **ZQLite backend** for package metadata and build tracking
* 🔄 **Auto-update + rebuild** from AUR and GitHub
* 🖥️ **Built-in HTTP server** to serve your repo directly to `pacman`
* 🔒 **Optional isolation** via Docker or systemd
* 🔌 Easily extensible (e.g. sync hooks, CI integration, zmake)

---

## 📦 Install

```bash
# Clone the repo
git clone https://github.com/ghostkellz/zaur.git
cd zaur

# Build with Zig
zig build -Drelease-fast

# Or run directly:
zig build run -- init
```

---

## 🧪 Quickstart

```bash
# Initialize the repo layout and database
zaur init

# Add a package from the AUR
zaur add aur/firefox

# Add a GitHub-hosted PKGBUILD
zaur add github:ghostkellz/nvcontrol

# Build and host the repo
zaur build all
zaur serve

# Point your pacman to the repo
sudo vim /etc/pacman.conf
[zaur]
Server = http://your-server-ip:8080/repo
```

---

## 🗃️ Project Structure

```
/etc/zaur/           # Config and repo metadata
~/GhostCTL/          # Default repo directory
└── packages/        # Built .pkg.tar.zst files
└── logs/            # Build logs
└── db/              # Generated repo db files
zqlite.db            # ZQLite metadata database
```

---

## 🛠 Planned Features

*

---

## 📚 License

MIT License. See `LICENSE` for details.

---

## 👻 Maintained by [GhostKellz](https://github.com/ghostkellz)

