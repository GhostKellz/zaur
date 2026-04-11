const std = @import("std");
const zaur = @import("zaur");

const Command = enum {
    init,
    config,
    source,
    build,
    repo,
    mirror,
    serve,
    list,
    clean,
    status,
    doctor,
    update,
    @"gpg-init",
    generate,
    backup,
    restore,
    security,
    add,
    sync,
    smart_sync,
    auto_update,
    help,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

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
        .init => try handleInit(allocator, init.environ_map),
        .config => try handleConfig(allocator, init.environ_map, args[2..]),
        .source => try handleSource(allocator, init.environ_map, args[2..]),
        .build => try handleBuild(allocator, init.environ_map, args[2..]),
        .repo => try handleRepo(allocator, init.environ_map, args[2..]),
        .mirror => try handleMirror(allocator, init.environ_map, args[2..]),
        .serve => try handleServe(allocator, init.environ_map, args[2..]),
        .list => try handleList(allocator, init.environ_map),
        .clean => try handleClean(allocator, init.environ_map, args[2..]),
        .status => try handleStatus(allocator, init.environ_map),
        .doctor => try handleDoctor(allocator, init.environ_map),
        .update => try handleUpdate(allocator, init.environ_map, args[2..]),
        .@"gpg-init" => try handleGpgInit(allocator, args[2..]),
        .generate => try handleGenerate(allocator, args[2..]),
        .backup => try handleBackup(allocator, init.environ_map),
        .restore => try handleRestore(allocator, init.environ_map, args[2..]),
        .security => try handleSecurity(allocator, init.environ_map, args[2..]),
        .add => try handleAddCompat(allocator, init.environ_map, args[2..]),
        .sync => try handleMirrorSyncCompat(allocator, init.environ_map, args[2..]),
        .smart_sync => try handleMirrorSmartSyncCompat(allocator, init.environ_map),
        .auto_update => try handleMirrorAutoUpdateCompat(allocator, init.environ_map),
        .help => try printHelp(),
    }
}

