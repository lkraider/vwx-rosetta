//! PID-targeted experimental dispatch through the VectorScript engine.
//! AppleEvent acknowledgement is separate from the bridge completion files.
const std = @import("std");
const builtin = @import("builtin");
const opdir = @import("rosetta_opdir.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const usage =
    \\usage: vwx native-script-send --program PATH [--wrap-only]
    \\       vwx native-script-send --pid N --expected-executable PATH --program PATH
    \\                              --operator-authorized [--timeout-ms N]
    \\       vwx native-script-send --pid N --expected-executable PATH --open-document PATH
    \\                              --operator-authorized [--timeout-ms N]
    \\Runs Python through VWapDoVS or queues a PID-targeted open-document event.
    \\Script files run inside PythonBeginContext/PythonEndContext. This route is experimental.
    \\No application is launched or closed. Files must be regular with one link.
    \\Scripts are limited to 1 MiB. Documents are limited to 1 GiB.
    \\Open events use no-reply delivery. The caller must verify the active document path.
    \\Script timeout is unknown and returns 0 so the caller can observe completion files.
    \\Neither delivery nor acknowledgement proves operation completion.
    \\Exit 1 refused or transport error. Exit 2 usage. Default timeout is 12000 ms.
    \\
;

const Config = struct {
    pid: i32 = 0,
    executable: []const u8 = "",
    program: []const u8 = "",
    open_document: bool = false,
    authorized: bool = false,
    wrap_only: bool = false,
    timeout_ms: u32 = 12000,
};

fn parse(args: []const []const u8) !Config {
    var c: Config = .{};
    var seen: u8 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const k = args[i];
        const bit: u8 = if (std.mem.eql(u8, k, "--pid")) 1 else if (std.mem.eql(u8, k, "--expected-executable")) 2 else if (std.mem.eql(u8, k, "--program")) 4 else if (std.mem.eql(u8, k, "--operator-authorized")) 8 else if (std.mem.eql(u8, k, "--wrap-only")) 16 else if (std.mem.eql(u8, k, "--timeout-ms")) 32 else if (std.mem.eql(u8, k, "--open-document")) 64 else return error.BadArgument;
        if (seen & bit != 0) return error.DuplicateArgument;
        seen |= bit;
        if (bit == 8) {
            c.authorized = true;
            continue;
        }
        if (bit == 16) {
            c.wrap_only = true;
            continue;
        }
        i += 1;
        if (i >= args.len) return error.MissingValue;
        const v = args[i];
        switch (bit) {
            1 => {
                c.pid = try std.fmt.parseInt(i32, v, 10);
                if (c.pid <= 0) return error.BadPid;
            },
            2 => c.executable = v,
            4 => c.program = v,
            64 => {
                c.program = v;
                c.open_document = true;
            },
            32 => {
                c.timeout_ms = try std.fmt.parseInt(u32, v, 10);
                if (c.timeout_ms == 0 or c.timeout_ms > 120000) return error.BadTimeout;
            },
            else => unreachable,
        }
    }
    if ((seen & 4 != 0 and seen & 64 != 0) or (c.open_document and c.wrap_only)) return error.BadCombination;
    if (!validPath(c.program)) return error.BadProgramPath;
    if (!c.wrap_only and (c.pid <= 0 or !validPath(c.executable))) return error.MissingIdentity;
    return c;
}

fn validPath(p: []const u8) bool {
    if (p.len == 0 or p.len > 4096 or p[0] != '/') return false;
    for (p) |ch| if (ch == 0 or ch < 32) return false;
    return std.unicode.utf8ValidateSlice(p);
}

pub fn wrap(a: Allocator, path: []const u8) ![]const u8 {
    if (!validPath(path)) return error.BadProgramPath;
    var j: Io.Writer.Allocating = .init(a);
    defer j.deinit();
    try std.json.Stringify.value(path, .{}, &j.writer);
    const p = j.written();
    const loader = try std.fmt.allocPrint(a, "exec(compile(open({s}, 'rb').read(), {s}, 'exec'), {{'__name__':'__main__','__file__':{s}}})", .{ p, p, p });
    defer a.free(loader);
    var w: Io.Writer.Allocating = .init(a);
    errdefer w.deinit();
    try w.writer.writeAll("PROCEDURE RosettaBridge;\nBEGIN\n  PythonBeginContext;\n  PythonExecute('");
    for (loader) |ch| {
        try w.writer.writeByte(ch);
        if (ch == '\'') try w.writer.writeByte(ch);
    }
    try w.writer.writeAll("');\n  PythonEndContext;\nEND;\nRUN(RosettaBridge);\n");
    if (w.written().len > 65536) return error.WrapperTooLarge;
    return w.toOwnedSlice();
}

