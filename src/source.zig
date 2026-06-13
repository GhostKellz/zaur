const std = @import("std");
const Database = @import("database.zig").Database;
const SourceKind = @import("database.zig").SourceKind;
const Config = @import("config.zig").Config;
const AurClient = @import("aur.zig").AurClient;

pub const SourceSpec = union(enum) {
    aur: struct {
        package_name: []const u8,
    },
    git: struct {
        repo_spec: []const u8,
    },
    local: struct {
        package_name: []const u8,
        path: []const u8,
    },
};

pub fn parse(spec: []const u8) !SourceSpec {
    if (std.mem.startsWith(u8, spec, "aur/")) {
        const name = spec[4..];
        try validateSourceName(name);
        return .{ .aur = .{ .package_name = name } };
    }
    if (std.mem.startsWith(u8, spec, "github:")) {
        const repo_spec = spec[7..];
        const derived_name = deriveGitSourceName(repo_spec);
        try validateSourceName(derived_name);
        return .{ .git = .{ .repo_spec = repo_spec } };
    }
    if (std.mem.startsWith(u8, spec, "git:")) {
        const repo_spec = spec[4..];
        const derived_name = deriveGitSourceName(repo_spec);
        try validateSourceName(derived_name);
        return .{ .git = .{ .repo_spec = repo_spec } };
    }
    if (std.mem.startsWith(u8, spec, "local:")) {
        const path = spec[6..];
        const package_name = std.fs.path.basename(path);
        try validateSourceName(package_name);
        return .{ .local = .{ .package_name = package_name, .path = path } };
    }
    return error.UnsupportedSourceSpec;
}

pub fn validateSourceName(name: []const u8) !void {
    // Reject empty names
    if (name.len == 0) return error.InvalidSourceName;

    // Reject names longer than 128 characters
    if (name.len > 128) return error.InvalidSourceName;

    // Reject names starting with '.'
    if (name[0] == '.') return error.InvalidSourceName;

    // Only allow alphanumeric, '-', '_', '.'
    for (name) |c| {
        const valid = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.';
        if (!valid) return error.InvalidSourceName;
    }
}

