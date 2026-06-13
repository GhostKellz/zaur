const std = @import("std");
const vercmp = @import("version.zig").vercmp;
const Database = @import("database.zig").Database;
const Config = @import("config.zig").Config;
const Severity = @import("database.zig").Severity;
const AdvisoryStatus = @import("database.zig").AdvisoryStatus;
const StaleStatus = @import("database.zig").StaleStatus;
const SignatureStatus = @import("database.zig").SignatureStatus;
const Advisory = @import("database.zig").Advisory;
const PackageSecurityStatus = @import("database.zig").PackageSecurityStatus;

pub const SyncResult = struct {
    advisories_synced: u32,
    errors: u32,
};

pub const ScanResult = struct {
    total: u32,
    clean: u32,
    vulnerable: u32,
    unknown: u32,
    stale: u32,
    unsigned: u32,
};

pub const SecurityManager = struct {
    allocator: std.mem.Allocator,
    database: *Database,
    config: *const Config,

    const ARCH_SECURITY_URL = "https://security.archlinux.org/json";

    pub fn init(allocator: std.mem.Allocator, config: *const Config, database: *Database) SecurityManager {
        return .{
            .allocator = allocator,
            .database = database,
            .config = config,
        };
    }

    pub fn deinit(self: *SecurityManager) void {
        _ = self;
        // Nothing to clean up currently
    }

    // =========================================================================
    // Advisory Sync
    // =========================================================================

    pub fn syncAdvisories(self: *SecurityManager) !SyncResult {
        const run_id = try self.database.recordSyncRunStart("advisory_sync");

        var result = SyncResult{
            .advisories_synced = 0,
            .errors = 0,
        };

        // Fetch advisories from Arch security tracker
        const json_data = self.fetchAdvisoryData() catch |err| {
            const details = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
            defer self.allocator.free(details);
            try self.database.recordSyncRunComplete(run_id, "failed", details);
            return err;
        };
        defer self.allocator.free(json_data);

        // Parse and store advisories
        const parsed = std.json.parseFromSlice([]const ArchAdvisory, self.allocator, json_data, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            const details = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"json_parse_failed\"}}", .{});
            defer self.allocator.free(details);
            try self.database.recordSyncRunComplete(run_id, "failed", details);
            return err;
        };
        defer parsed.deinit();

        for (parsed.value) |advisory| {
            // Skip advisories with no affected packages
            if (advisory.packages.len == 0) continue;

            // Build CVE IDs JSON array (shared across all packages for this advisory)
            var cve_json: std.ArrayList(u8) = .empty;
            defer cve_json.deinit(self.allocator);
            try cve_json.appendSlice(self.allocator, "[");
            for (advisory.issues, 0..) |issue, i| {
                if (i > 0) try cve_json.appendSlice(self.allocator, ",");
                try cve_json.appendSlice(self.allocator, "\"");
                try cve_json.appendSlice(self.allocator, issue);
                try cve_json.appendSlice(self.allocator, "\"");
            }
            try cve_json.appendSlice(self.allocator, "]");

            // Build reference URL
            const ref_url = try std.fmt.allocPrint(self.allocator, "https://security.archlinux.org/{s}", .{advisory.name});
            defer self.allocator.free(ref_url);

            // Store advisory for EACH affected package
            for (advisory.packages) |package_name| {
                // Create unique ID per advisory-package combination
                const composite_id = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ advisory.name, package_name });
                defer self.allocator.free(composite_id);

                self.database.upsertAdvisory(
                    composite_id,
                    package_name,
                    advisory.severity,
                    advisory.type,
                    advisory.affected,
                    if (advisory.fixed) |f| if (f.len > 0) f else null else null,
                    advisory.status,
                    cve_json.items,
                    ref_url,
                    advisory.created,
                ) catch {
                    result.errors += 1;
                    continue;
                };

                result.advisories_synced += 1;
            }
        }

        const details = try std.fmt.allocPrint(self.allocator, "{{\"advisories_synced\":{d},\"errors\":{d}}}", .{ result.advisories_synced, result.errors });
        defer self.allocator.free(details);
        try self.database.recordSyncRunComplete(run_id, "completed", details);

        return result;
    }

    fn fetchAdvisoryData(self: *SecurityManager) ![]const u8 {
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const io = threaded_io.io();

        var http_client: std.http.Client = .{
            .allocator = self.allocator,
            .io = io,
        };
        defer http_client.deinit();

        const uri = try std.Uri.parse(ARCH_SECURITY_URL);
        var req = try http_client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.HttpRequestFailed;
        }

        // Read response body
        var body_buf: [65536]u8 = undefined;
        const reader = response.reader(&body_buf);

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(self.allocator);

        var chunk_buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = reader.readSliceShort(&chunk_buf) catch break;
            if (bytes_read == 0) break;
            try body.appendSlice(self.allocator, chunk_buf[0..bytes_read]);

            // Limit to 10MB
            if (body.items.len > 10 * 1024 * 1024) {
                return error.ResponseTooLarge;
            }
        }

        return body.toOwnedSlice(self.allocator);
    }

    // =========================================================================
    // Security Status Computation
    // =========================================================================

    pub fn scanAllPackages(self: *SecurityManager) !ScanResult {
        const run_id = try self.database.recordSyncRunStart("status_scan");

        var result = ScanResult{
            .total = 0,
            .clean = 0,
            .vulnerable = 0,
            .unknown = 0,
            .stale = 0,
            .unsigned = 0,
        };

        // Get all packages
        const packages = try self.database.getPackages(self.allocator);
        defer {
            for (packages) |p| p.deinit(self.allocator);
            self.allocator.free(packages);
        }

        for (packages) |pkg| {
            const status = try self.computePackageStatus(pkg.name, pkg.version, pkg.repo_name, pkg.updated_at);

            // Store the status
            try self.database.upsertPackageSecurityStatus(
                pkg.name,
                pkg.repo_name,
                pkg.version,
                status.advisory_status,
                status.stale_status,
                status.signature_status,
                status.advisory_match_count,
                status.highest_severity,
            );

            result.total += 1;
            switch (status.advisory_status) {
                .clean => result.clean += 1,
                .vulnerable => result.vulnerable += 1,
                .unknown => result.unknown += 1,
                .unscanned => {},
            }
            if (status.stale_status == .stale) result.stale += 1;
            if (status.signature_status == .unsigned) result.unsigned += 1;
        }

        const details = try std.fmt.allocPrint(self.allocator, "{{\"total\":{d},\"vulnerable\":{d},\"clean\":{d},\"unknown\":{d}}}", .{ result.total, result.vulnerable, result.clean, result.unknown });
        defer self.allocator.free(details);
        try self.database.recordSyncRunComplete(run_id, "completed", details);

        return result;
    }

    pub fn scanPackage(self: *SecurityManager, package_name: []const u8) !?PackageSecurityStatus {
        // Get package info
        const pkg = try self.database.getPackage(self.allocator, package_name) orelse return null;
        defer pkg.deinit(self.allocator);

        const status = try self.computePackageStatus(pkg.name, pkg.version, pkg.repo_name, pkg.updated_at);

        // Store the status
        try self.database.upsertPackageSecurityStatus(
            pkg.name,
            pkg.repo_name,
            pkg.version,
            status.advisory_status,
            status.stale_status,
            status.signature_status,
            status.advisory_match_count,
            status.highest_severity,
        );

        // Return the stored status
        return try self.database.getPackageSecurityStatus(self.allocator, package_name);
    }

    fn computePackageStatus(
        self: *SecurityManager,
        package_name: []const u8,
        package_version: []const u8,
        repo_name: []const u8,
        updated_at: []const u8,
    ) !struct {
        advisory_status: AdvisoryStatus,
        stale_status: StaleStatus,
        signature_status: SignatureStatus,
        advisory_match_count: u32,
        highest_severity: ?Severity,
    } {
        // Check advisories
        const advisories = try self.database.getAdvisoriesForPackage(self.allocator, package_name);
        defer {
            for (advisories) |a| a.deinit(self.allocator);
            self.allocator.free(advisories);
        }

        var advisory_status: AdvisoryStatus = .unknown;
        var advisory_match_count: u32 = 0;
        var highest_severity: ?Severity = null;

        if (advisories.len > 0) {
            advisory_status = .clean; // Has advisories but not necessarily affected

            for (advisories) |advisory| {
                // Check if package is affected
                if (isAffectedByAdvisory(package_version, advisory)) {
                    advisory_status = .vulnerable;
                    advisory_match_count += 1;

                    // Track highest severity
                    if (highest_severity) |current| {
                        if (advisory.severity.order() > current.order()) {
                            highest_severity = advisory.severity;
                        }
                    } else {
                        highest_severity = advisory.severity;
                    }
                }
            }
        }

        // Check staleness
        const stale_status = self.checkStaleness(updated_at);

        // Check signature
        const signature_status = try self.checkSignature(package_name, repo_name);

        return .{
            .advisory_status = advisory_status,
            .stale_status = stale_status,
            .signature_status = signature_status,
            .advisory_match_count = advisory_match_count,
            .highest_severity = highest_severity,
        };
    }

    fn checkStaleness(self: *SecurityManager, updated_at: []const u8) StaleStatus {
        // Parse updated_at timestamp (nanoseconds)
        const updated_ns = std.fmt.parseInt(i128, updated_at, 10) catch return .unknown;

        // Get current time
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const now = std.Io.Timestamp.now(threaded_io.io(), .real);
        const now_ns: i128 = now.nanoseconds;

        // Calculate age in days
        const age_ns = now_ns - updated_ns;
        const ns_per_day: i128 = 24 * 60 * 60 * 1_000_000_000;
        const age_days = @divFloor(age_ns, ns_per_day);

        // Compare against threshold
        if (age_days > self.config.security_stale_days) {
            return .stale;
        }
        return .fresh;
    }

    fn checkSignature(self: *SecurityManager, package_name: []const u8, repo_name: []const u8) !SignatureStatus {
        // If signatures not required, return not_required
        if (!self.config.security_require_signatures) {
            return .not_required;
        }

        // Find the package file in the repo directory
        const repo_dir = try self.config.repoDir(self.allocator, repo_name);
        defer self.allocator.free(repo_dir);

        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const io = threaded_io.io();

        // List files in repo directory and find matching package
        var dir = std.Io.Dir.openDirAbsolute(io, repo_dir, .{ .iterate = true }) catch {
            return .unknown;
        };
        defer dir.close(io);

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;

            // Check if this is a package file for our package
            if (std.mem.startsWith(u8, entry.path, package_name) and
                std.mem.endsWith(u8, entry.path, ".pkg.tar.zst"))
            {
                // Check if .sig file exists
                const sig_name = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{entry.path});
                defer self.allocator.free(sig_name);

                const sig_path = try std.fs.path.join(self.allocator, &.{ repo_dir, sig_name });
                defer self.allocator.free(sig_path);

                // Check if signature file exists
                std.Io.Dir.access(.cwd(), io, sig_path, .{}) catch {
                    return .unsigned;
                };
                return .signed;
            }
        }

        return .unknown;
    }

    // =========================================================================
    // Query Methods
    // =========================================================================

    pub fn getPackageStatus(self: *SecurityManager, package_name: []const u8) !?PackageSecurityStatus {
        return self.database.getPackageSecurityStatus(self.allocator, package_name);
    }

    pub fn getAllPackageStatuses(self: *SecurityManager) ![]PackageSecurityStatus {
        return self.database.getAllPackageSecurityStatuses(self.allocator);
    }

    pub fn getAdvisories(self: *SecurityManager) ![]Advisory {
        return self.database.getAdvisories(self.allocator);
    }

    pub fn getAdvisoryCount(self: *SecurityManager) !u32 {
        return self.database.getAdvisoryCount();
    }
};

