//! Offline export operation directories and sealed file bundles.
//!
//! This module is standalone and unwired. No other source file imports it. It does not change
//! `rosetta_capture.zig` export retries, `storeExport` or any pack channel. Current capture retries
//! stay unsafe for sidecars until a later task wires this module into NativeDriver and capture.
//!
//! One operation directory holds the files of one export attempt. `Operation.create` makes the
//! directory with `mkdir` and refuses a name that already exists. A native exporter then writes the
//! main file and its sidecars into the directory. `Operation.seal` enumerates every regular file,
//! hashes each one through a fixed buffer and publishes a manifest and a seal. `verify` recomputes
//! the same data and reports a `Status`.
//!
//! Integrity scope. A verified bundle shows that the files named in the manifest exist with the
//! recorded size and SHA256, that no other file exists, and that the caller bindings match. It
//! says nothing about file contents. The manifest records `semantics` as `unchecked`. An OBJ
//! `mtllib` reference, a 3DS texture name or an export header check needs a later calibrated
//! reader. A caller declares expected sidecars by path. `seal` refuses a missing declared sidecar.
//! No function here turns a sniff result into geometry or profile acceptance.
//!
//! Directory layout. Five names at the directory root are reserved. Any other root name that starts
//! with `_opdir-` in any ASCII case is refused.
//! - `_opdir-open.json` is written when the directory is created. It is not hashed.
//! - `_opdir-manifest.json.partial` and `_opdir-seal.json.partial` hold bytes before publication.
//! - `_opdir-manifest.json` and `_opdir-seal.json` are the published manifest and seal.
//!
//! Publication protocol. Each publication writes a `.partial` file with an exclusive create, calls
//! `sync`, makes the file read-only (0444) and moves it to its final name with `renamePreserve`.
//! That rename fails when the final name exists. The manifest is published first. The seal is
//! published second and holds the manifest length and SHA256. The seal is the commit point.
//! `verify` reports a bundle as `verified` only when the seal exists, matches the manifest bytes
//! and every file matches the manifest.
//!
//! Interruption detection. A directory with the open marker and no manifest is `unsealed`. A
//! `.partial` file, or a manifest without a seal, is `interrupted`. A seal without a manifest, a
//! truncated manifest, a manifest that differs from the seal digest and any parse failure are
//! `malformed`. A changed, deleted or added file after the seal is `stale`. A symlink, special
//! file, invalid path, case alias or reserved name is `unsafe_tree`. No state is repaired. A new
//! attempt uses a new operation directory.
//!
//! Durability. Each published file is synced and the directory is synced with `fsync` after each
//! rename and after `create`. On macOS `fsync` does not force the drive cache to the platter and
//! the module does not call `F_FULLFSYNC`. A power loss can therefore lose a rename or a file. The
//! state after such a loss is `unsealed`, `interrupted` or `malformed` and never `verified`.
//! A process that stops between `mkdir` and the open marker leaves a directory that `verify`
//! reports as `malformed` with reason `NotOpen`.
//!
//! Residual race assumptions. The tree is not locked. The caller must stop every writer before
//! `seal`. A writer that keeps writing is detected through size, mtime, ctime and inode
//! comparisons before, during and after hashing and through a second scan. A filesystem with
//! coarse timestamps can miss a same-size rewrite inside one tick. Files open with `O_NOFOLLOW`
//! and `O_NONBLOCK`, so a FIFO swapped in after the type check opens at once and fails as
//! `SpecialFile` and never blocks. A regular file swapped in after the scan has another inode and
//! fails as `FileChanged`. A directory component swapped for a symlink between the scan and the
//! open is not detected on platforms where `resolve_beneath` is unsupported. Every regular file
//! with a link count above one fails as `HardLink`. That refusal stops an outside name from
//! sharing the bytes of a bundle payload. It does not stop a link made after `verify` ends.
//!
//! File names. The accepted capture path rules apply unchanged. A name outside
//! `[A-Za-z0-9._+-]`, a name that starts with `.`, `-` or `+`, and a path over 240 bytes,
//! 16 components or 128 bytes per component fail as `InvalidPath`. The module does not rename an
//! exporter dependency. An exporter that writes such a name makes `seal` fail and the caller
//! decides how to name the export.
//!
//! Resource limits. `Limits` bounds entry count, per-file size, total size and manifest size.
//! File bytes pass through one `chunk_bytes` stack buffer. Metadata allocation uses two arenas
//! over the caller allocator. Its size follows entry count and path length, which the limits
//! bound, and does not follow file sizes. Exceeding a limit returns an error from `seal` and the
//! status `limit_exceeded` from `verify`.
//!
//! Ownership and lifetime. `Operation` owns its path and `deinit` frees it. `Sealed` and
//! `Verification` own an arena. Every slice in `Sealed.manifest` stays valid until `deinit`. Spec
//! and expectation slices stay owned by the caller and are copied. A `Diagnostic` copies the path
//! into a fixed buffer.
//!
//! Paths follow the accepted capture rules. `pathProblem` below copies
//! `rosetta_capture.pathProblem`. A test compares the two functions, and the pack function, on a
//! fixed corpus and on random strings. ASCII case aliases follow `OutTree` in
//! `rosetta_capture.zig`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_manifest = "vwx-rosetta-opdir-manifest/1";
pub const schema_seal = "vwx-rosetta-opdir-seal/1";
pub const schema_open = "vwx-rosetta-opdir-open/1";
pub const semantics_unchecked = "unchecked";

pub const reserved_prefix = "_opdir-";
pub const open_name = "_opdir-open.json";
pub const manifest_name = "_opdir-manifest.json";
pub const seal_name = "_opdir-seal.json";
pub const manifest_partial_name = "_opdir-manifest.json.partial";
pub const seal_partial_name = "_opdir-seal.json.partial";

/// Size of the stack buffer that every hash pass reads through.
pub const chunk_bytes = 64 * 1024;

const max_path_bytes: usize = 240;
const max_components: usize = 16;
const max_component_bytes: usize = 128;
const max_small_bytes: usize = 4096;

pub const Limits = struct {
    /// Files and directories below the operation directory.
    max_entries: usize = 4096,
    max_file_bytes: u64 = 64 << 30,
    max_total_bytes: u64 = 256 << 30,
    max_manifest_bytes: usize = 4 << 20,
};

pub const PublishPhase = enum { after_manifest_partial, after_manifest, after_seal_partial };

/// Test and progress hooks. `after_chunk` runs after every hashed chunk with the bytes read so
/// far. `stop_after` makes `seal` return `error.InjectedStop` after that publication phase and
/// leaves the directory as the phase left it.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    after_chunk: ?*const fn (ctx: ?*anyopaque, path: []const u8, offset: u64) void = null,
    /// Runs after the scan and immediately before each file open in `seal` and `verify`. A test
    /// uses it to replace a file between the type check and the open call.
    before_open: ?*const fn (ctx: ?*anyopaque, path: []const u8) void = null,
    stop_after: ?PublishPhase = null,
};

pub const Error = error{
    OperationExists,
    InvalidName,
    InvalidPath,
    InvalidSpec,
    ReservedName,
    CaseAlias,
    DuplicatePath,
    PathConflict,
    Symlink,
    SpecialFile,
    HardLink,
    TooManyEntries,
    FileTooLarge,
    TotalTooLarge,
    ManifestTooLarge,
    FileChanged,
    TreeChanged,
    FileMissing,
    FileAdded,
    FileModified,
    MainFileMissing,
    SidecarMissing,
    AlreadySealed,
    NotOpen,
    Unsealed,
    Interrupted,
    MalformedSeal,
    MalformedManifest,
    ManifestDigestMismatch,
    NotCanonical,
    BindingMismatch,
    InjectedStop,
};

/// Fixed-size record of the path that caused an error. Optional on every call.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn path(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn set(d: ?*Diagnostic, p: []const u8) void {
        const x = d orelse return;
        x.len = @min(p.len, x.buf.len);
        @memcpy(x.buf[0..x.len], p[0..x.len]);
    }
};

// ---------------------------------------------------------------------------
// path rules
// ---------------------------------------------------------------------------

fn idProblem(s: []const u8) ?[]const u8 {
    if (s.len == 0) return "empty";
    if (s.len > 128) return "longer than 128 bytes";
    if (!std.ascii.isAlphanumeric(s[0])) return "first byte is not a letter or digit";
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return "byte outside [A-Za-z0-9._-]";
    }
    return null;
}

/// Null when `p` is a relative path under the accepted capture path rules. Otherwise the reason.
/// Control characters, spaces, backslashes and non-ASCII bytes fail the byte check.
pub fn pathProblem(p: []const u8) ?[]const u8 {
    if (p.len == 0) return "empty";
    if (p.len > max_path_bytes) return "longer than 240 bytes";
    if (p[0] == '/') return "absolute";
    if (p[p.len - 1] == '/') return "trailing slash";
    var it = std.mem.splitScalar(u8, p, '/');
    var n: usize = 0;
    while (it.next()) |c| : (n += 1) {
        if (c.len == 0) return "empty component";
        if (c.len > max_component_bytes) return "component longer than 128 bytes";
        if (std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return "dot component";
        if (!(std.ascii.isAlphanumeric(c[0]) or c[0] == '_')) return "component starts outside [A-Za-z0-9_]";
        for (c) |b| {
            if (!(std.ascii.isAlphanumeric(b) or b == '.' or b == '_' or b == '+' or b == '-')) return "byte outside [A-Za-z0-9._+-]";
        }
    }
    if (n > max_components) return "more than 16 components";
    return null;
}

/// Null when `name` is one valid path component. Used for operation directory names.
pub fn nameProblem(name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return "contains a slash";
    return pathProblem(name);
}

/// Builds an operation name `<profile_id>.a<attempt>` in `buf`. Distinct attempt numbers give
/// distinct directories, so sequential 3DS texture names and OBJ sidecars cannot overwrite one
/// another.
pub fn attemptName(buf: []u8, profile_id: []const u8, attempt: u32) Error![]const u8 {
    if (idProblem(profile_id) != null) return error.InvalidName;
    const s = std.fmt.bufPrint(buf, "{s}.a{d}", .{ profile_id, attempt }) catch return error.InvalidName;
    if (nameProblem(s) != null) return error.InvalidName;
    return s;
}

fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn rootReserved(rel: []const u8) bool {
    const first = if (std.mem.indexOfScalar(u8, rel, '/')) |i| rel[0..i] else rel;
    return std.ascii.startsWithIgnoreCase(first, reserved_prefix);
}

/// Claims directory and file paths by ASCII-lowercase key. Two spellings of one key are a case
/// alias on every volume. All memory comes from `arena`.
const AliasSet = struct {
    arena: Allocator,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    dirs: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn claimOneDir(s: *AliasSet, rel: []const u8) !void {
        const k = try std.ascii.allocLowerString(s.arena, rel);
        if (s.files.get(k)) |f| return if (std.mem.eql(u8, f, rel)) error.PathConflict else error.CaseAlias;
        const gop = try s.dirs.getOrPut(s.arena, k);
        if (!gop.found_existing) {
            gop.value_ptr.* = rel;
            return;
        }
        if (!std.mem.eql(u8, gop.value_ptr.*, rel)) return error.CaseAlias;
    }

    fn claimParents(s: *AliasSet, rel: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |j| : (i = j + 1) {
            try s.claimOneDir(rel[0..j]);
        }
    }

    /// `rel` must stay valid as long as the set. Callers pass arena copies.
    fn claimDir(s: *AliasSet, rel: []const u8) !void {
        try s.claimParents(rel);
        try s.claimOneDir(rel);
    }

    fn claimFile(s: *AliasSet, rel: []const u8) !void {
        try s.claimParents(rel);
        const k = try std.ascii.allocLowerString(s.arena, rel);
        if (s.files.get(k)) |prev| return if (std.mem.eql(u8, prev, rel)) error.DuplicatePath else error.CaseAlias;
        if (s.dirs.get(k)) |prev| return if (std.mem.eql(u8, prev, rel)) error.PathConflict else error.CaseAlias;
        try s.files.put(s.arena, k, rel);
    }
};

// ---------------------------------------------------------------------------
// typed data
// ---------------------------------------------------------------------------

/// Caller-provided bindings. Names match `result.json` in `storeExport`. Each field is checked
/// for form only. The module does not know what the digests identify.
pub const Bindings = struct {
    source_sha256: []const u8,
    state_sha256: []const u8,
    profile_id: []const u8,
    profile_sha256: []const u8,

    fn problem(b: Bindings) ?[]const u8 {
        if (!isSha256(b.source_sha256)) return "source_sha256 is not a lowercase SHA256";
        if (!isSha256(b.state_sha256)) return "state_sha256 is not a lowercase SHA256";
        if (!isSha256(b.profile_sha256)) return "profile_sha256 is not a lowercase SHA256";
        if (idProblem(b.profile_id) != null) return "profile_id is not a valid ID";
        return null;
    }

    fn eql(a: Bindings, b: Bindings) bool {
        return std.mem.eql(u8, a.source_sha256, b.source_sha256) and
            std.mem.eql(u8, a.state_sha256, b.state_sha256) and
            std.mem.eql(u8, a.profile_id, b.profile_id) and
            std.mem.eql(u8, a.profile_sha256, b.profile_sha256);
    }
};

pub const Entry = struct {
    path: []const u8,
    size: u64,
    sha256: [64]u8,
};

/// The typed manifest. `files` is sorted by byte order of `path` and holds every regular file
/// except the reserved names. `expected_sidecars` is sorted and is a subset of `files`.
pub const Manifest = struct {
    op_id: []const u8,
    format: []const u8,
    main_file: []const u8,
    bindings: Bindings,
    expected_sidecars: []const []const u8,
    files: []const Entry,

    pub fn find(m: *const Manifest, path: []const u8) ?*const Entry {
        for (m.files) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }
};

pub const Stats = struct {
    files: u64 = 0,
    bytes_hashed: u64 = 0,
    chunks: u64 = 0,
};

pub const SealSpec = struct {
    format: []const u8,
    /// Relative path of the export's main file. It must exist when `seal` runs.
    main_file: []const u8,
    bindings: Bindings,
    /// Relative paths that must exist. Each is recorded in the manifest.
    expected_sidecars: []const []const u8 = &.{},
    limits: Limits = .{},
    hooks: Hooks = .{},
};

/// A sealed manifest and the digest of its published bytes. Call `deinit` once.
pub const Sealed = struct {
    arena: std.heap.ArenaAllocator,
    manifest: Manifest,
    manifest_sha256: [64]u8,
    stats: Stats,

    pub fn deinit(s: *Sealed) void {
        s.arena.deinit();
    }
};

pub const Expect = struct {
    op_id: ?[]const u8 = null,
    format: ?[]const u8 = null,
    main_file: ?[]const u8 = null,
    bindings: ?Bindings = null,
    /// Paths the manifest must list. A path the manifest omits gives `sidecar_missing`.
    expected_sidecars: []const []const u8 = &.{},
};

pub const VerifyOptions = struct {
    limits: Limits = .{},
    hooks: Hooks = .{},
};

pub const Status = enum {
    verified,
    unsealed,
    interrupted,
    malformed,
    stale,
    binding_mismatch,
    sidecar_missing,
    unsafe_tree,
    limit_exceeded,
};

/// Result of `verify`. `reason` is an error name from `Error` and is a static string.
/// `sealed` is set only when `status` is `verified`.
pub const Verification = struct {
    status: Status,
    reason: []const u8,
    diag: Diagnostic = .{},
    sealed: ?Sealed = null,
    stats: Stats = .{},

    pub fn isVerified(v: *const Verification) bool {
        return v.status == .verified;
    }

    pub fn deinit(v: *Verification) void {
        if (v.sealed) |*s| s.deinit();
        v.sealed = null;
    }
};

// ---------------------------------------------------------------------------
// canonical text
// ---------------------------------------------------------------------------

fn writeManifest(w: *Io.Writer, m: *const Manifest) Io.Writer.Error!void {
    try w.print("{{\"schema\":\"{s}\",\"op_id\":\"{s}\",\"format\":\"{s}\",\"main_file\":\"{s}\",\"semantics\":\"{s}\",", .{ schema_manifest, m.op_id, m.format, m.main_file, semantics_unchecked });
    try w.print("\"bindings\":{{\"source_sha256\":\"{s}\",\"state_sha256\":\"{s}\",\"profile_id\":\"{s}\",\"profile_sha256\":\"{s}\"}},", .{ m.bindings.source_sha256, m.bindings.state_sha256, m.bindings.profile_id, m.bindings.profile_sha256 });
    try w.writeAll("\"expected_sidecars\":[");
    for (m.expected_sidecars, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{s});
    }
    try w.writeAll("],\"files\":[");
    for (m.files, 0..) |*e, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try w.print("{{\"path\":\"{s}\",\"size\":{d},\"sha256\":\"{s}\"}}", .{ e.path, e.size, &e.sha256 });
    }
    if (m.files.len > 0) try w.writeByte('\n');
    try w.writeAll("]}\n");
}

