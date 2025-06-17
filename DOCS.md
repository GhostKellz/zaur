# 📚 ZAUR Documentation

## 🛰️ Overview

ZAUR (Zig Arch User Repository) is a lightweight self-hosted AUR backend written in Zig. It provides:

* Your own local AUR mirror
* Easy `pacman` integration
* Optional GitHub auto-sync
* `aurutils` compatibility
* Optional NGINX reverse proxy support with HTTPS

## 🔧 Requirements

* Arch Linux server (or compatible)
* Zig v0.15+
* Git
* nginx (optional, for reverse proxy)
* acme.sh (optional, for HTTPS)

---

## 🚀 Running ZAUR

```bash
zaur serve --bind 10.6.0.10 --port 8080 --repo-dir /var/lib/zaur
```

This runs the service on your LAN at `http://10.6.0.10:8080`.

You can now add it as a repository in your `pacman.conf`:

```ini
[ghostctl]
SigLevel = Optional TrustAll
Server = http://10.6.0.10:8080/
```

---

## 🌐 NGINX Reverse Proxy (Remote or External LAN Host)

### Example setup: `/etc/nginx/sites-enabled/zaur.conf`

```nginx
server {
    listen 443 ssl;
    server_name aur.cktech.org;

    ssl_certificate     /etc/nginx/certs/cktech.org/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/cktech.org/privkey.pem;

    location / {
        proxy_pass http://10.6.0.10:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Restart nginx:

```bash
sudo systemctl reload nginx
```

### 🔒 TLS/ACME Integration

We recommend using [ghostcert](https://github.com/ghostkellz/ghostcert) to issue and manage certificates:

```bash
./ghostcert
```

This will issue a wildcard or domain-specific certificate via ACME, place it in the right directory, and reload NGINX.

---

## 🌐 Serving Directly from ZAUR with Built-In HTTP

If you're not using a reverse proxy, you can serve the repo directly:

```bash
zaur serve --port 8080 --repo-dir /var/lib/zaur
```

Then point Pacman directly to it:

```ini
[zaur]
SigLevel = Optional TrustAll
Server = http://10.6.0.10:8080/repo
```

---

## 🔄 Using as a Mirror

You can use `aurutils` or `repo-add` to keep ZAUR synced as a mirror:

```bash
zaur sync github.com/ghostkellz/your-pkgbuild-repo
zaur build --all
zaur refresh-index
```

You may want to automate this with a systemd timer or GitHub webhook in the future.

---

## 🔗 Helpful Files

* `pacman.conf` addition
* `/etc/nginx/sites-enabled/zaur.conf`
* `ghostcert` integration (see [ghostkellz/ghostcert](https://github.com/ghostkellz/ghostcert))
* `/etc/nginx/certs/cktech.org/` for SSL/TLS files

---

ZAUR makes it effortless to host and control your own secure Arch user repository – with the modern tooling you deserve 💡
