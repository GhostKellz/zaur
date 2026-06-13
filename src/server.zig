const std = @import("std");
const Database = @import("database.zig").Database;
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const MirrorPolicy = config_mod.MirrorPolicy;
const SourceManager = @import("source.zig");
const RepoManager = @import("repo.zig").RepoManager;
const ArchMirror = @import("mirror.zig").ArchMirror;
const PackageBuilder = @import("builder.zig").PackageBuilder;
const SecurityManager = @import("security.zig").SecurityManager;
const Scanner = @import("scanner.zig");
const Integrity = @import("integrity.zig");
const GpgSigner = @import("gpg.zig").GpgSigner;

const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: *const fn (*HttpServer, *std.http.Server.Request, std.Io) anyerror!void,
    auth_required: bool,
};

const routes = [_]Route{
    .{ .method = .GET, .path = "/", .handler = handleIndex, .auth_required = false },
    .{ .method = .GET, .path = "/api/health", .handler = apiHealth, .auth_required = false },
    .{ .method = .GET, .path = "/api/status", .handler = apiGetStatus, .auth_required = false },
    .{ .method = .GET, .path = "/api/packages", .handler = apiGetPackages, .auth_required = false },
    .{ .method = .GET, .path = "/api/sources", .handler = apiGetSources, .auth_required = false },
    .{ .method = .POST, .path = "/api/sources", .handler = apiAddSource, .auth_required = true },
    .{ .method = .DELETE, .path = "/api/sources", .handler = apiDeleteSource, .auth_required = true },
    .{ .method = .GET, .path = "/api/builds", .handler = apiGetBuilds, .auth_required = false },
    .{ .method = .POST, .path = "/api/builds", .handler = apiTriggerBuild, .auth_required = true },
    .{ .method = .GET, .path = "/api/repos", .handler = apiGetRepos, .auth_required = false },
    .{ .method = .POST, .path = "/api/repos/publish", .handler = apiPublishRepo, .auth_required = true },
    .{ .method = .GET, .path = "/api/mirror", .handler = apiGetMirrorStatus, .auth_required = false },
    .{ .method = .POST, .path = "/api/mirror/sync", .handler = apiTriggerMirrorSync, .auth_required = true },
    // Security endpoints
    .{ .method = .GET, .path = "/api/security/packages", .handler = apiSecurityPackages, .auth_required = false },
    .{ .method = .GET, .path = "/api/security/advisories", .handler = apiSecurityAdvisories, .auth_required = false },
    .{ .method = .POST, .path = "/api/security/sync", .handler = apiSecuritySync, .auth_required = true },
    .{ .method = .POST, .path = "/api/security/scan", .handler = apiSecurityScan, .auth_required = true },
    .{ .method = .GET, .path = "/api/security/findings", .handler = apiSecurityFindings, .auth_required = false },
    .{ .method = .POST, .path = "/api/security/scan-pkgbuild", .handler = apiSecurityScanPkgbuild, .auth_required = true },
    .{ .method = .GET, .path = "/api/security/keys", .handler = apiSecurityListKeys, .auth_required = true },
    .{ .method = .POST, .path = "/api/security/keys", .handler = apiSecurityAddKey, .auth_required = true },
    .{ .method = .DELETE, .path = "/api/security/keys", .handler = apiSecurityRemoveKey, .auth_required = true },
    .{ .method = .POST, .path = "/api/security/pin", .handler = apiSecurityPin, .auth_required = true },
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    bind_address: []const u8,
    database: ?*Database,
    config: ?*const Config,
    api_token: ?[]const u8,
    threaded_io: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, port: u16, bind_address: []const u8) HttpServer {
        return .{
            .allocator = allocator,
            .port = port,
            .bind_address = bind_address,
            .database = null,
            .config = null,
            .api_token = null,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
        };
    }

    pub fn initWithDatabase(allocator: std.mem.Allocator, port: u16, bind_address: []const u8, database: *Database) HttpServer {
        return .{
            .allocator = allocator,
            .port = port,
            .bind_address = bind_address,
            .database = database,
            .config = null,
            .api_token = null,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: *const Config, database: *Database) HttpServer {
        return .{
            .allocator = allocator,
            .port = config.port,
            .bind_address = config.bind_address,
            .database = database,
            .config = config,
            .api_token = config.api_token,
            .threaded_io = .init(std.heap.smp_allocator, .{}),
        };
    }

    pub fn start(self: *HttpServer) !void {
        const io = self.threaded_io.io();
        const address = try std.Io.net.IpAddress.parse(self.bind_address, self.port);
        var listener = try address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);

        std.debug.print("ZAUR HTTP server started on {s}:{d}\n", .{ self.bind_address, self.port });
        if (self.config) |cfg| {
            std.debug.print("Serving /aur/ from: {s}\n", .{cfg.aur_repo_dir});
            std.debug.print("Serving /custom/ from: {s}\n", .{cfg.custom_repo_dir});
            std.debug.print("Serving /mirror/ from: {s}\n", .{cfg.mirror_root});
        }
        if (self.api_token != null) {
            std.debug.print("API authentication enabled\n", .{});
        }
        if (self.config) |cfg| {
            if (cfg.cors_origin) |origin| {
                std.debug.print("CORS enabled for origin: {s}\n", .{origin});
            }
        }

        while (true) {
            const stream = listener.accept(io) catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            // Spawn thread to handle connection concurrently
            const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ self, stream }) catch |err| {
                std.debug.print("Thread spawn error: {}\n", .{err});
                var s = stream;
                s.close(io);
                continue;
            };
            thread.detach();
        }
    }

    // Thread entry point for concurrent connection handling
    fn handleConnectionThread(self: *HttpServer, stream: std.Io.net.Stream) void {
        // Each thread needs its own I/O context - threaded_io is NOT thread-safe to share
        var thread_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer thread_io.deinit();
        const io = thread_io.io();

        var conn_stream = stream;
        defer conn_stream.close(io);

        self.handleConnection(&conn_stream, io) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }

    // Max requests per keep-alive connection to prevent monopolization
    const MAX_REQUESTS_PER_CONNECTION: usize = 100;

    fn handleConnection(self: *HttpServer, stream: *std.Io.net.Stream, io: std.Io) !void {
        _ = self.threaded_io; // Unused, kept for compatibility
        var recv_buffer: [8192]u8 = undefined;
        var send_buffer: [8192]u8 = undefined;
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

        var request_count: usize = 0;
        while (request_count < MAX_REQUESTS_PER_CONNECTION) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => return err,
            };

            self.handleRequest(&request, io) catch |err| {
                std.debug.print("Request error: {}\n", .{err});
                self.jsonErrorWithCors(&request, .internal_server_error, "internal error") catch {};
            };

            request_count += 1;
            if (!request.head.keep_alive) return;
        }
    }

    fn handleRequest(self: *HttpServer, request: *std.http.Server.Request, io: std.Io) !void {
        const target = request.head.target;
        const method = request.head.method;

        // Handle CORS preflight OPTIONS requests
        if (method == .OPTIONS) {
            return self.handleCorsOptions(request);
        }

        // Check routes table first
        inline for (routes) |route| {
            if (method == route.method and std.mem.eql(u8, target, route.path)) {
                if (route.auth_required and !self.checkAuth(request)) {
                    return self.respondWithCors(request, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}");
                }
                return route.handler(self, request, io);
            }
        }

        // Only serve GET requests for static files
        if (method != .GET) {
            return self.respondWithCors(request, .not_found, "application/json", "{\"error\":\"not found\"}");
        }

        // Check explicit repo prefixes
        const config = self.config orelse return self.jsonErrorWithCors(request, .not_found, "not found");

        if (std.mem.startsWith(u8, target, "/aur/")) {
            return self.serveRepoFile(request, config.aur_repo_dir, target[5..], io);
        }
        if (std.mem.startsWith(u8, target, "/custom/")) {
            return self.serveRepoFile(request, config.custom_repo_dir, target[8..], io);
        }
        if (std.mem.startsWith(u8, target, "/mirror/")) {
            return self.serveMirrorFile(request, target[8..], io);
        }

        // Everything else is 404
        return self.jsonErrorWithCors(request, .not_found, "not found");
    }

    fn checkAuth(self: *HttpServer, request: *std.http.Server.Request) bool {
        const token = self.api_token orelse return true;

        var lines = std.mem.splitSequence(u8, request.head_buffer, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
                var value = line["authorization:".len..];
                while (value.len > 0 and value[0] == ' ') value = value[1..];
                if (std.mem.startsWith(u8, value, "Bearer ")) {
                    return std.mem.eql(u8, value[7..], token);
                }
            }
        }
        return false;
    }

    fn getCorsOrigin(self: *HttpServer) ?[]const u8 {
        if (self.config) |cfg| {
            return cfg.cors_origin;
        }
        return null;
    }

    fn handleCorsOptions(self: *HttpServer, request: *std.http.Server.Request) !void {
        const cors_origin = self.getCorsOrigin() orelse {
            // No CORS configured, reject OPTIONS
            return self.jsonErrorWithCors(request, .method_not_allowed, "method not allowed");
        };

        try request.respond("", .{
            .status = .no_content,
            .keep_alive = true,
            .extra_headers = &.{
                .{ .name = "Access-Control-Allow-Origin", .value = cors_origin },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, DELETE, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
                .{ .name = "Access-Control-Max-Age", .value = "86400" },
            },
        });
    }

    fn respondWithCors(self: *HttpServer, request: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8) !void {
        const cors_origin = self.getCorsOrigin();
        if (cors_origin) |origin| {
            try request.respond(body, .{
                .status = status,
                .keep_alive = true,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = content_type },
                    .{ .name = "Access-Control-Allow-Origin", .value = origin },
                },
            });
        } else {
            try request.respond(body, .{
                .status = status,
                .keep_alive = true,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = content_type },
                },
            });
        }
    }

    fn jsonErrorWithCors(self: *HttpServer, request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
        const escaped = jsonEscape(self.allocator, message) catch {
            return self.respondWithCors(request, status, "application/json", "{\"error\":\"internal error\"}");
        };
        defer self.allocator.free(escaped);

        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{escaped}) catch {
            return self.respondWithCors(request, status, "application/json", "{\"error\":\"internal error\"}");
        };
        return self.respondWithCors(request, status, "application/json", json);
    }

    fn readRequestBody(self: *HttpServer, request: *std.http.Server.Request) ![]const u8 {
        const content_length = request.head.content_length orelse return "";

        if (content_length > 1024 * 1024) return error.PayloadTooLarge;
        if (content_length == 0) return "";

        const body_buffer = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body_buffer);

        // Internal buffer for the reader, separate from destination
        var read_buf: [8192]u8 = undefined;
        const body_reader = request.readerExpectNone(&read_buf);

        try body_reader.readSliceAll(body_buffer);

        return body_buffer;
    }

    fn serveRepoFile(self: *HttpServer, request: *std.http.Server.Request, repo_root: []const u8, file_name: []const u8, io: std.Io) !void {
        // Path traversal protection
        if (!isValidRepoPath(file_name)) {
            return self.jsonErrorWithCors(request, .bad_request, "invalid path");
        }
        const file_path = try std.fs.path.join(self.allocator, &.{ repo_root, file_name });
        defer self.allocator.free(file_path);

        // Open file and get size for Content-Length
        var file = std.Io.Dir.openFile(.cwd(), io, file_path, .{}) catch {
            return self.jsonErrorWithCors(request, .not_found, "not found");
        };
        defer file.close(io);

        const stat = file.stat(io) catch {
            return self.jsonErrorWithCors(request, .not_found, "not found");
        };
        const file_size = stat.size;

        // Stream file in chunks using respondStreaming
        var stream_buf: [65536]u8 = undefined; // 64KB buffer
        var body_writer = try request.respondStreaming(&stream_buf, .{
            .content_length = file_size,
            .respond_options = .{
                .status = .ok,
                .keep_alive = true,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = contentType(file_name) },
                },
            },
        });

        var read_buf: [65536]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        var remaining = file_size;
        var stream_error = false;
        while (remaining > 0) {
            var chunk_buf: [32768]u8 = undefined;
            const to_read = @min(remaining, chunk_buf.len);
            const bytes_read = file_reader.interface.readSliceShort(chunk_buf[0..to_read]) catch {
                stream_error = true;
                break;
            };
            if (bytes_read == 0) break;
            body_writer.writer.writeAll(chunk_buf[0..bytes_read]) catch {
                stream_error = true;
                break;
            };
            remaining -= bytes_read;
        }
        // If we had an error, don't call end() - let connection close abruptly
        // so client knows response was incomplete
        if (stream_error) {
            return error.StreamingFailed;
        }
        try body_writer.end();
    }

    /// Serve files from mirror with on-demand downloading support
    /// Path format: {repo}/os/x86_64/{filename}
    fn serveMirrorFile(self: *HttpServer, request: *std.http.Server.Request, path: []const u8, io: std.Io) !void {
        const config = self.config orelse return self.jsonErrorWithCors(request, .not_found, "not found");
        const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");

        // Path traversal protection
        if (!isValidRepoPath(path)) {
            return self.jsonErrorWithCors(request, .bad_request, "invalid path");
        }

        // First, try to serve from local cache
        const file_path = try std.fs.path.join(self.allocator, &.{ config.mirror_root, path });
        defer self.allocator.free(file_path);

        var file = std.Io.Dir.openFile(.cwd(), io, file_path, .{}) catch |err| blk: {
            // File not found - try on-demand download if policy allows
            if (err == error.FileNotFound and config.mirror_policy == MirrorPolicy.ondemand) {
                // Parse path: {repo}/os/x86_64/{filename}
                const repo_end = std.mem.indexOf(u8, path, "/") orelse {
                    return self.jsonErrorWithCors(request, .not_found, "not found");
                };
                const repo = path[0..repo_end];

                // Verify path follows standard Arch mirror layout
                const rest = path[repo_end + 1 ..];
                if (!std.mem.startsWith(u8, rest, "os/x86_64/")) {
                    return self.jsonErrorWithCors(request, .not_found, "not found");
                }
                const filename = rest["os/x86_64/".len..];

                // Only download package files, not databases (databases should be synced manually)
                if (!std.mem.endsWith(u8, filename, ".pkg.tar.zst") and
                    !std.mem.endsWith(u8, filename, ".pkg.tar.xz") and
                    !std.mem.endsWith(u8, filename, ".sig"))
                {
                    return self.jsonErrorWithCors(request, .not_found, "not found");
                }

                // Try to download from upstream
                var mirror = ArchMirror.init(self.allocator, config, db) catch {
                    return self.jsonErrorWithCors(request, .internal_server_error, "mirror init failed");
                };
                defer mirror.deinit();

                std.debug.print("On-demand download: {s}/{s}\n", .{ repo, filename });
                const local_path = mirror.downloadPackageByFilename(repo, filename) catch |download_err| {
                    std.debug.print("On-demand download failed: {}\n", .{download_err});
                    return self.jsonErrorWithCors(request, .not_found, "not found");
                };
                defer self.allocator.free(local_path);

                // Now try to open the downloaded file
                break :blk std.Io.Dir.openFile(.cwd(), io, local_path, .{}) catch {
                    return self.jsonErrorWithCors(request, .not_found, "not found");
                };
            }
            return self.jsonErrorWithCors(request, .not_found, "not found");
        };
        defer file.close(io);

        const stat = file.stat(io) catch {
            return self.jsonErrorWithCors(request, .not_found, "not found");
        };
        const file_size = stat.size;

        // Stream file in chunks
        var stream_buf: [65536]u8 = undefined;
        var body_writer = try request.respondStreaming(&stream_buf, .{
            .content_length = file_size,
            .respond_options = .{
                .status = .ok,
                .keep_alive = true,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = contentType(path) },
                },
            },
        });

        var read_buf: [65536]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        var remaining = file_size;
        var stream_error = false;
        while (remaining > 0) {
            var chunk_buf: [32768]u8 = undefined;
            const to_read = @min(remaining, chunk_buf.len);
            const bytes_read = file_reader.interface.readSliceShort(chunk_buf[0..to_read]) catch {
                stream_error = true;
                break;
            };
            if (bytes_read == 0) break;
            body_writer.writer.writeAll(chunk_buf[0..bytes_read]) catch {
                stream_error = true;
                break;
            };
            remaining -= bytes_read;
        }
        if (stream_error) {
            return error.StreamingFailed;
        }
        try body_writer.end();
    }
};

