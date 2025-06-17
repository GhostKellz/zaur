const std = @import("std");

pub const GpgSigner = struct {
    allocator: std.mem.Allocator,
    gpg_key_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) GpgSigner {
        return GpgSigner{
            .allocator = allocator,
            .gpg_key_id = std.posix.getenv("ZAUR_GPG_KEY"), // Get from environment
        };
    }

    pub fn signPackage(self: *GpgSigner, package_path: []const u8) !void {
        const key_id = self.gpg_key_id orelse {
            std.debug.print("⚠️  No GPG key configured. Set ZAUR_GPG_KEY environment variable.\n", .{});
            return;
        };

        const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{package_path});
        defer self.allocator.free(sig_path);

        // Execute gpg command to sign package
        var child = std.process.Child.init(&.{
            "gpg",
            "--detach-sign",
            "--use-agent",
            "--no-armor",
            "--local-user",
            key_id,
            package_path,
        }, self.allocator);

        const result = try child.spawnAndWait();
        if (result == .Exited and result.Exited == 0) {
            std.debug.print("🔐 Signed package: {s}\n", .{package_path});
        } else {
            std.debug.print("❌ Failed to sign package: {s}\n", .{package_path});
            return error.GpgSigningFailed;
        }
    }

    pub fn initializeGpgKey(self: *GpgSigner, key_name: []const u8, key_email: []const u8) !void {
        std.debug.print("🔑 Generating GPG key for GhostCTL AUR...\n", .{});

        // Create batch file for GPG key generation
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

        // Write batch file
        const batch_file = try std.fs.cwd().createFile("gpg_batch.txt", .{});
        defer batch_file.close();
        try batch_file.writeAll(batch_content);

        // Generate key
        var child = std.process.Child.init(&.{ "gpg", "--batch", "--gen-key", "gpg_batch.txt" }, self.allocator);

        const result = try child.spawnAndWait();
        if (result == .Exited and result.Exited == 0) {
            std.debug.print("✅ GPG key generated successfully!\n", .{});
            std.debug.print("💡 Export your public key: gpg --armor --export {s}\n", .{key_email});
        } else {
            return error.GpgKeyGenerationFailed;
        }

        // Clean up batch file
        std.fs.cwd().deleteFile("gpg_batch.txt") catch {};
    }
};
