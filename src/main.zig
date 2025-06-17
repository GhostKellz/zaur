const std = @import("std");
const zaur = @import("zaur");

const Command = enum {
    init,
    add,
    build,
    serve,
    sync,
    list,
    clean,
    status,
    update,
    @"gpg-init",
    help,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printHelp();
        return;
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        std.debug.print("Unknown command: {s}\n", .{args[1]});
        try printHelp();
        return;
    };

    switch (command) {
        .init => try handleInit(allocator),
        .add => try handleAdd(allocator, args[2..]),
        .build => try handleBuild(allocator, args[2..]),
        .serve => try handleServe(allocator, args[2..]),
        .sync => try handleSync(allocator, args[2..]),
        .list => try handleList(allocator),
        .clean => try handleClean(allocator, args[2..]),
        .status => try handleStatus(allocator),
        .update => try handleUpdate(allocator, args[2..]),
        .@"gpg-init" => try handleGpgInit(allocator, args[2..]),
        .help => try printHelp(),
    }
}

fn handleInit(allocator: std.mem.Allocator) !void {
    std.debug.print("Initializing ZAUR repository...\n", .{});

    const config = try zaur.Config.init(allocator);
    defer config.deinit();

    try config.ensureDirectories();

    var db = try zaur.Database.init(allocator, config.db_path);
    defer db.deinit();

    std.debug.print("✓ Created directories:\n", .{});
    std.debug.print("  Repository: {s}\n", .{config.repo_dir});
    std.debug.print("  Build: {s}\n", .{config.build_dir});
    std.debug.print("✓ Initialized database: {s}\n", .{config.db_path});
    std.debug.print("ZAUR repository initialized successfully!\n", .{});
}

fn handleAdd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: Package name required\n", .{});
        std.debug.print("Usage: zaur add <package>\n", .{});
        std.debug.print("Examples:\n", .{});
        std.debug.print("  zaur add aur/firefox\n", .{});
        std.debug.print("  zaur add github:ghostkellz/nvcontrol\n", .{});
        return;
    }

    const config = try zaur.Config.init(allocator);
    defer config.deinit();

    var db = try zaur.Database.init(allocator, config.db_path);
    defer db.deinit();

    const package_spec = args[0];
    std.debug.print("Adding package: {s}\n", .{package_spec});

    if (std.mem.startsWith(u8, package_spec, "aur/")) {
        const package_name = package_spec[4..];

        var aur_client = zaur.AurClient.init(allocator);
        defer aur_client.deinit();

        // Search for package
        const aur_package = try aur_client.searchPackage(package_name);
        if (aur_package) |pkg| {
            defer pkg.deinit(allocator);

            try db.addPackage(package_name, "aur", pkg.url_path);
            try aur_client.downloadPkgbuild(package_name, config.build_dir);

            std.debug.print("✓ Added AUR package: {s}\n", .{package_name});
        } else {
            std.debug.print("✗ Package not found in AUR: {s}\n", .{package_name});
        }
    } else if (std.mem.startsWith(u8, package_spec, "github:")) {
        const github_spec = package_spec[7..];

        var aur_client = zaur.AurClient.init(allocator);
        defer aur_client.deinit();

        try aur_client.downloadFromGitHub(github_spec, config.build_dir);
        try db.addPackage(github_spec, "github", package_spec);

        std.debug.print("✓ Added GitHub package: {s}\n", .{github_spec});
    } else {
        std.debug.print("✗ Unsupported package format: {s}\n", .{package_spec});
        std.debug.print("Supported formats: aur/package-name, github:user/repo\n", .{});
    }
}

