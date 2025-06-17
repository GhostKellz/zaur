const std = @import("std");

pub const DependencyResolver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DependencyResolver {
        return DependencyResolver{
            .allocator = allocator,
        };
    }

    pub fn parsePkgbuildDependencies(self: *DependencyResolver, pkgbuild_path: []const u8) !PackageDependencies {
        const file = try std.fs.openFileAbsolute(pkgbuild_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var depends = std.ArrayList([]const u8).init(self.allocator);
        var makedepends = std.ArrayList([]const u8).init(self.allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (std.mem.startsWith(u8, trimmed, "depends=(")) {
                try self.parseDependencyArray(trimmed, &depends);
            } else if (std.mem.startsWith(u8, trimmed, "makedepends=(")) {
                try self.parseDependencyArray(trimmed, &makedepends);
            }
        }

        return PackageDependencies{
            .depends = try depends.toOwnedSlice(),
            .makedepends = try makedepends.toOwnedSlice(),
        };
    }

    fn parseDependencyArray(self: *DependencyResolver, line: []const u8, deps: *std.ArrayList([]const u8)) !void {
        // Extract content between parentheses
        const start = std.mem.indexOf(u8, line, "(") orelse return;
        const end = std.mem.lastIndexOf(u8, line, ")") orelse return;

        if (start >= end) return;

        const deps_content = line[start + 1 .. end];

        // Split by spaces and clean up
        var parts = std.mem.splitScalar(u8, deps_content, ' ');
        while (parts.next()) |part| {
            var clean_part = std.mem.trim(u8, part, " \t\"'");

            // Remove version constraints (e.g., "package>=1.0" -> "package")
            if (std.mem.indexOfAny(u8, clean_part, ">=<=")) |pos| {
                clean_part = clean_part[0..pos];
            }

            if (clean_part.len > 0) {
                try deps.append(try self.allocator.dupe(u8, clean_part));
            }
        }
    }

    pub fn resolveBuildOrder(self: *DependencyResolver, packages: []PackageWithDeps) ![][]const u8 {
        var visited = std.HashMap([]const u8, bool, std.hash_map.StringContext, 80).init(self.allocator);
        defer visited.deinit();

        var build_order = std.ArrayList([]const u8).init(self.allocator);
        defer build_order.deinit();

        // Topological sort using DFS
        for (packages) |pkg| {
            try self.dfsVisit(pkg.name, packages, &visited, &build_order);
        }

        return try build_order.toOwnedSlice();
    }

    fn dfsVisit(self: *DependencyResolver, pkg_name: []const u8, packages: []PackageWithDeps, visited: *std.HashMap([]const u8, bool, std.hash_map.StringContext, 80), build_order: *std.ArrayList([]const u8)) !void {
        if (visited.get(pkg_name) != null) return;

        try visited.put(pkg_name, true);

        // Find this package in the list
        for (packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, pkg_name)) {
                // Visit dependencies first
                for (pkg.deps.makedepends) |dep| {
                    // Check if dependency is in our package list
                    for (packages) |dep_pkg| {
                        if (std.mem.eql(u8, dep_pkg.name, dep)) {
                            try self.dfsVisit(dep, packages, visited, build_order);
                            break;
                        }
                    }
                }
                break;
            }
        }

        try build_order.append(pkg_name);
    }

    pub fn checkZigProject(self: *DependencyResolver, package_dir: []const u8) !bool {
        const build_zig = try std.fs.path.join(self.allocator, &.{ package_dir, "build.zig" });
        defer self.allocator.free(build_zig);

        std.fs.accessAbsolute(build_zig, .{}) catch {
            return false; // Not a Zig project
        };

        return true;
    }

    pub fn generateZigPkgbuild(self: *DependencyResolver, package_name: []const u8, package_dir: []const u8) !void {
        const pkgbuild_content = try std.fmt.allocPrint(self.allocator,
            \\# Maintainer: GhostCTL AUR <aur@ghostctl.com>
            \\pkgname={s}
            \\pkgver=1.0.0
            \\pkgrel=1
            \\pkgdesc="Zig package built by ZAUR"
            \\arch=('x86_64')
            \\url=""
            \\license=('MIT')
            \\makedepends=('zig>=0.15.0')
            \\source=()
            \\sha256sums=()
            \\
            \\build() {{
            \\    cd "$srcdir"
            \\    zig build -Doptimize=ReleaseFast
            \\}}
            \\
            \\package() {{
            \\    cd "$srcdir"
            \\    zig build install --prefix "$pkgdir/usr"
            \\}}
        , .{package_name});
        defer self.allocator.free(pkgbuild_content);

        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ package_dir, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);

        const file = try std.fs.createFileAbsolute(pkgbuild_path, .{});
        defer file.close();

        try file.writeAll(pkgbuild_content);
        std.debug.print("🦎 Generated Zig PKGBUILD for: {s}\n", .{package_name});
    }
};

pub const PackageDependencies = struct {
    depends: [][]const u8,
    makedepends: [][]const u8,

    pub fn deinit(self: PackageDependencies, allocator: std.mem.Allocator) void {
        for (self.depends) |dep| allocator.free(dep);
        for (self.makedepends) |dep| allocator.free(dep);
        allocator.free(self.depends);
        allocator.free(self.makedepends);
    }
};

pub const PackageWithDeps = struct {
    name: []const u8,
    deps: PackageDependencies,
};
