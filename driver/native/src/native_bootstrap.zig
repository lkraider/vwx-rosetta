//! Read-only capability probe of one running application process.
//!
//! `vwx native-probe` sends one `preflight` or `doc` request of the accepted Rosetta bridge
//! (`rosetta_capture.bridge_py`) through the existing sender protocol `<sender> <pid> <program.py>`.
//! The command launches no application. It has no route that quits, opens, saves, edits or closes a
//! document. The sender runs only through `native_ui_runtime.Transport`, which owns the child and
//! kills its process group at the deadline.
//!
//! Identity. `proc_pidpath` of `--pid` must equal `--expected-executable` byte for byte before the
//! sender runs. A mismatch refuses the request and the sender never starts.
//!
//! Request files. `<out>/probe-<pid>-<n>/` is created exclusively and holds `request.json`,
//! `program.py`, the bridge `out.json` or `err.txt`, the bridge `done` marker and the command's own
//! `probe-result.json`. `program.py` is the prefix below followed by `bridge_py` byte for byte. For
//! `doc` the prefix writes `request-effective.json` next to the request. It copies `request.json`
//! and fills `document` with the path that `vs.GetFPathName` returns when `--document` was not
//! given. The bridge then reports the active document and changes nothing. A `preflight` request
//! needs no document.
//!
//! Completion. The request completes when the bridge wrote its `done` marker (`done\n`) and a valid
//! response. Polling uses `nur.Backoff` and only decides when to look. A timeout and the raw sender
//! status are separate fields of the result. A timeout leaves the outcome of the script unknown.
//!
//! Status of this revision. Every test drives a fake sender, a fake clock and a fake process path.
//! The bridge Python has not run in an installed application from this command. A `preflight` with
//! no document window has no native evidence that the application accepts it.

const std = @import("std");
const builtin = @import("builtin");
const nur = @import("native_ui_runtime.zig");
const rc = @import("rosetta_capture.zig");
const opdir = @import("rosetta_opdir.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

pub const schema_result = "vwx-native-probe/1";
const max_response_bytes = 1 << 20;
const max_error_bytes = 16 * 1024;
const max_text_bytes = 2048;

pub const Kind = enum { preflight, doc, state, state_ext, scalar_units, plugin_workspace, frame_readback };

/// True for the requests that read the document state. They need an explicit `--document`.
fn needsDocument(k: Kind) bool {
    return k == .state or k == .state_ext or k == .scalar_units or k == .plugin_workspace or k == .frame_readback;
}

pub const Config = struct {
    pid: i32,
    expected_executable: []const u8,
    sender: []const u8,
    out_dir: []const u8,
    kind: Kind = .preflight,
    /// Absolute path the bridge must find open. Null lets the prefix read the active document path.
    document: ?[]const u8 = null,
    /// Names added to the preflight API list.
    extra_apis: []const []const u8 = &.{},
    /// Universal names that `plugin_workspace` reads with `vs.HasPlugin`. Empty for other requests.
    plugins: []const []const u8 = &.{},
    /// Exact layer names that `frame_readback` binds with `vs.GetLayerByName`. Empty for other requests.
    layers: []const []const u8 = &.{},
    /// `frame_readback` also binds the layer of the one selected object.
    current_object_layer: bool = false,
    /// Bound of the whole request after the sender returned.
    timeout_ms: u32 = 60_000,
    /// Bound of the sender process.
    send_timeout_ms: u32 = 15_000,
    poll_min_ms: u32 = 10,
    poll_max_ms: u32 = 250,
};

/// Process path of a pid, or null when the pid does not run. Production uses `proc_pidpath`.
pub const PidPathFn = *const fn (a: Allocator, pid: i32) ?[]const u8;

pub const Deps = struct {
    transport: nur.Transport,
    env: nur.Env,
    pid_path: PidPathFn,
};

pub const Outcome = enum {
    ok,
    refused,
    pid_not_running,
    executable_mismatch,
    sender_failed,
    bridge_error,
    invalid_response,
    process_gone,
    timeout,
    output_failed,
};

pub const SenderRecord = struct {
    status: []const u8,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    elapsed_ms: u64,
};

pub const Result = struct {
    outcome: Outcome,
    detail: []const u8 = "",
    observed_executable: ?[]const u8 = null,
    request_dir: ?[]const u8 = null,
    sender: ?SenderRecord = null,
    polls: u32 = 0,
    waited_ms: u64 = 0,
    /// Parsed `out.json` of an `ok` outcome.
    response: ?std.json.Value = null,
    /// Names the preflight reported present and absent. Empty for other requests.
    apis_present: []const []const u8 = &.{},
    apis_absent: []const []const u8 = &.{},
    /// A timeout or a vanished process leaves the script outcome unknown.
    uncertain: bool = false,
};

// Production process path

extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

/// `proc_pidpath` of the pid. Null off macOS, for a pid that does not run and for an empty result.
pub fn systemPidPath(a: Allocator, pid: i32) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    var buf: [4096]u8 = undefined;
    const n = proc_pidpath(pid, &buf, buf.len);
    if (n <= 0) return null;
    return a.dupe(u8, buf[0..@intCast(n)]) catch null;
}

// Request files

fn writeNew(io: Io, path: []const u8, bytes: []const u8) !void {
    var fh = try Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer fh.close(io);
    try fh.writeStreamingAll(io, bytes);
}

fn fileExists(io: Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn isRegular(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .file;
}

fn readFile(a: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, a, .limited(limit));
}

fn jsonText(a: Allocator, v: anytype) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.written();
}

/// Python string literal of a path. JSON string syntax is valid Python for these characters.
fn pyString(a: Allocator, s: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(s, .{}, &aw.writer);
    return aw.written();
}

/// Prefix of the bridge program for `doc`. The bridge body follows unchanged.
fn docPrefix(a: Allocator, req_path: []const u8, effective: []const u8) ![]u8 {
    const q_req = try pyString(a, req_path);
    const q_eff = try pyString(a, effective);
    return std.fmt.allocPrint(a,
        \\REQ_PATH = {s}
        \\def _probe_effective_request(src, dst):
        \\    import json, vs
        \\    f = open(src, 'r', encoding='utf-8')
        \\    try:
        \\        r = json.load(f)
        \\    finally:
        \\        f.close()
        \\    if not r.get('document'):
        \\        p = vs.GetFPathName()
        \\        r['document'] = p if isinstance(p, str) and p else '(no saved document)'
        \\    g = open(dst, 'w', encoding='utf-8')
        \\    try:
        \\        g.write(json.dumps(r))
        \\    finally:
        \\        g.close()
        \\try:
        \\    _probe_effective_request(REQ_PATH, {s})
        \\    REQ_PATH = {s}
        \\except Exception:
        \\    pass
        \\
    , .{ q_req, q_eff, q_eff });
}

fn apiNames(a: Allocator, extra: []const []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (rc.bridge_apis) |x| try names.append(a, x);
    var d = rc.Diags.init(a);
    for (rc.parseEntries(a, &d, rc.default_entries, "default entries")) |e| {
        if (!inList(names.items, e.api)) try names.append(a, e.api);
    }
    for (extra) |x| if (!inList(names.items, x)) try names.append(a, x);
    return names.items;
}

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn ascii(a: Allocator, bytes: []const u8) []const u8 {
    const n = @min(bytes.len, max_text_bytes);
    const out = a.alloc(u8, n) catch return "";
    for (bytes[0..n], out) |c, *o| o.* = if (c == '\n' or c == '\t' or (c >= 0x20 and c < 0x7f)) c else '?';
    return out;
}

fn senderRecord(a: Allocator, r: nur.RunOutput) SenderRecord {
    return .{
        .status = @tagName(r.status),
        .exit_code = r.exit_code,
        .stdout = ascii(a, r.stdout),
        .stderr = ascii(a, r.stderr),
        .stdout_truncated = r.stdout_truncated,
        .stderr_truncated = r.stderr_truncated,
        .elapsed_ms = r.elapsed_ns / std.time.ns_per_ms,
    };
}

fn validResponse(kind: Kind, v: std.json.Value, cfg: Config) ?[]const u8 {
    if (v != .object) return "out.json is not a JSON object";
    switch (kind) {
        .preflight => {
            const s = v.object.get("schema") orelse return "preflight response has no schema";
            if (s != .string or !std.mem.eql(u8, s.string, "vwx-rosetta-capabilities/1")) return "preflight response schema is not vwx-rosetta-capabilities/1";
            const apis = v.object.get("apis") orelse return "preflight response has no apis";
            if (apis != .object) return "preflight apis is not an object";
        },
        .state, .state_ext => {
            const s = v.object.get("schema") orelse return "state response has no schema";
            if (s != .string or !std.mem.eql(u8, s.string, rc.schema_state)) return "state response schema is not vwx-rosetta-native-state/1";
            const keys = [_][]const u8{ "classes", "layers", "origin" };
            for (keys) |k| {
                const x = v.object.get(k) orelse return "state response lacks classes, layers or origin";
                if (x != .array) return "state classes, layers and origin must be arrays";
            }
            const u = v.object.get("units") orelse return "state response has no units";
            if (u != .object) return "state units is not an object";
            if (kind == .state_ext) {
                const e = v.object.get("ext") orelse return "state_ext response has no ext";
                if (e != .object) return "state_ext ext is not an object";
            }
        },
        .scalar_units => return scalarUnitsProblem(v),
        .plugin_workspace => return pluginWorkspaceProblem(v, cfg.plugins),
        .frame_readback => return frameReadbackProblem(v, cfg),
        .doc => {
            const d = v.object.get("document") orelse return "doc response has no document";
            const p = v.object.get("path") orelse return "doc response has no path";
            if (d != .string or p != .string) return "doc response fields are not strings";
        },
    }
    return null;
}

// Scalar unit probe

pub const schema_scalar_units = "vwx-native-scalar-units/1";

/// One preference read of `scalar_units`. `want` names the Python type that the SDK declares.
pub const PrefSpec = struct { api: []const u8, selector: i32, want: []const u8 };

/// The preference reads of `scalar_units`. Selectors 176 and 180 are GetPrefReal and 178 and 182 are
/// GetPrefString in developer-scripting Appendix F and SDK ProgramVariables.h. Every entry is a
/// getter. The request reads raw values and maps none of them to a unit.
pub const scalar_prefs = [_]PrefSpec{
    .{ .api = "vs.GetPrefReal", .selector = 176, .want = "number" },
    .{ .api = "vs.GetPrefReal", .selector = 180, .want = "number" },
    .{ .api = "vs.GetPrefString", .selector = 178, .want = "string" },
    .{ .api = "vs.GetPrefString", .selector = 182, .want = "string" },
};

/// Extension of the accepted bridge. `_main` still enforces the exact active document for every
/// operation except `preflight`. Each record holds its own status. A missing API or an exception
/// stays in its record and the other records remain. A nonfinite number never reaches
/// `json.dumps(allow_nan=False)`. It becomes null with a `nonfinite` annotation.
/// native_verification: unexecuted.
const scalar_ext_head =
    \\# Read-only scalar unit probe. Getters only. One record per call.
    \\def _sx_clean(v, flags):
    \\    if v is None or isinstance(v, (bool, int, str)):
    \\        return v
    \\    if isinstance(v, float):
    \\        if math.isfinite(v):
    \\            return v
    \\        flags.append(repr(v))
    \\        return None
    \\    if isinstance(v, (list, tuple)):
    \\        return [_sx_clean(x, flags) for x in v]
    \\    if isinstance(v, dict):
    \\        return dict((str(k), _sx_clean(x, flags)) for k, x in v.items())
    \\    return repr(v)
    \\
    \\def _sx_call(api, args, want):
    \\    rec = {'api': api, 'selector': args[0] if args else None}
    \\    try:
    \\        name = api[3:]
    \\        if not api.startswith('vs.') or not hasattr(vs, name):
    \\            rec['status'] = 'gap'
    \\            rec['reason'] = 'api_absent'
    \\            return rec
    \\        raw = getattr(vs, name)(*args)
    \\    except Exception as e:
    \\        rec['status'] = 'error'
    \\        rec['reason'] = '%s: %s' % (type(e).__name__, e)
    \\        return rec
    \\    try:
    \\        flags = []
    \\        rec['python_type'] = type(raw).__name__
    \\        rec['raw'] = _sx_clean(_raw(raw), flags)
    \\        if flags:
    \\            rec['status'] = 'nonfinite'
    \\            rec['nonfinite'] = flags
    \\        elif want == 'number' and (isinstance(raw, bool) or not isinstance(raw, (int, float))):
    \\            rec['status'] = 'unexpected_type'
    \\        elif want == 'string' and not isinstance(raw, str):
    \\            rec['status'] = 'unexpected_type'
    \\        elif want == 'sequence' and not isinstance(raw, (list, tuple)):
    \\            rec['status'] = 'unexpected_type'
    \\        else:
    \\            rec['status'] = 'observed'
    \\    except Exception as e:
    \\        rec['status'] = 'error'
    \\        rec['reason'] = '%s: %s' % (type(e).__name__, e)
    \\    return rec
    \\
    \\
;

const scalar_ext_tail =
    \\def op_scalar_units(req):
    \\    prefs = []
    \\    for api, selector, want in _SX_PREFS:
    \\        prefs.append(_sx_call(api, [selector], want))
    \\    return {'schema': 'vwx-native-scalar-units/1', 'read_only': True,
    \\            'units': _sx_call('vs.GetUnits', [], 'sequence'), 'prefs': prefs}
    \\
    \\OPS['scalar_units'] = op_scalar_units
    \\
;

const bridge_tail = "\n_main()\n";

/// The Python extension of `scalar_units`. The preference list is generated from `scalar_prefs`.
fn scalarUnitsExt(a: Allocator) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(a);
    try aw.writer.writeAll(scalar_ext_head);
    try aw.writer.writeAll("_SX_PREFS = [");
    for (scalar_prefs, 0..) |p, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        try aw.writer.print("({s}, {d}, {s})", .{ try pyString(a, p.api), p.selector, try pyString(a, p.want) });
    }
    try aw.writer.writeAll("]\n\n");
    try aw.writer.writeAll(scalar_ext_tail);
    return aw.written();
}

/// The bridge program that follows the prefix. Every request except `scalar_units`, `plugin_workspace` and
/// `frame_readback` sends what it sent before. These three send `bridge_py` with their extension before the
/// final `_main()`. Null when `bridge_py` has no final `_main()` or memory is short.
fn bridgeBody(a: Allocator, kind: Kind) ?[]const u8 {
    if (kind != .scalar_units and kind != .plugin_workspace and kind != .frame_readback) return rc.bridgeProgram(a, @tagName(kind));
    const b = rc.bridge_py;
    if (!std.mem.endsWith(u8, b, bridge_tail)) return null;
    const ext = switch (kind) {
        .plugin_workspace => plugin_ext,
        .frame_readback => frame_ext,
        else => scalarUnitsExt(a) catch return null,
    };
    return std.mem.concat(a, u8, &.{ b[0 .. b.len - bridge_tail.len + 1], ext, bridge_tail[1..] }) catch null;
}

/// True when a parsed number is not finite. Zig keeps a number that overflows `f64` as a
/// `number_string`, so that form is parsed again. A finite big integer stays finite. Zig prints a
/// nonfinite float as `inf` or `nan`, which is not JSON, so the probe refuses such a response.
fn hasNonfinite(v: std.json.Value) bool {
    switch (v) {
        .float => |f| return !std.math.isFinite(f),
        .number_string => |s| return !std.math.isFinite(std.fmt.parseFloat(f64, s) catch return true),
        .array => |arr| {
            for (arr.items) |x| if (hasNonfinite(x)) return true;
            return false;
        },
        .object => |o| {
            for (o.values()) |x| if (hasNonfinite(x)) return true;
            return false;
        },
        else => return false,
    }
}