fn handleBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const config = try zaur.Config.init(allocator);
    defer config.deinit();

    var db = try zaur.Database.init(allocator, config.db_path);
    defer db.deinit();

    const target = if (args.len > 0) args[0] else "all";
    std.debug.print("Building: {s}\n", .{target});

    var builder = zaur.PackageBuilder.init(allocator, config.build_dir, config.repo_dir);

    if (std.mem.eql(u8, target, "all")) {
        const packages = try db.getPackages(allocator);
        defer {
            for (packages) |pkg| {
                pkg.deinit(allocator);
            }
            allocator.free(packages);
        }

        for (packages) |pkg| {
            std.debug.print("Building package: {s}\n", .{pkg.name});
            const result = try builder.buildPackage(pkg.name);
            defer result.deinit(allocator);

            if (result.success) {
                std.debug.print("✓ Built {s} successfully\n", .{pkg.name});
            } else {
                std.debug.print("✗ Failed to build {s}\n", .{pkg.name});
                std.debug.print("Build log:\n{s}\n", .{result.log});
            }
        }
    } else {
        const result = try builder.buildPackage(target);
        defer result.deinit(allocator);

        if (result.success) {
            std.debug.print("✓ Built {s} successfully\n", .{target});
        } else {
            std.debug.print("✗ Failed to build {s}\n", .{target});
            std.debug.print("Build log:\n{s}\n", .{result.log});
        }
    }

    // Generate repository database
    var repo_manager = zaur.RepoManager.init(allocator, config.repo_dir, config.db_name);
    try repo_manager.generateRepoDatabase();
}

fn handleServe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = try zaur.Config.init(allocator);
    defer config.deinit();

    // Parse arguments for port and bind address
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bind") and i + 1 < args.len) {
            allocator.free(config.bind_address);
            config.bind_address = try allocator.dupe(u8, args[i + 1]);
            i += 1;
        }
    }

    var server = zaur.HttpServer.init(allocator, config.repo_dir, config.port, config.bind_address);
    try server.start();
}

fn handleSync(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    if (args.len == 0) {
        std.debug.print("Error: Repository URL required\n", .{});
        std.debug.print("Usage: zaur sync <repo-url>\n", .{});
        return;
    }
    std.debug.print("Syncing from: {s}\n", .{args[0]});
    std.debug.print("Note: Sync functionality is planned for future versions\n", .{});
}

fn handleList(allocator: std.mem.Allocator) !void {
    const config = try zaur.Config.init(allocator);
    defer config.deinit();

    var db = try zaur.Database.init(allocator, config.db_path);
    defer db.deinit();

    std.debug.print("📦 ZAUR Repository Status\n", .{});
    std.debug.print("Repository: {s}\n", .{config.repo_dir});
    std.debug.print("\n🗄️ Database Packages:\n", .{});

    const packages = try db.getPackages(allocator);
    defer {
        for (packages) |pkg| {
            pkg.deinit(allocator);
        }
        allocator.free(packages);
    }

    if (packages.len == 0) {
        std.debug.print("  No packages in database\n", .{});
    } else {
        for (packages) |pkg| {
            const status_icon = if (std.mem.eql(u8, pkg.build_status, "success")) "✅" else if (std.mem.eql(u8, pkg.build_status, "failed")) "❌" else "⏳";
            std.debug.print("  {s} {s} ({s}) - {s}\n", .{ status_icon, pkg.name, pkg.version, pkg.build_status });
        }
    }

    // Show built packages in repository
    std.debug.print("\n📦 Built Packages:\n", .{});
    var repo_manager = zaur.RepoManager.init(allocator, config.repo_dir, config.db_name);
    try repo_manager.listPackages();
}

fn handleClean(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const config = try zaur.Config.init(allocator);
    defer config.deinit();

    const keep_versions: u32 = if (args.len > 0)
        try std.fmt.parseInt(u32, args[0], 10)
    else
        3;

    std.debug.print("🧹 Cleaning old packages (keeping {d} versions)...\n", .{keep_versions});

    // Clean build directory
    var build_dir = std.fs.openDirAbsolute(config.build_dir, .{ .iterate = true }) catch {
        std.debug.print("Build directory not found\n", .{});
        return;
    };
    defer build_dir.close();

    var build_iter = build_dir.iterate();
    var cleaned_count: u32 = 0;
    while (try build_iter.next()) |entry| {
        if (entry.kind == .directory) {
            const full_path = try std.fs.path.join(allocator, &.{ config.build_dir, entry.name });
            defer allocator.free(full_path);

            std.fs.deleteTreeAbsolute(full_path) catch |err| {
                std.debug.print("Warning: Could not clean {s}: {}\n", .{ entry.name, err });
                continue;
            };
            cleaned_count += 1;
            std.debug.print("  Removed build dir: {s}\n", .{entry.name});
        }
    }

    var repo_manager = zaur.RepoManager.init(allocator, config.repo_dir, config.db_name);
    try repo_manager.cleanOldPackages(keep_versions);

    std.debug.print("✅ Cleaned {d} build directories\n", .{cleaned_count});
}

