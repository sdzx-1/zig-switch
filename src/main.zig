const std = @import("std");
const SemanticVersion = std.SemanticVersion;
const troupe = @import("troupe");
const Data = troupe.Data;

pub fn main() !void {
    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_instance.allocator();

    const stdin = std.fs.File.stdin();
    var tmp_buf: [100]u8 = undefined;
    var stdin_reader = stdin.reader(&tmp_buf);
    const reader = &stdin_reader.interface;

    const dir = try std.fs.openDirAbsolute(base_path, .{ .iterate = true });

    var sdzx_ctx: SdzxCtx = .{
        .collect = .empty,
        .gpa = gpa,
        .dir = dir,
        .stdin = reader,
        .mcurrent = null,
    };

    try Runner.runProtocol(.sdzx, undefined, undefined, curr_id, &sdzx_ctx);
}

const base_path: []const u8 = "/home/hk/zig";

const Info = struct {
    sv: SemanticVersion,
    duration: i64,
};

const Collect = std.ArrayList(Info);

const Role = enum { sdzx };

const SdzxCtx = struct {
    gpa: std.mem.Allocator,
    collect: Collect,
    dir: std.fs.Dir,
    stdin: *std.Io.Reader,
    mcurrent: ?[]const u8,

    pub fn print_collect(self: *const @This()) !void {
        for (self.collect.items, 0..) |item, i| {
            const str0 = try std.fmt.allocPrint(self.gpa, "{f}", .{item.sv});
            const str1 =
                blk: {
                    if (self.mcurrent) |curr| {
                        if (std.mem.eql(u8, curr, str0)) break :blk "*";
                    }
                    break :blk " ";
                };

            std.debug.print("{d}: {s} {s: <25} {D}", .{ i, str1, str0, item.duration });
            std.debug.print("\n", .{});
        }
    }
};

const Context = struct {
    sdzx: type = SdzxCtx,
};

fn sdzx_info(name: []const u8) troupe.ProtocolInfo("sdzx", Role, Context{}, &.{.sdzx}, &.{}) {
    return .{ .name = name, .sender = .sdzx, .receiver = &.{} };
}

pub const EnterFsmState = Preprocess;

pub const Runner = troupe.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

const Preprocess = union(enum) {
    select: Data(void, Select),

    pub const info = sdzx_info("Preprocess");

    pub fn process(ctx: *SdzxCtx) !@This() {
        var iter = ctx.dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const mstr = try get_version(ctx.gpa, try ctx.gpa.dupe(u8, entry.name));
                if (mstr) |str| {
                    if (!std.mem.eql(u8, entry.name, str)) {
                        std.debug.print("not equal \n", .{});
                        const old_path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ base_path, entry.name });
                        const new_path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ base_path, str });
                        std.debug.print("rename: {s} to {s}\n", .{ old_path, new_path });
                        try std.fs.renameAbsolute(old_path, new_path);
                    }
                    const zig_file_path = try std.fmt.allocPrint(ctx.gpa, "{s}/bin/zig", .{str});
                    const zig_file = try ctx.dir.openFile(zig_file_path, .{});
                    const st: i128 = (try zig_file.stat()).ctime;
                    const curr_time = std.time.nanoTimestamp();
                    const diff: i64 = @intCast(curr_time - st);

                    const info_: Info = .{ .sv = try SemanticVersion.parse(str), .duration = diff };
                    try ctx.collect.append(ctx.gpa, info_);
                }
            }
        }

        std.sort.insertion(Info, ctx.collect.items, {}, compare_version);

        return .select;
    }
};