// Path validation to prevent traversal attacks
fn isValidRepoPath(path: []const u8) bool {
    // Reject empty paths
    if (path.len == 0) return false;

    // Reject absolute paths
    if (path[0] == '/') return false;

    // Reject paths containing null bytes
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;

    // Reject paths containing '..'
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.mem.indexOfScalar(u8, segment, '\\') != null) return false;
    }

    return true;
}

fn requireJsonContentType(request: *std.http.Server.Request) bool {
    var lines = std.mem.splitSequence(u8, request.head_buffer, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            var value = line["content-type:".len..];
            while (value.len > 0 and value[0] == ' ') value = value[1..];
            if (std.mem.indexOfScalar(u8, value, ';')) |semi| value = value[0..semi];
            value = std.mem.trim(u8, value, " \t");
            return std.ascii.eqlIgnoreCase(value, "application/json");
        }
    }
    return false;
}

// API Handlers

fn handleIndex(_: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    return respondText(request, .ok, "text/html", indexHtml());
}

fn apiHealth(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    return self.respondWithCors(request, .ok, "application/json", "{\"status\":\"ok\",\"version\":\"0.1.2\"}");
}

fn apiGetStatus(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    if (self.database) |db| {
        const count = try db.getPackageCount();
        const healthy = try db.healthCheck();
        var buf: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"status\":\"ok\",\"packages\":{d},\"database_ok\":{}}}", .{ count, healthy });
        return self.respondWithCors(request, .ok, "application/json", json);
    }
    return self.respondWithCors(request, .ok, "application/json", "{\"status\":\"ok\"}");
}