fn writeOpen(w: *Io.Writer, op_id: []const u8) Io.Writer.Error!void {
    try w.print("{{\"schema\":\"{s}\",\"op_id\":\"{s}\"}}\n", .{ schema_open, op_id });
}

fn writeSealText(w: *Io.Writer, op_id: []const u8, manifest_bytes: u64, manifest_sha256: []const u8) Io.Writer.Error!void {
    try w.print("{{\"schema\":\"{s}\",\"op_id\":\"{s}\",\"manifest_bytes\":{d},\"manifest_sha256\":\"{s}\"}}\n", .{ schema_seal, op_id, manifest_bytes, manifest_sha256 });
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var dg: [32]u8 = undefined;
    Sha256.hash(bytes, &dg, .{});
    return std.fmt.bytesToHex(dg, .lower);
}

const WireEntry = struct { path: []const u8, size: u64, sha256: []const u8 };
const WireBindings = struct { source_sha256: []const u8, state_sha256: []const u8, profile_id: []const u8, profile_sha256: []const u8 };
const WireManifest = struct {
    schema: []const u8,
    op_id: []const u8,
    format: []const u8,
    main_file: []const u8,
    semantics: []const u8,
    bindings: WireBindings,
    expected_sidecars: []const []const u8,
    files: []const WireEntry,
};
const WireSeal = struct { schema: []const u8, op_id: []const u8, manifest_bytes: u64, manifest_sha256: []const u8 };

fn parseWire(comptime T: type, a: Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false });
}

// ---------------------------------------------------------------------------
// manifest validation
// ---------------------------------------------------------------------------

fn malformed(diag: ?*Diagnostic, p: []const u8) Error {
    Diagnostic.set(diag, p);
    return error.MalformedManifest;
}

fn validateManifest(scratch: Allocator, m: *const Manifest, limits: Limits, diag: ?*Diagnostic) !void {
    if (nameProblem(m.op_id) != null) return malformed(diag, "op_id");
    if (idProblem(m.format) != null) return malformed(diag, "format");
    if (m.bindings.problem() != null) return malformed(diag, "bindings");
    if (pathProblem(m.main_file) != null or rootReserved(m.main_file)) return malformed(diag, m.main_file);
    if (m.files.len > limits.max_entries) return error.TooManyEntries;
    var aliases: AliasSet = .{ .arena = scratch };
    var total: u64 = 0;
    for (m.files, 0..) |e, i| {
        if (pathProblem(e.path) != null or rootReserved(e.path)) return malformed(diag, e.path);
        if (!isSha256(&e.sha256)) return malformed(diag, e.path);
        if (i > 0 and !std.mem.lessThan(u8, m.files[i - 1].path, e.path)) return malformed(diag, e.path);
        total = std.math.add(u64, total, e.size) catch return malformed(diag, e.path);
        aliases.claimFile(e.path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return malformed(diag, e.path),
        };
    }
    if (m.find(m.main_file) == null) return malformed(diag, m.main_file);
    if (m.expected_sidecars.len > limits.max_entries) return error.TooManyEntries;
    for (m.expected_sidecars, 0..) |s, i| {
        if (pathProblem(s) != null or m.find(s) == null or std.mem.eql(u8, s, m.main_file)) return malformed(diag, s);
        if (i > 0 and !std.mem.lessThan(u8, m.expected_sidecars[i - 1], s)) return malformed(diag, s);
    }
}

fn specProblem(spec: SealSpec) ?[]const u8 {
    if (idProblem(spec.format) != null) return "format";
    if (pathProblem(spec.main_file) != null or rootReserved(spec.main_file)) return spec.main_file;
    if (spec.bindings.problem() != null) return "bindings";
    for (spec.expected_sidecars) |s| {
        if (pathProblem(s) != null or rootReserved(s)) return s;
        if (std.mem.eql(u8, s, spec.main_file)) return s;
    }
    return null;
}

// ---------------------------------------------------------------------------
// tree scan and hashing
// ---------------------------------------------------------------------------

const Found = struct {
    path: []const u8,
    size: u64,
    mtime: i96,
    ctime: i96,
    inode: File.INode,
};

const Internal = struct {
    open: bool = false,
    manifest: bool = false,
    manifest_partial: bool = false,
    seal: bool = false,
    seal_partial: bool = false,
};

const Scan = struct { found: []Found, internal: Internal };

const Ctx = struct {
    io: Io,
    scratch: Allocator,
    limits: Limits,
    hooks: Hooks,
    diag: ?*Diagnostic,

    fn fail(c: *const Ctx, err: Error, p: []const u8) Error {
        Diagnostic.set(c.diag, p);
        return err;
    }
};

fn sameFile(f: Found, st: File.Stat) bool {
    return st.kind == .file and st.size == f.size and st.mtime.toNanoseconds() == f.mtime and
        st.ctime.toNanoseconds() == f.ctime and st.inode == f.inode;
}

fn foundLess(_: void, a: Found, b: Found) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn scanTree(c: *const Ctx, root: Dir) !Scan {
    var list: std.ArrayList(Found) = .empty;
    var aliases: AliasSet = .{ .arena = c.scratch };
    var internal: Internal = .{};
    var count: usize = 0;
    try scanDir(c, root, "", &list, &aliases, &internal, &count);
    std.mem.sort(Found, list.items, {}, foundLess);
    return .{ .found = list.items, .internal = internal };
}

fn aliasError(c: *const Ctx, e: anyerror, rel: []const u8) anyerror {
    return switch (e) {
        error.CaseAlias => c.fail(error.CaseAlias, rel),
        error.DuplicatePath => c.fail(error.DuplicatePath, rel),
        error.PathConflict => c.fail(error.PathConflict, rel),
        else => e,
    };
}

fn scanDir(c: *const Ctx, dir: Dir, prefix: []const u8, list: *std.ArrayList(Found), aliases: *AliasSet, internal: *Internal, count: *usize) !void {
    var it = dir.iterate();
    while (try it.next(c.io)) |ent| {
        var buf: [512]u8 = undefined;
        const rel = if (prefix.len == 0)
            ent.name
        else
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, ent.name }) catch return c.fail(error.InvalidPath, ent.name);
        const st = dir.statFile(c.io, ent.name, .{ .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => return c.fail(error.TreeChanged, rel),
            else => return e,
        };
        if (prefix.len == 0 and std.ascii.startsWithIgnoreCase(ent.name, reserved_prefix)) {
            if (st.kind == .sym_link) return c.fail(error.Symlink, rel);
            if (st.kind != .file) return c.fail(error.SpecialFile, rel);
            if (st.nlink > 1) return c.fail(error.HardLink, rel);
            if (std.mem.eql(u8, ent.name, open_name)) {
                internal.open = true;
            } else if (std.mem.eql(u8, ent.name, manifest_name)) {
                internal.manifest = true;
            } else if (std.mem.eql(u8, ent.name, manifest_partial_name)) {
                internal.manifest_partial = true;
            } else if (std.mem.eql(u8, ent.name, seal_name)) {
                internal.seal = true;
            } else if (std.mem.eql(u8, ent.name, seal_partial_name)) {
                internal.seal_partial = true;
            } else {
                return c.fail(error.ReservedName, rel);
            }
            continue;
        }
        count.* += 1;
        if (count.* > c.limits.max_entries) return c.fail(error.TooManyEntries, rel);
        if (pathProblem(rel) != null) return c.fail(error.InvalidPath, rel);
        const own = try c.scratch.dupe(u8, rel);
        switch (st.kind) {
            .file => {
                if (st.nlink > 1) return c.fail(error.HardLink, rel);
                aliases.claimFile(own) catch |e| return aliasError(c, e, rel);
                try list.append(c.scratch, .{
                    .path = own,
                    .size = st.size,
                    .mtime = st.mtime.toNanoseconds(),
                    .ctime = st.ctime.toNanoseconds(),
                    .inode = st.inode,
                });
            },
            .directory => {
                aliases.claimDir(own) catch |e| return aliasError(c, e, rel);
                var sub = dir.openDir(c.io, ent.name, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
                    error.FileNotFound => return c.fail(error.TreeChanged, rel),
                    else => return e,
                };
                defer sub.close(c.io);
                try scanDir(c, sub, own, list, aliases, internal, count);
            },
            .sym_link => return c.fail(error.Symlink, rel),
            else => return c.fail(error.SpecialFile, rel),
        }
    }
}

fn sameScan(a: []const Found, b: []const Found) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.path, y.path) or x.size != y.size or x.mtime != y.mtime or x.ctime != y.ctime or x.inode != y.inode) return false;
    }
    return true;
}

fn checkSizes(c: *const Ctx, found: []const Found) !void {
    var total: u64 = 0;
    for (found) |f| {
        if (f.size > c.limits.max_file_bytes) return c.fail(error.FileTooLarge, f.path);
        total = std.math.add(u64, total, f.size) catch return c.fail(error.TotalTooLarge, f.path);
        if (total > c.limits.max_total_bytes) return c.fail(error.TotalTooLarge, f.path);
    }
}

