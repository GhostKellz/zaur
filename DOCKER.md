# 🐳 ZAUR Docker Deployment

Easy containerized deployment of ZAUR (Zig Arch User Repository) using Docker and Docker Compose.

## 🚀 Quick Start

### One-Command Deployment
```bash
./deploy.sh
```

### Manual Deployment
```bash
# Build and start
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f zaur
```

## ⚙️ Configuration

### Environment Variables
Set these in `docker-compose.yml` or as environment variables:

```yaml
environment:
  - ZAUR_BIND=0.0.0.0        # Bind address
  - ZAUR_PORT=8080           # Port to listen on
  - ZAUR_GPG_NAME=Your Name  # GPG key name
  - ZAUR_GPG_EMAIL=your@email.com  # GPG key email
```

### Persistent Data
Data is stored in the `zaur_data` volume, which maps to `./zaur-data/` directory:
- Package database (SQLite)
- Built packages (.pkg.tar.zst files)
- GPG keys
- Build logs

## 🔧 Usage

### Managing Packages
```bash
# Add packages
docker-compose exec zaur zaur add aur/yay
docker-compose exec zaur zaur add github:ghostkellz/my-package

# Build packages
docker-compose exec zaur zaur build all

# List packages
docker-compose exec zaur zaur list

# Check status
docker-compose exec zaur zaur status
```

### Repository Access
Once running, your repository is available at:
- **Local**: `http://localhost:8080`
- **LAN**: `http://YOUR_IP:8080`
- **API**: `http://localhost:8080/api/packages`

### Pacman Configuration
Add to `/etc/pacman.conf`:
```ini
[zaur]
SigLevel = Optional TrustAll
Server = http://YOUR_IP:8080/
```

Then update pacman:
```bash
sudo pacman -Sy
```

## 🌐 Nginx Integration

For your separate nginx server, use this upstream configuration:

```nginx
upstream zaur_backend {
    server YOUR_ZAUR_IP:8080;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name aur.cktech.org;
    
    ssl_certificate /etc/nginx/certs/cktech.org/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/cktech.org/privkey.pem;
    
    location / {
        proxy_pass http://zaur_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

## 🛠️ Development

### Building Custom Image
```bash
# Build with custom tag
docker build -t zaur:custom .

# Run with custom image
docker run -d -p 8080:8080 -v zaur_data:/var/lib/zaur zaur:custom
```

### Debugging
```bash
# Enter container shell
docker-compose exec zaur bash

# View detailed logs
docker-compose logs --tail=100 zaur

# Restart service
docker-compose restart zaur
```

## 📊 Monitoring

### Health Checks
The container includes automatic health checks:
```bash
# Check health status
docker-compose ps

# Manual health check
docker-compose exec zaur curl -f http://localhost:8080/api/packages
```

### Resource Usage
```bash
# View resource usage
docker stats zaur

# View disk usage
docker system df
```

## 🔒 Security

### Container Security
- Runs as non-root `zaur` user
- No new privileges allowed
- Resource limits configured
- Minimal attack surface

### GPG Signing
Packages are automatically signed with your GPG key:
```bash
# Check GPG setup
docker-compose exec zaur gpg --list-keys

# Manual GPG init
docker-compose exec zaur zaur gpg-init "Your Name" "your@email.com"
```

## 📝 Troubleshooting

### Common Issues

**Container won't start:**
```bash
docker-compose logs zaur
```

**Permission issues:**
```bash
sudo chown -R 1000:1000 ./zaur-data
```

**Database initialization fails:**
```bash
docker-compose exec zaur rm -f /var/lib/zaur/.initialized
docker-compose restart zaur
```

**Empty repository database:**
```bash
docker-compose exec zaur zaur init
docker-compose exec zaur repo-add /var/lib/zaur/GhostCTL/packages/zaur.db.tar.zst
```

### Cleanup
```bash
# Stop and remove containers
docker-compose down

# Remove data (WARNING: This deletes all packages!)
docker-compose down -v
sudo rm -rf ./zaur-data

# Remove images
docker rmi zaur_zaur
```

## 🚀 Production Deployment

For production use:

1. **Use specific image tags** instead of `latest`
2. **Set up proper backup** for `zaur-data` volume
3. **Configure log rotation** in docker-compose.yml
4. **Use secrets** for GPG key management
5. **Set up monitoring** with health checks
6. **Configure firewall** rules for port 8080

Example production docker-compose.yml:
```yaml
version: '3.8'
services:
  zaur:
    image: zaur:1.0.0
    restart: always
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '1.0'
```