fn printHelp() !void {
    const help_text =
        \\ZAUR
        \\
        \\USAGE:
        \\    zaur <COMMAND> [OPTIONS]
        \\
        \\FOUNDATION COMMANDS:
        \\    init
        \\    config validate
        \\    config show
        \\    source add <spec>
        \\    source list
        \\    source update [name|all]
        \\    build run [package|all]
        \\    build logs [package]
        \\    repo publish
        \\    repo list
        \\    mirror sync [repo...]
        \\    mirror smart-sync
        \\    mirror auto-update
        \\    mirror verify
        \\    serve [--port <port>] [--bind <addr>]
        \\    doctor
        \\    status
        \\    clean [keep_versions]
        \\    backup
        \\    restore <backup_file>
        \\    generate <project_directory> [source_url] [--wasm]
        \\    gpg-init <name> <email>
        \\
        \\SECURITY COMMANDS:
        \\    security sync               Sync advisories from Arch security tracker
        \\    security status             Show security status summary
        \\    security status <package>   Show status for specific package
        \\    security scan [all]         Recompute security status for all packages
        \\    security scan <package>     Recompute status for specific package
        \\
        \\COMPATIBILITY ALIASES:
        \\    add <spec>
        \\    build [target]
        \\    sync [repo...]
        \\    smart-sync
        \\    auto-update
        \\
        \\SOURCE SPECS:
        \\    aur/firefox
        \\    github:user/repo
        \\    local:/absolute/or/relative/path
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn openConfigAndDb(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !struct { config: zaur.Config, db: zaur.Database } {
    const config = try zaur.Config.init(allocator, environ_map);
    errdefer config.deinit();
    try config.ensureDirectories();
    const db = try zaur.Database.init(allocator, config.db_path);
    return .{ .config = config, .db = db };
}

fn handleInit(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    std.debug.print("Initialized ZAUR\n", .{});
    std.debug.print("  data_root: {s}\n", .{ctx.config.data_root});
    std.debug.print("  repo_root: {s}\n", .{ctx.config.repo_root});
    std.debug.print("  build_root: {s}\n", .{ctx.config.build_root});
    std.debug.print("  source_root: {s}\n", .{ctx.config.source_root});
    std.debug.print("  db_path: {s}\n", .{ctx.config.db_path});
}

fn handleConfig(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    const action = if (args.len > 0) args[0] else "show";
    const config = try zaur.Config.init(allocator, environ_map);
    defer config.deinit();

    if (std.mem.eql(u8, action, "validate")) {
        try config.ensureDirectories();
        var db = try zaur.Database.init(allocator, config.db_path);
        defer db.deinit();
        const healthy = try db.healthCheck();
        std.debug.print("config valid: {any}\n", .{healthy});
        return;
    }

    std.debug.print("data_root={s}\n", .{config.data_root});
    std.debug.print("repo_root={s}\n", .{config.repo_root});
    std.debug.print("aur_repo_dir={s}\n", .{config.aur_repo_dir});
    std.debug.print("custom_repo_dir={s}\n", .{config.custom_repo_dir});
    std.debug.print("mirror_root={s}\n", .{config.mirror_root});
    std.debug.print("build_root={s}\n", .{config.build_root});
    std.debug.print("source_root={s}\n", .{config.source_root});
    std.debug.print("log_root={s}\n", .{config.log_root});
    std.debug.print("db_path={s}\n", .{config.db_path});
    std.debug.print("bind={s}\n", .{config.bind_address});
    std.debug.print("port={d}\n", .{config.port});
}

fn handleSource(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zaur source <add|list> ...\n", .{});
        return;
    }

    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 2) {
            std.debug.print("Usage: zaur source add <spec>\n", .{});
            return;
        }
        const spec = try zaur.SourceManager.parse(args[1]);
        const package_name = try zaur.SourceManager.addSource(allocator, ctx.config, &ctx.db, spec);
        defer allocator.free(package_name);
        std.debug.print("added source for package {s}\n", .{package_name});
        return;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        const sources = try ctx.db.getSources(allocator);
        defer {
            for (sources) |source| source.deinit(allocator);
            allocator.free(sources);
        }
        for (sources) |source| {
            std.debug.print("{s} [{s}] {s}\n", .{ source.name, source.kind.asString(), source.location });
        }
        return;
    }

    if (std.mem.eql(u8, args[0], "update")) {
        const target = if (args.len > 1) args[1] else "all";
        if (std.mem.eql(u8, target, "all")) {
            try zaur.SourceManager.updateAllSources(allocator, ctx.config, &ctx.db);
        } else {
            try zaur.SourceManager.updateSource(allocator, ctx.config, &ctx.db, target);
        }
        return;
    }

    std.debug.print("Unsupported source action: {s}\n", .{args[0]});
}

fn handleBuild(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    const action = if (args.len > 0 and !std.mem.eql(u8, args[0], "all")) args[0] else "run";

    if (std.mem.eql(u8, action, "logs")) {
        const target = if (args.len > 1) args[1] else if (args.len == 1 and !std.mem.eql(u8, args[0], "logs")) args[0] else null;
        return handleBuildLogs(allocator, environ_map, target);
    }

    const target = if (std.mem.eql(u8, action, "run")) blk: {
        if (args.len > 1) break :blk args[1];
        if (args.len == 1 and !std.mem.eql(u8, args[0], "run")) break :blk args[0];
        break :blk "all";
    } else args[0];

    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    if (std.mem.eql(u8, target, "all")) {
        const packages = try ctx.db.getPackages(allocator);
        defer {
            for (packages) |pkg| pkg.deinit(allocator);
            allocator.free(packages);
        }

        for (packages) |pkg| {
            try buildSinglePackage(allocator, &ctx.db, ctx.config, pkg.name, pkg.repo_name);
        }
    } else {
        const package = try ctx.db.getPackage(allocator, target) orelse {
            std.debug.print("package not found: {s}\n", .{target});
            return;
        };
        defer package.deinit(allocator);
        try buildSinglePackage(allocator, &ctx.db, ctx.config, package.name, package.repo_name);
    }
}

fn buildSinglePackage(allocator: std.mem.Allocator, db: *zaur.Database, config: zaur.Config, package_name: []const u8, repo_name: []const u8) !void {
    const source = try db.getSource(allocator, package_name) orelse {
        std.debug.print("source not found for package {s}\n", .{package_name});
        return;
    };
    defer source.deinit(allocator);

    var builder = zaur.PackageBuilder.init(allocator, config.source_root, config.build_root, config.repoDirForName(repo_name), &config);
    defer builder.deinit();
    const result = try builder.buildPackage(package_name);
    defer result.deinit(allocator);

    if (result.success) {
        try db.updatePackageBuildStatus(package_name, "success");
        try db.addBuildLog(package_name, "success", result.log);
        std.debug.print("built {s}\n", .{package_name});
    } else {
        try db.updatePackageBuildStatus(package_name, "failed");
        try db.addBuildLog(package_name, "failed", result.log);
        std.debug.print("build failed for {s}\n", .{package_name});
    }
}