/// Opens `sub` below `dir` for reading. Symlinks are not followed and the open never blocks.
/// A FIFO that replaced a regular file after the type check opens at once and the caller then
/// sees `kind != .file` from `stat`. A plain blocking open would wait for a writer without end.
/// The returned file stays in non-blocking mode, which has no effect on a regular file.
pub fn openRegularNoBlock(dir: Dir, io: Io, sub: []const u8) !File {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return dir.openFile(io, sub, .{ .follow_symlinks = false, .allow_directory = false });
    }
    const fd = std.posix.openat(dir.handle, sub, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |e| switch (e) {
        error.WouldBlock => return error.SpecialFile,
        else => return e,
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Streams one file through `chunk_bytes` and returns its SHA256. Fails with `FileChanged` when
/// the size, mtime, ctime or inode differs from the scan record, when the stream is longer or
/// shorter than the recorded size, or when the metadata differs after the last read.
fn hashFile(c: *const Ctx, root: Dir, f: Found, stats: *Stats) ![64]u8 {
    if (c.hooks.before_open) |cb| cb(c.hooks.ctx, f.path);
    const file = openRegularNoBlock(root, c.io, f.path) catch |e| switch (e) {
        error.FileNotFound => return c.fail(error.FileMissing, f.path),
        error.SymLinkLoop => return c.fail(error.Symlink, f.path),
        error.SpecialFile, error.IsDir, error.NotDir => return c.fail(error.SpecialFile, f.path),
        else => return e,
    };
    defer file.close(c.io);
    const st0 = try file.stat(c.io);
    if (st0.kind == .sym_link) return c.fail(error.Symlink, f.path);
    if (st0.kind != .file) return c.fail(error.SpecialFile, f.path);
    if (st0.nlink > 1) return c.fail(error.HardLink, f.path);
    if (!sameFile(f, st0)) return c.fail(error.FileChanged, f.path);
    var h = Sha256.init(.{});
    var buf: [chunk_bytes]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = file.readStreaming(c.io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        total += n;
        if (total > f.size) return c.fail(error.FileChanged, f.path);
        h.update(buf[0..n]);
        stats.chunks += 1;
        if (c.hooks.after_chunk) |cb| cb(c.hooks.ctx, f.path, total);
    }
    if (total != f.size) return c.fail(error.FileChanged, f.path);
    const st1 = try file.stat(c.io);
    if (st1.nlink > 1) return c.fail(error.HardLink, f.path);
    if (!sameFile(f, st1)) return c.fail(error.FileChanged, f.path);
    stats.bytes_hashed += total;
    stats.files += 1;
    var dg: [32]u8 = undefined;
    h.final(&dg);
    return std.fmt.bytesToHex(dg, .lower);
}

// ---------------------------------------------------------------------------
// internal files
// ---------------------------------------------------------------------------

fn readSmall(c: *const Ctx, root: Dir, name: []const u8, limit: usize, too_big: Error) ![]u8 {
    return root.readFileAlloc(c.io, name, c.scratch, .limited(limit + 1)) catch |e| switch (e) {
        error.StreamTooLong => return c.fail(too_big, name),
        else => return e,
    };
}

/// Writes `partial` exclusively, syncs it and makes it read-only. An existing `partial` stays
/// unchanged and gives `AlreadySealed`.
fn writePartial(io: Io, root: Dir, partial: []const u8, bytes: []const u8) !void {
    {
        const f = root.createFile(io, partial, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => return error.AlreadySealed,
            else => return e,
        };
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        try f.sync(io);
    }
    try root.setFilePermissions(io, partial, File.Permissions.fromMode(0o444), .{});
}

/// Moves `partial` to `name`. An existing `name` stays unchanged and gives `AlreadySealed`.
fn publish(io: Io, root: Dir, partial: []const u8, name: []const u8) !void {
    root.renamePreserve(partial, root, name, io) catch |e| switch (e) {
        error.PathAlreadyExists => return error.AlreadySealed,
        else => return e,
    };
    try syncDir(io, root);
}

/// Flushes directory entries of `dir` with `fsync` on its descriptor. On macOS `fsync` does not
/// force the drive cache to the platter. The module does not call `F_FULLFSYNC`.
fn syncDir(io: Io, dir: Dir) !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const f: File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try f.sync(io);
}

fn stopAt(h: Hooks, phase: PublishPhase) Error!void {
    if (h.stop_after) |p| {
        if (p == phase) return error.InjectedStop;
    }
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn findFound(found: []const Found, p: []const u8) ?usize {
    for (found, 0..) |f, i| {
        if (std.mem.eql(u8, f.path, p)) return i;
    }
    return null;
}

fn checkOpenMarker(c: *const Ctx, root: Dir, op_id: []const u8) !void {
    const st = root.statFile(c.io, open_name, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return c.fail(error.NotOpen, open_name),
        else => return e,
    };
    if (st.kind != .file) return c.fail(error.NotOpen, open_name);
    const bytes = try readSmall(c, root, open_name, max_small_bytes, error.NotOpen);
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    writeOpen(&w, op_id) catch return c.fail(error.NotOpen, open_name);
    if (!std.mem.eql(u8, bytes, w.buffered())) return c.fail(error.NotOpen, open_name);
}

// ---------------------------------------------------------------------------
// operation directory
// ---------------------------------------------------------------------------

/// One export attempt directory. `path` is `<root>/<name>`.
pub const Operation = struct {
    gpa: Allocator,
    path: []u8,
    name_start: usize,

    pub fn name(op: *const Operation) []const u8 {
        return op.path[op.name_start..];
    }

    pub fn deinit(op: *Operation) void {
        op.gpa.free(op.path);
        op.* = undefined;
    }

    /// Creates `<root>/<name>` with `mkdir` and writes the open marker. `root` must exist.
    /// Returns `OperationExists` when anything occupies the path, including a file or a
    /// symlink, and changes nothing in that case.
    pub fn create(gpa: Allocator, io: Io, root: []const u8, op_name: []const u8, diag: ?*Diagnostic) !Operation {
        if (nameProblem(op_name) != null) {
            Diagnostic.set(diag, op_name);
            return error.InvalidName;
        }
        if (root.len == 0) return error.InvalidName;
        const trimmed = if (root.len > 1) std.mem.trimEnd(u8, root, "/") else root;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ trimmed, op_name });
        errdefer gpa.free(path);
        Dir.cwd().createDir(io, path, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {
                Diagnostic.set(diag, op_name);
                return error.OperationExists;
            },
            else => return e,
        };
        var d = try Dir.cwd().openDir(io, path, .{ .follow_symlinks = false });
        defer d.close(io);
        var buf: [512]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try writeOpen(&w, op_name);
        const f = try d.createFile(io, open_name, .{ .exclusive = true });
        defer f.close(io);
        try f.writeStreamingAll(io, w.buffered());
        try f.sync(io);
        try syncDir(io, d);
        var parent = try Dir.cwd().openDir(io, trimmed, .{ .follow_symlinks = false });
        defer parent.close(io);
        try syncDir(io, parent);
        return .{ .gpa = gpa, .path = path, .name_start = path.len - op_name.len };
    }

    /// Opens a directory that `create` made earlier. Fails with `NotOpen` when the open marker
    /// is missing or does not name this directory.
    pub fn attach(gpa: Allocator, io: Io, path: []const u8) !Operation {
        const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
        const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| i + 1 else 0;
        if (nameProblem(trimmed[start..]) != null) return error.InvalidName;
        var d = try Dir.cwd().openDir(io, trimmed, .{ .follow_symlinks = false });
        defer d.close(io);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const c: Ctx = .{ .io = io, .scratch = arena.allocator(), .limits = .{}, .hooks = .{}, .diag = null };
        try checkOpenMarker(&c, d, trimmed[start..]);
        return .{ .gpa = gpa, .path = try gpa.dupe(u8, trimmed), .name_start = start };
    }

    /// Returns `<operation path>/<rel>` after the path rules and the reserved-name rule. The
    /// caller frees the result with the operation allocator. No file is created.
    pub fn filePath(op: *const Operation, rel: []const u8) ![]u8 {
        if (pathProblem(rel) != null) return error.InvalidPath;
        if (rootReserved(rel)) return error.ReservedName;
        return std.fmt.allocPrint(op.gpa, "{s}/{s}", .{ op.path, rel });
    }

    /// Creates parent directories and writes `bytes` to a new file `rel`. An existing file stays
    /// unchanged and the call returns `error.PathAlreadyExists`. The caller owns `bytes`. This
    /// helper serves small files such as test payloads.
    pub fn writeFileExclusive(op: *const Operation, io: Io, rel: []const u8, bytes: []const u8) !void {
        const full = try op.filePath(rel);
        defer op.gpa.free(full);
        if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| try Dir.cwd().createDirPath(io, full[0..i]);
        const f = try Dir.cwd().createFile(io, full, .{ .exclusive = true });
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }

    /// Hashes every regular file and publishes the manifest and the seal. On any error before
    /// the manifest rename, the directory holds no manifest and `verify` reports it as
    /// `unsealed`. Existing manifest and seal files are never replaced. The caller must stop
    /// all writers before this call.
    pub fn seal(op: *const Operation, gpa: Allocator, io: Io, spec: SealSpec, diag: ?*Diagnostic) !Sealed {
        if (specProblem(spec)) |p| {
            Diagnostic.set(diag, p);
            return error.InvalidSpec;
        }
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var out = std.heap.ArenaAllocator.init(gpa);
        errdefer out.deinit();
        const c: Ctx = .{ .io = io, .scratch = scratch.allocator(), .limits = spec.limits, .hooks = spec.hooks, .diag = diag };

        var root = try Dir.cwd().openDir(io, op.path, .{ .iterate = true, .follow_symlinks = false });
        defer root.close(io);
        try checkOpenMarker(&c, root, op.name());

        const scan1 = try scanTree(&c, root);
        const in = scan1.internal;
        if (in.manifest or in.seal or in.manifest_partial or in.seal_partial) return c.fail(error.AlreadySealed, manifest_name);
        if (findFound(scan1.found, spec.main_file) == null) return c.fail(error.MainFileMissing, spec.main_file);
        for (spec.expected_sidecars) |s| {
            if (findFound(scan1.found, s) == null) return c.fail(error.SidecarMissing, s);
        }
        try checkSizes(&c, scan1.found);

        var stats: Stats = .{};
        const oa = out.allocator();
        const files = try oa.alloc(Entry, scan1.found.len);
        for (scan1.found, files) |f, *e| {
            const hex = try hashFile(&c, root, f, &stats);
            e.* = .{ .path = try oa.dupe(u8, f.path), .size = f.size, .sha256 = hex };
        }
        const scan2 = try scanTree(&c, root);
        if (!sameScan(scan1.found, scan2.found) or !std.meta.eql(scan1.internal, scan2.internal)) return c.fail(error.TreeChanged, "");

        const sidecars = try oa.alloc([]const u8, spec.expected_sidecars.len);
        for (spec.expected_sidecars, sidecars) |s, *d| d.* = try oa.dupe(u8, s);
        std.mem.sort([]const u8, sidecars, {}, strLess);
        for (sidecars, 0..) |s, i| {
            if (i > 0 and std.mem.eql(u8, sidecars[i - 1], s)) return c.fail(error.InvalidSpec, s);
        }
        const m: Manifest = .{
            .op_id = try oa.dupe(u8, op.name()),
            .format = try oa.dupe(u8, spec.format),
            .main_file = try oa.dupe(u8, spec.main_file),
            .bindings = .{
                .source_sha256 = try oa.dupe(u8, spec.bindings.source_sha256),
                .state_sha256 = try oa.dupe(u8, spec.bindings.state_sha256),
                .profile_id = try oa.dupe(u8, spec.bindings.profile_id),
                .profile_sha256 = try oa.dupe(u8, spec.bindings.profile_sha256),
            },
            .expected_sidecars = sidecars,
            .files = files,
        };
        try validateManifest(c.scratch, &m, spec.limits, diag);

        var tmp: [64]u8 = undefined;
        var counter = Io.Writer.Discarding.init(&tmp);
        try writeManifest(&counter.writer, &m);
        if (counter.fullCount() > spec.limits.max_manifest_bytes) return c.fail(error.ManifestTooLarge, manifest_name);
        const mbytes = try c.scratch.alloc(u8, @intCast(counter.fullCount()));
        var mw: Io.Writer = .fixed(mbytes);
        try writeManifest(&mw, &m);
        const msha = sha256Hex(mbytes);
        var sbuf: [512]u8 = undefined;
        var sw: Io.Writer = .fixed(&sbuf);
        try writeSealText(&sw, m.op_id, mbytes.len, &msha);

        // Every allocation is done. Only publication remains.
        try writePartial(io, root, manifest_partial_name, mbytes);
        try stopAt(spec.hooks, .after_manifest_partial);
        try publish(io, root, manifest_partial_name, manifest_name);
        try stopAt(spec.hooks, .after_manifest);
        try writePartial(io, root, seal_partial_name, sw.buffered());
        try stopAt(spec.hooks, .after_seal_partial);
        try publish(io, root, seal_partial_name, seal_name);
        return .{ .arena = out, .manifest = m, .manifest_sha256 = msha, .stats = stats };
    }
};

// ---------------------------------------------------------------------------
// verification
// ---------------------------------------------------------------------------

/// Recomputes every digest of the bundle at `dir_path` and returns its state. A missing
/// directory and other I/O failures are returned as errors. Every bundle state, including a
/// stale or malformed one, is returned as a `Verification`.
pub fn verify(gpa: Allocator, io: Io, dir_path: []const u8, expect: Expect, opts: VerifyOptions) !Verification {
    var v: Verification = .{ .status = .malformed, .reason = "" };
    var out = std.heap.ArenaAllocator.init(gpa);
    var stats: Stats = .{};
    const result = verifyRun(gpa, io, dir_path, expect, opts, &out, &v.diag, &stats);
    v.stats = stats;
    if (result) |sealed| {
        v.status = .verified;
        v.reason = "verified";
        v.sealed = sealed;
        return v;
    } else |err| {
        out.deinit();
        v.status = switch (err) {
            error.Unsealed => .unsealed,
            error.Interrupted => .interrupted,
            error.NotOpen, error.MalformedSeal, error.MalformedManifest, error.ManifestDigestMismatch, error.NotCanonical => .malformed,
            error.FileChanged, error.TreeChanged, error.FileMissing, error.FileAdded, error.FileModified => .stale,
            error.BindingMismatch => .binding_mismatch,
            error.SidecarMissing => .sidecar_missing,
            error.InvalidPath, error.ReservedName, error.CaseAlias, error.DuplicatePath, error.PathConflict, error.Symlink, error.SpecialFile, error.HardLink => .unsafe_tree,
            error.TooManyEntries, error.FileTooLarge, error.TotalTooLarge, error.ManifestTooLarge => .limit_exceeded,
            else => return err,
        };
        v.reason = @errorName(err);
        return v;
    }
}

