const std = @import("std");
const Config = @import("config.zig").Config;

pub const GpgSigner = struct {
    allocator: std.mem.Allocator,
    threaded_io: std.Io.Threaded,
    gpg_key_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, config: ?*const Config) GpgSigner {
        // Load GPG key from config if available
        const key_id: ?[]const u8 = if (config) |cfg| cfg.gpg_key_id else null;

        return GpgSigner{
            .allocator = allocator,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
            .gpg_key_id = key_id,
        };
    }

    pub fn deinit(self: *GpgSigner) void {
        self.threaded_io.deinit();
    }

    pub fn signPackage(self: *GpgSigner, package_path: []const u8) !void {
        const key_id = self.gpg_key_id orelse {
            std.debug.print("No GPG key configured. Set ZAUR_GPG_KEY environment variable to enable signing.\n", .{});
            return;
        };

        const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{package_path});
        defer self.allocator.free(sig_path);

        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{
                "gpg",
                "--detach-sign",
                "--use-agent",
                "--no-armor",
                "--local-user",
                key_id,
                package_path,
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0) {
            std.debug.print("Signed package: {s}\n", .{package_path});
        } else {
            std.debug.print("Failed to sign package: {s}\nStderr: {s}\n", .{ package_path, result.stderr });
            return error.GpgSigningFailed;
        }
    }

    pub fn initializeGpgKey(self: *GpgSigner, key_name: []const u8, key_email: []const u8) !void {
        std.debug.print("Generating GPG key for ZAUR...\n", .{});

        const io = self.threaded_io.io();

        // Create batch content for GPG key generation
        const batch_content = try std.fmt.allocPrint(self.allocator,
            \\Key-Type: RSA
            \\Key-Length: 4096
            \\Subkey-Type: RSA
            \\Subkey-Length: 4096
            \\Name-Real: {s}
            \\Name-Email: {s}
            \\Expire-Date: 2y
            \\%commit
        , .{ key_name, key_email });
        defer self.allocator.free(batch_content);

        const temp_name = try createSecureBatchFile(self.allocator, io, batch_content);
        defer self.allocator.free(temp_name);
        defer std.Io.Dir.deleteFile(.cwd(), io, temp_name) catch {};

        // Generate key using batch file
        const result = try std.process.run(self.allocator, io, .{
            .argv = &.{ "gpg", "--batch", "--gen-key", temp_name },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0) {
            std.debug.print("GPG key generated successfully.\n", .{});
            std.debug.print("Export your public key: gpg --armor --export {s}\n", .{key_email});
            std.debug.print("Set ZAUR_GPG_KEY environment variable to enable signing.\n", .{});
        } else {
            std.debug.print("GPG key generation failed:\n{s}\n", .{result.stderr});
            return error.GpgKeyGenerationFailed;
        }
    }

    pub fn verifyPackageSignature(self: *GpgSigner, package_path: []const u8) !bool {
        const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{package_path});
        defer self.allocator.free(sig_path);

        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{
                "gpg",
                "--verify",
                sig_path,
                package_path,
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return result.term == .exited and result.term.exited == 0;
    }

    pub fn listKeys(self: *GpgSigner) ![]const u8 {
        const result = try std.process.run(self.allocator, self.threaded_io.io(), .{
            .argv = &.{ "gpg", "--list-keys", "--keyid-format", "long" },
        });
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0) {
            return result.stdout;
        } else {
            self.allocator.free(result.stdout);
            return error.GpgListKeysFailed;
        }
    }
};

fn createSecureBatchFile(allocator: std.mem.Allocator, io: std.Io, content: []const u8) ![]const u8 {
    var random_bytes: [16]u8 = undefined;
    var seed_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer seed_io.deinit();
    const seed_ts = std.Io.Timestamp.now(seed_io.io(), .real);
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(u64, @intCast(seed_ts.nanoseconds))));
    const random = prng.random();

    while (true) {
        random.bytes(&random_bytes);
        const hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try std.fmt.allocPrint(allocator, "/tmp/zaur_gpg_{s}.batch", .{hex});
        errdefer allocator.free(path);

        var file = std.Io.Dir.createFileAbsolute(io, path, .{
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        defer file.close(io);

        try file.writeStreamingAll(io, content);
        return path;
    }
}
