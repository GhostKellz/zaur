const std = @import("std");

pub const MirrorPolicy = enum {
    metadata, // Sync databases only (default)
    ondemand, // Download packages when requested (caching proxy)

    pub fn fromString(s: []const u8) MirrorPolicy {
        if (std.mem.eql(u8, s, "ondemand")) return .ondemand;
        return .metadata;
    }

    pub fn toString(self: MirrorPolicy) []const u8 {
        return switch (self) {
            .metadata => "metadata",
            .ondemand => "ondemand",
        };
    }
};

/// How makepkg is executed for a build.
pub const BuildIsolation = enum {
    none, // Run makepkg directly in the build dir (default)
    chroot, // Arch-native clean chroot via devtools (makechrootpkg)
    container, // makepkg inside an archlinux container (podman/docker)

    pub fn fromString(s: []const u8) BuildIsolation {
        if (std.mem.eql(u8, s, "chroot")) return .chroot;
        if (std.mem.eql(u8, s, "container")) return .container;
        return .none;
    }

    pub fn toString(self: BuildIsolation) []const u8 {
        return switch (self) {
            .none => "none",
            .chroot => "chroot",
            .container => "container",
        };
    }
};

/// What the PKGBUILD/source static analyzer does on findings.
pub const ScanPolicy = enum {
    off, // Skip scanning entirely
    warn, // Record + log findings but allow the build (default)
    enforce, // Block the build on critical/high findings

    pub fn fromString(s: []const u8) ScanPolicy {
        if (std.mem.eql(u8, s, "off")) return .off;
        if (std.mem.eql(u8, s, "enforce")) return .enforce;
        return .warn;
    }

    pub fn toString(self: ScanPolicy) []const u8 {
        return switch (self) {
            .off => "off",
            .warn => "warn",
            .enforce => "enforce",
        };
    }
};

