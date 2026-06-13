const std = @import("std");
const Config = @import("config.zig").Config;

pub const GpgSigner = struct {
    allocator: std.mem.Allocator,
    threaded_io: std.Io.Threaded,
    gpg_key_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, config: ?*const Config) GpgSigner {
        // Load GPG key from config if available
        const key_id: ?[]const u8 = if (config) |cfg| cfg.gpg_key_id else null;

        return GpgSigner{
            .allocator = allocator,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
            .gpg_key_id = key_id,
        };
    }

    pub fn deinit(self: *GpgSigner) void {
        self.threaded_io.deinit();
    }

    pub fn signPackage(self: *GpgSigner, package_path: []const u8) !void {
        const key_id = self.gpg_key_id orelse {
            std.debug.print("No GPG key configured. Set ZAUR_GPG_KEY environment variable to enable signing.\n", .{});
            return;
        };

        const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{package_path});
        defer self.allocator.free(sig_path);

        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{
                "gpg",
                "--detach-sign",
                "--use-agent",
                "--no-armor",
                "--local-user",
                key_id,
                package_path,
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0) {
            std.debug.print("Signed package: {s}\n", .{package_path});
        } else {
            std.debug.print("Failed to sign package: {s}\nStderr: {s}\n", .{ package_path, result.stderr });
            return error.GpgSigningFailed;
        }
    }

    pub fn initializeGpgKey(self: *GpgSigner, key_name: []const u8, key_email: []const u8) !void {
        std.debug.print("Generating GPG key for ZAUR...\n", .{});

        const io = self.threaded_io.io();

        // Create batch content for GPG key generation
        const batch_content = try std.fmt.allocPrint(self.allocator,
            \\Key-Type: RSA
            \\Key-Length: 4096
            \\Subkey-Type: RSA
            \\Subkey-Length: 4096
            \\Name-Real: {s}
            \\Name-Email: {s}
            \\Expire-Date: 2y
            \\%commit
        , .{ key_name, key_email });
        defer self.allocator.free(batch_content);

        const temp_name = try createSecureBatchFile(self.allocator, io, batch_content);
        defer self.allocator.free(temp_name);
        defer std.Io.Dir.deleteFile(.cwd(), io, temp_name) catch {};

        // Generate key using batch file
        const result = try std.process.run(self.allocator, io, .{
            .argv = &.{ "gpg", "--batch", "--gen-key", temp_name },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0) {
            std.debug.print("GPG key generated successfully.\n", .{});
            std.debug.print("Export your public key: gpg --armor --export {s}\n", .{key_email});
            std.debug.print("Set ZAUR_GPG_KEY environment variable to enable signing.\n", .{});
        } else {
            std.debug.print("GPG key generation failed:\n{s}\n", .{result.stderr});
            return error.GpgKeyGenerationFailed;
        }
    }

    pub fn verifyPackageSignature(self: *GpgSigner, package_path: []const u8) !bool {
        const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{package_path});
        defer self.allocator.free(sig_path);

        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{
                "gpg",
                "--verify",
                sig_path,
                package_path,
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return result.term == .exited and result.term.exited == 0;
    }

    pub fn listKeys(self: *GpgSigner) ![]const u8 {
        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{ "gpg", "--list-keys", "--keyid-format", "long" },
        });
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0) {
            return result.stdout;
        } else {
            self.allocator.free(result.stdout);
            return error.GpgListKeysFailed;
        }
    }

    /// Detached-sign the published repository database so clients can verify it
    /// (`<repo>.db.sig`). Reuses the same key + agent flow as `signPackage`.
    pub fn signRepoDb(self: *GpgSigner, db_path: []const u8) !void {
        try self.signPackage(db_path);
    }

    /// Verify the GPG signature on a git commit. Runs
    /// `git -C <repo_dir> verify-commit --raw <ref>` and parses the machine-
    /// readable status from stderr. The caller owns `result.fingerprint`.
    pub fn verifyGitCommit(self: *GpgSigner, repo_dir: []const u8, ref: []const u8) !CommitVerification {
        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{ "git", "-C", repo_dir, "verify-commit", "--raw", ref },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // git relays gpg's `[GNUPG:] ...` status lines on stderr.
        const status = parseGpgStatus(result.stderr);
        const fingerprint = if (extractValidSigFingerprint(result.stderr)) |fpr|
            try self.allocator.dupe(u8, fpr)
        else
            null;

        const signed = status == .good or status == .good_untrusted or status == .expired_key;
        return CommitVerification{
            .signed = signed,
            .status = status,
            .fingerprint = fingerprint,
        };
    }
};

