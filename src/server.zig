const std = @import("std");

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    repo_dir: []const u8,
    port: u16,
    bind_address: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_dir: []const u8, port: u16, bind_address: []const u8) HttpServer {
        return HttpServer{
            .allocator = allocator,
            .repo_dir = repo_dir,
            .port = port,
            .bind_address = bind_address,
        };
    }

    pub fn start(self: *HttpServer) !void {
        const address = try std.net.Address.parseIp(self.bind_address, self.port);
        var server = try address.listen(.{});
        defer server.deinit();

        std.debug.print("🚀 ZAUR HTTP server started on {s}:{d}\n", .{ self.bind_address, self.port });
        std.debug.print("📦 Serving repository from: {s}\n", .{self.repo_dir});
        std.debug.print("📋 For your reap CLI tool, use base URL: http://{s}:{d}/\n", .{ self.bind_address, self.port });
        std.debug.print("📋 Nginx upstream config:\n    upstream zaur {{ server {s}:{d}; }}\n", .{ self.bind_address, self.port });

        while (true) {
            const connection = server.accept() catch continue;
            self.handleConnection(connection) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *HttpServer, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        var buffer: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        const request_str = buffer[0..bytes_read];
        var lines = std.mem.splitSequence(u8, request_str, "\r\n");
        const request_line = lines.next() orelse return;

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) return;

        if (std.mem.eql(u8, path, "/")) {
            try self.serveIndex(connection);
        } else if (std.mem.eql(u8, path, "/api/packages")) {
            try self.serveAPI(connection);
        } else if (std.mem.startsWith(u8, path, "/")) {
            try self.serveFile(connection, path[1..]);
        } else {
            try self.send404(connection);
        }
    }

    fn serveIndex(self: *HttpServer, connection: std.net.Server.Connection) !void {
        const html =
            \\<!DOCTYPE html>
            \\<html><head><title>ZAUR Repository</title></head>
            \\<body><h1>🦎 ZAUR Repository</h1>
            \\<p>Repository files served here for pacman and nginx.</p>
            \\<p>API endpoint: <a href="/api/packages">/api/packages</a></p>
            \\</body></html>
        ;
        try self.sendResponse(connection, "200 OK", "text/html", html);
    }

    fn serveAPI(self: *HttpServer, connection: std.net.Server.Connection) !void {
        var json = std.ArrayList(u8).init(self.allocator);
        defer json.deinit();

        try json.appendSlice("{\"packages\":[");

        var dir = std.fs.openDirAbsolute(self.repo_dir, .{ .iterate = true }) catch {
            try json.appendSlice("]}");
            try self.sendResponse(connection, "200 OK", "application/json", json.items);
            return;
        };
        defer dir.close();

        var first = true;
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pkg.tar.zst")) {
                if (!first) try json.appendSlice(",");
                try json.writer().print("\"{s}\"", .{entry.name});
                first = false;
            }
        }

        try json.appendSlice("]}");
        try self.sendResponse(connection, "200 OK", "application/json", json.items);
    }

    fn serveFile(self: *HttpServer, connection: std.net.Server.Connection, file_name: []const u8) !void {
        const file_path = try std.fs.path.join(self.allocator, &.{ self.repo_dir, file_name });
        defer self.allocator.free(file_path);

        const file = std.fs.openFileAbsolute(file_path, .{}) catch {
            try self.send404(connection);
            return;
        };
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);
        defer self.allocator.free(contents);

        try self.sendResponse(connection, "200 OK", self.getContentType(file_name), contents);
    }

    fn send404(self: *HttpServer, connection: std.net.Server.Connection) !void {
        try self.sendResponse(connection, "404 Not Found", "text/plain", "404 Not Found");
    }

    fn sendResponse(self: *HttpServer, connection: std.net.Server.Connection, status: []const u8, content_type: []const u8, body: []const u8) !void {
        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, content_type, body.len, body });
        defer self.allocator.free(response);

        _ = try connection.stream.writeAll(response);
    }

    fn getContentType(self: *HttpServer, path: []const u8) []const u8 {
        _ = self;
        if (std.mem.endsWith(u8, path, ".db") or std.mem.endsWith(u8, path, ".db.tar.zst")) {
            return "application/octet-stream";
        } else if (std.mem.endsWith(u8, path, ".files") or std.mem.endsWith(u8, path, ".files.tar.zst")) {
            return "application/octet-stream";
        } else if (std.mem.endsWith(u8, path, ".pkg.tar.zst")) {
            return "application/octet-stream";
        } else if (std.mem.endsWith(u8, path, ".html")) {
            return "text/html";
        } else {
            return "application/octet-stream";
        }
    }
};