fn internalState(c: *const Ctx, root: Dir, name: []const u8) !bool {
    const st = root.statFile(c.io, name, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    if (st.kind == .sym_link) return c.fail(error.Symlink, name);
    if (st.kind != .file) return c.fail(error.SpecialFile, name);
    if (st.nlink > 1) return c.fail(error.HardLink, name);
    return true;
}

fn verifyRun(gpa: Allocator, io: Io, dir_path: []const u8, expect: Expect, opts: VerifyOptions, out: *std.heap.ArenaAllocator, diag: *Diagnostic, stats: *Stats) !Sealed {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const c: Ctx = .{ .io = io, .scratch = scratch.allocator(), .limits = opts.limits, .hooks = opts.hooks, .diag = diag };
    var root = try Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);

    const has_open = try internalState(&c, root, open_name);
    const has_mp = try internalState(&c, root, manifest_partial_name);
    const has_sp = try internalState(&c, root, seal_partial_name);
    const has_m = try internalState(&c, root, manifest_name);
    const has_s = try internalState(&c, root, seal_name);
    if (!has_open) return c.fail(error.NotOpen, open_name);
    if (has_mp) return c.fail(error.Interrupted, manifest_partial_name);
    if (has_sp) return c.fail(error.Interrupted, seal_partial_name);
    if (!has_m and !has_s) return error.Unsealed;
    if (has_m and !has_s) return c.fail(error.Interrupted, manifest_name);
    if (!has_m) return c.fail(error.MalformedSeal, seal_name);

    const sbytes = try readSmall(&c, root, seal_name, max_small_bytes, error.MalformedSeal);
    const ws = parseWire(WireSeal, c.scratch, sbytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return c.fail(error.MalformedSeal, seal_name),
    };
    if (!std.mem.eql(u8, ws.schema, schema_seal) or !isSha256(ws.manifest_sha256) or nameProblem(ws.op_id) != null) return c.fail(error.MalformedSeal, seal_name);
    {
        var buf: [512]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        writeSealText(&w, ws.op_id, ws.manifest_bytes, ws.manifest_sha256) catch return c.fail(error.MalformedSeal, seal_name);
        if (!std.mem.eql(u8, sbytes, w.buffered())) return c.fail(error.MalformedSeal, seal_name);
    }

    const mst = try root.statFile(io, manifest_name, .{ .follow_symlinks = false });
    if (mst.size > opts.limits.max_manifest_bytes) return c.fail(error.ManifestTooLarge, manifest_name);
    const mbytes = try readSmall(&c, root, manifest_name, opts.limits.max_manifest_bytes, error.ManifestTooLarge);
    const msha = sha256Hex(mbytes);
    if (mbytes.len != ws.manifest_bytes or !std.mem.eql(u8, &msha, ws.manifest_sha256)) return c.fail(error.ManifestDigestMismatch, manifest_name);

    const wm = parseWire(WireManifest, c.scratch, mbytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return c.fail(error.MalformedManifest, manifest_name),
    };
    if (!std.mem.eql(u8, wm.schema, schema_manifest) or !std.mem.eql(u8, wm.semantics, semantics_unchecked)) return c.fail(error.MalformedManifest, manifest_name);
    if (wm.files.len > opts.limits.max_entries) return c.fail(error.TooManyEntries, manifest_name);
    const oa = out.allocator();
    const files = try oa.alloc(Entry, wm.files.len);
    for (wm.files, files) |we, *e| {
        if (!isSha256(we.sha256)) return c.fail(error.MalformedManifest, we.path);
        e.* = .{ .path = try oa.dupe(u8, we.path), .size = we.size, .sha256 = we.sha256[0..64].* };
    }
    const sidecars = try oa.alloc([]const u8, wm.expected_sidecars.len);
    for (wm.expected_sidecars, sidecars) |s, *d| d.* = try oa.dupe(u8, s);
    const m: Manifest = .{
        .op_id = try oa.dupe(u8, wm.op_id),
        .format = try oa.dupe(u8, wm.format),
        .main_file = try oa.dupe(u8, wm.main_file),
        .bindings = .{
            .source_sha256 = try oa.dupe(u8, wm.bindings.source_sha256),
            .state_sha256 = try oa.dupe(u8, wm.bindings.state_sha256),
            .profile_id = try oa.dupe(u8, wm.bindings.profile_id),
            .profile_sha256 = try oa.dupe(u8, wm.bindings.profile_sha256),
        },
        .expected_sidecars = sidecars,
        .files = files,
    };
    try validateManifest(c.scratch, &m, opts.limits, diag);
    {
        var aw: Io.Writer.Allocating = .init(c.scratch);
        writeManifest(&aw.writer, &m) catch return error.OutOfMemory;
        if (!std.mem.eql(u8, aw.written(), mbytes)) return c.fail(error.NotCanonical, manifest_name);
    }
    if (!std.mem.eql(u8, m.op_id, ws.op_id)) return c.fail(error.MalformedSeal, seal_name);
    try checkOpenMarker(&c, root, m.op_id);

    if (expect.op_id) |x| if (!std.mem.eql(u8, x, m.op_id)) return c.fail(error.BindingMismatch, "op_id");
    if (expect.format) |x| if (!std.mem.eql(u8, x, m.format)) return c.fail(error.BindingMismatch, "format");
    if (expect.main_file) |x| if (!std.mem.eql(u8, x, m.main_file)) return c.fail(error.BindingMismatch, "main_file");
    if (expect.bindings) |b| if (!b.eql(m.bindings)) return c.fail(error.BindingMismatch, "bindings");
    for (expect.expected_sidecars) |s| {
        if (m.find(s) == null) return c.fail(error.SidecarMissing, s);
    }

    const scan1 = try scanTree(&c, root);
    try checkSizes(&c, scan1.found);
    var i: usize = 0;
    var j: usize = 0;
    while (i < m.files.len or j < scan1.found.len) {
        if (j >= scan1.found.len) return c.fail(error.FileMissing, m.files[i].path);
        if (i >= m.files.len) return c.fail(error.FileAdded, scan1.found[j].path);
        switch (std.mem.order(u8, m.files[i].path, scan1.found[j].path)) {
            .lt => return c.fail(error.FileMissing, m.files[i].path),
            .gt => return c.fail(error.FileAdded, scan1.found[j].path),
            .eq => {
                if (m.files[i].size != scan1.found[j].size) return c.fail(error.FileModified, m.files[i].path);
                i += 1;
                j += 1;
            },
        }
    }
    for (scan1.found, m.files) |f, e| {
        const hex = try hashFile(&c, root, f, stats);
        if (!std.mem.eql(u8, &hex, &e.sha256)) return c.fail(error.FileModified, f.path);
    }
    const scan2 = try scanTree(&c, root);
    if (!sameScan(scan1.found, scan2.found)) return c.fail(error.TreeChanged, "");
    return .{ .arena = out.*, .manifest = m, .manifest_sha256 = msha, .stats = stats.* };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
//
// Filesystem tests resolve the repository root with `git rev-parse --show-toplevel`.
// Each test creates its scratch directory with `mktemp -d /tmp/opdir-test.XXXXXX`.
// `Scratch.deinit` sources `tools/discard.sh` and calls `discard`.
// A test that needs a file to disappear renames it within its scratch directory.

const testing = std.testing;

const h1 = "1" ** 64;
const h2 = "2" ** 64;
const h3 = "3" ** 64;
const bind_a: Bindings = .{ .source_sha256 = h1, .state_sha256 = h2, .profile_id = "obj.mesh", .profile_sha256 = h3 };

pub const Scratch = struct {
    path: []u8,

    pub fn init() !Scratch {
        const r = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "mktemp", "-d", "/tmp/opdir-test.XXXXXX" } });
        defer testing.allocator.free(r.stdout);
        defer testing.allocator.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) return error.MktempFailed;
        const p = std.mem.trimEnd(u8, r.stdout, "\n");
        if (!std.mem.startsWith(u8, p, "/tmp/opdir-test.") or std.mem.indexOf(u8, p, "..") != null) return error.MktempUnexpectedPath;
        return .{ .path = try testing.allocator.dupe(u8, p) };
    }

    pub fn deinit(s: *Scratch) void {
        defer testing.allocator.free(s.path);
        if (!std.mem.startsWith(u8, s.path, "/tmp/opdir-test.")) return;
        const r = std.process.run(testing.allocator, testing.io, .{
            .argv = &.{ "sh", "-c", "root=$(git rev-parse --show-toplevel) && . \"$root/tools/discard.sh\" && discard \"$1\"", "sh", s.path },
        }) catch {
            std.debug.print("scratch {s} was not discarded. discard did not run\n", .{s.path});
            return;
        };
        defer testing.allocator.free(r.stdout);
        defer testing.allocator.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) std.debug.print("scratch {s} was not discarded. discard failed\n", .{s.path});
    }

    pub fn join(s: *const Scratch, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ s.path, rel });
    }

    pub fn mkdir(s: *const Scratch, rel: []const u8) !void {
        const p = try s.join(rel);
        defer testing.allocator.free(p);
        try Dir.cwd().createDir(testing.io, p, .default_dir);
    }

    fn op(s: *const Scratch, name: []const u8) !Operation {
        return Operation.create(testing.allocator, testing.io, s.path, name, null);
    }
};

fn put(op: *const Operation, rel: []const u8, bytes: []const u8) !void {
    try op.writeFileExclusive(testing.io, rel, bytes);
}

fn opPath(op: *const Operation, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ op.path, rel });
}

fn readRel(op: *const Operation, rel: []const u8) ![]u8 {
    const p = try opPath(op, rel);
    defer testing.allocator.free(p);
    return Dir.cwd().readFileAlloc(testing.io, p, testing.allocator, .limited(1 << 24));
}

/// Moves a file out of the operation directory into the scratch directory.
fn moveAway(s: *const Scratch, op: *const Operation, rel: []const u8, as: []const u8) !void {
    const from = try opPath(op, rel);
    defer testing.allocator.free(from);
    const to = try s.join(as);
    defer testing.allocator.free(to);
    try Dir.rename(Dir.cwd(), from, Dir.cwd(), to, testing.io);
}

/// Writes `bytes` at `offset` of an existing file without truncating it.
fn patch(op: *const Operation, rel: []const u8, offset: u64, bytes: []const u8) !void {
    const p = try opPath(op, rel);
    defer testing.allocator.free(p);
    const f = try Dir.cwd().createFile(testing.io, p, .{ .truncate = false });
    defer f.close(testing.io);
    try f.writePositionalAll(testing.io, bytes, offset);
}

fn specOf(main: []const u8, sidecars: []const []const u8) SealSpec {
    return .{ .format = "obj", .main_file = main, .bindings = bind_a, .expected_sidecars = sidecars };
}

fn sealOp(op: *const Operation, main: []const u8, sidecars: []const []const u8) !Sealed {
    return op.seal(testing.allocator, testing.io, specOf(main, sidecars), null);
}

fn check(op: *const Operation, expect: Expect) !Verification {
    return verify(testing.allocator, testing.io, op.path, expect, .{});
}

fn expectState(op: *const Operation, status: Status, reason: []const u8) !void {
    var v = try check(op, .{});
    defer v.deinit();
    if (v.status != status or !std.mem.eql(u8, v.reason, reason)) {
        std.debug.print("expected {s}/{s}, found {s}/{s} at `{s}`\n", .{ @tagName(status), reason, @tagName(v.status), v.reason, v.diag.path() });
        return error.TestUnexpectedResult;
    }
}

/// A small verified bundle with an OBJ main file, one MTL sidecar and one binary sidecar.
fn makeBundle(s: *const Scratch, name: []const u8) !Operation {
    var op = try s.op(name);
    errdefer op.deinit();
    try put(&op, "model.obj", "mtllib model.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n");
    try put(&op, "model.mtl", "newmap\nmap_Kd tex/a.bin\n");
    try put(&op, "tex/a.bin", "0123456789");
    var sl = try sealOp(&op, "model.obj", &.{"model.mtl"});
    sl.deinit();
    return op;
}

test "path rules match the accepted capture and pack functions" {
    const capture = @import("rosetta_capture.zig");
    const pack = @import("rosetta_pack.zig");
    const long_ok = "a" ** 128;
    const corpus = [_][]const u8{
        "",            "a",       "a/b",          "a/b/c.obj",               "_x",                              "9.3ds",
        "/abs",        "a/",      "a//b",         "a/./b",                   "a/../b",                          "..",
        ".",           ".hidden", "a/.hidden",    "-lead",                   "+lead",                           "a b",
        "a\tb",        "a\nb",    "a\x00b",       "a\x01b",                  "a\x7fb",                          "a\\b",
        "caf\xc3\xa9", "a:b",     "a*b",          "a?b",                     "A.MTL",                           "tex_001.bin",
        "x+y-z_1.2",   long_ok,   long_ok ++ "a", long_ok ++ "/" ++ long_ok, "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p", "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q",
    };
    for (corpus) |p| {
        try testing.expectEqualDeep(capture.pathProblem(p), pathProblem(p));
        try testing.expectEqual(pack.pathProblem(p) == null, pathProblem(p) == null);
    }
    const full240 = "abcdefghijklmn/" ** 15 ++ "abcdefghijklmno";
    try testing.expectEqual(@as(usize, 240), full240.len);
    try testing.expect(pathProblem(full240) == null);
    try testing.expect(pathProblem(full240 ++ "x") != null);
    try testing.expectEqualDeep(capture.pathProblem(full240 ++ "x"), pathProblem(full240 ++ "x"));

    var prng = std.Random.DefaultPrng.init(0x0bd1);
    const rnd = prng.random();
    const alphabet = "aZ09_.+-/\\ \x01\x7f\x80\xc3~:";
    var buf: [40]u8 = undefined;
    var n: usize = 0;
    while (n < 30000) : (n += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        const p = buf[0..len];
        try testing.expectEqualDeep(capture.pathProblem(p), pathProblem(p));
        try testing.expectEqual(pack.pathProblem(p) == null, pathProblem(p) == null);
    }
}

test "reserved names satisfy the path rules and root names are classified" {
    for ([_][]const u8{ open_name, manifest_name, seal_name, manifest_partial_name, seal_partial_name }) |n| {
        try testing.expect(pathProblem(n) == null);
        try testing.expect(rootReserved(n));
    }
    try testing.expect(rootReserved("_OPDIR-x"));
    try testing.expect(rootReserved("_opdir-dir/file"));
    try testing.expect(!rootReserved("sub/_opdir-seal.json"));
    try testing.expect(!rootReserved("_opdi"));
    try testing.expect(nameProblem("a/b") != null);
    try testing.expect(nameProblem("3ds.mesh.a1") == null);
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("3ds.mesh.a2", try attemptName(&buf, "3ds.mesh", 2));
    try testing.expectError(error.InvalidName, attemptName(&buf, "bad id", 1));
    try testing.expectError(error.InvalidName, attemptName(&buf, "a" ** 200, 1));
}

test "alias set separates spellings, duplicates and file or directory conflicts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s: AliasSet = .{ .arena = arena.allocator() };
    try s.claimFile("A.mtl");
    try testing.expectError(error.CaseAlias, s.claimFile("a.mtl"));
    try testing.expectError(error.DuplicatePath, s.claimFile("A.mtl"));
    try s.claimFile("dir/x");
    try testing.expectError(error.CaseAlias, s.claimFile("DIR/y"));
    try s.claimFile("dir/y");
    try testing.expectError(error.PathConflict, s.claimFile("dir"));
    try testing.expectError(error.CaseAlias, s.claimFile("Dir"));
    try testing.expectError(error.PathConflict, s.claimFile("A.mtl/z"));
    try testing.expectError(error.CaseAlias, s.claimFile("a.MTL/z"));
    try s.claimDir("other");
    try s.claimDir("other");
    try testing.expectError(error.CaseAlias, s.claimDir("OTHER"));
}

test "empty operation is unsealed and seal refuses a missing main file" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var op = try sc.op("p.a1");
    defer op.deinit();
    try expectState(&op, .unsealed, "Unsealed");
    var d: Diagnostic = .{};
    try testing.expectError(error.MainFileMissing, op.seal(testing.allocator, testing.io, specOf("model.obj", &.{}), &d));
    try testing.expectEqualStrings("model.obj", d.path());
    try expectState(&op, .unsealed, "Unsealed");
    try put(&op, "model.obj", "o x\n");
    try expectState(&op, .unsealed, "Unsealed");
}

