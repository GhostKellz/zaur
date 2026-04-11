const std = @import("std");
const SourceManager = @import("source.zig");
const Config = @import("config.zig").Config;

pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    source_root: []const u8,
    build_root: []const u8,
    output_dir: []const u8,
    config: ?*const Config,
    threaded_io: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, source_root: []const u8, build_root: []const u8, output_dir: []const u8, config: ?*const Config) PackageBuilder {
        return PackageBuilder{
            .allocator = allocator,
            .source_root = source_root,
            .build_root = build_root,
            .output_dir = output_dir,
            .config = config,
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

        // Create output directory if it doesn't exist
        try std.Io.Dir.createDirPath(.cwd(), self.threaded_io.io(), self.output_dir);

        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{
                "makepkg",
                "-s",
                "-f",
                "--noconfirm",
            },
            .cwd = .{ .path = package_dir },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const success = result.term == .exited and result.term.exited == 0;

        // Move built packages to output directory
        if (success) {
            try self.moveBuiltPackages(package_dir);
        }

        const log = try std.fmt.allocPrint(self.allocator, "STDOUT:\n{s}\n\nSTDERR:\n{s}", .{ result.stdout, result.stderr });

        return BuildResult{
            .success = success,
            .log = log,
        };
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