fn handleBuildLogs(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, package_name: ?[]const u8) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    const logs = try ctx.db.getBuildLogs(allocator, package_name);
    defer {
        for (logs) |log| log.deinit(allocator);
        allocator.free(logs);
    }

    for (logs) |log| {
        std.debug.print("[{s}] {s} {s}\n{s}\n\n", .{ log.finished_at, log.package_name, log.status, log.build_log });
    }
}

fn handleRepo(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    const action = if (args.len > 0) args[0] else "publish";
    const config = try zaur.Config.init(allocator, environ_map);
    defer config.deinit();

    if (std.mem.eql(u8, action, "publish")) {
        var failed = false;

        var aur_repo = zaur.RepoManager.init(allocator, config.aur_repo_dir, "aur");
        defer aur_repo.deinit();
        aur_repo.generateRepoDatabase() catch |err| {
            std.debug.print("Failed to generate AUR repo: {}\n", .{err});
            failed = true;
        };

        var custom_repo = zaur.RepoManager.init(allocator, config.custom_repo_dir, "custom");
        defer custom_repo.deinit();
        custom_repo.generateRepoDatabase() catch |err| {
            std.debug.print("Failed to generate custom repo: {}\n", .{err});
            failed = true;
        };

        if (failed) return error.PublishFailed;
        return;
    }

    if (std.mem.eql(u8, action, "list")) {
        var aur_repo = zaur.RepoManager.init(allocator, config.aur_repo_dir, "aur");
        defer aur_repo.deinit();
        try aur_repo.listPackages();
        var custom_repo = zaur.RepoManager.init(allocator, config.custom_repo_dir, "custom");
        defer custom_repo.deinit();
        try custom_repo.listPackages();
        return;
    }

    std.debug.print("Unsupported repo action: {s}\n", .{action});
}

fn handleMirror(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    const action = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, action, "sync")) return handleMirrorSyncCompat(allocator, environ_map, if (args.len > 1) args[1..] else &.{});
    if (std.mem.eql(u8, action, "smart-sync")) return handleMirrorSmartSyncCompat(allocator, environ_map);
    if (std.mem.eql(u8, action, "auto-update")) return handleMirrorAutoUpdateCompat(allocator, environ_map);
    if (std.mem.eql(u8, action, "verify")) {
        var ctx = try openConfigAndDb(allocator, environ_map);
        defer ctx.db.deinit();
        defer ctx.config.deinit();
        try zaur.MirrorCommands.handleVerify(allocator, &ctx.config, &ctx.db);
        return;
    }
    if (std.mem.eql(u8, action, "status")) {
        var ctx = try openConfigAndDb(allocator, environ_map);
        defer ctx.db.deinit();
        defer ctx.config.deinit();

        var mirror = try zaur.ArchMirror.init(allocator, &ctx.config, &ctx.db);
        defer mirror.deinit();

        var status = try mirror.getStatus();
        defer status.deinit(allocator);
        status.print();
        return;
    }
    std.debug.print("Unsupported mirror action: {s}\n", .{action});
    std.debug.print("Available actions: status, sync, smart-sync, auto-update, verify\n", .{});
}

fn handleServe(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            ctx.config.port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bind") and i + 1 < args.len) {
            allocator.free(ctx.config.bind_address);
            ctx.config.bind_address = try allocator.dupe(u8, args[i + 1]);
            i += 1;
        }
    }

    var server = zaur.HttpServer.initWithConfig(allocator, &ctx.config, &ctx.db);
    try server.start();
}

fn handleList(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    const packages = try ctx.db.getPackages(allocator);
    defer {
        for (packages) |pkg| pkg.deinit(allocator);
        allocator.free(packages);
    }

    for (packages) |pkg| {
        std.debug.print("{s} {s} [{s}] repo={s} status={s}\n", .{ pkg.name, pkg.version, pkg.source_type, pkg.repo_name, pkg.build_status });
    }
}