test "multi-file bundles list every file in byte order whatever the creation order" {
    var sc = try Scratch.init();
    defer sc.deinit();
    try sc.mkdir("r1");
    try sc.mkdir("r2");
    const r1 = try sc.join("r1");
    defer testing.allocator.free(r1);
    const r2 = try sc.join("r2");
    defer testing.allocator.free(r2);
    var a = try Operation.create(testing.allocator, testing.io, r1, "p.a1", null);
    defer a.deinit();
    var b = try Operation.create(testing.allocator, testing.io, r2, "p.a1", null);
    defer b.deinit();
    const names = [_][]const u8{ "model.obj", "model.mtl", "tex/b.bin", "tex/a.bin", "a-b.bin", "a/b.bin", "Z.bin" };
    for (names) |n| {
        const c = try std.fmt.allocPrint(testing.allocator, "{s}!", .{n});
        defer testing.allocator.free(c);
        try put(&a, n, c);
    }
    var i: usize = names.len;
    while (i > 0) : (i -= 1) {
        const c = try std.fmt.allocPrint(testing.allocator, "{s}!", .{names[i - 1]});
        defer testing.allocator.free(c);
        try put(&b, names[i - 1], c);
    }
    var sa = try sealOp(&a, "model.obj", &.{ "tex/a.bin", "model.mtl" });
    defer sa.deinit();
    var sb = try sealOp(&b, "model.obj", &.{ "model.mtl", "tex/a.bin" });
    defer sb.deinit();
    const want = [_][]const u8{ "Z.bin", "a-b.bin", "a/b.bin", "model.mtl", "model.obj", "tex/a.bin", "tex/b.bin" };
    try testing.expectEqual(want.len, sa.manifest.files.len);
    for (want, sa.manifest.files) |w, e| {
        try testing.expectEqualStrings(w, e.path);
        const content = try std.fmt.allocPrint(testing.allocator, "{s}!", .{w});
        defer testing.allocator.free(content);
        try testing.expectEqual(content.len, e.size);
        try testing.expectEqualSlices(u8, &sha256Hex(content), &e.sha256);
    }
    try testing.expectEqual(@as(usize, 2), sa.manifest.expected_sidecars.len);
    try testing.expectEqualStrings("model.mtl", sa.manifest.expected_sidecars[0]);
    try testing.expectEqualStrings("tex/a.bin", sa.manifest.expected_sidecars[1]);
    try testing.expectEqualSlices(u8, &sa.manifest_sha256, &sb.manifest_sha256);
    const ma = try readRel(&a, manifest_name);
    defer testing.allocator.free(ma);
    const mb = try readRel(&b, manifest_name);
    defer testing.allocator.free(mb);
    try testing.expectEqualStrings(ma, mb);
    try testing.expect(std.mem.indexOf(u8, ma, "\"semantics\":\"unchecked\"") != null);
    var va = try check(&a, .{ .op_id = "p.a1", .format = "obj", .main_file = "model.obj", .bindings = bind_a, .expected_sidecars = &.{"model.mtl"} });
    defer va.deinit();
    try testing.expectEqual(Status.verified, va.status);
    try testing.expectEqual(@as(u64, 7), va.stats.files);
    try testing.expectEqualSlices(u8, &sa.manifest_sha256, &va.sealed.?.manifest_sha256);
}

test "distinct attempts isolate sequential 3DS textures and OBJ sidecars" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var nb: [160]u8 = undefined;
    const n1 = try sc.op(try attemptName(&nb, "3ds.mesh", 1));
    var a1 = n1;
    defer a1.deinit();
    try put(&a1, "model.3ds", "3ds attempt one");
    try put(&a1, "tex_001.bin", "texture of attempt one");
    var s1 = try a1.seal(testing.allocator, testing.io, .{ .format = "3ds", .main_file = "model.3ds", .bindings = bind_a, .expected_sidecars = &.{"tex_001.bin"} }, null);
    defer s1.deinit();

    var a2 = try sc.op(try attemptName(&nb, "3ds.mesh", 2));
    defer a2.deinit();
    try put(&a2, "model.3ds", "3ds attempt two");
    try put(&a2, "tex_001.bin", "texture of attempt two");
    var s2 = try a2.seal(testing.allocator, testing.io, .{ .format = "3ds", .main_file = "model.3ds", .bindings = bind_a, .expected_sidecars = &.{"tex_001.bin"} }, null);
    defer s2.deinit();

    var d: Diagnostic = .{};
    try testing.expectError(error.OperationExists, Operation.create(testing.allocator, testing.io, sc.path, "3ds.mesh.a1", &d));
    try testing.expectEqualStrings("3ds.mesh.a1", d.path());
    try testing.expectError(error.PathAlreadyExists, put(&a1, "tex_001.bin", "overwrite"));
    const kept = try readRel(&a1, "tex_001.bin");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("texture of attempt one", kept);
    try testing.expect(!std.mem.eql(u8, &s1.manifest_sha256, &s2.manifest_sha256));
    try testing.expect(!std.mem.eql(u8, &s1.manifest.files[1].sha256, &s2.manifest.files[1].sha256));
    var v1 = try check(&a1, .{});
    defer v1.deinit();
    try testing.expectEqual(Status.verified, v1.status);
    try testing.expectEqualSlices(u8, &s1.manifest_sha256, &v1.sealed.?.manifest_sha256);
    var v2 = try check(&a2, .{});
    defer v2.deinit();
    try testing.expectEqual(Status.verified, v2.status);
}

test "occupied paths are refused and left unchanged" {
    var sc = try Scratch.init();
    defer sc.deinit();
    try sc.mkdir("occ");
    const keep = try sc.join("occ/keep.bin");
    defer testing.allocator.free(keep);
    {
        const f = try Dir.cwd().createFile(testing.io, keep, .{ .exclusive = true });
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "keep");
    }
    const filep = try sc.join("occfile");
    defer testing.allocator.free(filep);
    {
        const f = try Dir.cwd().createFile(testing.io, filep, .{ .exclusive = true });
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "file");
    }
    try sc.mkdir("target");
    const target = try sc.join("target");
    defer testing.allocator.free(target);
    const linkp = try sc.join("occlink");
    defer testing.allocator.free(linkp);
    try Dir.cwd().symLink(testing.io, target, linkp, .{ .is_directory = true });

    for ([_][]const u8{ "occ", "occfile", "occlink" }) |n| {
        try testing.expectError(error.OperationExists, Operation.create(testing.allocator, testing.io, sc.path, n, null));
    }
    const got = try Dir.cwd().readFileAlloc(testing.io, keep, testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("keep", got);
    const marker = try sc.join("target/" ++ open_name);
    defer testing.allocator.free(marker);
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(testing.io, marker, .{}));
    const occ_marker = try sc.join("occ/" ++ open_name);
    defer testing.allocator.free(occ_marker);
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(testing.io, occ_marker, .{}));

    for ([_][]const u8{ "a/b", "..", ".", "", "x y", ".hidden", "a\x01b", "-x" }) |n| {
        try testing.expectError(error.InvalidName, Operation.create(testing.allocator, testing.io, sc.path, n, null));
    }
}

test "relative paths with traversal, absolute roots or malformed components are refused" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var op = try sc.op("p.a1");
    defer op.deinit();
    const bad = [_][]const u8{
        "../x",                              "a/../../x", "/etc/passwd", "/abs.obj", "a//b", "a/./b",   "./a",  "a/",          "",
        "a b",                               "a\x01b",    "a\nb",        "a\x7fb",   "a\\b", ".hidden", "a/.b", "caf\xc3\xa9", "a" ** 129,
        "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q",
    };
    for (bad) |p| {
        try testing.expectError(error.InvalidPath, op.filePath(p));
        try testing.expectError(error.InvalidPath, put(&op, p, "x"));
    }
    for ([_][]const u8{ "_opdir-seal.json", "_OPDIR-x", "_opdir-dir/f.bin" }) |p| {
        try testing.expectError(error.ReservedName, op.filePath(p));
    }
    const ok = try op.filePath("sub/_opdir-seal.json");
    defer op.gpa.free(ok);
    try testing.expect(std.mem.endsWith(u8, ok, "/p.a1/sub/_opdir-seal.json"));

    try put(&op, "m.obj", "x");
    var d: Diagnostic = .{};
    const bad_specs = [_]SealSpec{
        .{ .format = "obj", .main_file = "../m.obj", .bindings = bind_a },
        .{ .format = "obj", .main_file = "/m.obj", .bindings = bind_a },
        .{ .format = "bad format", .main_file = "m.obj", .bindings = bind_a },
        .{ .format = "obj", .main_file = "_opdir-manifest.json", .bindings = bind_a },
        .{ .format = "obj", .main_file = "m.obj", .bindings = .{ .source_sha256 = "ABC", .state_sha256 = h2, .profile_id = "p", .profile_sha256 = h3 } },
        .{ .format = "obj", .main_file = "m.obj", .bindings = .{ .source_sha256 = h1, .state_sha256 = "F" ** 64, .profile_id = "p", .profile_sha256 = h3 } },
        .{ .format = "obj", .main_file = "m.obj", .bindings = .{ .source_sha256 = h1, .state_sha256 = h2, .profile_id = "p q", .profile_sha256 = h3 } },
        .{ .format = "obj", .main_file = "m.obj", .bindings = bind_a, .expected_sidecars = &.{"../x"} },
        .{ .format = "obj", .main_file = "m.obj", .bindings = bind_a, .expected_sidecars = &.{"m.obj"} },
    };
    for (bad_specs) |sp| try testing.expectError(error.InvalidSpec, op.seal(testing.allocator, testing.io, sp, &d));
    try put(&op, "x.bin", "x");
    try testing.expectError(error.InvalidSpec, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{ "x.bin", "x.bin" }), &d));
    try expectState(&op, .unsealed, "Unsealed");
}

test "ASCII case aliases on disk are refused or cannot be created" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var op = try sc.op("p.a1");
    defer op.deinit();
    try put(&op, "m.obj", "x");
    try put(&op, "a.mtl", "lower");
    if (put(&op, "A.MTL", "upper")) {
        std.debug.print("case-sensitive volume. both spellings exist\n", .{});
        var d: Diagnostic = .{};
        try testing.expectError(error.CaseAlias, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), &d));
        try testing.expectEqualStrings("A.MTL", d.path());
        try expectState(&op, .unsealed, "Unsealed");
    } else |e| {
        try testing.expectEqual(error.PathAlreadyExists, e);
        std.debug.print("case-insensitive volume. the second spelling was refused by exclusive create\n", .{});
        const kept = try readRel(&op, "a.mtl");
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("lower", kept);
    }
}

test "symlinks never enter a bundle" {
    var sc = try Scratch.init();
    defer sc.deinit();
    try sc.mkdir("outside");
    const out_file = try sc.join("outside/secret.bin");
    defer testing.allocator.free(out_file);
    {
        const f = try Dir.cwd().createFile(testing.io, out_file, .{ .exclusive = true });
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "outside secret");
    }
    const out_dir = try sc.join("outside");
    defer testing.allocator.free(out_dir);

    {
        var op = try sc.op("file-link");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        const lp = try opPath(&op, "link.bin");
        defer testing.allocator.free(lp);
        try Dir.cwd().symLink(testing.io, out_file, lp, .{});
        var d: Diagnostic = .{};
        try testing.expectError(error.Symlink, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), &d));
        try testing.expectEqualStrings("link.bin", d.path());
        try expectState(&op, .unsealed, "Unsealed");
    }
    {
        var op = try sc.op("dir-link");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        const lp = try opPath(&op, "linkdir");
        defer testing.allocator.free(lp);
        try Dir.cwd().symLink(testing.io, out_dir, lp, .{ .is_directory = true });
        try testing.expectError(error.Symlink, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), null));
    }
    {
        var op = try sc.op("dangling");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        const lp = try opPath(&op, "gone.bin");
        defer testing.allocator.free(lp);
        try Dir.cwd().symLink(testing.io, "/tmp/opdir-test-does-not-exist", lp, .{});
        try testing.expectError(error.Symlink, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), null));
    }
    {
        var op = try sc.op("reserved-link");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        const lp = try opPath(&op, seal_name);
        defer testing.allocator.free(lp);
        try Dir.cwd().symLink(testing.io, out_file, lp, .{});
        try testing.expectError(error.Symlink, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), null));
        try expectState(&op, .unsafe_tree, "Symlink");
    }
    {
        var op = try makeBundle(&sc, "swap");
        defer op.deinit();
        try moveAway(&sc, &op, "tex/a.bin", "moved-a.bin");
        const lp = try opPath(&op, "tex/a.bin");
        defer testing.allocator.free(lp);
        const target = try sc.join("moved-a.bin");
        defer testing.allocator.free(target);
        try Dir.cwd().symLink(testing.io, target, lp, .{});
        try expectState(&op, .unsafe_tree, "Symlink");
    }
    {
        var op = try makeBundle(&sc, "real");
        defer op.deinit();
        const lp = try sc.join("oplink");
        defer testing.allocator.free(lp);
        try Dir.cwd().symLink(testing.io, op.path, lp, .{ .is_directory = true });
        if (verify(testing.allocator, testing.io, lp, .{}, .{})) |*v| {
            var vv = v.*;
            vv.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
        try testing.expect(std.meta.isError(Operation.attach(testing.allocator, testing.io, lp)));
    }
}

pub extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "special files are refused" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var op = try sc.op("p.a1");
    defer op.deinit();
    try put(&op, "m.obj", "x");
    const fp = try opPath(&op, "pipe.bin");
    defer testing.allocator.free(fp);
    const z = try testing.allocator.dupeZ(u8, fp);
    defer testing.allocator.free(z);
    if (mkfifo(z.ptr, 0o600) != 0) {
        std.debug.print("mkfifo failed. special file case skipped\n", .{});
        return;
    }
    var d: Diagnostic = .{};
    try testing.expectError(error.SpecialFile, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), &d));
    try testing.expectEqualStrings("pipe.bin", d.path());
    try expectState(&op, .unsealed, "Unsealed");
}

test "generic integrity does not read OBJ references and declared sidecars are required" {
    var sc = try Scratch.init();
    defer sc.deinit();
    {
        // The OBJ names a missing MTL. No sidecar is declared, so the generic bundle verifies.
        var op = try sc.op("undeclared");
        defer op.deinit();
        try put(&op, "model.obj", "mtllib missing.mtl\nusemtl m\n");
        var sl = try sealOp(&op, "model.obj", &.{});
        defer sl.deinit();
        try expectState(&op, .verified, "verified");
        try testing.expectEqual(@as(usize, 0), sl.manifest.expected_sidecars.len);
    }
    {
        var op = try sc.op("garbage-main");
        defer op.deinit();
        try put(&op, "model.obj", "\x00\x01 not an OBJ at all");
        var sl = try sealOp(&op, "model.obj", &.{});
        defer sl.deinit();
        try expectState(&op, .verified, "verified");
    }
    {
        var op = try sc.op("declared");
        defer op.deinit();
        try put(&op, "model.obj", "mtllib model.mtl\n");
        var d: Diagnostic = .{};
        try testing.expectError(error.SidecarMissing, op.seal(testing.allocator, testing.io, specOf("model.obj", &.{"model.mtl"}), &d));
        try testing.expectEqualStrings("model.mtl", d.path());
        try expectState(&op, .unsealed, "Unsealed");
        try put(&op, "model.mtl", "newmtl m\n");
        var sl = try sealOp(&op, "model.obj", &.{"model.mtl"});
        defer sl.deinit();
        try expectState(&op, .verified, "verified");
    }
}

