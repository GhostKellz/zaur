const std = @import("std");
const sqlite = @import("sqlite");

pub const Database = struct {
    db: sqlite.Db,
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Database {
        // Convert path to null-terminated string
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const db = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = path_z },
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .threading_mode = .MultiThread,
        });

        var self = Database{
            .db = db,
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
        };

        try self.initSchema();
        return self;
    }

    pub fn deinit(self: *Database) void {
        self.db.deinit();
        self.allocator.free(self.path);
    }

    fn initSchema(self: *Database) !void {
        // Create packages table
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS packages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    name TEXT UNIQUE NOT NULL,
            \\    version TEXT NOT NULL DEFAULT 'unknown',
            \\    description TEXT,
            \\    source_type TEXT NOT NULL, -- 'aur', 'github', 'local'
            \\    source_url TEXT NOT NULL,
            \\    build_status TEXT DEFAULT 'pending', -- 'pending', 'building', 'success', 'failed'
            \\    last_built TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
        , .{}, .{});

        // Create build logs table
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS build_logs (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    package_id INTEGER NOT NULL,
            \\    log_content TEXT,
            \\    build_time DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    success BOOLEAN DEFAULT 0,
            \\    FOREIGN KEY (package_id) REFERENCES packages(id)
            \\);
        , .{}, .{});

        std.debug.print("✓ SQLite database schema initialized\n", .{});
    }

    pub fn addPackage(self: *Database, name: []const u8, source_type: []const u8, source_url: []const u8) !void {
        var stmt = try self.db.prepare(
            \\INSERT OR REPLACE INTO packages (name, source_type, source_url, updated_at) 
            \\VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        );
        defer stmt.deinit();

        try stmt.exec(.{}, .{ .name = name, .source_type = source_type, .source_url = source_url });
        std.debug.print("✓ Added package to database: {s}\n", .{name});
    }

    pub fn getPackages(self: *Database, allocator: std.mem.Allocator) ![]Package {
        var stmt = try self.db.prepare(
            \\SELECT name, version, description, source_type, source_url, build_status 
            \\FROM packages ORDER BY name
        );
        defer stmt.deinit();

        return try stmt.all(Package, allocator, .{}, .{});
    }

    pub fn updatePackageBuildStatus(self: *Database, name: []const u8, status: []const u8) !void {
        var stmt = try self.db.prepare(
            \\UPDATE packages SET build_status = ?, updated_at = CURRENT_TIMESTAMP 
            \\WHERE name = ?
        );
        defer stmt.deinit();

        try stmt.exec(.{}, .{ .build_status = status, .name = name });
        std.debug.print("✓ Updated build status for {s}: {s}\n", .{ name, status });
    }

    pub fn updatePackageVersion(self: *Database, name: []const u8, version: []const u8) !void {
        var stmt = try self.db.prepare(
            \\UPDATE packages SET version = ?, updated_at = CURRENT_TIMESTAMP 
            \\WHERE name = ?
        );
        defer stmt.deinit();

        try stmt.exec(.{}, .{ .version = version, .name = name });
        std.debug.print("✓ Updated version for {s}: {s}\n", .{ name, version });
    }

    pub fn addBuildLog(self: *Database, package_name: []const u8, log_content: []const u8, success: bool) !void {
        // First get the package ID
        var stmt = try self.db.prepare("SELECT id FROM packages WHERE name = ?");
        defer stmt.deinit();

        const maybe_package_id = try stmt.one(struct { id: i64 }, .{}, .{ .name = package_name });
        if (maybe_package_id) |row| {
            var log_stmt = try self.db.prepare(
                \\INSERT INTO build_logs (package_id, log_content, success) 
                \\VALUES (?, ?, ?)
            );
            defer log_stmt.deinit();

            try log_stmt.exec(.{}, .{ .package_id = row.id, .log_content = log_content, .success = success });
            std.debug.print("✓ Added build log for {s}\n", .{package_name});
        } else {
            std.debug.print("✗ Package not found for build log: {s}\n", .{package_name});
        }
    }
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8,
    source_type: []const u8,
    source_url: []const u8,
    build_status: []const u8,

    pub fn deinit(self: Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.source_type);
        allocator.free(self.source_url);
        allocator.free(self.build_status);
    }
};
