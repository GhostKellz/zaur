# Architecture

This document describes ZAUR's module layout, the build and request paths, and
the supply-chain gate boundary.

## High-Level Overview

```mermaid
flowchart TD
    cli["CLI<br/>main.zig"] --> lib["Library exports<br/>root.zig"]
    http["HTTP server<br/>server.zig"] --> lib

    lib --> config["config.zig<br/>environment config"]
    lib --> source["source.zig<br/>source specs + checkout"]
    lib --> builder["builder.zig<br/>makepkg pipeline"]
    lib --> repo["repo.zig<br/>repo-add publishing"]
    lib --> mirror["mirror.zig<br/>Arch mirror cache"]
    lib --> security["security.zig<br/>advisories + status"]
    lib --> db["database.zig<br/>ZQLite access"]

    source --> aur["aur.zig<br/>AUR RPC client"]
    source --> zigb["zigbuilder.zig"]
    source --> rustb["rustbuilder.zig"]
    builder --> deps["deps.zig<br/>dependency resolution"]

    builder --> scanner["scanner.zig"]
    builder --> integrity["integrity.zig"]
    builder --> gpg["gpg.zig"]
    builder --> sandbox["sandbox.zig"]

    db --> zqlite[("ZQLite")]
```

## Source Layout

```text
src/
├── main.zig          # CLI entry point and command dispatch
├── root.zig          # Public library exports
├── config.zig        # Environment-variable configuration
├── database.zig      # ZQLite schema, migrations, metadata, build records
├── source.zig        # Source specs (aur/github/local) and checkout
├── aur.zig           # AUR RPC client
├── builder.zig       # makepkg build pipeline and gate orchestration
├── deps.zig          # Dependency resolution
├── repo.zig          # pacman repository database generation (repo-add)
├── mirror.zig        # Official Arch repository mirroring/caching
├── server.zig        # HTTP server, REST API, and file serving
├── security.zig      # Advisory sync and per-package security status
├── scanner.zig       # PKGBUILD static analysis
├── integrity.zig     # SHA-256 hashing and checksum/ref pinning
├── gpg.zig           # Signed-commit verification and package signing
├── sandbox.zig       # Build isolation backends (chroot/container)
├── zigbuilder.zig    # PKGBUILD generation for Zig projects
├── rustbuilder.zig   # PKGBUILD generation for Rust projects
└── version.zig       # pacman-compatible version comparison (vercmp)
```

## Build Pipeline

```mermaid
sequenceDiagram
    participant CLI as CLI / API
    participant Src as Source manager
    participant Gate as Supply-chain gates
    participant Make as makepkg
    participant Repo as Repository publisher
    participant DB as ZQLite

    CLI->>Src: build run <package>
    Src->>Src: fetch/checkout PKGBUILD
    Src->>Gate: signed-commit trust check
    Gate->>Gate: PKGBUILD static analysis
    Gate-->>CLI: block on enforced critical/high finding
    Gate->>Make: apply build isolation, run makepkg
    Make->>Repo: built package artifact
    Repo->>Repo: repo-add (+ optional GPG sign)
    Repo->>DB: record package + build result
    DB-->>CLI: status
```

## Request Flow

```mermaid
sequenceDiagram
    participant Client as pacman / API client
    participant Server as HTTP server
    participant Auth as Auth check
    participant Core as ZAUR core
    participant FS as Repo / mirror files

    Client->>Server: GET/POST request
    Server->>Auth: protected endpoint?
    Auth-->>Client: 401 when token missing/invalid
    Auth->>Core: authorized request
    Core->>FS: read repo/mirror artifacts
    FS-->>Core: file or metadata
    Core-->>Client: JSON or package/database bytes
```

Each accepted TCP connection is handled on its own thread with an independent
`std.Io.Threaded` context; the database is guarded by a process-level mutex.

## Supply-Chain Gate Boundary

```mermaid
flowchart TD
    request["Build requested"] --> signed{"Signed commit required?"}
    signed -->|"yes"| trust{"HEAD signed by trusted key?"}
    signed -->|"no"| scan
    trust -->|"no"| reject["Reject build"]
    trust -->|"yes"| scan["PKGBUILD static analysis"]

    scan --> findings{"Critical/high findings?"}
    findings -->|"yes + enforce"| reject
    findings -->|"warn / none"| pin["Embed sha256sums + record commit"]

    pin --> isolation{"ZAUR_BUILD_ISOLATION"}
    isolation -->|"none"| host["Build on host"]
    isolation -->|"chroot"| chroot["makechrootpkg"]
    isolation -->|"container"| container["podman/docker"]

    host --> sign["Optional GPG package + DB signing"]
    chroot --> sign
    container --> sign
```

## Data Model

ZAUR persists metadata in a single ZQLite database (`zaur.db`). The schema is
created on `init` and evolved through additive migrations. It tracks sources,
packages, build records, trusted GPG keys, PKGBUILD scan findings, source pins,
and synced security advisories. Published repository databases
(`aur.db.tar.zst`, `custom.db.tar.zst`) are generated separately by `repo-add`
and served directly to pacman clients.

## External Tooling

ZAUR shells out to standard Arch tooling rather than reimplementing it:
`makepkg` (builds), `repo-add` (repository databases), `git` (source checkout),
`gpg` (signing/verification), and `tar` (mirror database extraction). See
[Configuration](../guides/configuration.md#external-tool-dependencies) for the
full list.
