#!/bin/bash
# ZAUR Installer Script
# Usage: curl -sSL https://raw.githubusercontent.com/ghostkellz/zaur/main/install.sh | bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="https://github.com/ghostkellz/zaur"
INSTALL_DIR="/tmp/zaur-install"
SERVICE_USER="zaur"
SERVICE_DIR="/var/lib/zaur"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check if running on Arch Linux
check_arch() {
    if ! command -v pacman &> /dev/null; then
        log_error "This installer is designed for Arch Linux systems only"
        exit 1
    fi
    
    if ! grep -q "Arch Linux" /etc/os-release 2>/dev/null; then
        log_warn "OS detection: This may not be Arch Linux, proceeding anyway..."
    fi
}

# Install dependencies
install_dependencies() {
    log_info "Installing dependencies..."
    
    # Update package database
    pacman -Sy --noconfirm
    
    # Install required packages
    pacman -S --needed --noconfirm \
        git \
        base-devel \
        sqlite \
        pacman-contrib \
        systemd
    
    # Install Zig from AUR if not present
    if ! command -v zig &> /dev/null; then
        log_info "Installing Zig compiler..."
        
        # Create temporary user for AUR package installation
        if ! id "makepkg-temp" &>/dev/null; then
            useradd -m -s /bin/bash makepkg-temp
            echo "makepkg-temp ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/makepkg-temp
        fi
        
        # Install zig from AUR
        su - makepkg-temp -c "
            cd /tmp
            git clone https://aur.archlinux.org/zig.git
            cd zig
            makepkg -si --noconfirm
        "
        
        # Cleanup temporary user
        userdel -r makepkg-temp 2>/dev/null || true
        rm -f /etc/sudoers.d/makepkg-temp
    fi
    
    log_success "Dependencies installed"
}

# Clone and build ZAUR
build_zaur() {
    log_info "Cloning and building ZAUR..."
    
    # Clean up any existing installation directory
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    
    # Clone repository
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Build ZAUR
    log_info "Building ZAUR with Zig..."
    zig build -Doptimize=ReleaseSafe
    
    # Run tests
    log_info "Running tests..."
    zig build test || log_warn "Some tests failed, but continuing installation"
    
    log_success "ZAUR built successfully"
}

# Install ZAUR system-wide
install_zaur() {
    log_info "Installing ZAUR system-wide..."
    
    cd "$INSTALL_DIR"
    
    # Install binary
    install -Dm755 zig-out/bin/zaur /usr/bin/zaur
    
    # Install documentation
    install -Dm644 README.md /usr/share/doc/zaur/README.md
    install -Dm644 DOCS.md /usr/share/doc/zaur/DOCS.md 2>/dev/null || true
    install -Dm644 LICENSE /usr/share/licenses/zaur/LICENSE
    
    log_success "ZAUR binaries installed"
}

# Create service user and directories
setup_service() {
    log_info "Setting up ZAUR service..."
    
    # Create service user
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -s /bin/false -d "$SERVICE_DIR" -c "ZAUR service user" "$SERVICE_USER"
        log_success "Created service user: $SERVICE_USER"
    fi
    
    # Create service directories
    mkdir -p "$SERVICE_DIR"/{packages,build}
    chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVICE_DIR"
    chmod 755 "$SERVICE_DIR"
    
    # Create systemd service file
    cat > /etc/systemd/system/zaur.service << 'EOF'
[Unit]
Description=ZAUR - Self-hosted AUR system
After=network.target

[Service]
Type=exec
User=zaur
Group=zaur
WorkingDirectory=/var/lib/zaur
ExecStart=/usr/bin/zaur serve --port 8080 --bind 0.0.0.0
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    
    log_success "Service configuration created"
}

# Initialize ZAUR
initialize_zaur() {
    log_info "Initializing ZAUR..."
    
    # Initialize as service user
    sudo -u "$SERVICE_USER" /usr/bin/zaur init || {
        log_warn "Failed to initialize as service user, trying manual setup..."
        
        # Create database manually if needed
        sudo -u "$SERVICE_USER" touch "$SERVICE_DIR/zaur.db"
        sudo -u "$SERVICE_USER" chmod 644 "$SERVICE_DIR/zaur.db"
    }
    
    log_success "ZAUR initialized"
}

# Setup firewall (optional)
setup_firewall() {
    if command -v ufw &> /dev/null; then
        log_info "Configuring firewall..."
        ufw allow 8080/tcp comment "ZAUR HTTP server"
        log_success "Firewall configured for port 8080"
    elif command -v firewall-cmd &> /dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port=8080/tcp
        firewall-cmd --reload
        log_success "Firewalld configured for port 8080"
    else
        log_warn "No firewall detected. Remember to open port 8080 if using a firewall"
    fi
}

# Cleanup installation files
cleanup() {
    log_info "Cleaning up installation files..."
    rm -rf "$INSTALL_DIR"
    log_success "Installation files cleaned up"
}

# Display post-installation information
show_completion() {
    log_success "ZAUR installation completed!"
    echo
    echo -e "${BLUE}=== ZAUR Installation Summary ===${NC}"
    echo -e "Binary installed at: ${GREEN}/usr/bin/zaur${NC}"
    echo -e "Service user: ${GREEN}$SERVICE_USER${NC}"
    echo -e "Data directory: ${GREEN}$SERVICE_DIR${NC}"
    echo -e "Service file: ${GREEN}/etc/systemd/system/zaur.service${NC}"
    echo
    echo -e "${BLUE}=== Next Steps ===${NC}"
    echo -e "1. Start the service: ${GREEN}sudo systemctl start zaur${NC}"
    echo -e "2. Enable auto-start: ${GREEN}sudo systemctl enable zaur${NC}"
    echo -e "3. Check status: ${GREEN}sudo systemctl status zaur${NC}"
    echo -e "4. View logs: ${GREEN}sudo journalctl -u zaur -f${NC}"
    echo
    echo -e "${BLUE}=== Usage Examples ===${NC}"
    echo -e "Initialize repository: ${GREEN}sudo -u $SERVICE_USER zaur init${NC}"
    echo -e "Add AUR package: ${GREEN}sudo -u $SERVICE_USER zaur add aur/yay${NC}"
    echo -e "Build packages: ${GREEN}sudo -u $SERVICE_USER zaur build all${NC}"
    echo -e "List packages: ${GREEN}sudo -u $SERVICE_USER zaur list${NC}"
    echo
    echo -e "${BLUE}=== Web Interface ===${NC}"
    echo -e "Once started, ZAUR will be available at: ${GREEN}http://localhost:8080${NC}"
    echo -e "Configure pacman: Add to /etc/pacman.conf:"
    echo -e "${YELLOW}[zaur]${NC}"
    echo -e "${YELLOW}SigLevel = Optional TrustAll${NC}"
    echo -e "${YELLOW}Server = http://localhost:8080/${NC}"
    echo
}

# Main installation function
main() {
    echo -e "${BLUE}=== ZAUR Installer ===${NC}"
    echo "Installing ZAUR - Self-hosted AUR system"
    echo
    
    check_root
    check_arch
    install_dependencies
    build_zaur
    install_zaur
    setup_service
    initialize_zaur
    setup_firewall
    cleanup
    show_completion
}

# Run main function
main "$@"