fn fileUrl(a: Allocator, path: []const u8) ![]const u8 {
    if (!validPath(path)) return error.BadProgramPath;
    var w: Io.Writer.Allocating = .init(a);
    errdefer w.deinit();
    try w.writer.writeAll("file://");
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-._~", ch) != null) {
            try w.writer.writeByte(ch);
        } else {
            try w.writer.writeByte('%');
            try w.writer.writeByte(hex[ch >> 4]);
            try w.writer.writeByte(hex[ch & 15]);
        }
    }
    return w.toOwnedSlice();
}

const Reply = struct { transport: i32 = 0, application: i32 = 0 };
const Native = if (builtin.os.tag == .macos) struct {
    const Desc = extern struct { kind: u32 = 0, data: ?*anyopaque = null };
    extern "c" fn proc_pidpath(pid: c_int, buffer: ?*anyopaque, size: u32) c_int;
    extern "c" fn AECreateDesc(kind: u32, data: ?*const anyopaque, size: isize, out: *Desc) i16;
    extern "c" fn AECreateAppleEvent(class: u32, id: u32, target: *const Desc, return_id: i16, transaction: i32, out: *Desc) i16;
    extern "c" fn AEPutParamPtr(event: *Desc, key: u32, kind: u32, data: ?*const anyopaque, size: isize) i16;
    extern "c" fn AESendMessage(event: *const Desc, reply: *Desc, mode: i32, timeout: i32) i16;
    extern "c" fn AEGetParamPtr(event: *const Desc, key: u32, kind: u32, actual: ?*u32, data: ?*anyopaque, size: isize, actual_size: ?*isize) i16;
    extern "c" fn AEDisposeDesc(desc: *Desc) i16;

    fn identity(pid: i32, expected: []const u8) bool {
        var buf: [4096]u8 = undefined;
        const n = proc_pidpath(pid, &buf, buf.len);
        return n > 0 and n <= buf.len and std.mem.eql(u8, expected, std.mem.sliceTo(buf[0..@intCast(n)], 0));
    }
    fn send(pid: i32, source: []const u8, timeout: u32, open_document: bool) Reply {
        var target: Desc = .{};
        var event: Desc = .{};
        var reply: Desc = .{};
        defer {
            _ = AEDisposeDesc(&reply);
            _ = AEDisposeDesc(&event);
            _ = AEDisposeDesc(&target);
        }
        var status = AECreateDesc(0x6b706964, &pid, @sizeOf(i32), &target);
        if (status == 0) status = AECreateAppleEvent(if (open_document) 0x61657674 else 0x56576170, if (open_document) 0x6f646f63 else 0x446f5653, &target, -1, 0, &event);
        if (status == 0) status = AEPutParamPtr(&event, 0x2d2d2d2d, if (open_document) 0x6675726c else 0x75746638, source.ptr, @intCast(source.len));
        const no: u8 = 0;
        if (status == 0 and open_document) status = AEPutParamPtr(&event, 0x4e6f6679, 0x626f6f6c, &no, 1);
        // Open completion is observed by NativeDriver rather than an AppleEvent reply deadline.
        if (status == 0) status = AESendMessage(&event, &reply, if (open_document) 0x11 else 0x13, @intCast((@as(u64, timeout) * 60 + 999) / 1000));
        var app_error: i32 = 0;
        if (status == 0 and !open_document) _ = AEGetParamPtr(&reply, 0x6572726e, 0x6c6f6e67, null, &app_error, @sizeOf(i32), null);
        return .{ .transport = status, .application = app_error };
    }
} else struct {
    fn identity(_: i32, _: []const u8) bool {
        return false;
    }
    fn send(_: i32, _: []const u8, _: u32, _: bool) Reply {
        return .{ .transport = -1 };
    }
};

fn exitCode(r: Reply) u8 {
    return if (r.transport == -1712 or (r.transport == 0 and r.application == 0)) 0 else 1;
}