fn apiGetPackages(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    if (self.database) |db| {
        const packages = try db.getPackages(self.allocator);
        defer {
            for (packages) |pkg| pkg.deinit(self.allocator);
            self.allocator.free(packages);
        }

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"packages\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");

            const name_escaped = try jsonEscape(self.allocator, pkg.name);
            defer self.allocator.free(name_escaped);
            const version_escaped = try jsonEscape(self.allocator, pkg.version);
            defer self.allocator.free(version_escaped);
            const source_escaped = try jsonEscape(self.allocator, pkg.source_type);
            defer self.allocator.free(source_escaped);
            const status_escaped = try jsonEscape(self.allocator, pkg.build_status);
            defer self.allocator.free(status_escaped);

            try json.print(self.allocator, "{{\"name\":\"{s}\",\"version\":\"{s}\",\"source\":\"{s}\",\"status\":\"{s}\"}}", .{
                name_escaped,
                version_escaped,
                source_escaped,
                status_escaped,
            });
        }
        try json.appendSlice(self.allocator, "]}");

        return self.respondWithCors(request, .ok, "application/json", json.items);
    }

    return self.respondWithCors(request, .ok, "application/json", "{\"packages\":[]}");
}

fn apiGetSources(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    if (self.database) |db| {
        const sources = try db.getSources(self.allocator);
        defer {
            for (sources) |s| s.deinit(self.allocator);
            self.allocator.free(sources);
        }

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);
        try json.appendSlice(self.allocator, "{\"sources\":[");
        for (sources, 0..) |src, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");

            const name_escaped = try jsonEscape(self.allocator, src.name);
            defer self.allocator.free(name_escaped);
            const location_escaped = try jsonEscape(self.allocator, src.location);
            defer self.allocator.free(location_escaped);
            const repo_escaped = try jsonEscape(self.allocator, src.repo_name);
            defer self.allocator.free(repo_escaped);

            try json.print(self.allocator, "{{\"name\":\"{s}\",\"kind\":\"{s}\",\"location\":\"{s}\",\"repo\":\"{s}\"}}", .{
                name_escaped,
                src.kind.asString(),
                location_escaped,
                repo_escaped,
            });
        }
        try json.appendSlice(self.allocator, "]}");
        return self.respondWithCors(request, .ok, "application/json", json.items);
    }
    return self.respondWithCors(request, .ok, "application/json", "{\"sources\":[]}");
}

fn apiGetBuilds(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    if (self.database) |db| {
        const logs = try db.getBuildLogs(self.allocator, null);
        defer {
            for (logs) |log| log.deinit(self.allocator);
            self.allocator.free(logs);
        }

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);
        try json.appendSlice(self.allocator, "{\"builds\":[");
        for (logs, 0..) |log, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");

            const pkg_escaped = try jsonEscape(self.allocator, log.package_name);
            defer self.allocator.free(pkg_escaped);
            const status_escaped = try jsonEscape(self.allocator, log.status);
            defer self.allocator.free(status_escaped);
            const time_escaped = try jsonEscape(self.allocator, log.finished_at);
            defer self.allocator.free(time_escaped);

            try json.print(self.allocator, "{{\"package\":\"{s}\",\"status\":\"{s}\",\"finished_at\":\"{s}\"}}", .{
                pkg_escaped,
                status_escaped,
                time_escaped,
            });
        }
        try json.appendSlice(self.allocator, "]}");
        return self.respondWithCors(request, .ok, "application/json", json.items);
    }
    return self.respondWithCors(request, .ok, "application/json", "{\"builds\":[]}");
}

