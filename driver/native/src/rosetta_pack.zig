//! Rosetta pack validation, immutable packaging, subsets, archives and copy records.
//!
//! The rules are in vwx/tools/research/rosetta/pack/SCHEMA.md (schema `vwx-rosetta/1`).
//! The module reads JSON metadata. It hashes every other file as opaque bytes.
//! `runCli` is the entry point for `vwx rosetta <command>`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const json = std.json;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_pack = "vwx-rosetta/1";
pub const schema_queue = "vwx-rosetta-queue/1";
pub const schema_obligations = "vwx-rosetta-obligations/1";
pub const schema_frames = "vwx-rosetta-frames/1";
pub const schema_coverage = "vwx-rosetta-coverage/1";
pub const schema_missing = "vwx-rosetta-missing/1";
pub const schema_subset = "vwx-rosetta-subset/1";
pub const schema_backup = "vwx-rosetta-backup/1";
pub const schema_measurements = "vwx-rosetta-measurements/1";
pub const schema_capture_selection = "vwx-rosetta-capture-selection/1";

pub const input_root_name = "rosetta.json";
pub const manifest_name = "MANIFEST.json";
pub const sums_name = "SHA256SUMS";
pub const catalog_name = "CATALOG.md";
pub const coverage_name = "COVERAGE.json";
pub const missing_name = "MISSING.json";
pub const subset_name = "SUBSET.json";
pub const measurements_name = "MEASUREMENTS.json";
/// Optional root file. `vwx rosetta-capture finalize --cases` writes it. It is copied byte for byte.
pub const capture_selection_name = "capture-selection.json";
/// The revision of the table in `componentProblem`. Each revision adds rows only.
pub const component_registry_revision: u32 = 4;

/// Files that build writes. `verify` regenerates them and compares bytes.
const generated_reports = [_][]const u8{ catalog_name, coverage_name, missing_name };

/// Metadata files are read whole. Every other file is streamed.
const max_metadata_bytes: usize = 64 << 20;
const max_json_line: usize = 1 << 20;
const max_path_bytes: usize = 240;
const max_components: usize = 16;
const max_component_bytes: usize = 128;
const max_id_bytes: usize = 128;
const chunk_bytes: usize = 1 << 16;

// ---------------------------------------------------------------------------
// diagnostics
// ---------------------------------------------------------------------------

pub const Severity = enum {
    @"error",
    gap,
    warning,
};

pub const Diag = struct {
    severity: Severity,
    code: []const u8,
    location: []const u8,
    message: []const u8,
};

pub const Diags = struct {
    arena: Allocator,
    list: std.ArrayList(Diag) = .empty,
    /// Errors that could not be stored because an allocation failed. They still count as errors.
    dropped_errors: usize = 0,

    pub fn init(arena: Allocator) Diags {
        return .{ .arena = arena };
    }

    pub fn add(d: *Diags, sev: Severity, code: []const u8, location: []const u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(d.arena, fmt, args) catch "(message allocation failed)";
        d.list.append(d.arena, .{ .severity = sev, .code = code, .location = location, .message = msg }) catch {
            if (sev == .@"error") d.dropped_errors += 1;
        };
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
        return d.count(.@"error") + d.dropped_errors;
    }

    pub fn has(d: *const Diags, code: []const u8) bool {
        for (d.list.items) |x| {
            if (std.mem.eql(u8, x.code, code)) return true;
        }
        return false;
    }

    pub fn write(d: *const Diags, w: *Io.Writer) Io.Writer.Error!void {
        for (d.list.items) |x| {
            try w.print("diag\t{s}\t{s}\t", .{ @tagName(x.severity), x.code });
            try writeEscaped(w, x.location);
            try w.writeByte('\t');
            try writeEscaped(w, x.message);
            try w.writeByte('\n');
        }
        if (d.dropped_errors > 0) try w.print("diag\terror\tout_of_memory\t.\t{d} errors could not be stored\n", .{d.dropped_errors});
    }
};

/// Writes `s` as one output field. A byte below 0x20, 0x7f and `\` become `\xNN`.
/// A file name or argument with a tab or a newline then stays inside its field and line.
pub fn writeEscaped(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') {
            try w.print("\\x{x:0>2}", .{c});
        } else try w.writeByte(c);
    }
}

fn loc(a: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch "(location)";
}

// ---------------------------------------------------------------------------
// lexical checks
// ---------------------------------------------------------------------------

/// Null when `s` is a valid ID. Otherwise the reason.
pub fn idProblem(s: []const u8) ?[]const u8 {
    if (s.len == 0) return "empty";
    if (s.len > max_id_bytes) return "longer than 128 bytes";
    if (!std.ascii.isAlphanumeric(s[0])) return "first byte is not a letter or digit";
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return "byte outside [A-Za-z0-9._-]";
    }
    return null;
}

fn componentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '+';
}

/// Null when `p` is a valid relative pack path. Otherwise the reason.
pub fn pathProblem(p: []const u8) ?[]const u8 {
    if (p.len == 0) return "empty";
    if (p.len > max_path_bytes) return "longer than 240 bytes";
    if (p[0] == '/') return "absolute";
    if (p[p.len - 1] == '/') return "trailing slash";
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| {
        n += 1;
        if (n > max_components) return "more than 16 components";
        if (c.len == 0) return "empty component";
        if (std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return "dot component";
        if (c.len > max_component_bytes) return "component longer than 128 bytes";
        for (c) |b| {
            if (b == '\\') return "backslash";
            if (!componentByte(b)) return "byte outside [A-Za-z0-9._+-]";
        }
        if (!(std.ascii.isAlphanumeric(c[0]) or c[0] == '_')) return "component starts with a byte other than a letter, digit or _";
    }
    return null;
}

pub fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

const credential_suffixes = [_][]const u8{ ".lic", ".key", ".pem", ".p8", ".p12", ".pfx", ".keychain", ".keychain-db" };
const credential_words = [_][]const u8{ "activation", "credential", "password", "secret", "id_rsa", "id_ecdsa", "id_ed25519" };
const private_key_marker = "PRIVATE KEY-----";

/// True when the base name of `p` names credential or activation material.
pub fn credentialName(p: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
    var buf: [max_component_bytes * 2]u8 = undefined;
    if (base.len > buf.len) return false;
    const low = std.ascii.lowerString(&buf, base);
    for (credential_suffixes) |s| {
        if (std.mem.endsWith(u8, low, s)) return true;
    }
    for (credential_words) |w| {
        if (std.mem.indexOf(u8, low, w) != null) return true;
    }
    return false;
}

fn lowerDup(a: Allocator, s: []const u8) []const u8 {
    const out = a.alloc(u8, s.len) catch return s;
    return std.ascii.lowerString(out, s);
}

fn hexOf(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return hexOf(d);
}

// ---------------------------------------------------------------------------
// channel registry
// ---------------------------------------------------------------------------

pub const Kind = enum { raw, normalized, sidecar };

pub const ContentReader = enum {
    none,
    json_syntax,
    jsonl_syntax,
    measurements,
    frames,
    /// Sealed export bundle manifest (`vwx-rosetta-opdir-manifest/1`) and its seal. Byte integrity only.
    bundle_manifest,
    bundle_seal,
    /// Reference scans of files inside a sealed bundle. The file stays preserved-unmeasured.
    scan_obj,
    scan_mtl,
    scan_3ds,

    pub fn capability(r: ContentReader) []const u8 {
        return switch (r) {
            .none, .scan_obj, .scan_mtl, .scan_3ds => "preserved_unmeasured",
            .json_syntax, .jsonl_syntax => "syntax_checked",
            .measurements, .frames => "measured",
            .bundle_manifest, .bundle_seal => "bundle_integrity_checked",
        };
    }
};

pub const ChannelInfo = struct {
    kind: Kind,
    dirs: []const []const u8,
    reader: ContentReader,
    export_format: ?[]const u8 = null,
    /// The channel belongs to the `exports` group without naming one format.
    exports_group: bool = false,

    pub fn isExport(i: ChannelInfo) bool {
        return i.export_format != null or i.exports_group;
    }
};

/// Appended rows keep the position of every earlier row. `export_<format>` channels follow this order.
pub const export_formats = [_][]const u8{ "dwg", "dxf", "parasolid", "sat", "obj", "stl", "3ds", "fbx", "gltf", "pdf", "svg", "ifc", "csv", "xlsx", "png", "jpeg", "other", "step", "usd", "iges", "3dm", "vwx" };

pub const channel_bundle_manifest = "export_bundle_manifest";
pub const channel_sidecar = "export_sidecar";

/// Channels of the sealed export bundle extension. They are looked up after the revision 1 rows.
const bundle_channel_table = [_]ChannelEntry{
    .{ .name = channel_bundle_manifest, .info = .{ .kind = .sidecar, .dirs = &.{"exports/"}, .reader = .bundle_manifest, .exports_group = true } },
    .{ .name = channel_sidecar, .info = .{ .kind = .raw, .dirs = &.{"exports/"}, .reader = .none, .exports_group = true } },
};

const ChannelEntry = struct { name: []const u8, info: ChannelInfo };

const channel_table = [_]ChannelEntry{
    .{ .name = "recipe", .info = .{ .kind = .raw, .dirs = &.{"recipe/"}, .reader = .none } },
    .{ .name = "recipe_checkpoint", .info = .{ .kind = .raw, .dirs = &.{"recipe/"}, .reader = .none } },
    .{ .name = "source_original", .info = .{ .kind = .raw, .dirs = &.{"source/"}, .reader = .none } },
    .{ .name = "source_reopened", .info = .{ .kind = .raw, .dirs = &.{"source/"}, .reader = .none } },
    .{ .name = "source_derivative", .info = .{ .kind = .raw, .dirs = &.{"source/"}, .reader = .none } },
    .{ .name = "blank_control", .info = .{ .kind = .raw, .dirs = &.{"source/"}, .reader = .none } },
    .{ .name = "native_query_raw", .info = .{ .kind = .raw, .dirs = &.{"native/raw/"}, .reader = .none } },
    .{ .name = "native_measurements", .info = .{ .kind = .normalized, .dirs = &.{"native/"}, .reader = .measurements } },
    .{ .name = "native_frames", .info = .{ .kind = .normalized, .dirs = &.{"native/"}, .reader = .frames } },
    .{ .name = "native_objects", .info = .{ .kind = .normalized, .dirs = &.{"native/"}, .reader = .jsonl_syntax } },
    .{ .name = "native_document", .info = .{ .kind = .normalized, .dirs = &.{"native/"}, .reader = .json_syntax } },
    .{ .name = "native_state", .info = .{ .kind = .sidecar, .dirs = &.{ "native/", "exports/" }, .reader = .json_syntax } },
    .{ .name = "export_result", .info = .{ .kind = .sidecar, .dirs = &.{"exports/"}, .reader = .json_syntax } },
    .{ .name = "view_image", .info = .{ .kind = .raw, .dirs = &.{"views/"}, .reader = .none } },
    .{ .name = "capture_log", .info = .{ .kind = .sidecar, .dirs = &.{"logs/"}, .reader = .none } },
    .{ .name = "normalized_comparison", .info = .{ .kind = .normalized, .dirs = &.{"normalized/"}, .reader = .jsonl_syntax } },
};

pub fn channelInfo(name: []const u8) ?ChannelInfo {
    for (channel_table) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.info;
    }
    if (std.mem.startsWith(u8, name, "export_")) {
        const f = name["export_".len..];
        for (export_formats) |x| {
            if (std.mem.eql(u8, x, f)) return .{ .kind = .raw, .dirs = &.{"exports/"}, .reader = .none, .export_format = x };
        }
    }
    for (bundle_channel_table) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.info;
    }
    return null;
}

test "an older-version save is a registered export format" {
    const info = channelInfo("export_vwx") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("vwx", info.export_format.?);
}

/// The channel names of revision 1, for reports.
pub fn channelNames(a: Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (channel_table) |e| out.append(a, e.name) catch {};
    for (export_formats) |f| out.append(a, std.fmt.allocPrint(a, "export_{s}", .{f}) catch f) catch {};
    for (bundle_channel_table) |e| out.append(a, e.name) catch {};
    return out.items;
}

