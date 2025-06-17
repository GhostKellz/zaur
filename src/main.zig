const std = @import("std");
const zaur = @import("zaur");

const Command = enum {
    init,
    add,
    build,
    serve,
    sync,
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
        try db.addPackage(github_spec, "github", package_spec);
        std.debug.print("✓ Added GitHub package: {s}\n", .{github_spec});
        std.debug.print("Note: GitHub package support is planned for future versions\n", .{});
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
        \\    help                Show this help
        \\
        \\EXAMPLES:
        \\    zaur init
        \\    zaur add aur/firefox
        \\    zaur add github:ghostkellz/nvcontrol
        \\    zaur build all
        \\    zaur serve --port 8080 --bind 0.0.0.0
        \\
        \\OPTIONS (serve):
        \\    --port <port>       Port to bind to (default: 8080)
        \\    --bind <address>    Address to bind to (default: 127.0.0.1)
        \\
    ;
    std.debug.print("{s}", .{help_text});
}