test "missing, changed, added and truncated files make a sealed bundle stale" {
    var sc = try Scratch.init();
    defer sc.deinit();
    {
        var op = try makeBundle(&sc, "deleted-sidecar");
        defer op.deinit();
        try moveAway(&sc, &op, "model.mtl", "moved-mtl");
        try expectState(&op, .stale, "FileMissing");
    }
    {
        var op = try makeBundle(&sc, "deleted-nested");
        defer op.deinit();
        try moveAway(&sc, &op, "tex/a.bin", "moved-tex");
        try expectState(&op, .stale, "FileMissing");
    }
    {
        var op = try makeBundle(&sc, "same-size");
        defer op.deinit();
        try patch(&op, "model.mtl", 0, "N");
        try expectState(&op, .stale, "FileModified");
    }
    {
        var op = try makeBundle(&sc, "appended");
        defer op.deinit();
        try patch(&op, "tex/a.bin", 10, "more");
        try expectState(&op, .stale, "FileModified");
    }
    {
        var op = try makeBundle(&sc, "truncated");
        defer op.deinit();
        const p = try opPath(&op, "model.obj");
        defer testing.allocator.free(p);
        const f = try Dir.cwd().createFile(testing.io, p, .{});
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "mtllib mo");
        try expectState(&op, .stale, "FileModified");
    }
    {
        var op = try makeBundle(&sc, "added");
        defer op.deinit();
        try put(&op, "extra.bin", "late");
        var v = try check(&op, .{});
        defer v.deinit();
        try testing.expectEqual(Status.stale, v.status);
        try testing.expectEqualStrings("FileAdded", v.reason);
        try testing.expectEqualStrings("extra.bin", v.diag.path());
    }
    {
        var op = try makeBundle(&sc, "added-dir-file");
        defer op.deinit();
        try put(&op, "tex/more.bin", "late");
        try expectState(&op, .stale, "FileAdded");
    }
    {
        var op = try makeBundle(&sc, "again");
        defer op.deinit();
        try testing.expectError(error.AlreadySealed, sealOp(&op, "model.obj", &.{"model.mtl"}));
        try expectState(&op, .verified, "verified");
    }
}

test "changed bindings and expectations are reported separately" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var op = try makeBundle(&sc, "p.a1");
    defer op.deinit();
    const base = bind_a;
    const variants = [_]Bindings{
        .{ .source_sha256 = "9" ** 64, .state_sha256 = base.state_sha256, .profile_id = base.profile_id, .profile_sha256 = base.profile_sha256 },
        .{ .source_sha256 = base.source_sha256, .state_sha256 = "9" ** 64, .profile_id = base.profile_id, .profile_sha256 = base.profile_sha256 },
        .{ .source_sha256 = base.source_sha256, .state_sha256 = base.state_sha256, .profile_id = "obj.other", .profile_sha256 = base.profile_sha256 },
        .{ .source_sha256 = base.source_sha256, .state_sha256 = base.state_sha256, .profile_id = base.profile_id, .profile_sha256 = "9" ** 64 },
    };
    for (variants) |b| {
        var v = try check(&op, .{ .bindings = b });
        defer v.deinit();
        try testing.expectEqual(Status.binding_mismatch, v.status);
        try testing.expectEqualStrings("BindingMismatch", v.reason);
        try testing.expectEqualStrings("bindings", v.diag.path());
    }
    for ([_]Expect{ .{ .op_id = "p.a2" }, .{ .format = "stl" }, .{ .main_file = "model.mtl" } }) |e| {
        var v = try check(&op, e);
        defer v.deinit();
        try testing.expectEqual(Status.binding_mismatch, v.status);
    }
    {
        var v = try check(&op, .{ .expected_sidecars = &.{ "model.mtl", "tex/a.bin" } });
        defer v.deinit();
        try testing.expectEqual(Status.verified, v.status);
    }
    {
        var v = try check(&op, .{ .expected_sidecars = &.{"tex/b.bin"} });
        defer v.deinit();
        try testing.expectEqual(Status.sidecar_missing, v.status);
        try testing.expectEqualStrings("tex/b.bin", v.diag.path());
    }
}

const Mutator = struct {
    const Mode = enum { append, rewrite };

    full: []const u8,
    at: u64,
    mode: Mode,
    fired: bool = false,

    fn hook(ctx: ?*anyopaque, path: []const u8, offset: u64) void {
        _ = path;
        const m: *Mutator = @ptrCast(@alignCast(ctx.?));
        if (m.fired or offset < m.at) return;
        m.fired = true;
        const f = Dir.cwd().createFile(testing.io, m.full, .{ .truncate = false }) catch @panic("hook open");
        defer f.close(testing.io);
        switch (m.mode) {
            .append => {
                const st = f.stat(testing.io) catch @panic("hook stat");
                f.writePositionalAll(testing.io, "x", st.size) catch @panic("hook write");
            },
            .rewrite => f.writePositionalAll(testing.io, "Z", 0) catch @panic("hook write"),
        }
    }
};

fn fillPattern(buf: []u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
}

test "a file that changes while it is hashed stops the seal" {
    var sc = try Scratch.init();
    defer sc.deinit();
    const size = 3 * chunk_bytes + 7;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    fillPattern(payload, 7);
    for ([_]Mutator.Mode{ .append, .rewrite }, 0..) |mode, i| {
        const name = if (i == 0) "grow" else "rewrite";
        var op = try sc.op(name);
        defer op.deinit();
        try put(&op, "model.obj", "small");
        try put(&op, "big.bin", payload);
        const full = try opPath(&op, "big.bin");
        defer testing.allocator.free(full);
        var m: Mutator = .{ .full = full, .at = chunk_bytes, .mode = mode };
        var sp = specOf("model.obj", &.{"big.bin"});
        sp.hooks = .{ .ctx = &m, .after_chunk = Mutator.hook };
        var d: Diagnostic = .{};
        try testing.expectError(error.FileChanged, op.seal(testing.allocator, testing.io, sp, &d));
        try testing.expect(m.fired);
        try testing.expectEqualStrings("big.bin", d.path());
        try expectState(&op, .unsealed, "Unsealed");
    }
}

test "a file that changes while a bundle is verified makes it stale" {
    var sc = try Scratch.init();
    defer sc.deinit();
    const size = 3 * chunk_bytes + 7;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    fillPattern(payload, 9);
    var op = try sc.op("p.a1");
    defer op.deinit();
    try put(&op, "model.obj", "small");
    try put(&op, "big.bin", payload);
    var sl = try sealOp(&op, "model.obj", &.{"big.bin"});
    defer sl.deinit();
    try expectState(&op, .verified, "verified");
    const full = try opPath(&op, "big.bin");
    defer testing.allocator.free(full);
    var m: Mutator = .{ .full = full, .at = chunk_bytes, .mode = .append };
    var v = try verify(testing.allocator, testing.io, op.path, .{}, .{ .hooks = .{ .ctx = &m, .after_chunk = Mutator.hook } });
    defer v.deinit();
    try testing.expect(m.fired);
    try testing.expectEqual(Status.stale, v.status);
    try testing.expectEqualStrings("FileChanged", v.reason);
}

test "interrupted publication is never reported as verified" {
    var sc = try Scratch.init();
    defer sc.deinit();
    const phases = [_]PublishPhase{ .after_manifest_partial, .after_manifest, .after_seal_partial };
    const partial_of = [_][]const u8{ manifest_partial_name, manifest_name, seal_partial_name };
    for (phases, partial_of) |phase, leftover| {
        var op = try sc.op(@tagName(phase));
        defer op.deinit();
        try put(&op, "model.obj", "x");
        try put(&op, "model.mtl", "y");
        var sp = specOf("model.obj", &.{"model.mtl"});
        sp.hooks.stop_after = phase;
        try testing.expectError(error.InjectedStop, op.seal(testing.allocator, testing.io, sp, null));
        var v = try check(&op, .{});
        defer v.deinit();
        try testing.expectEqual(Status.interrupted, v.status);
        try testing.expect(v.sealed == null);
        if (phase != .after_manifest) try testing.expectEqualStrings(leftover, v.diag.path());
        // A second seal refuses and leaves the interrupted files as they are.
        const before = try readRel(&op, leftover);
        defer testing.allocator.free(before);
        try testing.expectError(error.AlreadySealed, sealOp(&op, "model.obj", &.{"model.mtl"}));
        const after = try readRel(&op, leftover);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(before, after);
        try expectState(&op, .interrupted, "Interrupted");
    }
}

test "hand-made partial states are detected" {
    var sc = try Scratch.init();
    defer sc.deinit();
    {
        // A crash while the manifest was half written.
        var op = try sc.op("half-manifest");
        defer op.deinit();
        try put(&op, "model.obj", "x");
        const p = try opPath(&op, manifest_partial_name);
        defer testing.allocator.free(p);
        {
            const f = try Dir.cwd().createFile(testing.io, p, .{ .exclusive = true });
            defer f.close(testing.io);
            try f.writeStreamingAll(testing.io, "{\"schema\":\"vwx-rosetta-opdir-man");
        }
        try expectState(&op, .interrupted, "Interrupted");
        try testing.expectError(error.AlreadySealed, sealOp(&op, "model.obj", &.{}));
        const kept = try readRel(&op, manifest_partial_name);
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("{\"schema\":\"vwx-rosetta-opdir-man", kept);
    }
    {
        // A manifest placed before the seal exists.
        var op = try sc.op("manifest-only");
        defer op.deinit();
        try put(&op, "model.obj", "x");
        const p = try opPath(&op, manifest_name);
        defer testing.allocator.free(p);
        {
            const f = try Dir.cwd().createFile(testing.io, p, .{ .exclusive = true });
            defer f.close(testing.io);
            try f.writeStreamingAll(testing.io, "{}");
        }
        try expectState(&op, .interrupted, "Interrupted");
        try testing.expectError(error.AlreadySealed, sealOp(&op, "model.obj", &.{}));
        const kept = try readRel(&op, manifest_name);
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("{}", kept);
    }
    {
        // A seal without a manifest.
        var op = try sc.op("seal-only");
        defer op.deinit();
        try put(&op, "model.obj", "x");
        const p = try opPath(&op, seal_name);
        defer testing.allocator.free(p);
        {
            const f = try Dir.cwd().createFile(testing.io, p, .{ .exclusive = true });
            defer f.close(testing.io);
            try f.writeStreamingAll(testing.io, "{}");
        }
        try expectState(&op, .malformed, "MalformedSeal");
    }
    {
        // A directory that was never an operation directory.
        try sc.mkdir("plain");
        const p = try sc.join("plain");
        defer testing.allocator.free(p);
        var v = try verify(testing.allocator, testing.io, p, .{}, .{});
        defer v.deinit();
        try testing.expectEqual(Status.malformed, v.status);
        try testing.expectEqualStrings("NotOpen", v.reason);
        try testing.expectError(error.NotOpen, Operation.attach(testing.allocator, testing.io, p));
    }
    {
        var op = try sc.op("attach");
        defer op.deinit();
        var again = try Operation.attach(testing.allocator, testing.io, op.path);
        defer again.deinit();
        try testing.expectEqualStrings("attach", again.name());
        try put(&again, "model.obj", "x");
        var sl = try sealOp(&again, "model.obj", &.{});
        sl.deinit();
        try expectState(&op, .verified, "verified");
    }
}

fn forge(sc: *const Scratch, op: *const Operation, manifest_bytes: []const u8, seal_text: ?[]const u8) !void {
    const Counter = struct {
        var n: usize = 0;
    };
    Counter.n += 1;
    var nb: [64]u8 = undefined;
    try moveAway(sc, op, manifest_name, try std.fmt.bufPrint(&nb, "old-manifest-{d}", .{Counter.n}));
    try moveAway(sc, op, seal_name, try std.fmt.bufPrint(&nb, "old-seal-{d}", .{Counter.n}));
    const mp = try opPath(op, manifest_name);
    defer testing.allocator.free(mp);
    {
        const f = try Dir.cwd().createFile(testing.io, mp, .{ .exclusive = true });
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, manifest_bytes);
    }
    var sbuf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&sbuf);
    try writeSealText(&w, op.name(), manifest_bytes.len, &sha256Hex(manifest_bytes));
    const sp = try opPath(op, seal_name);
    defer testing.allocator.free(sp);
    const f = try Dir.cwd().createFile(testing.io, sp, .{ .exclusive = true });
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, seal_text orelse w.buffered());
}

fn render(m: *const Manifest) ![]u8 {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try writeManifest(&aw.writer, m);
    return aw.toOwnedSlice();
}

fn sealText(op_id: []const u8, len: usize, sha: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try writeSealText(&aw.writer, op_id, len, sha);
    return aw.toOwnedSlice();
}