pub const Config = struct {
    data_root: []const u8,
    repo_root: []const u8,
    aur_repo_dir: []const u8,
    custom_repo_dir: []const u8,
    mirror_root: []const u8,
    build_root: []const u8,
    source_root: []const u8,
    log_root: []const u8,
    db_name: []const u8,
    db_path: []const u8,
    bind_address: []const u8,
    port: u16,
    api_token: ?[]const u8,
    gpg_key_id: ?[]const u8,
    cors_origin: ?[]const u8,
    // Security settings
    security_stale_days: u32,
    security_require_signatures: bool,
    // Supply-chain hardening
    scan_policy: ScanPolicy,
    require_signed_commits: bool,
    checksum_pinning: bool,
    // Build isolation
    build_isolation: BuildIsolation,
    container_runtime: []const u8,
    container_image: []const u8,
    chroot_dir: []const u8,
    // Mirror settings
    mirror_upstream: []const u8,
    mirror_policy: MirrorPolicy,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !Config {
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const cwd = try std.process.currentPathAlloc(threaded_io.io(), allocator);
        defer allocator.free(cwd);

        const data_root_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_DATA_ROOT", ".zaur");
        defer allocator.free(data_root_value);
        const data_root = try absolutizePath(allocator, cwd, data_root_value);
        errdefer allocator.free(data_root);

        const repo_root_default = try std.fs.path.join(allocator, &.{ data_root, "repos" });
        defer allocator.free(repo_root_default);
        const repo_root_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_REPO_ROOT", repo_root_default);
        defer allocator.free(repo_root_value);
        const repo_root = try absolutizePath(allocator, cwd, repo_root_value);
        errdefer allocator.free(repo_root);

        const aur_repo_dir = try std.fs.path.join(allocator, &.{ repo_root, "aur" });
        errdefer allocator.free(aur_repo_dir);
        const custom_repo_dir = try std.fs.path.join(allocator, &.{ repo_root, "custom" });
        errdefer allocator.free(custom_repo_dir);

        const mirror_root_default = try std.fs.path.join(allocator, &.{ data_root, "mirror" });
        defer allocator.free(mirror_root_default);
        const mirror_root_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_MIRROR_ROOT", mirror_root_default);
        defer allocator.free(mirror_root_value);
        const mirror_root = try absolutizePath(allocator, cwd, mirror_root_value);
        errdefer allocator.free(mirror_root);

        const build_root_default = try std.fs.path.join(allocator, &.{ data_root, "build" });
        defer allocator.free(build_root_default);
        const build_root_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_BUILD_ROOT", build_root_default);
        defer allocator.free(build_root_value);
        const build_root = try absolutizePath(allocator, cwd, build_root_value);
        errdefer allocator.free(build_root);

        const source_root_default = try std.fs.path.join(allocator, &.{ data_root, "sources" });
        defer allocator.free(source_root_default);
        const source_root_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_SOURCE_ROOT", source_root_default);
        defer allocator.free(source_root_value);
        const source_root = try absolutizePath(allocator, cwd, source_root_value);
        errdefer allocator.free(source_root);

        const log_root_default = try std.fs.path.join(allocator, &.{ data_root, "logs" });
        defer allocator.free(log_root_default);
        const log_root_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_LOG_ROOT", log_root_default);
        defer allocator.free(log_root_value);
        const log_root = try absolutizePath(allocator, cwd, log_root_value);
        errdefer allocator.free(log_root);

        const db_name = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_DB_NAME", "zaur");
        errdefer allocator.free(db_name);

        const db_path_default = try std.fs.path.join(allocator, &.{ data_root, "zaur.db" });
        defer allocator.free(db_path_default);
        const db_path_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_DB_PATH", db_path_default);
        defer allocator.free(db_path_value);
        const db_path = try absolutizePath(allocator, cwd, db_path_value);
        errdefer allocator.free(db_path);

        const bind_address = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_BIND", "127.0.0.1");
        errdefer allocator.free(bind_address);

        const port = try envOrDefaultU16(allocator, environ_map, "ZAUR_PORT", 9004);

        const api_token: ?[]const u8 = if (environ_map.get("ZAUR_API_TOKEN")) |t|
            try allocator.dupe(u8, t)
        else
            null;
        errdefer if (api_token) |t| allocator.free(t);

        const gpg_key_id: ?[]const u8 = if (environ_map.get("ZAUR_GPG_KEY")) |k|
            try allocator.dupe(u8, k)
        else
            null;
        errdefer if (gpg_key_id) |k| allocator.free(k);

        const cors_origin: ?[]const u8 = if (environ_map.get("ZAUR_CORS_ORIGIN")) |origin|
            try allocator.dupe(u8, origin)
        else
            null;
        errdefer if (cors_origin) |origin| allocator.free(origin);

        const security_stale_days = try envOrDefaultU32(environ_map, "ZAUR_SECURITY_STALE_DAYS", 30);
        const security_require_signatures = envOrDefaultBool(environ_map, "ZAUR_SECURITY_REQUIRE_SIGNATURES", false);

        // Supply-chain hardening
        const scan_policy = ScanPolicy.fromString(environ_map.get("ZAUR_SCAN_POLICY") orelse "warn");
        const require_signed_commits = envOrDefaultBool(environ_map, "ZAUR_REQUIRE_SIGNED_COMMITS", false);
        const checksum_pinning = envOrDefaultBool(environ_map, "ZAUR_CHECKSUM_PINNING", true);

        // Build isolation
        const build_isolation = BuildIsolation.fromString(environ_map.get("ZAUR_BUILD_ISOLATION") orelse "none");
        const container_runtime = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_CONTAINER_RUNTIME", "podman");
        errdefer allocator.free(container_runtime);
        const container_image = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_CONTAINER_IMAGE", "archlinux:base-devel");
        errdefer allocator.free(container_image);

        const chroot_dir_default = try std.fs.path.join(allocator, &.{ data_root, "chroot" });
        defer allocator.free(chroot_dir_default);
        const chroot_dir_value = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_CHROOT_DIR", chroot_dir_default);
        defer allocator.free(chroot_dir_value);
        const chroot_dir = try absolutizePath(allocator, cwd, chroot_dir_value);
        errdefer allocator.free(chroot_dir);

        // Mirror settings
        const mirror_upstream = try envOrDefaultAlloc(allocator, environ_map, "ZAUR_MIRROR_UPSTREAM", "https://mirrors.kernel.org/archlinux");
        errdefer allocator.free(mirror_upstream);

        const mirror_policy_str = environ_map.get("ZAUR_MIRROR_POLICY") orelse "metadata";
        const mirror_policy = MirrorPolicy.fromString(mirror_policy_str);

        return .{
            .data_root = data_root,
            .repo_root = repo_root,
            .aur_repo_dir = aur_repo_dir,
            .custom_repo_dir = custom_repo_dir,
            .mirror_root = mirror_root,
            .build_root = build_root,
            .source_root = source_root,
            .log_root = log_root,
            .db_name = db_name,
            .db_path = db_path,
            .bind_address = bind_address,
            .port = port,
            .api_token = api_token,
            .gpg_key_id = gpg_key_id,
            .cors_origin = cors_origin,
            .security_stale_days = security_stale_days,
            .security_require_signatures = security_require_signatures,
            .scan_policy = scan_policy,
            .require_signed_commits = require_signed_commits,
            .checksum_pinning = checksum_pinning,
            .build_isolation = build_isolation,
            .container_runtime = container_runtime,
            .container_image = container_image,
            .chroot_dir = chroot_dir,
            .mirror_upstream = mirror_upstream,
            .mirror_policy = mirror_policy,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Config) void {
        self.allocator.free(self.data_root);
        self.allocator.free(self.repo_root);
        self.allocator.free(self.aur_repo_dir);
        self.allocator.free(self.custom_repo_dir);
        self.allocator.free(self.mirror_root);
        self.allocator.free(self.build_root);
        self.allocator.free(self.source_root);
        self.allocator.free(self.log_root);
        self.allocator.free(self.db_name);
        self.allocator.free(self.db_path);
        self.allocator.free(self.bind_address);
        if (self.api_token) |t| self.allocator.free(t);
        if (self.gpg_key_id) |k| self.allocator.free(k);
        if (self.cors_origin) |origin| self.allocator.free(origin);
        self.allocator.free(self.container_runtime);
        self.allocator.free(self.container_image);
        self.allocator.free(self.chroot_dir);
        self.allocator.free(self.mirror_upstream);
    }

    pub fn ensureDirectories(self: Config) !void {
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const io = threaded_io.io();

        const dirs = [_][]const u8{
            self.data_root,
            self.repo_root,
            self.aur_repo_dir,
            self.custom_repo_dir,
            self.mirror_root,
            self.build_root,
            self.source_root,
            self.log_root,
        };

        for (dirs) |dir| {
            try std.Io.Dir.createDirPath(.cwd(), io, dir);
        }
    }

    pub fn sourceCheckoutDir(self: Config, allocator: std.mem.Allocator, source_name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.source_root, source_name });
    }

    pub fn packageBuildDir(self: Config, allocator: std.mem.Allocator, package_name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.build_root, package_name });
    }

    pub fn defaultRepoDir(self: Config) []const u8 {
        return self.aur_repo_dir;
    }

    pub fn repoDirForName(self: Config, repo_name: []const u8) []const u8 {
        if (std.mem.eql(u8, repo_name, "custom")) return self.custom_repo_dir;
        return self.aur_repo_dir;
    }

    pub fn mirrorCacheDir(self: Config, allocator: std.mem.Allocator, repo_name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.mirror_root, repo_name });
    }

    /// Get the standard Arch mirror path for a repository: {mirror_root}/{repo}/os/x86_64
    pub fn mirrorRepoPath(self: Config, allocator: std.mem.Allocator, repo_name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.mirror_root, repo_name, "os", "x86_64" });
    }

    pub fn repoDir(self: Config, allocator: std.mem.Allocator, repo_name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, repo_name, "custom")) {
            return allocator.dupe(u8, self.custom_repo_dir);
        }
        return allocator.dupe(u8, self.aur_repo_dir);
    }
};