/// Why a `scalar_units` record is malformed, or null. A record names its API, its selector (an
/// integer, or null for a call without one) and its status.
fn recordProblem(r: std.json.Value) ?[]const u8 {
    if (r != .object) return "scalar_units record is not an object";
    const api = r.object.get("api") orelse return "scalar_units record has no api";
    if (api != .string) return "scalar_units record api is not a string";
    const sel = r.object.get("selector") orelse return "scalar_units record has no selector";
    if (sel != .integer and sel != .null) return "scalar_units record selector is not an integer or null";
    const st = r.object.get("status") orelse return "scalar_units record has no status";
    if (st != .string) return "scalar_units record status is not a string";
    return null;
}

fn scalarUnitsProblem(v: std.json.Value) ?[]const u8 {
    const s = v.object.get("schema") orelse return "scalar_units response has no schema";
    if (s != .string or !std.mem.eql(u8, s.string, schema_scalar_units)) return "scalar_units response schema is not vwx-native-scalar-units/1";
    if (hasNonfinite(v)) return "scalar_units response holds a nonfinite number";
    const u = v.object.get("units") orelse return "scalar_units response has no units record";
    if (recordProblem(u)) |why| return why;
    const ps = v.object.get("prefs") orelse return "scalar_units response has no prefs";
    if (ps != .array) return "scalar_units prefs is not an array";
    for (ps.array.items) |p| if (recordProblem(p)) |why| return why;
    for (scalar_prefs) |spec| {
        var found = false;
        for (ps.array.items) |p| {
            const api = p.object.get("api").?;
            const sel = p.object.get("selector").?;
            if (std.mem.eql(u8, api.string, spec.api) and sel == .integer and sel.integer == spec.selector) found = true;
        }
        if (!found) return "scalar_units prefs lacks a requested record";
    }
    return null;
}

// Plugin workspace probe

pub const schema_plugin_workspace = "vwx-native-plugin-workspace/1";
pub const max_plugins = 8;
pub const max_plugin_bytes = 128;

/// Why a candidate list is refused, or null. A candidate is a non-empty string of at most
/// `max_plugin_bytes` bytes with no control character, no DEL and no invalid UTF-8. The list holds
/// between 1 and `max_plugins` candidates. Duplicates are kept and each one is read.
fn pluginProblem(list: []const []const u8) ?[]const u8 {
    if (list.len == 0) return "--request plugin_workspace needs at least one --plugin";
    if (list.len > max_plugins) return "at most 8 --plugin candidates are accepted";
    for (list) |p| {
        if (p.len == 0) return "a --plugin candidate is empty";
        if (p.len > max_plugin_bytes) return "a --plugin candidate is longer than 128 bytes";
        for (p) |c| if (c < 0x20 or c == 0x7f) return "a --plugin candidate holds a control character";
        if (!std.unicode.utf8ValidateSlice(p)) return "a --plugin candidate is not valid UTF-8";
    }
    return null;
}

/// Extension of the accepted bridge. `_main` still enforces the exact active document. The only
/// `vs.` call is `vs.HasPlugin`, once per requested candidate. It reports whether the tool or
/// command is in the current workspace. It does not show that `vs.CreateCustomObject` accepts the
/// same name. A record keeps the requested string, the raw returned value and its Python type. The
/// status is `observed` only for a (bool, str) pair. Other shapes are `unexpected_shape` and keep
/// the raw value. A missing `vs.HasPlugin` is `gap` and an exception is `error`.
/// native_verification: unexecuted.
const plugin_ext =
    \\# Read-only plug-in workspace probe. vs.HasPlugin only. One record per requested name.
    \\def _pw_call(name):
    \\    rec = {'api': 'vs.HasPlugin', 'requested': name}
    \\    try:
    \\        if not hasattr(vs, 'HasPlugin'):
    \\            rec['status'] = 'gap'
    \\            rec['reason'] = 'api_absent'
    \\            return rec
    \\        raw = vs.HasPlugin(name)
    \\    except Exception as e:
    \\        rec['status'] = 'error'
    \\        rec['reason'] = '%s: %s' % (type(e).__name__, e)
    \\        return rec
    \\    try:
    \\        rec['python_type'] = type(raw).__name__
    \\        rec['raw'] = _raw(raw)
    \\        if isinstance(raw, (list, tuple)) and len(raw) == 2 and isinstance(raw[0], bool) and isinstance(raw[1], str):
    \\            rec['status'] = 'observed'
    \\            rec['in_workspace'] = raw[0]
    \\            rec['palette'] = raw[1]
    \\        else:
    \\            rec['status'] = 'unexpected_shape'
    \\    except Exception as e:
    \\        rec['status'] = 'error'
    \\        rec['reason'] = '%s: %s' % (type(e).__name__, e)
    \\    return rec
    \\
    \\def op_plugin_workspace(req):
    \\    names = req['payload']['plugins']
    \\    return {'schema': 'vwx-native-plugin-workspace/1', 'read_only': True,
    \\            'plugins': [_pw_call(n) for n in names]}
    \\
    \\OPS['plugin_workspace'] = op_plugin_workspace
    \\
;

/// Why a `plugin_workspace` response is malformed, or null. It holds one record per requested
/// string, in request order, each with its API, requested string and status.
fn pluginWorkspaceProblem(v: std.json.Value, requested: []const []const u8) ?[]const u8 {
    const s = v.object.get("schema") orelse return "plugin_workspace response has no schema";
    if (s != .string or !std.mem.eql(u8, s.string, schema_plugin_workspace)) return "plugin_workspace response schema is not vwx-native-plugin-workspace/1";
    const ro = v.object.get("read_only") orelse return "plugin_workspace response has no read_only";
    if (ro != .bool or !ro.bool) return "plugin_workspace read_only is not true";
    const ps = v.object.get("plugins") orelse return "plugin_workspace response has no plugins";
    if (ps != .array) return "plugin_workspace plugins is not an array";
    if (ps.array.items.len != requested.len) return "plugin_workspace plugins does not hold one record per requested name";
    for (ps.array.items, requested) |p, want| {
        if (p != .object) return "plugin_workspace record is not an object";
        const api = p.object.get("api") orelse return "plugin_workspace record has no api";
        if (api != .string or !std.mem.eql(u8, api.string, "vs.HasPlugin")) return "plugin_workspace record api is not vs.HasPlugin";
        const rq = p.object.get("requested") orelse return "plugin_workspace record has no requested string";
        if (rq != .string or !std.mem.eql(u8, rq.string, want)) return "plugin_workspace record requested string differs from the request";
        const st = p.object.get("status") orelse return "plugin_workspace record has no status";
        if (st != .string) return "plugin_workspace record status is not a string";
        if (std.mem.eql(u8, st.string, "observed")) {
            const m = p.object.get("in_workspace") orelse return "plugin_workspace observed record has no in_workspace";
            const pal = p.object.get("palette") orelse return "plugin_workspace observed record has no palette";
            if (m != .bool or pal != .string) return "plugin_workspace observed record has a wrong in_workspace or palette type";
            if (p.object.get("raw") == null) return "plugin_workspace observed record has no raw value";
        }
    }
    return null;
}

// Frame readback probe

pub const schema_frame_readback = "vwx-native-frame-readback/1";
pub const max_layers = 4;
pub const max_layer_bytes = 128;

/// Why a layer-binding option set is refused, or null. A layer name is a non-empty string of at most
/// `max_layer_bytes` bytes with no control character, no DEL and no invalid UTF-8. The request binds at
/// least one layer, by up to `max_layers` exact names or by the one selected object, or both.
fn layerProblem(list: []const []const u8, current_object: bool) ?[]const u8 {
    if (list.len == 0 and !current_object) return "--request frame_readback needs at least one --layer or --current-object-layer";
    if (list.len > max_layers) return "at most 4 --layer names are accepted";
    for (list) |p| {
        if (p.len == 0) return "a --layer name is empty";
        if (p.len > max_layer_bytes) return "a --layer name is longer than 128 bytes";
        for (p) |c| if (c < 0x20 or c == 0x7f) return "a --layer name holds a control character";
        if (!std.unicode.utf8ValidateSlice(p)) return "a --layer name is not valid UTF-8";
    }
    return null;
}

/// Extension of the accepted bridge. `_main` still enforces the exact active document. Every `vs.` call
/// is a getter of the SDK2026 `vs.py` with no side effect. A layer handle comes from
/// `vs.GetLayerByName(name)`, accepted only when `vs.GetLName` returns the same string, or from
/// `vs.GetLayer` of the one selected object that `vs.FSActLayer` returns when `vs.NumSelectedObjects`
/// is 1. A record keeps the raw return, its Python type and its length. The status is `observed` only
/// for the declared count of finite numbers. Other shapes are `unexpected_shape` and keep the raw
/// value. A missing API is `gap` and an exception is `error`. Nothing converts a unit or a frame.
/// native_verification: unexecuted.
const frame_ext =
    \\# Read-only frame readback probe. Getters only. One record per call.
    \\def _fr_clean(v, flags):
    \\    if v is None or isinstance(v, (bool, int, str)):
    \\        return v
    \\    if isinstance(v, float):
    \\        if math.isfinite(v):
    \\            return v
    \\        flags.append(repr(v))
    \\        return None
    \\    if isinstance(v, (list, tuple)):
    \\        return [_fr_clean(x, flags) for x in v]
    \\    return repr(v)
    \\
    \\def _fr_leaves(v):
    \\    if isinstance(v, (list, tuple)):
    \\        out = []
    \\        for x in v:
    \\            out.extend(_fr_leaves(x))
    \\        return out
    \\    return [v]
    \\
    \\def _fr_call(api, args, leaves):
    \\    rec = {'api': api}
    \\    try:
    \\        name = api[3:]
    \\        if not api.startswith('vs.') or not hasattr(vs, name):
    \\            rec['status'] = 'gap'
    \\            rec['reason'] = 'api_absent'
    \\            return rec, None
    \\        raw = getattr(vs, name)(*args)
    \\    except Exception as e:
    \\        rec['status'] = 'error'
    \\        rec['reason'] = '%s: %s' % (type(e).__name__, e)
    \\        return rec, None
    \\    try:
    \\        flags = []
    \\        rec['python_type'] = type(raw).__name__
    \\        rec['raw'] = _fr_clean(raw, flags)
    \\        if isinstance(raw, (list, tuple)):
    \\            rec['length'] = len(raw)
    \\            rec['element_lengths'] = [len(x) if isinstance(x, (list, tuple)) else None for x in raw]
    \\        if flags:
    \\            rec['status'] = 'nonfinite'
    \\            rec['nonfinite'] = flags
    \\        elif leaves is not None:
    \\            lv = _fr_leaves(raw)
    \\            bad = len(lv) != leaves or any(isinstance(x, bool) or not isinstance(x, (int, float)) for x in lv)
    \\            rec['status'] = 'unexpected_shape' if bad else 'observed'
    \\        else:
    \\            rec['status'] = 'observed'
    \\    except Exception as e:
    \\        rec['status'] = 'error'
    \\        rec['reason'] = '%s: %s' % (type(e).__name__, e)
    \\    return rec, raw
    \\
    \\def _fr_layer(out, h, requested):
    \\    if h is None or _nil(h):
    \\        out['status'] = 'unbound'
    \\        out['reason'] = 'nil_layer_handle'
    \\        return out
    \\    out['layer_name'], got = _fr_call('vs.GetLName', [h], None)
    \\    if requested is not None and got != requested:
    \\        out['status'] = 'unbound'
    \\        out['reason'] = 'layer_name_differs_from_request'
    \\        return out
    \\    out['elevation'] = _fr_call('vs.GetLayerElevation', [h], 2)[0]
    \\    out['elevation_n'] = _fr_call('vs.GetLayerElevationN', [h], 2)[0]
    \\    out['status'] = 'bound'
    \\    return out
    \\
    \\def _fr_by_name(name):
    \\    out = {'binding': 'name', 'requested': name}
    \\    out['lookup'], h = _fr_call('vs.GetLayerByName', [name], None)
    \\    return _fr_layer(out, h, name)
    \\
    \\def _fr_current_object():
    \\    out = {'binding': 'current_object', 'requested': None}
    \\    out['selected_count'], n = _fr_call('vs.NumSelectedObjects', [], None)
    \\    if n != 1 or isinstance(n, bool):
    \\        out['status'] = 'unbound'
    \\        out['reason'] = 'not_exactly_one_selected_object'
    \\        return out
    \\    out['object'], o = _fr_call('vs.FSActLayer', [], None)
    \\    if o is None or _nil(o):
    \\        out['status'] = 'unbound'
    \\        out['reason'] = 'selected_object_not_on_active_layer'
    \\        return out
    \\    out['get3dcntr'] = _fr_call('vs.Get3DCntr', [o], 3)[0]
    \\    out['layer_lookup'], h = _fr_call('vs.GetLayer', [o], None)
    \\    return _fr_layer(out, h, None)
    \\
    \\def op_frame_readback(req):
    \\    p = req['payload']
    \\    res = {'schema': 'vwx-native-frame-readback/1', 'read_only': True}
    \\    res['working_plane_n'] = _fr_call('vs.GetWorkingPlaneN', [], 9)[0]
    \\    res['working_plane'] = _fr_call('vs.GetWorkingPlane', [], 6)[0]
    \\    layers = [_fr_by_name(n) for n in p['layers']]
    \\    if p['current_object_layer']:
    \\        layers.append(_fr_current_object())
    \\    res['layers'] = layers
    \\    res['uncertainty'] = [
    \\        'the SDK2026 stub file gives no unit for GetWorkingPlane or GetWorkingPlaneN and no rotation convention for GetWorkingPlane',
    \\        'the SDK documents GetLayerElevation as millimetres in a remark and GetLayerElevationN as document units',
    \\        'no accepted text states the frame of GetWorkingPlaneN, GetLayerElevation or Get3DCntr z',
    \\        'the readback is the state of the open document now and not the state before the sealed save']
    \\    return res
    \\
    \\OPS['frame_readback'] = op_frame_readback
    \\
;

/// Why an API record of `frame_readback` is malformed, or null. It names the exact API and has a
/// status. An observed record keeps its raw value.
fn frameRecordProblem(r: ?std.json.Value, api: []const u8) ?[]const u8 {
    const rec = r orelse return "frame_readback response lacks a record";
    if (rec != .object) return "frame_readback record is not an object";
    const a = rec.object.get("api") orelse return "frame_readback record has no api";
    if (a != .string or !std.mem.eql(u8, a.string, api)) return "frame_readback record api differs from the expected getter";
    const st = rec.object.get("status") orelse return "frame_readback record has no status";
    if (st != .string) return "frame_readback record status is not a string";
    if (std.mem.eql(u8, st.string, "observed") and rec.object.get("raw") == null) return "frame_readback observed record has no raw value";
    return null;
}

