const std = @import("std");

pub const Config = struct {
    repo_dir: []const u8,
    build_dir: []const u8,
    db_name: []const u8,
    db_path: []const u8,
    bind_address: []const u8,
    port: u16,
    
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Config {
        const home_dir = std.posix.getenv("HOME") orelse "/tmp";
        
        return Config{
            .repo_dir = try std.fmt.allocPrint(allocator, "{s}/GhostCTL/packages", .{home_dir}),
            .build_dir = try std.fmt.allocPrint(allocator, "{s}/GhostCTL/build", .{home_dir}),
            .db_name = try allocator.dupe(u8, "zaur"),
            .db_path = try std.fmt.allocPrint(allocator, "{s}/GhostCTL/zaur.db", .{home_dir}),
            .bind_address = try allocator.dupe(u8, "127.0.0.1"),
            .port = 8080,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Config) void {
        self.allocator.free(self.repo_dir);
        self.allocator.free(self.build_dir);
        self.allocator.free(self.db_name);
        self.allocator.free(self.db_path);
        self.allocator.free(self.bind_address);
    }

    pub fn ensureDirectories(self: Config) !void {
        // Create necessary directories with parent directories
        const dirs = [_][]const u8{ self.repo_dir, self.build_dir };
        
        for (dirs) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                error.FileNotFound => {
                    // Create parent directories first
                    if (std.fs.path.dirname(dir)) |parent| {
                        try std.fs.makeDirAbsolute(parent);
                        try std.fs.makeDirAbsolute(dir);
                    } else {
                        return err;
                    }
                },
                else => return err,
            };
        }
    }
};