fn apiGetRepos(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    return self.respondWithCors(request, .ok, "application/json", "{\"repos\":[\"aur\",\"custom\"]}");
}

fn apiGetMirrorStatus(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const config = self.config orelse {
        return self.respondWithCors(request, .ok, "application/json", "{\"mirror\":{\"enabled\":false}}");
    };
    const db = self.database orelse {
        return self.respondWithCors(request, .ok, "application/json", "{\"mirror\":{\"enabled\":false}}");
    };

    // Initialize mirror to get status
    var mirror = ArchMirror.init(self.allocator, config, db) catch {
        return self.respondWithCors(request, .ok, "application/json", "{\"mirror\":{\"enabled\":false}}");
    };
    defer mirror.deinit();

    var status = mirror.getStatus() catch {
        return self.respondWithCors(request, .ok, "application/json", "{\"mirror\":{\"enabled\":false}}");
    };
    defer status.deinit(self.allocator);

    // Build JSON response with enhanced status
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(self.allocator);

    // Escape user-configurable values before JSON formatting
    const upstream_escaped = try jsonEscape(self.allocator, status.upstream);
    defer self.allocator.free(upstream_escaped);

    // Add header with upstream and policy
    const header = try std.fmt.allocPrint(self.allocator, "{{\"mirror\":{{\"upstream\":\"{s}\",\"policy\":\"{s}\",\"repos\":{{", .{
        upstream_escaped,
        status.policy.toString(),
    });
    defer self.allocator.free(header);
    try json.appendSlice(self.allocator, header);

    var first = true;
    var iter = status.repos.iterator();
    while (iter.next()) |entry| {
        if (!first) try json.appendSlice(self.allocator, ",");
        first = false;

        // Escape repo name before JSON formatting
        const repo_escaped = try jsonEscape(self.allocator, entry.key_ptr.*);
        defer self.allocator.free(repo_escaped);

        const repo_json = try std.fmt.allocPrint(self.allocator, "\"{s}\":{{\"packages\":{d},\"synced\":{s},\"cached\":{d},\"cache_size_bytes\":{d}}}", .{
            repo_escaped,
            entry.value_ptr.packages,
            if (entry.value_ptr.synced) "true" else "false",
            entry.value_ptr.cached_packages,
            entry.value_ptr.cache_size_bytes,
        });
        defer self.allocator.free(repo_json);
        try json.appendSlice(self.allocator, repo_json);
    }

    try json.appendSlice(self.allocator, "}}}");

    return self.respondWithCors(request, .ok, "application/json", json.items);
}

// POST /api/sources - Add a source
fn apiAddSource(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");

    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }

    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);

    // Parse JSON body: {"spec": "aur/package"}
    const spec_str = blk: {
        if (body.len == 0) break :blk null;
        const parsed = std.json.parseFromSlice(struct { spec: []const u8 }, self.allocator, body, .{}) catch break :blk null;
        defer parsed.deinit();
        break :blk self.allocator.dupe(u8, parsed.value.spec) catch null;
    };

    if (spec_str == null) {
        return self.jsonErrorWithCors(request, .bad_request, "missing spec field");
    }
    defer self.allocator.free(spec_str.?);

    const spec = SourceManager.parse(spec_str.?) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid source spec");
    };

    const package_name = SourceManager.addSource(self.allocator, config.*, db, spec) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "failed to add source: {}", .{err}) catch "failed to add source";
        return self.jsonErrorWithCors(request, .internal_server_error, msg);
    };
    defer self.allocator.free(package_name);

    const pkg_escaped = try jsonEscape(self.allocator, package_name);
    defer self.allocator.free(pkg_escaped);

    var json: [512]u8 = undefined;
    const response = std.fmt.bufPrint(&json, "{{\"success\":true,\"package\":\"{s}\"}}", .{pkg_escaped}) catch "{\"success\":true}";
    return self.respondWithCors(request, .ok, "application/json", response);
}

// DELETE /api/sources - Remove a source
fn apiDeleteSource(self: *HttpServer, request: *std.http.Server.Request, io: std.Io) !void {
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");

    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }

    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);

    // Parse JSON body: {"name": "package"}
    const name = blk: {
        if (body.len == 0) break :blk null;
        const parsed = std.json.parseFromSlice(struct { name: []const u8 }, self.allocator, body, .{}) catch break :blk null;
        defer parsed.deinit();
        break :blk self.allocator.dupe(u8, parsed.value.name) catch null;
    };

    if (name == null) {
        return self.jsonErrorWithCors(request, .bad_request, "missing name field");
    }
    defer self.allocator.free(name.?);

    // Check if source exists first
    const source = db.getSource(self.allocator, name.?) catch {
        return self.jsonErrorWithCors(request, .internal_server_error, "database error");
    };
    if (source == null) {
        return self.jsonErrorWithCors(request, .not_found, "source not found");
    }
    source.?.deinit(self.allocator);

    // Remove package (includes build logs) - may not exist, which is ok
    db.removePackage(name.?) catch {};

    // Remove source record
    db.removeSource(name.?) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "failed to remove source: {}", .{err}) catch "failed to remove";
        return self.jsonErrorWithCors(request, .internal_server_error, msg);
    };

    // Clean up filesystem: source checkout directory
    if (config.sourceCheckoutDir(self.allocator, name.?)) |checkout_dir| {
        defer self.allocator.free(checkout_dir);
        std.Io.Dir.deleteTree(.cwd(), io, checkout_dir) catch {};
    } else |_| {}

    // Clean up filesystem: build directory
    if (config.packageBuildDir(self.allocator, name.?)) |build_dir| {
        defer self.allocator.free(build_dir);
        std.Io.Dir.deleteTree(.cwd(), io, build_dir) catch {};
    } else |_| {}

    return self.respondWithCors(request, .ok, "application/json", "{\"success\":true}");
}

