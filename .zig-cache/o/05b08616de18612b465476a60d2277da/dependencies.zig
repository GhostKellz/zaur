pub const packages = struct {
    pub const @"zqlite-1.3.0-0Cdu4jPSEADbt8F1LhbHB0CvdaCUEHlj9wvcToMTVjf2" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zqlite-1.3.0-0Cdu4jPSEADbt8F1LhbHB0CvdaCUEHlj9wvcToMTVjf2";
        pub const build_zig = @import("zqlite-1.3.0-0Cdu4jPSEADbt8F1LhbHB0CvdaCUEHlj9wvcToMTVjf2");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zsync", "zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_" },
        };
    };
    pub const @"zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_";
        pub const build_zig = @import("zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zsync", "zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_" },
    .{ "zqlite", "zqlite-1.3.0-0Cdu4jPSEADbt8F1LhbHB0CvdaCUEHlj9wvcToMTVjf2" },
};