/// Null when an artifact of `info` may live at case-relative `path`.
fn dirProblem(info: ChannelInfo, path: []const u8) ?[]const u8 {
    if (info.kind != .raw and std.mem.startsWith(u8, path, "native/raw/")) return "native/raw/ holds raw channels only";
    for (info.dirs) |d| {
        if (std.mem.startsWith(u8, path, d) and path.len > d.len) return null;
    }
    return "path is outside the directory of its channel";
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Numbers stay as their source text, so a regenerated manifest keeps their bytes.
/// A duplicate key is an error.
/// Arrays and objects nest at most this deep. Deeper input gets `json_too_deep`.
/// `checkFinite` and `json.Stringify` recurse once per level.
pub const max_json_depth: usize = 128;

/// Scans raw JSON bytes for nesting depth without recursion. Malformed bytes pass to the parser.
fn jsonDepthOk(bytes: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > max_json_depth) return false;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

/// Diagnostic code for a `parseJson` error.
fn jsonErrorCode(e: anyerror) []const u8 {
    return if (e == error.NestingTooDeep) "json_too_deep" else "invalid_json";
}

pub fn parseJson(a: Allocator, bytes: []const u8) !json.Value {
    if (!jsonDepthOk(bytes)) return error.NestingTooDeep;
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

pub fn numberOf(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn intOf(v: json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| blk: {
            if (std.mem.indexOfAny(u8, s, ".eE") != null) break :blk null;
            break :blk std.fmt.parseInt(i64, s, 10) catch null;
        },
        else => null,
    };
}

/// Every number in `v` is finite. Reports the first nonfinite number.
fn checkFinite(d: *Diags, v: json.Value, where: []const u8) bool {
    switch (v) {
        .integer, .float, .number_string => {
            const f = numberOf(v) orelse {
                d.err("nonfinite_number", where, "number does not parse", .{});
                return false;
            };
            if (!std.math.isFinite(f)) {
                d.err("nonfinite_number", where, "number is not finite", .{});
                return false;
            }
            return true;
        },
        .array => |arr| {
            for (arr.items) |x| {
                if (!checkFinite(d, x, where)) return false;
            }
            return true;
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (!checkFinite(d, e.value_ptr.*, where)) return false;
            }
            return true;
        },
        else => return true,
    }
}

const Fields = struct {
    d: *Diags,
    v: json.Value,
    where: []const u8,
    ok: bool = true,

    fn init(d: *Diags, v: json.Value, where: []const u8, what: []const u8) ?Fields {
        if (v != .object) {
            d.err("schema_type", where, "{s} is not a JSON object", .{what});
            return null;
        }
        return .{ .d = d, .v = v, .where = where };
    }

    fn present(f: *Fields, name: []const u8) ?json.Value {
        const x = field(f.v, name) orelse {
            f.d.err("schema_missing_field", f.where, "field `{s}` is missing", .{name});
            f.ok = false;
            return null;
        };
        return x;
    }

    /// A required non-empty string.
    fn str(f: *Fields, name: []const u8) ?[]const u8 {
        const x = f.present(name) orelse return null;
        if (x != .string or x.string.len == 0) {
            f.d.err("schema_type", f.where, "field `{s}` is not a non-empty string", .{name});
            f.ok = false;
            return null;
        }
        return x.string;
    }

    /// A required field holding null or a non-empty string.
    fn strOrNull(f: *Fields, name: []const u8) ?[]const u8 {
        const x = f.present(name) orelse return null;
        switch (x) {
            .null => return null,
            .string => |s| {
                if (s.len > 0) return s;
            },
            else => {},
        }
        f.d.err("schema_type", f.where, "field `{s}` is not null or a non-empty string", .{name});
        f.ok = false;
        return null;
    }

    /// An optional field holding a non-empty string.
    fn optStr(f: *Fields, name: []const u8) ?[]const u8 {
        const x = field(f.v, name) orelse return null;
        switch (x) {
            .null => return null,
            .string => |s| {
                if (s.len > 0) return s;
            },
            else => {},
        }
        f.d.err("schema_type", f.where, "field `{s}` is not a non-empty string", .{name});
        f.ok = false;
        return null;
    }

    fn id(f: *Fields, name: []const u8) ?[]const u8 {
        const s = f.str(name) orelse return null;
        if (idProblem(s)) |why| {
            f.d.err("invalid_id", f.where, "field `{s}` value `{s}`: {s}", .{ name, s, why });
            f.ok = false;
            return null;
        }
        return s;
    }

    fn sha(f: *Fields, name: []const u8) ?[]const u8 {
        const s = f.strOrNull(name) orelse return null;
        if (!isSha256(s)) {
            f.d.err("malformed_hash", f.where, "field `{s}` is not 64 lowercase hex digits", .{name});
            f.ok = false;
            return null;
        }
        return s;
    }

    fn reqSha(f: *Fields, name: []const u8) ?[]const u8 {
        const x = field(f.v, name);
        if (x == null or x.? == .null) {
            f.d.err("schema_missing_field", f.where, "field `{s}` needs a SHA256", .{name});
            f.ok = false;
            return null;
        }
        return f.sha(name);
    }

    fn boolean(f: *Fields, name: []const u8) ?bool {
        const x = f.present(name) orelse return null;
        if (x != .bool) {
            f.d.err("schema_type", f.where, "field `{s}` is not a boolean", .{name});
            f.ok = false;
            return null;
        }
        return x.bool;
    }

    fn object(f: *Fields, name: []const u8) ?json.Value {
        const x = f.present(name) orelse return null;
        if (x != .object) {
            f.d.err("schema_type", f.where, "field `{s}` is not an object", .{name});
            f.ok = false;
            return null;
        }
        return x;
    }

    fn array(f: *Fields, name: []const u8) ?[]json.Value {
        const x = f.present(name) orelse return null;
        if (x != .array) {
            f.d.err("schema_type", f.where, "field `{s}` is not an array", .{name});
            f.ok = false;
            return null;
        }
        return x.array.items;
    }

    fn optArray(f: *Fields, name: []const u8) ?[]json.Value {
        const x = field(f.v, name) orelse return null;
        if (x != .array) {
            f.d.err("schema_type", f.where, "field `{s}` is not an array", .{name});
            f.ok = false;
            return null;
        }
        return x.array.items;
    }

    /// A required array of IDs.
    fn ids(f: *Fields, a: Allocator, name: []const u8) []const []const u8 {
        const arr = f.array(name) orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        for (arr) |x| {
            if (x != .string or idProblem(x.string) != null) {
                f.d.err("invalid_id", f.where, "field `{s}` holds an entry that is not a valid ID", .{name});
                f.ok = false;
                continue;
            }
            out.append(a, x.string) catch {};
        }
        return out.items;
    }

    fn schema(f: *Fields, want: []const u8) bool {
        const s = f.str("schema") orelse return false;
        if (!std.mem.eql(u8, s, want)) {
            f.d.err("schema_id", f.where, "schema is `{s}`, expected `{s}`", .{ s, want });
            f.ok = false;
            return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// model
// ---------------------------------------------------------------------------

pub const State = enum {
    pending,
    acquired,
    unavailable,
    out_of_scope,
    unverified,
    creation_unavailable,
    reference_unavailable,
    legacy_only,
    transient_only,
    reserved,
    unknown,

    pub fn isArtifactState(s: State) bool {
        return @intFromEnum(s) <= @intFromEnum(State.unverified);
    }

    /// The entry has bytes in the pack.
    pub fn hasBytes(s: State) bool {
        return s == .acquired or s == .unverified;
    }

    pub fn needsReason(s: State) bool {
        return !(s == .pending or s == .acquired or s == .unverified);
    }
};

pub const Universe = enum { controlled, interaction, university, native_acceptance };

pub const Group = enum { sources, native_channels, exports, auxiliary };

pub const Release = struct {
    version: ?[]const u8 = null,
    build: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    verified: bool = false,
};

pub const CaseRef = struct {
    case_id: []const u8,
    path: []const u8,
    sha256: ?[]const u8,
};

pub const Profile = struct {
    profile_id: []const u8,
    profile_revision: []const u8,
    profile_sha256: []const u8,
    format: []const u8,
    path: ?[]const u8,
};

pub const Dependency = struct {
    dependency_id: []const u8,
    path: []const u8,
    sha256: ?[]const u8,
    state: State,
    kind: []const u8,
};

pub const Obligation = struct {
    obligation_id: []const u8,
    case_id: []const u8,
    mechanism: []const u8,
    required_channels: []const []const u8,
    disposition: []const u8,
    owner: []const u8,
};

pub const Artifact = struct {
    artifact_id: []const u8,
    path: []const u8,
    sha256: ?[]const u8,
    channel: []const u8,
    info: ChannelInfo,
    required: bool,
    state: State,
    group: Group,
    size: ?u64 = null,
    reason: ?[]const u8 = null,
    derived_from: []const []const u8 = &.{},
    source_sha256: ?[]const u8 = null,
    state_sha256: ?[]const u8 = null,
    profile_id: ?[]const u8 = null,
    profile_sha256: ?[]const u8 = null,
};

pub const Case = struct {
    case_id: []const u8,
    family_id: []const u8,
    universe: Universe,
    recipe_revision: []const u8,
    recipe_sha256: ?[]const u8,
    artifacts: []Artifact,
    dependencies: []const []const u8,
    obligations: []const []const u8,
    state: State,
    reason: ?[]const u8,
    /// SHA256 of the case.json bytes.
    file_sha256: [64]u8,
};

pub const Root = struct {
    value: json.Value,
    release: Release,
    inventory_revision: []const u8,
    case_refs: []CaseRef,
    profiles: []Profile,
    dependencies: []Dependency,
    obligations: []Obligation,
};

fn parseState(f: *Fields, artifact: bool) ?State {
    const s = f.str("acquisition_state") orelse return null;
    const st = std.meta.stringToEnum(State, s) orelse {
        f.d.err("invalid_state", f.where, "acquisition_state `{s}` is not a known state", .{s});
        f.ok = false;
        return null;
    };
    if (artifact and !st.isArtifactState()) {
        f.d.err("invalid_state", f.where, "acquisition_state `{s}` is a case disposition and is invalid for a file entry", .{s});
        f.ok = false;
        return null;
    }
    return st;
}

/// Reason, evidence and hash rules shared by cases, artifacts and dependencies.
fn checkStateFields(f: *Fields, st: State, sha: ?[]const u8, has_sha_field: bool) ?[]const u8 {
    var reason: ?[]const u8 = null;
    if (st.needsReason()) {
        reason = f.optStr("reason");
        const ev = f.optStr("evidence");
        if (reason == null or ev == null) {
            f.d.err("disposition_without_evidence", f.where, "state `{s}` needs non-empty `reason` and `evidence`", .{@tagName(st)});
            f.ok = false;
        }
    }
    if (has_sha_field) {
        if (st.hasBytes() and sha == null) {
            f.d.err("malformed_hash", f.where, "state `{s}` needs a SHA256", .{@tagName(st)});
            f.ok = false;
        }
        if (!st.hasBytes() and sha != null) {
            f.d.err("hash_without_bytes", f.where, "state `{s}` has a SHA256 but no bytes in the pack", .{@tagName(st)});
            f.ok = false;
        }
    }
    return reason;
}

pub fn parseRelease(d: *Diags, v: json.Value, where: []const u8) ?Release {
    var f = Fields.init(d, v, where, "release") orelse return null;
    var r: Release = .{};
    r.version = f.strOrNull("version");
    r.build = f.strOrNull("build");
    r.edition = f.strOrNull("edition");
    r.platform = f.strOrNull("platform");
    const ver = f.str("verification") orelse return null;
    if (std.mem.eql(u8, ver, "verified")) {
        r.verified = true;
        if (r.version == null or r.build == null or r.platform == null) {
            d.err("release_unbound", where, "a verified release needs version, build and platform", .{});
            f.ok = false;
        }
    } else if (!std.mem.eql(u8, ver, "unverified")) {
        d.err("schema_type", where, "verification `{s}` is neither verified nor unverified", .{ver});
        f.ok = false;
    }
    return if (f.ok) r else null;
}

fn parseObligation(a: Allocator, d: *Diags, v: json.Value, where: []const u8) ?Obligation {
    var f = Fields.init(d, v, where, "obligation") orelse return null;
    const oid = f.id("obligation_id");
    const cid = f.id("case_id");
    const mech = f.str("mechanism");
    const chans_v = f.array("required_channels");
    _ = f.present("native_recipe");
    _ = f.present("independent_controls");
    _ = f.present("pairing_rule");
    const disp = f.str("disposition");
    _ = f.present("evidence");
    const owner = f.str("owner");
    var chans: std.ArrayList([]const u8) = .empty;
    if (chans_v) |cv| {
        for (cv) |c| {
            if (c != .string or channelInfo(c.string) == null) {
                d.err("unknown_channel", where, "required_channels holds an entry that is not a registered channel", .{});
                f.ok = false;
                continue;
            }
            chans.append(a, c.string) catch {};
        }
    }
    if (!f.ok) return null;
    return .{ .obligation_id = oid.?, .case_id = cid.?, .mechanism = mech.?, .required_channels = chans.items, .disposition = disp.?, .owner = owner.? };
}

const dependency_kinds = [_][]const u8{ "native_resource", "licensed_resource", "university_sample", "font", "linked_document", "sdk_material", "other" };
const licensed_kinds = [_][]const u8{ "licensed_resource", "university_sample", "font", "sdk_material" };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

fn parseDependency(d: *Diags, v: json.Value, where: []const u8) ?Dependency {
    var f = Fields.init(d, v, where, "dependency") orelse return null;
    const did = f.id("dependency_id");
    const p = f.str("path");
    const sha = f.sha("sha256");
    const st = parseState(&f, true);
    if (p) |pp| {
        if (pathProblem(pp)) |why| {
            d.err("invalid_path", where, "path `{s}`: {s}", .{ pp, why });
            f.ok = false;
        } else if (!std.mem.startsWith(u8, pp, "dependencies/")) {
            d.err("invalid_path", where, "path `{s}` is outside dependencies/", .{pp});
            f.ok = false;
        } else if (credentialName(pp)) {
            d.err("credential_material", where, "path `{s}` names credential or activation material", .{pp});
            f.ok = false;
        }
    }
    var kind: []const u8 = "other";
    if (f.object("provenance")) |prov| {
        var pf = Fields.init(d, prov, where, "provenance").?;
        if (pf.str("kind")) |k| {
            kind = k;
            if (!inList(&dependency_kinds, k)) {
                d.err("schema_type", where, "provenance kind `{s}` is not a known dependency kind", .{k});
                f.ok = false;
            }
        }
        const permitted = pf.boolean("permitted");
        const license = pf.strOrNull("license");
        _ = pf.strOrNull("source");
        if (!pf.ok) f.ok = false;
        if (st != null and st.?.hasBytes() and inList(&licensed_kinds, kind)) {
            if (permitted != true or license == null) {
                d.err("unpermitted_licensed_copy", where, "a copied `{s}` dependency needs permitted true and a license", .{kind});
                f.ok = false;
            }
        }
    }
    if (st) |s| _ = checkStateFields(&f, s, sha, true);
    if (!f.ok) return null;
    return .{ .dependency_id = did.?, .path = p.?, .sha256 = sha, .state = st.?, .kind = kind };
}

fn parseProfile(d: *Diags, v: json.Value, where: []const u8) ?Profile {
    var f = Fields.init(d, v, where, "profile") orelse return null;
    const pid = f.id("profile_id");
    const rev = f.str("profile_revision");
    const sha = f.reqSha("profile_sha256");
    const fmt = f.str("format");
    _ = f.str("format_revision");
    if (f.object("options")) |o| {
        if (!checkFinite(d, o, where)) f.ok = false;
    }
    if (f.object("state_overrides")) |o| {
        if (!checkFinite(d, o, where)) f.ok = false;
    }
    _ = f.present("applicability");
    const p = f.strOrNull("path");
    if (fmt) |ff| {
        if (!inList(&export_formats, ff)) {
            d.err("unknown_channel", where, "format `{s}` is not a registered export format", .{ff});
            f.ok = false;
        }
    }
    if (p) |pp| {
        if (pathProblem(pp)) |why| {
            d.err("invalid_path", where, "path `{s}`: {s}", .{ pp, why });
            f.ok = false;
        } else if (!std.mem.startsWith(u8, pp, "profiles/")) {
            d.err("invalid_path", where, "path `{s}` is outside profiles/", .{pp});
            f.ok = false;
        } else if (credentialName(pp)) {
            d.err("credential_material", where, "path `{s}` names credential or activation material", .{pp});
            f.ok = false;
        }
    }
    if (!f.ok) return null;
    return .{ .profile_id = pid.?, .profile_revision = rev.?, .profile_sha256 = sha.?, .format = fmt.?, .path = p };
}

/// Validates the root manifest fields. Entries with errors are left out of the result.
/// `need_case_hashes` is true for a published MANIFEST.json.
pub fn parseRoot(a: Allocator, d: *Diags, v: json.Value, need_case_hashes: bool) ?Root {
    const where = "root";
    var f = Fields.init(d, v, where, "root manifest") orelse return null;
    if (!f.schema(schema_pack)) return null;
    const rel_v = f.object("release");
    const inv = f.str("inventory_revision");
    const cases_v = f.array("cases") orelse &.{};
    const profiles_v = f.array("profiles") orelse &.{};
    const deps_v = f.array("dependencies") orelse &.{};
    const obl_v = f.array("obligations") orelse &.{};
    const release = if (rel_v) |rv| parseRelease(d, rv, "root.release") else null;

    var refs: std.ArrayList(CaseRef) = .empty;
    for (cases_v, 0..) |cv, i| {
        const w = loc(a, "root.cases[{d}]", .{i});
        var cf = Fields.init(d, cv, w, "case entry") orelse continue;
        const cid = cf.id("case_id");
        const p = cf.str("path");
        const sha = if (need_case_hashes) cf.reqSha("sha256") else cf.sha("sha256");
        if (cid != null and p != null) {
            const want = loc(a, "cases/{s}/case.json", .{cid.?});
            if (!std.mem.eql(u8, want, p.?)) {
                d.err("invalid_path", w, "path `{s}` differs from `{s}`", .{ p.?, want });
                cf.ok = false;
            }
        }
        if (cf.ok) refs.append(a, .{ .case_id = cid.?, .path = p.?, .sha256 = sha }) catch {};
    }
    var profiles: std.ArrayList(Profile) = .empty;
    for (profiles_v, 0..) |pv, i| {
        if (parseProfile(d, pv, loc(a, "root.profiles[{d}]", .{i}))) |p| profiles.append(a, p) catch {};
    }
    var deps: std.ArrayList(Dependency) = .empty;
    for (deps_v, 0..) |dv, i| {
        if (parseDependency(d, dv, loc(a, "root.dependencies[{d}]", .{i}))) |x| deps.append(a, x) catch {};
    }
    var obls: std.ArrayList(Obligation) = .empty;
    for (obl_v, 0..) |ov, i| {
        if (parseObligation(a, d, ov, loc(a, "root.obligations[{d}]", .{i}))) |x| obls.append(a, x) catch {};
    }

    // Colliding IDs of one kind.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (refs.items) |r| collide(a, d, &seen, "case", r.case_id);
    seen = .empty;
    for (profiles.items) |p| collide(a, d, &seen, "profile", p.profile_id);
    seen = .empty;
    for (deps.items) |x| collide(a, d, &seen, "dependency", x.dependency_id);
    seen = .empty;
    for (obls.items) |x| collide(a, d, &seen, "obligation", x.obligation_id);

    return .{
        .value = v,
        .release = release orelse .{},
        .inventory_revision = inv orelse "",
        .case_refs = refs.items,
        .profiles = profiles.items,
        .dependencies = deps.items,
        .obligations = obls.items,
    };
}

fn collide(a: Allocator, d: *Diags, seen: *std.StringHashMapUnmanaged(void), kind: []const u8, id: []const u8) void {
    const key = lowerDup(a, id);
    const gop = seen.getOrPut(a, key) catch return;
    if (gop.found_existing) d.err("colliding_id", loc(a, "{s}:{s}", .{ kind, id }), "{s} ID `{s}` collides with another {s} ID after ASCII lowercase", .{ kind, id, kind });
}

fn parseArtifact(a: Allocator, d: *Diags, v: json.Value, where: []const u8, group: Group) ?Artifact {
    var f = Fields.init(d, v, where, "artifact") orelse return null;
    const aid = f.id("artifact_id");
    const p = f.str("path");
    const sha = f.sha("sha256");
    const ch = f.str("channel");
    const req = f.boolean("required");
    const st = parseState(&f, true);
    const prov = f.object("provenance");
    var info: ?ChannelInfo = null;
    if (ch) |c| {
        info = channelInfo(c);
        if (info == null) {
            d.err("unknown_channel", where, "channel `{s}` is not registered", .{c});
            f.ok = false;
        }
    }
    if (p) |pp| {
        if (pathProblem(pp)) |why| {
            d.err("invalid_path", where, "path `{s}`: {s}", .{ pp, why });
            f.ok = false;
        } else if (credentialName(pp)) {
            d.err("credential_material", where, "path `{s}` names credential or activation material", .{pp});
            f.ok = false;
        } else if (std.mem.eql(u8, pp, "case.json")) {
            d.err("invalid_path", where, "path `case.json` is reserved for the case file", .{});
            f.ok = false;
        } else if (info) |inf| {
            if (dirProblem(inf, pp)) |why| {
                d.err("channel_directory", where, "path `{s}` with channel `{s}`: {s}", .{ pp, ch.?, why });
                f.ok = false;
            }
        }
    }
    var art: Artifact = .{
        .artifact_id = aid orelse "",
        .path = p orelse "",
        .sha256 = sha,
        .channel = ch orelse "",
        .info = info orelse .{ .kind = .raw, .dirs = &.{}, .reader = .none },
        .required = req orelse false,
        .state = st orelse .pending,
        .group = group,
    };
    if (field(v, "size")) |sv| {
        if (intOf(sv)) |n| {
            if (n >= 0) {
                art.size = @intCast(n);
            } else {
                d.err("schema_type", where, "field `size` is negative", .{});
                f.ok = false;
            }
        } else {
            d.err("schema_type", where, "field `size` is not a nonnegative integer", .{});
            f.ok = false;
        }
    }
    if (st) |s| art.reason = checkStateFields(&f, s, sha, true);

    if (prov) |pv| {
        if (info) |inf| {
            if (inf.kind == .normalized and art.state.hasBytes()) {
                const df = field(pv, "derived_from");
                var list: std.ArrayList([]const u8) = .empty;
                if (df != null and df.? == .array) {
                    for (df.?.array.items) |x| {
                        if (x == .string and idProblem(x.string) == null) list.append(a, x.string) catch {};
                    }
                }
                if (list.items.len == 0) {
                    d.err("normalized_without_raw", where, "a normalized artifact needs provenance.derived_from with artifact IDs", .{});
                    f.ok = false;
                }
                art.derived_from = list.items;
            }
        }
        var pf = Fields.init(d, pv, where, "provenance").?;
        if (field(pv, "source_sha256") != null) art.source_sha256 = pf.sha("source_sha256");
        if (field(pv, "state_sha256") != null) art.state_sha256 = pf.sha("state_sha256");
        if (!pf.ok) f.ok = false;
        // Capture writes `fake_driver` and `mixed_driver` for bytes that no single native run produced.
        if (field(pv, "native_verification")) |nv| {
            if (nv == .string and inList(&.{ "fake_driver", "mixed_driver" }, nv.string) and art.state == .acquired) {
                d.err("unverified_driver", where, "provenance.native_verification `{s}` with acquisition_state acquired", .{nv.string});
                f.ok = false;
            }
        }
        if (art.state.hasBytes() and std.mem.startsWith(u8, art.channel, "native_")) {
            if (art.source_sha256 == null) {
                d.err("unbound_native", where, "an acquired native artifact needs provenance.source_sha256", .{});
                f.ok = false;
            }
            if (!std.mem.eql(u8, art.channel, "native_state") and art.state_sha256 == null) {
                d.err("unbound_native", where, "an acquired native artifact needs provenance.state_sha256", .{});
                f.ok = false;
            }
        }
    }

    if (group == .exports) {
        art.profile_id = f.id("profile_id");
        if (info) |inf| {
            if (!inf.isExport()) {
                d.err("channel_group", where, "channel `{s}` is not an export channel", .{art.channel});
                f.ok = false;
            }
        }
        if (art.state.hasBytes()) {
            art.source_sha256 = f.reqSha("source_sha256");
            art.state_sha256 = f.reqSha("state_sha256");
            art.profile_sha256 = f.reqSha("profile_sha256");
            if (f.array("warnings") == null) f.ok = false;
            if (f.present("result")) |r| {
                if (r != .string and r != .object) {
                    d.err("schema_type", where, "field `result` is not a string or an object", .{});
                    f.ok = false;
                }
            }
        }
    } else if (info) |inf| {
        if (inf.isExport()) {
            d.err("channel_group", where, "export channel `{s}` belongs in `exports`", .{art.channel});
            f.ok = false;
        }
    }
    if (!f.ok) return null;
    return art;
}

/// Validates one case file. `file_sha` is the SHA256 of its bytes.
pub fn parseCase(a: Allocator, d: *Diags, v: json.Value, want_id: []const u8, file_sha: [64]u8) ?Case {
    const where = loc(a, "case:{s}", .{want_id});
    var f = Fields.init(d, v, where, "case") orelse return null;
    if (!f.schema(schema_pack)) return null;
    const cid = f.id("case_id");
    if (cid) |c| {
        if (!std.mem.eql(u8, c, want_id)) {
            d.err("case_id_mismatch", where, "case_id `{s}` differs from the root entry", .{c});
            f.ok = false;
        }
    }
    const fam = f.id("family_id");
    const rrev = f.str("recipe_revision");
    const rsha = f.sha("recipe_sha256");
    var universe: Universe = .controlled;
    if (f.optStr("universe")) |u| {
        universe = std.meta.stringToEnum(Universe, u) orelse blk: {
            d.err("schema_type", where, "universe `{s}` is not known", .{u});
            f.ok = false;
            break :blk .controlled;
        };
    }
    if (f.object("parameters")) |pv| {
        if (!checkFinite(d, pv, where)) f.ok = false;
    }
    _ = f.array("history");
    _ = f.array("expected_relationships");
    const st = parseState(&f, false);
    const deps = f.ids(a, "dependencies");
    const obls = f.ids(a, "obligations");
    var reason: ?[]const u8 = null;
    if (st) |s| reason = checkStateFields(&f, s, null, false);

    var arts: std.ArrayList(Artifact) = .empty;
    const groups = [_]struct { name: []const u8, g: Group, required: bool }{
        .{ .name = "sources", .g = .sources, .required = true },
        .{ .name = "native_channels", .g = .native_channels, .required = true },
        .{ .name = "exports", .g = .exports, .required = true },
        .{ .name = "auxiliary", .g = .auxiliary, .required = false },
    };
    for (groups) |g| {
        const arr = (if (g.required) f.array(g.name) else f.optArray(g.name)) orelse continue;
        for (arr, 0..) |x, i| {
            const w = loc(a, "case:{s}.{s}[{d}]", .{ want_id, g.name, i });
            if (parseArtifact(a, d, x, w, g.g)) |art| {
                arts.append(a, art) catch {};
            } else f.ok = false;
        }
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (arts.items) |x| collide(a, d, &seen, loc(a, "artifact of case {s}", .{want_id}), x.artifact_id);

    if (cid == null or fam == null or rrev == null or st == null) return null;
    return .{
        .case_id = cid.?,
        .family_id = fam.?,
        .universe = universe,
        .recipe_revision = rrev.?,
        .recipe_sha256 = rsha,
        .artifacts = arts.items,
        .dependencies = deps,
        .obligations = obls,
        .state = st.?,
        .reason = reason,
        .file_sha256 = file_sha,
    };
}

// ---------------------------------------------------------------------------
// cross references
// ---------------------------------------------------------------------------

pub const Pack = struct {
    root: Root,
    cases: []Case,
    /// SHA256 of the root manifest bytes.
    manifest_sha256: [64]u8,

    pub fn findCase(p: *const Pack, id: []const u8) ?*const Case {
        for (p.cases) |*c| {
            if (std.mem.eql(u8, c.case_id, id)) return c;
        }
        return null;
    }

    pub fn findProfile(p: *const Pack, id: []const u8) ?*const Profile {
        for (p.root.profiles) |*x| {
            if (std.mem.eql(u8, x.profile_id, id)) return x;
        }
        return null;
    }

    pub fn findDependency(p: *const Pack, id: []const u8) ?*const Dependency {
        for (p.root.dependencies) |*x| {
            if (std.mem.eql(u8, x.dependency_id, id)) return x;
        }
        return null;
    }

    pub fn findObligation(p: *const Pack, id: []const u8) ?*const Obligation {
        for (p.root.obligations) |*x| {
            if (std.mem.eql(u8, x.obligation_id, id)) return x;
        }
        return null;
    }
};

fn findArtifact(c: *const Case, id: []const u8) ?*const Artifact {
    for (c.artifacts) |*x| {
        if (std.mem.eql(u8, x.artifact_id, id)) return x;
    }
    return null;
}

/// True when an artifact of `channel` in case `c` holds acquired bytes.
fn channelAcquired(c: *const Case, channel: []const u8) bool {
    for (c.artifacts) |x| {
        if (x.state == .acquired and std.mem.eql(u8, x.channel, channel)) return true;
    }
    return false;
}

fn isBindingSource(x: *const Artifact) bool {
    return x.state == .acquired and (std.mem.eql(u8, x.channel, "source_reopened") or std.mem.eql(u8, x.channel, "source_derivative"));
}

fn hasSourceHash(c: *const Case, sha: []const u8) bool {
    for (c.artifacts) |*x| {
        if (isBindingSource(x) and std.mem.eql(u8, x.sha256.?, sha)) return true;
    }
    return false;
}

fn hasStateHash(c: *const Case, sha: []const u8) bool {
    for (c.artifacts) |x| {
        if (x.state == .acquired and std.mem.eql(u8, x.channel, "native_state") and std.mem.eql(u8, x.sha256.?, sha)) return true;
    }
    return false;
}

/// Pack-relative path of an artifact.
pub fn artifactPackPath(a: Allocator, c: *const Case, x: *const Artifact) []const u8 {
    return loc(a, "cases/{s}/{s}", .{ c.case_id, x.path });
}

/// Paths of the `recipe` artifact. Inventory skeletons write `recipe/recipe.json`. Capture
/// existing-document skeletons write `recipe/spec.json`.
const recipe_paths = [_][]const u8{ "recipe/recipe.json", "recipe/spec.json" };

/// Binds `recipe_sha256` to the one `recipe` artifact of the case. The file check compares that
/// artifact SHA256 with its bytes. A case with `recipe_sha256` null needs no `recipe` artifact.
/// The acquired synthetic cases of native-prep `check.zig` have that form.
fn checkRecipe(a: Allocator, d: *Diags, c: *const Case, cw: []const u8) void {
    var recipe: ?*const Artifact = null;
    for (c.artifacts) |*x| {
        const aw = loc(a, "case:{s}/{s}", .{ c.case_id, x.artifact_id });
        if (std.mem.eql(u8, x.channel, "recipe_checkpoint")) {
            if (inList(&recipe_paths, x.path)) d.err("recipe_path", aw, "recipe_checkpoint path `{s}` is a recipe path", .{x.path});
            continue;
        }
        if (!std.mem.eql(u8, x.channel, "recipe")) continue;
        if (recipe) |first| {
            d.err("recipe_duplicate", aw, "case has a second `recipe` artifact. The first is `{s}`", .{first.artifact_id});
            continue;
        }
        recipe = x;
        if (!inList(&recipe_paths, x.path)) d.err("recipe_path", aw, "recipe path `{s}` is neither recipe/recipe.json nor recipe/spec.json", .{x.path});
        if (x.state.hasBytes()) {
            if (c.recipe_sha256 == null or !std.mem.eql(u8, c.recipe_sha256.?, x.sha256.?)) d.err("recipe_hash_mismatch", aw, "recipe artifact SHA256 differs from recipe_sha256", .{});
        }
    }
    if (c.recipe_sha256 == null) return;
    const r = recipe orelse return d.err("recipe_missing", cw, "recipe_sha256 is set and the case has no artifact with channel `recipe`", .{});
    if (!r.state.hasBytes()) d.err("recipe_missing", cw, "recipe_sha256 is set and recipe artifact `{s}` is `{s}`", .{ r.artifact_id, @tagName(r.state) });
}

/// Checks references between root entries and cases. It reads no files.
pub fn crossCheck(a: Allocator, d: *Diags, p: *const Pack) void {
    // Paths of one pack: collisions and a file path used as a directory.
    var paths: std.StringHashMapUnmanaged([]const u8) = .empty;
    const addPath = struct {
        fn f(al: Allocator, dd: *Diags, m: *std.StringHashMapUnmanaged([]const u8), path: []const u8) void {
            const key = lowerDup(al, path);
            const gop = m.getOrPut(al, key) catch return;
            if (gop.found_existing) {
                dd.err("colliding_path", path, "path collides with `{s}` after ASCII lowercase", .{gop.value_ptr.*});
            } else gop.value_ptr.* = path;
        }
    }.f;
    for (generated_reports ++ [_][]const u8{ manifest_name, sums_name, subset_name, measurements_name, input_root_name }) |g| addPath(a, d, &paths, g);
    for (p.root.profiles) |x| {
        if (x.path) |pp| addPath(a, d, &paths, pp);
    }
    for (p.root.dependencies) |x| addPath(a, d, &paths, x.path);
    for (p.root.case_refs) |r| addPath(a, d, &paths, r.path);
    for (p.cases) |*c| {
        for (c.artifacts) |*x| addPath(a, d, &paths, artifactPackPath(a, c, x));
    }
    var it = paths.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, k, i, '/')) |slash| : (i = slash + 1) {
            if (paths.get(k[0..slash])) |other| d.err("colliding_path", e.value_ptr.*, "a parent directory has the same name as file `{s}`", .{other});
        }
    }

    // Root obligations name registered channels. A missing case is a report status.
    for (p.cases) |*c| {
        const cw = loc(a, "case:{s}", .{c.case_id});
        for (c.dependencies) |dep_id| {
            const dep = p.findDependency(dep_id) orelse {
                d.err("missing_dependency", cw, "dependency `{s}` is not in the root manifest", .{dep_id});
                continue;
            };
            if (c.state == .acquired and dep.state != .acquired) d.err("dependency_not_acquired", cw, "acquired case needs dependency `{s}`, which is `{s}`", .{ dep_id, @tagName(dep.state) });
        }
        for (c.obligations) |oid| {
            const o = p.findObligation(oid) orelse {
                d.err("unknown_obligation", cw, "obligation `{s}` is not in the root manifest", .{oid});
                continue;
            };
            if (!std.mem.eql(u8, o.case_id, c.case_id)) d.err("obligation_case_mismatch", cw, "obligation `{s}` belongs to case `{s}`", .{ oid, o.case_id });
        }
        checkRecipe(a, d, c, cw);
        checkBundleLayout(a, d, c);
        if (c.state == .acquired) {
            if (!hasAcquiredEvidence(c)) d.err("acquired_without_evidence", cw, "acquired case has no required artifact in state `acquired`", .{});
            for (c.artifacts) |x| {
                if (x.required and x.state != .acquired) d.err("required_channel_absent", cw, "required artifact `{s}` (channel `{s}`) is `{s}`", .{ x.artifact_id, x.channel, @tagName(x.state) });
            }
            for (p.root.obligations) |o| {
                if (!std.mem.eql(u8, o.case_id, c.case_id)) continue;
                for (o.required_channels) |ch| {
                    if (!channelAcquired(c, ch)) d.err("required_channel_absent", cw, "obligation `{s}` needs channel `{s}`, which has no acquired artifact", .{ o.obligation_id, ch });
                }
            }
        }
        for (c.artifacts) |*x| {
            const aw = loc(a, "case:{s}/{s}", .{ c.case_id, x.artifact_id });
            for (x.derived_from) |src_id| {
                const src = findArtifact(c, src_id) orelse {
                    d.err("normalized_without_raw", aw, "derived_from names `{s}`, which is not an artifact of the case", .{src_id});
                    continue;
                };
                if (src.info.kind == .normalized) d.err("normalized_without_raw", aw, "derived_from names normalized artifact `{s}`", .{src_id});
            }
            if (x.state.hasBytes() and (std.mem.startsWith(u8, x.channel, "native_") or x.group == .exports)) {
                if (x.source_sha256) |s| {
                    if (!hasSourceHash(c, s)) d.err("stale_source_binding", aw, "source_sha256 matches no acquired source_reopened or source_derivative artifact", .{});
                }
                if (x.state_sha256) |s| {
                    if (!hasStateHash(c, s)) d.err("stale_state_binding", aw, "state_sha256 matches no acquired native_state artifact", .{});
                }
            }
            if (x.group == .exports) {
                const pid = x.profile_id orelse continue;
                const prof = p.findProfile(pid) orelse {
                    d.err("unknown_profile", aw, "profile `{s}` is not in the root manifest", .{pid});
                    continue;
                };
                if (x.info.export_format) |fmt| {
                    if (!std.mem.eql(u8, fmt, prof.format)) d.err("profile_format_mismatch", aw, "channel format `{s}` differs from profile format `{s}`", .{ fmt, prof.format });
                }
                if (x.state.hasBytes()) {
                    if (x.profile_sha256) |ps| {
                        if (!std.mem.eql(u8, ps, prof.profile_sha256)) d.err("stale_profile_binding", aw, "profile_sha256 differs from profile `{s}`", .{pid});
                    }
                    if (prof.path == null) d.err("profile_unhashed", aw, "profile `{s}` has no file in the pack", .{pid});
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// frames and measurements
// ---------------------------------------------------------------------------

const length_units = [_][]const u8{ "mm", "cm", "m", "in", "ft" };

const Dim = enum { length, area, volume, angle, dimensionless, none };

const Quantity = enum {
    point3,
    vector3,
    direction3,
    bounds3,
    transform4x4,
    length,
    radius,
    area,
    volume,
    angle,
    control_points,
    knots,
    weights,
    domain,
    count,
    topology_counts,
    visibility,
    name,
    class_name,
    layer_name,

    fn dim(q: Quantity) Dim {
        return switch (q) {
            .point3, .vector3, .bounds3, .transform4x4, .length, .radius, .control_points => .length,
            .area => .area,
            .volume => .volume,
            .angle => .angle,
            .direction3, .knots, .weights, .domain, .count, .topology_counts => .dimensionless,
            .visibility, .name, .class_name, .layer_name => .none,
        };
    }
};

pub const FrameInfo = struct {
    units: ?[]const u8,
    path: []const u8,
};

/// Measurement references are resolved once every file of the case has been read,
/// so the order of files in a directory or an archive does not matter.
const RefKey = struct {
    frame_id: []const u8,
    units: []const u8,
    dim: Dim,
};

const IdentityAt = struct { path: []const u8, line_no: usize };

pub const CaseContent = struct {
    frames: std.StringHashMapUnmanaged(FrameInfo) = .empty,
    refs: std.ArrayList(struct { key: RefKey, count: u64, path: []const u8 }) = .empty,
    source_hashes: std.StringHashMapUnmanaged([]const u8) = .empty,
    state_hashes: std.StringHashMapUnmanaged([]const u8) = .empty,
    raw_ids: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// SHA256 of each accepted component-bearing identity, with the record that holds it.
    identities: std.AutoHashMapUnmanaged([32]u8, IdentityAt) = .empty,
    records: u64 = 0,
    measured: u64 = 0,
    gaps: u64 = 0,
    rejected: u64 = 0,
    /// Parsed bundle manifests and seals of the case, by case-relative path and directory.
    bundle_manifests: std.ArrayList(struct { path: []const u8, manifest: BundleManifest }) = .empty,
    bundle_seals: std.ArrayList(struct { dir: []const u8, seal: BundleSeal }) = .empty,
    bundle_refs: std.ArrayList(RefFound) = .empty,
    /// Byte counts that the readers counted, by pack path.
    file_sizes: std.StringHashMapUnmanaged(u64) = .empty,

    fn addRef(cc: *CaseContent, a: Allocator, key: RefKey, path: []const u8) void {
        for (cc.refs.items) |*r| {
            if (r.key.dim == key.dim and std.mem.eql(u8, r.key.frame_id, key.frame_id) and std.mem.eql(u8, r.key.units, key.units) and std.mem.eql(u8, r.path, path)) {
                r.count += 1;
                return;
            }
        }
        const k: RefKey = .{ .frame_id = a.dupe(u8, key.frame_id) catch return, .units = a.dupe(u8, key.units) catch return, .dim = key.dim };
        cc.refs.append(a, .{ .key = k, .count = 1, .path = path }) catch {};
    }

    fn addOnce(m: *std.StringHashMapUnmanaged([]const u8), a: Allocator, key: []const u8, path: []const u8) void {
        if (m.contains(key)) return;
        m.put(a, a.dupe(u8, key) catch return, path) catch {};
    }
};

fn numbersOf(v: json.Value, out: []f64) bool {
    if (v != .array or v.array.items.len != out.len) return false;
    for (v.array.items, 0..) |x, i| out[i] = numberOf(x) orelse return false;
    return true;
}

/// How a native API lays out a 4-number control point.
/// `cartesian` points have 3 numbers. `cartesian_weight` is x y z w with x y z in model space.
/// `homogeneous` is wx wy wz w. The module keeps the convention that the native API reports.
const PointConvention = enum {
    cartesian,
    cartesian_weight,
    homogeneous,

    fn width(c: PointConvention) usize {
        return if (c == .cartesian) 3 else 4;
    }
};

fn affineLastRow(m: []const f64) bool {
    return m[12] == 0 and m[13] == 0 and m[14] == 0 and m[15] == 1;
}

/// Checks a value against its quantity. Null when valid. Otherwise the reason.
fn valueProblem(q: Quantity, v: json.Value, conv: ?PointConvention) ?[]const u8 {
    var buf: [16]f64 = undefined;
    switch (q) {
        .point3, .vector3 => if (!numbersOf(v, buf[0..3])) return "needs 3 numbers",
        .direction3 => {
            if (!numbersOf(v, buf[0..3])) return "needs 3 numbers";
            if (buf[0] == 0 and buf[1] == 0 and buf[2] == 0) return "is the zero vector";
        },
        .bounds3 => {
            if (!numbersOf(v, buf[0..6])) return "needs 6 numbers";
            for (0..3) |i| {
                if (buf[i] > buf[i + 3]) return "minimum exceeds maximum";
            }
        },
        .transform4x4 => {
            if (!numbersOf(v, buf[0..16])) return "needs 16 numbers";
            if (!affineLastRow(buf[0..16])) return "last row is not 0 0 0 1";
        },
        .length, .radius, .angle => if (numberOf(v) == null) return "needs a number",
        .area, .volume => {
            const x = numberOf(v) orelse return "needs a number";
            if (x < 0) return "is negative";
        },
        .control_points => {
            if (v != .array or v.array.items.len == 0) return "needs a non-empty list of points";
            const c = conv orelse return "needs point_convention";
            const width = c.width();
            for (v.array.items) |p| {
                if (!numbersOf(p, buf[0..width])) return if (width == 3) "has a point that is not 3 numbers, as cartesian needs" else "has a point that is not 4 numbers, as cartesian_weight and homogeneous need";
                if (width == 4 and !(buf[3] > 0)) return "has a point weight at most 0";
            }
        },
        .knots => {
            if (v != .array or v.array.items.len == 0) return "needs a non-empty list";
            var prev: f64 = -std.math.inf(f64);
            for (v.array.items) |x| {
                const k = numberOf(x) orelse return "holds a value other than a number";
                if (k < prev) return "decreases";
                prev = k;
            }
        },
        .weights => {
            if (v != .array or v.array.items.len == 0) return "needs a non-empty list";
            for (v.array.items) |x| {
                const w = numberOf(x) orelse return "holds a value other than a number";
                if (!(w > 0)) return "holds a weight at most 0";
            }
        },
        .domain => {
            if (!numbersOf(v, buf[0..2])) return "needs 2 numbers";
            if (buf[0] > buf[1]) return "start exceeds end";
        },
        .count => {
            const n = intOf(v) orelse return "needs an integer";
            if (n < 0) return "is negative";
        },
        .topology_counts => {
            if (v != .object) return "needs an object";
            var it = v.object.iterator();
            while (it.next()) |e| {
                const n = intOf(e.value_ptr.*) orelse return "holds a value other than an integer";
                if (n < 0) return "holds a negative count";
            }
        },
        .visibility => if (v != .bool) return "needs a boolean",
        .name, .class_name, .layer_name => if (v != .string) return "needs a string",
    }
    return null;
}

fn unitsProblem(dim: Dim, units: []const u8) ?[]const u8 {
    switch (dim) {
        .length => if (!inList(&length_units, units)) return "is not mm, cm, m, in or ft",
        .area, .volume => {
            const suffix: u8 = if (dim == .area) '2' else '3';
            if (units.len < 2 or units[units.len - 1] != suffix or !inList(&length_units, units[0 .. units.len - 1])) return "is not a length unit with the dimension suffix";
        },
        .angle => if (!(std.mem.eql(u8, units, "deg") or std.mem.eql(u8, units, "rad"))) return "is not deg or rad",
        .dimensionless => if (!std.mem.eql(u8, units, "1")) return "is not 1",
        .none => if (!std.mem.eql(u8, units, "none")) return "is not none",
    }
    return null;
}

const max_measure_component_bytes: usize = 64;

/// Parses a decimal index of 1 to 10 ASCII digits with no leading zero, at most `maxInt(u32)`.
/// `std.fmt.parseInt` also accepts `+` and `_`, which would give one index two spellings.
fn componentIndex(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 10) return null;
    if (s.len > 1 and s[0] == '0') return null;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    return std.math.cast(u32, n);
}

fn indexAfter(comp: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, comp, prefix)) return null;
    return componentIndex(comp[prefix.len..]);
}

/// Text values of component-bearing `name`, `class_name` and `layer_name` records.
const max_measure_text_bytes: usize = 1024;

/// `GetTypeN` returns a `TDType`. `vwx/sdk/Objs.TDType.2026.h` declares `typedef Sint8 TDType`.
const max_type_code: i64 = std.math.maxInt(i8);

/// The component registry, revision 4. Revision 2 is the union of the components that native-prep
/// bb052f33 `check emit` and capture 19b34037 `RawNorm.put` write. Revision 3 adds the documented
/// returns of vs.GetArc, vs.GetGISOriginN and vs.GetRRDiam. Revision 4 adds count and angle `""`,
/// which commit 175366da accepted, the named cardinalities and `document.angle_to_north`.
/// Null when `comp` and `value` fit `q`. `valueProblem` has already accepted `value` for `q`.
fn componentProblem(q: Quantity, comp: []const u8, value: json.Value) ?[]const u8 {
    if (comp.len > max_measure_component_bytes) return "component exceeds 64 bytes";
    switch (q) {
        .volume => if (comp.len != 0) return "volume takes the empty component",
        .visibility => if (!inList(&.{ "", "object", "class", "layer" }, comp))
            return "visibility component is not empty, object, class or layer",
        .name, .class_name, .layer_name => {
            if (comp.len != 0) return "name, class_name and layer_name take the empty component";
            if (value.string.len > max_measure_text_bytes) return "text exceeds 1024 bytes";
            for (value.string) |ch| {
                if (ch < 0x20 or ch == 0x7f) return "text holds an ASCII control character";
            }
        },
        .topology_counts => {
            if (comp.len != 0) return "topology_counts takes the empty component";
            if (value.object.count() != 1) return "topology_counts holds keys other than type_code";
            const t = intOf(value.object.get("type_code") orelse return "topology_counts has no type_code").?;
            if (t > max_type_code) return "type_code exceeds 127, the TDType maximum";
        },
        .count => {
            const n = intOf(value).?;
            if (inList(&.{ "degree", "degree_u", "degree_v", "degree.u", "degree.v" }, comp)) {
                if (n < 1) return "degree is below 1";
                if (n > std.math.maxInt(u32)) return "degree exceeds 4294967295";
            } else if (std.mem.eql(u8, comp, "mesh.vertices")) {
                if (n > std.math.maxInt(u32)) return "mesh.vertices exceeds 4294967295";
            } else if (inList(&.{ "members", "classes", "objects", "vertices", "records" }, comp)) {
                // MaxLongInt, the largest LONGINT, in SDK2026 SDKLib/Include/Kernel/Math/MathCoordTypes.h.
                if (n > std.math.maxInt(i32)) return "named count exceeds 2147483647";
            } else if (std.mem.eql(u8, comp, "crop_objects")) {
                // vs.GetVPCropObject returns one handle.
                if (n > 1) return "crop_objects exceeds 1";
            } else if (comp.len != 0) return "count component is not empty, degree, degree_u, degree_v, degree.u, degree.v, mesh.vertices, members, classes, objects, vertices, records or crop_objects";
        },
        .angle => if (!inList(&.{ "", "symbol.rot", "arc.start_angle", "arc.sweep_angle", "gis.angle_to_north", "document.angle_to_north" }, comp))
            return "angle component is not empty, symbol.rot, arc.start_angle, arc.sweep_angle, gis.angle_to_north or document.angle_to_north",
        .length => {
            // vs.GetRRDiam returns the corner diameters. A diameter stays a length. The radius quantity has no component.
            if (inList(&.{ "rrect.diam.x", "rrect.diam.y" }, comp)) {
                if (numberOf(value).? < 0) return "rrect.diam is negative";
            } else if (!inList(&.{
                "wall.p1.x",             "wall.p1.y",                "wall.p1.z",           "wall.p2.x",
                "wall.p2.y",             "wall.p2.z",                "wall.thickness",      "wall.height",
                "wall.height.start_top", "wall.height.start_bottom", "wall.height.end_top", "wall.height.end_bottom",
            }, comp)) return "length component is not a wall axis, wall.thickness, wall.height, a wall.height part, rrect.diam.x or rrect.diam.y";
        },
        .point3 => if (!inList(&.{ "symbol.loc3d", "center" }, comp) and indexAfter(comp, "vertex:") == null and indexAfter(comp, "mesh.vertex:") == null)
            return "point3 component is not symbol.loc3d, center, vertex:<i> or mesh.vertex:<i>",
        .knots => if (!std.mem.eql(u8, comp, "u") and !std.mem.eql(u8, comp, "v") and indexAfter(comp, "piece:") == null)
            return "knots component is not u, v or piece:<i>",
        .control_points, .weights => {
            if (std.mem.startsWith(u8, comp, "piece:")) {
                if (indexAfter(comp, "piece:") == null) return "piece index is not a decimal from 0 to 4294967295 without a leading zero";
            } else if (std.mem.startsWith(u8, comp, "net:")) {
                const rest = comp["net:".len..];
                const x = std.mem.indexOfScalar(u8, rest, 'x') orelse return "net component is not net:<nu>x<nv>";
                const nu = componentIndex(rest[0..x]) orelse return "net u count is not a decimal from 1 to 4294967295 without a leading zero";
                const nv = componentIndex(rest[x + 1 ..]) orelse return "net v count is not a decimal from 1 to 4294967295 without a leading zero";
                if (nu == 0 or nv == 0) return "net count is 0";
                const size = std.math.mul(u64, nu, nv) catch return "net size overflows";
                if (value != .array or value.array.items.len != size) return "the value length differs from nu * nv of the net component";
            } else return "control_points and weights components are piece:<i> or net:<nu>x<nv>";
        },
        else => return "quantity has no component in the registry",
    }
    return null;
}

/// The identity spelling of a registered component. Capture writes `degree.u` and `degree.v`.
/// Native-prep writes `degree_u` and `degree_v` for the same NurbsDegree directions.
fn canonicalComponent(comp: []const u8) []const u8 {
    if (std.mem.eql(u8, comp, "degree.u")) return "degree_u";
    if (std.mem.eql(u8, comp, "degree.v")) return "degree_v";
    return comp;
}

/// Hashes the identity of a component-bearing record. Each field is length-prefixed, so
/// `["a.b"]` and `["a", "b"]` give different identities.
fn componentIdentity(object_id: []const u8, occ: []const json.Value, quantity: []const u8, comp: []const u8, frame_id: []const u8) [32]u8 {
    var h: Sha256 = .init(.{});
    const part = struct {
        fn f(hh: *Sha256, b: []const u8) void {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, b.len, .little);
            hh.update(&len);
            hh.update(b);
        }
    }.f;
    part(&h, object_id);
    var n: [8]u8 = undefined;
    std.mem.writeInt(u64, &n, occ.len, .little);
    h.update(&n);
    for (occ) |x| part(&h, x.string);
    part(&h, quantity);
    part(&h, comp);
    part(&h, frame_id);
    return h.finalResult();
}

/// Checks one measurement record. Valid references are added to `cc`.
fn checkMeasurement(a: Allocator, scratch: Allocator, d: *Diags, cc: *CaseContent, case_id: []const u8, path: []const u8, line_no: usize, v: json.Value) void {
    cc.records += 1;
    const where = loc(scratch, "{s}:{d}", .{ path, line_no });
    var sd = Diags.init(scratch);
    var f = Fields.init(&sd, v, where, "measurement record") orelse {
        rejectRecord(a, d, cc, &sd);
        return;
    };
    const cid = f.str("case_id");
    const src = f.reqSha("source_sha256");
    const st = f.reqSha("state_sha256");
    const object_id = f.str("object_id");
    const occ = f.array("occurrence_path");
    if (occ) |op| {
        for (op) |x| {
            if (x != .string) {
                sd.err("schema_type", where, "occurrence_path holds a value other than a string", .{});
                f.ok = false;
                break;
            }
        }
    }
    const qs = f.str("quantity");
    var conv: ?PointConvention = null;
    if (field(v, "point_convention")) |pc| {
        conv = if (pc == .string) std.meta.stringToEnum(PointConvention, pc.string) else null;
        if (conv == null) {
            sd.err("schema_type", where, "point_convention is not cartesian, cartesian_weight or homogeneous", .{});
            f.ok = false;
        }
    }
    const frame_id = f.id("frame_id");
    // `component` is optional. A record without it keeps the revision 1 rules and has no identity.
    var comp: ?[]const u8 = null;
    if (field(v, "component")) |c| {
        if (c == .string) comp = c.string else {
            sd.err("component_shape", where, "component is not a string", .{});
            f.ok = false;
        }
    }
    const units_v = f.present("units");
    const value = f.present("value");
    var raw_id: ?[]const u8 = null;
    if (f.object("provenance")) |pv| {
        var pf = Fields.init(&sd, pv, where, "provenance").?;
        _ = pf.str("api");
        _ = pf.str("api_version");
        raw_id = pf.id("raw_artifact_id");
        if (!pf.ok) f.ok = false;
    }
    if (cid) |c| {
        if (!std.mem.eql(u8, c, case_id)) {
            sd.err("case_id_mismatch", where, "case_id `{s}` differs from the case", .{c});
            f.ok = false;
        }
    }
    var q: ?Quantity = null;
    if (qs) |s| {
        q = std.meta.stringToEnum(Quantity, s);
        if (q == null) {
            sd.err("unknown_quantity", where, "quantity `{s}` is not registered", .{s});
            f.ok = false;
        }
    }
    if (value) |val| {
        if (!checkFinite(&sd, val, where)) f.ok = false;
        if (q) |qq| {
            if (f.ok) {
                if (qq != .control_points and conv != null) {
                    sd.err("schema_type", where, "point_convention applies to control_points only", .{});
                    f.ok = false;
                } else if (valueProblem(qq, val, conv)) |why| {
                    sd.err("invalid_value", where, "{s} value {s}", .{ @tagName(qq), why });
                    f.ok = false;
                } else if (comp) |c| {
                    if (componentProblem(qq, c, val)) |why| {
                        sd.err("component_shape", where, "component `{s}`: {s}", .{ c, why });
                        f.ok = false;
                    }
                }
            }
        }
    }
    var units: ?[]const u8 = null;
    if (units_v) |u| {
        switch (u) {
            .null => {},
            .string => |s| units = s,
            else => {
                sd.err("schema_type", where, "field `units` is not null or a string", .{});
                f.ok = false;
            },
        }
    }
    if (units != null and q != null) {
        if (unitsProblem(q.?.dim(), units.?)) |why| {
            sd.err("inconsistent_units", where, "units `{s}` for {s} {s}", .{ units.?, @tagName(q.?), why });
            f.ok = false;
        }
    }
    if (!f.ok or q == null or frame_id == null) {
        rejectRecord(a, d, cc, &sd);
        return;
    }
    if (comp) |c| {
        const key = componentIdentity(object_id.?, occ.?, qs.?, canonicalComponent(c), frame_id.?);
        const gop = cc.identities.getOrPut(a, key) catch {
            sd.err("out_of_memory", where, "cannot record the component identity", .{});
            rejectRecord(a, d, cc, &sd);
            return;
        };
        if (gop.found_existing) {
            sd.err("duplicate_identity", where, "object_id, occurrence_path, quantity, component and frame_id equal the record at {s}:{d}", .{ gop.value_ptr.path, gop.value_ptr.line_no });
            rejectRecord(a, d, cc, &sd);
            return;
        }
        gop.value_ptr.* = .{ .path = path, .line_no = line_no };
    }
    CaseContent.addOnce(&cc.source_hashes, a, src.?, path);
    CaseContent.addOnce(&cc.state_hashes, a, st.?, path);
    if (raw_id) |r| CaseContent.addOnce(&cc.raw_ids, a, r, path);
    if (units == null) {
        cc.gaps += 1;
        return;
    }
    cc.addRef(a, .{ .frame_id = frame_id.?, .units = units.?, .dim = q.?.dim() }, path);
}

/// Copies the first diagnostic of a rejected record. A file of bad records reports each
/// distinct code once per file plus a count, so one malformed export cannot flood the report.
fn rejectRecord(a: Allocator, d: *Diags, cc: *CaseContent, sd: *Diags) void {
    cc.rejected += 1;
    if (sd.list.items.len == 0) return;
    const x = sd.list.items[0];
    for (d.list.items) |y| {
        if (std.mem.eql(u8, y.code, x.code) and std.mem.startsWith(u8, x.location, y.location[0 .. std.mem.lastIndexOfScalar(u8, y.location, ':') orelse y.location.len])) return;
    }
    d.list.append(d.arena, .{
        .severity = x.severity,
        .code = x.code,
        .location = a.dupe(u8, x.location) catch "",
        .message = a.dupe(u8, x.message) catch "",
    }) catch {};
}

const frame_kinds = [_][]const u8{ "document_world", "layer", "object_local", "working_plane", "export", "other" };

/// Checks a frame sidecar and adds its frames to `cc`.
fn checkFrames(a: Allocator, d: *Diags, cc: *CaseContent, case_id: []const u8, path: []const u8, v: json.Value) void {
    var f = Fields.init(d, v, path, "frame sidecar") orelse return;
    if (!f.schema(schema_frames)) return;
    if (f.str("case_id")) |c| {
        if (!std.mem.eql(u8, c, case_id)) d.err("case_id_mismatch", path, "case_id `{s}` differs from the case", .{c});
    }
    if (f.reqSha("source_sha256")) |s| CaseContent.addOnce(&cc.source_hashes, a, s, path);
    if (f.str("transform_convention")) |tc| {
        if (!std.mem.eql(u8, tc, "row_major_child_to_parent")) d.err("schema_type", path, "transform_convention `{s}` is not row_major_child_to_parent", .{tc});
    }
    const frames = f.array("frames") orelse return;
    var parents: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    for (frames, 0..) |fv, i| {
        const w = loc(a, "{s}:frames[{d}]", .{ path, i });
        var ff = Fields.init(d, fv, w, "frame") orelse continue;
        const fid = ff.id("frame_id") orelse continue;
        const parent = ff.strOrNull("parent");
        if (ff.str("kind")) |k| {
            if (!inList(&frame_kinds, k)) d.err("schema_type", w, "frame kind `{s}` is not known", .{k});
        }
        const units = ff.strOrNull("units");
        if (units) |u| {
            if (!inList(&length_units, u)) d.err("inconsistent_units", w, "frame units `{s}` is not mm, cm, m, in or ft", .{u});
        }
        if (ff.present("transform")) |t| {
            if (parent == null) {
                if (t != .null) d.err("invalid_value", w, "a root frame has a null transform", .{});
            } else {
                var m: [16]f64 = undefined;
                if (!checkFinite(d, t, w)) {} else if (!numbersOf(t, &m)) {
                    d.err("invalid_value", w, "transform needs 16 numbers", .{});
                } else if (!affineLastRow(&m)) d.err("invalid_value", w, "transform last row is not 0 0 0 1", .{});
            }
        }
        if (cc.frames.contains(fid)) {
            d.err("colliding_id", w, "frame `{s}` is defined twice", .{fid});
            continue;
        }
        // `v` lives in the scratch arena of the Sink. The frame table outlives it.
        const key = a.dupe(u8, fid) catch return;
        cc.frames.put(a, key, .{ .units = if (units) |u| a.dupe(u8, u) catch null else null, .path = path }) catch {};
        parents.put(a, key, if (parent) |p| a.dupe(u8, p) catch null else null) catch {};
    }
    var it = parents.iterator();
    while (it.next()) |e| {
        var cur = e.value_ptr.*;
        var steps: usize = 0;
        while (cur) |p| : (steps += 1) {
            if (steps > parents.count()) {
                d.err("frame_cycle", path, "frame `{s}` has a cycle in its parent links", .{e.key_ptr.*});
                break;
            }
            cur = parents.get(p) orelse {
                d.err("unknown_frame", path, "frame `{s}` names parent `{s}`, which is not in the file", .{ e.key_ptr.*, p });
                break;
            };
        }
    }
}

/// Resolves the references collected from the content of case `c`.
fn resolveContent(a: Allocator, d: *Diags, c: *const Case, cc: *CaseContent) void {
    for (cc.refs.items) |r| {
        const fi = cc.frames.get(r.key.frame_id) orelse {
            d.err("unknown_frame", r.path, "{d} records name frame `{s}`, which no native_frames file of case `{s}` defines", .{ r.count, r.key.frame_id, c.case_id });
            cc.rejected += r.count;
            continue;
        };
        const fu = fi.units orelse {
            d.add(.gap, "unknown_units", r.path, "{d} records use frame `{s}`, whose units are unknown", .{ r.count, r.key.frame_id });
            cc.gaps += r.count;
            continue;
        };
        // Scalar area and volume units have their own schema checks and document preferences.
        const ok = switch (r.key.dim) {
            .length => std.mem.eql(u8, r.key.units, fu),
            else => true,
        };
        if (!ok) {
            d.err("inconsistent_units", r.path, "{d} records use units `{s}` in frame `{s}`, whose units are `{s}`", .{ r.count, r.key.units, r.key.frame_id, fu });
            cc.rejected += r.count;
            continue;
        }
        cc.measured += r.count;
    }
    var it = cc.source_hashes.iterator();
    while (it.next()) |e| {
        if (!hasSourceHash(c, e.key_ptr.*)) d.err("stale_source_binding", e.value_ptr.*, "source_sha256 {s} matches no acquired source_reopened or source_derivative artifact", .{e.key_ptr.*});
    }
    it = cc.state_hashes.iterator();
    while (it.next()) |e| {
        if (!hasStateHash(c, e.key_ptr.*)) d.err("stale_state_binding", e.value_ptr.*, "state_sha256 {s} matches no acquired native_state artifact", .{e.key_ptr.*});
    }
    it = cc.raw_ids.iterator();
    while (it.next()) |e| {
        const x = findArtifact(c, e.key_ptr.*);
        if (x == null or x.?.info.kind != .raw or x.?.state != .acquired) d.err("normalized_without_raw", e.value_ptr.*, "raw_artifact_id `{s}` is not an acquired raw artifact of the case", .{e.key_ptr.*});
    }
    for (c.artifacts) |*x| {
        if (!isManifestArtifact(x) or !x.state.hasBytes() or !std.mem.eql(u8, baseOf(x.path), bundle_manifest_file)) continue;
        const dir = bundleDirOf(x.path) orelse continue;
        var bm: ?BundleManifest = null;
        for (cc.bundle_manifests.items) |r| {
            if (std.mem.eql(u8, r.path, x.path)) bm = r.manifest;
        }
        var seal: ?BundleSeal = null;
        for (cc.bundle_seals.items) |r| {
            if (std.mem.eql(u8, r.dir, dir)) seal = r.seal;
        }
        if (bm) |m| checkBundle(a, d, c, cc, x, m, seal);
    }
}

// ---------------------------------------------------------------------------
// sealed export bundles
// ---------------------------------------------------------------------------
//
// An exports-directory bundle is one operation directory that the exporter filled. Its sidecar
// channel `export_bundle_manifest` holds two files, `_opdir-manifest.json` and `_opdir-seal.json`,
// whose serialized contract is `vwx-rosetta-opdir-manifest/1` and `vwx-rosetta-opdir-seal/1` of
// rosetta_opdir.zig. This module validates those bytes with its own bounded reader. It does not
// import rosetta_opdir.zig, so the pack source stays extractable alone. The parity fixtures of
// vwx/tools/research/trial-export-contract compare the two readers.
//
// A valid manifest proves byte integrity of the listed files and the binding fields. The text
// `semantics: unchecked` stays in the manifest. Nothing here measures geometry or accepts a profile.

pub const bundle_manifest_schema = "vwx-rosetta-opdir-manifest/1";
pub const bundle_seal_schema = "vwx-rosetta-opdir-seal/1";
pub const bundle_semantics = "unchecked";
pub const bundle_reserved_prefix = "_opdir-";
pub const bundle_manifest_file = "_opdir-manifest.json";
pub const bundle_seal_file = "_opdir-seal.json";
pub const max_bundle_manifest_bytes: usize = 4 << 20;
pub const max_bundle_seal_bytes: usize = 4096;
pub const max_bundle_entries: usize = 4096;
/// A 3DS file is read whole for its texture names up to this size. A larger file is a gap.
pub const max_bundle_scan_bytes: usize = 16 << 20;
/// A file with more references than this is a gap. Every reference up to the limit is checked.
pub const max_bundle_refs: usize = 4096;

pub const BundleBindings = struct {
    source_sha256: []const u8,
    state_sha256: []const u8,
    profile_id: []const u8,
    profile_sha256: []const u8,
};

pub const BundleFile = struct {
    path: []const u8,
    size: u64,
    sha256: []const u8,
};

/// A validated manifest. `files` is sorted by byte order and holds every payload of the operation
/// directory, the main file and the sidecars. The seal and manifest files are not listed.
pub const BundleManifest = struct {
    op_id: []const u8,
    format: []const u8,
    main_file: []const u8,
    bindings: BundleBindings,
    expected_sidecars: []const []const u8,
    files: []const BundleFile,

    pub fn find(m: *const BundleManifest, path: []const u8) ?*const BundleFile {
        for (m.files) |*f| {
            if (std.mem.eql(u8, f.path, path)) return f;
        }
        return null;
    }
};

pub const BundleSeal = struct {
    op_id: []const u8,
    manifest_bytes: u64,
    manifest_sha256: []const u8,
};

const WireBundleEntry = struct { path: []const u8, size: u64, sha256: []const u8 };
const WireBundleBindings = struct { source_sha256: []const u8, state_sha256: []const u8, profile_id: []const u8, profile_sha256: []const u8 };
const WireBundleManifest = struct {
    schema: []const u8,
    op_id: []const u8,
    format: []const u8,
    main_file: []const u8,
    semantics: []const u8,
    bindings: WireBundleBindings,
    expected_sidecars: []const []const u8,
    files: []const WireBundleEntry,
};
const WireBundleSeal = struct { schema: []const u8, op_id: []const u8, manifest_bytes: u64, manifest_sha256: []const u8 };

fn parseWire(comptime T: type, a: Allocator, bytes: []const u8) !T {
    return json.parseFromSliceLeaky(T, a, bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false });
}

/// First path component below which the operation writes its own marker files, in any ASCII case.
fn bundleReserved(rel: []const u8) bool {
    const first = if (std.mem.indexOfScalar(u8, rel, '/')) |i| rel[0..i] else rel;
    return std.ascii.startsWithIgnoreCase(first, bundle_reserved_prefix);
}

fn bundleNameProblem(name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return "contains a slash";
    return pathProblem(name);
}

/// Claims paths by ASCII-lowercase key. Two spellings of one file or directory are a case alias
/// on every volume, and a file cannot be the directory of another.
const BundleAliases = struct {
    arena: Allocator,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    dirs: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn claim(s: *BundleAliases, rel: []const u8) !void {
        const k = try std.ascii.allocLowerString(s.arena, rel);
        if (s.dirs.contains(k)) return error.PathConflict;
        const gop = try s.files.getOrPut(s.arena, k);
        if (gop.found_existing) return if (std.mem.eql(u8, gop.value_ptr.*, rel)) error.PathConflict else error.CaseAlias;
        gop.value_ptr.* = rel;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |j| : (i = j + 1) {
            const dk = try std.ascii.allocLowerString(s.arena, rel[0..j]);
            if (s.files.contains(dk)) return error.PathConflict;
            const dg = try s.dirs.getOrPut(s.arena, dk);
            if (!dg.found_existing) {
                dg.value_ptr.* = rel[0..j];
            } else if (!std.mem.eql(u8, dg.value_ptr.*, rel[0..j])) return error.CaseAlias;
        }
    }
};

/// Writes the canonical text of a manifest, byte for byte as rosetta_opdir.zig does.
fn renderBundleManifest(w: *Io.Writer, m: *const BundleManifest) Io.Writer.Error!void {
    try w.print("{{\"schema\":\"{s}\",\"op_id\":\"{s}\",\"format\":\"{s}\",\"main_file\":\"{s}\",\"semantics\":\"{s}\",", .{ bundle_manifest_schema, m.op_id, m.format, m.main_file, bundle_semantics });
    try w.print("\"bindings\":{{\"source_sha256\":\"{s}\",\"state_sha256\":\"{s}\",\"profile_id\":\"{s}\",\"profile_sha256\":\"{s}\"}},", .{ m.bindings.source_sha256, m.bindings.state_sha256, m.bindings.profile_id, m.bindings.profile_sha256 });
    try w.writeAll("\"expected_sidecars\":[");
    for (m.expected_sidecars, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{s});
    }
    try w.writeAll("],\"files\":[");
    for (m.files, 0..) |e, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try w.print("{{\"path\":\"{s}\",\"size\":{d},\"sha256\":\"{s}\"}}", .{ e.path, e.size, e.sha256 });
    }
    if (m.files.len > 0) try w.writeByte('\n');
    try w.writeAll("]}\n");
}