test "malformed and truncated manifests and seals are rejected" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var base = try makeBundle(&sc, "base");
    defer base.deinit();
    const good = try readRel(&base, manifest_name);
    defer testing.allocator.free(good);
    const good_seal = try readRel(&base, seal_name);
    defer testing.allocator.free(good_seal);

    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |x| testing.allocator.free(x);
        owned.deinit(testing.allocator);
    }
    const tweak = struct {
        fn run(list: *std.ArrayList([]u8), from: []const u8, needle: []const u8, with: []const u8) ![]const u8 {
            const x = try std.mem.replaceOwned(u8, testing.allocator, from, needle, with);
            try list.append(testing.allocator, x);
            return x;
        }
    }.run;
    const mk = struct {
        fn run(list: *std.ArrayList([]u8), main: []const u8, files: []const Entry, sidecars: []const []const u8) ![]const u8 {
            const m: Manifest = .{ .op_id = "base", .format = "obj", .main_file = main, .bindings = bind_a, .expected_sidecars = sidecars, .files = files };
            const x = try render(&m);
            try list.append(testing.allocator, x);
            return x;
        }
    }.run;
    const st = struct {
        fn run(list: *std.ArrayList([]u8), len: usize, sha: []const u8) ![]const u8 {
            const x = try sealText("base", len, sha);
            try list.append(testing.allocator, x);
            return x;
        }
    }.run;
    const real_sha = sha256Hex(good);
    const e_ok = Entry{ .path = "model.obj", .size = 1, .sha256 = sha256Hex("x") };
    const e_up = Entry{ .path = "X.bin", .size = 1, .sha256 = sha256Hex("x") };
    const e_lo = Entry{ .path = "x.bin", .size = 1, .sha256 = sha256Hex("x") };
    const e_trav = Entry{ .path = "../x", .size = 1, .sha256 = sha256Hex("x") };
    const e_badhex = Entry{ .path = "model.obj", .size = 1, .sha256 = ("G" ** 64).* };
    const e_res = Entry{ .path = "_opdir-x", .size = 1, .sha256 = sha256Hex("x") };

    const Case = struct { name: []const u8, bytes: []const u8, seal: ?[]const u8 = null, status: Status, reason: []const u8 };
    const mm = "MalformedManifest";
    const cases = [_]Case{
        .{ .name = "empty", .bytes = "", .status = .malformed, .reason = mm },
        .{ .name = "truncated half", .bytes = good[0 .. good.len / 2], .status = .malformed, .reason = mm },
        .{ .name = "truncated two bytes", .bytes = good[0 .. good.len - 2], .status = .malformed, .reason = mm },
        .{ .name = "final newline removed", .bytes = good[0 .. good.len - 1], .status = .malformed, .reason = "NotCanonical" },
        .{ .name = "garbage", .bytes = "not json\n", .status = .malformed, .reason = mm },
        .{ .name = "array", .bytes = "[]\n", .status = .malformed, .reason = mm },
        .{ .name = "trailing garbage", .bytes = try tweak(&owned, good, "]}\n", "]}\nxx"), .status = .malformed, .reason = mm },
        .{ .name = "unknown field", .bytes = try tweak(&owned, good, "{\"schema\"", "{\"extra\":1,\"schema\""), .status = .malformed, .reason = mm },
        .{ .name = "duplicate key", .bytes = try tweak(&owned, good, "\"format\":\"obj\",", "\"format\":\"obj\",\"format\":\"obj\","), .status = .malformed, .reason = mm },
        .{ .name = "wrong schema", .bytes = try tweak(&owned, good, "opdir-manifest/1", "opdir-manifest/2"), .status = .malformed, .reason = mm },
        .{ .name = "semantics checked", .bytes = try tweak(&owned, good, "\"unchecked\"", "\"checked\""), .status = .malformed, .reason = mm },
        .{ .name = "whitespace variant", .bytes = try tweak(&owned, good, "{\"schema\"", "{ \"schema\""), .status = .malformed, .reason = "NotCanonical" },
        .{ .name = "short hash", .bytes = try tweak(&owned, good, "\"sha256\":\"", "\"sha256\":\"0"), .status = .malformed, .reason = mm },
        .{ .name = "negative size", .bytes = try tweak(&owned, good, "\"size\":", "\"size\":-"), .status = .malformed, .reason = mm },
        .{ .name = "main not listed", .bytes = try mk(&owned, "gone.obj", &.{e_ok}, &.{}), .status = .malformed, .reason = mm },
        .{ .name = "case alias entries", .bytes = try mk(&owned, "model.obj", &.{ e_up, e_lo, e_ok }, &.{}), .status = .malformed, .reason = mm },
        .{ .name = "unsorted entries", .bytes = try mk(&owned, "model.obj", &.{ e_lo, e_ok }, &.{}), .status = .malformed, .reason = mm },
        .{ .name = "duplicate entries", .bytes = try mk(&owned, "model.obj", &.{ e_ok, e_ok }, &.{}), .status = .malformed, .reason = mm },
        .{ .name = "traversal entry", .bytes = try mk(&owned, "model.obj", &.{ e_trav, e_ok }, &.{}), .status = .malformed, .reason = mm },
        .{ .name = "bad hex entry", .bytes = try mk(&owned, "model.obj", &.{e_badhex}, &.{}), .status = .malformed, .reason = mm },
        .{ .name = "reserved entry", .bytes = try mk(&owned, "model.obj", &.{ e_res, e_ok }, &.{}), .status = .malformed, .reason = mm },
        .{ .name = "sidecar not listed", .bytes = try mk(&owned, "model.obj", &.{e_ok}, &.{"nope.bin"}), .status = .malformed, .reason = mm },
        .{ .name = "sidecar is main", .bytes = try mk(&owned, "model.obj", &.{e_ok}, &.{"model.obj"}), .status = .malformed, .reason = mm },
        .{ .name = "manifest op_id differs from seal", .bytes = try tweak(&owned, good, "\"op_id\":\"base\"", "\"op_id\":\"other\""), .status = .malformed, .reason = "MalformedSeal" },
        .{ .name = "seal truncated", .bytes = good, .seal = good_seal[0 .. good_seal.len / 2], .status = .malformed, .reason = "MalformedSeal" },
        .{ .name = "seal garbage", .bytes = good, .seal = "garbage\n", .status = .malformed, .reason = "MalformedSeal" },
        .{ .name = "seal whitespace variant", .bytes = good, .seal = try tweak(&owned, good_seal, "{\"schema\"", "{ \"schema\""), .status = .malformed, .reason = "MalformedSeal" },
        .{ .name = "seal wrong schema", .bytes = good, .seal = try tweak(&owned, good_seal, "opdir-seal/1", "opdir-seal/9"), .status = .malformed, .reason = "MalformedSeal" },
        .{ .name = "seal uppercase digest", .bytes = good, .seal = try st(&owned, good.len, "A" ** 64), .status = .malformed, .reason = "MalformedSeal" },
        .{ .name = "seal wrong digest", .bytes = good, .seal = try st(&owned, good.len, "0" ** 64), .status = .malformed, .reason = "ManifestDigestMismatch" },
        .{ .name = "seal wrong length", .bytes = good, .seal = try st(&owned, good.len + 1, &real_sha), .status = .malformed, .reason = "ManifestDigestMismatch" },
        .{ .name = "manifest truncated after sealing", .bytes = good[0 .. good.len - 1], .seal = good_seal, .status = .malformed, .reason = "ManifestDigestMismatch" },
        .{ .name = "manifest edited after sealing", .bytes = try tweak(&owned, good, "model.mtl", "model.mt1"), .seal = good_seal, .status = .malformed, .reason = "ManifestDigestMismatch" },
    };
    for (cases) |cs| {
        try forge(&sc, &base, cs.bytes, cs.seal);
        var v = try check(&base, .{});
        const ok = v.status == cs.status and std.mem.eql(u8, v.reason, cs.reason);
        if (!ok) std.debug.print("case `{s}` expected {s}/{s}, found {s}/{s} at `{s}`\n", .{ cs.name, @tagName(cs.status), cs.reason, @tagName(v.status), v.reason, v.diag.path() });
        v.deinit();
        try forge(&sc, &base, good, good_seal);
        try expectState(&base, .verified, "verified");
        if (!ok) return error.TestUnexpectedResult;
    }

    var small = try verify(testing.allocator, testing.io, base.path, .{}, .{ .limits = .{ .max_manifest_bytes = 10 } });
    defer small.deinit();
    try testing.expectEqual(Status.limit_exceeded, small.status);
    try testing.expectEqualStrings("ManifestTooLarge", small.reason);

    var marker = try makeBundle(&sc, "marker");
    defer marker.deinit();
    try moveAway(&sc, &marker, open_name, "old-marker");
    const mp = try opPath(&marker, open_name);
    defer testing.allocator.free(mp);
    {
        const f = try Dir.cwd().createFile(testing.io, mp, .{ .exclusive = true });
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "{\"schema\":\"vwx-rosetta-opdir-open/1\",\"op_id\":\"other\"}\n");
    }
    try expectState(&marker, .malformed, "NotOpen");
}

fn generate(op: *const Operation, rel: []const u8, size: u64, seed: u64) ![64]u8 {
    const p = try opPath(op, rel);
    defer testing.allocator.free(p);
    const f = try Dir.cwd().createFile(testing.io, p, .{ .exclusive = true });
    defer f.close(testing.io);
    const block = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(block);
    var prng = std.Random.DefaultPrng.init(seed);
    var h = Sha256.init(.{});
    var left = size;
    while (left > 0) {
        const n: usize = @intCast(@min(left, block.len));
        prng.random().bytes(block[0..n]);
        h.update(block[0..n]);
        try f.writeStreamingAll(testing.io, block[0..n]);
        left -= n;
    }
    var dg: [32]u8 = undefined;
    h.final(&dg);
    return std.fmt.bytesToHex(dg, .lower);
}

pub fn nowNs() i96 {
    return Io.Timestamp.now(testing.io, .awake).toNanoseconds();
}

test "large generated files stream through a fixed buffer with size-independent allocation" {
    comptime std.debug.assert(chunk_bytes == 64 * 1024);
    var sc = try Scratch.init();
    defer sc.deinit();
    const sizes = [_]u64{ 1 << 20, 16 << 20, 256 << 20 };
    var first_bytes: usize = 0;
    var first_allocs: usize = 0;
    var first_verify_bytes: usize = 0;
    for (sizes, 0..) |size, i| {
        var nb: [32]u8 = undefined;
        var op = try sc.op(try std.fmt.bufPrint(&nb, "big{d}", .{i}));
        defer op.deinit();
        try put(&op, "model.obj", "o big\n");
        const want = try generate(&op, "big.bin", size, 100 + i);

        var fa = testing.FailingAllocator.init(testing.allocator, .{});
        const t0 = nowNs();
        var sl = try op.seal(fa.allocator(), testing.io, specOf("model.obj", &.{"big.bin"}), null);
        const t1 = nowNs();
        defer sl.deinit();
        try testing.expectEqual(size + 6, sl.stats.bytes_hashed);
        try testing.expectEqual((size + chunk_bytes - 1) / chunk_bytes + 1, sl.stats.chunks);
        try testing.expectEqualSlices(u8, &want, &sl.manifest.find("big.bin").?.sha256);

        var fb = testing.FailingAllocator.init(testing.allocator, .{});
        const t2 = nowNs();
        var v = try verify(fb.allocator(), testing.io, op.path, .{ .expected_sidecars = &.{"big.bin"} }, .{});
        const t3 = nowNs();
        defer v.deinit();
        try testing.expectEqual(Status.verified, v.status);
        try testing.expectEqual(size + 6, v.stats.bytes_hashed);

        std.debug.print("evidence\tfile_bytes={d}\tseal_ns={d}\tverify_ns={d}\tseal_alloc_bytes={d}\tseal_allocs={d}\tverify_alloc_bytes={d}\tverify_allocs={d}\tchunks={d}\tchunk_bytes={d}\n", .{ size, t1 - t0, t3 - t2, fa.allocated_bytes, fa.allocations, fb.allocated_bytes, fb.allocations, sl.stats.chunks, chunk_bytes });
        if (i == 0) {
            first_bytes = fa.allocated_bytes;
            first_allocs = fa.allocations;
            first_verify_bytes = fb.allocated_bytes;
        }
        // The manifest text grows by a few digits when the decimal size grows. That is the only difference.
        try testing.expectEqual(first_allocs, fa.allocations);
        try testing.expect(@max(first_bytes, fa.allocated_bytes) - @min(first_bytes, fa.allocated_bytes) <= 256);
        try testing.expect(@max(first_verify_bytes, fb.allocated_bytes) - @min(first_verify_bytes, fb.allocated_bytes) <= 256);
        try testing.expect(fa.allocated_bytes < 128 * 1024);
        try testing.expect(fb.allocated_bytes < 128 * 1024);
    }
}

test "limits are enforced and exhaustion is reported" {
    var sc = try Scratch.init();
    defer sc.deinit();
    {
        var op = try sc.op("entries");
        defer op.deinit();
        for ([_][]const u8{ "m.obj", "a.bin", "b.bin", "c.bin" }) |n| try put(&op, n, n);
        var sp = specOf("m.obj", &.{});
        sp.limits.max_entries = 3;
        var d: Diagnostic = .{};
        try testing.expectError(error.TooManyEntries, op.seal(testing.allocator, testing.io, sp, &d));
        try testing.expect(d.path().len > 0);
        try expectState(&op, .unsealed, "Unsealed");
        sp.limits.max_entries = 4;
        var sl = try op.seal(testing.allocator, testing.io, sp, null);
        sl.deinit();
        var v = try verify(testing.allocator, testing.io, op.path, .{}, .{ .limits = .{ .max_entries = 3 } });
        defer v.deinit();
        try testing.expectEqual(Status.limit_exceeded, v.status);
        try testing.expectEqualStrings("TooManyEntries", v.reason);
    }
    {
        var op = try sc.op("dirs");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        try put(&op, "d1/x.bin", "x");
        try put(&op, "d2/y.bin", "y");
        var sp = specOf("m.obj", &.{});
        sp.limits.max_entries = 4;
        try testing.expectError(error.TooManyEntries, op.seal(testing.allocator, testing.io, sp, null));
        sp.limits.max_entries = 5;
        var sl = try op.seal(testing.allocator, testing.io, sp, null);
        sl.deinit();
    }
    {
        var op = try sc.op("file-bytes");
        defer op.deinit();
        try put(&op, "m.obj", "0123456789A");
        var sp = specOf("m.obj", &.{});
        sp.limits.max_file_bytes = 10;
        try testing.expectError(error.FileTooLarge, op.seal(testing.allocator, testing.io, sp, null));
        sp.limits.max_file_bytes = 11;
        var sl = try op.seal(testing.allocator, testing.io, sp, null);
        sl.deinit();
        var v = try verify(testing.allocator, testing.io, op.path, .{}, .{ .limits = .{ .max_file_bytes = 10 } });
        defer v.deinit();
        try testing.expectEqual(Status.limit_exceeded, v.status);
        try testing.expectEqualStrings("FileTooLarge", v.reason);
    }
    {
        var op = try sc.op("total-bytes");
        defer op.deinit();
        try put(&op, "m.obj", "012345");
        try put(&op, "n.bin", "012345");
        var sp = specOf("m.obj", &.{});
        sp.limits.max_total_bytes = 11;
        try testing.expectError(error.TotalTooLarge, op.seal(testing.allocator, testing.io, sp, null));
        sp.limits.max_total_bytes = 12;
        var sl = try op.seal(testing.allocator, testing.io, sp, null);
        sl.deinit();
        var v = try verify(testing.allocator, testing.io, op.path, .{}, .{ .limits = .{ .max_total_bytes = 11 } });
        defer v.deinit();
        try testing.expectEqual(Status.limit_exceeded, v.status);
        try testing.expectEqualStrings("TotalTooLarge", v.reason);
    }
    {
        var op = try sc.op("manifest-bytes");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        var sp = specOf("m.obj", &.{});
        sp.limits.max_manifest_bytes = 100;
        try testing.expectError(error.ManifestTooLarge, op.seal(testing.allocator, testing.io, sp, null));
        try expectState(&op, .unsealed, "Unsealed");
    }
}