fn handleStatus(allocator: std.mem.Allocator) !void {
    const config = try zaur.Config.init(allocator);
    defer config.deinit();

    std.debug.print("📊 ZAUR System Status\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    // Check directories
    std.debug.print("📁 Directories:\n", .{});
    const dirs = [_][]const u8{ config.repo_dir, config.build_dir };
    for (dirs) |dir| {
        std.fs.accessAbsolute(dir, .{}) catch {
            std.debug.print("  ❌ {s} (missing)\n", .{dir});
            continue;
        };
        std.debug.print("  ✅ {s}\n", .{dir});
    }

    // Check database
    std.debug.print("\n🗄️ Database:\n", .{});
    var db = zaur.Database.init(allocator, config.db_path) catch {
        std.debug.print("  ❌ Database connection failed\n", .{});
        return;
    };
    defer db.deinit();

    const packages = try db.getPackages(allocator);
    defer {
        for (packages) |pkg| {
            pkg.deinit(allocator);
        }
        allocator.free(packages);
    }

    std.debug.print("  ✅ Connected to {s}\n", .{config.db_path});
    std.debug.print("  📦 {d} packages tracked\n", .{packages.len});

    // Count by status
    var pending: u32 = 0;
    var success: u32 = 0;
    var failed: u32 = 0;
    for (packages) |pkg| {
        if (std.mem.eql(u8, pkg.build_status, "success")) {
            success += 1;
        } else if (std.mem.eql(u8, pkg.build_status, "failed")) {
            failed += 1;
        } else {
            pending += 1;
        }
    }

    std.debug.print("     ✅ {d} successful builds\n", .{success});
    std.debug.print("     ❌ {d} failed builds\n", .{failed});
    std.debug.print("     ⏳ {d} pending builds\n", .{pending});

    // Check repository files
    std.debug.print("\n📦 Repository:\n", .{});
    const db_file = try std.fmt.allocPrint(allocator, "{s}/{s}.db.tar.zst", .{ config.repo_dir, config.db_name });
    defer allocator.free(db_file);

    std.fs.accessAbsolute(db_file, .{}) catch {
        std.debug.print("  ❌ Repository database not generated\n", .{});
        std.debug.print("  💡 Run 'zaur build all' to generate\n", .{});
        return;
    };
    std.debug.print("  ✅ Repository database exists\n", .{});

    // Count package files
    var repo_dir = std.fs.openDirAbsolute(config.repo_dir, .{ .iterate = true }) catch return;
    defer repo_dir.close();

    var pkg_count: u32 = 0;
    var repo_iter = repo_dir.iterate();
    while (try repo_iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
            pkg_count += 1;
        }
    }
    std.debug.print("  📦 {d} package files ready\n", .{pkg_count});
}

