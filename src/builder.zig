const std = @import("std");
const SourceManager = @import("source.zig");
const Config = @import("config.zig").Config;
const scanner = @import("scanner.zig");
const sandbox = @import("sandbox.zig");
const ScanPolicy = @import("config.zig").ScanPolicy;
const Database = @import("database.zig").Database;
const GpgSigner = @import("gpg.zig").GpgSigner;

pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    source_root: []const u8,
    build_root: []const u8,
    output_dir: []const u8,
    config: ?*const Config,
    /// Optional DB handle used for the signed-commit trust gate. When null the
    /// gate is skipped (e.g. ad-hoc builds without a database context).
    database: ?*Database,
    threaded_io: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, source_root: []const u8, build_root: []const u8, output_dir: []const u8, config: ?*const Config, database: ?*Database) PackageBuilder {
        return PackageBuilder{
            .allocator = allocator,
            .source_root = source_root,
            .build_root = build_root,
            .output_dir = output_dir,
            .config = config,
            .database = database,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
        };
    }

    pub fn deinit(self: *PackageBuilder) void {
        self.threaded_io.deinit();
    }

    pub fn buildPackage(self: *PackageBuilder, package_name: []const u8) !BuildResult {
        const source_dir = try std.fs.path.join(self.allocator, &.{ self.source_root, package_name });
        defer self.allocator.free(source_dir);

        const package_dir = try std.fs.path.join(self.allocator, &.{ self.build_root, package_name });
        defer self.allocator.free(package_dir);

        try prepareWorkspace(self, source_dir, package_dir);

        // Check if PKGBUILD exists
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ package_dir, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);

        std.Io.Dir.accessAbsolute(self.threaded_io.io(), pkgbuild_path, .{}) catch {
            return BuildResult{
                .success = false,
                .log = try self.allocator.dupe(u8, "PKGBUILD not found"),
            };
        };

        // Signed-commit gate: when the source (or global policy) requires a
        // signed commit, verify HEAD against the trusted-key allowlist before
        // doing any work. Operates on the original checkout (which retains .git).
        if (try self.commitGate(package_name, source_dir)) |blocked_log| {
            return BuildResult{ .success = false, .log = blocked_log };
        }

        // Static-analysis gate: scan the prepared tree before running any
        // attacker-controlled makepkg logic. Policy decides whether findings
        // merely warn or hard-block the build.
        if (try self.scanGate(package_dir)) |blocked_log| {
            return BuildResult{ .success = false, .log = blocked_log };
        }

        // Create output directory if it doesn't exist
        try std.Io.Dir.createDirPath(.cwd(), self.threaded_io.io(), self.output_dir);

        const sb = try sandbox.runBuild(self.allocator, self.threaded_io.io(), .{
            .package_dir = package_dir,
            .config = self.config,
        });

        // Move built packages to output directory
        if (sb.success) {
            try self.moveBuiltPackages(package_dir);
        }

        return BuildResult{
            .success = sb.success,
            .log = sb.log,
        };
    }

    /// Run the PKGBUILD scanner and apply the configured policy. Returns a
    /// non-null owned log string when the build must be blocked (enforce policy
    /// with critical/high findings); returns null to proceed.
    fn scanGate(self: *PackageBuilder, package_dir: []const u8) !?[]u8 {
        const policy: ScanPolicy = if (self.config) |c| c.scan_policy else .warn;
        if (policy == .off) return null;

        const findings = try scanner.scanSourceTree(self.allocator, self.threaded_io.io(), package_dir);
        defer {
            for (findings) |f| f.deinit(self.allocator);
            self.allocator.free(findings);
        }

        if (findings.len == 0) return null;

        for (findings) |f| {
            std.debug.print("[scan:{s}] {s}:{d} {s} — {s}\n", .{ f.severity.asString(), f.file_name, f.line_no, f.rule_id, f.message });
        }

        if (policy == .enforce and scanner.shouldBlock(findings)) {
            return try std.fmt.allocPrint(self.allocator, "Build blocked by scan policy: {d} finding(s), highest severity {s}. Set ZAUR_SCAN_POLICY=warn to override.", .{ findings.len, if (scanner.maxSeverity(findings)) |s| s.asString() else "none" });
        }
        return null;
    }

    /// Enforce signed-commit policy. Returns an owned block message when the
    /// build must be refused, or null to proceed. Required when the global
    /// `require_signed_commits` is set or the source row opts in. When a
    /// trusted-key allowlist exists the signer fingerprint must be on it;
    /// otherwise any valid signature is accepted.
    fn commitGate(self: *PackageBuilder, package_name: []const u8, source_dir: []const u8) !?[]u8 {
        const config = self.config orelse return null;
        const db = self.database orelse return null;

        var required = config.require_signed_commits;
        if (!required) {
            if (db.getSourcePin(self.allocator, package_name) catch null) |pin| {
                defer pin.deinit(self.allocator);
                if (pin.require_signed_commit) required = true;
            }
        }
        if (!required) return null;

        // Only git checkouts carry a verifiable commit.
        const git_dir = try std.fs.path.join(self.allocator, &.{ source_dir, ".git" });
        defer self.allocator.free(git_dir);
        std.Io.Dir.accessAbsolute(self.threaded_io.io(), git_dir, .{}) catch {
            return try std.fmt.allocPrint(self.allocator, "Build blocked: source {s} requires a signed commit but has no git history to verify.", .{package_name});
        };

        var signer = GpgSigner.init(self.allocator, self.config);
        defer signer.deinit();
        const v = signer.verifyGitCommit(source_dir, "HEAD") catch |err| {
            return try std.fmt.allocPrint(self.allocator, "Build blocked: could not verify commit signature for {s}: {}", .{ package_name, err });
        };
        defer v.deinit(self.allocator);

        if (!v.signed) {
            return try std.fmt.allocPrint(self.allocator, "Build blocked: HEAD commit of {s} is not signed (status: {s}).", .{ package_name, v.status.asString() });
        }

        // Signature present — enforce the trust allowlist when one is configured.
        const trusted_count = db.trustedKeyCount() catch 0;
        if (trusted_count > 0) {
            const fpr = v.fingerprint orelse return try std.fmt.allocPrint(self.allocator, "Build blocked: signed commit of {s} has no extractable fingerprint to match against trusted keys.", .{package_name});
            const trusted = db.isKeyTrusted(fpr) catch false;
            if (!trusted) {
                return try std.fmt.allocPrint(self.allocator, "Build blocked: commit of {s} signed by untrusted key {s}. Trust it with: zaur security trust-key {s}", .{ package_name, fpr, fpr });
            }
        }
        return null;
    }

    fn moveBuiltPackages(self: *PackageBuilder, package_dir: []const u8) !void {
        var dir = try std.Io.Dir.openDirAbsolute(self.threaded_io.io(), package_dir, .{ .iterate = true });
        defer dir.close(self.threaded_io.io());

        var iterator = dir.iterate();
        while (try iterator.next(self.threaded_io.io())) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                const src_path = try std.fs.path.join(self.allocator, &.{ package_dir, entry.name });
                defer self.allocator.free(src_path);

                const dst_path = try std.fs.path.join(self.allocator, &.{ self.output_dir, entry.name });
                defer self.allocator.free(dst_path);

                try std.Io.Dir.copyFileAbsolute(src_path, dst_path, self.threaded_io.io(), .{});
                std.debug.print("Moved package: {s}\n", .{entry.name});

                // Sign the package if GPG key is configured
                const zaur = @import("root.zig");
                var gpg_signer = zaur.GpgSigner.init(self.allocator, self.config);
                defer gpg_signer.deinit();
                gpg_signer.signPackage(dst_path) catch |err| {
                    std.debug.print("Warning: Could not sign package {s}: {}\n", .{ entry.name, err });
                };
            }
        }
    }

    pub fn buildZigProject(self: *PackageBuilder, package_name: []const u8) !BuildResult {
        const package_dir = try std.fs.path.join(self.allocator, &.{ self.build_root, package_name });
        defer self.allocator.free(package_dir);

        // Check if it's a Zig project
        const zaur = @import("root.zig");
        var dep_resolver = zaur.DependencyResolver.init(self.allocator);

        const is_zig = try dep_resolver.checkZigProject(package_dir);
        if (!is_zig) {
            return BuildResult{
                .success = false,
                .log = try self.allocator.dupe(u8, "Not a Zig project"),
            };
        }

        // Generate PKGBUILD if needed
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ package_dir, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);

        std.Io.Dir.accessAbsolute(self.threaded_io.io(), pkgbuild_path, .{}) catch {
            try dep_resolver.generateZigPkgbuild(package_name, package_dir);
        };

        // Build using standard makepkg process
        return try self.buildPackage(package_name);
    }
};

fn prepareWorkspace(self: *PackageBuilder, source_dir: []const u8, package_dir: []const u8) !void {
    // Use shared utility from SourceManager to avoid duplicate logic
    try SourceManager.resetDirectory(package_dir);
    try SourceManager.copyDirectory(self.allocator, source_dir, package_dir);
}

pub const BuildResult = struct {
    success: bool,
    log: []const u8,

    pub fn deinit(self: BuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.log);
    }
};