pub const CommitStatus = enum {
    /// No signature present on the commit.
    unsigned,
    /// Valid signature from a key gpg already trusts.
    good,
    /// Valid signature, but the signing key is not in gpg's web-of-trust.
    good_untrusted,
    /// Signature present but cryptographically bad.
    bad,
    /// Otherwise-valid signature from an expired key.
    expired_key,

    pub fn asString(self: CommitStatus) []const u8 {
        return switch (self) {
            .unsigned => "unsigned",
            .good => "good",
            .good_untrusted => "good-untrusted",
            .bad => "bad",
            .expired_key => "expired-key",
        };
    }
};

pub const CommitVerification = struct {
    signed: bool,
    status: CommitStatus,
    /// 40-char primary-key fingerprint of the signer, if a valid signature was
    /// found. Owned by the caller.
    fingerprint: ?[]const u8,

    pub fn deinit(self: CommitVerification, allocator: std.mem.Allocator) void {
        if (self.fingerprint) |fpr| allocator.free(fpr);
    }
};

/// Map gpg `[GNUPG:]` status lines to a CommitStatus. Precedence favours the
/// most security-relevant outcome (bad signature beats a good one).
fn parseGpgStatus(stderr: []const u8) CommitStatus {
    if (std.mem.indexOf(u8, stderr, "[GNUPG:] BADSIG") != null) return .bad;
    if (std.mem.indexOf(u8, stderr, "[GNUPG:] ERRSIG") != null) return .bad;
    if (std.mem.indexOf(u8, stderr, "[GNUPG:] EXPKEYSIG") != null) return .expired_key;
    if (std.mem.indexOf(u8, stderr, "[GNUPG:] GOODSIG") != null or
        std.mem.indexOf(u8, stderr, "[GNUPG:] VALIDSIG") != null)
    {
        // TRUST_ULTIMATE/TRUST_FULLY means gpg trusts the key directly.
        if (std.mem.indexOf(u8, stderr, "[GNUPG:] TRUST_ULTIMATE") != null or
            std.mem.indexOf(u8, stderr, "[GNUPG:] TRUST_FULLY") != null)
            return .good;
        return .good_untrusted;
    }
    return .unsigned;
}

/// Extract the primary-key fingerprint from a `[GNUPG:] VALIDSIG` status line.
/// The VALIDSIG format places the primary-key fingerprint as the final field;
/// we conservatively return the first 40-char hex token on the line.
fn extractValidSigFingerprint(stderr: []const u8) ?[]const u8 {
    const marker = "[GNUPG:] VALIDSIG ";
    const start = std.mem.indexOf(u8, stderr, marker) orelse return null;
    const rest = stderr[start + marker.len ..];
    var it = std.mem.tokenizeAny(u8, rest, " \t\r\n");
    while (it.next()) |tok| {
        if (tok.len == 40 and isHex(tok)) return tok;
    }
    return null;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn createSecureBatchFile(allocator: std.mem.Allocator, io: std.Io, content: []const u8) ![]const u8 {
    var random_bytes: [16]u8 = undefined;
    var seed_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer seed_io.deinit();
    const seed_ts = std.Io.Timestamp.now(seed_io.io(), .real);
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(u64, @intCast(seed_ts.nanoseconds))));
    const random = prng.random();

    while (true) {
        random.bytes(&random_bytes);
        const hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try std.fmt.allocPrint(allocator, "/tmp/zaur_gpg_{s}.batch", .{hex});
        errdefer allocator.free(path);

        var file = std.Io.Dir.createFileAbsolute(io, path, .{
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        defer file.close(io);

        try file.writeStreamingAll(io, content);
        return path;
    }
}