fn handleUpdate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const config = try zaur.Config.init(allocator);
    defer config.deinit();

    var db = try zaur.Database.init(allocator, config.db_path);
    defer db.deinit();

    const target = if (args.len > 0) args[0] else "all";
    std.debug.print("🔄 Checking for updates: {s}\n", .{target});

    var aur_client = zaur.AurClient.init(allocator);
    defer aur_client.deinit();

    const packages = try db.getPackages(allocator);
    defer {
        for (packages) |pkg| {
            pkg.deinit(allocator);
        }
        allocator.free(packages);
    }

    var updated_count: u32 = 0;
    var rebuild_needed = false;

    for (packages) |pkg| {
        if (!std.mem.eql(u8, target, "all") and !std.mem.eql(u8, target, pkg.name)) {
            continue;
        }

        if (std.mem.eql(u8, pkg.source_type, "aur")) {
            const latest_version = try aur_client.checkForUpdates(pkg.name);
            if (latest_version) |new_version| {
                defer allocator.free(new_version);

                if (!std.mem.eql(u8, pkg.version, new_version)) {
                    std.debug.print("🆕 Update available: {s} {s} → {s}\n", .{ pkg.name, pkg.version, new_version });

                    // Download updated PKGBUILD
                    try aur_client.downloadPkgbuild(pkg.name, config.build_dir);

                    // Update database with new version
                    try db.updatePackageVersion(pkg.name, new_version);
                    updated_count += 1;
                    rebuild_needed = true;
                } else {
                    std.debug.print("✅ Up to date: {s} ({s})\n", .{ pkg.name, pkg.version });
                }
            }
        } else if (std.mem.eql(u8, pkg.source_type, "github")) {
            // For GitHub packages, we could check releases or commits
            std.debug.print("⚠️  GitHub update checking not yet implemented: {s}\n", .{pkg.name});
        }
    }

    if (rebuild_needed) {
        std.debug.print("\n🔨 Rebuilding updated packages...\n", .{});
        var builder = zaur.PackageBuilder.init(allocator, config.build_dir, config.repo_dir);

        for (packages) |pkg| {
            if (!std.mem.eql(u8, target, "all") and !std.mem.eql(u8, target, pkg.name)) {
                continue;
            }

            const result = try builder.buildPackage(pkg.name);
            defer result.deinit(allocator);

            if (result.success) {
                try db.updatePackageBuildStatus(pkg.name, "success");
                std.debug.print("✅ Rebuilt {s} successfully\n", .{pkg.name});
            } else {
                try db.updatePackageBuildStatus(pkg.name, "failed");
                std.debug.print("❌ Failed to rebuild {s}\n", .{pkg.name});
            }
        }

        // Regenerate repository database
        var repo_manager = zaur.RepoManager.init(allocator, config.repo_dir, config.db_name);
        try repo_manager.generateRepoDatabase();
    }

    std.debug.print("\n📊 Update Summary: {d} packages updated\n", .{updated_count});
}

fn handleGpgInit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Error: Name and email required\n", .{});
        std.debug.print("Usage: zaur gpg-init <name> <email>\n", .{});
        std.debug.print("Example: zaur gpg-init \"GhostCTL AUR\" \"aur@ghostctl.com\"\n", .{});
        return;
    }

    var gpg_signer = zaur.GpgSigner.init(allocator);
    try gpg_signer.initializeGpgKey(args[0], args[1]);

    std.debug.print("\n🔐 GPG Setup Complete!\n", .{});
    std.debug.print("💡 Set environment variable: export ZAUR_GPG_KEY=\"{s}\"\n", .{args[1]});
    std.debug.print("💡 Add to your shell profile for persistence\n", .{});
}

fn printHelp() !void {
    const help_text =
        \\ZAUR: Zig Arch User Repository
        \\
        \\USAGE:
        \\    zaur <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    init                Initialize ZAUR repository
        \\    add <package>       Add package from AUR or GitHub
        \\    build [target]      Build packages (default: all)
        \\    serve [options]     Start HTTP server
        \\    sync <repo-url>     Sync from remote repository
        \\    list                List packages and repository status
        \\    clean [versions]    Clean old builds (default: keep 3)
        \\    status              Show system health and statistics
        \\    update [target]     Check for updates and rebuild (default: all)
        \\    gpg-init <name> <email>  Initialize GPG key for package signing
        \\    help                Show this help
        \\
        \\EXAMPLES:
        \\    zaur init
        \\    zaur gpg-init "GhostCTL AUR" "aur@ghostctl.com"
        \\    zaur add aur/firefox
        \\    zaur add github:ghostkellz/nvcontrol
        \\    zaur add github:user/repo@main/subdir
        \\    zaur build all
        \\    zaur update firefox
        \\    zaur update all
        \\    zaur list
        \\    zaur clean 5
        \\    zaur status
        \\    zaur serve --port 8080 --bind 0.0.0.0
        \\
        \\OPTIONS (serve):
        \\    --port <port>       Port to bind to (default: 8080)
        \\    --bind <address>    Address to bind to (default: 127.0.0.1)
        \\
    ;
    std.debug.print("{s}", .{help_text});
}