// =========================================================================
// Arch Security Tracker JSON Types
// =========================================================================

const ArchAdvisory = struct {
    name: []const u8,
    packages: []const []const u8,
    status: []const u8,
    severity: []const u8,
    type: []const u8,
    affected: []const u8,
    fixed: ?[]const u8,
    issues: []const []const u8,
    created: []const u8,
};

// =========================================================================
// Version Comparison (Pacman-compatible)
// =========================================================================

fn isAffectedByAdvisory(package_version: []const u8, advisory: Advisory) bool {
    // If advisory has no fixed version, package is vulnerable if version >= affected
    if (advisory.fixed_version == null) {
        return compareVersions(package_version, advisory.affected_version) != .lt;
    }

    // If advisory has fixed version, package is vulnerable if:
    // affected <= package_version < fixed
    const cmp_affected = compareVersions(package_version, advisory.affected_version);
    const cmp_fixed = compareVersions(package_version, advisory.fixed_version.?);

    return (cmp_affected == .gt or cmp_affected == .eq) and cmp_fixed == .lt;
}

/// Compare two Arch Linux package versions using pacman semantics
/// Handles epoch:pkgver-pkgrel format
/// Uses the unified vercmp implementation from version.zig
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    return vercmp(a, b);
}

// =========================================================================
// Tests
// =========================================================================

