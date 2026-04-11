const std = @import("std");

/// Pacman-compatible version comparison (vercmp)
///
/// Version format: [epoch:]pkgver[-pkgrel]
/// - epoch: optional integer prefix before ':'
/// - pkgver: main version string
/// - pkgrel: optional package release number after final '-'
///
/// Comparison rules:
/// 1. Compare epoch first (missing epoch = 0)
/// 2. Compare pkgver using alphanumeric segment comparison
/// 3. Compare pkgrel if pkgver is equal
///
/// Segment comparison:
/// - Split on transitions between digit/non-digit characters
/// - Numeric segments compared as integers
/// - Non-numeric segments compared lexicographically
/// - Empty segments are less than non-empty
pub fn vercmp(a: []const u8, b: []const u8) std.math.Order {
    // Extract epoch, pkgver, and pkgrel
    const a_parts = parseVersion(a);
    const b_parts = parseVersion(b);

    // Compare epoch first
    if (a_parts.epoch != b_parts.epoch) {
        return std.math.order(a_parts.epoch, b_parts.epoch);
    }

    // Compare pkgver
    const pkgver_cmp = compareVersionString(a_parts.pkgver, b_parts.pkgver);
    if (pkgver_cmp != .eq) {
        return pkgver_cmp;
    }

    // Compare pkgrel
    return compareVersionString(a_parts.pkgrel, b_parts.pkgrel);
}

const VersionParts = struct {
    epoch: u32,
    pkgver: []const u8,
    pkgrel: []const u8,
};

fn parseVersion(version: []const u8) VersionParts {
    var epoch: u32 = 0;
    var rest = version;

    // Extract epoch (before ':')
    if (std.mem.indexOf(u8, version, ":")) |colon_pos| {
        epoch = std.fmt.parseInt(u32, version[0..colon_pos], 10) catch 0;
        rest = version[colon_pos + 1 ..];
    }

    // Extract pkgrel (after last '-')
    var pkgver = rest;
    var pkgrel: []const u8 = "";

    if (std.mem.lastIndexOf(u8, rest, "-")) |dash_pos| {
        pkgver = rest[0..dash_pos];
        pkgrel = rest[dash_pos + 1 ..];
    }

    return .{
        .epoch = epoch,
        .pkgver = pkgver,
        .pkgrel = pkgrel,
    };
}

/// Compare two version strings using pacman's segment comparison rules
fn compareVersionString(a: []const u8, b: []const u8) std.math.Order {
    var a_pos: usize = 0;
    var b_pos: usize = 0;

    while (a_pos < a.len or b_pos < b.len) {
        // Skip non-alphanumeric separators
        while (a_pos < a.len and !std.ascii.isAlphanumeric(a[a_pos])) {
            a_pos += 1;
        }
        while (b_pos < b.len and !std.ascii.isAlphanumeric(b[b_pos])) {
            b_pos += 1;
        }

        // If both exhausted, equal
        if (a_pos >= a.len and b_pos >= b.len) {
            return .eq;
        }

        // If one exhausted, check remaining content type:
        // - Remaining ALPHABETIC = prerelease suffix = LESS than end (1.0rc < 1.0)
        // - Remaining NUMERIC = version increment = GREATER than end (1.0.1 > 1.0)
        if (a_pos >= a.len) {
            // b has more content - check if it starts with alpha (prerelease)
            if (std.ascii.isAlphabetic(b[b_pos])) {
                return .gt; // "1.0" > "1.0rc" (release beats prerelease)
            }
            return .lt; // "1.0" < "1.0.1" (shorter version)
        }
        if (b_pos >= b.len) {
            // a has more content - check if it starts with alpha (prerelease)
            if (std.ascii.isAlphabetic(a[a_pos])) {
                return .lt; // "1.0rc" < "1.0" (prerelease loses to release)
            }
            return .gt; // "1.0.1" > "1.0"
        }

        // Extract next segment (all digits or all non-digits)
        const a_seg = extractSegment(a[a_pos..]);
        const b_seg = extractSegment(b[b_pos..]);

        // Compare segments
        const cmp = compareSegments(a_seg.data, b_seg.data, a_seg.is_numeric, b_seg.is_numeric);
        if (cmp != .eq) {
            return cmp;
        }

        a_pos += a_seg.data.len;
        b_pos += b_seg.data.len;
    }

    return .eq;
}

const Segment = struct {
    data: []const u8,
    is_numeric: bool,
};

