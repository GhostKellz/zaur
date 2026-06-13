//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Database = @import("database.zig").Database;
pub const AurClient = @import("aur.zig").AurClient;
pub const PackageBuilder = @import("builder.zig").PackageBuilder;
pub const RepoManager = @import("repo.zig").RepoManager;
pub const HttpServer = @import("server.zig").HttpServer;
pub const Config = @import("config.zig").Config;
pub const GpgSigner = @import("gpg.zig").GpgSigner;
pub const DependencyResolver = @import("deps.zig").DependencyResolver;
pub const ArchMirror = @import("mirror.zig").ArchMirror;
pub const MirrorCommands = @import("mirror.zig").MirrorCommands;
pub const ZigBuilder = @import("zigbuilder.zig").ZigBuilder;
pub const RustBuilder = @import("rustbuilder.zig").RustBuilder;
pub const Source = @import("database.zig").Source;
pub const SourceKind = @import("database.zig").SourceKind;
pub const TrustedKey = @import("database.zig").TrustedKey;
pub const ScanFinding = @import("database.zig").ScanFinding;
pub const SourcePin = @import("database.zig").SourcePin;
pub const Scanner = @import("scanner.zig");
pub const Integrity = @import("integrity.zig");
pub const Sandbox = @import("sandbox.zig");
pub const BuildIsolation = @import("config.zig").BuildIsolation;
pub const ScanPolicy = @import("config.zig").ScanPolicy;
pub const SourceSpec = @import("source.zig").SourceSpec;
pub const SourceManager = @import("source.zig");
pub const SecurityManager = @import("security.zig").SecurityManager;
pub const vercmp = @import("version.zig").vercmp;
pub const Advisory = @import("database.zig").Advisory;
pub const PackageSecurityStatus = @import("database.zig").PackageSecurityStatus;
pub const Severity = @import("database.zig").Severity;
pub const AdvisoryStatus = @import("database.zig").AdvisoryStatus;
pub const StaleStatus = @import("database.zig").StaleStatus;
pub const SignatureStatus = @import("database.zig").SignatureStatus;

pub fn advancedPrint() !void {
    std.debug.print("ZAUR: Zig Arch User Repository initialized!\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