test "compareVersions handles simple versions" {
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("1.0", "1.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.0", "1.1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.1", "1.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.9", "1.10"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.10", "1.9"));
}

test "compareVersions handles pkgrel" {
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("1.0-1", "1.0-1"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.0-1", "1.0-2"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0-2", "1.0-1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0-1", "1.0"));
}

test "compareVersions handles epochs" {
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1:1.0", "2.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("2.0", "1:1.0"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("1:1.0", "1:1.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("2:1.0", "1:9.0"));
}

test "compareVersions handles complex versions" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("3.2.1-1", "3.2.2-1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("3.2.2-1", "3.2.1-1"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1:3.2.1-1", "1:3.2.2-1"));
}

test "compareVersions handles alpha versions" {
    // Alpha < beta lexicographically
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.0alpha", "1.0beta"));
    // Prerelease versions (alpha/beta/rc) are LESS than release versions
    // Pacman ordering: 1.0alpha < 1.0beta < 1.0rc < 1.0
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.0beta", "1.0"));
}

test "isAffectedByAdvisory with fixed version" {
    const advisory = Advisory{
        .advisory_id = "AVG-1",
        .package_name = "test",
        .severity = .high,
        .vuln_type = "test",
        .affected_version = "1.0",
        .fixed_version = "1.2",
        .status = "Fixed",
        .cve_ids = "[]",
        .reference_url = null,
        .published_at = "2024-01-01",
        .updated_at = "2024-01-01",
    };

    // Version before affected - not affected
    try std.testing.expect(!isAffectedByAdvisory("0.9", advisory));

    // Version at affected - affected
    try std.testing.expect(isAffectedByAdvisory("1.0", advisory));

    // Version between affected and fixed - affected
    try std.testing.expect(isAffectedByAdvisory("1.1", advisory));

    // Version at fixed - not affected
    try std.testing.expect(!isAffectedByAdvisory("1.2", advisory));

    // Version after fixed - not affected
    try std.testing.expect(!isAffectedByAdvisory("1.3", advisory));
}

test "isAffectedByAdvisory without fixed version" {
    const advisory = Advisory{
        .advisory_id = "AVG-2",
        .package_name = "test",
        .severity = .critical,
        .vuln_type = "test",
        .affected_version = "2.0",
        .fixed_version = null,
        .status = "Vulnerable",
        .cve_ids = "[]",
        .reference_url = null,
        .published_at = "2024-01-01",
        .updated_at = "2024-01-01",
    };

    // Version before affected - not affected
    try std.testing.expect(!isAffectedByAdvisory("1.9", advisory));

    // Version at affected - affected
    try std.testing.expect(isAffectedByAdvisory("2.0", advisory));

    // Version after affected - affected (no fix available)
    try std.testing.expect(isAffectedByAdvisory("2.1", advisory));
}