/// Why a `frame_readback` response is malformed, or null. It holds the two working-plane records and
/// one layer entry per requested name in request order, then the current-object entry when requested.
/// A bound entry holds the layer name and both elevation records. A bound named entry returns the
/// requested string exactly.
fn frameReadbackProblem(v: std.json.Value, cfg: Config) ?[]const u8 {
    const s = v.object.get("schema") orelse return "frame_readback response has no schema";
    if (s != .string or !std.mem.eql(u8, s.string, schema_frame_readback)) return "frame_readback response schema is not vwx-native-frame-readback/1";
    const ro = v.object.get("read_only") orelse return "frame_readback response has no read_only";
    if (ro != .bool or !ro.bool) return "frame_readback read_only is not true";
    if (hasNonfinite(v)) return "frame_readback response holds a nonfinite number";
    if (frameRecordProblem(v.object.get("working_plane_n"), "vs.GetWorkingPlaneN")) |why| return why;
    if (frameRecordProblem(v.object.get("working_plane"), "vs.GetWorkingPlane")) |why| return why;
    const ls = v.object.get("layers") orelse return "frame_readback response has no layers";
    if (ls != .array) return "frame_readback layers is not an array";
    const want = cfg.layers.len + @as(usize, if (cfg.current_object_layer) 1 else 0);
    if (ls.array.items.len != want) return "frame_readback layers does not hold one entry per requested binding";
    for (ls.array.items, 0..) |e, i| {
        if (e != .object) return "frame_readback layer entry is not an object";
        const named = i < cfg.layers.len;
        const b = e.object.get("binding") orelse return "frame_readback layer entry has no binding";
        if (b != .string or !std.mem.eql(u8, b.string, if (named) "name" else "current_object")) return "frame_readback layer entry binding differs from the request";
        if (named) {
            const rq = e.object.get("requested") orelse return "frame_readback named entry has no requested string";
            if (rq != .string or !std.mem.eql(u8, rq.string, cfg.layers[i])) return "frame_readback requested layer name differs from the request";
        }
        const st = e.object.get("status") orelse return "frame_readback layer entry has no status";
        if (st != .string) return "frame_readback layer entry status is not a string";
        if (std.mem.eql(u8, st.string, "bound")) {
            if (frameRecordProblem(e.object.get("layer_name"), "vs.GetLName")) |why| return why;
            if (frameRecordProblem(e.object.get("elevation"), "vs.GetLayerElevation")) |why| return why;
            if (frameRecordProblem(e.object.get("elevation_n"), "vs.GetLayerElevationN")) |why| return why;
            if (named) {
                const raw = e.object.get("layer_name").?.object.get("raw") orelse return "frame_readback bound named entry has no layer name";
                if (raw != .string or !std.mem.eql(u8, raw.string, cfg.layers[i])) return "frame_readback bound layer name differs from the requested name";
            }
        } else if (std.mem.eql(u8, st.string, "unbound")) {
            const why = e.object.get("reason") orelse return "frame_readback unbound entry has no reason";
            if (why != .string) return "frame_readback unbound reason is not a string";
        } else return "frame_readback layer entry status is not bound or unbound";
    }
    return null;
}

fn finish(a: Allocator, io: Io, cfg: Config, res: *Result) void {
    const dir = res.request_dir orelse return;
    const Rec = struct {
        schema: []const u8,
        request: []const u8,
        pid: i32,
        expected_executable: []const u8,
        observed_executable: ?[]const u8,
        outcome: []const u8,
        detail: []const u8,
        uncertain: bool,
        sender: ?SenderRecord,
        timeout_ms: u32,
        send_timeout_ms: u32,
        polls: u32,
        waited_ms: u64,
        apis_present: []const []const u8,
        apis_absent: []const []const u8,
        response: ?std.json.Value,
    };
    const rec: Rec = .{
        .schema = schema_result,
        .request = @tagName(cfg.kind),
        .pid = cfg.pid,
        .expected_executable = cfg.expected_executable,
        .observed_executable = res.observed_executable,
        .outcome = @tagName(res.outcome),
        .detail = res.detail,
        .uncertain = res.uncertain,
        .sender = res.sender,
        .timeout_ms = cfg.timeout_ms,
        .send_timeout_ms = cfg.send_timeout_ms,
        .polls = res.polls,
        .waited_ms = res.waited_ms,
        .apis_present = res.apis_present,
        .apis_absent = res.apis_absent,
        .response = res.response,
    };
    const text = jsonText(a, rec) catch return;
    const path = std.fmt.allocPrint(a, "{s}/probe-result.json", .{dir}) catch return;
    writeNew(io, path, text) catch {
        if (res.outcome == .ok) {
            res.outcome = .output_failed;
            res.detail = "probe-result.json could not be written";
        }
    };
}

const PluginPayload = struct { plugins: []const []const u8 };
const FramePayload = struct { layers: []const []const u8, current_object_layer: bool };
const ApiPayload = struct { apis: []const []const u8 };

/// The accepted bridge request envelope with a chosen payload type.
fn RequestOf(comptime P: type) type {
    return struct {
        schema: []const u8,
        bridge_revision: []const u8,
        op: []const u8,
        case_id: []const u8,
        profile_id: []const u8,
        path: []const u8,
        expect: []const u8,
        document: ?[]const u8,
        after_paths: []const []const u8,
        after_dir: ?[]const u8,
        payload: P,
        out: []const u8,
        err: []const u8,
        done: []const u8,
        active: []const u8,
    };
}

/// `request.json` text. Every request but `plugin_workspace` and `frame_readback` sends the payload it sent
/// before. `plugin_workspace` sends `{"plugins": [...]}` and `frame_readback` sends
/// `{"layers": [...], "current_object_layer": bool}` so a name never enters Python source.
fn requestText(a: Allocator, cfg: Config, names: []const []const u8, out_path: []const u8, err_path: []const u8, done_path: []const u8, active_path: []const u8) ![]u8 {
    if (cfg.kind == .plugin_workspace) {
        const r: RequestOf(PluginPayload) = .{
            .schema = rc.schema_request,
            .bridge_revision = rc.bridge_revision,
            .op = @tagName(cfg.kind),
            .case_id = "",
            .profile_id = "",
            .path = "",
            .expect = "",
            .document = cfg.document,
            .after_paths = &.{},
            .after_dir = null,
            .payload = .{ .plugins = cfg.plugins },
            .out = out_path,
            .err = err_path,
            .done = done_path,
            .active = active_path,
        };
        return jsonText(a, r);
    }
    if (cfg.kind == .frame_readback) {
        const r: RequestOf(FramePayload) = .{
            .schema = rc.schema_request,
            .bridge_revision = rc.bridge_revision,
            .op = @tagName(cfg.kind),
            .case_id = "",
            .profile_id = "",
            .path = "",
            .expect = "",
            .document = cfg.document,
            .after_paths = &.{},
            .after_dir = null,
            .payload = .{ .layers = cfg.layers, .current_object_layer = cfg.current_object_layer },
            .out = out_path,
            .err = err_path,
            .done = done_path,
            .active = active_path,
        };
        return jsonText(a, r);
    }
    const r: RequestOf(ApiPayload) = .{
        .schema = rc.schema_request,
        .bridge_revision = rc.bridge_revision,
        .op = @tagName(cfg.kind),
        .case_id = "",
        .profile_id = "",
        .path = "",
        .expect = "",
        .document = cfg.document,
        .after_paths = &.{},
        .after_dir = null,
        .payload = .{ .apis = if (cfg.kind == .preflight) names else &.{} },
        .out = out_path,
        .err = err_path,
        .done = done_path,
        .active = active_path,
    };
    return jsonText(a, r);
}

fn refused(detail: []const u8) Result {
    return .{ .outcome = .refused, .detail = detail };
}

/// Sends one read-only request and waits for its bridge marker. The result borrows from `a`.
pub fn probe(a: Allocator, io: Io, deps: Deps, cfg: Config) Result {
    if (cfg.pid <= 1) return refused("--pid must be greater than 1");
    if (cfg.expected_executable.len == 0 or cfg.expected_executable[0] != '/') return refused("--expected-executable must be an absolute path");
    if (cfg.sender.len == 0 or cfg.sender[0] != '/') return refused("--sender must be an absolute path");
    if (cfg.out_dir.len == 0 or cfg.out_dir[0] != '/') return refused("--out must be an absolute path");
    if (cfg.document) |d| {
        if (d.len == 0 or d[0] != '/') return refused("--document must be an absolute path");
    }
    if (cfg.timeout_ms == 0 or cfg.send_timeout_ms == 0) return refused("timeouts must be greater than 0");
    if (needsDocument(cfg.kind) and cfg.document == null) return refused("--document is required for state, state_ext, scalar_units, plugin_workspace and frame_readback");
    if (cfg.kind == .plugin_workspace) {
        if (pluginProblem(cfg.plugins)) |why| return refused(why);
    } else if (cfg.plugins.len > 0) return refused("--plugin is accepted only with --request plugin_workspace");
    if (cfg.kind == .frame_readback) {
        if (layerProblem(cfg.layers, cfg.current_object_layer)) |why| return refused(why);
    } else if (cfg.layers.len > 0 or cfg.current_object_layer) return refused("--layer and --current-object-layer are accepted only with --request frame_readback");

    const st = Dir.cwd().statFile(io, cfg.out_dir, .{ .follow_symlinks = false }) catch return refused("--out is not readable");
    if (st.kind != .directory) return refused("--out must be an existing directory and not a symbolic link");
    if (!isRegular(io, cfg.sender)) return refused("--sender is not a regular file");

    // Identity gate. Nothing below runs unless the pid executes the expected file.
    const observed = deps.pid_path(a, cfg.pid) orelse return .{ .outcome = .pid_not_running, .detail = "proc_pidpath returned no path for the pid" };
    if (!std.mem.eql(u8, observed, cfg.expected_executable)) {
        return .{ .outcome = .executable_mismatch, .detail = "proc_pidpath differs from --expected-executable. The sender was not started", .observed_executable = observed };
    }

    var res: Result = .{ .outcome = .refused, .observed_executable = observed };
    var n: u32 = 0;
    const dir = while (true) : (n += 1) {
        if (n > 9999) {
            res.detail = "no free request directory";
            return res;
        }
        const d = std.fmt.allocPrint(a, "{s}/probe-{d}-{d}", .{ cfg.out_dir, cfg.pid, n }) catch return oom();
        Dir.cwd().createDir(io, d, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => {
                res.detail = "cannot create the request directory";
                return res;
            },
        };
        break d;
    };
    res.request_dir = dir;

    const names = apiNames(a, cfg.extra_apis) catch return oom();
    const req_path = std.fmt.allocPrint(a, "{s}/request.json", .{dir}) catch return oom();
    const out_path = std.fmt.allocPrint(a, "{s}/out.json", .{dir}) catch return oom();
    const err_path = std.fmt.allocPrint(a, "{s}/err.txt", .{dir}) catch return oom();
    const done_path = std.fmt.allocPrint(a, "{s}/done", .{dir}) catch return oom();
    const active_path = std.fmt.allocPrint(a, "{s}/active.json", .{dir}) catch return oom();
    const eff_path = std.fmt.allocPrint(a, "{s}/request-effective.json", .{dir}) catch return oom();
    const prog_path = std.fmt.allocPrint(a, "{s}/program.py", .{dir}) catch return oom();

    const req_text = requestText(a, cfg, names, out_path, err_path, done_path, active_path) catch return oom();
    const prefix = switch (cfg.kind) {
        .preflight, .state, .state_ext, .scalar_units, .plugin_workspace, .frame_readback => std.fmt.allocPrint(a, "REQ_PATH = {s}\n", .{pyString(a, req_path) catch return oom()}) catch return oom(),
        .doc => docPrefix(a, req_path, eff_path) catch return oom(),
    };
    const body = bridgeBody(a, cfg.kind) orelse return failed(&res, "the bridge program cannot be extended with a final _main() call");
    const program = std.mem.concat(a, u8, &.{ prefix, body }) catch return oom();
    writeNew(io, req_path, req_text) catch return failed(&res, "cannot write request.json");
    writeNew(io, prog_path, program) catch return failed(&res, "cannot write program.py");
    defer finish(a, io, cfg, &res);

    const pid_text = std.fmt.allocPrint(a, "{d}", .{cfg.pid}) catch return oom();
    const sent = deps.transport.run(a, &.{ cfg.sender, pid_text, prog_path }, cfg.send_timeout_ms, .{});
    res.sender = senderRecord(a, sent);
    if (!sent.succeeded()) {
        res.outcome = .sender_failed;
        res.detail = std.fmt.allocPrint(a, "the sender ended with status {s} and exit code {d}. The bridge outcome is unknown", .{ @tagName(sent.status), sent.exit_code }) catch "the sender failed";
        res.uncertain = sent.status != .spawn_failed;
        return res;
    }

    const start = deps.env.now();
    const deadline = start + @as(u64, cfg.timeout_ms) * std.time.ns_per_ms;
    var bo = nur.Backoff.init(cfg.poll_min_ms, cfg.poll_max_ms);
    while (true) {
        res.polls += 1;
        if (markerPresent(a, io, done_path)) {
            res.waited_ms = (deps.env.now() - start) / std.time.ns_per_ms;
            return classify(a, io, cfg.kind, &res, out_path, err_path, names, cfg);
        }
        if (deps.pid_path(a, cfg.pid)) |p| {
            if (!std.mem.eql(u8, p, cfg.expected_executable)) return gone(&res, start, deps.env, "the pid runs a different executable now");
        } else return gone(&res, start, deps.env, "the process ended during the request");
        if (deps.env.now() >= deadline) break;
        deps.env.sleep(bo.next(false));
    }
    res.polls += 1;
    res.waited_ms = (deps.env.now() - start) / std.time.ns_per_ms;
    if (markerPresent(a, io, done_path)) return classify(a, io, cfg.kind, &res, out_path, err_path, names, cfg);
    res.outcome = .timeout;
    res.uncertain = true;
    res.detail = std.fmt.allocPrint(a, "no bridge done marker after {d} ms. The sender exited with status {s}. The script may still run", .{ cfg.timeout_ms, res.sender.?.status }) catch "timeout";
    return res;
}

fn oom() Result {
    return .{ .outcome = .output_failed, .detail = "out of memory" };
}

fn failed(res: *Result, detail: []const u8) Result {
    res.outcome = .output_failed;
    res.detail = detail;
    return res.*;
}

fn gone(res: *Result, start: u64, env: nur.Env, detail: []const u8) Result {
    res.waited_ms = (env.now() - start) / std.time.ns_per_ms;
    res.outcome = .process_gone;
    res.uncertain = true;
    res.detail = detail;
    return res.*;
}

/// True when `done` is a regular file with the exact bridge content.
fn markerPresent(a: Allocator, io: Io, done: []const u8) bool {
    if (!isRegular(io, done)) return false;
    const t = readFile(a, io, done, 64) catch return false;
    return std.mem.eql(u8, t, "done\n");
}

fn classify(a: Allocator, io: Io, kind: Kind, res: *Result, out_path: []const u8, err_path: []const u8, names: []const []const u8, cfg: Config) Result {
    if (fileExists(io, err_path)) {
        const t = readFile(a, io, err_path, max_error_bytes) catch "";
        res.outcome = .bridge_error;
        res.detail = ascii(a, std.mem.trim(u8, t, " \n"));
        return res.*;
    }
    const bytes = readFile(a, io, out_path, max_response_bytes) catch {
        res.outcome = .invalid_response;
        res.detail = "the done marker exists and out.json cannot be read";
        return res.*;
    };
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch {
        res.outcome = .invalid_response;
        res.detail = "out.json is not JSON";
        return res.*;
    };
    if (validResponse(kind, v, cfg)) |why| {
        res.outcome = .invalid_response;
        res.detail = why;
        return res.*;
    }
    res.outcome = .ok;
    res.response = v;
    if (kind == .preflight) {
        const apis = v.object.get("apis").?.object;
        var present: std.ArrayList([]const u8) = .empty;
        var absent: std.ArrayList([]const u8) = .empty;
        for (names) |nm| {
            const x = apis.get(nm) orelse continue;
            if (x == .bool and x.bool) present.append(a, nm) catch {} else absent.append(a, nm) catch {};
        }
        res.apis_present = present.items;
        res.apis_absent = absent.items;
    }
    return res.*;
}

