# Changelog

## 0.1.4 (2026-06-10)

### Added — Supply-Chain Security Hardening
- **PKGBUILD static analysis** (`src/scanner.zig`): heuristic scanner flags pipe-to-shell, reverse shells, base64/eval obfuscation, setuid, writes to `~/.ssh`/`/etc`/crontab/systemd, network fetches inside build functions, and disabled checksums. Findings are severity-scored (critical/high/medium/low/info).
  - Policy gate via `ZAUR_SCAN_POLICY` (`off` | `warn` | `enforce`, default `warn`). `enforce` blocks builds on any critical/high finding before `makepkg` runs.
  - `zaur security scan-pkgbuild <source>` and `POST /api/security/scan-pkgbuild` persist findings; `GET /api/security/findings` exposes them.
- **Source integrity + checksum pinning** (`src/integrity.zig`): SHA-256 of fetched sources and tarballs via streaming `std.crypto`, no `sha256sum` subprocess. Generated Zig/Rust PKGBUILDs now embed real `sha256sums=(...)` instead of `SKIP` (falls back to `SKIP` only when download fails). New `sources` columns `source_hash`, `pinned_ref`, `resolved_commit`, `require_signed_commit`.
  - Git sources record their resolved HEAD commit on add/update; drift is logged. `zaur security pin <source> [ref]` / `unpin <source>` pin a reproducible ref (`ZAUR_CHECKSUM_PINNING`, default `true`).
- **Signed-commit verification + GPG key pinning** (`src/gpg.zig`): `git verify-commit` parsing distinguishes unsigned / bad-sig / good-but-untrusted / good. `trusted_keys` allowlist with `zaur security trust-key <fpr> [note]`, `list-keys`, `untrust-key <fpr>` and `GET/POST/DELETE /api/security/keys`. `zaur security verify-commit <source>` reports trust status (`ZAUR_REQUIRE_SIGNED_COMMITS`, default `false`).
  - Published repo databases are detached-signed (`<repo>.db.tar.zst.sig`) when a GPG key is configured, so pacman clients with `SigLevel = Required` can verify.
- **Configurable build isolation** (`src/sandbox.zig`): `ZAUR_BUILD_ISOLATION` selects `none` (default), `chroot` (devtools `makechrootpkg`), or `container` (`podman`/`docker`). Per-build override via `zaur build <pkg> --isolation=chroot|container|none`. Configurable through `ZAUR_CONTAINER_RUNTIME`, `ZAUR_CONTAINER_IMAGE`, `ZAUR_CHROOT_DIR`. Backends degrade gracefully when tooling is absent.

### Changed
- Database schema bumped to v3 with additive migration (`trusted_keys`, `pkgbuild_scan_findings` tables; new `sources` columns) — existing rows preserved.
- Build pipeline now runs two pre-`makepkg` gates: a signed-commit trust check (when required globally or per-source) followed by the static-analysis policy gate.
- `PackageBuilder.init` takes an optional `*Database` handle to drive the signed-commit trust gate.
- Repo database publishing (`zaur repo publish` and `POST /api/repos/publish`) detached-signs the generated `*.db.tar.zst` when a GPG key is configured.
- Bumped the `zqlite` dependency to `v1.6.7`, which fixes `ON CONFLICT DO UPDATE SET col = excluded.col` — required by the new `trusted_keys` upsert path (`security trust-key` and `POST /api/security/keys`).

### CLI
- New `zaur security` subcommands: `scan-pkgbuild`, `verify-commit`, `trust-key`, `untrust-key`, `list-keys`, `pin`, `unpin`.
- `zaur build <pkg> --isolation=none|chroot|container` per-build isolation override.

### API
- `GET /api/security/findings` (public), `POST /api/security/scan-pkgbuild` (auth).
- `GET/POST/DELETE /api/security/keys` (auth) for trusted-key management.
- `POST /api/security/pin` (auth) for source ref pinning.