fn handleClean(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    const config = try zaur.Config.init(allocator, environ_map);
    defer config.deinit();
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const keep_versions: u32 = if (args.len > 0) try std.fmt.parseInt(u32, args[0], 10) else 3;
    var build_dir = std.Io.Dir.openDirAbsolute(io, config.build_root, .{ .iterate = true }) catch return;
    defer build_dir.close(io);

    var iter = build_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            const full_path = try std.fs.path.join(allocator, &.{ config.build_root, entry.name });
            defer allocator.free(full_path);
            std.Io.Dir.deleteTree(.cwd(), io, full_path) catch {};
        }
    }

    var aur_repo = zaur.RepoManager.init(allocator, config.aur_repo_dir, "aur");
    defer aur_repo.deinit();
    try aur_repo.cleanOldPackages(keep_versions);

    var custom_repo = zaur.RepoManager.init(allocator, config.custom_repo_dir, "custom");
    defer custom_repo.deinit();
    try custom_repo.cleanOldPackages(keep_versions);
}

fn handleStatus(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    try handleDoctor(allocator, environ_map);
}

fn handleDoctor(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    const healthy = try ctx.db.healthCheck();
    const package_count = try ctx.db.getPackageCount();
    std.debug.print("database_ok={any}\n", .{healthy});
    std.debug.print("packages={d}\n", .{package_count});
    std.debug.print("data_root={s}\n", .{ctx.config.data_root});
    std.debug.print("aur_repo_dir={s}\n", .{ctx.config.aur_repo_dir});
    std.debug.print("custom_repo_dir={s}\n", .{ctx.config.custom_repo_dir});
    std.debug.print("build_root={s}\n", .{ctx.config.build_root});
}

fn handleUpdate(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    const target = if (args.len > 0) args[0] else "all";
    var aur_client = zaur.AurClient.init(allocator);
    defer aur_client.deinit();

    const packages = try ctx.db.getPackages(allocator);
    defer {
        for (packages) |pkg| pkg.deinit(allocator);
        allocator.free(packages);
    }

    for (packages) |pkg| {
        if (!std.mem.eql(u8, target, "all") and !std.mem.eql(u8, target, pkg.name)) continue;
        if (std.mem.eql(u8, pkg.source_type, "aur")) {
            const latest = try aur_client.checkForUpdates(pkg.name);
            if (latest) |version| {
                defer allocator.free(version);
                if (!std.mem.eql(u8, version, pkg.version)) {
                    try ctx.db.updatePackageVersion(pkg.name, version);
                    try aur_client.downloadPkgbuild(pkg.name, ctx.config.source_root);
                    try buildSinglePackage(allocator, &ctx.db, ctx.config, pkg.name, pkg.repo_name);
                }
            }
        }
    }
}

fn handleGpgInit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: zaur gpg-init <name> <email>\n", .{});
        return;
    }
    var gpg_signer = zaur.GpgSigner.init(allocator, null);
    defer gpg_signer.deinit();
    try gpg_signer.initializeGpgKey(args[0], args[1]);
}

fn handleGenerate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    if (args.len == 0) {
        std.debug.print("Usage: zaur generate <project_directory> [source_url] [--wasm]\n", .{});
        return;
    }

    const project_dir = args[0];
    const source_url = if (args.len > 1 and !std.mem.eql(u8, args[1], "--wasm")) args[1] else "https://example.com/source.tar.gz";
    const is_wasm = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--wasm")) break true;
    } else false;

    std.Io.Dir.access(.cwd(), io, project_dir, .{}) catch return error.FileNotFound;

    var zb = zaur.ZigBuilder.init(allocator, project_dir, ".");
    defer zb.deinit();
    var rb = zaur.RustBuilder.init(allocator, project_dir, ".");
    defer rb.deinit();

    var pkgbuild: []const u8 = undefined;
    defer allocator.free(pkgbuild);

    if (zb.isZigProject(project_dir)) {
        const project_info = try zb.analyzeProject(project_dir);
        defer project_info.deinit(allocator);
        pkgbuild = try zb.generatePKGBUILD(project_info, source_url);
    } else if (rb.isRustProject(project_dir)) {
        const project_info = try rb.analyzeProject(project_dir);
        defer project_info.deinit(allocator);
        pkgbuild = if (is_wasm) try rb.generateWasmPKGBUILD(project_info, source_url) else try rb.generatePKGBUILD(project_info, source_url);
    } else {
        const project_info = try zb.analyzeProject(project_dir);
        defer project_info.deinit(allocator);
        pkgbuild = try zb.generateHybridPKGBUILD(project_info, source_url);
    }

    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = "PKGBUILD", .data = pkgbuild });
    std.debug.print("generated PKGBUILD\n", .{});
}