// Command line

pub const usage_text =
    \\usage: vwx native-probe --pid N --expected-executable PATH --sender PATH --out DIR --operator-authorized
    \\                        [--request preflight|doc|state|state_ext|scalar_units|plugin_workspace|frame_readback] [--document PATH] [--api vs.Name]...
    \\                        [--plugin NAME]... (plugin_workspace only, 1 to 8 names of at most 128 bytes)
    \\                        [--layer NAME]... [--current-object-layer] (frame_readback only, at least one binding, at most 4 names)
    \\                        [--timeout-ms N] [--send-timeout-ms N] [--poll-max-ms N]
    \\       vwx native-probe --help
    \\
    \\Sends one read-only bridge request to a running process through `<sender> <pid> <program.py>`.
    \\The command matches proc_pidpath of the pid with --expected-executable before it starts the
    \\sender. It launches, quits, opens, saves and edits nothing. `preflight` reports API presence and
    \\needs no document. `doc` reports the active document name and path. --document names the path
    \\that the bridge must find open. `state` and `state_ext` read units, origin, class and layer
    \\visibility (and for `state_ext` selection, active layer and class, view and render mode) and
    \\require --document. The response is kept whole in out.json and probe-result.json.
    \\`scalar_units` requires --document like `state`. It reads vs.GetUnits and the raw values of
    \\vs.GetPrefReal 176 and 180 and vs.GetPrefString 178 and 182. Every record holds its API,
    \\selector and its own status, so one failing read leaves the others. It sets nothing and maps no
    \\value to a unit.
    \\`plugin_workspace` requires --document and one to eight --plugin universal names. It calls
    \\vs.HasPlugin once per name and keeps the requested string, the raw returned value, the boolean
    \\membership and the palette name. Membership shows a tool or command in the current workspace only.
    \\It does not show that vs.CreateCustomObject accepts the name. An absent name does not show that the
    \\plug-in is uninstalled. The request loads no plug-in and sets nothing.
    \\`frame_readback` requires --document and at least one binding. It reads vs.GetWorkingPlaneN and
    \\vs.GetWorkingPlane. For each --layer NAME it calls vs.GetLayerByName and keeps the layer only when
    \\vs.GetLName returns the same string. With --current-object-layer it needs exactly one selected object
    \\on the active layer, reads vs.Get3DCntr of that object and binds vs.GetLayer of it. For each bound
    \\layer it reads vs.GetLayerElevation and vs.GetLayerElevationN. Every record keeps the raw return, its
    \\shape and its status. It maps no unit and no frame. It sets no working plane, elevation or active
    \\layer and changes no geometry.
    \\DIR is an existing directory. The command creates
    \\DIR/probe-<pid>-<n>/ with request.json, program.py, the bridge out.json or err.txt, the done
    \\marker and probe-result.json. Defaults are --request preflight, --timeout-ms 60000,
    \\--send-timeout-ms 15000 and --poll-max-ms 250.
    \\Exit 0 ok, 1 refused, failed or timeout, 2 usage.
    \\
;

const Parsed = union(enum) { bad: []const u8, ok: struct { cfg: Config, authorized: bool } };

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseArgs(a: Allocator, argv: []const []const u8) Parsed {
    var pid: ?i32 = null;
    var exe: ?[]const u8 = null;
    var sender: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var cfg_kind: Kind = .preflight;
    var document: ?[]const u8 = null;
    var authorized = false;
    var timeout_ms: u32 = 60_000;
    var send_ms: u32 = 15_000;
    var poll_max: u32 = 250;
    var plugins: std.ArrayList([]const u8) = .empty;
    var layers: std.ArrayList([]const u8) = .empty;
    var current_object = false;
    var apis: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const k = argv[i];
        if (std.mem.eql(u8, k, "--operator-authorized")) {
            authorized = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--current-object-layer")) {
            current_object = true;
            continue;
        }
        if (i + 1 >= argv.len) return .{ .bad = "option needs a value" };
        const v = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, k, "--pid")) {
            pid = std.fmt.parseInt(i32, v, 10) catch return .{ .bad = "--pid is not a number" };
        } else if (std.mem.eql(u8, k, "--expected-executable")) {
            exe = v;
        } else if (std.mem.eql(u8, k, "--sender")) {
            sender = v;
        } else if (std.mem.eql(u8, k, "--out")) {
            out = v;
        } else if (std.mem.eql(u8, k, "--request")) {
            cfg_kind = std.meta.stringToEnum(Kind, v) orelse return .{ .bad = "--request is preflight, doc, state, state_ext, scalar_units, plugin_workspace or frame_readback" };
        } else if (std.mem.eql(u8, k, "--document")) {
            document = v;
        } else if (std.mem.eql(u8, k, "--api")) {
            if (!std.mem.startsWith(u8, v, "vs.")) return .{ .bad = "--api names start with vs." };
            apis.append(a, v) catch return .{ .bad = "out of memory" };
        } else if (std.mem.eql(u8, k, "--plugin")) {
            if (plugins.items.len >= max_plugins) return .{ .bad = "at most 8 --plugin candidates are accepted" };
            plugins.append(a, v) catch return .{ .bad = "out of memory" };
        } else if (std.mem.eql(u8, k, "--layer")) {
            if (layers.items.len >= max_layers) return .{ .bad = "at most 4 --layer names are accepted" };
            layers.append(a, v) catch return .{ .bad = "out of memory" };
        } else if (std.mem.eql(u8, k, "--timeout-ms")) {
            timeout_ms = parseU32(v) orelse return .{ .bad = "--timeout-ms is not a number" };
        } else if (std.mem.eql(u8, k, "--send-timeout-ms")) {
            send_ms = parseU32(v) orelse return .{ .bad = "--send-timeout-ms is not a number" };
        } else if (std.mem.eql(u8, k, "--poll-max-ms")) {
            poll_max = parseU32(v) orelse return .{ .bad = "--poll-max-ms is not a number" };
        } else return .{ .bad = "unknown option" };
    }
    if (pid == null) return .{ .bad = "--pid is required" };
    if (exe == null) return .{ .bad = "--expected-executable is required" };
    if (sender == null) return .{ .bad = "--sender is required" };
    if (out == null) return .{ .bad = "--out is required" };
    return .{ .ok = .{ .authorized = authorized, .cfg = .{
        .pid = pid.?,
        .expected_executable = exe.?,
        .sender = sender.?,
        .out_dir = out.?,
        .kind = cfg_kind,
        .document = document,
        .extra_apis = apis.items,
        .plugins = plugins.items,
        .layers = layers.items,
        .current_object_layer = current_object,
        .timeout_ms = timeout_ms,
        .send_timeout_ms = send_ms,
        .poll_max_ms = poll_max,
    } } };
}

