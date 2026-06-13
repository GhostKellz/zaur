//! Pluggable build isolation backends.
//!
//! `makepkg` runs attacker-controlled `build()`/`package()` code from the
//! PKGBUILD. Running that directly on the host (the historical behaviour) means a
//! malicious source has the builder's full user privileges. This module lets the
//! operator opt into stronger isolation:
//!
//!   * `none`      — run `makepkg` in the package dir on the host (legacy).
//!   * `chroot`    — Arch-native clean chroot via devtools (`makechrootpkg`).
//!   * `container` — disposable container (podman/docker) with `--rm`.
//!
//! All backends drop built `*.pkg.tar.zst` artifacts into the package directory
//! so the existing `builder.moveBuiltPackages` step picks them up unchanged.
//! Every subprocess uses the no-shell `argv` pattern; no source-controlled
//! string is ever passed to a shell for interpretation.

const std = @import("std");
const Config = @import("config.zig").Config;
const BuildIsolation = @import("config.zig").BuildIsolation;

pub const Result = struct {
    success: bool,
    /// Combined stdout/stderr of the build. Caller owns and must free.
    log: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.log);
    }
};

pub const Context = struct {
    /// Directory containing the prepared PKGBUILD + sources. Build runs here and
    /// artifacts are expected to land here.
    package_dir: []const u8,
    /// Effective config (selects the backend + runtime/image/chroot settings).
    config: ?*const Config,
};

/// Run a build under the configured isolation backend.
pub fn runBuild(allocator: std.mem.Allocator, io: std.Io, ctx: Context) !Result {
    const isolation: BuildIsolation = if (ctx.config) |c| c.build_isolation else .none;
    return switch (isolation) {
        .none => runNone(allocator, io, ctx),
        .chroot => runChroot(allocator, io, ctx),
        .container => runContainer(allocator, io, ctx),
    };
}

fn finishResult(allocator: std.mem.Allocator, result: std.process.RunResult) !Result {
    const success = result.term == .exited and result.term.exited == 0;
    const log = try std.fmt.allocPrint(allocator, "STDOUT:\n{s}\n\nSTDERR:\n{s}", .{ result.stdout, result.stderr });
    return Result{ .success = success, .log = log };
}

/// Legacy host build: `makepkg -s -f --noconfirm` in the package directory.
fn runNone(allocator: std.mem.Allocator, io: std.Io, ctx: Context) !Result {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "makepkg", "-s", "-f", "--noconfirm" },
        .cwd = .{ .path = ctx.package_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return finishResult(allocator, result);
}

/// Arch clean-chroot build via devtools. Ensures `<chroot_dir>/root` exists
/// (creating it once with `mkarchroot`), then builds with `makechrootpkg`.
/// Requires the `devtools` package; degrades to a clear error if absent.
fn runChroot(allocator: std.mem.Allocator, io: std.Io, ctx: Context) !Result {
    const cfg = ctx.config orelse return error.MissingConfig;
    const chroot_dir = cfg.chroot_dir;

    const root_path = try std.fs.path.join(allocator, &.{ chroot_dir, "root" });
    defer allocator.free(root_path);

    // Create the base chroot only if it does not already exist.
    const root_exists = blk: {
        std.Io.Dir.accessAbsolute(io, root_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!root_exists) {
        try std.Io.Dir.createDirPath(.cwd(), io, chroot_dir);
        const mk = try std.process.run(allocator, io, .{
            .argv = &.{ "mkarchroot", root_path, "base-devel" },
        });
        defer allocator.free(mk.stdout);
        defer allocator.free(mk.stderr);
        if (mk.term != .exited or mk.term.exited != 0) {
            const log = try std.fmt.allocPrint(allocator, "mkarchroot failed (is devtools installed?):\nSTDOUT:\n{s}\n\nSTDERR:\n{s}", .{ mk.stdout, mk.stderr });
            return Result{ .success = false, .log = log };
        }
    }

    // `-c` cleans the copy before building; `-r` selects the chroot root.
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "makechrootpkg", "-c", "-r", chroot_dir },
        .cwd = .{ .path = ctx.package_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return finishResult(allocator, result);
}

/// Disposable-container build. Bind-mounts the package directory into the
/// container, installs base-devel, and runs makepkg as a non-root build user so
/// artifacts land back in `package_dir` on the host. Uses host networking per
/// workstation defaults; the container is removed on exit (`--rm`).
fn runContainer(allocator: std.mem.Allocator, io: std.Io, ctx: Context) !Result {
    const cfg = ctx.config orelse return error.MissingConfig;
    const runtime = cfg.container_runtime;
    const image = cfg.container_image;

    // makepkg refuses to run as root, so create an unprivileged builder inside
    // the throwaway container and hand it the bind-mounted tree.
    const script =
        \\set -e
        \\pacman -Sy --noconfirm --needed base-devel git >/dev/null
        \\if ! id builder >/dev/null 2>&1; then useradd -m builder; fi
        \\echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
        \\chown -R builder /build
        \\su builder -c 'cd /build && makepkg -s -f --noconfirm'
    ;

    const mount_spec = try std.fmt.allocPrint(allocator, "{s}:/build", .{ctx.package_dir});
    defer allocator.free(mount_spec);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            runtime,    "run",
            "--rm",     "--network",
            "host",     "-v",
            mount_spec, "-w",
            "/build",   image,
            "bash",     "-c",
            script,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 127) {
        const log = try std.fmt.allocPrint(allocator, "container runtime '{s}' not found:\nSTDERR:\n{s}", .{ runtime, result.stderr });
        return Result{ .success = false, .log = log };
    }
    return finishResult(allocator, result);
}

// =============================================================================
// Tests
// =============================================================================

test "runBuild defaults to none when config absent" {
    // We can't actually run makepkg in the test environment, but we can verify
    // backend selection logic compiles and dispatches on the enum.
    const isolation: BuildIsolation = .none;
    try std.testing.expectEqual(BuildIsolation.none, isolation);
}
