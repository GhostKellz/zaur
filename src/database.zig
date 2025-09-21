const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    source_type: []const u8,
    source_url: []const u8,
    build_status: []const u8,
    added_at: []const u8,

    pub fn deinit(self: Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.source_type);
        allocator.free(self.source_url);
        allocator.free(self.build_status);
        allocator.free(self.added_at);
    }
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        var db: ?*c.sqlite3 = null;
        const result = c.sqlite3_open(db_path.ptr, &db);
        if (result != c.SQLITE_OK) {
            return error.DatabaseOpenFailed;
        }

        var database = Database{
            .allocator = allocator,
            .db = db.?,
        };

        try database.createTables();
        return database;
    }

    pub fn deinit(self: *Database) void {
        _ = c.sqlite3_close(self.db);
    }

    fn createTables(self: *Database) !void {
        const create_packages_sql =
            \\CREATE TABLE IF NOT EXISTS packages (
            \\    id INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL UNIQUE,
            \\    version TEXT DEFAULT 'unknown',
            \\    source_type TEXT NOT NULL, -- 'aur', 'github', 'local'
            \\    source_url TEXT NOT NULL,
            \\    build_status TEXT DEFAULT 'pending', -- 'pending', 'building', 'success', 'failed'
            \\    added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
        ;

        const create_builds_sql =
            \\CREATE TABLE IF NOT EXISTS builds (
            \\    id INTEGER PRIMARY KEY,
            \\    package_id INTEGER NOT NULL,
            \\    build_log TEXT,
            \\    status TEXT NOT NULL, -- 'success', 'failed'
            \\    started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    finished_at DATETIME,
            \\    FOREIGN KEY (package_id) REFERENCES packages(id)
            \\);
        ;

        const create_mirror_cache_sql =
            \\CREATE TABLE IF NOT EXISTS mirror_cache (
            \\    id INTEGER PRIMARY KEY,
            \\    repo_name TEXT NOT NULL, -- 'core', 'extra', 'multilib'
            \\    package_name TEXT NOT NULL,
            \\    package_version TEXT NOT NULL,
            \\    file_path TEXT NOT NULL,
            \\    file_size INTEGER,
            \\    cached_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    last_accessed DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    UNIQUE(repo_name, package_name, package_version)
            \\);
        ;

        try self.execute(create_packages_sql);
        try self.execute(create_builds_sql);
        try self.execute(create_mirror_cache_sql);
    }

    pub fn addPackage(self: *Database, name: []const u8, source_type: []const u8, source_url: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT OR REPLACE INTO packages (name, source_type, source_url, build_status) VALUES (?, ?, ?, 'pending')", .{});
        defer self.allocator.free(sql);

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (result != c.SQLITE_OK) {
            std.debug.print("SQL prepare error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Bind parameters
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, source_type.ptr, @intCast(source_type.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 3, source_url.ptr, @intCast(source_url.len), c.SQLITE_TRANSIENT);

        const step_result = c.sqlite3_step(stmt);
        if (step_result != c.SQLITE_DONE) {
            std.debug.print("SQL step error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlStepFailed;
        }
    }

    pub fn updatePackageVersion(self: *Database, name: []const u8, version: []const u8) !void {
        const sql = "UPDATE packages SET version = ?, updated_at = CURRENT_TIMESTAMP WHERE name = ?;";

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (result != c.SQLITE_OK) {
            std.debug.print("SQL prepare error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Bind parameters
        _ = c.sqlite3_bind_text(stmt, 1, version.ptr, @intCast(version.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT);

        const step_result = c.sqlite3_step(stmt);
        if (step_result != c.SQLITE_DONE) {
            std.debug.print("SQL step error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlStepFailed;
        }
    }

    pub fn updatePackageBuildStatus(self: *Database, name: []const u8, status: []const u8) !void {
        const sql = "UPDATE packages SET build_status = ?, updated_at = CURRENT_TIMESTAMP WHERE name = ?;";

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (result != c.SQLITE_OK) {
            std.debug.print("SQL prepare error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Bind parameters
        _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT);

        const step_result = c.sqlite3_step(stmt);
        if (step_result != c.SQLITE_DONE) {
            std.debug.print("SQL step error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlStepFailed;
        }
    }

    pub fn getPackages(self: *Database, allocator: std.mem.Allocator) ![]Package {
        const sql = "SELECT name, version, source_type, source_url, build_status, added_at FROM packages ORDER BY name;";

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (result != c.SQLITE_OK) {
            std.debug.print("SQL prepare error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var packages = std.ArrayList(Package).initCapacity(allocator, 0);
        errdefer packages.deinit();

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 0) orelse "unknown");
            const version = std.mem.span(c.sqlite3_column_text(stmt, 1) orelse "unknown");
            const source_type = std.mem.span(c.sqlite3_column_text(stmt, 2) orelse "unknown");
            const source_url = std.mem.span(c.sqlite3_column_text(stmt, 3) orelse "");
            const build_status = std.mem.span(c.sqlite3_column_text(stmt, 4) orelse "pending");
            const added_at = std.mem.span(c.sqlite3_column_text(stmt, 5) orelse "");

            const package = Package{
                .name = try allocator.dupe(u8, name),
                .version = try allocator.dupe(u8, version),
                .source_type = try allocator.dupe(u8, source_type),
                .source_url = try allocator.dupe(u8, source_url),
                .build_status = try allocator.dupe(u8, build_status),
                .added_at = try allocator.dupe(u8, added_at),
            };
            try packages.append(package);
        }

        return packages.toOwnedSlice();
    }

    pub fn getPackage(self: *Database, allocator: std.mem.Allocator, name: []const u8) !?Package {
        const sql =
            \\SELECT name, version, source_type, source_url, build_status, added_at 
            \\FROM packages WHERE name = ? LIMIT 1;
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bind(0, name);

        if (try stmt.queryRow()) |row| {
            return Package{
                .name = try allocator.dupe(u8, row.getTextByName("name") orelse "unknown"),
                .version = try allocator.dupe(u8, row.getTextByName("version") orelse "unknown"),
                .source_type = try allocator.dupe(u8, row.getTextByName("source_type") orelse "unknown"),
                .source_url = try allocator.dupe(u8, row.getTextByName("source_url") orelse ""),
                .build_status = try allocator.dupe(u8, row.getTextByName("build_status") orelse "pending"),
                .added_at = try allocator.dupe(u8, row.getTextByName("added_at") orelse ""),
            };
        }

        return null;
    }

    pub fn removePackage(self: *Database, name: []const u8) !void {
        const sql = "DELETE FROM packages WHERE name = ?;";

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bind(0, name);
        _ = try stmt.execute(self.db);
    }

    pub fn getPackageCount(self: *Database) !u32 {
        const sql = "SELECT COUNT(*) as count FROM packages;";

        if (try self.db.queryRow(sql)) |row| {
            return @intCast(row.getIntByName("count") orelse 0);
        }

        return 0;
    }

    // Mirror cache management
    pub fn cacheMirrorPackage(self: *Database, repo: []const u8, package_name: []const u8, version: []const u8, file_path: []const u8, file_size: u64) !void {
        const sql =
            \\INSERT OR REPLACE INTO mirror_cache 
            \\(repo_name, package_name, package_version, file_path, file_size, cached_at, last_accessed) 
            \\VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bind(0, repo);
        try stmt.bind(1, package_name);
        try stmt.bind(2, version);
        try stmt.bind(3, file_path);
        try stmt.bind(4, @intCast(file_size));

        _ = try stmt.execute(self.db);
    }

    pub fn getCachedPackages(self: *Database, allocator: std.mem.Allocator, repo: []const u8) ![][]const u8 {
        const sql =
            \\SELECT DISTINCT package_name FROM mirror_cache 
            \\WHERE repo_name = ? ORDER BY package_name;
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bind(0, repo);

        var result_set = try stmt.query();
        defer result_set.deinit();

        var packages = std.ArrayList([]const u8){};
        defer packages.deinit(allocator);

        while (result_set.next()) |row| {
            const package_name = try allocator.dupe(u8, row.getTextByName("package_name") orelse "");
            try packages.append(allocator, package_name);
        }

        return packages.toOwnedSlice();
    }

    pub fn updateLastAccessed(self: *Database, repo: []const u8, package_name: []const u8) !void {
        const sql =
            \\UPDATE mirror_cache SET last_accessed = CURRENT_TIMESTAMP 
            \\WHERE repo_name = ? AND package_name = ?;
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bind(0, repo);
        try stmt.bind(1, package_name);

        _ = try stmt.execute(self.db);
    }

    pub fn cleanOldCache(self: *Database, days_old: u32) !u32 {
        const sql =
            \\DELETE FROM mirror_cache 
            \\WHERE last_accessed < datetime('now', '-' || ? || ' days');
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bind(0, @intCast(days_old));

        return try stmt.execute(self.db);
    }

    // Build logging
    pub fn addBuildLog(self: *Database, package_name: []const u8, status: []const u8, log: []const u8) !void {
        // First get package ID
        const get_id_sql = "SELECT id FROM packages WHERE name = ? LIMIT 1;";

        var id_stmt = try self.db.prepare(get_id_sql);
        defer id_stmt.deinit();

        try id_stmt.bind(0, package_name);

        if (try id_stmt.queryRow()) |row| {
            const package_id = row.getIntByName("id") orelse return;

            const insert_sql =
                \\INSERT INTO builds (package_id, status, build_log, finished_at) 
                \\VALUES (?, ?, ?, CURRENT_TIMESTAMP);
            ;

            var stmt = try self.db.prepare(insert_sql);
            defer stmt.deinit();

            try stmt.bind(0, @intCast(package_id));
            try stmt.bind(1, status);
            try stmt.bind(2, log);

            _ = try stmt.execute(self.db);
        }
    }

    // Database introspection using ZQLite v1.2.2 schema APIs
    // pub fn getTableNames(self: *Database, allocator: std.mem.Allocator) ![][]const u8 {
    //     return try self.db.getTableNames(allocator);
    // }

    // pub fn getTableSchema(self: *Database, allocator: std.mem.Allocator, table_name: []const u8) ![]sqlite.ColumnInfo {
    //     return try self.db.getTableSchema(allocator, table_name);
    // }

    // Health check
    // pub fn healthCheck(self: *Database) !bool {
    //     const sql = "SELECT 1 as test;";

    //     if (try self.db.queryRow(sql)) |row| {
    //         return (row.getIntByName("test") orelse 0) == 1;
    //     }

    //     return false;
    // }

    fn execute(self: *Database, sql: []const u8) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (result != c.SQLITE_OK) {
            std.debug.print("SQL prepare error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const step_result = c.sqlite3_step(stmt);
        if (step_result != c.SQLITE_DONE and step_result != c.SQLITE_ROW) {
            std.debug.print("SQL step error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.SqlStepFailed;
        }
    }
};