test "allocation failure at every step leaves no manifest and no leak" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var n: usize = 0;
    while (n < 500) : (n += 1) {
        var nb: [32]u8 = undefined;
        var op = try sc.op(try std.fmt.bufPrint(&nb, "sweep{d}", .{n}));
        defer op.deinit();
        try put(&op, "model.obj", "mtllib model.mtl\n");
        try put(&op, "model.mtl", "newmtl m\n");
        try put(&op, "tex/a.bin", "0123");
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = n });
        if (op.seal(fa.allocator(), testing.io, specOf("model.obj", &.{"model.mtl"}), null)) |*s| {
            var sl = s.*;
            sl.deinit();
            try expectState(&op, .verified, "verified");
            break;
        } else |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            try expectState(&op, .unsealed, "Unsealed");
        }
    } else return error.SweepDidNotFinish;
    std.debug.print("seal sweep finished after {d} failing allocation points\n", .{n});

    var op = try makeBundle(&sc, "vsweep");
    defer op.deinit();
    n = 0;
    while (n < 500) : (n += 1) {
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = n });
        if (verify(fa.allocator(), testing.io, op.path, .{}, .{})) |*r| {
            var v = r.*;
            defer v.deinit();
            try testing.expectEqual(Status.verified, v.status);
            break;
        } else |e| try testing.expectEqual(error.OutOfMemory, e);
    } else return error.SweepDidNotFinish;
    std.debug.print("verify sweep finished after {d} failing allocation points\n", .{n});
}

test "reserved names are refused and never hashed" {
    var sc = try Scratch.init();
    defer sc.deinit();
    const writeRaw = struct {
        fn run(op: *const Operation, rel: []const u8, bytes: []const u8) !void {
            const p = try opPath(op, rel);
            defer testing.allocator.free(p);
            const f = try Dir.cwd().createFile(testing.io, p, .{ .exclusive = true });
            defer f.close(testing.io);
            try f.writeStreamingAll(testing.io, bytes);
        }
    }.run;
    {
        var op = try sc.op("prefilled-manifest");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        try writeRaw(&op, manifest_name, "mine");
        try testing.expectError(error.AlreadySealed, sealOp(&op, "m.obj", &.{}));
        const kept = try readRel(&op, manifest_name);
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("mine", kept);
    }
    {
        var op = try sc.op("prefilled-seal");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        try writeRaw(&op, seal_name, "mine");
        try testing.expectError(error.AlreadySealed, sealOp(&op, "m.obj", &.{}));
    }
    for ([_][]const u8{ "_OPDIR-Note.txt", "_opdir-extra.bin", "_opdir-" }) |n| {
        var nb: [32]u8 = undefined;
        var op = try sc.op(try std.fmt.bufPrint(&nb, "res{d}", .{n.len}));
        defer op.deinit();
        try put(&op, "m.obj", "x");
        try writeRaw(&op, n, "x");
        var d: Diagnostic = .{};
        try testing.expectError(error.ReservedName, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), &d));
        try testing.expectEqualStrings(n, d.path());
    }
    {
        var op = try sc.op("reserved-dir");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        const p = try opPath(&op, "_opdir-dir");
        defer testing.allocator.free(p);
        try Dir.cwd().createDir(testing.io, p, .default_dir);
        try testing.expectError(error.SpecialFile, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), null));
    }
    {
        var op = try sc.op("nested");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        try put(&op, "sub/_opdir-seal.json", "nested name is an ordinary file");
        var sl = try sealOp(&op, "m.obj", &.{});
        defer sl.deinit();
        try testing.expect(sl.manifest.find("sub/_opdir-seal.json") != null);
        try testing.expect(sl.manifest.find(open_name) == null);
        try expectState(&op, .verified, "verified");
    }
}

// ---------------------------------------------------------------------------
// repairs. FIFO replacement, hard links and identity changes around open
// ---------------------------------------------------------------------------

/// Releases a reader that blocks in `open` on a FIFO by opening its write end after `limit_ms`.
/// A test passes when `fired` stays false.
pub const Watchdog = struct {
    path: []const u8,
    limit_ms: u32 = 5000,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    pub fn run(w: *Watchdog) void {
        var waited: u32 = 0;
        while (waited < w.limit_ms) : (waited += 20) {
            if (w.done.load(.acquire)) return;
            testing.io.sleep(Io.Duration.fromMilliseconds(20), .awake) catch {};
        }
        w.fired.store(true, .release);
        const f = Dir.cwd().openFile(testing.io, w.path, .{ .mode = .write_only }) catch return;
        f.close(testing.io);
    }
};

const Swap = struct {
    const Kind = enum { fifo, regular };

    sc: *const Scratch,
    op: *const Operation,
    target: []const u8,
    kind: Kind,
    fired: bool = false,

    fn hook(ctx: ?*anyopaque, path: []const u8) void {
        const m: *Swap = @ptrCast(@alignCast(ctx.?));
        if (m.fired or !std.mem.eql(u8, path, m.target)) return;
        m.fired = true;
        const full = opPath(m.op, path) catch @panic("hook path");
        defer testing.allocator.free(full);
        const saved = readRel(m.op, path) catch @panic("hook read");
        defer testing.allocator.free(saved);
        moveAway(m.sc, m.op, path, "swapped-out") catch @panic("hook move");
        switch (m.kind) {
            .fifo => {
                const z = testing.allocator.dupeZ(u8, full) catch @panic("hook dupeZ");
                defer testing.allocator.free(z);
                if (mkfifo(z.ptr, 0o600) != 0) @panic("hook mkfifo");
            },
            .regular => {
                const f = Dir.cwd().createFile(testing.io, full, .{ .exclusive = true }) catch @panic("hook create");
                defer f.close(testing.io);
                f.writeStreamingAll(testing.io, saved) catch @panic("hook write");
            },
        }
    }
};

pub fn startWatchdog(w: *Watchdog) !std.Thread {
    return std.Thread.spawn(.{}, Watchdog.run, .{w});
}

test "control. a blocking open of a FIFO waits for a writer until the watchdog releases it" {
    var sc = try Scratch.init();
    defer sc.deinit();
    const fp = try sc.join("control.fifo");
    defer testing.allocator.free(fp);
    const z = try testing.allocator.dupeZ(u8, fp);
    defer testing.allocator.free(z);
    if (mkfifo(z.ptr, 0o600) != 0) {
        std.debug.print("mkfifo failed. control skipped\n", .{});
        return;
    }
    var wd: Watchdog = .{ .path = fp, .limit_ms = 300 };
    const th = try startWatchdog(&wd);
    const t0 = nowNs();
    const f = try Dir.cwd().openFile(testing.io, fp, .{});
    f.close(testing.io);
    const t1 = nowNs();
    wd.done.store(true, .release);
    th.join();
    try testing.expect(wd.fired.load(.acquire));
    try testing.expect(t1 - t0 >= 250 * std.time.ns_per_ms);
    std.debug.print("evidence\tcontrol_blocking_open_ns={d}\n", .{t1 - t0});
}

test "a file replaced by a FIFO before open fails as a special file within a deadline" {
    var sc = try Scratch.init();
    defer sc.deinit();
    {
        var op = try sc.op("seal-swap");
        defer op.deinit();
        try put(&op, "model.obj", "x");
        try put(&op, "big.bin", "payload");
        const fp = try opPath(&op, "big.bin");
        defer testing.allocator.free(fp);
        var wd: Watchdog = .{ .path = fp };
        const th = try startWatchdog(&wd);
        var sw: Swap = .{ .sc = &sc, .op = &op, .target = "big.bin", .kind = .fifo };
        var sp = specOf("model.obj", &.{"big.bin"});
        sp.hooks = .{ .ctx = &sw, .before_open = Swap.hook };
        var d: Diagnostic = .{};
        const t0 = nowNs();
        const r = op.seal(testing.allocator, testing.io, sp, &d);
        const t1 = nowNs();
        wd.done.store(true, .release);
        th.join();
        try testing.expect(sw.fired);
        try testing.expect(!wd.fired.load(.acquire));
        try testing.expectError(error.SpecialFile, r);
        try testing.expectEqualStrings("big.bin", d.path());
        try testing.expect(t1 - t0 < 2000 * std.time.ns_per_ms);
        std.debug.print("evidence\tfifo_swap_seal_ns={d}\n", .{t1 - t0});
        try expectState(&op, .unsealed, "Unsealed");
    }
    {
        var op = try makeBundle(&sc, "verify-swap");
        defer op.deinit();
        const fp = try opPath(&op, "tex/a.bin");
        defer testing.allocator.free(fp);
        var wd: Watchdog = .{ .path = fp };
        const th = try startWatchdog(&wd);
        var sw: Swap = .{ .sc = &sc, .op = &op, .target = "tex/a.bin", .kind = .fifo };
        const t0 = nowNs();
        var v = try verify(testing.allocator, testing.io, op.path, .{}, .{ .hooks = .{ .ctx = &sw, .before_open = Swap.hook } });
        const t1 = nowNs();
        wd.done.store(true, .release);
        th.join();
        defer v.deinit();
        try testing.expect(sw.fired);
        try testing.expect(!wd.fired.load(.acquire));
        try testing.expectEqual(Status.unsafe_tree, v.status);
        try testing.expectEqualStrings("SpecialFile", v.reason);
        try testing.expect(t1 - t0 < 2000 * std.time.ns_per_ms);
        std.debug.print("evidence\tfifo_swap_verify_ns={d}\n", .{t1 - t0});
    }
}

test "a regular file replaced by another inode before open is a change" {
    var sc = try Scratch.init();
    defer sc.deinit();
    {
        var op = try sc.op("seal-regular");
        defer op.deinit();
        try put(&op, "model.obj", "x");
        try put(&op, "big.bin", "same bytes");
        var sw: Swap = .{ .sc = &sc, .op = &op, .target = "big.bin", .kind = .regular };
        var sp = specOf("model.obj", &.{"big.bin"});
        sp.hooks = .{ .ctx = &sw, .before_open = Swap.hook };
        var d: Diagnostic = .{};
        try testing.expectError(error.FileChanged, op.seal(testing.allocator, testing.io, sp, &d));
        try testing.expect(sw.fired);
        try testing.expectEqualStrings("big.bin", d.path());
        try expectState(&op, .unsealed, "Unsealed");
    }
    {
        var op = try makeBundle(&sc, "verify-regular");
        defer op.deinit();
        var sw: Swap = .{ .sc = &sc, .op = &op, .target = "model.mtl", .kind = .regular };
        var v = try verify(testing.allocator, testing.io, op.path, .{}, .{ .hooks = .{ .ctx = &sw, .before_open = Swap.hook } });
        defer v.deinit();
        try testing.expect(sw.fired);
        try testing.expectEqual(Status.stale, v.status);
        try testing.expectEqualStrings("FileChanged", v.reason);
    }
}

fn hardLink(from: []const u8, to: []const u8) !void {
    try Dir.hardLink(Dir.cwd(), from, Dir.cwd(), to, testing.io, .{});
}

test "hard links to outside files are refused and the outside file is unchanged" {
    var sc = try Scratch.init();
    defer sc.deinit();
    try sc.mkdir("outside");
    const out_file = try sc.join("outside/ext.bin");
    defer testing.allocator.free(out_file);
    {
        const f = try Dir.cwd().createFile(testing.io, out_file, .{ .exclusive = true });
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "outside payload");
    }
    const before = try Dir.cwd().statFile(testing.io, out_file, .{});
    {
        var op = try sc.op("seal-link");
        defer op.deinit();
        try put(&op, "m.obj", "x");
        const lp = try opPath(&op, "alias.bin");
        defer testing.allocator.free(lp);
        try hardLink(out_file, lp);
        var d: Diagnostic = .{};
        try testing.expectError(error.HardLink, op.seal(testing.allocator, testing.io, specOf("m.obj", &.{}), &d));
        try testing.expectEqualStrings("alias.bin", d.path());
        try expectState(&op, .unsealed, "Unsealed");
        const after = try Dir.cwd().statFile(testing.io, out_file, .{});
        try testing.expectEqual(before.inode, after.inode);
        try testing.expectEqual(before.size, after.size);
        try testing.expectEqual(before.mtime.toNanoseconds(), after.mtime.toNanoseconds());
        const got = try Dir.cwd().readFileAlloc(testing.io, out_file, testing.allocator, .limited(64));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("outside payload", got);
    }
    {
        // An outside name made after sealing shares the bytes of a payload.
        var op = try makeBundle(&sc, "verify-link");
        defer op.deinit();
        const payload = try opPath(&op, "model.mtl");
        defer testing.allocator.free(payload);
        const alias = try sc.join("outside/alias-of-mtl");
        defer testing.allocator.free(alias);
        try hardLink(payload, alias);
        var v = try check(&op, .{});
        defer v.deinit();
        try testing.expectEqual(Status.unsafe_tree, v.status);
        try testing.expectEqualStrings("HardLink", v.reason);
        try testing.expectEqualStrings("model.mtl", v.diag.path());
    }
    {
        // A published manifest that gains a second name is refused too.
        var op = try makeBundle(&sc, "manifest-link");
        defer op.deinit();
        const mp = try opPath(&op, manifest_name);
        defer testing.allocator.free(mp);
        const alias = try sc.join("outside/alias-of-manifest");
        defer testing.allocator.free(alias);
        try hardLink(mp, alias);
        try expectState(&op, .unsafe_tree, "HardLink");
    }
}

test "a file type change after sealing is reported as stale" {
    var sc = try Scratch.init();
    defer sc.deinit();
    var op = try makeBundle(&sc, "type-change");
    defer op.deinit();
    try moveAway(&sc, &op, "tex/a.bin", "moved-a");
    const dp = try opPath(&op, "tex/a.bin");
    defer testing.allocator.free(dp);
    try Dir.cwd().createDir(testing.io, dp, .default_dir);
    try expectState(&op, .stale, "FileMissing");
}