fn handleAddCompat(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zaur add <spec>\n", .{});
        return;
    }
    try handleSource(allocator, environ_map, &.{ "add", args[0] });
}

fn handleMirrorSyncCompat(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();
    var mirror = try zaur.ArchMirror.init(allocator, &ctx.config, &ctx.db);
    defer mirror.deinit();

    if (args.len == 0) {
        try mirror.enableFullMirror();
    } else {
        for (args) |repo| try mirror.syncRepository(repo);
    }
}

fn handleMirrorSmartSyncCompat(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();
    var mirror = try zaur.ArchMirror.init(allocator, &ctx.config, &ctx.db);
    defer mirror.deinit();
    try mirror.smartSync();
}

fn handleMirrorAutoUpdateCompat(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();
    var mirror = try zaur.ArchMirror.init(allocator, &ctx.config, &ctx.db);
    defer mirror.deinit();
    try mirror.autoUpdate();
}

fn handleBackup(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const config = try zaur.Config.init(allocator, environ_map);
    defer config.deinit();

    // Create backups directory
    const backups_dir = try std.fs.path.join(allocator, &.{ config.data_root, "backups" });
    defer allocator.free(backups_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, backups_dir);

    // Generate timestamp for backup filename (seconds since epoch)
    const ts = std.Io.Timestamp.now(io, .real);
    const timestamp_secs = @divFloor(ts.nanoseconds, 1_000_000_000);
    const backup_name = try std.fmt.allocPrint(allocator, "zaur-{d}.db", .{timestamp_secs});
    defer allocator.free(backup_name);

    const backup_path = try std.fs.path.join(allocator, &.{ backups_dir, backup_name });
    defer allocator.free(backup_path);

    // Copy database file
    try std.Io.Dir.copyFileAbsolute(config.db_path, backup_path, io, .{});

    std.debug.print("Backup created: {s}\n", .{backup_path});
}

fn handleRestore(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    if (args.len == 0) {
        std.debug.print("Usage: zaur restore <backup_file>\n", .{});
        std.debug.print("\nAvailable backups:\n", .{});

        const config = try zaur.Config.init(allocator, environ_map);
        defer config.deinit();

        const backups_dir = try std.fs.path.join(allocator, &.{ config.data_root, "backups" });
        defer allocator.free(backups_dir);

        var dir = std.Io.Dir.openDirAbsolute(io, backups_dir, .{ .iterate = true }) catch {
            std.debug.print("  No backups found\n", .{});
            return;
        };
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".db")) {
                std.debug.print("  {s}\n", .{entry.name});
            }
        }
        return;
    }

    const config = try zaur.Config.init(allocator, environ_map);
    defer config.deinit();

    const backup_file = args[0];
    var backup_path: []const u8 = undefined;
    defer if (!std.fs.path.isAbsolute(backup_file)) allocator.free(backup_path);

    if (std.fs.path.isAbsolute(backup_file)) {
        backup_path = backup_file;
    } else {
        const backups_dir = try std.fs.path.join(allocator, &.{ config.data_root, "backups" });
        defer allocator.free(backups_dir);
        backup_path = try std.fs.path.join(allocator, &.{ backups_dir, backup_file });
    }

    // Check backup file exists
    std.Io.Dir.accessAbsolute(io, backup_path, .{}) catch {
        std.debug.print("Backup file not found: {s}\n", .{backup_path});
        return;
    };

    // Copy backup to database path
    try std.Io.Dir.copyFileAbsolute(backup_path, config.db_path, io, .{});

    std.debug.print("Database restored from: {s}\n", .{backup_path});
}