// POST /api/builds - Trigger a build
fn apiTriggerBuild(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");

    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }

    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);

    // Parse JSON body: {"package": "name"} or {"all": true}
    // Require valid JSON - do not default to dangerous "build all" on parse failure
    if (body.len == 0) {
        return self.jsonErrorWithCors(request, .bad_request, "missing request body");
    }

    const BuildRequest = struct { package: ?[]const u8 = null, all: bool = false };
    const parsed = std.json.parseFromSlice(BuildRequest, self.allocator, body, .{}) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid JSON");
    };
    defer parsed.deinit();

    const build_req = BuildRequest{
        .package = if (parsed.value.package) |p| self.allocator.dupe(u8, p) catch null else null,
        .all = parsed.value.all,
    };
    defer if (build_req.package) |p| self.allocator.free(p);

    // Require explicit intent - either specify a package or set all=true
    if (build_req.package == null and !build_req.all) {
        return self.jsonErrorWithCors(request, .bad_request, "specify package name or set all=true");
    }

    var built_count: u32 = 0;

    if (build_req.package) |pkg_name| {
        // Build single package
        const pkg = db.getPackage(self.allocator, pkg_name) catch null;
        if (pkg == null) {
            return self.jsonErrorWithCors(request, .not_found, "package not found");
        }
        defer pkg.?.deinit(self.allocator);

        try buildPackage(self.allocator, db, config, pkg_name, pkg.?.repo_name);
        built_count = 1;
    } else {
        // Build all packages
        const packages = try db.getPackages(self.allocator);
        defer {
            for (packages) |pkg| pkg.deinit(self.allocator);
            self.allocator.free(packages);
        }

        var failed_count: usize = 0;
        for (packages) |pkg| {
            buildPackage(self.allocator, db, config, pkg.name, pkg.repo_name) catch {
                failed_count += 1;
                continue;
            };
            built_count += 1;
        }

        if (failed_count > 0) {
            var json: [256]u8 = undefined;
            const response = std.fmt.bufPrint(&json, "{{\"success\":false,\"built\":{d},\"failed\":{d}}}", .{ built_count, failed_count }) catch "{\"success\":false}";
            return self.respondWithCors(request, .ok, "application/json", response);
        }
    }

    var json: [128]u8 = undefined;
    const response = std.fmt.bufPrint(&json, "{{\"success\":true,\"built\":{d}}}", .{built_count}) catch "{\"success\":true}";
    return self.respondWithCors(request, .ok, "application/json", response);
}

fn buildPackage(allocator: std.mem.Allocator, db: *Database, config: *const Config, package_name: []const u8, repo_name: []const u8) !void {
    const source = try db.getSource(allocator, package_name) orelse return error.SourceNotFound;
    defer source.deinit(allocator);

    var builder = PackageBuilder.init(allocator, config.source_root, config.build_root, config.repoDirForName(repo_name), config, db);
    defer builder.deinit();
    const result = try builder.buildPackage(package_name);
    defer result.deinit(allocator);

    if (result.success) {
        try db.updatePackageBuildStatus(package_name, "success");
        try db.addBuildLog(package_name, "success", result.log);
    } else {
        try db.updatePackageBuildStatus(package_name, "failed");
        try db.addBuildLog(package_name, "failed", result.log);
    }
}

// POST /api/repos/publish - Publish repository databases
fn apiPublishRepo(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");

    var aur_repo = RepoManager.init(self.allocator, config.aur_repo_dir, "aur");
    defer aur_repo.deinit();
    aur_repo.generateRepoDatabase() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "aur repo failed: {}", .{err}) catch "aur repo failed";
        return self.jsonErrorWithCors(request, .internal_server_error, msg);
    };
    aur_repo.signDatabase(config);

    var custom_repo = RepoManager.init(self.allocator, config.custom_repo_dir, "custom");
    defer custom_repo.deinit();
    custom_repo.generateRepoDatabase() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "custom repo failed: {}", .{err}) catch "custom repo failed";
        return self.jsonErrorWithCors(request, .internal_server_error, msg);
    };
    custom_repo.signDatabase(config);

    return self.respondWithCors(request, .ok, "application/json", "{\"success\":true,\"repos\":[\"aur\",\"custom\"]}");
}

// POST /api/mirror/sync - Trigger mirror sync
fn apiTriggerMirrorSync(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");

    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }

    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);

    // Parse JSON body: {"repos": ["core", "extra"]} or {"smart": true} or {"full": true}
    // Require valid JSON - do not default to dangerous actions on parse failure
    if (body.len == 0) {
        return self.jsonErrorWithCors(request, .bad_request, "missing request body");
    }

    const SyncRequest = struct { repos: ?[]const []const u8 = null, smart: bool = false, full: bool = false };
    const parsed = std.json.parseFromSlice(SyncRequest, self.allocator, body, .{}) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid JSON");
    };
    defer parsed.deinit();

    const sync_req = SyncRequest{ .repos = parsed.value.repos, .smart = parsed.value.smart, .full = parsed.value.full };

    // Require explicit intent
    if (sync_req.repos == null and !sync_req.smart and !sync_req.full) {
        return self.jsonErrorWithCors(request, .bad_request, "specify repos list, smart=true, or full=true");
    }

    var mirror = ArchMirror.init(self.allocator, config, db) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "mirror init failed: {}", .{err}) catch "mirror init failed";
        return self.jsonErrorWithCors(request, .internal_server_error, msg);
    };
    defer mirror.deinit();

    if (sync_req.repos) |repos| {
        var sync_failed: usize = 0;
        for (repos) |repo| {
            mirror.syncRepository(repo) catch {
                sync_failed += 1;
                continue;
            };
        }
        if (sync_failed > 0) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "sync failed for {d} repos", .{sync_failed}) catch "sync failed";
            return self.jsonErrorWithCors(request, .internal_server_error, msg);
        }
    } else if (sync_req.smart) {
        mirror.smartSync() catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "smart sync failed: {}", .{err}) catch "smart sync failed";
            return self.jsonErrorWithCors(request, .internal_server_error, msg);
        };
    } else if (sync_req.full) {
        mirror.enableFullMirror() catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "full mirror failed: {}", .{err}) catch "full mirror failed";
            return self.jsonErrorWithCors(request, .internal_server_error, msg);
        };
    }

    return self.respondWithCors(request, .ok, "application/json", "{\"success\":true}");
}

// =============================================================================
// Security API Handlers
// =============================================================================

fn apiSecurityPackages(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");

    var security = SecurityManager.init(self.allocator, config, db);
    defer security.deinit();

    const statuses = try security.getAllPackageStatuses();
    defer {
        for (statuses) |s| s.deinit(self.allocator);
        self.allocator.free(statuses);
    }

    // Build JSON response
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(self.allocator);

    try json.appendSlice(self.allocator, "{\"packages\":[");

    var vulnerable: u32 = 0;
    var clean: u32 = 0;
    var unknown: u32 = 0;
    var stale: u32 = 0;
    var unsigned: u32 = 0;

    for (statuses, 0..) |s, i| {
        if (i > 0) try json.appendSlice(self.allocator, ",");

        // Count stats
        switch (s.advisory_status) {
            .vulnerable => vulnerable += 1,
            .clean => clean += 1,
            .unknown => unknown += 1,
            .unscanned => {},
        }
        if (s.stale_status == .stale) stale += 1;
        if (s.signature_status == .unsigned) unsigned += 1;

        // Build package entry
        const name_escaped = try jsonEscape(self.allocator, s.package_name);
        defer self.allocator.free(name_escaped);
        const repo_escaped = try jsonEscape(self.allocator, s.repo_name);
        defer self.allocator.free(repo_escaped);
        const version_escaped = try jsonEscape(self.allocator, s.hosted_version);
        defer self.allocator.free(version_escaped);

        var buf: [512]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "{{\"name\":\"{s}\",\"repo\":\"{s}\",\"version\":\"{s}\",\"advisory_status\":\"{s}\",\"stale_status\":\"{s}\",\"signature_status\":\"{s}\",\"advisory_count\":{d}", .{
            name_escaped,
            repo_escaped,
            version_escaped,
            s.advisory_status.asString(),
            s.stale_status.asString(),
            s.signature_status.asString(),
            s.advisory_match_count,
        }) catch continue;
        try json.appendSlice(self.allocator, entry);

        if (s.highest_severity) |sev| {
            var sev_buf: [64]u8 = undefined;
            const sev_str = std.fmt.bufPrint(&sev_buf, ",\"highest_severity\":\"{s}\"", .{sev.asString()}) catch "";
            try json.appendSlice(self.allocator, sev_str);
        }

        try json.appendSlice(self.allocator, "}");
    }

    try json.appendSlice(self.allocator, "],\"summary\":{");

    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "\"total\":{d},\"vulnerable\":{d},\"clean\":{d},\"unknown\":{d},\"stale\":{d},\"unsigned\":{d}", .{
        statuses.len,
        vulnerable,
        clean,
        unknown,
        stale,
        unsigned,
    }) catch "";
    try json.appendSlice(self.allocator, summary);
    try json.appendSlice(self.allocator, "}}");

    return self.respondWithCors(request, .ok, "application/json", json.items);
}

