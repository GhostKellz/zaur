const std = @import("std");
const zqlite = @import("zqlite");

const SCHEMA_VERSION: i64 = 2;

// Concurrency Model (v1 Design):
// Single shared SQLite connection protected by application-level spinlock.
// All database operations are serialized. This is a safe, conservative model
// that prioritizes correctness over throughput. Suitable for a local package
// manager with modest concurrent load. Trade-off: no concurrent readers.

/// Simple spinlock mutex for thread synchronization
const SpinMutex = struct {
    state: std.atomic.Value(State) = .init(.unlocked),

    const State = enum(u32) {
        unlocked = 0,
        locked = 1,
    };

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(.unlocked, .release);
    }
};

pub const SourceKind = enum {
    aur,
    git,
    local,

    pub fn fromString(value: []const u8) SourceKind {
        if (std.mem.eql(u8, value, "aur")) return .aur;
        if (std.mem.eql(u8, value, "git") or std.mem.eql(u8, value, "github")) return .git;
        return .local;
    }

    pub fn asString(self: SourceKind) []const u8 {
        return switch (self) {
            .aur => "aur",
            .git => "git",
            .local => "local",
        };
    }
};

pub const Source = struct {
    name: []const u8,
    kind: SourceKind,
    location: []const u8,
    package_subpath: []const u8,
    repo_name: []const u8,
    updated_at: []const u8,
    created_at: []const u8,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.location);
        allocator.free(self.package_subpath);
        allocator.free(self.repo_name);
        allocator.free(self.updated_at);
        allocator.free(self.created_at);
    }
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    source_name: []const u8,
    source_type: []const u8,
    source_url: []const u8,
    source_subpath: []const u8,
    repo_name: []const u8,
    build_status: []const u8,
    added_at: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.source_name);
        allocator.free(self.source_type);
        allocator.free(self.source_url);
        allocator.free(self.source_subpath);
        allocator.free(self.repo_name);
        allocator.free(self.build_status);
        allocator.free(self.added_at);
        allocator.free(self.updated_at);
    }
};

pub const BuildLog = struct {
    package_name: []const u8,
    status: []const u8,
    build_log: []const u8,
    finished_at: []const u8,

    pub fn deinit(self: BuildLog, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.status);
        allocator.free(self.build_log);
        allocator.free(self.finished_at);
    }
};

pub const MirrorCacheEntry = struct {
    package_name: []const u8,
    package_version: []const u8,
    file_path: []const u8,
    file_size: u64,

    pub fn deinit(self: MirrorCacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.package_version);
        allocator.free(self.file_path);
    }
};

// Security types
pub const Severity = enum {
    critical,
    high,
    medium,
    low,
    unknown,

    pub fn fromString(value: []const u8) Severity {
        if (std.mem.eql(u8, value, "Critical")) return .critical;
        if (std.mem.eql(u8, value, "High")) return .high;
        if (std.mem.eql(u8, value, "Medium")) return .medium;
        if (std.mem.eql(u8, value, "Low")) return .low;
        return .unknown;
    }

    pub fn asString(self: Severity) []const u8 {
        return switch (self) {
            .critical => "Critical",
            .high => "High",
            .medium => "Medium",
            .low => "Low",
            .unknown => "Unknown",
        };
    }

    pub fn order(self: Severity) u8 {
        return switch (self) {
            .critical => 4,
            .high => 3,
            .medium => 2,
            .low => 1,
            .unknown => 0,
        };
    }
};

pub const AdvisoryStatus = enum {
    clean,
    vulnerable,
    unknown,
    unscanned,

    pub fn fromString(value: []const u8) AdvisoryStatus {
        if (std.mem.eql(u8, value, "clean")) return .clean;
        if (std.mem.eql(u8, value, "vulnerable")) return .vulnerable;
        if (std.mem.eql(u8, value, "unknown")) return .unknown;
        return .unscanned;
    }

    pub fn asString(self: AdvisoryStatus) []const u8 {
        return switch (self) {
            .clean => "clean",
            .vulnerable => "vulnerable",
            .unknown => "unknown",
            .unscanned => "unscanned",
        };
    }
};

pub const StaleStatus = enum {
    fresh,
    stale,
    unknown,

    pub fn fromString(value: []const u8) StaleStatus {
        if (std.mem.eql(u8, value, "fresh")) return .fresh;
        if (std.mem.eql(u8, value, "stale")) return .stale;
        return .unknown;
    }

    pub fn asString(self: StaleStatus) []const u8 {
        return switch (self) {
            .fresh => "fresh",
            .stale => "stale",
            .unknown => "unknown",
        };
    }
};

pub const SignatureStatus = enum {
    signed,
    unsigned,
    not_required,
    unknown,

    pub fn fromString(value: []const u8) SignatureStatus {
        if (std.mem.eql(u8, value, "signed")) return .signed;
        if (std.mem.eql(u8, value, "unsigned")) return .unsigned;
        if (std.mem.eql(u8, value, "not_required")) return .not_required;
        return .unknown;
    }

    pub fn asString(self: SignatureStatus) []const u8 {
        return switch (self) {
            .signed => "signed",
            .unsigned => "unsigned",
            .not_required => "not_required",
            .unknown => "unknown",
        };
    }
};

pub const Advisory = struct {
    advisory_id: []const u8,
    package_name: []const u8,
    severity: Severity,
    vuln_type: []const u8,
    affected_version: []const u8,
    fixed_version: ?[]const u8,
    status: []const u8,
    cve_ids: []const u8,
    reference_url: ?[]const u8,
    published_at: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: Advisory, allocator: std.mem.Allocator) void {
        allocator.free(self.advisory_id);
        allocator.free(self.package_name);
        allocator.free(self.vuln_type);
        allocator.free(self.affected_version);
        if (self.fixed_version) |fv| allocator.free(fv);
        allocator.free(self.status);
        allocator.free(self.cve_ids);
        if (self.reference_url) |url| allocator.free(url);
        allocator.free(self.published_at);
        allocator.free(self.updated_at);
    }
};