fn bundleFail(d: *Diags, code: []const u8, where: []const u8, comptime fmt: []const u8, args: anytype) ?BundleManifest {
    d.err(code, where, fmt, args);
    return null;
}

/// Validates the bytes of one `_opdir-manifest.json`. Bounds: `max_bundle_manifest_bytes` bytes,
/// `max_bundle_entries` files, the pack path rules for every path, no unknown or repeated key,
/// strict byte order, no ASCII case alias and the canonical text. `where` locates the file in
/// diagnostics. Returns null after at least one error diagnostic. An allocation failure is an error.
pub fn parseBundleManifest(a: Allocator, d: *Diags, where: []const u8, bytes: []const u8) ?BundleManifest {
    if (bytes.len > max_bundle_manifest_bytes) return bundleFail(d, "bundle_manifest_too_large", where, "manifest has {d} bytes. The limit is {d}", .{ bytes.len, max_bundle_manifest_bytes });
    const w = parseWire(WireBundleManifest, a, bytes) catch |e| switch (e) {
        error.OutOfMemory => return bundleFail(d, "out_of_memory", where, "manifest parse ran out of memory", .{}),
        else => return bundleFail(d, "bundle_manifest_malformed", where, "manifest does not parse as {s}: {s}", .{ bundle_manifest_schema, @errorName(e) }),
    };
    if (!std.mem.eql(u8, w.schema, bundle_manifest_schema)) return bundleFail(d, "bundle_manifest_malformed", where, "schema `{s}` is not {s}", .{ w.schema, bundle_manifest_schema });
    if (!std.mem.eql(u8, w.semantics, bundle_semantics)) return bundleFail(d, "bundle_manifest_malformed", where, "semantics `{s}`. A bundle manifest records `{s}`", .{ w.semantics, bundle_semantics });
    if (bundleNameProblem(w.op_id)) |why| return bundleFail(d, "bundle_manifest_malformed", where, "op_id `{s}`: {s}", .{ w.op_id, why });
    if (idProblem(w.format) != null or !inList(&export_formats, w.format)) return bundleFail(d, "bundle_manifest_malformed", where, "format `{s}` is not a registered export format", .{w.format});
    const b = w.bindings;
    if (!isSha256(b.source_sha256) or !isSha256(b.state_sha256) or !isSha256(b.profile_sha256) or idProblem(b.profile_id) != null)
        return bundleFail(d, "bundle_manifest_malformed", where, "bindings need lowercase SHA256 values and a valid profile_id", .{});
    if (pathProblem(w.main_file)) |why| return bundleFail(d, "bundle_manifest_path", where, "main_file `{s}`: {s}", .{ w.main_file, why });
    if (bundleReserved(w.main_file)) return bundleFail(d, "bundle_manifest_path", where, "main_file `{s}` uses a reserved name", .{w.main_file});
    if (w.files.len > max_bundle_entries) return bundleFail(d, "bundle_too_many_entries", where, "manifest lists {d} files. The limit is {d}", .{ w.files.len, max_bundle_entries });
    if (w.expected_sidecars.len > max_bundle_entries) return bundleFail(d, "bundle_too_many_entries", where, "manifest lists {d} sidecars. The limit is {d}", .{ w.expected_sidecars.len, max_bundle_entries });
    var aliases: BundleAliases = .{ .arena = a };
    var total: u64 = 0;
    var main_listed = false;
    const files = a.alloc(BundleFile, w.files.len) catch return bundleFail(d, "out_of_memory", where, "manifest check ran out of memory", .{});
    for (w.files, 0..) |e, i| {
        if (pathProblem(e.path)) |why| return bundleFail(d, "bundle_manifest_path", where, "entry `{s}`: {s}", .{ e.path, why });
        if (bundleReserved(e.path)) return bundleFail(d, "bundle_manifest_path", where, "entry `{s}` uses a reserved name", .{e.path});
        if (credentialName(e.path)) return bundleFail(d, "credential_material", where, "entry `{s}` names credential or activation material", .{e.path});
        if (!isSha256(e.sha256)) return bundleFail(d, "bundle_manifest_malformed", where, "entry `{s}` has no lowercase SHA256", .{e.path});
        if (i > 0 and !std.mem.lessThan(u8, w.files[i - 1].path, e.path)) return bundleFail(d, "bundle_manifest_order", where, "entry `{s}` is duplicated or out of byte order", .{e.path});
        total = std.math.add(u64, total, e.size) catch return bundleFail(d, "bundle_manifest_malformed", where, "the sizes add up beyond 64 bits", .{});
        aliases.claim(e.path) catch |err| switch (err) {
            error.OutOfMemory => return bundleFail(d, "out_of_memory", where, "manifest check ran out of memory", .{}),
            error.CaseAlias => return bundleFail(d, "bundle_alias", where, "entry `{s}` differs from another entry only by ASCII case", .{e.path}),
            error.PathConflict => return bundleFail(d, "bundle_alias", where, "entry `{s}` is both a file and a directory", .{e.path}),
        };
        if (std.mem.eql(u8, e.path, w.main_file)) main_listed = true;
        files[i] = .{ .path = e.path, .size = e.size, .sha256 = e.sha256 };
    }
    if (!main_listed) return bundleFail(d, "bundle_main_missing", where, "main_file `{s}` is not listed. An empty or main-less manifest holds no export", .{w.main_file});
    for (w.expected_sidecars, 0..) |s, i| {
        const listed = for (files) |f| {
            if (std.mem.eql(u8, f.path, s)) break true;
        } else false;
        if (pathProblem(s) != null or !listed or std.mem.eql(u8, s, w.main_file))
            return bundleFail(d, "bundle_manifest_malformed", where, "expected sidecar `{s}` is not a listed non-main file", .{s});
        if (i > 0 and !std.mem.lessThan(u8, w.expected_sidecars[i - 1], s)) return bundleFail(d, "bundle_manifest_order", where, "expected sidecar `{s}` is duplicated or out of byte order", .{s});
    }
    const m: BundleManifest = .{
        .op_id = w.op_id,
        .format = w.format,
        .main_file = w.main_file,
        .bindings = .{ .source_sha256 = b.source_sha256, .state_sha256 = b.state_sha256, .profile_id = b.profile_id, .profile_sha256 = b.profile_sha256 },
        .expected_sidecars = w.expected_sidecars,
        .files = files,
    };
    var out: Io.Writer.Allocating = .init(a);
    renderBundleManifest(&out.writer, &m) catch return bundleFail(d, "out_of_memory", where, "manifest check ran out of memory", .{});
    if (!std.mem.eql(u8, out.written(), bytes)) return bundleFail(d, "bundle_manifest_not_canonical", where, "manifest text differs from its canonical form", .{});
    return m;
}