fn apiSecurityAdvisories(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");

    var security = SecurityManager.init(self.allocator, config, db);
    defer security.deinit();

    const advisories = try security.getAdvisories();
    defer {
        for (advisories) |a| a.deinit(self.allocator);
        self.allocator.free(advisories);
    }

    // Build JSON response
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(self.allocator);

    try json.appendSlice(self.allocator, "{\"advisories\":[");

    for (advisories, 0..) |a, i| {
        if (i > 0) try json.appendSlice(self.allocator, ",");

        const id_escaped = try jsonEscape(self.allocator, a.advisory_id);
        defer self.allocator.free(id_escaped);
        const pkg_escaped = try jsonEscape(self.allocator, a.package_name);
        defer self.allocator.free(pkg_escaped);
        const type_escaped = try jsonEscape(self.allocator, a.vuln_type);
        defer self.allocator.free(type_escaped);
        const affected_escaped = try jsonEscape(self.allocator, a.affected_version);
        defer self.allocator.free(affected_escaped);

        var buf: [512]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"package\":\"{s}\",\"severity\":\"{s}\",\"type\":\"{s}\",\"affected\":\"{s}\"", .{
            id_escaped,
            pkg_escaped,
            a.severity.asString(),
            type_escaped,
            affected_escaped,
        }) catch continue;
        try json.appendSlice(self.allocator, entry);

        if (a.fixed_version) |fv| {
            const fv_escaped = try jsonEscape(self.allocator, fv);
            defer self.allocator.free(fv_escaped);
            var fv_buf: [256]u8 = undefined;
            const fv_str = std.fmt.bufPrint(&fv_buf, ",\"fixed\":\"{s}\"", .{fv_escaped}) catch "";
            try json.appendSlice(self.allocator, fv_str);
        }

        // Validate and sanitize cve_ids JSON array using std.json
        try json.appendSlice(self.allocator, ",\"cve_ids\":");
        try json.appendSlice(self.allocator, sanitizeCveIdsJson(self.allocator, a.cve_ids));
        try json.appendSlice(self.allocator, "}");
    }

    var count_buf: [64]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "],\"count\":{d}}}", .{advisories.len}) catch "]}";
    try json.appendSlice(self.allocator, count_str);

    return self.respondWithCors(request, .ok, "application/json", json.items);
}

fn apiSecuritySync(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");

    var security = SecurityManager.init(self.allocator, config, db);
    defer security.deinit();

    const result = security.syncAdvisories() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "sync failed: {}", .{err}) catch "sync failed";
        return self.jsonErrorWithCors(request, .internal_server_error, msg);
    };

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"success\":true,\"advisories_synced\":{d},\"errors\":{d}}}", .{ result.advisories_synced, result.errors }) catch "{\"success\":true}";
    return self.respondWithCors(request, .ok, "application/json", json);
}

fn apiSecurityScan(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");

    var security = SecurityManager.init(self.allocator, config, db);
    defer security.deinit();

    const result = security.scanAllPackages() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "scan failed: {}", .{err}) catch "scan failed";
        return self.jsonErrorWithCors(request, .internal_server_error, msg);
    };

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"success\":true,\"total\":{d},\"clean\":{d},\"vulnerable\":{d},\"unknown\":{d},\"stale\":{d},\"unsigned\":{d}}}", .{
        result.total,
        result.clean,
        result.vulnerable,
        result.unknown,
        result.stale,
        result.unsigned,
    }) catch "{\"success\":true}";
    return self.respondWithCors(request, .ok, "application/json", json);
}

// GET /api/security/findings - all persisted PKGBUILD scan findings
fn apiSecurityFindings(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");

    const findings = try db.getAllScanFindings(self.allocator);
    defer {
        for (findings) |f| f.deinit(self.allocator);
        self.allocator.free(findings);
    }

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(self.allocator);
    try json.appendSlice(self.allocator, "{\"findings\":[");

    for (findings, 0..) |f, i| {
        if (i > 0) try json.appendSlice(self.allocator, ",");
        const src = try jsonEscape(self.allocator, f.source_name);
        defer self.allocator.free(src);
        const file = try jsonEscape(self.allocator, f.file_name);
        defer self.allocator.free(file);
        const rule = try jsonEscape(self.allocator, f.rule_id);
        defer self.allocator.free(rule);
        const sev = try jsonEscape(self.allocator, f.severity);
        defer self.allocator.free(sev);
        const msg = try jsonEscape(self.allocator, f.message);
        defer self.allocator.free(msg);
        const exc = try jsonEscape(self.allocator, f.excerpt);
        defer self.allocator.free(exc);

        var buf: [1024]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "{{\"source\":\"{s}\",\"rule\":\"{s}\",\"severity\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"message\":\"{s}\",\"excerpt\":\"{s}\"}}", .{
            src, rule, sev, file, f.line_no, msg, exc,
        }) catch continue;
        try json.appendSlice(self.allocator, entry);
    }

    var count_buf: [64]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "],\"count\":{d}}}", .{findings.len}) catch "]}";
    try json.appendSlice(self.allocator, count_str);
    return self.respondWithCors(request, .ok, "application/json", json.items);
}

// POST /api/security/scan-pkgbuild - scan a source's checkout, persist findings
fn apiSecurityScanPkgbuild(self: *HttpServer, request: *std.http.Server.Request, io: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");

    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }
    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);
    if (body.len == 0) return self.jsonErrorWithCors(request, .bad_request, "missing request body");

    const ScanReq = struct { source: []const u8 };
    const parsed = std.json.parseFromSlice(ScanReq, self.allocator, body, .{}) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid JSON");
    };
    defer parsed.deinit();

    const source_name = try self.allocator.dupe(u8, parsed.value.source);
    defer self.allocator.free(source_name);
    SourceManager.validateSourceName(source_name) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid source name");
    };

    const checkout_dir = try config.sourceCheckoutDir(self.allocator, source_name);
    defer self.allocator.free(checkout_dir);

    const findings = Scanner.scanSourceTree(self.allocator, io, checkout_dir) catch {
        return self.jsonErrorWithCors(request, .internal_server_error, "scan failed");
    };
    defer {
        for (findings) |f| f.deinit(self.allocator);
        self.allocator.free(findings);
    }

    db.clearScanFindings(source_name) catch {};
    for (findings) |f| {
        db.addScanFinding(source_name, f.rule_id, f.severity.asString(), f.file_name, f.line_no, f.excerpt, f.message) catch {};
    }

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"success\":true,\"findings\":{d},\"blocked\":{}}}", .{ findings.len, Scanner.shouldBlock(findings) }) catch "{\"success\":true}";
    return self.respondWithCors(request, .ok, "application/json", json);
}

