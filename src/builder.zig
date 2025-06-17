const std = @import("std");

pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    build_dir: []const u8,
    output_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, build_dir: []const u8, output_dir: []const u8) PackageBuilder {
        return PackageBuilder{
            .allocator = allocator,
            .build_dir = build_dir,
            .output_dir = output_dir,
        };
    }

    pub fn buildPackage(self: *PackageBuilder, package_name: []const u8) !BuildResult {
        const package_dir = try std.fs.path.join(self.allocator, &.{ self.build_dir, package_name });
        defer self.allocator.free(package_dir);

        // Check if PKGBUILD exists
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ package_dir, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);

        std.fs.accessAbsolute(pkgbuild_path, .{}) catch {
            return BuildResult{
                .success = false,
                .log = try self.allocator.dupe(u8, "PKGBUILD not found"),
            };
        };

        // Create output directory if it doesn't exist
        std.fs.makeDirAbsolute(self.output_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Execute makepkg
        var child = std.process.Child.init(&.{
            "makepkg",
            "-s", // install missing dependencies
            "-f", // overwrite existing package
            "--noconfirm",
        }, self.allocator);

        child.cwd = package_dir;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);

        const result = try child.wait();
        const success = result == .Exited and result.Exited == 0;

        // Move built packages to output directory
        if (success) {
            try self.moveBuiltPackages(package_dir);
        }

        const log = try std.fmt.allocPrint(self.allocator, "STDOUT:\n{s}\n\nSTDERR:\n{s}", .{ stdout, stderr });

        self.allocator.free(stdout);
        self.allocator.free(stderr);

        return BuildResult{
            .success = success,
            .log = log,
        };
    }

    fn moveBuiltPackages(self: *PackageBuilder, package_dir: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(package_dir, .{ .iterate = true });
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                const src_path = try std.fs.path.join(self.allocator, &.{ package_dir, entry.name });
                defer self.allocator.free(src_path);

                const dst_path = try std.fs.path.join(self.allocator, &.{ self.output_dir, entry.name });
                defer self.allocator.free(dst_path);

                try std.fs.copyFileAbsolute(src_path, dst_path, .{});
                std.debug.print("Moved package: {s}\n", .{entry.name});

                // Sign the package if GPG key is configured
                const zaur = @import("root.zig");
                var gpg_signer = zaur.GpgSigner.init(self.allocator);
                gpg_signer.signPackage(dst_path) catch |err| {
                    std.debug.print("⚠️  Warning: Could not sign package {s}: {}\n", .{ entry.name, err });
                };
            }
        }
    }

    pub fn buildZigProject(self: *PackageBuilder, package_name: []const u8) !BuildResult {
        const package_dir = try std.fs.path.join(self.allocator, &.{ self.build_dir, package_name });
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

        std.fs.accessAbsolute(pkgbuild_path, .{}) catch {
            try dep_resolver.generateZigPkgbuild(package_name, package_dir);
        };

        // Build using standard makepkg process
        return try self.buildPackage(package_name);
    }
};

pub const BuildResult = struct {
    success: bool,
    log: []const u8,

    pub fn deinit(self: BuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.log);
    }
};