/// Validates the bytes of one `_opdir-seal.json`. The seal is the commit point of the publication.
pub fn parseBundleSeal(a: Allocator, d: *Diags, where: []const u8, bytes: []const u8) ?BundleSeal {
    if (bytes.len > max_bundle_seal_bytes) {
        d.err("bundle_seal_malformed", where, "seal has {d} bytes. The limit is {d}", .{ bytes.len, max_bundle_seal_bytes });
        return null;
    }
    const w = parseWire(WireBundleSeal, a, bytes) catch |e| {
        if (e == error.OutOfMemory) d.err("out_of_memory", where, "seal parse ran out of memory", .{}) else d.err("bundle_seal_malformed", where, "seal does not parse as {s}: {s}", .{ bundle_seal_schema, @errorName(e) });
        return null;
    };
    if (!std.mem.eql(u8, w.schema, bundle_seal_schema) or !isSha256(w.manifest_sha256) or bundleNameProblem(w.op_id) != null) {
        d.err("bundle_seal_malformed", where, "seal schema, op_id or manifest_sha256 is invalid", .{});
        return null;
    }
    var out: Io.Writer.Allocating = .init(a);
    out.writer.print("{{\"schema\":\"{s}\",\"op_id\":\"{s}\",\"manifest_bytes\":{d},\"manifest_sha256\":\"{s}\"}}\n", .{ bundle_seal_schema, w.op_id, w.manifest_bytes, w.manifest_sha256 }) catch {
        d.err("out_of_memory", where, "seal check ran out of memory", .{});
        return null;
    };
    if (!std.mem.eql(u8, out.written(), bytes)) {
        d.err("bundle_seal_malformed", where, "seal text differs from its canonical form", .{});
        return null;
    }
    return .{ .op_id = w.op_id, .manifest_bytes = w.manifest_bytes, .manifest_sha256 = w.manifest_sha256 };
}

/// The directory of a bundle file with its trailing slash, for a case-relative `exports/` path.
fn bundleDirOf(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "exports/")) return null;
    const i = std.mem.lastIndexOfScalar(u8, path, '/').?;
    if (i < "exports/".len) return null;
    return path[0 .. i + 1];
}

fn baseOf(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

fn isManifestArtifact(x: *const Artifact) bool {
    return std.mem.eql(u8, x.channel, channel_bundle_manifest);
}

/// The case-relative directory of every acquired bundle manifest, with a trailing slash.
fn bundleDirs(a: Allocator, c: *const Case) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (c.artifacts) |*x| {
        if (!isManifestArtifact(x) or !x.state.hasBytes()) continue;
        if (!std.mem.eql(u8, baseOf(x.path), bundle_manifest_file)) continue;
        if (bundleDirOf(x.path)) |dir| out.append(a, dir) catch {};
    }
    return out.items;
}

fn inBundleDir(dirs: []const []const u8, path: []const u8) ?[]const u8 {
    for (dirs) |dir| {
        if (std.mem.startsWith(u8, path, dir)) return dir;
    }
    return null;
}

/// Reader of one artifact. A file of an acquired bundle also gets the reference scan of its type.
fn artifactReader(x: *const Artifact, dirs: []const []const u8) ContentReader {
    if (isManifestArtifact(x)) {
        return if (std.mem.eql(u8, baseOf(x.path), bundle_seal_file)) .bundle_seal else .bundle_manifest;
    }
    if (x.group != .exports or inBundleDir(dirs, x.path) == null) return x.info.reader;
    if (std.mem.eql(u8, x.channel, "export_obj")) return .scan_obj;
    if (std.mem.eql(u8, x.channel, "export_3ds")) return .scan_3ds;
    if (std.mem.eql(u8, x.channel, channel_sidecar) and std.ascii.endsWithIgnoreCase(x.path, ".mtl")) return .scan_mtl;
    return x.info.reader;
}

/// Layout rules that need no file bytes. They read declared artifacts of one case.
fn checkBundleLayout(a: Allocator, d: *Diags, c: *const Case) void {
    const dirs = bundleDirs(a, c);
    for (c.artifacts) |*x| {
        const aw = loc(a, "case:{s}/{s}", .{ c.case_id, x.artifact_id });
        if (x.group == .exports and std.mem.startsWith(u8, x.path, "exports/") and std.ascii.startsWithIgnoreCase(baseOf(x.path), bundle_reserved_prefix)) {
            const ok = isManifestArtifact(x) and (std.mem.eql(u8, baseOf(x.path), bundle_manifest_file) or std.mem.eql(u8, baseOf(x.path), bundle_seal_file));
            if (!ok) d.err("bundle_reserved_name", aw, "path `{s}` uses a name reserved for the bundle protocol. A partial marker or open marker is not published", .{x.path});
        }
        if (isManifestArtifact(x)) {
            const base = baseOf(x.path);
            if (!std.mem.eql(u8, base, bundle_manifest_file) and !std.mem.eql(u8, base, bundle_seal_file)) {
                d.err("bundle_path", aw, "channel `{s}` holds `{s}` or `{s}` only", .{ channel_bundle_manifest, bundle_manifest_file, bundle_seal_file });
                continue;
            }
            const dir = bundleDirOf(x.path) orelse {
                d.err("bundle_path", aw, "path `{s}` is not below an operation directory of exports/", .{x.path});
                continue;
            };
            const other = if (std.mem.eql(u8, base, bundle_manifest_file)) bundle_seal_file else bundle_manifest_file;
            var partner: ?*const Artifact = null;
            for (c.artifacts) |*y| {
                if (isManifestArtifact(y) and y != x and std.mem.startsWith(u8, y.path, dir) and std.mem.eql(u8, y.path[dir.len..], other)) partner = y;
            }
            if (x.state.hasBytes() and (partner == null or !partner.?.state.hasBytes()))
                d.err("bundle_unsealed", aw, "`{s}` has no acquired `{s}` beside it. A bundle without both files is a partial publication", .{ base, other });
            for (dirs) |other_dir| {
                if (!std.mem.eql(u8, other_dir, dir) and std.mem.startsWith(u8, other_dir, dir) and x.state.hasBytes() and std.mem.eql(u8, base, bundle_manifest_file))
                    d.err("bundle_nested", aw, "operation directory `{s}` holds the operation directory `{s}`", .{ dir, other_dir });
            }
            continue;
        }
        if (!x.state.hasBytes() or x.group != .exports) continue;
        if (std.mem.eql(u8, x.channel, channel_sidecar) and inBundleDir(dirs, x.path) == null)
            d.err("sidecar_without_manifest", aw, "export_sidecar `{s}` lies in no operation directory with an acquired bundle manifest", .{x.path});
    }
}

const RefKind = enum { mtllib, map, texture };
const RefFound = struct { file: []const u8, target: []const u8, kind: RefKind };

fn dependsOnScan(fmt: []const u8) bool {
    return std.mem.eql(u8, fmt, "obj") or std.mem.eql(u8, fmt, "3ds");
}

/// Compares a bundle with the declarations of its case. `mart` is the acquired manifest artifact.
/// `sizes` maps case-relative paths to the byte counts that the readers counted.
fn checkBundle(a: Allocator, d: *Diags, c: *const Case, cc: *const CaseContent, mart: *const Artifact, bm: BundleManifest, seal: ?BundleSeal) void {
    const dir = bundleDirOf(mart.path).?;
    const mw = loc(a, "case:{s}/{s}", .{ c.case_id, mart.artifact_id });
    const dir_name = dir["exports/".len .. dir.len - 1];
    const op_name = if (std.mem.lastIndexOfScalar(u8, dir_name, '/')) |i| dir_name[i + 1 ..] else dir_name;
    if (!std.mem.eql(u8, bm.op_id, op_name)) d.err("bundle_op_mismatch", mw, "manifest op_id `{s}` differs from the operation directory `{s}`", .{ bm.op_id, op_name });

    // seal
    if (seal) |s| {
        if (!std.mem.eql(u8, s.op_id, bm.op_id)) d.err("bundle_seal_mismatch", mw, "seal op_id `{s}` differs from the manifest op_id `{s}`", .{ s.op_id, bm.op_id });
        if (mart.sha256) |ms| {
            if (!std.mem.eql(u8, ms, s.manifest_sha256)) d.err("bundle_seal_mismatch", mw, "seal manifest_sha256 differs from the SHA256 of the manifest file", .{});
        }
        const key = loc(a, "cases/{s}/{s}", .{ c.case_id, mart.path });
        if (cc.file_sizes.get(key)) |n| {
            if (n != s.manifest_bytes) d.err("bundle_seal_mismatch", mw, "seal manifest_bytes {d} differs from the {d} bytes of the manifest file", .{ s.manifest_bytes, n });
        }
    }

    // bindings of the manifest equal the bindings of its own artifact
    if (mart.source_sha256) |v| {
        if (!std.mem.eql(u8, v, bm.bindings.source_sha256)) d.err("stale_source_binding", mw, "manifest source_sha256 differs from the artifact", .{});
    }
    if (mart.state_sha256) |v| {
        if (!std.mem.eql(u8, v, bm.bindings.state_sha256)) d.err("stale_state_binding", mw, "manifest state_sha256 differs from the artifact", .{});
    }
    if (mart.profile_sha256) |v| {
        if (!std.mem.eql(u8, v, bm.bindings.profile_sha256)) d.err("stale_profile_binding", mw, "manifest profile_sha256 differs from the artifact", .{});
    }
    if (mart.profile_id) |v| {
        if (!std.mem.eql(u8, v, bm.bindings.profile_id)) d.err("bundle_profile_mismatch", mw, "manifest profile_id `{s}` differs from the artifact profile_id `{s}`", .{ bm.bindings.profile_id, v });
    }

    // every listed file is a declared artifact with the same hash and size
    for (bm.files) |f| {
        const full = loc(a, "{s}{s}", .{ dir, f.path });
        if (pathProblem(full)) |why| {
            d.err("bundle_path", mw, "payload `{s}` lies at `{s}` in the pack: {s}", .{ f.path, full, why });
            continue;
        }
        var art: ?*const Artifact = null;
        for (c.artifacts) |*x| {
            if (std.mem.eql(u8, x.path, full)) art = x;
        }
        const x = art orelse {
            d.err("bundle_payload_undeclared", mw, "manifest lists `{s}`. The case declares no artifact at `{s}`", .{ f.path, full });
            continue;
        };
        const xw = loc(a, "case:{s}/{s}", .{ c.case_id, x.artifact_id });
        if (!x.state.hasBytes()) {
            d.err("bundle_payload_not_acquired", xw, "manifest lists `{s}`, whose artifact is `{s}`", .{ f.path, @tagName(x.state) });
            continue;
        }
        const is_main = std.mem.eql(u8, f.path, bm.main_file);
        if (is_main) {
            const want = loc(a, "export_{s}", .{bm.format});
            if (!std.mem.eql(u8, x.channel, want)) d.err("bundle_main_channel", xw, "main file `{s}` of format `{s}` needs channel `{s}`, not `{s}`", .{ f.path, bm.format, want, x.channel });
        } else if (!std.mem.eql(u8, x.channel, channel_sidecar)) {
            d.err("bundle_sidecar_channel", xw, "`{s}` is not the main file. Its channel is `{s}`, not `{s}`", .{ f.path, x.channel, channel_sidecar });
        }
        if (x.sha256) |xs| {
            if (!std.mem.eql(u8, xs, f.sha256)) d.err("bundle_payload_mismatch", xw, "artifact SHA256 differs from the manifest entry `{s}`", .{f.path});
        }
        if (x.size) |n| {
            if (n != f.size) d.err("bundle_payload_mismatch", xw, "artifact size {d} differs from the manifest entry `{s}` ({d})", .{ n, f.path, f.size });
        }
        if (cc.file_sizes.get(loc(a, "cases/{s}/{s}", .{ c.case_id, full }))) |n| {
            if (n != f.size) d.err("bundle_payload_mismatch", xw, "file has {d} bytes. The manifest entry `{s}` lists {d}", .{ n, f.path, f.size });
        }
        const b = bm.bindings;
        if (x.source_sha256 != null and !std.mem.eql(u8, x.source_sha256.?, b.source_sha256)) d.err("stale_source_binding", xw, "source_sha256 differs from the bundle manifest", .{});
        if (x.state_sha256 != null and !std.mem.eql(u8, x.state_sha256.?, b.state_sha256)) d.err("stale_state_binding", xw, "state_sha256 differs from the bundle manifest", .{});
        if (x.profile_sha256 != null and !std.mem.eql(u8, x.profile_sha256.?, b.profile_sha256)) d.err("stale_profile_binding", xw, "profile_sha256 differs from the bundle manifest", .{});
        if (x.profile_id != null and !std.mem.eql(u8, x.profile_id.?, b.profile_id)) d.err("bundle_profile_mismatch", xw, "profile_id differs from the bundle manifest", .{});
    }

    // no acquired payload that the manifest omits
    for (c.artifacts) |*x| {
        if (!std.mem.startsWith(u8, x.path, dir) or !x.state.hasBytes() or isManifestArtifact(x)) continue;
        if (bm.find(x.path[dir.len..]) == null) d.err("bundle_extra_payload", loc(a, "case:{s}/{s}", .{ c.case_id, x.artifact_id }), "artifact `{s}` lies in the operation directory and the manifest does not list it", .{x.path});
    }

    // reference closure for the bounded syntaxes. Everything else stays unmeasured.
    for (cc.bundle_refs.items) |r| {
        if (!std.mem.startsWith(u8, r.file, dir)) continue;
        checkReference(a, d, c, bm, dir, r);
    }
    if (!dependsOnScan(bm.format) and bm.files.len > 1) {
        d.add(.gap, "bundle_references_unmeasured", mw, "format `{s}`: external references are checked for OBJ, MTL and 3DS syntax only. A manifest proves bundle bytes, not reference closure", .{bm.format});
    }
    d.add(.gap, "bundle_semantics_unchecked", mw, "manifest semantics `{s}`. The bundle bytes are intact. Geometry and profile validity are not measured", .{bundle_semantics});
}

/// Resolves one scanned reference against the files of the manifest.
fn checkReference(a: Allocator, d: *Diags, c: *const Case, bm: BundleManifest, dir: []const u8, r: RefFound) void {
    const where = loc(a, "case:{s}/{s}", .{ c.case_id, r.file });
    const from = r.file[dir.len..];
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, from, '/');
    while (it.next()) |p| parts.append(a, p) catch return d.err("out_of_memory", where, "reference check ran out of memory", .{});
    _ = parts.pop();
    if (r.target.len == 0 or r.target[0] == '/' or std.mem.indexOfScalar(u8, r.target, '\\') != null or std.mem.indexOfScalar(u8, r.target, ':') != null) {
        return d.err("reference_escapes_bundle", where, "reference `{s}` is absolute or not a relative bundle path", .{r.target});
    }
    var tp = std.mem.splitScalar(u8, r.target, '/');
    while (tp.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (parts.items.len == 0) return d.err("reference_escapes_bundle", where, "reference `{s}` leaves the operation directory", .{r.target});
            _ = parts.pop();
            continue;
        }
        parts.append(a, comp) catch return d.err("out_of_memory", where, "reference check ran out of memory", .{});
    }
    if (parts.items.len == 0) return d.err("reference_unresolved", where, "reference `{s}` names no file", .{r.target});
    const resolved = std.mem.join(a, "/", parts.items) catch return d.err("out_of_memory", where, "reference check ran out of memory", .{});
    if (bm.find(resolved) != null) return;
    for (bm.files) |f| {
        if (std.ascii.eqlIgnoreCase(f.path, resolved)) {
            if (r.kind == .texture) return d.add(.warning, "reference_case_alias", where, "3DS texture `{s}` matches `{s}` by ASCII case only", .{ r.target, f.path });
            return d.err("reference_case_alias", where, "reference `{s}` matches `{s}` by ASCII case only", .{ r.target, f.path });
        }
    }
    d.err("reference_unresolved", where, "{s} reference `{s}` resolves to `{s}`, which the bundle manifest does not list", .{ @tagName(r.kind), r.target, resolved });
}

/// Appends the references of one OBJ or MTL line. Option tokens of an MTL map statement are skipped.
fn scanReferenceLine(s: *Sink, line: []const u8) void {
    const sa = s.a;
    var toks = std.mem.tokenizeAny(u8, line, " \t\r");
    const head = toks.next() orelse return;
    if (head[0] == '#') return;
    const cc = s.content orelse return;
    const file = caseRelative(s) orelse return;
    if (s.reader == .scan_obj) {
        if (!std.mem.eql(u8, head, "mtllib")) return;
        while (toks.next()) |t| s.addReference(sa, cc, file, t, .mtllib);
        return;
    }
    const maps = [_][]const u8{ "map_Ka", "map_Kd", "map_Ks", "map_Ns", "map_d", "map_Ke", "map_bump", "bump", "disp", "decal", "refl", "map_Pr", "map_Pm", "map_Ps", "norm" };
    var is_map = false;
    for (maps) |m| {
        if (std.ascii.eqlIgnoreCase(head, m)) is_map = true;
    }
    if (!is_map) return;
    // The file name is the last token. Options such as `-s 1 1 1` come first.
    var last: ?[]const u8 = null;
    while (toks.next()) |t| last = t;
    if (last) |t| s.addReference(sa, cc, file, t, .map);
}

fn caseRelative(s: *const Sink) ?[]const u8 {
    const c = s.case orelse return null;
    const head = "cases/";
    if (!std.mem.startsWith(u8, s.path, head)) return null;
    const rest = s.path[head.len..];
    if (!std.mem.startsWith(u8, rest, c.case_id) or rest.len <= c.case_id.len or rest[c.case_id.len] != '/') return null;
    return rest[c.case_id.len + 1 ..];
}

/// Reads the texture names of the material chunks of a 3DS file. Returns false when the chunk
/// structure is malformed, so the caller records a gap rather than a closure claim.
fn scan3ds(s: *Sink, bytes: []const u8, file: []const u8, cc: *CaseContent) bool {
    const Chunk = struct { id: u16, len: u32 };
    const read = struct {
        fn at(b: []const u8, off: usize) ?Chunk {
            if (off + 6 > b.len) return null;
            return .{ .id = std.mem.readInt(u16, b[off..][0..2], .little), .len = std.mem.readInt(u32, b[off + 2 ..][0..4], .little) };
        }
    }.at;
    // Containers on the path to a texture name: MAIN, EDIT, MATERIAL and the map chunks.
    const containers = [_]u16{ 0x4D4D, 0x3D3D, 0xAFFF, 0xA200, 0xA204, 0xA210, 0xA220, 0xA230, 0xA33A, 0xA33C, 0xA33D, 0xA340, 0xA344 };
    var count: usize = 0;
    var stack_end: [8]usize = undefined;
    var depth: usize = 0;
    var off: usize = 0;
    const top = read(bytes, 0) orelse return false;
    if (top.id != 0x4D4D or top.len < 6 or top.len > bytes.len) return false;
    stack_end[0] = top.len;
    depth = 1;
    off = 6;
    while (depth > 0) {
        while (off >= stack_end[depth - 1]) {
            depth -= 1;
            if (depth == 0) return true;
        }
        const ch = read(bytes, off) orelse return false;
        if (ch.len < 6 or off + ch.len > stack_end[depth - 1]) return false;
        const end = off + ch.len;
        if (ch.id == 0xA300) {
            const body = bytes[off + 6 .. end];
            const nul = std.mem.indexOfScalar(u8, body, 0) orelse return false;
            count += 1;
            if (count > max_bundle_refs) return false;
            s.addReference(s.a, cc, file, body[0..nul], .texture);
            off = end;
            continue;
        }
        var is_container = false;
        for (containers) |id| {
            if (id == ch.id) is_container = true;
        }
        if (is_container) {
            if (depth == stack_end.len) return false;
            stack_end[depth] = end;
            depth += 1;
            off += 6;
        } else off = end;
    }
    return true;
}

// ---------------------------------------------------------------------------
// streamed content
// ---------------------------------------------------------------------------