fn writeResult(a: Allocator, out: *Io.Writer, res: Result) void {
    out.print("outcome\t{s}\n", .{@tagName(res.outcome)}) catch {};
    if (res.detail.len > 0) out.print("detail\t{s}\n", .{res.detail}) catch {};
    if (res.observed_executable) |p| out.print("observed_executable\t{s}\n", .{p}) catch {};
    if (res.request_dir) |d| out.print("request_dir\t{s}\n", .{d}) catch {};
    if (res.sender) |s| {
        out.print("sender_status\t{s}\nsender_exit_code\t{d}\n", .{ s.status, s.exit_code }) catch {};
        if (s.stderr.len > 0) out.print("sender_stderr\t{s}\n", .{std.mem.trim(u8, s.stderr, "\n")}) catch {};
    }
    out.print("polls\t{d}\nwaited_ms\t{d}\nuncertain\t{}\n", .{ res.polls, res.waited_ms, res.uncertain }) catch {};
    if (res.outcome == .ok) {
        if (res.request_dir) |d| {
            if (res.apis_present.len + res.apis_absent.len > 0) out.print("apis_present\t{d}\napis_absent\t{d}\nresponse\t{s}/out.json\n", .{ res.apis_present.len, res.apis_absent.len, d }) catch {};
            if (res.response) |v| {
                if (v == .object) {
                    if (v.object.get("document")) |x| if (x == .string) out.print("document\t{s}\n", .{x.string}) catch {};
                    if (v.object.get("path")) |x| if (x == .string) out.print("path\t{s}\n", .{x.string}) catch {};
                    if (v.object.get("units")) |x| out.print("units\t{s}\n", .{rc.stringifyLine(a, x)}) catch {};
                    if (v.object.get("origin")) |x| out.print("origin\t{s}\n", .{rc.stringifyLine(a, x)}) catch {};
                    if (v.object.get("classes")) |x| if (x == .array) out.print("classes\t{d}\n", .{x.array.items.len}) catch {};
                    if (v.object.get("layers")) |x| if (x == .array) out.print("layers\t{d}\n", .{x.array.items.len}) catch {};
                    if (v.object.get("plugins")) |ps| if (ps == .array) {
                        for (ps.array.items) |p| {
                            if (p != .object) continue;
                            const st = if (p.object.get("status")) |x| (if (x == .string) x.string else "?") else "?";
                            const member = if (p.object.get("in_workspace")) |x| (if (x == .bool) (if (x.bool) "true" else "false") else "?") else "-";
                            out.print("plugin\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ rc.stringifyLine(a, p.object.get("requested") orelse .null), st, member, rc.stringifyLine(a, p.object.get("palette") orelse .null), rc.stringifyLine(a, p.object.get("raw") orelse .null) }) catch {};
                        }
                    };
                    if (v.object.get("working_plane_n")) |x| if (x == .object) out.print("working_plane_n\t{s}\t{s}\n", .{ rc.stringifyLine(a, x.object.get("status") orelse .null), rc.stringifyLine(a, x.object.get("raw") orelse .null) }) catch {};
                    if (v.object.get("working_plane")) |x| if (x == .object) out.print("working_plane\t{s}\t{s}\n", .{ rc.stringifyLine(a, x.object.get("status") orelse .null), rc.stringifyLine(a, x.object.get("raw") orelse .null) }) catch {};
                    if (v.object.get("layers")) |ls| if (ls == .array and v.object.get("working_plane_n") != null) {
                        for (ls.array.items) |e| {
                            if (e != .object) continue;
                            const el = if (e.object.get("elevation")) |x| (if (x == .object) x.object.get("raw") orelse .null else .null) else .null;
                            const eln = if (e.object.get("elevation_n")) |x| (if (x == .object) x.object.get("raw") orelse .null else .null) else .null;
                            out.print("layer\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ rc.stringifyLine(a, e.object.get("binding") orelse .null), rc.stringifyLine(a, e.object.get("requested") orelse .null), rc.stringifyLine(a, e.object.get("status") orelse .null), rc.stringifyLine(a, el), rc.stringifyLine(a, eln) }) catch {};
                        }
                    };
                    if (v.object.get("prefs")) |ps| if (ps == .array) {
                        for (ps.array.items) |p| {
                            if (p != .object) continue;
                            const api = if (p.object.get("api")) |x| (if (x == .string) x.string else "?") else "?";
                            const st = if (p.object.get("status")) |x| (if (x == .string) x.string else "?") else "?";
                            out.print("pref\t{s}\t{s}\t{s}\t{s}\n", .{ api, rc.stringifyLine(a, p.object.get("selector") orelse .null), st, rc.stringifyLine(a, p.object.get("raw") orelse .null) }) catch {};
                        }
                    };
                }
            }
        }
    }
}

/// The `runCli` of `native-probe`. `argv` holds the arguments after the command name.
pub fn runCli(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    return runCliWith(gpa, io, argv, out, null);
}

pub fn runCliWith(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer, seams: ?Deps) u8 {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h") or std.mem.eql(u8, argv[0], "help"))) {
        out.writeAll(usage_text) catch {};
        out.flush() catch {};
        return 0;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = switch (parseArgs(a, argv)) {
        .bad => |why| {
            out.print("error\t{s}\n", .{why}) catch {};
            out.writeAll(usage_text) catch {};
            out.flush() catch {};
            return 2;
        },
        .ok => |p| p,
    };
    if (!parsed.authorized) {
        out.writeAll("outcome\trefused\ndetail\t--operator-authorized is required\n") catch {};
        out.flush() catch {};
        return 1;
    }
    var res: Result = undefined;
    if (seams) |d| {
        res = probe(a, io, d, parsed.cfg);
    } else {
        nur.installSignalHandlers();
        var pt: nur.ProcessTransport = .{ .io = io };
        var se: nur.SystemEnv = .{ .io = io };
        res = probe(a, io, .{ .transport = pt.transport(), .env = se.env(), .pid_path = systemPidPath }, parsed.cfg);
    }
    writeResult(a, out, res);
    out.flush() catch {};
    return if (res.outcome == .ok) 0 else 1;
}

// Tests. A fake sender, clock and process path stand in for the application.

const testing = std.testing;
const Scratch = opdir.Scratch;

const FakeEnv = struct {
    t: u64 = 0,
    sleeps: u32 = 0,

    fn env(f: *FakeEnv) nur.Env {
        return .{ .ptr = f, .nowFn = nowImpl, .sleepFn = sleepImpl };
    }
    fn nowImpl(ptr: *anyopaque) u64 {
        const f: *FakeEnv = @ptrCast(@alignCast(ptr));
        return f.t;
    }
    fn sleepImpl(ptr: *anyopaque, ms: u32) void {
        const f: *FakeEnv = @ptrCast(@alignCast(ptr));
        f.sleeps += 1;
        f.t += @as(u64, ms) * std.time.ns_per_ms;
    }
};

const Reply = enum { ok_preflight, ok_doc, ok_state, ok_state_ext, bad_state, bridge_error, nothing, bad_marker, bad_json, sender_exit_1, sender_timeout, ok_scalar, scalar_partial, scalar_huge, scalar_nan, scalar_missing, scalar_nostatus, plugin_ok, plugin_escape, plugin_gap, plugin_wrong_names, frame_ok, frame_unbound, frame_wrong_name };

/// Response of a fake application for `plugin_workspace`. It reads the requested names from
/// request.json. Door and Window are members of "Building Shell", Lighting Device is a member of
/// "Lighting" and every other name is absent with an empty palette. `reversed` swaps the order.
fn pluginJson(a: Allocator, dir: []const u8, reversed: bool) []const u8 {
    const rq = Dir.cwd().readFileAlloc(testing.io, std.fmt.allocPrint(a, "{s}/request.json", .{dir}) catch return "", a, .limited(1 << 20)) catch return "";
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{}) catch return "";
    const items = v.object.get("payload").?.object.get("plugins").?.array.items;
    var aw: Io.Writer.Allocating = .init(a);
    aw.writer.writeAll("{\"schema\":\"vwx-native-plugin-workspace/1\",\"read_only\":true,\"plugins\":[") catch return "";
    for (0..items.len) |k| {
        const name = items[if (reversed) items.len - 1 - k else k].string;
        const palette: []const u8 = if (std.mem.eql(u8, name, "Door") or std.mem.eql(u8, name, "Window")) "Building Shell" else if (std.mem.eql(u8, name, "Lighting Device")) "Lighting" else "";
        const member = palette.len > 0;
        if (k > 0) aw.writer.writeByte(',') catch return "";
        aw.writer.writeAll("{\"api\":\"vs.HasPlugin\",\"requested\":") catch return "";
        std.json.Stringify.value(name, .{}, &aw.writer) catch return "";
        aw.writer.print(",\"status\":\"observed\",\"python_type\":\"tuple\",\"raw\":[{},", .{member}) catch return "";
        std.json.Stringify.value(palette, .{}, &aw.writer) catch return "";
        aw.writer.print("],\"in_workspace\":{},\"palette\":", .{member}) catch return "";
        std.json.Stringify.value(palette, .{}, &aw.writer) catch return "";
        aw.writer.writeByte('}') catch return "";
    }
    aw.writer.writeAll("]}") catch return "";
    return aw.written();
}

const FakeSender = struct {
    reply: Reply,
    calls: u32 = 0,
    last_program: []const u8 = "",
    last_argv_len: usize = 0,

    fn transport(f: *FakeSender) nur.Transport {
        return .{ .ptr = f, .runFn = runImpl };
    }

    fn put(path: []const u8, bytes: []const u8) void {
        const fh = Dir.cwd().createFile(testing.io, path, .{ .exclusive = true }) catch return;
        defer fh.close(testing.io);
        fh.writeStreamingAll(testing.io, bytes) catch {};
    }

    fn runImpl(ptr: *anyopaque, a: Allocator, argv: []const []const u8, _: u32, _: nur.StreamLimits) nur.RunOutput {
        const f: *FakeSender = @ptrCast(@alignCast(ptr));
        f.calls += 1;
        f.last_argv_len = argv.len;
        const dir = std.fs.path.dirname(argv[2]).?;
        if (f.last_program.len > 0) testing.allocator.free(f.last_program);
        f.last_program = Dir.cwd().readFileAlloc(testing.io, argv[2], testing.allocator, .limited(1 << 22)) catch "";
        const out_p = std.fmt.allocPrint(a, "{s}/out.json", .{dir}) catch return .{ .status = .read_failed };
        const err_p = std.fmt.allocPrint(a, "{s}/err.txt", .{dir}) catch return .{ .status = .read_failed };
        const done_p = std.fmt.allocPrint(a, "{s}/done", .{dir}) catch return .{ .status = .read_failed };
        switch (f.reply) {
            .ok_preflight => {
                put(out_p, "{\"schema\":\"vwx-rosetta-capabilities/1\",\"driver\":\"native\",\"apis\":{\"vs.GetFName\":true,\"vs.GetFPathName\":true,\"vs.ExportSAT\":false},\"can_close\":true,\"raw_version\":null}");
                put(done_p, "done\n");
            },
            .ok_doc => {
                put(out_p, "{\"document\":\"seed.vwx\",\"path\":\"/tmp/seed.vwx\"}");
                put(done_p, "done\n");
            },
            .ok_state, .ok_state_ext => {
                put(out_p, if (f.reply == .ok_state) state_json else state_ext_json);
                put(done_p, "done\n");
            },
            .ok_scalar, .scalar_partial, .scalar_huge, .scalar_nan, .scalar_missing, .scalar_nostatus => {
                put(out_p, switch (f.reply) {
                    .ok_scalar => scalar_json,
                    .scalar_partial => scalar_partial_json,
                    .scalar_huge => scalar_huge_json,
                    .scalar_nan => scalar_nan_json,
                    .scalar_missing => scalar_missing_json,
                    else => scalar_nostatus_json,
                });
                put(done_p, "done\n");
            },
            .plugin_ok, .plugin_escape, .plugin_wrong_names => {
                put(out_p, pluginJson(a, dir, f.reply == .plugin_wrong_names));
                put(done_p, "done\n");
            },
            .frame_ok, .frame_unbound, .frame_wrong_name => {
                put(out_p, frameJson(a, dir, switch (f.reply) {
                    .frame_unbound => .unbound,
                    .frame_wrong_name => .wrong_name,
                    else => .ok,
                }));
                put(done_p, "done\n");
            },
            .plugin_gap => {
                put(out_p, "{\"schema\":\"vwx-native-plugin-workspace/1\",\"read_only\":true,\"plugins\":[{\"api\":\"vs.HasPlugin\",\"requested\":\"Door\",\"status\":\"gap\",\"reason\":\"api_absent\"}]}");
                put(done_p, "done\n");
            },
            .bad_state => {
                put(out_p, "{\"schema\":\"other/1\"}");
                put(done_p, "done\n");
            },
            .bridge_error => {
                put(err_p, "Traceback\nRuntimeError: vs.GetFPathName returns ''. Only a saved session copy is accepted\n");
                put(done_p, "done\n");
            },
            .bad_marker => {
                put(out_p, "{}");
                put(done_p, "do");
            },
            .bad_json => {
                put(out_p, "not json");
                put(done_p, "done\n");
            },
            .nothing, .sender_exit_1, .sender_timeout => {},
        }
        return switch (f.reply) {
            .sender_exit_1 => .{ .status = .exited, .exit_code = 1, .stderr = a.dupe(u8, "send failed -600") catch &.{} },
            .sender_timeout => .{ .status = .timed_out },
            else => .{ .status = .exited, .exit_code = 0 },
        };
    }
};

const state_json = "{\"schema\":\"vwx-rosetta-native-state/1\",\"classes\":[{\"name\":\"None\",\"visible\":true,\"raw_visibility\":0}],\"layers\":[{\"name\":\"Design Layer-1\",\"visible\":true,\"raw_visibility\":0}],\"units\":{\"units_per_inch\":25.4,\"raw\":[1,2,3,25.4]},\"origin\":[0.0,0.0]}";
const state_ext_json = "{\"schema\":\"vwx-rosetta-native-state/1\",\"classes\":[],\"layers\":[],\"units\":{\"units_per_inch\":25.4,\"raw\":[]},\"origin\":[0.0,0.0],\"ext\":{\"selection_count\":{\"status\":\"observed\",\"value\":0}}}";
// Fixture responses of `scalar_units`. The values are placeholders of the shape and not measurements.
const sx_units = "{\"api\":\"vs.GetUnits\",\"selector\":null,\"status\":\"observed\",\"python_type\":\"tuple\",\"raw\":[1,0,0,25.4,\"mm\",\" sq m\"]}";
const sx_open = "{\"schema\":\"vwx-native-scalar-units/1\",\"read_only\":true,\"units\":" ++ sx_units ++ ",\"prefs\":[";
const sx_r176 = "{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"status\":\"observed\",\"python_type\":\"float\",\"raw\":1.5}";
const sx_r180 = "{\"api\":\"vs.GetPrefReal\",\"selector\":180,\"status\":\"observed\",\"python_type\":\"float\",\"raw\":2.5}";
const sx_r178 = "{\"api\":\"vs.GetPrefString\",\"selector\":178,\"status\":\"observed\",\"python_type\":\"str\",\"raw\":\"fx-area\"}";
const sx_r182 = "{\"api\":\"vs.GetPrefString\",\"selector\":182,\"status\":\"observed\",\"python_type\":\"str\",\"raw\":\"fx-vol\"}";
const scalar_json = sx_open ++ sx_r176 ++ "," ++ sx_r180 ++ "," ++ sx_r178 ++ "," ++ sx_r182 ++ "]}";
const scalar_partial_json = sx_open ++
    "{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"status\":\"error\",\"reason\":\"RuntimeError: boom\"}," ++ sx_r180 ++ "," ++
    "{\"api\":\"vs.GetPrefString\",\"selector\":178,\"status\":\"gap\",\"reason\":\"api_absent\"}," ++ sx_r182 ++ "]}";
const scalar_huge_json = sx_open ++
    "{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"status\":\"observed\",\"python_type\":\"float\",\"raw\":1e999}," ++ sx_r180 ++ "," ++ sx_r178 ++ "," ++ sx_r182 ++ "]}";
const scalar_nan_json = sx_open ++
    "{\"api\":\"vs.GetPrefReal\",\"selector\":176,\"status\":\"observed\",\"python_type\":\"float\",\"raw\":NaN}," ++ sx_r180 ++ "," ++ sx_r178 ++ "," ++ sx_r182 ++ "]}";
const scalar_missing_json = sx_open ++ sx_r176 ++ "," ++ sx_r180 ++ "," ++ sx_r178 ++ "]}";
const scalar_nostatus_json = sx_open ++ sx_r176 ++ "," ++ sx_r180 ++ "," ++ sx_r178 ++ ",{\"api\":\"vs.GetPrefString\",\"selector\":182}]}";

const seed_doc = "/tmp/working-blank-metric.vwx";

const exe_path = "/Applications/Vectorworks 2027/Vectorworks 2027.app/Contents/MacOS/Vectorworks";

fn fakePidPathOk(a: Allocator, pid: i32) ?[]const u8 {
    if (pid != 10012) return null;
    return a.dupe(u8, exe_path) catch null;
}

fn fakePidPathOther(a: Allocator, _: i32) ?[]const u8 {
    return a.dupe(u8, "/Applications/Other.app/Contents/MacOS/Other") catch null;
}

fn fakePidPathNone(_: Allocator, _: i32) ?[]const u8 {
    return null;
}

const Fx = struct {
    scratch: Scratch,
    sender_path: []u8,
    env: FakeEnv = .{},
    snd: FakeSender,

    fn init(reply: Reply) !Fx {
        var s = try Scratch.init();
        errdefer s.deinit();
        const sp = try s.join("sender");
        errdefer testing.allocator.free(sp);
        try writeNew(testing.io, sp, "#!/bin/sh\n");
        return .{ .scratch = s, .sender_path = sp, .snd = .{ .reply = reply } };
    }

    fn deinit(f: *Fx) void {
        testing.allocator.free(f.sender_path);
        if (f.snd.last_program.len > 0) testing.allocator.free(f.snd.last_program);
        f.scratch.deinit();
    }

    fn deps(f: *Fx, pp: PidPathFn) Deps {
        return .{ .transport = f.snd.transport(), .env = f.env.env(), .pid_path = pp };
    }

    fn cfg(f: *Fx, kind: Kind) Config {
        return .{ .pid = 10012, .expected_executable = exe_path, .sender = f.sender_path, .out_dir = f.scratch.path, .kind = kind, .timeout_ms = 2000 };
    }
};

fn expectFile(dir: []const u8, name: []const u8) !void {
    const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(p);
    _ = try Dir.cwd().statFile(testing.io, p, .{ .follow_symlinks = false });
}

test "a different executable at the pid is refused before the sender runs" {
    var fx = try Fx.init(.ok_preflight);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOther), fx.cfg(.preflight));
    try testing.expectEqual(Outcome.executable_mismatch, r.outcome);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
    try testing.expect(r.request_dir == null);
    // A path that differs only by a trailing character is also refused.
    var c = fx.cfg(.preflight);
    c.expected_executable = exe_path ++ "/";
    const r2 = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.executable_mismatch, r2.outcome);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
}

test "a pid that does not run is refused before the sender runs" {
    var fx = try Fx.init(.ok_preflight);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = probe(arena.allocator(), testing.io, fx.deps(fakePidPathNone), fx.cfg(.preflight));
    try testing.expectEqual(Outcome.pid_not_running, r.outcome);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
}

test "preflight runs with no document and keeps the request files and the real marker" {
    var fx = try Fx.init(.ok_preflight);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), fx.cfg(.preflight));
    try testing.expectEqual(Outcome.ok, r.outcome);
    try testing.expectEqual(@as(u32, 1), fx.snd.calls);
    try testing.expectEqual(@as(usize, 3), fx.snd.last_argv_len);
    const dir = r.request_dir.?;
    for ([_][]const u8{ "request.json", "program.py", "out.json", "done", "probe-result.json" }) |n| try expectFile(dir, n);
    // The program is the one-line prefix followed by the accepted bridge byte for byte.
    const prog = fx.snd.last_program;
    try testing.expect(std.mem.startsWith(u8, prog, "REQ_PATH = \""));
    const nl = std.mem.indexOfScalar(u8, prog, '\n').?;
    try testing.expectEqualStrings(rc.bridge_py, prog[nl + 1 ..]);
    // The preflight request carries the bridge and entry API names and names no document.
    const rq = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/request.json", .{dir}), a, .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{});
    try testing.expectEqualStrings("preflight", v.object.get("op").?.string);
    try testing.expect(v.object.get("document").? == .null);
    var seen_save = false;
    var seen_export = false;
    for (v.object.get("payload").?.object.get("apis").?.array.items) |x| {
        if (std.mem.eql(u8, x.string, "vs.SaveActiveDocument")) seen_save = true;
        if (std.mem.eql(u8, x.string, "vs.ExportSAT")) seen_export = true;
    }
    try testing.expect(seen_save and seen_export);
    try testing.expect(r.apis_present.len == 2 and r.apis_absent.len == 1);
    try testing.expectEqualStrings("exited", r.sender.?.status);
}

test "doc reports through the effective request and keeps the original request" {
    var fx = try Fx.init(.ok_doc);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), fx.cfg(.doc));
    try testing.expectEqual(Outcome.ok, r.outcome);
    const prog = fx.snd.last_program;
    try testing.expect(std.mem.indexOf(u8, prog, "vs.GetFPathName()") != null);
    try testing.expect(std.mem.endsWith(u8, prog, rc.bridge_py));
    try testing.expectEqualStrings("seed.vwx", r.response.?.object.get("document").?.string);
    const rq = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/request.json", .{r.request_dir.?}), a, .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{});
    try testing.expectEqualStrings("doc", v.object.get("op").?.string);
    try testing.expect(v.object.get("document").? == .null);
}

test "a bridge error response keeps err.txt and the marker" {
    var fx = try Fx.init(.bridge_error);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), fx.cfg(.doc));
    try testing.expectEqual(Outcome.bridge_error, r.outcome);
    try testing.expect(std.mem.indexOf(u8, r.detail, "Only a saved session copy is accepted") != null);
    try expectFile(r.request_dir.?, "err.txt");
    try expectFile(r.request_dir.?, "done");
    try expectFile(r.request_dir.?, "probe-result.json");
}

test "a timeout is separate from the raw sender status and the files stay" {
    var fx = try Fx.init(.nothing);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), fx.cfg(.preflight));
    try testing.expectEqual(Outcome.timeout, r.outcome);
    try testing.expect(r.uncertain);
    try testing.expectEqualStrings("exited", r.sender.?.status);
    try testing.expectEqual(@as(u8, 0), r.sender.?.exit_code);
    try testing.expect(r.waited_ms >= 2000);
    try testing.expect(r.polls > 3);
    try expectFile(r.request_dir.?, "request.json");
    try expectFile(r.request_dir.?, "program.py");
    try expectFile(r.request_dir.?, "probe-result.json");
}

test "a marker with partial content and a response that is not JSON do not complete the request" {
    var fx = try Fx.init(.bad_marker);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), fx.cfg(.preflight));
    try testing.expectEqual(Outcome.timeout, r.outcome);
    var fx2 = try Fx.init(.bad_json);
    defer fx2.deinit();
    const r2 = probe(arena.allocator(), testing.io, fx2.deps(fakePidPathOk), fx2.cfg(.preflight));
    try testing.expectEqual(Outcome.invalid_response, r2.outcome);
}

test "a failed sender reports its raw status and never waits" {
    var fx = try Fx.init(.sender_exit_1);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), fx.cfg(.preflight));
    try testing.expectEqual(Outcome.sender_failed, r.outcome);
    try testing.expectEqual(@as(u8, 1), r.sender.?.exit_code);
    try testing.expectEqual(@as(u32, 0), r.polls);
    var fx2 = try Fx.init(.sender_timeout);
    defer fx2.deinit();
    const r2 = probe(arena.allocator(), testing.io, fx2.deps(fakePidPathOk), fx2.cfg(.preflight));
    try testing.expectEqual(Outcome.sender_failed, r2.outcome);
    try testing.expectEqualStrings("timed_out", r2.sender.?.status);
}

