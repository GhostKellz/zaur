# Quickstart

This walks through a minimal local workflow: initialize ZAUR, add a source,
build it, publish the repository, and serve it to pacman.

## Workflow

```mermaid
flowchart LR
    init["zaur init"] --> add["zaur source add"]
    add --> build["zaur build run"]
    build --> publish["zaur repo publish"]
    publish --> serve["zaur serve"]
    serve --> pacman["pacman -Sy"]
```

## Prerequisites

- Arch Linux with `makepkg` and `repo-add` (from `pacman` / `base-devel`)
- Zig matching the `minimum_zig_version` in [`build.zig.zon`](../../build.zig.zon)

## Build and Initialize

```bash
git clone https://github.com/ghostkellz/zaur.git
cd zaur
zig build

./zig-out/bin/zaur init
```

`init` creates the data root (default `.zaur/`) and the ZQLite database. See
[Configuration](../guides/configuration.md) to change locations.

## Add a Source

```bash
# From the AUR
zaur source add aur/yay

# From GitHub
zaur source add github:user/repo

# From a local path
zaur source add local:/path/to/project

zaur source list
```

See [Sources](../guides/sources.md) for source kinds and generated PKGBUILDs.

## Build

```bash
# Build one package, or everything
zaur build run yay
zaur build run all

# Inspect a build log
zaur build logs yay
```

## Publish and Serve

```bash
# Generate the pacman repository databases
zaur repo publish

# Serve repositories over HTTP (default 127.0.0.1:9004)
zaur serve --port 9004
```

## Point pacman at ZAUR

Add to `/etc/pacman.conf`:

```ini
[custom]
SigLevel = Optional TrustAll
Server = http://localhost:9004/custom/
```

Then refresh:

```bash
sudo pacman -Sy
```

See [Repositories](../guides/repositories.md) for AUR vs custom repos and
GPG-signed databases, and [Deployment](../guides/deployment.md) for a
production setup.