pub fn runCli(gpa: Allocator, io: Io, args: []const []const u8, out: *Io.Writer) u8 {
    defer out.flush() catch {};
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        out.writeAll(usage) catch {};
        return 0;
    }
    const cfg = parse(args) catch |e| {
        out.print("error\t{s}\n{s}", .{ @errorName(e), usage }) catch {};
        return 2;
    };
    if (!cfg.wrap_only and !cfg.authorized) {
        out.writeAll("refused\toperator authorization required\n") catch {};
        return 1;
    }
    if (!cfg.wrap_only and !Native.identity(cfg.pid, cfg.executable)) {
        out.writeAll("refused\texecutable mismatch or PID absent\n") catch {};
        return 1;
    }
    const file = opdir.openRegularNoBlock(Io.Dir.cwd(), io, cfg.program) catch |e| {
        out.print("refused\t{s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    defer file.close(io);
    const st = file.stat(io) catch {
        out.writeAll("refused\tfile stat failed\n") catch {};
        return 1;
    };
    const limit: u64 = if (cfg.open_document) 1 << 30 else 1 << 20;
    if (st.kind != .file or st.size == 0 or st.size > limit or st.nlink != 1) {
        out.writeAll("refused\tinput must be a bounded regular file with one link\n") catch {};
        return 1;
    }
    const source = (if (cfg.open_document) fileUrl(gpa, cfg.program) else wrap(gpa, cfg.program)) catch |e| {
        out.print("error\t{s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    defer gpa.free(source);
    if (cfg.wrap_only) {
        out.writeAll(source) catch {};
        return 0;
    }
    if (!Native.identity(cfg.pid, cfg.executable)) {
        out.writeAll("refused\texecutable changed before send\n") catch {};
        return 1;
    }
    const r = Native.send(cfg.pid, source, cfg.timeout_ms, cfg.open_document);
    out.print("transport\t{s}\napple_event_error\t{d}\napplication_error\t{d}\noperation_completion\tunobserved\n", .{ if (r.transport == -1712) "unknown_timeout" else if (exitCode(r) != 0) "failed" else if (cfg.open_document) "queued" else "acknowledged", r.transport, r.application }) catch {};
    return exitCode(r);
}

test "wrapper separates Python and VectorScript quoting" {
    const a = std.testing.allocator;
    const s = try wrap(a, "/tmp/O'Brien/quoted\"file.py");
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "O''Brien") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "quoted\\\"file.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "PythonBeginContext;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "RUN(RosettaBridge);") != null);
}
test "dispatch rejects bad arguments and paths" {
    try std.testing.expectError(error.BadProgramPath, wrap(std.testing.allocator, "relative.py"));
    try std.testing.expectError(error.BadProgramPath, wrap(std.testing.allocator, "/tmp/a\n.py"));
    try std.testing.expectError(error.MissingIdentity, parse(&.{ "--program", "/tmp/a.py" }));
    try std.testing.expectError(error.DuplicateArgument, parse(&.{ "--program", "/tmp/a.py", "--program", "/tmp/b.py" }));
    const c = try parse(&.{ "--program", "/tmp/a.py", "--wrap-only" });
    try std.testing.expect(c.wrap_only and !c.authorized);
}
test "transport timeout is unknown rather than completion" {
    try std.testing.expectEqual(@as(u8, 0), exitCode(.{ .transport = -1712 }));
    try std.testing.expectEqual(@as(u8, 1), exitCode(.{ .transport = -609 }));
    try std.testing.expectEqual(@as(u8, 1), exitCode(.{ .application = -1700 }));
}

test "document dispatch uses an encoded file URL and exclusive arguments" {
    const a = std.testing.allocator;
    const u = try fileUrl(a, "/tmp/O'Brien/spa ce/#mm.vwx");
    defer a.free(u);
    try std.testing.expectEqualStrings("file:///tmp/O%27Brien/spa%20ce/%23mm.vwx", u);
    const c = try parse(&.{ "--pid", "1946", "--expected-executable", "/Apps/VW", "--open-document", "/tmp/a.vwx", "--operator-authorized" });
    try std.testing.expect(c.open_document and c.authorized);
    try std.testing.expectError(error.BadCombination, parse(&.{ "--pid", "1", "--expected-executable", "/Apps/VW", "--program", "/tmp/a.py", "--open-document", "/tmp/a.vwx" }));
    try std.testing.expectError(error.BadCombination, parse(&.{ "--open-document", "/tmp/a.vwx", "--wrap-only" }));
}