pub fn addSource(allocator: std.mem.Allocator, config: Config, db: *Database, spec: SourceSpec) ![]const u8 {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Transactional: fetch/copy files FIRST, only insert into DB on success
    // If checkout already exists, download to temp first then swap on success
    // The swap preserves the old checkout until the new one is fully in place
    switch (spec) {
        .aur => |aur_spec| {
            var aur_client = AurClient.init(allocator);
            defer aur_client.deinit();

            const package = try aur_client.searchPackage(aur_spec.package_name);
            if (package == null) return error.SourceNotFound;
            defer package.?.deinit(allocator);

            const checkout_dir = try config.sourceCheckoutDir(allocator, aur_spec.package_name);
            defer allocator.free(checkout_dir);

            const exists = directoryExists(checkout_dir);
            if (exists) {
                // Atomic update: download to temp, backup old, swap, cleanup
                const temp_root = try std.fmt.allocPrint(allocator, "{s}.adding", .{config.source_root});
                defer allocator.free(temp_root);
                const temp_checkout = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_root, aur_spec.package_name });
                defer allocator.free(temp_checkout);
                const backup_dir = try std.fmt.allocPrint(allocator, "{s}.backup", .{checkout_dir});
                defer allocator.free(backup_dir);

                try resetDirectory(temp_checkout);
                errdefer std.Io.Dir.deleteTree(.cwd(), io, temp_root) catch {};

                try aur_client.downloadPkgbuild(aur_spec.package_name, temp_root);

                // Atomic swap: old -> backup, temp -> checkout, delete backup
                std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};
                try std.Io.Dir.renameAbsolute(checkout_dir, backup_dir, io);
                std.Io.Dir.renameAbsolute(temp_checkout, checkout_dir, io) catch |err| {
                    // Restore backup on failure
                    std.Io.Dir.renameAbsolute(backup_dir, checkout_dir, io) catch {};
                    return err;
                };
                std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};
                std.Io.Dir.deleteTree(.cwd(), io, temp_root) catch {};
            } else {
                try resetDirectory(checkout_dir);
                try aur_client.downloadPkgbuild(aur_spec.package_name, config.source_root);
            }

            try db.upsertSource(aur_spec.package_name, .aur, package.?.url_path, "", "aur");
            try db.addPackageFromSource(aur_spec.package_name, aur_spec.package_name, "aur");
            recordResolvedCommit(allocator, io, db, aur_spec.package_name, checkout_dir);
            return allocator.dupe(u8, aur_spec.package_name);
        },
        .git => |git_spec| {
            var aur_client = AurClient.init(allocator);
            defer aur_client.deinit();

            const name = deriveGitSourceName(git_spec.repo_spec);
            const checkout_dir = try config.sourceCheckoutDir(allocator, name);
            defer allocator.free(checkout_dir);

            const exists = directoryExists(checkout_dir);
            if (exists) {
                // Atomic update: download to temp, backup old, swap, cleanup
                const temp_root = try std.fmt.allocPrint(allocator, "{s}.adding", .{config.source_root});
                defer allocator.free(temp_root);
                const temp_checkout = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_root, name });
                defer allocator.free(temp_checkout);
                const backup_dir = try std.fmt.allocPrint(allocator, "{s}.backup", .{checkout_dir});
                defer allocator.free(backup_dir);

                try resetDirectory(temp_checkout);
                errdefer std.Io.Dir.deleteTree(.cwd(), io, temp_root) catch {};

                try aur_client.downloadFromGitHub(git_spec.repo_spec, temp_root);

                // Atomic swap: old -> backup, temp -> checkout, delete backup
                std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};
                try std.Io.Dir.renameAbsolute(checkout_dir, backup_dir, io);
                std.Io.Dir.renameAbsolute(temp_checkout, checkout_dir, io) catch |err| {
                    // Restore backup on failure
                    std.Io.Dir.renameAbsolute(backup_dir, checkout_dir, io) catch {};
                    return err;
                };
                std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};
                std.Io.Dir.deleteTree(.cwd(), io, temp_root) catch {};
            } else {
                try resetDirectory(checkout_dir);
                try aur_client.downloadFromGitHub(git_spec.repo_spec, config.source_root);
            }

            try db.upsertSource(name, .git, git_spec.repo_spec, "", "custom");
            try db.addPackageFromSource(name, name, "custom");
            recordResolvedCommit(allocator, io, db, name, checkout_dir);
            return allocator.dupe(u8, name);
        },
        .local => |local_spec| {
            const source_path = try absolutizePath(allocator, local_spec.path);
            defer allocator.free(source_path);

            const checkout_dir = try config.sourceCheckoutDir(allocator, local_spec.package_name);
            defer allocator.free(checkout_dir);

            const exists = directoryExists(checkout_dir);
            if (exists) {
                // Atomic update: copy to temp, backup old, swap, cleanup
                const temp_checkout = try std.fmt.allocPrint(allocator, "{s}.adding", .{checkout_dir});
                defer allocator.free(temp_checkout);
                const backup_dir = try std.fmt.allocPrint(allocator, "{s}.backup", .{checkout_dir});
                defer allocator.free(backup_dir);

                try resetDirectory(temp_checkout);
                errdefer std.Io.Dir.deleteTree(.cwd(), io, temp_checkout) catch {};

                try copyDirectory(allocator, source_path, temp_checkout);

                // Atomic swap: old -> backup, temp -> checkout, delete backup
                std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};
                try std.Io.Dir.renameAbsolute(checkout_dir, backup_dir, io);
                std.Io.Dir.renameAbsolute(temp_checkout, checkout_dir, io) catch |err| {
                    // Restore backup on failure
                    std.Io.Dir.renameAbsolute(backup_dir, checkout_dir, io) catch {};
                    return err;
                };
                std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};
            } else {
                try resetDirectory(checkout_dir);
                try copyDirectory(allocator, source_path, checkout_dir);
            }

            try db.upsertSource(local_spec.package_name, .local, source_path, "", "custom");
            try db.addPackageFromSource(local_spec.package_name, local_spec.package_name, "custom");
            return allocator.dupe(u8, local_spec.package_name);
        },
    }
}