fn envOrDefaultAlloc(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, key: []const u8, default_value: []const u8) ![]const u8 {
    if (environ_map.get(key)) |value| {
        return allocator.dupe(u8, value);
    }
    return allocator.dupe(u8, default_value);
}

fn envOrDefaultU16(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, key: []const u8, default_value: u16) !u16 {
    _ = allocator;
    if (environ_map.get(key)) |value| {
        return std.fmt.parseInt(u16, value, 10);
    }
    return default_value;
}

fn envOrDefaultU32(environ_map: *const std.process.Environ.Map, key: []const u8, default_value: u32) !u32 {
    if (environ_map.get(key)) |value| {
        return std.fmt.parseInt(u32, value, 10);
    }
    return default_value;
}

fn envOrDefaultBool(environ_map: *const std.process.Environ.Map, key: []const u8, default_value: bool) bool {
    if (environ_map.get(key)) |value| {
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes")) {
            return true;
        }
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no")) {
            return false;
        }
    }
    return default_value;
}

fn absolutizePath(allocator: std.mem.Allocator, cwd: []const u8, value: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    return std.fs.path.resolve(allocator, &.{ cwd, value });
}

test "BuildIsolation.fromString parses known values and defaults to none" {
    const testing = std.testing;
    try testing.expectEqual(BuildIsolation.chroot, BuildIsolation.fromString("chroot"));
    try testing.expectEqual(BuildIsolation.container, BuildIsolation.fromString("container"));
    try testing.expectEqual(BuildIsolation.none, BuildIsolation.fromString("none"));
    try testing.expectEqual(BuildIsolation.none, BuildIsolation.fromString("bogus"));
    // round-trip through toString
    try testing.expectEqualStrings("chroot", BuildIsolation.chroot.toString());
    try testing.expectEqualStrings("container", BuildIsolation.container.toString());
    try testing.expectEqualStrings("none", BuildIsolation.none.toString());
}

test "ScanPolicy.fromString parses known values and defaults to warn" {
    const testing = std.testing;
    try testing.expectEqual(ScanPolicy.off, ScanPolicy.fromString("off"));
    try testing.expectEqual(ScanPolicy.enforce, ScanPolicy.fromString("enforce"));
    try testing.expectEqual(ScanPolicy.warn, ScanPolicy.fromString("warn"));
    try testing.expectEqual(ScanPolicy.warn, ScanPolicy.fromString("nonsense"));
    try testing.expectEqualStrings("off", ScanPolicy.off.toString());
    try testing.expectEqualStrings("warn", ScanPolicy.warn.toString());
    try testing.expectEqualStrings("enforce", ScanPolicy.enforce.toString());
}

test "envOrDefaultBool honors truthy/falsy strings and default" {
    const testing = std.testing;
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try map.put("ZAUR_T", "true");
    try map.put("ZAUR_F", "0");
    try testing.expect(envOrDefaultBool(&map, "ZAUR_T", false));
    try testing.expect(!envOrDefaultBool(&map, "ZAUR_F", true));
    try testing.expect(envOrDefaultBool(&map, "ZAUR_MISSING", true));
    try testing.expect(!envOrDefaultBool(&map, "ZAUR_MISSING", false));
}