test "request directories are unique across probes" {
    var fx = try Fx.init(.ok_preflight);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r1 = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), fx.cfg(.preflight));
    const r2 = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), fx.cfg(.preflight));
    try testing.expect(!std.mem.eql(u8, r1.request_dir.?, r2.request_dir.?));
    try testing.expectEqual(Outcome.ok, r2.outcome);
}

test "the command line requires every named option and the authorization flag" {
    var fx = try Fx.init(.ok_preflight);
    defer fx.deinit();
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 2), runCliWith(testing.allocator, testing.io, &.{ "--pid", "10012" }, &w, fx.deps(fakePidPathOk)));
    var w2: Io.Writer = .fixed(&buf);
    const base = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", fx.sender_path, "--out", fx.scratch.path };
    try testing.expectEqual(@as(u8, 1), runCliWith(testing.allocator, testing.io, &base, &w2, fx.deps(fakePidPathOk)));
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "--operator-authorized is required") != null);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
    var w3: Io.Writer = .fixed(&buf);
    const full = base ++ [_][]const u8{ "--operator-authorized", "--timeout-ms", "1000" };
    try testing.expectEqual(@as(u8, 0), runCliWith(testing.allocator, testing.io, &full, &w3, fx.deps(fakePidPathOk)));
    try testing.expect(std.mem.indexOf(u8, w3.buffered(), "outcome\tok") != null);
    var w4: Io.Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), runCliWith(testing.allocator, testing.io, &.{"--help"}, &w4, fx.deps(fakePidPathOk)));
}

test "the production process path is null for a pid that does not run" {
    try testing.expect(systemPidPath(testing.allocator, 2147483000) == null);
}

test "state needs an explicit document and is refused before the sender runs" {
    var fx = try Fx.init(.ok_state);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]Kind{ .state, .state_ext }) |k| {
        const r = probe(arena.allocator(), testing.io, fx.deps(fakePidPathOk), fx.cfg(k));
        try testing.expectEqual(Outcome.refused, r.outcome);
        try testing.expect(std.mem.indexOf(u8, r.detail, "--document is required") != null);
        try testing.expect(r.request_dir == null);
    }
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const argv = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", fx.sender_path, "--out", fx.scratch.path, "--request", "state", "--operator-authorized" };
    try testing.expectEqual(@as(u8, 1), runCliWith(testing.allocator, testing.io, &argv, &w, fx.deps(fakePidPathOk)));
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
}

test "state sends the exact document with the accepted bridge and keeps the whole response" {
    var fx = try Fx.init(.ok_state);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = fx.cfg(.state);
    c.document = seed_doc;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const prog = fx.snd.last_program;
    const nl = std.mem.indexOfScalar(u8, prog, '\n').?;
    try testing.expectEqualStrings(rc.bridge_py, prog[nl + 1 ..]);
    const rq = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/request.json", .{r.request_dir.?}), a, .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{});
    try testing.expectEqualStrings("state", v.object.get("op").?.string);
    try testing.expectEqualStrings(seed_doc, v.object.get("document").?.string);
    try testing.expectEqualStrings(rc.schema_state, r.response.?.object.get("schema").?.string);
    try testing.expectEqual(@as(usize, 1), r.response.?.object.get("layers").?.array.items.len);
    const saved = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/probe-result.json", .{r.request_dir.?}), a, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, saved, "Design Layer-1") != null and std.mem.indexOf(u8, saved, "25.4") != null);
}

test "state_ext sends the accepted extension and requires its ext block" {
    var fx = try Fx.init(.ok_state_ext);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = fx.cfg(.state_ext);
    c.document = seed_doc;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const prog = fx.snd.last_program;
    const nl = std.mem.indexOfScalar(u8, prog, '\n').?;
    try testing.expectEqualStrings(rc.bridgeProgram(a, "state_ext"), prog[nl + 1 ..]);
    try testing.expect(std.mem.indexOf(u8, prog, "OPS['state_ext'] = op_state_ext") != null);
    try testing.expect(r.response.?.object.get("ext") != null);
    // A plain state response does not satisfy state_ext.
    var fx2 = try Fx.init(.ok_state);
    defer fx2.deinit();
    var c2 = fx2.cfg(.state_ext);
    c2.document = seed_doc;
    const r2 = probe(a, testing.io, fx2.deps(fakePidPathOk), c2);
    try testing.expectEqual(Outcome.invalid_response, r2.outcome);
    // A response with another schema is invalid for state.
    var fx3 = try Fx.init(.bad_state);
    defer fx3.deinit();
    var c3 = fx3.cfg(.state);
    c3.document = seed_doc;
    try testing.expectEqual(Outcome.invalid_response, probe(a, testing.io, fx3.deps(fakePidPathOk), c3).outcome);
}

test "scalar_units needs the exact document and the expected executable before the sender runs" {
    var fx = try Fx.init(.ok_scalar);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), fx.cfg(.scalar_units));
    try testing.expectEqual(Outcome.refused, r.outcome);
    try testing.expect(std.mem.indexOf(u8, r.detail, "--document is required") != null);
    try testing.expect(r.request_dir == null);
    var c = fx.cfg(.scalar_units);
    c.document = "relative.vwx";
    try testing.expectEqual(Outcome.refused, probe(a, testing.io, fx.deps(fakePidPathOk), c).outcome);
    // The executable guard holds for the new request.
    c.document = seed_doc;
    const r3 = probe(a, testing.io, fx.deps(fakePidPathOther), c);
    try testing.expectEqual(Outcome.executable_mismatch, r3.outcome);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
    // The command line refuses it without --document and does not start the sender.
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const argv = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", fx.sender_path, "--out", fx.scratch.path, "--request", "scalar_units", "--operator-authorized" };
    try testing.expectEqual(@as(u8, 1), runCliWith(testing.allocator, testing.io, &argv, &w, fx.deps(fakePidPathOk)));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "--document is required") != null);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
}

test "the request option parses scalar_units and keeps the older requests and the default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", "/s", "--out", "/o", "--operator-authorized" };
    switch (parseArgs(a, &base)) {
        .ok => |p| try testing.expectEqual(Kind.preflight, p.cfg.kind),
        .bad => return error.TestUnexpectedResult,
    }
    for ([_][]const u8{ "preflight", "doc", "state", "state_ext", "scalar_units" }) |name| {
        switch (parseArgs(a, &(base ++ [_][]const u8{ "--request", name }))) {
            .ok => |p| try testing.expectEqualStrings(name, @tagName(p.cfg.kind)),
            .bad => return error.TestUnexpectedResult,
        }
    }
    switch (parseArgs(a, &(base ++ [_][]const u8{ "--request", "scalar_unit" }))) {
        .ok => return error.TestUnexpectedResult,
        .bad => |why| try testing.expect(std.mem.indexOf(u8, why, "scalar_units") != null),
    }
    try testing.expect(std.mem.indexOf(u8, usage_text, "preflight|doc|state|state_ext|scalar_units") != null);
}

test "scalar_units sends getters only, the exact document and the accepted bridge guards" {
    var fx = try Fx.init(.ok_scalar);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = fx.cfg(.scalar_units);
    c.document = seed_doc;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const rq = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/request.json", .{r.request_dir.?}), a, .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{});
    try testing.expectEqualStrings("scalar_units", v.object.get("op").?.string);
    try testing.expectEqualStrings(seed_doc, v.object.get("document").?.string);
    const prog = fx.snd.last_program;
    try testing.expect(std.mem.startsWith(u8, prog, "REQ_PATH = \""));
    const nl = std.mem.indexOfScalar(u8, prog, '\n').?;
    const body = prog[nl + 1 ..];
    try testing.expectEqualStrings(bridgeBody(a, .scalar_units).?, body);
    // The accepted bridge comes first byte for byte and its final call stays the last line.
    const head = rc.bridge_py[0 .. rc.bridge_py.len - bridge_tail.len + 1];
    try testing.expect(std.mem.startsWith(u8, body, head));
    try testing.expect(std.mem.endsWith(u8, body, "\n_main()\n"));
    try testing.expect(std.mem.indexOf(u8, body, "OPS['scalar_units'] = op_scalar_units") != null);
    // The existing document guard is part of the program and applies to every operation but preflight.
    try testing.expect(std.mem.indexOf(u8, body, "if op != 'preflight':") != null);
    try testing.expect(std.mem.indexOf(u8, body, "_active([want], None)") != null);
    // The extension calls getters only. Each `vs.` name in it starts with Get.
    const ext = try scalarUnitsExt(a);
    var i: usize = 0;
    var names: usize = 0;
    while (std.mem.indexOfPos(u8, ext, i, "vs.")) |p| {
        i = p + 3;
        if (p > 0 and std.ascii.isAlphanumeric(ext[p - 1])) continue;
        var e = i;
        while (e < ext.len and (std.ascii.isAlphanumeric(ext[e]) or ext[e] == '_')) e += 1;
        if (e == i) continue;
        names += 1;
        try testing.expect(std.mem.startsWith(u8, ext[i..e], "Get"));
    }
    try testing.expect(names >= 5);
    for ([_][]const u8{ "Set", "Save", "Close", "Open", "Export", "Begin", "Delete", "DoMenu", "open(", "write", "exec", "eval" }) |bad| {
        try testing.expect(std.mem.indexOf(u8, ext, bad) == null);
    }
    for (scalar_prefs) |p| try testing.expect(std.mem.startsWith(u8, p.api, "vs.GetPref"));
    // The preference list in the program is the table. Nonfinite numbers are annotated.
    try testing.expect(std.mem.indexOf(u8, ext, "(\"vs.GetPrefReal\", 176, \"number\"), (\"vs.GetPrefReal\", 180, \"number\"), (\"vs.GetPrefString\", 178, \"string\"), (\"vs.GetPrefString\", 182, \"string\")]") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "math.isfinite") != null and std.mem.indexOf(u8, ext, "'nonfinite'") != null);
    try testing.expect(std.mem.indexOf(u8, ext, schema_scalar_units) != null);
    try testing.expect(std.mem.indexOf(u8, ext, "'vs.GetUnits', [], 'sequence'") != null);
}

test "older requests keep sending the program they sent before" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(rc.bridge_py, bridgeBody(a, .preflight).?);
    try testing.expectEqualStrings(rc.bridge_py, bridgeBody(a, .doc).?);
    try testing.expectEqualStrings(rc.bridge_py, bridgeBody(a, .state).?);
    try testing.expectEqualStrings(rc.bridgeProgram(a, "state_ext"), bridgeBody(a, .state_ext).?);
    try testing.expect(std.mem.indexOf(u8, rc.bridge_py, "op_scalar_units") == null);
    try testing.expect(needsDocument(.state) and needsDocument(.state_ext) and needsDocument(.scalar_units));
    try testing.expect(!needsDocument(.preflight) and !needsDocument(.doc));
}

test "scalar_units keeps every record and one failed read leaves the others" {
    var fx = try Fx.init(.scalar_partial);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = fx.cfg(.scalar_units);
    c.document = seed_doc;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const ps = r.response.?.object.get("prefs").?.array.items;
    try testing.expectEqual(@as(usize, 4), ps.len);
    try testing.expectEqualStrings("error", ps[0].object.get("status").?.string);
    try testing.expectEqualStrings("observed", ps[1].object.get("status").?.string);
    try testing.expectEqualStrings("gap", ps[2].object.get("status").?.string);
    try testing.expectEqualStrings("observed", ps[3].object.get("status").?.string);
    try testing.expectEqualStrings("observed", r.response.?.object.get("units").?.object.get("status").?.string);
    const saved = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/probe-result.json", .{r.request_dir.?}), a, .limited(1 << 20));
    for ([_][]const u8{ "RuntimeError: boom", "api_absent", "fx-vol", "\"selector\": 176", "\"selector\": 182" }) |s| try testing.expect(std.mem.indexOf(u8, saved, s) != null);
    // The command line prints one line per record.
    var fx2 = try Fx.init(.scalar_partial);
    defer fx2.deinit();
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const argv = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", fx2.sender_path, "--out", fx2.scratch.path, "--request", "scalar_units", "--document", seed_doc, "--operator-authorized", "--timeout-ms", "1000" };
    try testing.expectEqual(@as(u8, 0), runCliWith(testing.allocator, testing.io, &argv, &w, fx2.deps(fakePidPathOk)));
    const o = w.buffered();
    try testing.expect(std.mem.indexOf(u8, o, "pref\tvs.GetPrefReal\t176\terror\tnull\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "pref\tvs.GetPrefReal\t180\tobserved\t2.5\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "pref\tvs.GetPrefString\t178\tgap\tnull\n") != null);
}

test "scalar_units refuses a malformed response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Reply{ .scalar_missing, .scalar_nostatus }) |reply| {
        var fx = try Fx.init(reply);
        defer fx.deinit();
        var c = fx.cfg(.scalar_units);
        c.document = seed_doc;
        const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
        try testing.expectEqual(Outcome.invalid_response, r.outcome);
        try expectFile(r.request_dir.?, "probe-result.json");
    }
    // A plain state response does not satisfy scalar_units.
    var fx2 = try Fx.init(.ok_state);
    defer fx2.deinit();
    var c2 = fx2.cfg(.scalar_units);
    c2.document = seed_doc;
    try testing.expectEqual(Outcome.invalid_response, probe(a, testing.io, fx2.deps(fakePidPathOk), c2).outcome);
}

test "scalar_units rejects a nonfinite number and the Python side annotates it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fx.init(.scalar_huge);
    defer fx.deinit();
    var c = fx.cfg(.scalar_units);
    c.document = seed_doc;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.invalid_response, r.outcome);
    try testing.expect(std.mem.indexOf(u8, r.detail, "nonfinite") != null);
    var fx2 = try Fx.init(.scalar_nan);
    defer fx2.deinit();
    var c2 = fx2.cfg(.scalar_units);
    c2.document = seed_doc;
    try testing.expectEqual(Outcome.invalid_response, probe(a, testing.io, fx2.deps(fakePidPathOk), c2).outcome);
    const inf = std.math.inf(f64);
    var arr: std.json.Array = .init(a);
    try arr.append(.{ .float = 1.0 });
    try testing.expect(!hasNonfinite(.{ .array = arr }));
    try arr.append(.{ .float = inf });
    try testing.expect(hasNonfinite(.{ .array = arr }));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "k", .{ .array = arr });
    try testing.expect(hasNonfinite(.{ .object = obj }));
    try testing.expect(!hasNonfinite(.{ .float = 2.5 }) and !hasNonfinite(.null));
    try testing.expect(hasNonfinite(.{ .number_string = "1e999" }) and hasNonfinite(.{ .number_string = "-1e999" }));
    try testing.expect(!hasNonfinite(.{ .number_string = "123456789012345678901234567890" }));
}

// Plugin workspace probe tests

const pw_names = [_][]const u8{ "Door", "Window", "Lighting Device", "Plant" };