/// Receives the bytes of one file in chunks. It hashes them, scans for private key
/// material and runs the content reader of the channel.
pub const Sink = struct {
    a: Allocator,
    d: *Diags,
    path: []const u8,
    reader: ContentReader,
    case: ?*const Case = null,
    content: ?*CaseContent = null,
    hasher: Sha256 = .init(.{}),
    total: u64 = 0,
    tail: [private_key_marker.len - 1]u8 = undefined,
    tail_len: usize = 0,
    found_key: bool = false,
    buf: std.ArrayList(u8) = .empty,
    overflow: bool = false,
    skipping_line: bool = false,
    line_no: usize = 0,
    scratch: std.heap.ArenaAllocator,
    /// Keep the whole content, for metadata and generated files.
    keep: bool = false,
    ref_count: usize = 0,
    ref_overflow: bool = false,
    /// A buffer allocation failed. `finish` then reports an error and no reader result stands.
    alloc_failed: bool = false,

    pub fn init(a: Allocator, gpa: Allocator, d: *Diags, path: []const u8, reader: ContentReader) Sink {
        return .{ .a = a, .d = d, .path = path, .reader = reader, .scratch = .init(gpa) };
    }

    pub fn deinit(s: *Sink) void {
        s.scratch.deinit();
    }

    /// Bytes that a whole-file reader keeps before it gives up.
    fn wholeLimit(s: *const Sink) usize {
        return switch (s.reader) {
            .bundle_manifest => max_bundle_manifest_bytes,
            .bundle_seal => max_bundle_seal_bytes,
            .scan_3ds => max_bundle_scan_bytes,
            else => max_metadata_bytes,
        };
    }

    fn isScanLines(s: *const Sink) bool {
        return s.reader == .scan_obj or s.reader == .scan_mtl;
    }

    fn addReference(s: *Sink, a: Allocator, cc: *CaseContent, file: []const u8, target: []const u8, kind: RefKind) void {
        if (s.ref_count >= max_bundle_refs) {
            s.ref_overflow = true;
            return;
        }
        s.ref_count += 1;
        const t = a.dupe(u8, target) catch return s.d.err("out_of_memory", s.path, "reference scan ran out of memory", .{});
        cc.bundle_refs.append(a, .{ .file = file, .target = t, .kind = kind }) catch s.d.err("out_of_memory", s.path, "reference scan ran out of memory", .{});
    }

    fn scanKey(s: *Sink, chunk: []const u8) void {
        if (s.found_key) return;
        var joined: [2 * private_key_marker.len]u8 = undefined;
        const head = chunk[0..@min(chunk.len, private_key_marker.len - 1)];
        @memcpy(joined[0..s.tail_len], s.tail[0..s.tail_len]);
        @memcpy(joined[s.tail_len..][0..head.len], head);
        if (std.mem.indexOf(u8, joined[0 .. s.tail_len + head.len], private_key_marker) != null or
            std.mem.indexOf(u8, chunk, private_key_marker) != null)
        {
            s.found_key = true;
            return;
        }
        const keep_n = private_key_marker.len - 1;
        if (chunk.len >= keep_n) {
            @memcpy(&s.tail, chunk[chunk.len - keep_n ..]);
            s.tail_len = keep_n;
        } else {
            const total = s.tail_len + chunk.len;
            var tmp: [2 * private_key_marker.len]u8 = undefined;
            @memcpy(tmp[0..s.tail_len], s.tail[0..s.tail_len]);
            @memcpy(tmp[s.tail_len..total], chunk);
            const start = total -| keep_n;
            @memcpy(s.tail[0 .. total - start], tmp[start..total]);
            s.tail_len = total - start;
        }
    }

    pub fn feed(s: *Sink, chunk: []const u8) void {
        s.hasher.update(chunk);
        s.total += chunk.len;
        s.scanKey(chunk);
        const whole = s.keep or s.reader == .json_syntax or s.reader == .frames or s.reader == .bundle_manifest or s.reader == .bundle_seal or s.reader == .scan_3ds;
        if (whole) {
            if (s.overflow) return;
            const limit = s.wholeLimit();
            if (s.buf.items.len + chunk.len > limit) {
                s.overflow = true;
                if (s.reader == .scan_3ds) {
                    s.d.add(.gap, "reference_scan_limit", s.path, "file exceeds {d} bytes. Its texture references are not scanned", .{limit});
                } else s.d.err("too_large_for_reader", s.path, "file exceeds {d} bytes, the limit of its reader", .{limit});
                return;
            }
            s.buf.appendSlice(s.a, chunk) catch {
                s.alloc_failed = true;
            };
            return;
        }
        if (s.reader == .jsonl_syntax or s.reader == .measurements or s.isScanLines()) {
            var rest = chunk;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const part = if (nl) |i| rest[0..i] else rest;
                if (!s.skipping_line) {
                    if (s.buf.items.len + part.len > max_json_line) {
                        if (s.isScanLines()) {
                            s.d.add(.gap, "reference_scan_limit", loc(s.a, "{s}:{d}", .{ s.path, s.line_no + 1 }), "line exceeds {d} bytes. Its references are not scanned", .{max_json_line});
                        } else s.d.err("line_too_long", loc(s.a, "{s}:{d}", .{ s.path, s.line_no + 1 }), "JSON line exceeds {d} bytes", .{max_json_line});
                        s.skipping_line = true;
                        s.buf.clearRetainingCapacity();
                    } else s.buf.appendSlice(s.a, part) catch {
                        s.alloc_failed = true;
                    };
                }
                if (nl) |i| {
                    s.endLine();
                    rest = rest[i + 1 ..];
                } else rest = rest[rest.len..];
            }
        }
    }

    fn endLine(s: *Sink) void {
        s.line_no += 1;
        defer {
            s.buf.clearRetainingCapacity();
            s.skipping_line = false;
            _ = s.scratch.reset(.retain_capacity);
        }
        if (s.skipping_line) return;
        const line = std.mem.trim(u8, s.buf.items, " \r\t");
        if (line.len == 0) return;
        if (s.isScanLines()) return scanReferenceLine(s, line);
        const sa = s.scratch.allocator();
        const v = parseJson(sa, line) catch |e| {
            s.d.err(jsonErrorCode(e), loc(s.a, "{s}:{d}", .{ s.path, s.line_no }), "line does not parse: {s}", .{@errorName(e)});
            if (s.content) |cc| cc.rejected += 1;
            return;
        };
        if (s.reader == .measurements) {
            if (s.content) |cc| checkMeasurement(s.a, sa, s.d, cc, if (s.case) |c| c.case_id else "", s.path, s.line_no, v);
        }
    }

    /// Runs the whole-file readers of the bundle extension.
    fn finishBundle(s: *Sink) void {
        if (s.overflow) return;
        const cc = s.content orelse return;
        const file = caseRelative(s) orelse return;
        switch (s.reader) {
            .bundle_manifest => {
                if (parseBundleManifest(s.a, s.d, s.path, s.buf.items)) |m| cc.bundle_manifests.append(s.a, .{ .path = file, .manifest = m }) catch s.d.err("out_of_memory", s.path, "manifest bookkeeping ran out of memory", .{});
            },
            .bundle_seal => {
                if (parseBundleSeal(s.a, s.d, s.path, s.buf.items)) |seal| {
                    const dir = bundleDirOf(file) orelse return;
                    cc.bundle_seals.append(s.a, .{ .dir = dir, .seal = seal }) catch s.d.err("out_of_memory", s.path, "seal bookkeeping ran out of memory", .{});
                }
            },
            .scan_3ds => {
                if (!scan3ds(s, s.buf.items, file, cc)) s.d.add(.gap, "reference_scan_malformed", s.path, "the 3DS chunk structure does not parse. Texture references are not checked", .{});
            },
            else => {},
        }
    }

    /// Ends the stream. Returns the SHA256 of all bytes fed.
    pub fn finish(s: *Sink) [64]u8 {
        if (!s.keep and (s.reader == .jsonl_syntax or s.reader == .measurements or s.isScanLines()) and (s.buf.items.len > 0 or s.skipping_line)) s.endLine();
        if (s.ref_overflow) s.d.add(.gap, "reference_scan_limit", s.path, "more than {d} references. The rest are not checked", .{max_bundle_refs});
        s.finishBundle();
        if (s.alloc_failed) s.d.err("out_of_memory", s.path, "reading the file ran out of memory", .{});
        if (s.found_key) s.d.err("credential_material", s.path, "file contains `{s}`", .{private_key_marker});
        if ((s.reader == .json_syntax or s.reader == .frames) and !s.overflow) {
            const v = parseJson(s.scratch.allocator(), s.buf.items) catch |e| blk: {
                s.d.err(jsonErrorCode(e), s.path, "file does not parse: {s}", .{@errorName(e)});
                break :blk null;
            };
            if (v != null and s.reader == .frames) {
                if (s.content) |cc| checkFrames(s.a, s.d, cc, if (s.case) |c| c.case_id else "", s.path, v.?);
            }
        }
        var digest: [32]u8 = undefined;
        s.hasher.final(&digest);
        return hexOf(digest);
    }
};

// ---------------------------------------------------------------------------
// reports
// ---------------------------------------------------------------------------

const state_count = @typeInfo(State).@"enum".fields.len;
const StateCounts = [state_count]u64;

pub const ObligationStatus = enum { satisfied, missing, case_absent };

pub const ObligationRow = struct {
    o: *const Obligation,
    status: ObligationStatus,
    missing_channels: []const []const u8,
};

pub const ChannelRow = struct {
    channel: []const u8,
    capability: []const u8,
    counts: StateCounts = @splat(0),
};

/// Counts derived from metadata alone. COVERAGE.json, MISSING.json and CATALOG.md render this one value.
pub const Summary = struct {
    cases_total: u64 = 0,
    complete: u64 = 0,
    by_state: StateCounts = @splat(0),
    by_universe: [4]StateCounts = @splat(@splat(0)),
    channels: []ChannelRow = &.{},
    obligations: []ObligationRow = &.{},
    obligation_counts: [3]u64 = @splat(0),
};

/// An acquired case needs at least one required artifact with acquired bytes.
fn hasAcquiredEvidence(c: *const Case) bool {
    for (c.artifacts) |x| {
        if (x.required and x.state == .acquired) return true;
    }
    return false;
}

fn caseComplete(p: *const Pack, c: *const Case) bool {
    if (c.state != .acquired or !hasAcquiredEvidence(c)) return false;
    for (c.artifacts) |x| {
        if (x.required and x.state != .acquired) return false;
    }
    for (c.dependencies) |id| {
        const dep = p.findDependency(id) orelse return false;
        if (dep.state != .acquired) return false;
    }
    for (p.root.obligations) |o| {
        if (!std.mem.eql(u8, o.case_id, c.case_id)) continue;
        for (o.required_channels) |ch| {
            if (!channelAcquired(c, ch)) return false;
        }
    }
    return true;
}

pub fn summarize(a: Allocator, p: *const Pack) Summary {
    var s: Summary = .{};
    var rows: std.ArrayList(ChannelRow) = .empty;
    for (channelNames(a)) |name| {
        var used = false;
        for (p.cases) |c| {
            for (c.artifacts) |x| {
                if (std.mem.eql(u8, x.channel, name)) used = true;
            }
        }
        if (used) rows.append(a, .{ .channel = name, .capability = channelInfo(name).?.reader.capability() }) catch {};
    }
    for (p.cases) |*c| {
        s.cases_total += 1;
        s.by_state[@intFromEnum(c.state)] += 1;
        s.by_universe[@intFromEnum(c.universe)][@intFromEnum(c.state)] += 1;
        if (caseComplete(p, c)) s.complete += 1;
        for (c.artifacts) |x| {
            for (rows.items) |*r| {
                if (std.mem.eql(u8, r.channel, x.channel)) r.counts[@intFromEnum(x.state)] += 1;
            }
        }
    }
    s.channels = rows.items;
    var obl: std.ArrayList(ObligationRow) = .empty;
    for (p.root.obligations) |*o| {
        var missing: std.ArrayList([]const u8) = .empty;
        var status: ObligationStatus = .satisfied;
        if (p.findCase(o.case_id)) |c| {
            for (o.required_channels) |ch| {
                if (!channelAcquired(c, ch)) missing.append(a, ch) catch {};
            }
            if (c.state != .acquired or missing.items.len > 0) status = .missing;
        } else {
            status = .case_absent;
            missing.appendSlice(a, o.required_channels) catch {};
        }
        s.obligation_counts[@intFromEnum(status)] += 1;
        obl.append(a, .{ .o = o, .status = status, .missing_channels = missing.items }) catch {};
    }
    s.obligations = obl.items;
    return s;
}

fn writeStateCounts(js: *json.Stringify, counts: StateCounts) !void {
    try js.beginObject();
    inline for (@typeInfo(State).@"enum".fields, 0..) |f, i| {
        try js.objectField(f.name);
        try js.write(counts[i]);
    }
    try js.endObject();
}

fn writeRelease(js: *json.Stringify, r: Release) !void {
    try js.beginObject();
    try js.objectField("version");
    try js.write(r.version);
    try js.objectField("build");
    try js.write(r.build);
    try js.objectField("edition");
    try js.write(r.edition);
    try js.objectField("platform");
    try js.write(r.platform);
    try js.objectField("verification");
    try js.write(if (r.verified) "verified" else "unverified");
    try js.endObject();
}

pub fn renderCoverage(a: Allocator, p: *const Pack, s: *const Summary) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    var js: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("schema");
    try js.write(schema_coverage);
    try js.objectField("manifest_sha256");
    try js.write(&p.manifest_sha256);
    try js.objectField("release");
    try writeRelease(&js, p.root.release);
    try js.objectField("inventory_revision");
    try js.write(p.root.inventory_revision);
    try js.objectField("cases");
    try js.beginObject();
    try js.objectField("total");
    try js.write(s.cases_total);
    try js.objectField("complete");
    try js.write(s.complete);
    try js.objectField("by_state");
    try writeStateCounts(&js, s.by_state);
    try js.objectField("by_universe");
    try js.beginObject();
    inline for (@typeInfo(Universe).@"enum".fields, 0..) |f, i| {
        try js.objectField(f.name);
        try writeStateCounts(&js, s.by_universe[i]);
    }
    try js.endObject();
    try js.endObject();
    try js.objectField("channels");
    try js.beginObject();
    for (s.channels) |r| {
        try js.objectField(r.channel);
        try js.beginObject();
        try js.objectField("capability");
        try js.write(r.capability);
        try js.objectField("by_state");
        try writeStateCounts(&js, r.counts);
        try js.endObject();
    }
    try js.endObject();
    try js.objectField("obligations");
    try js.beginObject();
    try js.objectField("total");
    try js.write(s.obligations.len);
    inline for (@typeInfo(ObligationStatus).@"enum".fields, 0..) |f, i| {
        try js.objectField(f.name);
        try js.write(s.obligation_counts[i]);
    }
    try js.endObject();
    try js.endObject();
    try out.writer.writeByte('\n');
    return out.written();
}

pub fn renderMissing(a: Allocator, p: *const Pack, s: *const Summary) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    var js: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("schema");
    try js.write(schema_missing);
    try js.objectField("manifest_sha256");
    try js.write(&p.manifest_sha256);
    try js.objectField("cases");
    try js.beginArray();
    for (p.cases) |c| {
        if (c.state == .acquired) continue;
        try js.beginObject();
        try js.objectField("case_id");
        try js.write(c.case_id);
        try js.objectField("state");
        try js.write(@tagName(c.state));
        try js.objectField("reason");
        try js.write(c.reason);
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("artifacts");
    try js.beginArray();
    for (p.cases) |c| {
        for (c.artifacts) |x| {
            if (x.state == .acquired) continue;
            try js.beginObject();
            try js.objectField("case_id");
            try js.write(c.case_id);
            try js.objectField("artifact_id");
            try js.write(x.artifact_id);
            try js.objectField("channel");
            try js.write(x.channel);
            try js.objectField("required");
            try js.write(x.required);
            try js.objectField("state");
            try js.write(@tagName(x.state));
            try js.objectField("reason");
            try js.write(x.reason);
            try js.endObject();
        }
    }
    try js.endArray();
    try js.objectField("dependencies");
    try js.beginArray();
    for (p.root.dependencies) |x| {
        if (x.state == .acquired) continue;
        try js.beginObject();
        try js.objectField("dependency_id");
        try js.write(x.dependency_id);
        try js.objectField("state");
        try js.write(@tagName(x.state));
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("obligations");
    try js.beginArray();
    for (s.obligations) |r| {
        if (r.status == .satisfied) continue;
        try js.beginObject();
        try js.objectField("obligation_id");
        try js.write(r.o.obligation_id);
        try js.objectField("case_id");
        try js.write(r.o.case_id);
        try js.objectField("status");
        try js.write(@tagName(r.status));
        try js.objectField("missing_channels");
        try js.write(r.missing_channels);
        try js.objectField("owner");
        try js.write(r.o.owner);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try out.writer.writeByte('\n');
    return out.written();
}

fn cell(w: *Io.Writer, s: ?[]const u8) !void {
    const v = s orelse "-";
    for (v) |c| {
        switch (c) {
            '|' => try w.writeAll("\\|"),
            '\n', '\r', '\t' => try w.writeByte(' '),
            else => try w.writeByte(c),
        }
    }
}

pub fn renderCatalog(a: Allocator, p: *const Pack, s: *const Summary) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const r = p.root.release;
    try w.writeAll("# Rosetta pack catalog\n\n");
    try w.writeAll("- Release: ");
    try cell(w, r.version);
    try w.writeAll(" build ");
    try cell(w, r.build);
    try w.writeAll(", edition ");
    try cell(w, r.edition);
    try w.writeAll(", platform ");
    try cell(w, r.platform);
    try w.print(", {s}\n", .{if (r.verified) "verified" else "unverified"});
    try w.writeAll("- Inventory revision: ");
    try cell(w, p.root.inventory_revision);
    try w.print("\n- MANIFEST.json SHA256: {s}\n", .{&p.manifest_sha256});
    try w.print("- Cases: {d} total, {d} complete\n", .{ s.cases_total, s.complete });
    try w.print("- Obligations: {d} satisfied, {d} missing, {d} case_absent\n\n", .{ s.obligation_counts[0], s.obligation_counts[1], s.obligation_counts[2] });

    try w.writeAll("## Case states\n\n| Universe |");
    inline for (@typeInfo(State).@"enum".fields) |f| try w.print(" {s} |", .{f.name});
    try w.writeAll("\n| --- |");
    for (0..state_count) |_| try w.writeAll(" --- |");
    try w.writeByte('\n');
    inline for (@typeInfo(Universe).@"enum".fields, 0..) |f, i| {
        try w.print("| {s} |", .{f.name});
        for (s.by_universe[i]) |n| try w.print(" {d} |", .{n});
        try w.writeByte('\n');
    }

    try w.writeAll("\n## Cases\n\n| Case | Family | Universe | State | Recipe revision | Acquired artifacts | Artifacts | Reason |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for (p.cases) |c| {
        var acq: usize = 0;
        for (c.artifacts) |x| {
            if (x.state == .acquired) acq += 1;
        }
        try w.writeAll("| ");
        try cell(w, c.case_id);
        try w.writeAll(" | ");
        try cell(w, c.family_id);
        try w.print(" | {s} | {s} | ", .{ @tagName(c.universe), @tagName(c.state) });
        try cell(w, c.recipe_revision);
        try w.print(" | {d} | {d} | ", .{ acq, c.artifacts.len });
        try cell(w, c.reason);
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n## Channels\n\n| Channel | Capability |");
    inline for (@typeInfo(State).@"enum".fields[0..5]) |f| try w.print(" {s} |", .{f.name});
    try w.writeAll("\n| --- | --- | --- | --- | --- | --- | --- |\n");
    for (s.channels) |row| {
        try w.print("| {s} | {s} |", .{ row.channel, row.capability });
        for (row.counts[0..5]) |n| try w.print(" {d} |", .{n});
        try w.writeByte('\n');
    }

    try w.writeAll("\n## Obligations\n\n| Obligation | Case | Status | Missing channels | Owner |\n| --- | --- | --- | --- | --- |\n");
    for (s.obligations) |row| {
        try w.writeAll("| ");
        try cell(w, row.o.obligation_id);
        try w.writeAll(" | ");
        try cell(w, row.o.case_id);
        try w.print(" | {s} | ", .{@tagName(row.status)});
        for (row.missing_channels, 0..) |ch, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(ch);
        }
        if (row.missing_channels.len == 0) try w.writeByte('-');
        try w.writeAll(" | ");
        try cell(w, row.o.owner);
        try w.writeAll(" |\n");
    }
    return out.written();
}

pub const Generated = struct {
    catalog: []const u8,
    coverage: []const u8,
    missing: []const u8,

    pub fn get(g: *const Generated, name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, catalog_name)) return g.catalog;
        if (std.mem.eql(u8, name, coverage_name)) return g.coverage;
        return g.missing;
    }
};

pub fn generateReports(a: Allocator, p: *const Pack) !Generated {
    const s = summarize(a, p);
    return .{
        .catalog = try renderCatalog(a, p, &s),
        .coverage = try renderCoverage(a, p, &s),
        .missing = try renderMissing(a, p, &s),
    };
}