### Tests
- Scanner rule coverage (pipe-to-shell, reverse shell, obfuscation, sensitive-path writes) and clean-PKGBUILD negative cases.
- Integrity SHA-256 vectors and hex-digest correctness.
- Config parsing for `BuildIsolation`/`ScanPolicy` enums and boolean env helpers.
- Full suite: 71 tests passing on Zig `0.17.0-dev.813`.
- Docker harness (`docker/run-tests.sh`) covers `build`, `full` (16/16 HTTP/API), `security` (12/12 CLI + API), and `memory` (Valgrind, no definite leaks) on an Arch container.
- `docker/scripts/test-memory.sh` now builds the audited binary with `-Dcpu=x86_64_v2` so Valgrind can execute it (native AVX-512/newer opcodes previously SIGILL'd in TLS setup before `main`).

### Docs
- `SECURITY.md` gains a "Supply-Chain Hardening" section covering all four controls.
- `docs/configuration.md` documents the new `ZAUR_SCAN_POLICY`, `ZAUR_CHECKSUM_PINNING`, `ZAUR_REQUIRE_SIGNED_COMMITS`, `ZAUR_BUILD_ISOLATION`, `ZAUR_CONTAINER_RUNTIME`, `ZAUR_CONTAINER_IMAGE`, and `ZAUR_CHROOT_DIR` variables plus the new API endpoints.
- README adds a Supply-Chain Security badge and corrects the database badge to ZQLite.

## 0.1.3 (2026-04-11)

### Fixed
- **Thread Safety**: Fixed critical bug where `serveRepoFile()`, `serveMirrorFile()`, and `apiDeleteSource()` called shared `threaded_io.io()` from worker threads. Each thread now receives its own I/O context through the handler call chain.
- **Version Comparison**: Fixed prerelease ordering to match pacman behavior (`1.0rc1 < 1.0`, `1.0a < 1.0`). Alphabetic suffixes now correctly sort as prereleases.
- **JSON Escaping**: Security advisories API now escapes `affected_version` and `fixed_version` fields. Mirror status API escapes upstream URL and repo names.
- **CORS on Errors**: All API error responses now include CORS headers when `ZAUR_CORS_ORIGIN` is configured. Added `jsonErrorWithCors()` method replacing standalone `jsonError()` for API paths.
- **Source Add Atomicity**: `addSource()` now preserves existing checkout until new download succeeds (backup → swap → cleanup pattern). Failed fetches no longer destroy existing source data.

### Changed
- Route handler signature now includes `io: std.Io` parameter for thread-local I/O context
- Concurrency model documented in `src/database.zig`: single SQLite connection with application-level spinlock (safe-but-serialized v1 design)

### Tests
- Integration test 16 now runs 3 rounds of 15 concurrent mixed requests covering `/api/health`, `/api/status`, `/api/packages`, `/api/sources`, and authenticated `POST /api/builds`
- Test failures now output actual response content for debugging
- CORS tests verify exact header values, not just presence

## 0.1.2 (2026-04-11)

### Added
- `zaur backup` and `zaur restore` commands for database backup/recovery
- `zaur.service` systemd unit file with security hardening
- `pkg/PKGBUILD` for Arch package installation
- `install.sh` script for manual installation
- GPG package signing support via `ZAUR_GPG_KEY` environment variable
- CORS configuration via `ZAUR_CORS_ORIGIN` environment variable
- 43 regression tests covering path validation, JSON escaping, source parsing, PKGBUILD generation

### Changed
- API endpoints now require `Content-Type: application/json` for POST requests (returns 415 otherwise)
- Malformed JSON on POST requests returns 400 instead of falling back to defaults
- Mirror status reporting now uses filesystem/database state, not in-memory cache
- Static repo path validation rejects traversal attempts, empty segments, and backslashes
- Docker deployment uses latest Zig 0.16-dev (auto-fetched from ziglang.org)
- Removed wildcard CORS by default

### Fixed
- GPG temp files now use secure random names instead of predictable PID-based names
- Memory leak in ZigBuilder PKGBUILD generation
- Source deletion returns proper 404/409 errors instead of generic failures
- Error messages in JSON responses are now properly escaped

## 0.1.1 (2026-04-09)

### Added
- ZQLite integration for package metadata storage
- Mirror support for caching official Arch repositories
- Zig and Rust PKGBUILD generators
- HTTP API for package management

### Changed
- Updated for Zig 0.16.0-dev compatibility

## 0.1.0 (Initial)

- AUR package fetching and building
- Repository database generation
- HTTP server for pacman clients
- Source management (AUR, GitHub, git, local)