// GET /api/security/keys - list trusted GPG fingerprints
fn apiSecurityListKeys(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");

    const keys = try db.getTrustedKeys(self.allocator);
    defer {
        for (keys) |k| k.deinit(self.allocator);
        self.allocator.free(keys);
    }

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(self.allocator);
    try json.appendSlice(self.allocator, "{\"keys\":[");
    for (keys, 0..) |k, i| {
        if (i > 0) try json.appendSlice(self.allocator, ",");
        const fpr = try jsonEscape(self.allocator, k.fingerprint);
        defer self.allocator.free(fpr);
        const note = try jsonEscape(self.allocator, k.note);
        defer self.allocator.free(note);
        var buf: [512]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "{{\"fingerprint\":\"{s}\",\"note\":\"{s}\"}}", .{ fpr, note }) catch continue;
        try json.appendSlice(self.allocator, entry);
    }
    var count_buf: [64]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "],\"count\":{d}}}", .{keys.len}) catch "]}";
    try json.appendSlice(self.allocator, count_str);
    return self.respondWithCors(request, .ok, "application/json", json.items);
}

// POST /api/security/keys - add a trusted fingerprint
fn apiSecurityAddKey(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }
    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);
    if (body.len == 0) return self.jsonErrorWithCors(request, .bad_request, "missing request body");

    const KeyReq = struct { fingerprint: []const u8, note: []const u8 = "" };
    const parsed = std.json.parseFromSlice(KeyReq, self.allocator, body, .{}) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid JSON");
    };
    defer parsed.deinit();

    db.addTrustedKey(parsed.value.fingerprint, "", parsed.value.note) catch {
        return self.jsonErrorWithCors(request, .internal_server_error, "failed to add key");
    };
    return self.respondWithCors(request, .ok, "application/json", "{\"success\":true}");
}

// DELETE /api/security/keys - remove a trusted fingerprint
fn apiSecurityRemoveKey(self: *HttpServer, request: *std.http.Server.Request, _: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }
    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);
    if (body.len == 0) return self.jsonErrorWithCors(request, .bad_request, "missing request body");

    const KeyReq = struct { fingerprint: []const u8 };
    const parsed = std.json.parseFromSlice(KeyReq, self.allocator, body, .{}) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid JSON");
    };
    defer parsed.deinit();

    db.removeTrustedKey(parsed.value.fingerprint) catch {
        return self.jsonErrorWithCors(request, .internal_server_error, "failed to remove key");
    };
    return self.respondWithCors(request, .ok, "application/json", "{\"success\":true}");
}

// POST /api/security/pin - pin a source to a ref/commit
fn apiSecurityPin(self: *HttpServer, request: *std.http.Server.Request, io: std.Io) !void {
    const db = self.database orelse return self.jsonErrorWithCors(request, .internal_server_error, "no database");
    const config = self.config orelse return self.jsonErrorWithCors(request, .internal_server_error, "no config");
    if (!requireJsonContentType(request)) {
        return self.jsonErrorWithCors(request, .unsupported_media_type, "Content-Type must be application/json");
    }
    const body = try self.readRequestBody(request);
    defer if (body.len > 0) self.allocator.free(body);
    if (body.len == 0) return self.jsonErrorWithCors(request, .bad_request, "missing request body");

    const PinReq = struct { source: []const u8, ref: []const u8 = "" };
    const parsed = std.json.parseFromSlice(PinReq, self.allocator, body, .{}) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid JSON");
    };
    defer parsed.deinit();

    const source_name = try self.allocator.dupe(u8, parsed.value.source);
    defer self.allocator.free(source_name);
    SourceManager.validateSourceName(source_name) catch {
        return self.jsonErrorWithCors(request, .bad_request, "invalid source name");
    };

    const checkout_dir = try config.sourceCheckoutDir(self.allocator, source_name);
    defer self.allocator.free(checkout_dir);

    if (parsed.value.ref.len > 0) {
        Integrity.checkoutRef(self.allocator, io, checkout_dir, parsed.value.ref) catch {
            return self.jsonErrorWithCors(request, .internal_server_error, "failed to checkout ref");
        };
    }
    const commit = Integrity.resolveGitHead(self.allocator, io, checkout_dir) catch {
        return self.jsonErrorWithCors(request, .internal_server_error, "failed to resolve commit");
    };
    defer self.allocator.free(commit);
    const pin_ref = if (parsed.value.ref.len > 0) parsed.value.ref else commit;
    db.setSourcePin(source_name, null, pin_ref, commit, null) catch {
        return self.jsonErrorWithCors(request, .internal_server_error, "failed to persist pin");
    };
    return self.respondWithCors(request, .ok, "application/json", "{\"success\":true}");
}

// Response helpers

fn respondText(request: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8) !void {
    const method_needs_body = request.head.method == .POST or request.head.method == .PUT or request.head.method == .PATCH or request.head.method == .DELETE;
    const has_body_info = request.head.content_length != null or request.head.transfer_encoding != .none;
    const safe_keep_alive = if (method_needs_body and !has_body_info) false else true;

    try request.respond(body, .{
        .status = status,
        .keep_alive = safe_keep_alive,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = content_type },
        },
    });
}

fn jsonError(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    // Escape message for safe JSON embedding
    var escaped: [512]u8 = undefined;
    var escaped_len: usize = 0;

    for (message) |c| {
        if (escaped_len >= escaped.len - 6) break; // Leave room for escape sequences
        switch (c) {
            '"' => {
                escaped[escaped_len] = '\\';
                escaped[escaped_len + 1] = '"';
                escaped_len += 2;
            },
            '\\' => {
                escaped[escaped_len] = '\\';
                escaped[escaped_len + 1] = '\\';
                escaped_len += 2;
            },
            '\n' => {
                escaped[escaped_len] = '\\';
                escaped[escaped_len + 1] = 'n';
                escaped_len += 2;
            },
            '\r' => {
                escaped[escaped_len] = '\\';
                escaped[escaped_len + 1] = 'r';
                escaped_len += 2;
            },
            '\t' => {
                escaped[escaped_len] = '\\';
                escaped[escaped_len + 1] = 't';
                escaped_len += 2;
            },
            else => {
                if (c >= 0x20) {
                    escaped[escaped_len] = c;
                    escaped_len += 1;
                }
                // Skip other control characters
            },
        }
    }

    var buf: [600]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{escaped[0..escaped_len]}) catch "{\"error\":\"internal\"}";
    try respondText(request, status, "application/json", json);
}

