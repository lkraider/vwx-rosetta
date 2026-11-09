//! Rosetta native capture orchestration for `vwx rosetta-capture`.
//!
//! `plan` freezes a smoke or full queue, its scripts, recipes and profiles into a session
//! directory. `run` and `resume` drive each case through the create, query and export stages.
//! `finalize` writes a `vwx-rosetta/1` pack input tree from a pack skeleton and the session.
//!
//! A driver performs every native operation. FakeDriver simulates documents for tests. Its
//! artifacts are adapter evidence and finalize records them as `unverified`. NativeDriver sends
//! one Python program per operation to an app that the operator started. Nothing here launches,
//! installs or activates the app.
//!
//! Production wiring. `runCliProduction` is the command line of the binary. A native run there
//! needs the activation gate of `rosetta_activation.zig` with the features that `compiledFeatures`
//! derives from `feature_wiring`, the typed route file (`parseRouteSet`), an explicit phase and the
//! running executable digest. NativeDriver then runs helpers through `native_ui_runtime`'s
//! `ProcessTransport`, opens documents through `Runtime.waitForDocument`, closes through a guarded
//! File > Close step and exports through `Runtime.runExport`. Each export try owns an operation
//! directory that `rosetta_opdir.zig` seals and verifies. `runCli` keeps the legacy behavior for
//! the fake driver and the stub tests.
//!
//! Calibration status. No route is calibrated and no native branch has run. A route file claim is
//! never evidence. `loadEvidence` resolves a record by digest and checks it against the route, the
//! executable, a retained sealed bundle and the run binding.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const json = std.json;
const Sha256 = std.crypto.hash.sha2.Sha256;
const nur = @import("native_ui_runtime.zig");
const nui = @import("native_ui.zig");
const obs = @import("native_ui_observer.zig");
const uidiag = @import("native_ui_diagnostics.zig");
const opdir = @import("rosetta_opdir.zig");
const activation = @import("rosetta_activation.zig");
const pack = @import("rosetta_pack.zig");
const orc = @import("owned_reference_cleanup.zig");
const nb = @import("native_bootstrap.zig");

/// Modules that the capture wiring calls. Integration tests reach them through `Deps`, so that
/// one module root holds each source file. `Deps` is a type, so `testing.refAllDecls` of this
/// file does not run the tests of these modules.
pub const Deps = struct {
    pub const native_ui_runtime = nur;
    pub const native_ui = nui;
    pub const rosetta_opdir = opdir;
    pub const rosetta_activation = activation;
    pub const rosetta_pack = pack;
    pub const native_ui_observer = obs;
    pub const native_ui_diagnostics = uidiag;
};

pub const schema_session = "vwx-rosetta-capture-session/1";
pub const schema_stage = "vwx-rosetta-capture-stage/1";
pub const schema_journal = "vwx-rosetta-capture-journal/1";
pub const schema_outcome = "vwx-rosetta-capture-outcome/1";
pub const schema_run = "vwx-rosetta-capture-run/1";
pub const schema_capabilities = "vwx-rosetta-capabilities/1";
pub const schema_query = "vwx-rosetta-native-query/1";
pub const schema_state = "vwx-rosetta-native-state/1";
pub const schema_fake = "vwx-rosetta-fake-driver/1";
pub const schema_entries = "vwx-rosetta-export-entries/1";
pub const schema_request = "vwx-rosetta-native-request/1";
pub const schema_queue = "vwx-rosetta-queue/1";
pub const schema_pack = "vwx-rosetta/1";
pub const schema_frames = "vwx-rosetta-frames/1";
pub const bridge_revision = "4";

/// Exit status of `run` and `resume` when a native operation stopped the run. `resume` continues it.
pub const exit_stopped: u8 = 3;

const max_json_bytes = 256 << 20;

// ---------------------------------------------------------------------------
// diagnostics
// ---------------------------------------------------------------------------

pub const Severity = enum { @"error", gap, warning };

pub const Diag = struct {
    severity: Severity,
    code: []const u8,
    location: []const u8,
    message: []const u8,
};

pub const Diags = struct {
    arena: Allocator,
    list: std.ArrayList(Diag) = .empty,

    pub fn init(arena: Allocator) Diags {
        return .{ .arena = arena };
    }

    pub fn add(d: *Diags, sev: Severity, code: []const u8, location: []const u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(d.arena, fmt, args) catch "(message allocation failed)";
        d.list.append(d.arena, .{ .severity = sev, .code = code, .location = location, .message = msg }) catch {};
    }

    pub fn err(d: *Diags, code: []const u8, location: []const u8, comptime fmt: []const u8, args: anytype) void {
        d.add(.@"error", code, location, fmt, args);
    }

    pub fn count(d: *const Diags, sev: Severity) usize {
        var n: usize = 0;
        for (d.list.items) |x| {
            if (x.severity == sev) n += 1;
        }
        return n;
    }

    pub fn errors(d: *const Diags) usize {
        return d.count(.@"error");
    }

    pub fn has(d: *const Diags, code: []const u8) bool {
        for (d.list.items) |x| {
            if (std.mem.eql(u8, x.code, code)) return true;
        }
        return false;
    }

    pub fn write(d: *const Diags, w: *Io.Writer) Io.Writer.Error!void {
        for (d.list.items) |x| {
            try w.print("diag\t{s}\t{s}\t{s}\t", .{ @tagName(x.severity), x.code, x.location });
            for (x.message) |c| try w.writeByte(if (c == '\t' or c == '\n') ' ' else c);
            try w.writeByte('\n');
        }
    }
};

fn joinSentence(a: Allocator, x: []const u8, y: []const u8) []const u8 {
    return fmtA(a, "{s}. {s}", .{ std.mem.trimEnd(u8, x, "."), y });
}

fn fmtA(a: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch "(allocation failed)";
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var dg: [32]u8 = undefined;
    Sha256.hash(bytes, &dg, .{});
    return std.fmt.bytesToHex(dg, .lower);
}

fn shaDup(a: Allocator, bytes: []const u8) []const u8 {
    const h = sha256Hex(bytes);
    return a.dupe(u8, &h) catch "";
}

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// Null when `s` is a valid ID under pack SCHEMA.md. Otherwise the reason.
pub fn idProblem(s: []const u8) ?[]const u8 {
    if (s.len == 0) return "empty";
    if (s.len > 128) return "longer than 128 bytes";
    if (!std.ascii.isAlphanumeric(s[0])) return "first byte is not a letter or digit";
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return "byte outside [A-Za-z0-9._-]";
    }
    return null;
}

/// Null when `p` is a relative path under the pack path rules. Otherwise the reason.
pub fn pathProblem(p: []const u8) ?[]const u8 {
    if (p.len == 0) return "empty";
    if (p.len > 240) return "longer than 240 bytes";
    if (p[0] == '/') return "absolute";
    if (p[p.len - 1] == '/') return "trailing slash";
    var it = std.mem.splitScalar(u8, p, '/');
    var n: usize = 0;
    while (it.next()) |c| : (n += 1) {
        if (c.len == 0) return "empty component";
        if (c.len > 128) return "component longer than 128 bytes";
        if (eql(c, ".") or eql(c, "..")) return "dot component";
        if (!(std.ascii.isAlphanumeric(c[0]) or c[0] == '_')) return "component starts outside [A-Za-z0-9_]";
        for (c) |b| {
            if (!(std.ascii.isAlphanumeric(b) or b == '.' or b == '_' or b == '+' or b == '-')) return "byte outside [A-Za-z0-9._+-]";
        }
    }
    if (n > 16) return "more than 16 components";
    return null;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Numbers stay as source text so copied values keep their bytes.
pub fn parseJson(a: Allocator, bytes: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, a, bytes, .{
        .parse_numbers = false,
        .duplicate_field_behavior = .@"error",
    });
}

fn field(v: json.Value, name: []const u8) ?json.Value {
    return switch (v) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn strField(v: json.Value, name: []const u8) ?[]const u8 {
    const x = field(v, name) orelse return null;
    return if (x == .string) x.string else null;
}

fn arrField(v: json.Value, name: []const u8) []json.Value {
    const x = field(v, name) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn boolField(v: json.Value, name: []const u8) ?bool {
    const x = field(v, name) orelse return null;
    return if (x == .bool) x.bool else null;
}

pub fn numberOf(v: json.Value) ?f64 {
    const x: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(x)) x else null;
}

fn intOf(v: json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .float => |f| if (@floor(f) == f and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn strings(a: Allocator, vs: []json.Value) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (vs) |x| {
        if (x == .string) out.append(a, x.string) catch {};
    }
    return out.items;
}

/// Pretty JSON with a final newline.
pub fn stringify(a: Allocator, v: json.Value) []const u8 {
    var out: Io.Writer.Allocating = .init(a);
    json.Stringify.value(v, .{ .whitespace = .indent_2 }, &out.writer) catch return "{}\n";
    out.writer.writeByte('\n') catch {};
    return out.written();
}

/// One JSON line without a newline.
pub fn stringifyLine(a: Allocator, v: json.Value) []const u8 {
    var out: Io.Writer.Allocating = .init(a);
    json.Stringify.value(v, .{}, &out.writer) catch return "{}";
    return out.written();
}

const Obj = struct {
    a: Allocator,
    m: json.ObjectMap = .empty,

    fn init(a: Allocator) Obj {
        return .{ .a = a };
    }
    fn put(o: *Obj, k: []const u8, v: json.Value) void {
        o.m.put(o.a, k, v) catch {};
    }
    fn str(o: *Obj, k: []const u8, s: []const u8) void {
        o.put(k, .{ .string = s });
    }
    fn optStr(o: *Obj, k: []const u8, s: ?[]const u8) void {
        o.put(k, if (s) |x| .{ .string = x } else .null);
    }
    fn int(o: *Obj, k: []const u8, n: i64) void {
        o.put(k, .{ .integer = n });
    }
    fn boolean(o: *Obj, k: []const u8, b: bool) void {
        o.put(k, .{ .bool = b });
    }
    fn value(o: Obj) json.Value {
        return .{ .object = o.m };
    }
};

fn arr(a: Allocator) json.Array {
    return json.Array.init(a);
}

fn strArr(a: Allocator, items: []const []const u8) json.Value {
    var x = arr(a);
    for (items) |s| x.append(.{ .string = s }) catch {};
    return .{ .array = x };
}

fn num(f: f64) json.Value {
    return .{ .float = f };
}

// ---------------------------------------------------------------------------
// files
// ---------------------------------------------------------------------------

fn readAll(a: Allocator, io: Io, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, a, .limited(max_json_bytes));
}

pub fn exists(io: Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn fileSize(io: Io, path: []const u8) ?u64 {
    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return null;
    if (st.kind != .file) return null;
    return st.size;
}

fn dirname(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return ".";
    return if (i == 0) "/" else p[0..i];
}

fn basename(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
    return p[i + 1 ..];
}

fn mkdirp(io: Io, p: []const u8) !void {
    try Dir.cwd().createDirPath(io, p);
}

fn writeNew(io: Io, path: []const u8, bytes: []const u8) !void {
    var fh = try Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer fh.close(io);
    try fh.writeStreamingAll(io, bytes);
}

fn seal(io: Io, path: []const u8) !void {
    try Dir.cwd().setFilePermissions(io, path, Io.File.Permissions.fromMode(0o444), .{});
}

/// Moves `path` to the first free `<path>.superseded.<n>`. Earlier evidence stays readable.
fn supersede(a: Allocator, io: Io, path: []const u8) !void {
    var n: usize = 1;
    while (true) : (n += 1) {
        const to = fmtA(a, "{s}.superseded.{d}", .{ path, n });
        if (exists(io, to)) continue;
        try Dir.rename(Dir.cwd(), path, Dir.cwd(), to, io);
        return;
    }
}

/// Writes `<path>.partial`, renames it to `path` and makes it read-only. An existing file is
/// superseded first.
pub fn putSealed(a: Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    try mkdirp(io, dirname(path));
    const tmp = fmtA(a, "{s}.partial", .{path});
    if (exists(io, tmp)) try supersede(a, io, tmp);
    try writeNew(io, tmp, bytes);
    if (exists(io, path)) try supersede(a, io, path);
    try Dir.rename(Dir.cwd(), tmp, Dir.cwd(), path, io);
    try seal(io, path);
}

/// Copies bytes into a new writable file. The target must not exist.
fn copyNew(io: Io, from: []const u8, to: []const u8) !void {
    try Dir.copyFile(Dir.cwd(), from, Dir.cwd(), to, io, .{ .replace = false, .permissions = Io.File.Permissions.fromMode(0o644) });
}

pub fn hashFile(io: Io, path: []const u8) ![64]u8 {
    const f = try Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = f.readStreaming(io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var dg: [32]u8 = undefined;
    h.final(&dg);
    return std.fmt.bytesToHex(dg, .lower);
}

fn hashFileDup(a: Allocator, io: Io, path: []const u8) ?[]const u8 {
    const h = hashFile(io, path) catch return null;
    return a.dupe(u8, &h) catch null;
}

/// Appends one line. The file is opened without truncation and written at its end.
fn appendLine(io: Io, path: []const u8, line: []const u8) !void {
    var fh = try Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer fh.close(io);
    const st = try fh.stat(io);
    try fh.writePositionalAll(io, line, st.size);
    try fh.writePositionalAll(io, "\n", st.size + line.len);
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

fn sleepMs(io: Io, ms: u32) void {
    if (ms == 0) return;
    io.sleep(Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

fn pidAlive(pid: i32) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |e| return e == error.PermissionDenied;
    return true;
}

// ---------------------------------------------------------------------------
// export formats and output checks
// ---------------------------------------------------------------------------

pub const Format = struct { name: []const u8, ext: []const u8 };

pub const formats = [_]Format{
    .{ .name = "dwg", .ext = "dwg" },
    .{ .name = "dxf", .ext = "dxf" },
    .{ .name = "parasolid", .ext = "x_t" },
    .{ .name = "sat", .ext = "sat" },
    .{ .name = "stl", .ext = "stl" },
    .{ .name = "obj", .ext = "obj" },
    .{ .name = "gltf", .ext = "glb" },
    .{ .name = "fbx", .ext = "fbx" },
    .{ .name = "3ds", .ext = "3ds" },
    .{ .name = "pdf", .ext = "pdf" },
    .{ .name = "svg", .ext = "svg" },
    .{ .name = "png", .ext = "png" },
    .{ .name = "jpeg", .ext = "jpg" },
    .{ .name = "ifc", .ext = "ifc" },
    .{ .name = "csv", .ext = "csv" },
    .{ .name = "xlsx", .ext = "xlsx" },
    .{ .name = "step", .ext = "step" },
    .{ .name = "usd", .ext = "usd" },
    .{ .name = "iges", .ext = "igs" },
    .{ .name = "3dm", .ext = "3dm" },
};

pub fn formatExt(name: []const u8) ?[]const u8 {
    for (formats) |f| {
        if (eql(f.name, name)) return f.ext;
    }
    return null;
}

pub const Sniff = struct {
    ok: bool,
    code: []const u8,
    detail: []const u8,
};

fn sniffOk(detail: []const u8) Sniff {
    return .{ .ok = true, .code = "ok", .detail = detail };
}

fn sniffBad(code: []const u8, detail: []const u8) Sniff {
    return .{ .ok = false, .code = code, .detail = detail };
}

fn endsTrimmed(bytes: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, std.mem.trimEnd(u8, bytes, " \t\r\n\x00"), suffix);
}

fn readU32le(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Checks the leading magic and, where the format has one, the trailer or declared length.
/// A failed check is `bad_magic` or `partial_write`.
pub fn sniffExport(format: []const u8, bytes: []const u8) Sniff {
    if (bytes.len == 0) return sniffBad("empty_export", "file has 0 bytes");
    const s = bytes;
    if (eql(format, "dwg")) {
        if (!std.mem.startsWith(u8, s, "AC10")) return sniffBad("bad_magic", "DWG does not start with AC10");
        return sniffOk("DWG version string present");
    }
    if (eql(format, "dxf")) {
        if (std.mem.startsWith(u8, s, "AutoCAD Binary DXF")) return sniffOk("binary DXF sentinel");
        if (std.mem.indexOf(u8, s[0..@min(s.len, 512)], "SECTION") == null) return sniffBad("bad_magic", "no SECTION in the first 512 bytes");
        if (!endsTrimmed(s, "EOF")) return sniffBad("partial_write", "ASCII DXF does not end with EOF");
        return sniffOk("ASCII DXF with EOF");
    }
    if (eql(format, "parasolid")) {
        if (!std.mem.startsWith(u8, s, "**") and !std.mem.startsWith(u8, s, "PS")) return sniffBad("bad_magic", "Parasolid transmit header absent");
        return sniffOk("Parasolid transmit header");
    }
    if (eql(format, "sat")) {
        if (!std.ascii.isDigit(s[0])) return sniffBad("bad_magic", "SAT header does not start with a version number");
        if (std.mem.indexOf(u8, s, "End-of-ACIS-data") == null) return sniffBad("partial_write", "SAT has no End-of-ACIS-data");
        return sniffOk("SAT header and End-of-ACIS-data");
    }
    if (eql(format, "stl")) {
        if (std.mem.startsWith(u8, s, "solid ") and std.mem.indexOf(u8, s[0..@min(s.len, 1024)], "facet") != null) {
            if (!endsTrimmed(s, "") or std.mem.indexOf(u8, s, "endsolid") == null) return sniffBad("partial_write", "ASCII STL has no endsolid");
            return sniffOk("ASCII STL with endsolid");
        }
        if (s.len < 84) return sniffBad("partial_write", "binary STL shorter than 84 bytes");
        const n = readU32le(s, 80);
        const want = 84 + 50 * @as(u64, n);
        if (want != s.len) return sniffBad("partial_write", "binary STL length differs from 84 + 50 * triangle count");
        return sniffOk("binary STL length matches triangle count");
    }
    if (eql(format, "obj")) {
        if (std.mem.indexOfScalar(u8, s, 0) != null) return sniffBad("bad_magic", "OBJ text holds a NUL byte");
        if (std.mem.indexOf(u8, s, "\nv ") == null and !std.mem.startsWith(u8, s, "v ")) return sniffBad("bad_magic", "OBJ has no vertex line");
        return sniffOk("OBJ vertex lines present");
    }
    if (eql(format, "gltf")) {
        if (s.len < 12 or !std.mem.startsWith(u8, s, "glTF")) return sniffBad("bad_magic", "GLB magic absent");
        if (readU32le(s, 8) != s.len) return sniffBad("partial_write", "GLB length field differs from file size");
        return sniffOk("GLB length matches");
    }
    if (eql(format, "fbx")) {
        if (std.mem.startsWith(u8, s, "Kaydara FBX Binary")) return sniffOk("binary FBX magic");
        if (std.mem.startsWith(u8, s, "; FBX")) return sniffOk("ASCII FBX header");
        return sniffBad("bad_magic", "FBX magic absent");
    }
    if (eql(format, "3ds")) {
        if (s.len < 6 or s[0] != 0x4d or s[1] != 0x4d) return sniffBad("bad_magic", "3DS main chunk 0x4D4D absent");
        if (readU32le(s, 2) != s.len) return sniffBad("partial_write", "3DS main chunk length differs from file size");
        return sniffOk("3DS main chunk length matches");
    }
    if (eql(format, "pdf")) {
        if (!std.mem.startsWith(u8, s, "%PDF-")) return sniffBad("bad_magic", "PDF header absent");
        if (std.mem.indexOf(u8, s[s.len - @min(s.len, 1024) ..], "%%EOF") == null) return sniffBad("partial_write", "PDF has no %%EOF in the last 1024 bytes");
        return sniffOk("PDF header and %%EOF");
    }
    if (eql(format, "svg")) {
        if (std.mem.indexOf(u8, s[0..@min(s.len, 4096)], "<svg") == null) return sniffBad("bad_magic", "no <svg in the first 4096 bytes");
        if (!endsTrimmed(s, "</svg>")) return sniffBad("partial_write", "SVG does not end with </svg>");
        return sniffOk("SVG root element closed");
    }
    if (eql(format, "png")) {
        if (!std.mem.startsWith(u8, s, "\x89PNG\r\n\x1a\n")) return sniffBad("bad_magic", "PNG signature absent");
        if (s.len < 20 or !std.mem.eql(u8, s[s.len - 8 .. s.len - 4], "IEND")) return sniffBad("partial_write", "PNG does not end with IEND");
        return sniffOk("PNG signature and IEND");
    }
    if (eql(format, "jpeg")) {
        if (s.len < 4 or s[0] != 0xff or s[1] != 0xd8) return sniffBad("bad_magic", "JPEG SOI absent");
        if (s[s.len - 2] != 0xff or s[s.len - 1] != 0xd9) return sniffBad("partial_write", "JPEG does not end with EOI");
        return sniffOk("JPEG SOI and EOI");
    }
    if (eql(format, "ifc")) {
        if (!std.mem.startsWith(u8, s, "ISO-10303-21;")) return sniffBad("bad_magic", "IFC STEP header absent");
        if (!endsTrimmed(s, "END-ISO-10303-21;")) return sniffBad("partial_write", "IFC has no END-ISO-10303-21;");
        return sniffOk("IFC STEP header and end");
    }
    if (eql(format, "xlsx")) {
        if (!std.mem.startsWith(u8, s, "PK\x03\x04")) return sniffBad("bad_magic", "XLSX zip signature absent");
        if (std.mem.indexOf(u8, s[s.len - @min(s.len, 65557) ..], "PK\x05\x06") == null) return sniffBad("partial_write", "XLSX has no zip end record");
        return sniffOk("zip signature and end record");
    }
    // Formats that the bundle contract appended. Their checks live in one place.
    if (eql(format, "step") or eql(format, "usd") or eql(format, "iges") or eql(format, "3dm")) return sniffWindow(format, windowOfBytes(s));
    return sniffOk("format has no magic check");
}

// ---------------------------------------------------------------------------
// streaming output checks
// ---------------------------------------------------------------------------

/// Bytes of the head and of the tail that the format checks read.
pub const sniff_head_bytes = 8192;
pub const sniff_tail_bytes = 65557;

/// What one streaming pass records about a file. `sniffWindow` reads only these values. The head
/// and the tail are copies of the first and last bytes of the file.
pub const SniffWindow = struct {
    size: u64,
    head: []const u8,
    tail: []const u8,
    has_nul: bool,
    has_vertex_line: bool,
    has_endsolid: bool,
    has_acis_end: bool,
};

fn lastLine(bytes: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, bytes, " \t\r\n\x00");
    const i = std.mem.lastIndexOfScalar(u8, t, '\n') orelse return t;
    return std.mem.trimEnd(u8, t[i + 1 ..], "\r");
}

/// The checks of `sniffExport` over a window. A file whose head and tail fit the window gives the
/// same result as `sniffExport` on its bytes. Larger files are checked through the head, the tail,
/// the size and the flags of one streaming pass.
pub fn sniffWindow(format: []const u8, w: SniffWindow) Sniff {
    if (w.size == 0) return sniffBad("empty_export", "file has 0 bytes");
    const h = w.head;
    const t = w.tail;
    if (eql(format, "dwg")) {
        if (!std.mem.startsWith(u8, h, "AC10")) return sniffBad("bad_magic", "DWG does not start with AC10");
        return sniffOk("DWG version string present");
    }
    if (eql(format, "dxf")) {
        if (std.mem.startsWith(u8, h, "AutoCAD Binary DXF")) return sniffOk("binary DXF sentinel");
        if (std.mem.indexOf(u8, h[0..@min(h.len, 512)], "SECTION") == null) return sniffBad("bad_magic", "no SECTION in the first 512 bytes");
        if (!endsTrimmed(t, "EOF")) return sniffBad("partial_write", "ASCII DXF does not end with EOF");
        return sniffOk("ASCII DXF with EOF");
    }
    if (eql(format, "parasolid")) {
        if (!std.mem.startsWith(u8, h, "**") and !std.mem.startsWith(u8, h, "PS")) return sniffBad("bad_magic", "Parasolid transmit header absent");
        return sniffOk("Parasolid transmit header");
    }
    if (eql(format, "sat")) {
        if (!std.ascii.isDigit(h[0])) return sniffBad("bad_magic", "SAT header does not start with a version number");
        if (!w.has_acis_end) return sniffBad("partial_write", "SAT has no End-of-ACIS-data");
        return sniffOk("SAT header and End-of-ACIS-data");
    }
    if (eql(format, "stl")) {
        if (std.mem.startsWith(u8, h, "solid ") and std.mem.indexOf(u8, h[0..@min(h.len, 1024)], "facet") != null) {
            if (!w.has_endsolid) return sniffBad("partial_write", "ASCII STL has no endsolid");
            return sniffOk("ASCII STL with endsolid");
        }
        if (w.size < 84) return sniffBad("partial_write", "binary STL shorter than 84 bytes");
        const n = readU32le(h, 80);
        const want = 84 + 50 * @as(u64, n);
        if (want != w.size) return sniffBad("partial_write", "binary STL length differs from 84 + 50 * triangle count");
        return sniffOk("binary STL length matches triangle count");
    }
    if (eql(format, "obj")) {
        if (w.has_nul) return sniffBad("bad_magic", "OBJ text holds a NUL byte");
        if (!w.has_vertex_line and !std.mem.startsWith(u8, h, "v ")) return sniffBad("bad_magic", "OBJ has no vertex line");
        return sniffOk("OBJ vertex lines present");
    }
    if (eql(format, "gltf")) {
        if (w.size < 12 or !std.mem.startsWith(u8, h, "glTF")) return sniffBad("bad_magic", "GLB magic absent");
        if (readU32le(h, 8) != w.size) return sniffBad("partial_write", "GLB length field differs from file size");
        return sniffOk("GLB length matches");
    }
    if (eql(format, "fbx")) {
        if (std.mem.startsWith(u8, h, "Kaydara FBX Binary")) return sniffOk("binary FBX magic");
        if (std.mem.startsWith(u8, h, "; FBX")) return sniffOk("ASCII FBX header");
        return sniffBad("bad_magic", "FBX magic absent");
    }
    if (eql(format, "3ds")) {
        if (w.size < 6 or h[0] != 0x4d or h[1] != 0x4d) return sniffBad("bad_magic", "3DS main chunk 0x4D4D absent");
        if (readU32le(h, 2) != w.size) return sniffBad("partial_write", "3DS main chunk length differs from file size");
        return sniffOk("3DS main chunk length matches");
    }
    if (eql(format, "pdf")) {
        if (!std.mem.startsWith(u8, h, "%PDF-")) return sniffBad("bad_magic", "PDF header absent");
        if (std.mem.indexOf(u8, t[t.len - @min(t.len, 1024) ..], "%%EOF") == null) return sniffBad("partial_write", "PDF has no %%EOF in the last 1024 bytes");
        return sniffOk("PDF header and %%EOF");
    }
    if (eql(format, "svg")) {
        if (std.mem.indexOf(u8, h[0..@min(h.len, 4096)], "<svg") == null) return sniffBad("bad_magic", "no <svg in the first 4096 bytes");
        if (!endsTrimmed(t, "</svg>")) return sniffBad("partial_write", "SVG does not end with </svg>");
        return sniffOk("SVG root element closed");
    }
    if (eql(format, "png")) {
        if (!std.mem.startsWith(u8, h, "\x89PNG\r\n\x1a\n")) return sniffBad("bad_magic", "PNG signature absent");
        if (w.size < 20 or !std.mem.eql(u8, t[t.len - 8 .. t.len - 4], "IEND")) return sniffBad("partial_write", "PNG does not end with IEND");
        return sniffOk("PNG signature and IEND");
    }
    if (eql(format, "jpeg")) {
        if (w.size < 4 or h[0] != 0xff or h[1] != 0xd8) return sniffBad("bad_magic", "JPEG SOI absent");
        if (t[t.len - 2] != 0xff or t[t.len - 1] != 0xd9) return sniffBad("partial_write", "JPEG does not end with EOI");
        return sniffOk("JPEG SOI and EOI");
    }
    if (eql(format, "ifc") or eql(format, "step")) {
        if (!std.mem.startsWith(u8, h, "ISO-10303-21;")) return sniffBad("bad_magic", "STEP exchange header absent");
        if (!endsTrimmed(t, "END-ISO-10303-21;")) return sniffBad("partial_write", "no END-ISO-10303-21;");
        return sniffOk("STEP exchange header and end");
    }
    if (eql(format, "usd")) {
        if (std.mem.startsWith(u8, h, "#usda ") or std.mem.startsWith(u8, h, "PXR-USDC")) return sniffOk("USD header");
        return sniffBad("bad_magic", "USD header absent");
    }
    if (eql(format, "iges")) {
        const last = lastLine(t);
        if (last.len < 73 or last[72] != 'T') return sniffBad("partial_write", "IGES has no terminate record");
        return sniffOk("IGES terminate record present");
    }
    if (eql(format, "3dm")) {
        if (!std.mem.startsWith(u8, h, "3D Geometry File Format")) return sniffBad("bad_magic", "3DM header absent");
        return sniffOk("3DM header");
    }
    if (eql(format, "xlsx")) {
        if (!std.mem.startsWith(u8, h, "PK\x03\x04")) return sniffBad("bad_magic", "XLSX zip signature absent");
        if (std.mem.indexOf(u8, t, "PK\x05\x06") == null) return sniffBad("partial_write", "XLSX has no zip end record");
        return sniffOk("zip signature and end record");
    }
    return sniffOk("format has no magic check");
}

/// Window of bytes that are already in memory. Tests and small files use it.
pub fn windowOfBytes(bytes: []const u8) SniffWindow {
    return .{
        .size = bytes.len,
        .head = bytes[0..@min(bytes.len, sniff_head_bytes)],
        .tail = bytes[bytes.len - @min(bytes.len, sniff_tail_bytes) ..],
        .has_nul = std.mem.indexOfScalar(u8, bytes, 0) != null,
        .has_vertex_line = std.mem.indexOf(u8, bytes, "\nv ") != null,
        .has_endsolid = std.mem.indexOf(u8, bytes, "endsolid") != null,
        .has_acis_end = std.mem.indexOf(u8, bytes, "End-of-ACIS-data") != null,
    };
}

const FlagScan = struct {
    nul: bool = false,
    vertex: bool = false,
    endsolid: bool = false,
    acis: bool = false,

    fn feed(s: *FlagScan, bytes: []const u8) void {
        if (!s.nul) s.nul = std.mem.indexOfScalar(u8, bytes, 0) != null;
        if (!s.vertex) s.vertex = std.mem.indexOf(u8, bytes, "\nv ") != null;
        if (!s.endsolid) s.endsolid = std.mem.indexOf(u8, bytes, "endsolid") != null;
        if (!s.acis) s.acis = std.mem.indexOf(u8, bytes, "End-of-ACIS-data") != null;
    }
};

/// Opens `path` without following links or blocking on a special file, then streams it once through
/// a 64 KiB buffer. Memory use does not follow the file size. The head and the tail are copied
/// into `a`. A file that changes size during the pass fails with `error.FileChanged`.
pub fn sniffFile(a: Allocator, io: Io, format: []const u8, path: []const u8) !Sniff {
    const f = try opdir.openRegularNoBlock(Dir.cwd(), io, path);
    defer f.close(io);
    const st0 = try f.stat(io);
    if (st0.kind != .file) return error.SpecialFile;
    const head_len: usize = @intCast(@min(st0.size, sniff_head_bytes));
    const head = try a.alloc(u8, head_len);
    if ((try f.readPositionalAll(io, head, 0)) != head_len) return error.FileChanged;
    var scan: FlagScan = .{};
    // 15 bytes of the previous chunk keep a pattern that spans two chunks.
    var buf: [16 + 64 * 1024]u8 = undefined;
    var carry: usize = 0;
    var total: u64 = 0;
    while (true) {
        const n = f.readStreaming(io, &.{buf[16..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        scan.feed(buf[16 - carry .. 16 + n]);
        total += n;
        const keep: usize = @min(15, carry + n);
        std.mem.copyForwards(u8, buf[16 - keep .. 16], buf[16 + n - keep .. 16 + n]);
        carry = keep;
    }
    const st1 = try f.stat(io);
    if (total != st0.size or st1.size != st0.size) return error.FileChanged;
    const tail_len: usize = @intCast(@min(total, sniff_tail_bytes));
    const tail = try a.alloc(u8, tail_len);
    const got = try f.readPositionalAll(io, tail, total - tail_len);
    if (got != tail_len) return error.FileChanged;
    return sniffWindow(format, .{ .size = total, .head = head, .tail = tail, .has_nul = scan.nul, .has_vertex_line = scan.vertex, .has_endsolid = scan.endsolid, .has_acis_end = scan.acis });
}

// ---------------------------------------------------------------------------
// dependency closure of an OBJ bundle
// ---------------------------------------------------------------------------

/// Outcome of the reference check. `state` is `not_established` for a format whose references
/// this module does not read. A `problem` is a reference that the bundle cannot resolve.
pub const Closure = struct {
    state: []const u8,
    problem: ?[]const u8 = null,
};

/// Reads `path` through a 64 KiB buffer and calls `onLine` for each line of at most 4096 bytes.
/// Returns the number of longer lines that it skipped.
fn scanLines(io: Io, path: []const u8, ctx: anytype, comptime onLine: fn (@TypeOf(ctx), []const u8) void) !usize {
    const f = try opdir.openRegularNoBlock(Dir.cwd(), io, path);
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var line: [4096]u8 = undefined;
    var len: usize = 0;
    var skipping = false;
    var skipped: usize = 0;
    while (true) {
        const n = f.readStreaming(io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c == '\n') {
                if (skipping) {
                    skipped += 1;
                    skipping = false;
                } else onLine(ctx, line[0..len]);
                len = 0;
                continue;
            }
            if (skipping) continue;
            if (len == line.len) {
                skipping = true;
                len = 0;
                continue;
            }
            line[len] = c;
            len += 1;
        }
    }
    if (skipping) skipped += 1 else if (len > 0) onLine(ctx, line[0..len]);
    return skipped;
}

const max_refs = 256;

const RefScan = struct {
    a: Allocator,
    mtl: bool,
    refs: std.ArrayList([]const u8) = .empty,
    over: bool = false,

    fn add(s: *RefScan, name: []const u8) void {
        if (name.len == 0) return;
        if (s.refs.items.len >= max_refs) {
            s.over = true;
            return;
        }
        s.refs.append(s.a, s.a.dupe(u8, name) catch return) catch {};
    }

    fn line(s: *RefScan, raw: []const u8) void {
        const t = std.mem.trim(u8, raw, " \t\r");
        var it = std.mem.tokenizeAny(u8, t, " \t");
        const head = it.next() orelse return;
        if (!s.mtl) {
            if (std.ascii.eqlIgnoreCase(head, "mtllib")) while (it.next()) |x| s.add(x);
            return;
        }
        const is_map = std.ascii.startsWithIgnoreCase(head, "map_") or std.ascii.eqlIgnoreCase(head, "bump") or std.ascii.eqlIgnoreCase(head, "disp") or std.ascii.eqlIgnoreCase(head, "decal") or std.ascii.eqlIgnoreCase(head, "refl");
        if (!is_map) return;
        var last: []const u8 = "";
        while (it.next()) |x| last = x;
        // A statement with options and no file name ends in a number or an option name.
        if (last.len > 0 and last[0] != '-') s.add(last);
    }
};

/// The bundle path of `ref` when it is relative to the directory of `from`, else a reason.
fn resolveRef(a: Allocator, from: []const u8, ref: []const u8) union(enum) { path: []const u8, bad: []const u8 } {
    if (ref.len == 0 or ref[0] == '/') return .{ .bad = "reference_escapes_bundle" };
    if (std.mem.indexOfScalar(u8, ref, '\\') != null) return .{ .bad = "reference_escapes_bundle" };
    var comps = std.mem.splitScalar(u8, ref, '/');
    while (comps.next()) |c| {
        if (c.len == 0 or eql(c, ".") or eql(c, "..")) return .{ .bad = "reference_escapes_bundle" };
    }
    const dir = if (std.mem.lastIndexOfScalar(u8, from, '/')) |i| from[0..i] else "";
    return .{ .path = if (dir.len == 0) ref else fmtA(a, "{s}/{s}", .{ dir, ref }) };
}

/// Checks the `mtllib` names of the OBJ main file and the texture names of each MTL file that the
/// manifest holds. Every named file must be a manifest entry. This is a syntax check. It does not
/// read the geometry and does not decide whether a texture file is a valid image.
pub fn objClosure(a: Allocator, io: Io, op_path: []const u8, m: *const opdir.Manifest) !Closure {
    var skipped: usize = 0;
    var main_scan: RefScan = .{ .a = a, .mtl = false };
    skipped += try scanLines(io, fmtA(a, "{s}/{s}", .{ op_path, m.main_file }), &main_scan, RefScan.line);
    var over = main_scan.over;
    var seen: usize = 0;
    for (main_scan.refs.items) |ref| {
        const mtl_path = switch (resolveRef(a, m.main_file, ref)) {
            .path => |p| p,
            .bad => |code| return .{ .state = "obj_references_open", .problem = fmtA(a, "{s}: {s} names `{s}`", .{ code, m.main_file, ref }) },
        };
        if (m.find(mtl_path) == null) return .{ .state = "obj_references_open", .problem = fmtA(a, "reference_unresolved: {s} names `{s}` and the bundle has no file {s}", .{ m.main_file, ref, mtl_path }) };
        var mtl_scan: RefScan = .{ .a = a, .mtl = true };
        skipped += try scanLines(io, fmtA(a, "{s}/{s}", .{ op_path, mtl_path }), &mtl_scan, RefScan.line);
        over = over or mtl_scan.over;
        for (mtl_scan.refs.items) |tex| {
            seen += 1;
            const tex_path = switch (resolveRef(a, mtl_path, tex)) {
                .path => |p| p,
                .bad => |code| return .{ .state = "obj_references_open", .problem = fmtA(a, "{s}: {s} names `{s}`", .{ code, mtl_path, tex }) },
            };
            if (m.find(tex_path) == null) return .{ .state = "obj_references_open", .problem = fmtA(a, "reference_unresolved: {s} names `{s}` and the bundle has no file {s}", .{ mtl_path, tex, tex_path }) };
        }
    }
    if (over or skipped > 0) return .{ .state = "obj_mtl_scan_incomplete" };
    return .{ .state = if (main_scan.refs.items.len == 0) "obj_no_references" else "obj_mtl_references_closed" };
}

pub fn bundleClosure(a: Allocator, io: Io, format: []const u8, op_path: []const u8, m: *const opdir.Manifest) !Closure {
    if (eql(format, "obj")) return objClosure(a, io, op_path, m);
    return .{ .state = "not_established" };
}
// ---------------------------------------------------------------------------
// queue
// ---------------------------------------------------------------------------

pub const Query = struct {
    object_id: []const u8,
    quantity: []const u8,
    api: []const u8,
    frame: []const u8,
    /// One registered part of a multi-value return. Null when the queue gives none.
    component: ?[]const u8 = null,
    /// Typed call arguments. Null when the queue gives none. `queryArgProblem` checks each one.
    args: ?[]const json.Value = null,
    /// Set for `acquisition` `raw_only`. The query has no quantity and no component.
    raw_only: ?RawQuery = null,
};

/// The raw-only query descriptor of rosetta-inventory queue revision 5. The result keeps the
/// full call return. It has no value and no measurement record.
pub const RawQuery = struct { raw_call: []const u8, raw_return: []const json.Value, decision: []const u8 };

/// The bridge `RAW` allowlist. `object` is true when the call takes the handle of `object_id`.
/// The other calls take no arguments and use object_id `document`.
pub const raw_calls = [_]struct { name: []const u8, object: bool }{
    .{ .name = "GetTextStyleRef", .object = true },
    .{ .name = "GetGISOriginN", .object = false },
    .{ .name = "GetUnits", .object = false },
    .{ .name = "GetView", .object = false },
};

pub const raw_decisions = [_][]const u8{ "decision.quantity.reference", "decision.quantity.geodetic", "decision.quantity.unit_mark", "decision.query.get_view" };

/// Returns the diagnostic code and message of an invalid raw-only query. A query without
/// `acquisition` returns null.
pub fn rawQueryProblem(a: Allocator, q: json.Value) ?[2][]const u8 {
    const acq = field(q, "acquisition") orelse return null;
    const bad = "bad_raw_query";
    if (acq != .string or !eql(acq.string, "raw_only")) return .{ bad, "acquisition must be raw_only" };
    if (field(q, "quantity") != null or field(q, "component") != null) return .{ bad, "a raw-only query has no quantity and no component" };
    if (field(q, "args") != null) return .{ bad, "a raw-only query has no args" };
    if (!eql(strField(q, "normalization") orelse "", "unresolved")) return .{ bad, "normalization must be unresolved" };
    const rr = field(q, "raw_return") orelse .null;
    if (rr != .array or rr.array.items.len == 0) return .{ bad, "raw_return must be a nonempty list of strings" };
    for (rr.array.items) |x| if (x != .string) return .{ bad, "raw_return must be a nonempty list of strings" };
    if (!inList(&raw_decisions, strField(q, "decision") orelse "")) return .{ bad, fmtA(a, "decision `{s}` is not a maintainer raw-only decision", .{strField(q, "decision") orelse ""}) };
    const call = strField(q, "raw_call") orelse "";
    const rc = for (raw_calls) |x| {
        if (eql(x.name, call)) break x;
    } else return .{ "raw_call_unlisted", fmtA(a, "raw_call `{s}` is not in the bridge RAW allowlist", .{call}) };
    const api = strField(q, "api") orelse "";
    if (!std.mem.startsWith(u8, api, "vs.") or !eql(api[3..], call)) return .{ "raw_call_mismatch", fmtA(a, "api `{s}` differs from vs.{s}", .{ api, call }) };
    const doc = eql(strField(q, "object_id") orelse "", "document");
    if (rc.object == doc) return .{ "raw_object_mismatch", if (rc.object) fmtA(a, "{s} takes the handle of an object. object_id is document", .{call}) else fmtA(a, "{s} takes no handle. object_id must be document", .{call}) };
    return null;
}

/// The query record that the engine sends. `collector` holds the `planQuery` result. A result
/// record copies it, so the raw file keeps the plan of each query.
pub fn queryPayload(a: Allocator, q: Query) json.Value {
    var x = Obj.init(a);
    x.str("object_id", q.object_id);
    if (q.raw_only) |r| {
        x.str("api", q.api);
        x.str("frame", q.frame);
        x.str("acquisition", "raw_only");
        x.str("raw_call", r.raw_call);
        var rl = arr(a);
        rl.appendSlice(r.raw_return) catch {};
        x.put("raw_return", .{ .array = rl });
        x.str("normalization", "unresolved");
        x.str("decision", r.decision);
        var c = Obj.init(a);
        c.str("status", "raw_only");
        c.str("detail", planQuery(a, q).detail);
        c.str("raw_call", r.raw_call);
        x.put("collector", c.value());
        return x.value();
    }
    x.str("quantity", q.quantity);
    x.str("api", q.api);
    x.str("frame", q.frame);
    x.optStr("component", q.component);
    if (q.args) |l| {
        var al = arr(a);
        al.appendSlice(l) catch {};
        x.put("args", .{ .array = al });
    }
    const qp = planQuery(a, q);
    var c = Obj.init(a);
    if (qp.status) |st| {
        c.str("status", st);
        c.str("detail", qp.detail);
        c.optStr("raw_call", qp.raw_call);
    } else {
        const col = qp.collector.?;
        c.str("component", qp.component);
        c.str("part", col.component);
        c.boolean("units_documented", col.units_documented);
        c.optStr("raw_only", col.raw_only);
    }
    x.put("collector", c.value());
    return x.value();
}

/// Reads a queue query or a payload query. `default_frame` applies when `frame` is absent.
pub fn queryOf(v: json.Value, default_frame: []const u8) Query {
    const args = field(v, "args");
    return .{
        .object_id = strField(v, "object_id") orelse "",
        .quantity = strField(v, "quantity") orelse "",
        .api = strField(v, "api") orelse "",
        .frame = strField(v, "frame") orelse default_frame,
        .component = strField(v, "component"),
        .args = if (args != null and args.? == .array) args.?.array.items else null,
        .raw_only = if (eql(strField(v, "acquisition") orelse "", "raw_only")) .{
            .raw_call = strField(v, "raw_call") orelse "",
            .raw_return = arrField(v, "raw_return"),
            .decision = strField(v, "decision") orelse "",
        } else null,
    };
}

/// A query argument is a string, a bool, a finite number, `{"handle": "object"}` or
/// `{"handle": "layer", "name": <non-empty string>}`. The rule equals `bad_query_arg` of
/// rosetta-inventory 0ac3e1a4.
pub fn queryArgProblem(v: json.Value) ?[]const u8 {
    switch (v) {
        .string, .bool => return null,
        .integer, .float, .number_string => return if (numberOf(v) != null) null else "number is not finite",
        .object => |o| {
            const h = strField(v, "handle") orelse return "object argument has no handle string";
            if (eql(h, "object")) return if (o.count() == 1) null else "object handle has keys other than handle";
            if (eql(h, "layer")) {
                const n = strField(v, "name") orelse return "layer handle has no name string";
                if (n.len == 0) return "layer handle name is empty";
                return if (o.count() == 2) null else "layer handle has keys other than handle and name";
            }
            return "handle is not object or layer";
        },
        else => return "argument is not a string, bool, number or handle object",
    }
}

/// `existing_document` cases carry `source_sha256`. They collect from a scratch copy of a pinned
/// source. `generated` cases build their document from the blank template.
pub const CaseKind = enum { generated, existing_document };

pub const QCase = struct {
    kind: CaseKind = .generated,
    case_id: []const u8,
    family_id: []const u8,
    recipe_sha256: ?[]const u8,
    recipe_path: ?[]const u8,
    script_path: []const u8,
    script_sha256: []const u8,
    blank_control: ?[]const u8,
    dependencies: []const []const u8,
    profile_ids: []const []const u8,
    queries: []const Query,
    apis: []const []const u8,
    checkpoints: []const []const u8,
    save_reopen: bool,
    universe: ?[]const u8 = null,
    recipe_revision: ?[]const u8 = null,
    source_sha256: ?[]const u8 = null,
    /// Profile IDs of `export` operations with mode `operator_manual`.
    manual_exports: []const []const u8 = &.{},
    /// Operations with mode `operator_manual`, as `<op> <detail>` lines.
    manual_steps: []const []const u8 = &.{},
    expected_relationships: json.Value = .null,
    /// True when `blank_control` resolves in the frozen controls queue of the session.
    external_control: bool = false,
};

/// Operations of an existing-document case in queue order. `export`, `set_view` and
/// `close_without_save` are allowed with mode `operator_manual`.
pub const existing_required_ops = [_][]const u8{ "check_source", "copy_to_scratch", "open_copy", "state_before", "collect", "state_after", "check_source_after" };
const existing_manual_ops = [_][]const u8{ "set_view", "export", "close_without_save" };

pub const Profile = struct {
    profile_id: []const u8,
    profile_sha256: []const u8,
    format: []const u8,
    path: ?[]const u8,
    options: json.Value,
    overrides: json.Value,
};

/// One root `dependencies` entry of a queue. `path` is relative to the inventory directory.
pub const RootDep = struct { id: []const u8, path: []const u8, sha256: []const u8 };

pub const Queue = struct {
    sha256: []const u8,
    cases: []QCase,
    profiles: []Profile,
    dependencies: []const RootDep = &.{},

    pub fn findDep(q: *const Queue, id: []const u8) ?*const RootDep {
        for (q.dependencies) |*x| {
            if (eql(x.id, id)) return x;
        }
        return null;
    }

    pub fn findCase(q: *const Queue, id: []const u8) ?*const QCase {
        for (q.cases) |*c| {
            if (eql(c.case_id, id)) return c;
        }
        return null;
    }

    pub fn findProfile(q: *const Queue, id: []const u8) ?*const Profile {
        for (q.profiles) |*p| {
            if (eql(p.profile_id, id)) return p;
        }
        return null;
    }
};

fn lowerHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

pub fn parseQueue(a: Allocator, d: *Diags, bytes: []const u8, where: []const u8) ?Queue {
    return parseQueueWith(a, d, bytes, where, &.{});
}

/// `controls` lists case IDs of a frozen controls queue. An existing-document case may name one
/// of them as `blank_control`.
pub fn parseQueueWith(a: Allocator, d: *Diags, bytes: []const u8, where: []const u8, controls: []const []const u8) ?Queue {
    const v = parseJson(a, bytes) catch |e| {
        d.err("invalid_json", where, "queue does not parse: {s}", .{@errorName(e)});
        return null;
    };
    if (!eql(strField(v, "schema") orelse "", schema_queue)) {
        d.err("bad_schema", where, "schema must be {s}", .{schema_queue});
        return null;
    }
    var profiles: std.ArrayList(Profile) = .empty;
    for (arrField(v, "profiles")) |p| {
        const pid = strField(p, "profile_id") orelse {
            d.err("missing_field", where, "a profile has no profile_id", .{});
            continue;
        };
        const sha = strField(p, "profile_sha256") orelse "";
        const fmt = strField(p, "format") orelse "";
        if (idProblem(pid)) |why| d.err("bad_id", where, "profile_id `{s}` is invalid: {s}", .{ pid, why });
        if (!lowerHex64(sha)) d.err("bad_hash", where, "profile `{s}` has no valid profile_sha256", .{pid});
        if (formatExt(fmt) == null) d.err("unknown_format", where, "profile `{s}` has format `{s}`, which has no extension in rosetta_capture.formats", .{ pid, fmt });
        if (strField(p, "path")) |pp| {
            if (pathProblem(pp)) |why| d.err("bad_path", where, "profile `{s}` path is invalid: {s}", .{ pid, why });
        }
        profiles.append(a, .{
            .profile_id = pid,
            .profile_sha256 = sha,
            .format = fmt,
            .path = strField(p, "path"),
            .options = field(p, "options") orelse .null,
            .overrides = field(p, "state_overrides") orelse .null,
        }) catch {};
    }
    var cases: std.ArrayList(QCase) = .empty;
    for (arrField(v, "cases")) |c| {
        const id = strField(c, "case_id") orelse {
            d.err("missing_field", where, "a case has no case_id", .{});
            continue;
        };
        const cw = fmtA(a, "case:{s}", .{id});
        if (idProblem(id)) |why| d.err("bad_id", cw, "case_id is invalid: {s}", .{why});
        var queries: std.ArrayList(Query) = .empty;
        for (arrField(c, "queries"), 0..) |q, qi| {
            if (field(q, "component")) |x| {
                if (x != .string) d.err("bad_query_component", cw, "query {d} component is not a string", .{qi});
            }
            if (field(q, "args")) |x| {
                if (x != .array) d.err("bad_query_arg", cw, "query {d} args is not a list", .{qi}) else for (x.array.items, 0..) |y, ai| {
                    if (queryArgProblem(y)) |why| d.err("bad_query_arg", cw, "query {d} argument {d}: {s}", .{ qi, ai, why });
                }
            }
            if (rawQueryProblem(a, q)) |p| d.err(p[0], cw, "query {d}: {s}", .{ qi, p[1] });
            queries.append(a, queryOf(q, "document_world")) catch {};
        }
        var apis: std.ArrayList([]const u8) = .empty;
        var cps: std.ArrayList([]const u8) = .empty;
        var save_reopen = false;
        const source_sha = strField(c, "source_sha256");
        const kind: CaseKind = if (field(c, "source_sha256") != null) .existing_document else .generated;
        var manual: std.ArrayList([]const u8) = .empty;
        var steps: std.ArrayList([]const u8) = .empty;
        var seen_ops: std.ArrayList([]const u8) = .empty;
        const pids = strings(a, arrField(c, "profile_ids"));
        for (arrField(c, "operations")) |o| {
            const op = strField(o, "op") orelse "";
            seen_ops.append(a, op) catch {};
            if (strField(o, "api")) |api| {
                if (!inList(apis.items, api)) apis.append(a, api) catch {};
            }
            if (eql(op, "checkpoint")) {
                const cid = strField(o, "id") orelse "";
                if (idProblem(cid)) |why| d.err("bad_id", cw, "checkpoint id `{s}` is invalid: {s}", .{ cid, why });
                cps.append(a, cid) catch {};
            }
            if (eql(op, "save_reopen")) save_reopen = true;
            if (kind == .generated) {
                if (inList(&existing_required_ops, op)) d.err("ambiguous_case_kind", cw, "operation `{s}` belongs to an existing-document case. The case has no source_sha256", .{op});
                continue;
            }
            if (eql(op, "save_reopen") or eql(op, "checkpoint") or eql(op, "call") or eql(op, "create") or strField(o, "api") != null) {
                d.err("ambiguous_case_kind", cw, "operation `{s}` creates content. A case with source_sha256 collects from an existing document", .{op});
                continue;
            }
            if (eql(op, "check_source") or eql(op, "check_source_after")) {
                const want = strField(o, "sha256") orelse "";
                if (source_sha == null or !eql(want, source_sha.?)) d.err("source_digest_mismatch", cw, "{s} names SHA256 `{s}`. source_sha256 is `{s}`", .{ op, want, source_sha orelse "" });
            }
            if (inList(&existing_manual_ops, op)) {
                const mode = strField(o, "mode") orelse "";
                if (!eql(mode, "operator_manual")) {
                    d.err("unsupported_operation", cw, "operation `{s}` has mode `{s}`. Only operator_manual has a rule", .{ op, mode });
                    continue;
                }
                if (eql(op, "export")) {
                    const pid = strField(o, "profile_id") orelse "";
                    if (!inList(pids, pid)) d.err("unsupported_operation", cw, "export names profile `{s}`, which is not in profile_ids", .{pid});
                    manual.append(a, pid) catch {};
                    steps.append(a, fmtA(a, "export profile {s} channel {s}", .{ pid, strField(o, "channel") orelse "" })) catch {};
                } else {
                    var detail: []const u8 = "";
                    if (strField(o, "view")) |x| detail = fmtA(a, " view `{s}`", .{x});
                    if (strField(o, "layers")) |x| detail = fmtA(a, "{s} layers `{s}`", .{ detail, x });
                    steps.append(a, fmtA(a, "{s}{s}", .{ op, detail })) catch {};
                }
                continue;
            }
            if (!inList(&existing_required_ops, op)) d.err("unsupported_operation", cw, "operation `{s}` has no rule for an existing-document case", .{op});
        }
        if (kind == .generated) {
            if (!save_reopen) d.err("no_save_reopen", cw, "operations have no save_reopen", .{});
        } else {
            if (source_sha == null or !lowerHex64(source_sha.?)) d.err("bad_hash", cw, "source_sha256 is not a SHA256", .{});
            for (existing_required_ops) |op| {
                if (!inList(seen_ops.items, op)) d.err("existing_document_incomplete", cw, "operations have no `{s}`", .{op});
            }
            for (pids) |pid| {
                if (!inList(manual.items, pid)) d.err("unsupported_operation", cw, "profile `{s}` has no operator_manual export operation", .{pid});
            }
            if (arrField(c, "queries").len > 0) d.err("ambiguous_case_kind", cw, "an existing-document case collects every object. It has no queries", .{});
            if (strField(c, "recipe_path") == null or strField(c, "recipe_sha256") == null) d.err("missing_field", cw, "an existing-document case needs recipe_path and recipe_sha256 of its collect spec", .{});
        }
        const script_path = strField(c, "script_path") orelse "";
        if (pathProblem(script_path)) |why| d.err("bad_path", cw, "script_path is invalid: {s}", .{why});
        if (strField(c, "recipe_path")) |rp| {
            if (pathProblem(rp)) |why| d.err("bad_path", cw, "recipe_path is invalid: {s}", .{why});
        }
        const script_sha = strField(c, "script_sha256") orelse "";
        if (!lowerHex64(script_sha)) d.err("bad_hash", cw, "script_sha256 is not a SHA256", .{});
        const deps = strings(a, arrField(c, "dependencies"));
        for (deps) |dep| {
            if (idProblem(dep)) |why| d.err("bad_id", cw, "dependency `{s}` is invalid: {s}", .{ dep, why });
        }
        cases.append(a, .{
            .kind = kind,
            .universe = strField(c, "universe"),
            .recipe_revision = strField(c, "recipe_revision"),
            .source_sha256 = source_sha,
            .manual_exports = manual.items,
            .manual_steps = steps.items,
            .expected_relationships = field(c, "expected_relationships") orelse .null,
            .case_id = id,
            .family_id = strField(c, "family_id") orelse "",
            .recipe_sha256 = strField(c, "recipe_sha256"),
            .recipe_path = strField(c, "recipe_path"),
            .script_path = script_path,
            .script_sha256 = script_sha,
            .blank_control = strField(c, "blank_control"),
            .dependencies = deps,
            .profile_ids = pids,
            .queries = queries.items,
            .apis = apis.items,
            .checkpoints = cps.items,
            .save_reopen = save_reopen,
        }) catch {};
    }
    var roots: std.ArrayList(RootDep) = .empty;
    for (arrField(v, "dependencies")) |x| {
        const id = strField(x, "dependency_id") orelse {
            d.err("bad_dependency", where, "a root dependency has no dependency_id", .{});
            continue;
        };
        const dw = fmtA(a, "dependency:{s}", .{id});
        if (idProblem(id)) |why| d.err("bad_id", dw, "dependency_id is invalid: {s}", .{why});
        const path = strField(x, "path") orelse "";
        if (pathProblem(path)) |why| d.err("bad_path", dw, "path is invalid: {s}", .{why});
        const sha = strField(x, "sha256") orelse "";
        if (!lowerHex64(sha)) d.err("bad_hash", dw, "sha256 is not a SHA256", .{});
        for (roots.items) |r| {
            if (eql(r.id, id)) d.err("id_collision", dw, "root dependency `{s}` appears twice", .{id});
        }
        roots.append(a, .{ .id = id, .path = path, .sha256 = sha }) catch {};
    }
    const q: Queue = .{ .sha256 = shaDup(a, bytes), .cases = cases.items, .profiles = profiles.items, .dependencies = roots.items };
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (q.cases) |*c| {
        const cw = fmtA(a, "case:{s}", .{c.case_id});
        const low = std.ascii.allocLowerString(a, c.case_id) catch continue;
        if ((seen.getOrPut(a, low) catch continue).found_existing) d.err("id_collision", where, "case `{s}` appears twice after ASCII lowercase", .{c.case_id});
        for (c.profile_ids) |pid| {
            if (q.findProfile(pid) == null) d.err("unknown_profile", cw, "profile `{s}` is not in the queue", .{pid});
        }
        // `dependencies` lists root dependency IDs under pack SCHEMA.md. A queue case is a control.
        for (c.dependencies) |dep| {
            if (q.findCase(dep) != null or inList(controls, dep)) d.err("dependency_kind", cw, "dependency `{s}` names a queue case. dependencies lists root dependency IDs. Name a control in blank_control", .{dep});
        }
        if (c.blank_control) |b| {
            if (q.findCase(b) != null) {
                if (blankCycle(&q, c)) d.err("dependency_cycle", cw, "the blank_control chain from `{s}` returns to `{s}`", .{ b, c.case_id });
                continue;
            }
            if (c.kind == .existing_document and inList(controls, b)) {
                c.external_control = true;
                continue;
            }
            d.err("unknown_dependency", cw, "blank_control `{s}` is not a queue case{s}", .{ b, if (c.kind == .existing_document) " or a case of the --controls queue" else "" });
        }
    }
    return q;
}

/// True when following blank_control from `c` through queue cases reaches `c` again.
fn blankCycle(q: *const Queue, c: *const QCase) bool {
    var at = c;
    var n: usize = 0;
    while (n <= q.cases.len) : (n += 1) {
        const next = q.findCase(at.blank_control orelse return false) orelse return false;
        if (eql(next.case_id, c.case_id)) return true;
        at = next;
    }
    return true;
}

/// Returns a reason when the real path of `root/rel` is outside the real path of `root`.
/// A symbolic link inside `root` that points outside it gives a reason. A path that does not
/// resolve gives null, and the read that follows reports it.
pub fn escapeProblem(a: Allocator, io: Io, root: []const u8, rel: []const u8) ?[]const u8 {
    const rr = Dir.cwd().realPathFileAlloc(io, root, a) catch return null;
    const full = fmtA(a, "{s}/{s}", .{ root, rel });
    const rp = Dir.cwd().realPathFileAlloc(io, full, a) catch return null;
    if (!std.mem.startsWith(u8, rp, fmtA(a, "{s}/", .{rr}))) return fmtA(a, "{s} resolves to {s}, which is outside {s}", .{ full, rp, rr });
    return null;
}

// ---------------------------------------------------------------------------
// export entries
// ---------------------------------------------------------------------------

/// A documented scripting call that writes one export format.
pub const Entry = struct {
    format: []const u8,
    api: []const u8,
    /// `$path` is the output path. `$opt:<name>` is a profile option value.
    args: []const []const u8,
    verification: []const u8,
    source: []const u8,
};

pub fn parseEntries(a: Allocator, d: *Diags, bytes: []const u8, where: []const u8) []Entry {
    const v = parseJson(a, bytes) catch |e| {
        d.err("invalid_json", where, "entries do not parse: {s}", .{@errorName(e)});
        return &.{};
    };
    if (!eql(strField(v, "schema") orelse "", schema_entries)) d.err("bad_schema", where, "schema must be {s}", .{schema_entries});
    var out: std.ArrayList(Entry) = .empty;
    for (arrField(v, "entries")) |e| {
        const fmt = strField(e, "format") orelse "";
        const api = strField(e, "api") orelse "";
        if (formatExt(fmt) == null) d.err("unknown_format", where, "entry format `{s}` is unknown", .{fmt});
        if (!std.mem.startsWith(u8, api, "vs.")) d.err("bad_entry", where, "entry api `{s}` does not start with vs.", .{api});
        const args = strings(a, arrField(e, "args"));
        if (!inList(args, "$path")) d.err("bad_entry", where, "entry `{s}` has no $path argument", .{api});
        out.append(a, .{ .format = fmt, .api = api, .args = args, .verification = strField(e, "verification") orelse "unverified", .source = strField(e, "source") orelse "" }) catch {};
    }
    return out.items;
}

pub fn findEntry(entries: []const Entry, format: []const u8) ?*const Entry {
    for (entries) |*e| {
        if (eql(e.format, format)) return e;
    }
    return null;
}

/// Resolves the argument templates of `e` for `path` and the options of `p`.
/// Returns null with `missing` set when a named option is absent or null.
pub fn resolveArgs(a: Allocator, e: *const Entry, p: *const Profile, path: []const u8, missing: *[]const u8) ?json.Value {
    var out = arr(a);
    for (e.args) |t| {
        if (eql(t, "$path")) {
            out.append(.{ .string = path }) catch {};
        } else if (std.mem.startsWith(u8, t, "$opt:")) {
            const name = t[5..];
            const v = field(p.options, name) orelse .null;
            if (v == .null) {
                missing.* = name;
                return null;
            }
            out.append(v) catch {};
        } else out.append(.{ .string = t }) catch {};
    }
    return .{ .array = out };
}

// ---------------------------------------------------------------------------
// driver interface
// ---------------------------------------------------------------------------

/// `operator_export` asks the operator to export the open document by hand. The driver returns
/// after the operator has written the payload `dialog_record` file and the export file.
pub const OpKind = enum { preflight, open, save_as, close, run_script, state, apply_state, query, export_file, dismiss_modal, collect, operator_export, ui_export };

/// Mutating operations change the open document or the app. A timeout or crash during one
/// leaves the native state unknown, so the run stops.
pub fn isMutating(k: OpKind) bool {
    return switch (k) {
        .open, .save_as, .close, .run_script, .apply_state, .collect => true,
        else => false,
    };
}

pub const Op = struct {
    kind: OpKind,
    case_id: []const u8 = "",
    profile_id: []const u8 = "",
    /// Document, script or export path. Native operations need an absolute path.
    path: []const u8 = "",
    /// File name of the document that `open` must make active.
    expect: []const u8 = "",
    /// JSON text for the operation.
    payload: []const u8 = "{}",
};

pub const Status = enum { ok, timeout, modal, failed, crashed, unsupported };

/// The one native message that the STL exporter shows for a document without exportable objects.
/// The driver presses OK on it only for an in-flight `vs.ExportSTL`. Any other text stays an unknown dialog.
pub const stl_rejection_message = "Export STL failed. There are no valid objects available for export.";
pub const stl_api = "vs.ExportSTL";
pub const rejection_outcome = "application_rejected";

/// The reply payload of a rejected export. It names the native message and states that no file was
/// produced. The engine accepts it only from an `unsupported` reply for the STL export.
fn rejectionPayload(a: Allocator, message: []const u8, bridge: []const u8) []const u8 {
    var o = Obj.init(a);
    o.str("outcome", rejection_outcome);
    o.str("api", stl_api);
    o.str("native_message", message);
    o.boolean("acknowledged", true);
    o.boolean("file_claimed", false);
    o.str("bridge_reply", bridge);
    return stringifyLine(a, o.value());
}

fn apiOfPayload(a: Allocator, payload: []const u8) []const u8 {
    const v = parseJson(a, payload) catch return "";
    return strField(v, "api") orelse "";
}

pub const Reply = struct {
    status: Status,
    detail: []const u8 = "",
    warnings: []const []const u8 = &.{},
    /// JSON text.
    payload: []const u8 = "{}",
    /// True when an action was sent and its outcome is unknown. The engine then latches
    /// reconciliation and never replays the operation by itself.
    uncertain: bool = false,
    /// True when the driver refused before it sent any action, for example because a deadline or the
    /// run budget passed. The engine then stops without a reconcile latch.
    refused: bool = false,
};

pub const DriverKind = enum { fake, native };

pub const Driver = struct {
    ptr: *anyopaque,
    kind: DriverKind,
    callFn: *const fn (ptr: *anyopaque, a: Allocator, op: Op) Reply,

    pub fn call(d: Driver, a: Allocator, op: Op) Reply {
        return d.callFn(d.ptr, a, op);
    }
};

// ---------------------------------------------------------------------------
// fake driver
// ---------------------------------------------------------------------------

pub const FaultKind = enum { timeout, modal, failed, crash, partial, missing, warning, leak, rejected };

pub const Fault = struct {
    op: OpKind,
    case_id: ?[]const u8,
    profile_id: ?[]const u8,
    kind: FaultKind,
    times: u32,
    used: u32 = 0,
};

const FakeSidecar = struct { format: []const u8, path: []const u8, content: []const u8 };

const FakeClass = struct { name: []const u8, visible: bool };

const FakeDoc = struct {
    name: []const u8,
    objects: std.ArrayList([]const u8) = .empty,
    classes: std.ArrayList(FakeClass) = .empty,
    /// Names of `vs.CreateLayer` calls.
    layers: std.ArrayList([]const u8) = .empty,
    shown_all: bool = false,
    /// `raw` lines of the document: object rows that `collect` writes after the layer and class rows.
    raw: std.ArrayList([]const u8) = .empty,
};

/// Simulates the app for engine tests. Documents are text files that start with `FAKEVWX/1`.
/// `run_script` reads `vs.SetName`, `vs.NameClass`, `vs.HideClass`, `rosetta_checkpoint` and
/// `rosetta_save_reopen` lines of the frozen scripts. `collect` writes `vwx-m3d-native-raw/1`
/// rows from the `raw` lines of the open document.
pub const FakeDriver = struct {
    a: Allocator,
    io: Io,
    missing_apis: []const []const u8 = &.{},
    can_close: bool = true,
    upi: f64 = 25.4,
    origin: [2]f64 = .{ 0, 0 },
    faults: []Fault = &.{},
    dead: bool = false,
    modal_open: bool = false,
    doc: ?FakeDoc = null,
    /// Overrides that the next opened document inherits. A `leak` fault sets it.
    sticky_show_all: bool = false,
    log: std.ArrayList([]const u8) = .empty,
    /// Files that an export of `format` writes next to its main file. `path` is relative to the
    /// directory of the main file and may be nested. Specs set them with `sidecars`.
    sidecars: []const FakeSidecar = &.{},
    /// Main file text by format. A spec sets it with `main_text`.
    main_text: json.Value = .null,

    pub fn initSpec(a: Allocator, io: Io, d: *Diags, bytes: []const u8, where: []const u8) ?FakeDriver {
        const v = parseJson(a, bytes) catch |e| {
            d.err("invalid_json", where, "fake spec does not parse: {s}", .{@errorName(e)});
            return null;
        };
        if (!eql(strField(v, "schema") orelse "", schema_fake)) {
            d.err("bad_schema", where, "schema must be {s}", .{schema_fake});
            return null;
        }
        var f: FakeDriver = .{ .a = a, .io = io };
        f.missing_apis = strings(a, arrField(v, "missing_apis"));
        if (boolField(v, "can_close")) |b| f.can_close = b;
        var sc: std.ArrayList(FakeSidecar) = .empty;
        for (arrField(v, "sidecars")) |x| sc.append(a, .{ .format = strField(x, "format") orelse "", .path = strField(x, "path") orelse "", .content = strField(x, "content") orelse "" }) catch {};
        f.sidecars = sc.items;
        f.main_text = field(v, "main_text") orelse .null;
        if (field(v, "units_per_inch")) |u| f.upi = numberOf(u) orelse f.upi;
        const o = arrField(v, "origin");
        if (o.len == 2) f.origin = .{ numberOf(o[0]) orelse 0, numberOf(o[1]) orelse 0 };
        var faults: std.ArrayList(Fault) = .empty;
        for (arrField(v, "faults")) |x| {
            const op = std.meta.stringToEnum(OpKind, strField(x, "op") orelse "") orelse {
                d.err("bad_fault", where, "fault op `{s}` is unknown", .{strField(x, "op") orelse ""});
                continue;
            };
            const kind = std.meta.stringToEnum(FaultKind, strField(x, "kind") orelse "") orelse {
                d.err("bad_fault", where, "fault kind `{s}` is unknown", .{strField(x, "kind") orelse ""});
                continue;
            };
            const times = if (field(x, "times")) |t| intOf(t) orelse 1 else 1;
            faults.append(a, .{ .op = op, .case_id = strField(x, "case_id"), .profile_id = strField(x, "profile_id"), .kind = kind, .times = @intCast(@max(times, 0)) }) catch {};
        }
        f.faults = faults.items;
        return f;
    }

    pub fn driver(f: *FakeDriver) Driver {
        return .{ .ptr = f, .kind = .fake, .callFn = callOpaque };
    }

    fn callOpaque(ptr: *anyopaque, a: Allocator, op: Op) Reply {
        const f: *FakeDriver = @ptrCast(@alignCast(ptr));
        return f.call(a, op);
    }

    /// Number of logged operations of `kind` for `case_id`.
    pub fn countOps(f: *const FakeDriver, kind: OpKind, case_id: []const u8) usize {
        var n: usize = 0;
        const prefix = fmtA(f.a, "{s}\t{s}\t", .{ @tagName(kind), case_id });
        for (f.log.items) |x| {
            if (std.mem.startsWith(u8, x, prefix)) n += 1;
        }
        return n;
    }

    fn takeFault(f: *FakeDriver, op: Op) ?FaultKind {
        for (f.faults) |*x| {
            if (x.op != op.kind or x.used >= x.times) continue;
            if (x.case_id) |c| if (!eql(c, op.case_id)) continue;
            if (x.profile_id) |p| if (!eql(p, op.profile_id)) continue;
            x.used += 1;
            return x.kind;
        }
        return null;
    }

    fn call(f: *FakeDriver, a: Allocator, op: Op) Reply {
        f.log.append(f.a, fmtA(f.a, "{s}\t{s}\t{s}", .{ @tagName(op.kind), op.case_id, op.profile_id })) catch {};
        if (f.dead) return .{ .status = .crashed, .detail = "fake app is not running" };
        if (op.kind == .dismiss_modal) {
            if (!f.modal_open) return .{ .status = .failed, .detail = "no modal dialog is open" };
            f.modal_open = false;
            return .{ .status = .ok, .detail = "fake modal dismissed" };
        }
        if (f.modal_open) return .{ .status = .modal, .detail = "fake modal dialog blocks the app" };
        var warnings: []const []const u8 = &.{};
        var leak_now = false;
        if (f.takeFault(op)) |k| switch (k) {
            .timeout => return .{ .status = .timeout, .detail = "fake operation did not finish" },
            .modal => {
                f.modal_open = true;
                return .{ .status = .modal, .detail = "fake modal dialog opened" };
            },
            .failed => return .{ .status = .failed, .detail = "fake operation raised an exception" },
            // The fake application's STL exporter refuses the document and the fake driver reports the
            // outcome that the native driver reports after it pressed OK. No file is written.
            .rejected => if (op.kind == .export_file) return .{ .status = .unsupported, .detail = "the application rejected the STL export", .payload = rejectionPayload(a, stl_rejection_message, "none") },
            .crash => {
                f.dead = true;
                f.doc = null;
                return .{ .status = .crashed, .detail = "fake app exited" };
            },
            .partial => if (op.kind == .export_file or op.kind == .operator_export) return f.exportBytes(a, op, .partial, &.{}) else if (op.kind == .collect) return f.collect(a, op, true),
            .missing => if (op.kind == .export_file) {
                return .{ .status = .ok, .detail = "fake export reported success and wrote nothing" };
            } else if (op.kind == .operator_export) {
                // The fake operator writes the export and omits the dialog record.
                return f.exportBytes(a, op, .whole, &.{});
            },
            .warning => warnings = a.dupe([]const u8, &.{fmtA(a, "fake warning for {s}", .{@tagName(op.kind)})}) catch &.{},
            // On apply_state the next opened document inherits show_all. On open this document gets it.
            // On collect the open document gets it after the rows are written. On operator_export
            // the fake operator shows every class after the export.
            .leak => if (op.kind == .apply_state or op.kind == .open) {
                f.sticky_show_all = true;
            } else if (op.kind == .collect or op.kind == .operator_export or op.kind == .export_file) {
                leak_now = true;
            },
        };
        var r = f.perform(a, op);
        if (leak_now and r.status == .ok) f.doc.?.shown_all = true;
        if (r.status == .ok and warnings.len > 0) r.warnings = warnings;
        return r;
    }

    fn missing(f: *const FakeDriver, api: []const u8) bool {
        return inList(f.missing_apis, api);
    }

    fn serialize(f: *FakeDriver, a: Allocator, doc: *const FakeDoc) []const u8 {
        _ = f;
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, "FAKEVWX/1\n") catch {};
        for (doc.objects.items) |o| out.appendSlice(a, fmtA(a, "object\t{s}\n", .{o})) catch {};
        for (doc.classes.items) |c| out.appendSlice(a, fmtA(a, "class\t{s}\t{d}\n", .{ c.name, @intFromBool(c.visible) })) catch {};
        for (doc.layers.items) |l| out.appendSlice(a, fmtA(a, "layer\t{s}\n", .{l})) catch {};
        return out.items;
    }

    fn perform(f: *FakeDriver, a: Allocator, op: Op) Reply {
        switch (op.kind) {
            .preflight => return f.preflight(a, op),
            .open => {
                // The app keeps one active document. Opening another one replaces it.
                const bytes = readAll(f.a, f.io, op.path) catch return .{ .status = .failed, .detail = "cannot read document" };
                if (!std.mem.startsWith(u8, bytes, "FAKEVWX/1\n")) return .{ .status = .failed, .detail = "file is not a fake document" };
                var doc: FakeDoc = .{ .name = f.a.dupe(u8, basename(op.path)) catch "" };
                var lines = std.mem.splitScalar(u8, bytes, '\n');
                _ = lines.next();
                while (lines.next()) |ln| {
                    var cols = std.mem.splitScalar(u8, ln, '\t');
                    const kind = cols.next() orelse continue;
                    if (eql(kind, "object")) doc.objects.append(f.a, f.a.dupe(u8, cols.next() orelse "") catch "") catch {};
                    if (eql(kind, "layer")) doc.layers.append(f.a, f.a.dupe(u8, cols.next() orelse "") catch "") catch {};
                    if (eql(kind, "raw")) doc.raw.append(f.a, f.a.dupe(u8, ln["raw\t".len..]) catch "") catch {};
                    if (eql(kind, "class")) {
                        const name = f.a.dupe(u8, cols.next() orelse "") catch "";
                        doc.classes.append(f.a, .{ .name = name, .visible = eql(cols.next() orelse "1", "1") }) catch {};
                    }
                }
                if (f.sticky_show_all) {
                    doc.shown_all = true;
                    f.sticky_show_all = false;
                }
                f.doc = doc;
                return .{ .status = .ok, .payload = fmtA(a, "{{\"document\":\"{s}\"}}", .{doc.name}) };
            },
            .close => {
                if (!f.can_close) return .{ .status = .unsupported, .detail = "fake app has no close call" };
                if (f.doc == null) return .{ .status = .failed, .detail = "no document is open" };
                f.doc = null;
                return .{ .status = .ok };
            },
            .save_as => {
                const doc = &(f.doc orelse return .{ .status = .failed, .detail = "no document is open" });
                const bytes = f.serialize(a, doc);
                // A strict run saves its own work copy before the close. The payload names it.
                const own = if (parseJson(a, op.payload)) |pv| (boolField(pv, "overwrite_own") orelse false) else |_| false;
                if (own and exists(f.io, op.path)) {
                    var fh = Dir.cwd().createFile(f.io, op.path, .{ .truncate = true }) catch return .{ .status = .failed, .detail = "the work copy is not writable" };
                    defer fh.close(f.io);
                    fh.writeStreamingAll(f.io, bytes) catch return .{ .status = .failed, .detail = "the work copy is not writable" };
                } else writeNew(f.io, op.path, bytes) catch return .{ .status = .failed, .detail = "save target exists or is not writable" };
                f.doc.?.name = f.a.dupe(u8, basename(op.path)) catch "";
                return .{ .status = .ok };
            },
            .run_script => return f.runScript(a, op),
            .state => {
                const doc = &(f.doc orelse return .{ .status = .failed, .detail = "no document is open" });
                return .{ .status = .ok, .payload = f.stateJson(a, doc) };
            },
            .apply_state => {
                if (f.doc == null) return .{ .status = .failed, .detail = "no document is open" };
                const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
                const hc = strField(field(v, "overrides") orelse .null, "hidden_content");
                if (hc) |x| {
                    if (eql(x, "show_all")) f.doc.?.shown_all = true else if (!eql(x, "as_saved")) return .{ .status = .unsupported, .detail = "hidden_content value is unknown" };
                }
                return .{ .status = .ok };
            },
            .query => {
                const doc = &(f.doc orelse return .{ .status = .failed, .detail = "no document is open" });
                return .{ .status = .ok, .payload = f.queryJson(a, doc, op) };
            },
            .export_file => return f.exportBytes(a, op, .whole, &.{}),
            .operator_export => {
                const r = f.exportBytes(a, op, .whole, &.{});
                if (r.status != .ok) return r;
                const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
                const dp = strField(v, "dialog_record") orelse return .{ .status = .failed, .detail = "payload has no dialog_record" };
                writeNew(f.io, dp, "fake operator dialog record\n") catch return .{ .status = .failed, .detail = "dialog record exists" };
                return r;
            },
            .collect => return f.collect(a, op, false),
            .dismiss_modal => unreachable,
            .ui_export => return .{ .status = .unsupported, .detail = "the fake driver has no native UI" },
        }
    }

    /// Writes raw rows to payload `out`. `partial` omits the end row.
    fn collect(f: *FakeDriver, a: Allocator, op: Op, partial: bool) Reply {
        const doc = &(f.doc orelse return .{ .status = .failed, .detail = "no document is open" });
        const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
        const script = readAll(a, f.io, op.path) catch return .{ .status = .failed, .detail = "cannot read the collector" };
        const sh = sha256Hex(script);
        if (!eql(&sh, strField(v, "script_sha256") orelse "")) return .{ .status = .failed, .detail = fmtA(a, "ValueError: collector SHA256 {s} differs from the queue", .{&sh}) };
        const spec_bytes = readAll(a, f.io, strField(v, "spec") orelse "") catch return .{ .status = .failed, .detail = "cannot read the spec" };
        const spec = parseJson(a, spec_bytes) catch return .{ .status = .failed, .detail = "spec is not JSON" };
        const out_path = strField(v, "out") orelse return .{ .status = .failed, .detail = "payload has no out" };
        var lines: std.ArrayList(u8) = .empty;
        var rows: usize = 0;
        const W = struct {
            fn row(l: *std.ArrayList(u8), al: Allocator, n: *usize, text: []const u8) void {
                l.appendSlice(al, text) catch {};
                l.append(al, '\n') catch {};
                n.* += 1;
            }
        };
        var end = Obj.init(a);
        end.str("rec", "end");
        if (!inList(strings(a, arrField(spec, "expect_files")), doc.name)) {
            end.str("status", "error");
            end.str("reason", fmtA(a, "RuntimeError: front document is '{s}'. The spec expects one of its expect_files", .{doc.name}));
        } else {
            var m = Obj.init(a);
            m.str("rec", "meta");
            m.str("schema", schema_raw);
            m.str("case_id", strField(spec, "case_id") orelse "");
            m.str("spec_revision", strField(spec, "spec_revision") orelse "");
            m.str("file", doc.name);
            var units = arr(a);
            for ([_]json.Value{ .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 }, num(f.upi), .{ .string = "fake" }, .{ .string = "fake" } }) |x| units.append(x) catch {};
            var uo = Obj.init(a);
            uo.put("v", .{ .array = units });
            m.put("units", uo.value());
            var org = arr(a);
            org.append(num(f.origin[0])) catch {};
            org.append(num(f.origin[1])) catch {};
            var oo = Obj.init(a);
            oo.put("v", .{ .array = org });
            m.put("origin", oo.value());
            var vo = Obj.init(a);
            vo.str("v", "fake");
            m.put("version", vo.value());
            W.row(&lines, a, &rows, stringifyLine(a, m.value()));
            W.row(&lines, a, &rows, "{\"rec\":\"layer\",\"index\":1,\"name\":\"Design Layer-1\",\"type\":1,\"vis\":{\"v\":0},\"elevation\":{\"v\":0},\"scale\":{\"v\":1}}");
            for (doc.classes.items, 1..) |c, i| {
                const visible = c.visible or doc.shown_all;
                W.row(&lines, a, &rows, fmtA(a, "{{\"rec\":\"class\",\"index\":{d},\"name\":{s},\"vis\":{{\"v\":{d}}}}}", .{ i, stringifyLine(a, .{ .string = c.name }), @as(i32, if (visible) 0 else -1) }));
            }
            for (doc.raw.items) |x| W.row(&lines, a, &rows, x);
            end.str("status", "ok");
            end.int("rows", @intCast(rows + 1));
        }
        if (!partial) W.row(&lines, a, &rows, stringifyLine(a, end.value()));
        writeNew(f.io, out_path, lines.items) catch return .{ .status = .failed, .detail = "raw target exists or is not writable" };
        var r = Obj.init(a);
        r.put("end", if (partial) .null else end.value());
        return .{ .status = .ok, .payload = stringifyLine(a, r.value()) };
    }

    fn preflight(f: *FakeDriver, a: Allocator, op: Op) Reply {
        const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
        var apis = Obj.init(a);
        for (arrField(v, "apis")) |x| {
            if (x != .string) continue;
            apis.boolean(x.string, !f.missing(x.string));
        }
        var o = Obj.init(a);
        o.str("schema", schema_capabilities);
        o.str("driver", "fake");
        o.put("apis", apis.value());
        o.boolean("can_close", f.can_close);
        var rel = Obj.init(a);
        rel.put("version", .null);
        rel.put("build", .null);
        rel.put("edition", .null);
        rel.put("platform", .null);
        rel.str("verification", "unverified");
        o.put("release", rel.value());
        o.put("raw_version", .null);
        return .{ .status = .ok, .payload = stringifyLine(a, o.value()) };
    }

    fn pyString(line: []const u8, after: []const u8) ?[]const u8 {
        const i = std.mem.indexOf(u8, line, after) orelse return null;
        const rest = line[i + after.len ..];
        const q0 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        const q1 = std.mem.indexOfScalarPos(u8, rest, q0 + 1, '"') orelse return null;
        return rest[q0 + 1 .. q1];
    }

    fn runScript(f: *FakeDriver, a: Allocator, op: Op) Reply {
        if (f.doc == null) return .{ .status = .failed, .detail = "no document is open" };
        const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
        const cp_dir = strField(v, "checkpoint_dir") orelse return .{ .status = .failed, .detail = "payload has no checkpoint_dir" };
        const text = readAll(a, f.io, op.path) catch return .{ .status = .failed, .detail = "cannot read script" };
        var cps = arr(a);
        var reached = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |ln| {
            if (ln.len == 0 or ln[0] == '#') continue;
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, ln, i, "vs.")) |at| : (i = at + 3) {
                const end = std.mem.indexOfScalarPos(u8, ln, at, '(') orelse continue;
                const api = ln[at..end];
                if (f.missing(api)) return .{ .status = .failed, .detail = fmtA(a, "AttributeError: module 'vs' has no attribute '{s}'", .{api[3..]}) };
            }
            const doc = &f.doc.?;
            if (pyString(ln, "vs.SetName(")) |name| doc.objects.append(f.a, f.a.dupe(u8, name) catch "") catch {};
            if (pyString(ln, "vs.CreateLayer(")) |name| doc.layers.append(f.a, f.a.dupe(u8, name) catch "") catch {};
            if (pyString(ln, "vs.NameClass(")) |name| doc.classes.append(f.a, .{ .name = f.a.dupe(u8, name) catch "", .visible = true }) catch {};
            if (pyString(ln, "vs.HideClass(")) |name| {
                for (doc.classes.items) |*c| {
                    if (eql(c.name, name)) c.visible = false;
                }
            }
            if (pyString(ln, "rosetta_checkpoint(")) |cid| {
                const p = fmtA(a, "{s}/checkpoint-{s}.vwx", .{ cp_dir, cid });
                writeNew(f.io, p, f.serialize(a, doc)) catch return .{ .status = .failed, .detail = "checkpoint target exists" };
                var c = Obj.init(a);
                c.str("id", cid);
                c.str("path", p);
                cps.append(c.value()) catch {};
            }
            if (pyString(ln, "rosetta_dependency(")) |did| {
                const dx = field(field(v, "dependencies") orelse .null, did) orelse
                    return .{ .status = .failed, .detail = fmtA(a, "KeyError: dependency '{s}' is not in the case payload", .{did}) };
                const dp = strField(dx, "path") orelse "";
                const have = hashFileDup(a, f.io, dp) orelse return .{ .status = .failed, .detail = fmtA(a, "FileNotFoundError: {s}", .{dp}) };
                if (!eql(have, strField(dx, "sha256") orelse "")) return .{ .status = .failed, .detail = fmtA(a, "ValueError: dependency '{s}' has sha256 {s}", .{ did, have }) };
            }
            if (std.mem.indexOf(u8, ln, "rosetta_save_reopen()") != null) reached = true;
        }
        var o = Obj.init(a);
        o.put("checkpoints", .{ .array = cps });
        o.boolean("save_reopen_reached", reached);
        return .{ .status = .ok, .payload = stringifyLine(a, o.value()) };
    }

    fn stateJson(f: *FakeDriver, a: Allocator, doc: *const FakeDoc) []const u8 {
        var o = Obj.init(a);
        o.str("schema", schema_state);
        var classes = arr(a);
        var none = Obj.init(a);
        none.str("name", "None");
        none.boolean("visible", true);
        classes.append(none.value()) catch {};
        for (doc.classes.items) |c| {
            var x = Obj.init(a);
            x.str("name", c.name);
            x.boolean("visible", c.visible or doc.shown_all);
            classes.append(x.value()) catch {};
        }
        o.put("classes", .{ .array = classes });
        var layers = arr(a);
        var l = Obj.init(a);
        l.str("name", "Design Layer-1");
        l.boolean("visible", true);
        layers.append(l.value()) catch {};
        o.put("layers", .{ .array = layers });
        var u = Obj.init(a);
        u.put("units_per_inch", num(f.upi));
        o.put("units", u.value());
        var org = arr(a);
        org.append(num(f.origin[0])) catch {};
        org.append(num(f.origin[1])) catch {};
        o.put("origin", .{ .array = org });
        return stringifyLine(a, o.value());
    }

    /// Fixed raw returns of the RAW allowlist. The element counts follow vs.py:18998, 13724,
    /// 19456 and the 4 names of the vs.py:19649 Python return.
    fn fakeRaw(a: Allocator, rc: []const u8) json.Value {
        const text = if (eql(rc, "GetTextStyleRef"))
            "0"
        else if (eql(rc, "GetGISOriginN"))
            "[false,0,0,0]"
        else if (eql(rc, "GetUnits"))
            "[0,0,0,25.4,\"mm\",\"sq mm\"]"
        else if (eql(rc, "GetView"))
            "[0,0,0,[0,0,0]]"
        else
            "null";
        return parseJson(a, text) catch .null;
    }

    fn fakeValue(a: Allocator, q: Query, doc: *const FakeDoc) ?json.Value {
        const vals = struct {
            fn list(al: Allocator, xs: []const f64) json.Value {
                var x = arr(al);
                for (xs) |n| x.append(num(n)) catch {};
                return .{ .array = x };
            }
        };
        const qt = q.quantity;
        if (eql(qt, "point3")) return vals.list(a, &.{ 12.5, 7.25, 0.5 });
        if (eql(qt, "bounds3")) return vals.list(a, &.{ 12.5, 7.25, 0, 61, 33.5, 14.25 });
        if (eql(qt, "transform4x4")) return vals.list(a, &.{ 1, 0, 0, 2.5, 0, 1, 0, 1.25, 0, 0, 1, 0, 0, 0, 0, 1 });
        if (eql(qt, "length")) return num(48.5);
        if (eql(qt, "area")) return num(1278.125);
        if (eql(qt, "volume")) return num(9512.5);
        if (eql(qt, "angle")) return num(23.5);
        if (eql(qt, "count")) {
            const n: i64 = @intCast(doc.objects.items.len);
            return .{ .integer = if (eql(q.api, "vs.GetVPCropObject")) @min(n, 1) else n };
        }
        if (eql(qt, "topology_counts")) {
            var o = Obj.init(a);
            o.int("faces", 7);
            o.int("edges", 15);
            return o.value();
        }
        if (eql(qt, "visibility")) return .{ .bool = true };
        if (eql(qt, "name")) return .{ .string = if (eql(q.api, "vs.GetFName")) doc.name else q.object_id };
        if (eql(qt, "layer_name")) return .{ .string = if (doc.layers.items.len > 0) doc.layers.items[0] else "Design Layer-1" };
        if (eql(qt, "class_name")) return .{ .string = if (doc.classes.items.len > 0) doc.classes.items[0].name else "None" };
        if (eql(qt, "knots")) return vals.list(a, &.{ 0, 0, 0, 0, 1, 1, 1, 1 });
        if (eql(qt, "weights")) return vals.list(a, &.{ 1, 0.5, 0.5, 1 });
        if (eql(qt, "domain")) return vals.list(a, &.{ 0, 1 });
        if (eql(qt, "control_points")) {
            var x = arr(a);
            for ([_][3]f64{ .{ 2.5, 1.25, 0.5 }, .{ 10, 4, 0.5 }, .{ 20, 9, 0.5 }, .{ 31, 3, 0.5 } }) |p| x.append(vals.list(a, &p)) catch {};
            return .{ .array = x };
        }
        return null;
    }

    /// Resolves the layer arguments against the `vs.CreateLayer` names of the document. GetCVis
    /// gives code 0 for a visible class and -1 for a hidden class.
    fn fakeCollect(a: Allocator, q: Query, c: *const Collector, doc: *const FakeDoc, r: *Obj) void {
        for (q.args orelse &.{}) |x| {
            if (!eql(strField(x, "handle") orelse "", "layer")) continue;
            const name = strField(x, "name").?;
            if (!inList(doc.layers.items, name)) {
                r.str("status", "layer_not_found");
                r.str("reason", fmtA(a, "GetLayerByName('{s}') returned a nil handle", .{name}));
                return;
            }
        }
        if (c.raw_only) |why| {
            r.str("status", "raw_only");
            r.str("reason", why);
            var raw = arr(a);
            raw.append(.{ .bool = true }) catch {};
            raw.append(.{ .integer = 0 }) catch {};
            r.put("raw", .{ .array = raw });
            return;
        }
        if (eql(c.api, "vs.GetCVis")) {
            const name = q.args.?[0].string;
            var visible = true;
            for (doc.classes.items) |k| {
                if (eql(k.name, name)) visible = k.visible or doc.shown_all;
            }
            r.str("status", "ok");
            r.put("raw", .{ .integer = if (visible) 0 else -1 });
            r.put("value", .{ .bool = visible });
            return;
        }
        const val = fakeValue(a, q, doc) orelse {
            r.str("status", "collector_unimplemented");
            return;
        };
        r.str("status", "ok");
        r.put("value", val);
        r.put("raw", val);
        if (eql(q.quantity, "control_points")) r.str("point_convention", "cartesian");
    }

    fn queryJson(f: *FakeDriver, a: Allocator, doc: *const FakeDoc, op: Op) []const u8 {
        const v = parseJson(a, op.payload) catch .null;
        var results = arr(a);
        var objects = Obj.init(a);
        for (arrField(v, "queries")) |qv| {
            const q = queryOf(qv, "");
            var r = Obj.init(a);
            if (qv == .object) {
                var it = qv.object.iterator();
                while (it.next()) |en| r.put(en.key_ptr.*, en.value_ptr.*);
            }
            const found = eql(q.object_id, "document") or inList(doc.objects.items, q.object_id);
            var ob = Obj.init(a);
            ob.boolean("found", found);
            ob.str("type", if (eql(q.object_id, "document")) "document" else "fake");
            objects.put(q.object_id, ob.value());
            const qp = planQuery(a, q);
            if (f.missing(q.api)) {
                r.str("status", "api_absent");
            } else if (qp.status) |st| {
                r.str("status", st);
                r.str("reason", qp.detail);
                if (qp.raw_call) |rc| if (found) r.put("raw", fakeRaw(a, rc));
            } else if (!found) {
                r.str("status", "not_found");
            } else fakeCollect(a, q, qp.collector.?, doc, &r);
            results.append(r.value()) catch {};
        }
        var o = Obj.init(a);
        o.str("schema", schema_query);
        o.str("driver", "fake");
        o.str("document", doc.name);
        o.put("api_version", .null);
        var u = Obj.init(a);
        u.put("units_per_inch", num(f.upi));
        o.put("units", u.value());
        var org = arr(a);
        org.append(num(f.origin[0])) catch {};
        org.append(num(f.origin[1])) catch {};
        o.put("origin", .{ .array = org });
        o.put("objects", objects.value());
        o.put("results", .{ .array = results });
        return stringifyLine(a, o.value());
    }

    const Cut = enum { whole, partial };

    fn exportBytes(f: *FakeDriver, a: Allocator, op: Op, cut: Cut, warnings: []const []const u8) Reply {
        if (f.doc == null) return .{ .status = .failed, .detail = "no document is open" };
        const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
        const fmt = strField(v, "format") orelse "";
        const bytes = strField(f.main_text, fmt) orelse fakeExport(a, fmt, f.doc.?.name);
        const n = if (cut == .partial) bytes.len / 2 else bytes.len;
        writeNew(f.io, op.path, bytes[0..n]) catch return .{ .status = .failed, .detail = "export target exists" };
        if (cut != .partial) {
            for (f.sidecars) |s| {
                if (!eql(s.format, fmt)) continue;
                const to = fmtA(a, "{s}/{s}", .{ dirname(op.path), s.path });
                mkdirp(f.io, dirname(to)) catch return .{ .status = .failed, .detail = "cannot create the sidecar directory" };
                writeNew(f.io, to, s.content) catch return .{ .status = .failed, .detail = "sidecar target exists" };
            }
        }
        return .{ .status = .ok, .warnings = warnings };
    }
};

/// Synthetic export bytes with the magic and trailer that `sniffExport` checks.
pub fn fakeExport(a: Allocator, fmt: []const u8, doc: []const u8) []const u8 {
    if (eql(fmt, "dwg")) return fmtA(a, "AC1032 fake DWG of {s}\n", .{doc});
    if (eql(fmt, "dxf")) return fmtA(a, "  0\nSECTION\n  2\nHEADER\n999\nfake DXF of {s}\n  0\nENDSEC\n  0\nEOF\n", .{doc});
    if (eql(fmt, "parasolid")) return fmtA(a, "**ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz**************************\nfake {s}\n", .{doc});
    if (eql(fmt, "sat")) return fmtA(a, "700 0 1 0\nfake SAT of {s}\nEnd-of-ACIS-data\n", .{doc});
    if (eql(fmt, "stl")) {
        var b = a.alloc(u8, 84 + 50 * 2) catch return "";
        @memset(b, 0);
        @memcpy(b[0..8], "fake STL");
        std.mem.writeInt(u32, b[80..84], 2, .little);
        return b;
    }
    if (eql(fmt, "obj")) return fmtA(a, "# fake OBJ of {s}\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n", .{doc});
    if (eql(fmt, "gltf")) {
        var b = a.alloc(u8, 20) catch return "";
        @memset(b, ' ');
        @memcpy(b[0..4], "glTF");
        std.mem.writeInt(u32, b[4..8], 2, .little);
        std.mem.writeInt(u32, b[8..12], 20, .little);
        return b;
    }
    if (eql(fmt, "fbx")) return "Kaydara FBX Binary  \x00\x1a\x00fake";
    if (eql(fmt, "3ds")) {
        var b = a.alloc(u8, 16) catch return "";
        @memset(b, 0);
        b[0] = 0x4d;
        b[1] = 0x4d;
        std.mem.writeInt(u32, b[2..6], 16, .little);
        return b;
    }
    if (eql(fmt, "pdf")) return fmtA(a, "%PDF-1.7\n% fake PDF of {s}\ntrailer\n%%EOF\n", .{doc});
    if (eql(fmt, "svg")) return fmtA(a, "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"><desc>fake {s}</desc>\n</svg>\n", .{doc});
    if (eql(fmt, "png")) return "\x89PNG\r\n\x1a\nfakefakefake\x00\x00\x00\x00IEND\xaeB`\x82";
    if (eql(fmt, "jpeg")) return "\xff\xd8\xff\xe0fake JPEG\xff\xd9";
    if (eql(fmt, "ifc")) return fmtA(a, "ISO-10303-21;\nHEADER;\nFILE_NAME('{s}');\nENDSEC;\nEND-ISO-10303-21;\n", .{doc});
    if (eql(fmt, "xlsx")) return "PK\x03\x04fake XLSX PK\x05\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    if (eql(fmt, "step")) return fmtA(a, "ISO-10303-21;\nHEADER;\nFILE_NAME('{s}');\nENDSEC;\nEND-ISO-10303-21;\n", .{doc});
    if (eql(fmt, "usd")) return fmtA(a, "#usda 1.0\n(\n    doc = \"fake USD of {s}\"\n)\n", .{doc});
    if (eql(fmt, "iges")) {
        // One 80 column terminate record. Column 73 is the section letter.
        return fmtA(a, "{s: <72}T      1\n", .{"S      1G      1D      2P      2"});
    }
    if (eql(fmt, "3dm")) return fmtA(a, "3D Geometry File Format        1\nfake 3DM of {s}\n", .{doc});
    return fmtA(a, "fake {s} of {s}\n", .{ fmt, doc });
}

// ---------------------------------------------------------------------------
// collectors and normalization
// ---------------------------------------------------------------------------

pub const Dim = enum { length, area, volume, angle, dimensionless, none };

pub fn quantityDim(q: []const u8) ?Dim {
    const table = .{
        .{ "point3", Dim.length },                 .{ "vector3", Dim.length },           .{ "bounds3", Dim.length },
        .{ "transform4x4", Dim.length },           .{ "length", Dim.length },            .{ "radius", Dim.length },
        .{ "control_points", Dim.length },         .{ "area", Dim.area },                .{ "volume", Dim.volume },
        .{ "angle", Dim.angle },                   .{ "direction3", Dim.dimensionless }, .{ "knots", Dim.dimensionless },
        .{ "weights", Dim.dimensionless },         .{ "domain", Dim.dimensionless },     .{ "count", Dim.dimensionless },
        .{ "topology_counts", Dim.dimensionless }, .{ "visibility", Dim.none },          .{ "name", Dim.none },
        .{ "class_name", Dim.none },               .{ "layer_name", Dim.none },
    };
    inline for (table) |row| {
        if (eql(q, row[0])) return row[1];
    }
    return null;
}

/// One (api, quantity) pair that the bridge collects. `note` names the conversion it applies.
/// `check` names the `licensed_checks` entry that verifies the conversion.
/// `object` is the handle of the query object. `layer` is the handle of a named layer.
pub const ArgKind = enum { object, layer, string, integer };

/// `component` is the registered component of the record. A queue query that names a
/// component selects the collector with that component. A query without one selects the only
/// collector of its (api, quantity). `args` lists the argument kinds that the query must give.
/// `units_documented` false writes `units` null. `raw_only` names why the result keeps the raw
/// return and no value.
pub const Collector = struct {
    api: []const u8,
    quantity: []const u8,
    note: []const u8,
    check: []const u8 = "",
    component: []const u8 = "",
    /// Registry revision 4 cardinality component. A query that names it gets it as the
    /// record component. A query without a component gets `component`.
    named: []const u8 = "",
    args: []const ArgKind = &.{},
    units_documented: bool = true,
    raw_only: ?[]const u8 = null,
};

pub const collectors = [_]Collector{
    .{ .api = "vs.ClassNum", .quantity = "count", .note = "class count", .named = "classes" },
    .{ .api = "vs.FInGroup", .quantity = "count", .note = "FInGroup, then NextObj until a nil handle", .named = "members" },
    .{ .api = "vs.Count", .quantity = "count", .note = "vs.Count('ALL') object count", .named = "objects" },
    .{ .api = "vs.Get3DCntr", .quantity = "point3", .note = "first 3 numbers of the flattened return" },
    .{ .api = "vs.Get3DInfo", .quantity = "bounds3", .note = "derived bounds: Get3DCntr center plus or minus half of the Get3DInfo spans. The call returns delta-Y, delta-X, delta-Z in that order" },
    .{ .api = "vs.GetBBox", .quantity = "bounds3", .note = "GetBBox x and y, z from Get3DCntr and Get3DInfo depth" },
    .{ .api = "vs.GetAngleToNorth", .quantity = "angle", .note = "the REAL return. vs.py:10420 gives no unit", .check = "unit_undocumented", .component = "document.angle_to_north", .units_documented = false },
    .{ .api = "vs.GetArc", .quantity = "angle", .note = "startAngleR, element 0 of the vs.py:10432 return. vs.py gives no unit", .check = "unit_undocumented", .component = "arc.start_angle", .units_documented = false },
    .{ .api = "vs.GetArc", .quantity = "angle", .note = "arcAngleR, element 1 of the vs.py:10432 return. vs.py gives no unit", .check = "unit_undocumented", .component = "arc.sweep_angle", .units_documented = false },
    .{ .api = "vs.GetCVis", .quantity = "visibility", .note = "args[0] is the class name. VWClass.h:15-19 gives code 0 visible and -1 hidden. Other codes keep the raw return only", .args = &.{.string} },
    .{ .api = "vs.GetGISOriginN", .quantity = "angle", .note = "outAngleToNorth, element 3 of the vs.py:13724 return, when element 0 is True. vs.py gives no unit", .check = "unit_undocumented", .component = "gis.angle_to_north", .units_documented = false },
    .{ .api = "vs.GetRField", .quantity = "name", .note = "field string. args are the object, the record name and the field name", .args = &.{ .object, .string, .string } },
    .{ .api = "vs.GetRRDiam", .quantity = "length", .note = "xDiam, element 0 of the vs.py:17834 return. vs.py gives no unit", .check = "unit_undocumented", .component = "rrect.diam.x", .units_documented = false },
    .{ .api = "vs.GetRRDiam", .quantity = "length", .note = "yDiam, element 1 of the vs.py:17834 return. vs.py gives no unit", .check = "unit_undocumented", .component = "rrect.diam.y", .units_documented = false },
    .{ .api = "vs.GetVPLayerVisibility", .quantity = "visibility", .note = "args are the viewport and a layer handle. The (BOOLEAN, visibilityType) return of vs.py:19978 stays raw", .check = "vp_layer_visibility_code", .args = &.{ .object, .layer }, .raw_only = "no accepted source maps the visibilityType codes of GetVPLayerVisibility" },
    .{ .api = "vs.GetWSCellString", .quantity = "name", .note = "displayed cell string. args are the worksheet, the row and the column", .args = &.{ .object, .integer, .integer } },
    .{ .api = "vs.GetClass", .quantity = "class_name", .note = "class name string" },
    .{ .api = "vs.GetDimText", .quantity = "name", .note = "dimension text string" },
    .{ .api = "vs.GetEntityMatrix", .quantity = "transform4x4", .note = "Rz * Rx * diag(symbol scale) with the Get3DOrientation mirror on z. A false return or a nonzero rotY raises", .check = "entity_matrix_order" },
    .{ .api = "vs.GetFName", .quantity = "name", .note = "active document file name" },
    .{ .api = "vs.GetLName", .quantity = "layer_name", .note = "layer name of a layer handle" },
    .{ .api = "vs.GetLayerElevation", .quantity = "length", .note = "baseElev, the first value of the return", .check = "layer_elevation" },
    .{ .api = "vs.GetLocPt", .quantity = "point3", .note = "x and y with z 0" },
    .{ .api = "vs.GetLocus3D", .quantity = "point3", .note = "first 3 numbers of the flattened return" },
    .{ .api = "vs.GetMeshVertsCnt", .quantity = "count", .note = "mesh vertex count", .named = "mesh.vertices" },
    .{ .api = "vs.GetName", .quantity = "name", .note = "object name string" },
    .{ .api = "vs.GetObjMaterialName", .quantity = "name", .note = "material name. A false return raises" },
    .{ .api = "vs.GetOrigin", .quantity = "point3", .note = "document origin x and y with z 0" },
    .{ .api = "vs.GetPolyPt", .quantity = "point3", .note = "vertex 1 with z 0 from the polygon plane", .check = "vertex_index_base" },
    .{ .api = "vs.GetPolyPt3D", .quantity = "point3", .note = "vertex 0. vs.py:17170 gives the index range 0 to n-1", .check = "vertex_index_base" },
    .{ .api = "vs.GetSegPt1", .quantity = "point3", .note = "start point x and y with z 0" },
    .{ .api = "vs.GetSegPt2", .quantity = "point3", .note = "end point x and y with z 0" },
    .{ .api = "vs.GetSymLoc3D", .quantity = "point3", .note = "first 3 numbers of the flattened return" },
    .{ .api = "vs.GetSymName", .quantity = "name", .note = "symbol definition name" },
    .{ .api = "vs.GetSymRot", .quantity = "angle", .note = "degrees" },
    .{ .api = "vs.GetText", .quantity = "name", .note = "text string" },
    .{ .api = "vs.GetTypeN", .quantity = "topology_counts", .note = "object type code under key type_code" },
    .{ .api = "vs.GetVPCropObject", .quantity = "count", .note = "1 for a crop handle, 0 for a nil handle", .named = "crop_objects" },
    .{ .api = "vs.GetVectorFill", .quantity = "name", .note = "hatch name. A false return raises" },
    .{ .api = "vs.GetVertNum", .quantity = "count", .note = "vertex count", .named = "vertices" },
    .{ .api = "vs.GetWorkingPlaneN", .quantity = "transform4x4", .note = "columns uVec, normal x uVec, normal and center. A non-orthogonal or zero vector raises", .check = "working_plane_axes" },
    .{ .api = "vs.HCenter", .quantity = "point3", .note = "logical center x and y with z 0" },
    .{ .api = "vs.HHeight", .quantity = "length", .note = "object height" },
    .{ .api = "vs.HLength", .quantity = "length", .note = "object length" },
    .{ .api = "vs.HWidth", .quantity = "length", .note = "object width" },
    .{ .api = "vs.NurbsCurveEvalPt", .quantity = "domain", .note = "first and last knot of curve piece 0" },
    .{ .api = "vs.NurbsDegree", .quantity = "count", .note = "degree of curve piece 0", .named = "degree" },
    .{ .api = "vs.NurbsGetPt3D", .quantity = "control_points", .note = "cartesian points of curve piece 0" },
    .{ .api = "vs.NurbsGetWeight", .quantity = "weights", .note = "weights of curve piece 0" },
    .{ .api = "vs.NurbsKnot", .quantity = "knots", .note = "knots of curve piece 0" },
    .{ .api = "vs.NumRecords", .quantity = "count", .note = "attached record count", .named = "records" },
    .{ .api = "vs.ObjArea", .quantity = "area", .note = "area. The function reference states no unit, so the unit stays unresolved", .units_documented = false },
    .{ .api = "vs.ObjSurfaceArea", .quantity = "area", .note = "surface area in the document area unit (Units dialog), read from selectors 176 and 178, not document length squared" },
    .{ .api = "vs.ObjVolume", .quantity = "volume", .note = "volume in the document volume unit (Units dialog), read from selectors 180 and 182, not document length cubed" },
};

pub fn collectorFor(api: []const u8, quantity: []const u8) ?*const Collector {
    for (&collectors) |*c| {
        if (eql(c.api, api) and eql(c.quantity, quantity)) return c;
    }
    return null;
}

/// How the bridge treats one query. A null `status` collects with `collector`. Any other
/// status is the result status. `raw_call` names a `RAW` entry of the bridge that records the
/// raw return of a refused query.
pub const QueryPlan = struct {
    status: ?[]const u8 = null,
    detail: []const u8 = "",
    collector: ?*const Collector = null,
    /// Record component. It is the `named` component that the query names or the collector `component`.
    component: []const u8 = "",
    raw_call: ?[]const u8 = null,
    blocker: ?*const QueryBlocker = null,
};

fn argKindProblem(a: Allocator, k: ArgKind, v: json.Value, i: usize) ?[]const u8 {
    const ok = switch (k) {
        .object => v == .object and eql(strField(v, "handle") orelse "", "object"),
        .layer => v == .object and eql(strField(v, "handle") orelse "", "layer") and strField(v, "name") != null,
        .string => v == .string,
        .integer => intOf(v) != null,
    };
    if (ok) return null;
    return fmtA(a, "argument {d} must be {s}. The query gives {s}", .{ i, switch (k) {
        .object => "{\"handle\": \"object\"}",
        .layer => "{\"handle\": \"layer\", \"name\": <name>}",
        .string => "a string",
        .integer => "an integer",
    }, stringifyLine(a, v) });
}

/// Selects the collector of `q` or the status that refuses it. The bridge, the fake driver,
/// `normalize` and `readiness` use this rule.
pub fn planQuery(a: Allocator, q: Query) QueryPlan {
    if (q.raw_only) |r| return .{ .status = "raw_only", .detail = fmtA(a, "The bridge records the full return of vs.{s}. Normalization is unresolved under {s}", .{ r.raw_call, r.decision }), .raw_call = r.raw_call };
    for (&query_blockers) |*b| {
        if (eql(b.api, q.api) and eql(b.quantity, q.quantity)) return .{ .status = b.reason, .detail = b.detail, .raw_call = b.raw_call, .blocker = b };
    }
    var n: usize = 0;
    var pick: ?*const Collector = null;
    for (&collectors) |*c| {
        if (!eql(c.api, q.api) or !eql(c.quantity, q.quantity)) continue;
        n += 1;
        if (q.component) |want| {
            if (eql(c.component, want) or (c.named.len > 0 and eql(c.named, want))) pick = c;
        } else pick = c;
    }
    if (n == 0) return .{ .status = "collector_unimplemented", .detail = fmtA(a, "no collector reads {s} {s}", .{ q.api, q.quantity }) };
    if (q.component) |want| {
        if (pick == null) return .{ .status = "component_unregistered", .detail = fmtA(a, "no collector of {s} {s} writes component `{s}`", .{ q.api, q.quantity, want }) };
    } else if (n > 1) return .{ .status = "component_unspecified", .detail = fmtA(a, "{s} {s} has {d} components. The query names none", .{ q.api, q.quantity, n }) };
    const c = pick.?;
    const comp = if (q.component) |want| (if (c.named.len > 0 and eql(c.named, want)) c.named else c.component) else c.component;
    const given = q.args orelse &.{};
    if (c.args.len == 0) {
        if (given.len > 0) return .{ .status = "argument_unexpected", .detail = fmtA(a, "{s} takes no query arguments. The query gives {d}", .{ q.api, given.len }), .collector = c };
        return .{ .collector = c, .component = comp };
    }
    if (q.args == null) return .{ .status = "argument_missing", .detail = fmtA(a, "{s} needs {d} query arguments. The query gives none", .{ q.api, c.args.len }), .collector = c };
    if (given.len != c.args.len) return .{ .status = "argument_count", .detail = fmtA(a, "{s} needs {d} query arguments. The query gives {d}", .{ q.api, c.args.len, given.len }), .collector = c };
    for (c.args, given, 0..) |k, v, i| {
        if (argKindProblem(a, k, v, i)) |why| return .{ .status = "argument_type", .detail = fmtA(a, "{s} {s}", .{ q.api, why }), .collector = c };
    }
    return .{ .collector = c, .component = comp };
}

/// Maps `vs.GetUnits` units per inch to a frame length unit. Other values are null.
pub fn unitsFromUpi(upi: f64) ?[]const u8 {
    const table = [_]struct { f64, []const u8 }{ .{ 25.4, "mm" }, .{ 2.54, "cm" }, .{ 0.0254, "m" }, .{ 1, "in" }, .{ 1.0 / 12.0, "ft" } };
    for (table) |row| {
        if (@abs(upi - row[0]) <= 1e-9 * @max(1, row[0])) return row[1];
    }
    return null;
}

/// One supported document area or volume unit: units per square or cubic inch (Appendix F selectors
/// 176 and 180) and the unit mark that the Units dialog shows with it (selectors 178 and 182).
const ScalarPair = struct { scale: f64, name: []const u8, mark: []const u8 };

const area_pairs = [_]ScalarPair{
    .{ .scale = 1, .name = "in2", .mark = "sq in" },
    .{ .scale = 1.0 / 144.0, .name = "ft2", .mark = "sq ft" },
    .{ .scale = 6.4516, .name = "cm2", .mark = "sq cm" },
    .{ .scale = 645.16, .name = "mm2", .mark = "sq mm" },
    .{ .scale = 0.00064516, .name = "m2", .mark = "sq m" },
};

const volume_pairs = [_]ScalarPair{
    .{ .scale = 1, .name = "in3", .mark = "cu in" },
    .{ .scale = 1.0 / 1728.0, .name = "ft3", .mark = "cu ft" },
    .{ .scale = 16.387064, .name = "cm3", .mark = "cu cm" },
    .{ .scale = 16387.064, .name = "mm3", .mark = "cu mm" },
    .{ .scale = 1.6387064e-05, .name = "m3", .mark = "cu m" },
};

/// The reading of one document scalar unit: the unit name when scale and mark agree on a supported
/// pair, else null with the reason. `scale` and `mark` keep what was read.
pub const ScalarUnit = struct {
    unit: ?[]const u8 = null,
    why: []const u8 = "",
    scale: ?f64 = null,
    mark: ?[]const u8 = null,
};

pub const ScalarUnits = struct { area: ScalarUnit = .{}, volume: ScalarUnit = .{} };

fn prefRecord(rec: json.Value, api: []const u8, selector: i64) ?json.Value {
    for (arrField(rec, "prefs")) |p| {
        if (!eql(strField(p, "api") orelse "", api)) continue;
        const s = intOf(field(p, "selector") orelse .null) orelse continue;
        if (s == selector) return p;
    }
    return null;
}

fn trimMark(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn scalarOne(a: Allocator, rec: json.Value, scale_sel: i64, mark_sel: i64, pairs: []const ScalarPair, what: []const u8) ScalarUnit {
    var out: ScalarUnit = .{};
    const sp = prefRecord(rec, "vs.GetPrefReal", scale_sel) orelse {
        out.why = fmtA(a, "no {s} scale reading (vs.GetPrefReal {d}) in the raw record", .{ what, scale_sel });
        return out;
    };
    const mp = prefRecord(rec, "vs.GetPrefString", mark_sel) orelse {
        out.why = fmtA(a, "no {s} mark reading (vs.GetPrefString {d}) in the raw record", .{ what, mark_sel });
        return out;
    };
    for ([_]json.Value{ sp, mp }, [_]i64{ scale_sel, mark_sel }) |p, sel| {
        const st = strField(p, "status") orelse "";
        if (!eql(st, "observed")) {
            out.why = fmtA(a, "the {s} reading of selector {d} has status `{s}`", .{ what, sel, st });
            return out;
        }
    }
    const scale = numberOf(field(sp, "raw") orelse .null) orelse {
        out.why = fmtA(a, "the {s} scale of selector {d} is not a finite number", .{ what, scale_sel });
        return out;
    };
    out.scale = scale;
    const mark_raw = field(mp, "raw") orelse .null;
    if (mark_raw != .string or trimMark(mark_raw.string).len == 0) {
        out.why = fmtA(a, "the {s} mark of selector {d} is not a non-empty string", .{ what, mark_sel });
        return out;
    }
    const mark = trimMark(mark_raw.string);
    out.mark = mark;
    if (!(scale > 0)) {
        out.why = fmtA(a, "the {s} scale {d} is not positive", .{ what, scale });
        return out;
    }
    for (pairs) |pr| {
        if (@abs(scale - pr.scale) > 1e-9 * pr.scale) continue;
        if (!eql(mark, pr.mark)) {
            out.why = fmtA(a, "the {s} scale {d} is {s} but the mark is `{s}`, not `{s}`", .{ what, scale, pr.name, mark, pr.mark });
            return out;
        }
        out.unit = pr.name;
        return out;
    }
    out.why = fmtA(a, "the {s} scale {d} with mark `{s}` is not a supported unit pair", .{ what, scale, mark });
    return out;
}

/// The document area and volume units from the `scalar_units` record of a raw query file and, for
/// the area mark, the sixth element of `vs.GetUnits`. Each unit needs the observed scale and mark
/// of the same preference group. A reading that is missing, failed, nonfinite, not positive, not a
/// supported pair or contradicted by the other mark leaves that unit null. The area and volume units
/// are independent of each other and of the length unit.
pub fn scalarUnits(a: Allocator, rec: json.Value, get_units_raw: json.Value) ScalarUnits {
    var out: ScalarUnits = .{};
    if (rec != .object) {
        const why = "the raw record has no scalar_units evidence";
        out.area.why = why;
        out.volume.why = why;
        return out;
    }
    out.area = scalarOne(a, rec, 176, 178, &area_pairs, "area");
    out.volume = scalarOne(a, rec, 180, 182, &volume_pairs, "volume");
    // GetUnits carries the area mark too. Two readings of the mark must agree.
    if (out.area.unit != null and get_units_raw == .array and get_units_raw.array.items.len > 5) {
        const gu = get_units_raw.array.items[5];
        if (gu != .string or !eql(trimMark(gu.string), out.area.mark.?)) {
            out.area.why = fmtA(a, "the GetUnits area mark `{s}` contradicts the preference mark `{s}`", .{ if (gu == .string) gu.string else "(not a string)", out.area.mark.? });
            out.area.unit = null;
        }
    }
    return out;
}

/// The bounds that follow from `vs.Get3DCntr` and `vs.Get3DInfo`. The Function Reference remark of
/// Get3DInfo says the call returns delta-Y, delta-X and delta-Z in that order, although vs.py names
/// the values height, width and depth. The result is derived, not a getter return.
pub fn bounds3FromGetters(center: [3]f64, info: [3]f64) [6]f64 {
    const dy = info[0];
    const dx = info[1];
    const dz = info[2];
    return .{ center[0] - dx / 2, center[1] - dy / 2, center[2] - dz / 2, center[0] + dx / 2, center[1] + dy / 2, center[2] + dz / 2 };
}

/// Null when the derived bounds of a Get3DInfo result hold. Otherwise the reason. A raw object keeps
/// both getter returns, and the value must equal the bounds that the documented order gives. A plain
/// raw list is the form of the earlier producer, which took the first element as the x span. A native
/// capture in that form has no trustworthy bounds, and no corrected value is claimed for it.
fn get3dInfoProblem(result: json.Value, driver: []const u8, value: json.Value) ?[]const u8 {
    const raw = field(result, "raw") orelse .null;
    if (raw != .object) {
        if (eql(driver, "native")) return "the raw record is from the producer that swapped the x and y spans of Get3DInfo and keeps no getter evidence. No corrected bounds are claimed";
        return null;
    }
    if (!eql(strField(raw, "get3dinfo_order") orelse "", "dy,dx,dz")) return "the getter evidence does not name the Get3DInfo order dy,dx,dz";
    var c: [3]f64 = undefined;
    var info: [3]f64 = undefined;
    var got: [6]f64 = undefined;
    if (!numbers(field(raw, "get3dcntr") orelse .null, &c) or !numbers(field(raw, "get3dinfo") orelse .null, &info) or !numbers(value, &got)) return "the getter evidence or the bounds are not finite number lists";
    const want = bounds3FromGetters(c, info);
    for (want, got) |w, g| {
        if (@abs(w - g) > 1e-9 * @max(1, @abs(w))) return "the bounds differ from the bounds that the getter evidence gives";
    }
    return null;
}

fn scalarUnitValue(a: Allocator, u: ScalarUnit) json.Value {
    var o = Obj.init(a);
    o.optStr("unit", u.unit);
    if (u.why.len > 0) o.str("why", u.why);
    if (u.scale) |s| o.put("scale", num(s));
    o.optStr("mark", u.mark);
    return o.value();
}

fn numbers(v: json.Value, out: []f64) bool {
    if (v != .array or v.array.items.len != out.len) return false;
    for (v.array.items, 0..) |x, i| out[i] = numberOf(x) orelse return false;
    return true;
}

/// Null when `v` has the value form of `quantity` under the pack measurement table.
pub fn valueProblem(quantity: []const u8, v: json.Value, convention: ?[]const u8) ?[]const u8 {
    var b: [16]f64 = undefined;
    const q = quantity;
    if (eql(q, "point3") or eql(q, "vector3")) return if (numbers(v, b[0..3])) null else "needs 3 finite numbers";
    if (eql(q, "direction3")) {
        if (!numbers(v, b[0..3])) return "needs 3 finite numbers";
        return if (b[0] == 0 and b[1] == 0 and b[2] == 0) "direction is all 0" else null;
    }
    if (eql(q, "bounds3")) {
        if (!numbers(v, b[0..6])) return "needs 6 finite numbers";
        return if (b[0] > b[3] or b[1] > b[4] or b[2] > b[5]) "min exceeds max" else null;
    }
    if (eql(q, "transform4x4")) {
        if (!numbers(v, b[0..16])) return "needs 16 finite numbers";
        return if (b[12] != 0 or b[13] != 0 or b[14] != 0 or b[15] != 1) "last row is not 0 0 0 1" else null;
    }
    if (eql(q, "length") or eql(q, "radius") or eql(q, "angle")) return if (numberOf(v) != null) null else "needs a finite number";
    if (eql(q, "area") or eql(q, "volume")) {
        const x = numberOf(v) orelse return "needs a finite number";
        return if (x < 0) "is negative" else null;
    }
    if (eql(q, "count")) {
        const x = intOf(v) orelse return "needs an integer";
        return if (x < 0) "is negative" else null;
    }
    if (eql(q, "topology_counts")) {
        if (v != .object) return "needs an object";
        var it = v.object.iterator();
        while (it.next()) |e| {
            const x = intOf(e.value_ptr.*) orelse return "needs integer values";
            if (x < 0) return "has a negative count";
        }
        return null;
    }
    if (eql(q, "visibility")) return if (v == .bool) null else "needs a boolean";
    if (eql(q, "name") or eql(q, "class_name") or eql(q, "layer_name")) return if (v == .string) null else "needs a string";
    if (eql(q, "knots") or eql(q, "weights")) {
        if (v != .array or v.array.items.len == 0) return "needs a non-empty list";
        var prev: f64 = -std.math.inf(f64);
        for (v.array.items) |x| {
            const n = numberOf(x) orelse return "needs finite numbers";
            if (eql(q, "knots") and n < prev) return "knots decrease";
            if (eql(q, "weights") and n <= 0) return "weight is not above 0";
            prev = n;
        }
        return null;
    }
    if (eql(q, "domain")) {
        if (!numbers(v, b[0..2])) return "needs 2 finite numbers";
        return if (b[0] > b[1]) "first exceeds second" else null;
    }
    if (eql(q, "control_points")) {
        const c = convention orelse return "needs point_convention";
        const width: usize = if (eql(c, "cartesian")) 3 else if (eql(c, "cartesian_weight") or eql(c, "homogeneous")) 4 else return "point_convention is unknown";
        if (v != .array or v.array.items.len == 0) return "needs a non-empty list";
        for (v.array.items) |p| {
            if (!numbers(p, b[0..width])) return "point has the wrong number of values";
            if (width == 4 and b[3] <= 0) return "w is not above 0";
        }
        return null;
    }
    return "quantity is unknown";
}

/// Parse a nonnegative LONGINT without rounding decimal fractions or underflow to zero.
fn countNumberString(text: []const u8) ?i64 {
    const exp_at = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
    var mantissa = text[0..exp_at];
    const negative = std.mem.startsWith(u8, mantissa, "-");
    if (negative) mantissa = mantissa[1..];
    if (mantissa.len == 0 or mantissa[0] == '.' or mantissa[mantissa.len - 1] == '.') return null;
    var value: u64 = 0;
    var significant: usize = 0;
    var trailing: usize = 0;
    var fractional: i64 = 0;
    var decimal = false;
    for (mantissa) |ch| {
        if (ch == '.' and !decimal) {
            decimal = true;
            continue;
        }
        if (ch < '0' or ch > '9') return null;
        if (decimal) fractional += 1;
        if (ch == '0') {
            if (significant > 0) trailing += 1;
        } else {
            if (significant + trailing + 1 > 10) return null;
            for (0..trailing) |_| value *= 10;
            value = value * 10 + ch - '0';
            significant += trailing + 1;
            trailing = 0;
        }
    }
    const exponent = if (exp_at == text.len) 0 else std.fmt.parseInt(i64, text[exp_at + 1 ..], 10) catch return null;
    if (value == 0) return 0;
    if (negative) return null;
    const shift = std.math.sub(i64, exponent, fractional) catch return null;
    const scale = std.math.add(i64, shift, @intCast(trailing)) catch return null;
    if (scale < 0 or scale > 9) return null;
    for (0..@intCast(scale)) |_| value *= 10;
    return if (value <= std.math.maxInt(i32)) @intCast(value) else null;
}

/// SDK2026 vs.py:2942 declares Count as LONGINT. Preserve the raw query representation.
fn normalizedQueryValue(api: []const u8, quantity: []const u8, value: json.Value) ?json.Value {
    if (!eql(api, "vs.Count") or !eql(quantity, "count")) return value;
    const n: i64 = switch (value) {
        .integer => |x| if (x >= 0 and x <= std.math.maxInt(i32)) x else return null,
        .float => |x| if (std.math.isFinite(x) and x >= 0 and x <= std.math.maxInt(i32) and @trunc(x) == x) @intFromFloat(x) else return null,
        .number_string => |s| countNumberString(s) orelse return null,
        else => return null,
    };
    return .{ .integer = n };
}

pub const Normalized = struct {
    objects: []const u8,
    measurements: []const u8,
    frames: []const u8,
    document: []const u8,
    measured: usize,
    gaps: []const []const u8,
};

pub const NormInput = struct {
    case_id: []const u8,
    source_sha256: []const u8,
    state_sha256: []const u8,
    raw_artifact_id: []const u8,
    raw: []const u8,
};

/// Converts one raw query file into the objects, measurements, frames and document channels.
/// A frame whose origin is not (0, 0) or whose units per inch has no unit name gets null units.
pub fn normalize(a: Allocator, in: NormInput) !Normalized {
    const v = try parseJson(a, in.raw);
    if (!eql(strField(v, "schema") orelse "", schema_query)) return error.BadRawQuery;
    var gaps: std.ArrayList([]const u8) = .empty;
    const upi = numberOf(field(field(v, "units") orelse .null, "units_per_inch") orelse .null);
    var origin_zero = false;
    const org = arrField(v, "origin");
    if (org.len == 2) {
        const ox = numberOf(org[0]);
        const oy = numberOf(org[1]);
        origin_zero = ox != null and oy != null and ox.? == 0 and oy.? == 0;
    }
    const scalar = scalarUnits(a, field(v, "scalar_units") orelse .null, field(field(v, "units") orelse .null, "raw") orelse .null);
    var units: ?[]const u8 = if (upi) |u| unitsFromUpi(u) else null;
    var world_id: []const u8 = "document_world";
    if (units == null) gaps.append(a, "units_per_inch has no unit name. Frame units are null") catch {};
    if (!origin_zero) {
        world_id = "vs_user_unresolved";
        units = null;
        gaps.append(a, "the user origin is not (0, 0) or is unknown. Frame vs_user_unresolved has null units") catch {};
    }
    const api_version = field(v, "api_version") orelse .null;
    const api_version_str: json.Value = switch (api_version) {
        .string => api_version,
        .null => .{ .string = "unverified" },
        else => .{ .string = stringifyLine(a, api_version) },
    };

    var frames = arr(a);
    var wf = Obj.init(a);
    wf.str("frame_id", world_id);
    wf.put("parent", .null);
    wf.str("kind", if (origin_zero) "document_world" else "other");
    wf.optStr("units", units);
    wf.put("transform", .null);
    frames.append(wf.value()) catch {};

    var lines: std.ArrayList(u8) = .empty;
    var measured: usize = 0;
    for (arrField(v, "results"), 0..) |r, i| {
        const oid = strField(r, "object_id") orelse "";
        const quantity = strField(r, "quantity") orelse "";
        const api = strField(r, "api") orelse "";
        const status = strField(r, "status") orelse "missing";
        if (!eql(status, "ok")) {
            gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: {s}", .{ i, oid, api, quantity, status })) catch {};
            continue;
        }
        const val = normalizedQueryValue(api, quantity, field(r, "value") orelse .null) orelse {
            gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: Count return is not a nonnegative LONGINT", .{ i, oid, api, quantity })) catch {};
            continue;
        };
        const conv = strField(r, "point_convention");
        if (valueProblem(quantity, val, conv)) |why| {
            gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: value {s}", .{ i, oid, api, quantity, why })) catch {};
            continue;
        }
        if (eql(api, "vs.Get3DInfo") and eql(quantity, "bounds3")) {
            if (get3dInfoProblem(r, strField(v, "driver") orelse "", val)) |why| {
                gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: {s}", .{ i, oid, api, quantity, why })) catch {};
                continue;
            }
        }
        // The collector comes from the query fields of the result. The driver reply cannot select it.
        const qp = planQuery(a, queryOf(r, ""));
        const col = qp.collector orelse {
            gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: status ok for a query that the bridge refuses: {s}", .{ i, oid, api, quantity, qp.status orelse "" })) catch {};
            continue;
        };
        if (eql(col.component, "rrect.diam.x") or eql(col.component, "rrect.diam.y")) {
            if (numberOf(val).? < 0) {
                gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: rrect.diam is negative", .{ i, oid, api, quantity })) catch {};
                continue;
            }
        }
        const dim = quantityDim(quantity).?;
        const rec_units: ?[]const u8 = if (!col.units_documented) null else switch (dim) {
            .length => units,
            .area => scalar.area.unit,
            .volume => scalar.volume.unit,
            .angle => "deg",
            .dimensionless => "1",
            .none => "none",
        };
        if (!col.units_documented) gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: no documented return unit. The record has units null", .{ i, oid, api, quantity })) catch {};
        if (col.units_documented and rec_units == null and (dim == .area or dim == .volume)) {
            const why = if (dim == .area) scalar.area.why else scalar.volume.why;
            gaps.append(a, fmtA(a, "result {d} {s} {s} {s}: the document {s} unit is unresolved: {s}. The record has units null", .{ i, oid, api, quantity, if (dim == .area) "area" else "volume", why })) catch {};
        }
        var frame_id = world_id;
        if (eql(quantity, "transform4x4") and eql(strField(r, "frame") orelse "", "object_local")) {
            // The matrix places the object frame in the world frame. It is also a frame sidecar row.
            const fid = fmtA(a, "object_local.{s}", .{oid});
            var of = Obj.init(a);
            of.str("frame_id", fid);
            of.str("parent", world_id);
            of.str("kind", "object_local");
            of.optStr("units", units);
            of.put("transform", val);
            frames.append(of.value()) catch {};
        }
        if (strField(r, "frame")) |fr| {
            if (!eql(fr, "document_world") and !eql(fr, "object_local")) {
                gaps.append(a, fmtA(a, "result {d} {s} {s}: frame `{s}` has no sidecar row", .{ i, oid, api, fr })) catch {};
                continue;
            }
        }
        if (dim == .length or dim == .area or dim == .volume) {
            if (units == null) frame_id = world_id;
        }
        var m = Obj.init(a);
        m.str("case_id", in.case_id);
        m.str("source_sha256", in.source_sha256);
        m.str("state_sha256", in.state_sha256);
        m.str("object_id", oid);
        m.put("occurrence_path", strArr(a, &.{oid}));
        m.str("quantity", quantity);
        if (qp.component.len > 0) m.str("component", qp.component);
        m.str("frame_id", frame_id);
        m.optStr("units", rec_units);
        m.put("value", val);
        if (eql(quantity, "control_points")) m.str("point_convention", conv.?);
        var pv = Obj.init(a);
        pv.str("api", api);
        pv.put("api_version", api_version_str);
        pv.str("raw_artifact_id", in.raw_artifact_id);
        pv.int("raw_result_index", @intCast(i));
        m.put("provenance", pv.value());
        lines.appendSlice(a, stringifyLine(a, m.value())) catch {};
        lines.append(a, '\n') catch {};
        measured += 1;
    }

    var objs: std.ArrayList(u8) = .empty;
    if (field(v, "objects")) |ov| {
        if (ov == .object) {
            var it = ov.object.iterator();
            while (it.next()) |e| {
                var o = Obj.init(a);
                o.str("case_id", in.case_id);
                o.str("source_sha256", in.source_sha256);
                o.str("object_id", e.key_ptr.*);
                o.put("native", e.value_ptr.*);
                objs.appendSlice(a, stringifyLine(a, o.value())) catch {};
                objs.append(a, '\n') catch {};
            }
        }
    }

    var fo = Obj.init(a);
    fo.str("schema", schema_frames);
    fo.str("case_id", in.case_id);
    fo.str("source_sha256", in.source_sha256);
    fo.str("state_sha256", in.state_sha256);
    fo.str("transform_convention", "row_major_child_to_parent");
    fo.put("frames", .{ .array = frames });

    var doc = Obj.init(a);
    doc.str("case_id", in.case_id);
    doc.str("source_sha256", in.source_sha256);
    doc.str("state_sha256", in.state_sha256);
    doc.put("document", field(v, "document") orelse .null);
    doc.put("api_version", api_version);
    doc.put("units", field(v, "units") orelse .null);
    doc.put("origin", field(v, "origin") orelse .null);
    // The derived reading of the raw scalar_units record. It never replaces the raw record.
    var basis = Obj.init(a);
    basis.boolean("derived", true);
    basis.str("source", "scalar_units of the raw query file: vs.GetPrefReal 176 and 180, vs.GetPrefString 178 and 182, vs.GetUnits element 5");
    basis.put("area", scalarUnitValue(a, scalar.area));
    basis.put("volume", scalarUnitValue(a, scalar.volume));
    doc.put("scalar_unit_basis", basis.value());
    doc.put("gaps", strArr(a, gaps.items));

    return .{
        .objects = objs.items,
        .measurements = lines.items,
        .frames = stringify(a, fo.value()),
        .document = stringify(a, doc.value()),
        .measured = measured,
        .gaps = gaps.items,
    };
}

// ---------------------------------------------------------------------------
// existing-document raw normalization and binding
// ---------------------------------------------------------------------------

pub const schema_raw = "vwx-m3d-native-raw/1";
pub const schema_ledger = "vwx-m3d-native-ledger/1";
pub const schema_collect_spec = "vwx-m3d-collect-spec/1";

/// Native channel files of an existing-document case. The IDs and paths equal those of the
/// native-prep synthetic pack trees at bb052f33.
pub const NativeArtifact = struct { id: []const u8, rel: []const u8, channel: []const u8, derived: bool };
pub const native_artifacts = [_]NativeArtifact{
    .{ .id = "native_state", .rel = "native/native-state.json", .channel = "native_state", .derived = false },
    .{ .id = "native_query_raw", .rel = "native/raw/raw.jsonl", .channel = "native_query_raw", .derived = false },
    .{ .id = "native_objects", .rel = "native/objects.jsonl", .channel = "native_objects", .derived = true },
    .{ .id = "native_ledger", .rel = "native/ledger.jsonl", .channel = "native_objects", .derived = true },
    .{ .id = "native_measurements", .rel = "native/measurements.jsonl", .channel = "native_measurements", .derived = true },
    .{ .id = "native_frames", .rel = "native/frames.json", .channel = "native_frames", .derived = true },
    .{ .id = "native_document", .rel = "native/document.json", .channel = "native_document", .derived = true },
};

/// `provenance.api_status` of a record. `documented` names an API whose name and argument
/// order the Vectorworks function reference gives. No native run has confirmed any of them.
/// `unverified_signature` names an API that the native-prep collector README lists as
/// unverified. `unverified_mapping` is a documented API whose return code mapping is unverified.
pub const ApiStatus = enum { documented, unverified_signature, unverified_mapping };

pub const RawRow = struct { v: json.Value, line: usize };

pub const Raw = struct {
    sha256: [64]u8,
    meta: ?RawRow = null,
    layers: []const RawRow = &.{},
    objects: []const RawRow = &.{},
    end: ?RawRow = null,
    lines: usize = 0,
};

/// Parses `vwx-m3d-native-raw/1` JSON Lines. Rows other than meta, layer, object and end stay
/// in the raw file only.
pub fn parseRaw(a: Allocator, bytes: []const u8) !Raw {
    var r: Raw = .{ .sha256 = sha256Hex(bytes) };
    var layers: std.ArrayList(RawRow) = .empty;
    var objects: std.ArrayList(RawRow) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var n: usize = 0;
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        n += 1;
        const v = try parseJson(a, ln);
        const rec = strField(v, "rec") orelse return error.BadRawRow;
        const row: RawRow = .{ .v = v, .line = n };
        if (r.end != null) return error.RowAfterEnd;
        if (eql(rec, "meta")) {
            if (n != 1 or !eql(strField(v, "schema") orelse "", schema_raw)) return error.BadRawMeta;
            r.meta = row;
        } else if (eql(rec, "layer")) {
            try layers.append(a, row);
        } else if (eql(rec, "object")) {
            if (strField(v, "walk_id") == null or field(v, "occurrence_path") == null) return error.BadRawObject;
            for (arrField(v, "occurrence_path")) |x| if (x != .string) return error.BadRawObject;
            try objects.append(a, row);
        } else if (eql(rec, "end")) {
            r.end = row;
        }
    }
    r.layers = layers.items;
    r.objects = objects.items;
    r.lines = n;
    return r;
}

/// Null when the last raw row is `end` with status ok.
pub fn rawEndProblem(a: Allocator, r: *const Raw) ?[]const u8 {
    if (r.meta == null) return "the raw file has no meta row";
    const e = r.end orelse return "the raw file has no end row";
    const st = strField(e.v, "status") orelse "";
    if (!eql(st, "ok")) return fmtA(a, "the end row has status `{s}`: {s}", .{ st, strField(e.v, "reason") orelse "" });
    return null;
}

const Got = union(enum) { ok: json.Value, gap: []const u8 };

/// `{"v": x}` gives x. `{"err": e}` gives the gap e.
fn unwrapCall(v: ?json.Value) Got {
    const x = v orelse return .{ .gap = "field absent" };
    if (x == .object) {
        if (x.object.get("v")) |val| return .{ .ok = val };
        if (strField(x, "err")) |e| return .{ .gap = e };
    }
    return .{ .gap = "result is neither v nor err" };
}

fn flatNumbers(a: Allocator, v: json.Value, out: *std.ArrayList(json.Value)) bool {
    switch (v) {
        .integer, .float, .number_string => {
            if (numberOf(v) == null) return false;
            out.append(a, v) catch return false;
            return true;
        },
        .array => |l| {
            for (l.items) |x| if (!flatNumbers(a, x, out)) return false;
            return true;
        },
        else => return false,
    }
}

/// The numbers of a nested return as one list of `want` numbers.
fn flatN(a: Allocator, v: json.Value, want: usize) Got {
    var l: std.ArrayList(json.Value) = .empty;
    if (!flatNumbers(a, v, &l)) return .{ .gap = "return holds a value that is not a finite number" };
    if (l.items.len != want) return .{ .gap = fmtA(a, "return has {d} numbers. The record needs {d}", .{ l.items.len, want }) };
    var out = arr(a);
    out.appendSlice(l.items) catch {};
    return .{ .ok = .{ .array = out } };
}

/// Frame ID `<prefix>.<first 96 bytes of name, other than [A-Za-z0-9._-] as '-'>.<sha256(name)[0..8]>`.
pub fn hashedId(a: Allocator, prefix: []const u8, name: []const u8) []const u8 {
    const s = a.dupe(u8, name[0..@min(name.len, 96)]) catch return "";
    for (s) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '.' and ch.* != '_' and ch.* != '-') ch.* = '-';
    }
    const h = sha256Hex(name);
    return fmtA(a, "{s}.{s}.{s}", .{ prefix, s, h[0..8] });
}

fn occKey(a: Allocator, occ: []const json.Value) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (occ) |p| {
        if (out.items.len > 0) out.append(a, '/') catch {};
        out.appendSlice(a, if (p == .string) p.string else "?") catch {};
    }
    return out.items;
}

/// Visibility code 0 is visible and -1 is hidden. A boolean keeps its value. Other codes have no
/// mapping. The native-prep check.zig `visPart` applies the same rule.
fn visibilityOf(v: json.Value) ?bool {
    if (v == .bool) return v.bool;
    const c = intOf(v) orelse return null;
    if (c == 0) return true;
    if (c == -1) return false;
    return null;
}

const FrameRow = struct { id: []const u8, parent: ?[]const u8, kind: []const u8, transform: ?[16]f64 };
const Resolved = union(enum) { ok: []const u8, unresolved: []const u8 };

pub const RawNormInput = struct {
    case_id: []const u8,
    source_sha256: []const u8,
    state_sha256: []const u8,
    raw: []const u8,
};

pub const RawNormalized = struct {
    objects: []const u8,
    measurements: []const u8,
    ledger: []const u8,
    frames: []const u8,
    document: []const u8,
    measured: usize,
    units_gap: usize,
    gaps: usize,
    raw_end: []const u8,
};

const RawNorm = struct {
    a: Allocator,
    in: RawNormInput,
    raw: *const Raw,
    units: ?[]const u8 = null,
    /// Independent document area and volume units. A raw file without independent scalar evidence leaves both unresolved.
    scalar: ScalarUnits = .{},
    api_version: []const u8 = "unknown",
    frames: std.ArrayList(FrameRow) = .empty,
    resolved: std.StringHashMapUnmanaged(Resolved) = .empty,
    measurements: std.ArrayList(u8) = .empty,
    ledger: std.ArrayList(u8) = .empty,
    objects: std.ArrayList(u8) = .empty,
    counts: [5]usize = .{ 0, 0, 0, 0, 0 },

    const LedgerStatus = enum { measured, units_gap, missing_channel, unsupported, unresolved_transform };

    fn putFrame(n: *RawNorm, f: FrameRow) void {
        for (n.frames.items) |x| if (eql(x.id, f.id)) return;
        n.frames.append(n.a, f) catch {};
    }

    fn hasFrame(n: *const RawNorm, id: []const u8) bool {
        for (n.frames.items) |x| if (eql(x.id, id)) return true;
        return false;
    }

    /// A layer with exactly one layer row and elevation 0 shares document_world. Any other layer,
    /// a layer whose elevation is a gap and a layer index with two or more rows get a root frame
    /// of kind layer. The native-prep check.zig `layerFrame` applies the same rule.
    fn layerFrame(n: *RawNorm, root: []const u8) []const u8 {
        const want = std.fmt.parseInt(i64, root, 10) catch -1;
        var rows: usize = 0;
        for (n.raw.layers) |l| {
            if (intOf(field(l.v, "index") orelse .null) == want) rows += 1;
        }
        if (rows == 1) for (n.raw.layers) |l| {
            if (intOf(field(l.v, "index") orelse .null) != want) continue;
            switch (unwrapCall(field(l.v, "elevation"))) {
                .ok => |e| if (numberOf(e)) |z| if (z == 0) return "document_world",
                .gap => {},
            }
        };
        const id = hashedId(n.a, "layer", root);
        n.putFrame(.{ .id = id, .parent = null, .kind = "layer", .transform = null });
        return id;
    }

    /// Layer rows use the frame of their layer. Definition and occurrence rows use the frame of
    /// their definition.
    fn rowFrame(n: *RawNorm, row: json.Value) []const u8 {
        const root = strField(row, "root") orelse "";
        if (std.mem.startsWith(u8, root, "def:")) {
            const id = hashedId(n.a, "def", root[4..]);
            n.putFrame(.{ .id = id, .parent = null, .kind = "other", .transform = null });
            return id;
        }
        return n.layerFrame(root);
    }

    /// The row with walk_id occ[i] and occurrence_path occ[0..i].
    fn placementRow(n: *const RawNorm, occ: []const json.Value, i: usize) ?json.Value {
        if (occ[i] != .string) return null;
        rows: for (n.raw.objects) |r| {
            if (!eql(strField(r.v, "walk_id") orelse "", occ[i].string)) continue;
            const ro = arrField(r.v, "occurrence_path");
            if (ro.len != i) continue;
            for (ro, occ[0..i]) |x, y| {
                if (x != .string or y != .string or !eql(x.string, y.string)) continue :rows;
            }
            return r.v;
        }
        return null;
    }

    /// Frame `occ.<path>` of the placements occ[0..k]. Its transform maps into the enclosing
    /// placement frame. `placementMatrix` gives the 3x3 part and GetSymLoc3D the offset.
    fn resolve(n: *RawNorm, occ: []const json.Value, k: usize) Resolved {
        const key = occKey(n.a, occ[0..k]);
        if (n.resolved.get(key)) |r| return r;
        const r: Resolved = n.resolveOnce(occ, k, key);
        n.resolved.put(n.a, key, r) catch {};
        if (r == .unresolved) n.ledgerLine(occ[k - 1].string, occ[0 .. k - 1], "transform4x4", "placement", hashedId(n.a, "occ", key), .unresolved_transform, r.unresolved);
        return r;
    }

    /// A row below the placements `occ` needs root `def:<symbol.name of the innermost placement>`.
    fn rootProblem(n: *const RawNorm, row: json.Value, occ: []const json.Value) ?[]const u8 {
        const inner = n.placementRow(occ, occ.len - 1) orelse return "the innermost placement row is absent";
        const name = strField(field(inner, "symbol") orelse .null, "name") orelse return "the innermost placement has no symbol.name string";
        const want = fmtA(n.a, "def:{s}", .{name});
        const have = strField(row, "root") orelse "";
        if (!eql(have, want)) return fmtA(n.a, "root `{s}` differs from `{s}`", .{ have, want });
        return null;
    }

    fn resolveOnce(n: *RawNorm, occ: []const json.Value, k: usize, key: []const u8) Resolved {
        const a = n.a;
        if (occ[k - 1] != .string) return .{ .unresolved = "occurrence_path holds a value that is not a string" };
        const parent: []const u8 = if (k == 1) blk: {
            const row = n.placementRow(occ, 0) orelse return .{ .unresolved = fmtA(a, "placement row `{s}` is absent", .{key}) };
            const lf = n.rowFrame(row);
            if (!eql(lf, "document_world")) return .{ .unresolved = fmtA(a, "placement `{s}` is on frame {s}. How a layer elevation applies to placements is unverified", .{ key, lf }) };
            break :blk lf;
        } else switch (n.resolve(occ, k - 1)) {
            .ok => |id| id,
            .unresolved => return .{ .unresolved = fmtA(a, "the enclosing placement of `{s}` is unresolved", .{key}) },
        };
        const row = n.placementRow(occ, k - 1) orelse return .{ .unresolved = fmtA(a, "placement row `{s}` is absent", .{key}) };
        if (k > 1) {
            if (n.rootProblem(row, occ[0 .. k - 1])) |why| return .{ .unresolved = fmtA(a, "placement `{s}`: {s}", .{ key, why }) };
        }
        const sym = field(row, "symbol") orelse return .{ .unresolved = fmtA(a, "placement `{s}` has no symbol field", .{key}) };
        const loc = switch (unwrapCall(field(sym, "loc3d"))) {
            .ok => |v| switch (flatN(a, v, 3)) {
                .ok => |p| p,
                .gap => |g| return .{ .unresolved = fmtA(a, "GetSymLoc3D of `{s}`: {s}", .{ key, g }) },
            },
            .gap => |g| return .{ .unresolved = fmtA(a, "GetSymLoc3D of `{s}` is a gap: {s}", .{ key, g }) },
        };
        const rot = switch (unwrapCall(field(sym, "rot"))) {
            .ok => |v| numberOf(v) orelse return .{ .unresolved = fmtA(a, "GetSymRot of `{s}` is not a number", .{key}) },
            .gap => |g| return .{ .unresolved = fmtA(a, "GetSymRot of `{s}` is a gap: {s}", .{ key, g }) },
        };
        const flipped = switch (unwrapCall(field(sym, "flipped"))) {
            .ok => |v| flagOf(v) orelse return .{ .unresolved = fmtA(a, "IsObjectFlipped of `{s}` is not a boolean", .{key}) },
            .gap => |g| return .{ .unresolved = fmtA(a, "the flip flag of `{s}` is a gap: {s}", .{ key, g }) },
        };
        const m = switch (placementMatrix(a, row, sym, loc, rot, flipped)) {
            .ok => |x| x,
            .unresolved => |why| return .{ .unresolved = fmtA(a, "placement `{s}`: {s}", .{ key, why }) },
        };
        const p = loc.array.items;
        const id = hashedId(a, "occ", key);
        n.putFrame(.{ .id = id, .parent = parent, .kind = "object_local", .transform = .{
            m[0], m[1], m[2], numberOf(p[0]).?,
            m[3], m[4], m[5], numberOf(p[1]).?,
            m[6], m[7], m[8], numberOf(p[2]).?,
            0,    0,    0,    1,
        } });
        return .{ .ok = id };
    }

    fn ledgerLine(n: *RawNorm, oid: []const u8, occ: []const json.Value, quantity: ?[]const u8, component: []const u8, frame_id: []const u8, st: LedgerStatus, reason: ?[]const u8) void {
        var o = Obj.init(n.a);
        o.str("object_id", oid);
        var op = arr(n.a);
        op.appendSlice(occ) catch {};
        o.put("occurrence_path", .{ .array = op });
        o.optStr("quantity", quantity);
        o.str("component", component);
        o.str("frame_id", frame_id);
        o.str("status", @tagName(st));
        o.optStr("reason", reason);
        n.ledger.appendSlice(n.a, stringifyLine(n.a, o.value())) catch {};
        n.ledger.append(n.a, '\n') catch {};
        n.counts[@intFromEnum(st)] += 1;
    }

    /// One measurement record and its ledger line, or a missing_channel ledger line.
    fn put(n: *RawNorm, row: RawRow, frame_id: []const u8, quantity: []const u8, component: []const u8, api: []const u8, status: ApiStatus, got: Got, conv: ?[]const u8) void {
        const a = n.a;
        const oid = strField(row.v, "walk_id").?;
        const occ = arrField(row.v, "occurrence_path");
        const val = switch (got) {
            .gap => |g| return n.ledgerLine(oid, occ, quantity, component, frame_id, .missing_channel, fmtA(a, "{s}: {s}", .{ api, g })),
            .ok => |v| v,
        };
        if (valueProblem(quantity, val, conv)) |why| return n.ledgerLine(oid, occ, quantity, component, frame_id, .missing_channel, fmtA(a, "{s}: value {s}", .{ api, why }));
        const units: ?[]const u8 = switch (quantityDim(quantity).?) {
            .length => n.units,
            .area => n.scalar.area.unit,
            .volume => n.scalar.volume.unit,
            .angle => "deg",
            .dimensionless => "1",
            .none => "none",
        };
        var m = Obj.init(a);
        m.str("case_id", n.in.case_id);
        m.str("source_sha256", n.in.source_sha256);
        m.str("state_sha256", n.in.state_sha256);
        m.str("object_id", oid);
        var op = arr(a);
        op.appendSlice(occ) catch {};
        m.put("occurrence_path", .{ .array = op });
        m.str("quantity", quantity);
        m.str("component", component);
        m.str("frame_id", frame_id);
        if (conv) |c| m.str("point_convention", c);
        m.optStr("units", units);
        m.put("value", val);
        var pv = Obj.init(a);
        pv.str("api", api);
        pv.str("api_version", n.api_version);
        pv.str("raw_artifact_id", "native_query_raw");
        pv.str("api_status", @tagName(status));
        pv.str("raw_sha256", &n.raw.sha256);
        pv.int("raw_line", @intCast(row.line));
        m.put("provenance", pv.value());
        n.measurements.appendSlice(a, stringifyLine(a, m.value())) catch {};
        n.measurements.append(a, '\n') catch {};
        const units_why: []const u8 = switch (quantityDim(quantity).?) {
            .area => n.scalar.area.why,
            .volume => n.scalar.volume.why,
            else => "frame units are null",
        };
        n.ledgerLine(oid, occ, quantity, component, frame_id, if (units == null) .units_gap else .measured, if (units == null) units_why else null);
    }

    fn points(n: *RawNorm, items: []const json.Value) Got {
        var out = arr(n.a);
        for (items) |x| switch (unwrapCall(x)) {
            .ok => |v| switch (flatN(n.a, v, 3)) {
                .ok => |p| out.append(p) catch {},
                .gap => |g| return .{ .gap = g },
            },
            .gap => |g| return .{ .gap = g },
        };
        return .{ .ok = .{ .array = out } };
    }

    fn scalars(n: *RawNorm, items: []const json.Value) Got {
        var out = arr(n.a);
        for (items) |x| switch (unwrapCall(x)) {
            .ok => |v| out.append(v) catch {},
            .gap => |g| return .{ .gap = g },
        };
        return .{ .ok = .{ .array = out } };
    }

    fn object(n: *RawNorm, row: RawRow) void {
        const a = n.a;
        const v = row.v;
        const oid = strField(v, "walk_id").?;
        const occ = arrField(v, "occurrence_path");
        const fid = n.rowFrame(v);
        if (occ.len > 0) {
            _ = n.resolve(occ, occ.len);
            if (n.rootProblem(v, occ)) |why| n.ledgerLine(oid, occ, "transform4x4", "member_root", fid, .unresolved_transform, why);
        }
        var ob = Obj.init(a);
        ob.str("case_id", n.in.case_id);
        ob.str("source_sha256", n.in.source_sha256);
        ob.str("state_sha256", n.in.state_sha256);
        ob.str("object_id", oid);
        var op = arr(a);
        op.appendSlice(occ) catch {};
        ob.put("occurrence_path", .{ .array = op });
        ob.optStr("root", strField(v, "root"));
        ob.optStr("root_kind", strField(v, "root_kind"));
        ob.put("td", field(v, "td") orelse .null);
        ob.optStr("layer", strField(v, "layer"));
        ob.optStr("class", strField(v, "class"));
        ob.str("frame_id", fid);
        ob.int("raw_line", @intCast(row.line));
        n.objects.appendSlice(a, stringifyLine(a, ob.value())) catch {};
        n.objects.append(a, '\n') catch {};

        const td = field(v, "td") orelse .null;
        var tc = Obj.init(a);
        tc.put("type_code", td);
        n.put(row, fid, "topology_counts", "", "vs.GetTypeN", .documented, .{ .ok = tc.value() }, null);
        n.put(row, fid, "name", "", "vs.GetName", .documented, unwrapCall(field(v, "name")), null);
        if (strField(v, "class")) |c| n.put(row, fid, "class_name", "", "vs.GetClass", .documented, .{ .ok = .{ .string = c } }, null);
        const rk = strField(v, "root_kind") orelse "";
        if (eql(rk, "layer") or eql(rk, "sheet")) {
            if (strField(v, "layer")) |l| n.put(row, fid, "layer_name", "", "vs.GetLName", .documented, .{ .ok = .{ .string = l } }, null);
        }
        n.put(row, fid, "point3", "center", "vs.Get3DCntr", .documented, switch (unwrapCall(field(v, "cntr3d"))) {
            .ok => |x| flatN(a, x, 3),
            .gap => |g| .{ .gap = g },
        }, null);
        // VWClass.h:15-19 and VWLayerObj.h:21-24 give the GetCVis and GetLVis codes. vs.py has
        // no GetVisibility, so the object code keeps an unverified mapping.
        const vis = field(v, "vis") orelse .null;
        const vis_parts = [_]struct { []const u8, []const u8, ApiStatus }{
            .{ "object", "vs.GetVisibility", .unverified_mapping },
            .{ "class", "vs.GetCVis", .documented },
            .{ "layer", "vs.GetLVis", .documented },
        };
        for (vis_parts) |vp| {
            const got: Got = switch (unwrapCall(field(vis, vp[0]))) {
                .ok => |x| if (visibilityOf(x)) |b| .{ .ok = .{ .bool = b } } else .{ .gap = if (vp[2] == .documented and intOf(x) == 2)
                    "code 2 is Grayed. The visibility record holds true or false"
                else
                    fmtA(a, "code {s} has no visibility mapping", .{stringifyLine(a, x)}) },
                .gap => |g| .{ .gap = g },
            };
            n.put(row, fid, "visibility", vp[0], vp[1], vp[2], got, null);
        }
        if (field(v, "symbol")) |sym| {
            n.put(row, fid, "point3", "symbol.loc3d", "vs.GetSymLoc3D", .documented, switch (unwrapCall(field(sym, "loc3d"))) {
                .ok => |x| flatN(a, x, 3),
                .gap => |g| .{ .gap = g },
            }, null);
            n.put(row, fid, "angle", "symbol.rot", "vs.GetSymRot", .documented, unwrapCall(field(sym, "rot")), null);
        }
        const geom = field(v, "geom") orelse .null;
        if (field(geom, "volume") != null) n.put(row, fid, "volume", "", "vs.ObjVolume", .documented, unwrapCall(field(geom, "volume")), null);
        if (field(geom, "nurbs_curve")) |c| {
            n.put(row, fid, "count", "degree", "vs.NurbsDegree", .documented, unwrapCall(field(c, "degree")), null);
            for (arrField(c, "piece"), 0..) |p, i| {
                const comp = fmtA(a, "piece:{d}", .{i});
                n.put(row, fid, "control_points", comp, "vs.NurbsGetPt3D", .documented, n.points(arrField(p, "points")), "cartesian");
                n.put(row, fid, "weights", comp, "vs.NurbsGetWeight", .documented, n.scalars(arrField(p, "weights")), null);
                n.put(row, fid, "knots", comp, "vs.NurbsKnot", .documented, n.scalars(arrField(p, "knots")), null);
            }
        }
        if (field(geom, "nurbs_surface")) |s| n.surface(row, fid, s);
        if (field(geom, "wall")) |w| n.wall(row, fid, w);
        if (field(geom, "mesh")) |m| n.mesh(row, fid, m);
    }

    /// GetWallThickness (vs.py:20464) returns (BOOLEAN, thickness). GetWallHeight (vs.py:20277)
    /// returns start top, start bottom, end top and end bottom. GetSegPt1 and GetSegPt2 return x
    /// and y only. vs.py has no GetWallHeights.
    fn wall(n: *RawNorm, row: RawRow, fid: []const u8, w: json.Value) void {
        const a = n.a;
        const oid = strField(row.v, "walk_id").?;
        const occ = arrField(row.v, "occurrence_path");
        if (field(w, "thickness") == null and field(w, "height") == null) {
            return n.ledgerLine(oid, occ, null, "wall", fid, .unsupported, "the wall row holds neither thickness nor height");
        }
        if (field(w, "thickness") != null) n.put(row, fid, "length", "wall.thickness", "vs.GetWallThickness", .documented, switch (unwrapCall(field(w, "thickness"))) {
            .ok => |x| if (x == .array and x.array.items.len == 2 and flagOf(x.array.items[0]) == true) .{ .ok = x.array.items[1] } else .{ .gap = "GetWallThickness did not return [true, thickness]" },
            .gap => |g| .{ .gap = g },
        }, null);
        if (field(w, "height") != null) {
            const parts = [_][]const u8{ "wall.height.start_top", "wall.height.start_bottom", "wall.height.end_top", "wall.height.end_bottom" };
            const got: Got = switch (unwrapCall(field(w, "height"))) {
                .ok => |x| flatN(a, x, 4),
                .gap => |g| .{ .gap = g },
            };
            for (parts, 0..) |c, i| n.put(row, fid, "length", c, "vs.GetWallHeight", .documented, switch (got) {
                .ok => |x| .{ .ok = x.array.items[i] },
                .gap => |g| .{ .gap = g },
            }, null);
        }
        const raw_only = [_]struct { []const u8, []const u8 }{
            .{ "p1", "GetSegPt1 returns x and y only. The record needs a 3D point" },
            .{ "p2", "GetSegPt2 returns x and y only. The record needs a 3D point" },
            .{ "heights", "vs.py has no GetWallHeights" },
        };
        for (raw_only) |r| {
            if (field(w, r[0]) != null) n.ledgerLine(oid, occ, null, fmtA(a, "wall.{s}", .{r[0]}), fid, .unsupported, r[1]);
        }
    }

    /// `count_api` "GetMeshVertsCnt" (vs.py:15620) gives the vertex count. GetMeshVertex
    /// (vs.py:15605) gives each vertex. Its index base is unstated, so the vertices keep
    /// unverified_signature. GetVertNum is documented for polygons and polylines.
    fn mesh(n: *RawNorm, row: RawRow, fid: []const u8, m: json.Value) void {
        const a = n.a;
        const oid = strField(row.v, "walk_id").?;
        const occ = arrField(row.v, "occurrence_path");
        if (field(m, "vertnum") != null) n.ledgerLine(oid, occ, null, "mesh.vertnum", fid, .unsupported, "GetVertNum is documented for polygons and polylines");
        if (!eql(strField(m, "count_api") orelse "", "GetMeshVertsCnt")) {
            return n.ledgerLine(oid, occ, null, "mesh", fid, .unsupported, "the mesh row has no count_api GetMeshVertsCnt. vs.py has no GetMeshVertexCount and no GetMeshVertsCount");
        }
        const cnt = unwrapCall(field(m, "count"));
        n.put(row, fid, "count", "mesh.vertices", "vs.GetMeshVertsCnt", .documented, cnt, null);
        const c: usize = switch (cnt) {
            .ok => |x| if (intOf(x)) |k| (if (k >= 0) @intCast(k) else return) else return,
            .gap => return,
        };
        const vs_ = arrField(m, "vertices");
        if (vs_.len != c) {
            return n.ledgerLine(oid, occ, "point3", "mesh.vertex", fid, .missing_channel, fmtA(a, "vertices has {d} rows. GetMeshVertsCnt gives {d}", .{ vs_.len, c }));
        }
        for (vs_, 0..) |x, i| n.put(row, fid, "point3", fmtA(a, "mesh.vertex:{d}", .{i}), "vs.GetMeshVertex", .unverified_signature, switch (unwrapCall(x)) {
            .ok => |p| flatN(a, p, 3),
            .gap => |g| .{ .gap = g },
        }, null);
    }

    /// Points and weights flatten row-major with u outer. Component `net:<nu>x<nv>` keeps the net size.
    /// NurbsGetNumPts, NurbsDegree and NurbsKnot (vs.py:27675, 27642, 27728) take index 1 for u and
    /// 0 for v. NurbsGetPt3D (vs.py:27692) takes the u index first. A row with `axes` "uv" lists
    /// num_pts, degree and knots as [u, v]. A row without `axes` comes from collect.py at
    /// af2d617d. It lists them in direction-index order [v, u] and bounds its u loop by the v count.
    fn surface(n: *RawNorm, row: RawRow, fid: []const u8, s: json.Value) void {
        const a = n.a;
        const uv = eql(strField(s, "axes") orelse "", "uv");
        const st: ApiStatus = if (uv) .documented else .unverified_signature;
        const ui: usize = if (uv) 0 else 1;
        const deg = arrField(s, "degree");
        const knots = arrField(s, "knots");
        const np0 = arrField(s, "num_pts");
        const dirs = [_][]const u8{ "u", "v" };
        for (dirs, 0..) |dname, d| {
            const i = if (d == 0) ui else 1 - ui;
            n.put(row, fid, "count", fmtA(a, "degree.{s}", .{dname}), "vs.NurbsDegree", st, if (i < deg.len) unwrapCall(deg[i]) else .{ .gap = "degree list is short" }, null);
        }
        for (dirs, 0..) |dname, d| {
            const i = if (d == 0) ui else 1 - ui;
            n.put(row, fid, "knots", dname, "vs.NurbsKnot", st, if (i < knots.len and knots[i] == .array) n.scalars(knots[i].array.items) else .{ .gap = "knot list is absent" }, null);
        }
        if (!uv and np0.len == 2 and intOf(np0[0]) != null and intOf(np0[0]) != intOf(np0[1])) {
            const g = fmtA(a, "surface_axis_order: NurbsGetNumPts gives v {s} and u {s}. The collector bounds its u loop by the v count, so a non-square net is unreadable", .{ stringifyLine(a, np0[0]), stringifyLine(a, np0[1]) });
            n.put(row, fid, "control_points", "net", "vs.NurbsGetPt3D", st, .{ .gap = g }, "cartesian");
            n.put(row, fid, "weights", "net", "vs.NurbsGetWeight", st, .{ .gap = g }, null);
            return;
        }
        const np = arrField(s, "num_pts");
        const nu = if (np.len == 2) intOf(np[0]) else null;
        const nv = if (np.len == 2) intOf(np[1]) else null;
        const pts = arrField(s, "points");
        const wts = arrField(s, "weights");
        var why: ?[]const u8 = null;
        if (nu == null or nv == null or nu.? <= 0 or nv.? <= 0) why = "num_pts is not two positive integers";
        if (why == null and (pts.len != @as(usize, @intCast(nu.?)) or wts.len != pts.len)) why = fmtA(a, "points has {d} rows and weights has {d}. num_pts gives {d}", .{ pts.len, wts.len, nu.? });
        if (why == null) {
            for (pts, wts) |pr, wr| {
                if (pr != .array or wr != .array or pr.array.items.len != @as(usize, @intCast(nv.?)) or wr.array.items.len != pr.array.items.len) {
                    why = fmtA(a, "a points or weights row differs from num_pts v {d}", .{nv.?});
                    break;
                }
            }
        }
        if (why) |w| {
            const g = fmtA(a, "surface_count_mismatch: {s}", .{w});
            n.put(row, fid, "control_points", "net", "vs.NurbsGetPt3D", st, .{ .gap = g }, "cartesian");
            n.put(row, fid, "weights", "net", "vs.NurbsGetWeight", st, .{ .gap = g }, null);
            return;
        }
        var fp: std.ArrayList(json.Value) = .empty;
        var fw: std.ArrayList(json.Value) = .empty;
        for (pts, wts) |pr, wr| {
            fp.appendSlice(a, pr.array.items) catch {};
            fw.appendSlice(a, wr.array.items) catch {};
        }
        const comp = fmtA(a, "net:{d}x{d}", .{ nu.?, nv.? });
        n.put(row, fid, "control_points", comp, "vs.NurbsGetPt3D", st, n.points(fp.items), "cartesian");
        n.put(row, fid, "weights", comp, "vs.NurbsGetWeight", st, n.scalars(fw.items), null);
    }
};

/// cos and sin of `deg`. Multiples of 90 degrees give exact values.
fn rotation(deg: f64) [2]f64 {
    const r = @mod(deg, 360.0);
    if (r == 0) return .{ 1, 0 };
    if (r == 90) return .{ 0, 1 };
    if (r == 180) return .{ -1, 0 };
    if (r == 270) return .{ 0, -1 };
    const t = deg * std.math.pi / 180.0;
    return .{ @cos(t), @sin(t) };
}

/// A bool gives its value. A number gives true when it is nonzero.
fn flagOf(v: json.Value) ?bool {
    if (v == .bool) return v.bool;
    const x = numberOf(v) orelse return null;
    return x != 0;
}

const angle_tolerance = 1e-6;

fn sameAngle(x: f64, y: f64) bool {
    const d = @mod(x - y, 360.0);
    return @min(d, 360.0 - d) <= angle_tolerance;
}

fn sameLength(x: f64, y: f64) bool {
    return @abs(x - y) <= 1e-6 * @max(1.0, @max(@abs(x), @abs(y)));
}

const Matrix3 = union(enum) { ok: [9]f64, unresolved: []const u8 };

/// The 3x3 part of a symbol placement, row-major. It is rotate_z(GetSymRot) under the
/// native-prep b5023a0e collector/README.md Frames rules. These inputs give unresolved:
/// a flipped placement, a symbol scale_type other than 1, an absent or gap scale_type, and an
/// `entity_matrix` that is a gap, returns false, has a nonzero rx or ry, or has an offset or rz
/// farther than 1e-6 from GetSymLoc3D and GetSymRot. A row without `entity_matrix` composes.
/// Get3DOrientation (vs.py:10344) refuses composition when it returns true with a nonzero rotX
/// or rotY, a rotZ that differs from GetSymRot or isMirroredXY true. A gap or an absent field
/// leaves composition to the rules above.
fn placementMatrix(a: Allocator, row: json.Value, sym: json.Value, loc: json.Value, rot: f64, flipped: bool) Matrix3 {
    if (flipped) return .{ .unresolved = "the placement is flipped. The mirror axis is unverified" };
    if (field(row, "entity_matrix") != null) switch (unwrapCall(field(row, "entity_matrix"))) {
        .gap => |g| return .{ .unresolved = fmtA(a, "GetEntityMatrix is a gap: {s}", .{g}) },
        .ok => |e| {
            if (e != .array or e.array.items.len != 5) return .{ .unresolved = "GetEntityMatrix return is not [ok, offset, rotX, rotY, rotZ]" };
            const ei = e.array.items;
            if (ei[0] != .bool or !ei[0].bool) return .{ .unresolved = "GetEntityMatrix returned false" };
            const off = switch (flatN(a, ei[1], 3)) {
                .ok => |v| v.array.items,
                .gap => |g| return .{ .unresolved = fmtA(a, "GetEntityMatrix offset: {s}", .{g}) },
            };
            var ang: [3]f64 = undefined;
            for (0..3) |i| ang[i] = numberOf(ei[2 + i]) orelse return .{ .unresolved = fmtA(a, "GetEntityMatrix value {d} is not a number", .{2 + i}) };
            if (ang[0] != 0 or ang[1] != 0) return .{ .unresolved = fmtA(a, "GetEntityMatrix rotX {d} and rotY {d}. The axis order is unverified", .{ ang[0], ang[1] }) };
            for (0..3) |i| {
                const x = numberOf(off[i]).?;
                const want = numberOf(loc.array.items[i]).?;
                if (@abs(x - want) > 1e-6) return .{ .unresolved = fmtA(a, "GetEntityMatrix offset {d} is {d}. GetSymLoc3D gives {d}", .{ i, x, want }) };
            }
            if (!sameAngle(ang[2], rot)) return .{ .unresolved = fmtA(a, "GetEntityMatrix rotZ {d} differs from GetSymRot {d}", .{ ang[2], rot }) };
        },
    };
    switch (unwrapCall(field(row, "orient3d"))) {
        .gap => {},
        .ok => |o| if (o == .array and o.array.items.len == 5 and flagOf(o.array.items[0]) == true) {
            const oi = o.array.items;
            const rx = numberOf(oi[1]) orelse return .{ .unresolved = "Get3DOrientation rotX is not a number" };
            const ry = numberOf(oi[2]) orelse return .{ .unresolved = "Get3DOrientation rotY is not a number" };
            const rz = numberOf(oi[3]) orelse return .{ .unresolved = "Get3DOrientation rotZ is not a number" };
            if (!sameAngle(rx, 0) or !sameAngle(ry, 0)) return .{ .unresolved = fmtA(a, "Get3DOrientation rotX {d} and rotY {d}. The tilt composition is unverified", .{ rx, ry }) };
            if (!sameAngle(rz, rot)) return .{ .unresolved = fmtA(a, "Get3DOrientation rotZ {d} differs from GetSymRot {d}", .{ rz, rot }) };
            if (flagOf(oi[4]) != false) return .{ .unresolved = "Get3DOrientation isMirroredXY is not false" };
        },
    }
    const st = switch (unwrapCall(field(sym, "scale_type"))) {
        .ok => |v| intOf(v) orelse return .{ .unresolved = "symbol scale_type is not an integer" },
        .gap => |g| return .{ .unresolved = fmtA(a, "symbol scale_type is a gap: {s}. GetObjectVariableInt(h, 101) gives it", .{g}) },
    };
    if (st != 1) return .{ .unresolved = fmtA(a, "symbol scale_type {d}. Only scale type 1 composes. The scale composition of types 2 and 3 is unverified", .{st}) };
    const z = rotation(rot);
    return .{ .ok = .{ z[0], -z[1], 0, z[1], z[0], 0, 0, 0, 1 } };
}

/// Converts one `vwx-m3d-native-raw/1` file into the native channel files. Every record binds
/// `source_sha256`, `state_sha256` and the raw SHA256.
pub fn normalizeRaw(a: Allocator, in: RawNormInput) !RawNormalized {
    const raw = try a.create(Raw);
    raw.* = try parseRaw(a, in.raw);
    var n: RawNorm = .{ .a = a, .in = in, .raw = raw };
    var gaps: std.ArrayList([]const u8) = .empty;
    const meta = if (raw.meta) |m| m.v else .null;
    switch (unwrapCall(field(meta, "units"))) {
        .ok => |u| {
            const l = if (u == .array) u.array.items else &.{};
            if (l.len > 3) {
                if (numberOf(l[3])) |upi| n.units = unitsFromUpi(upi);
            }
            if (n.units == null) gaps.append(a, "GetUnits units per inch has no unit name. Frame units are null") catch {};
        },
        .gap => |g| gaps.append(a, fmtA(a, "GetUnits is a gap: {s}. Frame units are null", .{g})) catch {},
    }
    const units_raw: json.Value = switch (unwrapCall(field(meta, "units"))) {
        .ok => |u| u,
        .gap => .null,
    };
    n.scalar = scalarUnits(a, field(meta, "scalar_units") orelse .null, units_raw);
    if (n.scalar.volume.unit == null) gaps.append(a, fmtA(a, "the document volume unit is unresolved: {s}. Volume records have units null", .{n.scalar.volume.why})) catch {};
    switch (unwrapCall(field(meta, "origin"))) {
        .ok => |o| switch (flatN(a, o, 2)) {
            .ok => |p| if (numberOf(p.array.items[0]).? != 0 or numberOf(p.array.items[1]).? != 0) {
                n.units = null;
                gaps.append(a, "the user origin is not (0, 0). How query values relate to it is unverified. Frame units are null") catch {};
            },
            .gap => |g| {
                n.units = null;
                gaps.append(a, fmtA(a, "GetOrigin: {s}. Frame units are null", .{g})) catch {};
            },
        },
        .gap => |g| {
            n.units = null;
            gaps.append(a, fmtA(a, "GetOrigin is a gap: {s}. Frame units are null", .{g})) catch {};
        },
    }
    switch (unwrapCall(field(meta, "version"))) {
        .ok => |x| n.api_version = if (x == .string) x.string else stringifyLine(a, x),
        else => {},
    }
    n.putFrame(.{ .id = "document_world", .parent = null, .kind = "document_world", .transform = null });
    for (raw.objects) |row| n.object(row);

    var frames = arr(a);
    for (n.frames.items) |f| {
        var fo = Obj.init(a);
        fo.str("frame_id", f.id);
        fo.optStr("parent", f.parent);
        fo.str("kind", f.kind);
        fo.optStr("units", n.units);
        if (f.transform) |t| {
            var tl = arr(a);
            for (t) |x| tl.append(num(x)) catch {};
            fo.put("transform", .{ .array = tl });
        } else fo.put("transform", .null);
        frames.append(fo.value()) catch {};
    }
    var fr = Obj.init(a);
    fr.str("schema", schema_frames);
    fr.str("case_id", in.case_id);
    fr.str("source_sha256", in.source_sha256);
    fr.str("state_sha256", in.state_sha256);
    fr.str("transform_convention", "row_major_child_to_parent");
    fr.put("frames", .{ .array = frames });

    var lh = Obj.init(a);
    lh.str("schema", schema_ledger);
    lh.str("case_id", in.case_id);
    lh.str("raw_sha256", &raw.sha256);
    lh.str("source_sha256", in.source_sha256);
    lh.str("state_sha256", in.state_sha256);
    lh.str("transform_convention", "row_major_child_to_parent");
    lh.str("transform_basis", "GetSymLoc3D+GetSymRot+ovSymbolScaleType1");
    lh.str("entity_matrix", "compared_with_GetSymLoc3D_and_GetSymRot");
    const ledger = std.mem.concat(a, u8, &.{ stringifyLine(a, lh.value()), "\n", n.ledger.items }) catch return error.OutOfMemory;

    const end_problem = rawEndProblem(a, raw);
    var doc = Obj.init(a);
    doc.str("case_id", in.case_id);
    doc.str("source_sha256", in.source_sha256);
    doc.str("state_sha256", in.state_sha256);
    doc.str("raw_sha256", &raw.sha256);
    doc.put("file", field(meta, "file") orelse .null);
    doc.put("units", field(meta, "units") orelse .null);
    doc.put("origin", field(meta, "origin") orelse .null);
    doc.str("api_version", n.api_version);
    doc.optStr("length_units", n.units);
    doc.put("raw_end", if (raw.end) |e| e.v else .null);
    var counts = Obj.init(a);
    counts.int("raw_lines", @intCast(raw.lines));
    counts.int("objects", @intCast(raw.objects.len));
    counts.int("layers", @intCast(raw.layers.len));
    inline for (@typeInfo(RawNorm.LedgerStatus).@"enum".fields, 0..) |f, i| counts.int(f.name, @intCast(n.counts[i]));
    doc.put("counts", counts.value());
    doc.put("gaps", strArr(a, gaps.items));

    return .{
        .objects = n.objects.items,
        .measurements = n.measurements.items,
        .ledger = ledger,
        .frames = stringify(a, fr.value()),
        .document = stringify(a, doc.value()),
        .measured = n.counts[0],
        .units_gap = n.counts[1],
        .gaps = n.counts[2] + n.counts[3] + n.counts[4],
        .raw_end = end_problem orelse "ok",
    };
}

pub const BindingProblem = struct { code: []const u8, where: []const u8, msg: []const u8 };

/// Checks that the native channel files under `dir` bind `source/scratch.vwx`,
/// `native/native-state.json` and `native/raw/raw.jsonl`. `dir` is an attempt directory or a
/// pack case directory. Codes: missing_channel, raw_incomplete, wrong_source, wrong_state,
/// wrong_raw, wrong_occurrence, wrong_frame and wrong_record.
/// The derived files must equal byte for byte the output of normalizeRaw for the raw file, the
/// `case_id` of `native/native-state.json` and the source and state SHA256. An attempt directory
/// holds `stage-collected.json`. Its `native/state-after.json` must have the case, the source
/// SHA256 and the stateKey of `native/native-state.json`.
pub fn checkBinding(a: Allocator, io: Io, dir: []const u8) []const BindingProblem {
    var out: std.ArrayList(BindingProblem) = .empty;
    const P = struct {
        fn add(l: *std.ArrayList(BindingProblem), al: Allocator, code: []const u8, where: []const u8, comptime fmt: []const u8, args: anytype) void {
            l.append(al, .{ .code = code, .where = where, .msg = fmtA(al, fmt, args) }) catch {};
        }
    };
    const src_rel = "source/scratch.vwx";
    var missing = false;
    var rels: [native_artifacts.len + 1][]const u8 = undefined;
    rels[0] = src_rel;
    for (native_artifacts, 1..) |x, i| rels[i] = x.rel;
    for (rels) |rel| {
        if (!exists(io, fmtA(a, "{s}/{s}", .{ dir, rel }))) {
            P.add(&out, a, "missing_channel", rel, "the file is absent", .{});
            missing = true;
        }
    }
    if (missing) return out.items;
    const src = hashFileDup(a, io, fmtA(a, "{s}/{s}", .{ dir, src_rel })).?;
    const state = hashFileDup(a, io, fmtA(a, "{s}/native/native-state.json", .{dir})).?;
    const raw_bytes = readAll(a, io, fmtA(a, "{s}/native/raw/raw.jsonl", .{dir})) catch "";
    const raw = parseRaw(a, raw_bytes) catch |e| {
        P.add(&out, a, "raw_incomplete", "native/raw/raw.jsonl", "the raw file does not parse: {s}", .{@errorName(e)});
        return out.items;
    };
    if (rawEndProblem(a, &raw)) |why| P.add(&out, a, "raw_incomplete", "native/raw/raw.jsonl", "{s}", .{why});
    var norm: RawNorm = .{ .a = a, .in = .{ .case_id = "", .source_sha256 = "", .state_sha256 = "", .raw = "" }, .raw = &raw };
    const read = struct {
        fn json1(al: Allocator, i: Io, d: []const u8, rel: []const u8) json.Value {
            const b = readAll(al, i, fmtA(al, "{s}/{s}", .{ d, rel })) catch return .null;
            return parseJson(al, b) catch .null;
        }
    };
    const st = read.json1(a, io, dir, "native/native-state.json");
    if (!eql(strField(st, "source_sha256") orelse "", src)) P.add(&out, a, "wrong_source", "native/native-state.json", "source_sha256 differs from {s} SHA256 {s}", .{ src_rel, src });
    const frames = read.json1(a, io, dir, "native/frames.json");
    if (!eql(strField(frames, "source_sha256") orelse "", src)) P.add(&out, a, "wrong_source", "native/frames.json", "source_sha256 differs from {s} SHA256 {s}", .{ src_rel, src });
    if (!eql(strField(frames, "state_sha256") orelse "", state)) P.add(&out, a, "wrong_state", "native/frames.json", "state_sha256 differs from native/native-state.json SHA256 {s}", .{state});
    const doc = read.json1(a, io, dir, "native/document.json");
    if (!eql(strField(doc, "source_sha256") orelse "", src)) P.add(&out, a, "wrong_source", "native/document.json", "source_sha256 differs from {s}", .{src_rel});
    if (!eql(strField(doc, "state_sha256") orelse "", state)) P.add(&out, a, "wrong_state", "native/document.json", "state_sha256 differs from native/native-state.json", .{});
    if (!eql(strField(doc, "raw_sha256") orelse "", &raw.sha256)) P.add(&out, a, "wrong_raw", "native/document.json", "raw_sha256 differs from native/raw/raw.jsonl SHA256 {s}", .{&raw.sha256});
    var frame_ids: std.ArrayList([]const u8) = .empty;
    for (arrField(frames, "frames")) |f| frame_ids.append(a, strField(f, "frame_id") orelse "") catch {};

    const lines = [_][]const u8{ "native/measurements.jsonl", "native/objects.jsonl", "native/ledger.jsonl" };
    for (lines) |rel| {
        const bytes = readAll(a, io, fmtA(a, "{s}/{s}", .{ dir, rel })) catch "";
        var it = std.mem.splitScalar(u8, bytes, '\n');
        var no: usize = 0;
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            no += 1;
            const where = fmtA(a, "{s}:{d}", .{ rel, no });
            const v = parseJson(a, ln) catch {
                P.add(&out, a, "wrong_raw", where, "the line is not JSON", .{});
                continue;
            };
            const is_ledger = eql(rel, "native/ledger.jsonl");
            if (is_ledger and no == 1) {
                if (!eql(strField(v, "raw_sha256") orelse "", &raw.sha256)) P.add(&out, a, "wrong_raw", where, "raw_sha256 differs from native/raw/raw.jsonl SHA256 {s}", .{&raw.sha256});
                if (!eql(strField(v, "source_sha256") orelse "", src)) P.add(&out, a, "wrong_source", where, "source_sha256 differs from {s}", .{src_rel});
                if (!eql(strField(v, "state_sha256") orelse "", state)) P.add(&out, a, "wrong_state", where, "state_sha256 differs from native/native-state.json", .{});
                continue;
            }
            if (!is_ledger) {
                if (!eql(strField(v, "source_sha256") orelse "", src)) P.add(&out, a, "wrong_source", where, "source_sha256 differs from {s} SHA256 {s}", .{ src_rel, src });
                if (!eql(strField(v, "state_sha256") orelse "", state)) P.add(&out, a, "wrong_state", where, "state_sha256 differs from native/native-state.json SHA256 {s}", .{state});
            }
            if (eql(rel, "native/measurements.jsonl")) {
                const pv = field(v, "provenance") orelse .null;
                if (!eql(strField(pv, "raw_artifact_id") orelse "", "native_query_raw")) P.add(&out, a, "wrong_raw", where, "raw_artifact_id is not native_query_raw", .{});
                if (!eql(strField(pv, "raw_sha256") orelse "", &raw.sha256)) P.add(&out, a, "wrong_raw", where, "raw_sha256 differs from native/raw/raw.jsonl SHA256 {s}", .{&raw.sha256});
            }
            const oid = strField(v, "object_id") orelse "";
            const occ = arrField(v, "occurrence_path");
            const row = findRawRow(&raw, oid, occ) orelse {
                if (is_ledger and eql(strField(v, "status") orelse "", "unresolved_transform")) continue;
                P.add(&out, a, "wrong_occurrence", where, "no raw object row has walk_id `{s}` and occurrence_path [{s}]", .{ oid, occKey(a, occ) });
                continue;
            };
            const fid = strField(v, "frame_id") orelse "";
            if (is_ledger and eql(strField(v, "status") orelse "", "unresolved_transform")) continue;
            const want = norm.rowFrame(row.v);
            if (!eql(fid, want)) {
                P.add(&out, a, "wrong_frame", where, "frame_id `{s}` differs from `{s}`, the frame of raw line {d}", .{ fid, want, row.line });
            } else if (!inList(frame_ids.items, fid)) {
                P.add(&out, a, "wrong_frame", where, "frame_id `{s}` is absent from native/frames.json", .{fid});
            }
        }
    }
    const case_id = strField(st, "case_id") orelse "";
    if (normalizeRaw(a, .{ .case_id = case_id, .source_sha256 = src, .state_sha256 = state, .raw = raw_bytes })) |n| {
        const derived = [_][2][]const u8{
            .{ "native/objects.jsonl", n.objects },
            .{ "native/ledger.jsonl", n.ledger },
            .{ "native/measurements.jsonl", n.measurements },
            .{ "native/frames.json", n.frames },
            .{ "native/document.json", n.document },
        };
        for (derived) |dv| {
            const have = readAll(a, io, fmtA(a, "{s}/{s}", .{ dir, dv[0] })) catch "";
            if (recordDiff(have, dv[1])) |ln| {
                const hn = std.mem.count(u8, have, "\n");
                const wn = std.mem.count(u8, dv[1], "\n");
                if (hn != wn) {
                    P.add(&out, a, "wrong_record", fmtA(a, "{s}:{d}", .{ dv[0], ln }), "the file has {d} lines. normalizeRaw of native/raw/raw.jsonl gives {d} lines for case `{s}`", .{ hn, wn, case_id });
                } else {
                    P.add(&out, a, "wrong_record", fmtA(a, "{s}:{d}", .{ dv[0], ln }), "line {d} differs from normalizeRaw of native/raw/raw.jsonl for case `{s}`", .{ ln, case_id });
                }
            }
        }
    } else |e| P.add(&out, a, "raw_incomplete", "native/raw/raw.jsonl", "the raw rows do not normalize: {s}", .{@errorName(e)});
    if (exists(io, fmtA(a, "{s}/stage-collected.json", .{dir}))) {
        const after_rel = "native/state-after.json";
        const after = read.json1(a, io, dir, after_rel);
        if (after == .null) {
            P.add(&out, a, "wrong_state", after_rel, "the file is absent or is not JSON", .{});
        } else {
            if (!eql(strField(after, "schema") orelse "", schema_state)) P.add(&out, a, "wrong_state", after_rel, "schema is not {s}", .{schema_state});
            if (!eql(strField(after, "case_id") orelse "", case_id)) P.add(&out, a, "wrong_state", after_rel, "case_id differs from `{s}` in native/native-state.json", .{case_id});
            if (!eql(strField(after, "source_sha256") orelse "", src)) P.add(&out, a, "wrong_source", after_rel, "source_sha256 differs from {s} SHA256 {s}", .{ src_rel, src });
            const k0 = stateKey(a, stringifyLine(a, field(st, "state") orelse .null)) orelse "";
            const k1 = stateKey(a, stringifyLine(a, field(after, "state") orelse .null)) orelse "-";
            if (!eql(k0, k1)) P.add(&out, a, "wrong_state", after_rel, "the classes, layers, units or origin differ from native/native-state.json", .{});
        }
    }
    return out.items;
}

/// The 1-based number of the first line where `have` and `want` differ, or null if they are equal.
fn recordDiff(have: []const u8, want: []const u8) ?usize {
    if (std.mem.eql(u8, have, want)) return null;
    var hi = std.mem.splitScalar(u8, have, '\n');
    var wi = std.mem.splitScalar(u8, want, '\n');
    var no: usize = 0;
    while (true) {
        no += 1;
        const h = hi.next();
        const w = wi.next();
        if (h == null or w == null or !std.mem.eql(u8, h.?, w.?)) return no;
    }
}

fn findRawRow(raw: *const Raw, oid: []const u8, occ: []const json.Value) ?RawRow {
    rows: for (raw.objects) |r| {
        if (!eql(strField(r.v, "walk_id") orelse "", oid)) continue;
        const ro = arrField(r.v, "occurrence_path");
        if (ro.len != occ.len) continue;
        for (ro, occ) |x, y| {
            if (x != .string or y != .string or !eql(x.string, y.string)) continue :rows;
        }
        return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// native state checks
// ---------------------------------------------------------------------------

/// The comparable part of a state reply: classes, layers, units and origin. A reply of the strict
/// driver adds `ext` with selection, active layer and class, view, render mode, projection and
/// scope. Each entry keeps its status, so a gap compares as a gap.
pub fn stateKey(a: Allocator, payload: []const u8) ?[]const u8 {
    const v = parseJson(a, payload) catch return null;
    var o = Obj.init(a);
    o.put("classes", field(v, "classes") orelse .null);
    o.put("layers", field(v, "layers") orelse .null);
    o.put("units", field(v, "units") orelse .null);
    o.put("origin", field(v, "origin") orelse .null);
    if (field(v, "ext")) |x| o.put("ext", x);
    return stringifyLine(a, o.value());
}

/// Null when the state after `apply_state` shows the effect of `overrides`. Otherwise the reason.
pub fn overrideProblem(a: Allocator, overrides: json.Value, baseline: []const u8, after: []const u8) ?[]const u8 {
    const hc = strField(overrides, "hidden_content");
    if (overrides == .object) {
        var it = overrides.object.iterator();
        while (it.next()) |e| {
            if (!eql(e.key_ptr.*, "hidden_content")) return fmtA(a, "state override `{s}` has no apply rule", .{e.key_ptr.*});
        }
    }
    const want_all = if (hc) |x| eql(x, "show_all") else false;
    if (hc) |x| {
        if (!eql(x, "show_all") and !eql(x, "as_saved")) return fmtA(a, "hidden_content `{s}` has no apply rule", .{x});
    }
    if (!want_all) {
        const k0 = stateKey(a, baseline) orelse return "baseline state is not JSON";
        const k1 = stateKey(a, after) orelse return "state is not JSON";
        return if (eql(k0, k1)) null else "state differs from the saved state";
    }
    const v = parseJson(a, after) catch return "state is not JSON";
    for ([_][]const u8{ "classes", "layers" }) |list| {
        for (arrField(v, list)) |x| {
            if (boolField(x, "visible") != true) return fmtA(a, "{s} entry `{s}` is hidden after show_all", .{ list, strField(x, "name") orelse "" });
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// session
// ---------------------------------------------------------------------------

pub const Input = struct { path: []const u8, sha256: []const u8 };

pub const Session = struct {
    /// Absolute session directory.
    dir: []const u8,
    queue: Queue,
    entries: []Entry,
    template: ?[]const u8,
    inputs: []const Input,
    /// Case IDs of the frozen controls queue `inputs/controls-queue.json`.
    controls: []const []const u8 = &.{},
    /// `plan --stop-on-failure`. Every run and resume of the session stops after the first case
    /// that is not done.
    stop_on_failure: bool = false,

    pub fn path(s: *const Session, a: Allocator, rel: []const u8) []const u8 {
        return fmtA(a, "{s}/{s}", .{ s.dir, rel });
    }
};

pub const PlanOptions = struct {
    queue: []const u8,
    /// Directory that holds `scripts/` and `profiles/` of the queue.
    generated: []const u8,
    /// Directory that holds `recipes/` of the queue.
    inventory: []const u8,
    session: []const u8,
    template: ?[]const u8 = null,
    entries: ?[]const u8 = null,
    /// Directory that holds the `script_path` files. The default is `generated`.
    scripts: ?[]const u8 = null,
    /// Queue whose cases an existing-document case may name as `blank_control`.
    controls: ?[]const u8 = null,
    stop_on_failure: bool = false,
};

/// Parses a controls queue and returns its case IDs.
fn controlIds(a: Allocator, d: *Diags, bytes: []const u8, where: []const u8) ?[]const []const u8 {
    const q = parseQueue(a, d, bytes, where) orelse return null;
    var ids: std.ArrayList([]const u8) = .empty;
    for (q.cases) |c| ids.append(a, c.case_id) catch {};
    return ids.items;
}

/// Checks a `vwx-m3d-collect-spec/1` recipe against its existing-document case.
fn specProblem(a: Allocator, c: *const QCase, bytes: []const u8) ?[]const u8 {
    const v = parseJson(a, bytes) catch |e| return fmtA(a, "spec does not parse: {s}", .{@errorName(e)});
    if (!eql(strField(v, "schema") orelse "", "vwx-m3d-collect-spec/1")) return "spec schema is not vwx-m3d-collect-spec/1";
    if (!eql(strField(v, "case_id") orelse "", c.case_id)) return fmtA(a, "spec case_id `{s}` differs from the case", .{strField(v, "case_id") orelse ""});
    const src = field(v, "source") orelse return "spec has no source";
    if (!eql(strField(src, "sha256") orelse "", c.source_sha256 orelse "")) return fmtA(a, "spec source.sha256 `{s}` differs from source_sha256", .{strField(src, "sha256") orelse ""});
    const names = arrField(v, "expect_files");
    if (names.len == 0) return "spec expect_files is empty";
    for (names) |n| {
        const x = switch (n) {
            .string => |t| t,
            else => return "spec expect_files holds a value that is not a string",
        };
        if (x.len == 0 or std.mem.indexOfScalar(u8, x, '/') != null) return fmtA(a, "spec expect_files entry `{s}` is not a file name", .{x});
    }
    return null;
}

/// Operator steps that preparation leaves unexecuted. `plan` prints them and stores them.
pub const operator_steps = [_][]const u8{
    "Authorize native execution in writing. Record the authorization outside the pack.",
    "Install and activate the latest full-feature Vectorworks trial by hand. A licensed full build is also accepted.",
    "Start the full-feature app by hand. Record its pid. Do not use the Viewer. The Viewer has no Save, Save As or Export.",
    "Dismiss first-launch, license and update dialogs by hand before the run.",
    "Save one empty document in millimetres with origin (0, 0) and pass it as --template.",
    "Open that template document in the app before the run. The preflight reads the active document window.",
    "Run `vwx rosetta-capture run <session> --driver native --pid <pid> --sender <path> --operator-authorized`.",
    "Read the preflight file. Compare the release fields with Help > About. Record the build number, the edition and the enabled modules.",
    "Run the capability checklist steps that the preflight marks absent.",
};

/// Operator steps for sessions with existing-document cases. `plan` prints them after `operator_steps`.
pub const existing_operator_steps = [_][]const u8{
    "Write a sources JSON object that maps each existing-document case_id to the absolute path of its pinned source. Pass it as --sources.",
    "Keep each pinned source closed in the app. The run copies it into the session and opens the copy under work/.",
    "After the run, open a new copy of cases/<case>/attempt-<n>/source/scratch.vwx and do the `manual` lines of plan in order. The run records those exports as pending.",
};

/// Session path of the sealed copy of a root dependency.
pub fn depInput(a: Allocator, x: RootDep) []const u8 {
    return fmtA(a, "inputs/dependencies/{s}/{s}", .{ x.id, std.fs.path.basename(x.path) });
}

/// Freezes the queue and every input that it names into a new session directory.
pub fn plan(a: Allocator, io: Io, d: *Diags, o: PlanOptions, out: *Io.Writer) !void {
    const qbytes = try readAll(a, io, o.queue);
    var cbytes: ?[]const u8 = null;
    var controls: []const []const u8 = &.{};
    if (o.controls) |cp| {
        cbytes = try readAll(a, io, cp);
        controls = controlIds(a, d, cbytes.?, cp) orelse return;
        if (d.errors() > 0) return;
    }
    const q = parseQueueWith(a, d, qbytes, o.queue, controls) orelse return;
    if (d.errors() > 0) return;
    if (exists(io, o.session)) {
        d.err("session_exists", o.session, "plan writes a new session directory only", .{});
        return;
    }
    const ebytes = if (o.entries) |p| try readAll(a, io, p) else default_entries;
    _ = parseEntries(a, d, ebytes, o.entries orelse "default entries");
    if (d.errors() > 0) return;

    var files: std.ArrayList(struct { rel: []const u8, bytes: []const u8 }) = .empty;
    try files.append(a, .{ .rel = "inputs/queue.json", .bytes = qbytes });
    try files.append(a, .{ .rel = "inputs/export-entries.json", .bytes = ebytes });
    if (cbytes) |b| try files.append(a, .{ .rel = "inputs/controls-queue.json", .bytes = b });
    var generated_cases: usize = 0;
    for (q.cases) |*c| {
        if (c.kind == .generated) generated_cases += 1;
        const cw = fmtA(a, "case:{s}", .{c.case_id});
        const sp = fmtA(a, "{s}/{s}", .{ o.scripts orelse o.generated, c.script_path });
        if (escapeProblem(a, io, o.scripts orelse o.generated, c.script_path)) |why| {
            d.err("path_escape", cw, "script_path: {s}", .{why});
            continue;
        }
        const sb = readAll(a, io, sp) catch |e| {
            d.err("read_failed", cw, "cannot read {s}: {s}", .{ sp, @errorName(e) });
            continue;
        };
        const sh = sha256Hex(sb);
        if (!eql(&sh, c.script_sha256)) d.err("stale_script", cw, "{s} has SHA256 {s}. The queue names {s}", .{ sp, &sh, c.script_sha256 });
        try files.append(a, .{ .rel = fmtA(a, "inputs/scripts/{s}.py", .{c.case_id}), .bytes = sb });
        if (c.recipe_path) |rp| {
            const full = fmtA(a, "{s}/{s}", .{ o.inventory, rp });
            if (escapeProblem(a, io, o.inventory, rp)) |why| {
                d.err("path_escape", cw, "recipe_path: {s}", .{why});
                continue;
            }
            const rb = readAll(a, io, full) catch |e| {
                d.err("read_failed", cw, "cannot read {s}: {s}", .{ full, @errorName(e) });
                continue;
            };
            const rh = sha256Hex(rb);
            if (c.recipe_sha256 == null or !eql(&rh, c.recipe_sha256.?)) d.err("stale_recipe", cw, "{s} has SHA256 {s}, which differs from recipe_sha256", .{ full, &rh });
            if (c.kind == .existing_document) {
                if (specProblem(a, c, rb)) |why| d.err("spec_mismatch", cw, "{s}: {s}", .{ full, why });
            }
            try files.append(a, .{ .rel = fmtA(a, "inputs/recipes/{s}.json", .{c.case_id}), .bytes = rb });
        }
    }
    for (q.profiles) |p| {
        const rel = p.path orelse {
            d.err("missing_field", p.profile_id, "profile has no path", .{});
            continue;
        };
        const full = fmtA(a, "{s}/{s}", .{ o.generated, rel });
        if (escapeProblem(a, io, o.generated, rel)) |why| {
            d.err("path_escape", p.profile_id, "profile path: {s}", .{why});
            continue;
        }
        const pb = readAll(a, io, full) catch |e| {
            d.err("read_failed", p.profile_id, "cannot read {s}: {s}", .{ full, @errorName(e) });
            continue;
        };
        const ph = sha256Hex(pb);
        if (!eql(&ph, p.profile_sha256)) d.err("stale_profile", p.profile_id, "{s} has SHA256 {s}. The queue names {s}", .{ full, &ph, p.profile_sha256 });
        try files.append(a, .{ .rel = fmtA(a, "inputs/profiles/{s}.json", .{p.profile_id}), .bytes = pb });
    }
    // A root dependency file comes from the inventory directory. A case reads its sealed copy.
    for (q.dependencies) |x| {
        const dw = fmtA(a, "dependency:{s}", .{x.id});
        if (escapeProblem(a, io, o.inventory, x.path)) |why| {
            d.err("path_escape", dw, "path: {s}", .{why});
            continue;
        }
        const full = fmtA(a, "{s}/{s}", .{ o.inventory, x.path });
        const db = readAll(a, io, full) catch |e| {
            d.err("read_failed", dw, "cannot read {s}: {s}", .{ full, @errorName(e) });
            continue;
        };
        const dh = sha256Hex(db);
        if (!eql(&dh, x.sha256)) d.err("stale_dependency", dw, "{s} has SHA256 {s}. The queue names {s}", .{ full, &dh, x.sha256 });
        try files.append(a, .{ .rel = depInput(a, x), .bytes = db });
    }
    var template_sha: ?[]const u8 = null;
    if (o.template) |t| {
        const tb = readAll(a, io, t) catch |e| {
            d.err("read_failed", t, "cannot read the template: {s}", .{@errorName(e)});
            return;
        };
        if (tb.len == 0) d.err("empty_template", t, "the template document has 0 bytes", .{});
        template_sha = shaDup(a, tb);
        try files.append(a, .{ .rel = "inputs/template.vwx", .bytes = tb });
    }
    if (d.errors() > 0) return;

    try Dir.cwd().createDir(io, o.session, .default_dir);
    var inputs = arr(a);
    for (files.items) |f| {
        try putSealed(a, io, fmtA(a, "{s}/{s}", .{ o.session, f.rel }), f.bytes);
        var x = Obj.init(a);
        x.str("path", f.rel);
        x.str("sha256", shaDup(a, f.bytes));
        try inputs.append(x.value());
    }
    var cases = arr(a);
    for (q.cases) |c| {
        var x = Obj.init(a);
        x.str("case_id", c.case_id);
        x.str("kind", @tagName(c.kind));
        x.optStr("source_sha256", c.source_sha256);
        var deps: std.ArrayList([]const u8) = .empty;
        if (c.blank_control) |b| try deps.append(a, b);
        x.put("dependencies", strArr(a, deps.items));
        x.boolean("external_control", c.external_control);
        x.put("resource_dependencies", strArr(a, c.dependencies));
        x.put("manual_steps", strArr(a, c.manual_steps));
        x.put("creation_apis", strArr(a, c.apis));
        x.put("checkpoints", strArr(a, c.checkpoints));
        x.put("profile_ids", strArr(a, c.profile_ids));
        x.int("queries", @intCast(c.queries.len));
        try cases.append(x.value());
    }
    var root = Obj.init(a);
    root.str("schema", schema_session);
    root.str("created_by", "vwx rosetta-capture plan");
    root.str("bridge_revision", bridge_revision);
    root.str("queue_sha256", q.sha256);
    root.optStr("template_sha256", template_sha);
    root.str("native_verification", "unexecuted");
    root.put("inputs", .{ .array = inputs });
    root.put("cases", .{ .array = cases });
    root.put("external_controls", strArr(a, controls));
    if (o.stop_on_failure) root.boolean("stop_on_failure", true);
    root.put("operator_steps", strArr(a, &operator_steps));
    if (q.cases.len > generated_cases) root.put("existing_operator_steps", strArr(a, &existing_operator_steps));
    try putSealed(a, io, fmtA(a, "{s}/session.json", .{o.session}), stringify(a, root.value()));

    try out.print("summary\tcases\t{d}\nsummary\tprofiles\t{d}\nsummary\tinputs\t{d}\n", .{ q.cases.len, q.profiles.len, files.items.len });
    for (q.cases) |c| {
        if (c.kind == .existing_document) {
            try out.print("plan\t{s}\tcollect", .{c.case_id});
            for (c.profile_ids) |pid| try out.print(",export-pending:{s}", .{pid});
            try out.writeByte('\n');
            for (c.manual_steps) |m| try out.print("manual\t{s}\t{s}\n", .{ c.case_id, m });
            continue;
        }
        try out.print("plan\t{s}\tcreate,query", .{c.case_id});
        for (c.profile_ids) |pid| try out.print(",export:{s}", .{pid});
        try out.writeByte('\n');
    }
    if (template_sha == null and generated_cases > 0) d.add(.gap, "template_absent", o.session, "run refuses this session until an operator plans it with --template", .{});
    for (operator_steps) |s| try out.print("operator\tunexecuted\t{s}\n", .{s});
    if (q.cases.len > generated_cases) {
        for (existing_operator_steps) |s| try out.print("operator\tunexecuted\t{s}\n", .{s});
    }
    try out.flush();
}

/// Reads `session.json`, checks every input hash and parses the frozen queue and entries.
pub fn loadSession(a: Allocator, io: Io, d: *Diags, dir: []const u8) ?Session {
    const sp = fmtA(a, "{s}/session.json", .{dir});
    const bytes = readAll(a, io, sp) catch |e| {
        d.err("read_failed", sp, "cannot read the session: {s}", .{@errorName(e)});
        return null;
    };
    const v = parseJson(a, bytes) catch |e| {
        d.err("invalid_json", sp, "session does not parse: {s}", .{@errorName(e)});
        return null;
    };
    if (!eql(strField(v, "schema") orelse "", schema_session)) {
        d.err("bad_schema", sp, "schema must be {s}", .{schema_session});
        return null;
    }
    var inputs: std.ArrayList(Input) = .empty;
    var template: ?[]const u8 = null;
    for (arrField(v, "inputs")) |x| {
        const rel = strField(x, "path") orelse continue;
        const want = strField(x, "sha256") orelse "";
        const full = fmtA(a, "{s}/{s}", .{ dir, rel });
        const have = hashFileDup(a, io, full) orelse {
            d.err("stale_session_input", rel, "input file is missing", .{});
            continue;
        };
        if (!eql(have, want)) d.err("stale_session_input", rel, "input SHA256 {s} differs from the planned {s}", .{ have, want });
        inputs.append(a, .{ .path = rel, .sha256 = want }) catch {};
        if (eql(rel, "inputs/template.vwx")) template = full;
    }
    if (d.errors() > 0) return null;
    var controls: []const []const u8 = &.{};
    const cp = fmtA(a, "{s}/inputs/controls-queue.json", .{dir});
    if (exists(io, cp)) {
        const cb = readAll(a, io, cp) catch return null;
        controls = controlIds(a, d, cb, cp) orelse return null;
    }
    const qp = fmtA(a, "{s}/inputs/queue.json", .{dir});
    const qbytes = readAll(a, io, qp) catch return null;
    const q = parseQueueWith(a, d, qbytes, qp, controls) orelse return null;
    if (!eql(q.sha256, strField(v, "queue_sha256") orelse "")) d.err("stale_session_input", qp, "queue SHA256 differs from session queue_sha256", .{});
    const ep = fmtA(a, "{s}/inputs/export-entries.json", .{dir});
    const ebytes = readAll(a, io, ep) catch return null;
    const entries = parseEntries(a, d, ebytes, ep);
    if (d.errors() > 0) return null;
    return .{ .dir = dir, .queue = q, .entries = entries, .template = template, .inputs = inputs.items, .controls = controls, .stop_on_failure = boolField(v, "stop_on_failure") orelse false };
}

// ---------------------------------------------------------------------------
// engine
// ---------------------------------------------------------------------------

/// Requirements of a production run. A run without them keeps the legacy behavior of the test
/// seams. `rosetta-capture run --driver native` always builds one.
pub const Strict = struct {
    /// Lowercase SHA-256 of the executable that runs. Stage records bind to it and a resume with
    /// another executable refuses the recorded bundle.
    exe_sha256: []const u8,
    phase: nur.Phase = .verified,
    release: []const u8 = "",
    workspace: []const u8 = "",
    routes: ?*const RouteSet = null,
    /// Directory of the calibration evidence records and their retained bundles.
    evidence_dir: []const u8 = "",
    /// Explicit authorization of a scratch calibration session. The calibration phase needs it.
    scratch: ?nur.ScratchAuthorization = null,
    /// `mac` for the macOS backend. `injected` for a test backend. Calibration evidence from an
    /// injected backend never resolves.
    backend: []const u8 = "injected",
    /// Budgets of the validated activation packet. Null keeps the runtime defaults.
    budgets: ?activation.Budgets = null,
};

pub const inflight_name = "INFLIGHT.json";

/// The text that the in-flight record keeps for an operation. The native driver compares it with the
/// record before it presses anything.
fn inflightContext(a: Allocator, op: Op) []const u8 {
    const v = parseJson(a, if (op.payload.len > 0) op.payload else "{}") catch .null;
    return fmtA(a, "case={s} profile={s} path={s} op_dir={s}", .{ op.case_id, op.profile_id, op.path, strField(v, "op_dir") orelse "" });
}

/// Writes `bytes` to `path` through a `.partial` file that is synced, renamed and followed by a sync
/// of the directory. An existing `path` is not replaced.
fn writeDurable(io: Io, path: []const u8, bytes: []const u8) !void {
    if (exists(io, path)) return error.PathAlreadyExists;
    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.partial", .{path});
    defer std.heap.page_allocator.free(tmp_path);
    var fh = Dir.cwd().createFile(io, tmp_path, .{ .exclusive = true }) catch |e| {
        if (e == error.PathAlreadyExists) {
            // A `.partial` file from an interrupted write. Move it aside and write again.
            const aside = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.superseded.{d}", .{ tmp_path, nowMs(io) });
            defer std.heap.page_allocator.free(aside);
            try Dir.rename(Dir.cwd(), tmp_path, Dir.cwd(), aside, io);
            return writeDurable(io, path, bytes);
        }
        return e;
    };
    {
        defer fh.close(io);
        try fh.writeStreamingAll(io, bytes);
        try fh.sync(io);
    }
    try Dir.rename(Dir.cwd(), tmp_path, Dir.cwd(), path, io);
    var d = try Dir.cwd().openDir(io, dirname(path), .{});
    defer d.close(io);
    const df: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    try df.sync(io);
}

/// The in-flight record. `begin` writes `<dir>/INFLIGHT.json` durably before the first mutating call
/// of an operation. `end` moves it to `<dir>/inflight-history/` after a definite reply. A reply that
/// is not definite keeps the file. Any later `begin` then refuses, and a new process refuses at
/// startup until `reconcile` moves the record. Calls nest. The file belongs to the outermost call.
pub const InflightFile = struct {
    io: Io,
    dir: []const u8,
    run: u32 = 0,
    depth: u32 = 0,
    kept: bool = false,
    /// Names the case, the profile, the document and the export directory of the operation in flight.
    /// A reconcile reader finds a partial export through it.
    context: []const u8 = "",
    /// Counters for tests and the journal.
    begins: u32 = 0,
    cleared: u32 = 0,

    pub fn journal(f: *InflightFile) nur.Journal {
        return .{ .ptr = f, .beginFn = beginImpl, .endFn = endImpl };
    }

    pub fn path(f: *const InflightFile, a: Allocator) []const u8 {
        return fmtA(a, "{s}/{s}", .{ f.dir, inflight_name });
    }

    fn beginImpl(ptr: *anyopaque, what: []const u8) bool {
        const f: *InflightFile = @ptrCast(@alignCast(ptr));
        f.begins += 1;
        if (f.depth > 0) {
            f.depth += 1;
            return true;
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var o = Obj.init(a);
        o.str("schema", schema_inflight);
        o.int("run", f.run);
        o.int("pid", std.c.getpid());
        o.int("t_ms", nowMs(f.io));
        o.str("what", what);
        o.str("context", f.context);
        writeDurable(f.io, f.path(a), stringify(a, o.value())) catch return false;
        f.depth = 1;
        return true;
    }

    fn endImpl(ptr: *anyopaque, definite: bool) void {
        const f: *InflightFile = @ptrCast(@alignCast(ptr));
        if (!definite) f.kept = true;
        if (f.depth > 0) f.depth -= 1;
        if (f.depth != 0 or f.kept) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const hist = fmtA(a, "{s}/inflight-history", .{f.dir});
        mkdirp(f.io, hist) catch return;
        var n: usize = 1;
        while (exists(f.io, fmtA(a, "{s}/done-{d}.json", .{ hist, n }))) n += 1;
        Dir.rename(Dir.cwd(), f.path(a), Dir.cwd(), fmtA(a, "{s}/done-{d}.json", .{ hist, n }), f.io) catch {
            f.kept = true;
            return;
        };
        f.cleared += 1;
    }
};

pub const schema_inflight = "vwx-rosetta-capture-inflight/1";

/// The disposal of a scratch document before its window closes. The strict run saves the scratch
/// copy to its own session path, so the guarded close sees a saved document and the app shows no
/// save sheet. The run record names the policy. No original source path is touched.
pub const scratch_disposal_policy = "save_scratch_to_own_session_path_before_close";

/// A run of more cases than this is an expansion. It needs the completion check.
pub const max_bounded_cases: usize = 16;

pub const Config = struct {
    /// Attempts per case and run. An attempt reruns the script into a new attempt directory.
    max_attempts: u32 = 3,
    /// Extra tries for one idempotent operation or one export.
    retries: u32 = 2,
    /// Wait between the two size reads of an export file.
    settle_ms: u32 = 0,
    /// `--operator-exports`. A format without a scripting entry gets an operator export step.
    operator_exports: bool = false,
    /// `--stop-on-failure`. A case outcome other than done stops the run with `exit_stopped`
    /// before the next queue case starts.
    stop_on_failure: bool = false,
    /// Each export try writes into its own operation directory
    /// `exports/<format>/<profile>.a<n>/`. The bundle is sealed, verified and published as a
    /// manifest, a seal, one main file and sidecars. Without it an export is one file
    /// `exports/<format>/<profile>/output.<ext>`.
    bundle_exports: bool = false,
    /// Production requirements. Null keeps the legacy behavior.
    strict: ?*const Strict = null,
};

pub const Outcome = enum { done, blocked, creation_unavailable, failed };

const Stopped = error{Stopped};

const StageFile = struct { rel: []const u8, sha256: []const u8 };

const AttemptResult = union(enum) {
    done,
    retry: []const u8,
    failed: []const u8,
};

const Verify = union(enum) {
    /// Attempt has DONE and every listed file has its recorded bytes.
    complete,
    /// The listed stages verify. Later stages are absent or failed.
    partial,
    /// A listed file is missing or differs. The reason names it.
    stale: []const u8,
};

pub const Engine = struct {
    a: Allocator,
    io: Io,
    d: *Diags,
    s: *const Session,
    drv: Driver,
    cfg: Config,
    out: *Io.Writer,
    run_no: u32 = 0,
    apis: json.Value = .null,
    can_close: bool = true,
    outcomes: std.StringHashMapUnmanaged(Outcome) = .empty,
    visiting: std.StringHashMapUnmanaged(void) = .empty,
    any_failed: bool = false,
    stop_reason: []const u8 = "",
    op_seq: u32 = 0,
    /// Object of `run --sources`: case_id to the absolute path of the pinned source document.
    sources: json.Value = .null,
    /// The durable in-flight record. Null in legacy runs.
    inflight: ?*InflightFile = null,
    /// Path of the document that the last `open` made active. Empty after a close.
    cur_doc: []const u8 = "",

    fn p(e: *Engine, comptime fmt: []const u8, args: anytype) []const u8 {
        return fmtA(e.a, "{s}/" ++ fmt, .{e.s.dir} ++ args);
    }

    /// One journal line per event. Progress lines go to `out` with a flush.
    fn journal(e: *Engine, event: []const u8, case_id: []const u8, detail: []const u8, extra: ?json.Value) void {
        var o = Obj.init(e.a);
        o.str("schema", schema_journal);
        o.int("t_ms", nowMs(e.io));
        o.int("run", e.run_no);
        o.str("event", event);
        o.str("case_id", case_id);
        o.str("detail", detail);
        if (extra) |x| o.put("data", x);
        appendLine(e.io, e.p("journal.jsonl", .{}), stringifyLine(e.a, o.value())) catch {};
        e.out.print("event\t{s}\t{s}\t", .{ event, case_id }) catch {};
        for (detail) |c| e.out.writeByte(if (c == '\t' or c == '\n') ' ' else c) catch {};
        e.out.writeByte('\n') catch {};
        e.out.flush() catch {};
    }

    fn stop(e: *Engine, case_id: []const u8, reason: []const u8) Stopped {
        e.stop_reason = reason;
        e.journal("stopped", case_id, reason, null);
        return error.Stopped;
    }

    /// True for an operation that changes the app, a document or a file that the app writes.
    fn needsMarker(k: OpKind) bool {
        return switch (k) {
            .open, .save_as, .close, .run_script, .apply_state, .collect, .export_file, .ui_export, .dismiss_modal, .operator_export => true,
            .preflight, .state, .query => false,
        };
    }

    /// A reply that proves the action did not leave the app in an unknown state.
    fn definiteReply(r: Reply) bool {
        if (r.uncertain) return false;
        if (r.refused) return true;
        return switch (r.status) {
            .ok, .failed, .unsupported, .modal => true,
            .timeout, .crashed => false,
        };
    }

    /// One driver call. A mutating operation writes the in-flight record first and clears it after a
    /// definite reply. A record that cannot be written refuses the operation before the driver call.
    /// The text that the in-flight record keeps for an operation.
    fn opContext(e: *Engine, op: Op) []const u8 {
        return inflightContext(e.a, op);
    }

    fn call(e: *Engine, op: Op) Reply {
        e.op_seq += 1;
        var marked = false;
        if (e.inflight) |f| {
            if (needsMarker(op.kind)) {
                f.context = e.opContext(op);
                if (!InflightFile.beginImpl(f, @tagName(op.kind))) {
                    const refused: Reply = .{ .status = .failed, .refused = true, .detail = "refused. The in-flight record could not be written, or an earlier record is still pending" };
                    e.journal("op", op.case_id, fmtA(e.a, "{s} refused {s}", .{ @tagName(op.kind), refused.detail }), null);
                    return refused;
                }
                marked = true;
            }
        }
        const r = e.drv.call(e.a, op);
        if (marked) InflightFile.endImpl(e.inflight.?, definiteReply(r));
        if ((op.kind == .open or op.kind == .save_as) and r.status == .ok) e.cur_doc = op.path;
        var x = Obj.init(e.a);
        x.str("op", @tagName(op.kind));
        x.str("profile_id", op.profile_id);
        x.str("status", @tagName(r.status));
        x.put("warnings", strArr(e.a, r.warnings));
        e.journal("op", op.case_id, fmtA(e.a, "{s} {s} {s}", .{ @tagName(op.kind), @tagName(r.status), r.detail }), x.value());
        return r;
    }

    /// Stops the run after a reply that is uncertain or that the driver refused before any action. An
    /// uncertain reply writes the reconcile latch. A refusal writes none.
    fn gateReply(e: *Engine, op: Op, r: Reply) Stopped!void {
        if (r.uncertain) {
            e.latch(op.case_id, fmtA(e.a, "{s} is uncertain: {s}", .{ @tagName(op.kind), r.detail }));
            return e.stop(op.case_id, fmtA(e.a, "{s} is uncertain: {s}. Reconcile the app before any replay", .{ @tagName(op.kind), r.detail }));
        }
        if (r.refused) return e.stop(op.case_id, fmtA(e.a, "{s} was refused before any action: {s}. No latch was written", .{ @tagName(op.kind), r.detail }));
    }

    /// Dismisses a modal dialog. A driver that cannot dismiss it stops the run for the operator. An
    /// uncertain dismiss reply latches before the stop.
    fn dismiss(e: *Engine, op: Op) Stopped!void {
        const dop: Op = .{ .kind = .dismiss_modal, .case_id = op.case_id, .profile_id = op.profile_id };
        const r = e.call(dop);
        try e.gateReply(dop, r);
        if (r.status != .ok) return e.stop(op.case_id, fmtA(e.a, "a modal dialog blocks {s}. Dismiss it by hand, then resume. {s}", .{ @tagName(op.kind), r.detail }));
    }

    /// A mutating operation runs once. An uncertain or refused reply is handled before any dialog
    /// dismissal. A timeout or crash stops the run.
    fn mutating(e: *Engine, op: Op) Stopped!Reply {
        const r = e.call(op);
        try e.gateReply(op, r);
        switch (r.status) {
            .timeout => {
                e.latch(op.case_id, fmtA(e.a, "{s} timed out. The document state is unknown", .{@tagName(op.kind)}));
                return e.stop(op.case_id, fmtA(e.a, "{s} timed out. The document state is unknown", .{@tagName(op.kind)}));
            },
            .crashed => {
                e.latch(op.case_id, fmtA(e.a, "the app crashed during {s}", .{@tagName(op.kind)}));
                return e.stop(op.case_id, fmtA(e.a, "the app crashed during {s}: {s}", .{ @tagName(op.kind), r.detail }));
            },
            .modal => try e.dismiss(op),
            else => {},
        }
        return r;
    }

    /// An idempotent operation retries after a timeout or a dismissed modal dialog.
    fn idempotent(e: *Engine, op: Op) Stopped!Reply {
        var last: Reply = .{ .status = .failed };
        var t: u32 = 0;
        while (t <= e.cfg.retries) : (t += 1) {
            last = e.call(op);
            try e.gateReply(op, last);
            switch (last.status) {
                .ok, .failed, .unsupported => return last,
                .crashed => return e.stop(op.case_id, fmtA(e.a, "the app crashed during {s}: {s}", .{ @tagName(op.kind), last.detail })),
                .modal => try e.dismiss(op),
                .timeout => e.journal("retry", op.case_id, fmtA(e.a, "{s} timed out on try {d}", .{ @tagName(op.kind), t + 1 }), null),
            }
        }
        if (last.status == .timeout) return e.stop(op.case_id, fmtA(e.a, "{s} timed out {d} times", .{ @tagName(op.kind), e.cfg.retries + 1 }));
        return last;
    }

    /// Saves disposable work copies during strict cleanup. Getter-only query copies use
    /// closeQueryCopy instead. Sealed evidence paths remain unchanged.
    fn saveScratch(e: *Engine, case_id: []const u8) Stopped!?[]const u8 {
        if (e.cfg.strict == null or e.cur_doc.len == 0) return null;
        const sess = fmtA(e.a, "{s}/", .{e.s.dir});
        // Judge the path below the session directory only. The directory above may hold any name.
        if (!std.mem.startsWith(u8, e.cur_doc, sess)) return null;
        const rel = e.cur_doc[sess.len..];
        if (!std.mem.startsWith(u8, rel, "cases/") or std.mem.indexOf(u8, rel, "/work/") == null or std.mem.indexOf(u8, rel, "/source/") != null) return null;
        const r = try e.mutating(.{ .kind = .save_as, .case_id = case_id, .path = e.cur_doc, .expect = basename(e.cur_doc), .payload = "{\"overwrite_own\":true}" });
        if (r.status != .ok) return fmtA(e.a, "scratch save failed: {s}. The document stays open", .{r.detail});
        return null;
    }

    /// True when the tracked document is a disposable export work copy of this session.
    fn ownedScratchOpen(e: *Engine) bool {
        if (e.cur_doc.len == 0) return false;
        const sess = fmtA(e.a, "{s}/", .{e.s.dir});
        if (!std.mem.startsWith(u8, e.cur_doc, sess)) return false;
        const rel = e.cur_doc[sess.len..];
        return std.mem.startsWith(u8, rel, "cases/") and std.mem.indexOf(u8, rel, "/work/") != null and std.mem.indexOf(u8, rel, "/source/") == null;
    }

    fn closeDoc(e: *Engine, case_id: []const u8) Stopped!?[]const u8 {
        if (try e.saveScratch(case_id)) |why| return why;
        return e.closeOpenedDoc(case_id);
    }

    /// Closes the exact work copy of a read-only query without rewriting its bytes. A query can still
    /// leave the app with unsaved changes, and the close then shows the save prompt. Under the strict
    /// route the call carries the proof of the owned copy, so the driver may answer that one exact
    /// prompt with Don't Save. Without the proof the close keeps its default guard and stops on any dialog.
    fn closeQueryCopy(e: *Engine, case_id: []const u8, scratch: []const u8, source: []const u8, source_sha: []const u8) Stopped!?[]const u8 {
        if (!eql(e.cur_doc, scratch)) return e.stop(case_id, "query close refused because the tracked document differs from its work copy");
        return e.closeOpenedDocWith(case_id, e.discardPayload(scratch, source, source_sha));
    }

    /// The close payload that lets the driver discard the unsaved changes of one query work copy, or null.
    /// The copy must be below this session as `cases/<case>/attempt-<n>/work/query*/reopened.vwx`, with
    /// the sealed `source/reopened.vwx` of the same attempt, and both files must hold the recorded digest now.
    fn discardPayload(e: *Engine, scratch: []const u8, source: []const u8, source_sha: []const u8) ?[]const u8 {
        if (e.cfg.strict == null or !isLowerHex64(source_sha)) return null;
        const sess = fmtA(e.a, "{s}/", .{e.s.dir});
        if (!std.mem.startsWith(u8, scratch, sess)) return null;
        if (!queryCopyShape(scratch[sess.len..])) return null;
        const ad = dirname(dirname(dirname(scratch)));
        if (!eql(source, fmtA(e.a, "{s}/source/reopened.vwx", .{ad}))) return null;
        if (!eql(hashFileDup(e.a, e.io, source) orelse "", source_sha)) return null;
        if (!eql(hashFileDup(e.a, e.io, scratch) orelse "", source_sha)) return null;
        var d = Obj.init(e.a);
        d.str("scratch", scratch);
        d.str("source", source);
        d.str("source_sha256", source_sha);
        var o = Obj.init(e.a);
        o.str("fallback", "ui_menu");
        o.put("discard_unsaved", d.value());
        return stringifyLine(e.a, o.value());
    }

    fn closeOpenedDoc(e: *Engine, case_id: []const u8) Stopped!?[]const u8 {
        return e.closeOpenedDocWith(case_id, null);
    }

    fn closeOpenedDocWith(e: *Engine, case_id: []const u8, discard: ?[]const u8) Stopped!?[]const u8 {
        if (!e.can_close) {
            if (e.cfg.strict == null) return "close is unavailable. The document stays open in the app";
            // The app declares no CloseDocument. The strict driver closes through File > Close after
            // its identity and saved-state checks. A dialog after the menu step stops the run.
            const r = try e.mutating(.{ .kind = .close, .case_id = case_id, .payload = discard orelse "{\"fallback\":\"ui_menu\"}" });
            if (r.status == .unsupported) return fmtA(e.a, "the guarded close is unsupported: {s}. The document stays open in the app", .{r.detail});
            if (r.status != .ok) return fmtA(e.a, "close failed: {s}", .{r.detail});
            e.cur_doc = "";
            return null;
        }
        const r = try e.mutating(.{ .kind = .close, .case_id = case_id });
        if (r.status == .unsupported) {
            e.can_close = false;
            return "close is unsupported. Later documents open in new windows";
        }
        if (r.status != .ok) return fmtA(e.a, "close failed: {s}", .{r.detail});
        e.cur_doc = "";
        return null;
    }

    fn apiPresent(e: *Engine, api: []const u8) ?bool {
        const v = field(e.apis, api) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    fn acquireLock(e: *Engine) !void {
        const lp = e.p("LOCK", .{});
        const mine = fmtA(e.a, "{d}\n", .{std.c.getpid()});
        writeNew(e.io, lp, mine) catch |err| {
            if (err != error.PathAlreadyExists) return err;
            const held = readAll(e.a, e.io, lp) catch "";
            const pid = std.fmt.parseInt(i32, std.mem.trim(u8, held, " \n"), 10) catch 0;
            if (pid > 0 and pidAlive(pid)) {
                e.d.err("session_locked", lp, "process {d} holds the session lock", .{pid});
                return error.SessionLocked;
            }
            try mkdirp(e.io, e.p("lock-history", .{}));
            try Dir.rename(Dir.cwd(), lp, Dir.cwd(), e.p("lock-history/stale-{d}-{d}", .{ pid, nowMs(e.io) }), e.io);
            try writeNew(e.io, lp, mine);
        };
    }

    fn releaseLock(e: *Engine) void {
        mkdirp(e.io, e.p("lock-history", .{})) catch return;
        Dir.rename(Dir.cwd(), e.p("LOCK", .{}), Dir.cwd(), e.p("lock-history/run-{d}", .{e.run_no}), e.io) catch {};
    }

    fn nextRun(e: *Engine) !u32 {
        try mkdirp(e.io, e.p("runs", .{}));
        var n: u32 = 1;
        while (exists(e.io, e.p("runs/{d}.json", .{n}))) n += 1;
        var o = Obj.init(e.a);
        o.str("schema", schema_run);
        o.int("run", n);
        o.str("driver", @tagName(e.drv.kind));
        o.str("native_verification", if (e.drv.kind == .fake) "fake_driver" else "native_unverified");
        if (e.cfg.strict) |st| {
            // The record states the scratch disposal and the budgets that this run enforces.
            o.str("scratch_disposal", scratch_disposal_policy);
            if (st.budgets) |b| {
                o.int("operation_deadline_ms", @intCast(b.operation_deadline_ms));
                o.int("run_budget_ms", @intCast(b.run_budget_ms));
                o.int("max_attempts_per_operation", b.max_attempts_per_operation);
            }
        }
        try putSealed(e.a, e.io, e.p("runs/{d}.json", .{n}), stringify(e.a, o.value()));
        return n;
    }

    /// Runs every case of the session. Returns 0, 1 when a case failed, or `exit_stopped`.
    pub fn run(e: *Engine) !u8 {
        var generated = false;
        for (e.s.queue.cases) |c| generated = generated or c.kind == .generated;
        if (generated and e.s.template == null) {
            e.d.err("template_absent", e.s.dir, "the session has no blank template. Plan it again with --template", .{});
            return 1;
        }
        e.acquireLock() catch |err| {
            if (err == error.SessionLocked) return 1;
            return err;
        };
        defer e.releaseLock();
        e.run_no = try e.nextRun();
        if (e.inflight) |f| f.run = e.run_no;
        e.journal("run_start", "", @tagName(e.drv.kind), null);
        const status: u8 = e.runCases() catch |err| switch (err) {
            error.Stopped => exit_stopped,
            else => return err,
        };
        e.journal("run_end", "", fmtA(e.a, "status {d}", .{status}), null);
        return status;
    }

    /// Refuses every UI route whose evidence cannot be resolved before the first native call.
    fn routeGate(e: *Engine) Stopped!void {
        if (e.cfg.strict == null) return;
        for (e.s.queue.cases) |c| {
            for (c.profile_ids) |pid| {
                const prof = e.s.queue.findProfile(pid) orelse continue;
                if (findEntry(e.s.entries, prof.format) != null) continue;
                if (e.routePreflight(prof)) |why| return e.stop(c.case_id, fmtA(e.a, "export {s} is refused before any native call. {s}", .{ pid, why }));
            }
        }
    }

    fn runCases(e: *Engine) !u8 {
        if (e.latchPending()) |why| return e.stop("", fmtA(e.a, "a reconcile latch is pending. Reconcile the app and the outputs, then run `reconcile`. {s}", .{why}));
        try e.routeGate();
        try e.preflight();
        const stop_on_failure = e.cfg.stop_on_failure or e.s.stop_on_failure;
        if (e.s.stop_on_failure) e.journal("stop_on_failure", "", "session.json sets stop_on_failure. A case that is not done stops the run", null);
        for (e.s.queue.cases, 0..) |*c, i| {
            const o = try e.processCase(c);
            if (!stop_on_failure or o == .done) continue;
            const next = if (i + 1 < e.s.queue.cases.len) e.s.queue.cases[i + 1].case_id else "";
            if (next.len == 0) return e.stop(c.case_id, fmtA(e.a, "case `{s}` is {s}. --stop-on-failure stops the run", .{ c.case_id, @tagName(o) }));
            return e.stop(c.case_id, fmtA(e.a, "case `{s}` is {s}. --stop-on-failure stops the run before case `{s}`", .{ c.case_id, @tagName(o), next }));
        }
        return if (e.any_failed) 1 else 0;
    }

    fn preflight(e: *Engine) !void {
        var names: std.ArrayList([]const u8) = .empty;
        for (bridge_apis) |x| try names.append(e.a, x);
        for (e.s.queue.cases) |c| {
            for (c.apis) |x| if (!inList(names.items, x)) try names.append(e.a, x);
            for (c.queries) |q| if (!inList(names.items, q.api)) try names.append(e.a, q.api);
        }
        for (e.s.entries) |x| if (!inList(names.items, x.api)) try names.append(e.a, x.api);
        var po = Obj.init(e.a);
        po.put("apis", strArr(e.a, names.items));
        const r = try e.idempotent(.{ .kind = .preflight, .payload = stringifyLine(e.a, po.value()) });
        if (r.status != .ok) return e.stop("", fmtA(e.a, "preflight failed: {s}", .{r.detail}));
        const v = parseJson(e.a, r.payload) catch return e.stop("", "preflight reply is not JSON");
        e.apis = field(v, "apis") orelse .null;
        e.can_close = boolField(v, "can_close") orelse false;
        try putSealed(e.a, e.io, e.p("preflight/run-{d}.json", .{e.run_no}), stringify(e.a, v));
        for (required_bridge_apis) |x| {
            if (e.apiPresent(x) != true) return e.stop("", fmtA(e.a, "preflight reports {s} absent. The engine needs it to save and identify documents", .{x}));
        }
    }

    fn writeOutcome(e: *Engine, c: *const QCase, o: Outcome, reason: []const u8, evidence: []const u8, attempt: u32) void {
        e.outcomes.put(e.a, c.case_id, o) catch {};
        if (o == .failed) e.any_failed = true;
        var x = Obj.init(e.a);
        x.str("schema", schema_outcome);
        x.str("case_id", c.case_id);
        x.int("run", e.run_no);
        x.str("outcome", @tagName(o));
        x.str("reason", reason);
        x.str("evidence", evidence);
        x.int("attempt", attempt);
        x.str("driver", @tagName(e.drv.kind));
        putSealed(e.a, e.io, e.p("cases/{s}/outcome/run-{d}.json", .{ c.case_id, e.run_no }), stringify(e.a, x.value())) catch {};
        e.journal("outcome", c.case_id, fmtA(e.a, "{s} {s}", .{ @tagName(o), reason }), null);
    }

    fn processCase(e: *Engine, c: *const QCase) anyerror!Outcome {
        if (e.outcomes.get(c.case_id)) |o| return o;
        if (e.visiting.contains(c.case_id)) return .blocked;
        try e.visiting.put(e.a, c.case_id, {});
        // `blank_control` orders the cases. `dependencies` names root resource IDs, which the
        // pack records and this run does not capture.
        if (c.blank_control) |dep| {
            if (c.external_control) {
                e.journal("external_control", c.case_id, fmtA(e.a, "blank_control `{s}` is a case of inputs/controls-queue.json. This session does not capture it", .{dep}), null);
            } else {
                const dc = e.s.queue.findCase(dep).?;
                const o = try e.processCase(dc);
                if (o != .done) {
                    e.writeOutcome(c, .blocked, fmtA(e.a, "dependency `{s}` is {s}", .{ dep, @tagName(o) }), fmtA(e.a, "cases/{s}/outcome/run-{d}.json", .{ dep, e.run_no }), 0);
                    return .blocked;
                }
            }
        }
        for (c.dependencies) |dep| {
            if (e.s.queue.findDep(dep) != null) {
                e.journal("file_dependency", c.case_id, fmtA(e.a, "root dependency `{s}` is a sealed session input. rosetta_dependency returns its path", .{dep}), null);
            } else e.journal("resource_dependency", c.case_id, fmtA(e.a, "dependency `{s}` has no root entry in the queue. This run does not capture it", .{dep}), null);
        }
        for (c.apis) |api| {
            if (e.apiPresent(api) == false) {
                e.writeOutcome(c, .creation_unavailable, fmtA(e.a, "preflight reports {s} absent", .{api}), fmtA(e.a, "preflight/run-{d}.json", .{e.run_no}), 0);
                return .creation_unavailable;
            }
        }

        var attempt = latestAttempt(e.a, e.io, e.s, c.case_id);
        var start_new = attempt == 0;
        if (attempt > 0) {
            // An attempt keeps the driver that wrote its first record. Another driver starts a new attempt.
            switch (attemptDriver(e.a, e.io, e.attemptDir(c, attempt), c)) {
                .none => {},
                .one => |k| if (k != e.drv.kind) {
                    e.journal("driver_changed", c.case_id, fmtA(e.a, "attempt {d} records driver {s}. This run uses {s}. A new attempt starts and attempt {d} stays", .{ attempt, @tagName(k), @tagName(e.drv.kind), attempt }), null);
                    start_new = true;
                },
                .mixed => |why| {
                    e.journal("driver_mixed", c.case_id, fmtA(e.a, "attempt {d}: {s}. A new attempt starts and attempt {d} stays", .{ attempt, why, attempt }), null);
                    start_new = true;
                },
            }
        }
        if (attempt > 0 and !start_new) {
            switch (verifyAttempt(e.a, e.io, e.s, c, attempt)) {
                .complete => {
                    if (e.strictAttemptProblem(c, attempt)) |why| {
                        e.journal("stale_bundle", c.case_id, fmtA(e.a, "attempt {d} is stale: {s}. A new attempt starts and attempt {d} stays", .{ attempt, why, attempt }), null);
                        start_new = true;
                    } else {
                        e.journal("verified", c.case_id, fmtA(e.a, "attempt {d} verifies. Nothing reruns", .{attempt}), null);
                        e.writeOutcome(c, .done, "attempt verified", fmtA(e.a, "cases/{s}/attempt-{d}/DONE.json", .{ c.case_id, attempt }), attempt);
                        return .done;
                    }
                },
                .partial => e.journal("resume", c.case_id, fmtA(e.a, "attempt {d} continues after its verified stages", .{attempt}), null),
                .stale => |why| {
                    e.journal("stale_source_hash", c.case_id, fmtA(e.a, "attempt {d} is stale: {s}. A new attempt starts and attempt {d} stays", .{ attempt, why, attempt }), null);
                    start_new = true;
                },
            }
        }
        if (c.kind == .existing_document) {
            const sp = strField(e.sources, c.case_id) orelse {
                e.writeOutcome(c, .blocked, "run --sources has no path for this existing-document case", "inputs/queue.json", 0);
                e.any_failed = true;
                return .blocked;
            };
            if (try e.sourceProblem(c, sp)) |why| {
                e.writeOutcome(c, .failed, why, sp, 0);
                return .failed;
            }
        }
        var tries: u32 = 0;
        var last_reason: []const u8 = "";
        while (tries < e.cfg.max_attempts) : (tries += 1) {
            if (start_new) {
                attempt += 1;
                try mkdirp(e.io, e.p("cases/{s}/attempt-{d}", .{ c.case_id, attempt }));
            }
            const r = try e.runAttempt(c, attempt);
            switch (r) {
                .done => {
                    e.writeOutcome(c, .done, "attempt complete", fmtA(e.a, "cases/{s}/attempt-{d}/DONE.json", .{ c.case_id, attempt }), attempt);
                    return .done;
                },
                .retry => |why| {
                    last_reason = why;
                    e.journal("attempt_failed", c.case_id, fmtA(e.a, "attempt {d}: {s}", .{ attempt, why }), null);
                    start_new = true;
                },
                .failed => |why| {
                    e.writeOutcome(c, .failed, why, fmtA(e.a, "cases/{s}/attempt-{d}", .{ c.case_id, attempt }), attempt);
                    return .failed;
                },
            }
        }
        e.writeOutcome(c, .failed, fmtA(e.a, "{d} attempts failed. Last: {s}", .{ e.cfg.max_attempts, last_reason }), fmtA(e.a, "cases/{s}/attempt-{d}", .{ c.case_id, attempt }), attempt);
        return .failed;
    }

    fn attemptDir(e: *Engine, c: *const QCase, attempt: u32) []const u8 {
        return e.p("cases/{s}/attempt-{d}", .{ c.case_id, attempt });
    }

    fn writeStage(e: *Engine, ad: []const u8, name: []const u8, status: []const u8, files: []const StageFile, warnings: []const []const u8, extra: json.Value) !void {
        var o = Obj.init(e.a);
        o.str("schema", schema_stage);
        o.str("stage", name);
        o.str("status", status);
        o.int("run", e.run_no);
        o.str("driver", @tagName(e.drv.kind));
        var fl = arr(e.a);
        for (files) |f| {
            var x = Obj.init(e.a);
            x.str("path", f.rel);
            x.str("sha256", f.sha256);
            try fl.append(x.value());
        }
        o.put("files", .{ .array = fl });
        o.put("warnings", strArr(e.a, warnings));
        o.put("data", extra);
        try putSealed(e.a, e.io, fmtA(e.a, "{s}/stage-{s}.json", .{ ad, name }), stringify(e.a, o.value()));
    }

    /// Seals `rel` under the attempt directory and returns its stage file entry.
    fn sealFile(e: *Engine, ad: []const u8, rel: []const u8, bytes: []const u8) !StageFile {
        try putSealed(e.a, e.io, fmtA(e.a, "{s}/{s}", .{ ad, rel }), bytes);
        return .{ .rel = rel, .sha256 = shaDup(e.a, bytes) };
    }

    /// Moves a file that the app wrote into the attempt directory and seals it.
    fn adoptFile(e: *Engine, ad: []const u8, from: []const u8, rel: []const u8) !StageFile {
        const to = fmtA(e.a, "{s}/{s}", .{ ad, rel });
        try mkdirp(e.io, dirname(to));
        if (exists(e.io, to)) try supersede(e.a, e.io, to);
        try Dir.rename(Dir.cwd(), from, Dir.cwd(), to, e.io);
        try seal(e.io, to);
        const h = try hashFile(e.io, to);
        return .{ .rel = rel, .sha256 = try e.a.dupe(u8, &h) };
    }

    fn freshDir(e: *Engine, base: []const u8) ![]const u8 {
        var n: u32 = 1;
        while (exists(e.io, fmtA(e.a, "{s}-{d}", .{ base, n }))) n += 1;
        const d = fmtA(e.a, "{s}-{d}", .{ base, n });
        try mkdirp(e.io, d);
        return d;
    }

    /// Size is above 0 and equal across two reads `settle_ms` apart.
    fn stableSize(e: *Engine, path: []const u8) ?u64 {
        const s0 = fileSize(e.io, path) orelse return null;
        sleepMs(e.io, e.cfg.settle_ms);
        const s1 = fileSize(e.io, path) orelse return null;
        if (s0 != s1 or s0 == 0) return null;
        return s0;
    }

    /// Expected names of the source document under `expect_files` of the frozen collect spec.
    fn expectFiles(e: *Engine, c: *const QCase) []const []const u8 {
        const b = readAll(e.a, e.io, e.p("inputs/recipes/{s}.json", .{c.case_id})) catch return &.{};
        const v = parseJson(e.a, b) catch return &.{};
        return strings(e.a, arrField(v, "expect_files"));
    }

    /// The source must be a regular file outside the session with the queue digest and an
    /// expected file name.
    fn sourceProblem(e: *Engine, c: *const QCase, sp: []const u8) !?[]const u8 {
        if (!std.fs.path.isAbsolute(sp)) return fmtA(e.a, "source path `{s}` is not absolute", .{sp});
        const real = Dir.cwd().realPathFileAlloc(e.io, sp, e.a) catch return fmtA(e.a, "source_unreadable: cannot resolve {s}", .{sp});
        const sess = Dir.cwd().realPathFileAlloc(e.io, e.s.dir, e.a) catch e.s.dir;
        if (std.mem.startsWith(u8, real, fmtA(e.a, "{s}/", .{sess}))) return fmtA(e.a, "source path `{s}` is inside the session", .{sp});
        const have = hashFileDup(e.a, e.io, sp) orelse return fmtA(e.a, "source_unreadable: cannot hash {s}", .{sp});
        if (!eql(have, c.source_sha256.?)) return fmtA(e.a, "source_digest_mismatch: {s} has SHA256 {s}. The queue names {s}", .{ sp, have, c.source_sha256.? });
        if (!inList(e.expectFiles(c), basename(sp))) return fmtA(e.a, "source_name_unexpected: `{s}` is not in expect_files of inputs/recipes/{s}.json", .{ basename(sp), c.case_id });
        return null;
    }

    fn runAttempt(e: *Engine, c: *const QCase, attempt: u32) !AttemptResult {
        const ad = e.attemptDir(c, attempt);
        if (c.kind == .existing_document) {
            if (!stageOk(e.a, e.io, ad, "collected")) {
                const r = try e.stageCollect(c, ad, strField(e.sources, c.case_id).?);
                if (r != .done) return r;
            }
            var failed: ?[]const u8 = null;
            for (c.profile_ids) |pid| {
                const name = fmtA(e.a, "export-{s}", .{pid});
                const prof = e.s.queue.findProfile(pid).?;
                const routed = e.cfg.strict != null and e.cfg.bundle_exports and (findEntry(e.s.entries, prof.format) != null or e.uiRouteFor(prof) != null);
                if (routed or (e.cfg.operator_exports and findEntry(e.s.entries, prof.format) == null and formatCheck(prof.format) != null)) {
                    if (stageOk(e.a, e.io, ad, name) and eql(stageStatus(e.a, e.io, ad, name), "ok")) {
                        if (e.bundleStageProblem(c, ad, name, prof)) |why| return .{ .retry = fmtA(e.a, "stale_bundle: {s}: {s}", .{ pid, why }) };
                        continue;
                    }
                    if (try e.stageOperatorExisting(c, ad, prof, strField(e.sources, c.case_id).?)) |why| failed = why;
                    continue;
                }
                if (stageOk(e.a, e.io, ad, name)) continue;
                var x = Obj.init(e.a);
                x.str("reason", "the queue gives this export as an operator_manual operation. No documented scripting entry runs it");
                x.str("evidence", "inputs/queue.json");
                x.str("mode", "operator_manual");
                try e.writeStage(ad, name, "pending", &.{}, &.{}, x.value());
                e.journal("export_pending", c.case_id, fmtA(e.a, "{s}: operator_manual", .{pid}), null);
            }
            if (failed) |why| return .{ .failed = why };
            try writeDone(e.a, e.io, ad, c, e.drv.kind, e.run_no);
            return .done;
        }
        if (!stageOk(e.a, e.io, ad, "created")) {
            const r = try e.stageCreate(c, ad);
            if (r != .done) return r;
        }
        if (!stageOk(e.a, e.io, ad, "queried")) {
            const r = try e.stageQuery(c, ad);
            if (r != .done) return r;
        }
        var failed: ?[]const u8 = null;
        for (c.profile_ids) |pid| {
            const name = fmtA(e.a, "export-{s}", .{pid});
            const prof = e.s.queue.findProfile(pid).?;
            if (stageOk(e.a, e.io, ad, name)) {
                if (e.bundleStageProblem(c, ad, name, prof)) |why| return .{ .retry = fmtA(e.a, "stale_bundle: {s}: {s}", .{ pid, why }) };
                continue;
            }
            if (try e.stageExport(c, ad, prof)) |why| failed = why;
        }
        if (failed) |why| return .{ .failed = why };
        try writeDone(e.a, e.io, ad, c, e.drv.kind, e.run_no);
        return .done;
    }

    fn stageCreate(e: *Engine, c: *const QCase, ad: []const u8) !AttemptResult {
        const w = try e.freshDir(fmtA(e.a, "{s}/work/create", .{ad}));
        const start = fmtA(e.a, "{s}/start.vwx", .{w});
        try copyNew(e.io, e.s.template.?, start);
        var warnings: std.ArrayList([]const u8) = .empty;
        var r = try e.mutating(.{ .kind = .open, .case_id = c.case_id, .path = start, .expect = "start.vwx" });
        if (r.status != .ok) return .{ .retry = fmtA(e.a, "open of the blank template returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        const cpd = fmtA(e.a, "{s}/checkpoints", .{w});
        try mkdirp(e.io, cpd);
        var po = Obj.init(e.a);
        po.str("checkpoint_dir", cpd);
        po.str("case_id", c.case_id);
        var deps = Obj.init(e.a);
        for (c.dependencies) |dep| {
            const x = e.s.queue.findDep(dep) orelse continue;
            var dx = Obj.init(e.a);
            dx.str("path", e.s.path(e.a, depInput(e.a, x.*)));
            dx.str("sha256", x.sha256);
            deps.put(dep, dx.value());
        }
        po.put("dependencies", deps.value());
        r = try e.mutating(.{ .kind = .run_script, .case_id = c.case_id, .path = e.p("inputs/scripts/{s}.py", .{c.case_id}), .payload = stringifyLine(e.a, po.value()) });
        if (r.status != .ok) {
            _ = try e.closeDoc(c.case_id);
            return .{ .retry = fmtA(e.a, "run_script returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        }
        try warnings.appendSlice(e.a, r.warnings);
        const sv = parseJson(e.a, r.payload) catch .null;
        if (boolField(sv, "save_reopen_reached") != true) {
            _ = try e.closeDoc(c.case_id);
            return .{ .retry = "the script did not reach rosetta_save_reopen()" };
        }
        var cp_files: std.ArrayList(struct { id: []const u8, path: []const u8 }) = .empty;
        for (arrField(sv, "checkpoints")) |x| try cp_files.append(e.a, .{ .id = strField(x, "id") orelse "", .path = strField(x, "path") orelse "" });
        if (cp_files.items.len != c.checkpoints.len) {
            _ = try e.closeDoc(c.case_id);
            return .{ .retry = fmtA(e.a, "the script wrote {d} checkpoints. The queue lists {d}", .{ cp_files.items.len, c.checkpoints.len }) };
        }
        for (c.checkpoints, cp_files.items) |want, have| {
            if (!eql(want, have.id) or e.stableSize(have.path) == null) {
                _ = try e.closeDoc(c.case_id);
                return .{ .retry = fmtA(e.a, "checkpoint `{s}` is missing or empty", .{want}) };
            }
        }
        const orig = fmtA(e.a, "{s}/original.vwx", .{w});
        r = try e.mutating(.{ .kind = .save_as, .case_id = c.case_id, .path = orig, .expect = "original.vwx" });
        if (r.status != .ok or e.stableSize(orig) == null) {
            _ = try e.closeDoc(c.case_id);
            return .{ .retry = fmtA(e.a, "save_as returned {s} or wrote no stable file: {s}", .{ @tagName(r.status), r.detail }) };
        }
        try warnings.appendSlice(e.a, r.warnings);
        if (try e.closeDoc(c.case_id)) |wn| try warnings.append(e.a, wn);
        var files: std.ArrayList(StageFile) = .empty;
        try files.append(e.a, try e.adoptFile(ad, orig, "source/original.vwx"));
        for (cp_files.items) |cp| try files.append(e.a, try e.adoptFile(ad, cp.path, fmtA(e.a, "recipe/checkpoint-{s}.vwx", .{cp.id})));
        const script = try readAll(e.a, e.io, e.p("inputs/scripts/{s}.py", .{c.case_id}));
        try files.append(e.a, try e.sealFile(ad, "logs/script.py", script));
        try e.writeStage(ad, "created", "ok", files.items, warnings.items, .null);
        return .done;
    }

    fn stageQuery(e: *Engine, c: *const QCase, ad: []const u8) !AttemptResult {
        const orig = fmtA(e.a, "{s}/source/original.vwx", .{ad});
        const reo = fmtA(e.a, "{s}/source/reopened.vwx", .{ad});
        if (exists(e.io, reo)) try supersede(e.a, e.io, reo);
        try copyNew(e.io, orig, reo);
        try seal(e.io, reo);
        const src_sha = hashFileDup(e.a, e.io, reo) orelse return error.HashFailed;
        // Vectorworks opens a sealed file as an unsaved copy. Queries use a separate writable copy.
        const wd = try e.freshDir(fmtA(e.a, "{s}/work/query", .{ad}));
        const scratch = fmtA(e.a, "{s}/reopened.vwx", .{wd});
        try copyNew(e.io, reo, scratch);
        if (!eql(hashFileDup(e.a, e.io, scratch) orelse "", src_sha)) return .{ .retry = "the query work copy differs from source/reopened.vwx" };
        var warnings: std.ArrayList([]const u8) = .empty;
        var r = try e.mutating(.{ .kind = .open, .case_id = c.case_id, .path = scratch, .expect = "reopened.vwx" });
        if (r.status != .ok) return .{ .retry = fmtA(e.a, "open of reopened.vwx returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        r = try e.idempotent(.{ .kind = .state, .case_id = c.case_id });
        if (r.status != .ok) {
            _ = try e.closeQueryCopy(c.case_id, scratch, reo, src_sha);
            return .{ .retry = fmtA(e.a, "state returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        }
        const state_bytes = stateFile(e.a, c.case_id, src_sha, null, r.payload) orelse {
            _ = try e.closeQueryCopy(c.case_id, scratch, reo, src_sha);
            return .{ .retry = "state reply is not JSON" };
        };
        var qo = Obj.init(e.a);
        var ql = arr(e.a);
        for (c.queries) |q| try ql.append(queryPayload(e.a, q));
        qo.put("queries", .{ .array = ql });
        r = try e.idempotent(.{ .kind = .query, .case_id = c.case_id, .payload = stringifyLine(e.a, qo.value()) });
        if (r.status != .ok) {
            _ = try e.closeQueryCopy(c.case_id, scratch, reo, src_sha);
            return .{ .retry = fmtA(e.a, "query returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        }
        const raw = r.payload;
        try warnings.appendSlice(e.a, r.warnings);
        if (try e.closeQueryCopy(c.case_id, scratch, reo, src_sha)) |wn| try warnings.append(e.a, wn);
        const after = hashFileDup(e.a, e.io, scratch) orelse "";
        if (!eql(after, src_sha)) return .{ .retry = "the query work copy changed while the app had it open" };
        if (!eql(hashFileDup(e.a, e.io, reo) orelse "", src_sha)) return .{ .retry = "the sealed source/reopened.vwx changed during the query" };

        var files: std.ArrayList(StageFile) = .empty;
        try files.append(e.a, .{ .rel = "source/reopened.vwx", .sha256 = src_sha });
        const sf = try e.sealFile(ad, "native/native-state.json", state_bytes);
        try files.append(e.a, sf);
        try files.append(e.a, try e.sealFile(ad, "native/raw/query.json", raw));
        const n = normalize(e.a, .{ .case_id = c.case_id, .source_sha256 = src_sha, .state_sha256 = sf.sha256, .raw_artifact_id = "native.query_raw", .raw = raw }) catch |err| {
            return .{ .retry = fmtA(e.a, "raw query does not normalize: {s}", .{@errorName(err)}) };
        };
        try files.append(e.a, try e.sealFile(ad, "native/objects.jsonl", n.objects));
        try files.append(e.a, try e.sealFile(ad, "native/geometry.jsonl", n.measurements));
        try files.append(e.a, try e.sealFile(ad, "native/frames.json", n.frames));
        try files.append(e.a, try e.sealFile(ad, "native/document.json", n.document));
        var x = Obj.init(e.a);
        x.str("source_sha256", src_sha);
        x.str("state_sha256", sf.sha256);
        x.int("measured", @intCast(n.measured));
        x.put("gaps", strArr(e.a, n.gaps));
        for (n.gaps) |g| e.journal("query_gap", c.case_id, g, null);
        try e.writeStage(ad, "queried", "ok", files.items, warnings.items, x.value());
        return .done;
    }

    /// Collects one existing document from a byte copy. The pinned source stays closed.
    /// `source/scratch.vwx` is the copy that the native records bind. The app opens a further
    /// copy under `work/` with the source file name.
    fn stageCollect(e: *Engine, c: *const QCase, ad: []const u8, sp: []const u8) !AttemptResult {
        const want = c.source_sha256.?;
        var files: std.ArrayList(StageFile) = .empty;
        const rels = [_][]const u8{ "source/original.vwx", "source/scratch.vwx" };
        var from = sp;
        for (rels) |rel| {
            const to = fmtA(e.a, "{s}/{s}", .{ ad, rel });
            try mkdirp(e.io, dirname(to));
            if (exists(e.io, to)) try supersede(e.a, e.io, to);
            try copyNew(e.io, from, to);
            try seal(e.io, to);
            const h = hashFileDup(e.a, e.io, to) orelse return error.HashFailed;
            if (!eql(h, want)) return .{ .failed = fmtA(e.a, "source_digest_mismatch: the copy {s} has SHA256 {s}. The queue names {s}", .{ rel, h, want }) };
            try files.append(e.a, .{ .rel = rel, .sha256 = h });
            from = to;
        }
        const scratch = fmtA(e.a, "{s}/source/scratch.vwx", .{ad});
        const name = basename(sp);
        const w = try e.freshDir(fmtA(e.a, "{s}/work/open", .{ad}));
        const doc = fmtA(e.a, "{s}/{s}", .{ w, name });
        try copyNew(e.io, scratch, doc);
        var warnings: std.ArrayList([]const u8) = .empty;
        var r = try e.mutating(.{ .kind = .open, .case_id = c.case_id, .path = doc, .expect = name });
        if (r.status != .ok) return .{ .retry = fmtA(e.a, "open of the work copy returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        r = try e.idempotent(.{ .kind = .state, .case_id = c.case_id });
        if (r.status != .ok) {
            _ = try e.closeDoc(c.case_id);
            return .{ .retry = fmtA(e.a, "state before collect returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        }
        const before = r.payload;
        const raw_tmp = fmtA(e.a, "{s}/raw.jsonl", .{w});
        var po = Obj.init(e.a);
        po.str("script_sha256", c.script_sha256);
        po.str("spec", e.p("inputs/recipes/{s}.json", .{c.case_id}));
        po.str("out", raw_tmp);
        r = try e.mutating(.{ .kind = .collect, .case_id = c.case_id, .path = e.p("inputs/scripts/{s}.py", .{c.case_id}), .expect = name, .payload = stringifyLine(e.a, po.value()) });
        if (r.status != .ok) {
            _ = try e.closeDoc(c.case_id);
            return .{ .retry = fmtA(e.a, "collect returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        }
        try warnings.appendSlice(e.a, r.warnings);
        r = try e.idempotent(.{ .kind = .state, .case_id = c.case_id });
        if (r.status != .ok) {
            _ = try e.closeDoc(c.case_id);
            return .{ .retry = fmtA(e.a, "state after collect returned {s}: {s}", .{ @tagName(r.status), r.detail }) };
        }
        const after = r.payload;
        if (try e.closeDoc(c.case_id)) |wn| try warnings.append(e.a, wn);
        const src_after = hashFileDup(e.a, e.io, sp) orelse "";
        if (!eql(src_after, want)) return .{ .failed = fmtA(e.a, "source_changed: {s} has SHA256 {s} after the collect. The queue names {s}", .{ sp, src_after, want }) };
        const scratch_after = hashFileDup(e.a, e.io, scratch) orelse "";
        if (!eql(scratch_after, want)) return .{ .failed = "source_changed: source/scratch.vwx changed during the collect" };
        if (!eql(hashFileDup(e.a, e.io, doc) orelse "", want)) try warnings.append(e.a, fmtA(e.a, "the work copy {s} changed while the app had it open", .{name}));
        const k0 = stateKey(e.a, before) orelse "";
        const k1 = stateKey(e.a, after) orelse "-";
        if (!eql(k0, k1)) return .{ .retry = "state_changed: the state after collect differs from the state before collect" };
        if (!exists(e.io, raw_tmp)) return .{ .retry = "raw_incomplete: collect wrote no raw file" };
        const raw = try readAll(e.a, e.io, raw_tmp);
        const parsed = parseRaw(e.a, raw) catch |err| return .{ .retry = fmtA(e.a, "raw_incomplete: the raw file does not parse: {s}", .{@errorName(err)}) };
        if (rawEndProblem(e.a, &parsed)) |why| {
            const kept = try e.adoptFile(ad, raw_tmp, fmtA(e.a, "logs/rejected-raw-{d}.jsonl", .{e.op_seq}));
            e.journal("raw_incomplete", c.case_id, fmtA(e.a, "{s}. The rows stay at {s}", .{ why, kept.rel }), null);
            return .{ .retry = fmtA(e.a, "raw_incomplete: {s}", .{why}) };
        }
        const sf = try e.sealFile(ad, "native/native-state.json", stateFile(e.a, c.case_id, want, null, before) orelse return .{ .retry = "state reply is not JSON" });
        try files.append(e.a, sf);
        try files.append(e.a, try e.sealFile(ad, "native/state-after.json", stateFile(e.a, c.case_id, want, null, after).?));
        const rf = try e.adoptFile(ad, raw_tmp, "native/raw/raw.jsonl");
        try files.append(e.a, rf);
        const n = normalizeRaw(e.a, .{ .case_id = c.case_id, .source_sha256 = want, .state_sha256 = sf.sha256, .raw = raw }) catch |err| {
            return .{ .retry = fmtA(e.a, "raw rows do not normalize: {s}", .{@errorName(err)}) };
        };
        try files.append(e.a, try e.sealFile(ad, "native/objects.jsonl", n.objects));
        try files.append(e.a, try e.sealFile(ad, "native/ledger.jsonl", n.ledger));
        try files.append(e.a, try e.sealFile(ad, "native/measurements.jsonl", n.measurements));
        try files.append(e.a, try e.sealFile(ad, "native/frames.json", n.frames));
        try files.append(e.a, try e.sealFile(ad, "native/document.json", n.document));
        const script = try readAll(e.a, e.io, e.p("inputs/scripts/{s}.py", .{c.case_id}));
        try files.append(e.a, try e.sealFile(ad, "logs/collect.py", script));
        const problems = checkBinding(e.a, e.io, ad);
        if (problems.len > 0) return .{ .failed = fmtA(e.a, "{s} at {s}: {s}", .{ problems[0].code, problems[0].where, problems[0].msg }) };
        var x = Obj.init(e.a);
        x.str("source_sha256", want);
        x.str("state_sha256", sf.sha256);
        x.str("raw_sha256", rf.sha256);
        x.str("raw_end", n.raw_end);
        x.int("measured", @intCast(n.measured));
        x.int("units_gap", @intCast(n.units_gap));
        x.int("gaps", @intCast(n.gaps));
        try e.writeStage(ad, "collected", "ok", files.items, warnings.items, x.value());
        return .done;
    }

    /// Returns null on success or when the profile is unavailable. Otherwise the failure reason.
    fn stageExport(e: *Engine, c: *const QCase, ad: []const u8, prof: *const Profile) !?[]const u8 {
        const name = fmtA(e.a, "export-{s}", .{prof.profile_id});
        const rel_dir = fmtA(e.a, "exports/{s}/{s}", .{ prof.format, prof.profile_id });
        if (exportUnavailable(e, prof)) |u| {
            var x = Obj.init(e.a);
            x.str("reason", u.reason);
            x.str("evidence", u.evidence);
            try e.writeStage(ad, name, "unavailable", &.{}, &.{}, x.value());
            e.journal("profile_unavailable", c.case_id, fmtA(e.a, "{s}: {s}", .{ prof.profile_id, u.reason }), null);
            return null;
        }
        if (e.routePreflight(prof)) |why| return e.stop(c.case_id, fmtA(e.a, "export {s} is refused before any native call. {s}", .{ prof.profile_id, why }));
        const rt = e.exportRoute(prof, true);
        const queried = readStage(e.a, e.io, ad, "queried") orelse return error.StageMissing;
        const src_sha = strField(field(queried, "data") orelse .null, "source_sha256") orelse "";
        const baseline = try readAll(e.a, e.io, fmtA(e.a, "{s}/native/native-state.json", .{ad}));
        const base_state = stringifyLine(e.a, field(try parseJson(e.a, baseline), "state") orelse .null);
        const reo = fmtA(e.a, "{s}/source/reopened.vwx", .{ad});

        // A fresh byte copy of reopened.vwx per profile. Its state must equal the saved state.
        var clean = false;
        var leak_try: u32 = 0;
        while (leak_try < 2) : (leak_try += 1) {
            const wd = try e.freshDir(fmtA(e.a, "{s}/work/{s}", .{ ad, prof.profile_id }));
            const scratch = fmtA(e.a, "{s}/scratch.vwx", .{wd});
            try copyNew(e.io, reo, scratch);
            const r = try e.mutating(.{ .kind = .open, .case_id = c.case_id, .profile_id = prof.profile_id, .path = scratch, .expect = "scratch.vwx" });
            if (r.status != .ok) return try failExport(e, ad, name, c.case_id, fmtA(e.a, "open of the scratch copy returned {s}: {s}", .{ @tagName(r.status), r.detail }));
            const st = try e.idempotent(.{ .kind = .state, .case_id = c.case_id, .profile_id = prof.profile_id });
            if (st.status != .ok) {
                _ = try e.closeDoc(c.case_id);
                return try failExport(e, ad, name, c.case_id, fmtA(e.a, "state returned {s}", .{@tagName(st.status)}));
            }
            const k0 = stateKey(e.a, base_state) orelse "";
            const k1 = stateKey(e.a, st.payload) orelse "-";
            if (eql(k0, k1)) {
                clean = true;
                break;
            }
            e.journal("profile_state_leak", c.case_id, fmtA(e.a, "{s}: the fresh scratch copy opened with a state that differs from the saved state", .{prof.profile_id}), null);
            _ = try e.closeDoc(c.case_id);
        }
        if (!clean) return try failExport(e, ad, name, c.case_id, "profile state leak: two fresh scratch copies opened with a changed state");

        var ao = Obj.init(e.a);
        ao.put("overrides", prof.overrides);
        var r = try e.mutating(.{ .kind = .apply_state, .case_id = c.case_id, .profile_id = prof.profile_id, .payload = stringifyLine(e.a, ao.value()) });
        if (r.status != .ok) {
            _ = try e.closeDoc(c.case_id);
            return try failExport(e, ad, name, c.case_id, fmtA(e.a, "apply_state returned {s}: {s}", .{ @tagName(r.status), r.detail }));
        }
        r = try e.idempotent(.{ .kind = .state, .case_id = c.case_id, .profile_id = prof.profile_id });
        if (r.status != .ok) {
            _ = try e.closeDoc(c.case_id);
            return try failExport(e, ad, name, c.case_id, "state after apply_state failed");
        }
        if (overrideProblem(e.a, prof.overrides, base_state, r.payload)) |why| {
            _ = try e.closeDoc(c.case_id);
            return try failExport(e, ad, name, c.case_id, why);
        }
        var files: std.ArrayList(StageFile) = .empty;
        const state_bytes = stateFile(e.a, c.case_id, src_sha, prof.profile_id, r.payload).?;
        const sf = try e.sealFile(ad, fmtA(e.a, "{s}/native-state.json", .{rel_dir}), state_bytes);
        try files.append(e.a, sf);

        if (e.cfg.bundle_exports) return try e.finishBundle(c, ad, name, prof, rel_dir, rt, stateKey(e.a, r.payload), src_sha, sf.sha256, &files);
        const tr = try e.exportTries(c, ad, prof, rel_dir, rt, stateKey(e.a, r.payload));
        var warnings: std.ArrayList([]const u8) = .empty;
        try warnings.appendSlice(e.a, tr.warnings);
        if (try e.closeDoc(c.case_id)) |wn| try warnings.append(e.a, wn);
        if (tr.state_changed) |why| return try failExport(e, ad, name, c.case_id, why);
        const good = tr.ok_path orelse return try failExport(e, ad, name, c.case_id, fmtA(e.a, "{d} export tries failed: {s}", .{ e.cfg.retries + 1, std.mem.join(e.a, ", ", tr.problems) catch "" }));
        try e.storeExport(c, ad, name, prof, rel_dir, rt, &tr, good, src_sha, sf.sha256, &files, warnings.items);
        return null;
    }

    fn failExport(e: *Engine, ad: []const u8, name: []const u8, case_id: []const u8, why: []const u8) ![]const u8 {
        var x = Obj.init(e.a);
        x.str("reason", why);
        try e.writeStage(ad, name, "failed", &.{}, &.{}, x.value());
        e.journal("export_failed", case_id, fmtA(e.a, "{s}: {s}", .{ name, why }), null);
        return why;
    }

    /// Adopts the accepted try as `<rel_dir>/output.<ext>` and writes result.json and the ok stage.
    fn storeExport(e: *Engine, c: *const QCase, ad: []const u8, name: []const u8, prof: *const Profile, rel_dir: []const u8, rt: Route, tr: *const Tries, good: []const u8, src_sha: []const u8, state_sha: []const u8, files: *std.ArrayList(StageFile), warnings: []const []const u8) !void {
        _ = c;
        const out_rel = fmtA(e.a, "{s}/output.{s}", .{ rel_dir, formatExt(prof.format).? });
        const of = try e.adoptFile(ad, good, out_rel);
        try files.append(e.a, of);
        var res = Obj.init(e.a);
        res.str("profile_id", prof.profile_id);
        res.str("profile_sha256", prof.profile_sha256);
        res.str("source_sha256", src_sha);
        res.str("state_sha256", state_sha);
        res.str("output_sha256", of.sha256);
        res.put("warnings", strArr(e.a, warnings));
        var rr = Obj.init(e.a);
        if (rt.entry) |entry| {
            rr.str("api", entry.api);
            var targs = arr(e.a);
            for (entry.args) |x| try targs.append(.{ .string = x });
            rr.put("args", .{ .array = targs });
            rr.str("entry_verification", entry.verification);
        } else {
            rr.str("mode", "operator_dialog");
            rr.str("step", rt.step);
            rr.str("entry_verification", "operator_unverified");
            const df = try e.adoptFile(ad, tr.dialog_path.?, fmtA(e.a, "{s}/dialog.txt", .{rel_dir}));
            try files.append(e.a, df);
            rr.str("dialog_sha256", df.sha256);
        }
        rr.int("tries", tr.tries);
        rr.put("rejected_tries", strArr(e.a, tr.problems));
        rr.str("output_check", tr.sniff.detail);
        rr.str("driver", @tagName(e.drv.kind));
        res.put("result", rr.value());
        try files.append(e.a, try e.sealFile(ad, fmtA(e.a, "{s}/result.json", .{rel_dir}), stringify(e.a, res.value())));
        try e.writeStage(ad, name, "ok", files.items, warnings, res.value());
    }

    /// A scripting entry, a typed UI route, or the operator step for a format without either.
    const Route = struct { entry: ?*const Entry, step: []const u8, ui: ?*const UiRoute = null };

    const Tries = struct {
        ok_path: ?[]const u8 = null,
        dialog_path: ?[]const u8 = null,
        sniff: Sniff,
        problems: []const []const u8,
        warnings: []const []const u8,
        tries: u32,
        /// Set when the state after an operator export differs from the state before it.
        state_changed: ?[]const u8 = null,
        state_after: ?[]const u8 = null,
    };

    /// The scripting entry runs when its API is present and its options are set. Otherwise a typed
    /// UI route runs. Otherwise the legacy operator step stands.
    fn exportRoute(e: *Engine, prof: *const Profile, keep_state: bool) Route {
        const entry = findEntry(e.s.entries, prof.format);
        if (entry) |x| {
            if (e.cfg.strict == null or e.scriptedUsable(prof, x) or e.uiRouteFor(prof) == null) return .{ .entry = x, .step = "" };
        }
        if (e.uiRouteFor(prof)) |u| return .{ .entry = null, .step = "", .ui = u };
        return .{ .entry = null, .step = operatorStep(e.a, prof, keep_state) orelse "" };
    }

    /// Writes `<rel_dir>/try-<n>.<ext>` until one passes the output checks. An operator route
    /// prints an `operator` line per try and waits for the operator to write the file and its
    /// `.dialog.txt` record. `want_key` is the state key that an operator export must keep.
    fn exportTries(e: *Engine, c: *const QCase, ad: []const u8, prof: *const Profile, rel_dir: []const u8, rt: Route, want_key: ?[]const u8) !Tries {
        const ext = formatExt(prof.format).?;
        var warnings: std.ArrayList([]const u8) = .empty;
        var problems: std.ArrayList([]const u8) = .empty;
        var res: Tries = .{ .sniff = sniffBad("not_run", ""), .problems = &.{}, .warnings = &.{}, .tries = 0 };
        var t: u32 = 1;
        var tries: u32 = 0;
        while (tries <= e.cfg.retries) : (tries += 1) {
            while (exists(e.io, fmtA(e.a, "{s}/{s}/try-{d}.{s}", .{ ad, rel_dir, t, ext }))) t += 1;
            const tp = fmtA(e.a, "{s}/{s}/try-{d}.{s}", .{ ad, rel_dir, t, ext });
            const dp = fmtA(e.a, "{s}.dialog.txt", .{tp});
            var op: Op = .{ .kind = .export_file, .case_id = c.case_id, .profile_id = prof.profile_id, .path = tp };
            var xo = Obj.init(e.a);
            xo.str("format", prof.format);
            if (rt.entry) |entry| {
                var missing_opt: []const u8 = "";
                xo.str("api", entry.api);
                xo.put("args", resolveArgs(e.a, entry, prof, tp, &missing_opt).?);
            } else {
                op.kind = .operator_export;
                xo.str("step", rt.step);
                xo.put("options", prof.options);
                xo.str("dialog_record", dp);
                try mkdirp(e.io, dirname(tp));
                e.out.print("operator\t{s}\t{s}\t{s}\t{s}\n", .{ c.case_id, prof.profile_id, tp, rt.step }) catch {};
                e.out.flush() catch {};
            }
            op.payload = stringifyLine(e.a, xo.value());
            const er = e.call(op);
            switch (er.status) {
                .crashed => return e.stop(c.case_id, fmtA(e.a, "the app crashed during export {s}", .{prof.profile_id})),
                .modal => {
                    try e.dismiss(op);
                    try problems.append(e.a, "modal");
                    continue;
                },
                .timeout, .failed, .unsupported => {
                    try problems.append(e.a, fmtA(e.a, "{s}: {s}", .{ @tagName(er.status), er.detail }));
                    e.journal("retry", c.case_id, fmtA(e.a, "export {s} try {d} returned {s}", .{ prof.profile_id, t, @tagName(er.status) }), null);
                    continue;
                },
                .ok => {},
            }
            if (fileSize(e.io, tp) == null) {
                try problems.append(e.a, "missing_export");
                e.journal("missing_export", c.case_id, fmtA(e.a, "export {s} try {d} reported success and wrote no file", .{ prof.profile_id, t }), null);
                continue;
            }
            if (e.stableSize(tp) == null) {
                try problems.append(e.a, "partial_write");
                e.journal("partial_write", c.case_id, fmtA(e.a, "export {s} try {d} has 0 bytes or a changing size", .{ prof.profile_id, t }), null);
                continue;
            }
            res.sniff = sniffFile(e.a, e.io, prof.format, tp) catch {
                try problems.append(e.a, "read_failed");
                continue;
            };
            if (!res.sniff.ok) {
                try problems.append(e.a, res.sniff.code);
                e.journal(res.sniff.code, c.case_id, fmtA(e.a, "export {s} try {d}: {s}", .{ prof.profile_id, t, res.sniff.detail }), null);
                continue;
            }
            if (rt.entry == null) {
                if ((fileSize(e.io, dp) orelse 0) == 0) {
                    try problems.append(e.a, "dialog_record_missing");
                    e.journal("dialog_record_missing", c.case_id, fmtA(e.a, "operator export {s} try {d} has no {s}", .{ prof.profile_id, t, basename(dp) }), null);
                    continue;
                }
                const st = try e.idempotent(.{ .kind = .state, .case_id = c.case_id, .profile_id = prof.profile_id });
                if (st.status != .ok) {
                    res.state_changed = fmtA(e.a, "state after the operator export returned {s}: {s}", .{ @tagName(st.status), st.detail });
                    break;
                }
                if (want_key) |k| {
                    if (!eql(k, stateKey(e.a, st.payload) orelse "-")) {
                        res.state_changed = "operator_state_changed: the class, layer, unit or origin state after the operator export differs from native-state.json";
                        break;
                    }
                }
                res.state_after = st.payload;
                res.dialog_path = dp;
            }
            try warnings.appendSlice(e.a, er.warnings);
            res.ok_path = tp;
            break;
        }
        res.problems = problems.items;
        res.warnings = warnings.items;
        res.tries = @min(tries + 1, e.cfg.retries + 1);
        return res;
    }

    /// Paired exports of one case that apply the same state overrides must start from one sealed
    /// document and state context. A profile whose state key differs from an earlier exported
    /// profile of its group is refused before its export runs.
    fn pairProblem(e: *Engine, c: *const QCase, ad: []const u8, prof: *const Profile, key_sha: []const u8) ?[]const u8 {
        const group = stringifyLine(e.a, prof.overrides);
        for (c.profile_ids) |pid| {
            if (eql(pid, prof.profile_id)) continue;
            const other = e.s.queue.findProfile(pid) orelse continue;
            if (!eql(stringifyLine(e.a, other.overrides), group)) continue;
            const st = readStage(e.a, e.io, ad, fmtA(e.a, "export-{s}", .{pid})) orelse continue;
            if (!eql(strField(st, "status") orelse "", "ok")) continue;
            const have = strField(field(st, "data") orelse .null, "state_key_sha256") orelse continue;
            if (!eql(have, key_sha)) return fmtA(e.a, "paired_state_mismatch: profile {s} exported from state context {s}. Profile {s} has {s}. Paired exports need one sealed state", .{ pid, have, prof.profile_id, key_sha });
        }
        return null;
    }

    /// Runs the bundle export of `prof` and writes its stage. Returns null on success or when the
    /// profile is unavailable. Otherwise the failure reason.
    fn finishBundle(e: *Engine, c: *const QCase, ad: []const u8, name: []const u8, prof: *const Profile, rel_dir: []const u8, rt: Route, want_key: ?[]const u8, src_sha: []const u8, state_sha: []const u8, files: *std.ArrayList(StageFile)) !?[]const u8 {
        const key_sha = shaDup(e.a, want_key orelse "");
        if (e.pairProblem(c, ad, prof, key_sha)) |why| {
            _ = try e.closeDoc(c.case_id);
            return try failExport(e, ad, name, c.case_id, why);
        }
        const bt = try e.exportBundle(c, ad, prof, rt, want_key, src_sha, state_sha);
        var warnings: std.ArrayList([]const u8) = .empty;
        try warnings.appendSlice(e.a, bt.warnings);
        if (bt.unavailable) |u| if (u.rejected) |msg| {
            // The rejection is recorded before the cleanup, so a stop during the close keeps it. The
            // scratch copy is closed through the guarded close without a save. A sealed source is not touched.
            var x = Obj.init(e.a);
            x.str("reason", u.reason);
            x.str("evidence", u.evidence);
            x.str("outcome", rejection_outcome);
            x.str("api", stl_api);
            x.str("native_message", msg);
            x.boolean("file_claimed", false);
            x.str("scratch_cleanup", "requested");
            try e.writeStage(ad, name, "unavailable", &.{}, &.{}, x.value());
            e.journal("profile_unavailable", c.case_id, fmtA(e.a, "{s}: {s}", .{ prof.profile_id, u.reason }), null);
            if (!e.ownedScratchOpen()) return e.stop(c.case_id, "the rejected export left a document that is not the export scratch copy. It was not closed. Reconcile by hand");
            if (try e.closeOpenedDoc(c.case_id)) |wn| {
                e.journal("scratch_close_failed", c.case_id, wn, null);
            } else e.journal("scratch_closed", c.case_id, fmtA(e.a, "{s} was closed without a save after the rejected export", .{prof.profile_id}), null);
            return null;
        };
        // A finished export is persisted before the close. The other outcomes close first.
        const clean = bt.unavailable == null and bt.state_changed == null and bt.ok != null;
        if (!clean) {
            if (try e.closeDoc(c.case_id)) |wn| try warnings.append(e.a, wn);
        }
        if (bt.unavailable) |u| {
            var x = Obj.init(e.a);
            x.str("reason", u.reason);
            x.str("evidence", u.evidence);
            try e.writeStage(ad, name, "unavailable", &.{}, &.{}, x.value());
            e.journal("profile_unavailable", c.case_id, fmtA(e.a, "{s}: {s}", .{ prof.profile_id, u.reason }), null);
            return null;
        }
        if (bt.state_changed) |why| return try failExport(e, ad, name, c.case_id, why);
        const ok = bt.ok orelse return try failExport(e, ad, name, c.case_id, fmtA(e.a, "{d} export tries failed: {s}", .{ e.cfg.retries + 1, std.mem.join(e.a, ", ", bt.problems) catch "" }));
        if (c.kind == .existing_document) {
            // The pinned source and the scratch copy keep the queue digest during the export.
            const want = c.source_sha256.?;
            const sp = strField(e.sources, c.case_id) orelse "";
            if (!eql(hashFileDup(e.a, e.io, sp) orelse "", want)) {
                _ = try e.closeDoc(c.case_id);
                return try failExport(e, ad, name, c.case_id, fmtA(e.a, "source_changed: {s} changed during the export", .{sp}));
            }
            if (!eql(hashFileDup(e.a, e.io, fmtA(e.a, "{s}/source/scratch.vwx", .{ad})) orelse "", want)) {
                _ = try e.closeDoc(c.case_id);
                return try failExport(e, ad, name, c.case_id, "source_changed: source/scratch.vwx changed during the export");
            }
        }
        try e.storeBundle(c, ad, name, prof, rel_dir, &bt, ok, src_sha, state_sha, key_sha, files, warnings.items);
        // The stage is on disk. A close failure or stop leaves the export evidence recoverable.
        if (try e.closeDoc(c.case_id)) |wn| e.journal("close_warning", c.case_id, wn, null);
        return null;
    }

    /// Publishes the sealed bundle of the accepted try: every file of the operation directory is a
    /// stage file, result.json names the bundle and the stage binds the run inputs that a resume
    /// compares.
    fn storeBundle(e: *Engine, c: *const QCase, ad: []const u8, name: []const u8, prof: *const Profile, rel_dir: []const u8, bt: *const BundleTries, ok: BundleOk, src_sha: []const u8, state_sha: []const u8, key_sha: []const u8, files: *std.ArrayList(StageFile), warnings: []const []const u8) !void {
        const st = e.cfg.strict;
        for (ok.files) |f| try files.append(e.a, f);
        var res = Obj.init(e.a);
        res.str("profile_id", prof.profile_id);
        res.str("profile_sha256", prof.profile_sha256);
        res.str("source_sha256", src_sha);
        res.str("state_sha256", state_sha);
        res.str("output_sha256", ok.main_sha256);
        res.put("warnings", strArr(e.a, warnings));
        var rr = Obj.init(e.a);
        rr.put("route", ok.route);
        rr.int("tries", bt.tries);
        rr.put("rejected_tries", strArr(e.a, bt.problems));
        rr.str("output_check", ok.sniff.detail);
        rr.str("driver", @tagName(e.drv.kind));
        var b = Obj.init(e.a);
        b.str("op_id", ok.op_name);
        b.int("attempt", ok.attempt);
        b.str("dir", ok.op_rel);
        b.str("format", prof.format);
        b.str("main_file", ok.main_file);
        b.str("manifest_sha256", ok.manifest_sha256);
        b.str("seal_sha256", ok.seal_sha256);
        var sl = arr(e.a);
        for (ok.sidecars) |s| {
            var x = Obj.init(e.a);
            x.str("path", s.path);
            x.int("size", @intCast(s.size));
            x.str("sha256", s.sha256);
            try sl.append(x.value());
        }
        b.put("sidecars", .{ .array = sl });
        b.str("dependency_closure", ok.closure.state);
        b.str("semantics", "unchecked");
        rr.put("bundle", b.value());
        res.put("result", rr.value());
        res.str("state_key_sha256", key_sha);
        res.str("pair_group", stringifyLine(e.a, prof.overrides));
        res.str("options_sha256", optionsDigest(e.a, prof.options));
        if (st) |s| {
            res.str("executable_sha256", s.exe_sha256);
            res.str("phase", @tagName(s.phase));
            res.str("recipe_sha256", shaDup(e.a, readAll(e.a, e.io, e.p("inputs/recipes/{s}.json", .{c.case_id})) catch ""));
        }
        try files.append(e.a, try e.sealFile(ad, fmtA(e.a, "{s}/result.json", .{rel_dir}), stringify(e.a, res.value())));
        try e.writeStage(ad, name, "ok", files.items, warnings, res.value());
    }

    /// Resume check of one completed export stage of a production run. Null when the stage still
    /// binds the current executable, profile, recipe, document identity and route evidence and its
    /// bundle verifies. Otherwise the reason.
    fn bundleStageProblem(e: *Engine, c: *const QCase, ad: []const u8, name: []const u8, prof: *const Profile) ?[]const u8 {
        const st = e.cfg.strict orelse return null;
        const v = readStage(e.a, e.io, ad, name) orelse return null;
        if (!eql(strField(v, "status") orelse "", "ok")) return null;
        const data = field(v, "data") orelse .null;
        const bundle = field(field(data, "result") orelse .null, "bundle") orelse return "stale_stage: the stage holds no sealed bundle";
        if (!eql(strField(data, "executable_sha256") orelse "", st.exe_sha256)) return "stale_executable: the stage was written by another executable";
        if (!eql(strField(data, "profile_sha256") orelse "", prof.profile_sha256)) return "stale_profile: the profile hash differs from the stage";
        const recipe = shaDup(e.a, readAll(e.a, e.io, e.p("inputs/recipes/{s}.json", .{c.case_id})) catch "");
        if (!eql(strField(data, "recipe_sha256") orelse "", recipe)) return "stale_recipe: the frozen recipe differs from the stage";
        const src = strField(data, "source_sha256") orelse "";
        if (c.kind == .existing_document) {
            if (!eql(src, c.source_sha256 orelse "")) return "stale_document: the stage names another source document";
        } else {
            const now = hashFileDup(e.a, e.io, fmtA(e.a, "{s}/source/reopened.vwx", .{ad})) orelse return "stale_document: source/reopened.vwx is missing";
            if (!eql(src, now)) return "stale_document: source/reopened.vwx differs from the document that the stage exported";
        }
        if (e.uiRouteFor(prof)) |ur| {
            const rinfo = field(field(data, "result") orelse .null, "route") orelse .null;
            if (eql(strField(rinfo, "mode") orelse "", "ui")) {
                const want = if (st.phase == .verified) ur.evidence_sha256 else "";
                if (!eql(strField(rinfo, "route_sha256") orelse "", ur.route_sha256)) return "stale_route: the typed route changed after the export";
                if (!eql(strField(rinfo, "evidence_sha256") orelse "", want)) return "stale_route: the calibration evidence changed after the export";
            }
        }
        const dir = fmtA(e.a, "{s}/{s}", .{ ad, strField(bundle, "dir") orelse "" });
        var sidecars: std.ArrayList([]const u8) = .empty;
        for (arrField(bundle, "sidecars")) |s| {
            if (strField(s, "path")) |sp| sidecars.append(e.a, sp) catch {};
        }
        var ver = opdir.verify(e.a, e.io, dir, .{
            .op_id = strField(bundle, "op_id"),
            .format = prof.format,
            .main_file = strField(bundle, "main_file"),
            .bindings = .{ .source_sha256 = src, .state_sha256 = strField(data, "state_sha256") orelse "", .profile_id = prof.profile_id, .profile_sha256 = prof.profile_sha256 },
        }, .{}) catch |err| return fmtA(e.a, "stale_bundle: {s} cannot be read: {s}", .{ dir, @errorName(err) });
        defer ver.deinit();
        if (!ver.isVerified()) return fmtA(e.a, "stale_bundle: {s} is {s}: {s}", .{ dir, @tagName(ver.status), ver.reason });
        return null;
    }

    /// Every export stage of an attempt that DONE.json lists must pass `bundleStageProblem`.
    fn strictAttemptProblem(e: *Engine, c: *const QCase, attempt: u32) ?[]const u8 {
        const ad = e.attemptDir(c, attempt);
        for (c.profile_ids) |pid| {
            const prof = e.s.queue.findProfile(pid) orelse continue;
            if (e.bundleStageProblem(c, ad, fmtA(e.a, "export-{s}", .{pid}), prof)) |why| return fmtA(e.a, "{s}: {s}", .{ pid, why });
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // sealed export bundles
    // -----------------------------------------------------------------------

    fn uiRouteFor(e: *Engine, prof: *const Profile) ?*const UiRoute {
        const st = e.cfg.strict orelse return null;
        const rs = st.routes orelse return null;
        return rs.forFormat(prof.format);
    }

    /// True when the scripting entry can run: the API is present and every option it needs is set.
    fn scriptedUsable(e: *Engine, prof: *const Profile, entry: *const Entry) bool {
        if (e.apiPresent(entry.api) != true) return false;
        var missing: []const u8 = "";
        return resolveArgs(e.a, entry, prof, "", &missing) != null;
    }

    fn runBinding(e: *Engine, prof: *const Profile, src_sha: []const u8, state_sha: []const u8) nur.Binding {
        const st = e.cfg.strict.?;
        return .{ .release = st.release, .workspace = st.workspace, .profile_hash = prof.profile_sha256, .source_digest = src_sha, .state_digest = state_sha };
    }

    /// Refuses a UI route before any native call when its evidence cannot be resolved. The
    /// calibration phase needs the scratch authorization and no evidence. The verified phase needs
    /// evidence that names this route, this executable and a retained bundle that verifies.
    fn routePreflight(e: *Engine, prof: *const Profile) ?[]const u8 {
        const st = e.cfg.strict orelse return null;
        const ur = e.uiRouteFor(prof) orelse return null;
        if (findEntry(e.s.entries, prof.format) != null and e.scriptedUsable(prof, findEntry(e.s.entries, prof.format).?)) return null;
        switch (st.phase) {
            .inventory => return "the inventory phase runs no export",
            .calibration => {
                if (st.scratch == null) return "scratch_not_authorized: the calibration phase needs an authorized scratch session";
                return null;
            },
            .verified => {
                if (nur.isTargeted(ur.format)) return fmtA(e.a, "refused: format {s} is a targeted format. It runs inventory and calibration only", .{prof.format});
                switch (loadEvidence(e.a, e.io, ur, st.evidence_dir, st.exe_sha256)) {
                    .ok => return null,
                    .problem => |pr| return fmtA(e.a, "{s}: {s}", .{ pr.code, pr.msg }),
                }
            },
        }
    }

    const SideFile = struct { path: []const u8, size: u64, sha256: []const u8 };

    const BundleOk = struct {
        op_name: []const u8,
        attempt: u32,
        /// Relative to the attempt directory.
        op_rel: []const u8,
        main_file: []const u8,
        manifest_sha256: []const u8,
        seal_sha256: []const u8,
        /// Manifest paths other than the main file, in manifest byte order.
        sidecars: []const SideFile,
        main_sha256: []const u8,
        /// Every published file, relative to the attempt directory.
        files: []const StageFile,
        sniff: Sniff,
        closure: Closure,
        route: json.Value,
    };

    const BundleTries = struct {
        ok: ?BundleOk = null,
        problems: []const []const u8,
        warnings: []const []const u8,
        tries: u32,
        /// Set when the state before or after an export differs from the sealed state context.
        state_changed: ?[]const u8 = null,
        /// Set when the exporter wrote a name that the path rules refuse.
        unavailable: ?Unavailable = null,
        /// Raw state reply after the accepted export.
        state_after: ?[]const u8 = null,
    };

    fn latch(e: *Engine, case_id: []const u8, why: []const u8) void {
        if (e.cfg.strict == null) return;
        var o = Obj.init(e.a);
        o.str("schema", schema_reconcile);
        o.int("run", e.run_no);
        o.str("case_id", case_id);
        o.str("reason", why);
        const lp = e.p("RECONCILE.json", .{});
        if (exists(e.io, lp)) return;
        putSealed(e.a, e.io, lp, stringify(e.a, o.value())) catch {};
        e.journal("reconcile_latched", case_id, why, null);
    }

    /// The reason that an earlier run left a reconcile latch, or null.
    fn latchPending(e: *Engine) ?[]const u8 {
        if (e.cfg.strict == null) return null;
        // An in-flight record means that an earlier process died, or stopped, between an action and its reply.
        const ip = e.p(inflight_name, .{});
        if (exists(e.io, ip)) {
            const ib = readAll(e.a, e.io, ip) catch "";
            const iv = parseJson(e.a, ib) catch .null;
            return fmtA(e.a, "an action was in flight and no definite reply was recorded ({s}, run {s}). INFLIGHT.json holds the record", .{ strField(iv, "what") orelse "unreadable record", if (field(iv, "run")) |r| (if (r == .number_string) r.number_string else "?") else "?" });
        }
        const lp = e.p("RECONCILE.json", .{});
        const bytes = readAll(e.a, e.io, lp) catch return if (exists(e.io, lp)) "RECONCILE.json is unreadable" else null;
        const v = parseJson(e.a, bytes) catch return "RECONCILE.json does not parse";
        return fmtA(e.a, "case `{s}` run {s}: {s}", .{ strField(v, "case_id") orelse "", if (field(v, "run")) |r| (if (r == .number_string) r.number_string else "?") else "?", strField(v, "reason") orelse "" });
    }

    /// The text of the open marker that `opdir.Operation.create` writes. A test compares the bytes.
    pub fn openMarkerText(a: Allocator, op_id: []const u8) []const u8 {
        return fmtA(a, "{{\"schema\":\"{s}\",\"op_id\":\"{s}\"}}\n", .{ opdir.schema_open, op_id });
    }

    /// Creates `<root>/<name>` exclusively without the open marker. The runtime of a UI route needs
    /// an empty directory. `markOpen` writes the marker after the export.
    fn createUnmarked(e: *Engine, root: []const u8, name: []const u8) !opdir.Operation {
        if (opdir.nameProblem(name) != null) return error.InvalidName;
        const path = try std.fmt.allocPrint(e.a, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), name });
        Dir.cwd().createDir(e.io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return error.OperationExists,
            else => return err,
        };
        return .{ .gpa = e.a, .path = path, .name_start = path.len - name.len };
    }

    fn markOpen(e: *Engine, op: *const opdir.Operation) !void {
        const mp = try std.fmt.allocPrint(e.a, "{s}/{s}", .{ op.path, opdir.open_name });
        var fh = try Dir.cwd().createFile(e.io, mp, .{ .exclusive = true });
        defer fh.close(e.io);
        try fh.writeStreamingAll(e.io, openMarkerText(e.a, op.name()));
        try fh.sync(e.io);
    }

    fn stateOf(e: *Engine, c: *const QCase, prof: *const Profile) Stopped!Reply {
        return e.idempotent(.{ .kind = .state, .case_id = c.case_id, .profile_id = prof.profile_id });
    }

    /// Runs the export of `prof` up to `retries + 1` times. Every try owns a fresh operation
    /// directory `<ad>/exports/<format>/<profile>.a<n>`. A failed try stays on disk. The state
    /// before and after each try must equal `want_key`. A changed state or an uncertain action ends
    /// the tries, because an isolated output directory does not make the document state safe to
    /// retry. The accepted try is sealed, verified and checked for references.
    fn exportBundle(e: *Engine, c: *const QCase, ad: []const u8, prof: *const Profile, rt: Route, want_key: ?[]const u8, src_sha: []const u8, state_sha: []const u8) !BundleTries {
        const ext = formatExt(prof.format).?;
        var warnings: std.ArrayList([]const u8) = .empty;
        var problems: std.ArrayList([]const u8) = .empty;
        var res: BundleTries = .{ .problems = &.{}, .warnings = &.{}, .tries = 0 };
        const fmt_root = fmtA(e.a, "{s}/exports/{s}", .{ ad, prof.format });
        try mkdirp(e.io, fmt_root);
        var attempt_no: u32 = 0;
        var tries: u32 = 0;
        while (tries <= e.cfg.retries) : (tries += 1) {
            // A fresh directory per try. An existing directory is never reused.
            var name_buf: [160]u8 = undefined;
            var op: opdir.Operation = undefined;
            while (true) {
                attempt_no += 1;
                const nm = opdir.attemptName(&name_buf, prof.profile_id, attempt_no) catch {
                    try problems.append(e.a, "invalid_operation_name");
                    res.unavailable = .{ .reason = fmtA(e.a, "profile id `{s}` does not make a valid operation name", .{prof.profile_id}), .evidence = fmtA(e.a, "inputs/profiles/{s}.json", .{prof.profile_id}) };
                    break;
                };
                // The UI runtime refuses a directory that holds a file, so a UI route gets the open
                // marker after its export. A scripted route gets it first.
                op = (if (rt.ui != null) e.createUnmarked(fmt_root, nm) else opdir.Operation.create(e.a, e.io, fmt_root, nm, null)) catch |err| switch (err) {
                    error.OperationExists => continue,
                    else => return err,
                };
                break;
            }
            if (res.unavailable != null) break;
            const op_name = op.name();
            const op_rel = fmtA(e.a, "exports/{s}/{s}", .{ prof.format, op_name });

            // The state before the export. A changed state stops every later try.
            const sb = try e.stateOf(c, prof);
            if (sb.status != .ok) {
                try problems.append(e.a, "state_unreadable");
                res.state_changed = fmtA(e.a, "state before the export returned {s}: {s}", .{ @tagName(sb.status), sb.detail });
                break;
            }
            if (want_key) |k| {
                if (!eql(k, stateKey(e.a, sb.payload) orelse "-")) {
                    res.state_changed = "state_changed: the document state before the export differs from the sealed state context";
                    break;
                }
            }

            var main_name: []const u8 = fmtA(e.a, "export.{s}", .{ext});
            var sidecars: []const []const u8 = &.{};
            var eop: Op = .{ .kind = .export_file, .case_id = c.case_id, .profile_id = prof.profile_id };
            var xo = Obj.init(e.a);
            xo.str("format", prof.format);
            var route_info = Obj.init(e.a);
            if (rt.entry) |entry| {
                const tp = try op.filePath(main_name);
                eop.path = tp;
                var missing_opt: []const u8 = "";
                xo.str("api", entry.api);
                xo.put("args", resolveArgs(e.a, entry, prof, tp, &missing_opt).?);
                route_info.str("mode", "scripted");
                route_info.str("api", entry.api);
                route_info.str("entry_verification", entry.verification);
            } else if (rt.ui) |ur| {
                const st = e.cfg.strict.?;
                main_name = ur.outputs.primary;
                sidecars = ur.outputs.required_sidecars;
                eop.kind = .ui_export;
                eop.path = try op.filePath(main_name);
                xo.str("route_id", ur.id);
                xo.str("phase", @tagName(st.phase));
                xo.str("op_id", op_name);
                xo.str("op_dir", op.path);
                route_info.str("mode", "ui");
                route_info.str("route_id", ur.id);
                route_info.str("route_sha256", ur.route_sha256);
                route_info.str("phase", @tagName(st.phase));
                route_info.str("evidence_sha256", if (st.phase == .verified) ur.evidence_sha256 else "");
                route_info.str("release", st.release);
                route_info.str("workspace", st.workspace);
                route_info.str("backend", st.backend);
                var b = Obj.init(e.a);
                const rb = e.runBinding(prof, src_sha, state_sha);
                b.str("release", rb.release);
                b.str("workspace", rb.workspace);
                b.str("profile_hash", rb.profile_hash);
                b.str("source_digest", rb.source_digest);
                b.str("state_digest", rb.state_digest);
                b.str("options_sha256", optionsDigest(e.a, prof.options));
                xo.put("binding", b.value());
                if (st.phase == .verified) switch (loadEvidence(e.a, e.io, ur, st.evidence_dir, st.exe_sha256)) {
                    .ok => |ev| {
                        if (evidenceIdentityProblem(ev, rb.release, rb.workspace, optionsDigest(e.a, prof.options))) |why| {
                            try problems.append(e.a, "evidence_stale_identity");
                            res.unavailable = .{ .reason = fmtA(e.a, "{s}", .{why}), .evidence = fmtA(e.a, "{s}/{s}.json", .{ st.evidence_dir, ur.evidence_sha256 }) };
                            break;
                        }
                    },
                    .problem => |pr| {
                        try problems.append(e.a, pr.code);
                        res.unavailable = .{ .reason = fmtA(e.a, "{s}: {s}", .{ pr.code, pr.msg }), .evidence = fmtA(e.a, "{s}/{s}.json", .{ st.evidence_dir, ur.evidence_sha256 }) };
                        break;
                    },
                };
            } else {
                try problems.append(e.a, "no_route");
                res.unavailable = .{ .reason = fmtA(e.a, "format {s} has no scripting entry and no typed UI route", .{prof.format}), .evidence = "inputs/export-entries.json" };
                break;
            }
            eop.payload = stringifyLine(e.a, xo.value());
            const er = e.call(eop);
            // An uncertain or refused reply comes before any dialog handling or retry.
            if (er.uncertain) {
                const why = fmtA(e.a, "export {s} try {d} is uncertain: {s}", .{ prof.profile_id, attempt_no, er.detail });
                e.latch(c.case_id, why);
                return e.stop(c.case_id, fmtA(e.a, "{s}. Reconcile the app and the outputs before any replay", .{why}));
            }
            if (er.refused) return e.stop(c.case_id, fmtA(e.a, "export {s} try {d} was refused before any action: {s}. No latch was written", .{ prof.profile_id, attempt_no, er.detail }));
            switch (er.status) {
                .crashed => {
                    e.latch(c.case_id, fmtA(e.a, "the app crashed during export {s}", .{prof.profile_id}));
                    return e.stop(c.case_id, fmtA(e.a, "the app crashed during export {s}", .{prof.profile_id}));
                },
                .modal => {
                    try e.dismiss(eop);
                    try problems.append(e.a, "modal");
                    continue;
                },
                .timeout, .failed, .unsupported => {
                    // The application's own refusal of the STL export is an outcome, not a failure to retry.
                    if (rejectedStl(e.a, eop, er)) |msg| {
                        try problems.append(e.a, fmtA(e.a, "{s}: {s}", .{ rejection_outcome, msg }));
                        res.unavailable = .{ .reason = fmtA(e.a, "{s}: {s}", .{ rejection_outcome, msg }), .evidence = op_rel, .rejected = msg };
                        e.journal("profile_rejected", c.case_id, fmtA(e.a, "export {s} try {d}: the application rejected the export: {s}. No file was produced", .{ prof.profile_id, attempt_no, msg }), null);
                        break;
                    }
                    try problems.append(e.a, fmtA(e.a, "{s}: {s}", .{ @tagName(er.status), er.detail }));
                    e.journal("retry", c.case_id, fmtA(e.a, "export {s} try {d} returned {s}", .{ prof.profile_id, attempt_no, @tagName(er.status) }), null);
                    if (er.uncertain) {
                        // An action was sent and its outcome is unknown. The run stops with the
                        // latch set. Nothing replays until `reconcile` clears it.
                        const why = fmtA(e.a, "export {s} try {d} is uncertain: {s}", .{ prof.profile_id, attempt_no, er.detail });
                        e.latch(c.case_id, why);
                        return e.stop(c.case_id, fmtA(e.a, "{s}. Reconcile the app and the outputs before any replay", .{why}));
                    }
                    continue;
                },
                .ok => {},
            }
            // The completion evidence stays in the bundle record. A UI export carries the correlated
            // progress transition that the runtime saw. A scripted export carries the reply of the
            // bridge program, which returns after the export call. The offline fake driver is
            // labeled as such and is no native evidence.
            if (rt.ui != null) {
                const pv = parseJson(e.a, er.payload) catch .null;
                route_info.put("completion", field(pv, "completion") orelse .null);
                route_info.put("cadence", field(pv, "cadence") orelse .null);
            } else {
                var cn = Obj.init(e.a);
                cn.str("via", if (e.drv.kind == .native) "bridge_reply" else "fake_driver");
                cn.boolean("established", true);
                cn.str("contract", if (e.drv.kind == .native) "the bridge program returns after the export call" else "offline fake driver, no native evidence");
                route_info.put("completion", cn.value());
            }
            if (rt.ui != null) e.markOpen(&op) catch |err| return e.stop(c.case_id, fmtA(e.a, "the open marker of {s} could not be written: {s}", .{ op.name(), @errorName(err) }));
            const main_path = try op.filePath(main_name);
            const size0 = fileSize(e.io, main_path) orelse {
                try problems.append(e.a, "missing_export");
                e.journal("missing_export", c.case_id, fmtA(e.a, "export {s} try {d} reported success and wrote no {s}", .{ prof.profile_id, attempt_no, main_name }), null);
                continue;
            };
            if (size0 == 0) {
                try problems.append(e.a, "empty_export");
                e.journal("empty_export", c.case_id, fmtA(e.a, "export {s} try {d} wrote 0 bytes", .{ prof.profile_id, attempt_no }), null);
                continue;
            }
            if (e.stableSize(main_path) == null) {
                try problems.append(e.a, "partial_write");
                e.journal("partial_write", c.case_id, fmtA(e.a, "export {s} try {d} has a changing size", .{ prof.profile_id, attempt_no }), null);
                continue;
            }
            const sniff = sniffFile(e.a, e.io, prof.format, main_path) catch |err| {
                try problems.append(e.a, "read_failed");
                e.journal("read_failed", c.case_id, fmtA(e.a, "export {s} try {d}: {s}", .{ prof.profile_id, attempt_no, @errorName(err) }), null);
                continue;
            };
            if (!sniff.ok) {
                try problems.append(e.a, sniff.code);
                e.journal(sniff.code, c.case_id, fmtA(e.a, "export {s} try {d}: {s}", .{ prof.profile_id, attempt_no, sniff.detail }), null);
                continue;
            }
            // The state after the export. A changed state is not retried.
            const sa = try e.stateOf(c, prof);
            if (sa.status != .ok) {
                res.state_changed = fmtA(e.a, "state after the export returned {s}: {s}", .{ @tagName(sa.status), sa.detail });
                break;
            }
            if (want_key) |k| {
                if (!eql(k, stateKey(e.a, sa.payload) orelse "-")) {
                    res.state_changed = "state_changed: the document state after the export differs from the sealed state context";
                    break;
                }
            }
            // Seal, verify and parse with the pack reader.
            var diag: opdir.Diagnostic = .{};
            const bind: opdir.Bindings = .{ .source_sha256 = src_sha, .state_sha256 = state_sha, .profile_id = prof.profile_id, .profile_sha256 = prof.profile_sha256 };
            var sealed = op.seal(e.a, e.io, .{ .format = prof.format, .main_file = main_name, .bindings = bind, .expected_sidecars = sidecars }, &diag) catch |err| switch (err) {
                error.InvalidPath, error.ReservedName, error.CaseAlias => {
                    try problems.append(e.a, "bad_path");
                    res.unavailable = .{ .reason = fmtA(e.a, "bad_path: the exporter wrote `{s}`, which breaks the path rules ({s})", .{ diag.path(), @errorName(err) }), .evidence = op_rel };
                    break;
                },
                else => {
                    try problems.append(e.a, fmtA(e.a, "seal_failed: {s} at {s}", .{ @errorName(err), diag.path() }));
                    e.journal("seal_failed", c.case_id, fmtA(e.a, "export {s} try {d}: {s} at {s}", .{ prof.profile_id, attempt_no, @errorName(err), diag.path() }), null);
                    continue;
                },
            };
            defer sealed.deinit();
            var ver = opdir.verify(e.a, e.io, op.path, .{ .op_id = op_name, .format = prof.format, .main_file = main_name, .bindings = bind, .expected_sidecars = sidecars }, .{}) catch |err| {
                try problems.append(e.a, fmtA(e.a, "verify_failed: {s}", .{@errorName(err)}));
                continue;
            };
            defer ver.deinit();
            if (!ver.isVerified()) {
                try problems.append(e.a, fmtA(e.a, "bundle_{s}: {s}", .{ @tagName(ver.status), ver.reason }));
                continue;
            }
            const man_path = try std.fmt.allocPrint(e.a, "{s}/{s}", .{ op.path, opdir.manifest_name });
            const seal_path = try std.fmt.allocPrint(e.a, "{s}/{s}", .{ op.path, opdir.seal_name });
            var pd = pack.Diags.init(e.a);
            const man_bytes = readAll(e.a, e.io, man_path) catch "";
            const seal_bytes = readAll(e.a, e.io, seal_path) catch "";
            const pm = pack.parseBundleManifest(e.a, &pd, op_rel, man_bytes);
            const ps = pack.parseBundleSeal(e.a, &pd, op_rel, seal_bytes);
            if (pm == null or ps == null or pd.errors() > 0) {
                try problems.append(e.a, if (pd.list.items.len > 0) fmtA(e.a, "{s}: {s}", .{ pd.list.items[0].code, pd.list.items[0].message }) else "bundle_reader_refused");
                continue;
            }
            const closure = bundleClosure(e.a, e.io, prof.format, op.path, &sealed.manifest) catch |err| Closure{ .state = "scan_failed", .problem = fmtA(e.a, "scan_failed: {s}", .{@errorName(err)}) };
            if (closure.problem) |why| {
                try problems.append(e.a, why);
                e.journal("dependency_loss", c.case_id, fmtA(e.a, "export {s} try {d}: {s}", .{ prof.profile_id, attempt_no, why }), null);
                // A reference that escapes the bundle fails the same way on every try.
                if (std.mem.startsWith(u8, why, "reference_escapes_bundle")) break;
                continue;
            }
            // Pack paths of the published files.
            var files: std.ArrayList(StageFile) = .empty;
            var side: std.ArrayList(SideFile) = .empty;
            var main_sha: []const u8 = "";
            var long_name: ?[]const u8 = null;
            for (sealed.manifest.files) |f| {
                const rel = fmtA(e.a, "{s}/{s}", .{ op_rel, f.path });
                if (opdir.pathProblem(rel) != null) long_name = rel;
                const sha = try e.a.dupe(u8, &f.sha256);
                try files.append(e.a, .{ .rel = rel, .sha256 = sha });
                if (eql(f.path, main_name)) main_sha = sha else try side.append(e.a, .{ .path = try e.a.dupe(u8, f.path), .size = f.size, .sha256 = sha });
            }
            if (long_name) |why| {
                try problems.append(e.a, "bad_path");
                res.unavailable = .{ .reason = fmtA(e.a, "bad_path: the pack path {s} breaks the path rules", .{why}), .evidence = op_rel };
                break;
            }
            for (side.items, 1..) |_, k| {
                if (fmtA(e.a, "export.{s}.a{d}.sidecar.{d:0>4}", .{ prof.profile_id, attempt_no, k }).len > 128) {
                    try problems.append(e.a, "bad_path");
                    res.unavailable = .{ .reason = "bad_path: a sidecar artifact id would exceed 128 bytes", .evidence = op_rel };
                    break;
                }
            }
            if (res.unavailable != null) break;
            const man_hash = hashFile(e.io, man_path) catch {
                try problems.append(e.a, "read_failed");
                continue;
            };
            const seal_hash = hashFile(e.io, seal_path) catch {
                try problems.append(e.a, "read_failed");
                continue;
            };
            const man_sha = try e.a.dupe(u8, &man_hash);
            const seal_sha = try e.a.dupe(u8, &seal_hash);
            try files.append(e.a, .{ .rel = fmtA(e.a, "{s}/{s}", .{ op_rel, opdir.manifest_name }), .sha256 = man_sha });
            try files.append(e.a, .{ .rel = fmtA(e.a, "{s}/{s}", .{ op_rel, opdir.seal_name }), .sha256 = seal_sha });
            try warnings.appendSlice(e.a, er.warnings);
            res.state_after = sa.payload;
            route_info.put("report", parseJson(e.a, er.payload) catch .null);
            res.ok = .{
                .op_name = try e.a.dupe(u8, op_name),
                .attempt = attempt_no,
                .op_rel = op_rel,
                .main_file = main_name,
                .manifest_sha256 = man_sha,
                .seal_sha256 = seal_sha,
                .sidecars = side.items,
                .main_sha256 = main_sha,
                .files = files.items,
                .sniff = sniff,
                .closure = closure,
                .route = route_info.value(),
            };
            break;
        }
        res.problems = problems.items;
        res.warnings = warnings.items;
        res.tries = @min(tries + 1, e.cfg.retries + 1);
        return res;
    }
    /// Operator export of an existing-document case. A fresh copy of source/scratch.vwx opens with
    /// the collected state. The operator sets the view and layers that the profile options name.
    /// The state before and after the export are both sealed. The pinned source and the scratch
    /// copy must keep the queue digest.
    fn stageOperatorExisting(e: *Engine, c: *const QCase, ad: []const u8, prof: *const Profile, sp: []const u8) !?[]const u8 {
        const name = fmtA(e.a, "export-{s}", .{prof.profile_id});
        const rel_dir = fmtA(e.a, "exports/{s}/{s}", .{ prof.format, prof.profile_id });
        const want = c.source_sha256.?;
        const baseline = try readAll(e.a, e.io, fmtA(e.a, "{s}/native/native-state.json", .{ad}));
        const base_state = stringifyLine(e.a, field(try parseJson(e.a, baseline), "state") orelse .null);
        const scratch = fmtA(e.a, "{s}/source/scratch.vwx", .{ad});
        const doc_name = basename(sp);
        const w = try e.freshDir(fmtA(e.a, "{s}/work/{s}", .{ ad, prof.profile_id }));
        const doc = fmtA(e.a, "{s}/{s}", .{ w, doc_name });
        try copyNew(e.io, scratch, doc);
        const r = try e.mutating(.{ .kind = .open, .case_id = c.case_id, .profile_id = prof.profile_id, .path = doc, .expect = doc_name });
        if (r.status != .ok) return try failExport(e, ad, name, c.case_id, fmtA(e.a, "open of the work copy returned {s}: {s}", .{ @tagName(r.status), r.detail }));
        const st = try e.idempotent(.{ .kind = .state, .case_id = c.case_id, .profile_id = prof.profile_id });
        if (st.status != .ok) {
            _ = try e.closeDoc(c.case_id);
            return try failExport(e, ad, name, c.case_id, fmtA(e.a, "state returned {s}", .{@tagName(st.status)}));
        }
        if (!eql(stateKey(e.a, base_state) orelse "", stateKey(e.a, st.payload) orelse "-")) {
            _ = try e.closeDoc(c.case_id);
            return try failExport(e, ad, name, c.case_id, "profile state leak: the work copy opened with a state that differs from native/native-state.json");
        }
        var files: std.ArrayList(StageFile) = .empty;
        try files.append(e.a, try e.sealFile(ad, fmtA(e.a, "{s}/state-before.json", .{rel_dir}), stateFile(e.a, c.case_id, want, prof.profile_id, st.payload).?));
        const rt = e.exportRoute(prof, false);
        if (e.cfg.bundle_exports) {
            // The state before the export is the sealed context. The exporter must keep it.
            const sfx = try e.sealFile(ad, fmtA(e.a, "{s}/native-state.json", .{rel_dir}), stateFile(e.a, c.case_id, want, prof.profile_id, st.payload).?);
            try files.append(e.a, sfx);
            return try e.finishBundle(c, ad, name, prof, rel_dir, rt, stateKey(e.a, st.payload), want, sfx.sha256, &files);
        }
        const tr = try e.exportTries(c, ad, prof, rel_dir, rt, null);
        var warnings: std.ArrayList([]const u8) = .empty;
        try warnings.appendSlice(e.a, tr.warnings);
        if (try e.closeDoc(c.case_id)) |wn| try warnings.append(e.a, wn);
        if (tr.state_changed) |why| return try failExport(e, ad, name, c.case_id, why);
        const good = tr.ok_path orelse return try failExport(e, ad, name, c.case_id, fmtA(e.a, "{d} export tries failed: {s}", .{ e.cfg.retries + 1, std.mem.join(e.a, ", ", tr.problems) catch "" }));
        if (!eql(hashFileDup(e.a, e.io, sp) orelse "", want)) return try failExport(e, ad, name, c.case_id, fmtA(e.a, "source_changed: {s} changed during the operator export", .{sp}));
        if (!eql(hashFileDup(e.a, e.io, scratch) orelse "", want)) return try failExport(e, ad, name, c.case_id, "source_changed: source/scratch.vwx changed during the operator export");
        if (!eql(hashFileDup(e.a, e.io, doc) orelse "", want)) try warnings.append(e.a, fmtA(e.a, "the work copy {s} changed while the app had it open", .{doc_name}));
        const sf = try e.sealFile(ad, fmtA(e.a, "{s}/native-state.json", .{rel_dir}), stateFile(e.a, c.case_id, want, prof.profile_id, tr.state_after.?).?);
        try files.append(e.a, sf);
        try e.storeExport(c, ad, name, prof, rel_dir, rt, &tr, good, want, sf.sha256, &files, warnings.items);
        return null;
    }
};

/// True when `<dir>/INFLIGHT.json` is the record of this very export: a schema record of this vwx
/// process whose `what` is `export_file` and whose context names the case, profile, path and directory.
fn inflightMatches(a: Allocator, io: Io, dir: []const u8, op: Op) bool {
    if (dir.len == 0) return false;
    const bytes = readAll(a, io, fmtA(a, "{s}/{s}", .{ dir, inflight_name })) catch return false;
    const v = parseJson(a, bytes) catch return false;
    if (!eql(strField(v, "schema") orelse "", schema_inflight) or !eql(strField(v, "what") orelse "", "export_file")) return false;
    if (!eql(strField(v, "context") orelse "", inflightContext(a, op))) return false;
    const pv = field(v, "pid") orelse return false;
    return (intOf(pv) orelse -1) == std.c.getpid();
}

/// True for `cases/<case>/attempt-<n>/work/query[-n]/reopened.vwx` below the session directory.
fn queryCopyShape(rel: []const u8) bool {
    if (!std.mem.startsWith(u8, rel, "cases/") or !std.mem.endsWith(u8, rel, "/reopened.vwx")) return false;
    if (std.mem.indexOf(u8, rel, "..") != null or std.mem.indexOf(u8, rel, "/source/") != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    _ = it.next();
    const case_id = it.next() orelse return false;
    const attempt = it.next() orelse return false;
    const work = it.next() orelse return false;
    const dir = it.next() orelse return false;
    const file = it.next() orelse return false;
    if (it.next() != null) return false;
    return case_id.len > 0 and std.mem.startsWith(u8, attempt, "attempt-") and eql(work, "work") and std.mem.startsWith(u8, dir, "query") and eql(file, "reopened.vwx");
}

/// The native message when `er` is the application's rejection of the STL export `eop`, else null.
/// Both the request and the reply must name `vs.ExportSTL`, the reply must carry the exact approved
/// message, state that OK was pressed and claim no file.
fn rejectedStl(a: Allocator, eop: Op, er: Reply) ?[]const u8 {
    if (er.status != .unsupported or er.uncertain or er.refused) return null;
    if (eop.kind != .export_file or !eql(apiOfPayload(a, eop.payload), stl_api)) return null;
    const v = parseJson(a, er.payload) catch return null;
    if (!eql(strField(v, "outcome") orelse "", rejection_outcome) or !eql(strField(v, "api") orelse "", stl_api)) return null;
    if (!(boolField(v, "acknowledged") orelse false) or (boolField(v, "file_claimed") orelse true)) return null;
    const msg = strField(v, "native_message") orelse return null;
    if (!eql(msg, stl_rejection_message)) return null;
    return msg;
}

/// APIs that every run probes. The engine refuses a run without the required ones.
pub const bridge_apis = [_][]const u8{ "vs.SaveActiveDocument", "vs.CloseDocument", "vs.GetFName", "vs.GetFPathName", "vs.GetUnits", "vs.GetOrigin", "vs.GetVersion", "vs.GetObject", "vs.ShowClass", "vs.ClassList" };
pub const required_bridge_apis = [_][]const u8{ "vs.SaveActiveDocument", "vs.GetFName", "vs.GetFPathName" };

const Unavailable = struct {
    reason: []const u8,
    evidence: []const u8,
    /// The native message of an export that the application rejected. Null for every other reason.
    rejected: ?[]const u8 = null,
};

fn exportUnavailable(e: *Engine, prof: *const Profile) ?Unavailable {
    // A typed UI route stands in for a scripting entry that cannot run.
    const ui = e.uiRouteFor(prof);
    const entry = findEntry(e.s.entries, prof.format) orelse {
        if (ui != null) return null;
        if (e.cfg.operator_exports and formatCheck(prof.format) != null) return null;
        return .{
            .reason = fmtA(e.a, "no documented scripting entry for format {s}. The capability checklist lists the manual export step", .{prof.format}),
            .evidence = "inputs/export-entries.json",
        };
    };
    if (e.apiPresent(entry.api) != true) {
        if (ui != null) return null;
        return .{
            .reason = fmtA(e.a, "preflight reports {s} absent", .{entry.api}),
            .evidence = fmtA(e.a, "preflight/run-{d}.json", .{e.run_no}),
        };
    }
    var missing: []const u8 = "";
    if (resolveArgs(e.a, entry, prof, "", &missing) == null) {
        if (ui != null) return null;
        return .{
            .reason = fmtA(e.a, "profile option {s} is null. Entry {s} needs a value", .{ missing, entry.api }),
            .evidence = fmtA(e.a, "inputs/profiles/{s}.json", .{prof.profile_id}),
        };
    }
    // A scripting entry is unverified. A verified run needs calibration evidence of the same format
    // that matches the release, the workspace and the profile options. Otherwise the profile stays
    // unavailable and no scripted export reaches an acquired state on the strength of its API alone.
    if (e.cfg.strict) |st| {
        if (st.phase == .verified) {
            const ur = ui orelse return .{ .reason = fmtA(e.a, "evidence_missing: scripted entry {s} has no calibration evidence for format {s}", .{ entry.api, prof.format }), .evidence = "inputs/export-entries.json" };
            switch (loadEvidence(e.a, e.io, ur, st.evidence_dir, st.exe_sha256)) {
                .problem => |pr| return .{ .reason = fmtA(e.a, "{s}: {s}", .{ pr.code, pr.msg }), .evidence = fmtA(e.a, "{s}/{s}.json", .{ st.evidence_dir, ur.evidence_sha256 }) },
                .ok => |ev| if (evidenceIdentityProblem(ev, st.release, st.workspace, optionsDigest(e.a, prof.options))) |why| {
                    return .{ .reason = why, .evidence = fmtA(e.a, "{s}/{s}.json", .{ st.evidence_dir, ur.evidence_sha256 }) };
                },
            }
        }
    }
    return null;
}

/// The native-state sidecar: the state reply bound to the source bytes.
fn stateFile(a: Allocator, case_id: []const u8, src_sha: []const u8, profile_id: ?[]const u8, payload: []const u8) ?[]const u8 {
    const v = parseJson(a, payload) catch return null;
    var o = Obj.init(a);
    o.str("schema", schema_state);
    o.str("case_id", case_id);
    o.str("source_sha256", src_sha);
    o.optStr("profile_id", profile_id);
    o.put("state", v);
    return stringify(a, o.value());
}

fn readStage(a: Allocator, io: Io, ad: []const u8, name: []const u8) ?json.Value {
    const bytes = readAll(a, io, fmtA(a, "{s}/stage-{s}.json", .{ ad, name })) catch return null;
    return parseJson(a, bytes) catch null;
}

fn stageStatus(a: Allocator, io: Io, ad: []const u8, name: []const u8) []const u8 {
    const v = readStage(a, io, ad, name) orelse return "";
    return strField(v, "status") orelse "";
}

/// The stage record exists with status ok or unavailable, and every listed file has its bytes.
fn stageOk(a: Allocator, io: Io, ad: []const u8, name: []const u8) bool {
    const v = readStage(a, io, ad, name) orelse return false;
    const st = strField(v, "status") orelse "";
    if (!eql(st, "ok") and !eql(st, "unavailable") and !eql(st, "pending")) return false;
    return stageFilesProblem(a, io, ad, v) == null;
}

fn stageFilesProblem(a: Allocator, io: Io, ad: []const u8, v: json.Value) ?[]const u8 {
    for (arrField(v, "files")) |f| {
        const rel = strField(f, "path") orelse return "stage file entry has no path";
        const want = strField(f, "sha256") orelse "";
        const have = hashFileDup(a, io, fmtA(a, "{s}/{s}", .{ ad, rel })) orelse return fmtA(a, "{s} is missing", .{rel});
        if (!eql(have, want)) return fmtA(a, "{s} has SHA256 {s}. The stage recorded {s}", .{ rel, have, want });
    }
    return null;
}

fn stageNames(a: Allocator, c: *const QCase) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (c.kind == .existing_document) {
        out.append(a, "collected") catch {};
    } else {
        out.append(a, "created") catch {};
        out.append(a, "queried") catch {};
    }
    for (c.profile_ids) |pid| out.append(a, fmtA(a, "export-{s}", .{pid})) catch {};
    return out.items;
}

/// `driver` and `run` bind the attempt to the driver that wrote every stage record.
fn writeDone(a: Allocator, io: Io, ad: []const u8, c: *const QCase, drv: DriverKind, run_no: u32) !void {
    var o = Obj.init(a);
    o.str("schema", schema_stage);
    o.str("stage", "DONE");
    o.str("case_id", c.case_id);
    o.str("driver", @tagName(drv));
    o.int("run", run_no);
    var l = arr(a);
    for (stageNames(a, c)) |n| {
        const rel = fmtA(a, "stage-{s}.json", .{n});
        var x = Obj.init(a);
        x.str("path", rel);
        x.str("sha256", hashFileDup(a, io, fmtA(a, "{s}/{s}", .{ ad, rel })) orelse "");
        try l.append(x.value());
    }
    o.put("files", .{ .array = l });
    try putSealed(a, io, fmtA(a, "{s}/DONE.json", .{ad}), stringify(a, o.value()));
}

pub const AttemptDriver = union(enum) {
    /// The attempt has no stage record and no DONE.json.
    none,
    one: DriverKind,
    /// Two records name different drivers, or one record names no driver.
    mixed: []const u8,
};

/// Reads `driver` from every stage record and from DONE.json of one attempt. The run ledger
/// `runs/<n>.json` takes no part.
pub fn attemptDriver(a: Allocator, io: Io, ad: []const u8, c: *const QCase) AttemptDriver {
    var seen: ?DriverKind = null;
    var first: []const u8 = "";
    var names: std.ArrayList([]const u8) = .empty;
    for (stageNames(a, c)) |n| names.append(a, fmtA(a, "stage-{s}.json", .{n})) catch {};
    names.append(a, "DONE.json") catch {};
    for (names.items) |rel| {
        const bytes = readAll(a, io, fmtA(a, "{s}/{s}", .{ ad, rel })) catch continue;
        const v = parseJson(a, bytes) catch return .{ .mixed = fmtA(a, "{s} does not parse", .{rel}) };
        const name = strField(v, "driver") orelse "";
        const k = std.meta.stringToEnum(DriverKind, name) orelse return .{ .mixed = fmtA(a, "{s} records no driver", .{rel}) };
        if (seen) |s0| {
            if (s0 != k) return .{ .mixed = fmtA(a, "{s} records driver {s}. {s} records driver {s}", .{ first, @tagName(s0), rel, name }) };
        } else {
            seen = k;
            first = rel;
        }
    }
    return if (seen) |k| .{ .one = k } else .none;
}

/// `run` of DONE.json. Null for an attempt without DONE.json or without `run`.
fn attemptRun(a: Allocator, io: Io, ad: []const u8) ?u32 {
    const bytes = readAll(a, io, fmtA(a, "{s}/DONE.json", .{ad})) catch return null;
    const v = parseJson(a, bytes) catch return null;
    const n = intOf(field(v, "run") orelse .null) orelse return null;
    return if (n > 0) @intCast(n) else null;
}

pub fn latestAttempt(a: Allocator, io: Io, s: *const Session, case_id: []const u8) u32 {
    var n: u32 = 0;
    while (exists(io, fmtA(a, "{s}/cases/{s}/attempt-{d}", .{ s.dir, case_id, n + 1 }))) n += 1;
    return n;
}

/// Checks DONE, every stage record and every file that a record lists.
pub fn verifyAttempt(a: Allocator, io: Io, s: *const Session, c: *const QCase, attempt: u32) Verify {
    const ad = fmtA(a, "{s}/cases/{s}/attempt-{d}", .{ s.dir, c.case_id, attempt });
    for (stageNames(a, c)) |n| {
        const v = readStage(a, io, ad, n) orelse continue;
        if (stageFilesProblem(a, io, ad, v)) |why| return .{ .stale = why };
    }
    const done = readAll(a, io, fmtA(a, "{s}/DONE.json", .{ad})) catch return .partial;
    const v = parseJson(a, done) catch return .{ .stale = "DONE.json does not parse" };
    if (stageFilesProblem(a, io, ad, v)) |why| return .{ .stale = why };
    return .complete;
}

// ---------------------------------------------------------------------------
// finalize
// ---------------------------------------------------------------------------

pub const FinalizeOptions = struct {
    session: []const u8,
    skeleton: []const u8,
    out: []const u8,
    /// JSON object with `version`, `build`, `edition`, `platform` and `verification`.
    release: ?[]const u8 = null,
    /// Selection file with schema `vwx-rosetta-capture-selection/1`.
    cases: ?[]const u8 = null,
};

const LatestOutcome = struct { run: u32, v: json.Value, bytes: []const u8, path: []const u8 };

fn latestOutcome(a: Allocator, io: Io, s: *const Session, case_id: []const u8) ?LatestOutcome {
    var n: u32 = 1;
    var best: ?LatestOutcome = null;
    while (n < 100000) : (n += 1) {
        const p = fmtA(a, "{s}/cases/{s}/outcome/run-{d}.json", .{ s.dir, case_id, n });
        if (!exists(io, fmtA(a, "{s}/runs/{d}.json", .{ s.dir, n }))) break;
        const bytes = readAll(a, io, p) catch continue;
        const v = parseJson(a, bytes) catch continue;
        best = .{ .run = n, .v = v, .bytes = bytes, .path = p };
    }
    return best;
}

/// Returns a reason when `path` is not a regular file that this process can open for reading.
fn readableProblem(a: Allocator, io: Io, path: []const u8) ?[]const u8 {
    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |e| return fmtA(a, "cannot stat {s}: {s}", .{ path, @errorName(e) });
    if (st.kind != .file) return fmtA(a, "{s} is a {s}. finalize copies regular files only", .{ path, @tagName(st.kind) });
    const f = Dir.cwd().openFile(io, path, .{}) catch |e| return fmtA(a, "cannot open {s}: {s}", .{ path, @errorName(e) });
    f.close(io);
    return null;
}

/// Real path of a new directory `path`. The deepest existing ancestor goes through realpath. The
/// missing components follow it. A missing component `.` or `..` and an entry that exists without
/// resolving give `bad`.
fn resolveNew(a: Allocator, io: Io, path: []const u8) union(enum) { ok: []const u8, bad: []const u8 } {
    var head = path;
    var tail: std.ArrayList([]const u8) = .empty;
    while (true) {
        if (Dir.cwd().realPathFileAlloc(io, head, a)) |rp| {
            var out: []const u8 = rp;
            var i = tail.items.len;
            while (i > 0) {
                i -= 1;
                out = if (eql(out, "/")) fmtA(a, "/{s}", .{tail.items[i]}) else fmtA(a, "{s}/{s}", .{ out, tail.items[i] });
            }
            return .{ .ok = out };
        } else |_| {}
        if (exists(io, head)) return .{ .bad = fmtA(a, "{s} exists and does not resolve", .{head}) };
        const trimmed = std.mem.trimEnd(u8, head, "/");
        const base = basename(trimmed);
        if (base.len == 0 or eql(base, ".") or eql(base, "..")) return .{ .bad = fmtA(a, "{s} is missing and ends in `{s}`", .{ head, base }) };
        tail.append(a, base) catch return .{ .bad = "out of memory" };
        head = dirname(trimmed);
    }
}

/// Output tree of `finalize`. The dry pass records every output path and reports a path problem,
/// a path written twice and a path under an output file. The write pass creates the same paths.
///
/// The out-dir can be on case-insensitive APFS. Two paths that are equal after ASCII lowercase
/// name one file there. pathProblem limits every output path to the bytes [A-Za-z0-9._+-], so
/// Unicode case folding and normalization do not apply. The maps key each path by its ASCII
/// lowercase form and keep its first spelling. A second spelling of one key is `path_collision`
/// on every volume.
const OutTree = struct {
    a: Allocator,
    io: Io,
    d: *Diags,
    /// Output directory.
    root: []const u8,
    dry: bool,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    dirs: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn full(t: *OutTree, rel: []const u8) []const u8 {
        return fmtA(t.a, "{s}/{s}", .{ t.root, rel });
    }

    fn key(t: *OutTree, rel: []const u8) []const u8 {
        return std.ascii.allocLowerString(t.a, rel) catch @panic("out of memory");
    }

    /// Records directory `rel`. False when `rel` is an output file or has another spelling.
    fn claimOneDir(t: *OutTree, rel: []const u8, full_rel: []const u8, where: []const u8) bool {
        const k = t.key(rel);
        if (t.files.get(k)) |f| {
            if (!eql(rel, full_rel)) {
                t.d.err("path_collision", where, "output path `{s}` is under the output file `{s}`", .{ full_rel, f });
            } else if (eql(rel, f)) {
                t.d.err("path_collision", where, "output directory `{s}` is an output file", .{rel});
            } else {
                t.d.err("path_collision", where, "output directory `{s}` is the output file `{s}` after ASCII lowercase", .{ rel, f });
            }
            return false;
        }
        const gop = t.dirs.getOrPut(t.a, k) catch @panic("out of memory");
        if (!gop.found_existing) {
            gop.value_ptr.* = rel;
            return true;
        }
        if (eql(gop.value_ptr.*, rel)) return true;
        t.d.err("path_collision", where, "output directory `{s}` of `{s}` is the output directory `{s}` after ASCII lowercase", .{ rel, full_rel, gop.value_ptr.* });
        return false;
    }

    /// Records the parent directories of `rel`. False when one of them is an output file or has
    /// another spelling.
    fn claimParents(t: *OutTree, rel: []const u8, where: []const u8) bool {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |j| : (i = j + 1) {
            if (!t.claimOneDir(rel[0..j], rel, where)) return false;
        }
        return true;
    }

    /// True when the write pass may create file `rel`. The write pass always gets true.
    fn claim(t: *OutTree, rel: []const u8, where: []const u8) bool {
        if (!t.dry) return true;
        if (pathProblem(rel)) |why| {
            t.d.err("bad_path", where, "output path `{s}` is invalid: {s}", .{ rel, why });
            return false;
        }
        const k = t.key(rel);
        if (t.files.get(k) orelse t.dirs.get(k)) |prev| {
            if (eql(prev, rel)) {
                t.d.err("path_collision", where, "output path `{s}` is written twice", .{rel});
            } else if (t.files.contains(k)) {
                t.d.err("path_collision", where, "output path `{s}` is the output file `{s}` after ASCII lowercase", .{ rel, prev });
            } else {
                t.d.err("path_collision", where, "output path `{s}` is the output directory `{s}` after ASCII lowercase", .{ rel, prev });
            }
            return false;
        }
        if (!t.claimParents(rel, where)) return false;
        t.files.put(t.a, k, rel) catch @panic("out of memory");
        return true;
    }

    fn claimDir(t: *OutTree, rel: []const u8, where: []const u8) bool {
        if (!t.dry) return true;
        if (pathProblem(rel)) |why| {
            t.d.err("bad_path", where, "output directory `{s}` is invalid: {s}", .{ rel, why });
            return false;
        }
        if (!t.claimParents(rel, where)) return false;
        return t.claimOneDir(rel, rel, where);
    }

    fn copy(t: *OutTree, from: []const u8, rel: []const u8, where: []const u8) !void {
        if (!t.claim(rel, where)) return;
        if (t.dry) {
            if (readableProblem(t.a, t.io, from)) |why| t.d.err("read_failed", where, "{s}", .{why});
            return;
        }
        const to = t.full(rel);
        try mkdirp(t.io, dirname(to));
        try copyNew(t.io, from, to);
    }

    fn write(t: *OutTree, rel: []const u8, bytes: []const u8, where: []const u8) !void {
        if (!t.claim(rel, where)) return;
        if (t.dry) return;
        const to = t.full(rel);
        try mkdirp(t.io, dirname(to));
        try writeNew(t.io, to, bytes);
    }

    /// Copies every regular file under `from` to `rel`, except the paths in `skip`.
    fn copyDir(t: *OutTree, from: []const u8, rel: []const u8, skip: []const []const u8, where: []const u8) !void {
        if (!t.claimDir(rel, where)) return;
        if (!t.dry) try mkdirp(t.io, t.full(rel));
        var dir = try Dir.cwd().openDir(t.io, from, .{ .iterate = true });
        defer dir.close(t.io);
        var walker = try dir.walk(t.a);
        defer walker.deinit();
        while (try walker.next(t.io)) |e| {
            const r = fmtA(t.a, "{s}/{s}", .{ rel, e.path });
            if (e.kind == .directory) {
                if (t.claimDir(r, where) and !t.dry) try mkdirp(t.io, t.full(r));
                continue;
            }
            if (e.kind != .file) return error.SpecialFile;
            if (inList(skip, e.path)) continue;
            try t.copy(fmtA(t.a, "{s}/{s}", .{ from, e.path }), r, where);
        }
    }
};

const CaseWriter = struct {
    a: Allocator,
    io: Io,
    d: *Diags,
    tree: *OutTree,
    case_id: []const u8,
    /// Output case directory relative to the output directory.
    dir: []const u8,
    /// Absolute attempt directory.
    from: []const u8,
    case: *json.ObjectMap,

    fn group(w: *CaseWriter, name: []const u8) *json.Array {
        const gop = w.case.getOrPut(w.a, name) catch unreachable;
        if (!gop.found_existing or gop.value_ptr.* != .array) gop.value_ptr.* = .{ .array = arr(w.a) };
        return &gop.value_ptr.array;
    }

    fn find(list: *json.Array, id: []const u8) ?*json.ObjectMap {
        for (list.items) |*x| {
            if (x.* == .object and eql(strField(x.*, "artifact_id") orelse "", id)) return &x.object;
        }
        return null;
    }

    fn entry(w: *CaseWriter, g: []const u8, id: []const u8, path: []const u8, channel: []const u8, required: bool) *json.ObjectMap {
        const list = w.group(g);
        if (find(list, id)) |o| return o;
        var o = Obj.init(w.a);
        o.str("artifact_id", id);
        o.str("path", path);
        o.put("sha256", .null);
        o.str("channel", channel);
        o.boolean("required", required);
        o.str("acquisition_state", "pending");
        o.put("provenance", (Obj.init(w.a)).value());
        list.append(o.value()) catch {};
        return &list.items[list.items.len - 1].object;
    }

    /// Copies `rel` of the attempt directory to the path of the entry and records its hash.
    fn put(w: *CaseWriter, g: []const u8, id: []const u8, rel: []const u8, channel: []const u8, required: bool, state: []const u8, prov: json.Value) !*json.ObjectMap {
        return w.putFrom(g, id, fmtA(w.a, "{s}/{s}", .{ w.from, rel }), rel, channel, required, state, prov);
    }

    fn putFrom(w: *CaseWriter, g: []const u8, id: []const u8, src: []const u8, rel: []const u8, channel: []const u8, required: bool, state: []const u8, prov: json.Value) !*json.ObjectMap {
        const o = w.entry(g, id, rel, channel, required);
        const pv = o.get("path") orelse json.Value{ .string = rel };
        if (pv != .string) {
            w.d.err("bad_path", w.case_id, "{s} artifact `{s}` has no string path", .{ g, id });
            return o;
        }
        const out_rel = fmtA(w.a, "{s}/{s}", .{ w.dir, pv.string });
        try w.tree.copy(src, out_rel, w.case_id);
        if (!w.tree.dry) {
            const h = try hashFile(w.io, w.tree.full(out_rel));
            try o.put(w.a, "sha256", .{ .string = try w.a.dupe(u8, &h) });
        }
        try o.put(w.a, "acquisition_state", .{ .string = state });
        try o.put(w.a, "provenance", prov);
        _ = o.swapRemove("reason");
        _ = o.swapRemove("evidence");
        return o;
    }
};

/// Writes a pack input tree. Cases without an outcome keep their skeleton bytes.
/// Every check runs before the first write.
pub fn finalize(a: Allocator, io: Io, d: *Diags, o: FinalizeOptions, out: *Io.Writer) !void {
    const s = loadSession(a, io, d, o.session) orelse return;
    if (exists(io, o.out)) {
        d.err("output_exists", o.out, "finalize writes a new directory only", .{});
        return;
    }
    var release: ?json.Value = null;
    var release_verified = false;
    if (o.release) |rp| {
        const rv = parseJson(a, try readAll(a, io, rp)) catch {
            d.err("invalid_json", rp, "release file does not parse", .{});
            return;
        };
        release_verified = eql(strField(rv, "verification") orelse "", "verified");
        for ([_][]const u8{ "version", "build", "platform" }) |k| {
            if (release_verified and strField(rv, k) == null) d.err("release_unbound", rp, "a verified release needs `{s}`", .{k});
        }
        release = rv;
    }
    if (d.errors() > 0) return;
    const root_path = fmtA(a, "{s}/rosetta.json", .{o.skeleton});
    const root_bytes = try readAll(a, io, root_path);
    var root = parseJson(a, root_bytes) catch {
        d.err("invalid_json", root_path, "the skeleton root does not parse", .{});
        return;
    };
    const sel = finalizeSelection(a, io, d, &s, o.cases) orelse return;
    finalizeChecks(a, io, d, &s, o, root, root_path, sel.ids);
    if (d.errors() > 0) return;

    if (release) |rv| try root.object.put(a, "release", rv);
    const root_out = if (release != null) stringify(a, root) else root_bytes;
    // The dry pass runs every check of the write pass. The output directory exists only after it passes.
    var tree: OutTree = .{ .a = a, .io = io, .d = d, .root = o.out, .dry = true };
    _ = try finalizeWrite(a, io, d, &s, o, &tree, root, root_out, sel, release_verified);
    if (d.errors() > 0) return;
    tree.dry = false;
    try mkdirp(io, o.out);
    const n = try finalizeWrite(a, io, d, &s, o, &tree, root, root_out, sel, release_verified);
    try out.print("summary\tcases_untouched\t{d}\n", .{n.untouched});
    for (std.enums.values(Outcome)) |k| try out.print("summary\t{s}\t{d}\n", .{ @tagName(k), n.counts.get(k) });
    if (sel.record != null) try out.print("summary\tselected\t{d}\n", .{sel.ids.len});
    try out.flush();
}

const WriteCounts = struct { counts: std.enums.EnumArray(Outcome, usize), untouched: usize };

/// One pass over the output tree of `finalize`. `tree.dry` selects the dry pass.
fn finalizeWrite(a: Allocator, io: Io, d: *Diags, s: *const Session, o: FinalizeOptions, tree: *OutTree, root: json.Value, root_out: []const u8, sel: Selection, release_verified: bool) !WriteCounts {
    const where = "rosetta.json";
    try tree.write("rosetta.json", root_out, where);
    if (sel.record) |rec| try tree.write("capture-selection.json", rec, where);
    for (arrField(root, "profiles")) |p| {
        const rel = strField(p, "path") orelse continue;
        try tree.copy(fmtA(a, "{s}/{s}", .{ o.skeleton, rel }), rel, where);
    }
    for (arrField(root, "dependencies")) |x| {
        const rel = strField(x, "path") orelse continue;
        try tree.copy(depSource(a, io, s, o.skeleton, x).?, rel, where);
    }
    var counts = std.enums.EnumArray(Outcome, usize).initFill(0);
    var untouched: usize = 0;
    for (arrField(root, "cases")) |r| {
        const cid = strField(r, "case_id").?;
        const crel = strField(r, "path").?;
        const kdir = fmtA(a, "{s}/{s}", .{ o.skeleton, dirname(crel) });
        const odir = dirname(crel);
        // The recipe bytes come from the frozen session copy. finalizeChecks compared the skeleton file with it.
        const qc = s.queue.findCase(cid).?;
        try tree.copyDir(kdir, odir, &.{ "case.json", recipeRel(qc) }, cid);
        try tree.copy(frozenRecipe(a, io, s, qc) orelse "", fmtA(a, "{s}/{s}", .{ odir, recipeRel(qc) }), cid);
        const cbytes = try readAll(a, io, fmtA(a, "{s}/case.json", .{kdir}));
        const lo = latestOutcome(a, io, s, cid) orelse {
            try tree.write(crel, cbytes, cid);
            untouched += 1;
            continue;
        };
        const outcome = std.meta.stringToEnum(Outcome, strField(lo.v, "outcome") orelse "") orelse {
            d.err("bad_outcome", lo.path, "outcome is unknown", .{});
            continue;
        };
        counts.getPtr(outcome).* += 1;
        var cv = try parseJson(a, cbytes);
        var w: CaseWriter = .{ .a = a, .io = io, .d = d, .tree = tree, .case_id = cid, .dir = odir, .from = "", .case = &cv.object };
        // A done case takes the driver from the sealed records of its attempt.
        // Any other outcome takes the driver from its outcome record.
        var log_tag = provTag(std.meta.stringToEnum(DriverKind, strField(lo.v, "driver") orelse ""), release_verified);
        var done: ?struct { c: *const QCase, k: DriverKind, tag: []const u8, run_no: u32, attempt: u32 } = null;
        if (outcome == .done) {
            const attempt: u32 = @intCast(intOf(field(lo.v, "attempt") orelse .null) orelse 0);
            const c = s.queue.findCase(cid).?;
            switch (verifyAttempt(a, io, s, c, attempt)) {
                .complete => {},
                .partial => {
                    d.err("attempt_incomplete", cid, "attempt {d} has no DONE.json", .{attempt});
                    continue;
                },
                .stale => |why| {
                    d.err("stale_source_hash", cid, "attempt {d}: {s}. Resume the session before finalize", .{ attempt, why });
                    continue;
                },
            }
            w.from = fmtA(a, "{s}/cases/{s}/attempt-{d}", .{ s.dir, cid, attempt });
            // Authority comes from the records of this attempt. The run ledger and later runs take no part.
            const auth = attemptDriver(a, io, w.from, c);
            const drv: ?DriverKind = switch (auth) {
                .one => |k| k,
                .none => null,
                .mixed => |why| blk: {
                    if (!tree.dry) d.add(.warning, "driver_mixed", cid, "attempt {d}: {s}. Every record of the case is unverified", .{ attempt, why });
                    break :blk null;
                },
            };
            log_tag = provTag(drv, release_verified);
            // A mixed or unrecorded driver gets the `fake` rules: every state is unverified.
            done = .{ .c = c, .k = drv orelse .fake, .tag = log_tag, .run_no = attemptRun(a, io, w.from) orelse lo.run, .attempt = attempt };
        }
        _ = try w.putFrom("auxiliary", "capture.outcome", lo.path, "logs/outcome.json", "capture_log", false, "unverified", provBase(a, log_tag, lo.run, null));
        const pre = fmtA(a, "{s}/preflight/run-{d}.json", .{ s.dir, lo.run });
        if (exists(io, pre)) _ = try w.putFrom("auxiliary", "capture.preflight", pre, "logs/preflight.json", "capture_log", false, "unverified", provBase(a, log_tag, lo.run, null));
        switch (outcome) {
            .blocked, .failed => {},
            .creation_unavailable => {
                try cv.object.put(a, "acquisition_state", .{ .string = "creation_unavailable" });
                try cv.object.put(a, "reason", .{ .string = strField(lo.v, "reason") orelse "" });
                try cv.object.put(a, "evidence", .{ .string = "logs/preflight.json" });
            },
            .done => {
                const x = done.?;
                const all_acquired = if (x.c.kind == .existing_document)
                    try finalizeExisting(&w, x.c, s, x.k, release_verified, x.tag, x.run_no, x.attempt)
                else
                    try finalizeDone(&w, x.c, s, x.k, release_verified, x.tag, x.run_no, x.attempt);
                const cstate: []const u8 = if (all_acquired) "acquired" else "unverified";
                try cv.object.put(a, "acquisition_state", .{ .string = cstate });
            },
        }
        try tree.write(crel, stringify(a, cv), cid);
    }
    return .{ .counts = counts, .untouched = untouched };
}

/// `native_verification` of a record. Null is a mixed or unrecorded driver.
fn provTag(drv: ?DriverKind, release_verified: bool) []const u8 {
    const k = drv orelse return "mixed_driver";
    return switch (k) {
        .fake => "fake_driver",
        .native => if (release_verified) "native_verified_release" else "native_unverified_release",
    };
}

const Selection = struct {
    ids: []const []const u8,
    /// Bytes of `capture-selection.json`. Null when finalize takes every session case.
    record: ?[]const u8,
};

pub const schema_selection = "vwx-rosetta-capture-selection/1";

/// Reads `--cases`. The file names `queue_sha256` of the session and the case IDs that the
/// skeleton holds. Without `--cases` the selection is every session case.
fn finalizeSelection(a: Allocator, io: Io, d: *Diags, s: *const Session, path: ?[]const u8) ?Selection {
    var all: std.ArrayList([]const u8) = .empty;
    const p = path orelse {
        for (s.queue.cases) |c| all.append(a, c.case_id) catch {};
        return .{ .ids = all.items, .record = null };
    };
    const bytes = readAll(a, io, p) catch |e| {
        d.err("read_failed", p, "cannot read the selection: {s}", .{@errorName(e)});
        return null;
    };
    const v = parseJson(a, bytes) catch {
        d.err("invalid_json", p, "the selection does not parse", .{});
        return null;
    };
    if (!eql(strField(v, "schema") orelse "", schema_selection)) d.err("bad_schema", p, "schema must be {s}", .{schema_selection});
    if (!eql(strField(v, "queue_sha256") orelse "", s.queue.sha256)) d.err("selection_unbound", p, "queue_sha256 is `{s}`. The session queue has SHA256 {s}", .{ strField(v, "queue_sha256") orelse "", s.queue.sha256 });
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (arrField(v, "cases")) |x| {
        if (x != .string) {
            d.err("bad_id", p, "a selected case ID is not a string", .{});
            continue;
        }
        if ((seen.getOrPut(a, x.string) catch continue).found_existing) d.err("duplicate_case", p, "the selection names `{s}` twice", .{x.string});
        if (s.queue.findCase(x.string) == null) d.err("unrelated_case", p, "the selection names `{s}`, which is not a session case", .{x.string});
        all.append(a, x.string) catch {};
    }
    if (all.items.len == 0) d.err("empty_selection", p, "the selection names no case", .{});
    if (d.errors() > 0) return null;
    var rec = Obj.init(a);
    rec.str("schema", schema_selection);
    rec.str("selection_sha256", shaDup(a, bytes));
    rec.str("queue_sha256", s.queue.sha256);
    rec.int("session_cases", @intCast(s.queue.cases.len));
    rec.put("cases", strArr(a, all.items));
    return .{ .ids = all.items, .record = stringify(a, rec.value()) };
}

const case_groups = [_][]const u8{ "sources", "native_channels", "exports", "auxiliary" };

/// Checks the skeleton against the session and the selection. Reports every problem as a diag.
fn finalizeChecks(a: Allocator, io: Io, d: *Diags, s: *const Session, o: FinalizeOptions, root: json.Value, root_path: []const u8, selected: []const []const u8) void {
    if (o.out.len > 0) {
        switch (resolveNew(a, io, o.out)) {
            .bad => |why| d.err("bad_path", o.out, "the output directory does not resolve: {s}", .{why}),
            .ok => |rp| for ([_][]const u8{ s.dir, o.skeleton }) |inside| {
                const rr = Dir.cwd().realPathFileAlloc(io, inside, a) catch {
                    d.err("read_failed", o.out, "cannot resolve the input {s}", .{inside});
                    continue;
                };
                if (eql(rp, rr) or std.mem.startsWith(u8, rp, fmtA(a, "{s}/", .{rr}))) d.err("output_inside_input", o.out, "the output directory resolves to {s}, which is inside {s}", .{ rp, inside });
            },
        }
    }
    const qv = parseJson(a, readAll(a, io, s.path(a, "inputs/queue.json")) catch "") catch json.Value.null;
    const have_rev = strField(root, "inventory_revision") orelse "";
    const inv_rev = strField(qv, "inventory_revision");
    const q_rev = strField(qv, "queue_revision");
    if (!(inv_rev != null and eql(have_rev, inv_rev.?)) and !(q_rev != null and eql(have_rev, q_rev.?)))
        d.err("revision_mismatch", root_path, "inventory_revision is `{s}`. The session queue has inventory_revision `{s}` and queue_revision `{s}`", .{ have_rev, inv_rev orelse "", q_rev orelse "" });
    for (arrField(root, "profiles")) |p| {
        const rel = strField(p, "path") orelse continue;
        if (pathProblem(rel)) |why| {
            d.err("bad_path", root_path, "profile path `{s}` is invalid: {s}", .{ rel, why });
            continue;
        }
        if (escapeProblem(a, io, o.skeleton, rel)) |why| d.err("path_escape", root_path, "profile path: {s}", .{why});
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (arrField(root, "cases")) |r| {
        const cid = strField(r, "case_id") orelse {
            d.err("missing_field", root_path, "a skeleton case has no case_id", .{});
            continue;
        };
        if ((seen.getOrPut(a, cid) catch continue).found_existing) d.err("duplicate_case", root_path, "the skeleton lists `{s}` twice", .{cid});
        if (s.queue.findCase(cid) == null) {
            d.err("unrelated_case", root_path, "skeleton case `{s}` is not a session case", .{cid});
            continue;
        }
        if (!inList(selected, cid)) d.err("unselected_case", root_path, "skeleton case `{s}` is not in the selection", .{cid});
        const want = fmtA(a, "cases/{s}/case.json", .{cid});
        const crel = strField(r, "path") orelse "";
        if (!eql(crel, want)) {
            d.err("bad_path", root_path, "case `{s}` has path `{s}`. finalize needs `{s}`", .{ cid, crel, want });
            continue;
        }
        const kdir = fmtA(a, "{s}/{s}", .{ o.skeleton, dirname(crel) });
        if (escapeProblem(a, io, o.skeleton, dirname(crel))) |why| {
            d.err("path_escape", cid, "{s}", .{why});
            continue;
        }
        if (treeProblem(a, io, kdir)) |why| d.err("path_escape", cid, "{s}", .{why});
        const cbytes = readAll(a, io, fmtA(a, "{s}/case.json", .{kdir})) catch |e| {
            d.err("read_failed", cid, "cannot read the skeleton case.json: {s}", .{@errorName(e)});
            continue;
        };
        const cv = parseJson(a, cbytes) catch {
            d.err("invalid_json", cid, "the skeleton case.json does not parse", .{});
            continue;
        };
        if (cv != .object) {
            d.err("invalid_json", cid, "the skeleton case.json is not an object", .{});
            continue;
        }
        if (strField(cv, "case_id")) |inner| {
            if (!eql(inner, cid)) d.err("unrelated_case", cid, "the skeleton case.json names case `{s}`", .{inner});
        }
        const c = s.queue.findCase(cid).?;
        // The skeleton recipe must be the recipe that the session ran.
        const recipe_fields = [_]struct { []const u8, ?[]const u8 }{ .{ "recipe_revision", c.recipe_revision }, .{ "recipe_sha256", c.recipe_sha256 } };
        for (recipe_fields) |rf| {
            const have = strField(cv, rf[0]) orelse "";
            if (!eql(have, rf[1] orelse "")) d.err("revision_mismatch", cid, "the skeleton case.json has {s} `{s}`. The session case has `{s}`", .{ rf[0], have, rf[1] orelse "" });
        }
        var recipes: usize = 0;
        for (case_groups) |g| {
            for (arrField(cv, g)) |x| {
                const aid = strField(x, "artifact_id") orelse {
                    d.err("bad_field", cid, "a {s} artifact has no string artifact_id", .{g});
                    continue;
                };
                const ap = strField(x, "path") orelse {
                    d.err("bad_path", cid, "{s} artifact `{s}` has no string path", .{ g, aid });
                    continue;
                };
                if (pathProblem(ap)) |why| {
                    d.err("bad_path", cid, "{s} artifact `{s}` path `{s}` is invalid: {s}", .{ g, aid, ap, why });
                    continue;
                }
                const ch = strField(x, "channel") orelse {
                    d.err("bad_field", cid, "{s} artifact `{s}` has no string channel", .{ g, aid });
                    continue;
                };
                if (eql(ch, "recipe")) recipes += 1;
                recipeArtifactCheck(a, d, c, g, x, aid, ap, ch);
                if (eql(g, "exports")) exportChannelCheck(a, d, s, c, x, aid, ch);
            }
        }
        if (recipes != 1) d.err("recipe_unbound", cid, "the skeleton case.json has {d} artifacts with channel `recipe`. finalize needs exactly 1 at auxiliary `recipe` path `{s}`", .{ recipes, recipeRel(c) });
        recipeTreeCheck(a, io, d, s, c, kdir);
    }
    for (arrField(root, "dependencies")) |x| {
        const id = strField(x, "dependency_id") orelse "";
        const rel = strField(x, "path") orelse "";
        if (pathProblem(rel)) |why| {
            d.err("bad_path", root_path, "dependency `{s}` path `{s}` is invalid: {s}", .{ id, rel, why });
            continue;
        }
        if (depSource(a, io, s, o.skeleton, x) == null) d.err("missing_dependency", root_path, "dependency `{s}` has no session or skeleton file with sha256 {s}", .{ id, strField(x, "sha256") orelse "" });
    }
    for (selected) |cid| {
        if (!seen.contains(cid)) d.err("case_omitted", root_path, "the skeleton omits session case `{s}`. Pass --cases with a selection to finalize a subset", .{cid});
    }
}

/// An export entry names a profile of the session case. Its channel is `export_<format>` of that profile.
/// finalize builds the export directory from the same profile.
fn exportChannelCheck(a: Allocator, d: *Diags, s: *const Session, c: *const QCase, x: json.Value, aid: []const u8, ch: []const u8) void {
    const pid = strField(x, "profile_id") orelse {
        d.err("bad_channel", c.case_id, "export `{s}` has no string profile_id", .{aid});
        return;
    };
    if (!inList(c.profile_ids, pid)) {
        d.err("bad_channel", c.case_id, "export `{s}` names profile `{s}`, which is not in the session case profile_ids", .{ aid, pid });
        return;
    }
    const prof = s.queue.findProfile(pid) orelse {
        d.err("bad_channel", c.case_id, "export `{s}` names profile `{s}`, which is not a session profile", .{ aid, pid });
        return;
    };
    const want = fmtA(a, "export_{s}", .{prof.format});
    if (!eql(ch, want)) d.err("bad_channel", c.case_id, "export `{s}` has channel `{s}`. Profile `{s}` has format {s}, so the channel is `{s}`", .{ aid, ch, pid, prof.format, want });
}

/// Path of the recipe artifact in a case directory. finalize writes it from `inputs/recipes/<case>.json` of the session.
fn recipeRel(c: *const QCase) []const u8 {
    return if (c.kind == .existing_document) "recipe/spec.json" else "recipe/recipe.json";
}

/// Path of the script copy in a case directory. finalize writes it from the attempt.
fn scriptRel(c: *const QCase) []const u8 {
    return if (c.kind == .existing_document) "logs/collect.py" else "logs/script.py";
}

/// Session file that binds the recipe bytes of a case. Null when its hash differs from recipe_sha256.
fn frozenRecipe(a: Allocator, io: Io, s: *const Session, c: *const QCase) ?[]const u8 {
    const p = s.path(a, fmtA(a, "inputs/recipes/{s}.json", .{c.case_id}));
    const want = c.recipe_sha256 orelse return null;
    if (!eql(hashFileDup(a, io, p) orelse "", want)) return null;
    return p;
}

/// The `recipe` channel belongs to one auxiliary artifact `recipe` at recipeRel. The
/// `recipe_checkpoint` channel belongs to auxiliary `recipe.checkpoint.<id>` at
/// `recipe/checkpoint-<id>.vwx` for a checkpoint of the session case. No other artifact names a
/// path under `recipe/` or a case spelling of these channels. The channel label takes no part in
/// the byte check. recipeTreeCheck hashes the files.
fn recipeArtifactCheck(a: Allocator, d: *Diags, c: *const QCase, g: []const u8, x: json.Value, aid: []const u8, ap: []const u8, ch: []const u8) void {
    const cid = c.case_id;
    const is_recipe = eql(ch, "recipe");
    const is_cp = eql(ch, "recipe_checkpoint");
    if (!is_recipe and !is_cp and (std.ascii.eqlIgnoreCase(ch, "recipe") or std.ascii.eqlIgnoreCase(ch, "recipe_checkpoint")))
        d.err("bad_channel", cid, "{s} artifact `{s}` has channel `{s}`. The recipe channels are `recipe` and `recipe_checkpoint`", .{ g, aid, ch });
    const under = std.ascii.startsWithIgnoreCase(ap, "recipe/");
    if (is_recipe) {
        if (!eql(g, "auxiliary") or !eql(aid, "recipe") or !eql(ap, recipeRel(c)))
            d.err("recipe_unbound", cid, "{s} artifact `{s}` at `{s}` has channel `recipe`. finalize needs auxiliary `recipe` at `{s}`", .{ g, aid, ap, recipeRel(c) });
        const want = c.recipe_sha256 orelse "";
        const have = strField(x, "sha256") orelse "";
        if (!eql(have, want)) d.err("revision_mismatch", cid, "recipe artifact `{s}` has sha256 `{s}`. The session case has recipe_sha256 `{s}`", .{ aid, have, want });
        return;
    }
    if (is_cp) {
        const cp = for (c.checkpoints) |k| {
            if (eql(aid, fmtA(a, "recipe.checkpoint.{s}", .{k})) and eql(ap, fmtA(a, "recipe/checkpoint-{s}.vwx", .{k}))) break k;
        } else null;
        if (cp == null or !eql(g, "auxiliary"))
            d.err("recipe_unbound", cid, "{s} artifact `{s}` at `{s}` has channel `recipe_checkpoint`. The session case lists no checkpoint with that ID and path", .{ g, aid, ap });
        return;
    }
    if (under) d.err("recipe_unbound", cid, "{s} artifact `{s}` with channel `{s}` names `{s}` under recipe/. Only the recipe and its checkpoints live there", .{ g, aid, ch, ap });
}

/// Every file of the skeleton case directory under `recipe/` must be the recipe file at recipeRel
/// with the bytes of the frozen session recipe. A script copy at scriptRel must have the bytes of
/// the frozen session script. The path comparison ignores case for the case-insensitive APFS default.
fn recipeTreeCheck(a: Allocator, io: Io, d: *Diags, s: *const Session, c: *const QCase, kdir: []const u8) void {
    const cid = c.case_id;
    const rrel = recipeRel(c);
    const want = c.recipe_sha256 orelse "";
    if (c.recipe_sha256 == null) d.err("recipe_unbound", cid, "the session case has no recipe_sha256", .{});
    if (c.recipe_sha256 != null and frozenRecipe(a, io, s, c) == null) d.err("stale_recipe", cid, "the session file inputs/recipes/{s}.json differs from recipe_sha256 `{s}`", .{ cid, want });
    var seen_recipe = false;
    var h = Dir.cwd().openDir(io, kdir, .{ .iterate = true }) catch return;
    defer h.close(io);
    var walker = h.walk(a) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |e| {
        const p = a.dupe(u8, e.path) catch return;
        const full = fmtA(a, "{s}/{s}", .{ kdir, p });
        if (std.ascii.startsWithIgnoreCase(p, "recipe/")) {
            if (e.kind == .directory) {
                d.err("recipe_unbound", cid, "the skeleton directory {s} is under recipe/. finalize copies the recipe file only", .{p});
                continue;
            }
            if (!eql(p, rrel)) {
                d.err("recipe_unbound", cid, "the skeleton file {s} is under recipe/. finalize copies {s} only", .{ p, rrel });
                continue;
            }
            seen_recipe = true;
            if (!eql(hashFileDup(a, io, full) orelse "", want)) d.err("revision_mismatch", cid, "the skeleton file {s} differs from recipe_sha256 `{s}`", .{ p, want });
            continue;
        }
        if (std.ascii.eqlIgnoreCase(p, scriptRel(c)) and e.kind != .directory) {
            if (!eql(hashFileDup(a, io, full) orelse "", c.script_sha256)) d.err("stale_script", cid, "the skeleton file {s} differs from script_sha256 `{s}`", .{ p, c.script_sha256 });
        }
    }
    if (!seen_recipe) d.err("recipe_unbound", cid, "the skeleton has no recipe file {s}", .{rrel});
}

/// File that finalize copies for a skeleton root dependency. The sealed session copy comes first.
/// The skeleton file is the second choice. Each must have the skeleton sha256.
fn depSource(a: Allocator, io: Io, s: *const Session, skel: []const u8, x: json.Value) ?[]const u8 {
    const id = strField(x, "dependency_id") orelse return null;
    const rel = strField(x, "path") orelse return null;
    const want = strField(x, "sha256") orelse return null;
    if (s.queue.findDep(id)) |qd| {
        const sp = s.path(a, depInput(a, qd.*));
        if (eql(hashFileDup(a, io, sp) orelse "", want)) return sp;
    }
    const kp = fmtA(a, "{s}/{s}", .{ skel, rel });
    if (eql(hashFileDup(a, io, kp) orelse "", want)) return kp;
    return null;
}

/// Returns a reason when `dir` holds an entry other than a regular file or a directory.
fn treeProblem(a: Allocator, io: Io, dir: []const u8) ?[]const u8 {
    var h = Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |e| return fmtA(a, "cannot open {s}: {s}", .{ dir, @errorName(e) });
    defer h.close(io);
    var walker = h.walk(a) catch return fmtA(a, "cannot walk {s}", .{dir});
    defer walker.deinit();
    while (walker.next(io) catch return fmtA(a, "cannot walk {s}", .{dir})) |e| {
        if (e.kind != .file and e.kind != .directory) return fmtA(a, "{s}/{s} is a {s}", .{ dir, e.path, @tagName(e.kind) });
    }
    return null;
}

fn provBase(a: Allocator, tag: []const u8, run_no: u32, attempt: ?u32) json.Value {
    var p = Obj.init(a);
    p.str("native_verification", tag);
    p.str("captured_by", "vwx rosetta-capture");
    p.int("capture_run", run_no);
    if (attempt) |n| p.int("capture_attempt", n);
    return p.value();
}

fn withFields(a: Allocator, base: json.Value, fields: []const struct { []const u8, json.Value }) json.Value {
    var m: json.ObjectMap = .empty;
    var it = base.object.iterator();
    while (it.next()) |e| m.put(a, e.key_ptr.*, e.value_ptr.*) catch {};
    for (fields) |f| m.put(a, f[0], f[1]) catch {};
    return .{ .object = m };
}

/// A bundle artifact that finalize adds to the case `exports` list after the main export entry.
const BundleExtra = struct {
    id: []const u8,
    rel: []const u8,
    channel: []const u8,
    state: []const u8,
    source_sha256: json.Value,
    state_sha256: json.Value,
    profile_id: []const u8,
    profile_sha256: []const u8,
    warnings: json.Value,
    result: json.Value,
};

/// The `bundle` object of an `ok` export stage, or null for a single-file export.
fn bundleOf(data: json.Value) ?json.Value {
    const b = field(field(data, "result") orelse .null, "bundle") orelse return null;
    return if (b == .object) b else null;
}

/// A calibration export is never an acquired artifact.
fn bundleState(data: json.Value, state: []const u8) []const u8 {
    return if (eql(strField(data, "phase") orelse "", "calibration")) "unverified" else state;
}

fn bundleMainRel(a: Allocator, b: json.Value) []const u8 {
    return fmtA(a, "{s}/{s}", .{ strField(b, "dir") orelse "", strField(b, "main_file") orelse "" });
}

/// The manifest, the seal and the sidecar artifacts of one published bundle. The ids follow
/// capture/CONTRACT.md "Export bundle publication".
fn bundleExtras(a: Allocator, list: *std.ArrayList(BundleExtra), pid: []const u8, b: json.Value, data: json.Value, state: []const u8, sv: json.Value, esv: json.Value, profile_sha256: []const u8) !void {
    const dir = strField(b, "dir") orelse "";
    const n: i64 = if (field(b, "attempt")) |x| (intOf(x) orelse 0) else 0;
    const warnings = field(data, "warnings") orelse json.Value{ .array = arr(a) };
    const result = field(data, "result") orelse json.Value{ .string = "" };
    const prefix = fmtA(a, "export.{s}.a{d}", .{ pid, n });
    const base: BundleExtra = .{ .id = "", .rel = "", .channel = "", .state = state, .source_sha256 = sv, .state_sha256 = esv, .profile_id = pid, .profile_sha256 = profile_sha256, .warnings = warnings, .result = result };
    var m = base;
    m.id = fmtA(a, "{s}.manifest", .{prefix});
    m.rel = fmtA(a, "{s}/{s}", .{ dir, opdir.manifest_name });
    m.channel = pack.channel_bundle_manifest;
    try list.append(a, m);
    var sl = base;
    sl.id = fmtA(a, "{s}.seal", .{prefix});
    sl.rel = fmtA(a, "{s}/{s}", .{ dir, opdir.seal_name });
    sl.channel = pack.channel_bundle_manifest;
    try list.append(a, sl);
    for (arrField(b, "sidecars"), 1..) |s, k| {
        var x = base;
        x.id = fmtA(a, "{s}.sidecar.{d:0>4}", .{ prefix, k });
        x.rel = fmtA(a, "{s}/{s}", .{ dir, strField(s, "path") orelse "" });
        x.channel = pack.channel_sidecar;
        try list.append(a, x);
    }
}

fn putExtras(w: *CaseWriter, a: Allocator, extras: []const BundleExtra, base: json.Value) !void {
    for (extras) |x| {
        const o = try w.put("exports", x.id, x.rel, x.channel, false, x.state, base);
        try o.put(a, "profile_id", .{ .string = x.profile_id });
        try o.put(a, "source_sha256", x.source_sha256);
        try o.put(a, "state_sha256", x.state_sha256);
        try o.put(a, "profile_sha256", .{ .string = x.profile_sha256 });
        try o.put(a, "warnings", x.warnings);
        try o.put(a, "result", x.result);
    }
}

/// Returns true when every required artifact of the case is `acquired`.
fn finalizeDone(w: *CaseWriter, c: *const QCase, s: *const Session, drv: DriverKind, release_verified: bool, tag: []const u8, run_no: u32, attempt: u32) !bool {
    const a = w.a;
    const created = readStage(a, w.io, w.from, "created").?;
    const queried = readStage(a, w.io, w.from, "queried").?;
    const qd = field(queried, "data") orelse .null;
    const src = strField(qd, "source_sha256") orelse "";
    const st = strField(qd, "state_sha256") orelse "";
    const ok_state = struct {
        fn f(dk: DriverKind, verified: bool, stage: json.Value) []const u8 {
            if (dk != .native or !verified) return "unverified";
            return if (arrField(stage, "warnings").len == 0) "acquired" else "unverified";
        }
    }.f;
    const base = provBase(a, tag, run_no, attempt);
    const s_created = ok_state(drv, release_verified, created);
    const s_queried = ok_state(drv, release_verified, queried);
    const sv: json.Value = .{ .string = src };
    const tv: json.Value = .{ .string = st };
    _ = try w.put("sources", "source.original", "source/original.vwx", "source_original", true, s_created, base);
    _ = try w.put("sources", "source.reopened", "source/reopened.vwx", "source_reopened", true, s_queried, withFields(a, base, &.{.{ "copied_from", .{ .string = "source.original" } }}));
    const bound = withFields(a, base, &.{ .{ "source_sha256", sv }, .{ "state_sha256", tv } });
    _ = try w.put("native_channels", "native.state", "native/native-state.json", "native_state", true, s_queried, withFields(a, base, &.{.{ "source_sha256", sv }}));
    _ = try w.put("native_channels", "native.query_raw", "native/raw/query.json", "native_query_raw", true, s_queried, bound);
    const derived = withFields(a, bound, &.{.{ "derived_from", strArr(a, &.{ "native.query_raw", "native.state" }) }});
    _ = try w.put("native_channels", "native.objects", "native/objects.jsonl", "native_objects", true, s_queried, derived);
    _ = try w.put("native_channels", "native.measurements", "native/geometry.jsonl", "native_measurements", true, s_queried, derived);
    _ = try w.put("native_channels", "native.frames", "native/frames.json", "native_frames", true, s_queried, derived);
    _ = try w.put("native_channels", "native.document", "native/document.json", "native_document", true, s_queried, derived);
    for (c.checkpoints) |cp| {
        _ = try w.put("auxiliary", fmtA(a, "recipe.checkpoint.{s}", .{cp}), fmtA(a, "recipe/checkpoint-{s}.vwx", .{cp}), "recipe_checkpoint", false, s_created, base);
    }
    _ = try w.put("auxiliary", "capture.script", "logs/script.py", "capture_log", false, "unverified", base);
    for (stageNames(a, c)) |n| {
        const rec = fmtA(a, "{s}/stage-{s}.json", .{ w.from, n });
        _ = try w.putFrom("auxiliary", fmtA(a, "capture.stage.{s}", .{n}), rec, fmtA(a, "logs/stage-{s}.json", .{n}), "capture_log", false, "unverified", base);
    }
    var extras: std.ArrayList(BundleExtra) = .empty;
    for (w.group("exports").items) |*x| {
        if (x.* != .object) continue;
        const pid = strField(x.*, "profile_id") orelse continue;
        const prof = s.queue.findProfile(pid) orelse continue;
        const stage = readStage(a, w.io, w.from, fmtA(a, "export-{s}", .{pid})) orelse continue;
        const status = strField(stage, "status") orelse "";
        const data = field(stage, "data") orelse .null;
        const eo = &x.object;
        if (eql(status, "unavailable")) {
            try eo.put(a, "acquisition_state", .{ .string = "unavailable" });
            try eo.put(a, "sha256", .null);
            try eo.put(a, "reason", .{ .string = strField(data, "reason") orelse "" });
            try eo.put(a, "evidence", .{ .string = fmtA(a, "logs/stage-export-{s}.json", .{pid}) });
            continue;
        }
        if (!eql(status, "ok")) continue;
        const ext = formatExt(prof.format).?;
        const rel_dir = fmtA(a, "exports/{s}/{s}", .{ prof.format, pid });
        const bundle = bundleOf(data);
        const es = bundleState(data, ok_state(drv, release_verified, stage));
        const esv: json.Value = .{ .string = strField(data, "state_sha256") orelse "" };
        _ = try w.put("auxiliary", fmtA(a, "export.{s}.state", .{pid}), fmtA(a, "{s}/native-state.json", .{rel_dir}), "native_state", false, es, withFields(a, base, &.{.{ "source_sha256", sv }}));
        _ = try w.put("auxiliary", fmtA(a, "export.{s}.result", .{pid}), fmtA(a, "{s}/result.json", .{rel_dir}), "export_result", false, es, withFields(a, base, &.{ .{ "source_sha256", sv }, .{ "state_sha256", esv } }));
        const id = strField(x.*, "artifact_id") orelse "";
        const main_rel = if (bundle) |b| bundleMainRel(a, b) else fmtA(a, "{s}/output.{s}", .{ rel_dir, ext });
        if (bundle != null) try eo.put(a, "path", .{ .string = main_rel });
        const o = try w.put("exports", id, main_rel, strField(x.*, "channel") orelse "", true, es, base);
        try o.put(a, "source_sha256", sv);
        try o.put(a, "state_sha256", esv);
        try o.put(a, "profile_sha256", .{ .string = prof.profile_sha256 });
        try o.put(a, "warnings", field(data, "warnings") orelse .{ .array = arr(a) });
        try o.put(a, "result", field(data, "result") orelse .{ .string = "" });
        if (bundle) |b| try bundleExtras(a, &extras, pid, b, data, es, sv, esv, prof.profile_sha256);
    }
    try putExtras(w, a, extras.items, base);
    for ([_][]const u8{ "sources", "native_channels", "exports", "auxiliary" }) |g| {
        for (w.group(g).items) |x| {
            if (boolField(x, "required") == true and !eql(strField(x, "acquisition_state") orelse "", "acquired")) return false;
        }
    }
    return true;
}

/// Writes a pack input tree with every artifact pending for the existing-document cases of a
/// session. Generated cases take their skeleton from the inventory `pack-skeleton/`.
pub fn skeleton(a: Allocator, io: Io, d: *Diags, session: []const u8, out_dir: []const u8, out: *Io.Writer) !void {
    const s = loadSession(a, io, d, session) orelse return;
    if (exists(io, out_dir)) {
        d.err("output_exists", out_dir, "skeleton writes a new directory only", .{});
        return;
    }
    const qv = try parseJson(a, try readAll(a, io, s.path(a, "inputs/queue.json")));
    for (s.queue.cases) |c| {
        if (c.kind == .generated) d.err("generated_case", c.case_id, "the inventory pack-skeleton/ holds generated cases. skeleton writes existing-document cases only", .{});
    }
    if (d.errors() > 0) return;
    try mkdirp(io, out_dir);
    var refs = arr(a);
    var n: usize = 0;
    for (arrField(qv, "cases")) |cv| {
        const cid = strField(cv, "case_id") orelse continue;
        const c = s.queue.findCase(cid).?;
        const rel = fmtA(a, "cases/{s}/case.json", .{cid});
        var r = Obj.init(a);
        r.str("case_id", cid);
        r.str("path", rel);
        r.put("sha256", .null);
        try refs.append(r.value());
        const cdir = fmtA(a, "{s}/cases/{s}", .{ out_dir, cid });
        try mkdirp(io, fmtA(a, "{s}/recipe", .{cdir}));
        try copyNew(io, s.path(a, fmtA(a, "inputs/recipes/{s}.json", .{cid})), fmtA(a, "{s}/recipe/spec.json", .{cdir}));
        try writeNew(io, fmtA(a, "{s}/case.json", .{cdir}), stringify(a, existingCase(a, c, cv)));
        n += 1;
    }
    var profiles = arr(a);
    for (arrField(qv, "profiles")) |pv| {
        try profiles.append(pv);
        const pid = strField(pv, "profile_id") orelse continue;
        const rel = strField(pv, "path") orelse continue;
        const to = fmtA(a, "{s}/{s}", .{ out_dir, rel });
        try mkdirp(io, dirname(to));
        try copyNew(io, s.path(a, fmtA(a, "inputs/profiles/{s}.json", .{pid})), to);
    }
    var root = Obj.init(a);
    root.str("schema", "vwx-rosetta/1");
    root.put("release", field(qv, "release") orelse .null);
    root.str("inventory_revision", strField(qv, "queue_revision") orelse "");
    root.put("cases", .{ .array = refs });
    root.put("profiles", .{ .array = profiles });
    root.put("dependencies", .{ .array = arr(a) });
    root.put("obligations", .{ .array = arr(a) });
    try writeNew(io, fmtA(a, "{s}/rosetta.json", .{out_dir}), stringify(a, root.value()));
    try out.print("summary\tcases\t{d}\n", .{n});
    try out.flush();
}

fn pendingEntry(a: Allocator, id: []const u8, path: []const u8, channel: []const u8, required: bool) Obj {
    var o = Obj.init(a);
    o.str("artifact_id", id);
    o.str("path", path);
    o.put("sha256", .null);
    o.str("channel", channel);
    o.boolean("required", required);
    o.str("acquisition_state", "pending");
    var p = Obj.init(a);
    p.str("native_verification", "unexecuted");
    o.put("provenance", p.value());
    return o;
}

const manual_export_reason = "the queue gives this export as an operator_manual operation. No documented scripting entry runs it";

/// case.json of an existing-document case. `required` follows `required_channels` of the queue.
fn existingCase(a: Allocator, c: *const QCase, cv: json.Value) json.Value {
    const need = strings(a, arrField(cv, "required_channels"));
    var o = Obj.init(a);
    o.str("schema", "vwx-rosetta/1");
    o.str("case_id", c.case_id);
    o.str("family_id", c.family_id);
    o.str("recipe_revision", c.recipe_revision orelse "");
    o.str("recipe_sha256", c.recipe_sha256.?);
    o.str("universe", c.universe orelse "native_acceptance");
    o.put("parameters", (Obj.init(a)).value());
    var hist = arr(a);
    for (arrField(cv, "operations")) |op| {
        const name = strField(op, "op") orelse continue;
        const mode = strField(op, "mode");
        hist.append(.{ .string = if (mode) |m| fmtA(a, "{s} {s}", .{ name, m }) else name }) catch {};
    }
    o.put("history", .{ .array = hist });
    o.put("expected_relationships", field(cv, "expected_relationships") orelse .{ .array = arr(a) });
    var sources = arr(a);
    sources.append(pendingEntry(a, "source.original", "source/original.vwx", "source_original", inList(need, "source_original")).value()) catch {};
    sources.append(pendingEntry(a, "source.scratch", "source/scratch.vwx", "source_derivative", inList(need, "source_derivative")).value()) catch {};
    o.put("sources", .{ .array = sources });
    var native = arr(a);
    for (native_artifacts) |na| native.append(pendingEntry(a, na.id, na.rel, na.channel, inList(need, na.channel)).value()) catch {};
    native.append(pendingEntry(a, "native_state_after", "native/state-after.json", "native_state", false).value()) catch {};
    o.put("native_channels", .{ .array = native });
    var exports = arr(a);
    var aux = arr(a);
    for (c.profile_ids) |pid| {
        const prof = for (arrField(cv, "operations")) |op| {
            if (eql(strField(op, "profile_id") orelse "", pid)) break op;
        } else .null;
        const ch = strField(prof, "channel") orelse "";
        const fmt = ch[@min(ch.len, "export_".len)..];
        var e = pendingEntry(a, fmtA(a, "export.{s}", .{pid}), fmtA(a, "exports/{s}/{s}/output.{s}", .{ fmt, pid, formatExt(fmt) orelse fmt }), ch, true);
        e.str("profile_id", pid);
        e.str("reason", manual_export_reason);
        e.str("evidence", "inputs/queue.json");
        exports.append(e.value()) catch {};
        aux.append(pendingEntry(a, fmtA(a, "export.{s}.result", .{pid}), fmtA(a, "exports/{s}/{s}/result.json", .{ fmt, pid }), "export_result", inList(need, "export_result")).value()) catch {};
    }
    o.put("exports", .{ .array = exports });
    var r = Obj.init(a);
    r.str("artifact_id", "recipe");
    r.str("path", "recipe/spec.json");
    r.str("sha256", c.recipe_sha256.?);
    r.str("channel", "recipe");
    r.boolean("required", inList(need, "recipe"));
    r.str("acquisition_state", "acquired");
    var rp = Obj.init(a);
    rp.str("queue_path", c.recipe_path orelse "");
    r.put("provenance", rp.value());
    aux.append(r.value()) catch {};
    o.put("auxiliary", .{ .array = aux });
    o.put("dependencies", strArr(a, c.dependencies));
    o.put("obligations", .{ .array = arr(a) });
    o.str("acquisition_state", "pending");
    return o.value();
}

/// Returns true when every required artifact of the case is `acquired`.
fn finalizeExisting(w: *CaseWriter, c: *const QCase, s: *const Session, drv: DriverKind, release_verified: bool, tag: []const u8, run_no: u32, attempt: u32) !bool {
    const a = w.a;
    const collected = readStage(a, w.io, w.from, "collected").?;
    const cd = field(collected, "data") orelse .null;
    const sv: json.Value = .{ .string = strField(cd, "source_sha256") orelse "" };
    const tv: json.Value = .{ .string = strField(cd, "state_sha256") orelse "" };
    const st: []const u8 = if (drv == .native and release_verified and arrField(collected, "warnings").len == 0) "acquired" else "unverified";
    const base = provBase(a, tag, run_no, attempt);
    _ = try w.put("sources", "source.original", "source/original.vwx", "source_original", true, st, base);
    _ = try w.put("sources", "source.scratch", "source/scratch.vwx", "source_derivative", false, st, withFields(a, base, &.{.{ "copied_from", .{ .string = "source.original" } }}));
    const bound = withFields(a, base, &.{ .{ "source_sha256", sv }, .{ "state_sha256", tv } });
    const derived = withFields(a, bound, &.{.{ "derived_from", strArr(a, &.{"native_query_raw"}) }});
    for (native_artifacts) |na| {
        const prov = if (eql(na.channel, "native_state")) withFields(a, base, &.{.{ "source_sha256", sv }}) else if (na.derived) derived else bound;
        _ = try w.put("native_channels", na.id, na.rel, na.channel, true, st, prov);
    }
    _ = try w.put("native_channels", "native_state_after", "native/state-after.json", "native_state", false, st, withFields(a, base, &.{.{ "source_sha256", sv }}));
    _ = try w.put("auxiliary", "capture.script", "logs/collect.py", "capture_log", false, "unverified", base);
    for (stageNames(a, c)) |n| {
        const rec = fmtA(a, "{s}/stage-{s}.json", .{ w.from, n });
        _ = try w.putFrom("auxiliary", fmtA(a, "capture.stage.{s}", .{n}), rec, fmtA(a, "logs/stage-{s}.json", .{n}), "capture_log", false, "unverified", base);
    }
    var extras: std.ArrayList(BundleExtra) = .empty;
    for (w.group("exports").items) |*x| {
        const pid = strField(x.*, "profile_id") orelse continue;
        const stage = readStage(a, w.io, w.from, fmtA(a, "export-{s}", .{pid})) orelse continue;
        const data = field(stage, "data") orelse .null;
        if (eql(strField(stage, "status") orelse "", "ok")) {
            // finalizeChecks binds the channel to the profile format. The directory comes from the session profile.
            const prof = s.queue.findProfile(pid) orelse continue;
            const rel_dir = fmtA(a, "exports/{s}/{s}", .{ prof.format, pid });
            const bundle = bundleOf(data);
            const es: []const u8 = bundleState(data, if (drv == .native and release_verified and arrField(stage, "warnings").len == 0) "acquired" else "unverified");
            const esv: json.Value = .{ .string = strField(data, "state_sha256") orelse "" };
            const sprov = withFields(a, base, &.{.{ "source_sha256", sv }});
            _ = try w.put("auxiliary", fmtA(a, "export.{s}.state_before", .{pid}), fmtA(a, "{s}/state-before.json", .{rel_dir}), "native_state", false, es, sprov);
            _ = try w.put("auxiliary", fmtA(a, "export.{s}.state", .{pid}), fmtA(a, "{s}/native-state.json", .{rel_dir}), "native_state", false, es, sprov);
            if (bundle == null) _ = try w.put("auxiliary", fmtA(a, "export.{s}.dialog", .{pid}), fmtA(a, "{s}/dialog.txt", .{rel_dir}), "capture_log", false, es, sprov);
            _ = try w.put("auxiliary", fmtA(a, "export.{s}.result", .{pid}), fmtA(a, "{s}/result.json", .{rel_dir}), "export_result", false, es, withFields(a, base, &.{ .{ "source_sha256", sv }, .{ "state_sha256", esv } }));
            const id = strField(x.*, "artifact_id") orelse "";
            if (bundle) |b| try x.object.put(a, "path", .{ .string = bundleMainRel(a, b) });
            const o = try w.put("exports", id, strField(x.*, "path") orelse "", strField(x.*, "channel") orelse "", true, es, base);
            try o.put(a, "source_sha256", sv);
            try o.put(a, "state_sha256", esv);
            try o.put(a, "warnings", field(data, "warnings") orelse .{ .array = arr(a) });
            try o.put(a, "result", field(data, "result") orelse .{ .string = "" });
            if (bundle) |b| {
                try o.put(a, "profile_sha256", .{ .string = prof.profile_sha256 });
                try bundleExtras(a, &extras, pid, b, data, es, sv, esv, prof.profile_sha256);
            }
            continue;
        }
        try x.object.put(a, "evidence", .{ .string = fmtA(a, "logs/stage-export-{s}.json", .{pid}) });
        try x.object.put(a, "reason", .{ .string = strField(data, "reason") orelse manual_export_reason });
    }
    try putExtras(w, a, extras.items, base);
    for ([_][]const u8{ "sources", "native_channels", "exports", "auxiliary" }) |g| {
        for (w.group(g).items) |x| {
            if (boolField(x, "required") == true and !eql(strField(x, "acquisition_state") orelse "", "acquired")) return false;
        }
    }
    return true;
}

/// Copies every regular file under `from` to `to`, except `skip` at the top level.
pub fn copyTree(a: Allocator, io: Io, from: []const u8, to: []const u8, skip: []const u8) !void {
    try mkdirp(io, to);
    var dir = try Dir.cwd().openDir(io, from, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .directory) {
            try mkdirp(io, fmtA(a, "{s}/{s}", .{ to, e.path }));
            continue;
        }
        if (e.kind != .file) return error.SpecialFile;
        if (eql(e.path, skip)) continue;
        try copyNew(io, fmtA(a, "{s}/{s}", .{ from, e.path }), fmtA(a, "{s}/{s}", .{ to, e.path }));
    }
}

// ---------------------------------------------------------------------------
// typed UI routes, calibration evidence and the completion record
// ---------------------------------------------------------------------------

pub const schema_routes = "vwx-rosetta-ui-routes/1";
pub const schema_evidence = "vwx-rosetta-calibration-evidence/1";
pub const schema_completion = "vwx-rosetta-automation-completion/1";
pub const schema_reconcile = "vwx-rosetta-capture-reconcile/1";
pub const max_route_bytes = 1 << 20;
pub const max_routes = 64;
pub const max_evidence_bytes = 1 << 20;
pub const max_completion_bytes = 1 << 20;

/// One typed export route as a route file serializes it. Slices live in the loader arena.
pub const UiRoute = struct {
    id: []const u8,
    format: nur.Format,
    route: nur.Route,
    outputs: nur.ExpectedOutputs,
    /// SHA-256 of the typed route text without status, calibration id and evidence reference.
    /// Calibration evidence binds to it.
    route_sha256: []const u8,
    calibration_id: []const u8 = "",
    /// SHA-256 of the evidence record. Empty for an uncalibrated route.
    evidence_sha256: []const u8 = "",
};

pub const RouteSet = struct {
    release: []const u8,
    workspace: []const u8,
    routes: []const UiRoute,

    pub fn forFormat(rs: *const RouteSet, format_id: []const u8) ?*const UiRoute {
        for (rs.routes) |*r| {
            if (eql(nur.formatId(r.format), format_id)) return r;
        }
        return null;
    }

    pub fn byId(rs: *const RouteSet, id: []const u8) ?*const UiRoute {
        for (rs.routes) |*r| {
            if (eql(r.id, id)) return r;
        }
        return null;
    }
};

fn onlyKeys(v: json.Value, allowed: []const []const u8) bool {
    if (v != .object) return false;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (!inList(allowed, e.key_ptr.*)) return false;
    }
    return true;
}

fn parseVia(a: Allocator, v: json.Value) ?nur.Via {
    switch (v) {
        .string => |s| return if (eql(s, "title_element")) .title_element else null,
        .object => {
            if (!onlyKeys(v, &.{"path"}) or v.object.count() != 1) return null;
            const p = field(v, "path") orelse return null;
            if (p != .array or p.array.items.len == 0 or p.array.items.len > nur.max_path_steps) return null;
            var steps: std.ArrayList(nur.PathStep) = .empty;
            for (p.array.items) |sv| {
                if (!onlyKeys(sv, &.{ "role", "index", "of" })) return null;
                const r = std.meta.stringToEnum(nur.Role, strField(sv, "role") orelse return null) orelse return null;
                const idx = intOf(field(sv, "index") orelse return null) orelse return null;
                const of = intOf(field(sv, "of") orelse return null) orelse return null;
                if (idx < 1 or idx > 255 or of < 1 or of > 255) return null;
                steps.append(a, .{ .role = r, .index = @intCast(idx), .of = @intCast(of) }) catch return null;
            }
            return .{ .path = steps.items };
        },
        else => return null,
    }
}

fn parseSelector(a: Allocator, v: json.Value) ?nur.Selector {
    if (!onlyKeys(v, &.{ "label", "role", "container", "via" })) return null;
    const label = strField(v, "label") orelse return null;
    const role = std.meta.stringToEnum(nur.Role, strField(v, "role") orelse return null) orelse return null;
    const cv = field(v, "container") orelse return null;
    const container: nur.Container = switch (cv) {
        .string => |s| if (eql(s, "document_sheet")) .document_sheet else return null,
        .object => blk: {
            if (!onlyKeys(cv, &.{ "window", "window_sheet" }) or cv.object.count() != 1) return null;
            if (strField(cv, "window_sheet")) |t| break :blk .{ .window_sheet = a.dupe(u8, t) catch return null };
            break :blk .{ .window = a.dupe(u8, strField(cv, "window") orelse return null) catch return null };
        },
        else => return null,
    };
    const via: nur.Via = if (field(v, "via")) |x| parseVia(a, x) orelse return null else .name;
    return .{ .container = container, .role = role, .label = a.dupe(u8, label) catch return null, .via = via };
}

fn parseValue(a: Allocator, v: json.Value) ?nur.OptionValue {
    if (!onlyKeys(v, &.{ "checked", "choice", "text" }) or v.object.count() != 1) return null;
    if (boolField(v, "checked")) |b| return .{ .checked = b };
    if (strField(v, "choice")) |s| return .{ .choice = a.dupe(u8, s) catch return null };
    if (strField(v, "text")) |s| return .{ .text = a.dupe(u8, s) catch return null };
    return null;
}

fn parseStep(a: Allocator, v: json.Value) ?nur.Step {
    if (v != .object or v.object.count() != 1) return null;
    if (field(v, "menu")) |m| {
        if (m != .array) return null;
        var labels: std.ArrayList([]const u8) = .empty;
        for (m.array.items) |x| {
            if (x != .string) return null;
            labels.append(a, a.dupe(u8, x.string) catch return null) catch return null;
        }
        return .{ .menu = labels.items };
    }
    if (field(v, "option")) |o| {
        if (!onlyKeys(o, &.{ "selector", "value" })) return null;
        return .{ .option = .{ .selector = parseSelector(a, field(o, "selector") orelse return null) orelse return null, .value = parseValue(a, field(o, "value") orelse return null) orelse return null } };
    }
    if (field(v, "destination")) |dv| {
        if (!onlyKeys(dv, &.{ "name_field", "name_mode", "dir_field", "save_panel" })) return null;
        const mode = std.meta.stringToEnum(nur.NameMode, strField(dv, "name_mode") orelse "full_name") orelse return null;
        const df = field(dv, "dir_field");
        var save_panel: ?nur.SavePanelDir = null;
        if (field(dv, "save_panel")) |sp| {
            if (!onlyKeys(sp, &.{ "where", "sheet_field", "go" }) or sp.object.count() != 3) return null;
            save_panel = .{
                .where = parseSelector(a, field(sp, "where") orelse return null) orelse return null,
                .sheet_field = parseSelector(a, field(sp, "sheet_field") orelse return null) orelse return null,
                .go = parseSelector(a, field(sp, "go") orelse return null) orelse return null,
            };
        }
        return .{ .destination = .{
            .name_field = parseSelector(a, field(dv, "name_field") orelse return null) orelse return null,
            .name_mode = mode,
            .dir_field = if (df) |x| (if (x == .null) null else parseSelector(a, x) orelse return null) else null,
            .save_panel = save_panel,
        } };
    }
    if (field(v, "confirm")) |c| return .{ .confirm = parseSelector(a, c) orelse return null };
    return null;
}

fn selectorJson(a: Allocator, s: nur.Selector) json.Value {
    var o = Obj.init(a);
    o.str("label", s.label);
    o.str("role", @tagName(s.role));
    switch (s.container) {
        .document_sheet => o.str("container", "document_sheet"),
        .window => |t| {
            var c = Obj.init(a);
            c.str("window", t);
            o.put("container", c.value());
        },
        .window_sheet => |t| {
            var c = Obj.init(a);
            c.str("window_sheet", t);
            o.put("container", c.value());
        },
    }
    // The key exists only for a selector that is not matched by name, so older route digests hold.
    switch (s.via) {
        .name => {},
        .title_element => o.str("via", "title_element"),
        .path => |p| {
            var steps = arr(a);
            for (p) |st| {
                var so = Obj.init(a);
                so.str("role", @tagName(st.role));
                so.int("index", st.index);
                so.int("of", st.of);
                steps.append(so.value()) catch {};
            }
            var vo = Obj.init(a);
            vo.put("path", .{ .array = steps });
            o.put("via", vo.value());
        },
    }
    return o.value();
}

fn stepJson(a: Allocator, st: nur.Step) json.Value {
    var o = Obj.init(a);
    switch (st) {
        .menu => |labels| o.put("menu", strArr(a, labels)),
        .option => |x| {
            var p = Obj.init(a);
            p.put("selector", selectorJson(a, x.selector));
            var vv = Obj.init(a);
            switch (x.value) {
                .checked => |b| vv.boolean("checked", b),
                .choice => |s| vv.str("choice", s),
                .text => |s| vv.str("text", s),
            }
            p.put("value", vv.value());
            o.put("option", p.value());
        },
        .destination => |x| {
            var p = Obj.init(a);
            p.put("name_field", selectorJson(a, x.name_field));
            p.str("name_mode", @tagName(x.name_mode));
            p.put("dir_field", if (x.dir_field) |df| selectorJson(a, df) else .null);
            if (x.save_panel) |sp| {
                var so = Obj.init(a);
                so.put("where", selectorJson(a, sp.where));
                so.put("sheet_field", selectorJson(a, sp.sheet_field));
                so.put("go", selectorJson(a, sp.go));
                p.put("save_panel", so.value());
            }
            o.put("destination", p.value());
        },
        .confirm => |s| o.put("confirm", selectorJson(a, s)),
    }
    return o.value();
}

/// The typed route in a fixed key order. `route_sha256` is the digest of this text.
fn routeCoreJson(a: Allocator, r: nur.Route, outputs: nur.ExpectedOutputs) json.Value {
    var o = Obj.init(a);
    o.str("id", r.id);
    o.str("format", nur.formatId(r.format));
    o.boolean("progress", r.progress);
    // The key is written only when the route names an indicator, so a route without one keeps its digest.
    if (r.progress_id.len > 0) o.str("progress_id", r.progress_id);
    o.put("cancel", if (r.cancel) |c| selectorJson(a, c) else .null);
    var steps = arr(a);
    for (r.steps) |st| steps.append(stepJson(a, st)) catch {};
    o.put("steps", .{ .array = steps });
    var out = Obj.init(a);
    out.str("primary", outputs.primary);
    out.put("required_sidecars", strArr(a, outputs.required_sidecars));
    out.put("allowed_sidecar_exts", strArr(a, outputs.allowed_sidecar_exts));
    o.put("outputs", out.value());
    return o.value();
}

fn routeDigest(a: Allocator, r: nur.Route, outputs: nur.ExpectedOutputs) []const u8 {
    return shaDup(a, stringifyLine(a, routeCoreJson(a, r, outputs)));
}

fn isLowerHex64(s: []const u8) bool {
    return lowerHex64(s);
}

/// Parses a route file. The file holds typed steps only. Every route passes `nur.validateRoute`
/// and `nur.validateOutputs`. A key that the schema does not name is an error. The loader reads no
/// evidence. `status` and `evidence_sha256` are claims that `resolveEvidence` checks per run.
pub fn parseRouteSet(a: Allocator, d: *Diags, bytes: []const u8, where: []const u8) ?RouteSet {
    const v = parseJson(a, bytes) catch |e| {
        d.err("routes_malformed", where, "the route file does not parse: {s}", .{@errorName(e)});
        return null;
    };
    if (!onlyKeys(v, &.{ "schema", "release", "workspace", "routes" }) or !eql(strField(v, "schema") orelse "", schema_routes)) {
        d.err("routes_malformed", where, "the route file needs schema {s} and the keys schema, release, workspace and routes", .{schema_routes});
        return null;
    }
    const release = strField(v, "release") orelse "";
    const workspace = strField(v, "workspace") orelse "";
    const lim: nur.Limits = .{};
    if (release.len == 0 or workspace.len == 0 or release.len > lim.max_label or workspace.len > lim.max_label) {
        d.err("routes_malformed", where, "release and workspace are strings of 1 to {d} bytes", .{lim.max_label});
        return null;
    }
    const rv = field(v, "routes") orelse .null;
    if (rv != .array or rv.array.items.len > max_routes) {
        d.err("routes_malformed", where, "routes is an array of at most {d} entries", .{max_routes});
        return null;
    }
    var list: std.ArrayList(UiRoute) = .empty;
    var ok = true;
    for (rv.array.items, 0..) |x, i| {
        const loc = fmtA(a, "{s}/routes/{d}", .{ where, i });
        if (!onlyKeys(x, &.{ "id", "format", "progress", "progress_id", "cancel", "steps", "outputs", "binding", "status", "calibration_id", "evidence_sha256" })) {
            d.err("routes_malformed", loc, "the route holds a key that the schema does not name", .{});
            ok = false;
            continue;
        }
        const id = strField(x, "id") orelse "";
        const fmt = nur.formatFromId(strField(x, "format") orelse "") orelse {
            d.err("route_format_unknown", loc, "format `{s}` is not a canonical route format id", .{strField(x, "format") orelse ""});
            ok = false;
            continue;
        };
        var steps: std.ArrayList(nur.Step) = .empty;
        var steps_ok = field(x, "steps") != null and field(x, "steps").? == .array;
        if (steps_ok) for (field(x, "steps").?.array.items) |sv| {
            const st = parseStep(a, sv) orelse {
                steps_ok = false;
                break;
            };
            steps.append(a, st) catch {
                steps_ok = false;
                break;
            };
        };
        if (!steps_ok) {
            d.err("route_step_malformed", loc, "a step is not a typed menu, option, destination or confirm record", .{});
            ok = false;
            continue;
        }
        const cancel_v = field(x, "cancel") orelse .null;
        const cancel: ?nur.Selector = if (cancel_v == .null) null else parseSelector(a, cancel_v) orelse {
            d.err("route_step_malformed", loc, "cancel is not a typed selector", .{});
            ok = false;
            continue;
        };
        const ov = field(x, "outputs") orelse .null;
        if (!onlyKeys(ov, &.{ "primary", "required_sidecars", "allowed_sidecar_exts" })) {
            d.err("route_outputs_malformed", loc, "outputs needs primary and may hold required_sidecars and allowed_sidecar_exts", .{});
            ok = false;
            continue;
        }
        const outputs: nur.ExpectedOutputs = .{
            .primary = strField(ov, "primary") orelse "",
            .required_sidecars = strings(a, arrField(ov, "required_sidecars")),
            .allowed_sidecar_exts = strings(a, arrField(ov, "allowed_sidecar_exts")),
        };
        const bv = field(x, "binding") orelse .null;
        if (!onlyKeys(bv, &.{ "profile_hash", "source_digest", "state_digest" })) {
            d.err("route_binding_malformed", loc, "binding needs profile_hash, source_digest and state_digest", .{});
            ok = false;
            continue;
        }
        const status_name = strField(x, "status") orelse "uncalibrated";
        const status = std.meta.stringToEnum(nur.CalibrationStatus, status_name) orelse {
            d.err("route_status_malformed", loc, "status `{s}` is neither uncalibrated nor calibrated", .{status_name});
            ok = false;
            continue;
        };
        const route: nur.Route = .{
            .id = id,
            .format = fmt,
            .steps = steps.items,
            .cancel = cancel,
            .progress = boolField(x, "progress") orelse false,
            .progress_id = strField(x, "progress_id") orelse "",
            .binding = .{
                .release = release,
                .workspace = workspace,
                .profile_hash = strField(bv, "profile_hash") orelse "",
                .source_digest = strField(bv, "source_digest") orelse "",
                .state_digest = strField(bv, "state_digest") orelse "",
            },
            .status = status,
        };
        nur.validateBinding(route.binding, lim) catch {
            d.err("route_binding_malformed", loc, "release and workspace are labels and the three digests are lowercase SHA-256", .{});
            ok = false;
            continue;
        };
        nur.validateRoute(route, .calibration, lim) catch |e| {
            d.err("route_invalid", loc, "route `{s}` is not a valid typed route: {s}", .{ id, @errorName(e) });
            ok = false;
            continue;
        };
        nur.validateOutputs(fmt, outputs, lim) catch |e| {
            d.err("route_outputs_malformed", loc, "route `{s}` has invalid expected outputs: {s}", .{ id, @errorName(e) });
            ok = false;
            continue;
        };
        for (list.items) |prev| {
            if (eql(prev.id, id) or prev.format == fmt) {
                d.err("route_duplicate", loc, "route `{s}` repeats an id or a format", .{id});
                ok = false;
            }
        }
        const ev_sha = strField(x, "evidence_sha256") orelse "";
        if (ev_sha.len > 0 and !isLowerHex64(ev_sha)) {
            d.err("route_status_malformed", loc, "evidence_sha256 is not a lowercase SHA-256", .{});
            ok = false;
            continue;
        }
        if (status == .calibrated and ev_sha.len == 0) {
            // A calibrated claim without an evidence digest stays a claim. The run refuses it.
            d.add(.warning, "route_claim_without_evidence", loc, "route `{s}` claims calibrated and names no evidence record. A verified run refuses it", .{id});
        }
        list.append(a, .{
            .id = id,
            .format = fmt,
            .route = route,
            .outputs = outputs,
            .route_sha256 = routeDigest(a, route, outputs),
            .calibration_id = strField(x, "calibration_id") orelse "",
            .evidence_sha256 = ev_sha,
        }) catch return null;
    }
    if (!ok) return null;
    return .{ .release = release, .workspace = workspace, .routes = list.items };
}

/// The route file text for `rs`. Parsing the result gives the same route digests.
pub fn routeSetJson(a: Allocator, rs: RouteSet) json.Value {
    var o = Obj.init(a);
    o.str("schema", schema_routes);
    o.str("release", rs.release);
    o.str("workspace", rs.workspace);
    var list = arr(a);
    for (rs.routes) |r| {
        var x = Obj.init(a);
        const core = routeCoreJson(a, r.route, r.outputs);
        var it = core.object.iterator();
        while (it.next()) |e| x.put(e.key_ptr.*, e.value_ptr.*);
        var b = Obj.init(a);
        b.str("profile_hash", r.route.binding.profile_hash);
        b.str("source_digest", r.route.binding.source_digest);
        b.str("state_digest", r.route.binding.state_digest);
        x.put("binding", b.value());
        x.str("status", @tagName(r.route.status));
        x.str("calibration_id", r.calibration_id);
        x.str("evidence_sha256", r.evidence_sha256);
        list.append(x.value()) catch {};
    }
    o.put("routes", .{ .array = list });
    return o.value();
}

// calibration evidence

pub const EvidenceProblem = struct { code: []const u8, msg: []const u8 };

/// Calibration evidence after the digest, route, executable and retained bundle checks.
pub const LoadedEvidence = struct {
    calibration_id: []const u8,
    evidence_sha256: []const u8,
    /// The binding of the calibration run. It is retained provenance. A verified run compares only
    /// the calibration identity (see `evidenceIdentityProblem`). The source and state digests of a
    /// run come from the sealed bundle of that run.
    binding: nur.Binding,
    profile_id: []const u8,
    manifest_sha256: []const u8,
    executable_sha256: []const u8,
    /// SHA-256 of the profile options that the calibration used.
    options_sha256: []const u8,
    /// The `export_ms` measurement that the calibration run recorded, when it is a number.
    export_ms: ?f64 = null,
};

pub const EvidenceResult = union(enum) { ok: LoadedEvidence, problem: EvidenceProblem };

fn evProblem(a: Allocator, code: []const u8, comptime fmt: []const u8, args: anytype) EvidenceResult {
    return .{ .problem = .{ .code = code, .msg = fmtA(a, fmt, args) } };
}

/// Resolves the evidence record that `ur` names by digest. The record is `<evidence_dir>/<sha>.json`
/// and its bytes must hash to `<sha>`. It must name this route, its typed digest and the running
/// executable, come from a native backend and point to a retained bundle that `opdir.verify`
/// accepts under the recorded bindings. The route status and the calibration id are claims. They
/// are compared with the record and never accepted alone.
pub fn loadEvidence(a: Allocator, io: Io, ur: *const UiRoute, evidence_dir: []const u8, exe_sha256: []const u8) EvidenceResult {
    if (ur.evidence_sha256.len == 0) return evProblem(a, "evidence_missing", "route `{s}` names no calibration evidence", .{ur.id});
    const path = fmtA(a, "{s}/{s}.json", .{ evidence_dir, ur.evidence_sha256 });
    const bytes = Dir.cwd().readFileAlloc(io, path, a, .limited(max_evidence_bytes)) catch return evProblem(a, "evidence_unreadable", "cannot read {s}", .{path});
    const have = sha256Hex(bytes);
    if (!eql(&have, ur.evidence_sha256)) return evProblem(a, "evidence_digest_mismatch", "{s} hashes to {s}", .{ path, &have });
    const v = parseJson(a, bytes) catch return evProblem(a, "evidence_malformed", "{s} does not parse", .{path});
    if (!onlyKeys(v, &.{ "schema", "calibration_id", "route_id", "route_sha256", "format", "binding", "profile_id", "executable_sha256", "backend", "bundle", "options", "files", "measurements", "options_sha256" }) or !eql(strField(v, "schema") orelse "", schema_evidence)) {
        return evProblem(a, "evidence_malformed", "{s} is not a {s} record", .{ path, schema_evidence });
    }
    const cal = strField(v, "calibration_id") orelse "";
    if (cal.len == 0 or !eql(cal, ur.calibration_id)) return evProblem(a, "evidence_stale_route", "the record names calibration `{s}` and the route names `{s}`", .{ cal, ur.calibration_id });
    if (!eql(strField(v, "route_id") orelse "", ur.id) or !eql(strField(v, "format") orelse "", nur.formatId(ur.format))) return evProblem(a, "evidence_stale_route", "the record names another route or format", .{});
    if (!eql(strField(v, "route_sha256") orelse "", ur.route_sha256)) return evProblem(a, "evidence_stale_route", "the typed route changed after calibration", .{});
    const exe = strField(v, "executable_sha256") orelse "";
    if (!eql(exe, exe_sha256)) return evProblem(a, "evidence_stale_binary", "the record was written by executable {s}. This is {s}", .{ exe, exe_sha256 });
    if (!eql(strField(v, "backend") orelse "", "mac")) return evProblem(a, "evidence_not_native", "backend `{s}` is not the macOS backend", .{strField(v, "backend") orelse ""});
    const bv = field(v, "binding") orelse .null;
    const binding: nur.Binding = .{
        .release = strField(bv, "release") orelse "",
        .workspace = strField(bv, "workspace") orelse "",
        .profile_hash = strField(bv, "profile_hash") orelse "",
        .source_digest = strField(bv, "source_digest") orelse "",
        .state_digest = strField(bv, "state_digest") orelse "",
    };
    nur.validateBinding(binding, .{}) catch return evProblem(a, "evidence_malformed", "the record binding is malformed", .{});
    for (arrField(v, "options")) |o| {
        if (!eql(strField(o, "requested") orelse "", strField(o, "observed") orelse "\x00")) return evProblem(a, "evidence_options_unconfirmed", "option `{s}` was requested as `{s}` and read back as `{s}`", .{ strField(o, "label") orelse "", strField(o, "requested") orelse "", strField(o, "observed") orelse "" });
    }
    const options_sha = strField(v, "options_sha256") orelse "";
    if (!isLowerHex64(options_sha)) return evProblem(a, "evidence_malformed", "the record has no options_sha256", .{});
    const export_ms: ?f64 = if (field(v, "measurements")) |m| (if (field(m, "export_ms")) |x| numberOf(x) else null) else null;
    const bundle = field(v, "bundle") orelse .null;
    const bdir = strField(bundle, "dir") orelse "";
    const profile_id = strField(v, "profile_id") orelse "";
    if (opdir.pathProblem(bdir) != null) return evProblem(a, "evidence_malformed", "the bundle directory `{s}` is not a relative path", .{bdir});
    const manifest_sha = strField(bundle, "manifest_sha256") orelse "";
    var ver = opdir.verify(a, io, fmtA(a, "{s}/{s}", .{ evidence_dir, bdir }), .{
        .op_id = strField(bundle, "op_id"),
        .format = nur.formatId(ur.format),
        .main_file = strField(bundle, "main_file"),
        .bindings = .{ .source_sha256 = binding.source_digest, .state_sha256 = binding.state_digest, .profile_id = profile_id, .profile_sha256 = binding.profile_hash },
    }, .{}) catch |e| return evProblem(a, "evidence_bundle_unverified", "the retained bundle {s} cannot be read: {s}", .{ bdir, @errorName(e) });
    defer ver.deinit();
    if (!ver.isVerified()) return evProblem(a, "evidence_bundle_unverified", "the retained bundle {s} is {s}: {s}", .{ bdir, @tagName(ver.status), ver.reason });
    if (!eql(manifest_sha, &ver.sealed.?.manifest_sha256)) return evProblem(a, "evidence_bundle_unverified", "the retained manifest hashes to {s}. The record names {s}", .{ &ver.sealed.?.manifest_sha256, manifest_sha });
    return .{ .ok = .{ .calibration_id = cal, .evidence_sha256 = ur.evidence_sha256, .binding = binding, .profile_id = profile_id, .manifest_sha256 = manifest_sha, .executable_sha256 = exe, .options_sha256 = options_sha, .export_ms = export_ms } };
}

/// The whole calibration binding equals the run binding in every field. This is provenance. A verified
/// run does not need it. A run of another case has other source and state digests.
pub fn evidenceBindingProblem(ev: LoadedEvidence, run: nur.Binding) ?[]const u8 {
    if (!ev.binding.eql(run)) return "the evidence binding differs from the run binding in release, workspace, profile, source or state";
    return null;
}

/// SHA-256 of the options of a profile in the order of the queue. A calibration binds the options
/// that its route typed and read back. Profiles of one format with equal options share it.
pub fn optionsDigest(a: Allocator, options: json.Value) []const u8 {
    return shaDup(a, stringifyLine(a, options));
}

/// The calibration identity that a verified run and the completion check compare with one evidence
/// record. It names the release, the workspace and the profile options. The route digest and the
/// executable are checked by `loadEvidence`. The source and state of a run are bound through the sealed
/// bundle of that run, so several cases and profiles share one record.
pub fn evidenceIdentityProblem(ev: LoadedEvidence, release: []const u8, workspace: []const u8, options_sha256: []const u8) ?[]const u8 {
    if (!eql(ev.binding.release, release) or !eql(ev.binding.workspace, workspace)) return "evidence_stale_release: the calibration names another release or workspace";
    if (!eql(ev.options_sha256, options_sha256)) return "evidence_stale_options: the profile options differ from the calibrated options";
    return null;
}

/// The route with its status and evidence set from retained evidence. The status is `calibrated`
/// only here. A route file claim never reaches the runtime without this step. A calibration run
/// defines its own binding, so the route takes the run binding. A verified run takes the run binding
/// too, after the caller checked `evidenceIdentityProblem`. The runtime then compares equal bindings,
/// and the identity check carries the comparison that matters.
pub fn routeForRun(ur: *const UiRoute, ev: ?LoadedEvidence, phase: nur.Phase, run: nur.Binding) nur.Route {
    var r = ur.route;
    r.status = .uncalibrated;
    r.evidence = null;
    if (phase == .calibration) r.binding = run;
    if (ev) |e| {
        r.status = .calibrated;
        r.binding = run;
        r.evidence = .{ .calibration_id = e.calibration_id, .binding = run };
    }
    return r;
}

// ---------------------------------------------------------------------------
// native driver
// ---------------------------------------------------------------------------

/// The strict console, window and modal route of the native driver. `rt` runs every UI export and
/// every document gate. `backend` is the backend of `rt`, which the guarded close uses for one menu
/// step. `calls` counts the calls that reached each route. Tests read it as evidence that an
/// operation used the runtime and not a bypass.
pub const UiWiring = struct {
    rt: *nur.Runtime,
    backend: nur.Backend,
    routes: ?*const RouteSet = null,
    evidence_dir: []const u8 = "",
    exe_sha256: []const u8 = "",
    phase: nur.Phase = .verified,
    scratch: ?nur.ScratchAuthorization = null,
    expect_converted: bool = false,
    expect_watermark: bool = false,
    allow_conversion_ack: bool = false,
    allow_watermark_ack: bool = false,
    /// Titles of other document windows that stay open. Only the owned reference cleanup sets it.
    tolerated_documents: []const []const u8 = &.{},
    /// Deadline of the guarded close.
    close_timeout_ms: u32 = 20_000,
    calls: Calls = .{},

    pub const Calls = struct { gate: u32 = 0, ui_export: u32 = 0, close_menu: u32 = 0, dismiss: u32 = 0 };

    fn policy(u: *const UiWiring, a: Allocator, document: []const u8) nui.Policy {
        const buf = a.alloc(u8, 300) catch return .{ .expected = .{ .original = document } };
        return .{
            .expected = .{
                .original = document,
                .converted = if (u.expect_converted) nui.convertedName(buf, document) else null,
                .watermarked = u.expect_watermark,
            },
            // Observed macOS ioreg omits the lock key for the active unlocked console.
            .console = .{ .missing_lock_key_is_unlocked = true },
            .allow_conversion_ack = u.allow_conversion_ack,
            .allow_watermark_ack = u.allow_watermark_ack,
            .tolerated_documents = u.tolerated_documents,
        };
    }
};

pub const NativeConfig = struct {
    pid: i32,
    /// Program that sends one Apple Event: `<sender> <pid> <file.py>` and `<sender> -open <pid> <doc>`.
    sender: []const u8,
    osascript: []const u8 = "/usr/bin/osascript",
    /// Absolute directory for request files.
    request_root: []const u8,
    send_timeout_ms: u32 = 30_000,
    op_timeout_ms: u32 = 600_000,
    /// Wait for one operator export. `--operator-timeout-ms`.
    operator_timeout_ms: u32 = 1_800_000,
    poll_ms: u32 = 250,
    /// Process transport for every helper that the driver starts. Null selects
    /// `native_ui_runtime.ProcessTransport`.
    transport: ?nur.Transport = null,
    /// Read-only window evidence. Null preserves the injected transport route.
    window_backend: ?uidiag.Backend = null,
    /// Strict console, window and modal route. Null keeps the legacy window-name poll and the
    /// dismiss_modal refusal.
    ui: ?*UiWiring = null,
    /// `state` reads selection, active layer and class, view, render mode and scope in addition to
    /// classes, layers, units and origin. An API that the app lacks is a recorded gap.
    extended_state: bool = false,
    /// Absolute executable path that the pid must run. The known STL rejection is acknowledged only
    /// when this is set and `pathOf` returns exactly it right before the press.
    expected_executable: []const u8 = "",
    pathOf: *const fn (pid: i32, buf: []u8) ?[]const u8 = nativePidPath,
    /// Session directory whose INFLIGHT.json must name the export in flight before a press.
    inflight_dir: []const u8 = "",
};

const native_pid = if (@import("builtin").os.tag == .macos) struct {
    extern "c" fn proc_pidpath(pid: c_int, buffer: ?*anyopaque, size: u32) c_int;
    fn pathOf(pid: i32, buf: []u8) ?[]const u8 {
        const n = proc_pidpath(pid, buf.ptr, @intCast(buf.len));
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    }
} else struct {
    fn pathOf(pid: i32, buf: []u8) ?[]const u8 {
        _ = .{ pid, buf };
        return null;
    }
};

fn nativePidPath(pid: i32, buf: []u8) ?[]const u8 {
    return native_pid.pathOf(pid, buf);
}

/// State of the watch for the known STL rejection while one bridge request runs.
const StlWatch = struct {
    op: Op,
    /// The approved native message after OK was pressed.
    rejected: ?[]const u8 = null,
    /// Set when a dialog stopped the watch. The reply is then the unknown modal that stops the run.
    stop: ?Reply = null,
};

/// Sends one bridge program per operation to the app process `pid`. It never starts the app.
pub const NativeDriver = struct {
    a: Allocator,
    io: Io,
    cfg: NativeConfig,
    seq: u32 = 0,
    /// Absolute path of the session document that the last `open` made active. The bridge refuses
    /// every document operation when the active document has another path. Null after `close`.
    doc: ?[]const u8 = null,
    /// SHA-256 of `doc` at the last open or save. The guarded close compares it with the file.
    doc_sha256: ?[]const u8 = null,
    /// File name that the last `open` expected. `dismiss_modal` classifies a dialog against it when
    /// no document is open yet.
    last_expect: ?[]const u8 = null,
    /// Helper subprocesses started through the transport. Tests read it as evidence of the route.
    helper_calls: u32 = 0,

    pub fn driver(n: *NativeDriver) Driver {
        return .{ .ptr = n, .kind = .native, .callFn = callOpaque };
    }

    fn callOpaque(ptr: *anyopaque, a: Allocator, op: Op) Reply {
        const n: *NativeDriver = @ptrCast(@alignCast(ptr));
        return n.call(a, op);
    }

    fn call(n: *NativeDriver, a: Allocator, op: Op) Reply {
        var r = n.callInner(a, op);
        // A timeout that was not refused before any action leaves the effect of a mutating operation
        // unknown. The engine then latches reconciliation and does not retry.
        if (r.status == .timeout and !r.refused and Engine.needsMarker(op.kind)) r.uncertain = true;
        return r;
    }

    fn callInner(n: *NativeDriver, a: Allocator, op: Op) Reply {
        if (!pidAlive(n.cfg.pid)) return .{ .status = .crashed, .detail = fmtA(a, "process {d} is not running", .{n.cfg.pid}) };
        switch (op.kind) {
            .dismiss_modal => return n.dismissModal(a, op),
            .open => return n.open(a, op),
            .close => {
                if (n.cfg.ui != null and std.mem.indexOf(u8, op.payload, "\"fallback\"") != null) return n.closeGuarded(a, op);
                return n.python(a, op, "close");
            },
            .state => return n.python(a, op, if (n.cfg.extended_state) "state_ext" else "state"),
            .export_file => return n.python(a, op, "export"),
            .operator_export => return n.operatorWait(a, op),
            .ui_export => return n.uiExport(a, op),
            else => return n.python(a, op, @tagName(op.kind)),
        }
    }

    // -----------------------------------------------------------------------
    // strict UI route
    // -----------------------------------------------------------------------

    fn basenameOf(path: []const u8) []const u8 {
        return basename(path);
    }

    /// The reply for a runtime failure. A failure that left the app in an unknown state is
    /// `uncertain`. An unknown dialog stays `modal`, which the engine turns into an operator stop
    /// because this driver acknowledges nothing outside the known notices. A deadline or a timeout
    /// that is not uncertain happened before any action. The reply is then `refused`, so the engine
    /// stops without a latch.
    fn replyFromFailure(a: Allocator, f: nur.FailureReport) Reply {
        const diag_note: []const u8 = if (f.diag.attempted) fmtA(a, " | diagnostic {s} {s}: {s}", .{ f.diag.reason, if (f.diag.captured) "captured" else "not captured", f.diag.note() }) else "";
        const detail = if (f.cause != f.kind) fmtA(a, "{s} ({s}): {s}{s}", .{ @tagName(f.kind), @tagName(f.cause), f.detail(), diag_note }) else fmtA(a, "{s}: {s}{s}", .{ @tagName(f.kind), f.detail(), diag_note });
        if (f.uncertain) return .{ .status = if (f.cause == .unknown_ui) .modal else .failed, .detail = detail, .uncertain = true };
        return switch (f.cause) {
            .process_lost => .{ .status = .crashed, .detail = detail },
            .timeout, .deadline_exceeded => .{ .status = .timeout, .detail = detail, .refused = true },
            .unknown_ui, .ambiguous_target, .console_locked, .wrong_identity => .{ .status = .modal, .detail = detail },
            else => .{ .status = .failed, .detail = detail },
        };
    }

    /// Acknowledges a known notice only when the caller permitted it. License, save, overwrite
    /// and unknown dialogs stop the run for the operator.
    fn dismissModal(n: *NativeDriver, a: Allocator, op: Op) Reply {
        _ = op;
        const u = n.cfg.ui orelse return .{ .status = .unsupported, .detail = "the native driver does not dismiss dialogs. Dismiss it by hand" };
        const doc = n.doc orelse n.last_expect orelse return .{ .status = .unsupported, .detail = "no session document. Dismiss the dialog by hand" };
        u.calls.dismiss += 1;
        const g = u.rt.waitForDocument(.{ .pid = n.cfg.pid, .policy = u.policy(a, basenameOf(doc)) });
        if (g.failure) |f| {
            const refused = !f.uncertain and (f.cause == .timeout or f.cause == .deadline_exceeded);
            return .{ .status = .unsupported, .detail = fmtA(a, "stop for the operator. {s}: {s}", .{ @tagName(f.kind), f.detail() }), .uncertain = f.uncertain, .refused = refused };
        }
        if (g.acknowledged_conversion or g.acknowledged_watermark) return .{ .status = .ok, .detail = "a known notice was acknowledged" };
        return .{ .status = .ok, .detail = "no dialog blocks the document" };
    }

    /// Closes the session document through File > Close when the app declares no CloseDocument.
    /// The close needs the live process, the document path that the bridge reports, the file bytes of
    /// the last open or save and one ready window of the expected document. The menu step and the
    /// observations run through `Runtime.closeDocument`, so the runtime deadlines, statistics,
    /// in-flight record and latch apply. A dialog after the menu step is uncertain and is never
    /// acknowledged. `vs.Close` is not a substitute. It closes a text file.
    fn closeGuarded(n: *NativeDriver, a: Allocator, op: Op) Reply {
        const u = n.cfg.ui.?;
        const doc = n.doc orelse return .{ .status = .failed, .detail = "close has no session document" };
        const dr = n.python(a, .{ .kind = .state, .case_id = op.case_id, .profile_id = op.profile_id, .path = doc, .expect = basenameOf(doc) }, "doc");
        if (dr.status != .ok) return dr;
        const reported = parseJson(a, dr.payload) catch .null;
        if (!eql(basenameOf(strField(reported, "path") orelse ""), basenameOf(doc))) return .{ .status = .failed, .detail = "identity: the bridge reports another document" };
        if (n.doc_sha256) |want| {
            const have = hashFileDup(a, n.io, doc) orelse "";
            if (!eql(have, want)) return .{ .status = .failed, .detail = "saved_state: the document file changed since the last open or save" };
        }
        // The unsaved changes of an owned query copy may be discarded when the close shows the exact
        // save prompt. The proof is checked here, against the files and the bridge, and not only by the caller.
        var discard: ?nur.Runtime.DiscardPolicy = null;
        var why_not: []const u8 = "";
        var source_path: []const u8 = "";
        var source_sha: []const u8 = "";
        const pv = parseJson(a, op.payload) catch .null;
        if (field(pv, "discard_unsaved")) |du| {
            source_path = strField(du, "source") orelse "";
            source_sha = strField(du, "source_sha256") orelse "";
            if (n.discardProblem(a, du, doc, strField(reported, "path") orelse "")) |why| why_not = why else discard = .{ .document = basenameOf(doc) };
        }
        u.calls.close_menu += 1;
        const rep = u.rt.closeDocument(.{ .pid = n.cfg.pid, .policy = u.policy(a, basenameOf(doc)), .discard = discard });
        if (rep.failure) |f| return replyFromFailure(a, f);
        const scratch = doc;
        n.doc = null;
        n.doc_sha256 = null;
        if (rep.discarded) {
            // Don't Save leaves both files as they were. A change is an uncertain state and stops the run.
            if (!eql(hashFileDup(a, n.io, source_path) orelse "", source_sha) or !eql(hashFileDup(a, n.io, scratch) orelse "", source_sha)) {
                return .{ .status = .failed, .detail = "saved_state: the sealed source or the query copy changed after Don't Save", .uncertain = true };
            }
            return .{ .status = .ok, .detail = "closed through File > Close after Don't Save of the owned query copy" };
        }
        if (why_not.len > 0) return .{ .status = .ok, .detail = fmtA(a, "closed through File > Close. The discard was not applied: {s}", .{why_not}) };
        return .{ .status = .ok, .detail = "closed through File > Close" };
    }

    /// Null when every part of the ownership proof holds. The tracked document, the active document that
    /// the bridge reports and the owned scratch are one exact path, the sealed source is the sibling
    /// source of the same attempt, and both files hold the recorded digest and the digest of the open.
    fn discardProblem(n: *NativeDriver, a: Allocator, du: json.Value, doc: []const u8, reported: []const u8) ?[]const u8 {
        const scratch = strField(du, "scratch") orelse return "no scratch path";
        const source = strField(du, "source") orelse return "no source path";
        const sha = strField(du, "source_sha256") orelse return "no source digest";
        if (!isLowerHex64(sha)) return "the source digest is not a SHA-256";
        if (!eql(scratch, doc)) return "the scratch is not the tracked document";
        if (!eql(reported, doc)) return "the active document is not the owned scratch";
        const i = std.mem.indexOf(u8, scratch, "/cases/") orelse return "the scratch is not below a case";
        if (!queryCopyShape(scratch[i + 1 ..])) return "the scratch is not a query work copy";
        if (!eql(source, fmtA(a, "{s}/source/reopened.vwx", .{dirname(dirname(dirname(scratch)))}))) return "the source is not the sealed source of this attempt";
        if (!eql(hashFileDup(a, n.io, source) orelse "", sha)) return "the sealed source digest differs";
        if (!eql(hashFileDup(a, n.io, scratch) orelse "", sha)) return "the query copy bytes differ from the source";
        if (!eql(n.doc_sha256 orelse "", sha)) return "the digest at open differs";
        return null;
    }

    /// Runs one typed UI export through the runtime into the operation directory of the payload.
    /// The verified phase resolves the calibration evidence of the route first. The reply payload
    /// carries the option read-back, the observed files and the statistics.
    fn uiExport(n: *NativeDriver, a: Allocator, op: Op) Reply {
        const u = n.cfg.ui orelse return .{ .status = .unsupported, .detail = "the driver has no UI wiring" };
        const doc = n.doc orelse return .{ .status = .failed, .detail = "ui_export has no session document" };
        const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
        const rs = u.routes orelse return .{ .status = .unsupported, .detail = "no route set is loaded" };
        const ur = rs.byId(strField(v, "route_id") orelse "") orelse return .{ .status = .failed, .detail = "invalid_route: the payload names no loaded route" };
        const phase = std.meta.stringToEnum(nur.Phase, strField(v, "phase") orelse "") orelse return .{ .status = .failed, .detail = "invalid_route: the payload names no phase" };
        const bv = field(v, "binding") orelse .null;
        const run: nur.Binding = .{
            .release = strField(bv, "release") orelse "",
            .workspace = strField(bv, "workspace") orelse "",
            .profile_hash = strField(bv, "profile_hash") orelse "",
            .source_digest = strField(bv, "source_digest") orelse "",
            .state_digest = strField(bv, "state_digest") orelse "",
        };
        var ev: ?LoadedEvidence = null;
        if (phase == .verified) switch (loadEvidence(a, n.io, ur, u.evidence_dir, u.exe_sha256)) {
            .ok => |x| {
                // The calibration identity must match. The source and state of this run are bound by its own sealed bundle.
                if (evidenceIdentityProblem(x, run.release, run.workspace, strField(bv, "options_sha256") orelse "")) |why| return .{ .status = .failed, .detail = fmtA(a, "uncalibrated_route: {s}", .{why}) };
                ev = x;
            },
            .problem => |p| return .{ .status = .failed, .detail = fmtA(a, "uncalibrated_route: {s}: {s}", .{ p.code, p.msg }) },
        };
        u.calls.ui_export += 1;
        var rep = u.rt.runExport(.{
            .phase = phase,
            .route = routeForRun(ur, ev, phase, run),
            .policy = u.policy(a, basenameOf(doc)),
            .pid = n.cfg.pid,
            .run_binding = run,
            .op_id = strField(v, "op_id") orelse "",
            .op_dir = strField(v, "op_dir") orelse "",
            .outputs = ur.outputs,
            .scratch = u.scratch,
        });
        defer rep.deinit(u.rt.a);
        var ev_note = Obj.init(a);
        ev_note.put("completion", completionValue(a, rep.completion));
        ev_note.put("cadence", cadenceValue(a, rep.stats.cadence));
        if (rep.failure) |f| {
            var rf = replyFromFailure(a, f);
            rf.detail = fmtA(a, "{s} | completion via={s} established={} observations={d}", .{ rf.detail, @tagName(rep.completion.via), rep.completion.established, rep.completion.observations });
            rf.payload = stringifyLine(a, ev_note.value());
            return rf;
        }
        var o = Obj.init(a);
        o.str("route_id", rep.route_id);
        o.str("phase", @tagName(rep.phase));
        o.boolean("verified", rep.verified);
        o.str("dependency_closure", @tagName(rep.dependency_closure));
        var opts = arr(a);
        for (rep.options) |x| {
            var p = Obj.init(a);
            p.str("label", x.label);
            p.str("requested", x.requested);
            p.str("observed", x.observed);
            opts.append(p.value()) catch {};
        }
        o.put("options", .{ .array = opts });
        var files = arr(a);
        for (rep.files) |x| {
            var p = Obj.init(a);
            p.str("name", x.name);
            p.int("size", @intCast(x.size));
            p.str("role", @tagName(x.role));
            files.append(p.value()) catch {};
        }
        o.put("files", .{ .array = files });
        o.put("completion", completionValue(a, rep.completion));
        o.put("cadence", cadenceValue(a, rep.stats.cadence));
        o.int("polls", rep.stats.polls);
        o.int("elapsed_ms", @intCast(rep.stats.elapsed_ns / std.time.ns_per_ms));
        if (rep.diag.attempted) {
            var dn = Obj.init(a);
            dn.str("reason", rep.diag.reason);
            dn.boolean("captured", rep.diag.captured);
            dn.str("note", rep.diag.note());
            o.put("diagnostic", dn.value());
        }
        return .{ .status = .ok, .payload = stringifyLine(a, o.value()) };
    }

    /// Runs one helper through the process transport. The child leads its own process group. A
    /// deadline or an output limit kills the group and reaps the child before this returns. The
    /// buffers keep the output received so far.
    fn exec(n: *NativeDriver, a: Allocator, argv: []const []const u8, ms: u32) nur.RunOutput {
        var pt: nur.ProcessTransport = .{ .io = n.io };
        const t = n.cfg.transport orelse pt.transport();
        n.helper_calls += 1;
        return t.run(a, argv, ms, .{ .stdout = 1 << 20, .stderr = 64 << 10 });
    }

    /// At most 240 bytes of stderr, or of the partial stdout when stderr is empty. Control bytes
    /// become spaces so that a journal line stays one line.
    fn partialText(a: Allocator, r: nur.RunOutput) []const u8 {
        const src = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \r\n");
        const cut = src[0..@min(src.len, 240)];
        const out = a.dupe(u8, cut) catch return "";
        for (out) |*c| {
            if (c.* < 0x20 or c.* == 0x7f) c.* = ' ';
        }
        return out;
    }

    /// The reply for a helper that did not exit with status 0, or null for one that did.
    fn helperFailure(a: Allocator, r: nur.RunOutput, what: []const u8) ?Reply {
        if (r.succeeded()) return null;
        const part = partialText(a, r);
        return switch (r.status) {
            .timed_out => .{ .status = .timeout, .detail = if (part.len == 0) "the sender did not finish" else fmtA(a, "the sender did not finish. Partial output: {s}", .{part}) },
            .output_limit => .{ .status = .failed, .detail = fmtA(a, "{s} wrote more than its output limit. Partial output: {s}", .{ what, part }) },
            .spawn_failed => .{ .status = .failed, .detail = fmtA(a, "{s} could not start", .{what}) },
            .read_failed => .{ .status = .failed, .detail = fmtA(a, "{s} output could not be read", .{what}) },
            .exited, .signaled => .{ .status = .failed, .detail = fmtA(a, "{s} failed: {s}", .{ what, part }) },
        };
    }

    fn osa(n: *NativeDriver, a: Allocator, script: []const u8) ?[]const u8 {
        const r = n.exec(a, &.{ n.cfg.osascript, "-e", script }, n.cfg.send_timeout_ms);
        if (!r.succeeded()) return null;
        return std.mem.trim(u8, r.stdout, " \r\n");
    }

    /// Document names from the configured window backend. Null when the query failed.
    fn windowNames(n: *NativeDriver, a: Allocator) ?[]const u8 {
        if (n.cfg.window_backend) |b| {
            const wins = switch (b.windows(.{ .pid = n.cfg.pid, .window_id = null, .window_title = null, .timeout_ms = n.cfg.send_timeout_ms })) {
                .failed => return null,
                .windows => |w| w,
            };
            var names: std.ArrayList(u8) = .empty;
            for (wins) |w| {
                if (!eql(w.subrole, "AXStandardWindow") or w.modal != false) continue;
                const title = w.title orelse continue;
                if (title.len == 0) continue;
                if (names.items.len > 0) names.appendSlice(a, ", ") catch return null;
                names.appendSlice(a, title) catch return null;
            }
            return names.toOwnedSlice(a) catch null;
        }
        return n.osa(a, fmtA(a, "tell application \"System Events\" to get name of every window of (first process whose unix id is {d})", .{n.cfg.pid}));
    }

    fn dialogOpen(n: *NativeDriver, a: Allocator) bool {
        if (n.cfg.window_backend) |b| {
            const wins = switch (b.windows(.{ .pid = n.cfg.pid, .window_id = null, .window_title = null, .timeout_ms = n.cfg.send_timeout_ms })) {
                .failed => return true,
                .windows => |w| w,
            };
            for (wins) |w| if (w.modal != false) return true;
            return false;
        }
        const s = n.osa(a, fmtA(a, "tell application \"System Events\" to tell (first process whose unix id is {d}) to count (every window whose subrole is \"AXDialog\" or subrole is \"AXSystemDialog\")", .{n.cfg.pid})) orelse return false;
        const k = std.fmt.parseInt(u32, s, 10) catch return false;
        return k > 0;
    }

    fn reqDir(n: *NativeDriver, a: Allocator) ![]const u8 {
        while (true) {
            n.seq += 1;
            const d = fmtA(a, "{s}/req-{d}", .{ n.cfg.request_root, n.seq });
            if (exists(n.io, d)) continue;
            try mkdirp(n.io, d);
            return d;
        }
    }

    fn python(n: *NativeDriver, a: Allocator, op: Op, name: []const u8) Reply {
        // A Python event with no document window crashed the app in earlier vwui runs.
        if (n.cfg.window_backend != null and n.dialogOpen(a)) return .{ .status = .modal, .detail = "the window backend reports a modal or unreadable window" };
        const wins = n.windowNames(a) orelse return .{ .status = .failed, .detail = "document window query failed. Grant Accessibility access to the terminal" };
        if (wins.len == 0) return .{ .status = .failed, .detail = "the app has no document window. Open a document before this operation" };
        const doc_op = !eql(name, "preflight");
        if (doc_op and n.doc == null) return .{ .status = .failed, .detail = fmtA(a, "{s} has no session document. Open a session copy first", .{name}) };
        const dir = n.reqDir(a) catch return .{ .status = .failed, .detail = "cannot create the request directory" };
        var r = Obj.init(a);
        // The bridge compares vs.GetFName and vs.GetFPathName with `document` before the operation.
        // After the operation the active document must be `document`, a path in `after_paths` or a
        // file in `after_dir`. The bridge writes the matching path to `active`.
        r.put("document", if (doc_op) .{ .string = n.doc.? } else .null);
        var after = arr(a);
        if (op.kind == .save_as) after.append(.{ .string = op.path }) catch {};
        r.put("after_paths", .{ .array = after });
        r.put("after_dir", if (op.kind == .run_script) field(parseJson(a, op.payload) catch .null, "checkpoint_dir") orelse .null else .null);
        r.str("schema", schema_request);
        r.str("bridge_revision", bridge_revision);
        r.str("op", name);
        r.str("case_id", op.case_id);
        r.str("profile_id", op.profile_id);
        r.str("path", op.path);
        r.str("expect", op.expect);
        r.put("payload", parseJson(a, op.payload) catch .null);
        const out = fmtA(a, "{s}/out.json", .{dir});
        const err = fmtA(a, "{s}/err.txt", .{dir});
        const done = fmtA(a, "{s}/done", .{dir});
        const active = fmtA(a, "{s}/active.json", .{dir});
        r.str("out", out);
        r.str("err", err);
        r.str("done", done);
        r.str("active", active);
        const req_path = fmtA(a, "{s}/request.json", .{dir});
        putSealed(a, n.io, req_path, stringify(a, r.value())) catch return .{ .status = .failed, .detail = "cannot write request.json" };
        const prog = fmtA(a, "{s}/program.py", .{dir});
        const head = fmtA(a, "REQ_PATH = {s}\n", .{stringifyLine(a, .{ .string = req_path })});
        putSealed(a, n.io, prog, std.mem.concat(a, u8, &.{ head, bridgeProgram(a, name) }) catch "") catch return .{ .status = .failed, .detail = "cannot write program.py" };
        const pid = fmtA(a, "{d}", .{n.cfg.pid});
        const sent = n.exec(a, &.{ n.cfg.sender, pid, prog }, n.cfg.send_timeout_ms);
        if (helperFailure(a, sent, "the sender")) |f| return f;
        var watch: StlWatch = .{ .op = op };
        const watching = op.kind == .export_file and eql(apiOfPayload(a, op.payload), stl_api) and n.cfg.ui != null;
        var reply = n.wait(a, out, err, done, if (watching) &watch else null);
        // The request was sent and no reply came. The script may still run.
        if ((reply.status == .timeout or reply.status == .modal) and Engine.needsMarker(op.kind)) reply.uncertain = true;
        if (!doc_op or reply.status != .ok) return reply;
        if (op.kind == .close) {
            n.doc = null;
            return reply;
        }
        const av = parseJson(a, readAll(a, n.io, active) catch "") catch .null;
        const now = strField(av, "path") orelse {
            n.doc = null;
            return .{ .status = .failed, .detail = "the bridge wrote no active document path" };
        };
        n.doc = now;
        if (op.kind == .save_as) n.doc_sha256 = hashFileDup(a, n.io, now);
        return reply;
    }

    /// Waits for the `done` file of one bridge request. The file is read once more at the deadline,
    /// so a reply that arrived during the last interval counts. A timeout leaves the outcome of the
    /// request unknown, because the script may still run. `python` marks it uncertain for an
    /// operation that changes the app, so the engine latches reconciliation and stops instead of
    /// retrying into a directory that the script may still write.
    fn wait(n: *NativeDriver, a: Allocator, out: []const u8, err: []const u8, done: []const u8, watch: ?*StlWatch) Reply {
        const deadline = nowMs(n.io) + n.cfg.op_timeout_ms;
        var bo = nur.Backoff.init(10, n.cfg.poll_ms);
        while (true) {
            if (exists(n.io, done)) {
                if (watch) |w| if (w.rejected) |msg| {
                    // The application refused the export. The bridge call has now returned, so the
                    // app is idle again. Whatever the bridge wrote, the outcome is the rejection.
                    const bridge: []const u8 = if (exists(n.io, err)) "error" else "returned";
                    return .{ .status = .unsupported, .detail = fmtA(a, "the application rejected the STL export: {s}", .{msg}), .payload = rejectionPayload(a, msg, bridge) };
                };
                if (exists(n.io, err)) {
                    const t = readAll(a, n.io, err) catch "";
                    return .{ .status = .failed, .detail = std.mem.trim(u8, t, " \n") };
                }
                const payload = readAll(a, n.io, out) catch return .{ .status = .failed, .detail = "done exists without out.json" };
                _ = parseJson(a, payload) catch return .{ .status = .failed, .detail = "out.json is not JSON" };
                return .{ .status = .ok, .payload = payload };
            }
            if (!pidAlive(n.cfg.pid)) return .{ .status = .crashed, .detail = fmtA(a, "process {d} exited during the operation", .{n.cfg.pid}) };
            if (watch) |w| if (w.rejected == null and n.dialogOpen(a)) {
                // A dialog while the export call is blocked. The one approved message is acknowledged.
                // Every other dialog is an unknown modal that stops the run, as without the watch.
                if (n.acknowledgeStlRejection(a, w)) |stop| return stop;
                continue;
            };
            if (nowMs(n.io) >= deadline) break;
            sleepMs(n.io, bo.next(false));
        }
        if (n.dialogOpen(a)) return .{ .status = .modal, .detail = "System Events reports a dialog window" };
        return .{ .status = .timeout, .detail = fmtA(a, "no done file after {d} ms", .{n.cfg.op_timeout_ms}) };
    }

    /// Presses OK on the approved STL rejection after every binding holds: the target pid runs the
    /// expected executable, INFLIGHT.json names this very `vs.ExportSTL` export, and the runtime finds
    /// exactly one modal with the approved text beside the one expected document window. Returns the
    /// reply that ends the call when anything differs or the press leaves an unknown state, and null
    /// after a verified acknowledgement.
    fn acknowledgeStlRejection(n: *NativeDriver, a: Allocator, w: *StlWatch) ?Reply {
        const u = n.cfg.ui.?;
        const unknown = struct {
            fn r(al: Allocator, why: []const u8) Reply {
                return .{ .status = .modal, .detail = fmtA(al, "a dialog blocks the STL export and is not acknowledged: {s}", .{why}), .uncertain = true };
            }
        }.r;
        if (n.cfg.expected_executable.len == 0) return unknown(a, "no --expected-executable was given");
        var buf: [4096]u8 = undefined;
        const path = n.cfg.pathOf(n.cfg.pid, &buf) orelse return unknown(a, "the target process has no executable path");
        if (!eql(path, n.cfg.expected_executable)) return unknown(a, "the target process runs another executable");
        const doc = n.doc orelse return unknown(a, "no session document");
        if (!inflightMatches(a, n.io, n.cfg.inflight_dir, w.op)) return unknown(a, "INFLIGHT.json does not name this export");
        u.calls.dismiss += 1;
        const rep = u.rt.acknowledgeNotice(.{ .pid = n.cfg.pid, .policy = u.policy(a, basenameOf(doc)), .message = stl_rejection_message });
        if (rep.failure) |f| {
            var rf = replyFromFailure(a, f);
            rf.status = .modal;
            rf.uncertain = true;
            return rf;
        }
        if (rep.absent) return unknown(a, "the dialog went away before it was read");
        w.rejected = stl_rejection_message;
        return null;
    }

    /// Writes operator.json into a request directory and polls until the dialog record exists and
    /// the export file has the same size above 0 on two polls. It sends nothing to the app.
    fn operatorWait(n: *NativeDriver, a: Allocator, op: Op) Reply {
        const v = parseJson(a, op.payload) catch return .{ .status = .failed, .detail = "payload is not JSON" };
        const dp = strField(v, "dialog_record") orelse return .{ .status = .failed, .detail = "payload has no dialog_record" };
        const dir = n.reqDir(a) catch return .{ .status = .failed, .detail = "cannot create the request directory" };
        var r = Obj.init(a);
        r.str("schema", schema_request);
        r.str("op", "operator_export");
        r.str("case_id", op.case_id);
        r.str("profile_id", op.profile_id);
        r.str("path", op.path);
        r.put("payload", v);
        putSealed(a, n.io, fmtA(a, "{s}/operator.json", .{dir}), stringify(a, r.value())) catch return .{ .status = .failed, .detail = "cannot write operator.json" };
        const deadline = nowMs(n.io) + n.cfg.operator_timeout_ms;
        var bo = nur.Backoff.init(10, @max(n.cfg.poll_ms, 1000));
        var last: ?u64 = null;
        while (nowMs(n.io) < deadline) {
            if (!pidAlive(n.cfg.pid)) return .{ .status = .crashed, .detail = fmtA(a, "process {d} exited during the operator export", .{n.cfg.pid}) };
            const size = fileSize(n.io, op.path);
            if (size != null and size.? > 0 and last != null and last.? == size.? and exists(n.io, dp)) return .{ .status = .ok };
            const changed = size != last;
            last = size;
            sleepMs(n.io, bo.next(changed));
        }
        return .{ .status = .timeout, .detail = fmtA(a, "no export file and dialog record after {d} ms", .{n.cfg.operator_timeout_ms}) };
    }

    fn open(n: *NativeDriver, a: Allocator, op: Op) Reply {
        // A spent run budget refuses the open before the Apple Event leaves.
        if (n.cfg.ui) |u| {
            if (u.rt.budgetExhausted()) return .{ .status = .timeout, .refused = true, .detail = "deadline_exceeded: the run budget passed before the open. No event was sent" };
            // Subscribe before the open event leaves.
            u.rt.armNotifier(n.cfg.pid, "");
        }
        const pid = fmtA(a, "{d}", .{n.cfg.pid});
        const sent = n.exec(a, &.{ n.cfg.sender, "-open", pid, op.path }, n.cfg.send_timeout_ms);
        if (helperFailure(a, sent, "the open sender")) |f| return f;
        n.last_expect = op.expect;
        if (n.cfg.ui) |u| {
            // Console, window identity, progress and known notices come from the runtime.
            u.calls.gate += 1;
            const g = u.rt.waitForDocument(.{ .pid = n.cfg.pid, .policy = u.policy(a, op.expect), .wait_for_readable_windows = true });
            if (g.failure) |f| {
                // The open event was sent. A timeout now leaves the document state unknown.
                var rf = replyFromFailure(a, f);
                if (rf.refused) {
                    rf.refused = false;
                    rf.uncertain = true;
                }
                return rf;
            }
        } else {
            const stem = if (std.mem.endsWith(u8, op.expect, ".vwx")) op.expect[0 .. op.expect.len - 4] else op.expect;
            const deadline = nowMs(n.io) + n.cfg.op_timeout_ms;
            var bo = nur.Backoff.init(10, n.cfg.poll_ms);
            while (true) {
                if (n.windowNames(a)) |names| {
                    if (std.mem.indexOf(u8, names, stem) != null) break;
                }
                if (!pidAlive(n.cfg.pid)) return .{ .status = .crashed, .detail = "the app exited during open" };
                if (nowMs(n.io) >= deadline) {
                    if (n.dialogOpen(a)) return .{ .status = .modal, .detail = "a dialog opened during open" };
                    return .{ .status = .timeout, .detail = fmtA(a, "no window named {s}", .{op.expect}) };
                }
                sleepMs(n.io, bo.next(false));
            }
        }
        // The `doc` request names the opened path. The bridge refuses a front document with another
        // vs.GetFPathName, including a copy with the same file name in another directory.
        n.doc = op.path;
        const r = n.python(a, .{ .kind = .state, .case_id = op.case_id, .profile_id = op.profile_id, .path = op.path, .expect = op.expect }, "doc");
        if (r.status != .ok) {
            n.doc = null;
            return r;
        }
        const v = parseJson(a, r.payload) catch .null;
        const name = strField(v, "document") orelse "";
        if (!eql(basename(name), op.expect)) {
            n.doc = null;
            return .{ .status = .failed, .detail = fmtA(a, "vs.GetFName names `{s}`. The open expected `{s}`", .{ name, op.expect }) };
        }
        n.doc_sha256 = hashFileDup(a, n.io, op.path);
        return r;
    }
};
/// Python bridge that NativeDriver sends. `REQ_PATH = "<request.json>"` comes before it.
pub const bridge_py =
    \\# Rosetta capture bridge revision 4. `vwx rosetta-capture packet` writes this file.
    \\# native_verification: unexecuted. Each vs call is a candidate until a native run records it.
    \\# NativeDriver prepends REQ_PATH = "<request.json>". The program writes `out`, then `done`.
    \\# An exception writes `err`, then `done`.
    \\import hashlib, json, math, os, traceback
    \\import vs
    \\
    \\def _write(path, text):
    \\    f = open(path, 'w', encoding='utf-8')
    \\    try:
    \\        f.write(text)
    \\    finally:
    \\        f.close()
    \\
    \\def _flat(v):
    \\    if isinstance(v, (list, tuple)):
    \\        out = []
    \\        for x in v:
    \\            out.extend(_flat(x))
    \\        return out
    \\    return [v]
    \\
    \\def _num(v):
    \\    return [float(x) for x in _flat(v) if isinstance(x, (int, float)) and not isinstance(x, bool)]
    \\
    \\def _raw(v):
    \\    if isinstance(v, (list, tuple)):
    \\        return [_raw(x) for x in v]
    \\    if isinstance(v, dict):
    \\        return dict((str(k), _raw(x)) for k, x in v.items())
    \\    if isinstance(v, (int, float, str, bool)) or v is None:
    \\        return v
    \\    return repr(v)
    \\
    \\def _nil(h):
    \\    if h is None:
    \\        return True
    \\    try:
    \\        return h == vs.Handle(0)
    \\    except Exception:
    \\        return False
    \\
    \\def _version():
    \\    if hasattr(vs, 'GetVersion'):
    \\        return _raw(vs.GetVersion())
    \\    return None
    \\
    \\def op_preflight(req):
    \\    apis = {}
    \\    for name in req['payload'].get('apis', []):
    \\        apis[name] = name.startswith('vs.') and hasattr(vs, name[3:])
    \\    return {'schema': 'vwx-rosetta-capabilities/1', 'driver': 'native', 'apis': apis,
    \\            'can_close': hasattr(vs, 'CloseDocument'), 'raw_version': _version(),
    \\            'release': {'version': None, 'build': None, 'edition': None, 'platform': None,
    \\                        'verification': 'unverified'}}
    \\
    \\def op_doc(req):
    \\    return {'document': vs.GetFName(), 'path': vs.GetFPathName()}
    \\
    \\def op_run_script(req):
    \\    cp_dir = req['payload']['checkpoint_dir']
    \\    cps = []
    \\    reached = {'value': False}
    \\    def rosetta_checkpoint(cid):
    \\        path = os.path.join(cp_dir, 'checkpoint-%s.vwx' % cid)
    \\        vs.SaveActiveDocument(path)
    \\        cps.append({'id': cid, 'path': path})
    \\    def rosetta_save_reopen():
    \\        reached['value'] = True
    \\    deps = req['payload'].get('dependencies') or {}
    \\    def rosetta_dependency(did):
    \\        d = deps.get(did)
    \\        if d is None:
    \\            raise KeyError('dependency %r is not in the case payload' % (did,))
    \\        f = open(d['path'], 'rb')
    \\        try:
    \\            got = hashlib.sha256(f.read()).hexdigest()
    \\        finally:
    \\            f.close()
    \\        if got != d['sha256']:
    \\            raise ValueError('dependency %r has sha256 %s. The plan sealed %s' % (did, got, d['sha256']))
    \\        return os.path.abspath(d['path'])
    \\    g = {'__name__': '__rosetta_case__', 'vs': vs, 'rosetta_dependency': rosetta_dependency,
    \\         'rosetta_checkpoint': rosetta_checkpoint, 'rosetta_save_reopen': rosetta_save_reopen}
    \\    f = open(req['path'], 'r', encoding='utf-8')
    \\    try:
    \\        src = f.read()
    \\    finally:
    \\        f.close()
    \\    exec(compile(src, req['path'], 'exec'), g)
    \\    return {'checkpoints': cps, 'save_reopen_reached': reached['value']}
    \\
    \\def op_save_as(req):
    \\    vs.SaveActiveDocument(req['path'])
    \\    return {'document': vs.GetFName()}
    \\
    \\def op_close(req):
    \\    vs.CloseDocument()
    \\    return {}
    \\
    \\def _classes():
    \\    out = []
    \\    for i in range(1, vs.ClassNum() + 1):
    \\        name = vs.ClassList(i)
    \\        raw = vs.GetCVis(name)
    \\        out.append({'name': name, 'visible': raw == 0, 'raw_visibility': raw})
    \\    return out
    \\
    \\def _layers():
    \\    out = []
    \\    h = vs.FLayer()
    \\    while not _nil(h):
    \\        raw = vs.GetLVis(h)
    \\        out.append({'name': vs.GetLName(h), 'visible': raw == 0, 'raw_visibility': raw})
    \\        h = vs.NextLayer(h)
    \\    return out
    \\
    \\def _units():
    \\    raw = _raw(vs.GetUnits())
    \\    upi = raw[3] if isinstance(raw, list) and len(raw) > 3 else None
    \\    return {'units_per_inch': upi, 'raw': raw}
    \\
    \\def _origin():
    \\    return _num(vs.GetOrigin())[:2]
    \\
    \\# Read-only preference getters of the document area and volume units, once per query
    \\# (Appendix F selectors 176 and 180 with the marks 178 and 182). Each read stands alone.
    \\def _pref(api, selector):
    \\    r = {'api': api, 'selector': selector}
    \\    fn = getattr(vs, api[3:], None)
    \\    if fn is None:
    \\        r['status'] = 'gap'
    \\        r['reason'] = 'api_absent'
    \\        return r
    \\    try:
    \\        raw = fn(selector)
    \\    except Exception as e:
    \\        r['status'] = 'error'
    \\        r['reason'] = '%s: %s' % (type(e).__name__, e)
    \\        return r
    \\    r['python_type'] = type(raw).__name__
    \\    if isinstance(raw, float) and (raw != raw or raw in (float('inf'), float('-inf'))):
    \\        r['status'] = 'nonfinite'
    \\        r['raw'] = None
    \\        return r
    \\    r['status'] = 'observed'
    \\    r['raw'] = _raw(raw)
    \\    return r
    \\
    \\def _scalar_units():
    \\    return {'read_only': True, 'prefs': [_pref('vs.GetPrefReal', 176), _pref('vs.GetPrefReal', 180),
    \\                                          _pref('vs.GetPrefString', 178), _pref('vs.GetPrefString', 182)]}
    \\
    \\def op_state(req):
    \\    return {'schema': 'vwx-rosetta-native-state/1', 'classes': _classes(), 'layers': _layers(),
    \\            'units': _units(), 'origin': _origin()}
    \\
    \\def op_apply_state(req):
    \\    ov = req['payload'].get('overrides') or {}
    \\    hc = ov.get('hidden_content')
    \\    if hc == 'show_all':
    \\        for c in _classes():
    \\            vs.ShowClass(c['name'])
    \\        h = vs.FLayer()
    \\        while not _nil(h):
    \\            vs.SetLayerVisibility(h, 0)
    \\            h = vs.NextLayer(h)
    \\    elif hc not in (None, 'as_saved'):
    \\        raise ValueError('hidden_content %r has no apply rule' % hc)
    \\    return {}
    \\
    \\# vs.py names the Get3DInfo return (height, width, depth). The Function Reference remark of
    \\# Get3DInfo says the call returns delta-Y, delta-X and delta-Z in that order. The bounds are
    \\# derived from Get3DCntr and half of each span. Both getter returns stay in the raw record.
    \\def _box3_parts(h):
    \\    c = _num(vs.Get3DCntr(h))[:3]
    \\    info = _num(vs.Get3DInfo(h))[:3]
    \\    dy, dx, dz = info
    \\    box = [c[0] - dx / 2, c[1] - dy / 2, c[2] - dz / 2, c[0] + dx / 2, c[1] + dy / 2, c[2] + dz / 2]
    \\    return box, c, info
    \\
    \\def _box3(h):
    \\    return _box3_parts(h)[0]
    \\
    \\def _box3_info(h):
    \\    box, c, info = _box3_parts(h)
    \\    return _R({'derived': True, 'get3dcntr': _raw(c), 'get3dinfo': _raw(info), 'get3dinfo_order': 'dy,dx,dz'}, value=box)
    \\
    \\def _bbox(h):
    \\    p = _num(vs.GetBBox(h))
    \\    z0 = z1 = 0.0
    \\    try:
    \\        b = _box3(h)
    \\        z0, z1 = b[2], b[5]
    \\    except Exception:
    \\        pass
    \\    return [min(p[0], p[2]), min(p[1], p[3]), z0, max(p[0], p[2]), max(p[1], p[3]), z1]
    \\
    \\# GetEntityMatrix gives (ok, offset, rotX, rotY, rotZ). The native-prep b5023a0e Frames rules
    \\# compose a matrix only for rotX = 0, rotY = 0, no flip and symbol scale type 1.
    \\# Get3DOrientation refuses composition only when it returns ok with the flip flag set.
    \\def _matrix(h):
    \\    e = vs.GetEntityMatrix(h)
    \\    if e[0] is not True:
    \\        raise ValueError('GetEntityMatrix returned %r' % (e[0],))
    \\    r = _num(e[1:])
    \\    if len(r) != 6:
    \\        raise ValueError('GetEntityMatrix gave %d numbers' % len(r))
    \\    raw = {'entity_matrix': _raw(e)}
    \\    def refuse(why):
    \\        return _R(raw, status='unresolved_transform', reason=why)
    \\    if r[3] != 0 or r[4] != 0:
    \\        return refuse('rotX %r and rotY %r have no verified composition' % (r[3], r[4]))
    \\    o = vs.Get3DOrientation(h)
    \\    raw['orientation'] = _raw(o)
    \\    if o[0] is True and o[4] is True:
    \\        return refuse('Get3DOrientation reports a flip')
    \\    if vs.GetTypeN(h) == 15:
    \\        st = vs.GetObjectVariableInt(h, 101)
    \\        raw['scale_type'] = _raw(st)
    \\        if st != 1:
    \\            return refuse('symbol scale type %r has no verified composition' % (st,))
    \\    x, y, z, az = r[0], r[1], r[2], math.radians(r[5])
    \\    cz, sz = math.cos(az), math.sin(az)
    \\    return _R(raw, [cz, -sz, 0.0, x, sz, cz, 0.0, y, 0.0, 0.0, 1.0, z, 0, 0, 0, 1])
    \\
    \\def _named(v):
    \\    if v[0] is not True:
    \\        raise ValueError('call returned %r' % (v[0],))
    \\    return v[1]
    \\
    \\def _members(h):
    \\    n = 0
    \\    m = vs.FInGroup(h)
    \\    while not _nil(m):
    \\        n += 1
    \\        m = vs.NextObj(m)
    \\    return n
    \\
    \\def _unit(v):
    \\    n = math.sqrt(sum(x * x for x in v))
    \\    if n == 0:
    \\        raise ValueError('zero vector %r' % (v,))
    \\    return [x / n for x in v]
    \\
    \\# GetWorkingPlaneN gives the center, the normal and the u vector of the active working plane.
    \\def _wplane(h):
    \\    r = _num(vs.GetWorkingPlaneN())
    \\    if len(r) != 9:
    \\        raise ValueError('GetWorkingPlaneN gave %d numbers' % len(r))
    \\    c, z, x = r[0:3], _unit(r[3:6]), _unit(r[6:9])
    \\    if abs(sum(z[i] * x[i] for i in range(3))) > 1e-9:
    \\        raise ValueError('uVec is not orthogonal to the normal')
    \\    y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]]
    \\    return [x[0], y[0], z[0], c[0], x[1], y[1], z[1], c[1], x[2], y[2], z[2], c[2], 0, 0, 0, 1]
    \\
    \\def _knots(h):
    \\    return [float(vs.NurbsKnot(h, 0, i)) for i in range(vs.NurbsNumKnots(h, 0))]
    \\
    \\COLLECT = {
    \\    ('vs.ClassNum', 'count'): lambda h: vs.ClassNum(),
    \\    ('vs.FInGroup', 'count'): _members,
    \\    ('vs.Count', 'count'): lambda h: vs.Count('(ALL)'),
    \\    ('vs.Get3DCntr', 'point3'): lambda h: _num(vs.Get3DCntr(h))[:3],
    \\    ('vs.Get3DInfo', 'bounds3'): _box3_info,
    \\    ('vs.GetBBox', 'bounds3'): _bbox,
    \\    ('vs.GetClass', 'class_name'): lambda h: vs.GetClass(h),
    \\    ('vs.GetDimText', 'name'): lambda h: vs.GetDimText(h),
    \\    ('vs.GetEntityMatrix', 'transform4x4'): _matrix,
    \\    ('vs.GetFName', 'name'): lambda h: vs.GetFName(),
    \\    ('vs.GetLName', 'layer_name'): lambda h: vs.GetLName(h),
    \\    ('vs.GetLayerElevation', 'length'): lambda h: float(vs.GetLayerElevation(h)[0]),
    \\    ('vs.GetLocPt', 'point3'): lambda h: _num(vs.GetLocPt(h))[:2] + [0.0],
    \\    ('vs.GetLocus3D', 'point3'): lambda h: _num(vs.GetLocus3D(h))[:3],
    \\    ('vs.GetMeshVertsCnt', 'count'): lambda h: vs.GetMeshVertsCnt(h),
    \\    ('vs.GetName', 'name'): lambda h: vs.GetName(h),
    \\    ('vs.GetObjMaterialName', 'name'): lambda h: _named(vs.GetObjMaterialName(h)),
    \\    ('vs.GetOrigin', 'point3'): lambda h: _origin() + [0.0],
    \\    ('vs.GetPolyPt', 'point3'): lambda h: _num(vs.GetPolyPt(h, 1))[:2] + [0.0],
    \\    ('vs.GetPolyPt3D', 'point3'): lambda h: _num(vs.GetPolyPt3D(h, 0))[:3],
    \\    ('vs.GetSegPt1', 'point3'): lambda h: _num(vs.GetSegPt1(h))[:2] + [0.0],
    \\    ('vs.GetSegPt2', 'point3'): lambda h: _num(vs.GetSegPt2(h))[:2] + [0.0],
    \\    ('vs.GetSymLoc3D', 'point3'): lambda h: _num(vs.GetSymLoc3D(h))[:3],
    \\    ('vs.GetSymName', 'name'): lambda h: vs.GetSymName(h),
    \\    ('vs.GetSymRot', 'angle'): lambda h: float(vs.GetSymRot(h)),
    \\    ('vs.GetText', 'name'): lambda h: vs.GetText(h),
    \\    ('vs.GetTypeN', 'topology_counts'): lambda h: {'type_code': vs.GetTypeN(h)},
    \\    ('vs.GetVectorFill', 'name'): lambda h: _named(vs.GetVectorFill(h)),
    \\    ('vs.GetVPCropObject', 'count'): lambda h: 0 if _nil(vs.GetVPCropObject(h)) else 1,
    \\    ('vs.GetVertNum', 'count'): lambda h: vs.GetVertNum(h),
    \\    ('vs.GetWorkingPlaneN', 'transform4x4'): _wplane,
    \\    ('vs.HCenter', 'point3'): lambda h: _num(vs.HCenter(h))[:2] + [0.0],
    \\    ('vs.HHeight', 'length'): lambda h: float(vs.HHeight(h)),
    \\    ('vs.HLength', 'length'): lambda h: float(vs.HLength(h)),
    \\    ('vs.HWidth', 'length'): lambda h: float(vs.HWidth(h)),
    \\    ('vs.NurbsCurveEvalPt', 'domain'): lambda h: [_knots(h)[0], _knots(h)[-1]],
    \\    ('vs.NurbsDegree', 'count'): lambda h: vs.NurbsDegree(h, 0),
    \\    ('vs.NurbsGetPt3D', 'control_points'): lambda h: [_num(vs.NurbsGetPt3D(h, 0, i))[:3] for i in range(vs.NurbsGetNumPts(h, 0))],
    \\    ('vs.NurbsGetWeight', 'weights'): lambda h: [float(vs.NurbsGetWeight(h, 0, i)) for i in range(vs.NurbsGetNumPts(h, 0))],
    \\    ('vs.NurbsKnot', 'knots'): _knots,
    \\    ('vs.NumRecords', 'count'): lambda h: vs.NumRecords(h),
    \\    ('vs.ObjArea', 'area'): lambda h: float(vs.ObjArea(h)),
    \\    ('vs.ObjSurfaceArea', 'area'): lambda h: float(vs.ObjSurfaceArea(h)),
    \\    ('vs.ObjVolume', 'volume'): lambda h: float(vs.ObjVolume(h)),
    \\}
    \\
    \\class _R(object):
    \\    # One collector return. `raw` is the call return. A status other than ok keeps no value.
    \\    def __init__(self, raw, value=None, status='ok', reason=None):
    \\        self.raw, self.value, self.status, self.reason = raw, value, status, reason
    \\
    \\class _Status(Exception):
    \\    def __init__(self, status, reason):
    \\        Exception.__init__(self, reason)
    \\        self.status, self.reason = status, reason
    \\
    \\# {"handle": "object"} is the query object. {"handle": "layer", "name": n} is GetLayerByName(n).
    \\def _args(q, h):
    \\    out = []
    \\    for x in q.get('args') or []:
    \\        if isinstance(x, dict) and x.get('handle') == 'object':
    \\            out.append(h)
    \\        elif isinstance(x, dict) and x.get('handle') == 'layer':
    \\            lh = vs.GetLayerByName(x['name'])
    \\            if _nil(lh):
    \\                raise _Status('layer_not_found', 'GetLayerByName(%r) returned a nil handle' % (x['name'],))
    \\            out.append(lh)
    \\        else:
    \\            out.append(x)
    \\    return out
    \\
    \\# VWClass.h:15-19 gives code 0 visible and -1 hidden.
    \\def _cvis(h, a):
    \\    raw = vs.GetCVis(a[0])
    \\    if raw == 0:
    \\        return _R(raw, True)
    \\    if raw == -1:
    \\        return _R(raw, False)
    \\    return _R(raw, status='unmapped_code', reason='GetCVis code %r has no visibility mapping' % (raw,))
    \\
    \\def _part(fn, i):
    \\    def get(h, a):
    \\        raw = fn(h)
    \\        return _R(raw, float(raw[i]))
    \\    return get
    \\
    \\def _gis_angle(h, a):
    \\    raw = vs.GetGISOriginN()
    \\    if raw[0] is not True:
    \\        return _R(raw, status='gis_origin_unset', reason='GetGISOriginN returned %r' % (raw[0],))
    \\    return _R(raw, float(raw[3]))
    \\
    \\def _vp_layer(h, a):
    \\    return _R(vs.GetVPLayerVisibility(*a), status='raw_only', reason='no accepted source maps the visibilityType codes of GetVPLayerVisibility')
    \\
    \\def _north(h, a):
    \\    raw = vs.GetAngleToNorth()
    \\    return _R(raw, float(raw))
    \\
    \\# Collectors that take query arguments or write a component. The key ends with the component.
    \\PARTS = {
    \\    ('vs.GetAngleToNorth', 'angle', 'document.angle_to_north'): _north,
    \\    ('vs.GetArc', 'angle', 'arc.start_angle'): _part(lambda h: vs.GetArc(h), 0),
    \\    ('vs.GetArc', 'angle', 'arc.sweep_angle'): _part(lambda h: vs.GetArc(h), 1),
    \\    ('vs.GetCVis', 'visibility', ''): _cvis,
    \\    ('vs.GetGISOriginN', 'angle', 'gis.angle_to_north'): _gis_angle,
    \\    ('vs.GetRField', 'name', ''): lambda h, a: vs.GetRField(*a),
    \\    ('vs.GetRRDiam', 'length', 'rrect.diam.x'): _part(lambda h: vs.GetRRDiam(h), 0),
    \\    ('vs.GetRRDiam', 'length', 'rrect.diam.y'): _part(lambda h: vs.GetRRDiam(h), 1),
    \\    ('vs.GetVPLayerVisibility', 'visibility', ''): _vp_layer,
    \\    ('vs.GetWSCellString', 'name', ''): lambda h, a: vs.GetWSCellString(*a),
    \\}
    \\
    \\# Raw returns of refused queries. RAW is the complete allowlist of raw-only calls.
    \\# The arity follows vs.py:18998, 13724, 19456 and 19649.
    \\RAW = {
    \\    'GetTextStyleRef': lambda h: vs.GetTextStyleRef(h),
    \\    'GetGISOriginN': lambda h: vs.GetGISOriginN(),
    \\    'GetUnits': lambda h: vs.GetUnits(),
    \\    'GetView': lambda h: vs.GetView(),
    \\}
    \\
    \\def op_query(req):
    \\    results = []
    \\    objects = {}
    \\    for q in req['payload'].get('queries', []):
    \\        r = dict(q)
    \\        c = q.get('collector') or {}
    \\        oid = q['object_id']
    \\        h = None
    \\        if oid != 'document':
    \\            h = vs.GetObject(oid)
    \\        found = oid == 'document' or not _nil(h)
    \\        objects[oid] = {'found': found, 'type': 'document' if oid == 'document' else (vs.GetTypeN(h) if found else None)}
    \\        fn = PARTS.get((q['api'], q.get('quantity'), c.get('part', '')))
    \\        if fn is None and c.get('part', '') == '' and not q.get('args'):
    \\            one = COLLECT.get((q['api'], q.get('quantity')))
    \\            if one is not None:
    \\                fn = lambda h, a, one=one: one(h)
    \\        if not hasattr(vs, q['api'][3:]):
    \\            r['status'] = 'api_absent'
    \\        elif c.get('status'):
    \\            r['status'] = c['status']
    \\            r['reason'] = c.get('detail')
    \\            raw = RAW.get(c.get('raw_call'))
    \\            if c.get('raw_call') is not None and raw is None:
    \\                r['status'] = 'raw_call_unlisted'
    \\            elif raw is not None and not found:
    \\                r['status'] = 'not_found'
    \\            elif raw is not None:
    \\                try:
    \\                    r['raw'] = _raw(raw(h))
    \\                except Exception as e:
    \\                    r['raw_error'] = '%s: %s' % (type(e).__name__, e)
    \\        elif not found:
    \\            r['status'] = 'not_found'
    \\        elif fn is None:
    \\            r['status'] = 'collector_unimplemented'
    \\        else:
    \\            try:
    \\                v = fn(h, _args(q, h))
    \\                if isinstance(v, _R):
    \\                    r['raw'] = _raw(v.raw)
    \\                    r['status'] = v.status
    \\                    if v.status == 'ok':
    \\                        r['value'] = _raw(v.value)
    \\                    else:
    \\                        r['reason'] = v.reason
    \\                else:
    \\                    v = _raw(v)
    \\                    r['status'] = 'ok'
    \\                    r['value'] = v
    \\                    r['raw'] = v
    \\                if r['status'] == 'ok' and q.get('quantity') == 'control_points':
    \\                    r['point_convention'] = 'cartesian'
    \\            except _Status as e:
    \\                r['status'] = e.status
    \\                r['reason'] = e.reason
    \\            except Exception as e:
    \\                r['status'] = 'error'
    \\                r['error'] = '%s: %s' % (type(e).__name__, e)
    \\        results.append(r)
    \\    return {'schema': 'vwx-rosetta-native-query/1', 'driver': 'native', 'document': vs.GetFName(),
    \\            'api_version': _version(), 'units': _units(), 'origin': _origin(),
    \\            'scalar_units': _scalar_units(), 'objects': objects, 'results': results}
    \\
    \\def op_export(req):
    \\    p = req['payload']
    \\    fn = getattr(vs, p['api'][3:])
    \\    return {'return': _raw(fn(*p['args']))}
    \\
    \\# Runs the frozen native-prep collector. It reads globals OUT and SPEC and writes
    \\# vwx-m3d-native-raw/1 rows to OUT. The collector calls query functions only.
    \\def op_collect(req):
    \\    p = req['payload']
    \\    f = open(req['path'], 'rb')
    \\    try:
    \\        src = f.read()
    \\    finally:
    \\        f.close()
    \\    have = hashlib.sha256(src).hexdigest()
    \\    if have != p['script_sha256']:
    \\        raise ValueError('collector SHA256 %s differs from the queue %s' % (have, p['script_sha256']))
    \\    g = {'__name__': '__rosetta_collect__', 'vs': vs, 'OUT': p['out'], 'SPEC': p['spec']}
    \\    exec(compile(src.decode('utf-8'), req['path'], 'exec'), g)
    \\    last = None
    \\    f = open(p['out'], 'r', encoding='utf-8')
    \\    try:
    \\        for line in f:
    \\            if line.strip():
    \\                last = line
    \\    finally:
    \\        f.close()
    \\    return {'end': json.loads(last) if last else None}
    \\
    \\def _same(x, y):
    \\    return os.path.normcase(os.path.realpath(x)) == os.path.normcase(os.path.realpath(y))
    \\
    \\# Returns the allowed path of the active document. vs.GetFName and vs.GetFPathName must name
    \\# one path of `allowed` or a file in `allowed_dir`. A new unsaved document has no path.
    \\def _active(allowed, allowed_dir):
    \\    name = vs.GetFName()
    \\    path = vs.GetFPathName()
    \\    if not isinstance(path, str) or not path:
    \\        raise RuntimeError('vs.GetFPathName returns %r. Only a saved session copy is accepted' % (path,))
    \\    for want in allowed:
    \\        if name == os.path.basename(want) and _same(path, want):
    \\            return want
    \\    if allowed_dir and name == os.path.basename(path) and _same(os.path.dirname(path), allowed_dir):
    \\        return os.path.join(allowed_dir, name)
    \\    raise RuntimeError('the active document is %r at %r. The request accepts %r' % (name, path, allowed))
    \\
    \\OPS = {'preflight': op_preflight, 'doc': op_doc, 'run_script': op_run_script, 'save_as': op_save_as,
    \\       'close': op_close, 'state': op_state, 'apply_state': op_apply_state, 'query': op_query,
    \\       'export': op_export, 'collect': op_collect}
    \\
    \\def _main():
    \\    f = open(REQ_PATH, 'r', encoding='utf-8')
    \\    try:
    \\        req = json.load(f)
    \\    finally:
    \\        f.close()
    \\    try:
    \\        op = req['op']
    \\        if op != 'preflight':
    \\            want = req.get('document')
    \\            if not want:
    \\                raise RuntimeError('the request names no session document')
    \\            _active([want], None)
    \\        result = OPS[op](req)
    \\        if op not in ('preflight', 'close'):
    \\            now = _active([want] + list(req.get('after_paths') or []), req.get('after_dir'))
    \\            _write(req['active'], json.dumps({'path': now}))
    \\        _write(req['out'], json.dumps(result, allow_nan=False))
    \\    except Exception:
    \\        _write(req['err'], traceback.format_exc())
    \\    _write(req['done'], 'done\n')
    \\
    \\_main()
    \\
;

/// Reads that `bridge_py` lacks. The strict driver sends `bridgeProgram` for the `state_ext`
/// operation. Every value carries a status. An API that the app lacks is a recorded gap and never
/// an invented value. `vs.Projection` is a setter in SDK2026, so the projection is a gap by design.
/// native_verification: unexecuted.
pub const bridge_ext_py =
    \\# Extended state reads. Each entry holds a status. A missing API is a gap.
    \\def _obs(fn):
    \\    try:
    \\        return {'status': 'observed', 'value': _raw(fn())}
    \\    except AttributeError as e:
    \\        return {'status': 'gap', 'reason': 'api_absent', 'detail': str(e)}
    \\    except Exception as e:
    \\        return {'status': 'error', 'reason': '%s: %s' % (type(e).__name__, e)}
    \\
    \\def op_state_ext(req):
    \\    base = op_state(req)
    \\    sel = _obs(lambda: vs.NumSelectedObjects())
    \\    ext = {'selection_count': sel,
    \\           'active_layer': _obs(lambda: vs.GetLName(vs.ActLayer())),
    \\           'active_class': _obs(lambda: vs.ActiveClass()),
    \\           'view': _obs(lambda: vs.GetView()),
    \\           'render_mode': _obs(lambda: vs.GetLayerRenderMode(vs.ActLayer())),
    \\           'projection': {'status': 'gap', 'reason': 'no_getter',
    \\                          'detail': 'SDK2026 vs.py declares vs.Projection as a setter only'}}
    \\    if sel['status'] == 'observed':
    \\        ext['scope'] = {'status': 'observed', 'value': 'selected' if sel['value'] else 'document'}
    \\    else:
    \\        ext['scope'] = {'status': 'gap', 'reason': 'selection_unobserved'}
    \\    base['ext'] = ext
    \\    return base
    \\
    \\OPS['state_ext'] = op_state_ext
    \\
;

const bridge_tail = "\n_main()\n";

/// `bridge_py` for every operation except `state_ext`. For `state_ext` the extension comes before
/// the final `_main()` call. `bridge_py` itself stays byte-equal to the committed packet.
pub fn bridgeProgram(a: Allocator, op_name: []const u8) []const u8 {
    if (!eql(op_name, "state_ext")) return bridge_py;
    if (!std.mem.endsWith(u8, bridge_py, bridge_tail)) return bridge_py;
    return std.mem.concat(a, u8, &.{ bridge_py[0 .. bridge_py.len - bridge_tail.len + 1], bridge_ext_py, bridge_tail[1..] }) catch bridge_py;
}
// ---------------------------------------------------------------------------
// export entries and capability checklist
// ---------------------------------------------------------------------------

/// Documented scripting export entries. The SAT entry quotes the purpose of profile sat.solids.
pub const default_entries =
    \\{
    \\  "schema": "vwx-rosetta-export-entries/1",
    \\  "native_verification": "unexecuted",
    \\  "entries": [
    \\    {
    \\      "format": "sat",
    \\      "api": "vs.ExportSAT",
    \\      "args": ["$path", "$opt:solid_as_surface"],
    \\      "verification": "unverified",
    \\      "source": "inventory 4637e7db profiles/sat.solids.json purpose: vs.ExportSAT(filePath, solidAsSurface=False)."
    \\    },
    \\    {
    \\      "format": "stl",
    \\      "api": "vs.ExportSTL",
    \\      "args": ["$path", "$opt:binary", "$opt:percent_tess", "$opt:objects"],
    \\      "verification": "unverified",
    \\      "source": "SDK2026 vs.py:9353 parameters filePath, exportBinary, percentTess, exportObjectsOptions."
    \\    },
    \\    {
    \\      "format": "ifc",
    \\      "api": "vs.IFC_ExportNoUI",
    \\      "args": ["$path"],
    \\      "verification": "unverified",
    \\      "source": "SDK2026 vs.py:23433 parameter strFullFilePath. The IFC schema and MVD come from the document IFC settings."
    \\    }
    \\  ]
    \\}
    \\
;

pub const FormatFamily = struct { format: []const u8, family: []const u8, check: []const u8 };

/// Manual checks for formats without a verified scripting entry. Each stays unexecuted.
pub const format_checks = [_]FormatFamily{
    .{ .format = "dwg", .family = "drawing", .check = "File > Export > Export DWG/DXF/DWF. Record the dialog fields, the DWG version list and whether classes export as layers." },
    .{ .format = "dxf", .family = "drawing", .check = "File > Export > Export DWG/DXF/DWF with DXF selected. Record the DXF version list and the 3D conversion choices." },
    .{ .format = "parasolid", .family = "solid", .check = "File > Export > Export Parasolid. Record the schema version list. Search the function reference for a Parasolid export call." },
    .{ .format = "sat", .family = "solid", .check = "Run vs.ExportSAT(path, False) on a document with one extrude. Record the return value and the SAT header version." },
    .{ .format = "stl", .family = "mesh", .check = "Run vs.ExportSTL(path, True, percentTess, exportObjectsOptions) after the operator records the tessellation percent range and the exportObjectsOptions codes from File > Export > Export STL." },
    .{ .format = "obj", .family = "mesh", .check = "File > Export > Export OBJ. Record the material option and the units of the written vertices." },
    .{ .format = "gltf", .family = "mesh", .check = "File > Export > Export glTF. Record GLB or glTF output and the texture option." },
    .{ .format = "fbx", .family = "mesh", .check = "File > Export > Export FBX. Record the FBX version list." },
    .{ .format = "3ds", .family = "mesh", .check = "File > Export > Export 3DS. Record the dialog fields." },
    .{ .format = "pdf", .family = "drawing", .check = "File > Export > Export PDF. Record the resolution field and the classes-as-layers option." },
    .{ .format = "svg", .family = "drawing", .check = "Search the export menu for SVG. Record the menu item or its absence." },
    .{ .format = "png", .family = "image", .check = "File > Export > Export Image File. Record width, height, view, render mode and the orientation of the written image." },
    .{ .format = "jpeg", .family = "image", .check = "File > Export > Export Image File with JPEG. Record the quality field." },
    .{ .format = "ifc", .family = "semantic", .check = "Run vs.IFC_ExportNoUI(path) on a document with one wall. Record the return value, the FILE_SCHEMA line and the document IFC settings that set it." },
    .{ .format = "csv", .family = "semantic", .check = "Export a worksheet as CSV. Record the delimiter and the encoding." },
    .{ .format = "xlsx", .family = "semantic", .check = "Search the worksheet export menu for Excel output. Record the menu item or its absence." },
};

pub fn formatCheck(format: []const u8) ?[]const u8 {
    for (format_checks) |fc| {
        if (eql(fc.format, format)) return fc.check;
    }
    return null;
}

/// The operator step of a format without a scripting entry. The menu text is a candidate. No
/// local native reference shows it. `keep_state` holds for generated cases, where the run
/// compares the state after the export with native-state.json.
pub fn operatorStep(a: Allocator, prof: *const Profile, keep_state: bool) ?[]const u8 {
    const check = formatCheck(prof.format) orelse return null;
    const opts = stringifyLine(a, prof.options);
    const tail = if (keep_state)
        "Keep the document open. Keep class and layer visibility unchanged."
    else
        "Set the view and the layers that the options name. Keep the document open. Close no document.";
    return fmtA(a, "Export profile {s} by hand to the printed path with the options {s}. Candidate menu, unverified: {s} Write each dialog field and its value to the printed path plus .dialog.txt. {s}", .{ prof.profile_id, opts, check, tail });
}

/// The capability checklist. With a preflight file it adds the API probe result of each entry.
pub fn capabilities(a: Allocator, entries: []const Entry, preflight: ?json.Value) json.Value {
    const apis = if (preflight) |p| field(p, "apis") orelse .null else .null;
    var list = arr(a);
    for (format_checks) |fc| {
        var o = Obj.init(a);
        o.str("format", fc.format);
        o.str("family", fc.family);
        if (findEntry(entries, fc.format)) |e| {
            o.str("entry_api", e.api);
            o.str("entry_verification", e.verification);
            const probe = field(apis, e.api);
            o.str("probe", if (probe == null) "not_probed" else if (probe.? == .bool and probe.?.bool) "present_unverified" else "absent");
        } else {
            o.put("entry_api", .null);
            o.str("entry_verification", "no_documented_entry");
            o.str("probe", "not_probed");
        }
        o.str("manual_check", fc.check);
        o.str("state", "unexecuted");
        list.append(o.value()) catch {};
    }
    var root = Obj.init(a);
    root.str("schema", schema_capabilities);
    root.str("native_verification", "unexecuted");
    root.put("formats", .{ .array = list });
    var bridge = arr(a);
    for (bridge_apis) |x| bridge.append(.{ .string = x }) catch {};
    root.put("bridge_apis", .{ .array = bridge });
    return root.value();
}

/// Writes bridge.py, export-entries.json and capabilities.json into a new directory.
pub fn packet(a: Allocator, io: Io, d: *Diags, dir: []const u8, out: *Io.Writer) !void {
    if (exists(io, dir)) {
        d.err("output_exists", dir, "packet writes a new directory only", .{});
        return;
    }
    try mkdirp(io, dir);
    const entries = parseEntries(a, d, default_entries, "default entries");
    const files = [_]struct { []const u8, []const u8 }{
        .{ "bridge.py", bridge_py },
        .{ "export-entries.json", default_entries },
        .{ "capabilities.json", stringify(a, capabilities(a, entries, null)) },
    };
    for (files) |f| {
        try writeNew(io, fmtA(a, "{s}/{s}", .{ dir, f[0] }), f[1]);
        try out.print("wrote\t{s}\t{s}\n", .{ f[0], &sha256Hex(f[1]) });
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// readiness
// ---------------------------------------------------------------------------

pub const schema_readiness = "vwx-rosetta-capture-readiness/1";

/// One `def` of the SDK vs.py. `extra` counts the numbers that POINT, POINT3D and VECTOR
/// parameters add when a call passes their coordinates one by one.
pub const VsDef = struct { line: usize, params: u32, extra: u32 };

pub const VsPy = struct {
    defs: std.StringHashMapUnmanaged(VsDef) = .empty,
    count: usize = 0,

    pub fn get(v: *const VsPy, api: []const u8) ?VsDef {
        if (!std.mem.startsWith(u8, api, "vs.")) return null;
        return v.defs.get(api[3..]);
    }
};

/// Reads every `def` of vs.py. Each parameter line holds names before `#` and the type after it.
pub fn parseVsPy(a: Allocator, bytes: []const u8) VsPy {
    var v: VsPy = .{};
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |l| lines.append(a, l) catch {};
    const L = lines.items;
    var i: usize = 0;
    while (i < L.len) : (i += 1) {
        const l = L[i];
        if (!std.mem.startsWith(u8, l, "def ")) continue;
        const open = std.mem.indexOfScalar(u8, l, '(') orelse continue;
        var d: VsDef = .{ .line = i + 1, .params = 0, .extra = 0 };
        if (!std.mem.startsWith(u8, std.mem.trim(u8, l[open + 1 ..], " \t\r"), ")")) {
            var j = i + 1;
            while (j < L.len and !std.mem.startsWith(u8, std.mem.trim(u8, L[j], " \t\r"), ")")) : (j += 1) {
                const hash = std.mem.indexOfScalar(u8, L[j], '#') orelse L[j].len;
                var n: u32 = 0;
                var parts = std.mem.splitScalar(u8, L[j][0..hash], ',');
                while (parts.next()) |x| {
                    if (std.mem.trim(u8, x, " \t\r").len > 0) n += 1;
                }
                d.params += n;
                const ty = std.mem.trim(u8, L[j][@min(hash + 1, L[j].len)..], " \t\r");
                if (n == 1) {
                    if (std.mem.startsWith(u8, ty, "POINT3D") or std.mem.startsWith(u8, ty, "VECTOR")) {
                        d.extra += 2;
                    } else if (std.mem.startsWith(u8, ty, "POINT")) d.extra += 1;
                }
            }
            i = j;
        }
        v.defs.put(a, std.mem.trim(u8, l[4..open], " "), d) catch {};
        v.count += 1;
    }
    return v;
}

/// A verification that needs the licensed app. Readiness rows name these IDs in `check`.
/// The licensed operator runs `steps` in a scratch session. `owner` records the result and runs
/// `revision_step`. readiness.json prepends `licensed_common_stops` to `stop_conditions`.
pub const LicensedCheck = struct {
    id: []const u8,
    priority: u8,
    text: []const u8,
    inputs: []const u8,
    observation: []const u8,
    steps: []const []const u8,
    mutation: []const u8,
    raw_fields: []const []const u8,
    output: []const u8,
    accepted_bounds: []const u8,
    stop_conditions: []const []const u8,
    revision_step: []const u8,
    owner: []const u8,
};

/// readiness.json records the sha256 of this file. A source edit changes the committed matrix.
const capture_source = @embedFile("rosetta_capture.zig");

pub const licensed_common_stops = [_][]const u8{
    "The app crashes or a run exits 3. Record the run output, journal.jsonl and the macOS crash report. Stop the session.",
    "vs.GetFPathName names a document outside the scratch directory of the check. Stop the check and record the path.",
    "A listed call raises an exception that the step does not catch. Record the exception text. Stop the check.",
};

pub const licensed_checks = [_]LicensedCheck{
    .{
        .id = "release",
        .priority = 1,
        .text = "Record the preflight release fields, the build, the edition, the enabled modules and the installed plug-in universal names. Compare them with Help > About.",
        .inputs = "The running licensed app and the preflight file that `run --driver native` writes to the session directory.",
        .observation = "The preflight release fields and the Help > About dialog.",
        .steps = &.{ "Run `run --driver native --stop-on-failure` on the pilot-1 session until preflight completes.", "Open Help > About. Record the release, the build and the edition.", "Record the enabled modules and the installed plug-in universal names from the preflight file." },
        .mutation = "none",
        .raw_fields = &.{ "preflight release fields", "Help > About release", "Help > About build", "Help > About edition", "enabled modules", "plug-in universal names" },
        .output = "licensed/release.txt in the session directory. One line `field<TAB><raw field><TAB><raw value>` for each raw field. A last line `result<TAB><value>` with value `equal` or `differs`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "Each preflight release field equals the Help > About text.",
        .stop_conditions = &.{"A preflight release field differs from Help > About. Stop the session and send both values to the maintainer."},
        .revision_step = "A difference makes rosetta-capture change the preflight bridge call. Equal values keep the bridge.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "document_path",
        .priority = 1,
        .text = "Record the vs.GetFPathName and vs.GetFName returns for a saved document, a reopened document and a new untitled document.",
        .inputs = "The operator template saved as licensed/document_path/a.vwx and a copy at licensed/document_path/b/a.vwx.",
        .observation = "The raw vs.GetFPathName and vs.GetFName returns.",
        .steps = &.{ "Open a.vwx. Record vs.GetFPathName() and vs.GetFName().", "Open b/a.vwx. Record both returns.", "Create a new untitled document. Record both returns. Close it without saving." },
        .mutation = "none",
        .raw_fields = &.{ "vs.GetFPathName return", "vs.GetFName return" },
        .output = "licensed/document_path.txt in the session directory. One line `field<TAB><document><TAB><raw field><TAB><raw value>` for each raw field of the documents `a.vwx`, `b/a.vwx` and `untitled`. A last line `result<TAB><value>` with value `distinct` or `same_path`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "vs.GetFPathName gives the absolute path of the file. The two copies give two different paths. The untitled document gives an empty string.",
        .stop_conditions = &.{"vs.GetFPathName gives the same value for a.vwx and b/a.vwx. Stop the session. The bridge document check needs a distinct path."},
        .revision_step = "A different path form makes rosetta-capture change `_active` in the bridge and the bridge revision.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "export_menu",
        .priority = 1,
        .text = "Open each File > Export item that an operator_step export row names. Record the menu path, every dialog field with its default value and the written file. Write the record to the .dialog.txt path that the run prints.",
        .inputs = "A new copy of cases/<case>/attempt-<n>/source/scratch.vwx for each operator_export row. The rosetta-inventory rows name the formats 3ds, csv, dwg, dxf, fbx, gltf, obj, parasolid, pdf, png, svg and xlsx with the candidate menu of their evidence column. The native-prep rows name the format dwg. Their set_view rows name view Right Isometric with every design layer visible.",
        .observation = "The File > Export menu item, the export dialog fields and the first 256 bytes of the written file for each row. The view name and the visible design layers for each set_view row.",
        .steps = &.{ "Open the scratch copy.", "For a set_view row, set the view and the layers that the row names. Record the view name in the View bar.", "Open the File > Export item that the row evidence names.", "Record every dialog field with its default value.", "Export to the path that the `manual` line prints. Record the file size and the first 256 bytes." },
        .mutation = "The export writes one file to the path that the `manual` line prints.",
        .raw_fields = &.{ "row format or operation", "menu path", "dialog field names", "dialog default values", "written file sha256", "written file size", "written file first 256 bytes", "View bar view name" },
        .output = "The .dialog.txt path and the export path that the run prints. One line `field<TAB><raw field><TAB><raw value>` for each raw field. A last line `result<TAB><value>` with value `written`, `absent` or `header_mismatch`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "The menu item exists and the written file has more than 0 bytes. The first bytes match the row format. fbx starts with `Kaydara FBX Binary` or `; FBX`. gltf starts with `glTF` for GLB output or `{` for glTF text. 3ds starts with bytes 0x4D 0x4D. xlsx starts with `PK`. svg holds `<svg` in the first 256 bytes. parasolid starts with `**` for x_t text or `PS` for x_b binary. dwg starts with `AC10`. dxf starts with `AutoCAD Binary DXF` or holds `SECTION` in the first 256 bytes. pdf starts with `%PDF-`. png starts with the 8 bytes 0x89 0x50 0x4E 0x47 0x0D 0x0A 0x1A 0x0A. obj and csv hold printable ASCII in the first 256 bytes. A set_view row shows Right Isometric in the View bar.",
        .stop_conditions = &.{ "The menu has no item for the format. Record the absence. Continue with the next row.", "The written file has 0 bytes or its first bytes differ from the format bound. Record the first 256 bytes. Continue with the next row." },
        .revision_step = "An absent item makes rosetta-capture mark the profile unavailable for the release. A changed default makes rosetta-capture record the value in the profile options.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "export_entry",
        .priority = 1,
        .text = "Run each scripting export entry once on a one-object document. Record the return value, the written file and its header.",
        .inputs = "A scratch copy of the operator template with one vs.Rect, saved as licensed/export_entry/one.vwx. The export entries in packet/export-entries.json.",
        .observation = "The return value of each export entry and the written file.",
        .steps = &.{ "Open one.vwx.", "Call each export entry with a path under licensed/export_entry/.", "Record the return value, the file size and the first 256 bytes." },
        .mutation = "Each call writes one export file under licensed/export_entry/.",
        .raw_fields = &.{ "entry return value", "written file size", "written file first 256 bytes" },
        .output = "licensed/export_entry.txt in the session directory. One line `field<TAB><entry><TAB><raw field><TAB><raw value>` for each raw field of each entry. One line `result<TAB><entry><TAB><value>` for each entry with value `written`, `dialog` or `header_mismatch`, or a last line `stop<TAB><stop condition>`.",
        .accepted_bounds = "The call returns without a dialog and the file starts with the format header of the entry.",
        .stop_conditions = &.{"The call opens a dialog. Cancel the dialog. Record the dialog title. Stop the entry."},
        .revision_step = "A dialog or a wrong header makes rosetta-capture move the profile to the manual export step.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "entity_matrix_order",
        .priority = 1,
        .text = "Place a symbol with rotX, rotZ, a non-uniform scale and a mirror. Compare GetEntityMatrix and Get3DOrientation with the placed transform. Record the values for a nonzero rotY.",
        .inputs = "A scratch document in millimetres with one symbol definition holding a 1 x 2 x 3 millimetre extrude. Two instances. Instance a has rotX 30 degrees, rotZ 45 degrees, scale factors (1, 2, 3) and a mirror. Instance b adds rotY 20 degrees.",
        .observation = "The raw vs.GetEntityMatrix and vs.Get3DOrientation returns for each instance.",
        .steps = &.{ "Place the two instances with the transforms of the inputs.", "Call vs.GetEntityMatrix(h) and vs.Get3DOrientation(h) for each instance." },
        .mutation = "The step creates the two instances in the scratch document.",
        .raw_fields = &.{ "vs.GetEntityMatrix return elements", "vs.Get3DOrientation return elements" },
        .output = "licensed/entity_matrix_order.txt in the session directory. One line `field<TAB><instance><TAB><raw field><TAB><raw value>` for each raw field of the instances `a` and `b`. A last line `result<TAB><value>` with value `rz_rx_scale` or `other_order`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "For instance a each element of the 3 x 3 rotation and scale part of the matrix equals Rz * Rx * diag(scale) with the mirror on z within 1e-6. These elements have no unit.",
        .stop_conditions = &.{"vs.GetEntityMatrix returns a false BOOLEAN. Record the return. Stop the check."},
        .revision_step = "A different product order makes rosetta-capture change placementMatrix and the collector entries that cite this check.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "argument_codes",
        .priority = 2,
        .text = "Run each code that a readiness row names on a scratch document. Read the code back with the API of the row. Record the attribute that the code gives.",
        .inputs = "vs.Add2DVertex vertexType 0, 1, 3 and 4 in planar.polygon.from_polyline and planar.polyline.asym. vs.AppendRoofEdge slopeAngle 90 in building.roof.two_edges. vs.NewField fType 4 and 1 in resource.record.attached and ix.mech.repeated-shared-distinct-metadata. vs.SetUnits in control.blank.mm, control.blank.imperial, document.units.imperial, ix.mech.rational-surface-trim-hole-units, ix.planar.18e402f11398, ix.planar.939badf6bd41, ix.planar.b592862becd2 and ix.planar.c16429abac1c. vs.SetVPLayerVisibility visibilityType 0 in annotation.viewport.sheet and ix.mech.viewport-crop-annotation-visibility. vs.CreateLight lightType 2 in spatial.light.point. vs.LinearDim dimType, arrow and textFlag 0 in annotation.dimension.linear.",
        .observation = "The raw readback of each code. vs.GetPolylineVertex (vs.py:17137, 2 parameters, 3 returned values) for vs.Add2DVertex. vs.GetRoofEdge (vs.py:17695, 2 parameters, 5 returned values) for vs.AppendRoofEdge. The record format dialog field type for vs.NewField. vs.GetUnits (vs.py:19456, 0 parameters, 6 returned values) for vs.SetUnits. vs.GetVPLayerVisibility (vs.py:19978, 2 returned values) for vs.SetVPLayerVisibility. vs.GetLightInfo (vs.py:15113, 1 parameter, 4 returned values) for vs.CreateLight. The Object Info palette fields for vs.LinearDim.",
        .steps = &.{ "Run the case of the row through save_reopen in a scratch session.", "Call the readback API of the row for each created object. Record the raw return.", "Record the attribute that the Object Info palette or the owning dialog shows for the code." },
        .mutation = "The step creates the objects of each row case in the scratch document.",
        .raw_fields = &.{ "row API and case", "code value", "readback API raw return", "palette or dialog attribute" },
        .output = "licensed/argument_codes.txt in the session directory. One line `field<TAB><row API><TAB><raw field><TAB><raw value>` for each row and call. A last line `result<TAB><row API><TAB><value>` with value `match` or `differs`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "vs.GetPolylineVertex element 1 equals the vertexType of the recipe vertex at the index base that polyline_vertex.index_base records. vs.GetRoofEdge element 2 is 90 within 1e-6 degrees or 1.570796 within 1e-6 radians. The record format dialog shows Text for fType 4 and Integer for fType 1. Each of the 6 vs.GetUnits elements equals the vs.SetUnits argument at the same position, with upi within 1e-9 units per inch. vs.GetVPLayerVisibility returns True and visibilityType 0. vs.GetLightInfo element 0 is 2 and the palette names a point light. vs.LinearDim returns a handle that is not nil and the palette values for dimType, arrow and textFlag 0 are the record.",
        .stop_conditions = &.{ "The reference gives no code table for the argument. Record the absence. Continue with the next row.", "The readback API returns False or a nil handle. Record the return. Continue with the next row." },
        .revision_step = "Another code makes rosetta-capture send the recipe revision to the queue owner of the case.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "argument_order",
        .priority = 2,
        .text = "Run the recipe calls of each argument_order row. Read every set value back. Record which argument sets which value.",
        .inputs = "vs.NurbsSetPt3D (vs.py:27781, 4 parameters) in nurbs.surface.rational, solid.shell.surface and ix.mech.rational-surface-trim-hole-units. Each recipe call gives the u index, the v index and a 3D point. vs.AddVectorFillLayer (vs.py:622, 9 parameters) in resource.hatch.two_layer. The recipe adds 2 hatch layers with 9 values each.",
        .observation = "The vs.NurbsGetPt3D (vs.py:27692, 3 parameters, 1 returned point) return for each vs.NurbsSetPt3D call with the recipe index order and with the indices swapped. The Edit Hatch dialog values of hatch layers 1 and 2.",
        .steps = &.{ "Run the case of the row through save_reopen in a scratch session.", "For each vs.NurbsSetPt3D(h, i, j, p) call of the recipe, call vs.NurbsGetPt3D(h, i, j) and vs.NurbsGetPt3D(h, j, i). Record both raw returns.", "Open the hatch of resource.hatch.two_layer in the Edit Hatch dialog. Record each field of layers 1 and 2." },
        .mutation = "The step creates the objects of each row case in the scratch document.",
        .raw_fields = &.{ "row API and case", "recipe argument values", "vs.NurbsGetPt3D return for (i, j)", "vs.NurbsGetPt3D return for (j, i)", "Edit Hatch dialog field values" },
        .output = "licensed/argument_order.txt in the session directory. One line `field<TAB><row API><TAB><raw field><TAB><raw value>` for each row and call. A last line `result<TAB><row API><TAB><value>` with value `recipe_order` or `other_order`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "vs.NurbsGetPt3D(h, i, j) returns the recipe point p within 1e-6 millimetres for each recipe call. For i different from j the swapped call returns the recipe point of (j, i) within 1e-6 millimetres. Each Edit Hatch dialog field shows the recipe argument at its vs.py:622 parameter position within 1e-6 in the unit that the dialog field shows.",
        .stop_conditions = &.{ "The call creates no object. Record the return. Continue with the next row.", "vs.NurbsGetPt3D raises an exception. Record the exception text and the indices. Continue with the next call." },
        .revision_step = "Another order makes rosetta-capture send the recipe revision to the queue owner of the case.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "deferred_constructor",
        .priority = 2,
        .text = "Record the installed plug-in universal names and the API that returns the named reference.",
        .inputs = "The readiness rows with check deferred_constructor and the preflight plug-in list. `case_ids` names the cases of those rows. Each case creates its object with vs.CreateCustomObject (vs.py:3203, 3 parameters).",
        .observation = "The universal name of each plug-in object and the handle that vs.CreateCustomObject returns.",
        .steps = &.{ "Record the universal names in the preflight plug-in list.", "Call vs.CreateCustomObject with each name on a scratch document. Record the return." },
        .mutation = "The step creates one plug-in object per name in the scratch document.",
        .raw_fields = &.{ "plug-in universal name", "vs.CreateCustomObject return" },
        .output = "licensed/deferred_constructor.txt in the session directory. One line `field<TAB><case><TAB><raw field><TAB><raw value>` for each raw field of each case in `case_ids`. One line `result<TAB><case><TAB><value>` for each case with value `handle`, `nil` or `absent`, or a last line `stop<TAB><stop condition>`.",
        .accepted_bounds = "The name that the recipe uses is in the plug-in list and the call returns a handle.",
        .stop_conditions = &.{"The plug-in is absent from the release. Record the absence. Continue with the next row."},
        .revision_step = "Another name makes rosetta-capture send the recipe revision to the queue owner of the case. An absent plug-in keeps the case blocked.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "point_arguments_expanded",
        .priority = 2,
        .text = "Run the call with coordinates passed one by one. Compare the object with the call that passes point tuples.",
        .inputs = "vs.Rect (vs.py:30419, 2 parameters) in m3d.fx.event-nested, m3d.fx.multi-lattice, m3d.fx.plane-frame, m3d.fx.repeated-same-extent and m3d.fx.visibility. vs.Oval (vs.py:28613, 2 parameters) in m3d.fx.multi-lattice. A scratch document in millimetres. The calls vs.Rect(12.5, 33.5, 61, 7.25), vs.Rect((12.5, 33.5), (61, 7.25)), vs.Oval(12.5, 33.5, 61, 7.25) and vs.Oval((12.5, 33.5), (61, 7.25)).",
        .observation = "The vs.GetBBox (vs.py:10519, 1 parameter, 2 returned points) return of each of the 4 objects.",
        .steps = &.{ "Run the 4 calls of the inputs on a scratch document.", "Call vs.GetBBox(h) for each object. Record the raw return." },
        .mutation = "The step creates 4 objects in the scratch document.",
        .raw_fields = &.{ "row API", "expanded call return", "tuple call return", "vs.GetBBox return of each object" },
        .output = "licensed/point_arguments_expanded.txt in the session directory. One line `field<TAB><row API><TAB><raw field><TAB><raw value>` for each call. A last line `result<TAB><row API><TAB><value>` with value `equal`, `different` or `type_error`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "For vs.Rect and for vs.Oval the expanded call and the tuple call give vs.GetBBox returns that are equal within 1e-6 millimetres. Their x values are 12.5 and 61 and their y values are 33.5 and 7.25 within 1e-6 millimetres.",
        .stop_conditions = &.{"The expanded call raises a TypeError. Record the text. Continue with the next row."},
        .revision_step = "Different objects or a TypeError make the queue owner of the case change the recipe to point tuples.",
        .owner = "native-prep",
    },
    .{
        .id = "layer_elevation",
        .priority = 2,
        .text = "Set a design layer elevation. Record GetLayerElevation and the Get3DCntr z of an object on that layer.",
        .inputs = "A scratch document in millimetres with design layer L at elevation 250 millimetres and one extrude at z 0 millimetres on L.",
        .observation = "The raw vs.GetLayerElevation return and the vs.Get3DCntr z of the extrude.",
        .steps = &.{ "Set the elevation of L to 250 in the Organization dialog.", "Call vs.GetLayerElevation(layer).", "Call vs.Get3DCntr(h) for the extrude." },
        .mutation = "The step sets one layer elevation in the scratch document.",
        .raw_fields = &.{ "vs.GetLayerElevation return elements", "vs.Get3DCntr return elements" },
        .output = "licensed/layer_elevation.txt in the session directory. One line `field<TAB><raw field><TAB><raw value>` for each raw field. A last line `result<TAB><value>` with value `element_0` or `other_order`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "Element 0 of vs.GetLayerElevation is 250 within 1e-6 millimetres.",
        .stop_conditions = &.{"vs.GetLayerElevation returns fewer than 2 elements. Record the return. Stop the check."},
        .revision_step = "Another element order makes rosetta-capture change the collector entry for vs.GetLayerElevation.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "vertex_index_base",
        .priority = 2,
        .text = "Record the vertex that index 0 and index 1 return for GetPolyPt, GetPolyPt3D and GetMeshVertex.",
        .inputs = "A scratch document in millimetres with a polygon, a 3D polygon and a mesh. Each has first vertex (1, 2, 0) and second vertex (7, 3, 0) in millimetres.",
        .observation = "The raw returns of vs.GetPolyPt, vs.GetPolyPt3D and vs.GetMeshVertex for index 0 and index 1.",
        .steps = &.{ "Create the three objects.", "Call each API with index 0 and index 1." },
        .mutation = "The step creates the three objects in the scratch document.",
        .raw_fields = &.{ "vs.GetPolyPt return for 0 and 1", "vs.GetPolyPt3D return for 0 and 1", "vs.GetMeshVertex return for 0 and 1" },
        .output = "licensed/vertex_index_base.txt in the session directory. One line `field<TAB><API><TAB><index><TAB><raw value>` for index 0 and index 1 of each API. One line `result<TAB><API><TAB><value>` for each API with value `0_based`, `1_based` or `unknown`, or a last line `stop<TAB><stop condition>`.",
        .accepted_bounds = "Index 1 returns (1, 2, 0) within 1e-6 millimetres for a 1-based API. Index 0 returns (1, 2, 0) within 1e-6 millimetres for a 0-based API.",
        .stop_conditions = &.{"An API returns neither listed vertex. Record the return. Stop the check."},
        .revision_step = "A 0-based API makes rosetta-capture change the collector index for that API.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "export_candidate",
        .priority = 3,
        .text = "Run the candidate API on a scratch document. Record whether it opens a dialog, which format it writes and where. Record the internal menu names that vs.DoMenuTextByName accepts for the export items.",
        .inputs = "The one.vwx document of export_entry and the candidate APIs that packet/capabilities.json lists.",
        .observation = "The dialog, the written file and the vs.DoMenuTextByName result for each candidate.",
        .steps = &.{ "Call each candidate API with a path under licensed/export_candidate/.", "Record a dialog title or the written file." },
        .mutation = "Each call writes at most one file under licensed/export_candidate/.",
        .raw_fields = &.{ "candidate return value", "dialog title", "written file path", "written file first 256 bytes" },
        .output = "licensed/export_candidate.txt in the session directory. One line `field<TAB><candidate API><TAB><raw field><TAB><raw value>` for each raw field of each candidate. One line `result<TAB><candidate API><TAB><value>` for each candidate with value `written`, `dialog` or `no_file`, or a last line `stop<TAB><stop condition>`.",
        .accepted_bounds = "A candidate that writes the format without a dialog is an export entry candidate.",
        .stop_conditions = &.{"The call opens a dialog. Cancel the dialog. Record the title. Continue with the next candidate."},
        .revision_step = "A candidate without a dialog makes rosetta-capture propose a new export entry with entry_verification unverified.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "working_plane_axes",
        .priority = 3,
        .text = "Set a tilted working plane. Compare GetWorkingPlaneN with the plane that the recipe set.",
        .inputs = "The recipe of document.working_plane.tilted on a scratch document.",
        .observation = "The raw vs.GetWorkingPlaneN return.",
        .steps = &.{ "Run the recipe of document.working_plane.tilted.", "Call vs.GetWorkingPlaneN()." },
        .mutation = "The recipe sets the working plane of the scratch document.",
        .raw_fields = &.{"vs.GetWorkingPlaneN return elements"},
        .output = "licensed/working_plane_axes.txt in the session directory. One line `field<TAB><raw field><TAB><raw value>` for each raw field. A last line `result<TAB><value>` with value `match` or `differs`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "The center equals the recipe value within 1e-6 in the length unit of the recipe document. Each component of the normal and of uVec equals the recipe value within 1e-6. These components have no unit.",
        .stop_conditions = &.{"A returned vector has length 0. Record the return. Stop the check."},
        .revision_step = "Another element order makes rosetta-capture change the collector entry for vs.GetWorkingPlaneN.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "vp_layer_visibility_code",
        .priority = 3,
        .text = "Set one viewport layer to visible, gray and hidden. Record the GetVPLayerVisibility BOOLEAN and visibilityType for each.",
        .inputs = "A scratch document with design layer L and one sheet layer viewport V that shows L.",
        .observation = "The raw vs.GetVPLayerVisibility return after each setting.",
        .steps = &.{ "Set L to visible in V with the viewport dialog. Call vs.GetVPLayerVisibility(V, L).", "Repeat for gray.", "Repeat for hidden." },
        .mutation = "The step changes the layer visibility of V three times.",
        .raw_fields = &.{ "vs.GetVPLayerVisibility BOOLEAN", "vs.GetVPLayerVisibility visibilityType" },
        .output = "licensed/vp_layer_visibility_code.txt in the session directory. One line `field<TAB><setting><TAB><raw field><TAB><raw value>` for each raw field of the settings `visible`, `gray` and `hidden`. A last line `result<TAB><value>` with value `distinct` or `not_distinct`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "The three settings give three different visibilityType values.",
        .stop_conditions = &.{"vs.GetVPLayerVisibility returns a false BOOLEAN. Record the return. Stop the check."},
        .revision_step = "Three distinct values let rosetta-capture propose a maintainer decision for the code table. The query stays raw_only until the decision.",
        .owner = "rosetta-capture",
    },
    .{
        .id = "unit_undocumented",
        .priority = 3,
        .text = "Read the return of each collector row with an undocumented unit on a document with known values. Record the raw return and its unit.",
        .inputs = "Angle rows: vs.GetAngleToNorth for document.angle_to_north, vs.GetArc element 0 for arc.start_angle, vs.GetArc element 1 for arc.sweep_angle and vs.GetGISOriginN element 3 for gis.angle_to_north. Length rows: vs.GetRRDiam element 0 for rrect.diam.x and element 1 for rrect.diam.y. The planar.arc.asym recipe gives start 17.5 and sweep 233.25. The planar.rrect.asym recipe gives Diam (6.5, 4.25) in a millimetre document. The document.georeference.epsg copy of angle_to_north.unit sets the angle to north to 30 degrees.",
        .observation = "The raw return of each row API.",
        .steps = &.{ "Run planar.arc.asym, planar.rrect.asym and document.georeference.epsg through save_reopen in a scratch session.", "In a copy of the document.georeference.epsg document, set the angle to north to 30 degrees in the georeferencing settings.", "Call vs.GetArc(h), vs.GetRRDiam(h), vs.GetAngleToNorth() and vs.GetGISOriginN(). Record each raw return." },
        .mutation = "The step sets the angle to north in one scratch copy.",
        .raw_fields = &.{ "row API and component", "row API return" },
        .output = "licensed/unit_undocumented.txt in the session directory. One line `field<TAB><component><TAB><raw value>` for each row. A last line `result<TAB><component><TAB><value>` for each row with value `degrees`, `radians`, `millimetres` or `unknown`, or `stop<TAB><stop condition>`.",
        .accepted_bounds = "arc.start_angle is 17.5 within 1e-6 for degrees or 0.305433 within 1e-6 for radians. arc.sweep_angle is 233.25 or -126.75 within 1e-6 for degrees, or 4.07098 or -2.212205 within 1e-6 for radians. document.angle_to_north is 30 within 1e-6 for degrees or 0.523599 within 1e-6 for radians. gis.angle_to_north equals document.angle_to_north within 1e-9 in the unit of document.angle_to_north. rrect.diam.x is 6.5 and rrect.diam.y is 4.25 within 1e-6 for millimetres.",
        .stop_conditions = &.{"The return of a row is neither the degree value nor the radian value for an angle row, or neither the millimetre value nor a known length conversion for a length row. Record the return. Stop the row."},
        .revision_step = "A known conversion makes rosetta-capture record the unit in the collector entry. An unknown unit keeps the query raw-only.",
        .owner = "rosetta-capture",
    },
};

/// A queued (api, quantity) pair that the bridge refuses to collect. An empty `owner` names the
/// queue owner.
/// `raw_call` names a bridge `RAW` entry that records the raw return. Null keeps the raw
/// acquisition missing.
pub const QueryBlocker = struct { api: []const u8, quantity: []const u8, reason: []const u8, detail: []const u8, owner: []const u8 = "", check: []const u8 = "", raw_call: ?[]const u8 = null };

pub const query_blockers = [_]QueryBlocker{
    .{ .api = "vs.GetTypeN", .quantity = "count", .reason = "quantity_mismatch", .detail = "GetTypeN returns an object type code. The collector gives topology_counts.type_code." },
    .{ .api = "vs.GetTextStyleRef", .quantity = "count", .reason = "quantity_mismatch", .detail = "GetTextStyleRef returns a LONGINT style reference. Maintainer proposal decision.quantity.reference. The bridge records the raw return of vs.GetTextStyleRef(h).", .owner = "maintainer", .raw_call = "GetTextStyleRef" },
    .{ .api = "vs.GetView", .quantity = "name", .reason = "quantity_mismatch", .detail = "vs.py:19649 GetView takes 0 parameters and returns 6 values. No accepted source names the fields. The bridge records the raw return of vs.GetView().", .owner = "maintainer", .raw_call = "GetView" },
    .{ .api = "vs.GetGISOriginN", .quantity = "point3", .reason = "quantity_mismatch", .detail = "GetGISOriginN returns a BOOLEAN, a latitude, a longitude and an angle to north. Maintainer proposal decision.quantity.geodetic. The bridge records the raw return of vs.GetGISOriginN().", .owner = "maintainer", .raw_call = "GetGISOriginN" },
    .{ .api = "vs.FSymDef", .quantity = "count", .reason = "count_scope_unspecified", .detail = "FSymDef returns the first symbol definition handle. The query names no folder and no depth for the count." },
    .{ .api = "vs.GetUnits", .quantity = "name", .reason = "component_unspecified", .detail = "GetUnits returns lenUnitMk and areaUnitMk. The query names neither. Maintainer proposal decision.quantity.unit_mark. The bridge records the raw return of vs.GetUnits(). op_state also records it.", .owner = "maintainer", .raw_call = "GetUnits" },
    .{ .api = "vs.GetRRDiam", .quantity = "radius", .reason = "quantity_mismatch", .detail = "GetRRDiam returns xDiam and yDiam. Both are diameters. Collectors read them as length components rrect.diam.x and rrect.diam.y." },
    .{ .api = "vs.GetMeshVertex", .quantity = "point3", .reason = "argument_missing", .detail = "GetMeshVertex takes a vertex index. The query gives none. vs.py gives no index base.", .check = "vertex_index_base" },
    .{ .api = "vs.GetPolylineVertex", .quantity = "control_points", .reason = "argument_missing", .detail = "GetPolylineVertex takes vertexNum. The query gives none. vs.py gives no index base." },
    .{ .api = "vs.NurbsSurfaceEvalPt", .quantity = "control_points", .reason = "argument_missing", .detail = "NurbsSurfaceEvalPt evaluates one point at u and v. The query gives no parameters." },
    .{ .api = "vs.EvaluateNurbsSurfacePointAndNormal", .quantity = "direction3", .reason = "argument_missing", .detail = "EvaluateNurbsSurfacePointAndNormal evaluates at u and v. The query gives no parameters." },
};

/// Scripting calls that vs.py declares for a format without an export entry. Each stays a
/// candidate until a licensed run records its behaviour.
pub const export_candidates = [_]struct { format: []const u8, apis: []const []const u8 }{
    .{ .format = "dwg", .apis = &.{"vs.ExportDXFDWG"} },
    .{ .format = "dxf", .apis = &.{"vs.ExportDXFDWG"} },
    .{ .format = "pdf", .apis = &.{ "vs.OpenPDFDocument", "vs.ExportPDFPages" } },
    .{ .format = "png", .apis = &.{ "vs.CreateImageFromPaint", "vs.ExportImageFile" } },
    .{ .format = "jpeg", .apis = &.{ "vs.CreateImageFromPaint", "vs.ExportImageFile" } },
};

/// The engine route that writes each queued channel. `export_<format>` channels follow their export rows.
pub const channel_routes = [_]struct { []const u8, []const u8 }{
    .{ "recipe", "finalize copies the frozen recipe or collect spec" },
    .{ "recipe_checkpoint", "stage checkpoint-<id> saves recipe/checkpoint-<id>.vwx" },
    .{ "source_original", "stage create saves source/original.vwx. Existing-document cases pin the source digest" },
    .{ "source_reopened", "stage reopen saves source/reopened.vwx" },
    .{ "native_state", "op_state writes native-state.json" },
    .{ "native_objects", "normalize writes native/objects.json from the query or raw rows" },
    .{ "native_measurements", "normalize writes measurements.jsonl from the query or raw rows" },
    .{ "native_query_raw", "op_query writes native/raw/query.json. op_collect writes native/raw/raw.jsonl" },
    .{ "native_frames", "normalize writes native/frames.json" },
    .{ "native_document", "normalize writes native/document.json" },
    .{ "capture_log", "finalize copies the stage records, the script and the outcome" },
    .{ "export_result", "the export stage writes result.json" },
};

const RRow = struct {
    queue: []const u8,
    case_id: []const u8,
    kind: []const u8,
    item: []const u8,
    action: []const u8,
    reason: []const u8,
    check: []const u8,
    owner: []const u8,
    evidence: []const u8,
    /// The creation or query API. Inventory licensed checks match it with the case ID.
    api: []const u8 = "",
};

pub const ReadinessQueue = struct { owner: []const u8, path: []const u8 };

pub const ReadinessOptions = struct {
    vs_py: []const u8,
    inventory_readiness: []const u8,
    out: []const u8,
    queues: []const ReadinessQueue,
};

fn tsvField(a: Allocator, s: []const u8) []const u8 {
    const t = a.dupe(u8, s) catch return s;
    for (t) |*c| {
        if (c.* == '\t' or c.* == '\n' or c.* == '\r') c.* = ' ';
    }
    return t;
}

fn vsCite(a: Allocator, vs: *const VsPy, api: []const u8) []const u8 {
    const d = vs.get(api) orelse return fmtA(a, "{s} absent from vs.py", .{api});
    return fmtA(a, "{s} vs.py:{d} parameter count {d}", .{ api, d.line, d.params });
}

fn familyOf(format: []const u8) []const u8 {
    for (format_checks) |fc| {
        if (eql(fc.format, format)) return fc.family;
    }
    return "none";
}

fn profileOf(v: json.Value) Profile {
    return .{
        .profile_id = strField(v, "profile_id") orelse "",
        .profile_sha256 = strField(v, "profile_sha256") orelse "",
        .format = strField(v, "format") orelse "",
        .path = strField(v, "path"),
        .options = field(v, "options") orelse .null,
        .overrides = field(v, "state_overrides") orelse .null,
    };
}

const Readiness = struct {
    a: Allocator,
    vs: *const VsPy,
    inv: json.Value,
    entries: []const Entry,
    rows: std.ArrayList(RRow) = .empty,

    fn add(r: *Readiness, row0: RRow) void {
        var row = row0;
        if (row.api.len > 0 and eql(row.queue, "rosetta-inventory") and !eql(row.action, "unresolved")) {
            for (arrField(r.inv, "licensed_checks")) |lc| {
                const id = strField(lc, "check_id") orelse continue;
                if (!eql(strField(lc, "api") orelse "", row.api)) continue;
                for (arrField(lc, "case_ids")) |c| {
                    if (c == .string and eql(c.string, row.case_id)) row.check = if (row.check.len > 0) fmtA(r.a, "{s},{s}", .{ row.check, id }) else id;
                }
            }
        }
        r.rows.append(r.a, row) catch {};
    }

    /// The inventory ledger describes the rosetta-inventory queue only.
    fn invQuery(r: *const Readiness, queue: []const u8, api: []const u8, quantity: []const u8) ?json.Value {
        if (!eql(queue, "rosetta-inventory")) return null;
        for (arrField(field(r.inv, "queries") orelse .null, "entries")) |e| {
            if (eql(strField(e, "api") orelse "", api) and eql(strField(e, "quantity") orelse "", quantity)) return e;
        }
        return null;
    }

    fn unverifiedArg(r: *Readiness, api: []const u8, case_id: []const u8) ?json.Value {
        for (arrField(r.inv, "unverified_arguments")) |u| {
            if (!eql(strField(u, "api") orelse "", api)) continue;
            for (arrField(u, "case_ids")) |c| {
                if (c == .string and eql(c.string, case_id)) return u;
            }
        }
        return null;
    }

    fn creation(r: *Readiness, q: []const u8, case_id: []const u8, op: json.Value) void {
        const a = r.a;
        const api = strField(op, "api") orelse return;
        const n = arrField(op, "args").len;
        const item = fmtA(a, "{s} {s}/{d}", .{ strField(op, "op") orelse "?", api, n });
        var row: RRow = .{ .queue = q, .case_id = case_id, .kind = "creation", .item = item, .action = "shipped", .reason = "run_script", .check = "", .owner = "rosetta-capture", .evidence = vsCite(a, r.vs, api), .api = api };
        const d = r.vs.get(api) orelse {
            row.action = "unresolved";
            row.reason = "api_absent";
            row.owner = q;
            return r.add(row);
        };
        if (n != d.params) {
            if (n > d.params and n <= d.params + d.extra) {
                row.check = "point_arguments_expanded";
                row.owner = q;
                row.evidence = fmtA(a, "{s}. The call passes {d} numbers for the point parameters", .{ row.evidence, n });
            } else {
                row.action = "unresolved";
                row.reason = "arity_mismatch";
                row.owner = q;
                row.evidence = fmtA(a, "{s}. The call passes {d} arguments", .{ row.evidence, n });
                return r.add(row);
            }
        }
        if (r.unverifiedArg(api, case_id)) |u| {
            row.check = if (row.check.len > 0) fmtA(a, "{s},{s}", .{ row.check, strField(u, "kind") orelse "?" }) else strField(u, "kind") orelse "?";
            row.owner = strField(u, "owner") orelse q;
            row.evidence = fmtA(a, "{s}. {s}: {s}", .{ row.evidence, strField(u, "arguments") orelse "", strField(u, "detail") orelse "" });
        }
        r.add(row);
    }

    fn query(r: *Readiness, q: []const u8, case_id: []const u8, qv: json.Value) void {
        const a = r.a;
        const qq = queryOf(qv, "document_world");
        const api = qq.api;
        const item = if (qq.raw_only) |ro|
            fmtA(a, "{s} {s} raw_only {s}", .{ strField(qv, "object_id") orelse "?", api, ro.raw_call })
        else if (qq.component) |c|
            fmtA(a, "{s} {s} {s} {s}", .{ strField(qv, "object_id") orelse "?", api, qq.quantity, c })
        else
            fmtA(a, "{s} {s} {s}", .{ strField(qv, "object_id") orelse "?", api, qq.quantity });
        var row: RRow = .{ .queue = q, .case_id = case_id, .kind = "query", .item = item, .action = "unresolved", .reason = "", .check = "", .owner = q, .evidence = vsCite(a, r.vs, api), .api = api };
        if (r.vs.get(api) == null) {
            row.reason = "api_absent";
            return r.add(row);
        }
        const qp = planQuery(a, qq);
        if (qp.status) |st| {
            row.reason = st;
            row.evidence = joinSentence(a, row.evidence, qp.detail);
            if (qp.blocker) |b| {
                row.check = b.check;
                if (b.owner.len > 0) row.owner = b.owner;
                row.evidence = joinSentence(a, row.evidence, if (b.raw_call != null) "Raw query available" else "Raw query unavailable");
            } else row.owner = "rosetta-capture";
            if (eql(st, "collector_unimplemented")) row.evidence = joinSentence(a, row.evidence, "Raw query unavailable");
            if (qq.raw_only) |ro| {
                row.action = "raw_only";
                row.reason = "normalization_unresolved";
                row.check = ro.decision;
                row.owner = "maintainer";
                row.evidence = joinSentence(a, row.evidence, "Raw query available");
            }
            // The inventory ledger names the licensed check that supplies the missing argument.
            if (r.invQuery(q, api, qq.quantity)) |e| {
                if (eql(row.action, "unresolved") and eql(strField(e, "capture_status") orelse "", "licensed_prerequisite")) {
                    row.action = "licensed_prerequisite";
                    row.owner = strField(e, "owner") orelse row.owner;
                }
            }
            return r.add(row);
        }
        const c = qp.collector.?;
        row.action = "shipped";
        row.reason = "collector";
        row.check = c.check;
        row.owner = "rosetta-capture";
        row.evidence = fmtA(a, "{s}. {s}", .{ row.evidence, c.note });
        if (c.raw_only) |why| {
            row.action = "raw_only";
            row.reason = "mapping_unverified";
            row.owner = "maintainer";
            row.evidence = fmtA(a, "{s}. {s}", .{ row.evidence, why });
        } else if (!c.units_documented) {
            row.action = "units_gap";
            row.reason = "units_undocumented";
            row.owner = "maintainer";
            row.evidence = fmtA(a, "{s}. The record keeps the value with units null until the licensed check records the unit", .{row.evidence});
        }
        r.add(row);
    }

    /// Returns the action of the row so that the `export_<format>` channel row can follow it.
    fn exportRow(r: *Readiness, q: []const u8, case_id: []const u8, prof: *const Profile, existing: bool) []const u8 {
        const a = r.a;
        const item = fmtA(a, "{s} {s}", .{ prof.profile_id, prof.format });
        var row: RRow = .{ .queue = q, .case_id = case_id, .kind = "export", .item = item, .action = "unresolved", .reason = "", .check = "", .owner = q, .evidence = "" };
        const entry = findEntry(r.entries, prof.format);
        if (existing and entry != null) {
            row.reason = "existing_entry_unrouted";
            row.owner = "rosetta-capture";
            row.evidence = fmtA(a, "runAttempt routes existing-document exports through the operator step only. Format {s} has entry {s}", .{ prof.format, entry.?.api });
            r.add(row);
            return row.action;
        }
        if (entry) |e| {
            var missing: []const u8 = "";
            if (resolveArgs(a, e, prof, "", &missing) == null) {
                row.reason = "profile_option_null";
                row.evidence = fmtA(a, "{s} needs option {s}. {s}", .{ e.api, missing, e.source });
            } else {
                row.action = "shipped";
                row.reason = "export_entry";
                row.check = "export_entry";
                row.owner = "rosetta-capture";
                row.evidence = fmtA(a, "{s}. {s}", .{ vsCite(a, r.vs, e.api), e.source });
            }
            r.add(row);
            return row.action;
        }
        if (formatCheck(prof.format)) |chk| {
            row.action = fmtA(a, "operator_step:{s}", .{familyOf(prof.format)});
            row.reason = "operator_export";
            row.check = "export_menu";
            row.owner = "person";
            var ev: []const u8 = fmtA(a, "--operator-exports. Candidate menu, unverified: {s}", .{chk});
            for (export_candidates) |ec| {
                if (!eql(ec.format, prof.format)) continue;
                row.check = "export_menu,export_candidate";
                for (ec.apis) |x| ev = fmtA(a, "{s} Candidate call {s}.", .{ ev, vsCite(a, r.vs, x) });
            }
            row.evidence = ev;
            r.add(row);
            return row.action;
        }
        row.reason = "no_export_route";
        row.evidence = fmtA(a, "format {s} has no entry and no manual check", .{prof.format});
        r.add(row);
        return row.action;
    }

    fn channel(r: *Readiness, q: []const u8, case_id: []const u8, ch: []const u8, export_action: ?[]const u8) void {
        var row: RRow = .{ .queue = q, .case_id = case_id, .kind = "channel", .item = ch, .action = "unresolved", .reason = "no_channel_route", .check = "", .owner = "rosetta-capture", .evidence = "" };
        if (std.mem.startsWith(u8, ch, "export_") and !eql(ch, "export_result")) {
            if (export_action) |x| {
                row.action = x;
                row.reason = "export_rows";
                row.owner = if (eql(x, "shipped")) "rosetta-capture" else "person";
                row.evidence = "follows the export rows of this case and format";
            } else row.evidence = "no queued profile of this format";
            return r.add(row);
        }
        for (channel_routes) |cr| {
            if (!eql(cr[0], ch)) continue;
            row.action = "shipped";
            row.reason = "engine_stage";
            row.evidence = cr[1];
        }
        r.add(row);
    }

    fn existingOp(r: *Readiness, q: []const u8, case_id: []const u8, op: json.Value) void {
        const a = r.a;
        const name = strField(op, "op") orelse "?";
        const manual = eql(strField(op, "mode") orelse "", "operator_manual");
        var row: RRow = .{ .queue = q, .case_id = case_id, .kind = "operation", .item = name, .action = "shipped", .reason = "engine_stage", .check = "", .owner = "rosetta-capture", .evidence = "" };
        if (eql(name, "export")) return; // export rows cover the profile.
        if (manual and eql(name, "set_view")) {
            row.action = "operator_step:view";
            row.reason = "operator_export";
            row.owner = "person";
            row.check = "export_menu";
            row.evidence = fmtA(a, "the operator export step of this case names the view and the layers: {s}", .{stringifyLine(a, op)});
        } else if (eql(name, "close_without_save")) {
            row.evidence = "the engine closes the work copy. check_source_after compares the pinned source and scratch.vwx digests";
        } else row.evidence = fmtA(a, "existing-document stage {s}", .{name});
        r.add(row);
    }
};

pub const checklist_channels = [_][]const u8{ "shipped", "licensed-first-pass", "raw-only", "manual", "unsupported" };

/// shipped rows run with no licensed check. licensed-first-pass rows run, and their value
/// counts after the named licensed check records the native behaviour. raw-only rows record the
/// raw return with no value. manual rows are operator steps. unsupported rows have no route.
fn checklistChannel(x: *const RRow) []const u8 {
    if (std.mem.startsWith(u8, x.action, "operator_step:")) return "manual";
    if (eql(x.action, "raw_only")) return "raw-only";
    if (eql(x.action, "unresolved")) return "unsupported";
    if (eql(x.action, "shipped") and x.check.len == 0) return "shipped";
    return "licensed-first-pass";
}

fn checklistSubject(x: *const RRow) []const u8 {
    if (eql(checklistChannel(x), "shipped")) return "-";
    if (eql(x.kind, "export")) return x.item[(std.mem.lastIndexOfScalar(u8, x.item, ' ') orelse 0) + 1 ..];
    if (x.api.len > 0) return x.api;
    return x.item;
}

/// The operator text of one checklist group. Inventory family and query fields come first.
/// The licensed check texts follow.
fn checklistNext(a: Allocator, r: *const Readiness, x: *const RRow) []const u8 {
    const ch = checklistChannel(x);
    if (eql(ch, "shipped")) return "The packet runs these rows. The licensed run writes the native records.";
    var t: []const u8 = "";
    if (eql(x.kind, "family")) {
        for (arrField(field(r.inv, "families") orelse .null, "unsupported")) |f| {
            if (!eql(strField(f, "family_id") orelse "", x.item)) continue;
            var chans: []const u8 = "";
            for (arrField(f, "raw_channels")) |c| {
                if (c == .string) chans = if (chans.len > 0) fmtA(a, "{s}, {s}", .{ chans, c.string }) else c.string;
            }
            t = fmtA(a, "{s} {s} Raw channels {s}. Next owner {s}. {s}", .{ strField(f, "operator_action") orelse "", strField(f, "inputs") orelse "", chans, strField(f, "next_owner") orelse "?", strField(f, "limit") orelse "" });
        }
        return t;
    }
    if (eql(x.kind, "query") and !eql(x.action, "shipped")) {
        if (r.invQuery(x.queue, x.api, queryQuantity(x))) |e| {
            if (strField(e, "next_step")) |ns| t = ns;
        }
        if (t.len == 0 and eql(x.action, "raw_only")) {
            if (strField(field(r.inv, "raw_only_queries") orelse .null, "next_step")) |ns| t = ns;
        }
    }
    if (eql(x.reason, "arity_mismatch")) t = joinSentence(a, x.evidence, "The queue owner changes the call to the vs.py parameter count.");
    if (eql(x.reason, "api_absent")) t = joinSentence(a, x.evidence, "The queue owner replaces the call with an API that vs.py declares.");
    if (t.len == 0) t = x.evidence;
    var it = std.mem.splitScalar(u8, x.check, ',');
    while (it.next()) |c| {
        if (c.len == 0) continue;
        var ct: []const u8 = "";
        for (licensed_checks) |lc| {
            if (eql(lc.id, c)) ct = fmtA(a, "Check {s}. {s}", .{ c, lc.text });
        }
        for (arrField(r.inv, "licensed_checks")) |lc| {
            if (eql(strField(lc, "check_id") orelse "", c)) ct = fmtA(a, "Inventory check {s}. {s}", .{ c, strField(lc, "observation") orelse "" });
        }
        if (inList(&raw_decisions, c)) ct = fmtA(a, "Maintainer decision {s}.", .{c});
        t = if (t.len > 0) joinSentence(a, t, ct) else ct;
    }
    return std.mem.trim(u8, t, " ");
}

/// The quantity word of a query row item `<object> <api> <quantity> [component]`.
fn queryQuantity(x: *const RRow) []const u8 {
    var it = std.mem.splitScalar(u8, x.item, ' ');
    _ = it.next();
    _ = it.next();
    return it.next() orelse "";
}

/// One line per channel, kind, subject, action, reason, check and owner. Lines follow the
/// order of checklist_channels and then the matrix order.
fn checklist(a: Allocator, r: *const Readiness) ![]const u8 {
    const G = struct { first: *const RRow, rows: u32 = 0, cases: std.ArrayList([]const u8) = .empty };
    var groups: std.StringArrayHashMapUnmanaged(G) = .empty;
    for (r.rows.items) |*x| {
        const k = fmtA(a, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}", .{ checklistChannel(x), x.kind, checklistSubject(x), x.action, x.reason, if (x.check.len == 0) "-" else x.check, x.owner });
        const g = try groups.getOrPut(a, k);
        if (!g.found_existing) g.value_ptr.* = .{ .first = x };
        g.value_ptr.rows += 1;
        if (!inList(g.value_ptr.cases.items, x.case_id)) try g.value_ptr.cases.append(a, x.case_id);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "channel\tkind\tsubject\taction\treason\tcheck\towner\trows\tcases\tcase_ids\tnext\n");
    for (checklist_channels) |ch| {
        for (groups.keys(), groups.values()) |k, g| {
            if (!eql(k[0..std.mem.indexOfScalar(u8, k, '\t').?], ch)) continue;
            const ids = std.mem.join(a, ",", g.cases.items) catch "";
            try out.print(a, "{s}\t{d}\t{d}\t{s}\t{s}\n", .{ k, g.rows, g.cases.items.len, tsvField(a, ids), tsvField(a, checklistNext(a, r, g.first)) });
        }
    }
    return out.items;
}

/// Writes readiness.tsv and readiness.json into a new directory. Every queued creation call,
/// query, export profile and channel gets one row.
pub fn readiness(a: Allocator, io: Io, d: *Diags, o: ReadinessOptions, out: *Io.Writer) !void {
    if (exists(io, o.out)) {
        d.err("output_exists", o.out, "readiness writes a new directory only", .{});
        return;
    }
    const vbytes = try readAll(a, io, o.vs_py);
    const vs = parseVsPy(a, vbytes);
    if (vs.count == 0) {
        d.err("bad_vs_py", o.vs_py, "no def lines", .{});
        return;
    }
    const ibytes = try readAll(a, io, o.inventory_readiness);
    const inv = parseJson(a, ibytes) catch {
        d.err("invalid_json", o.inventory_readiness, "inventory readiness does not parse", .{});
        return;
    };
    var r: Readiness = .{ .a = a, .vs = &vs, .inv = inv, .entries = parseEntries(a, d, default_entries, "default entries") };
    var qinfo = arr(a);
    for (o.queues) |qq| {
        const qbytes = try readAll(a, io, qq.path);
        const qv = parseJson(a, qbytes) catch {
            d.err("invalid_json", qq.path, "queue does not parse", .{});
            return;
        };
        var profiles: std.ArrayList(Profile) = .empty;
        for (arrField(qv, "profiles")) |p| try profiles.append(a, profileOf(p));
        const cases = arrField(qv, "cases");
        var qi = Obj.init(a);
        qi.str("owner", qq.owner);
        qi.str("sha256", shaDup(a, qbytes));
        qi.int("cases", @intCast(cases.len));
        qinfo.append(qi.value()) catch {};
        for (cases) |c| {
            const id = strField(c, "case_id") orelse "";
            const existing = strField(c, "source_sha256") != null;
            for (arrField(c, "operations")) |op| {
                if (existing) r.existingOp(qq.owner, id, op) else if (strField(op, "api") != null) r.creation(qq.owner, id, op);
            }
            for (arrField(c, "queries")) |x| r.query(qq.owner, id, x);
            var fmt_action: std.StringHashMapUnmanaged([]const u8) = .empty;
            for (arrField(c, "profile_ids")) |pv| {
                const pid = if (pv == .string) pv.string else continue;
                var prof: ?*const Profile = null;
                for (profiles.items) |*p| {
                    if (eql(p.profile_id, pid)) prof = p;
                }
                const p = prof orelse {
                    r.add(.{ .queue = qq.owner, .case_id = id, .kind = "export", .item = pid, .action = "unresolved", .reason = "profile_missing", .check = "", .owner = qq.owner, .evidence = "the queue lists no profile of this ID" });
                    continue;
                };
                const act = r.exportRow(qq.owner, id, p, existing);
                const key = fmtA(a, "export_{s}", .{p.format});
                const prev = fmt_action.get(key);
                if (prev == null or eql(prev.?, "shipped")) try fmt_action.put(a, key, act);
            }
            for (arrField(c, "required_channels")) |ch| {
                if (ch == .string) r.channel(qq.owner, id, ch.string, fmt_action.get(ch.string));
            }
        }
    }
    for (arrField(field(inv, "families") orelse .null, "unsupported")) |f| {
        if (arrField(f, "case_ids").len > 0) continue;
        r.add(.{ .queue = "rosetta-inventory", .case_id = "-", .kind = "family", .item = strField(f, "family_id") orelse "?", .action = "unresolved", .reason = strField(f, "disposition") orelse "?", .check = "", .owner = strField(f, "owner") orelse "?", .evidence = strField(f, "detail") orelse "" });
    }
    for (arrField(field(inv, "families") orelse .null, "prerequisites")) |f| {
        for (arrField(f, "case_ids")) |cv| {
            const cid = if (cv == .string) cv.string else continue;
            for (arrField(f, "prerequisites")) |pr| {
                r.add(.{ .queue = "rosetta-inventory", .case_id = cid, .kind = "prerequisite", .item = strField(f, "family_id") orelse "?", .action = "operator_step:preflight", .reason = strField(f, "channel") orelse "?", .check = "release", .owner = "person", .evidence = if (pr == .string) pr.string else "" });
            }
        }
    }

    var tsv: std.ArrayList(u8) = .empty;
    try tsv.appendSlice(a, "queue\tcase_id\tkind\titem\taction\treason\tcheck\towner\tevidence\n");
    for (r.rows.items) |x| {
        const cols = [_][]const u8{ x.queue, x.case_id, x.kind, x.item, x.action, x.reason, if (x.check.len == 0) "-" else x.check, x.owner, x.evidence };
        for (cols, 0..) |col, i| {
            if (i > 0) try tsv.append(a, '\t');
            try tsv.appendSlice(a, tsvField(a, col));
        }
        try tsv.append(a, '\n');
    }

    // Counts per kind and action, unresolved groups and check use.
    var counts = Obj.init(a);
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(*const RRow)) = .empty;
    var check_rows: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var check_cases: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var op_groups: std.StringArrayHashMapUnmanaged(std.ArrayList(*const RRow)) = .empty;
    for (r.rows.items) |*x| {
        const kc = counts.m.getPtr(x.kind) orelse blk: {
            counts.put(x.kind, Obj.init(a).value());
            break :blk counts.m.getPtr(x.kind).?;
        };
        const cur = kc.object.get(x.action);
        kc.object.put(a, x.action, .{ .integer = (if (cur) |c| c.integer else 0) + 1 }) catch {};
        if (eql(x.action, "unresolved") or eql(x.action, "raw_only")) {
            const gk = fmtA(a, "{s}\t{s}\t{s}", .{ x.kind, x.reason, x.owner });
            const g = try groups.getOrPut(a, gk);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(a, x);
        }
        if (std.mem.startsWith(u8, x.action, "operator_step:")) {
            const g = try op_groups.getOrPut(a, x.action);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(a, x);
        }
        var it = std.mem.splitScalar(u8, x.check, ',');
        while (it.next()) |c| {
            if (c.len == 0) continue;
            const g = try check_rows.getOrPut(a, c);
            g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
            const cc = try check_cases.getOrPut(a, c);
            if (!cc.found_existing) cc.value_ptr.* = .empty;
            if (!inList(cc.value_ptr.items, x.case_id)) try cc.value_ptr.append(a, x.case_id);
        }
    }
    var unresolved = arr(a);
    for (groups.keys(), groups.values()) |k, rows| {
        var parts = std.mem.splitScalar(u8, k, '\t');
        var g = Obj.init(a);
        g.str("kind", parts.next().?);
        g.str("reason", parts.next().?);
        g.str("owner", parts.next().?);
        g.int("rows", @intCast(rows.items.len));
        var items: std.ArrayList([]const u8) = .empty;
        var cases: std.ArrayList([]const u8) = .empty;
        for (rows.items) |x| {
            if (!inList(items.items, x.item)) try items.append(a, x.item);
            if (!inList(cases.items, x.case_id)) try cases.append(a, x.case_id);
        }
        g.put("items", strArr(a, items.items));
        g.put("case_ids", strArr(a, cases.items));
        unresolved.append(g.value()) catch {};
    }
    var checks = arr(a);
    for (licensed_checks) |lc| {
        var g = Obj.init(a);
        g.str("id", lc.id);
        g.int("priority", lc.priority);
        g.int("rows", check_rows.get(lc.id) orelse 0);
        g.put("case_ids", strArr(a, if (check_cases.get(lc.id)) |l| l.items else &.{}));
        g.str("text", lc.text);
        g.str("inputs", lc.inputs);
        g.str("observation", lc.observation);
        g.put("steps", strArr(a, lc.steps));
        g.str("mutation", lc.mutation);
        g.put("raw_fields", strArr(a, lc.raw_fields));
        g.str("output", lc.output);
        g.str("accepted_bounds", lc.accepted_bounds);
        var stops: std.ArrayList([]const u8) = .empty;
        try stops.appendSlice(a, &licensed_common_stops);
        try stops.appendSlice(a, lc.stop_conditions);
        g.put("stop_conditions", strArr(a, stops.items));
        g.str("revision_step", lc.revision_step);
        g.str("owner", lc.owner);
        g.str("source", "rosetta-capture");
        g.str("state", "unexecuted");
        checks.append(g.value()) catch {};
    }
    for (arrField(inv, "licensed_checks")) |lc| {
        const id = strField(lc, "check_id") orelse continue;
        var g = Obj.init(a);
        g.str("id", id);
        g.str("api", strField(lc, "api") orelse "");
        g.int("rows", check_rows.get(id) orelse 0);
        g.str("text", strField(lc, "observation") orelse "");
        // The inventory owns these fields. readiness copies them unchanged.
        for ([_][]const u8{ "case_ids", "inputs", "observation", "expected", "steps", "mutation", "raw_fields", "output", "accepted_bounds", "stop_conditions", "revision_step", "owner" }) |k| {
            if (lc.object.get(k)) |v| g.put(k, v);
        }
        g.str("source", "rosetta-inventory");
        g.str("state", "unexecuted");
        checks.append(g.value()) catch {};
    }
    for (check_rows.keys()) |k| {
        // A raw_only row names its maintainer decision in `check`.
        var known = inList(&raw_decisions, k);
        for (licensed_checks) |lc| known = known or eql(lc.id, k);
        for (arrField(inv, "licensed_checks")) |lc| known = known or eql(strField(lc, "check_id") orelse "", k);
        if (!known) d.err("unknown_check", k, "a readiness row names a check without a licensed_checks entry or a raw-only decision", .{});
    }
    var opg = arr(a);
    for (op_groups.keys(), op_groups.values()) |k, rows| {
        var g = Obj.init(a);
        g.str("group", k);
        g.int("rows", @intCast(rows.items.len));
        var items: std.ArrayList([]const u8) = .empty;
        for (rows.items) |x| {
            if (eql(x.kind, "channel")) continue;
            const it = if (eql(x.kind, "export")) x.item[(std.mem.lastIndexOfScalar(u8, x.item, ' ') orelse 0) + 1 ..] else x.item;
            if (!inList(items.items, it)) try items.append(a, it);
        }
        g.put("items", strArr(a, items.items));
        opg.append(g.value()) catch {};
    }

    var root = Obj.init(a);
    root.str("schema", schema_readiness);
    root.str("native_verification", "unexecuted");
    var inputs = Obj.init(a);
    var vi = Obj.init(a);
    vi.str("sha256", shaDup(a, vbytes));
    vi.int("defs", @intCast(vs.count));
    inputs.put("vs_py", vi.value());
    var ii = Obj.init(a);
    ii.str("sha256", shaDup(a, ibytes));
    ii.str("queue_sha256", strField(inv, "queue_sha256") orelse "");
    inputs.put("inventory_readiness", ii.value());
    inputs.put("queues", .{ .array = qinfo });
    inputs.str("bridge_revision", bridge_revision);
    var ci = Obj.init(a);
    ci.str("path", "vwx/src/rosetta_capture.zig");
    ci.str("sha256", shaDup(a, capture_source));
    inputs.put("capture_source", ci.value());
    root.put("inputs", inputs.value());
    root.int("rows", @intCast(r.rows.items.len));
    root.put("counts", counts.value());
    root.put("unresolved", .{ .array = unresolved });
    root.put("operator_groups", .{ .array = opg });
    root.put("licensed_checks", .{ .array = checks });
    root.str("tsv_sha256", shaDup(a, tsv.items));
    const cl = try checklist(a, &r);
    var clo = Obj.init(a);
    var chs = Obj.init(a);
    for (checklist_channels) |ch| {
        var n: i64 = 0;
        for (r.rows.items) |*x| {
            if (eql(checklistChannel(x), ch)) n += 1;
        }
        chs.int(ch, n);
    }
    clo.put("rows", chs.value());
    clo.str("sha256", shaDup(a, cl));
    root.put("checklist", clo.value());

    try mkdirp(io, o.out);
    const files = [_]struct { []const u8, []const u8 }{
        .{ "readiness.tsv", tsv.items },
        .{ "checklist.tsv", cl },
        .{ "readiness.json", stringify(a, root.value()) },
    };
    for (files) |f| {
        try writeNew(io, fmtA(a, "{s}/{s}", .{ o.out, f[0] }), f[1]);
        try out.print("wrote\t{s}\t{s}\n", .{ f[0], &sha256Hex(f[1]) });
    }
    try out.print("summary\trows\t{d}\n", .{r.rows.items.len});
    for (unresolved.items) |g| try out.print("unresolved\t{s}\t{s}\t{s}\t{d}\n", .{ strField(g, "kind").?, strField(g, "reason").?, strField(g, "owner").?, intOf(field(g, "rows").?).? });
    try out.flush();
}

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------

pub fn statusReport(a: Allocator, io: Io, d: *Diags, dir: []const u8, out: *Io.Writer) !void {
    const s = loadSession(a, io, d, dir) orelse return;
    var runs: u32 = 0;
    while (exists(io, fmtA(a, "{s}/runs/{d}.json", .{ dir, runs + 1 }))) runs += 1;
    try out.print("summary\truns\t{d}\n", .{runs});
    if (exists(io, fmtA(a, "{s}/LOCK", .{dir}))) try out.print("summary\tlock\tpresent\n", .{});
    for (s.queue.cases) |*c| {
        const att = latestAttempt(a, io, &s, c.case_id);
        const v: []const u8 = if (att == 0) "none" else switch (verifyAttempt(a, io, &s, c, att)) {
            .complete => "complete",
            .partial => "partial",
            .stale => "stale",
        };
        const lo = latestOutcome(a, io, &s, c.case_id);
        const oc = if (lo) |x| strField(x.v, "outcome") orelse "?" else "none";
        try out.print("case\t{s}\t{s}\tattempt-{d}\t{s}\n", .{ c.case_id, oc, att, v });
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// compiled capability table
// ---------------------------------------------------------------------------

/// One implementation that a feature or route calls. `ptr` takes the address of the real function,
/// so a name that no longer exists fails the build. `needs` lists the `native_ui_runtime.features`
/// that the implementation depends on. The feature is unavailable when the runtime reports one of
/// them as not implemented.
pub const Impl = struct { name: []const u8, ptr: *const anyopaque };

fn impl(comptime name: []const u8, comptime f: anytype) Impl {
    return .{ .name = name, .ptr = @ptrCast(&f) };
}

pub const FeatureWiring = struct {
    feature: activation.Feature,
    impls: []const Impl,
    needs: []const []const u8 = &.{},
};

/// Every activation feature with the functions that implement it. A table entry names a function
/// that production code calls. The tests count the calls through fake backends.
pub const feature_wiring = [_]FeatureWiring{
    .{ .feature = .open_identity, .impls = &.{ impl("NativeDriver.open", NativeDriver.open), impl("nur.Runtime.waitForDocument", nur.Runtime.waitForDocument) }, .needs = &.{"console_process_window_modal_observation"} },
    .{ .feature = .console_handling, .impls = &.{impl("nur.Runtime.waitForDocument", nur.Runtime.waitForDocument)}, .needs = &.{"console_process_window_modal_observation"} },
    .{ .feature = .modal_handling, .impls = &.{ impl("NativeDriver.dismissModal", NativeDriver.dismissModal), impl("nur.Runtime.waitForDocument", nur.Runtime.waitForDocument) }, .needs = &.{ "console_process_window_modal_observation", "known_notice_acknowledgement" } },
    .{ .feature = .save_reopen_close, .impls = &.{ impl("NativeDriver.closeGuarded", NativeDriver.closeGuarded), impl("NativeDriver.open", NativeDriver.open), impl("Engine.closeDoc", Engine.closeDoc) }, .needs = &.{ "export_menu_navigation", "console_process_window_modal_observation" } },
    .{ .feature = .bounded_ui_execution, .impls = &.{ impl("NativeDriver.uiExport", NativeDriver.uiExport), impl("nur.Runtime.runExport", nur.Runtime.runExport) }, .needs = &.{ "export_menu_navigation", "exact_control_lookup", "destination_entry_and_confirmation", "progress_and_completion_observation" } },
    .{ .feature = .typed_options, .impls = &.{ impl("parseRouteSet", parseRouteSet), impl("nur.validateRoute", nur.validateRoute) }, .needs = &.{"option_set_with_read_back"} },
    .{ .feature = .window_inventory, .impls = &.{ impl("runInventory", runInventory), impl("nur.Runtime.runExport", nur.Runtime.runExport) }, .needs = &.{ "exact_control_lookup", "window_targeted_screenshot" } },
    .{ .feature = .attempt_directories, .impls = &.{ impl("Engine.exportBundle", Engine.exportBundle), impl("opdir.Operation.create", opdir.Operation.create) } },
    .{ .feature = .sidecar_manifests, .impls = &.{ impl("Engine.exportBundle", Engine.exportBundle), impl("opdir.Operation.seal", opdir.Operation.seal), impl("Engine.storeBundle", Engine.storeBundle) }, .needs = &.{"nested_sidecar_enumeration"} },
    .{ .feature = .streaming_verification, .impls = &.{ impl("sniffFile", sniffFile), impl("opdir.verify", opdir.verify), impl("objClosure", objClosure) } },
    .{ .feature = .checkpoint_resume, .impls = &.{ impl("Engine.bundleStageProblem", Engine.bundleStageProblem), impl("Engine.strictAttemptProblem", Engine.strictAttemptProblem), impl("verifyAttempt", verifyAttempt) } },
    .{ .feature = .deadlines, .impls = &.{ impl("NativeDriver.exec", NativeDriver.exec), impl("nur.ProcessTransport.transport", nur.ProcessTransport.transport) }, .needs = &.{"subprocess_transport_with_deadline"} },
    .{ .feature = .diagnostics, .impls = &.{ impl("NativeDriver.partialText", NativeDriver.partialText), impl("Engine.journal", Engine.journal) } },
    .{ .feature = .uncertain_mutation_refusal, .impls = &.{ impl("Engine.latch", Engine.latch), impl("Engine.latchPending", Engine.latchPending), impl("nur.Runtime.runExport", nur.Runtime.runExport) } },
};

fn nurImplemented(name: []const u8) bool {
    for (nur.features) |f| {
        if (eql(f.name, name)) return f.implemented;
    }
    return false;
}

pub fn featureAvailable(w: FeatureWiring) bool {
    if (w.impls.len == 0) return false;
    for (w.needs) |n| {
        if (!nurImplemented(n)) return false;
    }
    return true;
}

/// A format route is implemented when the UI route engine accepts the format, the bundle path
/// writes it and the pack registers it. A format that fails one test stays unavailable. SKP, SVG
/// and glTF fail the first test, so the early availability checks claim nothing here.
pub fn routeAvailable(r: activation.Route) bool {
    const id = @tagName(r);
    if (nur.formatFromId(id) == null) return false;
    if (formatExt(id) == null) return false;
    if (!inList(&pack.export_formats, id)) return false;
    for (feature_wiring) |w| {
        if ((w.feature == .bounded_ui_execution or w.feature == .sidecar_manifests) and !featureAvailable(w)) return false;
    }
    return true;
}

/// The typed table that `rosetta-activation` passes to `activation.runWith`. Every feature and route
/// defaults to unavailable. `provenance` names the table, so the unwired default stays
/// distinguishable.
pub fn compiledFeatures(a: Allocator) activation.CompiledFeatures {
    var c: activation.CompiledFeatures = .{};
    var n_impl: usize = 0;
    var n_feat: usize = 0;
    var n_route: usize = 0;
    for (feature_wiring) |w| {
        if (!featureAvailable(w)) continue;
        c.setFeature(w.feature, .implemented);
        n_feat += 1;
        n_impl += w.impls.len;
    }
    for (std.enums.values(activation.Route)) |r| {
        if (!routeAvailable(r)) continue;
        c.setRoute(r, .implemented);
        n_route += 1;
    }
    c.provenance = fmtA(a, "rosetta_capture.feature_wiring/1 features={d} routes={d} impls={d}", .{ n_feat, n_route, n_impl });
    return c;
}

/// Prints the implementation behind every true feature and route as tab-separated lines.
pub fn writeWiring(a: Allocator, w: *Io.Writer) Io.Writer.Error!void {
    for (feature_wiring) |fw| {
        try w.print("feature\t{s}\t{s}\t", .{ @tagName(fw.feature), if (featureAvailable(fw)) "implemented" else "unavailable" });
        for (fw.impls, 0..) |im, i| try w.print("{s}{s}", .{ if (i > 0) "," else "", im.name });
        try w.writeByte('\n');
    }
    for (std.enums.values(activation.Route)) |r| {
        const ok = routeAvailable(r);
        try w.print("route\t{s}\t{s}\t{s}\t", .{ @tagName(r), @tagName(r.class()), if (ok) "implemented" else "unavailable" });
        if (ok) {
            const scripted = findDefaultEntry(a, @tagName(r));
            try w.print("NativeDriver.uiExport,Engine.exportBundle{s}{s}", .{ if (scripted != null) "," else "", if (scripted) |e| e else "" });
        } else try w.writeAll("no route engine for this format");
        try w.writeByte('\n');
    }
    try w.writeAll("native_calibration\trequired\tno route is calibrated and no native branch has run\n");
}

fn findDefaultEntry(a: Allocator, format: []const u8) ?[]const u8 {
    var d = Diags.init(a);
    const entries = parseEntries(a, &d, default_entries, "default entries");
    const e = findEntry(entries, format) orelse return null;
    return e.api;
}

/// Router of `vwx rosetta-activation`. It binds the running executable and passes the compiled
/// table to `activation.runWith`. A `--binary` argument must name the running executable. Another
/// path is refused, so the packet binds the bytes that run. `--features unwired` passes the empty
/// table. It removes features and never adds one.
pub fn runActivationCli(gpa: Allocator, io: Io, args: []const []const u8, out: *Io.Writer) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const self = std.process.executablePathAlloc(io, a) catch {
        out.writeAll("{\"schema\":\"vwx-rosetta-activation-result/1\",\"error\":\"running_executable_unknown\"}\n") catch {};
        return 1;
    };
    var list: std.ArrayList([]const u8) = .empty;
    var unwired = false;
    if (args.len == 0) return activation.runWith(gpa, io, args, out, .{});
    list.append(a, args[0]) catch return 1;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (eql(args[i], "--binary")) {
            const real_arg = Dir.cwd().realPathFileAlloc(io, args[i + 1], a) catch "";
            const real_self = Dir.cwd().realPathFileAlloc(io, self, a) catch self;
            if (!eql(real_arg, real_self)) {
                out.print("{{\"schema\":\"{s}\",\"error\":\"binary_not_running_executable\"}}\n", .{activation.schema_result}) catch {};
                return 1;
            }
            continue;
        }
        if (eql(args[i], "--features")) {
            if (!eql(args[i + 1], "unwired")) {
                out.writeAll("{\"schema\":\"vwx-rosetta-activation-result/1\",\"error\":\"features_value_unknown\"}\n") catch {};
                return 2;
            }
            unwired = true;
            continue;
        }
        list.append(a, args[i]) catch return 1;
        list.append(a, args[i + 1]) catch return 1;
    }
    if (i < args.len) list.append(a, args[i]) catch return 1;
    if (args.len > 1) {
        list.append(a, "--binary") catch return 1;
        list.append(a, self) catch return 1;
    }
    return activation.runWith(gpa, io, list.items, out, if (unwired) .{} else compiledFeatures(a));
}

// ---------------------------------------------------------------------------
// completion record and expansion check
// ---------------------------------------------------------------------------

/// Inputs of the expansion check. The record is a claim. The check binds it to the running
/// executable, the queue, the profiles, the recipes and the loaded routes, and resolves each
/// referenced calibration evidence record by digest.
pub const FormatOptions = struct { format: []const u8, options_sha256: []const u8 };

pub const CompletionInput = struct {
    record_path: []const u8,
    exe_sha256: []const u8,
    queue_sha256: []const u8,
    profiles_sha256: []const u8,
    recipes_sha256: []const u8,
    release: []const u8,
    workspace: []const u8,
    routes: *const RouteSet,
    evidence_dir: []const u8,
    /// Format ids that the session profiles export.
    formats: []const []const u8,
    /// Object families of the session cases.
    families: []const []const u8,
    /// The options digest of every session profile with its format.
    options: []const FormatOptions,
};

fn addUnique(a: Allocator, list: *std.ArrayList([]const u8), s: []const u8) void {
    if (!inList(list.items, s)) list.append(a, s) catch {};
}

/// Format ids and family ids of a session queue, each once and in queue order.
pub fn sessionFormats(a: Allocator, q: *const Queue) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (q.cases) |c| {
        for (c.profile_ids) |pid| {
            if (q.findProfile(pid)) |p| addUnique(a, &out, p.format);
        }
    }
    return out.items;
}

/// The format and the options digest of each profile that a case of the queue exports.
pub fn sessionOptions(a: Allocator, q: *const Queue) []const FormatOptions {
    var out: std.ArrayList(FormatOptions) = .empty;
    for (q.cases) |c| {
        for (c.profile_ids) |pid| {
            const p = q.findProfile(pid) orelse continue;
            out.append(a, .{ .format = p.format, .options_sha256 = optionsDigest(a, p.options) }) catch {};
        }
    }
    return out.items;
}

pub fn sessionFamilies(a: Allocator, q: *const Queue) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (q.cases) |c| addUnique(a, &out, c.family_id);
    return out.items;
}

/// Returns true when the record passes every rule. Each failed rule adds an error to `d`. The check
/// writes nothing and calls no backend. A missing record, a stale binding, a format without a
/// calibrated route or an exact approved exception, a family outside the record, a missing
/// measurement or a measurement over its budget each refuse.
pub fn checkCompletion(a: Allocator, io: Io, d: *Diags, in: CompletionInput) bool {
    const before = d.errors();
    const where = in.record_path;
    const bytes = Dir.cwd().readFileAlloc(io, in.record_path, a, .limited(max_completion_bytes)) catch |e| {
        d.err("completion_missing", where, "the completion record cannot be read: {s}", .{@errorName(e)});
        return false;
    };
    const v = parseJson(a, bytes) catch |e| {
        d.err("completion_malformed", where, "the completion record does not parse: {s}", .{@errorName(e)});
        return false;
    };
    if (!onlyKeys(v, &.{ "schema", "executable_sha256", "release", "workspace", "queue_sha256", "profiles_sha256", "recipes_sha256", "routes", "families", "measurements", "exceptions" }) or !eql(strField(v, "schema") orelse "", schema_completion)) {
        d.err("completion_malformed", where, "the completion record needs schema {s} and the keys of that schema", .{schema_completion});
        return false;
    }
    const binds = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "executable_sha256", in.exe_sha256, "completion_stale_binary" },
        .{ "queue_sha256", in.queue_sha256, "completion_stale_input" },
        .{ "profiles_sha256", in.profiles_sha256, "completion_stale_input" },
        .{ "recipes_sha256", in.recipes_sha256, "completion_stale_input" },
        .{ "release", in.release, "completion_stale_release" },
        .{ "workspace", in.workspace, "completion_stale_release" },
    };
    for (binds) |b| {
        if (!eql(strField(v, b[0]) orelse "", b[1])) d.err(b[2], where, "`{s}` of the record differs from the current value", .{b[0]});
    }
    const exceptions = arrField(v, "exceptions");
    for (exceptions) |x| {
        const op = strField(x, "operation") orelse "";
        const reason: []const u8 = strField(x, "reason") orelse "";
        const by: []const u8 = strField(x, "approved_by") orelse "";
        const ref: []const u8 = strField(x, "approval_ref") orelse "";
        const at: []const u8 = strField(x, "approved_at") orelse "";
        const ok = onlyKeys(x, &.{ "operation", "reason", "approved_by", "approval_ref", "approved_at" }) and op.len > 0 and reason.len > 0 and by.len > 0 and ref.len > 0 and at.len > 0;
        if (!ok) d.err("completion_exception_unapproved", where, "the exception for `{s}` lacks a reason, an approver, an approval reference or an approval time", .{op});
    }
    for (in.formats) |fid| {
        var excepted = false;
        for (exceptions) |x| {
            if (eql(strField(x, "operation") orelse "", fid)) excepted = true;
        }
        var entry: ?json.Value = null;
        for (arrField(v, "routes")) |r| {
            if (eql(strField(r, "operation") orelse "", fid)) entry = r;
        }
        if (entry == null) {
            if (!excepted) d.err("completion_route_missing", fid, "format `{s}` has no calibrated route in the record and no exact approved exception", .{fid});
            continue;
        }
        const r = entry.?;
        const ur = in.routes.forFormat(fid) orelse {
            d.err("completion_route_unverified", fid, "the record names a route for `{s}` and the loaded route set has none", .{fid});
            continue;
        };
        if (nur.isTargeted(ur.format)) {
            d.err("completion_route_unverified", fid, "format `{s}` is a targeted format. It cannot reach the verified phase", .{fid});
            continue;
        }
        if (ur.route.status != .calibrated or !eql(strField(r, "route_id") orelse "", ur.id) or !eql(strField(r, "calibration_id") orelse "", ur.calibration_id) or !eql(strField(r, "evidence_sha256") orelse "", ur.evidence_sha256)) {
            d.err("completion_route_unverified", fid, "the record and the loaded route for `{s}` differ in route id, calibration id, evidence or status", .{fid});
            continue;
        }
        const ev = switch (loadEvidence(a, io, ur, in.evidence_dir, in.exe_sha256)) {
            .ok => |x| x,
            .problem => |p| {
                d.err("completion_route_unverified", fid, "{s}: {s}", .{ p.code, p.msg });
                continue;
            },
        };
        // The same identity check as a verified run. Every session profile of the format must match
        // the calibrated options, and the release and the workspace must match.
        var identity_ok = true;
        for (in.options) |fo| {
            if (!eql(fo.format, fid)) continue;
            if (evidenceIdentityProblem(ev, in.release, in.workspace, fo.options_sha256)) |why| {
                d.err("completion_route_unverified", fid, "{s}", .{why});
                identity_ok = false;
                break;
            }
        }
        if (!identity_ok) continue;
        // The measurement comes from the retained evidence. The record supplies only the budget.
        var measured = false;
        for (arrField(v, "measurements")) |m| {
            if (!eql(strField(m, "operation") orelse "", fid) or !eql(strField(m, "metric") orelse "", "export_ms")) continue;
            measured = true;
            const budget = numberOf(field(m, "budget") orelse .null);
            if (ev.export_ms == null or budget == null or budget.? <= 0) {
                d.err("completion_measurement_missing", fid, "the evidence of `{s}` has no export_ms value or the record has no budget", .{fid});
            } else if (ev.export_ms.? > budget.?) d.add(.warning, "completion_budget_exceeded", fid, "export_ms of `{s}` in the evidence is {d} and the estimate is {d}. A complete artifact is valid at any latency", .{ fid, ev.export_ms.?, budget.? });
        }
        if (!measured) d.err("completion_measurement_missing", fid, "no export_ms budget for `{s}`", .{fid});
    }
    const supported = strings(a, arrField(v, "families"));
    for (in.families) |fam| {
        if (!inList(supported, fam)) d.err("completion_family_unsupported", fam, "family `{s}` is not in the supported families of the record", .{fam});
    }
    return d.errors() == before;
}

// ---------------------------------------------------------------------------
// bounded inventory
// ---------------------------------------------------------------------------

pub const InventoryOptions = struct {
    rt: *nur.Runtime,
    routes: *const RouteSet,
    pid: i32,
    /// Basename of the expected open document.
    document: []const u8,
    /// Existing absolute directory. Each route gets a fresh directory below it.
    out_dir: []const u8,
    only: ?[]const u8 = null,
};

/// Runs the inventory phase of each route. It looks up every selector of the route, captures one
/// window screenshot into the fresh directory of the route and presses the cancel button. It stops
/// at the first failure. The report names the controls, the screenshot and the failure kind. The
/// directory stays unsealed, because no document or state binds an inventory.
pub fn runInventory(a: Allocator, io: Io, d: *Diags, o: InventoryOptions, out: *Io.Writer) !u8 {
    var failed = false;
    var ran: usize = 0;
    for (o.routes.routes) |ur| {
        if (o.only) |id| if (!eql(id, ur.id)) continue;
        ran += 1;
        const op_id = fmtA(a, "inv-{s}-a1", .{ur.id});
        const dir = fmtA(a, "{s}/{s}", .{ o.out_dir, op_id });
        Dir.cwd().createDir(io, dir, .default_dir) catch |e| {
            d.err("output_exists", dir, "the inventory directory cannot be created: {s}", .{@errorName(e)});
            return 1;
        };
        // One record covers the whole route. A stop between the menu press and the cancel press leaves it.
        if (o.rt.journal) |j| if (!j.beginFn(j.ptr, "inventory")) {
            d.err("inflight_unwritable", o.out_dir, "the in-flight record cannot be written or an earlier record is pending", .{});
            return 1;
        };
        var rep = o.rt.runExport(.{
            .phase = .inventory,
            .route = ur.route,
            .policy = .{
                .expected = .{ .original = o.document },
                .console = .{ .missing_lock_key_is_unlocked = true },
            },
            .pid = o.pid,
            .run_binding = ur.route.binding,
            .op_id = op_id,
            .op_dir = dir,
            .outputs = ur.outputs,
            .screenshot_name = "window.png",
        });
        if (o.rt.journal) |j| j.endFn(j.ptr, rep.failure == null or !rep.failure.?.uncertain);
        defer rep.deinit(o.rt.a);
        var x = Obj.init(a);
        x.str("schema", "vwx-rosetta-native-inventory/1");
        x.str("route_id", ur.id);
        x.str("format", nur.formatId(ur.format));
        x.str("phase", "inventory");
        x.str("native_verification", "unverified");
        if (rep.failure) |f| {
            var fo = Obj.init(a);
            fo.str("kind", @tagName(f.kind));
            fo.str("cause", @tagName(f.cause));
            fo.boolean("uncertain", f.uncertain);
            fo.str("detail", f.detail());
            x.put("failure", fo.value());
        } else x.put("failure", .null);
        var cl = arr(a);
        for (rep.controls) |c| {
            var co = Obj.init(a);
            co.str("label", c.label);
            co.int("count", c.count);
            co.str("value", c.value);
            co.boolean("enabled", c.enabled);
            try cl.append(co.value());
        }
        x.put("controls", .{ .array = cl });
        x.put("screenshot", if (rep.screenshot) |s| (blk: {
            var so = Obj.init(a);
            so.str("name", s.name);
            so.int("size", @intCast(s.size));
            break :blk so.value();
        }) else .null);
        x.int("polls", rep.stats.polls);
        try writeNew(io, fmtA(a, "{s}/inventory-report.json", .{dir}), stringify(a, x.value()));
        try out.print("inventory\t{s}\t{s}\t{s}\n", .{ ur.id, if (rep.failure) |f| @tagName(f.kind) else "ok", dir });
        if (rep.failure != null) {
            failed = true;
            if (rep.failure.?.uncertain) try out.print("reconcile_required\t{s}\t{s}\n", .{ ur.id, dir });
            break;
        }
    }
    if (ran == 0) d.err("route_missing", "inventory", "no route matched", .{});
    return if (failed or ran == 0) 1 else 0;
}

// ---------------------------------------------------------------------------
// production setup and commands
// ---------------------------------------------------------------------------

/// The completion evidence of a runtime export as a JSON value. `via` names the producer contract
/// that established it. `established` is true only for a correlated progress transition with a
/// closed dialog.
fn completionValue(a: Allocator, c: nur.Completion) json.Value {
    var o = Obj.init(a);
    o.str("via", @tagName(c.via));
    o.boolean("established", c.established);
    o.put("baseline", if (c.baseline) |b| .{ .integer = b } else .null);
    o.int("observations", c.observations);
    o.str("progress_id", c.progress_id);
    o.int("unmatched", c.unmatched);
    o.put("last", if (c.last) |l| .{ .integer = l } else .null);
    return o.value();
}

/// The observation cadence of a runtime export: the chosen intervals, the counts that adapted them
/// and the reason. These intervals decide when the app is inspected and never whether an export
/// succeeded.
fn cadenceValue(a: Allocator, c: nur.Cadence) json.Value {
    var o = Obj.init(a);
    o.int("waits", c.count);
    o.int("min_ms", c.min_ms);
    o.int("max_ms", c.max_ms);
    o.int("woke", c.woke);
    o.int("timed_out", c.timed_out);
    o.int("delivered", c.delivered);
    o.int("missed", c.missed);
    o.int("fallback_ms", c.fallback_ms);
    o.str("reason", @tagName(c.reason));
    var buf: [32]u32 = undefined;
    var recent = arr(a);
    for (c.recent(&buf)) |ms| recent.append(.{ .integer = ms }) catch {};
    o.put("recent_ms", .{ .array = recent });
    return o.value();
}

/// Wakeups from the app through `native_ui_observer`. The runtime arms it before each mutating call
/// with the pid and the export directory. The first arm of a pid and directory creates an observer
/// and subscribes before the action. Later arms reuse it and drain stale events. A wakeup ends a
/// runtime wait early and proves nothing, because the runtime reads the bridge, process, UI and
/// output state after it. A timeout, an interrupt, a lost notification or a failed or denied
/// subscription leaves a bounded poll. The record `observation.json` lists the capabilities that the
/// platform reported and the counters, so the mode is an observed fact. `dispose` ends the
/// subscription and runs on every exit of a run.
pub const ObserverNotifier = struct {
    a: Allocator,
    io: Io,
    env: nur.Env,
    /// Null selects `obs.SystemBackend` (AX and kqueue). A test injects `obs.FakeBackend`.
    injected: ?obs.Backend = null,
    /// False when the clock is a fake. A wait then reads the observer without blocking and moves the
    /// clock itself.
    real_wait: bool = true,
    /// Absolute path prefix of the observation records. Each write makes a new file `<prefix>-<n>.json`
    /// and replaces nothing. The highest number is the latest state. Empty writes no record.
    record_path: []const u8 = "",
    observer: ?*obs.Observer = null,
    system: ?*obs.SystemBackend = null,
    pid: i32 = 0,
    dir_buf: [512]u8 = undefined,
    dir_len: usize = 0,
    want_buf: [512]u8 = undefined,
    want_len: usize = 0,
    mode: obs.Mode = .polling,
    subscriptions: u32 = 0,
    subscribe_failures: u32 = 0,
    wakeups: u32 = 0,
    timeouts: u32 = 0,
    interrupts: u32 = 0,
    rescans: u32 = 0,
    fallback_waits: u32 = 0,
    disposed: u32 = 0,
    record_seq: u32 = 0,
    /// The capabilities that the platform reported at the last subscription.
    caps: [obs.max_capabilities]obs.Capability = undefined,
    caps_len: usize = 0,

    pub fn notifier(n: *ObserverNotifier) nur.Notifier {
        return .{ .ptr = n, .armFn = armImpl, .waitFn = waitImpl, .watchFn = watchImpl };
    }

    fn me(p: *anyopaque) *ObserverNotifier {
        return @ptrCast(@alignCast(p));
    }

    fn dirNow(n: *const ObserverNotifier) []const u8 {
        return n.dir_buf[0..n.dir_len];
    }

    fn watchImpl(p: *anyopaque, dir: []const u8) void {
        const n = me(p);
        n.want_len = if (dir.len <= n.want_buf.len) dir.len else 0;
        @memcpy(n.want_buf[0..n.want_len], dir[0..n.want_len]);
    }

    fn armImpl(p: *anyopaque, pid: i32) void {
        const n = me(p);
        const want = n.want_buf[0..n.want_len];
        if (n.observer != null and n.pid == pid and std.mem.eql(u8, n.dirNow(), want)) {
            _ = n.observer.?.poll();
            return;
        }
        n.release();
        n.pid = pid;
        n.dir_len = want.len;
        @memcpy(n.dir_buf[0..n.dir_len], want);
        const backend: obs.Backend = n.injected orelse blk: {
            const sb = n.a.create(obs.SystemBackend) catch {
                n.subscribe_failures += 1;
                return;
            };
            sb.* = .{ .a = n.a };
            n.system = sb;
            break :blk sb.backend();
        };
        const o = obs.Observer.create(n.a, backend) catch {
            n.subscribe_failures += 1;
            n.freeSystem();
            return;
        };
        var watch: [1]obs.Watch = undefined;
        var watches: []const obs.Watch = &.{};
        if (n.dir_len > 0) {
            watch[0] = .{ .path = n.dirNow() };
            watches = watch[0..1];
        }
        o.subscribe(.{ .pid = pid, .watches = watches }) catch {
            n.subscribe_failures += 1;
            o.destroy();
            n.freeSystem();
            return;
        };
        n.observer = o;
        n.subscriptions += 1;
        n.mode = o.mode();
        n.caps_len = o.capabilities().len;
        @memcpy(n.caps[0..n.caps_len], o.capabilities());
        n.writeRecord();
    }

    fn waitImpl(p: *anyopaque, max_ms: u32) bool {
        const n = me(p);
        const o = n.observer orelse {
            n.fallback_waits += 1;
            n.env.sleep(max_ms);
            return false;
        };
        if (n.mode == .polling) {
            // No subscription is active. The wait is a labeled poll.
            n.fallback_waits += 1;
            n.env.sleep(max_ms);
            return false;
        }
        switch (o.wait(if (n.real_wait) max_ms else 0)) {
            .wake => |w| {
                n.wakeups += 1;
                if (w.needsRescan()) n.rescans += 1;
                return true;
            },
            .timeout => {
                n.timeouts += 1;
                if (!n.real_wait) n.env.sleep(max_ms);
                return false;
            },
            .interrupted => {
                n.interrupts += 1;
                return true;
            },
            .closed => {
                n.fallback_waits += 1;
                n.env.sleep(max_ms);
                return false;
            },
        }
    }

    fn freeSystem(n: *ObserverNotifier) void {
        if (n.system) |sb| n.a.destroy(sb);
        n.system = null;
    }

    /// Ends the subscription and frees what the notifier created. Safe to call twice.
    pub fn release(n: *ObserverNotifier) void {
        if (n.observer) |o| {
            n.writeRecord();
            o.teardown();
            o.destroy();
            n.observer = null;
        }
        n.freeSystem();
    }

    /// Ends the subscription and writes the final record.
    pub fn dispose(n: *ObserverNotifier) void {
        n.disposed += 1;
        n.release();
        n.writeRecord();
    }

    fn writeRecord(n: *ObserverNotifier) void {
        if (n.record_path.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var o = Obj.init(a);
        o.str("schema", schema_observation);
        o.int("pid", n.pid);
        o.str("dir", n.dirNow());
        o.str("mode", if (n.observer != null) @tagName(n.mode) else "none");
        o.str("last_mode", @tagName(n.mode));
        o.int("subscriptions", n.subscriptions);
        o.int("subscribe_failures", n.subscribe_failures);
        o.int("wakeups", n.wakeups);
        o.int("timeouts", n.timeouts);
        o.int("interrupts", n.interrupts);
        o.int("rescans", n.rescans);
        o.int("fallback_waits", n.fallback_waits);
        var caps = arr(a);
        for (n.caps[0..n.caps_len]) |c| {
            var x = Obj.init(a);
            x.str("source", @tagName(c.source));
            x.str("kind", @tagName(c.kind));
            x.str("label", c.label);
            x.str("status", @tagName(c.status));
            x.int("code", c.code);
            caps.append(x.value()) catch {};
        }
        o.put("capabilities", .{ .array = caps });
        n.record_seq += 1;
        writeDurable(n.io, fmtA(a, "{s}-{d}.json", .{ n.record_path, n.record_seq }), stringify(a, o.value())) catch {};
    }
};

pub const schema_observation = "vwx-rosetta-capture-observation/1";

/// Read-only UI capture through `native_ui_diagnostics`. One call writes `window.png`,
/// `controls.tsv` and `record.json` into `<out_dir>/diag-<pid>-<n>/`. The caller passes an `out_dir`
/// that no export bundle contains. The result carries the outcome and the directory. An unknown
/// dialog needs no window selector, so the module selects the single modal window. Other reasons
/// select the document window by its exact title. A capture problem is reported in the result and
/// never replaces the failure that raised the capture.
pub const DiagAdapter = struct {
    a: Allocator,
    io: Io,
    env: nur.Env,
    out_dir: []const u8,
    backend: uidiag.Backend,
    timeout_ms: u32 = 8_000,
    captures: u32 = 0,
    detail_buf: [400]u8 = undefined,

    pub fn hook(d: *DiagAdapter) nur.Diagnostic {
        return .{ .ptr = d, .captureFn = captureImpl };
    }

    fn captureImpl(p: *anyopaque, req: nur.DiagRequest) nur.DiagResult {
        const d: *DiagAdapter = @ptrCast(@alignCast(p));
        d.captures += 1;
        const by_title = !eql(req.reason, "unknown_modal") and req.window_title.len > 0;
        var rep = uidiag.capture(d.a, d.io, d.backend, d.env, .{
            .pid = req.pid,
            .window_title = if (by_title) req.window_title else null,
            .out_dir = d.out_dir,
            .reason = req.reason,
            .expected_condition = req.expected,
            .last_action = req.last_action,
            .timeout_ms = d.timeout_ms,
        }) catch return .{ .captured = false, .detail = "the diagnostic capture ran out of memory" };
        defer rep.deinit();
        const usable = (rep.outcome == .complete or rep.outcome == .partial) and rep.record_path != null;
        const text = std.fmt.bufPrint(&d.detail_buf, "{s} {s} png={s} controls={s}", .{
            @tagName(rep.outcome),
            rep.diag_dir orelse "no directory",
            @tagName(rep.screenshot),
            @tagName(rep.controls),
        }) catch @tagName(rep.outcome);
        return .{ .captured = usable, .detail = text };
    }
};

/// Test seams of the production path. The binary leaves them null. A test injects a backend, a
/// transport or an executable path. An injected backend is recorded as `injected` and cannot
/// produce calibration evidence that `loadEvidence` accepts.
pub const Seams = struct {
    /// Executable path of a pid. A test sets it. Null reads the real process.
    pid_path: ?*const fn (pid: i32, buf: []u8) ?[]const u8 = null,
    backend: ?nur.Backend = null,
    transport: ?nur.Transport = null,
    exe_path: ?[]const u8 = null,
    /// A fake clock and sleep for the whole-run budget. A test sets it.
    env: ?nur.Env = null,
    /// Observer backend. Null selects the system backend, except under an injected UI backend, where
    /// no observer is installed and every wait is a labeled poll.
    observer: ?obs.Backend = null,
    /// Diagnostic backend. Null selects `diag.MacBackend`, except under an injected UI backend, where
    /// the runtime takes a screenshot through that backend.
    diag_backend: ?uidiag.Backend = null,
    /// Menu backend of the owned reference cleanup. Null selects the system backend.
    menu_backend: ?uidiag.MenuBackend = null,
};

pub var seams: Seams = .{};

/// Everything that a production native run allocates. The pointers stay valid for the run.
const Production = struct {
    strict: Strict,
    routes: RouteSet,
    pt: nur.ProcessTransport,
    env: nur.SystemEnv,
    files: nur.SystemFiles,
    mac: nur.MacBackend,
    rt: nur.Runtime,
    ui: UiWiring,
    exe_path: []const u8,
    report: activation.Report,
    budgets: ?activation.Budgets = null,
    diag_mac: uidiag.MacBackend = undefined,
    diag_native: uidiag.NativeWindowBackend = undefined,
    diag_backend: ?uidiag.Backend = null,
    diag_adapter: DiagAdapter = undefined,
    observer: ObserverNotifier = undefined,
    observer_on: bool = false,
};

/// Installs the diagnostic capture and the observation record of a production run. `dir` is the
/// session directory of a capture run or the output directory of a native inventory. The captures go
/// to `<dir>/diagnostics`, which no export bundle and no inventory operation directory contains. The
/// observation records go to `<dir>/observation-<n>.json`. The caller ends the subscription with
/// `p.observer.dispose()` on every exit.
fn installAdapters(a: Allocator, io: Io, p: *Production, dir: []const u8) void {
    const diag_dir = fmtA(a, "{s}/diagnostics", .{dir});
    if (mkdirp(io, diag_dir)) |_| {
        if (p.diag_backend) |db| {
            p.diag_adapter = .{ .a = a, .io = io, .env = p.rt.env, .out_dir = diag_dir, .backend = db };
            p.rt.diagnostic = p.diag_adapter.hook();
        } else p.rt.diag_dir = diag_dir;
    } else |_| {}
    p.observer.record_path = fmtA(a, "{s}/observation", .{dir});
}

fn runningExe(a: Allocator, io: Io) ![]const u8 {
    if (seams.exe_path) |p| return p;
    return try std.process.executablePathAlloc(io, a);
}

fn exeDigest(a: Allocator, io: Io, d: *Diags, exe: []const u8) ?[]const u8 {
    const dg = activation.hashFile(io, exe, activation.max_binary_bytes) catch |e| {
        d.err("running_executable_unreadable", exe, "cannot hash the running executable: {s}", .{@errorName(e)});
        return null;
    };
    return a.dupe(u8, &dg.sha256) catch null;
}

const strict_options = [_][]const u8{ "--activation-packet", "--routes", "--evidence-dir", "--release", "--workspace", "--phase" };

/// Builds the production wiring of one native command. It checks the requirements first, then the
/// activation gate with the compiled table and the running executable, then the typed route file.
/// No backend call happens here. A missing requirement or a failed gate returns null with
/// errors in `d`.
fn setupProduction(a: Allocator, io: Io, d: *Diags, x: *const Args, osascript: []const u8) !?*Production {
    var missing = false;
    for (strict_options) |k| {
        if (x.get(k) == null) {
            d.err("strict_requirement_missing", k, "a native run needs {s}. The native command has no switch that skips the activation gate", .{k});
            missing = true;
        }
    }
    if (x.inputs.items.len == 0) {
        d.err("strict_requirement_missing", "--activation-input", "a native run needs the activation inputs queue, profiles and recipes", .{});
        missing = true;
    }
    if (x.flags.get("--operator-exports") != null) {
        d.err("strict_requirement_violated", "--operator-exports", "operator exports are an exception that the completion record carries. A native run does not accept the switch", .{});
        missing = true;
    }
    if (missing) return null;
    const phase = std.meta.stringToEnum(nur.Phase, x.get("--phase").?) orelse {
        d.err("strict_requirement_missing", "--phase", "the phase is inventory, calibration or verified", .{});
        return null;
    };
    var scratch: ?nur.ScratchAuthorization = null;
    if (phase == .calibration) {
        const sid = x.get("--scratch-session") orelse {
            d.err("scratch_not_authorized", "--scratch-session", "the calibration phase runs only in an explicitly authorized scratch session", .{});
            return null;
        };
        scratch = .{ .session = sid };
    }
    const exe = try runningExe(a, io);
    const exe_sha = exeDigest(a, io, d, exe) orelse return null;

    var inputs: std.ArrayList(activation.InputPath) = .empty;
    for (x.inputs.items) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse {
            d.err("strict_requirement_missing", "--activation-input", "`{s}` is not <id>=<path>", .{kv});
            return null;
        };
        try inputs.append(a, .{ .id = kv[0..eq], .path = kv[eq + 1 ..] });
    }
    const prod = try a.create(Production);
    prod.exe_path = exe;
    prod.report = try activation.check(a, io, .{ .packet_path = x.get("--activation-packet").?, .binary_path = exe, .inputs = inputs.items, .features = compiledFeatures(a) });
    for (prod.report.diags) |g| d.err(g.code, g.location, "{s}", .{g.message});
    activation.enforce(.activation_gate, &prod.report) catch {
        d.err("activation_not_ready", x.get("--activation-packet").?, "the activation check is {s}. A native run needs offline_ready. Native calibration is still required after it", .{@tagName(prod.report.status)});
        return null;
    };
    const rp = x.get("--routes").?;
    const rbytes = Dir.cwd().readFileAlloc(io, rp, a, .limited(max_route_bytes)) catch |e| {
        d.err("routes_malformed", rp, "cannot read the route file: {s}", .{@errorName(e)});
        return null;
    };
    prod.routes = parseRouteSet(a, d, rbytes, rp) orelse return null;
    if (!eql(prod.routes.release, x.get("--release").?) or !eql(prod.routes.workspace, x.get("--workspace").?)) {
        d.err("stale_route", rp, "the route file names release `{s}` and workspace `{s}`. The run names `{s}` and `{s}`", .{ prod.routes.release, prod.routes.workspace, x.get("--release").?, x.get("--workspace").? });
        return null;
    }
    prod.pt = .{ .io = io };
    prod.env = .{ .io = io };
    prod.files = .{ .io = io };
    const transport = seams.transport orelse prod.pt.transport();
    prod.mac = nur.MacBackend.init(a, transport, prod.env.env(), .{ .osascript = osascript });
    const backend = seams.backend orelse prod.mac.backend();
    // The validated packet budgets reach the runtime and the engine. The run budget is one whole-run
    // clock that a retry does not refresh. The operation deadline applies to each operation.
    prod.budgets = activation.loadBudgets(a, io, x.get("--activation-packet").?);
    var limits: nur.Limits = .{ .cancel_after_failure = true };
    if (prod.budgets) |b| {
        limits.op_deadline_ms = @intCast(@min(b.operation_deadline_ms, std.math.maxInt(u32)));
        limits.run_deadline_ms = @intCast(@min(b.run_budget_ms, std.math.maxInt(u32)));
    }
    // A stall with no observed change raises one capture. The wait goes on to the operation deadline.
    limits.stall_ms = @min(20_000, limits.op_deadline_ms / 2);
    prod.rt = nur.Runtime.init(a, backend, seams.env orelse prod.env.env(), prod.files.files(), limits);
    if (seams.backend == null) nur.installSignalHandlers();
    const run_env = seams.env orelse prod.env.env();
    prod.diag_mac = uidiag.MacBackend.init(a, transport, run_env, .{ .osascript = osascript });
    prod.diag_backend = seams.diag_backend orelse (if (seams.backend == null) prod.diag_mac.backend() else null);
    if (@import("builtin").os.tag == .macos and seams.backend == null and seams.transport == null and seams.diag_backend == null) {
        prod.diag_native = uidiag.NativeWindowBackend.init(a, &prod.diag_mac, run_env);
        prod.diag_backend = prod.diag_native.backend();
    }
    prod.observer = .{ .a = a, .io = io, .env = run_env, .injected = seams.observer, .real_wait = seams.env == null };
    prod.observer_on = seams.backend == null or seams.observer != null;
    if (prod.observer_on) prod.rt.notifier = prod.observer.notifier();
    prod.strict = .{
        .exe_sha256 = exe_sha,
        .phase = phase,
        .release = x.get("--release").?,
        .workspace = x.get("--workspace").?,
        .routes = &prod.routes,
        .evidence_dir = x.get("--evidence-dir").?,
        .scratch = scratch,
        .backend = if (seams.backend == null) "mac" else "injected",
        .budgets = prod.budgets,
    };
    prod.ui = .{
        .rt = &prod.rt,
        .backend = backend,
        .routes = &prod.routes,
        .evidence_dir = prod.strict.evidence_dir,
        .exe_sha256 = exe_sha,
        .phase = phase,
        .scratch = scratch,
        .allow_conversion_ack = x.flags.get("--allow-conversion-ack") != null,
        .allow_watermark_ack = x.flags.get("--allow-watermark-ack") != null,
        .expect_converted = x.flags.get("--expect-converted") != null,
        .expect_watermark = x.flags.get("--expect-watermark") != null,
    };
    return prod;
}

/// SHA-256 of the profile hashes and of the recipe digests of a queue, in queue order. The
/// completion record binds them.
pub fn sessionDigests(a: Allocator, q: *const Queue) struct { profiles: []const u8, recipes: []const u8 } {
    var ps: std.ArrayList(u8) = .empty;
    for (q.profiles) |p| ps.appendSlice(a, fmtA(a, "{s} {s}\n", .{ p.profile_id, p.profile_sha256 })) catch {};
    var rs: std.ArrayList(u8) = .empty;
    for (q.cases) |c| rs.appendSlice(a, fmtA(a, "{s} {s}\n", .{ c.case_id, c.recipe_sha256 orelse "" })) catch {};
    return .{ .profiles = shaDup(a, ps.items), .recipes = shaDup(a, rs.items) };
}

/// The expansion gate. A run of more than `max_bounded_cases` cases, or a run with `--expansion`,
/// needs a completion record that passes `checkCompletion`. The gate runs before the first native
/// call. Returns true when the run may start.
fn expansionGate(a: Allocator, io: Io, d: *Diags, x: *const Args, s: *const Session, prod: *const Production) bool {
    const expand = s.queue.cases.len > max_bounded_cases or x.flags.get("--expansion") != null;
    if (!expand) return true;
    const rec = x.get("--completion") orelse {
        d.err("expansion_refused", "--completion", "{d} cases need the automation completion record. A run of at most {d} cases is a bounded run. Premature expansion is refused before any native call", .{ s.queue.cases.len, max_bounded_cases });
        return false;
    };
    const dg = sessionDigests(a, &s.queue);
    const ok = checkCompletion(a, io, d, .{
        .record_path = rec,
        .exe_sha256 = prod.strict.exe_sha256,
        .queue_sha256 = s.queue.sha256,
        .profiles_sha256 = dg.profiles,
        .recipes_sha256 = dg.recipes,
        .release = prod.strict.release,
        .workspace = prod.strict.workspace,
        .routes = &prod.routes,
        .evidence_dir = prod.strict.evidence_dir,
        .formats = sessionFormats(a, &s.queue),
        .families = sessionFamilies(a, &s.queue),
        .options = sessionOptions(a, &s.queue),
    });
    if (!ok) d.err("expansion_refused", rec, "the completion check refused the expansion", .{});
    return ok;
}

/// Closes one stranded export scratch copy through the guarded File > Close during an explicit
/// reconcile. It acts only with operator authorization, the exact absolute scratch path of this
/// session, the expected executable on the pid, the active document check of the bridge and a sealed
/// source whose SHA-256 equals the given digest. Any mismatch leaves the latch and the app as they
/// were. The call never saves, never answers a dialog and never clears the latch. It writes a record
/// under `cleanup-records/` that `reconcile` follows.
fn closeScratchCommand(a: Allocator, io: Io, d: *Diags, x: *const Args, dir: []const u8, out: *Io.Writer) !u8 {
    if (x.flags.get("--operator-authorized") == null) {
        d.err("not_authorized", "close-scratch", "closing a document needs --operator-authorized. The operator starts the app", .{});
        return 1;
    }
    const pid = std.fmt.parseInt(i32, x.get("--pid") orelse return usage(out), 10) catch return usage(out);
    const sender = x.get("--sender") orelse return usage(out);
    const exe_want = x.get("--expected-executable") orelse return usage(out);
    const scratch = x.get("--scratch") orelse return usage(out);
    const src_path = x.get("--sealed-source") orelse return usage(out);
    const src_want = x.get("--sealed-source-sha256") orelse return usage(out);
    const note = x.get("--reason") orelse "";
    if (exe_want.len == 0 or exe_want[0] != '/' or scratch.len == 0 or scratch[0] != '/' or src_path.len == 0 or src_path[0] != '/') {
        d.err("path_not_absolute", "close-scratch", "--expected-executable, --scratch and --sealed-source are exact absolute paths", .{});
        return 1;
    }
    if (!isLowerHex64(src_want)) {
        d.err("digest_invalid", "--sealed-source-sha256", "the sealed source digest is 64 lowercase hex digits", .{});
        return 1;
    }
    if (note.len == 0) {
        d.err("reason_missing", "--reason", "name the rejection that the operator observed. The record keeps the text", .{});
        return 1;
    }
    // A latch must exist, and it must belong to the case of this scratch copy.
    const lp = fmtA(a, "{s}/RECONCILE.json", .{dir});
    const ip = fmtA(a, "{s}/{s}", .{ dir, inflight_name });
    if (!exists(io, lp) and !exists(io, ip)) {
        d.err("no_latch", dir, "the session has no reconcile latch and no in-flight record. Nothing is stranded", .{});
        return 1;
    }
    const prefix = fmtA(a, "{s}/cases/", .{dir});
    if (!std.mem.startsWith(u8, scratch, prefix)) {
        d.err("scratch_refused", scratch, "the scratch copy is not below this session's cases directory", .{});
        return 1;
    }
    const rel = scratch[prefix.len..];
    const case_id = rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse rel.len];
    if (case_id.len == 0 or std.mem.indexOf(u8, rel, "/work/") == null or std.mem.indexOf(u8, rel, "/source/") != null or std.mem.indexOf(u8, rel, "..") != null or !eql(basename(scratch), "scratch.vwx")) {
        d.err("scratch_refused", scratch, "only a work/<profile>/scratch.vwx copy of a case is closed. A source or another document is refused", .{});
        return 1;
    }
    if (!exists(io, scratch)) {
        d.err("scratch_refused", scratch, "the scratch copy does not exist", .{});
        return 1;
    }
    var latch_case: []const u8 = "";
    if (exists(io, lp)) {
        const lv = parseJson(a, readAll(a, io, lp) catch "") catch .null;
        latch_case = strField(lv, "case_id") orelse "";
    } else {
        const iv = parseJson(a, readAll(a, io, ip) catch "") catch .null;
        const ctx = strField(iv, "context") orelse "";
        if (std.mem.startsWith(u8, ctx, fmtA(a, "case={s} ", .{case_id}))) latch_case = case_id;
    }
    if (!eql(latch_case, case_id)) {
        d.err("latch_mismatch", scratch, "the latch belongs to another case than this scratch copy", .{});
        return 1;
    }
    // The sealed source stays as it was. A different digest leaves everything alone.
    const src_have = hashFileDup(a, io, src_path) orelse "";
    if (!eql(src_have, src_want)) {
        d.err("sealed_source_mismatch", src_path, "the sealed source hashes to `{s}`, not `{s}`. Nothing was closed", .{ src_have, src_want });
        return 1;
    }
    const scratch_before = hashFileDup(a, io, scratch) orelse "";

    const osascript = x.get("--osascript") orelse "/usr/bin/osascript";
    var pt: nur.ProcessTransport = .{ .io = io };
    var env: nur.SystemEnv = .{ .io = io };
    var files: nur.SystemFiles = .{ .io = io };
    const run_env = seams.env orelse env.env();
    const transport = seams.transport orelse pt.transport();
    var mac = nur.MacBackend.init(a, transport, run_env, .{ .osascript = osascript });
    const backend = seams.backend orelse mac.backend();
    var rt = nur.Runtime.init(a, backend, run_env, files.files(), .{});
    var diag_mac = uidiag.MacBackend.init(a, transport, run_env, .{ .osascript = osascript });
    var diag_native: uidiag.NativeWindowBackend = undefined;
    var diag_backend: ?uidiag.Backend = seams.diag_backend orelse (if (seams.backend == null) diag_mac.backend() else null);
    if (@import("builtin").os.tag == .macos and seams.backend == null and seams.transport == null and seams.diag_backend == null) {
        diag_native = uidiag.NativeWindowBackend.init(a, &diag_mac, run_env);
        diag_backend = diag_native.backend();
    }
    var ui: UiWiring = .{
        .rt = &rt,
        .backend = backend,
        .expect_converted = x.flags.get("--expect-converted") != null,
        .expect_watermark = x.flags.get("--expect-watermark") != null,
    };
    const pid_of = seams.pid_path orelse nativePidPath;
    var buf: [4096]u8 = undefined;
    const have_exe = pid_of(pid, &buf) orelse "";
    if (!eql(have_exe, exe_want)) {
        d.err("executable_mismatch", "--expected-executable", "pid {d} runs `{s}`, not the expected executable. Nothing was closed", .{ pid, have_exe });
        return 1;
    }
    var n: NativeDriver = .{ .a = a, .io = io, .cfg = .{
        .pid = pid,
        .sender = sender,
        .osascript = osascript,
        .request_root = fmtA(a, "{s}/native-requests", .{dir}),
        .window_backend = diag_backend,
        .transport = seams.transport,
        .ui = &ui,
        .expected_executable = exe_want,
        .pathOf = pid_of,
        .inflight_dir = dir,
    }, .doc = scratch };
    // The bridge compares the active document with `document` before it answers. A different active
    // document is refused there and the menu step never runs.
    const rep = n.closeGuarded(a, .{ .kind = .close, .case_id = case_id, .payload = "{\"fallback\":\"ui_menu\"}" });
    const src_after = hashFileDup(a, io, src_path) orelse "";
    const scratch_after = hashFileDup(a, io, scratch) orelse "";
    var rec = Obj.init(a);
    rec.str("schema", "vwx-rosetta-capture-cleanup/1");
    rec.int("t_ms", nowMs(io));
    rec.int("pid", pid);
    rec.str("executable", exe_want);
    rec.str("case_id", case_id);
    rec.str("scratch", scratch);
    rec.str("scratch_sha256_before", scratch_before);
    rec.str("scratch_sha256_after", scratch_after);
    rec.str("sealed_source", src_path);
    rec.str("sealed_source_sha256", src_want);
    rec.boolean("sealed_source_unchanged", eql(src_after, src_want));
    rec.str("operator_rejection_note", note);
    rec.str("outcome", if (rep.status == .ok) "closed" else if (rep.uncertain) "uncertain" else "refused_or_failed");
    rec.str("reply_status", @tagName(rep.status));
    rec.str("reply_detail", rep.detail);
    rec.boolean("latch_cleared", false);
    var k: usize = 1;
    while (exists(io, fmtA(a, "{s}/cleanup-records/close-{d}.json", .{ dir, k }))) k += 1;
    try putSealed(a, io, fmtA(a, "{s}/cleanup-records/close-{d}.json", .{ dir, k }), stringify(a, rec.value()));
    if (rep.status != .ok) {
        d.err("close_failed", scratch, "{s}: {s}. The latch is intact. The record is cleanup-records/close-{d}.json", .{ @tagName(rep.status), rep.detail, k });
        return 1;
    }
    try out.print("closed\t{s}\nrecord\t{s}/cleanup-records/close-{d}.json\nlatch\tintact. Run reconcile after the record is reviewed\n", .{ scratch, dir, k });
    return 0;
}

/// Maps a bridge reply of the `doc` operation to a path proof. The bridge compares vs.GetFName and
/// vs.GetFPathName with the reference before it answers. Its two named refusals prove that another
/// document, or a document without a path, is active. Every other failure proves nothing.
fn referenceProof(r: Reply) orc.Active {
    if (r.status == .ok) return .matches;
    if (r.uncertain or r.refused) return .{ .failed = r.detail };
    if (otherDocumentMarker(r.detail)) return .{ .other = r.detail };
    return .{ .failed = r.detail };
}

/// True for the two bridge errors that prove another document, or a document without a path, is active.
fn otherDocumentMarker(detail: []const u8) bool {
    return std.mem.indexOf(u8, detail, "RuntimeError: the active document is ") != null or std.mem.indexOf(u8, detail, "RuntimeError: vs.GetFPathName returns ") != null;
}

/// The diagnostic of a probe that proved nothing. It names the outcome and the detail, and for a sender
/// that did not succeed its status, exit code and at most 240 bytes of stderr. It never says only "failed".
fn probeFailure(a: Allocator, res: nb.Result) []const u8 {
    var s = fmtA(a, "native-probe doc {s}: {s}", .{ @tagName(res.outcome), res.detail });
    if (res.sender) |sr| if (!eql(sr.status, "exited") or sr.exit_code != 0) {
        const err = a.dupe(u8, std.mem.trim(u8, sr.stderr[0..@min(sr.stderr.len, 240)], " \r\n")) catch return s;
        for (err) |*c| {
            if (c.* < 0x20 or c.* == 0x7f) c.* = ' ';
        }
        s = fmtA(a, "{s}. Sender status {s}, exit code {d}, stderr: {s}", .{ s, sr.status, sr.exit_code, err });
    };
    if (res.request_dir) |d| s = fmtA(a, "{s}. Request directory {s}", .{ s, d });
    return s;
}

/// Maps the result of a `native-probe doc` request for the reference to a path proof. Only an `ok` response
/// whose `path` equals the reference proves the match, and only the two named bridge errors prove another
/// document. A probe that is uncertain or ended any other way proves nothing and keeps its diagnostic.
fn referenceProbeProof(a: Allocator, res: nb.Result, reference: []const u8) orc.Active {
    if (res.outcome == .ok) {
        const v = res.response orelse return .{ .failed = probeFailure(a, res) };
        const p = strField(v, "path") orelse return .{ .failed = fmtA(a, "native-probe doc ok: the response has no path. Request directory {s}", .{res.request_dir orelse ""}) };
        if (!eql(p, reference)) return .{ .failed = fmtA(a, "native-probe doc ok: the response path {s} differs from the reference {s}", .{ p, reference }) };
        return .matches;
    }
    if (res.outcome == .bridge_error and !res.uncertain and otherDocumentMarker(res.detail)) return .{ .other = res.detail };
    return .{ .failed = probeFailure(a, res) };
}

/// `native_bootstrap.PidPathFn` over the pid path seam of this module, so a test's executable path reaches the probe.
fn probePidPath(a: Allocator, pid: i32) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const p = (seams.pid_path orelse nativePidPath)(pid, &buf) orelse return null;
    return a.dupe(u8, p) catch null;
}

/// Maps the report of the Window menu press to a step. Every status before the press is a definite
/// refusal. A press that failed may still have run.
fn activationStep(r: uidiag.MenuReport) orc.Step {
    if (r.status == .pressed) return .{ .status = .done, .detail = "Window menu item pressed" };
    if (r.status == .press_failed) return .{ .status = .failed, .uncertain = true, .detail = "the Window menu press failed and may have run" };
    return .{ .status = .refused, .detail = if (r.reason.len > 0) r.reason else @tagName(r.status) };
}

/// The effects of the owned reference cleanup. They run on one native driver and one runtime.
const ReferenceOps = struct {
    a: Allocator,
    io: Io,
    n: *NativeDriver,
    menu: uidiag.MenuBackend,
    env: nur.Env,
    transport: nur.Transport,
    pid: i32,
    exe: []const u8,
    reference: []const u8,
    settle_ms: u32 = 300,
    marker_path: []const u8 = "",
    marker_bytes: []const u8 = "",

    fn ops(r: *ReferenceOps) orc.Ops {
        return .{ .beginFn = begin, .ptr = r, .exePathFn = exePath, .canonicalFn = canonical, .digestFn = digest, .activeFn = active, .activateFn = activate, .closeFn = close };
    }
    fn self(p: *anyopaque) *ReferenceOps {
        return @ptrCast(@alignCast(p));
    }
    fn begin(p: *anyopaque) bool {
        const r = self(p);
        return createReferenceMarker(r.io, r.marker_path, r.marker_bytes);
    }
    fn exePath(p: *anyopaque, pid: i32, buf: []u8) ?[]const u8 {
        return self(p).n.cfg.pathOf(pid, buf);
    }
    fn canonical(p: *anyopaque, path: []const u8) bool {
        const r = self(p);
        const rp = Dir.cwd().realPathFileAlloc(r.io, path, r.a) catch return false;
        return eql(rp, path);
    }
    fn digest(p: *anyopaque, path: []const u8) ?[]const u8 {
        const r = self(p);
        return hashFileDup(r.a, r.io, path);
    }
    fn active(p: *anyopaque, path: []const u8) orc.Active {
        const r = self(p);
        // A getter-only proof through `native-probe doc`. It skips the window and dialog prechecks of
        // `NativeDriver.python`, which failed before any document request, and it keeps the same pid, executable and sender.
        const root = r.n.cfg.request_root;
        mkdirp(r.io, root) catch return .{ .failed = fmtA(r.a, "native-probe doc: the request directory {s} cannot be created", .{root}) };
        const res = nb.probe(r.a, r.io, .{ .transport = r.transport, .env = r.env, .pid_path = probePidPath }, .{
            .pid = r.pid,
            .expected_executable = r.exe,
            .sender = r.n.cfg.sender,
            .out_dir = root,
            .kind = .doc,
            .document = path,
            .timeout_ms = @min(r.n.cfg.op_timeout_ms, 60_000),
            .send_timeout_ms = r.n.cfg.send_timeout_ms,
            .poll_max_ms = r.n.cfg.poll_ms,
        });
        return referenceProbeProof(r.a, res, path);
    }
    fn activate(p: *anyopaque, title: []const u8) orc.Step {
        const r = self(p);
        var buf: [4096]u8 = undefined;
        const items = [_][]const u8{ "Window", title };
        const rep = uidiag.menu(r.a, r.menu, .{ .pid = r.pid, .expected_executable = r.exe, .items = &items, .press = true, .window_document = title }, &buf);
        const st = activationStep(rep);
        if (st.status == .done) r.env.sleep(r.settle_ms);
        return st;
    }
    fn close(p: *anyopaque, title: []const u8, discard: bool) orc.Step {
        const r = self(p);
        const u = r.n.cfg.ui.?;
        u.calls.close_menu += 1;
        const rep = u.rt.closeDocument(.{ .pid = r.pid, .policy = u.policy(r.a, title), .discard = if (discard) .{ .document = title } else null });
        if (rep.failure) |f| {
            const rf = NativeDriver.replyFromFailure(r.a, f);
            return .{ .status = if (f.uncertain) .failed else .refused, .uncertain = f.uncertain, .detail = rf.detail };
        }
        return .{ .status = .done, .discarded = rep.discarded };
    }
};

/// The journal of the owned reference cleanup lives in `<session>/cleanup-records/`.
/// `reference-<sha256 of the reference path>.inflight` is the per-reference marker. It is created
/// exclusively and synced before the first dispatched action. `reference-<n>.json` is the final record.
/// It is published by exclusive creation, so no run replaces an earlier record.
fn referenceMarkerPath(a: Allocator, dir: []const u8, reference: []const u8) []const u8 {
    return fmtA(a, "{s}/cleanup-records/reference-{s}.inflight", .{ dir, sha256Hex(reference) });
}

fn syncDir(io: Io, path: []const u8) void {
    var d = Dir.cwd().openDir(io, path, .{}) catch return;
    defer d.close(io);
    const df: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    df.sync(io) catch {};
}

/// Null when the reference may be dispatched. Otherwise the reason it must not. A marker of this
/// reference, an uncertain record of this reference and a record that cannot be read all refuse. A
/// marker or an uncertain record of another reference does not.
fn referenceRefusal(a: Allocator, io: Io, dir: []const u8, reference: []const u8) ?[]const u8 {
    const marker = referenceMarkerPath(a, dir, reference);
    if (exists(io, marker)) return fmtA(a, "the in-flight marker {s} exists. An earlier run dispatched an action or crashed. Reconcile by hand first", .{marker});
    const rdir = fmtA(a, "{s}/cleanup-records", .{dir});
    var h = Dir.cwd().openDir(io, rdir, .{ .iterate = true }) catch return null;
    defer h.close(io);
    var it = h.iterate();
    while (it.next(io) catch return "the cleanup records cannot be listed") |e| {
        if (e.kind != .file) continue;
        if (!std.mem.startsWith(u8, e.name, "reference-") or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const rp = fmtA(a, "{s}/{s}", .{ rdir, e.name });
        const bytes = readAll(a, io, rp) catch return fmtA(a, "the record {s} cannot be read", .{rp});
        const v = parseJson(a, bytes) catch return fmtA(a, "the record {s} does not parse", .{rp});
        const rf = strField(v, "reference") orelse return fmtA(a, "the record {s} names no reference", .{rp});
        if (!eql(rf, reference)) continue;
        const u = field(v, "uncertain") orelse return fmtA(a, "the record {s} has no uncertain field", .{rp});
        if (u != .bool or u.bool) return fmtA(a, "the record {s} of this reference is uncertain. Reconcile by hand first", .{rp});
    }
    return null;
}

/// Creates the marker exclusively and syncs it and its directory. False when the marker already exists
/// or cannot be made durable. A marker that this call created and could not complete is removed again.
fn createReferenceMarker(io: Io, path: []const u8, bytes: []const u8) bool {
    mkdirp(io, dirname(path)) catch return false;
    var fh = Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch return false;
    var ok = true;
    fh.writeStreamingAll(io, bytes) catch {
        ok = false;
    };
    if (ok) fh.sync(io) catch {
        ok = false;
    };
    fh.close(io);
    if (!ok) {
        Dir.cwd().deleteFile(io, path) catch {};
        return false;
    }
    syncDir(io, dirname(path));
    return true;
}

/// Publishes `bytes` as the first free `cleanup-records/reference-<n>.json` by exclusive creation and
/// returns n. An existing record is never replaced. The record is synced and made read-only.
fn publishReferenceRecord(a: Allocator, io: Io, dir: []const u8, bytes: []const u8) !usize {
    const rdir = fmtA(a, "{s}/cleanup-records", .{dir});
    try mkdirp(io, rdir);
    var k: usize = 1;
    while (k < 100000) : (k += 1) {
        const p = fmtA(a, "{s}/reference-{d}.json", .{ rdir, k });
        var fh = Dir.cwd().createFile(io, p, .{ .exclusive = true }) catch |e| {
            if (e == error.PathAlreadyExists) continue;
            return e;
        };
        {
            defer fh.close(io);
            try fh.writeStreamingAll(io, bytes);
            try fh.sync(io);
        }
        try seal(io, p);
        syncDir(io, rdir);
        return k;
    }
    return error.TooManyRecords;
}

/// The session-wide exclusion of the owned reference cleanup is the session `LOCK` itself, the lock that a
/// capture run holds. It is created exclusively (`createFile` with `.exclusive`, one `O_EXCL` open) and
/// holds the pid of this process. A held lock of a live process refuses. A lock of a dead process or one
/// that is empty or unreadable also refuses: unlike a capture run, the cleanup never takes a lock over,
/// because a take-over is a rename of a path that a racing process may have just created.
/// Null when this process now holds the lock. Otherwise the reason it does not.
fn acquireSessionExclusion(a: Allocator, io: Io, dir: []const u8) ?[]const u8 {
    const lp = fmtA(a, "{s}/LOCK", .{dir});
    writeNew(io, lp, fmtA(a, "{d}\n", .{std.c.getpid()})) catch |err| {
        if (err != error.PathAlreadyExists) return fmtA(a, "the session lock {s} cannot be created: {s}", .{ lp, @errorName(err) });
        const held = readAll(a, io, lp) catch "";
        const pid = std.fmt.parseInt(i32, std.mem.trim(u8, held, " \n"), 10) catch 0;
        if (pid > 0 and pidAlive(pid)) return fmtA(a, "process {d} holds the session lock {s}", .{ pid, lp });
        return fmtA(a, "the session lock {s} exists and names no live process. Reconcile by hand first", .{lp});
    };
    return null;
}

/// Moves this process's lock to `lock-history/`. It never moves a lock that names another process.
fn releaseSessionExclusion(a: Allocator, io: Io, dir: []const u8) bool {
    const lp = fmtA(a, "{s}/LOCK", .{dir});
    const held = readAll(a, io, lp) catch return false;
    if (!eql(held, fmtA(a, "{d}\n", .{std.c.getpid()}))) return false;
    mkdirp(io, fmtA(a, "{s}/lock-history", .{dir})) catch return false;
    Dir.rename(Dir.cwd(), lp, Dir.cwd(), fmtA(a, "{s}/lock-history/cleanup-{d}-{d}", .{ dir, std.c.getpid(), nowMs(io) }), io) catch return false;
    return true;
}

fn referenceMarkerBytes(a: Allocator, io: Io, req: orc.Request) []const u8 {
    var o = Obj.init(a);
    o.str("schema", "vwx-rosetta-capture-reference-inflight/1");
    o.int("t_ms", nowMs(io));
    o.int("owner_pid", std.c.getpid());
    o.int("pid", req.pid);
    o.str("executable", req.expected_executable);
    o.str("reference", req.reference);
    o.str("operator_reason", req.reason);
    return stringify(a, o.value());
}

/// Closes one standalone task-owned reference document through File > Close, after a Window menu
/// activation when another document is active. See `owned_reference_cleanup.zig` for the sequence.
/// It needs operator authorization, the pid and exact executable, the canonical temporary path and
/// the recorded digest of the reference. It never saves, never deletes and never retries. It writes
/// `cleanup-records/reference-<n>.json` under the session directory and does not touch the latch.
/// Before the first dispatched action it creates the per-reference `.inflight` marker. It refuses before any
/// action when that marker or an uncertain record of the reference exists. See OWNED-REFERENCE-JOURNAL-REPAIR.md.
fn closeReferenceCommand(a: Allocator, io: Io, d: *Diags, x: *const Args, dir: []const u8, out: *Io.Writer) !u8 {
    const pid = std.fmt.parseInt(i32, x.get("--pid") orelse return usage(out), 10) catch return usage(out);
    const sender = x.get("--sender") orelse return usage(out);
    const req: orc.Request = .{
        .operator_authorized = x.flags.get("--operator-authorized") != null,
        .pid = pid,
        .expected_executable = x.get("--expected-executable") orelse return usage(out),
        .reference = x.get("--reference") orelse return usage(out),
        .reference_sha256 = x.get("--reference-sha256") orelse return usage(out),
        .tolerated = x.tolerated.items,
        .allow_discard = x.flags.get("--allow-discard-unsaved") != null,
        .reason = x.get("--reason") orelse "",
    };
    if (orc.precheck(req)) |why| {
        d.err("reference_refused", "close-reference", "{s}. Nothing was sent to the application", .{why});
        return 1;
    }
    if (!exists(io, dir)) {
        d.err("session_missing", dir, "the session directory does not exist", .{});
        return 1;
    }
    // Session-wide exclusion, before admission, any proof or any action. Held through the final record.
    if (acquireSessionExclusion(a, io, dir)) |why| {
        d.err("reference_refused", req.reference, "{s}. Nothing was sent to the application", .{why});
        return 1;
    }
    // The process ends holding it whenever an action may be unproven or no record was published.
    var release_lock = true;
    defer if (release_lock and !releaseSessionExclusion(a, io, dir)) {
        d.err("session_lock_kept", dir, "the session lock could not be released. Check it by hand", .{});
    };
    // Before any proof or action: a marker or an uncertain record of this reference latches it.
    if (referenceRefusal(a, io, dir, req.reference)) |why| {
        d.err("reference_refused", req.reference, "{s}. Nothing was sent to the application", .{why});
        return 1;
    }
    const osascript = x.get("--osascript") orelse "/usr/bin/osascript";
    var pt: nur.ProcessTransport = .{ .io = io };
    var env: nur.SystemEnv = .{ .io = io };
    var files: nur.SystemFiles = .{ .io = io };
    const run_env = seams.env orelse env.env();
    const transport = seams.transport orelse pt.transport();
    var mac = nur.MacBackend.init(a, transport, run_env, .{ .osascript = osascript });
    const backend = seams.backend orelse mac.backend();
    var rt = nur.Runtime.init(a, backend, run_env, files.files(), .{});
    var diag_mac = uidiag.MacBackend.init(a, transport, run_env, .{ .osascript = osascript });
    var diag_native: uidiag.NativeWindowBackend = undefined;
    var diag_backend: ?uidiag.Backend = seams.diag_backend orelse (if (seams.backend == null) diag_mac.backend() else null);
    if (@import("builtin").os.tag == .macos and seams.backend == null and seams.transport == null and seams.diag_backend == null) {
        diag_native = uidiag.NativeWindowBackend.init(a, &diag_mac, run_env);
        diag_backend = diag_native.backend();
    }
    var sys_menu: uidiag.SystemMenu = .{ .env = run_env };
    const menu_backend = seams.menu_backend orelse uidiag.systemMenuBackend(&sys_menu) orelse {
        d.err("needs_macos", "close-reference", "the Window menu activation needs macOS", .{});
        return 1;
    };
    // The only place that tolerates other document windows. It lists the titles that the operator named.
    var ui: UiWiring = .{ .rt = &rt, .backend = backend, .tolerated_documents = req.tolerated };
    const pid_of = seams.pid_path orelse nativePidPath;
    var n: NativeDriver = .{ .a = a, .io = io, .cfg = .{
        .pid = pid,
        .sender = sender,
        .osascript = osascript,
        .request_root = fmtA(a, "{s}/native-requests", .{dir}),
        .window_backend = diag_backend,
        .transport = seams.transport,
        .ui = &ui,
        .expected_executable = req.expected_executable,
        .pathOf = pid_of,
        .inflight_dir = dir,
    }, .doc = req.reference };
    var ro: ReferenceOps = .{ .a = a, .io = io, .n = &n, .menu = menu_backend, .env = run_env, .transport = transport, .pid = pid, .exe = req.expected_executable, .reference = req.reference, .marker_path = referenceMarkerPath(a, dir, req.reference), .marker_bytes = referenceMarkerBytes(a, io, req)  };
    const rep = orc.run(req, ro.ops());

    var rec = Obj.init(a);
    rec.str("schema", "vwx-rosetta-capture-reference-cleanup/1");
    rec.int("t_ms", nowMs(io));
    rec.int("pid", pid);
    rec.str("executable", req.expected_executable);
    rec.str("reference", req.reference);
    rec.str("reference_sha256_recorded", req.reference_sha256);
    rec.str("reference_sha256_before", rep.digest_before);
    rec.str("reference_sha256_after", rep.digest_after);
    var tol = arr(a);
    for (req.tolerated) |t| tol.append(.{ .string = t }) catch {};
    rec.put("tolerated_documents", .{ .array = tol });
    rec.boolean("allow_discard_unsaved", req.allow_discard);
    rec.str("operator_reason", req.reason);
    rec.str("outcome", @tagName(rep.outcome));
    rec.str("detail", rep.detail);
    rec.int("path_proofs", rep.proofs);
    rec.str("proof_detail", rep.proof_detail);
    rec.boolean("activated", rep.activated);
    rec.boolean("discarded", rep.discarded);
    rec.boolean("uncertain", rep.outcome == .uncertain);
    var acts = arr(a);
    for (rep.recorded()) |act| {
        var o = Obj.init(a);
        o.str("action", act.name);
        o.str("status", @tagName(act.status));
        o.boolean("uncertain", act.uncertain);
        o.str("detail", act.detail);
        acts.append(o.value()) catch {};
    }
    rec.put("dispatched_actions", .{ .array = acts });
    rec.boolean("saved", false);
    rec.boolean("deleted", false);
    rec.boolean("retried", false);
    rec.boolean("latch_cleared", false);
    rec.str("inflight_marker", ro.marker_path);
    rec.boolean("marker_created", rep.begun);
    const clean = rep.begun and (rep.outcome == .closed or rep.outcome == .stopped);
    rec.boolean("marker_removed_after_record", clean);
    release_lock = false;
    const k = try publishReferenceRecord(a, io, dir, stringify(a, rec.value()));
    const rp = fmtA(a, "{s}/cleanup-records/reference-{d}.json", .{ dir, k });
    // The marker goes only after the record is durable, and only when no dispatched action is unproven.
    if (clean) Dir.cwd().deleteFile(io, ro.marker_path) catch {};
    // The transient session exclusion goes with it. An unproven action keeps the lock, as it keeps the marker.
    release_lock = !rep.begun or clean;
    if (rep.outcome != .closed) {
        d.err("reference_not_closed", req.reference, "{s}: {s}{s}. {s}. The record is cleanup-records/reference-{d}.json", .{ @tagName(rep.outcome), rep.detail, if (rep.proof_detail.len > 0) fmtA(a, " ({s})", .{rep.proof_detail}) else "", if (rep.outcome == .uncertain) "The result of a dispatched action is unproven. The in-flight marker stays. Check the application by hand. Nothing is retried" else "No dispatched action changed the document", k });
        return 1;
    }
    try out.print("closed\t{s}\nrecord\t{s}\n", .{ req.reference, rp });
    return 0;
}

/// Clears the reconcile latch of a session. The caller names the reason. The latch file and the
/// reason are kept under `reconcile-history/`.
fn reconcileCommand(a: Allocator, io: Io, d: *Diags, dir: []const u8, reason: []const u8, out: *Io.Writer) !u8 {
    const names = [_][]const u8{ "RECONCILE.json", inflight_name };
    var present: std.ArrayList([]const u8) = .empty;
    for (names) |nm| {
        if (exists(io, fmtA(a, "{s}/{s}", .{ dir, nm }))) try present.append(a, nm);
    }
    if (present.items.len == 0) {
        d.err("no_latch", dir, "the session has no reconcile latch and no in-flight record", .{});
        return 1;
    }
    if (reason.len == 0) {
        d.err("reason_missing", "--reason", "clearing the latch needs a reason that names the reconciled app and output state", .{});
        return 1;
    }
    const hist = fmtA(a, "{s}/reconcile-history", .{dir});
    try mkdirp(io, hist);
    var n: usize = 1;
    while (exists(io, fmtA(a, "{s}/latch-{d}.json", .{ hist, n })) or exists(io, fmtA(a, "{s}/inflight-{d}.json", .{ hist, n }))) n += 1;
    var o = Obj.init(a);
    o.str("schema", schema_reconcile);
    o.str("cleared_reason", reason);
    o.int("cleared_at_ms", nowMs(io));
    try putSealed(a, io, fmtA(a, "{s}/clear-{d}.json", .{ hist, n }), stringify(a, o.value()));
    for (present.items) |nm| {
        const to = if (eql(nm, inflight_name)) fmtA(a, "{s}/inflight-{d}.json", .{ hist, n }) else fmtA(a, "{s}/latch-{d}.json", .{ hist, n });
        try Dir.rename(Dir.cwd(), fmtA(a, "{s}/{s}", .{ dir, nm }), Dir.cwd(), to, io);
    }
    try out.print("reconciled\t{d}\n", .{n});
    return 0;
}

/// Promotes a completed calibration-phase export to a calibration evidence record. The stage must
/// come from a native run of this executable on the macOS backend and name a bundle that verifies.
/// The bundle is copied under the evidence directory, the record is written at `<sha>.json` and a
/// route file with the claim filled in is written exclusively to `--routes-out`.
fn calibrationEvidenceCommand(a: Allocator, io: Io, d: *Diags, x: *const Args, dir: []const u8, rs: RouteSet, exe_sha: []const u8, out: *Io.Writer) !u8 {
    const case_id = x.get("--case-id") orelse return 2;
    const pid = x.get("--profile-id") orelse return 2;
    const cal_id = x.get("--calibration-id") orelse return 2;
    const ev_dir = x.get("--evidence-dir") orelse return 2;
    const routes_out = x.get("--routes-out") orelse return 2;
    if (!idOkLabel(cal_id)) {
        d.err("calibration_id_invalid", "--calibration-id", "the calibration id is 1 to 64 bytes of [A-Za-z0-9._-]", .{});
        return 1;
    }
    var attempt: u32 = 0;
    while (exists(io, fmtA(a, "{s}/cases/{s}/attempt-{d}", .{ dir, case_id, attempt + 1 }))) attempt += 1;
    if (attempt == 0) {
        d.err("stage_missing", case_id, "the case has no attempt", .{});
        return 1;
    }
    const ad = fmtA(a, "{s}/cases/{s}/attempt-{d}", .{ dir, case_id, attempt });
    const stage = readStage(a, io, ad, fmtA(a, "export-{s}", .{pid})) orelse {
        d.err("stage_missing", pid, "attempt {d} has no export stage for profile {s}", .{ attempt, pid });
        return 1;
    };
    const data = field(stage, "data") orelse .null;
    const rinfo = field(field(data, "result") orelse .null, "route") orelse .null;
    const bundle = bundleOf(data) orelse {
        d.err("evidence_refused", pid, "the stage holds no sealed bundle", .{});
        return 1;
    };
    if (!eql(strField(stage, "status") orelse "", "ok") or !eql(strField(data, "phase") orelse "", "calibration") or !eql(strField(rinfo, "mode") orelse "", "ui") or !eql(strField(rinfo, "backend") orelse "", "mac")) {
        d.err("evidence_refused", pid, "evidence needs an ok calibration-phase export from a UI route on the macOS backend", .{});
        return 1;
    }
    if (!eql(strField(data, "executable_sha256") orelse "", exe_sha)) {
        d.err("evidence_refused", pid, "the stage was written by another executable", .{});
        return 1;
    }
    const ur = rs.byId(strField(rinfo, "route_id") orelse "") orelse {
        d.err("evidence_refused", pid, "the loaded route set has no route `{s}`", .{strField(rinfo, "route_id") orelse ""});
        return 1;
    };
    if (!eql(strField(rinfo, "route_sha256") orelse "", ur.route_sha256)) {
        d.err("evidence_refused", pid, "the typed route changed after the calibration export", .{});
        return 1;
    }
    const binding: nur.Binding = .{
        .release = strField(rinfo, "release") orelse "",
        .workspace = strField(rinfo, "workspace") orelse "",
        .profile_hash = strField(data, "profile_sha256") orelse "",
        .source_digest = strField(data, "source_sha256") orelse "",
        .state_digest = strField(data, "state_sha256") orelse "",
    };
    nur.validateBinding(binding, .{}) catch {
        d.err("evidence_refused", pid, "the stage binding is malformed", .{});
        return 1;
    };
    if (!isLowerHex64(strField(data, "options_sha256") orelse "")) {
        d.err("evidence_refused", pid, "the stage records no options_sha256. Run the calibration again with this executable", .{});
        return 1;
    }
    var sidecars: std.ArrayList([]const u8) = .empty;
    for (arrField(bundle, "sidecars")) |sc| try sidecars.append(a, strField(sc, "path") orelse "");
    const src_dir = fmtA(a, "{s}/{s}", .{ ad, strField(bundle, "dir") orelse "" });
    var ver = try opdir.verify(a, io, src_dir, .{
        .op_id = strField(bundle, "op_id"),
        .format = nur.formatId(ur.format),
        .main_file = strField(bundle, "main_file"),
        .bindings = .{ .source_sha256 = binding.source_digest, .state_sha256 = binding.state_digest, .profile_id = pid, .profile_sha256 = binding.profile_hash },
    }, .{});
    defer ver.deinit();
    if (!ver.isVerified()) {
        d.err("evidence_refused", pid, "the bundle is {s}: {s}", .{ @tagName(ver.status), ver.reason });
        return 1;
    }
    const rel = fmtA(a, "bundles/{s}", .{cal_id});
    const dst_dir = fmtA(a, "{s}/{s}", .{ ev_dir, rel });
    try mkdirp(io, dst_dir);
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(a, opdir.open_name);
    try names.append(a, opdir.manifest_name);
    try names.append(a, opdir.seal_name);
    for (ver.sealed.?.manifest.files) |f| try names.append(a, f.path);
    for (names.items) |nm| {
        const to = fmtA(a, "{s}/{s}", .{ dst_dir, nm });
        try mkdirp(io, dirname(to));
        try copyNew(io, fmtA(a, "{s}/{s}", .{ src_dir, nm }), to);
        try seal(io, to);
    }
    var eo = Obj.init(a);
    eo.str("schema", schema_evidence);
    eo.str("calibration_id", cal_id);
    eo.str("route_id", ur.id);
    eo.str("route_sha256", ur.route_sha256);
    eo.str("format", nur.formatId(ur.format));
    var bo = Obj.init(a);
    bo.str("release", binding.release);
    bo.str("workspace", binding.workspace);
    bo.str("profile_hash", binding.profile_hash);
    bo.str("source_digest", binding.source_digest);
    bo.str("state_digest", binding.state_digest);
    eo.put("binding", bo.value());
    eo.str("profile_id", pid);
    eo.str("options_sha256", strField(data, "options_sha256") orelse "");
    eo.str("executable_sha256", exe_sha);
    eo.str("backend", "mac");
    var bu = Obj.init(a);
    bu.str("dir", rel);
    bu.str("op_id", strField(bundle, "op_id") orelse "");
    bu.str("main_file", strField(bundle, "main_file") orelse "");
    bu.str("manifest_sha256", &ver.sealed.?.manifest_sha256);
    eo.put("bundle", bu.value());
    const report = field(rinfo, "report") orelse .null;
    eo.put("options", field(report, "options") orelse .{ .array = arr(a) });
    eo.put("files", field(report, "files") orelse .{ .array = arr(a) });
    var mo = Obj.init(a);
    mo.put("export_ms", field(report, "elapsed_ms") orelse .null);
    eo.put("measurements", mo.value());
    const text = stringify(a, eo.value());
    const sha = sha256Hex(text);
    try mkdirp(io, ev_dir);
    try writeNew(io, fmtA(a, "{s}/{s}.json", .{ ev_dir, &sha }), text);
    // The route file with the claim and the calibrated binding.
    var list: std.ArrayList(UiRoute) = .empty;
    for (rs.routes) |r| {
        var c = r;
        if (eql(r.id, ur.id)) {
            c.route.binding = binding;
            c.route.status = .calibrated;
            c.calibration_id = try a.dupe(u8, cal_id);
            c.evidence_sha256 = try a.dupe(u8, &sha);
        }
        try list.append(a, c);
    }
    try writeNew(io, routes_out, stringify(a, routeSetJson(a, .{ .release = rs.release, .workspace = rs.workspace, .routes = list.items })));
    try out.print("evidence\t{s}\t{s}\t{s}\n", .{ cal_id, &sha, routes_out });
    return 0;
}

fn idOkLabel(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

pub const usage_text =
    \\usage: vwx rosetta-capture <command> ...
    \\  plan <queue.json> <generated-dir> <inventory-dir> <session> [--template <blank.vwx>] [--entries <entries.json>]
    \\       [--scripts <script-base-dir>] [--controls <controls-queue.json>] [--stop-on-failure]
    \\  run <session> --driver fake --fake <spec.json> [engine options]
    \\  run <session> --driver native --pid <pid> --sender <path> --operator-authorized [--osascript <path>] [--timeout-ms <n>]
    \\      --activation-packet <packet.json> --activation-input queue=<path> --activation-input profiles=<path>
    \\      --activation-input recipes=<path> --routes <routes.json> --evidence-dir <dir> --release <label>
    \\      --workspace <label> --phase calibration|verified [--scratch-session <id>] [--completion <record.json>]
    \\      [--expansion] [--allow-conversion-ack] [--allow-watermark-ack] [--expect-converted] [--expect-watermark]
    \\      [engine options]   A native run needs every named option. No switch skips the activation gate.
    \\  resume <session> ...           same options as run. Verified cases are not regenerated.
    \\  close-scratch <session> --pid <pid> --sender <path> --expected-executable <path> --scratch <abs path>
    \\                --sealed-source <abs path> --sealed-source-sha256 <hex> --reason <text> --operator-authorized
    \\                closes one stranded export scratch copy through the guarded close, never saves and
    \\                never clears the latch. Writes cleanup-records/close-<n>.json
    \\  close-reference <session> --pid <pid> --sender <path> --expected-executable <path> --reference <abs path>
    \\                --reference-sha256 <hex> [--tolerate-document <title.vwx>]... [--allow-discard-unsaved]
    \\                --reason <text> --operator-authorized
    \\                closes one task-owned standalone reference document. The path is a canonical .vwx file in a
    \\                mktemp directory below /Volumes/volxxxx/Caches/tmp or /private/tmp. The operator supplies the
    \\                recorded digest. Window > title activates it when another document is active. The SDK path is
    \\                proven after the activation and again before File > Close. Never saves, deletes or retries.
    \\                Writes cleanup-records/reference-<n>.json
    \\  reconcile <session> --reason <text>   clears the latch that an uncertain action left
    \\  status <session>
    \\  finalize <session> <pack-skeleton-dir> <out-dir> [--release <release.json>] [--cases <selection.json>]
    \\  skeleton <session> <out-dir>    pack skeleton of the existing-document cases
    \\  check-binding <attempt-dir>     source, state, raw, frame and occurrence binding of native records
    \\  packet <out-dir>
    \\  capabilities [<preflight.json>]
    \\  wiring                          the implementation behind each compiled feature and route
    \\  routes-check <routes.json> [--evidence-dir <dir>]   typed route file and its evidence claims
    \\  expansion-check <session> --completion <record.json> --routes <routes.json> --evidence-dir <dir>
    \\      --release <label> --workspace <label>
    \\  calibration-evidence <session> --case-id <id> --profile-id <id> --calibration-id <id> --routes <routes.json>
    \\      --routes-out <routes.json> --evidence-dir <dir>   promotes a calibration-phase export from the macOS backend
    \\  native-inventory --pid <pid> --operator-authorized --document <name.vwx> --out-dir <dir> [--route <id>]
    \\      with the activation options above and --phase inventory
    \\  readiness <vs.py> <inventory-readiness.json> <out-dir> <owner>=<queue.json>...
    \\engine options: --max-attempts <n> --retries <n> --settle-ms <n> --sources <sources.json>
    \\  --operator-exports [--operator-timeout-ms <n>]   operator export step for formats without a scripting entry. Fake runs only
    \\  --stop-on-failure   exit 3 after the first case that is not done. The next case does not start
    \\exit status: 0 complete, 1 invalid or a case failed, 2 usage, 3 stopped for operator action
    \\
;

const Args = struct {
    pos: std.ArrayList([]const u8) = .empty,
    opts: std.StringHashMapUnmanaged([]const u8) = .empty,
    flags: std.StringHashMapUnmanaged(void) = .empty,
    /// Each `--activation-input <id>=<path>`.
    inputs: std.ArrayList([]const u8) = .empty,
    /// Each `--tolerate-document <title.vwx>`.
    tolerated: std.ArrayList([]const u8) = .empty,

    fn get(x: *const Args, k: []const u8) ?[]const u8 {
        return x.opts.get(k);
    }

    fn int(x: *const Args, k: []const u8, default: u32) ?u32 {
        const v = x.get(k) orelse return default;
        return std.fmt.parseInt(u32, v, 10) catch null;
    }
};

const value_opts = [_][]const u8{ "--expected-executable", "--scratch", "--sealed-source", "--sealed-source-sha256", "--template", "--entries", "--scripts", "--controls", "--sources", "--driver", "--fake", "--pid", "--sender", "--osascript", "--timeout-ms", "--operator-timeout-ms", "--max-attempts", "--retries", "--settle-ms", "--release", "--cases", "--activation-packet", "--activation-input", "--routes", "--evidence-dir", "--workspace", "--phase", "--scratch-session", "--completion", "--reason", "--out-dir", "--document", "--route", "--calibration-id", "--routes-out", "--case-id", "--profile-id", "--reference", "--reference-sha256", "--tolerate-document" };
const flag_opts = [_][]const u8{ "--operator-authorized", "--operator-exports", "--stop-on-failure", "--expansion", "--allow-conversion-ack", "--allow-watermark-ack", "--expect-converted", "--expect-watermark", "--allow-discard-unsaved" };

fn parseArgs(a: Allocator, argv: []const []const u8) ?Args {
    var x: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (inList(&flag_opts, s)) {
            x.flags.put(a, s, {}) catch return null;
        } else if (inList(&value_opts, s)) {
            if (i + 1 >= argv.len) return null;
            i += 1;
            if (eql(s, "--activation-input")) {
                x.inputs.append(a, argv[i]) catch return null;
            } else if (eql(s, "--tolerate-document")) {
                x.tolerated.append(a, argv[i]) catch return null;
            } else x.opts.put(a, s, argv[i]) catch return null;
        } else if (std.mem.startsWith(u8, s, "--")) {
            return null;
        } else x.pos.append(a, s) catch return null;
    }
    return x;
}

fn absPath(a: Allocator, io: Io, p: []const u8) ![]const u8 {
    if (p.len > 0 and p[0] == '/') return p;
    const cwd = try Dir.cwd().realPathFileAlloc(io, ".", a);
    return fmtA(a, "{s}/{s}", .{ cwd, p });
}

/// Runs one command with the legacy test-seam behavior. `--driver native` here keeps the operator
/// authorization gate only. Diagnostics and a `result` line go to `out`, which is flushed.
pub fn runCli(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    return runWithMode(gpa, io, argv, out, false);
}

/// Runs one command with the production requirements. `vwx rosetta-capture` calls it. `--driver
/// native` then needs the activation gate, the typed route file, the evidence directory and an
/// explicit phase. No switch skips them.
pub fn runCliProduction(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    return runWithMode(gpa, io, argv, out, true);
}

fn runWithMode(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer, production: bool) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d = Diags.init(a);
    const st = runCommand(a, io, &d, argv, out, production) catch |e| blk: {
        d.err("failed", "vwx rosetta-capture", "{s}", .{@errorName(e)});
        break :blk @as(u8, 1);
    };
    d.write(out) catch {};
    const final: u8 = if (st == 2 or st == exit_stopped) st else if (st != 0 or d.errors() > 0) 1 else 0;
    out.print("result\t{s}\n", .{switch (final) {
        0 => "valid",
        1 => "invalid",
        2 => "usage",
        else => "stopped",
    }}) catch {};
    out.flush() catch {};
    return final;
}

fn usage(out: *Io.Writer) u8 {
    out.writeAll(usage_text) catch {};
    return 2;
}

fn runCommand(a: Allocator, io: Io, d: *Diags, argv: []const []const u8, out: *Io.Writer, production: bool) !u8 {
    if (argv.len == 0) return usage(out);
    const cmd = argv[0];
    const x = parseArgs(a, argv[1..]) orelse return usage(out);
    const P = x.pos.items;
    if (eql(cmd, "plan")) {
        if (P.len != 4) return usage(out);
        try plan(a, io, d, .{ .queue = P[0], .generated = P[1], .inventory = P[2], .session = try absPath(a, io, P[3]), .template = x.get("--template"), .entries = x.get("--entries"), .scripts = x.get("--scripts"), .controls = x.get("--controls"), .stop_on_failure = x.flags.get("--stop-on-failure") != null }, out);
        return 0;
    }
    if (eql(cmd, "run") or eql(cmd, "resume")) {
        if (P.len != 1) return usage(out);
        var cfg: Config = .{
            .max_attempts = x.int("--max-attempts", 3) orelse return usage(out),
            .retries = x.int("--retries", 2) orelse return usage(out),
            .settle_ms = x.int("--settle-ms", 0) orelse return usage(out),
            .operator_exports = x.flags.get("--operator-exports") != null,
            .stop_on_failure = x.flags.get("--stop-on-failure") != null,
        };
        const dir = try absPath(a, io, P[0]);
        const s = loadSession(a, io, d, dir) orelse return 1;
        const kind = std.meta.stringToEnum(DriverKind, x.get("--driver") orelse "") orelse return usage(out);
        var fake: FakeDriver = undefined;
        var native: NativeDriver = undefined;
        var prod: ?*Production = null;
        const drv: Driver = switch (kind) {
            .fake => blk: {
                const sp = x.get("--fake") orelse return usage(out);
                fake = FakeDriver.initSpec(a, io, d, try readAll(a, io, sp), sp) orelse return 1;
                break :blk fake.driver();
            },
            .native => blk: {
                if (x.flags.get("--operator-authorized") == null) {
                    d.err("not_authorized", "--driver native", "native runs need --operator-authorized. The operator starts the app. This program does not launch it", .{});
                    return 1;
                }
                const pid = std.fmt.parseInt(i32, x.get("--pid") orelse return usage(out), 10) catch return usage(out);
                const sender = x.get("--sender") orelse return usage(out);
                const osascript = x.get("--osascript") orelse "/usr/bin/osascript";
                if (production) {
                    // The production requirements run before the first native call.
                    prod = (try setupProduction(a, io, d, &x, osascript)) orelse return 1;
                    if (prod.?.strict.phase == .inventory) {
                        d.err("strict_requirement_violated", "--phase", "the inventory phase runs through native-inventory. A capture run uses calibration or verified", .{});
                        return 1;
                    }
                    if (!expansionGate(a, io, d, &x, &s, prod.?)) return 1;
                    cfg.bundle_exports = true;
                    cfg.strict = &prod.?.strict;
                    // The packet attempt limit bounds the tries of one operation.
                    if (prod.?.budgets) |b| cfg.retries = @min(cfg.retries, if (b.max_attempts_per_operation > 0) b.max_attempts_per_operation - 1 else 0);
                }
                const op_asked = x.int("--timeout-ms", 600_000) orelse return usage(out);
                const op_eff: u32 = if (prod) |p| (if (p.budgets) |b| @intCast(@min(op_asked, b.operation_deadline_ms)) else op_asked) else op_asked;
                native = .{ .a = a, .io = io, .cfg = .{
                    .pid = pid,
                    .sender = sender,
                    .osascript = osascript,
                    .request_root = fmtA(a, "{s}/native-requests", .{dir}),
                    .op_timeout_ms = op_eff,
                    .operator_timeout_ms = x.int("--operator-timeout-ms", 1_800_000) orelse return usage(out),
                    .window_backend = if (prod) |p| p.diag_backend else null,
                    .transport = if (production) seams.transport else null,
                    .ui = if (prod) |p| &p.ui else null,
                    .extended_state = prod != null,
                    .expected_executable = x.get("--expected-executable") orelse "",
                    .pathOf = seams.pid_path orelse nativePidPath,
                    .inflight_dir = dir,
                } };
                break :blk native.driver();
            },
        };
        // The observer subscription ends on every exit of the run.
        defer if (prod) |p| p.observer.dispose();
        var e: Engine = .{ .a = a, .io = io, .d = d, .s = &s, .drv = drv, .cfg = cfg, .out = out };
        if (prod) |p| {
            // The in-flight record lives in the session. The runtime and the engine share it. The run
            // budget starts here, after the offline gates.
            const fj = try a.create(InflightFile);
            fj.* = .{ .io = io, .dir = dir };
            e.inflight = fj;
            p.rt.journal = fj.journal();
            p.rt.restartRun();
            installAdapters(a, io, p, dir);
        }
        if (x.get("--sources")) |sp| {
            e.sources = parseJson(a, try readAll(a, io, sp)) catch {
                d.err("invalid_json", sp, "sources file does not parse", .{});
                return 1;
            };
            if (e.sources != .object) {
                d.err("schema_type", sp, "sources file is not an object of case_id to path", .{});
                return 1;
            }
        }
        const r = try e.run();
        if (r == exit_stopped) try out.print("stopped\t{s}\n", .{e.stop_reason});
        return r;
    }
    if (eql(cmd, "status")) {
        if (P.len != 1) return usage(out);
        try statusReport(a, io, d, try absPath(a, io, P[0]), out);
        return 0;
    }
    if (eql(cmd, "finalize")) {
        if (P.len != 3) return usage(out);
        try finalize(a, io, d, .{ .session = try absPath(a, io, P[0]), .skeleton = P[1], .out = P[2], .release = x.get("--release"), .cases = x.get("--cases") }, out);
        return 0;
    }
    if (eql(cmd, "skeleton")) {
        if (P.len != 2) return usage(out);
        try skeleton(a, io, d, try absPath(a, io, P[0]), P[1], out);
        return 0;
    }
    if (eql(cmd, "check-binding")) {
        if (P.len != 1) return usage(out);
        const probs = checkBinding(a, io, P[0]);
        for (probs) |b| d.err(b.code, b.where, "{s}", .{b.msg});
        try out.print("summary\tbinding_problems\t{d}\n", .{probs.len});
        return if (probs.len == 0) 0 else 1;
    }
    if (eql(cmd, "packet")) {
        if (P.len != 1) return usage(out);
        try packet(a, io, d, P[0], out);
        return 0;
    }
    if (eql(cmd, "readiness")) {
        if (P.len < 4) return usage(out);
        var queues: std.ArrayList(ReadinessQueue) = .empty;
        for (P[3..]) |qa| {
            const eq = std.mem.indexOfScalar(u8, qa, '=') orelse return usage(out);
            if (eq == 0 or eq + 1 == qa.len) return usage(out);
            try queues.append(a, .{ .owner = qa[0..eq], .path = qa[eq + 1 ..] });
        }
        try readiness(a, io, d, .{ .vs_py = P[0], .inventory_readiness = P[1], .out = P[2], .queues = queues.items }, out);
        return 0;
    }
    if (eql(cmd, "capabilities")) {
        if (P.len > 1) return usage(out);
        const pre: ?json.Value = if (P.len == 1) parseJson(a, try readAll(a, io, P[0])) catch {
            d.err("invalid_json", P[0], "preflight file does not parse", .{});
            return 1;
        } else null;
        const entries = parseEntries(a, d, default_entries, "default entries");
        try out.writeAll(stringify(a, capabilities(a, entries, pre)));
        return 0;
    }
    if (eql(cmd, "wiring")) {
        if (P.len != 0) return usage(out);
        try writeWiring(a, out);
        return 0;
    }
    if (eql(cmd, "routes-check")) {
        if (P.len != 1) return usage(out);
        const bytes = Dir.cwd().readFileAlloc(io, P[0], a, .limited(max_route_bytes)) catch |err| {
            d.err("routes_malformed", P[0], "cannot read the route file: {s}", .{@errorName(err)});
            return 1;
        };
        const rs = parseRouteSet(a, d, bytes, P[0]) orelse return 1;
        const exe_sha = exeDigest(a, io, d, try runningExe(a, io)) orelse return 1;
        for (rs.routes) |*r| {
            var verdict: []const u8 = "no_evidence";
            if (r.evidence_sha256.len > 0 or r.route.status == .calibrated) verdict = switch (loadEvidence(a, io, r, x.get("--evidence-dir") orelse "", exe_sha)) {
                .ok => "resolved",
                .problem => |p| p.code,
            };
            try out.print("route\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ r.id, nur.formatId(r.format), @tagName(r.route.status), if (nur.isTargeted(r.format)) "targeted" else "required", verdict });
        }
        return 0;
    }
    if (eql(cmd, "expansion-check")) {
        if (P.len != 1) return usage(out);
        const s = loadSession(a, io, d, try absPath(a, io, P[0])) orelse return 1;
        const rec = x.get("--completion") orelse return usage(out);
        const rp = x.get("--routes") orelse return usage(out);
        const bytes = Dir.cwd().readFileAlloc(io, rp, a, .limited(max_route_bytes)) catch |err| {
            d.err("routes_malformed", rp, "cannot read the route file: {s}", .{@errorName(err)});
            return 1;
        };
        const rs = parseRouteSet(a, d, bytes, rp) orelse return 1;
        const exe_sha = exeDigest(a, io, d, try runningExe(a, io)) orelse return 1;
        const dg = sessionDigests(a, &s.queue);
        const ok = checkCompletion(a, io, d, .{
            .record_path = rec,
            .exe_sha256 = exe_sha,
            .queue_sha256 = s.queue.sha256,
            .profiles_sha256 = dg.profiles,
            .recipes_sha256 = dg.recipes,
            .release = x.get("--release") orelse return usage(out),
            .workspace = x.get("--workspace") orelse return usage(out),
            .routes = &rs,
            .evidence_dir = x.get("--evidence-dir") orelse return usage(out),
            .formats = sessionFormats(a, &s.queue),
            .families = sessionFamilies(a, &s.queue),
            .options = sessionOptions(a, &s.queue),
        });
        try out.print("expansion\t{s}\n", .{if (ok) "allowed" else "refused"});
        return if (ok) 0 else 1;
    }
    if (eql(cmd, "close-scratch")) {
        if (P.len != 1) return usage(out);
        if (!production) {
            d.err("strict_requirement_violated", "close-scratch", "the cleanup runs through the production wiring", .{});
            return 1;
        }
        return closeScratchCommand(a, io, d, &x, try absPath(a, io, P[0]), out);
    }
    if (eql(cmd, "close-reference")) {
        if (P.len != 1) return usage(out);
        if (!production) {
            d.err("strict_requirement_violated", "close-reference", "the cleanup runs through the production wiring", .{});
            return 1;
        }
        return closeReferenceCommand(a, io, d, &x, try absPath(a, io, P[0]), out);
    }
    if (eql(cmd, "reconcile")) {
        if (P.len != 1) return usage(out);
        return reconcileCommand(a, io, d, try absPath(a, io, P[0]), x.get("--reason") orelse "", out);
    }
    if (eql(cmd, "calibration-evidence")) {
        if (P.len != 1) return usage(out);
        const rp = x.get("--routes") orelse return usage(out);
        const bytes = Dir.cwd().readFileAlloc(io, rp, a, .limited(max_route_bytes)) catch |err| {
            d.err("routes_malformed", rp, "cannot read the route file: {s}", .{@errorName(err)});
            return 1;
        };
        const rs = parseRouteSet(a, d, bytes, rp) orelse return 1;
        const exe_sha = exeDigest(a, io, d, try runningExe(a, io)) orelse return 1;
        return calibrationEvidenceCommand(a, io, d, &x, try absPath(a, io, P[0]), rs, exe_sha, out);
    }
    if (eql(cmd, "native-inventory")) {
        if (P.len != 0) return usage(out);
        if (!production) {
            d.err("strict_requirement_violated", "native-inventory", "the inventory command runs through the production wiring", .{});
            return 1;
        }
        if (x.flags.get("--operator-authorized") == null) {
            d.err("not_authorized", "native-inventory", "native inventory needs --operator-authorized. The operator starts the app", .{});
            return 1;
        }
        const pid = std.fmt.parseInt(i32, x.get("--pid") orelse return usage(out), 10) catch return usage(out);
        const prod = (try setupProduction(a, io, d, &x, x.get("--osascript") orelse "/usr/bin/osascript")) orelse return 1;
        if (prod.strict.phase != .inventory) {
            d.err("strict_requirement_violated", "--phase", "native-inventory runs the inventory phase", .{});
            return 1;
        }
        const out_dir = try absPath(a, io, x.get("--out-dir") orelse return usage(out));
        // The inventory presses menu and cancel controls. It keeps the in-flight record in its output
        // directory. A record from an earlier interrupted inventory refuses the start.
        const fj = try a.create(InflightFile);
        fj.* = .{ .io = io, .dir = out_dir };
        if (exists(io, fj.path(a))) {
            d.err("inflight_pending", fj.path(a), "an earlier inventory left an in-flight record. Reconcile the app and move the record before a new inventory", .{});
            return 1;
        }
        prod.rt.journal = fj.journal();
        prod.rt.restartRun();
        installAdapters(a, io, prod, out_dir);
        // The observer subscribes before the first menu press and ends its subscription on every exit.
        defer prod.observer.dispose();
        return runInventory(a, io, d, .{
            .rt = &prod.rt,
            .routes = &prod.routes,
            .pid = pid,
            .document = x.get("--document") orelse return usage(out),
            .out_dir = out_dir,
            .only = x.get("--route"),
        }, out);
    }
    return usage(out);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(Engine);
    testing.refAllDecls(FakeDriver);
    testing.refAllDecls(NativeDriver);
}

test "sniffExport detects truncated outputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (formats) |f| {
        const whole = fakeExport(a, f.name, "x.vwx");
        try testing.expect(sniffExport(f.name, whole).ok);
    }
    for ([_][]const u8{ "dxf", "sat", "stl", "gltf", "3ds", "pdf", "svg", "png" }) |name| {
        const whole = fakeExport(a, name, "x.vwx");
        const s = sniffExport(name, whole[0 .. whole.len / 2]);
        try testing.expect(!s.ok);
    }
    try testing.expectEqualStrings("empty_export", sniffExport("sat", "").code);
}

test "normalizeRaw binds hashes, frames and occurrence paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"rec":"meta","schema":"vwx-m3d-native-raw/1","case_id":"c","file":"f.vwx","version":{"v":[31,0,0]},"units":{"v":[0,0,0,25.4,"mm","sq mm"]},"origin":{"v":[0,0]}}
        \\{"rec":"layer","index":1,"name":"L","elevation":{"v":0}}
        \\{"rec":"layer","index":2,"name":"Up","elevation":{"v":300}}
        \\{"rec":"object","walk_id":"1.1","occurrence_path":[],"root":"1","root_kind":"layer","td":15,"layer":"L","class":"None","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[[1,2],3]},"orient3d":{"v":[true,0,0,90,false]},"symbol":{"name":"S","loc3d":{"v":[[10,0],0]},"rot":{"v":90},"flipped":{"v":0},"scale_type":{"v":1}},"geom":{}}
        \\{"rec":"object","walk_id":"def:S.d1","occurrence_path":["1.1"],"root":"def:S","root_kind":"occurrence","td":111,"layer":"L","class":"None","name":{"v":"c"},"vis":{"object":{"v":2},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"err":"absent"},"geom":{"nurbs_curve":{"degree":{"v":1},"pieces":1,"piece":[{"num_pts":2,"num_knots":4,"points":[{"v":[0,0,0]},{"v":[1,0,0]}],"weights":[{"v":1},{"v":1}],"knots":[{"v":0},{"v":0},{"v":1},{"v":1}]}]}}}
        \\{"rec":"object","walk_id":"2.1","occurrence_path":[],"root":"2","root_kind":"layer","td":15,"layer":"Up","class":"None","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"symbol":{"name":"S","loc3d":{"v":[0,0,0]},"rot":{"v":0},"flipped":{"v":0}},"geom":{"wall":{}}}
        \\{"rec":"object","walk_id":"def:S.d1","occurrence_path":["2.1"],"root":"def:S","root_kind":"occurrence","td":111,"layer":"Up","class":"None","name":{"v":"c"},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"geom":{}}
        \\{"rec":"end","status":"ok","rows":8}
        \\
    ;
    const src = "a" ** 64;
    const st = "b" ** 64;
    const n = try normalizeRaw(a, .{ .case_id = "c", .source_sha256 = src, .state_sha256 = st, .raw = raw });
    try std.testing.expectEqualStrings("ok", n.raw_end);
    const occ = hashedId(a, "occ", "1.1");
    try std.testing.expect(std.mem.indexOf(u8, n.frames, occ) != null);
    try std.testing.expect(std.mem.indexOf(u8, n.frames, hashedId(a, "layer", "2")) != null);
    try std.testing.expect(std.mem.indexOf(u8, n.frames, hashedId(a, "occ", "2.1")) == null);
    try std.testing.expect(std.mem.indexOf(u8, n.ledger, "\"status\":\"unresolved_transform\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, n.ledger, "\"status\":\"unsupported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, n.ledger, "code 2 has no visibility mapping") != null);
    try std.testing.expect(std.mem.indexOf(u8, n.measurements, "\"component\":\"piece:0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, n.measurements, "\"occurrence_path\":[\"1.1\"]") != null);
    try std.testing.expect(n.measured > 0 and n.gaps == 4);
    const bad = try normalizeRaw(a, .{ .case_id = "c", .source_sha256 = src, .state_sha256 = st, .raw = raw[0 .. std.mem.lastIndexOf(u8, raw[0 .. raw.len - 1], "\n").? + 1] });
    try std.testing.expectEqualStrings("the raw file has no end row", bad.raw_end);
}

test "normalizeRaw keeps a boolean visibility and gives a duplicated layer index its own frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"rec":"meta","schema":"vwx-m3d-native-raw/1","case_id":"c","file":"f.vwx","version":{"v":[31,0,0]},"units":{"v":[0,0,0,25.4,"mm","sq mm"]},"origin":{"v":[0,0]}}
        \\{"rec":"layer","index":1,"name":"L","elevation":{"v":0}}
        \\{"rec":"layer","index":1,"name":"L","elevation":{"v":0}}
        \\{"rec":"layer","index":2,"name":"M","elevation":{"v":0}}
        \\{"rec":"object","walk_id":"1.1","occurrence_path":[],"root":"1","root_kind":"layer","td":15,"layer":"L","class":"None","name":{"v":""},"vis":{"object":{"v":true},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"symbol":{"name":"S","loc3d":{"v":[0,0,0]},"rot":{"v":0},"flipped":{"v":0},"scale_type":{"v":1}},"geom":{}}
        \\{"rec":"object","walk_id":"2.1","occurrence_path":[],"root":"2","root_kind":"layer","td":15,"layer":"M","class":"None","name":{"v":""},"vis":{"object":{"v":false},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"geom":{}}
        \\{"rec":"end","status":"ok","rows":6}
        \\
    ;
    const n = try normalizeRaw(a, .{ .case_id = "c", .source_sha256 = "a" ** 64, .state_sha256 = "b" ** 64, .raw = raw });
    try std.testing.expect(std.mem.indexOf(u8, n.ledger, "has no visibility mapping") == null);
    try std.testing.expect(std.mem.indexOf(u8, n.measurements, "\"component\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, n.frames, hashedId(a, "layer", "1")) != null);
    try std.testing.expect(std.mem.indexOf(u8, n.frames, hashedId(a, "layer", "2")) == null);
}

test "normalizeRaw measures documented wall, mesh and surface channels and refuses the others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head =
        \\{"rec":"meta","schema":"vwx-m3d-native-raw/1","case_id":"c","file":"f.vwx","version":{"v":[31,0,0]},"units":{"v":[0,0,0,25.4,"mm","sq mm"]},"origin":{"v":[0,0]}}
        \\{"rec":"layer","index":1,"name":"L","elevation":{"v":0}}
        \\
    ;
    const body =
        \\{"rec":"object","walk_id":"1.1","occurrence_path":[],"root":"1","root_kind":"layer","td":68,"layer":"L","class":"W","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":2},"layer":{"v":-1}},"cntr3d":{"v":[0,0,0]},"geom":{"wall":{"p1":{"v":[0,0]},"p2":{"v":[1000,0]},"thickness":{"v":[true,100]},"height":{"v":[2400,0,2400,0]},"heights":{"err":"absent"}}}}
        \\{"rec":"object","walk_id":"1.2","occurrence_path":[],"root":"1","root_kind":"layer","td":40,"layer":"L","class":"W","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"geom":{"mesh":{"count_api":"GetMeshVertsCnt","count":{"v":2},"vertnum":{"v":2},"vertices":[{"v":[0,0,0]},{"v":[[1,0],0]}]}}}
        \\{"rec":"object","walk_id":"1.3","occurrence_path":[],"root":"1","root_kind":"layer","td":40,"layer":"L","class":"W","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"geom":{"mesh":{"count":0,"vertnum":{"v":0},"vertices":[]}}}
        \\{"rec":"object","walk_id":"1.4","occurrence_path":[],"root":"1","root_kind":"layer","td":114,"layer":"L","class":"W","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"geom":{"nurbs_surface":{"degree":[{"v":1},{"v":2}],"num_pts":[2,3],"knots":[[{"v":0}],[{"v":1}]],"points":[[{"v":[0,0,0]},{"v":[0,1,0]}],[{"v":[1,0,0]},{"v":[1,1,0]}]],"weights":[[{"v":1},{"v":1}],[{"v":1},{"v":1}]]}}}
        \\{"rec":"object","walk_id":"1.5","occurrence_path":[],"root":"1","root_kind":"layer","td":114,"layer":"L","class":"W","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"geom":{"nurbs_surface":{"axes":"uv","degree":[{"v":3},{"v":1}],"num_pts":[1,2],"knots":[[{"v":7}],[{"v":8}]],"points":[[{"v":[0,0,0]},{"v":[0,1,0]}]],"weights":[[{"v":1},{"v":1}]]}}}
        \\{"rec":"end","status":"ok","rows":7}
        \\
    ;
    const n = try normalizeRaw(a, .{ .case_id = "c", .source_sha256 = "a" ** 64, .state_sha256 = "b" ** 64, .raw = head ++ body });
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    try testing.expect(has(n.measurements, "\"component\":\"wall.thickness\""));
    try testing.expect(has(n.measurements, "\"component\":\"wall.height.end_bottom\""));
    try testing.expect(has(n.ledger, "\"component\":\"wall.p1\",\"frame_id\":\"document_world\",\"status\":\"unsupported\""));
    try testing.expect(has(n.ledger, "vs.py has no GetWallHeights"));
    try testing.expect(has(n.ledger, "code 2 is Grayed"));
    try testing.expect(has(n.measurements, "\"component\":\"layer\",\"frame_id\":\"document_world\",\"units\":\"none\",\"value\":false"));
    try testing.expect(has(n.measurements, "\"component\":\"mesh.vertices\",\"frame_id\":\"document_world\",\"units\":\"1\",\"value\":2"));
    try testing.expect(has(n.measurements, "\"component\":\"mesh.vertex:1\",\"frame_id\":\"document_world\",\"units\":\"mm\",\"value\":[1,0,0]"));
    try testing.expect(has(n.ledger, "no count_api GetMeshVertsCnt"));
    try testing.expect(has(n.ledger, "GetVertNum is documented for polygons"));
    try testing.expect(has(n.ledger, "surface_axis_order: NurbsGetNumPts gives v 2 and u 3"));
    // The legacy row lists degree [v, u], so degree.u is the second entry.
    try testing.expect(has(n.measurements, "\"object_id\":\"1.4\",\"occurrence_path\":[],\"quantity\":\"count\",\"component\":\"degree.u\",\"frame_id\":\"document_world\",\"units\":\"1\",\"value\":2"));
    try testing.expect(has(n.measurements, "\"object_id\":\"1.5\",\"occurrence_path\":[],\"quantity\":\"count\",\"component\":\"degree.u\",\"frame_id\":\"document_world\",\"units\":\"1\",\"value\":3"));
    try testing.expect(has(n.measurements, "\"component\":\"net:1x2\""));
    try testing.expect(has(n.measurements, "\"api\":\"vs.NurbsGetPt3D\",\"api_version\":\"[31,0,0]\",\"raw_artifact_id\":\"native_query_raw\",\"api_status\":\"documented\""));
}

test "placementMatrix composes rotate_z for scale type 1 and refuses flips, tilts and scales" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loc = try parseJson(a, "[0,0,780]");
    const Case = struct { row: []const u8, sym: []const u8, rot: f64, flipped: bool, want: ?[9]f64, reason: []const u8 = "" };
    const one = "{\"scale_type\":{\"v\":1}}";
    const cases = [_]Case{
        .{ .row = "{\"entity_matrix\":{\"v\":[true,[0,0,780],0,0,90]}}", .sym = one, .rot = 90, .flipped = false, .want = .{ 0, -1, 0, 1, 0, 0, 0, 0, 1 } },
        .{ .row = "{}", .sym = one, .rot = 0, .flipped = false, .want = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        .{ .row = "{\"orient3d\":{\"err\":\"absent\"},\"entity_matrix\":{\"v\":[true,[0,0,780],0,0,450]}}", .sym = one, .rot = 90, .flipped = false, .want = .{ 0, -1, 0, 1, 0, 0, 0, 0, 1 } },
        // m2d-native-acceptance raw/02-inst-planters.out 9.29 is flipped with rx 180.
        .{ .row = "{\"orient3d\":{\"v\":[true,180,0,0,true]},\"entity_matrix\":{\"v\":[true,[0,0,780],180,0,0]}}", .sym = one, .rot = 0, .flipped = true, .want = null, .reason = "flipped" },
        .{ .row = "{\"entity_matrix\":{\"v\":[true,[0,0,780],180,0,0]}}", .sym = one, .rot = 0, .flipped = false, .want = null, .reason = "rotX 180" },
        .{ .row = "{\"entity_matrix\":{\"v\":[true,[0,0,780],0,10,0]}}", .sym = one, .rot = 0, .flipped = false, .want = null, .reason = "axis order is unverified" },
        .{ .row = "{\"entity_matrix\":{\"v\":[true,[0,0,0],0,0,0]}}", .sym = one, .rot = 0, .flipped = false, .want = null, .reason = "offset 2" },
        .{ .row = "{\"entity_matrix\":{\"v\":[true,[0,0,780],0,0,45]}}", .sym = one, .rot = 90, .flipped = false, .want = null, .reason = "differs from GetSymRot" },
        .{ .row = "{\"entity_matrix\":{\"v\":[false,[0,0,780],0,0,0]}}", .sym = one, .rot = 0, .flipped = false, .want = null, .reason = "returned false" },
        .{ .row = "{\"entity_matrix\":{\"err\":\"absent\"}}", .sym = one, .rot = 0, .flipped = false, .want = null, .reason = "GetEntityMatrix is a gap" },
        .{ .row = "{\"entity_matrix\":{\"v\":[true,[0,0,780],0,0]}}", .sym = one, .rot = 0, .flipped = false, .want = null, .reason = "is not [ok, offset" },
        .{ .row = "{\"orient3d\":{\"v\":[true,0,0,0,true]}}", .sym = one, .rot = 0, .flipped = false, .want = null, .reason = "isMirroredXY" },
        .{ .row = "{\"orient3d\":{\"v\":[true,0,0,45,false]}}", .sym = one, .rot = 90, .flipped = false, .want = null, .reason = "differs from GetSymRot" },
        .{ .row = "{}", .sym = "{}", .rot = 0, .flipped = false, .want = null, .reason = "scale_type is a gap" },
        .{ .row = "{}", .sym = "{\"scale_type\":{\"v\":2},\"scale\":{\"v\":[0.4,0.4,0.4]}}", .rot = 0, .flipped = false, .want = null, .reason = "scale_type 2" },
        .{ .row = "{}", .sym = "{\"scale_type\":{\"v\":3},\"scale\":{\"v\":[1.4,1.1,1.2]}}", .rot = 0, .flipped = false, .want = null, .reason = "scale_type 3" },
    };
    for (cases) |c| {
        const got = placementMatrix(a, try parseJson(a, c.row), try parseJson(a, c.sym), loc, c.rot, c.flipped);
        if (c.want) |w| {
            try testing.expect(got == .ok);
            for (w, got.ok) |x, y| try testing.expectApproxEqAbs(x, y, 1e-12);
        } else {
            try testing.expect(got == .unresolved);
            try testing.expect(std.mem.indexOf(u8, got.unresolved, c.reason) != null);
        }
    }
    try testing.expectEqual(@as(?bool, true), flagOf(try parseJson(a, "1")));
    try testing.expectEqual(@as(?bool, false), flagOf(try parseJson(a, "false")));
    try testing.expectEqual(@as(?bool, null), flagOf(try parseJson(a, "\"x\"")));
}

test "unitsFromUpi maps known units and refuses others" {
    try testing.expectEqualStrings("mm", unitsFromUpi(25.4).?);
    try testing.expectEqualStrings("ft", unitsFromUpi(1.0 / 12.0).?);
    try testing.expect(unitsFromUpi(3.0) == null);
}

test "planQuery selects components and arguments and refuses the controls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { q: []const u8, status: ?[]const u8, component: []const u8 = "" };
    const cases = [_]Case{
        .{ .q = "{\"api\":\"vs.ClassNum\",\"quantity\":\"count\"}", .status = null },
        .{ .q = "{\"api\":\"vs.ClassNum\",\"quantity\":\"count\",\"component\":\"classes\"}", .status = null, .component = "classes" },
        .{ .q = "{\"api\":\"vs.ClassNum\",\"quantity\":\"count\",\"component\":\"members\"}", .status = "component_unregistered" },
        .{ .q = "{\"api\":\"vs.GetVPCropObject\",\"quantity\":\"count\",\"component\":\"crop_objects\"}", .status = null, .component = "crop_objects" },
        .{ .q = "{\"api\":\"vs.GetArc\",\"quantity\":\"angle\"}", .status = "component_unspecified" },
        .{ .q = "{\"api\":\"vs.GetArc\",\"quantity\":\"angle\",\"component\":\"arc.sweep_angle\"}", .status = null, .component = "arc.sweep_angle" },
        .{ .q = "{\"api\":\"vs.GetAngleToNorth\",\"quantity\":\"angle\"}", .status = null, .component = "document.angle_to_north" },
        .{ .q = "{\"api\":\"vs.GetGISOriginN\",\"quantity\":\"angle\"}", .status = null, .component = "gis.angle_to_north" },
        .{ .q = "{\"api\":\"vs.GetCVis\",\"quantity\":\"visibility\"}", .status = "argument_missing" },
        .{ .q = "{\"api\":\"vs.GetCVis\",\"quantity\":\"visibility\",\"args\":[3]}", .status = "argument_type" },
        .{ .q = "{\"api\":\"vs.GetCVis\",\"quantity\":\"visibility\",\"args\":[\"A\",\"B\"]}", .status = "argument_count" },
        .{ .q = "{\"api\":\"vs.GetCVis\",\"quantity\":\"visibility\",\"args\":[\"A\"]}", .status = null },
        .{ .q = "{\"api\":\"vs.GetVPLayerVisibility\",\"quantity\":\"visibility\",\"args\":[{\"handle\":\"object\"},{\"handle\":\"object\"}]}", .status = "argument_type" },
        .{ .q = "{\"api\":\"vs.GetVPLayerVisibility\",\"quantity\":\"visibility\",\"args\":[{\"handle\":\"object\"},{\"handle\":\"layer\",\"name\":\"L\"}]}", .status = null },
        .{ .q = "{\"api\":\"vs.GetWSCellString\",\"quantity\":\"name\",\"args\":[{\"handle\":\"object\"},1,1.5]}", .status = "argument_type" },
        .{ .q = "{\"api\":\"vs.GetName\",\"quantity\":\"name\",\"args\":[1]}", .status = "argument_unexpected" },
        .{ .q = "{\"api\":\"vs.GetView\",\"quantity\":\"name\"}", .status = "quantity_mismatch" },
        .{ .q = "{\"api\":\"vs.GetNoSuch\",\"quantity\":\"name\"}", .status = "collector_unimplemented" },
    };
    for (cases) |c| {
        const qp = planQuery(a, queryOf(try parseJson(a, c.q), "document_world"));
        if (c.status) |st| {
            try testing.expectEqualStrings(st, qp.status orelse "");
        } else {
            try testing.expect(qp.status == null);
            try testing.expectEqualStrings(c.component, qp.component);
        }
    }
    // Every raw_call names a key of the bridge RAW dict. op_query has no getattr route.
    for (query_blockers) |b| {
        const k = b.raw_call orelse continue;
        try testing.expect(std.mem.indexOf(u8, bridge_py, fmtA(a, "'{s}': lambda h: vs.{s}(", .{ k, k })) != null);
    }
    const qa = std.mem.indexOf(u8, bridge_py, "def op_query(").?;
    const qb = std.mem.indexOf(u8, bridge_py, "def op_export(").?;
    try testing.expect(std.mem.indexOf(u8, bridge_py[qa..qb], "getattr(") == null);
    try testing.expect(queryArgProblem(try parseJson(a, "{\"handle\":\"layer\"}")) != null);
    try testing.expect(queryArgProblem(try parseJson(a, "{\"handle\":\"object\",\"x\":1}")) != null);
    try testing.expect(queryArgProblem(try parseJson(a, "null")) != null);
}

test "rawQueryProblem accepts the raw-only descriptor and refuses its controls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "\"acquisition\":\"raw_only\",\"frame\":\"document_world\",\"normalization\":\"unresolved\"";
    const Case = struct { q: []const u8, code: ?[]const u8 };
    const cases = [_]Case{
        .{ .q = "\"object_id\":\"document\",\"api\":\"vs.GetGISOriginN\",\"raw_call\":\"GetGISOriginN\",\"raw_return\":[\"BOOLEAN\",\"outLat REAL\"],\"decision\":\"decision.quantity.geodetic\"", .code = null },
        .{ .q = "\"object_id\":\"t\",\"api\":\"vs.GetTextStyleRef\",\"raw_call\":\"GetTextStyleRef\",\"raw_return\":[\"LONGINT\"],\"decision\":\"decision.quantity.reference\"", .code = null },
        .{ .q = "\"object_id\":\"document\",\"api\":\"vs.GetTextStyleRef\",\"raw_call\":\"GetTextStyleRef\",\"raw_return\":[\"LONGINT\"],\"decision\":\"decision.quantity.reference\"", .code = "raw_object_mismatch" },
        .{ .q = "\"object_id\":\"t\",\"api\":\"vs.GetView\",\"raw_call\":\"GetView\",\"raw_return\":[\"REAL\"],\"decision\":\"decision.query.get_view\"", .code = "raw_object_mismatch" },
        .{ .q = "\"object_id\":\"document\",\"api\":\"vs.GetName\",\"raw_call\":\"GetName\",\"raw_return\":[\"STRING\"],\"decision\":\"decision.query.get_view\"", .code = "raw_call_unlisted" },
        .{ .q = "\"object_id\":\"document\",\"api\":\"vs.GetView\",\"raw_call\":\"GetUnits\",\"raw_return\":[\"REAL\"],\"decision\":\"decision.query.get_view\"", .code = "raw_call_mismatch" },
        .{ .q = "\"object_id\":\"document\",\"api\":\"vs.GetUnits\",\"raw_call\":\"GetUnits\",\"raw_return\":[],\"decision\":\"decision.quantity.unit_mark\"", .code = "bad_raw_query" },
        .{ .q = "\"object_id\":\"document\",\"api\":\"vs.GetUnits\",\"raw_call\":\"GetUnits\",\"raw_return\":[\"STRING\"],\"decision\":\"decision.other\"", .code = "bad_raw_query" },
        .{ .q = "\"object_id\":\"document\",\"api\":\"vs.GetUnits\",\"quantity\":\"name\",\"raw_call\":\"GetUnits\",\"raw_return\":[\"STRING\"],\"decision\":\"decision.quantity.unit_mark\"", .code = "bad_raw_query" },
    };
    for (cases) |c| {
        const v = try parseJson(a, fmtA(a, "{{{s},{s}}}", .{ base, c.q }));
        const got = rawQueryProblem(a, v);
        if (c.code) |want| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(want, got.?[0]);
        } else {
            try testing.expect(got == null);
            const qp = planQuery(a, queryOf(v, "document_world"));
            try testing.expectEqualStrings("raw_only", qp.status.?);
            try testing.expect(qp.raw_call != null);
        }
    }
    try testing.expect(rawQueryProblem(a, try parseJson(a, "{\"acquisition\":\"normalized\"}")) != null);
    try testing.expect(rawQueryProblem(a, try parseJson(a, "{\"api\":\"vs.GetName\"}")) == null);
    for (raw_calls) |rc| try testing.expect(std.mem.indexOf(u8, bridge_py, fmtA(a, "'{s}': lambda h: vs.{s}(", .{ rc.name, rc.name })) != null);
}

test "valueProblem checks value forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(valueProblem("bounds3", try parseJson(a, "[0,0,0,1,1,1]"), null) == null);
    try testing.expect(valueProblem("bounds3", try parseJson(a, "[2,0,0,1,1,1]"), null) != null);
    try testing.expect(valueProblem("control_points", try parseJson(a, "[[1,2,3]]"), null) != null);
    try testing.expect(valueProblem("control_points", try parseJson(a, "[[1,2,3]]"), "cartesian") == null);
    try testing.expect(valueProblem("direction3", try parseJson(a, "[0,0,0]"), null) != null);
    try testing.expect(valueProblem("weights", try parseJson(a, "[1,0]"), null) != null);
}

test "normalizedQueryValue converts only exact Count LONGINT floats" {
    for ([_]f64{ 0, 2, std.math.maxInt(i32) }) |x| {
        const got = normalizedQueryValue("vs.Count", "count", .{ .float = x }).?;
        try testing.expect(got == .integer);
        try testing.expectEqual(@as(i64, @intFromFloat(x)), got.integer);
    }
    for ([_]f64{ -1, 0.5, 2147483648, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |x| {
        try testing.expect(normalizedQueryValue("vs.Count", "count", .{ .float = x }) == null);
    }
    for ([_][]const u8{ "0.0", "2.0", "2e0", "20e-1", "0.002e3", "2147483647.0", "2.147483647e9" }, [_]i64{ 0, 2, 2, 2, 2, 2147483647, 2147483647 }) |s, expected| {
        const got = normalizedQueryValue("vs.Count", "count", .{ .number_string = s }).?;
        try testing.expectEqual(expected, got.integer);
    }
    for ([_][]const u8{ "0.5", "1e-999", "2147483647.0000001", "2147483648.0", "-1.0", "2.00000000000000000000000001", "1e999", "1e9223372036854775807", "1e-9223372036854775808" }) |s| {
        try testing.expect(normalizedQueryValue("vs.Count", "count", .{ .number_string = s }) == null);
    }
    try testing.expect(normalizedQueryValue("vs.ClassNum", "count", .{ .float = 2 }).? == .float);
    try testing.expect(normalizedQueryValue("vs.Count", "length", .{ .float = 2 }).? == .float);
    try testing.expect(normalizedQueryValue("vs.Count", "count", .{ .integer = 2 }).? == .integer);
    try testing.expect(normalizedQueryValue("vs.Count", "count", .{ .bool = false }) == null);
    // Generic valueProblem retains its existing coercion. Count validation is API-specific.
    try testing.expect(valueProblem("count", .{ .float = 2 }, null) == null);
}

test "normalize preserves raw Count float and emits integer measurement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"schema":"vwx-rosetta-native-query/1","units":{"units_per_inch":25.4},"origin":[0,0],
        \\"results":[{"object_id":"document","quantity":"count","api":"vs.Count","component":"objects","frame":"document_world","status":"ok","value":0.0,"raw":0.0}]}
    ;
    const n = try normalize(a, .{ .case_id = "c", .source_sha256 = "s", .state_sha256 = "t", .raw_artifact_id = "native.query_raw", .raw = raw });
    try testing.expectEqual(@as(usize, 1), n.measured);
    try testing.expectEqual(@as(usize, 0), n.gaps.len);
    const m = try parseJson(a, n.measurements);
    try testing.expectEqualStrings("0", field(m, "value").?.number_string);
    try testing.expectEqualStrings("objects", strField(m, "component").?);
    try testing.expectEqualStrings("1", strField(m, "units").?);
    try testing.expectEqual(@as(i64, 0), intOf(field(field(m, "provenance").?, "raw_result_index").?).?);
    const original = arrField(try parseJson(a, raw), "results")[0];
    try testing.expectEqualStrings("0.0", field(original, "value").?.number_string);
    try testing.expectEqualStrings("0.0", field(original, "raw").?.number_string);
}

test "normalize retains gaps for invalid Count floats and other API floats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"schema":"vwx-rosetta-native-query/1","units":{"units_per_inch":25.4},"origin":[0,0],
        \\"results":[{"object_id":"document","quantity":"count","api":"vs.Count","status":"ok","value":0.5},
        \\{"object_id":"document","quantity":"count","api":"vs.Count","status":"ok","value":-1.0},
        \\{"object_id":"document","quantity":"count","api":"vs.Count","status":"ok","value":2147483648.0},
        \\{"object_id":"document","quantity":"count","api":"vs.ClassNum","status":"ok","value":2.0}]}
    ;
    const n = try normalize(a, .{ .case_id = "c", .source_sha256 = "s", .state_sha256 = "t", .raw_artifact_id = "native.query_raw", .raw = raw });
    try testing.expectEqual(@as(usize, 0), n.measured);
    try testing.expectEqual(@as(usize, 4), n.gaps.len);
}

test "normalize gives null frame units for a nonzero origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"schema":"vwx-rosetta-native-query/1","units":{"units_per_inch":25.4},"origin":[5,0],
        \\"results":[{"object_id":"o","quantity":"length","api":"vs.HWidth","frame":"document_world","status":"ok","value":3},
        \\{"object_id":"o","quantity":"count","api":"vs.Count","frame":"document_world","status":"ok","value":2}]}
    ;
    const n = try normalize(a, .{ .case_id = "c", .source_sha256 = "s", .state_sha256 = "t", .raw_artifact_id = "native.query_raw", .raw = raw });
    try testing.expectEqual(@as(usize, 2), n.measured);
    try testing.expect(std.mem.indexOf(u8, n.frames, "\"units\": null") != null);
    try testing.expect(std.mem.indexOf(u8, n.measurements, "\"units\":null") != null);
    try testing.expect(std.mem.indexOf(u8, n.measurements, "\"units\":\"1\"") != null);
}

test "overrideProblem refuses unknown overrides and hidden content after show_all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hidden = "{\"classes\":[{\"name\":\"A\",\"visible\":false}],\"layers\":[]}";
    const shown = "{\"classes\":[{\"name\":\"A\",\"visible\":true}],\"layers\":[]}";
    try testing.expect(overrideProblem(a, try parseJson(a, "{\"hidden_content\":\"show_all\"}"), hidden, hidden) != null);
    try testing.expect(overrideProblem(a, try parseJson(a, "{\"hidden_content\":\"show_all\"}"), hidden, shown) == null);
    try testing.expect(overrideProblem(a, try parseJson(a, "{}"), hidden, shown) != null);
    try testing.expect(overrideProblem(a, try parseJson(a, "{\"lights\":\"on\"}"), hidden, hidden) != null);
}

test "resolveArgs refuses a null profile option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diags.init(a);
    const entries = parseEntries(a, &d, default_entries, "default");
    try testing.expectEqual(@as(usize, 0), d.errors());
    const e = findEntry(entries, "sat").?;
    var p: Profile = .{ .profile_id = "sat.solids", .profile_sha256 = "", .format = "sat", .path = null, .options = try parseJson(a, "{\"solid_as_surface\":false,\"sat_version\":null}"), .overrides = .null };
    var missing: []const u8 = "";
    const args = resolveArgs(a, e, &p, "/x.sat", &missing).?;
    try testing.expectEqualStrings("[\"/x.sat\",false]", stringifyLine(a, args));
    p.options = try parseJson(a, "{}");
    try testing.expect(resolveArgs(a, e, &p, "/x.sat", &missing) == null);
    try testing.expectEqualStrings("solid_as_surface", missing);
}

test "runCli prints usage with exit 2" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 2), runCli(testing.allocator, testing.io, &.{"nope"}, &w));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "result\tusage") != null);
}

test "sniffWindow gives the result of sniffExport on whole, truncated and altered bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (formats) |f| {
        const whole = fakeExport(a, f.name, "x.vwx");
        var variants: std.ArrayList([]const u8) = .empty;
        try variants.append(a, whole);
        try variants.append(a, whole[0 .. whole.len / 2]);
        try variants.append(a, whole[0 .. whole.len / 4]);
        try variants.append(a, whole[0 .. whole.len - 1]);
        try variants.append(a, whole[1..]);
        try variants.append(a, "");
        try variants.append(a, "x");
        const flipped = try a.dupe(u8, whole);
        flipped[0] ^= 0x20;
        try variants.append(a, flipped);
        for (variants.items) |v| {
            const want = sniffExport(f.name, v);
            const got = sniffWindow(f.name, windowOfBytes(v));
            try testing.expectEqual(want.ok, got.ok);
            try testing.expectEqualStrings(want.code, got.code);
        }
    }
}

test "native capture window guards use injected document evidence and fail closed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fake = struct {
        windows: []const uidiag.WindowInfo = &.{},
        failed: bool = false,
        fn read(ptr: *anyopaque, t: uidiag.Target) uidiag.WindowsReply {
            const f: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(t.pid == 77);
            return if (f.failed) .{ .failed = .{ .kind = .transport_error, .detail = "injected failure" } } else .{ .windows = f.windows };
        }
    };
    var f: Fake = .{};
    var n: NativeDriver = .{ .a = a, .io = testing.io, .cfg = .{
        .pid = 77,
        .sender = "/unused",
        .request_root = "/unused",
        .window_backend = .{ .ptr = &f, .windowsFn = Fake.read, .treeFn = undefined, .captureFn = undefined },
    } };
    try testing.expectEqualStrings("", n.windowNames(a).?);
    try testing.expect(!n.dialogOpen(a));
    const absent = n.python(a, .{ .kind = .preflight }, "preflight");
    try testing.expectEqual(Status.failed, absent.status);
    try testing.expectEqual(@as(u32, 0), n.helper_calls);
    f.windows = &.{.{ .title = "source.vwx", .subrole = "AXStandardWindow", .modal = false }};
    try testing.expectEqualStrings("source.vwx", n.windowNames(a).?);
    try testing.expect(!n.dialogOpen(a));
    f.windows = &.{
        .{ .title = "source.vwx", .subrole = "AXStandardWindow", .modal = false },
        .{ .title = "Export", .subrole = "AXDialog", .modal = true },
    };
    try testing.expect(n.dialogOpen(a));
    try testing.expectEqual(Status.modal, n.python(a, .{ .kind = .preflight }, "preflight").status);
    f.windows = &.{.{ .title = "Export", .subrole = "AXDialog", .modal = true }};
    try testing.expectEqualStrings("", n.windowNames(a).?);
    f.windows = &.{.{ .title = "Palette", .subrole = "AXFloatingWindow", .modal = false }};
    try testing.expectEqualStrings("", n.windowNames(a).?);
    f.windows = &.{.{ .title = "unknown" }};
    try testing.expect(n.dialogOpen(a));
    f.failed = true;
    try testing.expect(n.windowNames(a) == null);
    try testing.expect(n.dialogOpen(a));
    try testing.expectEqual(@as(u32, 0), n.helper_calls);
}

const sp_route_file =
    \\{"schema":"vwx-rosetta-ui-routes/1","release":"Vectorworks 2027 trial","workspace":"Design Suite","routes":[
    \\{"id":"pdf-save-panel","format":"pdf","progress":false,"cancel":null,
    \\"steps":[
    \\{"menu":["File","Export"]},
    \\{"option":{"selector":{"label":"Format:","role":"popup","container":{"window":"Export PDF"},"via":"title_element"},"value":{"choice":"PDF"}}},
    \\{"destination":{"name_field":{"label":"","role":"text_field","container":{"window":"Export as PDF Document"},"via":{"path":[{"role":"text_field","index":1,"of":2}]}},
    \\"save_panel":{"where":{"label":"Where:","role":"popup","container":{"window":"Export as PDF Document"}},
    \\"sheet_field":{"label":"","role":"combo_box","container":{"window_sheet":"Export as PDF Document"},"via":{"path":[{"role":"combo_box","index":1,"of":1}]}},
    \\"go":{"label":"Go","role":"button","container":{"window_sheet":"Export as PDF Document"}}}}},
    \\{"confirm":{"label":"Save","role":"button","container":{"window":"Export as PDF Document"}}}],
    \\"outputs":{"primary":"model.pdf","required_sidecars":[],"allowed_sidecar_exts":[]},
    \\"binding":{"profile_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","state_digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}]}
;

test "a route file carries title element selectors, paths and the save panel directory step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diags.init(a);
    const rs = parseRouteSet(a, &d, sp_route_file, "routes.json") orelse return error.TestUnexpectedResult;
    const r = rs.routes[0];
    try std.testing.expectEqual(@as(usize, 4), r.route.steps.len);
    const opt = r.route.steps[1].option.selector;
    try std.testing.expect(opt.via == .title_element);
    const dest = r.route.steps[2].destination;
    try std.testing.expect(dest.name_field.via == .path);
    try std.testing.expectEqual(@as(u8, 2), dest.name_field.via.path[0].of);
    const sp = dest.save_panel.?;
    try std.testing.expect(sp.where.via == .name);
    try std.testing.expect(sp.sheet_field.container == .window_sheet);
    try std.testing.expect(sp.sheet_field.role == .combo_box);
    try std.testing.expect(dest.dir_field == null);
    // The digest text writes every new key and the parse of that text gives the same digest.
    const text = stringifyLine(a, routeCoreJson(a, r.route, r.outputs));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"via\":\"title_element\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"via\":{\"path\":[{\"role\":\"text_field\",\"index\":1,\"of\":2}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"container\":{\"window_sheet\":\"Export as PDF Document\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"save_panel\":{\"where\"") != null);
    try std.testing.expectEqualStrings(r.route_sha256, routeDigest(a, r.route, r.outputs));
}

test "a selector without a locator writes no via key, so older route digests stay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = stringifyLine(a, selectorJson(a, .{ .container = .document_sheet, .role = .button, .label = "Save" }));
    try std.testing.expectEqualStrings("{\"label\":\"Save\",\"role\":\"button\",\"container\":\"document_sheet\"}", text);
}

test "a route file refuses a malformed locator and an unknown container key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][2][]const u8{
        .{ "\"via\":\"title_element\"", "\"via\":\"nearest\"" },
        .{ "\"index\":1,\"of\":2", "\"index\":3,\"of\":2" },
        .{ "\"index\":1,\"of\":2", "\"index\":0,\"of\":2" },
        .{ "{\"window_sheet\":\"Export as PDF Document\"},\"via\":{\"path\":[{\"role\":\"combo_box\"", "{\"sheet\":\"Export as PDF Document\"},\"via\":{\"path\":[{\"role\":\"combo_box\"" },
    };
    for (bad) |pair| {
        const i = std.mem.indexOf(u8, sp_route_file, pair[0]) orelse return error.TestUnexpectedResult;
        const text = try std.mem.concat(a, u8, &.{ sp_route_file[0..i], pair[1], sp_route_file[i + pair[0].len ..] });
        var d = Diags.init(a);
        try std.testing.expect(parseRouteSet(a, &d, text, "routes.json") == null);
    }
}

test "native capture console policy accepts an omitted lock key with valid session evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const wiring: UiWiring = .{ .rt = undefined, .backend = undefined };
    const policy = wiring.policy(arena.allocator(), "scratch.vwx");
    const session = "\"IOConsoleUsers\"=({\"kCGSSessionOnConsoleKey\"=Yes,\"kCGSessionLoginDoneKey\"=Yes,\"kCGSSessionUserNameKey\"=\"someone\"})";
    const cases = [_]struct { obs: nui.ConsoleObservation, expected: nui.ConsoleState }{
        .{ .obs = .{ .owner = "someone", .user = "someone", .registry = session }, .expected = .ready },
        .{ .obs = .{ .owner = "someone", .user = "someone", .registry = session ++ "\"CGSSessionScreenIsLocked\"=Yes" }, .expected = .locked },
        .{ .obs = .{ .owner = "root", .user = "someone", .registry = session }, .expected = .wrong_console },
        .{ .obs = .{ .owner = "someone", .user = "other", .registry = session }, .expected = .wrong_console },
        .{ .obs = .{ .owner = "someone", .user = "someone", .registry = session ++ "\"CGSSessionScreenIsLocked\"=invalid" }, .expected = .unknown },
        .{ .obs = .{ .owner = "someone", .user = "someone", .registry = "\"IOConsoleUsers\"=()" }, .expected = .unknown },
        .{ .obs = .{ .owner = "someone", .user = "someone", .registry = "\"IOConsoleUsers\"=({\"kCGSSessionOnConsoleKey\"=Yes,\"kCGSessionLoginDoneKey\"=Yes,\"kCGSSessionUserNameKey\"=\"other\"})" }, .expected = .unknown },
        .{ .obs = .{ .owner = "someone", .user = "someone", .registry = "\"IOConsoleUsers\"=({\"kCGSSessionOnConsoleKey\"=No,\"kCGSessionLoginDoneKey\"=Yes,\"kCGSSessionUserNameKey\"=\"someone\"})" }, .expected = .unknown },
        .{ .obs = .{ .owner = "someone", .user = "someone", .registry = "\"IOConsoleUsers\"=({\"kCGSSessionOnConsoleKey\"=Yes,\"kCGSessionLoginDoneKey\"=No,\"kCGSSessionUserNameKey\"=\"someone\"})" }, .expected = .unknown },
        .{ .obs = .{ .owner = "someone", .user = "someone" }, .expected = .unknown },
        .{ .obs = .{}, .expected = .unknown },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, nui.classifyConsole(case.obs, policy.console));
}

test "only the exact STL rejection of an STL export is an outcome" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const eop: Op = .{ .kind = .export_file, .payload = "{\"format\":\"stl\",\"api\":\"vs.ExportSTL\",\"args\":[]}" };
    const good: Reply = .{ .status = .unsupported, .payload = rejectionPayload(a, stl_rejection_message, "returned") };
    try std.testing.expectEqualStrings(stl_rejection_message, rejectedStl(a, eop, good).?);
    // Another message, a changed text and an empty one.
    for ([_][]const u8{ "Export STL failed. There is no disk space.", stl_rejection_message ++ " ", "" }) |m| {
        try std.testing.expect(rejectedStl(a, eop, .{ .status = .unsupported, .payload = rejectionPayload(a, m, "returned") }) == null);
    }
    // Another API, another operation kind, another status, an uncertain or a refused reply.
    try std.testing.expect(rejectedStl(a, .{ .kind = .export_file, .payload = "{\"api\":\"vs.ExportSAT\"}" }, good) == null);
    try std.testing.expect(rejectedStl(a, .{ .kind = .ui_export, .payload = eop.payload }, good) == null);
    for ([_]Status{ .ok, .failed, .modal, .timeout, .crashed }) |st| {
        var r = good;
        r.status = st;
        try std.testing.expect(rejectedStl(a, eop, r) == null);
    }
    var u = good;
    u.uncertain = true;
    try std.testing.expect(rejectedStl(a, eop, u) == null);
    var rf = good;
    rf.refused = true;
    try std.testing.expect(rejectedStl(a, eop, rf) == null);
    // The payload must carry the press, must claim no file and must name the outcome and the API.
    for ([_][]const u8{
        "{\"outcome\":\"application_rejected\",\"api\":\"vs.ExportSTL\",\"native_message\":\"" ++ stl_rejection_message ++ "\",\"acknowledged\":false,\"file_claimed\":false}",
        "{\"outcome\":\"application_rejected\",\"api\":\"vs.ExportSTL\",\"native_message\":\"" ++ stl_rejection_message ++ "\",\"acknowledged\":true,\"file_claimed\":true}",
        "{\"outcome\":\"application_rejected\",\"api\":\"vs.ExportSTL\",\"native_message\":\"" ++ stl_rejection_message ++ "\",\"acknowledged\":true}",
        "{\"outcome\":\"ok\",\"api\":\"vs.ExportSTL\",\"native_message\":\"" ++ stl_rejection_message ++ "\",\"acknowledged\":true,\"file_claimed\":false}",
        "{\"outcome\":\"application_rejected\",\"api\":\"vs.ExportSAT\",\"native_message\":\"" ++ stl_rejection_message ++ "\",\"acknowledged\":true,\"file_claimed\":false}",
        "not json",
        "{}",
    }) |p| try std.testing.expect(rejectedStl(a, eop, .{ .status = .unsupported, .payload = p }) == null);
}

test "the in-flight context is the text that the engine writes and the driver compares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op: Op = .{ .kind = .export_file, .case_id = "c1", .profile_id = "p1", .path = "/x/export.stl", .payload = "{\"op_dir\":\"/x\"}" };
    try std.testing.expectEqualStrings("case=c1 profile=p1 path=/x/export.stl op_dir=/x", inflightContext(a, op));
}

// Scalar units and Get3DInfo bounds

fn prefsJson(a: Allocator, area_scale: []const u8, vol_scale: []const u8, area_mark: []const u8, vol_mark: []const u8) []const u8 {
    return fmtA(a, "{{\"read_only\":true,\"prefs\":[{{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"python_type\":\"float\",\"raw\":{s},\"status\":\"observed\"}},{{\"api\":\"vs.GetPrefReal\",\"selector\":180,\"python_type\":\"float\",\"raw\":{s},\"status\":\"observed\"}},{{\"api\":\"vs.GetPrefString\",\"selector\":178,\"python_type\":\"str\",\"raw\":\"{s}\",\"status\":\"observed\"}},{{\"api\":\"vs.GetPrefString\",\"selector\":182,\"python_type\":\"str\",\"raw\":\"{s}\",\"status\":\"observed\"}}]}}", .{ area_scale, vol_scale, area_mark, vol_mark });
}

const scalar_results =
    \\{"object_id":"o","quantity":"length","api":"vs.HWidth","frame":"document_world","status":"ok","value":3.0625,"raw":3.0625},
    \\{"object_id":"o","quantity":"area","api":"vs.ObjSurfaceArea","frame":"document_world","status":"ok","value":8.524250000000001e-03,"raw":8.524250000000001e-03},
    \\{"object_id":"o","quantity":"volume","api":"vs.ObjVolume","frame":"document_world","status":"ok","value":3.5570312500000005e-05,"raw":3.5570312500000005e-05},
    \\{"object_id":"o","quantity":"area","api":"vs.ObjArea","frame":"document_world","status":"ok","value":9.0625e-04,"raw":9.0625e-04},
    \\{"object_id":"document","quantity":"count","api":"vs.Count","component":"objects","frame":"document_world","status":"ok","value":7.0,"raw":7.0}
;

fn queryRaw(a: Allocator, upi: []const u8, units_raw: []const u8, scalar: ?[]const u8) []const u8 {
    return fmtA(a, "{{\"schema\":\"vwx-rosetta-native-query/1\",\"driver\":\"native\",\"units\":{{\"units_per_inch\":{s},\"raw\":{s}}},\"origin\":[0,0]{s}{s},\"results\":[{s}]}}", .{ upi, units_raw, if (scalar != null) ",\"scalar_units\":" else "", scalar orelse "", scalar_results });
}

fn measurementUnits(a: Allocator, n: Normalized, api: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, n.measurements, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        const m = parseJson(a, ln) catch continue;
        if (!eql(strField(field(m, "provenance") orelse .null, "api") orelse "", api)) continue;
        const u = field(m, "units") orelse return null;
        return if (u == .string) u.string else null;
    }
    return "(no record)";
}

fn gapMentions(n: Normalized, needle: []const u8) bool {
    for (n.gaps) |g| if (std.mem.indexOf(u8, g, needle) != null) return true;
    return false;
}

fn normQuery(a: Allocator, raw: []const u8) !Normalized {
    return normalize(a, .{ .case_id = "c", .source_sha256 = "s", .state_sha256 = "t", .raw_artifact_id = "native.query_raw", .raw = raw });
}

test "area and volume units come from their own readings and not from the length unit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The live document: length mm, area unit square metre, volume unit cubic metre.
    const raw = queryRaw(a, "25.4", "[1,2,0,25.4,\"mm\",\" sq m\"]", prefsJson(a, "0.00064516", "0.000016387064", " sq m", " cu m"));
    const n = try normQuery(a, raw);
    try testing.expectEqualStrings("mm", measurementUnits(a, n, "vs.HWidth").?);
    try testing.expectEqualStrings("m2", measurementUnits(a, n, "vs.ObjSurfaceArea").?);
    try testing.expectEqualStrings("m3", measurementUnits(a, n, "vs.ObjVolume").?);
    try testing.expectEqualStrings("1", measurementUnits(a, n, "vs.Count").?);
    // The numbers are the raw numbers, byte for byte, and the raw file is not changed.
    try testing.expect(std.mem.indexOf(u8, n.measurements, "\"value\":8.524250000000001e-03") != null);
    try testing.expect(std.mem.indexOf(u8, n.measurements, "\"value\":3.5570312500000005e-05") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "3.5570312500000005e-05") != null);
    // ObjArea has no documented unit contract: its unit is unresolved and the value is kept.
    try testing.expect(measurementUnits(a, n, "vs.ObjArea") == null);
    try testing.expect(std.mem.indexOf(u8, n.measurements, "\"value\":9.0625e-04") != null);
    try testing.expect(gapMentions(n, "vs.ObjArea"));
    try testing.expect(!gapMentions(n, "vs.ObjVolume") and !gapMentions(n, "vs.ObjSurfaceArea"));
    // The derived reading is labeled and the raw readings stay in the raw file.
    const doc = try parseJson(a, n.document);
    const basis = field(doc, "scalar_unit_basis").?;
    try testing.expect(boolField(basis, "derived").?);
    try testing.expectEqualStrings("m2", strField(field(basis, "area").?, "unit").?);
    try testing.expectEqualStrings("m3", strField(field(basis, "volume").?, "unit").?);
}

test "another supported scalar pair maps by its own scale and mark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Millimetre area and volume units beside a metre length.
    const mm = try normQuery(a, queryRaw(a, "0.0254", "[1,2,0,0.0254,\"m\",\" sq mm\"]", prefsJson(a, "645.16", "16387.064", " sq mm", " cu mm")));
    try testing.expectEqualStrings("m", measurementUnits(a, mm, "vs.HWidth").?);
    try testing.expectEqualStrings("mm2", measurementUnits(a, mm, "vs.ObjSurfaceArea").?);
    try testing.expectEqualStrings("mm3", measurementUnits(a, mm, "vs.ObjVolume").?);
    // Square and cubic feet with an inch length.
    const ft = try normQuery(a, queryRaw(a, "1", "[1,2,0,1,\"in\",\"sq ft\"]", prefsJson(a, "0.006944444444444444", "0.0005787037037037037", "sq ft", "cu ft")));
    try testing.expectEqualStrings("in", measurementUnits(a, ft, "vs.HWidth").?);
    try testing.expectEqualStrings("ft2", measurementUnits(a, ft, "vs.ObjSurfaceArea").?);
    try testing.expectEqualStrings("ft3", measurementUnits(a, ft, "vs.ObjVolume").?);
    // The two units are independent of each other: a supported area unit with an unsupported volume unit.
    const mix = try normQuery(a, queryRaw(a, "25.4", "[1,2,0,25.4,\"mm\",\" sq m\"]", prefsJson(a, "0.00064516", "3.0", " sq m", " cu stone")));
    try testing.expectEqualStrings("m2", measurementUnits(a, mix, "vs.ObjSurfaceArea").?);
    try testing.expect(measurementUnits(a, mix, "vs.ObjVolume") == null);
    try testing.expect(gapMentions(mix, "not a supported unit pair"));
}

test "missing, failed, invalid and custom scalar readings give null units and a gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const units = "[1,2,0,25.4,\"mm\",\" sq m\"]";
    // No scalar evidence at all, as in a raw file from before the capture.
    const none = try normQuery(a, queryRaw(a, "25.4", units, null));
    try testing.expect(measurementUnits(a, none, "vs.ObjSurfaceArea") == null and measurementUnits(a, none, "vs.ObjVolume") == null);
    try testing.expectEqualStrings("mm", measurementUnits(a, none, "vs.HWidth").?);
    try testing.expect(gapMentions(none, "no scalar_units evidence"));
    try testing.expect(std.mem.indexOf(u8, none.measurements, "\"value\":3.5570312500000005e-05") != null);
    // A pref that failed or is absent leaves only its own dimension unresolved.
    const failed = "{\"prefs\":[{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"status\":\"error\",\"reason\":\"TypeError: x\"},{\"api\":\"vs.GetPrefReal\",\"selector\":180,\"python_type\":\"float\",\"raw\":0.000016387064,\"status\":\"observed\"},{\"api\":\"vs.GetPrefString\",\"selector\":178,\"python_type\":\"str\",\"raw\":\" sq m\",\"status\":\"observed\"},{\"api\":\"vs.GetPrefString\",\"selector\":182,\"python_type\":\"str\",\"raw\":\" cu m\",\"status\":\"observed\"}]}";
    const f = try normQuery(a, queryRaw(a, "25.4", units, failed));
    try testing.expect(measurementUnits(a, f, "vs.ObjSurfaceArea") == null);
    try testing.expectEqualStrings("m3", measurementUnits(a, f, "vs.ObjVolume").?);
    try testing.expect(gapMentions(f, "status `error`"));
    const gap_mark = "{\"prefs\":[{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"python_type\":\"float\",\"raw\":0.00064516,\"status\":\"observed\"},{\"api\":\"vs.GetPrefReal\",\"selector\":180,\"python_type\":\"float\",\"raw\":0.000016387064,\"status\":\"observed\"},{\"api\":\"vs.GetPrefString\",\"selector\":178,\"status\":\"gap\",\"reason\":\"api_absent\"}]}";
    const g = try normQuery(a, queryRaw(a, "25.4", units, gap_mark));
    try testing.expect(measurementUnits(a, g, "vs.ObjSurfaceArea") == null and measurementUnits(a, g, "vs.ObjVolume") == null);
    try testing.expect(gapMentions(g, "no volume mark reading"));
    // Invalid scales: zero, negative, an unsupported value, a string, and a nonfinite reading.
    for ([_][]const u8{ "0.0", "-0.00064516", "0.5", "\"0.00064516\"" }) |bad| {
        const raw = queryRaw(a, "25.4", units, prefsJson(a, bad, "0.000016387064", " sq m", " cu m"));
        const r = try normQuery(a, raw);
        try testing.expect(measurementUnits(a, r, "vs.ObjSurfaceArea") == null);
        try testing.expectEqualStrings("m3", measurementUnits(a, r, "vs.ObjVolume").?);
    }
    const nonfinite = "{\"prefs\":[{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"python_type\":\"float\",\"raw\":null,\"status\":\"nonfinite\"},{\"api\":\"vs.GetPrefReal\",\"selector\":180,\"python_type\":\"float\",\"raw\":0.000016387064,\"status\":\"observed\"},{\"api\":\"vs.GetPrefString\",\"selector\":178,\"python_type\":\"str\",\"raw\":\" sq m\",\"status\":\"observed\"},{\"api\":\"vs.GetPrefString\",\"selector\":182,\"python_type\":\"str\",\"raw\":\" cu m\",\"status\":\"observed\"}]}";
    const nf = try normQuery(a, queryRaw(a, "25.4", units, nonfinite));
    try testing.expect(measurementUnits(a, nf, "vs.ObjSurfaceArea") == null and gapMentions(nf, "status `nonfinite`"));
    // A custom area unit that matches no supported pair, such as acres: unresolved, not guessed.
    const custom = try normQuery(a, queryRaw(a, "25.4", units, prefsJson(a, "0.0000002295684113865932", "1.6387064e-05", " ac", " cu m")));
    try testing.expect(measurementUnits(a, custom, "vs.ObjSurfaceArea") == null and gapMentions(custom, "not a supported unit pair"));
    try testing.expectEqualStrings("m3", measurementUnits(a, custom, "vs.ObjVolume").?);
}

test "conflicting marks leave the unit unresolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The scale is square metres and the mark says square millimetres.
    const mark = try normQuery(a, queryRaw(a, "25.4", "[1,2,0,25.4,\"mm\",\" sq m\"]", prefsJson(a, "0.00064516", "0.000016387064", " sq mm", " cu mm")));
    try testing.expect(measurementUnits(a, mark, "vs.ObjSurfaceArea") == null and measurementUnits(a, mark, "vs.ObjVolume") == null);
    try testing.expect(gapMentions(mark, "but the mark is"));
    // GetUnits and the preference disagree about the area mark. Volume has no second reading.
    const gu = try normQuery(a, queryRaw(a, "25.4", "[1,2,0,25.4,\"mm\",\" sq mm\"]", prefsJson(a, "0.00064516", "0.000016387064", " sq m", " cu m")));
    try testing.expect(measurementUnits(a, gu, "vs.ObjSurfaceArea") == null);
    try testing.expectEqualStrings("m3", measurementUnits(a, gu, "vs.ObjVolume").?);
    try testing.expect(gapMentions(gu, "contradicts the preference mark"));
    // A blank mark is no mark.
    const blank = try normQuery(a, queryRaw(a, "25.4", "[1,2,0,25.4,\"mm\",\" \"]", prefsJson(a, "0.00064516", "0.000016387064", " ", " cu m")));
    try testing.expect(measurementUnits(a, blank, "vs.ObjSurfaceArea") == null);
}

test "scalarUnits reads each dimension by itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try parseJson(a, prefsJson(a, "1", "1", "sq in", "cu in"));
    const s = scalarUnits(a, rec, .null);
    try testing.expectEqualStrings("in2", s.area.unit.?);
    try testing.expectEqualStrings("in3", s.volume.unit.?);
    try testing.expectEqual(@as(?f64, 1), s.area.scale);
    const empty = scalarUnits(a, .null, .null);
    try testing.expect(empty.area.unit == null and empty.volume.unit == null and empty.area.why.len > 0);
}

test "legacy raw captures keep the volume unit unresolved and new evidence resolves it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    const body =
        \\{"rec":"layer","index":1,"name":"L","elevation":{"v":0}}
        \\{"rec":"object","walk_id":"1.1","occurrence_path":[],"root":"1","root_kind":"layer","td":40,"layer":"L","class":"W","name":{"v":""},"vis":{"object":{"v":0},"class":{"v":0},"layer":{"v":0}},"cntr3d":{"v":[0,0,0]},"geom":{"volume":{"v":3.5570312500000005e-05}}}
        \\{"rec":"end","status":"ok","rows":2}
        \\
    ;
    const legacy_head =
        \\{"rec":"meta","schema":"vwx-m3d-native-raw/1","case_id":"c","file":"f.vwx","version":{"v":[31,0,0]},"units":{"v":[0,0,0,25.4,"mm"," sq m"]},"origin":{"v":[0,0]}}
        \\
    ;
    const n = try normalizeRaw(a, .{ .case_id = "c", .source_sha256 = "a" ** 64, .state_sha256 = "b" ** 64, .raw = legacy_head ++ body });
    try testing.expect(has(n.measurements, "\"quantity\":\"volume\"") and has(n.measurements, "\"units\":null,\"value\":3.5570312500000005e-05"));
    try testing.expect(has(n.ledger, "\"status\":\"units_gap\"") and has(n.ledger, "no scalar_units evidence"));
    try testing.expect(n.units_gap == 1);
    try testing.expect(!has(n.measurements, "\"units\":\"mm3\"") and !has(n.measurements, "\"units\":\"m3\""));
    const new_head =
        \\{"rec":"meta","schema":"vwx-m3d-native-raw/1","case_id":"c","file":"f.vwx","version":{"v":[31,0,0]},"units":{"v":[0,0,0,25.4,"mm"," sq m"]},"origin":{"v":[0,0]},"scalar_units":{"prefs":[{"api":"vs.GetPrefReal","selector":176,"python_type":"float","raw":0.00064516,"status":"observed"},{"api":"vs.GetPrefReal","selector":180,"python_type":"float","raw":1.6387064e-05,"status":"observed"},{"api":"vs.GetPrefString","selector":178,"python_type":"str","raw":" sq m","status":"observed"},{"api":"vs.GetPrefString","selector":182,"python_type":"str","raw":" cu m","status":"observed"}]}}
        \\
    ;
    const m = try normalizeRaw(a, .{ .case_id = "c", .source_sha256 = "a" ** 64, .state_sha256 = "b" ** 64, .raw = new_head ++ body });
    try testing.expect(has(m.measurements, "\"units\":\"m3\",\"value\":3.5570312500000005e-05"));
    try testing.expect(m.units_gap == 0);
}

test "Count stays an integer with units 1 beside scalar evidence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normQuery(a, queryRaw(a, "25.4", "[1,2,0,25.4,\"mm\",\" sq m\"]", prefsJson(a, "0.00064516", "0.000016387064", " sq m", " cu m")));
    try testing.expect(std.mem.indexOf(u8, n.measurements, "\"quantity\":\"count\",\"component\":\"objects\",\"frame_id\":\"document_world\",\"units\":\"1\",\"value\":7") != null);
    try testing.expect(std.mem.indexOf(u8, n.measurements, "7.0") == null);
}

test "Get3DInfo bounds use the documented delta-Y, delta-X, delta-Z order on an asymmetric extrude" {
    // The known extrude: Get3DInfo gives 34.25 (dy), 51.25 (dx), 39.25 (dz), the center is [31.625,21.625,22.125].
    const b = bounds3FromGetters(.{ 31.625, 21.625, 22.125 }, .{ 34.25, 51.25, 39.25 });
    try testing.expectEqualSlices(f64, &.{ 6, 4.5, 2.5, 57.25, 38.75, 41.75 }, &b);
    // The earlier reading (first value as the x span) gives the box that the live capture showed.
    const swapped = bounds3FromGetters(.{ 31.625, 21.625, 22.125 }, .{ 51.25, 34.25, 39.25 });
    try testing.expectEqualSlices(f64, &.{ 14.5, -4, 2.5, 48.75, 47.25, 41.75 }, &swapped);
    // The bridge program takes the tuple as (dy, dx, dz) and keeps both getter returns in the raw record.
    try testing.expect(std.mem.indexOf(u8, bridge_py, "dy, dx, dz = info") != null);
    try testing.expect(std.mem.indexOf(u8, bridge_py, "w, hh, d = _num(vs.Get3DInfo(h))") == null);
    try testing.expect(std.mem.indexOf(u8, bridge_py, "'get3dinfo_order': 'dy,dx,dz'") != null);
    try testing.expect(std.mem.indexOf(u8, bridge_py, "('vs.Get3DInfo', 'bounds3'): _box3_info") != null);
}

test "Get3DInfo bounds from the new bridge verify and from the earlier producer are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "{\"schema\":\"vwx-rosetta-native-query/1\",\"driver\":\"native\",\"units\":{\"units_per_inch\":25.4},\"origin\":[0,0],\"results\":[";
    const row = "{\"object_id\":\"o\",\"quantity\":\"bounds3\",\"api\":\"vs.Get3DInfo\",\"frame\":\"document_world\",\"status\":\"ok\",\"value\":[6,4.5,2.5,57.25,38.75,41.75],\"raw\":";
    const good_raw = "{\"derived\":true,\"get3dcntr\":[31.625,21.625,22.125],\"get3dinfo\":[34.25,51.25,39.25],\"get3dinfo_order\":\"dy,dx,dz\"}";
    const good = try normQuery(a, fmtA(a, "{s}{s}{s}}}]}}", .{ head, row, good_raw }));
    try testing.expectEqual(@as(usize, 1), good.measured);
    try testing.expect(std.mem.indexOf(u8, good.measurements, "[6,4.5,2.5,57.25,38.75,41.75]") != null);
    // A value that disagrees with its own getter evidence.
    const wrong_value = try normQuery(a, fmtA(a, "{s}{s}{s}}}]}}", .{ head, "{\"object_id\":\"o\",\"quantity\":\"bounds3\",\"api\":\"vs.Get3DInfo\",\"frame\":\"document_world\",\"status\":\"ok\",\"value\":[14.5,-4,2.5,48.75,47.25,41.75],\"raw\":", good_raw }));
    try testing.expectEqual(@as(usize, 0), wrong_value.measured);
    try testing.expect(gapMentions(wrong_value, "differ from the bounds that the getter evidence gives"));
    // The earlier producer wrote the box as the raw list.
    const old = try normQuery(a, fmtA(a, "{s}{s}[14.5,-4,2.5,48.75,47.25,41.75]}}]}}", .{ head, "{\"object_id\":\"o\",\"quantity\":\"bounds3\",\"api\":\"vs.Get3DInfo\",\"frame\":\"document_world\",\"status\":\"ok\",\"value\":[14.5,-4,2.5,48.75,47.25,41.75],\"raw\":" }));
    try testing.expectEqual(@as(usize, 0), old.measured);
    try testing.expect(gapMentions(old, "swapped the x and y spans"));
    // Another order name is refused.
    const bad_order = try normQuery(a, fmtA(a, "{s}{s}{{\"get3dcntr\":[0,0,0],\"get3dinfo\":[1,2,3],\"get3dinfo_order\":\"dx,dy,dz\"}}}}]}}", .{ head, row }));
    try testing.expectEqual(@as(usize, 0), bad_order.measured);
}

test "only a query work copy of a case attempt has the shape that an owned discard needs" {
    try testing.expect(queryCopyShape("cases/resource.gradient.three_stop/attempt-1/work/query-1/reopened.vwx"));
    try testing.expect(queryCopyShape("cases/c/attempt-12/work/query/reopened.vwx"));
    for ([_][]const u8{
        "cases/c/attempt-1/source/reopened.vwx",
        "cases/c/attempt-1/work/query-1/other.vwx",
        "cases/c/attempt-1/work/stl.binary/reopened.vwx",
        "cases/c/attempt-1/work/query-1/sub/reopened.vwx",
        "cases/c/attempt-1/work/query-1/../source/reopened.vwx",
        "cases/c/work/query-1/reopened.vwx",
        "cases/c/attempt/work/query-1/reopened.vwx",
        "cases//attempt-1/work/query-1/reopened.vwx",
        "other/c/attempt-1/work/query-1/reopened.vwx",
        "work/query-1/reopened.vwx",
        "",
    }) |p| try testing.expect(!queryCopyShape(p));
}

test "reference proof separates a proven other document from an unproven bridge failure" {
    try testing.expect(referenceProof(.{ .status = .ok }) == .matches);
    const other = "Traceback (most recent call last):\n  File \"x\", line 1\nRuntimeError: the active document is 'ref-b.vwx' at '/x/ref-b.vwx'. The request accepts ['/x/ref-a.vwx']";
    try testing.expect(referenceProof(.{ .status = .failed, .detail = other }) == .other);
    const nopath = "Traceback\nRuntimeError: vs.GetFPathName returns ''. Only a saved session copy is accepted";
    try testing.expect(referenceProof(.{ .status = .failed, .detail = nopath }) == .other);
    try testing.expect(referenceProof(.{ .status = .failed, .detail = "document window query failed" }) == .failed);
    try testing.expect(referenceProof(.{ .status = .modal, .detail = "the window backend reports a modal or unreadable window" }) == .failed);
    try testing.expect(referenceProof(.{ .status = .timeout, .detail = "no done file" }) == .failed);
    try testing.expect(referenceProof(.{ .status = .failed, .detail = other, .uncertain = true }) == .failed);
}

test "activation step is done only for a press and uncertain only for a failed press" {
    try testing.expectEqual(orc.StepStatus.done, activationStep(.{ .status = .pressed }).status);
    const pf = activationStep(.{ .status = .press_failed });
    try testing.expect(pf.status == .failed and pf.uncertain);
    for ([_]uidiag.MenuStatus{ .not_running, .identity_mismatch, .read_failed, .refused_policy, .refused_path_missing, .refused_path_ambiguous, .refused_not_an_item, .refused_leaf_submenu, .refused_leaf_disabled, .refused_identity_changed }) |s| {
        const st = activationStep(.{ .status = s });
        try testing.expect(st.status == .refused and !st.uncertain);
    }
}

const test_root = @import("build_options").volume;
const journal_ref_a = test_root ++ "/Caches/tmp/rosetta-export-expansion-20261015.PaJbkB/extrude.asym.vwx";
const journal_ref_b = test_root ++ "/Caches/tmp/trial-live-observation-20261015.zpNvyR/readiness-initial.vwx";

fn journalSession(a: Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    return tmp.dir.realPathFileAlloc(testing.io, ".", a);
}

fn journalRecord(a: Allocator, reference: []const u8, uncertain: bool) []const u8 {
    var o = Obj.init(a);
    o.str("schema", "vwx-rosetta-capture-reference-cleanup/1");
    o.str("reference", reference);
    o.boolean("uncertain", uncertain);
    return stringify(a, o.value());
}

test "owned reference journal: a marker of the reference refuses and a marker of another reference does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_a) == null);
    const mp = referenceMarkerPath(a, dir, journal_ref_a);
    try testing.expect(createReferenceMarker(testing.io, mp, "{}"));
    try testing.expect(exists(testing.io, mp));
    // Exclusive creation: a second run cannot take the marker.
    try testing.expect(!createReferenceMarker(testing.io, mp, "{\"other\":1}"));
    const kept = try readAll(a, testing.io, mp);
    try testing.expectEqualStrings("{}", kept);
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_a) != null);
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_b) == null);
    try testing.expect(createReferenceMarker(testing.io, referenceMarkerPath(a, dir, journal_ref_b), "{}"));
}

test "owned reference journal: an uncertain or unreadable record refuses and a later distinct success does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    _ = try publishReferenceRecord(a, testing.io, dir, journalRecord(a, journal_ref_a, true));
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_a) != null);
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_b) == null);
    // A successful record of the distinct reference leaves the uncertain latch of the first in place.
    _ = try publishReferenceRecord(a, testing.io, dir, journalRecord(a, journal_ref_b, false));
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_a) != null);
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_b) == null);
    // A record that does not parse proves nothing and refuses every reference.
    _ = try publishReferenceRecord(a, testing.io, dir, "{\"reference\":");
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_b) != null);
}

test "owned reference journal: publication never replaces an existing record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    const first = journalRecord(a, journal_ref_a, true);
    // A racing run took number 1 after this run scanned. Creation is exclusive, so this run takes 2.
    try testing.expectEqual(@as(usize, 1), try publishReferenceRecord(a, testing.io, dir, first));
    try testing.expectEqual(@as(usize, 2), try publishReferenceRecord(a, testing.io, dir, journalRecord(a, journal_ref_a, false)));
    try testing.expectEqual(@as(usize, 3), try publishReferenceRecord(a, testing.io, dir, journalRecord(a, journal_ref_b, false)));
    const p1 = fmtA(a, "{s}/cleanup-records/reference-1.json", .{dir});
    try testing.expectEqualStrings(first, try readAll(a, testing.io, p1));
    try testing.expect(!exists(testing.io, fmtA(a, "{s}.superseded.1", .{p1})));
    // The record is read-only.
    try testing.expectError(error.AccessDenied, Dir.cwd().openFile(testing.io, p1, .{ .mode = .read_write }));
}

const JournalFake = struct {
    marker: []const u8,
    activations: usize = 0,
    closes: usize = 0,
    close: orc.Step = .{ .status = .failed, .uncertain = true, .detail = "unproven" },

    fn ops(f: *JournalFake) orc.Ops {
        return .{ .ptr = f, .exePathFn = exePath, .canonicalFn = canon, .digestFn = digest, .activeFn = active, .activateFn = activate, .closeFn = closeFn, .beginFn = begin };
    }
    fn self(p: *anyopaque) *JournalFake {
        return @ptrCast(@alignCast(p));
    }
    fn exePath(_: *anyopaque, _: i32, buf: []u8) ?[]const u8 {
        const e = "/Applications/Vectorworks 2027/Vectorworks 2027.app/Contents/MacOS/Vectorworks";
        @memcpy(buf[0..e.len], e);
        return buf[0..e.len];
    }
    fn canon(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn digest(_: *anyopaque, _: []const u8) ?[]const u8 {
        return "a" ** 64;
    }
    fn active(_: *anyopaque, _: []const u8) orc.Active {
        return .matches;
    }
    fn activate(p: *anyopaque, _: []const u8) orc.Step {
        self(p).activations += 1;
        return .{ .status = .done };
    }
    fn closeFn(p: *anyopaque, _: []const u8, _: bool) orc.Step {
        const f = self(p);
        f.closes += 1;
        return f.close;
    }
    fn begin(p: *anyopaque) bool {
        return createReferenceMarker(testing.io, self(p).marker, "{}");
    }
};

test "owned reference journal: after an uncertain close the marker stays and a second run dispatches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    const req: orc.Request = .{ .operator_authorized = true, .pid = 4242, .expected_executable = "/Applications/Vectorworks 2027/Vectorworks 2027.app/Contents/MacOS/Vectorworks", .reference = journal_ref_a, .reference_sha256 = "a" ** 64, .reason = "pending fixture" };
    var f1: JournalFake = .{ .marker = referenceMarkerPath(a, dir, journal_ref_a) };
    const rep = orc.run(req, f1.ops());
    try testing.expectEqual(orc.Outcome.uncertain, rep.outcome);
    try testing.expect(rep.begun);
    try testing.expectEqual(@as(usize, 1), f1.closes);
    // The marker was created before the dispatched close and the command keeps it for an uncertain outcome.
    try testing.expect(exists(testing.io, f1.marker));
    // The command-line pre-check refuses before any effect.
    try testing.expect(referenceRefusal(a, testing.io, dir, journal_ref_a) != null);
    // A run that got past that check still dispatches nothing: the exclusive marker creation fails.
    var f2: JournalFake = .{ .marker = f1.marker };
    const rep2 = orc.run(req, f2.ops());
    try testing.expectEqual(orc.Outcome.stopped, rep2.outcome);
    try testing.expect(!rep2.begun);
    try testing.expectEqual(@as(usize, 0), f2.activations);
    try testing.expectEqual(@as(usize, 0), f2.closes);
    try testing.expectEqual(@as(usize, 0), rep2.n_actions);
}

const exclusion_exe = "/Applications/Vectorworks 2027/Vectorworks 2027.app/Contents/MacOS/Vectorworks";

/// Runs `close-reference` for `reference` against `dir`. The refusals under test happen before any backend.
fn exclusionCommand(a: Allocator, dir: []const u8, reference: []const u8, d: *Diags) !u8 {
    const argv = [_][]const u8{ dir, "--pid", "4242", "--sender", "/x/sender", "--expected-executable", exclusion_exe, "--reference", reference, "--reference-sha256", "a" ** 64, "--reason", "fixture", "--operator-authorized" };
    const x = parseArgs(a, &argv).?;
    var out: Io.Writer.Allocating = .init(a);
    return closeReferenceCommand(a, testing.io, d, &x, dir, &out.writer);
}

fn expectNoCleanupEffects(a: Allocator, dir: []const u8) !void {
    try testing.expect(!exists(testing.io, fmtA(a, "{s}/cleanup-records", .{dir})));
    try testing.expect(!exists(testing.io, fmtA(a, "{s}/native-requests", .{dir})));
}

test "owned reference exclusion: creation is exclusive and a second reference is refused without effects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    // The first process takes the session lock. This process is alive, so the lock names a live process.
    try testing.expect(acquireSessionExclusion(a, testing.io, dir) == null);
    const lp = fmtA(a, "{s}/LOCK", .{dir});
    const mine = try readAll(a, testing.io, lp);
    // A second acquisition fails at the exclusive create and leaves the lock as it was.
    try testing.expect(acquireSessionExclusion(a, testing.io, dir) != null);
    try testing.expectEqualStrings(mine, try readAll(a, testing.io, lp));
    // The command for a different reference of the same session fails before the application and any record.
    var d = Diags.init(a);
    try testing.expectEqual(@as(u8, 1), try exclusionCommand(a, dir, journal_ref_b, &d));
    try testing.expect(d.has("reference_refused"));
    try expectNoCleanupEffects(a, dir);
    try testing.expectEqualStrings(mine, try readAll(a, testing.io, lp));
    try testing.expect(!exists(testing.io, referenceMarkerPath(a, dir, journal_ref_b)));
}

test "owned reference exclusion: a live capture lock refuses and a lock of no live process refuses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    const lp = fmtA(a, "{s}/LOCK", .{dir});
    // The format and the holder of `acquireLock`: the pid of a live capture run and a newline.
    try writeNew(testing.io, lp, fmtA(a, "{d}\n", .{std.c.getppid()}));
    var d = Diags.init(a);
    try testing.expectEqual(@as(u8, 1), try exclusionCommand(a, dir, journal_ref_a, &d));
    try testing.expect(d.has("reference_refused"));
    try expectNoCleanupEffects(a, dir);
    try testing.expectEqualStrings(fmtA(a, "{d}\n", .{std.c.getppid()}), try readAll(a, testing.io, lp));
    // The lock is never released by a process that does not hold it.
    try testing.expect(!releaseSessionExclusion(a, testing.io, dir));
    try testing.expect(exists(testing.io, lp));
    // A lock that names no live process is not taken over either.
    try Dir.cwd().deleteFile(testing.io, lp);
    try writeNew(testing.io, lp, "2147483646\n");
    var d2 = Diags.init(a);
    try testing.expectEqual(@as(u8, 1), try exclusionCommand(a, dir, journal_ref_a, &d2));
    try expectNoCleanupEffects(a, dir);
    try testing.expectEqualStrings("2147483646\n", try readAll(a, testing.io, lp));
}

test "owned reference exclusion: after a proven success the lock is released and a distinct reference runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    const lp = fmtA(a, "{s}/LOCK", .{dir});
    const refs = [_][]const u8{ journal_ref_a, journal_ref_b };
    for (refs) |ref| {
        try testing.expect(acquireSessionExclusion(a, testing.io, dir) == null);
        try testing.expect(referenceRefusal(a, testing.io, dir, ref) == null);
        const req: orc.Request = .{ .operator_authorized = true, .pid = 4242, .expected_executable = exclusion_exe, .reference = ref, .reference_sha256 = "a" ** 64, .reason = "fixture" };
        var f: JournalFake = .{ .marker = referenceMarkerPath(a, dir, ref), .close = .{ .status = .done } };
        const rep = orc.run(req, f.ops());
        try testing.expectEqual(orc.Outcome.closed, rep.outcome);
        try testing.expectEqual(@as(usize, 1), f.closes);
        // Published while the lock is held, the marker and the lock go afterwards.
        try testing.expect(exists(testing.io, lp));
        _ = try publishReferenceRecord(a, testing.io, dir, journalRecord(a, ref, false));
        try Dir.cwd().deleteFile(testing.io, f.marker);
        try testing.expect(releaseSessionExclusion(a, testing.io, dir));
        try testing.expect(!exists(testing.io, lp));
    }
    try testing.expect(exists(testing.io, fmtA(a, "{s}/cleanup-records/reference-2.json", .{dir})));
}

// Reference path proof through `native-probe doc`

const proof_exe = "/Applications/Vectorworks 2027/Vectorworks 2027.app/Contents/MacOS/Vectorworks";
const proof_ref = "/private/tmp/pathproof.AbC123/ref.vwx";

const ProofSender = struct {
    mode: enum { correct, wrong_path, other_document, no_path_document, bridge_other, exit_1 } = .correct,
    calls: u32 = 0,
    t: u64 = 0,

    fn transport(f: *ProofSender) nur.Transport {
        return .{ .ptr = f, .runFn = runImpl };
    }
    fn env(f: *ProofSender) nur.Env {
        return .{ .ptr = f, .nowFn = nowImpl, .sleepFn = sleepImpl };
    }
    fn nowImpl(ptr: *anyopaque) u64 {
        const f: *ProofSender = @ptrCast(@alignCast(ptr));
        return f.t;
    }
    fn sleepImpl(ptr: *anyopaque, ms: u32) void {
        const f: *ProofSender = @ptrCast(@alignCast(ptr));
        f.t += @as(u64, ms) * std.time.ns_per_ms;
    }
    fn put(path: []const u8, bytes: []const u8) void {
        const fh = Dir.cwd().createFile(testing.io, path, .{ .exclusive = true }) catch return;
        defer fh.close(testing.io);
        fh.writeStreamingAll(testing.io, bytes) catch {};
    }
    fn runImpl(ptr: *anyopaque, a: Allocator, argv: []const []const u8, _: u32, _: nur.StreamLimits) nur.RunOutput {
        const f: *ProofSender = @ptrCast(@alignCast(ptr));
        f.calls += 1;
        if (f.mode == .exit_1) return .{ .status = .exited, .exit_code = 1, .stderr = a.dupe(u8, "AppleEvent timed out. (-1712)\n") catch &.{} };
        const dir = std.fs.path.dirname(argv[2]).?;
        const out_p = fmtA(a, "{s}/out.json", .{dir});
        const err_p = fmtA(a, "{s}/err.txt", .{dir});
        const done_p = fmtA(a, "{s}/done", .{dir});
        switch (f.mode) {
            .correct => put(out_p, fmtA(a, "{{\"document\":\"ref.vwx\",\"path\":\"{s}\"}}", .{proof_ref})),
            .wrong_path => put(out_p, "{\"document\":\"ref.vwx\",\"path\":\"/private/tmp/pathproof.AbC123/other.vwx\"}"),
            .other_document => put(err_p, "Traceback\nRuntimeError: the active document is 'b.vwx' at '/x/b.vwx'. The request accepts ['/x/ref.vwx']\n"),
            .no_path_document => put(err_p, "Traceback\nRuntimeError: vs.GetFPathName returns ''. Only a saved session copy is accepted\n"),
            .bridge_other => put(err_p, "Traceback\nRuntimeError: vs.GetFName is unavailable\n"),
            .exit_1 => unreachable,
        }
        put(done_p, "done\n");
        return .{ .status = .exited };
    }
};

const FailedWindows = struct {
    calls: u32 = 0,
    fn backend(f: *FailedWindows) uidiag.Backend {
        return .{ .ptr = f, .windowsFn = windowsImpl, .treeFn = treeImpl, .captureFn = captureImpl };
    }
    fn windowsImpl(ptr: *anyopaque, _: uidiag.Target) uidiag.WindowsReply {
        const f: *FailedWindows = @ptrCast(@alignCast(ptr));
        f.calls += 1;
        return .{ .failed = .{ .kind = .transport_error, .detail = "windows unreadable" } };
    }
    fn treeImpl(_: *anyopaque, _: uidiag.Target, _: uidiag.TreeLimits) uidiag.TreeReply {
        return .{ .failed = .{ .kind = .transport_error, .detail = "no tree" } };
    }
    fn captureImpl(_: *anyopaque, _: uidiag.Target, _: []const u8) uidiag.CaptureReply {
        return .{ .failed = .{ .kind = .transport_error, .detail = "no capture" } };
    }
};

fn proofPidPath(_: i32, buf: []u8) ?[]const u8 {
    @memcpy(buf[0..proof_exe.len], proof_exe);
    return buf[0..proof_exe.len];
}

/// The production adapter over fakes. The window backend always fails, the sender is `snd`.
fn proofOps(a: Allocator, dir: []const u8, snd: *ProofSender, win: *FailedWindows, n: *NativeDriver, sender: []const u8) ReferenceOps {
    n.* = .{ .a = a, .io = testing.io, .cfg = .{
        .pid = 4242,
        .sender = sender,
        .request_root = fmtA(a, "{s}/native-requests", .{dir}),
        .window_backend = win.backend(),
        .transport = snd.transport(),
        .expected_executable = proof_exe,
        .pathOf = proofPidPath,
        .inflight_dir = dir,
    }, .doc = proof_ref };
    return .{ .a = a, .io = testing.io, .n = n, .menu = undefined, .env = snd.env(), .transport = snd.transport(), .pid = 4242, .exe = proof_exe, .reference = proof_ref };
}

fn proofSender(a: Allocator, dir: []const u8) ![]const u8 {
    const sp = fmtA(a, "{s}/sender", .{dir});
    try writeNew(testing.io, sp, "#!/bin/sh\n");
    return sp;
}

test "reference path proof: a failed window backend no longer stops the proof before the document request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    var snd: ProofSender = .{};
    var win: FailedWindows = .{};
    var n: NativeDriver = undefined;
    var ro = proofOps(a, dir, &snd, &win, &n, try proofSender(a, dir));
    const saved = seams.pid_path;
    seams.pid_path = proofPidPath;
    defer seams.pid_path = saved;
    // The old route fails on its window precheck, before any sender call. That is the defect.
    const old = n.python(a, .{ .kind = .state, .case_id = "reference-cleanup", .profile_id = "", .path = proof_ref, .expect = "ref.vwx" }, "doc");
    try testing.expectEqual(@as(u32, 0), snd.calls);
    try testing.expect(old.status != .ok and std.mem.indexOf(u8, old.detail, "the window backend reports a modal or unreadable window") != null);
    win.calls = 0;
    // The adapter reaches the proof request and the correct response path proves the match.
    const proof = ro.ops().activeFn(ro.ops().ptr, proof_ref);
    try testing.expect(proof == .matches);
    try testing.expectEqual(@as(u32, 1), snd.calls);
    try testing.expectEqual(@as(u32, 0), win.calls);
    // The request is a read-only doc request for the exact document, kept under native-requests.
    const rq = try readAll(a, testing.io, fmtA(a, "{s}/native-requests/probe-4242-0/request.json", .{dir}));
    const v = try parseJson(a, rq);
    try testing.expectEqualStrings("doc", strField(v, "op").?);
    try testing.expectEqualStrings(proof_ref, strField(v, "document").?);
    try testing.expect(exists(testing.io, fmtA(a, "{s}/native-requests/probe-4242-0/probe-result.json", .{dir})));
}

test "reference path proof: only the response path equality and the two bridge markers decide" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    var snd: ProofSender = .{};
    var win: FailedWindows = .{};
    var n: NativeDriver = undefined;
    var ro = proofOps(a, dir, &snd, &win, &n, try proofSender(a, dir));
    const saved = seams.pid_path;
    seams.pid_path = proofPidPath;
    defer seams.pid_path = saved;
    snd.mode = .wrong_path;
    const wrong = ro.ops().activeFn(ro.ops().ptr, proof_ref);
    try testing.expect(wrong == .failed);
    try testing.expect(std.mem.indexOf(u8, wrong.failed, "differs from the reference") != null);
    snd.mode = .other_document;
    try testing.expect(ro.ops().activeFn(ro.ops().ptr, proof_ref) == .other);
    snd.mode = .no_path_document;
    try testing.expect(ro.ops().activeFn(ro.ops().ptr, proof_ref) == .other);
    snd.mode = .bridge_other;
    const other = ro.ops().activeFn(ro.ops().ptr, proof_ref);
    try testing.expect(other == .failed);
    try testing.expect(std.mem.indexOf(u8, other.failed, "bridge_error") != null and std.mem.indexOf(u8, other.failed, "vs.GetFName is unavailable") != null);
}

test "reference path proof: a real sender setup failure keeps its outcome, status and stderr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try journalSession(a, &tmp);
    var snd: ProofSender = .{ .mode = .exit_1 };
    var win: FailedWindows = .{};
    var n: NativeDriver = undefined;
    var ro = proofOps(a, dir, &snd, &win, &n, try proofSender(a, dir));
    const saved = seams.pid_path;
    seams.pid_path = proofPidPath;
    defer seams.pid_path = saved;
    const proof = ro.ops().activeFn(ro.ops().ptr, proof_ref);
    try testing.expect(proof == .failed);
    for ([_][]const u8{ "sender_failed", "exit code 1", "AppleEvent timed out. (-1712)", "native-probe doc" }) |part| {
        try testing.expect(std.mem.indexOf(u8, proof.failed, part) != null);
    }
    // A sender that is not a regular file is refused by the probe and also stays specific.
    var ro2 = proofOps(a, dir, &snd, &win, &n, "/nonexistent/sender");
    const refused_proof = ro2.ops().activeFn(ro2.ops().ptr, proof_ref);
    try testing.expect(refused_proof == .failed and std.mem.indexOf(u8, refused_proof.failed, "--sender is not a regular file") != null);
    // The cleanup report and record carry that detail instead of the generic sentence alone.
    const req: orc.Request = .{ .operator_authorized = true, .pid = 4242, .expected_executable = proof_exe, .reference = proof_ref, .reference_sha256 = "a" ** 64, .reason = "fixture" };
    var f: ProofFailFake = .{ .detail = proof.failed };
    const rep = orc.run(req, f.ops());
    try testing.expectEqual(orc.Outcome.refused, rep.outcome);
    try testing.expectEqual(@as(u32, 0), rep.proofs);
    try testing.expectEqualStrings(proof.failed, rep.proof_detail);
    try testing.expect(!rep.begun and rep.n_actions == 0);
}

const ProofFailFake = struct {
    detail: []const u8,
    fn ops(f: *ProofFailFake) orc.Ops {
        return .{ .ptr = f, .exePathFn = exePath, .canonicalFn = canon, .digestFn = digest, .activeFn = active, .activateFn = activate, .closeFn = closeFn };
    }
    fn exePath(_: *anyopaque, _: i32, buf: []u8) ?[]const u8 {
        @memcpy(buf[0..proof_exe.len], proof_exe);
        return buf[0..proof_exe.len];
    }
    fn canon(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn digest(_: *anyopaque, _: []const u8) ?[]const u8 {
        return "a" ** 64;
    }
    fn active(p: *anyopaque, _: []const u8) orc.Active {
        const f: *ProofFailFake = @ptrCast(@alignCast(p));
        return .{ .failed = f.detail };
    }
    fn activate(_: *anyopaque, _: []const u8) orc.Step {
        unreachable;
    }
    fn closeFn(_: *anyopaque, _: []const u8, _: bool) orc.Step {
        unreachable;
    }
};