pub const PackageSecurityStatus = struct {
    package_name: []const u8,
    repo_name: []const u8,
    hosted_version: []const u8,
    advisory_status: AdvisoryStatus,
    stale_status: StaleStatus,
    signature_status: SignatureStatus,
    advisory_match_count: u32,
    highest_severity: ?Severity,
    last_scanned_at: ?[]const u8,
    updated_at: []const u8,

    pub fn deinit(self: PackageSecurityStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.repo_name);
        allocator.free(self.hosted_version);
        if (self.last_scanned_at) |ts| allocator.free(ts);
        allocator.free(self.updated_at);
    }
};

pub const ColumnInfo = struct {
    name: []const u8,
    data_type: []const u8,
    is_primary_key: bool,
    is_nullable: bool,
    has_default: bool,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    db_path: []const u8,
    conn: *zqlite.Connection,
    mutex: SpinMutex = .{},

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        // Ensure parent directory exists
        if (std.fs.path.dirname(db_path)) |parent| {
            var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
            defer threaded_io.deinit();
            std.Io.Dir.createDirPath(.cwd(), threaded_io.io(), parent) catch {};
        }

        // Open or create the database
        const conn = try zqlite.open(allocator, db_path);
        errdefer conn.close();

        var db = Database{
            .allocator = allocator,
            .db_path = try allocator.dupe(u8, db_path),
            .conn = conn,
        };

        // Bootstrap schema
        try db.bootstrapSchema();

        // Run migrations for existing databases
        try db.runMigrations();

        // Import legacy JSON if it exists
        try db.importLegacyJson();

        return db;
    }

    pub fn deinit(self: *Database) void {
        self.conn.close();
        self.allocator.free(self.db_path);
    }

    fn bootstrapSchema(self: *Database) !void {
        // Create tables
        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS schema_version (
            \\    version INTEGER NOT NULL
            \\)
        );

        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS sources (
            \\    name TEXT PRIMARY KEY,
            \\    kind TEXT NOT NULL,
            \\    location TEXT NOT NULL,
            \\    package_subpath TEXT NOT NULL DEFAULT '',
            \\    repo_name TEXT NOT NULL,
            \\    created_at TEXT NOT NULL,
            \\    updated_at TEXT NOT NULL
            \\)
        );

        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS packages (
            \\    name TEXT PRIMARY KEY,
            \\    version TEXT NOT NULL DEFAULT 'unknown',
            \\    source_name TEXT NOT NULL,
            \\    repo_name TEXT NOT NULL,
            \\    build_status TEXT NOT NULL DEFAULT 'pending',
            \\    added_at TEXT NOT NULL,
            \\    updated_at TEXT NOT NULL
            \\)
        );

        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS build_logs (
            \\    id INTEGER PRIMARY KEY,
            \\    package_name TEXT NOT NULL,
            \\    status TEXT NOT NULL,
            \\    build_log TEXT NOT NULL,
            \\    finished_at TEXT NOT NULL
            \\)
        );

        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS mirror_cache (
            \\    repo_name TEXT NOT NULL,
            \\    package_name TEXT NOT NULL,
            \\    package_version TEXT NOT NULL,
            \\    file_path TEXT NOT NULL,
            \\    file_size INTEGER NOT NULL,
            \\    cached_at TEXT NOT NULL,
            \\    last_accessed TEXT NOT NULL,
            \\    PRIMARY KEY (repo_name, package_name, package_version)
            \\)
        );

        // Security tables
        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS security_advisories (
            \\    advisory_id TEXT PRIMARY KEY,
            \\    package_name TEXT NOT NULL,
            \\    severity TEXT NOT NULL,
            \\    vuln_type TEXT NOT NULL,
            \\    affected_version TEXT NOT NULL,
            \\    fixed_version TEXT,
            \\    status TEXT NOT NULL,
            \\    cve_ids TEXT NOT NULL DEFAULT '[]',
            \\    reference_url TEXT,
            \\    published_at TEXT NOT NULL,
            \\    updated_at TEXT NOT NULL
            \\)
        );

        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS security_package_status (
            \\    package_name TEXT PRIMARY KEY,
            \\    repo_name TEXT NOT NULL,
            \\    hosted_version TEXT NOT NULL,
            \\    advisory_status TEXT NOT NULL DEFAULT 'unscanned',
            \\    stale_status TEXT NOT NULL DEFAULT 'unknown',
            \\    signature_status TEXT NOT NULL DEFAULT 'unknown',
            \\    advisory_match_count INTEGER NOT NULL DEFAULT 0,
            \\    highest_severity TEXT,
            \\    last_scanned_at TEXT,
            \\    updated_at TEXT NOT NULL
            \\)
        );

        try self.conn.execute(
            \\CREATE TABLE IF NOT EXISTS security_sync_runs (
            \\    id INTEGER PRIMARY KEY,
            \\    kind TEXT NOT NULL,
            \\    status TEXT NOT NULL,
            \\    started_at TEXT NOT NULL,
            \\    finished_at TEXT,
            \\    details TEXT
            \\)
        );

        // Create indexes
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_packages_source ON packages(source_name)") catch {};
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_packages_status ON packages(build_status)") catch {};
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_build_logs_package ON build_logs(package_name)") catch {};
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_mirror_cache_accessed ON mirror_cache(last_accessed)") catch {};
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_advisories_package ON security_advisories(package_name)") catch {};
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_advisories_severity ON security_advisories(severity)") catch {};
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_pkg_status_advisory ON security_package_status(advisory_status)") catch {};

        // Initialize schema version if not present
        var result = try self.conn.query("SELECT version FROM schema_version LIMIT 1");
        defer result.deinit();

        if (result.next()) |row| {
            var r = row;
            r.deinit();
        } else {
            // Insert initial schema version
            var stmt = try self.conn.prepare("INSERT INTO schema_version (version) VALUES (?)");
            defer stmt.deinit();
            try stmt.bind(0, SCHEMA_VERSION);
            var exec_result = try stmt.execute();
            exec_result.deinit();
        }
    }

    fn runMigrations(self: *Database) !void {
        // Get current schema version
        var result = try self.conn.query("SELECT version FROM schema_version LIMIT 1");
        defer result.deinit();

        var current_version: i64 = 0;
        if (result.next()) |row| {
            var r = row;
            defer r.deinit();
            current_version = r.getInt(0) orelse 0;
        }

        // Run migrations as needed
        if (current_version < 2) {
            try self.migrateToV2();
        }
    }

    fn migrateToV2(self: *Database) !void {
        // Security tables are already created by bootstrapSchema (IF NOT EXISTS)
        // Just update the schema version
        try self.conn.execute("UPDATE schema_version SET version = 2");
        std.debug.print("Database migrated to schema version 2\n", .{});
    }

    fn importLegacyJson(self: *Database) !void {
        const json_path = try std.fmt.allocPrint(self.allocator, "{s}.json", .{self.db_path});
        defer self.allocator.free(json_path);

        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const io = threaded_io.io();

        // Check if JSON file exists and read it
        const raw = std.Io.Dir.readFileAlloc(.cwd(), io, json_path, self.allocator, .limited(10 * 1024 * 1024)) catch return;
        defer self.allocator.free(raw);

        if (raw.len == 0) return;

        // Parse legacy JSON
        const CatalogSource = struct {
            name: []const u8,
            kind: []const u8,
            location: []const u8,
            package_subpath: []const u8,
            repo_name: []const u8,
            updated_at: []const u8,
            created_at: []const u8,
        };

        const CatalogPackage = struct {
            name: []const u8,
            version: []const u8,
            source_name: []const u8,
            repo_name: []const u8,
            build_status: []const u8,
            added_at: []const u8,
            updated_at: []const u8,
        };

        const CatalogBuildLog = struct {
            package_name: []const u8,
            status: []const u8,
            build_log: []const u8,
            finished_at: []const u8,
        };

        const CatalogMirrorCache = struct {
            repo_name: []const u8,
            package_name: []const u8,
            package_version: []const u8,
            file_path: []const u8,
            file_size: u64,
            cached_at: []const u8,
            last_accessed: []const u8,
        };

        const CatalogData = struct {
            version: u32,
            sources: []CatalogSource,
            packages: []CatalogPackage,
            builds: []CatalogBuildLog,
            mirror_cache: []CatalogMirrorCache,
        };

        var parsed = std.json.parseFromSlice(CatalogData, self.allocator, raw, .{}) catch return;
        defer parsed.deinit();

        // Import sources
        for (parsed.value.sources) |source| {
            self.upsertSource(source.name, SourceKind.fromString(source.kind), source.location, source.package_subpath, source.repo_name) catch continue;
        }

        // Import packages
        for (parsed.value.packages) |pkg| {
            self.addPackageFromSource(pkg.name, pkg.source_name, pkg.repo_name) catch continue;
            self.updatePackageVersion(pkg.name, pkg.version) catch continue;
            self.updatePackageBuildStatus(pkg.name, pkg.build_status) catch continue;
        }

        // Import build logs
        for (parsed.value.builds) |build| {
            self.addBuildLog(build.package_name, build.status, build.build_log) catch continue;
        }

        // Import mirror cache
        for (parsed.value.mirror_cache) |entry| {
            self.cacheMirrorPackage(entry.repo_name, entry.package_name, entry.package_version, entry.file_path, entry.file_size) catch continue;
        }

        // Delete JSON file after successful import
        std.Io.Dir.deleteFile(.cwd(), io, json_path) catch {};
    }

    pub fn upsertSource(self: *Database, name: []const u8, kind: SourceKind, location: []const u8, package_subpath: []const u8, repo_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        // Check if source exists
        var check_stmt = try self.conn.prepare("SELECT created_at FROM sources WHERE name = ?");
        defer check_stmt.deinit();
        try check_stmt.bind(0, name);
        var check_result = try check_stmt.execute();
        defer check_result.deinit();

        if (check_result.rows.items.len > 0) {
            // Get existing created_at
            const created_at = check_result.rows.items[0].values[0].Text;

            // Update existing
            var stmt = try self.conn.prepare(
                \\UPDATE sources SET kind = ?, location = ?, package_subpath = ?,
                \\repo_name = ?, updated_at = ? WHERE name = ?
            );
            defer stmt.deinit();
            try stmt.bind(0, kind.asString());
            try stmt.bind(1, location);
            try stmt.bind(2, package_subpath);
            try stmt.bind(3, repo_name);
            try stmt.bind(4, now);
            try stmt.bind(5, name);
            var result = try stmt.execute();
            result.deinit();
            _ = created_at;
        } else {
            // Insert new
            var stmt = try self.conn.prepare(
                \\INSERT INTO sources (name, kind, location, package_subpath, repo_name, created_at, updated_at)
                \\VALUES (?, ?, ?, ?, ?, ?, ?)
            );
            defer stmt.deinit();
            try stmt.bind(0, name);
            try stmt.bind(1, kind.asString());
            try stmt.bind(2, location);
            try stmt.bind(3, package_subpath);
            try stmt.bind(4, repo_name);
            try stmt.bind(5, now);
            try stmt.bind(6, now);
            var result = try stmt.execute();
            result.deinit();
        }
    }

    pub fn addPackage(self: *Database, name: []const u8, source_type: []const u8, source_url: []const u8) !void {
        const kind = SourceKind.fromString(source_type);
        try self.upsertSource(name, kind, source_url, "", "aur");
        try self.addPackageFromSource(name, name, "aur");
    }

    pub fn addPackageFromSource(self: *Database, name: []const u8, source_name: []const u8, repo_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        // Check if package exists
        var check_stmt = try self.conn.prepare("SELECT added_at, version FROM packages WHERE name = ?");
        defer check_stmt.deinit();
        try check_stmt.bind(0, name);
        var check_result = try check_stmt.execute();
        defer check_result.deinit();

        if (check_result.rows.items.len > 0) {
            // Update existing - preserve added_at and version
            var stmt = try self.conn.prepare(
                \\UPDATE packages SET source_name = ?, repo_name = ?,
                \\build_status = 'pending', updated_at = ? WHERE name = ?
            );
            defer stmt.deinit();
            try stmt.bind(0, source_name);
            try stmt.bind(1, repo_name);
            try stmt.bind(2, now);
            try stmt.bind(3, name);
            var result = try stmt.execute();
            result.deinit();
        } else {
            // Insert new
            var stmt = try self.conn.prepare(
                \\INSERT INTO packages (name, version, source_name, repo_name, build_status, added_at, updated_at)
                \\VALUES (?, 'unknown', ?, ?, 'pending', ?, ?)
            );
            defer stmt.deinit();
            try stmt.bind(0, name);
            try stmt.bind(1, source_name);
            try stmt.bind(2, repo_name);
            try stmt.bind(3, now);
            try stmt.bind(4, now);
            var result = try stmt.execute();
            result.deinit();
        }
    }

    pub fn updatePackageVersion(self: *Database, name: []const u8, version: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare("UPDATE packages SET version = ?, updated_at = ? WHERE name = ?");
        defer stmt.deinit();
        try stmt.bind(0, version);
        try stmt.bind(1, now);
        try stmt.bind(2, name);
        var result = try stmt.execute();
        result.deinit();
    }

    pub fn updatePackageBuildStatus(self: *Database, name: []const u8, status: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare("UPDATE packages SET build_status = ?, updated_at = ? WHERE name = ?");
        defer stmt.deinit();
        try stmt.bind(0, status);
        try stmt.bind(1, now);
        try stmt.bind(2, name);
        var result = try stmt.execute();
        result.deinit();
    }

    pub fn removePackage(self: *Database, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Delete build logs first
        var log_stmt = try self.conn.prepare("DELETE FROM build_logs WHERE package_name = ?");
        defer log_stmt.deinit();
        try log_stmt.bind(0, name);
        var log_result = try log_stmt.execute();
        log_result.deinit();

        // Delete package
        var pkg_stmt = try self.conn.prepare("DELETE FROM packages WHERE name = ?");
        defer pkg_stmt.deinit();
        try pkg_stmt.bind(0, name);
        var pkg_result = try pkg_stmt.execute();
        pkg_result.deinit();
    }

    pub fn removeSource(self: *Database, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt = try self.conn.prepare("DELETE FROM sources WHERE name = ?");
        defer stmt.deinit();
        try stmt.bind(0, name);
        var result = try stmt.execute();
        result.deinit();
    }

    pub fn getSources(self: *Database, allocator: std.mem.Allocator) ![]Source {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.conn.query("SELECT name, kind, location, package_subpath, repo_name, updated_at, created_at FROM sources ORDER BY name");
        defer result.deinit();

        var sources: std.ArrayList(Source) = .empty;
        errdefer {
            for (sources.items) |s| s.deinit(allocator);
            sources.deinit(allocator);
        }

        while (result.next()) |row| {
            var r = row;
            defer r.deinit();

            try sources.append(allocator, .{
                .name = try allocator.dupe(u8, r.getText(0) orelse ""),
                .kind = SourceKind.fromString(r.getText(1) orelse "local"),
                .location = try allocator.dupe(u8, r.getText(2) orelse ""),
                .package_subpath = try allocator.dupe(u8, r.getText(3) orelse ""),
                .repo_name = try allocator.dupe(u8, r.getText(4) orelse ""),
                .updated_at = try allocator.dupe(u8, r.getText(5) orelse ""),
                .created_at = try allocator.dupe(u8, r.getText(6) orelse ""),
            });
        }

        return sources.toOwnedSlice(allocator);
    }

    pub fn getSource(self: *Database, allocator: std.mem.Allocator, name: []const u8) !?Source {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt = try self.conn.prepare("SELECT name, kind, location, package_subpath, repo_name, updated_at, created_at FROM sources WHERE name = ?");
        defer stmt.deinit();
        try stmt.bind(0, name);
        var exec_result = try stmt.execute();
        defer exec_result.deinit();

        if (exec_result.rows.items.len == 0) return null;

        const row = exec_result.rows.items[0];
        return Source{
            .name = try allocator.dupe(u8, valueToText(row.values[0])),
            .kind = SourceKind.fromString(valueToText(row.values[1])),
            .location = try allocator.dupe(u8, valueToText(row.values[2])),
            .package_subpath = try allocator.dupe(u8, valueToText(row.values[3])),
            .repo_name = try allocator.dupe(u8, valueToText(row.values[4])),
            .updated_at = try allocator.dupe(u8, valueToText(row.values[5])),
            .created_at = try allocator.dupe(u8, valueToText(row.values[6])),
        };
    }

    pub fn getPackages(self: *Database, allocator: std.mem.Allocator) ![]Package {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.conn.query(
            \\SELECT p.name, p.version, p.source_name, s.kind, s.location, s.package_subpath,
            \\       p.repo_name, p.build_status, p.added_at, p.updated_at
            \\FROM packages p
            \\JOIN sources s ON s.name = p.source_name
            \\ORDER BY p.name
        );
        defer result.deinit();

        var packages: std.ArrayList(Package) = .empty;
        errdefer {
            for (packages.items) |p| p.deinit(allocator);
            packages.deinit(allocator);
        }

        while (result.next()) |row| {
            var r = row;
            defer r.deinit();

            try packages.append(allocator, .{
                .name = try allocator.dupe(u8, r.getText(0) orelse ""),
                .version = try allocator.dupe(u8, r.getText(1) orelse "unknown"),
                .source_name = try allocator.dupe(u8, r.getText(2) orelse ""),
                .source_type = try allocator.dupe(u8, r.getText(3) orelse "local"),
                .source_url = try allocator.dupe(u8, r.getText(4) orelse ""),
                .source_subpath = try allocator.dupe(u8, r.getText(5) orelse ""),
                .repo_name = try allocator.dupe(u8, r.getText(6) orelse ""),
                .build_status = try allocator.dupe(u8, r.getText(7) orelse "pending"),
                .added_at = try allocator.dupe(u8, r.getText(8) orelse ""),
                .updated_at = try allocator.dupe(u8, r.getText(9) orelse ""),
            });
        }

        return packages.toOwnedSlice(allocator);
    }

    pub fn getPackage(self: *Database, allocator: std.mem.Allocator, name: []const u8) !?Package {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt = try self.conn.prepare(
            \\SELECT p.name, p.version, p.source_name, s.kind, s.location, s.package_subpath,
            \\       p.repo_name, p.build_status, p.added_at, p.updated_at
            \\FROM packages p
            \\JOIN sources s ON s.name = p.source_name
            \\WHERE p.name = ?
        );
        defer stmt.deinit();
        try stmt.bind(0, name);
        var exec_result = try stmt.execute();
        defer exec_result.deinit();

        if (exec_result.rows.items.len == 0) return null;

        const row = exec_result.rows.items[0];
        return Package{
            .name = try allocator.dupe(u8, valueToText(row.values[0])),
            .version = try allocator.dupe(u8, valueToText(row.values[1])),
            .source_name = try allocator.dupe(u8, valueToText(row.values[2])),
            .source_type = try allocator.dupe(u8, valueToText(row.values[3])),
            .source_url = try allocator.dupe(u8, valueToText(row.values[4])),
            .source_subpath = try allocator.dupe(u8, valueToText(row.values[5])),
            .repo_name = try allocator.dupe(u8, valueToText(row.values[6])),
            .build_status = try allocator.dupe(u8, valueToText(row.values[7])),
            .added_at = try allocator.dupe(u8, valueToText(row.values[8])),
            .updated_at = try allocator.dupe(u8, valueToText(row.values[9])),
        };
    }

    pub fn getPackageCount(self: *Database) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.conn.query("SELECT COUNT(*) FROM packages");
        defer result.deinit();

        if (result.next()) |row| {
            var r = row;
            defer r.deinit();
            const count = r.getInt(0) orelse 0;
            return @intCast(count);
        }
        return 0;
    }

    pub fn cacheMirrorPackage(self: *Database, repo: []const u8, package_name: []const u8, version: []const u8, file_path: []const u8, file_size: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        // Check if exists
        var check_stmt = try self.conn.prepare(
            \\SELECT 1 FROM mirror_cache WHERE repo_name = ? AND package_name = ? AND package_version = ?
        );
        defer check_stmt.deinit();
        try check_stmt.bind(0, repo);
        try check_stmt.bind(1, package_name);
        try check_stmt.bind(2, version);
        var check_result = try check_stmt.execute();
        defer check_result.deinit();

        if (check_result.rows.items.len > 0) {
            // Update
            var stmt = try self.conn.prepare(
                \\UPDATE mirror_cache SET file_path = ?, file_size = ?, cached_at = ?, last_accessed = ?
                \\WHERE repo_name = ? AND package_name = ? AND package_version = ?
            );
            defer stmt.deinit();
            try stmt.bind(0, file_path);
            try stmt.bind(1, @as(i64, @intCast(file_size)));
            try stmt.bind(2, now);
            try stmt.bind(3, now);
            try stmt.bind(4, repo);
            try stmt.bind(5, package_name);
            try stmt.bind(6, version);
            var result = try stmt.execute();
            result.deinit();
        } else {
            // Insert
            var stmt = try self.conn.prepare(
                \\INSERT INTO mirror_cache (repo_name, package_name, package_version, file_path, file_size, cached_at, last_accessed)
                \\VALUES (?, ?, ?, ?, ?, ?, ?)
            );
            defer stmt.deinit();
            try stmt.bind(0, repo);
            try stmt.bind(1, package_name);
            try stmt.bind(2, version);
            try stmt.bind(3, file_path);
            try stmt.bind(4, @as(i64, @intCast(file_size)));
            try stmt.bind(5, now);
            try stmt.bind(6, now);
            var result = try stmt.execute();
            result.deinit();
        }
    }

    pub fn getCachedPackages(self: *Database, allocator: std.mem.Allocator, repo: []const u8) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt = try self.conn.prepare("SELECT DISTINCT package_name FROM mirror_cache WHERE repo_name = ? ORDER BY package_name");
        defer stmt.deinit();
        try stmt.bind(0, repo);
        var exec_result = try stmt.execute();
        defer exec_result.deinit();

        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }

        for (exec_result.rows.items) |row| {
            try names.append(allocator, try allocator.dupe(u8, valueToText(row.values[0])));
        }

        return names.toOwnedSlice(allocator);
    }

    pub fn getMirrorCacheEntries(self: *Database, allocator: std.mem.Allocator, repo: []const u8) ![]MirrorCacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt = try self.conn.prepare(
            \\SELECT package_name, package_version, file_path, file_size FROM mirror_cache WHERE repo_name = ? ORDER BY package_name
        );
        defer stmt.deinit();
        try stmt.bind(0, repo);
        var exec_result = try stmt.execute();
        defer exec_result.deinit();

        var entries: std.ArrayList(MirrorCacheEntry) = .empty;
        errdefer {
            for (entries.items) |e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        for (exec_result.rows.items) |row| {
            try entries.append(allocator, MirrorCacheEntry{
                .package_name = try allocator.dupe(u8, valueToText(row.values[0])),
                .package_version = try allocator.dupe(u8, valueToText(row.values[1])),
                .file_path = try allocator.dupe(u8, valueToText(row.values[2])),
                .file_size = @intCast(valueToInt(row.values[3])),
            });
        }

        return entries.toOwnedSlice(allocator);
    }

    pub fn updateLastAccessed(self: *Database, repo: []const u8, package_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare("UPDATE mirror_cache SET last_accessed = ? WHERE repo_name = ? AND package_name = ?");
        defer stmt.deinit();
        try stmt.bind(0, now);
        try stmt.bind(1, repo);
        try stmt.bind(2, package_name);
        var result = try stmt.execute();
        result.deinit();
    }

    pub fn cleanOldCache(self: *Database, days_old: u32) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Calculate cutoff timestamp (nanoseconds)
        var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded_io.deinit();
        const ts = std.Io.Timestamp.now(threaded_io.io(), .real);
        const now_ns = ts.nanoseconds;
        const cutoff_ns = now_ns - (@as(i96, days_old) * 24 * 60 * 60 * 1_000_000_000);
        const cutoff_str = try std.fmt.allocPrint(self.allocator, "{d}", .{cutoff_ns});
        defer self.allocator.free(cutoff_str);

        var stmt = try self.conn.prepare("DELETE FROM mirror_cache WHERE last_accessed < ?");
        defer stmt.deinit();
        try stmt.bind(0, cutoff_str);
        var result = try stmt.execute();
        defer result.deinit();

        return result.affected_rows;
    }

    pub fn addBuildLog(self: *Database, package_name: []const u8, status: []const u8, log: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare(
            \\INSERT INTO build_logs (package_name, status, build_log, finished_at)
            \\VALUES (?, ?, ?, ?)
        );
        defer stmt.deinit();
        try stmt.bind(0, package_name);
        try stmt.bind(1, status);
        try stmt.bind(2, log);
        try stmt.bind(3, now);
        var result = try stmt.execute();
        result.deinit();
    }

    pub fn getBuildLogs(self: *Database, allocator: std.mem.Allocator, package_name: ?[]const u8) ![]BuildLog {
        self.mutex.lock();
        defer self.mutex.unlock();

        var logs: std.ArrayList(BuildLog) = .empty;
        errdefer {
            for (logs.items) |l| l.deinit(allocator);
            logs.deinit(allocator);
        }

        if (package_name) |name| {
            var stmt = try self.conn.prepare(
                \\SELECT package_name, status, build_log, finished_at FROM build_logs
                \\WHERE package_name = ? ORDER BY finished_at DESC
            );
            defer stmt.deinit();
            try stmt.bind(0, name);
            var exec_result = try stmt.execute();
            defer exec_result.deinit();

            for (exec_result.rows.items) |row| {
                try logs.append(allocator, .{
                    .package_name = try allocator.dupe(u8, valueToText(row.values[0])),
                    .status = try allocator.dupe(u8, valueToText(row.values[1])),
                    .build_log = try allocator.dupe(u8, valueToText(row.values[2])),
                    .finished_at = try allocator.dupe(u8, valueToText(row.values[3])),
                });
            }
        } else {
            var result = try self.conn.query("SELECT package_name, status, build_log, finished_at FROM build_logs ORDER BY finished_at DESC");
            defer result.deinit();

            while (result.next()) |row| {
                var r = row;
                defer r.deinit();

                try logs.append(allocator, .{
                    .package_name = try allocator.dupe(u8, r.getText(0) orelse ""),
                    .status = try allocator.dupe(u8, r.getText(1) orelse ""),
                    .build_log = try allocator.dupe(u8, r.getText(2) orelse ""),
                    .finished_at = try allocator.dupe(u8, r.getText(3) orelse ""),
                });
            }
        }

        return logs.toOwnedSlice(allocator);
    }

    // ==========================================================================
    // Security Advisory Methods
    // ==========================================================================

    pub fn upsertAdvisory(
        self: *Database,
        advisory_id: []const u8,
        package_name: []const u8,
        severity: []const u8,
        vuln_type: []const u8,
        affected_version: []const u8,
        fixed_version: ?[]const u8,
        status: []const u8,
        cve_ids: []const u8,
        reference_url: ?[]const u8,
        published_at: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare(
            \\INSERT INTO security_advisories
            \\    (advisory_id, package_name, severity, vuln_type, affected_version,
            \\     fixed_version, status, cve_ids, reference_url, published_at, updated_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(advisory_id) DO UPDATE SET
            \\    package_name = excluded.package_name,
            \\    severity = excluded.severity,
            \\    vuln_type = excluded.vuln_type,
            \\    affected_version = excluded.affected_version,
            \\    fixed_version = excluded.fixed_version,
            \\    status = excluded.status,
            \\    cve_ids = excluded.cve_ids,
            \\    reference_url = excluded.reference_url,
            \\    published_at = excluded.published_at,
            \\    updated_at = excluded.updated_at
        );
        defer stmt.deinit();

        const empty: []const u8 = "";
        try stmt.bind(0, advisory_id);
        try stmt.bind(1, package_name);
        try stmt.bind(2, severity);
        try stmt.bind(3, vuln_type);
        try stmt.bind(4, affected_version);
        if (fixed_version) |fv| {
            try stmt.bind(5, fv);
        } else {
            try stmt.bind(5, empty);
        }
        try stmt.bind(6, status);
        try stmt.bind(7, cve_ids);
        if (reference_url) |url| {
            try stmt.bind(8, url);
        } else {
            try stmt.bind(8, empty);
        }
        try stmt.bind(9, published_at);
        try stmt.bind(10, now);

        var result = try stmt.execute();
        result.deinit();
    }

    pub fn getAdvisories(self: *Database, allocator: std.mem.Allocator) ![]Advisory {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.conn.query(
            \\SELECT advisory_id, package_name, severity, vuln_type, affected_version,
            \\       fixed_version, status, cve_ids, reference_url, published_at, updated_at
            \\FROM security_advisories
            \\ORDER BY published_at DESC
        );
        defer result.deinit();

        var advisories: std.ArrayList(Advisory) = .empty;
        errdefer {
            for (advisories.items) |a| a.deinit(allocator);
            advisories.deinit(allocator);
        }

        while (result.next()) |row| {
            var r = row;
            defer r.deinit();

            const fixed_ver = r.getText(5);
            const ref_url = r.getText(8);

            try advisories.append(allocator, .{
                .advisory_id = try allocator.dupe(u8, r.getText(0) orelse ""),
                .package_name = try allocator.dupe(u8, r.getText(1) orelse ""),
                .severity = Severity.fromString(r.getText(2) orelse "Unknown"),
                .vuln_type = try allocator.dupe(u8, r.getText(3) orelse ""),
                .affected_version = try allocator.dupe(u8, r.getText(4) orelse ""),
                .fixed_version = if (fixed_ver) |fv| try allocator.dupe(u8, fv) else null,
                .status = try allocator.dupe(u8, r.getText(6) orelse ""),
                .cve_ids = try allocator.dupe(u8, r.getText(7) orelse "[]"),
                .reference_url = if (ref_url) |url| try allocator.dupe(u8, url) else null,
                .published_at = try allocator.dupe(u8, r.getText(9) orelse ""),
                .updated_at = try allocator.dupe(u8, r.getText(10) orelse ""),
            });
        }

        return advisories.toOwnedSlice(allocator);
    }

    pub fn getAdvisoriesForPackage(self: *Database, allocator: std.mem.Allocator, package_name: []const u8) ![]Advisory {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt = try self.conn.prepare(
            \\SELECT advisory_id, package_name, severity, vuln_type, affected_version,
            \\       fixed_version, status, cve_ids, reference_url, published_at, updated_at
            \\FROM security_advisories
            \\WHERE package_name = ?
            \\ORDER BY published_at DESC
        );
        defer stmt.deinit();
        try stmt.bind(0, package_name);

        var exec_result = try stmt.execute();
        defer exec_result.deinit();

        var advisories: std.ArrayList(Advisory) = .empty;
        errdefer {
            for (advisories.items) |a| a.deinit(allocator);
            advisories.deinit(allocator);
        }

        for (exec_result.rows.items) |row| {
            const fixed_ver = valueToText(row.values[5]);
            const ref_url = valueToText(row.values[8]);

            try advisories.append(allocator, .{
                .advisory_id = try allocator.dupe(u8, valueToText(row.values[0])),
                .package_name = try allocator.dupe(u8, valueToText(row.values[1])),
                .severity = Severity.fromString(valueToText(row.values[2])),
                .vuln_type = try allocator.dupe(u8, valueToText(row.values[3])),
                .affected_version = try allocator.dupe(u8, valueToText(row.values[4])),
                .fixed_version = if (fixed_ver.len > 0) try allocator.dupe(u8, fixed_ver) else null,
                .status = try allocator.dupe(u8, valueToText(row.values[6])),
                .cve_ids = try allocator.dupe(u8, valueToText(row.values[7])),
                .reference_url = if (ref_url.len > 0) try allocator.dupe(u8, ref_url) else null,
                .published_at = try allocator.dupe(u8, valueToText(row.values[9])),
                .updated_at = try allocator.dupe(u8, valueToText(row.values[10])),
            });
        }

        return advisories.toOwnedSlice(allocator);
    }

    pub fn getAdvisoryCount(self: *Database) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.conn.query("SELECT COUNT(*) FROM security_advisories");
        defer result.deinit();

        if (result.next()) |row| {
            var r = row;
            defer r.deinit();
            const count = r.getInt(0) orelse 0;
            return @intCast(count);
        }
        return 0;
    }

    // ==========================================================================
    // Package Security Status Methods
    // ==========================================================================

    pub fn upsertPackageSecurityStatus(
        self: *Database,
        package_name: []const u8,
        repo_name: []const u8,
        hosted_version: []const u8,
        advisory_status: AdvisoryStatus,
        stale_status: StaleStatus,
        signature_status: SignatureStatus,
        advisory_match_count: u32,
        highest_severity: ?Severity,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare(
            \\INSERT INTO security_package_status
            \\    (package_name, repo_name, hosted_version, advisory_status, stale_status,
            \\     signature_status, advisory_match_count, highest_severity, last_scanned_at, updated_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(package_name) DO UPDATE SET
            \\    repo_name = excluded.repo_name,
            \\    hosted_version = excluded.hosted_version,
            \\    advisory_status = excluded.advisory_status,
            \\    stale_status = excluded.stale_status,
            \\    signature_status = excluded.signature_status,
            \\    advisory_match_count = excluded.advisory_match_count,
            \\    highest_severity = excluded.highest_severity,
            \\    last_scanned_at = excluded.last_scanned_at,
            \\    updated_at = excluded.updated_at
        );
        defer stmt.deinit();

        const empty: []const u8 = "";
        try stmt.bind(0, package_name);
        try stmt.bind(1, repo_name);
        try stmt.bind(2, hosted_version);
        try stmt.bind(3, advisory_status.asString());
        try stmt.bind(4, stale_status.asString());
        try stmt.bind(5, signature_status.asString());
        try stmt.bind(6, @as(i64, @intCast(advisory_match_count)));
        if (highest_severity) |s| {
            try stmt.bind(7, s.asString());
        } else {
            try stmt.bind(7, empty);
        }
        try stmt.bind(8, now);
        try stmt.bind(9, now);

        var result = try stmt.execute();
        result.deinit();
    }

    pub fn getPackageSecurityStatus(self: *Database, allocator: std.mem.Allocator, package_name: []const u8) !?PackageSecurityStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt = try self.conn.prepare(
            \\SELECT package_name, repo_name, hosted_version, advisory_status, stale_status,
            \\       signature_status, advisory_match_count, highest_severity, last_scanned_at, updated_at
            \\FROM security_package_status
            \\WHERE package_name = ?
        );
        defer stmt.deinit();
        try stmt.bind(0, package_name);

        var exec_result = try stmt.execute();
        defer exec_result.deinit();

        if (exec_result.rows.items.len == 0) return null;

        const row = exec_result.rows.items[0];
        const last_scanned = valueToText(row.values[8]);
        const severity_str = valueToText(row.values[7]);

        return PackageSecurityStatus{
            .package_name = try allocator.dupe(u8, valueToText(row.values[0])),
            .repo_name = try allocator.dupe(u8, valueToText(row.values[1])),
            .hosted_version = try allocator.dupe(u8, valueToText(row.values[2])),
            .advisory_status = AdvisoryStatus.fromString(valueToText(row.values[3])),
            .stale_status = StaleStatus.fromString(valueToText(row.values[4])),
            .signature_status = SignatureStatus.fromString(valueToText(row.values[5])),
            .advisory_match_count = @intCast(valueToInt(row.values[6])),
            .highest_severity = if (severity_str.len > 0) Severity.fromString(severity_str) else null,
            .last_scanned_at = if (last_scanned.len > 0) try allocator.dupe(u8, last_scanned) else null,
            .updated_at = try allocator.dupe(u8, valueToText(row.values[9])),
        };
    }

    pub fn getAllPackageSecurityStatuses(self: *Database, allocator: std.mem.Allocator) ![]PackageSecurityStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.conn.query(
            \\SELECT package_name, repo_name, hosted_version, advisory_status, stale_status,
            \\       signature_status, advisory_match_count, highest_severity, last_scanned_at, updated_at
            \\FROM security_package_status
            \\ORDER BY package_name
        );
        defer result.deinit();

        var statuses: std.ArrayList(PackageSecurityStatus) = .empty;
        errdefer {
            for (statuses.items) |s| s.deinit(allocator);
            statuses.deinit(allocator);
        }

        while (result.next()) |row| {
            var r = row;
            defer r.deinit();

            const last_scanned = r.getText(8);
            const severity_str = r.getText(7);

            try statuses.append(allocator, .{
                .package_name = try allocator.dupe(u8, r.getText(0) orelse ""),
                .repo_name = try allocator.dupe(u8, r.getText(1) orelse ""),
                .hosted_version = try allocator.dupe(u8, r.getText(2) orelse ""),
                .advisory_status = AdvisoryStatus.fromString(r.getText(3) orelse "unscanned"),
                .stale_status = StaleStatus.fromString(r.getText(4) orelse "unknown"),
                .signature_status = SignatureStatus.fromString(r.getText(5) orelse "unknown"),
                .advisory_match_count = @intCast(r.getInt(6) orelse 0),
                .highest_severity = if (severity_str) |s| Severity.fromString(s) else null,
                .last_scanned_at = if (last_scanned) |ts| try allocator.dupe(u8, ts) else null,
                .updated_at = try allocator.dupe(u8, r.getText(9) orelse ""),
            });
        }

        return statuses.toOwnedSlice(allocator);
    }

    // ==========================================================================
    // Security Sync Run Methods
    // ==========================================================================

    pub fn recordSyncRunStart(self: *Database, kind: []const u8) !i64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare(
            \\INSERT INTO security_sync_runs (kind, status, started_at)
            \\VALUES (?, 'running', ?)
        );
        defer stmt.deinit();
        try stmt.bind(0, kind);
        try stmt.bind(1, now);

        var result = try stmt.execute();
        result.deinit();

        // Get the last inserted row ID
        var id_result = try self.conn.query("SELECT last_insert_rowid()");
        defer id_result.deinit();

        if (id_result.next()) |row| {
            var r = row;
            defer r.deinit();
            return r.getInt(0) orelse 0;
        }
        return 0;
    }

    pub fn recordSyncRunComplete(self: *Database, run_id: i64, status: []const u8, details: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try nowTimestamp(self.allocator);
        defer self.allocator.free(now);

        var stmt = try self.conn.prepare(
            \\UPDATE security_sync_runs
            \\SET status = ?, finished_at = ?, details = ?
            \\WHERE id = ?
        );
        defer stmt.deinit();
        const empty: []const u8 = "";
        try stmt.bind(0, status);
        try stmt.bind(1, now);
        // Bind details or empty string if null
        if (details) |d| {
            try stmt.bind(2, d);
        } else {
            try stmt.bind(2, empty);
        }
        try stmt.bind(3, run_id);

        var result = try stmt.execute();
        result.deinit();
    }

    pub fn getTableNames(self: *Database, allocator: std.mem.Allocator) ![][]const u8 {
        _ = self;
        const names = [_][]const u8{ "sources", "packages", "build_logs", "mirror_cache", "schema_version", "security_advisories", "security_package_status", "security_sync_runs" };
        var out = try allocator.alloc([]const u8, names.len);
        for (names, 0..) |name, i| out[i] = try allocator.dupe(u8, name);
        return out;
    }

    pub fn getTableSchema(self: *Database, allocator: std.mem.Allocator, table_name: []const u8) ![]ColumnInfo {
        _ = self;
        if (std.mem.eql(u8, table_name, "sources")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "name", .data_type = "TEXT", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "kind", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "location", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "package_subpath", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "repo_name", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "created_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "updated_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
            });
        }
        if (std.mem.eql(u8, table_name, "packages")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "name", .data_type = "TEXT", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "version", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "source_name", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "repo_name", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "build_status", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "added_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "updated_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
            });
        }
        if (std.mem.eql(u8, table_name, "build_logs")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "id", .data_type = "INTEGER", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "package_name", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "status", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "build_log", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "finished_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
            });
        }
        if (std.mem.eql(u8, table_name, "mirror_cache")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "repo_name", .data_type = "TEXT", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "package_name", .data_type = "TEXT", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "package_version", .data_type = "TEXT", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "file_path", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "file_size", .data_type = "INTEGER", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "cached_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "last_accessed", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
            });
        }
        if (std.mem.eql(u8, table_name, "schema_version")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "version", .data_type = "INTEGER", .is_primary_key = false, .is_nullable = false, .has_default = false },
            });
        }
        if (std.mem.eql(u8, table_name, "security_advisories")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "advisory_id", .data_type = "TEXT", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "package_name", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "severity", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "vuln_type", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "affected_version", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "fixed_version", .data_type = "TEXT", .is_primary_key = false, .is_nullable = true, .has_default = false },
                .{ .name = "status", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "cve_ids", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "reference_url", .data_type = "TEXT", .is_primary_key = false, .is_nullable = true, .has_default = false },
                .{ .name = "published_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "updated_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
            });
        }
        if (std.mem.eql(u8, table_name, "security_package_status")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "package_name", .data_type = "TEXT", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "repo_name", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "hosted_version", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "advisory_status", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "stale_status", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "signature_status", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "advisory_match_count", .data_type = "INTEGER", .is_primary_key = false, .is_nullable = false, .has_default = true },
                .{ .name = "highest_severity", .data_type = "TEXT", .is_primary_key = false, .is_nullable = true, .has_default = false },
                .{ .name = "last_scanned_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = true, .has_default = false },
                .{ .name = "updated_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
            });
        }
        if (std.mem.eql(u8, table_name, "security_sync_runs")) {
            return cloneColumnInfo(allocator, &.{
                .{ .name = "id", .data_type = "INTEGER", .is_primary_key = true, .is_nullable = false, .has_default = false },
                .{ .name = "kind", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "status", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "started_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = false, .has_default = false },
                .{ .name = "finished_at", .data_type = "TEXT", .is_primary_key = false, .is_nullable = true, .has_default = false },
                .{ .name = "details", .data_type = "TEXT", .is_primary_key = false, .is_nullable = true, .has_default = false },
            });
        }
        return try allocator.alloc(ColumnInfo, 0);
    }

    pub fn healthCheck(self: *Database) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.conn.query("SELECT version FROM schema_version LIMIT 1");
        defer result.deinit();

        if (result.next()) |row| {
            var r = row;
            defer r.deinit();
            const version = r.getInt(0) orelse 0;
            return version == SCHEMA_VERSION;
        }
        return false;
    }
};

fn valueToText(value: zqlite.storage.Value) []const u8 {
    return switch (value) {
        .Text => |t| t,
        .Integer => "",
        else => "",
    };
}

fn valueToInt(value: zqlite.storage.Value) i64 {
    return switch (value) {
        .Integer => |i| i,
        else => 0,
    };
}

fn nowTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const ts = std.Io.Timestamp.now(threaded_io.io(), .real);
    return std.fmt.allocPrint(allocator, "{d}", .{ts.nanoseconds});
}

fn cloneColumnInfo(allocator: std.mem.Allocator, template: []const ColumnInfo) ![]ColumnInfo {
    var out = try allocator.alloc(ColumnInfo, template.len);
    for (template, 0..) |col, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, col.name),
            .data_type = try allocator.dupe(u8, col.data_type),
            .is_primary_key = col.is_primary_key,
            .is_nullable = col.is_nullable,
            .has_default = col.has_default,
        };
    }
    return out;
}