/// SHA256SUMS lists every pack file except itself, sorted by path bytes.
pub fn renderSums(a: Allocator, m: *const Model) ![]const u8 {
    const Line = struct { path: []const u8, sha: []const u8 };
    var lines: std.ArrayList(Line) = .empty;
    for (m.expects.items) |e| {
        if (std.mem.eql(u8, e.path, sums_name) or std.mem.eql(u8, e.path, subset_name)) continue;
        try lines.append(a, .{ .path = e.path, .sha = e.sha256 });
    }
    std.mem.sort(Line, lines.items, {}, struct {
        fn lt(_: void, x: Line, y: Line) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    var out: Io.Writer.Allocating = .init(a);
    for (lines.items) |l| try out.writer.print("{s}  {s}\n", .{ l.sha, l.path });
    return out.written();
}

// ---------------------------------------------------------------------------
// model of one pack copy
// ---------------------------------------------------------------------------

pub const Mode = enum { input, pack };

pub const Meta = struct {
    bytes: []const u8,
    sha256: [64]u8,
};

/// One file that the metadata lists.
pub const Expect = struct {
    path: []const u8,
    sha256: []const u8,
    size: ?u64 = null,
    reader: ContentReader = .none,
    case_index: ?usize = null,
    /// The copy under check holds this file.
    selected: bool = true,
    /// Read whole by the metadata loader.
    metadata: bool = false,
    seen: bool = false,
    /// The file lies in a sealed bundle directory. A hard link there is an error.
    bundle: bool = false,
};

pub const Subset = struct {
    parent_pack: []const u8,
    cases: []const []const u8,
};

pub const Model = struct {
    mode: Mode,
    pack: Pack,
    expects: std.ArrayList(Expect) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    contents: []CaseContent,
    /// Case directories whose metadata has errors. Their unlisted files get no extra diagnostic.
    noisy_dirs: []const []const u8,
    selection: ?[]const []const u8 = null,
    subset: ?Subset = null,
    generated: ?Generated = null,
    /// Metadata files read by the loader, by pack path.
    metas: std.StringHashMapUnmanaged(Meta) = .empty,

    fn selected(m: *const Model, case_id: []const u8) bool {
        const sel = m.selection orelse return true;
        return inList(sel, case_id);
    }

    fn add(m: *Model, a: Allocator, e: Expect) void {
        const gop = m.index.getOrPut(a, e.path) catch return;
        if (gop.found_existing) return;
        gop.value_ptr.* = m.expects.items.len;
        m.expects.append(a, e) catch {};
    }

    pub fn find(m: *const Model, path: []const u8) ?usize {
        return m.index.get(path);
    }

    fn isNoisy(m: *const Model, path: []const u8) bool {
        for (m.noisy_dirs) |dir| {
            if (std.mem.startsWith(u8, path, dir)) return true;
        }
        return false;
    }
};

/// Loads the root manifest and case files through `ctx.get(path) ?Meta`.
fn loadModel(a: Allocator, d: *Diags, mode: Mode, ctx: anytype) ?Model {
    const root_name = if (mode == .input) input_root_name else manifest_name;
    const rm = ctx.get(root_name) orelse {
        if (!d.has("missing_file")) d.err("missing_file", root_name, "root manifest is absent", .{});
        return null;
    };
    const rv = parseJson(a, rm.bytes) catch |e| {
        d.err(jsonErrorCode(e), root_name, "file does not parse: {s}", .{@errorName(e)});
        return null;
    };
    const root = parseRoot(a, d, rv, mode == .pack) orelse return null;
    var cases: std.ArrayList(Case) = .empty;
    var noisy: std.ArrayList([]const u8) = .empty;
    for (root.case_refs) |r| {
        const dir = loc(a, "cases/{s}/", .{r.case_id});
        const before = d.errors();
        defer if (d.errors() != before) noisy.append(a, dir) catch {};
        const cm = ctx.get(r.path) orelse continue;
        if (r.sha256) |s| {
            if (!std.mem.eql(u8, s, &cm.sha256)) d.err("hash_mismatch", r.path, "SHA256 {s} differs from the root entry {s}", .{ &cm.sha256, s });
        }
        const cv = parseJson(a, cm.bytes) catch |e| {
            d.err(jsonErrorCode(e), r.path, "file does not parse: {s}", .{@errorName(e)});
            continue;
        };
        if (parseCase(a, d, cv, r.case_id, cm.sha256)) |c| cases.append(a, c) catch {};
    }
    const contents = a.alloc(CaseContent, cases.items.len) catch {
        d.err("out_of_memory", root_name, "the case content table ran out of memory", .{});
        return null;
    };
    var m: Model = .{
        .mode = mode,
        .pack = .{ .root = root, .cases = cases.items, .manifest_sha256 = rm.sha256 },
        .contents = contents,
        .noisy_dirs = noisy.items,
    };
    for (m.contents) |*c| c.* = .{};
    crossCheck(a, d, &m.pack);
    return m;
}

/// Checks `capture-selection.json` against the root manifest. The selection names every manifest case once.
fn checkCaptureSelection(a: Allocator, d: *Diags, p: *const Pack, meta: Meta) void {
    const w = capture_selection_name;
    const v = parseJson(a, meta.bytes) catch |e| {
        d.err(jsonErrorCode(e), w, "file does not parse: {s}", .{@errorName(e)});
        return;
    };
    var f = Fields.init(d, v, w, "capture selection") orelse return;
    if (!f.schema(schema_capture_selection)) return;
    _ = f.reqSha("selection_sha256");
    _ = f.reqSha("queue_sha256");
    const total = if (f.present("session_cases")) |x| intOf(x) else null;
    const ids = f.ids(a, "cases");
    if (!f.ok) return;
    if (total == null or total.? < 1 or total.? > std.math.maxInt(u32)) {
        d.err("schema_type", w, "field `session_cases` is not an integer from 1 to 4294967295", .{});
        return;
    }
    if (ids.len == 0) {
        d.err("selection_empty", w, "field `cases` is empty", .{});
        return;
    }
    if (duplicateId(a, ids)) |id| d.err("selection_duplicate", w, "case `{s}` appears twice in field `cases`", .{id});
    if (ids.len > total.?) d.err("selection_mismatch", w, "field `cases` names {d} cases. session_cases is {d}", .{ ids.len, total.? });
    for (ids) |id| {
        if (p.findCase(id) == null) d.err("unknown_case", w, "case `{s}` is not in the manifest", .{id});
    }
    for (p.root.case_refs) |r| {
        if (!inList(ids, r.case_id)) d.err("selection_mismatch", w, "manifest case `{s}` is not in field `cases`", .{r.case_id});
    }
}

/// Reads SUBSET.json and limits the expected files to its cases.
fn applySubset(a: Allocator, d: *Diags, m: *Model, meta: Meta) void {
    m.subset = parseSubset(a, d, m, meta);
    if (m.subset) |s| m.selection = s.cases;
}

fn parseSubset(a: Allocator, d: *Diags, m: *const Model, meta: Meta) ?Subset {
    const v = parseJson(a, meta.bytes) catch |e| {
        d.err(jsonErrorCode(e), subset_name, "file does not parse: {s}", .{@errorName(e)});
        return null;
    };
    var f = Fields.init(d, v, subset_name, "subset record") orelse return null;
    if (!f.schema(schema_subset)) return null;
    const parent = f.str("parent_pack");
    const msha = f.reqSha("parent_manifest_sha256");
    const ids = f.ids(a, "cases");
    if (f.ok and ids.len == 0) {
        d.err("subset_empty", subset_name, "field `cases` is empty. A subset selects at least one case", .{});
        return null;
    }
    if (duplicateId(a, ids)) |id| {
        d.err("selection_duplicate", subset_name, "case `{s}` appears twice in field `cases`", .{id});
        return null;
    }
    if (msha) |s| {
        if (!std.mem.eql(u8, s, &m.pack.manifest_sha256)) d.err("hash_mismatch", subset_name, "parent_manifest_sha256 differs from the MANIFEST.json SHA256 {s}", .{&m.pack.manifest_sha256});
    }
    for (ids) |id| {
        if (m.pack.findCase(id) == null) d.err("unknown_case", subset_name, "case `{s}` is not in the manifest", .{id});
    }
    if (!f.ok) return null;
    return .{ .parent_pack = parent.?, .cases = ids };
}

/// Lists every file of the pack. Files of unselected cases get `selected` false.
fn planExpects(a: Allocator, m: *Model, metas: anytype) void {
    const p = &m.pack;
    if (m.mode == .input) {
        m.add(a, .{ .path = input_root_name, .sha256 = a.dupe(u8, &p.manifest_sha256) catch "", .metadata = true });
    } else {
        m.add(a, .{ .path = manifest_name, .sha256 = a.dupe(u8, &p.manifest_sha256) catch "", .metadata = true });
        if (m.generated) |g| {
            for (generated_reports) |name| m.add(a, .{ .path = name, .sha256 = a.dupe(u8, &sha256Hex(g.get(name))) catch "", .metadata = true });
        }
        m.add(a, .{ .path = sums_name, .sha256 = "", .metadata = true });
        // `checkMeasurements` compares the stored bytes with the counts of the readers.
        const ms: []const u8 = if (metas.peek(measurements_name)) |mm| a.dupe(u8, &mm.sha256) catch "" else "";
        m.add(a, .{ .path = measurements_name, .sha256 = ms, .metadata = true });
        if (m.subset != null) m.add(a, .{ .path = subset_name, .sha256 = "", .metadata = true });
    }
    if (metas.peek(capture_selection_name)) |cs| m.add(a, .{ .path = capture_selection_name, .sha256 = a.dupe(u8, &cs.sha256) catch "", .metadata = true });
    for (p.root.case_refs) |r| {
        const sha: []const u8 = if (r.sha256) |s| s else if (metas.peek(r.path)) |cm| a.dupe(u8, &cm.sha256) catch "" else "";
        m.add(a, .{ .path = r.path, .sha256 = sha, .metadata = true });
    }
    for (p.root.profiles) |x| {
        const path = x.path orelse continue;
        var used = m.selection == null;
        for (p.cases) |c| {
            if (!m.selected(c.case_id)) continue;
            for (c.artifacts) |art| {
                if (art.profile_id != null and std.mem.eql(u8, art.profile_id.?, x.profile_id)) used = true;
            }
        }
        m.add(a, .{ .path = path, .sha256 = x.profile_sha256, .selected = used });
    }
    for (p.root.dependencies) |x| {
        if (!x.state.hasBytes()) continue;
        var used = m.selection == null;
        for (p.cases) |c| {
            if (m.selected(c.case_id) and inList(c.dependencies, x.dependency_id)) used = true;
        }
        m.add(a, .{ .path = x.path, .sha256 = x.sha256.?, .selected = used });
    }
    for (p.cases, 0..) |*c, ci| {
        const dirs = bundleDirs(a, c);
        for (c.artifacts) |*x| {
            if (!x.state.hasBytes()) continue;
            m.add(a, .{
                .path = artifactPackPath(a, c, x),
                .sha256 = x.sha256.?,
                .size = x.size,
                .reader = artifactReader(x, dirs),
                .case_index = ci,
                .selected = m.selected(c.case_id),
                .bundle = x.group == .exports and inBundleDir(dirs, x.path) != null,
            });
        }
    }
}

/// Compares stored generated files with the files regenerated from the metadata.
fn checkGenerated(a: Allocator, d: *Diags, m: *Model, metas: anytype) void {
    const g = m.generated orelse return;
    for (generated_reports) |name| {
        const stored = metas.get(name) orelse continue;
        if (!std.mem.eql(u8, stored.bytes, g.get(name))) d.err("report_mismatch", name, "stored bytes differ from the report regenerated from MANIFEST.json and the case files", .{});
    }
    const sums = renderSums(a, m) catch return;
    if (metas.get(sums_name)) |stored| {
        if (!std.mem.eql(u8, stored.bytes, sums)) d.err("report_mismatch", sums_name, "stored bytes differ from the list regenerated from the metadata", .{});
    }
}

fn openSink(m: *Model, a: Allocator, gpa: Allocator, d: *Diags, i: usize) Sink {
    const e = &m.expects.items[i];
    var s = Sink.init(a, gpa, d, e.path, e.reader);
    if (e.case_index) |ci| {
        s.case = &m.pack.cases[ci];
        s.content = &m.contents[ci];
    }
    return s;
}

fn closeSink(m: *Model, d: *Diags, i: usize, s: *Sink) void {
    const e = &m.expects.items[i];
    e.seen = true;
    const sha = s.finish();
    if (e.case_index) |ci| {
        if (e.bundle or std.mem.indexOf(u8, e.path, "/exports/") != null) m.contents[ci].file_sizes.put(s.a, e.path, s.total) catch d.err("out_of_memory", e.path, "size bookkeeping ran out of memory", .{});
    }
    if (!std.mem.eql(u8, e.sha256, &sha)) d.err("hash_mismatch", e.path, "SHA256 {s} differs from the declared {s}", .{ &sha, e.sha256 });
    if (e.size) |n| {
        if (n != s.total) d.err("size_mismatch", e.path, "file has {d} bytes. The metadata declares {d}", .{ s.total, n });
    }
}

fn finishModel(a: Allocator, d: *Diags, m: *Model) void {
    for (m.expects.items) |e| {
        if (e.selected and !e.metadata and !e.seen) d.err("missing_file", e.path, "listed file is absent", .{});
    }
    for (m.pack.cases, 0..) |*c, ci| {
        if (m.selected(c.case_id)) resolveContent(a, d, c, &m.contents[ci]);
    }
}

/// Lists the counts of the measurement readers for every case, one line per case.
pub fn renderMeasurements(a: Allocator, m: *const Model) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{{\n  \"schema\": \"{s}\",\n  \"cases\": [", .{schema_measurements});
    for (m.pack.cases, 0..) |*c, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try writeMeasurementEntry(w, c.case_id, &m.contents[i]);
    }
    try w.writeAll(if (m.pack.cases.len == 0) "]\n}\n" else "\n  ]\n}\n");
    return out.written();
}

fn writeMeasurementEntry(w: *Io.Writer, case_id: []const u8, cc: *const CaseContent) !void {
    var js: json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("case_id");
    try js.write(case_id);
    try js.objectField("records");
    try js.write(cc.records);
    try js.objectField("measured");
    try js.write(cc.measured);
    try js.objectField("gaps");
    try js.write(cc.gaps);
    try js.objectField("rejected");
    try js.write(cc.rejected);
    try js.endObject();
}

/// Compares the stored MEASUREMENTS.json with the counts of the readers.
/// A whole pack compares bytes. A selection compares the entries of the selected cases.
fn checkMeasurements(a: Allocator, d: *Diags, m: *const Model, stored: ?Meta) void {
    const st = stored orelse return;
    if (m.selection == null) {
        const want = renderMeasurements(a, m) catch return;
        if (!std.mem.eql(u8, st.bytes, want)) d.err("report_mismatch", measurements_name, "stored bytes differ from the counts of the measurement readers", .{});
        return;
    }
    const v = parseJson(a, st.bytes) catch |e| {
        d.err(jsonErrorCode(e), measurements_name, "file does not parse: {s}", .{@errorName(e)});
        return;
    };
    var f = Fields.init(d, v, measurements_name, "measurement report") orelse return;
    if (!f.schema(schema_measurements)) return;
    const list = f.array("cases") orelse return;
    if (list.len != m.pack.cases.len) {
        d.err("report_mismatch", measurements_name, "report lists {d} cases. The manifest lists {d}", .{ list.len, m.pack.cases.len });
        return;
    }
    for (m.pack.cases, 0..) |*c, i| {
        var ew: Io.Writer.Allocating = .init(a);
        writeMeasurementEntry(&ew.writer, c.case_id, &m.contents[i]) catch return;
        var gw: Io.Writer.Allocating = .init(a);
        var js: json.Stringify = .{ .writer = &gw.writer };
        js.write(list[i]) catch return;
        const sel = m.selected(c.case_id);
        const got = gw.written();
        const want = ew.written();
        if (sel and !std.mem.eql(u8, got, want)) {
            d.err("report_mismatch", measurements_name, "entry {d} is `{s}`. The measurement readers give `{s}`", .{ i, got, want });
        } else if (!sel and !std.mem.startsWith(u8, got, want[0 .. std.mem.indexOf(u8, want, ",\"records\"") orelse want.len])) {
            d.err("report_mismatch", measurements_name, "entry {d} is `{s}`. The manifest names case `{s}` there", .{ i, got, c.case_id });
        }
    }
}

/// Totals of the measurement readers over the selected cases.
pub const ContentTotals = struct { records: u64 = 0, measured: u64 = 0, gaps: u64 = 0, rejected: u64 = 0 };

pub fn contentTotals(m: *const Model) ContentTotals {
    var t: ContentTotals = .{};
    for (m.contents) |c| {
        t.records += c.records;
        t.measured += c.measured;
        t.gaps += c.gaps;
        t.rejected += c.rejected;
    }
    return t;
}

// ---------------------------------------------------------------------------
// directory access
// ---------------------------------------------------------------------------

const Opened = struct {
    file: File,
    stat: File.Stat,
};

/// Opens `sub` for reading without following a symbolic link and without waiting for a writer.
/// A FIFO that replaced a regular file after the type check opens at once. The caller then sees
/// the wrong kind from `stat`. A plain open would block without end.
pub fn openNoBlock(dir: Dir, io: Io, sub: []const u8) !File {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return dir.openFile(io, sub, .{ .follow_symlinks = false, .allow_directory = false });
    }
    const fd = std.posix.openat(dir.handle, sub, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |e| switch (e) {
        error.WouldBlock => return error.NotRegular,
        else => return e,
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Opens `path` beneath `base`. Each component is checked with a stat call that does not
/// follow symbolic links and opened with O_NOFOLLOW. The open file must have the inode of the stat.
fn openBeneath(io: Io, base: Dir, path: []const u8) !Opened {
    var cur = base;
    defer if (cur.handle != base.handle) cur.close(io);
    var it = std.mem.splitScalar(u8, path, '/');
    var comp = it.first();
    while (it.next()) |next| {
        const st = try cur.statFile(io, comp, .{ .follow_symlinks = false });
        if (st.kind == .sym_link) return error.SymLink;
        if (st.kind != .directory) return error.NotDir;
        const sub = try cur.openDir(io, comp, .{ .follow_symlinks = false });
        if (cur.handle != base.handle) cur.close(io);
        cur = sub;
        comp = next;
    }
    const st = try cur.statFile(io, comp, .{ .follow_symlinks = false });
    if (st.kind == .sym_link) return error.SymLink;
    if (st.kind != .file) return error.NotRegular;
    const f = try openNoBlock(cur, io, comp);
    errdefer f.close(io);
    const fst = try f.stat(io);
    if (fst.inode != st.inode or fst.kind != .file) return error.FileChanged;
    return .{ .file = f, .stat = fst };
}

fn openErrorCode(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "missing_file",
        error.SymLink, error.SymLinkLoop => "symlink",
        error.NotRegular, error.NotDir, error.IsDir => "special_file",
        error.FileChanged, error.Unstable => "unstable_file",
        else => "read_failed",
    };
}

/// Streams an open file into `sink`. The size and modification time must stay the same
/// and the byte count must equal the size, so the hash covers stable bytes.
fn streamInto(io: Io, o: Opened, sink: *Sink, buf: []u8) !void {
    while (true) {
        const n = o.file.readStreaming(io, &.{buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        sink.feed(buf[0..n]);
    }
    const after = try o.file.stat(io);
    if (after.size != o.stat.size or after.mtime.nanoseconds != o.stat.mtime.nanoseconds or sink.total != o.stat.size) return error.Unstable;
}

/// Reads metadata files beneath a directory on request and keeps them.
const DirMetas = struct {
    a: Allocator,
    gpa: Allocator,
    io: Io,
    d: *Diags,
    base: Dir,
    cache: std.StringHashMapUnmanaged(?Meta) = .empty,

    fn peek(s: *DirMetas, path: []const u8) ?Meta {
        return (s.cache.get(path) orelse return null) orelse null;
    }

    fn get(s: *DirMetas, path: []const u8) ?Meta {
        if (s.cache.get(path)) |m| return m;
        const m = readMeta(s.a, s.gpa, s.io, s.d, s.base, path);
        s.cache.put(s.a, path, m) catch {};
        return m;
    }

    /// Like `get`, but an absent file gets no diagnostic.
    fn getOptional(s: *DirMetas, path: []const u8) ?Meta {
        _ = s.base.statFile(s.io, path, .{ .follow_symlinks = false }) catch return null;
        return s.get(path);
    }
};

fn readMeta(a: Allocator, gpa: Allocator, io: Io, d: *Diags, base: Dir, path: []const u8) ?Meta {
    const o = openBeneath(io, base, path) catch |e| {
        d.err(openErrorCode(e), path, "cannot open: {s}", .{@errorName(e)});
        return null;
    };
    defer o.file.close(io);
    if (o.stat.size > max_metadata_bytes) {
        d.err("too_large_for_reader", path, "metadata file exceeds {d} bytes", .{max_metadata_bytes});
        return null;
    }
    var sink = Sink.init(a, gpa, d, path, .none);
    sink.keep = true;
    defer sink.deinit();
    var buf: [chunk_bytes]u8 = undefined;
    streamInto(io, o, &sink, &buf) catch |e| {
        d.err(openErrorCode(e), path, "read failed: {s}", .{@errorName(e)});
        return null;
    };
    const sha = sink.finish();
    return .{ .bytes = sink.buf.items, .sha256 = sha };
}

/// True when symbolic link `link_path` with `target` resolves outside the tree, judged lexically.
pub fn linkEscapes(link_path: []const u8, target: []const u8) bool {
    if (target.len == 0 or target[0] == '/') return true;
    var depth: isize = @intCast(std.mem.countScalar(u8, link_path, '/'));
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            depth -= 1;
            if (depth < 0) return true;
        } else depth += 1;
    }
    return false;
}

/// Reports every directory entry that the metadata does not list.
fn walkTree(a: Allocator, io: Io, d: *Diags, base: Dir, m: ?*const Model) void {
    var w = base.walk(a) catch return;
    defer w.deinit();
    while (true) {
        const e = (w.next(io) catch |err| {
            d.err("read_failed", ".", "directory walk failed: {s}", .{@errorName(err)});
            return;
        }) orelse break;
        const p = a.dupe(u8, e.path) catch return;
        switch (e.kind) {
            .directory => {},
            .sym_link => {
                var buf: [4096]u8 = undefined;
                const n = e.dir.readLink(io, e.basename, &buf) catch 0;
                const target = buf[0..n];
                d.err("symlink", p, "symbolic link to `{s}` {s}", .{ target, if (linkEscapes(p, target)) "leaves the tree" else "stays inside the tree" });
            },
            .file => {
                if (m) |mm| {
                    if (mm.find(p) != null or mm.isNoisy(p)) continue;
                }
                if (credentialName(p)) {
                    d.err("credential_material", p, "unlisted file name names credential or activation material", .{});
                } else if (std.ascii.startsWithIgnoreCase(e.basename, bundle_reserved_prefix)) {
                    d.err("bundle_unpublished_marker", p, "an open marker, partial file or unlisted bundle file. The publication is not complete", .{});
                } else d.err("unlisted_file", p, "file is not listed in the metadata", .{});
            },
            else => d.err("special_file", p, "entry is a {s}", .{@tagName(e.kind)}),
        }
    }
}

pub const VerifyOptions = struct {
    mode: Mode = .pack,
    /// Check the files of these cases only.
    cases: ?[]const []const u8 = null,
    /// Walk the tree and report unlisted entries.
    walk: bool = true,
    /// The tree must be a whole pack. A `SUBSET.json` file is an error.
    /// Publication, recovery, replication, archives and lineage set this.
    whole: bool = false,
};

/// Forwards to another allocator and remembers that an allocation failed. Many reader and
/// bookkeeping steps of the verifier drop an entry when an allocation fails. The flag makes
/// the whole result an error instead of a smaller clean result.
const FailTrack = struct {
    inner: Allocator,
    failed: bool = false,

    fn allocator(t: *FailTrack) Allocator {
        return .{ .ptr = t, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const t: *FailTrack = @ptrCast(@alignCast(ctx));
        const r = t.inner.rawAlloc(len, alignment, ra);
        if (r == null) t.failed = true;
        return r;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const t: *FailTrack = @ptrCast(@alignCast(ctx));
        return t.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const t: *FailTrack = @ptrCast(@alignCast(ctx));
        return t.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const t: *FailTrack = @ptrCast(@alignCast(ctx));
        t.inner.rawFree(memory, alignment, ra);
    }
};

/// Validates the tree at `base`. `base` must be open with `iterate`. A failed allocation of `a`
/// gives error `out_of_memory` and the result is not trusted.
pub fn verifyDir(a: Allocator, gpa: Allocator, io: Io, d: *Diags, base: Dir, opt: VerifyOptions) ?Model {
    var track: FailTrack = .{ .inner = a };
    const m = verifyDirRun(track.allocator(), gpa, io, d, base, opt);
    if (track.failed) d.err("out_of_memory", ".", "an allocation failed while the tree was checked. The result is not trusted", .{});
    return m;
}

fn verifyDirRun(a: Allocator, gpa: Allocator, io: Io, d: *Diags, base: Dir, opt: VerifyOptions) ?Model {
    if (opt.cases) |want| {
        if (want.len == 0) {
            d.err("selection_empty", "cases", "the case selection is empty. Omit the selection to check the whole pack", .{});
            return null;
        }
        if (duplicateId(a, want)) |id| {
            d.err("selection_duplicate", "cases", "case `{s}` appears twice", .{id});
            return null;
        }
    }
    var metas: DirMetas = .{ .a = a, .gpa = gpa, .io = io, .d = d, .base = base };
    var m = loadModel(a, d, opt.mode, &metas) orelse {
        if (opt.walk) walkTree(a, io, d, base, null);
        return null;
    };
    if (metas.getOptional(capture_selection_name)) |cs| checkCaptureSelection(a, d, &m.pack, cs);
    if (opt.mode == .pack) {
        if (metas.getOptional(subset_name)) |sm| {
            if (opt.whole) {
                d.err("subset_in_pack", subset_name, "a whole pack holds no SUBSET.json. Only an extracted subset archive has one", .{});
            } else applySubset(a, d, &m, sm);
        }
        m.generated = generateReports(a, &m.pack) catch null;
        _ = metas.get(measurements_name);
    }
    if (opt.cases) |want| {
        for (want) |id| {
            if (m.pack.findCase(id) == null) d.err("unknown_case", id, "case is not in the manifest", .{});
            if (m.selection) |sel| {
                if (!inList(sel, id)) d.err("unknown_case", id, "case is not in this subset", .{});
            }
        }
        // A subset keeps its own scope, so every present file is still checked.
        if (m.subset == null) m.selection = want;
    }
    planExpects(a, &m, &metas);
    if (opt.mode == .pack) checkGenerated(a, d, &m, &metas);
    var cit = metas.cache.iterator();
    while (cit.next()) |e| {
        if (e.value_ptr.*) |meta| m.metas.put(a, e.key_ptr.*, meta) catch {};
    }

    const buf = gpa.alloc(u8, chunk_bytes) catch return m;
    defer gpa.free(buf);
    for (m.expects.items, 0..) |e, i| {
        if (e.metadata) continue;
        // `--cases` on a whole pack skips the other cases. A subset checks every file present.
        if (!e.selected and m.subset == null) continue;
        const o = openBeneath(io, base, e.path) catch |err| {
            const code = openErrorCode(err);
            if (std.mem.eql(u8, code, "missing_file")) continue;
            m.expects.items[i].seen = true;
            d.err(code, e.path, "cannot open: {s}", .{@errorName(err)});
            continue;
        };
        defer o.file.close(io);
        if (!e.selected) d.err("unselected_file_present", e.path, "file belongs to a case outside SUBSET.json. A subset archive omits it", .{});
        if (o.stat.nlink > 1) {
            if (e.bundle) {
                d.err("hard_link", e.path, "a bundle file has {d} hard links. A sealed bundle holds files of its own", .{o.stat.nlink});
            } else d.add(.warning, "hard_link", e.path, "file has {d} hard links", .{o.stat.nlink});
        }
        var sink = openSink(&m, a, gpa, d, i);
        defer sink.deinit();
        streamInto(io, o, &sink, buf) catch |err| d.err(openErrorCode(err), e.path, "read failed: {s}", .{@errorName(err)});
        closeSink(&m, d, i, &sink);
    }
    finishModel(a, d, &m);
    if (opt.mode == .pack) checkMeasurements(a, d, &m, metas.peek(measurements_name));
    if (opt.walk) walkTree(a, io, d, base, &m);
    return m;
}


/// Metadata held in memory, for a manifest being built and for archive streams.
const MapMetas = struct {
    a: Allocator,
    d: *Diags,
    map: std.StringHashMapUnmanaged(Meta) = .empty,

    fn put(s: *MapMetas, path: []const u8, bytes: []const u8) void {
        s.map.put(s.a, path, .{ .bytes = bytes, .sha256 = sha256Hex(bytes) }) catch {};
    }

    fn peek(s: *MapMetas, path: []const u8) ?Meta {
        return s.map.get(path);
    }

    fn get(s: *MapMetas, path: []const u8) ?Meta {
        return s.map.get(path) orelse {
            s.d.err("missing_file", path, "listed metadata file is absent", .{});
            return null;
        };
    }
};

// ---------------------------------------------------------------------------
// names and lineage
// ---------------------------------------------------------------------------

pub fn packName(a: Allocator, r: Release, manifest_sha256: [64]u8) []const u8 {
    if (!r.verified) return loc(a, "unverified-release-{s}", .{manifest_sha256[0..16]});
    const raw = loc(a, "{s}-{s}", .{ r.version.?, r.build.? });
    const slug = a.dupe(u8, raw) catch return raw;
    for (slug) |*c| {
        if (!(std.ascii.isAlphanumeric(c.*) or c.* == '.' or c.* == '-')) c.* = '-';
    }
    return loc(a, "{s}-{s}", .{ slug, manifest_sha256[0..16] });
}

/// Compares two packs. Reused revisions with new bytes and changed sources of one release are errors.
pub const LineageCounts = struct { kept: u64 = 0, added: u64 = 0, retired: u64 = 0, changed_sources: u64 = 0 };

fn sameRelease(x: Release, y: Release) bool {
    const eq = struct {
        fn f(p: ?[]const u8, q: ?[]const u8) bool {
            if (p == null or q == null) return p == null and q == null;
            return std.mem.eql(u8, p.?, q.?);
        }
    }.f;
    return x.verified and y.verified and eq(x.version, y.version) and eq(x.build, y.build) and eq(x.edition, y.edition) and eq(x.platform, y.platform);
}

pub fn lineage(a: Allocator, d: *Diags, old: *const Pack, new: *const Pack) LineageCounts {
    var n: LineageCounts = .{};
    const same = sameRelease(old.root.release, new.root.release);
    for (new.cases) |*c| {
        const oc = old.findCase(c.case_id) orelse {
            n.added += 1;
            continue;
        };
        n.kept += 1;
        const w = loc(a, "case:{s}", .{c.case_id});
        const same_recipe = std.mem.eql(u8, oc.recipe_revision, c.recipe_revision);
        if (same_recipe and oc.recipe_sha256 != null and c.recipe_sha256 != null and !std.mem.eql(u8, oc.recipe_sha256.?, c.recipe_sha256.?))
            d.err("recipe_revision_reused", w, "recipe_revision `{s}` names different recipe bytes in the two packs", .{c.recipe_revision});
        for (c.artifacts) |*x| {
            if (!x.state.hasBytes() or !std.mem.startsWith(u8, x.channel, "source_")) continue;
            const ox = findArtifact(oc, x.artifact_id) orelse continue;
            if (!ox.state.hasBytes() or !std.mem.eql(u8, ox.channel, x.channel)) continue;
            if (std.mem.eql(u8, ox.sha256.?, x.sha256.?)) continue;
            n.changed_sources += 1;
            const original = std.mem.eql(u8, x.channel, "source_original");
            if ((original and same_recipe) or same) {
                d.err("source_hash_changed", loc(a, "{s}/{s}", .{ w, x.artifact_id }), "`{s}` bytes changed{s}", .{ x.channel, if (same) " within one release" else " under one recipe_revision" });
            }
        }
    }
    for (old.cases) |c| {
        if (new.findCase(c.case_id) == null) {
            n.retired += 1;
            d.add(.warning, "case_retired", loc(a, "case:{s}", .{c.case_id}), "case is absent from the new pack", .{});
        }
    }
    for (new.root.profiles) |x| {
        const ox = old.findProfile(x.profile_id) orelse continue;
        if (std.mem.eql(u8, ox.profile_revision, x.profile_revision) and !std.mem.eql(u8, ox.profile_sha256, x.profile_sha256))
            d.err("profile_revision_reused", loc(a, "profile:{s}", .{x.profile_id}), "profile_revision `{s}` names different profile bytes in the two packs", .{x.profile_revision});
    }
    return n;
}

// ---------------------------------------------------------------------------
// store: staging, sealing and publication
// ---------------------------------------------------------------------------

pub const packs_dir = "packs";
pub const staging_dir = ".staging";
pub const abandoned_dir = ".abandoned";
const sealed_suffix = ".sealed";
const published_suffix = ".published";

/// Test hook. The build stops at the named point as if the process died there.
pub const CrashPoint = enum { none, after_copy, after_seal, after_rename };

/// Test hook. `run` is called at the named point of `build`, while the build holds the store lock.
pub const HookPoint = enum { before_rename };
pub const Hook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, point: HookPoint) void,
};

/// Store lock file. `build` and `replicate` wait for it. `recover` fails with `store_busy` while another process holds it.
pub const lock_name = ".lock";
const lock_create_attempts = 8;

pub const Published = struct {
    name: []const u8,
    already: bool,
    manifest_sha256: [64]u8,
};

const darwin_c = struct {
    extern "c" fn renameatx_np(fromfd: c_int, from: [*:0]const u8, tofd: c_int, to: [*:0]const u8, flags: c_uint) c_int;
    const RENAME_EXCL: c_uint = 0x4;
};

/// Renames `from` to `to` and fails with PathAlreadyExists when `to` exists.
/// darwin uses renameatx_np with RENAME_EXCL. Other systems use Dir.renamePreserve.
fn renameNoReplace(a: Allocator, io: Io, from_dir: Dir, from: []const u8, to_dir: Dir, to: []const u8) !void {
    if (comptime builtin.os.tag.isDarwin()) {
        const fz = try a.dupeZ(u8, from);
        const tz = try a.dupeZ(u8, to);
        if (darwin_c.renameatx_np(from_dir.handle, fz, to_dir.handle, tz, darwin_c.RENAME_EXCL) == 0) return;
        const e: std.c.E = @enumFromInt(std.c._errno().*);
        return switch (e) {
            .EXIST => error.PathAlreadyExists,
            .NOENT => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            else => error.RenameFailed,
        };
    }
    return Dir.renamePreserve(from_dir, from, to_dir, to, io);
}

/// Calls fsync on a directory through `Io`. libc is not required.
/// Linux opens a directory without `iterate` as O_PATH. fsync on an O_PATH handle returns EBADF, and `Io` panics on EBADF.
/// The `iterate` open of "." gives a handle opened for reading.
fn syncDir(io: Io, dir: Dir) void {
    if (comptime builtin.os.tag == .windows) return;
    const rd = dir.openDir(io, ".", .{ .iterate = true }) catch return;
    defer rd.close(io);
    const f: File = .{ .handle = rd.handle, .flags = .{ .nonblocking = false } };
    f.sync(io) catch {};
}

fn exists(io: Io, dir: Dir, sub: []const u8) bool {
    _ = dir.statFile(io, sub, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn parentOf(path: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return path[0..i];
}

/// Creates `path` with `bytes`. The file must be new.
fn writeNew(io: Io, dir: Dir, path: []const u8, bytes: []const u8) !void {
    if (parentOf(path)) |pp| try dir.createDirPath(io, pp);
    var f = try dir.createFile(io, path, .{ .exclusive = true });
    defer f.close(io);
    var at: usize = 0;
    while (at < bytes.len) {
        const end = @min(bytes.len, at + chunk_bytes);
        try f.writeStreamingAll(io, bytes[at..end]);
        at = end;
    }
    try f.sync(io);
}

/// Copies `path` from `src` to a new file in `dst`. Returns the SHA256 of the stable bytes copied.
fn copyNew(io: Io, src: Dir, dst: Dir, path: []const u8, buf: []u8) ![64]u8 {
    const o = try openBeneath(io, src, path);
    defer o.file.close(io);
    if (parentOf(path)) |pp| try dst.createDirPath(io, pp);
    var f = try dst.createFile(io, path, .{ .exclusive = true });
    defer f.close(io);
    var h: Sha256 = .init(.{});
    var total: u64 = 0;
    while (true) {
        const n = o.file.readStreaming(io, &.{buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        h.update(buf[0..n]);
        total += n;
        try f.writeStreamingAll(io, buf[0..n]);
    }
    const after = try o.file.stat(io);
    if (after.size != o.stat.size or after.mtime.nanoseconds != o.stat.mtime.nanoseconds or total != o.stat.size) return error.Unstable;
    try f.sync(io);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return hexOf(digest);
}

/// Sets published modes below `dir`: files 0444, directories 0555. The root keeps its mode,
/// because darwin needs write permission on a directory to rename it into another parent.
fn sealModes(a: Allocator, io: Io, dir: Dir) !void {
    var dirs: std.ArrayList([]const u8) = .empty;
    var w = try dir.walk(a);
    defer w.deinit();
    while (try w.next(io)) |e| {
        switch (e.kind) {
            .directory => try dirs.append(a, try a.dupe(u8, e.path)),
            .file => try dir.setFilePermissions(io, e.path, File.Permissions.fromMode(0o444), .{ .follow_symlinks = false }),
            else => return error.UnexpectedEntry,
        }
    }
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn gt(_: void, x: []const u8, y: []const u8) bool {
            return x.len > y.len;
        }
    }.gt);
    for (dirs.items) |p| {
        var sub = try dir.openDir(io, p, .{ .follow_symlinks = false });
        syncDir(io, sub);
        sub.close(io);
        try dir.setFilePermissions(io, p, File.Permissions.fromMode(0o555), .{ .follow_symlinks = false });
    }
    syncDir(io, dir);
}

const StoreDirs = struct {
    lock: File,
    packs: Dir,
    staging: Dir,
    abandoned: Dir,

    /// Takes the exclusive store lock, then opens the store directories.
    /// With `wait` false, a held lock gives error.WouldBlock.
    fn open(io: Io, store: Dir, wait: bool) !StoreDirs {
        const lock = try createLock(io, store, wait);
        errdefer lock.close(io);
        for ([_][]const u8{ packs_dir, staging_dir, abandoned_dir }) |n| try store.createDirPath(io, n);
        return .{
            .lock = lock,
            .packs = try store.openDir(io, packs_dir, .{ .follow_symlinks = false, .iterate = true }),
            .staging = try store.openDir(io, staging_dir, .{ .follow_symlinks = false, .iterate = true }),
            .abandoned = try store.openDir(io, abandoned_dir, .{ .follow_symlinks = false, .iterate = true }),
        };
    }

    /// On darwin APFS, two concurrent `openat` calls with `O_CREAT` for one new name can return ENOENT.
    /// In 2000 measured attempts the first retry succeeded. A store directory that is gone still fails after the bound.
    fn createLock(io: Io, store: Dir, wait: bool) !File {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            return store.createFile(io, lock_name, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = !wait }) catch |e| {
                if (e == error.FileNotFound and attempt + 1 < lock_create_attempts) continue;
                return e;
            };
        }
    }

    fn close(s: *StoreDirs, io: Io) void {
        s.packs.close(io);
        s.staging.close(io);
        s.abandoned.close(io);
        s.lock.close(io);
    }
};

const DestState = enum { same, differs, invalid };

/// Verifies the existing `packs/<name>` as a whole pack and compares its manifest SHA256 with `want`.
/// Reports `published_pack_invalid` or `published_pack_differs` and leaves the directory unchanged.
fn checkDestination(a: Allocator, gpa: Allocator, io: Io, d: *Diags, s: *StoreDirs, name: []const u8, want: [64]u8) DestState {
    const where = loc(a, "packs/{s}", .{name});
    var vd = Diags.init(a);
    const m = blk: {
        var dir = s.packs.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch |e| {
            vd.err(openErrorCode(e), name, "cannot open pack: {s}", .{@errorName(e)});
            break :blk null;
        };
        defer dir.close(io);
        break :blk verifyDir(a, gpa, io, &vd, dir, .{ .whole = true });
    };
    if (m == null or vd.errors() > 0) {
        d.err("published_pack_invalid", where, "a directory with this name exists and fails verification. It is left unchanged", .{});
        d.list.appendSlice(d.arena, vd.list.items) catch {};
        return .invalid;
    }
    if (!std.mem.eql(u8, &m.?.pack.manifest_sha256, &want)) {
        d.err("published_pack_differs", where, "the pack with this name has MANIFEST.json SHA256 {s}. This copy has {s}. It is left unchanged", .{ &m.?.pack.manifest_sha256, &want });
        return .differs;
    }
    return .same;
}

/// Verifies a published or staged pack directory with its own diagnostics.
/// Returns the manifest SHA256 when the copy is valid.
fn verifyQuiet(a: Allocator, gpa: Allocator, io: Io, parent: Dir, name: []const u8, out: ?*Diags) ?[64]u8 {
    var dd = Diags.init(a);
    const d = out orelse &dd;
    var dir = parent.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch |e| {
        d.err(openErrorCode(e), name, "cannot open pack: {s}", .{@errorName(e)});
        return null;
    };
    defer dir.close(io);
    const m = verifyDir(a, gpa, io, d, dir, .{ .whole = true }) orelse return null;
    if (d.errors() > 0) return null;
    const want = packName(a, m.pack.root.release, m.pack.manifest_sha256);
    if (!std.mem.eql(u8, want, name) and !std.mem.startsWith(u8, name, loc(a, "{s}.", .{want}))) {
        d.err("pack_name_mismatch", name, "directory name differs from `{s}`", .{want});
        return null;
    }
    return m.pack.manifest_sha256;
}

/// Moves `.staging/<entry>` to `.abandoned/<entry>`. A name taken in `.abandoned` gets a numeric suffix.
fn abandon(a: Allocator, io: Io, s: *StoreDirs, entry: []const u8) !void {
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const to = if (i == 0) entry else loc(a, "{s}.{d}", .{ entry, i });
        renameNoReplace(a, io, s.staging, entry, s.abandoned, to) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        syncDir(io, s.abandoned);
        syncDir(io, s.staging);
        return;
    }
    return error.PathAlreadyExists;
}