const Select = union(enum) {
    loop: Data(void, @This()),
    set_version: Data(void, SetVersion),
    delete: Data(void, Delect),
    exit: Data(void, troupe.Exit),

    pub const info = sdzx_info("Select");

    pub fn process(ctx: *SdzxCtx) !@This() {
        ctx.mcurrent = try get_current(ctx.gpa);
        try ctx.print_collect();

        std.debug.print("\ns: SetVersion, d: Delete, q: Exit:\n", .{});
        if (try ctx.stdin.takeDelimiter('\n')) |str| {
            if (std.mem.eql(u8, str, "s")) {
                return .set_version;
            } else if (std.mem.eql(u8, str, "q")) {
                std.debug.print("Exit zig-switch!\n", .{});
                return .exit;
            } else if (std.mem.eql(u8, str, "d")) {
                return .delete;
            }
        }
        return .loop;
    }
};

const SetVersion = union(enum) {
    loop: Data(void, @This()),
    back: Data(void, Select),

    pub const info = sdzx_info("SetVersion");

    pub fn process(ctx: *SdzxCtx) !@This() {
        std.debug.print("\nInput index:\n", .{});
        if (try ctx.stdin.takeDelimiter('\n')) |str| {
            if (std.mem.eql(u8, str, "q")) {
                return .back;
            } else {
                if (std.fmt.parseInt(usize, str, 10)) |idx| {
                    if (idx < ctx.collect.items.len) {
                        //set new zig link
                        if (ctx.mcurrent) |_| {
                            try std.fs.deleteFileAbsolute("/home/hk/.local/bin/zig");
                            const info_ = ctx.collect.items[idx];
                            const target = try std.fmt.allocPrint(ctx.gpa, "{s}/{f}/bin/zig", .{ base_path, info_.sv });
                            try std.fs.symLinkAbsolute(target, "/home/hk/.local/bin/zig", .{});

                            std.debug.print("set success!\n", .{});
                            return .back;
                        }
                    } else {
                        std.debug.print("idx too large\n", .{});
                    }
                } else |parse_error| {
                    std.debug.print("parse error: {any}\n", .{parse_error});
                }
            }
        }
        return .loop;
    }
};

const Delect = union(enum) {
    loop: Data(void, @This()),
    back: Data(void, Select),

    pub const info = sdzx_info("Delect");

    pub fn process(ctx: *SdzxCtx) !@This() {
        std.debug.print("\nInput index:\n", .{});
        if (try ctx.stdin.takeDelimiter('\n')) |str| {
            if (std.mem.eql(u8, str, "q")) {
                return .back;
            } else {
                if (std.fmt.parseInt(usize, str, 10)) |idx| {
                    if (idx < ctx.collect.items.len) {
                        const info_ = ctx.collect.items[idx];
                        const dest = try std.fmt.allocPrint(ctx.gpa, "{s}/{f}", .{ base_path, info_.sv });
                        try std.fs.deleteTreeAbsolute(dest);
                        _ = ctx.collect.orderedRemove(idx);

                        std.debug.print("delete success!\n", .{});
                        return .back;
                    } else {
                        std.debug.print("idx too large\n", .{});
                    }
                } else |parse_error| {
                    std.debug.print("parse error: {any}\n", .{parse_error});
                }
            }
        }
        return .loop;
    }
};

fn get_version(gpa: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const zig = try std.fmt.allocPrint(gpa, "{s}/{s}/bin/zig", .{ base_path, name });
    var child = std.process.Child.init(&.{ zig, "version" }, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    try child.collectOutput(gpa, &stdout, &stderr, 1024 * 10);

    if (stderr.items.len != 0) {
        return null;
    } else {
        return stdout.items[0 .. stdout.items.len - 1];
    }
}

fn compare_version(_: void, l: Info, r: Info) bool {
    return switch (l.sv.order(r.sv)) {
        .lt => true,
        .eq => true,
        .gt => false,
    };
}

fn get_current(gpa: std.mem.Allocator) !?[]const u8 {
    var child = std.process.Child.init(&.{ "zig", "version" }, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    try child.collectOutput(gpa, &stdout, &stderr, 1024 * 10);

    if (stderr.items.len != 0) {
        return null;
    } else {
        return stdout.items[0 .. stdout.items.len - 1];
    }
}
