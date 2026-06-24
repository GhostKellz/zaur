# Installation

ZAUR is a single Zig binary plus standard Arch tooling. This covers building
from source and running it as a systemd service. For a quick local trial, see
the [Quickstart](quickstart.md).

## Prerequisites

- Arch Linux
- Zig matching the `minimum_zig_version` in [`build.zig.zon`](../../build.zig.zon)
- Runtime tools: `makepkg`, `repo-add`, `git`, and optionally `gpg`

```bash
sudo pacman -Sy --needed git base-devel pacman-contrib gnupg
```

ZAUR tracks a specific Zig **dev** build, so the stable `zig` package will not
satisfy it. Install the matching nightly from
[ziglang.org/download](https://ziglang.org/download/) (or a `zig-dev`-style
build) that meets the pinned `minimum_zig_version`.

## Build from Source

```bash
git clone https://github.com/ghostkellz/zaur.git
cd zaur
zig build -Doptimize=ReleaseSafe
```

The binary is produced at `zig-out/bin/zaur`.

## Install the Binary

```bash
sudo install -Dm755 zig-out/bin/zaur /usr/bin/zaur
sudo install -Dm644 LICENSE /usr/share/licenses/zaur/LICENSE
```

## Run as a systemd Service

```bash
# Dedicated service user and data directory
sudo useradd -r -s /bin/false -d /var/lib/zaur -m zaur

# Install the unit shipped in the repository
sudo install -Dm644 zaur.service /usr/lib/systemd/system/zaur.service
sudo systemctl daemon-reload

# Initialize data as the service user
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur init

# Start and enable
sudo systemctl enable --now zaur
systemctl status zaur
curl http://localhost:9004/api/health
```

The bundled unit applies systemd hardening (`NoNewPrivileges`, `ProtectSystem`,
and related sandboxing). ZAUR binds to `127.0.0.1:9004` by default; see
[Configuration](../guides/configuration.md) to change the bind address and port,
and [Deployment](../guides/deployment.md) to put it behind nginx.

## Managing the Service

```bash
# Operate on sources/builds as the service user
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur source add aur/yay
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur build run all
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur repo publish
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur source list

# Maintenance
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur status
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur backup
sudo -u zaur ZAUR_DATA_ROOT=/var/lib/zaur zaur clean 3   # keep 3 versions

# Follow logs
sudo journalctl -u zaur -f
```

## Uninstall

```bash
sudo systemctl disable --now zaur
sudo rm /usr/bin/zaur /usr/lib/systemd/system/zaur.service
sudo systemctl daemon-reload
sudo rm -rf /var/lib/zaur /usr/share/licenses/zaur
sudo userdel zaur
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Permission denied | Run commands as the `zaur` user with `ZAUR_DATA_ROOT` set |
| Build failures | `zaur build logs <package>` and AUR package status |
| Service won't start | `journalctl -u zaur` |
| Database errors | Re-run `zaur init` for the data root |