test "plugin_workspace refuses missing, too many, empty, long and malformed candidates before the sender runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(pluginProblem(&.{}) != null);
    try testing.expect(pluginProblem(&pw_names) == null);
    const nine = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    try testing.expect(pluginProblem(nine[0..8]) == null);
    try testing.expect(pluginProblem(&nine) != null);
    try testing.expect(pluginProblem(&.{""}) != null);
    const at_cap = try a.alloc(u8, max_plugin_bytes);
    @memset(at_cap, 'x');
    try testing.expect(pluginProblem(&.{at_cap}) == null);
    const over = try a.alloc(u8, max_plugin_bytes + 1);
    @memset(over, 'x');
    try testing.expect(pluginProblem(&.{over}) != null);
    try testing.expect(pluginProblem(&.{"a\nb"}) != null);
    try testing.expect(pluginProblem(&.{"a\x00b"}) != null);
    try testing.expect(pluginProblem(&.{"a\x7fb"}) != null);
    try testing.expect(pluginProblem(&.{"a\xffb"}) != null);

    var fx = try Fx.init(.plugin_ok);
    defer fx.deinit();
    var c = fx.cfg(.plugin_workspace);
    c.document = seed_doc;
    var r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.refused, r.outcome);
    try testing.expect(std.mem.indexOf(u8, r.detail, "at least one --plugin") != null);
    c.plugins = &nine;
    r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.refused, r.outcome);
    // --plugin without the plugin_workspace request and plugin_workspace without a document are refused.
    var c2 = fx.cfg(.state);
    c2.document = seed_doc;
    c2.plugins = &pw_names;
    r = probe(a, testing.io, fx.deps(fakePidPathOk), c2);
    try testing.expectEqual(Outcome.refused, r.outcome);
    var c3 = fx.cfg(.plugin_workspace);
    c3.plugins = &pw_names;
    r = probe(a, testing.io, fx.deps(fakePidPathOk), c3);
    try testing.expectEqual(Outcome.refused, r.outcome);
    try testing.expect(std.mem.indexOf(u8, r.detail, "--document is required") != null);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);

    // The command line stops a ninth --plugin and keeps the order of the others.
    const base = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", "/s", "--out", "/o", "--operator-authorized", "--request", "plugin_workspace" };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &base);
    for (nine[0..8]) |n| try argv.appendSlice(a, &.{ "--plugin", n });
    switch (parseArgs(a, argv.items)) {
        .ok => |p| {
            try testing.expectEqual(@as(usize, 8), p.cfg.plugins.len);
            try testing.expectEqualStrings("a", p.cfg.plugins[0]);
            try testing.expectEqualStrings("h", p.cfg.plugins[7]);
        },
        .bad => return error.TestUnexpectedResult,
    }
    try argv.appendSlice(a, &.{ "--plugin", "i" });
    switch (parseArgs(a, argv.items)) {
        .ok => return error.TestUnexpectedResult,
        .bad => |why| try testing.expect(std.mem.indexOf(u8, why, "at most 8") != null),
    }
}

test "plugin_workspace carries each candidate in request.json and never in the Python source" {
    var fx = try Fx.init(.plugin_escape);
    defer fx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const odd = [_][]const u8{ "quote\"s'; import os #", "back\\slash", "Door", "Door", "Ünï/Plant é" };
    var c = fx.cfg(.plugin_workspace);
    c.document = seed_doc;
    c.plugins = &odd;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const rq = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/request.json", .{r.request_dir.?}), a, .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{});
    try testing.expectEqualStrings("plugin_workspace", v.object.get("op").?.string);
    const got = v.object.get("payload").?.object.get("plugins").?.array.items;
    try testing.expectEqual(odd.len, got.len);
    for (odd, got) |want, g| try testing.expectEqualStrings(want, g.string);
    try testing.expect(v.object.get("payload").?.object.get("apis") == null);
    for (odd) |n| try testing.expect(std.mem.indexOf(u8, fx.snd.last_program, n) == null);
    // The duplicate is read twice and the raw value stays in the kept response.
    try testing.expectEqual(@as(usize, 5), r.response.?.object.get("plugins").?.array.items.len);
    try expectFile(r.request_dir.?, "probe-result.json");
}

test "plugin_workspace program calls vs.HasPlugin only and reports a missing API as a gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = bridgeBody(a, .plugin_workspace).?;
    const head = rc.bridge_py[0 .. rc.bridge_py.len - bridge_tail.len + 1];
    try testing.expect(std.mem.startsWith(u8, body, head));
    try testing.expect(std.mem.endsWith(u8, body, "\n_main()\n"));
    try testing.expect(std.mem.indexOf(u8, body, "OPS['plugin_workspace'] = op_plugin_workspace") != null);
    try testing.expect(std.mem.indexOf(u8, body, "if op != 'preflight':") != null);
    try testing.expect(std.mem.indexOf(u8, body, "_active([want], None)") != null);
    try testing.expect(std.mem.indexOf(u8, plugin_ext, "hasattr(vs, 'HasPlugin')") != null);
    try testing.expect(std.mem.indexOf(u8, plugin_ext, "rec['status'] = 'gap'") != null);
    try testing.expect(std.mem.indexOf(u8, plugin_ext, "'unexpected_shape'") != null);
    try testing.expect(std.mem.indexOf(u8, plugin_ext, "'error'") != null);
    try testing.expect(std.mem.indexOf(u8, plugin_ext, "req['payload']['plugins']") != null);
    try testing.expect(std.mem.indexOf(u8, plugin_ext, schema_plugin_workspace) != null);
    // A gap record that the Python side writes is kept by the Zig side.
    var fx = try Fx.init(.plugin_gap);
    defer fx.deinit();
    var c = fx.cfg(.plugin_workspace);
    c.document = seed_doc;
    c.plugins = &.{"Door"};
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const rec = r.response.?.object.get("plugins").?.array.items[0].object;
    try testing.expectEqualStrings("gap", rec.get("status").?.string);
    try testing.expectEqualStrings("api_absent", rec.get("reason").?.string);
    // A script error stays an explicit bridge error.
    var fx2 = try Fx.init(.bridge_error);
    defer fx2.deinit();
    var c2 = fx2.cfg(.plugin_workspace);
    c2.document = seed_doc;
    c2.plugins = &.{"Door"};
    const r2 = probe(a, testing.io, fx2.deps(fakePidPathOk), c2);
    try testing.expectEqual(Outcome.bridge_error, r2.outcome);
}

test "plugin_workspace keeps the raw tuple, membership and palette and refuses a wrong shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fx.init(.plugin_ok);
    defer fx.deinit();
    var c = fx.cfg(.plugin_workspace);
    c.document = seed_doc;
    c.plugins = &pw_names;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const items = r.response.?.object.get("plugins").?.array.items;
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Door", items[0].object.get("requested").?.string);
    try testing.expect(items[0].object.get("in_workspace").?.bool);
    try testing.expectEqualStrings("Building Shell", items[0].object.get("palette").?.string);
    try testing.expectEqualStrings("tuple", items[0].object.get("python_type").?.string);
    try testing.expectEqual(@as(usize, 2), items[0].object.get("raw").?.array.items.len);
    try testing.expect(!items[3].object.get("in_workspace").?.bool);
    try testing.expectEqualStrings("", items[3].object.get("palette").?.string);
    // The saved result and the printed lines keep them as well.
    const res_text = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/probe-result.json", .{r.request_dir.?}), a, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, res_text, "\"palette\": \"Building Shell\"") != null);
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    writeResult(a, &w, r);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "plugin\t\"Door\"\tobserved\ttrue\t\"Building Shell\"\t[true,\"Building Shell\"]\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "plugin\t\"Plant\"\tobserved\tfalse\t\"\"\t[false,\"\"]\n") != null);

    // Wrong shapes of the response are invalid. An unexpected tuple shape from the app stays recorded.
    const names = [_][]const u8{ "Door", "Window" };
    const head = "{\"schema\":\"vwx-native-plugin-workspace/1\",\"read_only\":true,\"plugins\":[";
    const door = "{\"api\":\"vs.HasPlugin\",\"requested\":\"Door\",\"status\":\"observed\",\"python_type\":\"tuple\",\"raw\":[true,\"P\"],\"in_workspace\":true,\"palette\":\"P\"}";
    const win = "{\"api\":\"vs.HasPlugin\",\"requested\":\"Window\",\"status\":\"unexpected_shape\",\"python_type\":\"bool\",\"raw\":true}";
    const cases = [_]struct { json: []const u8, ok: bool }{
        .{ .json = head ++ door ++ "," ++ win ++ "]}", .ok = true },
        .{ .json = head ++ door ++ "]}", .ok = false },
        .{ .json = head ++ win ++ "," ++ door ++ "]}", .ok = false },
        .{ .json = "{\"schema\":\"vwx-native-plugin-workspace/2\",\"read_only\":true,\"plugins\":[]}", .ok = false },
        .{ .json = "{\"schema\":\"vwx-native-plugin-workspace/1\",\"plugins\":[]}", .ok = false },
        .{ .json = "{\"schema\":\"vwx-native-plugin-workspace/1\",\"read_only\":true,\"plugins\":{}}", .ok = false },
        .{ .json = head ++ "{\"api\":\"vs.HasPlugin\",\"requested\":\"Door\",\"status\":\"observed\",\"raw\":[true,\"P\"],\"in_workspace\":1,\"palette\":\"P\"}," ++ win ++ "]}", .ok = false },
        .{ .json = head ++ "{\"api\":\"vs.CreateCustomObject\",\"requested\":\"Door\",\"status\":\"gap\"}," ++ win ++ "]}", .ok = false },
        .{ .json = head ++ "{\"api\":\"vs.HasPlugin\",\"requested\":\"Door\"}," ++ win ++ "]}", .ok = false },
    };
    for (cases) |cs| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, cs.json, .{});
        try testing.expectEqual(cs.ok, pluginWorkspaceProblem(v, &names) == null);
    }
    var fx2 = try Fx.init(.plugin_wrong_names);
    defer fx2.deinit();
    var c2 = fx2.cfg(.plugin_workspace);
    c2.document = seed_doc;
    c2.plugins = &pw_names;
    const r2 = probe(a, testing.io, fx2.deps(fakePidPathOk), c2);
    try testing.expectEqual(Outcome.invalid_response, r2.outcome);
    try testing.expect(std.mem.indexOf(u8, r2.detail, "requested string differs") != null);
}

test "plugin_workspace program has no constructor, setter, geometry, navigation or loading call" {
    // Every `vs.` name in the extension is vs.HasPlugin.
    var i: usize = 0;
    var names: usize = 0;
    while (std.mem.indexOfPos(u8, plugin_ext, i, "vs.")) |p| {
        i = p + 3;
        if (p > 0 and std.ascii.isAlphanumeric(plugin_ext[p - 1])) continue;
        var e = i;
        while (e < plugin_ext.len and (std.ascii.isAlphanumeric(plugin_ext[e]) or plugin_ext[e] == '_')) e += 1;
        if (e == i) continue;
        names += 1;
        try testing.expectEqualStrings("HasPlugin", plugin_ext[i..e]);
    }
    try testing.expect(names >= 2);
    for ([_][]const u8{ "Create", "Set", "Save", "Close", "Open", "Export", "Begin", "Delete", "DoMenu", "Load", "Install", "Move", "Rotate", "open(", "write", "exec", "eval", "import" }) |bad| {
        try testing.expect(std.mem.indexOf(u8, plugin_ext, bad) == null);
    }
}

test "existing requests keep their payload, parsing and defaults after plugin_workspace was added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", "/s", "--out", "/o", "--operator-authorized" };
    for ([_][]const u8{ "preflight", "doc", "state", "state_ext", "scalar_units" }) |name| {
        switch (parseArgs(a, &(base ++ [_][]const u8{ "--request", name }))) {
            .ok => |p| {
                try testing.expectEqualStrings(name, @tagName(p.cfg.kind));
                try testing.expectEqual(@as(usize, 0), p.cfg.plugins.len);
            },
            .bad => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(!needsDocument(.preflight) and !needsDocument(.doc) and needsDocument(.plugin_workspace));
    try testing.expectEqualStrings(rc.bridge_py, bridgeBody(a, .preflight).?);
    try testing.expectEqualStrings(rc.bridge_py, bridgeBody(a, .doc).?);
    try testing.expectEqualStrings(rc.bridge_py, bridgeBody(a, .state).?);
    try testing.expectEqualStrings(rc.bridgeProgram(a, "state_ext"), bridgeBody(a, .state_ext).?);
    try testing.expect(std.mem.indexOf(u8, rc.bridge_py, "op_plugin_workspace") == null);
    // A preflight request.json keeps the `apis` payload and gains no `plugins` key.
    var fx = try Fx.init(.ok_preflight);
    defer fx.deinit();
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), fx.cfg(.preflight));
    try testing.expectEqual(Outcome.ok, r.outcome);
    const rq = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/request.json", .{r.request_dir.?}), a, .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{});
    try testing.expect(v.object.get("payload").?.object.get("apis") != null);
    try testing.expect(v.object.get("payload").?.object.get("plugins") == null);
    try testing.expect(std.mem.indexOf(u8, usage_text, "preflight|doc|state|state_ext|scalar_units") != null);
    try testing.expect(std.mem.indexOf(u8, usage_text, "plugin_workspace") != null);
}

test "plugin_workspace runs through the command line and prints one line per candidate" {
    var fx = try Fx.init(.plugin_ok);
    defer fx.deinit();
    var buf: [8192]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    const argv = [_][]const u8{
        "--pid",        "10012",  "--expected-executable", exe_path, "--sender", fx.sender_path, "--out", fx.scratch.path,
        "--request",    "plugin_workspace", "--document", seed_doc, "--operator-authorized", "--timeout-ms", "1000",
        "--plugin", "Door", "--plugin", "Window", "--plugin", "Lighting Device", "--plugin", "Plant",
    };
    try testing.expectEqual(@as(u8, 0), runCliWith(testing.allocator, testing.io, &argv, &w, fx.deps(fakePidPathOk)));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "outcome\tok\n") != null);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, w.buffered(), '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, "plugin\t")) {
        lines += 1;
    };
    try testing.expectEqual(@as(usize, 4), lines);
    // Without any --plugin the command is refused and exits 1 before the sender runs.
    var w2 = Io.Writer.fixed(&buf);
    const none = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", fx.sender_path, "--out", fx.scratch.path, "--request", "plugin_workspace", "--document", seed_doc, "--operator-authorized" };
    const calls = fx.snd.calls;
    try testing.expectEqual(@as(u8, 1), runCliWith(testing.allocator, testing.io, &none, &w2, fx.deps(fakePidPathOk)));
    try testing.expectEqual(calls, fx.snd.calls);
}

// Frame readback probe tests

const fr_layers = [_][]const u8{ "Design Layer-1", "Design Layer-2" };