/// Best-effort: record the cloned checkout's HEAD commit so updates can detect
/// drift and pins have a baseline. Non-git checkouts (or rev-parse failures)
/// are silently ignored — this is integrity metadata, not a hard requirement.
fn recordResolvedCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    source_name: []const u8,
    checkout_dir: []const u8,
) void {
    const integrity = @import("integrity.zig");
    const commit = integrity.resolveGitHead(allocator, io, checkout_dir) catch return;
    defer allocator.free(commit);
    db.setSourcePin(source_name, null, null, commit, null) catch {};
}

pub fn resetDirectory(path: []const u8) !void {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const exists = blk: {
        std.Io.Dir.access(.cwd(), io, path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists) {
        try std.Io.Dir.deleteTree(.cwd(), io, path);
    }
    try std.Io.Dir.createDirPath(.cwd(), io, path);
}

fn directoryExists(path: []const u8) bool {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    std.Io.Dir.access(.cwd(), io, path, .{}) catch return false;
    return true;
}

fn absolutizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);

    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const cwd = try std.process.currentPathAlloc(threaded_io.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn copyDirectory(allocator: std.mem.Allocator, source_dir: []const u8, dest_dir: []const u8) !void {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var source = try std.Io.Dir.openDirAbsolute(io, source_dir, .{ .iterate = true });
    defer source.close(io);

    var walker = try source.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, entry.path });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .directory => try std.Io.Dir.createDirPath(.cwd(), io, dest_path),
            .file => {
                const src_path = try std.fs.path.join(allocator, &.{ source_dir, entry.path });
                defer allocator.free(src_path);

                if (std.fs.path.dirname(dest_path)) |parent| {
                    try std.Io.Dir.createDirPath(.cwd(), io, parent);
                }

                try std.Io.Dir.copyFileAbsolute(src_path, dest_path, io, .{});
            },
            .sym_link => {
                // Reject symlinks explicitly - they can cause security issues
                std.debug.print("Error: symlink not supported: {s}\n", .{entry.path});
                return error.SymlinkNotSupported;
            },
            else => {
                // Reject other special file types (block devices, sockets, etc.)
                std.debug.print("Error: unsupported file type: {s}\n", .{entry.path});
                return error.UnsupportedFileType;
            },
        }
    }
}

fn deriveGitSourceName(repo_spec: []const u8) []const u8 {
    var parts = std.mem.splitScalar(u8, repo_spec, '/');
    _ = parts.next();
    const second = parts.next() orelse repo_spec;
    if (std.mem.indexOfScalar(u8, second, '@')) |at_pos| return second[0..at_pos];
    return second;
}

// =============================================================================
// Tests: Source Name Validation
// =============================================================================

test "validateSourceName rejects empty names" {
    try std.testing.expectError(error.InvalidSourceName, validateSourceName(""));
}

test "validateSourceName rejects names starting with dot" {
    try std.testing.expectError(error.InvalidSourceName, validateSourceName(".hidden"));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName(".."));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("."));
}

test "validateSourceName rejects names longer than 128 chars" {
    const long_name = comptime blk: {
        var buf: [129]u8 = undefined;
        @memset(&buf, 'a');
        break :blk buf;
    };
    try std.testing.expectError(error.InvalidSourceName, validateSourceName(&long_name));
}

test "validateSourceName rejects invalid characters" {
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("foo/bar"));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("foo bar"));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("foo\x00bar"));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("foo:bar"));
    try std.testing.expectError(error.InvalidSourceName, validateSourceName("foo*bar"));
}

test "validateSourceName accepts valid names" {
    try validateSourceName("yay");
    try validateSourceName("yay-git");
    try validateSourceName("package_name");
    try validateSourceName("Package-Name.1.0");
    try validateSourceName("lib32-glibc");
    try validateSourceName("a");
}

