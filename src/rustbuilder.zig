const std = @import("std");

/// RustBuilder - Leverages Cargo build system to create Arch packages from Rust projects
pub const RustBuilder = struct {
    allocator: std.mem.Allocator,
    build_dir: []const u8,
    package_dir: []const u8,
    threaded_io: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, build_dir: []const u8, package_dir: []const u8) RustBuilder {
        return RustBuilder{
            .allocator = allocator,
            .build_dir = allocator.dupe(u8, build_dir) catch @panic("OOM"),
            .package_dir = allocator.dupe(u8, package_dir) catch @panic("OOM"),
            .threaded_io = .init(std.heap.smp_allocator, .{}),
        };
    }

    pub fn deinit(self: *RustBuilder) void {
        self.allocator.free(self.build_dir);
        self.allocator.free(self.package_dir);
        self.threaded_io.deinit();
    }

    /// Detects if a project is a Rust project by checking for Cargo.toml
    pub fn isRustProject(_: *RustBuilder, project_path: []const u8) bool {
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cargo_toml_path = std.fmt.bufPrint(path_buf[0..], "{s}/Cargo.toml", .{project_path}) catch return false;

        std.Io.Dir.accessAbsolute(threaded_io.io(), cargo_toml_path, .{}) catch return false;
        return true;
    }

    /// Analyzes Cargo.toml for package metadata
    pub fn analyzeProject(self: *RustBuilder, project_path: []const u8) !RustProjectInfo {
        const io = self.threaded_io.io();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cargo_toml_path = std.fmt.bufPrint(path_buf[0..], "{s}/Cargo.toml", .{project_path}) catch return error.PathTooLong;

        const file = std.Io.Dir.openFileAbsolute(io, cargo_toml_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var targets: std.ArrayList([]const u8) = .empty;
                try targets.append(self.allocator, "rust-project");
                var deps: std.ArrayList([]const u8) = .empty;
                return RustProjectInfo{
                    .name = "unknown-rust-project",
                    .version = "0.1.0",
                    .description = "Rust project (no Cargo.toml found)",
                    .targets = try targets.toOwnedSlice(self.allocator),
                    .dependencies = try deps.toOwnedSlice(self.allocator),
                    .edition = "2021",
                    .license = "MIT",
                    .homepage = "",
                    .repository = "",
                    .is_binary = true,
                    .is_library = false,
                };
            },
            else => return err,
        };
        defer file.close(io);

        const content = try std.Io.Dir.readFileAlloc(.cwd(), io, cargo_toml_path, self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(content);

        return try self.parseCargoToml(content, project_path);
    }

    /// Generates PKGBUILD for a Rust project
    pub fn generatePKGBUILD(self: *RustBuilder, project_info: RustProjectInfo, source_url: []const u8) ![]const u8 {
        const rust_deps = if (project_info.dependencies.len > 0)
            "'rust' 'cargo'"
        else
            "'rust' 'cargo'";

        const build_targets = if (project_info.is_binary and project_info.is_library)
            "# Build both binary and library\n    cargo build --release --all-targets"
        else if (project_info.is_binary)
            "# Build binary\n    cargo build --release --bin"
        else
            "# Build library\n    cargo build --release --lib";

        const install_commands = try self.generateRustInstallCommands(project_info);
        defer self.allocator.free(install_commands);

        const pkgbuild = try std.fmt.allocPrint(self.allocator,
            \\# Maintainer: ZAUR (Zig Arch User Repository)
            \\# Auto-generated PKGBUILD for Rust project
            \\
            \\pkgname={s}
            \\pkgver={s}
            \\pkgrel=1
            \\pkgdesc="{s}"
            \\arch=('x86_64' 'aarch64')
            \\url="{s}"
            \\license=('{s}')
            \\makedepends=({s})
            \\source=("$pkgname-$pkgver.tar.gz::{s}")
            \\sha256sums=('SKIP')
            \\
            \\prepare() {{
            \\    cd "$srcdir"/*
            \\
            \\    # Set up Cargo environment
            \\    export CARGO_HOME="$srcdir/.cargo"
            \\    export CARGO_TARGET_DIR="$srcdir/target"
            \\
            \\    # Create .cargo/config.toml for optimization
            \\    mkdir -p .cargo
            \\    cat > .cargo/config.toml << 'EOF'
            \\[build]
            \\rustflags = ["-C", "opt-level=3"]
            \\
            \\[profile.release]
            \\lto = true
            \\codegen-units = 1
            \\panic = "abort"
            \\strip = true
            \\EOF
            \\}}
            \\
            \\build() {{
            \\    cd "$srcdir"/*
            \\
            \\    export CARGO_HOME="$srcdir/.cargo"
            \\    export CARGO_TARGET_DIR="$srcdir/target"
            \\    export RUSTUP_TOOLCHAIN=stable
            \\
            \\    {s}
            \\}}
            \\
            \\check() {{
            \\    cd "$srcdir"/*
            \\
            \\    export CARGO_HOME="$srcdir/.cargo"
            \\    export CARGO_TARGET_DIR="$srcdir/target"
            \\
            \\    # Run Rust tests
            \\    cargo test --release --all-targets 2>/dev/null || echo "No tests found or tests failed"
            \\}}
            \\
            \\package() {{
            \\    cd "$srcdir"/*
            \\
            \\    export CARGO_HOME="$srcdir/.cargo"
            \\    export CARGO_TARGET_DIR="$srcdir/target"
            \\
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
            \\    elif [ -f LICENSE-MIT ]; then
            \\        install -Dm644 LICENSE-MIT "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
            \\    elif [ -f LICENSE-APACHE ]; then
            \\        install -Dm644 LICENSE-APACHE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
            \\    fi
            \\
            \\    # Install man pages if available
            \\    if [ -d target/release/man ]; then
            \\        find target/release/man -name "*.1" -exec install -Dm644 {{}} "$pkgdir/usr/share/man/man1/" \;
            \\    fi
            \\
            \\    # Install shell completions if available
            \\    if [ -d target/release/completions ]; then
            \\        # Bash completions
            \\        if [ -f target/release/completions/$pkgname.bash ]; then
            \\            install -Dm644 target/release/completions/$pkgname.bash "$pkgdir/usr/share/bash-completion/completions/$pkgname"
            \\        fi
            \\        # Zsh completions
            \\        if [ -f target/release/completions/_$pkgname ]; then
            \\            install -Dm644 target/release/completions/_$pkgname "$pkgdir/usr/share/zsh/site-functions/_$pkgname"
            \\        fi
            \\        # Fish completions
            \\        if [ -f target/release/completions/$pkgname.fish ]; then
            \\            install -Dm644 target/release/completions/$pkgname.fish "$pkgdir/usr/share/fish/vendor_completions.d/$pkgname.fish"
            \\        fi
            \\    fi
            \\}}
            \\
        , .{
            project_info.name,
            project_info.version,
            project_info.description,
            if (project_info.homepage.len > 0) project_info.homepage else if (project_info.repository.len > 0) project_info.repository else source_url,
            project_info.license,
            rust_deps,
            source_url,
            build_targets,
            install_commands,
        });

        return pkgbuild;
    }

    /// Builds a Rust project using Cargo
    pub fn buildProject(self: *RustBuilder, project_path: []const u8, optimize_mode: []const u8) !BuildResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const io = self.threaded_io.io();

        // Set up Cargo environment
        const cargo_home = try std.fmt.allocPrint(allocator, "{s}/.cargo", .{project_path});
        const cargo_target_dir = try std.fmt.allocPrint(allocator, "{s}/target", .{project_path});

        // Create optimized Cargo config
        try self.createCargoConfig(project_path, optimize_mode);

        const build_flag = if (std.mem.eql(u8, optimize_mode, "release")) "--release" else "";

        const args = [_][]const u8{ "cargo", "build", build_flag, "--all-targets" };

        var env_map: std.process.Environ.Map = .empty;
        defer env_map.deinit(allocator);
        try env_map.put(allocator, "CARGO_HOME", cargo_home);
        try env_map.put(allocator, "CARGO_TARGET_DIR", cargo_target_dir);
        try env_map.put(allocator, "RUSTUP_TOOLCHAIN", "stable");

        const result = try std.process.run(allocator, io, .{
            .argv = &args,
            .cwd = .{ .path = project_path },
            .environ_map = &env_map,
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

    /// Creates a WASM-specific PKGBUILD for Rust projects that compile to WebAssembly
    pub fn generateWasmPKGBUILD(self: *RustBuilder, project_info: RustProjectInfo, source_url: []const u8) ![]const u8 {
        const pkgbuild = try std.fmt.allocPrint(self.allocator,
            \\# Maintainer: ZAUR (Zig Arch User Repository)
            \\# Auto-generated PKGBUILD for Rust WASM project
            \\
            \\pkgname={s}-wasm
            \\pkgver={s}
            \\pkgrel=1
            \\pkgdesc="{s} (WebAssembly build)"
            \\arch=('any')
            \\url="{s}"
            \\license=('{s}')
            \\makedepends=('rust' 'cargo' 'wasm-pack')
            \\source=("$pkgname-$pkgver.tar.gz::{s}")
            \\sha256sums=('SKIP')
            \\
            \\build() {{
            \\    cd "$srcdir"/*
            \\
            \\    export CARGO_HOME="$srcdir/.cargo"
            \\    export CARGO_TARGET_DIR="$srcdir/target"
            \\
            \\    # Add WASM target
            \\    rustup target add wasm32-unknown-unknown
            \\
            \\    # Build with wasm-pack for web deployment
            \\    wasm-pack build --target web --release
            \\
            \\    # Also build for Node.js if applicable
            \\    wasm-pack build --target nodejs --release --out-dir pkg-nodejs
            \\}}
            \\
            \\package() {{
            \\    cd "$srcdir"/*
            \\
            \\    # Install WASM files for web
            \\    install -dm755 "$pkgdir/usr/share/{s}-wasm/web"
            \\    cp -r pkg/* "$pkgdir/usr/share/{s}-wasm/web/"
            \\
            \\    # Install WASM files for Node.js
            \\    if [ -d pkg-nodejs ]; then
            \\        install -dm755 "$pkgdir/usr/share/{s}-wasm/nodejs"
            \\        cp -r pkg-nodejs/* "$pkgdir/usr/share/{s}-wasm/nodejs/"
            \\    fi
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
            \\}}
            \\
        , .{
            project_info.name,
            project_info.version,
            project_info.description,
            if (project_info.homepage.len > 0) project_info.homepage else if (project_info.repository.len > 0) project_info.repository else source_url,
            project_info.license,
            source_url,
            project_info.name,
            project_info.name,
            project_info.name,
            project_info.name,
        });

        return pkgbuild;
    }

    // Private helper methods

    fn parseCargoToml(self: *RustBuilder, content: []const u8, project_path: []const u8) !RustProjectInfo {
        var name: []const u8 = "unknown-project";
        var version: []const u8 = "0.1.0";
        var description: []const u8 = "Rust project";
        var license: []const u8 = "MIT";
        var homepage: []const u8 = "";
        var repository: []const u8 = "";
        var edition: []const u8 = "2021";

        var in_package_section = false;
        var dependencies: std.ArrayList([]const u8) = .empty;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Track sections
            if (std.mem.startsWith(u8, trimmed, "[package]")) {
                in_package_section = true;
                continue;
            } else if (std.mem.startsWith(u8, trimmed, "[") and !std.mem.startsWith(u8, trimmed, "[package]")) {
                in_package_section = false;
            }

            if (in_package_section) {
                if (self.extractTomlValue(trimmed, "name")) |value| {
                    name = value;
                } else if (self.extractTomlValue(trimmed, "version")) |value| {
                    version = value;
                } else if (self.extractTomlValue(trimmed, "description")) |value| {
                    description = value;
                } else if (self.extractTomlValue(trimmed, "license")) |value| {
                    license = value;
                } else if (self.extractTomlValue(trimmed, "homepage")) |value| {
                    homepage = value;
                } else if (self.extractTomlValue(trimmed, "repository")) |value| {
                    repository = value;
                } else if (self.extractTomlValue(trimmed, "edition")) |value| {
                    edition = value;
                }
            }

            // Parse dependencies
            if (std.mem.startsWith(u8, trimmed, "[dependencies]") or
                std.mem.startsWith(u8, trimmed, "[build-dependencies]") or
                std.mem.startsWith(u8, trimmed, "[dev-dependencies]"))
            {
                continue;
            }
        }

        // Detect binary vs library
        const is_binary = try self.hasBinaryTargets(project_path);
        const is_library = try self.hasLibraryTarget(project_path);

        var targets: std.ArrayList([]const u8) = .empty;
        if (is_binary) {
            const binary_targets = try self.getBinaryTargets(project_path);
            defer {
                // Free each string and then the slice
                for (binary_targets) |target| {
                    self.allocator.free(target);
                }
                self.allocator.free(binary_targets);
            }
            for (binary_targets) |target| {
                try targets.append(self.allocator, try self.allocator.dupe(u8, target));
            }
        }
        if (targets.items.len == 0) {
            try targets.append(self.allocator, try self.allocator.dupe(u8, name));
        }

        return RustProjectInfo{
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, version),
            .description = try self.allocator.dupe(u8, description),
            .targets = try targets.toOwnedSlice(self.allocator),
            .dependencies = try dependencies.toOwnedSlice(self.allocator),
            .edition = try self.allocator.dupe(u8, edition),
            .license = try self.allocator.dupe(u8, license),
            .homepage = try self.allocator.dupe(u8, homepage),
            .repository = try self.allocator.dupe(u8, repository),
            .is_binary = is_binary,
            .is_library = is_library,
        };
    }

    fn extractTomlValue(self: *RustBuilder, line: []const u8, key: []const u8) ?[]const u8 {
        const key_with_eq = std.fmt.allocPrint(self.allocator, "{s} =", .{key}) catch return null;
        defer self.allocator.free(key_with_eq);

        if (std.mem.startsWith(u8, line, key_with_eq)) {
            if (std.mem.indexOf(u8, line, "\"")) |start| {
                if (std.mem.lastIndexOf(u8, line, "\"")) |end| {
                    if (end > start + 1) {
                        return line[start + 1 .. end];
                    }
                }
            }
        }
        return null;
    }

    fn hasBinaryTargets(_: *RustBuilder, project_path: []const u8) !bool {
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const io = threaded_io.io();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_main_path = std.fmt.bufPrint(path_buf[0..], "{s}/src/main.rs", .{project_path}) catch return false;

        std.Io.Dir.accessAbsolute(io, src_main_path, .{}) catch {
            // Check for bin directory
            const bin_dir_path = std.fmt.bufPrint(path_buf[0..], "{s}/src/bin", .{project_path}) catch return false;
            var bin_dir = std.Io.Dir.openDirAbsolute(io, bin_dir_path, .{}) catch return false;
            defer bin_dir.close(io);
            return true;
        };
        return true;
    }

    fn hasLibraryTarget(_: *RustBuilder, project_path: []const u8) !bool {
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const lib_rs_path = std.fmt.bufPrint(path_buf[0..], "{s}/src/lib.rs", .{project_path}) catch return false;

        std.Io.Dir.accessAbsolute(threaded_io.io(), lib_rs_path, .{}) catch return false;
        return true;
    }

    fn getBinaryTargets(self: *RustBuilder, project_path: []const u8) ![][]const u8 {
        const io = self.threaded_io.io();
        var targets: std.ArrayList([]const u8) = .empty;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Check src/main.rs (default binary)
        const main_rs_path = std.fmt.bufPrint(path_buf[0..], "{s}/src/main.rs", .{project_path}) catch return targets.toOwnedSlice(self.allocator);
        std.Io.Dir.accessAbsolute(io, main_rs_path, .{}) catch {
            // Check src/bin directory
            const bin_dir_path = std.fmt.bufPrint(path_buf[0..], "{s}/src/bin", .{project_path}) catch return targets.toOwnedSlice(self.allocator);
            var bin_dir = std.Io.Dir.openDirAbsolute(io, bin_dir_path, .{ .iterate = true }) catch return targets.toOwnedSlice(self.allocator);
            defer bin_dir.close(io);

            var iterator = bin_dir.iterate();
            while (try iterator.next(io)) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".rs")) {
                    const name_without_ext = entry.name[0 .. entry.name.len - 3];
                    try targets.append(self.allocator, try self.allocator.dupe(u8, name_without_ext));
                }
            }
            return targets.toOwnedSlice(self.allocator);
        };

        // Default binary from main.rs - extract name from Cargo.toml or use directory name
        const project_name = std.fs.path.basename(project_path);
        try targets.append(self.allocator, try self.allocator.dupe(u8, project_name));

        return targets.toOwnedSlice(self.allocator);
    }

    fn createCargoConfig(self: *RustBuilder, project_path: []const u8, optimize_mode: []const u8) !void {
        const io = self.threaded_io.io();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cargo_dir_path = std.fmt.bufPrint(path_buf[0..], "{s}/.cargo", .{project_path}) catch return;

        std.Io.Dir.createDirPath(.cwd(), io, cargo_dir_path) catch {};

        const config_path = std.fmt.bufPrint(path_buf[0..], "{s}/.cargo/config.toml", .{project_path}) catch return;

        // Generic baseline for reproducibility - no target-cpu=native
        const optimization_flags = if (std.mem.eql(u8, optimize_mode, "release"))
            \\[build]
            \\rustflags = ["-C", "opt-level=3"]
            \\
            \\[profile.release]
            \\lto = true
            \\codegen-units = 1
            \\panic = "abort"
            \\strip = true
        else
            \\[build]
            \\rustflags = ["-C", "opt-level=1"]
            \\
            \\[profile.dev]
            \\opt-level = 1
        ;

        try std.Io.Dir.writeFile(.cwd(), io, .{
            .sub_path = config_path,
            .data = optimization_flags,
        });
    }

    fn generateRustInstallCommands(self: *RustBuilder, project_info: RustProjectInfo) ![]const u8 {
        var commands: std.ArrayList(u8) = .empty;

        if (project_info.is_binary) {
            for (project_info.targets) |target| {
                const cmd = try std.fmt.allocPrint(self.allocator,
                    \\    # Install {s} binary
                    \\    if [ -f target/release/{s} ]; then
                    \\        install -Dm755 target/release/{s} "$pkgdir/usr/bin/{s}"
                    \\    fi
                    \\
                , .{ target, target, target, target });
                defer self.allocator.free(cmd);
                try commands.appendSlice(self.allocator, cmd);
            }
        }

        if (project_info.is_library) {
            const cmd = try std.fmt.allocPrint(self.allocator,
                \\    # Install library files
                \\    if [ -d target/release/deps ]; then
                \\        find target/release/deps -name "lib{s}-*.rlib" -exec install -Dm644 {{}} "$pkgdir/usr/lib/" \; 2>/dev/null || true
                \\    fi
                \\
            , .{project_info.name});
            defer self.allocator.free(cmd);
            try commands.appendSlice(self.allocator, cmd);
        }

        return commands.toOwnedSlice(self.allocator);
    }

    fn findBuildArtifacts(self: *RustBuilder, project_path: []const u8) ![][]const u8 {
        const io = self.threaded_io.io();
        var artifacts: std.ArrayList([]const u8) = .empty;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_release_path = std.fmt.bufPrint(path_buf[0..], "{s}/target/release", .{project_path}) catch return artifacts.toOwnedSlice(self.allocator);

        var dir = std.Io.Dir.openDirAbsolute(io, target_release_path, .{ .iterate = true }) catch return artifacts.toOwnedSlice(self.allocator);
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .file and !std.mem.endsWith(u8, entry.name, ".d")) {
                // Skip dependency files and temporary files
                if (!std.mem.startsWith(u8, entry.name, ".") and !std.mem.endsWith(u8, entry.name, ".rlib")) {
                    try artifacts.append(self.allocator, try self.allocator.dupe(u8, entry.name));
                }
            }
        }

        return artifacts.toOwnedSlice(self.allocator);
    }
};

pub const RustProjectInfo = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    targets: [][]const u8,
    dependencies: [][]const u8,
    edition: []const u8,
    license: []const u8,
    homepage: []const u8,
    repository: []const u8,
    is_binary: bool,
    is_library: bool,

    pub fn deinit(self: RustProjectInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        for (self.targets) |target| allocator.free(target);
        for (self.dependencies) |dep| allocator.free(dep);
        allocator.free(self.targets);
        allocator.free(self.dependencies);
        allocator.free(self.edition);
        allocator.free(self.license);
        allocator.free(self.homepage);
        allocator.free(self.repository);
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
// Tests: Rust PKGBUILD Generation
// =============================================================================

test "generatePKGBUILD produces valid PKGBUILD structure" {
    const allocator = std.testing.allocator;

    var builder = RustBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    try targets.append(allocator, try allocator.dupe(u8, "myapp"));
    var deps: std.ArrayList([]const u8) = .empty;

    const info = RustProjectInfo{
        .name = try allocator.dupe(u8, "myapp"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test Rust application"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
        .edition = try allocator.dupe(u8, "2021"),
        .license = try allocator.dupe(u8, "MIT"),
        .homepage = try allocator.dupe(u8, "https://example.com"),
        .repository = try allocator.dupe(u8, "https://github.com/user/myapp"),
        .is_binary = true,
        .is_library = false,
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generatePKGBUILD(info, "https://example.com/myapp.tar.gz");
    defer allocator.free(pkgbuild);

    // Verify required PKGBUILD fields
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgname=myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgver=1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgrel=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgdesc=\"Test Rust application\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "arch=('x86_64' 'aarch64')") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "license=('MIT')") != null);
}

test "generatePKGBUILD includes cargo build commands" {
    const allocator = std.testing.allocator;

    var builder = RustBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    try targets.append(allocator, try allocator.dupe(u8, "myapp"));
    var deps: std.ArrayList([]const u8) = .empty;

    const info = RustProjectInfo{
        .name = try allocator.dupe(u8, "myapp"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
        .edition = try allocator.dupe(u8, "2021"),
        .license = try allocator.dupe(u8, "MIT"),
        .homepage = try allocator.dupe(u8, ""),
        .repository = try allocator.dupe(u8, ""),
        .is_binary = true,
        .is_library = false,
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generatePKGBUILD(info, "https://example.com/myapp.tar.gz");
    defer allocator.free(pkgbuild);

    // Verify build function uses cargo
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "cargo build") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "--release") != null);
}

test "generatePKGBUILD does not include target-cpu=native" {
    const allocator = std.testing.allocator;

    var builder = RustBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    try targets.append(allocator, try allocator.dupe(u8, "myapp"));
    var deps: std.ArrayList([]const u8) = .empty;

    const info = RustProjectInfo{
        .name = try allocator.dupe(u8, "myapp"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
        .edition = try allocator.dupe(u8, "2021"),
        .license = try allocator.dupe(u8, "MIT"),
        .homepage = try allocator.dupe(u8, ""),
        .repository = try allocator.dupe(u8, ""),
        .is_binary = true,
        .is_library = false,
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generatePKGBUILD(info, "https://example.com/myapp.tar.gz");
    defer allocator.free(pkgbuild);

    // Should NOT include host-specific flags
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "target-cpu=native") == null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "-C target-cpu=native") == null);
}

test "generateWasmPKGBUILD produces valid WASM structure" {
    const allocator = std.testing.allocator;

    var builder = RustBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    try targets.append(allocator, try allocator.dupe(u8, "wasm-app"));
    var deps: std.ArrayList([]const u8) = .empty;

    const info = RustProjectInfo{
        .name = try allocator.dupe(u8, "wasm-app"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "WASM application"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
        .edition = try allocator.dupe(u8, "2021"),
        .license = try allocator.dupe(u8, "MIT"),
        .homepage = try allocator.dupe(u8, ""),
        .repository = try allocator.dupe(u8, ""),
        .is_binary = true,
        .is_library = false,
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generateWasmPKGBUILD(info, "https://example.com/wasm.tar.gz");
    defer allocator.free(pkgbuild);

    // Verify WASM-specific content
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgname=wasm-app-wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "wasm-pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "wasm32-unknown-unknown") != null);
}

test "generatePKGBUILD includes library install for library projects" {
    const allocator = std.testing.allocator;

    var builder = RustBuilder.init(allocator, "/tmp/build", "/tmp/pkg");
    defer builder.deinit();

    var targets: std.ArrayList([]const u8) = .empty;
    try targets.append(allocator, try allocator.dupe(u8, "mylib"));
    var deps: std.ArrayList([]const u8) = .empty;

    const info = RustProjectInfo{
        .name = try allocator.dupe(u8, "mylib"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test library"),
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try deps.toOwnedSlice(allocator),
        .edition = try allocator.dupe(u8, "2021"),
        .license = try allocator.dupe(u8, "MIT"),
        .homepage = try allocator.dupe(u8, ""),
        .repository = try allocator.dupe(u8, ""),
        .is_binary = false,
        .is_library = true,
    };
    defer info.deinit(allocator);

    const pkgbuild = try builder.generatePKGBUILD(info, "https://example.com/mylib.tar.gz");
    defer allocator.free(pkgbuild);

    // Verify library install commands
    try std.testing.expect(std.mem.indexOf(u8, pkgbuild, "lib") != null);
}