/// Response of a fake application for `frame_readback`. It reads the layer names and the
/// current-object flag from request.json. Elevations are placeholders of the shape and not measurements.
/// `unbound` leaves the first named layer unbound. `wrong_name` returns another name for it.
fn frameJson(a: Allocator, dir: []const u8, mode: enum { ok, unbound, wrong_name }) []const u8 {
    const rq = Dir.cwd().readFileAlloc(testing.io, std.fmt.allocPrint(a, "{s}/request.json", .{dir}) catch return "", a, .limited(1 << 20)) catch return "";
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{}) catch return "";
    const pl = v.object.get("payload").?.object;
    const items = pl.get("layers").?.array.items;
    var aw: Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeAll("{\"schema\":\"vwx-native-frame-readback/1\",\"read_only\":true," ++
        "\"working_plane_n\":{\"api\":\"vs.GetWorkingPlaneN\",\"status\":\"observed\",\"python_type\":\"tuple\",\"raw\":[0,0,0,0,0.6,0.8,1,0,0],\"length\":9}," ++
        "\"working_plane\":{\"api\":\"vs.GetWorkingPlane\",\"status\":\"observed\",\"python_type\":\"tuple\",\"raw\":[1,2,3,4,5,6],\"length\":6},\"layers\":[") catch return "";
    var first = true;
    for (items, 0..) |it, i| {
        if (!first) w.writeByte(',') catch return "";
        first = false;
        w.writeAll("{\"binding\":\"name\",\"requested\":") catch return "";
        std.json.Stringify.value(it.string, .{}, w) catch return "";
        if (mode == .unbound and i == 0) {
            w.writeAll(",\"status\":\"unbound\",\"reason\":\"nil_layer_handle\"}") catch return "";
            continue;
        }
        w.writeAll(",\"status\":\"bound\",\"layer_name\":{\"api\":\"vs.GetLName\",\"status\":\"observed\",\"python_type\":\"str\",\"raw\":") catch return "";
        std.json.Stringify.value(if (mode == .wrong_name and i == 0) "Other" else it.string, .{}, w) catch return "";
        w.writeAll("},\"elevation\":{\"api\":\"vs.GetLayerElevation\",\"status\":\"observed\",\"python_type\":\"tuple\",\"raw\":[640750.0,0.0],\"length\":2}," ++
            "\"elevation_n\":{\"api\":\"vs.GetLayerElevationN\",\"status\":\"observed\",\"python_type\":\"tuple\",\"raw\":[640.75,0.0],\"length\":2}}") catch return "";
    }
    if (pl.get("current_object_layer").?.bool) {
        if (!first) w.writeByte(',') catch return "";
        w.writeAll("{\"binding\":\"current_object\",\"requested\":null,\"status\":\"bound\",\"get3dcntr\":{\"api\":\"vs.Get3DCntr\",\"status\":\"observed\",\"raw\":[1,2,3]}," ++
            "\"layer_name\":{\"api\":\"vs.GetLName\",\"status\":\"observed\",\"python_type\":\"str\",\"raw\":\"Design Layer-1\"}," ++
            "\"elevation\":{\"api\":\"vs.GetLayerElevation\",\"status\":\"observed\",\"raw\":[640750.0,0.0]}," ++
            "\"elevation_n\":{\"api\":\"vs.GetLayerElevationN\",\"status\":\"observed\",\"raw\":[640.75,0.0]}}") catch return "";
    }
    w.writeAll("]}") catch return "";
    return aw.written();
}

fn frameCfg(fx: *Fx) Config {
    var c = fx.cfg(.frame_readback);
    c.document = seed_doc;
    c.layers = &fr_layers;
    return c;
}

test "frame_readback refuses a missing, oversized or malformed binding before the sender runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fx.init(.frame_ok);
    defer fx.deinit();
    var c = fx.cfg(.frame_readback);
    c.document = seed_doc;
    var r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.refused, r.outcome);
    try testing.expect(std.mem.indexOf(u8, r.detail, "at least one --layer or --current-object-layer") != null);
    const five = [_][]const u8{ "a", "b", "c", "d", "e" };
    c.layers = &five;
    r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expect(std.mem.indexOf(u8, r.detail, "at most 4") != null);
    const long = [_]u8{'x'} ** (max_layer_bytes + 1);
    const bad = [_][]const u8{ "", &long, "a\nb", "a\x7fb", "\xff\xfe" };
    for (bad) |name| {
        c.layers = &.{name};
        r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
        try testing.expectEqual(Outcome.refused, r.outcome);
    }
    // No document, a relative document and a binding on another request are refused as well.
    var c2 = frameCfg(&fx);
    c2.document = null;
    try testing.expect(std.mem.indexOf(u8, probe(a, testing.io, fx.deps(fakePidPathOk), c2).detail, "--document is required") != null);
    c2.document = "relative.vwx";
    try testing.expectEqual(Outcome.refused, probe(a, testing.io, fx.deps(fakePidPathOk), c2).outcome);
    var c3 = fx.cfg(.scalar_units);
    c3.document = seed_doc;
    c3.layers = &fr_layers;
    try testing.expect(std.mem.indexOf(u8, probe(a, testing.io, fx.deps(fakePidPathOk), c3).detail, "only with --request frame_readback") != null);
    c3.layers = &.{};
    c3.current_object_layer = true;
    try testing.expectEqual(Outcome.refused, probe(a, testing.io, fx.deps(fakePidPathOk), c3).outcome);
    // The identity guard still runs first for a valid request.
    const m = probe(a, testing.io, fx.deps(fakePidPathOther), frameCfg(&fx));
    try testing.expectEqual(Outcome.executable_mismatch, m.outcome);
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
    // The command line parses both options and exits 1 without a binding.
    const base = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", "/s", "--out", "/o", "--operator-authorized", "--request", "frame_readback", "--document", seed_doc };
    switch (parseArgs(a, &(base ++ [_][]const u8{ "--layer", "Design Layer-1", "--layer", "Design Layer-2", "--current-object-layer" }))) {
        .ok => |p| {
            try testing.expectEqual(Kind.frame_readback, p.cfg.kind);
            try testing.expectEqual(@as(usize, 2), p.cfg.layers.len);
            try testing.expectEqualStrings("Design Layer-2", p.cfg.layers[1]);
            try testing.expect(p.cfg.current_object_layer);
        },
        .bad => return error.TestUnexpectedResult,
    }
    var over: [2 * 5][]const u8 = undefined;
    for (0..5) |i| {
        over[2 * i] = "--layer";
        over[2 * i + 1] = "L";
    }
    switch (parseArgs(a, &(base ++ over))) {
        .bad => |why| try testing.expect(std.mem.indexOf(u8, why, "at most 4") != null),
        .ok => return error.TestUnexpectedResult,
    }
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    const none = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", fx.sender_path, "--out", fx.scratch.path, "--request", "frame_readback", "--document", seed_doc, "--operator-authorized" };
    try testing.expectEqual(@as(u8, 1), runCliWith(testing.allocator, testing.io, &none, &w, fx.deps(fakePidPathOk)));
    try testing.expectEqual(@as(u32, 0), fx.snd.calls);
}

test "frame_readback sends the exact document and each name in request.json and never in the Python source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fx.init(.frame_ok);
    defer fx.deinit();
    var c = frameCfg(&fx);
    c.layers = &.{ "Design Layer-1", "L\"'\\ 2" };
    c.current_object_layer = true;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    try testing.expectEqual(@as(u32, 1), fx.snd.calls);
    const rq = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/request.json", .{r.request_dir.?}), a, .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rq, .{});
    try testing.expectEqualStrings("frame_readback", v.object.get("op").?.string);
    try testing.expectEqualStrings(seed_doc, v.object.get("document").?.string);
    const pl = v.object.get("payload").?.object;
    try testing.expectEqual(@as(usize, 2), pl.get("layers").?.array.items.len);
    try testing.expectEqualStrings("L\"'\\ 2", pl.get("layers").?.array.items[1].string);
    try testing.expect(pl.get("current_object_layer").?.bool);
    try testing.expect(pl.get("apis") == null);
    try testing.expect(std.mem.indexOf(u8, fx.snd.last_program, "Design Layer-1") == null);
    const head = rc.bridge_py[0 .. rc.bridge_py.len - bridge_tail.len + 1];
    try testing.expect(std.mem.indexOf(u8, fx.snd.last_program, head) != null);
    try testing.expect(std.mem.endsWith(u8, fx.snd.last_program, "\n_main()\n"));
    try testing.expect(std.mem.indexOf(u8, fx.snd.last_program, "OPS['frame_readback'] = op_frame_readback") != null);
    try testing.expect(std.mem.indexOf(u8, fx.snd.last_program, "_active([want], None)") != null);
    try testing.expect(std.mem.indexOf(u8, frame_ext, "req['payload']") != null);
    try testing.expect(std.mem.indexOf(u8, frame_ext, schema_frame_readback) != null);
    try expectFile(r.request_dir.?, "probe-result.json");
}

test "frame_readback keeps the raw readbacks, prints them and accepts an unbound entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fx.init(.frame_ok);
    defer fx.deinit();
    var c = frameCfg(&fx);
    c.current_object_layer = true;
    const r = probe(a, testing.io, fx.deps(fakePidPathOk), c);
    try testing.expectEqual(Outcome.ok, r.outcome);
    const ls = r.response.?.object.get("layers").?.array.items;
    try testing.expectEqual(@as(usize, 3), ls.len);
    try testing.expectEqual(@as(usize, 2), ls[0].object.get("elevation").?.object.get("raw").?.array.items.len);
    try testing.expectEqualStrings("current_object", ls[2].object.get("binding").?.string);
    try testing.expectEqual(@as(usize, 9), r.response.?.object.get("working_plane_n").?.object.get("raw").?.array.items.len);
    const res_text = try Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/probe-result.json", .{r.request_dir.?}), a, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, res_text, "vs.GetLayerElevationN") != null);
    var buf: [8192]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    writeResult(a, &w, r);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "working_plane_n\t\"observed\"\t[0,0,0,0,0.6,0.8,1,0,0]\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "layer\t\"name\"\t\"Design Layer-1\"\t\"bound\"\t[640750,0]\t[640.75,0]\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "layer\t\"current_object\"\tnull\t\"bound\"\t") != null);
    // An unbound entry with its reason is a valid response. A wrong name or a wrong API is not.
    var fx2 = try Fx.init(.frame_unbound);
    defer fx2.deinit();
    try testing.expectEqual(Outcome.ok, probe(a, testing.io, fx2.deps(fakePidPathOk), frameCfg(&fx2)).outcome);
    var fx3 = try Fx.init(.frame_wrong_name);
    defer fx3.deinit();
    const r3 = probe(a, testing.io, fx3.deps(fakePidPathOk), frameCfg(&fx3));
    try testing.expectEqual(Outcome.invalid_response, r3.outcome);
    try testing.expect(std.mem.indexOf(u8, r3.detail, "differs from the requested name") != null);
    try expectFile(r3.request_dir.?, "probe-result.json");
}

test "frame_readback refuses a malformed response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wp = "\"working_plane_n\":{\"api\":\"vs.GetWorkingPlaneN\",\"status\":\"gap\",\"reason\":\"api_absent\"},\"working_plane\":{\"api\":\"vs.GetWorkingPlane\",\"status\":\"error\",\"reason\":\"RuntimeError: x\"},";
    const head = "{\"schema\":\"vwx-native-frame-readback/1\",\"read_only\":true,";
    const un = "{\"binding\":\"name\",\"requested\":\"A\",\"status\":\"unbound\",\"reason\":\"nil_layer_handle\"}";
    const cases = [_]struct { json: []const u8, ok: bool }{
        .{ .json = head ++ wp ++ "\"layers\":[" ++ un ++ "]}", .ok = true },
        .{ .json = head ++ wp ++ "\"layers\":[]}", .ok = false },
        .{ .json = head ++ wp ++ "\"layers\":[" ++ un ++ "," ++ un ++ "]}", .ok = false },
        .{ .json = head ++ "\"layers\":[" ++ un ++ "]}", .ok = false },
        .{ .json = "{\"schema\":\"vwx-native-frame-readback/2\",\"read_only\":true," ++ wp ++ "\"layers\":[" ++ un ++ "]}", .ok = false },
        .{ .json = "{\"schema\":\"vwx-native-frame-readback/1\"," ++ wp ++ "\"layers\":[" ++ un ++ "]}", .ok = false },
        .{ .json = head ++ wp ++ "\"layers\":[{\"binding\":\"name\",\"requested\":\"B\",\"status\":\"unbound\",\"reason\":\"r\"}]}", .ok = false },
        .{ .json = head ++ wp ++ "\"layers\":[{\"binding\":\"current_object\",\"requested\":null,\"status\":\"unbound\",\"reason\":\"r\"}]}", .ok = false },
        .{ .json = head ++ wp ++ "\"layers\":[{\"binding\":\"name\",\"requested\":\"A\",\"status\":\"unbound\"}]}", .ok = false },
        .{ .json = head ++ wp ++ "\"layers\":[{\"binding\":\"name\",\"requested\":\"A\",\"status\":\"bound\"}]}", .ok = false },
        .{ .json = head ++ wp ++ "\"layers\":[{\"binding\":\"name\",\"requested\":\"A\",\"status\":\"maybe\"}]}", .ok = false },
        .{ .json = head ++ "\"working_plane_n\":{\"api\":\"vs.SetWorkingPlaneN\",\"status\":\"gap\"},\"working_plane\":{\"api\":\"vs.GetWorkingPlane\",\"status\":\"gap\"},\"layers\":[" ++ un ++ "]}", .ok = false },
        .{ .json = head ++ wp ++ "\"layers\":[" ++ un ++ "],\"x\":1e999}", .ok = false },
    };
    const cfg: Config = .{ .pid = 10012, .expected_executable = exe_path, .sender = "/s", .out_dir = "/o", .kind = .frame_readback, .layers = &.{"A"} };
    for (cases) |cs| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, cs.json, .{});
        try testing.expectEqual(cs.ok, frameReadbackProblem(v, cfg) == null);
    }
    // The current-object entry is required when the flag is set.
    var cur = cfg;
    cur.layers = &.{};
    cur.current_object_layer = true;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, head ++ wp ++ "\"layers\":[" ++ un ++ "]}", .{});
    try testing.expect(frameReadbackProblem(v, cur) != null);
}

test "frame_readback program calls getters only and has no setter, geometry, navigation or loading call" {
    const allowed = [_][]const u8{ "GetLayerByName", "GetLName", "GetLayerElevation", "GetLayerElevationN", "GetLayer", "FSActLayer", "NumSelectedObjects", "Get3DCntr", "GetWorkingPlaneN", "GetWorkingPlane" };
    var i: usize = 0;
    var names: usize = 0;
    while (std.mem.indexOfPos(u8, frame_ext, i, "vs.")) |p| {
        i = p + 3;
        if (p > 0 and std.ascii.isAlphanumeric(frame_ext[p - 1])) continue;
        var e = i;
        while (e < frame_ext.len and (std.ascii.isAlphanumeric(frame_ext[e]) or frame_ext[e] == '_')) e += 1;
        if (e == i) continue;
        names += 1;
        try testing.expect(inList(&allowed, frame_ext[i..e]));
    }
    try testing.expect(names >= 10);
    for ([_][]const u8{ "Create", "Set", "Save", "Close", "Open", "Export", "Begin", "Delete", "DoMenu", "Load", "Install", "Move", "Rotate", "Layer(", "open(", "write", "exec", "eval", "import", "Handle(" }) |bad| {
        try testing.expect(std.mem.indexOf(u8, frame_ext, bad) == null);
    }
    // The name lookup is checked against the layer's own name and the working plane is read before any layer call.
    try testing.expect(std.mem.indexOf(u8, frame_ext, "got != requested") != null);
    try testing.expect(std.mem.indexOf(u8, frame_ext, "'vs.GetWorkingPlaneN'").? < std.mem.indexOf(u8, frame_ext, "_fr_by_name(n) for n").?);
}

test "older requests keep their program, payload and options after frame_readback was added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "--pid", "10012", "--expected-executable", exe_path, "--sender", "/s", "--out", "/o", "--operator-authorized" };
    for ([_][]const u8{ "preflight", "doc", "state", "state_ext", "scalar_units", "plugin_workspace" }) |name| {
        switch (parseArgs(a, &(base ++ [_][]const u8{ "--request", name }))) {
            .ok => |p| {
                try testing.expectEqual(@as(usize, 0), p.cfg.layers.len);
                try testing.expect(!p.cfg.current_object_layer);
            },
            .bad => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(needsDocument(.frame_readback) and !needsDocument(.doc));
    try testing.expectEqualStrings(rc.bridge_py, bridgeBody(a, .state).?);
    try testing.expectEqualStrings(rc.bridgeProgram(a, "state_ext"), bridgeBody(a, .state_ext).?);
    try testing.expect(std.mem.indexOf(u8, rc.bridge_py, "op_frame_readback") == null);
    try testing.expect(std.mem.indexOf(u8, bridgeBody(a, .plugin_workspace).?, "op_frame_readback") == null);
    try testing.expect(std.mem.indexOf(u8, usage_text, "preflight|doc|state|state_ext|scalar_units|plugin_workspace|frame_readback") != null);
}
