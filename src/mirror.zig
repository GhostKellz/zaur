const std = @import("std");
const Database = @import("database.zig").Database;
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const MirrorPolicy = config_mod.MirrorPolicy;

/// Package metadata parsed from repo database
pub const PackageInfo = struct {
    name: []const u8,
    version: []const u8,
    filename: []const u8,
    arch: []const u8,

    pub fn deinit(self: PackageInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.filename);
        allocator.free(self.arch);
    }
};

pub const ArchMirror = struct {
    allocator: std.mem.Allocator,
    threaded_io: std.Io.Threaded,
    http_client: ?std.http.Client,
    mirror_url: []const u8,
    mirror_root: []const u8,
    mirror_policy: MirrorPolicy,
    database: *Database,
    bind_address: []const u8,
    port: u16,

    // Cached parsed package info per repo (in-memory cache, not authoritative)
    parsed_packages: std.StringHashMapUnmanaged([]PackageInfo),

    pub const OFFICIAL_REPOS = [_][]const u8{ "core", "extra", "multilib" };

    pub fn init(allocator: std.mem.Allocator, config: *const Config, database: *Database) !ArchMirror {
        return ArchMirror{
            .allocator = allocator,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
            .http_client = null, // Initialized lazily
            .mirror_url = config.mirror_upstream,
            .mirror_root = config.mirror_root,
            .mirror_policy = config.mirror_policy,
            .database = database,
            .bind_address = config.bind_address,
            .port = config.port,
            .parsed_packages = .empty,
        };
    }

    fn getHttpClient(self: *ArchMirror) *std.http.Client {
        if (self.http_client == null) {
            self.http_client = std.http.Client{
                .allocator = self.allocator,
                .io = self.threaded_io.io(),
            };
        }
        return &self.http_client.?;
    }

    pub fn deinit(self: *ArchMirror) void {
        // Free parsed packages
        var iter = self.parsed_packages.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.*) |pkg| {
                pkg.deinit(self.allocator);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.parsed_packages.deinit(self.allocator);

        if (self.http_client) |*client| {
            client.deinit();
        }
        self.threaded_io.deinit();
    }

    /// Sync repository database from official Arch mirror
    /// Uses standard Arch mirror path layout: {mirror_root}/{repo}/os/x86_64/
    pub fn syncRepository(self: *ArchMirror, repo: []const u8) !void {
        std.debug.print("Syncing repository: {s} from {s}\n", .{ repo, self.mirror_url });
        const io = self.threaded_io.io();

        // Create repository directory with standard Arch layout: repo/os/x86_64
        const repo_dir = try std.fs.path.join(self.allocator, &.{ self.mirror_root, repo, "os", "x86_64" });
        defer self.allocator.free(repo_dir);

        try std.Io.Dir.createDirPath(.cwd(), io, repo_dir);

        // Download repository database
        try self.downloadRepoDatabase(repo, repo_dir);

        // Parse the database to get package list and validate it's not empty
        const packages = try self.loadRepoPackages(repo);
        if (packages == 0) {
            std.debug.print("Warning: Repository {s} database contains no packages\n", .{repo});
        }

        std.debug.print("Repository {s} synced successfully ({d} packages)\n", .{ repo, packages });
    }

    /// Load and parse repo database to get package list
    /// Returns number of packages parsed
    fn loadRepoPackages(self: *ArchMirror, repo: []const u8) !usize {
        const db_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/os/x86_64/{s}.db.tar.gz", .{ self.mirror_root, repo, repo });
        defer self.allocator.free(db_path);

        const packages = try parseRepoDatabase(self.allocator, self.threaded_io.io(), db_path);

        // Store in cache (free old if exists)
        if (self.parsed_packages.get(repo)) |old_packages| {
            for (old_packages) |pkg| pkg.deinit(self.allocator);
            self.allocator.free(old_packages);
        }

        const repo_key = try self.allocator.dupe(u8, repo);
        try self.parsed_packages.put(self.allocator, repo_key, packages);

        return packages.len;
    }

    /// Download specific packages to local cache
    pub fn cachePackages(self: *ArchMirror, repo: []const u8, packages: []const []const u8) !void {
        std.debug.print("Caching {d} packages from {s}\n", .{ packages.len, repo });

        for (packages) |pkg_name| {
            self.downloadPackage(repo, pkg_name) catch |err| {
                std.debug.print("Failed to cache {s}: {}\n", .{ pkg_name, err });
            };
        }
    }

    /// Smart sync - sync repo databases only (not individual packages)
    /// This downloads the .db.tar.gz files so pacman can see what's available,
    /// but does not pre-cache any package files. Packages are downloaded on demand.
    pub fn smartSync(self: *ArchMirror) !void {
        std.debug.print("Starting smart sync (database-only)\n", .{});

        var synced: usize = 0;
        var failed: usize = 0;

        for (OFFICIAL_REPOS) |repo| {
            self.syncRepository(repo) catch |err| {
                std.debug.print("Failed to sync {s}: {}\n", .{ repo, err });
                failed += 1;
                continue;
            };
            synced += 1;
        }

        std.debug.print("Smart sync complete: {d} synced, {d} failed\n", .{ synced, failed });
    }

    /// Enable ZAUR as a complete Arch mirror replacement
    pub fn enableFullMirror(self: *ArchMirror) !void {
        std.debug.print("Enabling full Arch mirror mode\n", .{});

        // Sync all official repositories
        for (OFFICIAL_REPOS) |repo| {
            try self.syncRepository(repo);
        }

        // Generate pacman configuration
        try self.generatePacmanConfig();

        std.debug.print("Full mirror mode enabled\n", .{});
        std.debug.print("Update your /etc/pacman.conf with the generated configuration\n", .{});
    }

    /// Check for updates by comparing local cache with parsed repo database
    /// An "update" is a package that exists in the DB cache with a different version
    /// than what's currently in the repo database.
    /// Note: This requires the repo database to be loaded first (via syncRepository or loadRepoPackages)
    pub fn checkForUpdates(self: *ArchMirror, repo: []const u8) ![]const PackageInfo {
        // Ensure repo database is loaded
        if (self.parsed_packages.get(repo) == null) {
            // Try to load from disk if database file exists
            _ = self.loadRepoPackages(repo) catch {
                // No database available - can't check for updates
                return &.{};
            };
        }

        // Get cached packages from database
        const cached = try self.database.getMirrorCacheEntries(self.allocator, repo);
        defer {
            for (cached) |c| c.deinit(self.allocator);
            self.allocator.free(cached);
        }

        // Get current packages from parsed repo database
        const current = self.parsed_packages.get(repo) orelse return &.{};

        // Find packages with version changes
        var updates: std.ArrayList(PackageInfo) = .empty;

        for (current) |pkg| {
            for (cached) |c| {
                if (std.mem.eql(u8, c.package_name, pkg.name)) {
                    if (!std.mem.eql(u8, c.package_version, pkg.version)) {
                        try updates.append(self.allocator, pkg);
                    }
                    break;
                }
            }
        }

        return updates.toOwnedSlice(self.allocator);
    }

    // Private helper methods

    fn downloadRepoDatabase(self: *ArchMirror, repo: []const u8, dest_dir: []const u8) !void {
        const db_types = [_][]const u8{ "db", "files" };

        for (db_types) |db_type| {
            const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}/os/x86_64/{s}.{s}.tar.gz", .{ self.mirror_url, repo, repo, db_type });
            defer self.allocator.free(url);

            const filename = try std.fmt.allocPrint(self.allocator, "{s}.{s}.tar.gz", .{ repo, db_type });
            defer self.allocator.free(filename);

            const dest_file = try std.fs.path.join(self.allocator, &.{ dest_dir, filename });
            defer self.allocator.free(dest_file);

            // Download using HTTP client
            try self.downloadToFile(url, dest_file);
            std.debug.print("Downloaded {s}.{s}.tar.gz\n", .{ repo, db_type });
        }
    }

    fn downloadToFile(self: *ArchMirror, url: []const u8, dest_path: []const u8) !void {
        const io = self.threaded_io.io();

        const uri = try std.Uri.parse(url);
        var req = try self.getHttpClient().request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.HttpRequestFailed;
        }

        // Get expected content length for verification
        const expected_size: ?u64 = response.head.content_length;

        // Stream directly to file instead of loading into memory
        var transfer_buf: [65536]u8 = undefined; // 64KB chunks
        const reader = response.reader(&transfer_buf);

        // Create/truncate output file
        var file = try std.Io.Dir.createFile(.cwd(), io, dest_path, .{});
        defer file.close(io);

        var total_read: u64 = 0;
        const max_size: u64 = 100 * 1024 * 1024; // 100MB limit
        var had_read_error = false;

        // Stream chunks to file
        var chunk_buf: [65536]u8 = undefined;
        while (true) {
            const bytes_read = reader.readSliceShort(&chunk_buf) catch {
                // Track read errors - don't silently accept partial downloads
                had_read_error = true;
                break;
            };
            if (bytes_read == 0) break;

            total_read += bytes_read;
            if (total_read > max_size) {
                // Delete partial file before returning error
                file.close(io);
                std.Io.Dir.deleteFile(.cwd(), io, dest_path) catch {};
                return error.ResponseTooLarge;
            }

            file.writeStreamingAll(io, chunk_buf[0..bytes_read]) catch {
                // Write error - delete partial file
                file.close(io);
                std.Io.Dir.deleteFile(.cwd(), io, dest_path) catch {};
                return error.WriteError;
            };
        }

        // Validate we got actual content
        if (total_read == 0) {
            std.Io.Dir.deleteFile(.cwd(), io, dest_path) catch {};
            return error.EmptyResponse;
        }

        // If we had a read error mid-stream, the download is incomplete
        if (had_read_error) {
            std.Io.Dir.deleteFile(.cwd(), io, dest_path) catch {};
            return error.IncompleteDownload;
        }

        // Verify content length if server provided it
        if (expected_size) |expected| {
            if (total_read != expected) {
                std.Io.Dir.deleteFile(.cwd(), io, dest_path) catch {};
                return error.IncompleteDownload;
            }
        }
    }

    fn downloadPackage(self: *ArchMirror, repo: []const u8, pkg_name: []const u8) !void {
        const io = self.threaded_io.io();

        // Ensure repo database is loaded
        if (self.parsed_packages.get(repo) == null) {
            _ = try self.loadRepoPackages(repo);
        }

        // Look up package in parsed database
        const packages = self.parsed_packages.get(repo) orelse return error.RepoNotSynced;

        var filename: ?[]const u8 = null;
        var version: ?[]const u8 = null;
        for (packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, pkg_name)) {
                filename = pkg.filename;
                version = pkg.version;
                break;
            }
        }

        if (filename == null) {
            std.debug.print("Package {s} not found in {s} repo database\n", .{ pkg_name, repo });
            return error.PackageNotFound;
        }

        const pkg_url = try std.fmt.allocPrint(self.allocator, "{s}/{s}/os/x86_64/{s}", .{ self.mirror_url, repo, filename.? });
        defer self.allocator.free(pkg_url);

        // Use standard Arch mirror path layout: repo/os/x86_64/
        const dest_dir = try std.fs.path.join(self.allocator, &.{ self.mirror_root, repo, "os", "x86_64" });
        defer self.allocator.free(dest_dir);
        try std.Io.Dir.createDirPath(.cwd(), io, dest_dir);

        const dest_file = try std.fs.path.join(self.allocator, &.{ dest_dir, filename.? });
        defer self.allocator.free(dest_file);

        try self.downloadToFile(pkg_url, dest_file);

        // Get file size
        const stat = std.Io.Dir.statFile(.cwd(), io, dest_file) catch |err| {
            std.debug.print("Failed to stat downloaded file: {}\n", .{err});
            return;
        };

        // Record in database
        self.database.cacheMirrorPackage(repo, pkg_name, version.?, dest_file, @intCast(stat.size)) catch |err| {
            std.debug.print("Failed to record cache entry: {}\n", .{err});
        };

        std.debug.print("Downloaded package: {s}\n", .{pkg_name});
    }

    /// Download a package by filename (for on-demand caching)
    /// Returns the local file path if successful
    pub fn downloadPackageByFilename(self: *ArchMirror, repo: []const u8, filename: []const u8) ![]const u8 {
        const io = self.threaded_io.io();

        const pkg_url = try std.fmt.allocPrint(self.allocator, "{s}/{s}/os/x86_64/{s}", .{ self.mirror_url, repo, filename });
        defer self.allocator.free(pkg_url);

        // Use standard Arch mirror path layout: repo/os/x86_64/
        const dest_dir = try std.fs.path.join(self.allocator, &.{ self.mirror_root, repo, "os", "x86_64" });
        defer self.allocator.free(dest_dir);
        try std.Io.Dir.createDirPath(.cwd(), io, dest_dir);

        const dest_file = try std.fs.path.join(self.allocator, &.{ dest_dir, filename });

        try self.downloadToFile(pkg_url, dest_file);

        // Get file size and extract package name/version for database
        const stat = std.Io.Dir.statFile(.cwd(), io, dest_file, .{}) catch |err| {
            std.debug.print("Failed to stat downloaded file: {}\n", .{err});
            return dest_file;
        };

        // Parse package name from filename (name-version-arch.pkg.tar.zst)
        if (self.parsePackageFilename(filename)) |info| {
            self.database.cacheMirrorPackage(repo, info.name, info.version, dest_file, @intCast(stat.size)) catch |err| {
                std.debug.print("Failed to record cache entry: {}\n", .{err});
            };
        }

        return dest_file;
    }

    /// Parse package name and version from filename
    /// Format: name-version-arch.pkg.tar.zst or name-version-arch.pkg.tar.xz
    fn parsePackageFilename(self: *ArchMirror, filename: []const u8) ?struct { name: []const u8, version: []const u8 } {
        _ = self;
        // Strip extension
        var base = filename;
        if (std.mem.endsWith(u8, base, ".pkg.tar.zst")) {
            base = base[0 .. base.len - 12];
        } else if (std.mem.endsWith(u8, base, ".pkg.tar.xz")) {
            base = base[0 .. base.len - 11];
        } else {
            return null;
        }

        // Find arch suffix (last -xxx part)
        const arch_pos = std.mem.lastIndexOf(u8, base, "-") orelse return null;
        const without_arch = base[0..arch_pos];

        // Find version (second to last -xxx part)
        const version_pos = std.mem.lastIndexOf(u8, without_arch, "-") orelse return null;

        return .{
            .name = without_arch[0..version_pos],
            .version = without_arch[version_pos + 1 ..],
        };
    }

    /// Check if a package exists in a repository
    pub fn isPackageInRepo(self: *ArchMirror, pkg_name: []const u8, repo: []const u8) bool {
        // Try to ensure repo is loaded
        if (self.parsed_packages.get(repo) == null) {
            self.loadRepoPackages(repo) catch return false;
        }

        const packages = self.parsed_packages.get(repo) orelse return false;
        for (packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, pkg_name)) return true;
        }
        return false;
    }

    /// Get package info from parsed database
    pub fn getPackageInfo(self: *ArchMirror, pkg_name: []const u8, repo: []const u8) ?PackageInfo {
        // Try to ensure repo is loaded
        if (self.parsed_packages.get(repo) == null) {
            self.loadRepoPackages(repo) catch return null;
        }

        const packages = self.parsed_packages.get(repo) orelse return null;
        for (packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, pkg_name)) return pkg;
        }
        return null;
    }

    fn generatePacmanConfig(self: *ArchMirror) !void {
        const io = self.threaded_io.io();
        const config_path = try std.fs.path.join(self.allocator, &.{ self.mirror_root, "pacman.conf.zaur" });
        defer self.allocator.free(config_path);

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "# ZAUR Generated Pacman Configuration\n");
        try content.appendSlice(self.allocator, "# Add these sections to your /etc/pacman.conf\n");
        try content.appendSlice(self.allocator, "# Replace existing [core], [extra], [multilib] sections or add these before them\n\n");

        // Determine the server URL - use bind address, but replace 0.0.0.0 with localhost
        const server_host = if (std.mem.eql(u8, self.bind_address, "0.0.0.0")) "localhost" else self.bind_address;

        // Generate configuration for official repos via ZAUR using standard pacman $repo/$arch variables
        for (OFFICIAL_REPOS) |repo| {
            const repo_section = try std.fmt.allocPrint(self.allocator, "[{s}]\n", .{repo});
            defer self.allocator.free(repo_section);
            try content.appendSlice(self.allocator, repo_section);
            try content.appendSlice(self.allocator, "SigLevel = Required DatabaseOptional TrustedOnly\n");
            // Use $repo and $arch variables so pacman knows the standard layout
            const repo_server = try std.fmt.allocPrint(self.allocator, "Server = http://{s}:{d}/mirror/$repo/os/$arch\n\n", .{ server_host, self.port });
            defer self.allocator.free(repo_server);
            try content.appendSlice(self.allocator, repo_server);
        }

        // Add AUR and custom sections
        try content.appendSlice(self.allocator, "[aur]\n");
        try content.appendSlice(self.allocator, "SigLevel = Optional TrustAll\n");
        const aur_server = try std.fmt.allocPrint(self.allocator, "Server = http://{s}:{d}/aur/\n\n", .{ server_host, self.port });
        defer self.allocator.free(aur_server);
        try content.appendSlice(self.allocator, aur_server);

        try content.appendSlice(self.allocator, "[custom]\n");
        try content.appendSlice(self.allocator, "SigLevel = Optional TrustAll\n");
        const custom_server = try std.fmt.allocPrint(self.allocator, "Server = http://{s}:{d}/custom/\n\n", .{ server_host, self.port });
        defer self.allocator.free(custom_server);
        try content.appendSlice(self.allocator, custom_server);

        try std.Io.Dir.writeFile(.cwd(), io, .{
            .sub_path = config_path,
            .data = content.items,
        });

        std.debug.print("Pacman configuration written to: {s}\n", .{config_path});
    }

    /// Verify cached mirror files exist and are valid
    /// "Synced" means the repo database file exists on disk
    /// Uses standard Arch mirror path layout: repo/os/x86_64/
    pub fn verify(self: *ArchMirror) !VerifyResult {
        const io = self.threaded_io.io();
        var result = VerifyResult{
            .repos = .empty,
            .all_valid = true,
        };

        for (OFFICIAL_REPOS) |repo| {
            var repo_result = RepoVerifyResult{
                .exists = false,
                .db_exists = false,
                .package_count = 0,
            };

            // Use standard Arch mirror path layout: repo/os/x86_64
            const repo_dir = try std.fs.path.join(self.allocator, &.{ self.mirror_root, repo, "os", "x86_64" });
            defer self.allocator.free(repo_dir);

            // Check if repo directory exists
            std.Io.Dir.access(.cwd(), io, repo_dir, .{}) catch {
                try result.repos.put(self.allocator, repo, repo_result);
                result.all_valid = false;
                continue;
            };
            repo_result.exists = true;

            // Check for database file
            const db_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}.db.tar.gz", .{ repo_dir, repo });
            defer self.allocator.free(db_file);

            std.Io.Dir.access(.cwd(), io, db_file, .{}) catch {
                try result.repos.put(self.allocator, repo, repo_result);
                result.all_valid = false;
                continue;
            };
            repo_result.db_exists = true;

            // Parse database to get package count
            const packages = parseRepoDatabase(self.allocator, io, db_file) catch {
                try result.repos.put(self.allocator, repo, repo_result);
                result.all_valid = false;
                continue;
            };
            repo_result.package_count = packages.len;

            // Free parsed packages (we just needed the count)
            for (packages) |pkg| pkg.deinit(self.allocator);
            self.allocator.free(packages);

            try result.repos.put(self.allocator, repo, repo_result);
        }

        return result;
    }

    /// Auto-update: sync repos and report on available updates
    pub fn autoUpdate(self: *ArchMirror) !void {
        std.debug.print("Starting auto-update\n", .{});

        // Sync all repo databases first
        for (OFFICIAL_REPOS) |repo| {
            self.syncRepository(repo) catch |err| {
                std.debug.print("Failed to sync {s}: {}\n", .{ repo, err });
            };
        }

        // Check for updates in each repo
        for (OFFICIAL_REPOS) |repo| {
            const updates = try self.checkForUpdates(repo);
            defer self.allocator.free(updates);

            if (updates.len > 0) {
                std.debug.print("{d} updates available in {s}\n", .{ updates.len, repo });
            } else {
                std.debug.print("No updates available in {s}\n", .{repo});
            }
        }
    }

    /// Get mirror status from filesystem and database (authoritative, not in-memory)
    /// This method inspects actual disk state and database, not cached in-memory data
    /// Uses standard Arch mirror path layout: repo/os/x86_64/
    pub fn getStatus(self: *ArchMirror) !MirrorStatus {
        const io = self.threaded_io.io();
        var status = MirrorStatus{
            .repos = .empty,
            .upstream = self.mirror_url,
            .policy = self.mirror_policy,
        };

        for (OFFICIAL_REPOS) |repo| {
            var repo_status = MirrorStatus.RepoStatus{
                .packages = 0,
                .synced = false,
                .cached_packages = 0,
                .cache_size_bytes = 0,
            };

            // Check filesystem for synced state (database file exists)
            // Use standard Arch mirror path layout: repo/os/x86_64/
            const db_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/os/x86_64/{s}.db.tar.gz", .{ self.mirror_root, repo, repo });
            defer self.allocator.free(db_path);

            const db_exists = blk: {
                std.Io.Dir.access(.cwd(), io, db_path, .{}) catch break :blk false;
                break :blk true;
            };

            if (db_exists) {
                repo_status.synced = true;

                // Parse database to get accurate package count
                const packages = parseRepoDatabase(self.allocator, io, db_path) catch |err| {
                    std.debug.print("Failed to parse {s} database: {}\n", .{ repo, err });
                    try status.repos.put(self.allocator, repo, repo_status);
                    continue;
                };
                repo_status.packages = packages.len;

                // Free parsed packages
                for (packages) |pkg| pkg.deinit(self.allocator);
                self.allocator.free(packages);
            }

            // Query database for cached package count and compute cache size
            const cached = self.database.getMirrorCacheEntries(self.allocator, repo) catch {
                try status.repos.put(self.allocator, repo, repo_status);
                continue;
            };
            repo_status.cached_packages = cached.len;
            for (cached) |c| {
                repo_status.cache_size_bytes += c.file_size;
                c.deinit(self.allocator);
            }
            self.allocator.free(cached);

            try status.repos.put(self.allocator, repo, repo_status);
        }

        return status;
    }

    /// Check if a package file exists locally
    pub fn isPackageCached(self: *ArchMirror, repo: []const u8, filename: []const u8) bool {
        const io = self.threaded_io.io();
        const file_path = std.fs.path.join(self.allocator, &.{ self.mirror_root, repo, "os", "x86_64", filename }) catch return false;
        defer self.allocator.free(file_path);

        std.Io.Dir.access(.cwd(), io, file_path, .{}) catch return false;
        return true;
    }

    /// Get the local file path for a package
    pub fn getPackageFilePath(self: *ArchMirror, repo: []const u8, filename: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.mirror_root, repo, "os", "x86_64", filename });
    }
};

pub const VerifyResult = struct {
    repos: std.StringHashMapUnmanaged(RepoVerifyResult),
    all_valid: bool,

    pub fn deinit(self: *VerifyResult, allocator: std.mem.Allocator) void {
        self.repos.deinit(allocator);
    }

    pub fn print(self: *const VerifyResult) void {
        var iter = self.repos.iterator();
        while (iter.next()) |entry| {
            const repo = entry.key_ptr.*;
            const result = entry.value_ptr.*;
            if (result.db_exists) {
                std.debug.print("{s}: synced ({d} packages)\n", .{ repo, result.package_count });
            } else if (result.exists) {
                std.debug.print("{s}: directory exists but no database\n", .{repo});
            } else {
                std.debug.print("{s}: not synced\n", .{repo});
            }
        }
        if (self.all_valid) {
            std.debug.print("Mirror verification passed\n", .{});
        } else {
            std.debug.print("Mirror verification failed\n", .{});
        }
    }
};

pub const RepoVerifyResult = struct {
    exists: bool,
    db_exists: bool,
    package_count: usize,
};

pub const MirrorStatus = struct {
    repos: std.StringHashMapUnmanaged(RepoStatus),
    upstream: []const u8, // Upstream mirror URL
    policy: MirrorPolicy, // Current caching policy

    pub const RepoStatus = struct {
        packages: usize, // Total packages in repo database
        synced: bool, // Database file exists on disk
        cached_packages: usize, // Packages actually cached locally
        cache_size_bytes: u64, // Total size of cached package files
    };

    pub fn deinit(self: *MirrorStatus, allocator: std.mem.Allocator) void {
        self.repos.deinit(allocator);
    }

    /// Print status in human-readable format
    pub fn print(self: *const MirrorStatus) void {
        std.debug.print("Mirror upstream: {s}\n", .{self.upstream});
        std.debug.print("Caching policy: {s}\n", .{self.policy.toString()});
        std.debug.print("\n", .{});

        var total_packages: usize = 0;
        var total_cached: usize = 0;
        var total_size: u64 = 0;

        var iter = self.repos.iterator();
        while (iter.next()) |entry| {
            const repo = entry.key_ptr.*;
            const status = entry.value_ptr.*;
            total_packages += status.packages;
            total_cached += status.cached_packages;
            total_size += status.cache_size_bytes;

            if (status.synced) {
                const size_mb = @as(f64, @floatFromInt(status.cache_size_bytes)) / (1024.0 * 1024.0);
                std.debug.print("{s}: synced ({d} packages, {d} cached, {d:.1} MB)\n", .{ repo, status.packages, status.cached_packages, size_mb });
            } else {
                std.debug.print("{s}: not synced\n", .{repo});
            }
        }

        const total_size_mb = @as(f64, @floatFromInt(total_size)) / (1024.0 * 1024.0);
        std.debug.print("\nTotal: {d} packages available, {d} cached ({d:.1} MB)\n", .{ total_packages, total_cached, total_size_mb });
    }
};

/// Parse an Arch Linux repo database (.db.tar.gz)
/// Returns array of PackageInfo with name, version, filename, arch
/// Uses external tar command for reliable parsing
/// Returns error.EmptyDatabase if database contains no valid packages
/// Returns error.CorruptedDatabase if database cannot be parsed
pub fn parseRepoDatabase(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) ![]PackageInfo {
    // Use tar to list and extract desc files
    var packages: std.ArrayList(PackageInfo) = .empty;
    errdefer {
        for (packages.items) |pkg| pkg.deinit(allocator);
        packages.deinit(allocator);
    }

    // First, list all files to find desc files
    const list_result = std.process.run(allocator, io, .{
        .argv = &.{ "tar", "-tzf", db_path },
    }) catch {
        return error.CorruptedDatabase;
    };
    defer allocator.free(list_result.stdout);
    defer allocator.free(list_result.stderr);

    // Check if tar command succeeded
    if (list_result.term != .exited or list_result.term.exited != 0) {
        return error.CorruptedDatabase;
    }

    // Check for empty output (empty or corrupted database)
    if (list_result.stdout.len == 0) {
        return error.EmptyDatabase;
    }

    // Parse the file list to find desc files
    var desc_count: usize = 0;
    var lines = std.mem.splitScalar(u8, list_result.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, "/desc")) continue;
        desc_count += 1;

        // Extract this desc file's content
        const extract_result = std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xOzf", db_path, line },
        }) catch continue;
        defer allocator.free(extract_result.stdout);
        defer allocator.free(extract_result.stderr);

        // Parse the desc file
        if (parseDescFile(allocator, extract_result.stdout)) |pkg| {
            try packages.append(allocator, pkg);
        } else |_| {
            // Skip malformed desc files
        }
    }

    // If we found desc files but couldn't parse any, database is corrupted
    if (desc_count > 0 and packages.items.len == 0) {
        return error.CorruptedDatabase;
    }

    // If no desc files found at all, database is empty (might be valid but unusual)
    if (desc_count == 0) {
        return error.EmptyDatabase;
    }

    return packages.toOwnedSlice(allocator);
}

/// Parse a desc file from the repo database
fn parseDescFile(allocator: std.mem.Allocator, content: []const u8) !PackageInfo {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var arch: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_field: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (line.len == 0) {
            current_field = null;
            continue;
        }

        if (std.mem.startsWith(u8, line, "%") and std.mem.endsWith(u8, line, "%")) {
            current_field = line;
            continue;
        }

        if (current_field) |field| {
            if (std.mem.eql(u8, field, "%NAME%")) {
                name = try allocator.dupe(u8, line);
            } else if (std.mem.eql(u8, field, "%VERSION%")) {
                version = try allocator.dupe(u8, line);
            } else if (std.mem.eql(u8, field, "%FILENAME%")) {
                filename = try allocator.dupe(u8, line);
            } else if (std.mem.eql(u8, field, "%ARCH%")) {
                arch = try allocator.dupe(u8, line);
            }
        }
    }

    if (name == null or version == null or filename == null) {
        if (name) |n| allocator.free(n);
        if (version) |v| allocator.free(v);
        if (filename) |f| allocator.free(f);
        if (arch) |a| allocator.free(a);
        return error.InvalidDescFile;
    }

    return PackageInfo{
        .name = name.?,
        .version = version.?,
        .filename = filename.?,
        .arch = arch orelse try allocator.dupe(u8, "x86_64"),
    };
}

/// Mirror management commands
pub const MirrorCommands = struct {
    pub fn handleVerify(allocator: std.mem.Allocator, config: *const Config, database: *Database) !void {
        var mirror = try ArchMirror.init(allocator, config, database);
        defer mirror.deinit();

        var result = try mirror.verify();
        defer result.deinit(allocator);
        result.print();
    }

    pub fn handleSync(allocator: std.mem.Allocator, args: []const []const u8, config: *const Config, database: *Database) !void {
        var mirror = try ArchMirror.init(allocator, config, database);
        defer mirror.deinit();

        if (args.len == 0) {
            // Sync all repositories
            try mirror.enableFullMirror();
        } else {
            // Sync specific repositories
            for (args) |repo| {
                try mirror.syncRepository(repo);
            }
        }
    }

    pub fn handleSmartSync(allocator: std.mem.Allocator, config: *const Config, database: *Database) !void {
        var mirror = try ArchMirror.init(allocator, config, database);
        defer mirror.deinit();

        try mirror.smartSync();
    }

    pub fn handleAutoUpdate(allocator: std.mem.Allocator, config: *const Config, database: *Database) !void {
        var mirror = try ArchMirror.init(allocator, config, database);
        defer mirror.deinit();

        // Sync repos first
        try mirror.smartSync();

        // Check for updates in each repo
        for (ArchMirror.OFFICIAL_REPOS) |repo| {
            const updates = try mirror.checkForUpdates(repo);
            defer allocator.free(updates);

            if (updates.len > 0) {
                std.debug.print("{d} updates available in {s}\n", .{ updates.len, repo });
            } else {
                std.debug.print("No updates available in {s}\n", .{repo});
            }
        }
    }
};
