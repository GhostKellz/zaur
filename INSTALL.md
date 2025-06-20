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
sudo useradd -r -s /bin/false -d /var/lib/zaur -c "ZAUR service user" zaur

# Create directories
sudo mkdir -p /var/lib/zaur/{packages,build}
sudo chown -R zaur:zaur /var/lib/zaur

# Install systemd service
sudo cp zaur.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### Step 5: Initialize and Start

```bash
# Initialize ZAUR
sudo -u zaur zaur init

# Start service
sudo systemctl start zaur
sudo systemctl enable zaur

# Check status
sudo systemctl status zaur
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
[zaur]
SigLevel = Optional TrustAll
Server = http://localhost:8080/
```

### Nginx Reverse Proxy (Optional)

```nginx
server {
    listen 80;
    server_name aur.yourdomain.com;
    
    location /zaur/ {
        proxy_pass http://localhost:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Usage

### Basic Commands

```bash
# Add packages from AUR
sudo -u zaur zaur add aur/yay
sudo -u zaur zaur add aur/firefox

# Build all packages
sudo -u zaur zaur build all

# List repository
sudo -u zaur zaur list

# Check status
sudo -u zaur zaur status

# Clean old builds
sudo -u zaur zaur clean 3

# Start HTTP server (if not using systemd)
sudo -u zaur zaur serve --port 8080 --bind 0.0.0.0
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
sudo rm /etc/systemd/system/zaur.service
sudo rm -rf /var/lib/zaur
sudo rm -rf /usr/share/doc/zaur

# Remove user
sudo userdel zaur

# Remove from pacman.conf
sudo sed -i '/\[zaur\]/,+2d' /etc/pacman.conf
```

## Security Notes

- ZAUR runs as unprivileged `zaur` user
- Default binding is `0.0.0.0:8080` (change if needed)
- No authentication by default (add reverse proxy if needed)
- Packages are built in isolated directory under `/var/lib/zaur`

## Support

- GitHub Issues: https://github.com/ghostkellz/zaur/issues
- Documentation: [README.md](README.md)
- Source Code: https://github.com/ghostkellz/zaur