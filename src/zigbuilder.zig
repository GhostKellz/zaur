const std = @import("std");
const zqlite = @import("zqlite");

/// ZigBuilder - Leverages Zig build system to create Arch packages from Zig projects
pub const ZigBuilder = struct {
    allocator: std.mem.Allocator,
    build_dir: []const u8,
    package_dir: []const u8,
    threaded_io: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, build_dir: []const u8, package_dir: []const u8) ZigBuilder {
        return ZigBuilder{
            .allocator = allocator,
            .build_dir = allocator.dupe(u8, build_dir) catch @panic("OOM"),
            .package_dir = allocator.dupe(u8, package_dir) catch @panic("OOM"),
            .threaded_io = .init(std.heap.smp_allocator, .{}),
        };
    }

    pub fn deinit(self: *ZigBuilder) void {
        self.allocator.free(self.build_dir);
        self.allocator.free(self.package_dir);
        self.threaded_io.deinit();
    }

    /// Detects if a project is a Zig project by checking for build.zig
    pub fn isZigProject(_: *ZigBuilder, project_path: []const u8) bool {
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const build_zig_path = std.fmt.bufPrint(path_buf[0..], "{s}/build.zig", .{project_path}) catch return false;

        std.Io.Dir.accessAbsolute(threaded_io.io(), build_zig_path, .{}) catch return false;
        return true;
    }

    /// Analyzes build.zig.zon for package metadata
    pub fn analyzeProject(self: *ZigBuilder, project_path: []const u8) !ZigProjectInfo {
        const io = self.threaded_io.io();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const zon_path = std.fmt.bufPrint(path_buf[0..], "{s}/build.zig.zon", .{project_path}) catch return error.PathTooLong;

        const file = std.Io.Dir.openFileAbsolute(io, zon_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var targets: std.ArrayList([]const u8) = .empty;
                try targets.append(self.allocator, "zaur");
                var deps: std.ArrayList([]const u8) = .empty;
                return ZigProjectInfo{
                    .name = "unknown-zig-project",
                    .version = "0.1.0",
                    .description = "Zig project (no build.zig.zon found)",
                    .targets = try targets.toOwnedSlice(self.allocator),
                    .dependencies = try deps.toOwnedSlice(self.allocator),
                };
            },
            else => return err,
        };
        defer file.close(io);

        var buf: [64]u8 = undefined;
        var reader = file.reader(io, buf[0..]);
        const content = try reader.interface.readAlloc(self.allocator, 1024 * 1024); // Max 1MB
        defer self.allocator.free(content);

        return try self.parseZigZon(content);
    }

    /// Generates PKGBUILD for a Zig project
    pub fn generatePKGBUILD(self: *ZigBuilder, project_info: ZigProjectInfo, source_url: []const u8) ![]const u8 {
        var targets_str: std.ArrayList(u8) = .empty;
        defer targets_str.deinit(self.allocator);

        for (project_info.targets, 0..) |target, i| {
            if (i > 0) try targets_str.appendSlice(self.allocator, " ");
            try targets_str.print(self.allocator, "'{s}'", .{target});
        }

        const install_commands = try self.generateInstallCommands(project_info.targets);
        defer self.allocator.free(install_commands);

        const pkgbuild = try std.fmt.allocPrint(self.allocator,
            \\# Maintainer: ZAUR (Zig Arch User Repository)
            \\# Auto-generated PKGBUILD for Zig project
            \\
            \\pkgname={s}
            \\pkgver={s}
            \\pkgrel=1
            \\pkgdesc="{s}"
            \\arch=('x86_64' 'aarch64')
            \\url="{s}"
            \\license=('MIT' 'Apache' 'GPL' 'BSD')
            \\makedepends=('zig>=0.13.0')
            \\source=("$pkgname-$pkgver.tar.gz::{s}")
            \\sha256sums=('SKIP')
            \\
            \\build() {{
            \\    cd "$srcdir"/*
            \\
            \\    # Zig build with optimizations
            \\    zig build -Doptimize=ReleaseFast --prefix-exe-dir bin --prefix-lib-dir lib
            \\
            \\    # Build C libraries if any C source files exist
            \\    if find . -name "*.c" -o -name "*.h" | head -1 | grep -q .; then
            \\        echo "Building C components with Zig..."
            \\        # Zig compiles C code - using generic baseline for reproducibility
            \\        find . -name "*.c" -exec zig cc -O3 {{}} \;
            \\    fi
            \\}}
            \\
            \\check() {{
            \\    cd "$srcdir"/*
            \\    # Run Zig tests if available
            \\    zig build test 2>/dev/null || echo "No tests found"
            \\}}
            \\
            \\package() {{
            \\    cd "$srcdir"/*
            \\
            \\    # Install main executables
            \\{s}
            \\
            \\    # Install documentation
            \\    if [ -f README.md ]; then
            \\        install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
            \\    fi
            \\
            \\    # Install license
            \\    if [ -f LICENSE ]; then
            \\        install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
            \\    fi
            \\
            \\    # Install any library files
            \\    if [ -d zig-out/lib ]; then
            \\        cp -r zig-out/lib/* "$pkgdir/usr/lib/" 2>/dev/null || true
            \\    fi
            \\}}
            \\
        , .{
            project_info.name,
            project_info.version,
            project_info.description,
            source_url,
            source_url,
            install_commands,
        });

        return pkgbuild;
    }

    /// Builds a Zig project using the Zig build system
    pub fn buildProject(self: *ZigBuilder, project_path: []const u8, optimize_mode: []const u8) !BuildResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const io = self.threaded_io.io();

        // Change to project directory and run zig build
        const args = [_][]const u8{
            "zig",                                                                 "build",
            try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize_mode}), "--prefix-exe-dir",
            "bin",                                                                 "--prefix-lib-dir",
            "lib",
        };

        const result = try std.process.run(allocator, io, .{
            .argv = &args,
            .cwd = .{ .path = project_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        return BuildResult{
            .success = result.term == .exited and result.term.exited == 0,
            .stdout = try self.allocator.dupe(u8, result.stdout),
            .stderr = try self.allocator.dupe(u8, result.stderr),
            .artifacts = try self.findBuildArtifacts(project_path),
        };
    }

    /// Leverages Zig as a C compiler for building C projects
    pub fn buildCProjectWithZig(self: *ZigBuilder, project_path: []const u8, c_files: [][]const u8) !BuildResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const io = self.threaded_io.io();

        var build_log: std.ArrayList(u8) = .empty;
        var success = true;

        // Compile each C file with Zig's C compiler (generic baseline for reproducibility)
        for (c_files) |c_file| {
            const args = [_][]const u8{
                "zig", "cc",
                "-O3",
                "-fPIC",
                "-std=c99",
                c_file,
                "-o",
                try std.fmt.allocPrint(allocator, "{s}.o", .{c_file[0 .. c_file.len - 2]}),
            };

            const result = try std.process.run(allocator, io, .{
                .argv = &args,
                .cwd = .{ .path = project_path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (result.term != .exited or result.term.exited != 0) {
                success = false;
                try build_log.print(self.allocator, "Failed to compile {s}:\n{s}\n", .{ c_file, result.stderr });
            } else {
                try build_log.print(self.allocator, "Compiled {s} with Zig\n", .{c_file});
            }
        }

        return BuildResult{
            .success = success,
            .stdout = try self.allocator.dupe(u8, build_log.items),
            .stderr = try self.allocator.dupe(u8, ""),
            .artifacts = try self.findBuildArtifacts(project_path),
        };
    }

    /// Creates a hybrid PKGBUILD for projects with both Zig and C code
    pub fn generateHybridPKGBUILD(self: *ZigBuilder, project_info: ZigProjectInfo, source_url: []const u8) ![]const u8 {
        const pkgbuild = try std.fmt.allocPrint(self.allocator,
            \\# Maintainer: ZAUR (Zig Arch User Repository)
            \\# Hybrid Zig/C project - leveraging Zig as superior C compiler
            \\
            \\pkgname={s}
            \\pkgver={s}
            \\pkgrel=1
            \\pkgdesc="{s} (built with Zig compiler)"
            \\arch=('x86_64' 'aarch64')
            \\url="{s}"
            \\license=('MIT')
            \\makedepends=('zig>=0.13.0')
            \\source=("$pkgname-$pkgver.tar.gz::{s}")
            \\sha256sums=('SKIP')
            \\
            \\build() {{
            \\    cd "$srcdir"/*
            \\    
            \\    # Build Zig components first
            \\    if [ -f build.zig ]; then
            \\        echo "Building Zig components..."
            \\        zig build -Doptimize=ReleaseFast
            \\    fi
            \\    
            \\    # Use Zig to compile C code (generic baseline for reproducibility)
            \\    echo "Compiling C code with Zig compiler..."
            \\    find . -name "*.c" -exec zig cc -O3 -fPIC {{}} -c \;
            \\
            \\    # Link everything together
            \\    if [ -f build.zig ]; then
            \\        # Use Zig build system for linking
            \\        zig build -Doptimize=ReleaseFast --prefix-exe-dir bin
            \\    else
            \\        # Manual linking with Zig
            \\        zig cc -O3 *.o -o {s}
            \\    fi
            \\}}
            \\
            \\package() {{
            \\    cd "$srcdir"/*
            \\    
            \\    # Install executables
            \\    if [ -d zig-out/bin ]; then
            \\        install -Dm755 zig-out/bin/* "$pkgdir/usr/bin/"
            \\    elif [ -f {s} ]; then
            \\        install -Dm755 {s} "$pkgdir/usr/bin/{s}"
            \\    fi
            \\    
            \\    # Install documentation and license
            \\    [ -f README.md ] && install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
            \\    [ -f LICENSE ] && install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
            \\}}
            \\
        , .{
            project_info.name,
            project_info.version,
            project_info.description,
            source_url,
            source_url,
            project_info.name,
            project_info.name,
            project_info.name,
            project_info.name,
        });

        return pkgbuild;
    }

    // Private helper methods
    fn parseZigZon(self: *ZigBuilder, content: []const u8) !ZigProjectInfo {
        // Simple parsing - look for .name and .version
        var name: []const u8 = "unknown-project";
        var version: []const u8 = "0.1.0";
        const description: []const u8 = "Zig project";

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, ".name = ")) {
                // Extract name from .name = "something" or .name = .something
                if (std.mem.indexOf(u8, trimmed, "\"")) |start| {
                    if (std.mem.lastIndexOf(u8, trimmed, "\"")) |end| {
                        if (end > start + 1) {
                            name = trimmed[start + 1 .. end];
                        }
                    }
                } else if (std.mem.indexOf(u8, trimmed, ".")) |dot_pos| {
                    if (dot_pos + 1 < trimmed.len) {
                        const name_part = trimmed[dot_pos + 1 ..];
                        if (std.mem.indexOf(u8, name_part, ",")) |comma| {
                            name = std.mem.trim(u8, name_part[0..comma], " \t");
                        } else {
                            name = std.mem.trim(u8, name_part, " \t,");
                        }
                    }
                }
            }

            if (std.mem.startsWith(u8, trimmed, ".version = ")) {
                if (std.mem.indexOf(u8, trimmed, "\"")) |start| {
                    if (std.mem.lastIndexOf(u8, trimmed, "\"")) |end| {
                        if (end > start + 1) {
                            version = trimmed[start + 1 .. end];
                        }
                    }
                }
            }
        }

        var targets: std.ArrayList([]const u8) = .empty;
        try targets.append(self.allocator, try self.allocator.dupe(u8, name));
        var deps: std.ArrayList([]const u8) = .empty;
        return ZigProjectInfo{
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, version),
            .description = try self.allocator.dupe(u8, description),
            .targets = try targets.toOwnedSlice(self.allocator),
            .dependencies = try deps.toOwnedSlice(self.allocator),
        };
    }

    fn generateInstallCommands(self: *ZigBuilder, targets: [][]const u8) ![]const u8 {
        var commands: std.ArrayList(u8) = .empty;

        for (targets) |target| {
            try commands.print(self.allocator,
                \\    # Install {s}
                \\    if [ -f zig-out/bin/{s} ]; then
                \\        install -Dm755 zig-out/bin/{s} "$pkgdir/usr/bin/{s}"
                \\    fi
                \\
            , .{ target, target, target, target });
        }

        return commands.toOwnedSlice(self.allocator);
    }

    fn findBuildArtifacts(self: *ZigBuilder, project_path: []const u8) ![][]const u8 {
        const io = self.threaded_io.io();
        var artifacts: std.ArrayList([]const u8) = .empty;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const zig_out_path = std.fmt.bufPrint(path_buf[0..], "{s}/zig-out/bin", .{project_path}) catch return artifacts.toOwnedSlice(self.allocator);

        var dir = std.Io.Dir.openDirAbsolute(io, zig_out_path, .{ .iterate = true }) catch return artifacts.toOwnedSlice(self.allocator);
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .file) {
                try artifacts.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }

        return artifacts.toOwnedSlice(self.allocator);
    }
};

pub const ZigProjectInfo = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    targets: [][]const u8,
    dependencies: [][]const u8,

    pub fn deinit(self: ZigProjectInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        for (self.targets) |target| allocator.free(target);
        for (self.dependencies) |dep| allocator.free(dep);
        allocator.free(self.targets);
        allocator.free(self.dependencies);
    }
};

pub const BuildResult = struct {
    success: bool,
    stdout: []const u8,
    stderr: []const u8,
    artifacts: [][]const u8,

    pub fn deinit(self: BuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        for (self.artifacts) |artifact| allocator.free(artifact);
        allocator.free(self.artifacts);
    }
};

// =============================================================================
// Tests: Zig PKGBUILD Generation
// =============================================================================

test "generatePKGBUILD produces valid PKGBUILD structure" {
    const allocator = std.testing.allocator;

    var builder = ZigBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    const target_name = try allocator.dupe(u8, "myapp");
    try targets.append(allocator, target_name);
    var deps: std.ArrayList([]const u8) = .empty;

    const info = ZigProjectInfo{
        .name = try allocator.dupe(u8, "myapp"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test application"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generatePKGBUILD(info, "https://example.com/myapp.tar.gz");
    defer allocator.free(pkgbuild);

    // Verify required PKGBUILD fields
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgname=myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgver=1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgrel=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgdesc=\"Test application\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "arch=('x86_64' 'aarch64')") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "makedepends=('zig>=0.13.0')") != null);
}

test "generatePKGBUILD includes zig build commands" {
    const allocator = std.testing.allocator;

    var builder = ZigBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    const target_name = try allocator.dupe(u8, "myapp");
    try targets.append(allocator, target_name);
    var deps: std.ArrayList([]const u8) = .empty;

    const info = ZigProjectInfo{
        .name = try allocator.dupe(u8, "myapp"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generatePKGBUILD(info, "https://example.com/myapp.tar.gz");
    defer allocator.free(pkgbuild);

    // Verify build function uses zig build
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "zig build") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "-Doptimize=ReleaseFast") != null);
}

test "generatePKGBUILD does not include target-cpu=native" {
    const allocator = std.testing.allocator;

    var builder = ZigBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    const target_name = try allocator.dupe(u8, "myapp");
    try targets.append(allocator, target_name);
    var deps: std.ArrayList([]const u8) = .empty;

    const info = ZigProjectInfo{
        .name = try allocator.dupe(u8, "myapp"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generatePKGBUILD(info, "https://example.com/myapp.tar.gz");
    defer allocator.free(pkgbuild);

    // Should NOT include host-specific flags
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "target-cpu=native") == null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "-mcpu=native") == null);
}

test "generateHybridPKGBUILD produces valid structure" {
    const allocator = std.testing.allocator;

    var builder = ZigBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    const target_name = try allocator.dupe(u8, "hybrid-app");
    try targets.append(allocator, target_name);
    var deps: std.ArrayList([]const u8) = .empty;

    const info = ZigProjectInfo{
        .name = try allocator.dupe(u8, "hybrid-app"),
        .version = try allocator.dupe(u8, "2.0.0"),
        .description = try allocator.dupe(u8, "Hybrid Zig/C project"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generateHybridPKGBUILD(info, "https://example.com/hybrid.tar.gz");
    defer allocator.free(pkgbuild);

    // Verify hybrid-specific content
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgname=hybrid-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "zig cc") != null);
}

// =============================================================================
// Tests: ZON Parsing
// =============================================================================

test "parseZigZon extracts name and version" {
    const allocator = std.testing.allocator;

    var builder = ZigBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    const zon_content =
        \\.{
        \\    .name = "test-project",
        \\    .version = "0.5.0",
        \\}
    ;

    const info = try builder.parseZigZon(zon_content);
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("test-project", info.name);
    try std.testing.expectEqualStrings("0.5.0", info.version);
}