fn extractSegment(s: []const u8) Segment {
    if (s.len == 0) {
        return .{ .data = "", .is_numeric = false };
    }

    const is_numeric = std.ascii.isDigit(s[0]);
    var end: usize = 0;

    while (end < s.len) {
        const c = s[end];
        if (is_numeric) {
            if (!std.ascii.isDigit(c)) break;
        } else {
            if (!std.ascii.isAlphabetic(c)) break;
        }
        end += 1;
    }

    return .{
        .data = s[0..end],
        .is_numeric = is_numeric,
    };
}

fn compareSegments(a: []const u8, b: []const u8, a_numeric: bool, b_numeric: bool) std.math.Order {
    // Numeric segments always compare greater than alpha segments
    if (a_numeric and !b_numeric) return .gt;
    if (!a_numeric and b_numeric) return .lt;

    if (a_numeric and b_numeric) {
        // Both numeric - compare as integers
        // Skip leading zeros for comparison
        const a_trimmed = std.mem.trimStart(u8, a, "0");
        const b_trimmed = std.mem.trimStart(u8, b, "0");

        // Longer number (after trimming zeros) is greater
        if (a_trimmed.len != b_trimmed.len) {
            return std.math.order(a_trimmed.len, b_trimmed.len);
        }

        // Same length - lexicographic comparison works for equal-length numeric strings
        return std.mem.order(u8, a_trimmed, b_trimmed);
    }

    // Both alphabetic - lexicographic comparison
    return std.mem.order(u8, a, b);
}

// Tests

test "vercmp simple versions" {
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0", "2.0"));
    try std.testing.expectEqual(std.math.Order.gt, vercmp("2.0", "1.0"));
    try std.testing.expectEqual(std.math.Order.eq, vercmp("1.0", "1.0"));
}

test "vercmp multi-segment versions" {
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0.0", "1.0.1"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.9", "1.10"));
    try std.testing.expectEqual(std.math.Order.gt, vercmp("1.10", "1.9"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.2.3", "1.10.0"));
}

test "vercmp with pkgrel" {
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0-1", "1.0-2"));
    try std.testing.expectEqual(std.math.Order.gt, vercmp("1.0-10", "1.0-2"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0-1", "1.1-1"));
    try std.testing.expectEqual(std.math.Order.gt, vercmp("1.1-1", "1.0-2"));
}

test "vercmp with epoch" {
    try std.testing.expectEqual(std.math.Order.gt, vercmp("1:1.0", "2.0"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0", "1:0.5"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1:1.0", "2:0.1"));
    try std.testing.expectEqual(std.math.Order.eq, vercmp("0:1.0", "1.0"));
}

test "vercmp alphanumeric" {
    // Prerelease suffixes (alpha) are LESS than release versions
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0a", "1.0"));
    try std.testing.expectEqual(std.math.Order.gt, vercmp("1.0", "1.0a"));

    // Alpha comparison between prereleases
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0a", "1.0b"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0alpha", "1.0beta"));
}

test "vercmp prerelease" {
    // Pre-release versions are LESS than release versions
    // Pacman ordering: 1.0a < 1.0b < 1.0beta < 1.0rc < 1.0 < 1.0.1
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0rc1", "1.0"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0alpha", "1.0"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0beta", "1.0"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0rc", "1.0"));
}

test "vercmp complex real-world versions" {
    // Linux kernel versions
    try std.testing.expectEqual(std.math.Order.lt, vercmp("5.15.0", "5.15.1"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("5.15.0", "6.0.0"));

    // Package versions with arch suffix style
    try std.testing.expectEqual(std.math.Order.lt, vercmp("3.2.1", "3.2.2"));

    // Versions with letters
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.0a", "1.0b"));
    try std.testing.expectEqual(std.math.Order.gt, vercmp("1.0b", "1.0a"));
}

test "vercmp leading zeros" {
    try std.testing.expectEqual(std.math.Order.eq, vercmp("1.01", "1.1"));
    try std.testing.expectEqual(std.math.Order.eq, vercmp("1.001", "1.1"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1.01", "1.2"));
}

test "vercmp full format" {
    // epoch:pkgver-pkgrel
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1:2.3.4-5", "1:2.3.4-6"));
    try std.testing.expectEqual(std.math.Order.lt, vercmp("1:2.3.4-5", "2:1.0.0-1"));
    try std.testing.expectEqual(std.math.Order.gt, vercmp("2:1.0-1", "1:9.9.9-99"));
}
