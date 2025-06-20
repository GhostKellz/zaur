# Maintainer: GhostKellz <ghostkellz@example.com>
pkgname=zaur
pkgver=1.0.0
pkgrel=1
pkgdesc="A lightweight, Zig-native self-hosted AUR system for building and hosting Arch packages"
arch=('x86_64' 'aarch64')
url="https://github.com/ghostkellz/zaur"
license=('MIT')
depends=('sqlite' 'git' 'base-devel' 'pacman-contrib')
makedepends=('zig>=0.15.0')
provides=('zaur')
conflicts=('zaur-git')
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
    cd "$pkgname-$pkgver"
    
    # Build with Zig
    zig build -Doptimize=ReleaseSafe
}

check() {
    cd "$pkgname-$pkgver"
    
    # Run tests
    zig build test
}

package() {
    cd "$pkgname-$pkgver"
    
    # Install binary
    install -Dm755 zig-out/bin/zaur "$pkgdir/usr/bin/zaur"
    
    # Install documentation
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm644 DOCS.md "$pkgdir/usr/share/doc/$pkgname/DOCS.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    
    # Install systemd service file
    cat > zaur.service << EOF
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
    
    install -Dm644 zaur.service "$pkgdir/usr/lib/systemd/system/zaur.service"
    
    # Create sysusers configuration
    cat > zaur.sysusers << EOF
u zaur - "ZAUR service user" /var/lib/zaur /bin/nologin
EOF
    
    install -Dm644 zaur.sysusers "$pkgdir/usr/lib/sysusers.d/zaur.conf"
    
    # Create tmpfiles configuration for runtime directory
    cat > zaur.tmpfiles << EOF
d /var/lib/zaur 0755 zaur zaur -
d /var/lib/zaur/packages 0755 zaur zaur -
d /var/lib/zaur/build 0755 zaur zaur -
EOF
    
    install -Dm644 zaur.tmpfiles "$pkgdir/usr/lib/tmpfiles.d/zaur.conf"
}