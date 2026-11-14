//! CLI: mysqlbinlog-zig --file <path> [--format jsonl]
const std = @import("std");
const parser = @import("parser.zig");

fn usage() void {
    std.debug.print("Usage: mysqlbinlog-zig --file <path> [--format jsonl]\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var path: ?[]const u8 = null;
    var fmt: []const u8 = "jsonl";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            usage();
            return;
        } else if (std.mem.eql(u8, a, "--file") and i + 1 < args.len) {
            i += 1;
            path = args[i];
        } else if (std.mem.eql(u8, a, "--format") and i + 1 < args.len) {
            i += 1;
            fmt = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            usage();
            std.process.exit(2);
        }
    }
    if (path == null) {
        usage();
        std.process.exit(2);
    }
    if (!std.mem.eql(u8, fmt, "jsonl")) {
        std.debug.print("only --format jsonl is supported\n", .{});
        std.process.exit(2);
    }

    const data = std.fs.cwd().readFileAlloc(alloc, path.?, 64 * 1024 * 1024) catch |e| {
        std.debug.print("cannot open file: {s}: {s}\n", .{ path.?, @errorName(e) });
        std.process.exit(2);
    };
    defer alloc.free(data);

    const out = parser.parseBuffer(alloc, data) catch |e| {
        std.debug.print("parse failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer alloc.free(out);

    // std.posix.write is stable across Zig 0.13/0.14.
    var off: usize = 0;
    while (off < out.len) {
        off += try std.posix.write(1, out[off..]);
    }
}
