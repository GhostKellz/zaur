# ZAUR Documentation

ZAUR is a Zig-native AUR package builder and pacman repository server for Arch
Linux. It builds packages from AUR, GitHub, and local sources, publishes
pacman-compatible repositories, optionally mirrors official Arch repositories,
and applies supply-chain security gates around the build pipeline.

## Documentation Map

```mermaid
flowchart TD
    start["Start here<br/>docs/README.md"]

    start --> gs["Getting Started"]
    start --> guides["Guides"]
    start --> security["Security"]
    start --> api["API Reference"]
    start --> internals["Internals"]

    gs --> install["installation.md"]
    gs --> quick["quickstart.md"]

    guides --> config["configuration.md"]
    guides --> sources["sources.md"]
    guides --> repos["repositories.md"]
    guides --> mirror["mirror.md"]
    guides --> deploy["deployment.md"]

    security --> supply["supply-chain.md"]

    api --> http["http-api.md"]

    internals --> arch["architecture.md"]
```

## Runtime Shape

```mermaid
flowchart LR
    cli["zaur CLI"] --> core["ZAUR core"]
    pacman["pacman client"] --> http["HTTP server"]
    http --> core

    core --> sources["Source manager<br/>aur / github / local"]
    core --> builder["Build pipeline<br/>makepkg"]
    core --> repo["Repository publisher<br/>repo-add"]
    core --> mirror["Arch mirror cache"]
    core --> db[("ZQLite<br/>metadata + builds")]

    builder --> gates["Supply-chain gates"]
    gates --> scan["PKGBUILD scanner"]
    gates --> verify["Signed-commit trust"]
    gates --> pin["Checksum/ref pinning"]
    gates --> sandbox["Build isolation"]
```

## Build Pipeline Flow

```mermaid
flowchart TD
    add["source add"] --> fetch["Fetch PKGBUILD<br/>git / AUR"]
    fetch --> commit{"Signed-commit<br/>required?"}
    commit -->|"yes"| trust["Verify HEAD against trusted keys"]
    commit -->|"no"| scan
    trust --> scan["PKGBUILD static analysis"]
    scan --> policy{"ZAUR_SCAN_POLICY"}
    policy -->|"enforce + critical/high"| block["Build blocked"]
    policy -->|"warn / off / clean"| isolate["Apply ZAUR_BUILD_ISOLATION"]
    isolate --> makepkg["makepkg builds package"]
    makepkg --> publish["repo publish<br/>repo-add + optional GPG sign"]
    publish --> serve["HTTP server serves to pacman"]
```

## Getting Started

- [Installation](getting-started/installation.md) - Build from source, install the binary, and run as a systemd service.
- [Quickstart](getting-started/quickstart.md) - Initialize, add a source, build, publish, and serve locally.

## Guides

- [Configuration](guides/configuration.md) - Environment variables, data directories, and repository naming.
- [Sources](guides/sources.md) - AUR, GitHub, and local sources, plus generated PKGBUILDs for Zig and Rust projects.
- [Repositories](guides/repositories.md) - Publishing pacman databases, client configuration, and GPG signing.
- [Mirror](guides/mirror.md) - Caching official Arch repositories in metadata or on-demand mode.
- [Deployment](guides/deployment.md) - Docker Compose, nginx reverse proxy, and domain routing.

## Security

- [Supply-Chain Hardening](security/supply-chain.md) - PKGBUILD scanning, checksum/ref pinning, signed-commit trust, key management, and build isolation.

## API Reference

- [HTTP API](api/http-api.md) - Endpoints, authentication, and request requirements.

## Internals

- [Architecture](internals/architecture.md) - Module graph, build/request flows, and the supply-chain gate boundary.

## Quick Links

| Area | Path |
|------|------|
| Package metadata | [`../build.zig.zon`](../build.zig.zon) |
| Build script | [`../build.zig`](../build.zig) |
| Library exports | [`../src/root.zig`](../src/root.zig) |
| CLI entry point | [`../src/main.zig`](../src/main.zig) |
| Release notes | [`../CHANGELOG.md`](../CHANGELOG.md) |
| Security policy | [`../SECURITY.md`](../SECURITY.md) |
| Contributing | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |
