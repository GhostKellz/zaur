const std = @import("std");
const vercmp = @import("version.zig").vercmp;

pub const RepoManager = struct {
    allocator: std.mem.Allocator,
    repo_dir: []const u8,
    db_name: []const u8,
    threaded_io: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, repo_dir: []const u8, db_name: []const u8) RepoManager {
        return RepoManager{
            .allocator = allocator,
            .repo_dir = repo_dir,
            .db_name = db_name,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
        };
    }

    pub fn deinit(self: *RepoManager) void {
        self.threaded_io.deinit();
    }

    pub fn generateRepoDatabase(self: *RepoManager) !void {
        try std.Io.Dir.createDirPath(.cwd(), self.threaded_io.io(), self.repo_dir);

        // Get all .pkg.tar.zst files in the directory
        var package_files: std.ArrayList([]const u8) = .empty;
        defer {
            for (package_files.items) |file| {
                self.allocator.free(file);
            }
            package_files.deinit(self.allocator);
        }

        var dir = try std.Io.Dir.openDir(.cwd(), self.threaded_io.io(), self.repo_dir, .{ .iterate = true });
        defer dir.close(self.threaded_io.io());

        var iterator = dir.iterate();
        while (try iterator.next(self.threaded_io.io())) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                try package_files.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }

        if (package_files.items.len == 0) {
            std.debug.print("No packages found in {s}\n", .{self.repo_dir});
            return;
        }

        // Build repo-add command
        var args: std.ArrayList([]const u8) = .empty;

        const db_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.db.tar.zst", .{ self.repo_dir, self.db_name });
        defer self.allocator.free(db_path);

        try args.append(self.allocator, "repo-add");
        try args.append(self.allocator, db_path);

        for (package_files.items) |pkg_file| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.repo_dir, pkg_file });
            try args.append(self.allocator, full_path);
        }

        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = args.items,
            .cwd = .{ .path = self.repo_dir },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            if (result.stderr.len > 0) {
                std.debug.print("repo-add failed:\n{s}\n", .{result.stderr});
            }
            return error.RepoAddFailed;
        }

        // Clean up full paths
        for (args.items[2..]) |path| {
            self.allocator.free(path);
        }
        args.deinit(self.allocator);

        std.debug.print("Repository database generated: {s}\n", .{db_path});
    }

    pub fn cleanOldPackages(self: *RepoManager, keep_versions: u32) !void {
        const io = self.threaded_io.io();

        // Collect all package files
        var package_files: std.ArrayList([]const u8) = .empty;
        defer {
            for (package_files.items) |f| self.allocator.free(f);
            package_files.deinit(self.allocator);
        }

        var dir = try std.Io.Dir.openDir(.cwd(), io, self.repo_dir, .{ .iterate = true });
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                try package_files.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }

        // Group by package name (strip version-pkgrel-arch.pkg.tar.zst)
        var groups: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        defer {
            var it = groups.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.deinit(self.allocator);
            }
            groups.deinit(self.allocator);
        }

        for (package_files.items) |filename| {
            const pkg_name = extractPackageName(filename) orelse continue;
            const gop = try groups.getOrPut(self.allocator, pkg_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(self.allocator, filename);
        }

        // For each group, delete all but the newest keep_versions
        var deleted_count: usize = 0;
        var git = groups.iterator();
        while (git.next()) |kv| {
            var versions = kv.value_ptr.items;
            if (versions.len <= keep_versions) continue;

            // Sort by version descending using proper version comparison
            std.mem.sort([]const u8, versions, {}, struct {
                fn cmp(_: void, a: []const u8, b: []const u8) bool {
                    // Extract version strings and compare properly
                    const ver_a = extractVersionString(a) orelse return false;
                    const ver_b = extractVersionString(b) orelse return true;
                    return compareVersions(ver_a, ver_b) == .gt;
                }
            }.cmp);

            // Delete older versions beyond keep_versions
            for (versions[keep_versions..]) |old_file| {
                const path = try std.fs.path.join(self.allocator, &.{ self.repo_dir, old_file });
                defer self.allocator.free(path);
                std.Io.Dir.deleteFile(.cwd(), io, path) catch continue;
                deleted_count += 1;
            }
        }

        if (deleted_count > 0) {
            std.debug.print("Cleaned up {d} old package version(s)\n", .{deleted_count});
        } else {
            std.debug.print("No old packages to clean up\n", .{});
        }
    }

    fn extractPackageName(filename: []const u8) ?[]const u8 {
        // Package format: pkgname-version-pkgrel-arch.pkg.tar.zst
        // We need to extract pkgname by finding version pattern
        const base = if (std.mem.endsWith(u8, filename, ".pkg.tar.zst"))
            filename[0 .. filename.len - 15]
        else
            return null;

        // Find arch suffix (x86_64, any, etc)
        var last_dash = std.mem.lastIndexOfScalar(u8, base, '-') orelse return null;
        const before_arch = base[0..last_dash];

        // Find pkgrel
        last_dash = std.mem.lastIndexOfScalar(u8, before_arch, '-') orelse return null;
        const before_pkgrel = before_arch[0..last_dash];

        // Find version - everything before this is the package name
        last_dash = std.mem.lastIndexOfScalar(u8, before_pkgrel, '-') orelse return null;
        return before_pkgrel[0..last_dash];
    }

    fn extractVersionString(filename: []const u8) ?[]const u8 {
        // Package format: pkgname-version-pkgrel-arch.pkg.tar.zst
        // Extract "version-pkgrel" part
        const base = if (std.mem.endsWith(u8, filename, ".pkg.tar.zst"))
            filename[0 .. filename.len - 15]
        else
            return null;

        // Find arch suffix
        var last_dash = std.mem.lastIndexOfScalar(u8, base, '-') orelse return null;
        const before_arch = base[0..last_dash];

        // Find pkgrel
        last_dash = std.mem.lastIndexOfScalar(u8, before_arch, '-') orelse return null;
        const before_pkgrel = before_arch[0..last_dash];

        // Find version start
        last_dash = std.mem.lastIndexOfScalar(u8, before_pkgrel, '-') orelse return null;

        // Return "version-pkgrel"
        return before_arch[last_dash + 1 ..];
    }

    fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
        // Use unified pacman-compatible version comparison
        return vercmp(a, b);
    }

    pub fn listPackages(self: *RepoManager) !void {
        var dir = try std.Io.Dir.openDir(.cwd(), self.threaded_io.io(), self.repo_dir, .{ .iterate = true });
        defer dir.close(self.threaded_io.io());

        std.debug.print("Packages in repository:\n", .{});
        var iterator = dir.iterate();
        while (try iterator.next(self.threaded_io.io())) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                std.debug.print("  {s}\n", .{entry.name});
            }
        }
    }
};
