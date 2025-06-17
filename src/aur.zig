const std = @import("std");

pub const AurClient = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) AurClient {
        return AurClient{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *AurClient) void {
        self.http_client.deinit();
    }

    pub fn searchPackage(self: *AurClient, package_name: []const u8) !?AurPackage {
        const uri_string = try std.fmt.allocPrint(self.allocator, "https://aur.archlinux.org/rpc/?v=5&type=info&arg={s}", .{package_name});
        defer self.allocator.free(uri_string);

        const uri = try std.Uri.parse(uri_string);

        // Use a simple buffer for headers
        var header_buffer: [4096]u8 = undefined;

        var req = try self.http_client.open(.GET, uri, .{
            .server_header_buffer = &header_buffer,
        });
        defer req.deinit();

        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            return null;
        }

        const body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(body);

        // Parse JSON response
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
            std.debug.print("Failed to parse AUR response: {}\n", .{err});
            return null;
        };
        defer parsed.deinit();

        const results = parsed.value.object.get("results") orelse return null;
        const results_array = results.array;

        if (results_array.items.len == 0) {
            return null;
        }

        const pkg_obj = results_array.items[0].object;
        const name = pkg_obj.get("Name").?.string;
        const version = pkg_obj.get("Version").?.string;
        const description = if (pkg_obj.get("Description")) |desc| desc.string else "No description";
        const url_path = pkg_obj.get("URLPath").?.string;

        return AurPackage{
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, version),
            .description = try self.allocator.dupe(u8, description),
            .url_path = try self.allocator.dupe(u8, url_path),
        };
    }

    pub fn downloadPkgbuild(self: *AurClient, package_name: []const u8, dest_dir: []const u8) !void {
        // Clone the AUR package repository
        const git_url = try std.fmt.allocPrint(self.allocator, "https://aur.archlinux.org/{s}.git", .{package_name});
        defer self.allocator.free(git_url);

        const dest_path = try std.fs.path.join(self.allocator, &.{ dest_dir, package_name });
        defer self.allocator.free(dest_path);

        // Execute git clone
        var child = std.process.Child.init(&.{ "git", "clone", git_url, dest_path }, self.allocator);
        const result = try child.spawnAndWait();

        if (result != .Exited or result.Exited != 0) {
            return error.GitCloneFailed;
        }
    }

    pub fn downloadFromGitHub(self: *AurClient, repo_spec: []const u8, dest_dir: []const u8) !void {
        // Parse "user/repo" or "user/repo@branch" or "user/repo/path"
        var parts = std.mem.splitScalar(u8, repo_spec, '/');
        const user = parts.next() orelse return error.InvalidRepoSpec;
        var repo_and_branch = parts.next() orelse return error.InvalidRepoSpec;
        const subpath = parts.rest();

        // Check for branch specification
        var branch: []const u8 = "main";
        var repo = repo_and_branch;
        if (std.mem.indexOf(u8, repo_and_branch, "@")) |at_pos| {
            repo = repo_and_branch[0..at_pos];
            branch = repo_and_branch[at_pos + 1 ..];
        }

        const git_url = try std.fmt.allocPrint(self.allocator, "https://github.com/{s}/{s}.git", .{ user, repo });
        defer self.allocator.free(git_url);

        const dest_path = try std.fs.path.join(self.allocator, &.{ dest_dir, repo });
        defer self.allocator.free(dest_path);

        // Clone repository
        var child = std.process.Child.init(&.{ "git", "clone", "-b", branch, git_url, dest_path }, self.allocator);
        const result = try child.spawnAndWait();

        if (result != .Exited or result.Exited != 0) {
            return error.GitCloneFailed;
        }

        // If subpath specified, move PKGBUILD to root
        if (subpath.len > 0) {
            const pkgbuild_src = try std.fs.path.join(self.allocator, &.{ dest_path, subpath, "PKGBUILD" });
            defer self.allocator.free(pkgbuild_src);

            const pkgbuild_dst = try std.fs.path.join(self.allocator, &.{ dest_path, "PKGBUILD" });
            defer self.allocator.free(pkgbuild_dst);

            std.fs.copyFileAbsolute(pkgbuild_src, pkgbuild_dst, .{}) catch |err| {
                std.debug.print("Warning: Could not find PKGBUILD at {s}: {}\n", .{ pkgbuild_src, err });
            };
        }

        std.debug.print("✓ Downloaded GitHub repository: {s}\n", .{repo_spec});
    }

    pub fn checkForUpdates(self: *AurClient, package_name: []const u8) !?[]const u8 {
        const aur_package = try self.searchPackage(package_name);
        if (aur_package) |pkg| {
            defer pkg.deinit(self.allocator);
            return try self.allocator.dupe(u8, pkg.version);
        }
        return null;
    }
};

pub const AurPackage = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    url_path: []const u8,

    pub fn deinit(self: AurPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.url_path);
    }
};