fn handleSecurity(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zaur security <sync|status|scan> ...\n", .{});
        return;
    }

    var ctx = try openConfigAndDb(allocator, environ_map);
    defer ctx.db.deinit();
    defer ctx.config.deinit();

    var security = zaur.SecurityManager.init(allocator, &ctx.config, &ctx.db);
    defer security.deinit();

    const action = args[0];

    if (std.mem.eql(u8, action, "sync")) {
        std.debug.print("Syncing advisories from Arch security tracker...\n", .{});
        const result = try security.syncAdvisories();
        std.debug.print("Synced {d} advisories ({d} errors)\n", .{ result.advisories_synced, result.errors });
        return;
    }

    if (std.mem.eql(u8, action, "status")) {
        if (args.len > 1) {
            // Single package status
            const package_name = args[1];
            const status = try security.getPackageStatus(package_name);
            if (status) |s| {
                defer s.deinit(allocator);
                printPackageSecurityStatus(s);
            } else {
                std.debug.print("No security status for package: {s}\n", .{package_name});
                std.debug.print("Run 'zaur security scan {s}' to compute status\n", .{package_name});
            }
        } else {
            // All packages status summary
            const statuses = try security.getAllPackageStatuses();
            defer {
                for (statuses) |s| s.deinit(allocator);
                allocator.free(statuses);
            }

            if (statuses.len == 0) {
                std.debug.print("No security statuses available.\n", .{});
                std.debug.print("Run 'zaur security scan all' to compute statuses.\n", .{});
                return;
            }

            var vulnerable: u32 = 0;
            var clean: u32 = 0;
            var unknown: u32 = 0;
            var stale: u32 = 0;
            var unsigned: u32 = 0;

            for (statuses) |s| {
                printPackageSecurityStatus(s);
                switch (s.advisory_status) {
                    .vulnerable => vulnerable += 1,
                    .clean => clean += 1,
                    .unknown => unknown += 1,
                    .unscanned => {},
                }
                if (s.stale_status == .stale) stale += 1;
                if (s.signature_status == .unsigned) unsigned += 1;
            }

            std.debug.print("\nSummary: {d} packages - {d} vulnerable, {d} clean, {d} unknown, {d} stale, {d} unsigned\n", .{ statuses.len, vulnerable, clean, unknown, stale, unsigned });
        }
        return;
    }

    if (std.mem.eql(u8, action, "scan")) {
        if (args.len > 1 and !std.mem.eql(u8, args[1], "all")) {
            // Single package scan
            const package_name = args[1];
            std.debug.print("Scanning package: {s}\n", .{package_name});
            const status = try security.scanPackage(package_name);
            if (status) |s| {
                defer s.deinit(allocator);
                printPackageSecurityStatus(s);
            } else {
                std.debug.print("Package not found: {s}\n", .{package_name});
            }
        } else {
            // Scan all packages
            std.debug.print("Scanning all packages...\n", .{});
            const result = try security.scanAllPackages();
            std.debug.print("Scanned {d} packages: {d} clean, {d} vulnerable, {d} unknown\n", .{ result.total, result.clean, result.vulnerable, result.unknown });
            if (result.stale > 0) std.debug.print("  {d} stale packages\n", .{result.stale});
            if (result.unsigned > 0) std.debug.print("  {d} unsigned packages\n", .{result.unsigned});
        }
        return;
    }

    std.debug.print("Unknown security action: {s}\n", .{action});
    std.debug.print("Usage: zaur security <sync|status|scan> ...\n", .{});
}

fn printPackageSecurityStatus(s: zaur.PackageSecurityStatus) void {
    // Build status string
    var status_parts: [3][]const u8 = undefined;
    var status_count: usize = 0;

    status_parts[status_count] = s.advisory_status.asString();
    status_count += 1;

    if (s.stale_status == .stale) {
        status_parts[status_count] = "stale";
        status_count += 1;
    }
    if (s.signature_status == .unsigned) {
        status_parts[status_count] = "unsigned";
        status_count += 1;
    }

    // Print in key=value format
    std.debug.print("package={s} repo={s} version={s} status={s}", .{
        s.package_name,
        s.repo_name,
        s.hosted_version,
        status_parts[0],
    });

    for (status_parts[1..status_count]) |part| {
        std.debug.print(",{s}", .{part});
    }

    std.debug.print(" advisories={d}", .{s.advisory_match_count});

    if (s.highest_severity) |sev| {
        std.debug.print(" severity={s}", .{sev.asString()});
    }

    std.debug.print("\n", .{});
}