// Validate and sanitize a JSON array of CVE ID strings using std.json
// Returns the original input if valid, or "[]" if invalid
fn sanitizeCveIdsJson(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    // Use std.json to parse and validate
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        return "[]";
    };
    defer parsed.deinit();

    // Must be an array
    if (parsed.value != .array) {
        return "[]";
    }

    // Each element must be a string
    for (parsed.value.array.items) |item| {
        if (item != .string) {
            return "[]";
        }
    }

    // Valid - return original input (it parsed successfully so it's safe)
    return input;
}

// Escape a string for safe JSON embedding
fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // Control character - escape as \u00XX
                    var hex_buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex_buf, "\\u00{x:0>2}", .{c}) catch unreachable;
                    try result.appendSlice(allocator, &hex_buf);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".db")) return "application/octet-stream";
    if (std.mem.endsWith(u8, path, ".db.tar.gz")) return "application/gzip";
    if (std.mem.endsWith(u8, path, ".pkg.tar.zst")) return "application/zstd";
    if (std.mem.endsWith(u8, path, ".sig")) return "application/pgp-signature";
    return "application/octet-stream";
}

fn indexHtml() []const u8 {
    return
    \\<!DOCTYPE html>
    \\<html>
    \\<head><title>ZAUR</title></head>
    \\<body>
    \\<h1>ZAUR</h1>
    \\<p>Self-hosted Arch package service.</p>
    \\<h2>API Endpoints</h2>
    \\<ul>
    \\<li><a href="/api/health">/api/health</a> - Health check</li>
    \\<li><a href="/api/status">/api/status</a> - System status</li>
    \\<li><a href="/api/packages">/api/packages</a> - List packages</li>
    \\<li><a href="/api/sources">/api/sources</a> - List sources</li>
    \\<li><a href="/api/builds">/api/builds</a> - Build history</li>
    \\<li><a href="/api/repos">/api/repos</a> - Repository info</li>
    \\<li><a href="/api/mirror">/api/mirror</a> - Mirror status</li>
    \\</ul>
    \\<h2>Admin Endpoints (auth required)</h2>
    \\<ul>
    \\<li>POST /api/sources - Add source</li>
    \\<li>DELETE /api/sources - Remove source</li>
    \\<li>POST /api/builds - Trigger build</li>
    \\<li>POST /api/repos/publish - Publish repos</li>
    \\<li>POST /api/mirror/sync - Sync mirror</li>
    \\</ul>
    \\</body>
    \\</html>
    ;
}

// =============================================================================
// Tests: Path Validation and Security
// =============================================================================

test "isValidRepoPath rejects empty paths" {
    try std.testing.expect(!isValidRepoPath(""));
}

test "isValidRepoPath rejects absolute paths" {
    try std.testing.expect(!isValidRepoPath("/etc/passwd"));
    try std.testing.expect(!isValidRepoPath("/aur/package.pkg.tar.zst"));
}

test "isValidRepoPath rejects null bytes" {
    try std.testing.expect(!isValidRepoPath("package\x00.pkg.tar.zst"));
    try std.testing.expect(!isValidRepoPath("core/\x00../etc/passwd"));
}

test "isValidRepoPath rejects dot-dot traversal" {
    try std.testing.expect(!isValidRepoPath("../etc/passwd"));
    try std.testing.expect(!isValidRepoPath("core/../../../etc/passwd"));
    try std.testing.expect(!isValidRepoPath(".."));
    try std.testing.expect(!isValidRepoPath("foo/.."));
    try std.testing.expect(!isValidRepoPath("foo/../bar"));
}

test "isValidRepoPath rejects single dot segments" {
    try std.testing.expect(!isValidRepoPath("."));
    try std.testing.expect(!isValidRepoPath("./foo"));
    try std.testing.expect(!isValidRepoPath("foo/."));
    try std.testing.expect(!isValidRepoPath("foo/./bar"));
}

test "isValidRepoPath rejects empty segments" {
    try std.testing.expect(!isValidRepoPath("foo//bar"));
    try std.testing.expect(!isValidRepoPath("//foo"));
    try std.testing.expect(!isValidRepoPath("foo/bar//"));
}

test "isValidRepoPath rejects backslash paths" {
    try std.testing.expect(!isValidRepoPath("foo\\bar"));
    try std.testing.expect(!isValidRepoPath("..\\etc\\passwd"));
    try std.testing.expect(!isValidRepoPath("core\\package.pkg.tar.zst"));
}

test "isValidRepoPath accepts valid repo paths" {
    try std.testing.expect(isValidRepoPath("core/package-1.0-1-x86_64.pkg.tar.zst"));
    try std.testing.expect(isValidRepoPath("extra/package.db.tar.gz"));
    try std.testing.expect(isValidRepoPath("multilib/lib32-glibc-2.39-1-x86_64.pkg.tar.zst"));
    try std.testing.expect(isValidRepoPath("package.pkg.tar.zst"));
    try std.testing.expect(isValidRepoPath("zaur.db"));
    try std.testing.expect(isValidRepoPath("core.db.tar.gz"));
}

test "isValidRepoPath accepts nested valid paths" {
    try std.testing.expect(isValidRepoPath("a/b/c/d.pkg.tar.zst"));
    try std.testing.expect(isValidRepoPath("repo/arch/package.pkg.tar.zst"));
}

// =============================================================================
// Tests: JSON Escaping
// =============================================================================

test "jsonEscape handles special characters" {
    const allocator = std.testing.allocator;

    const escaped = try jsonEscape(allocator, "hello\"world");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("hello\\\"world", escaped);
}

test "jsonEscape handles backslashes" {
    const allocator = std.testing.allocator;

    const escaped = try jsonEscape(allocator, "path\\to\\file");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", escaped);
}

test "jsonEscape handles newlines and tabs" {
    const allocator = std.testing.allocator;

    const escaped = try jsonEscape(allocator, "line1\nline2\ttab");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", escaped);
}

test "jsonEscape handles control characters" {
    const allocator = std.testing.allocator;

    const escaped = try jsonEscape(allocator, "test\x01\x02value");
    defer allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\u00") != null);
}

test "jsonEscape preserves normal strings" {
    const allocator = std.testing.allocator;

    const escaped = try jsonEscape(allocator, "normal-string_123");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("normal-string_123", escaped);
}

// =============================================================================
// Tests: Content Type Detection
// =============================================================================

test "contentType returns correct types for package files" {
    try std.testing.expectEqualStrings("application/zstd", contentType("package.pkg.tar.zst"));
    try std.testing.expectEqualStrings("application/gzip", contentType("core.db.tar.gz"));
    try std.testing.expectEqualStrings("application/pgp-signature", contentType("package.pkg.tar.zst.sig"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("zaur.db"));
}

test "contentType returns correct types for web files" {
    try std.testing.expectEqualStrings("text/html", contentType("index.html"));
    try std.testing.expectEqualStrings("text/css", contentType("style.css"));
    try std.testing.expectEqualStrings("application/javascript", contentType("app.js"));
    try std.testing.expectEqualStrings("application/json", contentType("data.json"));
    try std.testing.expectEqualStrings("application/wasm", contentType("module.wasm"));
}

test "contentType defaults to octet-stream for unknown extensions" {
    try std.testing.expectEqualStrings("application/octet-stream", contentType("unknown.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("noextension"));
}