test "validateSourceName accepts max length name" {
    const max_name = comptime blk: {
        var buf: [128]u8 = undefined;
        @memset(&buf, 'a');
        break :blk buf;
    };
    try validateSourceName(&max_name);
}

// =============================================================================
// Tests: Source Spec Parsing
// =============================================================================

test "parse handles AUR sources" {
    const spec = try parse("aur/yay");
    switch (spec) {
        .aur => |aur| try std.testing.expectEqualStrings("yay", aur.package_name),
        else => return error.TestUnexpectedResult,
    }
}

test "parse handles GitHub sources" {
    const spec = try parse("github:Jguer/yay");
    switch (spec) {
        .git => |git| try std.testing.expectEqualStrings("Jguer/yay", git.repo_spec),
        else => return error.TestUnexpectedResult,
    }
}

test "parse handles git sources" {
    // git: prefix expects user/repo format similar to github:
    const spec = try parse("git:user/myrepo");
    switch (spec) {
        .git => |git| try std.testing.expectEqualStrings("user/myrepo", git.repo_spec),
        else => return error.TestUnexpectedResult,
    }
}

test "parse handles local sources" {
    const spec = try parse("local:/path/to/mypackage");
    switch (spec) {
        .local => |local| {
            try std.testing.expectEqualStrings("mypackage", local.package_name);
            try std.testing.expectEqualStrings("/path/to/mypackage", local.path);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse rejects unsupported specs" {
    try std.testing.expectError(error.UnsupportedSourceSpec, parse("http://example.com"));
    try std.testing.expectError(error.UnsupportedSourceSpec, parse("random-string"));
    try std.testing.expectError(error.UnsupportedSourceSpec, parse(""));
}

test "parse rejects invalid AUR package names" {
    try std.testing.expectError(error.InvalidSourceName, parse("aur/.hidden"));
    try std.testing.expectError(error.InvalidSourceName, parse("aur/foo/bar"));
    try std.testing.expectError(error.InvalidSourceName, parse("aur/"));
}

// =============================================================================
// Tests: Git Source Name Derivation
// =============================================================================

test "deriveGitSourceName extracts repo name" {
    try std.testing.expectEqualStrings("yay", deriveGitSourceName("Jguer/yay"));
    try std.testing.expectEqualStrings("repo", deriveGitSourceName("user/repo"));
}

test "deriveGitSourceName handles version tags" {
    try std.testing.expectEqualStrings("yay", deriveGitSourceName("Jguer/yay@v12.0.0"));
    try std.testing.expectEqualStrings("repo", deriveGitSourceName("user/repo@main"));
}

test "deriveGitSourceName handles missing slash" {
    try std.testing.expectEqualStrings("repo", deriveGitSourceName("repo"));
}

pub fn updateSource(allocator: std.mem.Allocator, config: Config, db: *Database, source_name: []const u8) !void {
    const source = try db.getSource(allocator, source_name) orelse return error.SourceNotFound;
    defer source.deinit(allocator);

    const checkout_dir = try config.sourceCheckoutDir(allocator, source.name);
    defer allocator.free(checkout_dir);

    // Atomic update: download to temp dir first, then swap on success
    const temp_name = try std.fmt.allocPrint(allocator, "{s}.updating", .{source.name});
    defer allocator.free(temp_name);
    const temp_dir = try config.sourceCheckoutDir(allocator, temp_name);
    defer allocator.free(temp_dir);

    // Ensure temp dir is clean
    try resetDirectory(temp_dir);

    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Download to temp dir
    const download_success = blk: {
        switch (source.kind) {
            .aur => {
                var aur_client = AurClient.init(allocator);
                defer aur_client.deinit();
                aur_client.downloadPkgbuild(source.name, temp_dir) catch break :blk false;
            },
            .git => {
                var aur_client = AurClient.init(allocator);
                defer aur_client.deinit();
                aur_client.downloadFromGitHub(source.location, temp_dir) catch break :blk false;
            },
            .local => {
                copyDirectory(allocator, source.location, temp_dir) catch break :blk false;
            },
        }
        break :blk true;
    };

    if (!download_success) {
        // Clean up temp dir on failure, keep existing checkout
        std.Io.Dir.deleteTree(.cwd(), io, temp_dir) catch {};
        return error.UpdateFailed;
    }

    // Download functions create nested structure: temp_dir/source_name/
    // We need to swap the nested directory, not the temp parent
    const nested_dir = try std.fs.path.join(allocator, &.{ temp_dir, source.name });
    defer allocator.free(nested_dir);

    // For local sources, copyDirectory copies contents directly (no nesting)
    // For AUR/Git sources, download creates source_name subdirectory
    const swap_from = if (source.kind == .local) temp_dir else nested_dir;

    // Verify the directory to swap actually exists
    std.Io.Dir.access(.cwd(), io, swap_from, .{}) catch {
        std.Io.Dir.deleteTree(.cwd(), io, temp_dir) catch {};
        return error.UpdateFailed;
    };

    // Success: swap temp dir with checkout dir
    const backup_name = try std.fmt.allocPrint(allocator, "{s}.old", .{source.name});
    defer allocator.free(backup_name);
    const backup_dir = try config.sourceCheckoutDir(allocator, backup_name);
    defer allocator.free(backup_dir);

    // Remove old backup if exists
    std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};

    // Rename current -> backup (if exists)
    const current_exists = blk: {
        std.Io.Dir.access(.cwd(), io, checkout_dir, .{}) catch break :blk false;
        break :blk true;
    };
    if (current_exists) {
        std.Io.Dir.renameAbsolute(checkout_dir, backup_dir, io) catch {};
    }

    // Rename nested temp dir -> checkout dir
    std.Io.Dir.renameAbsolute(swap_from, checkout_dir, io) catch |err| {
        // Restore backup on failure
        if (current_exists) {
            std.Io.Dir.renameAbsolute(backup_dir, checkout_dir, io) catch {};
        }
        return err;
    };

    // Clean up remaining temp directory and backup
    std.Io.Dir.deleteTree(.cwd(), io, temp_dir) catch {};
    std.Io.Dir.deleteTree(.cwd(), io, backup_dir) catch {};

    // Integrity: reconcile the new checkout against any recorded pin/commit.
    reconcileCommit(allocator, io, db, source.name, checkout_dir);

    std.debug.print("Updated source: {s}\n", .{source.name});
}

/// After an update swap, reconcile the freshly fetched checkout with its
/// integrity metadata:
///   * If a `pinned_ref` is set, force the checkout back to that ref so an
///     update can never silently advance past the pinned point.
///   * Otherwise, log any commit drift (old → new) and record the new HEAD.
/// All steps are best-effort; failures never abort an otherwise good update.
fn reconcileCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    source_name: []const u8,
    checkout_dir: []const u8,
) void {
    const integrity = @import("integrity.zig");
    const pin = (db.getSourcePin(allocator, source_name) catch return) orelse return;
    defer pin.deinit(allocator);

    if (pin.pinned_ref.len > 0) {
        integrity.checkoutRef(allocator, io, checkout_dir, pin.pinned_ref) catch {
            std.debug.print("Warning: failed to restore pinned ref {s} for {s}\n", .{ pin.pinned_ref, source_name });
        };
    }

    const new_commit = integrity.resolveGitHead(allocator, io, checkout_dir) catch return;
    defer allocator.free(new_commit);

    if (pin.resolved_commit.len > 0 and !std.mem.eql(u8, pin.resolved_commit, new_commit)) {
        std.debug.print("Source {s} advanced: {s} -> {s}\n", .{ source_name, pin.resolved_commit, new_commit });
    }
    db.setSourcePin(source_name, null, null, new_commit, null) catch {};
}

pub fn updateAllSources(allocator: std.mem.Allocator, config: Config, db: *Database) !void {
    const sources = try db.getSources(allocator);
    defer {
        for (sources) |s| s.deinit(allocator);
        allocator.free(sources);
    }

    for (sources) |source| {
        updateSource(allocator, config, db, source.name) catch |err| {
            std.debug.print("Failed to update {s}: {any}\n", .{ source.name, err });
        };
    }
}
