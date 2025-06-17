//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Database = @import("database.zig").Database;
pub const AurClient = @import("aur.zig").AurClient;
pub const PackageBuilder = @import("builder.zig").PackageBuilder;
pub const RepoManager = @import("repo.zig").RepoManager;
pub const HttpServer = @import("server.zig").HttpServer;
pub const Config = @import("config.zig").Config;

pub fn advancedPrint() !void {
    std.debug.print("ZAUR: Zig Arch User Repository initialized!\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