/// Writes every file of `m` into a new staging directory, verifies and seals it,
/// then renames it to `packs/<name>` without replacing an existing entry.
/// `bytes` holds the content of generated and metadata files. Every other file is copied from `src`.
fn publish(a: Allocator, gpa: Allocator, io: Io, d: *Diags, store: Dir, name: []const u8, m: *const Model, src: Dir, bytes: *MapMetas, crash: CrashPoint, hook: ?Hook) ?Published {
    var s = StoreDirs.open(io, store, true) catch |e| {
        d.err("store_failed", ".", "cannot lock and open the store directories: {s}", .{@errorName(e)});
        return null;
    };
    defer s.close(io);
    if (exists(io, s.packs, name)) {
        if (checkDestination(a, gpa, io, d, &s, name, m.pack.manifest_sha256) != .same) return null;
        return .{ .name = name, .already = true, .manifest_sha256 = m.pack.manifest_sha256 };
    }
    var nonce_bytes: [8]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
    const stage = loc(a, "{s}.{s}", .{ name, &nonce });
    s.staging.createDir(io, stage, .default_dir) catch |e| {
        d.err("store_failed", stage, "cannot create the staging directory: {s}", .{@errorName(e)});
        return null;
    };
    var sd = s.staging.openDir(io, stage, .{ .follow_symlinks = false, .iterate = true }) catch |e| {
        d.err("store_failed", stage, "cannot open the staging directory: {s}", .{@errorName(e)});
        return null;
    };
    defer sd.close(io);

    const buf = gpa.alloc(u8, chunk_bytes) catch return null;
    defer gpa.free(buf);
    var ok = true;
    for (m.expects.items) |e| {
        if (!e.selected) continue;
        if (bytes.peek(e.path)) |meta| {
            writeNew(io, sd, e.path, meta.bytes) catch |err| {
                d.err("store_failed", e.path, "write failed: {s}", .{@errorName(err)});
                ok = false;
            };
            continue;
        }
        const sha = copyNew(io, src, sd, e.path, buf) catch |err| {
            d.err(openErrorCode(err), e.path, "copy failed: {s}", .{@errorName(err)});
            ok = false;
            continue;
        };
        if (e.sha256.len > 0 and !std.mem.eql(u8, e.sha256, &sha)) {
            d.err("input_changed", e.path, "copied bytes have SHA256 {s}. Validation saw {s}", .{ &sha, e.sha256 });
            ok = false;
        }
    }
    if (crash == .after_copy) return null;
    if (ok) {
        var vd = Diags.init(a);
        if (verifyQuiet(a, gpa, io, s.staging, stage, &vd) == null) {
            d.err("staging_invalid", stage, "the staged copy fails verification", .{});
            d.list.appendSlice(d.arena, vd.list.items) catch {};
            ok = false;
        }
    }
    if (ok) sealModes(a, io, sd) catch |e| {
        d.err("store_failed", stage, "cannot set published modes: {s}", .{@errorName(e)});
        ok = false;
    };
    if (!ok) {
        abandon(a, io, &s, stage) catch {};
        return null;
    }
    const journal = loc(a, "{s}{s}", .{ stage, sealed_suffix });
    const record = loc(a, "{{\"name\": \"{s}\", \"manifest_sha256\": \"{s}\"}}\n", .{ name, &m.pack.manifest_sha256 });
    writeNew(io, s.staging, journal, record) catch |e| {
        d.err("store_failed", journal, "cannot write the seal journal: {s}", .{@errorName(e)});
        abandon(a, io, &s, stage) catch {};
        return null;
    };
    syncDir(io, s.staging);
    if (crash == .after_seal) return null;
    if (hook) |h| h.run(h.ctx, .before_rename);
    return finishPublish(a, gpa, io, d, &s, stage, name, m.pack.manifest_sha256, crash);
}

/// Renames a sealed staging directory into `packs/` and marks its journal published.
/// When `packs/<name>` exists, the existing directory must be a valid pack with manifest `sha`.
/// Otherwise the sealed staging copy and its journal stay in `.staging`.
fn finishPublish(a: Allocator, gpa: Allocator, io: Io, d: *Diags, s: *StoreDirs, stage: []const u8, name: []const u8, sha: [64]u8, crash: CrashPoint) ?Published {
    renameNoReplace(a, io, s.staging, stage, s.packs, name) catch |e| {
        if (e == error.PathAlreadyExists) {
            if (checkDestination(a, gpa, io, d, s, name, sha) != .same) {
                d.err("publish_collision", loc(a, "{s}/{s}", .{ staging_dir, stage }), "the sealed copy stays in .staging with its journal. `recover` publishes it after packs/{s} is removed", .{name});
                return null;
            }
            d.add(.warning, "published_concurrently", name, "another process published the same manifest first. The staged copy moves to .abandoned", .{});
            abandon(a, io, s, stage) catch {};
            abandon(a, io, s, loc(a, "{s}{s}", .{ stage, sealed_suffix })) catch {};
            return .{ .name = name, .already = true, .manifest_sha256 = sha };
        }
        d.err("store_failed", name, "publish rename failed: {s}", .{@errorName(e)});
        return null;
    };
    syncDir(io, s.packs);
    syncDir(io, s.staging);
    if (crash == .after_rename) return null;
    completeJournal(a, io, d, s, stage, name);
    return .{ .name = name, .already = false, .manifest_sha256 = sha };
}

/// Sets the published root mode and renames the journal from `.sealed` to `.published`.
fn completeJournal(a: Allocator, io: Io, d: *Diags, s: *StoreDirs, stage: []const u8, name: []const u8) void {
    s.packs.setFilePermissions(io, name, File.Permissions.fromMode(0o555), .{ .follow_symlinks = false }) catch |e| {
        d.err("store_failed", name, "cannot set the root mode: {s}", .{@errorName(e)});
        return;
    };
    syncDir(io, s.packs);
    renameNoReplace(a, io, s.staging, loc(a, "{s}{s}", .{ stage, sealed_suffix }), s.staging, loc(a, "{s}{s}", .{ stage, published_suffix })) catch |e| {
        d.err("store_failed", stage, "cannot mark the journal published: {s}", .{@errorName(e)});
        return;
    };
    syncDir(io, s.staging);
}

fn realPathAlloc(a: Allocator, io: Io, dir: Dir) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return null;
    return a.dupe(u8, buf[0..n]) catch null;
}

fn within(inner: []const u8, outer: []const u8) bool {
    if (!std.mem.startsWith(u8, inner, outer)) return false;
    return inner.len == outer.len or inner[outer.len] == '/' or std.mem.eql(u8, outer, "/");
}

/// Renders MANIFEST.json from the input root value with the case file hashes filled in.
fn renderManifest(a: Allocator, m: *const Model) ![]const u8 {
    const cases = field(m.pack.root.value, "cases").?.array.items;
    for (cases) |*cv| {
        const id = field(cv.*, "case_id").?.string;
        const i = m.find(loc(a, "cases/{s}/case.json", .{id})) orelse return error.MissingCase;
        try cv.object.put(a, "sha256", .{ .string = m.expects.items[i].sha256 });
    }
    var out: Io.Writer.Allocating = .init(a);
    try json.Stringify.value(m.pack.root.value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

pub const BuildOptions = struct {
    previous: ?Dir = null,
    crash: CrashPoint = .none,
    hook: ?Hook = null,
};

/// Validates an input tree and publishes it as `<store>/packs/<name>`.
pub fn build(a: Allocator, gpa: Allocator, io: Io, d: *Diags, input: Dir, store: Dir, opt: BuildOptions) ?Published {
    const ip = realPathAlloc(a, io, input) orelse {
        d.err("store_failed", ".", "cannot resolve the input tree path", .{});
        return null;
    };
    const sp = realPathAlloc(a, io, store) orelse {
        d.err("store_failed", ".", "cannot resolve the store path", .{});
        return null;
    };
    if (within(ip, sp) or within(sp, ip)) {
        d.err("store_overlaps_input", sp, "the store and the input tree `{s}` contain each other", .{ip});
        return null;
    }
    var im = verifyDir(a, gpa, io, d, input, .{ .mode = .input }) orelse return null;
    if (d.errors() > 0) return null;

    var bytes: MapMetas = .{ .a = a, .d = d };
    const manifest = renderManifest(a, &im) catch |e| {
        d.err("manifest_failed", manifest_name, "cannot render: {s}", .{@errorName(e)});
        return null;
    };
    bytes.put(manifest_name, manifest);
    for (im.pack.root.case_refs) |r| bytes.put(r.path, im.metas.get(r.path).?.bytes);
    if (im.metas.get(capture_selection_name)) |cs| bytes.put(capture_selection_name, cs.bytes);
    var pm = loadModel(a, d, .pack, &bytes) orelse return null;
    pm.generated = generateReports(a, &pm.pack) catch return null;
    for (generated_reports) |n| bytes.put(n, pm.generated.?.get(n));
    bytes.put(measurements_name, renderMeasurements(a, &im) catch return null);
    planExpects(a, &pm, &bytes);
    bytes.put(sums_name, renderSums(a, &pm) catch return null);
    if (d.errors() > 0) return null;

    if (opt.previous) |prev| {
        var pd = Diags.init(a);
        const old = verifyDir(a, gpa, io, &pd, prev, .{ .whole = true });
        if (old == null or pd.errors() > 0) {
            d.err("previous_invalid", "--previous", "the previous pack fails verification", .{});
            d.list.appendSlice(d.arena, pd.list.items) catch {};
            return null;
        }
        _ = lineage(a, d, &old.?.pack, &pm.pack);
        if (d.errors() > 0) return null;
    }
    const name = packName(a, pm.pack.root.release, pm.pack.manifest_sha256);
    return publish(a, gpa, io, d, store, name, &pm, input, &bytes, opt.crash, opt.hook);
}

/// Publishes a verified copy of the whole pack `src` in `store`.
pub fn replicate(a: Allocator, gpa: Allocator, io: Io, d: *Diags, src: Dir, src_name: []const u8, store: Dir, crash: CrashPoint) ?Published {
    const m = verifyDir(a, gpa, io, d, src, .{ .whole = true }) orelse return null;
    if (d.errors() > 0) return null;
    if (m.subset != null) {
        d.err("subset_copy", subset_name, "replicate copies whole packs only", .{});
        return null;
    }
    const name = packName(a, m.pack.root.release, m.pack.manifest_sha256);
    if (!std.mem.eql(u8, name, src_name)) d.add(.warning, "pack_name_mismatch", src_name, "source directory name differs from `{s}`", .{name});
    var bytes: MapMetas = .{ .a = a, .d = d };
    return publish(a, gpa, io, d, store, name, &m, src, &bytes, crash, null);
}

pub const RecoverCounts = struct { published: u64 = 0, abandoned: u64 = 0, repaired: u64 = 0 };

/// Finishes sealed builds and moves unsealed builds to `.abandoned`.
pub fn recover(a: Allocator, gpa: Allocator, io: Io, d: *Diags, store: Dir) RecoverCounts {
    var n: RecoverCounts = .{};
    var s = StoreDirs.open(io, store, false) catch |e| {
        if (e == error.WouldBlock) {
            d.err("store_busy", lock_name, "another process holds the store lock. recover changes nothing", .{});
        } else d.err("store_failed", ".", "cannot lock and open the store directories: {s}", .{@errorName(e)});
        return n;
    };
    defer s.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = s.staging.iterate();
    while (it.next(io) catch null) |e| names.append(a, a.dupe(u8, e.name) catch continue) catch {};
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (names.items) |entry| {
        if (std.mem.endsWith(u8, entry, published_suffix)) continue;
        // Publishing a staging directory renames its journal, which comes later in `names`.
        if (!exists(io, s.staging, entry)) continue;
        if (std.mem.endsWith(u8, entry, sealed_suffix)) {
            const stage = entry[0 .. entry.len - sealed_suffix.len];
            if (exists(io, s.staging, stage)) continue;
            const name = stageName(stage) orelse continue;
            if (!exists(io, s.packs, name)) {
                d.err("journal_without_pack", entry, "sealed journal names `{s}`, which is in neither .staging nor packs", .{name});
                continue;
            }
            completeJournal(a, io, d, &s, stage, name);
            n.repaired += 1;
            continue;
        }
        const name = stageName(entry) orelse {
            d.add(.warning, "unknown_staging_entry", entry, "entry is not a staging directory. It moves to .abandoned", .{});
            abandon(a, io, &s, entry) catch {};
            n.abandoned += 1;
            continue;
        };
        const journal = loc(a, "{s}{s}", .{ entry, sealed_suffix });
        if (!exists(io, s.staging, journal)) {
            abandon(a, io, &s, entry) catch |e| d.err("store_failed", entry, "cannot move to .abandoned: {s}", .{@errorName(e)});
            n.abandoned += 1;
            continue;
        }
        // Recovery applies the same whole-pack verification as `build`.
        var vd = Diags.init(a);
        const sha = verifyQuiet(a, gpa, io, s.staging, entry, &vd) orelse {
            d.err("staging_invalid", entry, "sealed staging copy fails verification. It moves to .abandoned", .{});
            d.list.appendSlice(d.arena, vd.list.items) catch {};
            abandon(a, io, &s, entry) catch {};
            abandon(a, io, &s, journal) catch {};
            n.abandoned += 1;
            continue;
        };
        if (exists(io, s.packs, name)) {
            // A copy of the published manifest is a duplicate. Any other destination keeps the staged copy.
            if (checkDestination(a, gpa, io, d, &s, name, sha) == .same) {
                abandon(a, io, &s, entry) catch {};
                abandon(a, io, &s, journal) catch {};
                n.abandoned += 1;
            }
            continue;
        }
        if (finishPublish(a, gpa, io, d, &s, entry, name, sha, .none)) |p| {
            if (!p.already) n.published += 1;
        }
    }
    return n;
}

/// `<name>.<16 hex digit nonce>` gives `<name>`.
fn stageName(stage: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, stage, '.') orelse return null;
    const nonce = stage[dot + 1 ..];
    if (nonce.len != 16) return null;
    for (nonce) |c| {
        if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return null;
    }
    return stage[0..dot];
}


// ---------------------------------------------------------------------------
// archives
// ---------------------------------------------------------------------------

const tar_block = 512;

fn octal(field_buf: []u8, value: u64) void {
    // The field ends with a NUL. The digits fill the rest, zero padded.
    var v = value;
    var i = field_buf.len - 1;
    field_buf[i] = 0;
    while (i > 0) {
        i -= 1;
        field_buf[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
}

fn paxRecord(w: *Io.Writer, key: []const u8, value: []const u8) !void {
    // The length prefix counts its own digits.
    const body = key.len + value.len + 3;
    var n = body + 1;
    while (std.fmt.count("{d}", .{n}) + body != n) n += 1;
    try w.print("{d} {s}={s}\n", .{ n, key, value });
}

fn tarHeader(w: *Io.Writer, name: []const u8, size: u64, typeflag: u8, mode: u64) !void {
    var h: [tar_block]u8 = @splat(0);
    @memcpy(h[0..@min(name.len, 100)], name[0..@min(name.len, 100)]);
    octal(h[100..108], mode);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], if (size < (1 << 33)) size else 0);
    octal(h[136..148], 0);
    @memset(h[148..156], ' ');
    h[156] = typeflag;
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    var sum: u64 = 0;
    for (h) |b| sum += b;
    octal(h[148..155], sum);
    h[155] = ' ';
    try w.writeAll(&h);
}

/// Writes a ustar header. A name above 100 bytes or a size of 8 GiB or more gets a pax header first.
fn tarEntry(a: Allocator, w: *Io.Writer, name: []const u8, size: u64) !void {
    if (name.len > 100 or size >= (1 << 33)) {
        var rec: Io.Writer.Allocating = .init(a);
        if (name.len > 100) try paxRecord(&rec.writer, "path", name);
        if (size >= (1 << 33)) try paxRecord(&rec.writer, "size", loc(a, "{d}", .{size}));
        const body = rec.written();
        try tarHeader(w, "PaxHeader", body.len, 'x', 0o444);
        try w.writeAll(body);
        try tarPad(w, body.len);
    }
    try tarHeader(w, name, size, '0', 0o444);
}

fn tarPad(w: *Io.Writer, size: u64) !void {
    const rem: usize = @intCast(size % tar_block);
    if (rem == 0) return;
    const zeros: [tar_block]u8 = @splat(0);
    try w.writeAll(zeros[0 .. tar_block - rem]);
}

fn isMetaPath(rel: []const u8) bool {
    for ([_][]const u8{ manifest_name, subset_name, sums_name, measurements_name, capture_selection_name } ++ generated_reports) |n| {
        if (std.mem.eql(u8, rel, n)) return true;
    }
    if (!std.mem.startsWith(u8, rel, "cases/") or !std.mem.endsWith(u8, rel, "/case.json")) return false;
    const mid = rel["cases/".len .. rel.len - "/case.json".len];
    return mid.len > 0 and std.mem.indexOfScalar(u8, mid, '/') == null;
}

pub fn renderSubset(a: Allocator, parent: []const u8, manifest_sha256: [64]u8, cases: []const []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    var js: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("schema");
    try js.write(schema_subset);
    try js.objectField("parent_pack");
    try js.write(parent);
    try js.objectField("parent_manifest_sha256");
    try js.write(&manifest_sha256);
    try js.objectField("cases");
    try js.write(cases);
    try js.endObject();
    try out.writer.writeByte('\n');
    return out.written();
}

/// Writes a pack or a case subset of it as a POSIX tar to `w`.
/// Metadata comes first, so `verifyArchive` can check each later entry while it streams.
/// Returns the top-level directory name in the archive.
pub fn writeArchive(a: Allocator, gpa: Allocator, io: Io, d: *Diags, pack: Dir, pack_name: []const u8, cases: ?[]const []const u8, w: *Io.Writer) ?[]const u8 {
    if (cases) |sel| {
        if (sel.len == 0) {
            d.err("selection_empty", "cases", "the case selection is empty. Pass null to archive the whole pack", .{});
            return null;
        }
        if (duplicateId(a, sel)) |id| {
            d.err("selection_duplicate", "cases", "case `{s}` appears twice", .{id});
            return null;
        }
    }
    var m = verifyDir(a, gpa, io, d, pack, .{ .whole = true }) orelse return null;
    if (d.errors() > 0) return null;
    if (m.subset != null) {
        d.err("subset_copy", subset_name, "archive reads whole packs only", .{});
        return null;
    }
    const name = packName(a, m.pack.root.release, m.pack.manifest_sha256);
    if (!std.mem.eql(u8, name, pack_name)) d.add(.warning, "pack_name_mismatch", pack_name, "directory name differs from `{s}`", .{name});
    var subset_bytes: ?[]const u8 = null;
    var top = name;
    if (cases) |sel| {
        for (sel) |id| {
            if (m.pack.findCase(id) == null) d.err("unknown_case", id, "case is not in the manifest", .{});
        }
        if (d.errors() > 0) return null;
        subset_bytes = renderSubset(a, name, m.pack.manifest_sha256, sel) catch return null;
        top = loc(a, "{s}-subset-{s}", .{ name, sha256Hex(subset_bytes.?)[0..12] });
        m.selection = sel;
        // Plan again so the profiles and dependencies follow the selected cases.
        var fresh: Model = m;
        fresh.expects = .empty;
        fresh.index = .empty;
        var mm: MapMetas = .{ .a = a, .d = d, .map = m.metas };
        planExpects(a, &fresh, &mm);
        m = fresh;
    }
    const buf = gpa.alloc(u8, chunk_bytes) catch return null;
    defer gpa.free(buf);
    const write = struct {
        fn bytes(al: Allocator, ww: *Io.Writer, t: []const u8, path: []const u8, data: []const u8) !void {
            try tarEntry(al, ww, loc(al, "{s}/{s}", .{ t, path }), data.len);
            try ww.writeAll(data);
            try tarPad(ww, data.len);
        }
    };
    var order: std.ArrayList([]const u8) = .empty;
    order.append(a, manifest_name) catch {};
    if (subset_bytes != null) order.append(a, subset_name) catch {};
    order.appendSlice(a, &([_][]const u8{ sums_name, measurements_name } ++ generated_reports)) catch {};
    if (m.metas.get(capture_selection_name) != null) order.append(a, capture_selection_name) catch {};
    for (m.pack.root.case_refs) |r| order.append(a, r.path) catch {};
    for (order.items) |path| {
        const data = if (std.mem.eql(u8, path, subset_name)) subset_bytes.? else (m.metas.get(path) orelse {
            d.err("missing_file", path, "metadata file was not read", .{});
            return null;
        }).bytes;
        write.bytes(a, w, top, path, data) catch |e| {
            d.err("archive_failed", path, "write failed: {s}", .{@errorName(e)});
            return null;
        };
    }
    for (m.expects.items) |e| {
        if (e.metadata or !e.selected) continue;
        const o = openBeneath(io, pack, e.path) catch |err| {
            d.err(openErrorCode(err), e.path, "cannot open: {s}", .{@errorName(err)});
            return null;
        };
        defer o.file.close(io);
        var sink = Sink.init(a, gpa, d, e.path, .none);
        defer sink.deinit();
        tarEntry(a, w, loc(a, "{s}/{s}", .{ top, e.path }), o.stat.size) catch |err| {
            d.err("archive_failed", e.path, "write failed: {s}", .{@errorName(err)});
            return null;
        };
        var total: u64 = 0;
        while (total < o.stat.size) {
            const n = o.file.readStreaming(io, &.{buf[0..@intCast(@min(buf.len, o.stat.size - total))]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    d.err("read_failed", e.path, "read failed: {s}", .{@errorName(err)});
                    return null;
                },
            };
            if (n == 0) break;
            sink.feed(buf[0..n]);
            w.writeAll(buf[0..n]) catch |err| {
                d.err("archive_failed", e.path, "write failed: {s}", .{@errorName(err)});
                return null;
            };
            total += n;
        }
        const sha = sink.finish();
        if (total != o.stat.size or !std.mem.eql(u8, &sha, e.sha256)) {
            d.err("unstable_file", e.path, "bytes changed while the archive was written", .{});
            return null;
        }
        tarPad(w, total) catch return null;
    }
    const zeros: [2 * tar_block]u8 = @splat(0);
    w.writeAll(&zeros) catch return null;
    w.flush() catch return null;
    return top;
}

/// Checks an archive as a stream. It extracts nothing.
pub fn verifyArchive(a: Allocator, gpa: Allocator, d: *Diags, r: *Io.Reader) ?Model {
    var name_buf: [4096]u8 = undefined;
    var link_buf: [4096]u8 = undefined;
    var it = std.tar.Iterator.init(r, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var metas: MapMetas = .{ .a = a, .d = d };
    var model: ?Model = null;
    var in_data = false;
    var top: ?[]const u8 = null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const buf = gpa.alloc(u8, chunk_bytes) catch return null;
    defer gpa.free(buf);
    const finalize = struct {
        fn f(al: Allocator, dd: *Diags, mm: *MapMetas) ?Model {
            var m = loadModel(al, dd, .pack, mm) orelse return null;
            if (mm.peek(capture_selection_name)) |cs| checkCaptureSelection(al, dd, &m.pack, cs);
            if (mm.peek(subset_name)) |sm| applySubset(al, dd, &m, sm);
            m.generated = generateReports(al, &m.pack) catch null;
            _ = mm.get(measurements_name);
            planExpects(al, &m, mm);
            checkGenerated(al, dd, &m, mm);
            var mit = mm.map.iterator();
            while (mit.next()) |e| {
                if (m.find(e.key_ptr.*) == null) dd.err("unlisted_file", e.key_ptr.*, "metadata entry is not listed", .{});
            }
            m.metas = mm.map;
            return m;
        }
    }.f;
    while (true) {
        const f = (it.next() catch |e| {
            d.err("archive_malformed", "archive", "entry header does not parse: {s}", .{@errorName(e)});
            break;
        }) orelse break;
        const full = a.dupe(u8, std.mem.trimEnd(u8, f.name, "/")) catch return null;
        const slash = std.mem.indexOfScalar(u8, full, '/');
        const head = full[0 .. slash orelse full.len];
        if (top == null) {
            if (pathProblem(head)) |why| d.err("invalid_path", full, "top-level directory `{s}`: {s}", .{ head, why });
            top = head;
        } else if (!std.mem.eql(u8, head, top.?)) {
            d.err("archive_prefix", full, "entry is outside the top-level directory `{s}`", .{top.?});
            continue;
        }
        if (f.kind == .directory) continue;
        if (slash == null) {
            d.err("archive_prefix", full, "file entry is outside the top-level directory", .{});
            continue;
        }
        const rel = full[slash.? + 1 ..];
        if (f.kind == .sym_link) {
            d.err("symlink", rel, "symbolic link to `{s}` {s}", .{ f.link_name, if (linkEscapes(rel, f.link_name)) "leaves the tree" else "stays inside the tree" });
            continue;
        }
        if (pathProblem(rel)) |why| {
            d.err("invalid_path", rel, "entry path: {s}", .{why});
            continue;
        }
        const gop = seen.getOrPut(a, lowerDup(a, rel)) catch return null;
        if (gop.found_existing) {
            d.err("duplicate_entry", rel, "path occurs twice after ASCII lowercase", .{});
            continue;
        }
        if (isMetaPath(rel)) {
            if (in_data) {
                d.err("archive_order", rel, "metadata entry follows a data entry", .{});
                continue;
            }
            if (f.size > max_metadata_bytes) {
                d.err("too_large_for_reader", rel, "metadata entry exceeds {d} bytes", .{max_metadata_bytes});
                continue;
            }
            const bytes = a.alloc(u8, @intCast(f.size)) catch return null;
            r.readSliceAll(bytes) catch |e| {
                d.err("archive_malformed", rel, "entry is truncated: {s}", .{@errorName(e)});
                break;
            };
            it.unread_file_bytes = 0;
            var sink = Sink.init(a, gpa, d, rel, .none);
            defer sink.deinit();
            sink.feed(bytes);
            metas.map.put(a, rel, .{ .bytes = bytes, .sha256 = sink.finish() }) catch {};
            continue;
        }
        if (!in_data) {
            in_data = true;
            model = finalize(a, d, &metas);
        }
        const m = if (model) |*mm| mm else continue;
        const i = m.find(rel) orelse {
            if (credentialName(rel)) {
                d.err("credential_material", rel, "unlisted entry name names credential or activation material", .{});
            } else d.err("unlisted_file", rel, "entry is not listed in the metadata", .{});
            continue;
        };
        if (!m.expects.items[i].selected) d.err("unselected_file_present", rel, "entry belongs to a case outside SUBSET.json. A subset archive omits it", .{});
        var sink = openSink(m, a, gpa, d, i);
        defer sink.deinit();
        var left = f.size;
        while (left > 0) {
            const n: usize = @intCast(@min(left, buf.len));
            r.readSliceAll(buf[0..n]) catch |e| {
                d.err("archive_malformed", rel, "entry is truncated: {s}", .{@errorName(e)});
                break;
            };
            sink.feed(buf[0..n]);
            left -= n;
        }
        it.unread_file_bytes = 0;
        closeSink(m, d, i, &sink);
        if (left > 0) break;
    }
    if (!in_data) model = finalize(a, d, &metas);
    if (model) |*m| {
        finishModel(a, d, m);
        checkMeasurements(a, d, m, metas.peek(measurements_name));
        if (top) |t| {
            const want = packName(a, m.pack.root.release, m.pack.manifest_sha256);
            if (!std.mem.startsWith(u8, t, want)) d.add(.warning, "pack_name_mismatch", t, "top-level directory differs from `{s}`", .{want});
        }
    }
    return model;
}

// ---------------------------------------------------------------------------
// copies
// ---------------------------------------------------------------------------

const darwin_statfs = struct {
    const StatFs = extern struct {
        f_bsize: u32,
        f_iosize: i32,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_fsid: [2]i32,
        f_owner: u32,
        f_type: u32,
        f_flags: u32,
        f_fssubtype: u32,
        f_fstypename: [16]u8,
        f_mntonname: [1024]u8,
        f_mntfromname: [1024]u8,
        f_flags_ext: u32,
        f_reserved: [7]u32,
    };
    const fstatfs = @extern(*const fn (c_int, *StatFs) callconv(.c) c_int, .{ .name = if (builtin.cpu.arch == .x86_64) "fstatfs$INODE64" else "fstatfs" });
};

pub const StorageInfo = struct {
    real_path: ?[]const u8 = null,
    device: ?i64 = null,
    mount_source: ?[]const u8 = null,
    mount_point: ?[]const u8 = null,
};

fn storageInfo(a: Allocator, io: Io, dir: Dir) StorageInfo {
    var s: StorageInfo = .{ .real_path = realPathAlloc(a, io, dir) };
    if (comptime builtin.os.tag == .linux) {
        // statx works without libc. The device number packs major and minor for equality tests only.
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{}, &st)) == .SUCCESS)
            s.device = @bitCast((@as(u64, st.dev_major) << 32) | st.dev_minor);
    } else if (comptime builtin.os.tag.isDarwin()) {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(dir.handle, &st) == 0) s.device = @intCast(st.dev);
    }
    if (comptime builtin.os.tag.isDarwin()) {
        var fs: darwin_statfs.StatFs = undefined;
        if (darwin_statfs.fstatfs(dir.handle, &fs) == 0) {
            s.mount_source = a.dupe(u8, std.mem.sliceTo(&fs.f_mntfromname, 0)) catch null;
            s.mount_point = a.dupe(u8, std.mem.sliceTo(&fs.f_mntonname, 0)) catch null;
        }
    }
    return s;
}

