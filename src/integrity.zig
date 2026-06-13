//! Source integrity helpers: content checksums and git ref/commit pinning.
//!
//! Checksums use Zig's in-tree SHA-256 (no `sha256sum` subprocess). Git
//! operations shell out to `git` via the existing no-shell argv pattern so a
//! malicious source name can never be interpreted as a flag or command.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Maximum size we will hash from a single file (256 MiB). Sources larger than
/// this are unusual for a PKGBUILD tree and almost certainly a mistake.
const MAX_HASH_BYTES: usize = 256 * 1024 * 1024;

pub const HashError = error{ FileTooLarge, ReadFailed };

/// Lowercase hex encoding of a 32-byte digest.
pub fn hexDigest(digest: [Sha256.digest_length]u8) [Sha256.digest_length * 2]u8 {
    var out: [Sha256.digest_length * 2]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

/// SHA-256 of a file's contents. Caller owns the returned hex string.
pub fn sha256File(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(MAX_HASH_BYTES)) catch |err| {
        return switch (err) {
            error.StreamTooLong => HashError.FileTooLarge,
            else => HashError.ReadFailed,
        };
    };
    defer allocator.free(content);

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    const hex = hexDigest(digest);
    return allocator.dupe(u8, &hex);
}

/// SHA-256 over an in-memory buffer. Caller owns the returned hex string.
pub fn sha256Bytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = hexDigest(digest);
    return allocator.dupe(u8, &hex);
}

/// Maximum download size when hashing a remote source tarball (100 MiB),
/// matching mirror.zig's transfer cap.
const MAX_URL_BYTES: u64 = 100 * 1024 * 1024;

/// Download a URL and return the SHA-256 hex digest of its bytes, streaming so
/// the whole tarball never has to be buffered. Used to embed a real
/// `sha256sums=()` value in generated PKGBUILDs instead of `SKIP`. Caller owns
/// the returned hex string.
pub fn sha256Url(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.HttpRequestFailed;

    var transfer_buf: [65536]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var hasher = Sha256.init(.{});
    var total: u64 = 0;
    var chunk_buf: [65536]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
        if (total > MAX_URL_BYTES) return error.ResponseTooLarge;
        hasher.update(chunk_buf[0..n]);
    }
    if (total == 0) return error.EmptyResponse;

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = hexDigest(digest);
    return allocator.dupe(u8, &hex);
}

/// Resolve the current commit of a git checkout (`git -C <dir> rev-parse HEAD`).
/// Returns the trimmed 40-char SHA. Caller owns the returned string.
pub fn resolveGitHead(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo_dir, "rev-parse", "HEAD" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.GitRevParseFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

/// Check out a specific ref/commit/tag in an existing checkout, detaching HEAD.
/// Used to pin a source to a reproducible point (`git -C <dir> checkout <ref>`).
pub fn checkoutRef(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8, ref: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo_dir, "checkout", "--quiet", "--detach", ref },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.GitCheckoutFailed;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "sha256Bytes matches known vector" {
    const allocator = std.testing.allocator;
    // SHA-256("abc")
    const hex = try sha256Bytes(allocator, "abc");
    defer allocator.free(hex);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hex,
    );
}

test "sha256Bytes of empty input" {
    const allocator = std.testing.allocator;
    const hex = try sha256Bytes(allocator, "");
    defer allocator.free(hex);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hex,
    );
}

test "hexDigest encodes all bytes lowercase" {
    var digest: [Sha256.digest_length]u8 = undefined;
    @memset(&digest, 0xab);
    const hex = hexDigest(digest);
    for (hex) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    try std.testing.expectEqual(@as(usize, 64), hex.len);
}
