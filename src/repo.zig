const std = @import("std");

pub const RepoManager = struct {
    allocator: std.mem.Allocator,
    repo_dir: []const u8,
    db_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_dir: []const u8, db_name: []const u8) RepoManager {
        return RepoManager{
            .allocator = allocator,
            .repo_dir = repo_dir,
            .db_name = db_name,
        };
    }

    pub fn generateRepoDatabase(self: *RepoManager) !void {
        // Ensure repo directory exists
        std.fs.makeDirAbsolute(self.repo_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Get all .pkg.tar.zst files in the directory
        var package_files: std.ArrayList([]const u8) = .{};
        defer {
            for (package_files.items) |file| {
                self.allocator.free(file);
            }
            package_files.deinit(self.allocator);
        }

        var dir = try std.fs.openDirAbsolute(self.repo_dir, .{ .iterate = true });
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                try package_files.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }

        if (package_files.items.len == 0) {
            std.debug.print("No packages found in {s}\n", .{self.repo_dir});
            return;
        }

        // Build repo-add command
        var args: std.ArrayList([]const u8) = .{};
        defer args.deinit(self.allocator);

        const db_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.db.tar.zst", .{ self.repo_dir, self.db_name });
        defer self.allocator.free(db_path);

        try args.append(self.allocator, "repo-add");
        try args.append(self.allocator, db_path);
        
        for (package_files.items) |pkg_file| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.repo_dir, pkg_file });
            try args.append(self.allocator, full_path);
        }

        // Execute repo-add
        var child = std.process.Child.init(args.items, self.allocator);
        child.cwd = self.repo_dir;
        
        const result = try child.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
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
        // TODO: Implement cleanup of old package versions
        _ = self;
        _ = keep_versions;
        std.debug.print("Package cleanup not yet implemented\n", .{});
    }

    pub fn listPackages(self: *RepoManager) !void {
        var dir = try std.fs.openDirAbsolute(self.repo_dir, .{ .iterate = true });
        defer dir.close();

        std.debug.print("Packages in repository:\n", .{});
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                std.debug.print("  {s}\n", .{entry.name});
            }
        }
    }
};