/// `/dev/disk3s5` gives `disk3`, the APFS container or whole disk.
fn diskOf(source: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, source, "/dev/disk")) return null;
    var i: usize = "/dev/disk".len;
    while (i < source.len and std.ascii.isDigit(source[i])) i += 1;
    if (i == "/dev/disk".len) return null;
    return source["/dev/".len..i];
}

pub const StorageRelation = enum { same_device, same_apfs_container, different_devices, unknown };

pub fn storageRelation(x: StorageInfo, y: StorageInfo) StorageRelation {
    if (x.device == null or y.device == null) return .unknown;
    if (x.device.? == y.device.?) return .same_device;
    if (x.mount_source != null and y.mount_source != null) {
        const dx = diskOf(x.mount_source.?);
        const dy = diskOf(y.mount_source.?);
        if (dx != null and dy != null and std.mem.eql(u8, dx.?, dy.?)) return .same_apfs_container;
    }
    return .different_devices;
}

pub const CopyResult = struct {
    info: StorageInfo,
    valid: bool,
    errors: usize,
    manifest_sha256: ?[64]u8,
};

/// Verifies two copies and renders the backup record. Returns null when either copy cannot be opened.
pub fn verifyCopies(a: Allocator, gpa: Allocator, io: Io, d: *Diags, x: Dir, y: Dir) ?[]const u8 {
    var results: [2]CopyResult = undefined;
    for ([_]Dir{ x, y }, 0..) |dir, i| {
        var cd = Diags.init(a);
        const m = verifyDir(a, gpa, io, &cd, dir, .{ .whole = true });
        const label = if (i == 0) "copy_a" else "copy_b";
        for (cd.list.items) |e| d.list.append(d.arena, .{ .severity = e.severity, .code = e.code, .location = loc(a, "{s}:{s}", .{ label, e.location }), .message = e.message }) catch {};
        results[i] = .{
            .info = storageInfo(a, io, dir),
            .valid = m != null and cd.errors() == 0 and m.?.subset == null,
            .errors = cd.errors(),
            .manifest_sha256 = if (m) |mm| mm.pack.manifest_sha256 else null,
        };
    }
    const same_manifest = results[0].manifest_sha256 != null and results[1].manifest_sha256 != null and std.mem.eql(u8, &results[0].manifest_sha256.?, &results[1].manifest_sha256.?);
    if (!same_manifest) d.err("copies_differ", "copies", "the two copies have different MANIFEST.json bytes", .{});
    const rel = storageRelation(results[0].info, results[1].info);
    if (rel != .different_devices) d.add(.gap, "copies_share_storage", "copies", "storage_relation is {s}. The two copies are not an independent backup", .{@tagName(rel)});

    var out: Io.Writer.Allocating = .init(a);
    var js: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    const render = struct {
        fn f(j: *json.Stringify, r: []const CopyResult, relation: StorageRelation, same: bool) !void {
            try j.beginObject();
            try j.objectField("schema");
            try j.write(schema_backup);
            try j.objectField("manifest_sha256");
            try j.write(if (same) @as(?[]const u8, &r[0].manifest_sha256.?) else null);
            try j.objectField("copies");
            try j.beginArray();
            for (r) |c| {
                try j.beginObject();
                try j.objectField("real_path");
                try j.write(c.info.real_path);
                try j.objectField("device");
                try j.write(c.info.device);
                try j.objectField("mount_source");
                try j.write(c.info.mount_source);
                try j.objectField("mount_point");
                try j.write(c.info.mount_point);
                try j.objectField("manifest_sha256");
                try j.write(if (c.manifest_sha256) |*s| @as(?[]const u8, s) else null);
                try j.objectField("result");
                try j.write(if (c.valid) "valid" else "invalid");
                try j.objectField("errors");
                try j.write(c.errors);
                try j.endObject();
            }
            try j.endArray();
            try j.objectField("identical");
            try j.write(same);
            try j.objectField("storage_relation");
            try j.write(@tagName(relation));
            try j.objectField("independent_storage_verified");
            try j.write(false);
            try j.endObject();
        }
    }.f;
    render(&js, &results, rel, same_manifest) catch return null;
    out.writer.writeByte('\n') catch return null;
    return out.written();
}

// ---------------------------------------------------------------------------
// single-file validation
// ---------------------------------------------------------------------------

fn validateQueue(a: Allocator, d: *Diags, v: json.Value) void {
    var f = Fields.init(d, v, "queue", "queue") orelse return;
    if (!f.schema(schema_queue)) return;
    if (f.object("release")) |rv| _ = parseRelease(d, rv, "queue.release");
    const cases = f.array("cases") orelse &.{};
    const profiles = f.array("profiles") orelse &.{};
    var pids: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (profiles, 0..) |pv, i| {
        if (parseProfile(d, pv, loc(a, "queue.profiles[{d}]", .{i}))) |p| {
            collide(a, d, &seen, "profile", p.profile_id);
            pids.append(a, p.profile_id) catch {};
        }
    }
    seen = .empty;
    for (cases, 0..) |cv, i| {
        const w = loc(a, "queue.cases[{d}]", .{i});
        var cf = Fields.init(d, cv, w, "queue case") orelse continue;
        if (cf.id("case_id")) |id| collide(a, d, &seen, "case", id);
        _ = cf.id("family_id");
        _ = cf.str("recipe_revision");
        _ = cf.sha("recipe_sha256");
        _ = cf.ids(a, "dependencies");
        if (cf.array("required_channels")) |chs| {
            for (chs) |c| {
                if (c != .string or channelInfo(c.string) == null) d.err("unknown_channel", w, "required_channels holds an entry that is not a registered channel", .{});
            }
        }
        _ = cf.array("expected_relationships");
        for (cf.ids(a, "profile_ids")) |pid| {
            if (!inList(pids.items, pid)) d.err("unknown_profile", w, "profile `{s}` is not in the queue profiles", .{pid});
        }
        _ = cf.array("operations");
    }
}

fn validateOverlay(a: Allocator, d: *Diags, v: json.Value) void {
    var f = Fields.init(d, v, "overlay", "obligation overlay") orelse return;
    if (!f.schema(schema_obligations)) return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (f.array("obligations") orelse &.{}, 0..) |ov, i| {
        if (parseObligation(a, d, ov, loc(a, "overlay.obligations[{d}]", .{i}))) |o| collide(a, d, &seen, "obligation", o.obligation_id);
    }
}

/// Checks one metadata file by its `schema` value. A `.jsonl` file is read as measurement records.
pub fn validateBytes(a: Allocator, gpa: Allocator, d: *Diags, name: []const u8, bytes: []const u8) void {
    if (std.mem.endsWith(u8, name, ".jsonl")) {
        var cc: CaseContent = .{};
        var sink = Sink.init(a, gpa, d, name, .measurements);
        defer sink.deinit();
        sink.content = &cc;
        // Without a case, a record's case_id is compared with the first record's case_id.
        const first_case = blk: {
            const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
            const v = parseJson(a, bytes[0..nl]) catch break :blk "";
            const c = field(v, "case_id") orelse break :blk "";
            break :blk if (c == .string) c.string else "";
        };
        var fake: Case = std.mem.zeroes(Case);
        fake.case_id = first_case;
        sink.case = &fake;
        sink.feed(bytes);
        _ = sink.finish();
        return;
    }
    var key = Sink.init(a, gpa, d, name, .none);
    defer key.deinit();
    key.feed(bytes);
    _ = key.finish();
    const v = parseJson(a, bytes) catch |e| {
        d.err(jsonErrorCode(e), name, "file does not parse: {s}", .{@errorName(e)});
        return;
    };
    const schema = field(v, "schema") orelse {
        d.err("schema_missing_field", name, "field `schema` is missing", .{});
        return;
    };
    if (schema != .string) {
        d.err("schema_type", name, "field `schema` is not a string", .{});
        return;
    }
    const s = schema.string;
    if (std.mem.eql(u8, s, schema_pack)) {
        if (field(v, "cases") != null and field(v, "release") != null) {
            _ = parseRoot(a, d, v, false);
        } else {
            const id = if (field(v, "case_id")) |c| (if (c == .string) c.string else "") else "";
            _ = parseCase(a, d, v, id, sha256Hex(bytes));
        }
    } else if (std.mem.eql(u8, s, schema_queue)) {
        validateQueue(a, d, v);
    } else if (std.mem.eql(u8, s, schema_obligations)) {
        validateOverlay(a, d, v);
    } else if (std.mem.eql(u8, s, schema_frames)) {
        var cc: CaseContent = .{};
        const id = if (field(v, "case_id")) |c| (if (c == .string) c.string else "") else "";
        checkFrames(a, d, &cc, id, name, v);
    } else {
        d.err("schema_id", name, "schema `{s}` has no single-file check. Generated reports are checked by `verify`", .{s});
    }
}

// ---------------------------------------------------------------------------
// command line
// ---------------------------------------------------------------------------

pub const usage_text =
    \\usage: vwx rosetta <command> [arguments]
    \\  validate <file>
    \\  check <tree> [--cases <id,...>]
    \\  build <input-tree> <store> [--previous <pack>]
    \\  verify <pack> [--cases <id,...>]
    \\  archive <pack> <out.tar> [--cases <id,...>]
    \\  verify-archive <file.tar>
    \\  replicate <pack> <store>
    \\  verify-copies <pack-a> <pack-b> <record.json>
    \\  recover <store>
    \\  report <pack> [--cases <id,...>]
    \\  lineage <old-pack> <new-pack>
    \\
;

/// Splits a `--cases` value at commas. Returns null when the value or any item is empty.
fn splitIds(a: Allocator, s: []const u8) ?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |x| {
        if (x.len == 0) return null;
        out.append(a, x) catch return null;
    }
    return out.items;
}

/// The first case ID that appears twice in `ids`.
fn duplicateId(a: Allocator, ids: []const []const u8) ?[]const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (ids) |id| {
        const gop = seen.getOrPut(a, id) catch return null;
        if (gop.found_existing) return id;
    }
    return null;
}

fn baseName(path: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, path, "/");
    return if (std.mem.lastIndexOfScalar(u8, t, '/')) |i| t[i + 1 ..] else t;
}

fn openArgDir(io: Io, path: []const u8) !Dir {
    return Dir.cwd().openDir(io, path, .{ .iterate = true });
}

/// Writes the output file through `<path>.partial.<nonce>` and a rename that never replaces.
fn writeOutput(a: Allocator, io: Io, d: *Diags, path: []const u8, bytes: []const u8) bool {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const tmp = loc(a, "{s}.partial.{s}", .{ path, &std.fmt.bytesToHex(nonce, .lower) });
    writeNew(io, Dir.cwd(), tmp, bytes) catch |e| {
        d.err("write_failed", tmp, "cannot write: {s}", .{@errorName(e)});
        return false;
    };
    renameNoReplace(a, io, Dir.cwd(), tmp, Dir.cwd(), path) catch |e| {
        d.err("write_failed", path, "cannot publish the file without replacing an existing file: {s}. The bytes stay in `{s}`", .{ @errorName(e), tmp });
        return false;
    };
    return true;
}

fn printSummary(w: *Io.Writer, m: *const Model) !void {
    const s = summarize(std.heap.page_allocator, &m.pack);
    try w.print("summary\tmanifest_sha256\t{s}\n", .{&m.pack.manifest_sha256});
    try w.print("summary\tscope\t{s}\n", .{if (m.subset != null) "subset" else if (m.selection != null) "selected_cases" else "whole"});
    try w.print("summary\tcases\t{d}\n", .{s.cases_total});
    // A partial scope counts only the cases whose files were checked.
    var complete = s.complete;
    if (m.selection) |sel| {
        complete = 0;
        for (m.pack.cases) |*c| {
            if (inList(sel, c.case_id) and caseComplete(&m.pack, c)) complete += 1;
        }
    }
    try w.print("summary\tcomplete\t{d}\n", .{complete});
    inline for (@typeInfo(State).@"enum".fields, 0..) |f, i| {
        if (s.by_state[i] > 0) try w.print("summary\tcases_{s}\t{d}\n", .{ f.name, s.by_state[i] });
    }
    inline for (@typeInfo(ObligationStatus).@"enum".fields, 0..) |f, i| try w.print("summary\tobligations_{s}\t{d}\n", .{ f.name, s.obligation_counts[i] });
    const t = contentTotals(m);
    try w.print("summary\tmeasurement_records\t{d}\nsummary\tmeasured\t{d}\nsummary\tmeasurement_gaps\t{d}\nsummary\tmeasurement_rejected\t{d}\n", .{ t.records, t.measured, t.gaps, t.rejected });
    if (m.selection) |sel| try w.print("summary\tselected_cases\t{d}\n", .{sel.len});
}

/// Entry point for `vwx rosetta <command>`. `argv` starts after `rosetta`.
/// Returns 0 when valid, 1 when invalid or failed and 2 for invalid arguments.
pub fn runCli(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d = Diags.init(a);
    const status = runCommand(a, gpa, io, &d, argv, out) catch |e| blk: {
        d.err("failed", "vwx rosetta", "{s}", .{@errorName(e)});
        break :blk @as(u8, 1);
    };
    d.write(out) catch {};
    const final: u8 = if (status == 2) 2 else if (status != 0 or d.errors() > 0) 1 else 0;
    out.print("result\t{s}\n", .{switch (final) {
        0 => "valid",
        1 => "invalid",
        else => "usage",
    }}) catch {};
    out.flush() catch {};
    return final;
}

fn runCommand(a: Allocator, gpa: Allocator, io: Io, d: *Diags, argv: []const []const u8, out: *Io.Writer) !u8 {
    if (argv.len == 0) {
        try out.writeAll(usage_text);
        return 2;
    }
    const cmd = argv[0];
    var pos: std.ArrayList([]const u8) = .empty;
    var cases: ?[]const []const u8 = null;
    var previous: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--cases") and i + 1 < argv.len) {
            i += 1;
            if (cases != null) {
                d.err("option_repeated", "--cases", "the option appears twice", .{});
                return 2;
            }
            // An unset shell variable gives `--cases ""`. The command refuses it with status 2.
            cases = splitIds(a, argv[i]) orelse {
                d.err("selection_empty", "--cases", "the value has an empty case ID. Omit --cases to check the whole pack", .{});
                return 2;
            };
            if (duplicateId(a, cases.?)) |id| {
                d.err("selection_duplicate", "--cases", "case `{s}` appears twice", .{id});
                return 2;
            }
        } else if (std.mem.eql(u8, argv[i], "--previous") and i + 1 < argv.len) {
            i += 1;
            if (previous != null) {
                d.err("option_repeated", "--previous", "the option appears twice", .{});
                return 2;
            }
            previous = argv[i];
        } else if (std.mem.startsWith(u8, argv[i], "--")) {
            try out.writeAll(usage_text);
            return 2;
        } else try pos.append(a, argv[i]);
    }
    const P = pos.items;
    // `build --cases c1` published the whole pack before this check.
    if (cases != null and !inList(&.{ "check", "verify", "report", "archive" }, cmd)) {
        d.err("option_not_accepted", "--cases", "`{s}` takes no --cases", .{cmd});
        try out.writeAll(usage_text);
        return 2;
    }
    if (previous != null and !std.mem.eql(u8, cmd, "build")) {
        d.err("option_not_accepted", "--previous", "`{s}` takes no --previous", .{cmd});
        try out.writeAll(usage_text);
        return 2;
    }
    const want = struct {
        fn n(o: *Io.Writer, have: usize, need: usize) bool {
            if (have == need) return true;
            o.writeAll(usage_text) catch {};
            return false;
        }
    }.n;
    if (std.mem.eql(u8, cmd, "validate")) {
        if (!want(out, P.len, 1)) return 2;
        const bytes = Dir.cwd().readFileAlloc(io, P[0], a, .limited(max_metadata_bytes)) catch |e| {
            d.err(openErrorCode(e), P[0], "cannot read: {s}", .{@errorName(e)});
            return 1;
        };
        validateBytes(a, gpa, d, baseName(P[0]), bytes);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "check") or std.mem.eql(u8, cmd, "verify") or std.mem.eql(u8, cmd, "report")) {
        if (!want(out, P.len, 1)) return 2;
        var dir = try openArgDir(io, P[0]);
        defer dir.close(io);
        const mode: Mode = if (std.mem.eql(u8, cmd, "check") and exists(io, dir, input_root_name)) .input else .pack;
        const m = verifyDir(a, gpa, io, d, dir, .{ .mode = mode, .cases = cases }) orelse return 1;
        if (mode == .pack and m.subset == null) {
            const name = packName(a, m.pack.root.release, m.pack.manifest_sha256);
            if (!std.mem.eql(u8, name, baseName(P[0]))) d.add(.warning, "pack_name_mismatch", P[0], "directory name differs from `{s}`", .{name});
        }
        try printSummary(out, &m);
        if (std.mem.eql(u8, cmd, "report")) {
            const s = summarize(a, &m.pack);
            for (s.obligations) |r| {
                if (r.status == .satisfied) continue;
                // `owner` is free text. Escaping keeps each obligation on one line.
                try out.writeAll("missing\t");
                try writeEscaped(out, r.o.obligation_id);
                try out.writeByte('\t');
                try writeEscaped(out, r.o.case_id);
                try out.print("\t{s}\t", .{@tagName(r.status)});
                for (r.missing_channels, 0..) |ch, k| {
                    if (k > 0) try out.writeByte(',');
                    try writeEscaped(out, ch);
                }
                try out.writeByte('\t');
                try writeEscaped(out, r.o.owner);
                try out.writeByte('\n');
            }
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "build")) {
        if (!want(out, P.len, 2)) return 2;
        var input = try openArgDir(io, P[0]);
        defer input.close(io);
        try Dir.cwd().createDirPath(io, P[1]);
        var store = try openArgDir(io, P[1]);
        defer store.close(io);
        var prev: ?Dir = null;
        if (previous) |pp| prev = try openArgDir(io, pp);
        defer if (prev) |*p| p.close(io);
        const r = build(a, gpa, io, d, input, store, .{ .previous = prev }) orelse return 1;
        try out.print("published\t{s}\t{s}\t{s}\n", .{ if (r.already) "already" else "new", r.name, &r.manifest_sha256 });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "replicate")) {
        if (!want(out, P.len, 2)) return 2;
        var src = try openArgDir(io, P[0]);
        defer src.close(io);
        try Dir.cwd().createDirPath(io, P[1]);
        var store = try openArgDir(io, P[1]);
        defer store.close(io);
        const r = replicate(a, gpa, io, d, src, baseName(P[0]), store, .none) orelse return 1;
        try out.print("published\t{s}\t{s}\t{s}\n", .{ if (r.already) "already" else "new", r.name, &r.manifest_sha256 });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "recover")) {
        if (!want(out, P.len, 1)) return 2;
        var store = try openArgDir(io, P[0]);
        defer store.close(io);
        const n = recover(a, gpa, io, d, store);
        try out.print("recovered\tpublished\t{d}\nrecovered\tabandoned\t{d}\nrecovered\trepaired\t{d}\n", .{ n.published, n.abandoned, n.repaired });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "archive")) {
        if (!want(out, P.len, 2)) return 2;
        var pack = try openArgDir(io, P[0]);
        defer pack.close(io);
        if (exists(io, Dir.cwd(), P[1])) {
            d.err("write_failed", P[1], "output exists. The module never replaces a file", .{});
            return 1;
        }
        var nonce: [8]u8 = undefined;
        io.random(&nonce);
        const tmp = loc(a, "{s}.partial.{s}", .{ P[1], &std.fmt.bytesToHex(nonce, .lower) });
        var f = try Dir.cwd().createFile(io, tmp, .{ .exclusive = true });
        var wbuf: [1 << 16]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        const top = writeArchive(a, gpa, io, d, pack, baseName(P[0]), cases, &fw.interface);
        fw.interface.flush() catch {};
        f.sync(io) catch {};
        f.close(io);
        if (top == null) {
            d.err("archive_failed", tmp, "archive is incomplete. The partial file stays for inspection", .{});
            return 1;
        }
        renameNoReplace(a, io, Dir.cwd(), tmp, Dir.cwd(), P[1]) catch |e| {
            d.err("write_failed", P[1], "cannot publish the archive: {s}. The bytes stay in `{s}`", .{ @errorName(e), tmp });
            return 1;
        };
        try out.writeAll("archive\t");
        try writeEscaped(out, P[1]);
        try out.print("\t{s}\n", .{top.?});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "verify-archive")) {
        if (!want(out, P.len, 1)) return 2;
        var f = try Dir.cwd().openFile(io, P[0], .{});
        defer f.close(io);
        var rbuf: [1 << 16]u8 = undefined;
        var fr = f.readerStreaming(io, &rbuf);
        const m = verifyArchive(a, gpa, d, &fr.interface) orelse return 1;
        try printSummary(out, &m);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "verify-copies")) {
        if (!want(out, P.len, 3)) return 2;
        var x = try openArgDir(io, P[0]);
        defer x.close(io);
        var y = try openArgDir(io, P[1]);
        defer y.close(io);
        const record = verifyCopies(a, gpa, io, d, x, y) orelse return 1;
        if (!writeOutput(a, io, d, P[2], record)) return 1;
        try out.writeAll("record\t");
        try writeEscaped(out, P[2]);
        try out.writeByte('\n');
        return 0;
    }
    if (std.mem.eql(u8, cmd, "lineage")) {
        if (!want(out, P.len, 2)) return 2;
        var x = try openArgDir(io, P[0]);
        defer x.close(io);
        var y = try openArgDir(io, P[1]);
        defer y.close(io);
        const mo = verifyDir(a, gpa, io, d, x, .{ .whole = true }) orelse return 1;
        const mn = verifyDir(a, gpa, io, d, y, .{ .whole = true }) orelse return 1;
        const n = lineage(a, d, &mo.pack, &mn.pack);
        try out.print("lineage\tkept\t{d}\nlineage\tadded\t{d}\nlineage\tretired\t{d}\nlineage\tchanged_sources\t{d}\n", .{ n.kept, n.added, n.retired, n.changed_sources });
        return 0;
    }
    try out.writeAll(usage_text);
    return 2;
}

test {
    std.testing.refAllDecls(@This());
}
