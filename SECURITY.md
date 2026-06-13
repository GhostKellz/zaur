# Security Policy

## Status

ZAUR is under active development. Security hardening has been applied to path validation, API input handling, and GPG operations.

## Supply-Chain Hardening

ZAUR includes defense-in-depth controls against the AUR/source-compromise threat class. These are layered mitigations, not guarantees; the static scanner in particular is heuristic and should be paired with the `enforce` gate and signed-commit verification for stronger assurance.

### PKGBUILD static analysis

Heuristic scanning of `PKGBUILD`, `*.install`, `.SRCINFO`, and top-level shell scripts flags patterns such as pipe-to-shell, reverse shells, base64/eval obfuscation, setuid, writes to sensitive paths (`~/.ssh`, `/etc`, crontab, systemd units), undeclared network fetches inside build functions, and disabled checksums. Findings are severity-scored.

- `ZAUR_SCAN_POLICY=off|warn|enforce` (default `warn`). `enforce` blocks a build on any critical/high finding before `makepkg` runs.
- `zaur security scan-pkgbuild <source>` — scan and persist findings.

### Source integrity and checksum pinning

Fetched sources and generated-PKGBUILD tarballs are hashed with streamed SHA-256 (no `sha256sum` subprocess). Generated Zig/Rust PKGBUILDs embed the computed `sha256sums` rather than `SKIP`. Git sources record their resolved HEAD commit; drift is logged and pinned refs are enforced.

- `ZAUR_CHECKSUM_PINNING=true|false` (default `true`).
- `zaur security pin <source> [ref]` / `zaur security unpin <source>`.

### Signed-commit verification and key pinning

Git source HEAD commits can be verified with `git verify-commit`, distinguishing unsigned / bad-signature / good-but-untrusted / good. A `trusted_keys` allowlist gates which fingerprints are accepted. Published repository databases are detached-signed when a GPG key is configured.

- `ZAUR_REQUIRE_SIGNED_COMMITS=true|false` (default `false`).
- `zaur security verify-commit <source>`, `zaur security trust-key <fpr> [note]`, `list-keys`, `untrust-key <fpr>`.

### Build isolation

Builds can run in an isolated backend selected by `ZAUR_BUILD_ISOLATION`:

- `none` (default) — `makepkg` in the build workspace.
- `chroot` — devtools `makechrootpkg` against a clean chroot (`ZAUR_CHROOT_DIR`).
- `container` — `podman`/`docker` (`ZAUR_CONTAINER_RUNTIME`) using `ZAUR_CONTAINER_IMAGE`.

Per-build override: `zaur build <pkg> --isolation=chroot|container|none`. Backends degrade gracefully when the required tooling is absent.

## Supported Versions

Security support currently applies to the active main branch while the project is being stabilized.

## Reporting A Vulnerability

Please do not open a public issue for security-sensitive problems.

Report vulnerabilities privately to the maintainer through the project's preferred private contact channel. Include:

- a clear description of the issue
- affected commit or branch information
- reproduction steps if available
- impact assessment
- any suggested mitigation

## Scope

Security issues may include:

- authentication or authorization bypass
- unsafe package source handling
- command injection or shell injection
- archive extraction issues
- path traversal in file serving or build paths
- secrets exposure
- signature verification or signing workflow flaws
- container or deployment misconfiguration with security impact

## Response Expectations

Reports will be triaged and validated before a fix timeline is communicated. Coordinated disclosure is preferred.
