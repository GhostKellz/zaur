# ZAUR Installation Guide

## Quick Install (One-liner)

```bash
curl -sSL https://raw.githubusercontent.com/ghostkellz/zaur/main/install.sh | sudo bash
```

## Manual Installation

### Prerequisites

- Arch Linux system
- Root access (sudo)
- Internet connection

### Step 1: Install Dependencies

```bash
sudo pacman -Sy --needed git base-devel sqlite pacman-contrib
```

### Step 2: Install Zig Compiler

```bash
# From AUR
yay -S zig
# OR build from AUR manually
git clone https://aur.archlinux.org/zig.git
cd zig && makepkg -si
```

### Step 3: Build and Install ZAUR

```bash
# Clone repository
git clone https://github.com/ghostkellz/zaur.git
cd zaur

# Build
zig build -Doptimize=ReleaseSafe

# Install
sudo install -Dm755 zig-out/bin/zaur /usr/bin/zaur
sudo install -Dm644 README.md /usr/share/doc/zaur/README.md
sudo install -Dm644 LICENSE /usr/share/licenses/zaur/LICENSE
```

### Step 4: Setup Service

```bash
# Create service user
sudo useradd -r -s /bin/false -d /var/lib/zaur -m zaur

# Install systemd service
sudo install -Dm644 zaur.service /usr/lib/systemd/system/zaur.service
sudo systemctl daemon-reload
```

### Step 5: Initialize and Start

```bash
# Initialize ZAUR
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur init

# Start service
sudo systemctl start zaur
sudo systemctl enable zaur

# Check status
sudo systemctl status zaur
curl http://localhost:9004/api/health
```

## Package Installation Methods

### Method 1: Using PKGBUILD

```bash
# Build package
makepkg -si

# Install
sudo pacman -U zaur-*.pkg.tar.zst
```

### Method 2: AUR Helper

```bash
# Using yay
yay -S zaur

# Using paru
paru -S zaur
```

## Configuration

### Pacman Integration

Add to `/etc/pacman.conf`:

```ini
[aur]
SigLevel = Optional TrustAll
Server = http://localhost:9004/aur/

[custom]
SigLevel = Optional TrustAll
Server = http://localhost:9004/custom/
```

### Nginx Reverse Proxy (Optional)

```nginx
server {
    listen 80;
    server_name aur.yourdomain.com;
    
    location /zaur/ {
        proxy_pass http://localhost:9004/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Usage

### Basic Commands

```bash
# Add packages from AUR
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur source add aur/yay

# Add from GitHub
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur source add github:user/repo

# List sources
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur source list

# Build all packages
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur build all

# Publish repository database
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur repo publish

# List packages
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur list

# Check status
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur status

# Backup database
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur backup

# Restore from backup
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur restore <backup_file>

# Clean old builds (keep 3 versions)
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur clean 3
```

### Service Management

```bash
# Start/Stop service
sudo systemctl start zaur
sudo systemctl stop zaur

# Enable/Disable auto-start
sudo systemctl enable zaur
sudo systemctl disable zaur

# View logs
sudo journalctl -u zaur -f
```

## Troubleshooting

### Common Issues

1. **Permission denied**: Ensure commands are run as `zaur` user
2. **Build failures**: Check dependencies and AUR package status
3. **Service won't start**: Check logs with `journalctl -u zaur`
4. **Database errors**: Reinitialize with `sudo -u zaur zaur init`

### Logs Location

- System logs: `journalctl -u zaur`
- Application data: `/var/lib/zaur/`
- Configuration: Built-in (no external config files)

### Uninstallation

```bash
# Stop and disable service
sudo systemctl stop zaur
sudo systemctl disable zaur

# Remove files
sudo rm /usr/bin/zaur
sudo rm /usr/lib/systemd/system/zaur.service
sudo systemctl daemon-reload
sudo rm -rf /var/lib/zaur
sudo rm -rf /usr/share/doc/zaur
sudo rm -rf /usr/share/licenses/zaur

# Remove user
sudo userdel zaur

# Remove from pacman.conf
sudo sed -i '/\[aur\]/,+2d' /etc/pacman.conf
sudo sed -i '/\[custom\]/,+2d' /etc/pacman.conf
```

## Security Notes

- ZAUR runs as unprivileged `zaur` user
- Default binding is `127.0.0.1:9004` (localhost only)
- Set `ZAUR_API_TOKEN` to require authentication for admin endpoints
- Set `ZAUR_GPG_KEY` to enable package signing
- Packages are built in isolated directory under `/var/lib/zaur`
- Systemd service includes security hardening (NoNewPrivileges, ProtectSystem, etc.)

## Support

- GitHub Issues: https://github.com/ghostkellz/zaur/issues
- Documentation: [README.md](README.md)
- Source Code: https://github.com/ghostkellz/zaur