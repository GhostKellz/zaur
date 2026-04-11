# Changelog

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
