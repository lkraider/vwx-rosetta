//! vwx — the Vectorworks automation commands that the rosetta drivers call.
//!
//! The modules under src/ come from vwx/src at commit 6970c341 of the old repository. This file
//! replaces its main.zig, which also held the document decoder and the DXF writer.

const std = @import("std");
const native_ui_diagnostics = @import("native_ui_diagnostics.zig");
const native_ui_runtime = @import("native_ui_runtime.zig");
const native_script_dispatch = @import("native_script_dispatch.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage_text =
    \\usage: vwx <command> [args]
    \\
    \\commands:
    \\  info <file.vwx>       format version, header size, version string and build
    \\  ui-dialog             read or press the front dialog of a running Vectorworks
    \\  ui-menu               list or press a menu item of a running Vectorworks
    \\  ui-export-control     read or set a control of an export options dialog
    \\  native-script-send    run a Python program inside a running Vectorworks
    \\
    \\Each command except info prints its own usage when it gets no arguments.
    \\
;

const Route = *const fn (Allocator, Io, []const []const u8, *Io.Writer) u8;

fn route(cmd: []const u8) ?Route {
    if (std.mem.eql(u8, cmd, "ui-dialog")) return native_ui_diagnostics.runDialogCli;
    if (std.mem.eql(u8, cmd, "ui-menu")) return native_ui_diagnostics.runMenuCli;
    if (std.mem.eql(u8, cmd, "ui-export-control")) return native_ui_runtime.runExportControlCli;
    if (std.mem.eql(u8, cmd, "native-script-send")) return native_script_dispatch.runCli;
    return null;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    const cmd = args.next() orelse return usage(io);
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        Io.File.stdout().writeStreamingAll(io, usage_text) catch {};
        return;
    }

    const run: Route = route(cmd) orelse if (std.mem.eql(u8, cmd, "info")) info else return usage(io);

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(init.gpa);
    while (args.next()) |x| try list.append(init.gpa, x);

    var buf: [1 << 16]u8 = undefined;
    // writerStreaming appends at the file position. Io.File.writer writes at offset 0 and
    // overwrites a file that the caller opened with `>>`.
    var w = Io.File.stdout().writerStreaming(io, &buf);
    const status = run(init.gpa, io, list.items, &w.interface);
    w.interface.flush() catch {};
    if (status != 0) std.process.exit(status);
}

fn usage(io: Io) void {
    Io.File.stderr().writeStreamingAll(io, usage_text) catch {};
    std.process.exit(2);
}

fn info(gpa: Allocator, io: Io, args: []const []const u8, out: *Io.Writer) u8 {
    if (args.len != 1) {
        Io.File.stderr().writeStreamingAll(io, "usage: vwx info <file.vwx>\n") catch {};
        return 2;
    }
    const data = Io.Dir.cwd().readFileAlloc(io, args[0], gpa, .unlimited) catch |err| {
        out.print("vwx: error: {s}: {s}\n", .{ args[0], @errorName(err) }) catch {};
        return 1;
    };
    defer gpa.free(data);
    const h = Header.parse(data) catch {
        out.print("vwx: error: {s}: {d} bytes is shorter than a document header\n", .{ args[0], data.len }) catch {};
        return 1;
    };
    out.print("file            {d} bytes\n", .{data.len}) catch return 1;
    out.print("format version  0x{X:0>8}\n", .{h.format_version}) catch return 1;
    out.print("header size     {d}\n", .{h.header_size}) catch return 1;
    out.print("version string  {s}\n", .{h.version_string}) catch return 1;
    out.print("build           {s}\n", .{h.build}) catch return 1;
    return 0;
}

const Header = struct {
    format_version: u32,
    header_size: u32,
    version_string: []const u8,
    build: []const u8,

    fn parse(d: []const u8) !Header {
        if (d.len < 0x100) return error.FileTooSmall;
        return .{
            .format_version = readU32(d, 0),
            .header_size = readU32(d, 8),
            .version_string = readLenPrefixed(d, 12),
            .build = readBuild(d),
        };
    }
};

fn readU32(d: []const u8, off: usize) u32 {
    if (off + 4 > d.len) return 0;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

fn readLenPrefixed(d: []const u8, off: usize) []const u8 {
    if (off + 2 > d.len) return "";
    const len = std.mem.readInt(u16, d[off..][0..2], .big);
    if (off + 2 + @as(usize, len) > d.len) return "";
    const raw = d[off + 2 ..][0..len];
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return raw[0..end];
}

fn readBuild(d: []const u8) []const u8 {
    const needle = "BUILD: ";
    const at = std.mem.indexOf(u8, d[0..@min(d.len, 512)], needle) orelse return "";
    const rest = d[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse 0;
    return rest[0..end];
}

test "Header.parse reads the big-endian fields and the build string" {
    var d = [_]u8{0} ** 0x100;
    std.mem.writeInt(u32, d[0..4], 0x0000_0024, .big);
    std.mem.writeInt(u32, d[8..12], 512, .big);
    std.mem.writeInt(u16, d[12..14], 4, .big);
    @memcpy(d[14..18], "2027");
    @memcpy(d[32..45], "BUILD: 885363");
    const h = try Header.parse(&d);
    try std.testing.expectEqual(@as(u32, 0x24), h.format_version);
    try std.testing.expectEqual(@as(u32, 512), h.header_size);
    try std.testing.expectEqualStrings("2027", h.version_string);
    try std.testing.expectEqualStrings("885363", h.build);
}

test "Header.parse refuses a file shorter than the header" {
    try std.testing.expectError(error.FileTooSmall, Header.parse(&[_]u8{0} ** 16));
}
