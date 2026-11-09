//! Offline activation-readiness packet and gate for the trial export automation.
//!
//! `prepare` writes an activation and calibration packet into a scratch directory. `check`
//! validates that packet against the bytes of the current executable, the current input files and
//! typed compiled-feature data that the integration author supplies. Neither operation makes a
//! native call, activates anything or reads a drawing or license file.
//!
//! `rosetta_capture.zig` imports this module. `rosetta_capture.runActivationCli` passes the
//! compiled features to `runWith` and binds the running executable. `loadBudgets` hands the packet
//! budgets to the production run. The module imports neither `rosetta_capture.zig` nor `main.zig`.
//!
//! Two readiness axes stay separate in every result.
//! - `activation_readiness` is `ready_for_bounded_live_calibration` when every offline check
//!   passes. Otherwise it is `blocked`.
//! - `capture_readiness` is always `native_calibration_required`. This module cannot report
//!   verified acquisition. `verified_acquisition` is always false.
//! A packet cannot supply a verified profile, a reviewer verdict or a resolved post-activation
//! check. Any such claim is a diagnostic. Evidence entries are references only. The program checks
//! fields and bindings. Independent review evaluates the implementation.
//!
//! Compiled features. `CompiledFeatures` defaults to unavailable for every feature and route and
//! has no provenance. A caller that never supplies the table gets `blocked` with
//! `runtime_features_unwired`. The packet and the plan carry no feature booleans.
//!
//! Limits. A packet or plan file is read through a buffer of at most `max_packet_bytes`. The
//! binary and each input file are hashed through a 64 KiB buffer without a size-dependent
//! allocation. Diagnostics are capped at `max_diags`. Opening a FIFO or another non-regular path
//! fails at once and never blocks.
//!
//! Publication. `prepare` writes `<out>.partial` with an exclusive create, syncs it and moves it
//! to the output path with a non-replacing rename. An occupied output path stays unchanged. The
//! output path must be absolute and below a scratch root in `scratch_roots`.
//!
//! Pending contract work. The module records STEP and Parasolid catalog identifiers as pending
//! when the plan says so. It reads and changes no catalog and rejects a pending entry that carries
//! an identifier.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const opdir = @import("rosetta_opdir.zig");

pub const schema_packet = "vwx-rosetta-activation-packet/1";
pub const schema_plan = "vwx-rosetta-activation-plan/1";
pub const schema_result = "vwx-rosetta-activation-result/1";
pub const schema_prepare = "vwx-rosetta-activation-prepare/1";

pub const max_packet_bytes: usize = 1 << 20;
pub const max_binary_bytes: u64 = 8 << 30;
pub const max_input_bytes: u64 = 4 << 30;
pub const max_entries: usize = 128;
pub const max_diags: usize = 256;
pub const max_operation_deadline_ms: u64 = 60 * 60 * 1000;
pub const max_run_budget_ms: u64 = 4 * 60 * 60 * 1000;
pub const max_attempts_per_operation: u32 = 8;

/// Absolute prefixes under which `prepare` may write a packet.
pub const scratch_roots = [_][]const u8{ "/tmp/", "/private/tmp/", @import("build_options").volume ++ "/Caches/tmp/", "/private/var/folders/" };

/// Input ids that every packet must bind.
pub const required_inputs = [_][]const u8{ "queue", "profiles", "recipes" };

// ---------------------------------------------------------------------------
// routes, features and canonical lists
// ---------------------------------------------------------------------------

/// Export formats and early availability checks. `class` separates them.
pub const Route = enum {
    dxf,
    dwg,
    pdf,
    png,
    obj,
    stl,
    @"3ds",
    fbx,
    parasolid,
    step,
    usd,
    sat,
    iges,
    @"3dm",
    ifc,
    skp,
    svg,
    gltf,

    pub const Class = enum { required, targeted, early_check };

    pub fn class(r: Route) Class {
        return switch (r) {
            .dxf, .dwg, .pdf, .png, .obj, .stl, .@"3ds", .fbx, .parasolid, .step => .required,
            .usd, .sat, .iges, .@"3dm", .ifc => .targeted,
            .skp, .svg, .gltf => .early_check,
        };
    }
};

pub const route_count = @typeInfo(Route).@"enum".fields.len;

/// Capabilities that the binary must compile before offline-ready status.
pub const Feature = enum {
    open_identity,
    console_handling,
    modal_handling,
    save_reopen_close,
    bounded_ui_execution,
    typed_options,
    window_inventory,
    attempt_directories,
    sidecar_manifests,
    streaming_verification,
    checkpoint_resume,
    deadlines,
    diagnostics,
    uncertain_mutation_refusal,
};

pub const feature_count = @typeInfo(Feature).@"enum".fields.len;

pub const Availability = enum { unavailable, implemented };

/// Typed integration input. Every value defaults to unavailable. The integration author fills it
/// from code that the binary compiles. `provenance` names the table, for example a source revision.
/// An empty `provenance` means that nothing was wired.
pub const CompiledFeatures = struct {
    features: [feature_count]Availability = @splat(.unavailable),
    routes: [route_count]Availability = @splat(.unavailable),
    provenance: []const u8 = "",

    pub fn feature(c: *const CompiledFeatures, f: Feature) Availability {
        return c.features[@intFromEnum(f)];
    }

    pub fn route(c: *const CompiledFeatures, r: Route) Availability {
        return c.routes[@intFromEnum(r)];
    }

    pub fn setFeature(c: *CompiledFeatures, f: Feature, a: Availability) void {
        c.features[@intFromEnum(f)] = a;
    }

    pub fn setRoute(c: *CompiledFeatures, r: Route, a: Availability) void {
        c.routes[@intFromEnum(r)] = a;
    }
};

pub const Phase = enum { identity, synthetic, recovery };

pub const CalibrationStep = struct { id: []const u8, phase: Phase };

/// Bounded initial calibration order. Identity and capability checks come first and end at
/// `identity_stop_gate`. Representative synthetic exports follow. Recovery checks come last.
/// Full inventory and private-drawing capture stay disabled until a separate complete calibration
/// record passes.
pub const calibration_steps = [_]CalibrationStep{
    .{ .id = "edition_version_build_platform", .phase = .identity },
    .{ .id = "api_save_close_path_identity", .phase = .identity },
    .{ .id = "source_template_hash_pid", .phase = .identity },
    .{ .id = "early_skp_availability", .phase = .identity },
    .{ .id = "early_svg_availability", .phase = .identity },
    .{ .id = "early_gltf_availability", .phase = .identity },
    .{ .id = "identity_stop_gate", .phase = .identity },
    .{ .id = "units_origins_visibility_codes", .phase = .synthetic },
    .{ .id = "menu_dialog_tab_inventory", .phase = .synthetic },
    .{ .id = "profile_options", .phase = .synthetic },
    .{ .id = "paired_same_state_exports", .phase = .synthetic },
    .{ .id = "sidecar_manifests", .phase = .synthetic },
    .{ .id = "unsupported_object_families", .phase = .synthetic },
    .{ .id = "sketchup_interchange", .phase = .synthetic },
    .{ .id = "checkpoint_resume_recovery", .phase = .recovery },
    .{ .id = "uncertain_mutation_refusal", .phase = .recovery },
    .{ .id = "budget_measurement", .phase = .recovery },
};

/// Checks that only live calibration can resolve. Every packet lists all of them as pending.
pub const postactivation_pending = [_][]const u8{
    "release_binding",
    "api_signatures",
    "menu_dialog_inventory",
    "profile_calibration",
    "step_parasolid_catalog_identifiers",
    "sketchup_import_calibration",
    "unsupported_family_dispositions",
    "recovery_budgets",
    "complete_calibration_record",
};

const forbidden_keys = [_][]const u8{ "verdict", "review_verdict", "reviewer_verdict", "verified", "verified_acquisition", "capture_ready", "capture_readiness", "native_verified" };

// ---------------------------------------------------------------------------
// wire types. The plan and the packet share one shape
// ---------------------------------------------------------------------------

pub const Digest = struct { sha256: []const u8, bytes: u64 };
pub const InputBinding = struct { id: []const u8, sha256: []const u8, bytes: u64 };
pub const Coverage = struct {
    operation: []const u8,
    /// `engine` or `unresolved`.
    disposition: []const u8,
    families: []const []const u8 = &.{},
    /// `unverified` is the only accepted value.
    profile_status: []const u8 = "unverified",
    /// `present` or `pending_contract`.
    catalog_status: []const u8 = "present",
    catalog_identifier: ?[]const u8 = null,
};
pub const Exception = struct {
    operation: []const u8,
    reason: []const u8 = "",
    approved_by: []const u8 = "",
    approval_ref: []const u8 = "",
    approved_at: []const u8 = "",
};
/// A reference to evidence. It holds no verdict.
pub const Evidence = struct { kind: []const u8, commit: []const u8 = "", command: []const u8 = "", path: []const u8 = "" };
pub const Budgets = struct { operation_deadline_ms: u64 = 0, run_budget_ms: u64 = 0, max_attempts_per_operation: u32 = 0 };
pub const CalStep = struct { id: []const u8, phase: []const u8 };
pub const Calibration = struct {
    stop_after_identity: bool = false,
    private_capture_enabled: bool = false,
    full_inventory_enabled: bool = false,
    steps: []const CalStep = &.{},
};
pub const Pending = struct { id: []const u8, status: []const u8 };

pub const Packet = struct {
    schema: []const u8,
    binary: ?Digest = null,
    inputs: []const InputBinding = &.{},
    coverage: []const Coverage = &.{},
    exceptions: []const Exception = &.{},
    evidence: []const Evidence = &.{},
    budgets: ?Budgets = null,
    calibration: ?Calibration = null,
    postactivation: []const Pending = &.{},
};

pub const InputPath = struct { id: []const u8, path: []const u8 };

// ---------------------------------------------------------------------------
// bounded file reads and streaming hashes
// ---------------------------------------------------------------------------

pub const FileDigest = struct { sha256: [64]u8, bytes: u64 };

fn openRegular(path: []const u8) !File {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.Unsupported;
    const fd = std.posix.openat(Dir.cwd().handle, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |e| switch (e) {
        error.WouldBlock => return error.NotRegular,
        else => return e,
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Streams `path` through a 64 KiB buffer. A FIFO or other non-regular path fails as
/// `NotRegular` without blocking. A file larger than `max_bytes` fails as `TooLarge`. A file
/// whose size or mtime changes while it is read fails as `Changed`.
pub fn hashFile(io: Io, path: []const u8, max_bytes: u64) !FileDigest {
    const file = try openRegular(path);
    defer file.close(io);
    const st0 = try file.stat(io);
    if (st0.kind != .file) return error.NotRegular;
    if (st0.size > max_bytes) return error.TooLarge;
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        total += n;
        if (total > max_bytes) return error.TooLarge;
        h.update(buf[0..n]);
    }
    const st1 = try file.stat(io);
    if (total != st0.size or st1.size != st0.size or st1.mtime.toNanoseconds() != st0.mtime.toNanoseconds()) return error.Changed;
    var dg: [32]u8 = undefined;
    h.final(&dg);
    return .{ .sha256 = std.fmt.bytesToHex(dg, .lower), .bytes = total };
}

/// Reads at most `max_bytes` from a regular file into `arena`. A longer file fails as `TooLarge`.
fn readBounded(arena: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openRegular(path);
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind != .file) return error.NotRegular;
    if (st.size > max_bytes) return error.TooLarge;
    const buf = try arena.alloc(u8, @intCast(st.size));
    var got: usize = 0;
    while (got < buf.len) {
        const n = file.readStreaming(io, &.{buf[got..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        got += n;
    }
    if (got != buf.len) return error.Changed;
    return buf;
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn isCommit(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn plainText(s: []const u8, max: usize) bool {
    if (s.len == 0 or s.len > max) return false;
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

fn idOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (!std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// prepare
// ---------------------------------------------------------------------------

pub const PrepareArgs = struct {
    plan_path: []const u8,
    binary_path: []const u8,
    inputs: []const InputPath,
    out_path: []const u8,
};

pub const PrepareOutcome = struct { packet_sha256: [64]u8, bytes: usize };

pub const PrepareError = error{
    OutNotScratch,
    OutExists,
    PlanMalformed,
    PlanSchema,
    DuplicateInput,
    InvalidInputId,
    TooManyInputs,
};

/// Null when `out` is an absolute path below a scratch root without dot components.
pub fn scratchProblem(out: []const u8) ?[]const u8 {
    if (out.len == 0 or out[0] != '/') return "not absolute";
    var it = std.mem.splitScalar(u8, out, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..") or std.mem.eql(u8, c, ".")) return "dot component";
    }
    for (scratch_roots) |r| {
        if (std.mem.startsWith(u8, out, r) and out.len > r.len and out[out.len - 1] != '/') return null;
    }
    return "not below a scratch root";
}

/// Writes the packet for `args.plan_path` to `args.out_path`. The plan supplies coverage,
/// exceptions, evidence references, budgets and the two disabled-by-default capture flags.
/// `prepare` adds the digest of the binary and of each input, the canonical calibration order and
/// the pending post-activation checks. It does not judge the plan. `check` does.
pub fn prepare(gpa: Allocator, io: Io, args: PrepareArgs) !PrepareOutcome {
    if (scratchProblem(args.out_path) != null) return error.OutNotScratch;
    if (args.inputs.len > 16) return error.TooManyInputs;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plan_bytes = try readBounded(arena, io, args.plan_path, max_packet_bytes);
    const plan = std.json.parseFromSliceLeaky(Packet, arena, plan_bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return error.PlanMalformed,
    };
    if (!std.mem.eql(u8, plan.schema, schema_plan)) return error.PlanSchema;

    const bin = try hashFile(io, args.binary_path, max_binary_bytes);
    const inputs = try arena.alloc(InputBinding, args.inputs.len);
    for (args.inputs, inputs, 0..) |ip, *slot, i| {
        if (!idOk(ip.id)) return error.InvalidInputId;
        for (args.inputs[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, ip.id)) return error.DuplicateInput;
        }
        const d = try hashFile(io, ip.path, max_input_bytes);
        slot.* = .{ .id = ip.id, .sha256 = try arena.dupe(u8, &d.sha256), .bytes = d.bytes };
    }
    const steps = try arena.alloc(CalStep, calibration_steps.len);
    for (calibration_steps, steps) |s, *slot| slot.* = .{ .id = s.id, .phase = @tagName(s.phase) };
    const pend = try arena.alloc(Pending, postactivation_pending.len);
    for (postactivation_pending, pend) |id, *slot| slot.* = .{ .id = id, .status = "pending" };
    const cal_in = plan.calibration orelse Calibration{};

    const packet: Packet = .{
        .schema = schema_packet,
        .binary = .{ .sha256 = try arena.dupe(u8, &bin.sha256), .bytes = bin.bytes },
        .inputs = inputs,
        .coverage = plan.coverage,
        .exceptions = plan.exceptions,
        .evidence = plan.evidence,
        .budgets = plan.budgets,
        .calibration = .{
            .stop_after_identity = true,
            .private_capture_enabled = cal_in.private_capture_enabled,
            .full_inventory_enabled = cal_in.full_inventory_enabled,
            .steps = steps,
        },
        .postactivation = pend,
    };
    var aw: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(packet, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    const bytes = aw.written();
    if (bytes.len > max_packet_bytes) return error.PlanMalformed;

    const partial = try std.fmt.allocPrint(arena, "{s}.partial", .{args.out_path});
    {
        const f = Dir.cwd().createFile(io, partial, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => return error.OutExists,
            else => return e,
        };
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        try f.sync(io);
    }
    Dir.cwd().renamePreserve(partial, Dir.cwd(), args.out_path, io) catch |e| switch (e) {
        error.PathAlreadyExists => return error.OutExists,
        else => return e,
    };
    return .{ .packet_sha256 = sha256Hex(bytes), .bytes = bytes.len };
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var dg: [32]u8 = undefined;
    Sha256.hash(bytes, &dg, .{});
    return std.fmt.bytesToHex(dg, .lower);
}

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

pub const Diag = struct { code: []const u8, location: []const u8, message: []const u8 };

pub const Status = enum { blocked, offline_ready };

/// Result of `check`. `deinit` frees every slice.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    status: Status,
    diags: []const Diag,
    pending_native: []const []const u8,
    pending_contract: []const []const u8,
    unresolved_operations: []const []const u8,

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
    }

    pub fn has(r: *const Report, code: []const u8) bool {
        for (r.diags) |d| {
            if (std.mem.eql(u8, d.code, code)) return true;
        }
        return false;
    }

    pub fn hasAt(r: *const Report, code: []const u8, location: []const u8) bool {
        for (r.diags) |d| {
            if (std.mem.eql(u8, d.code, code) and std.mem.eql(u8, d.location, location)) return true;
        }
        return false;
    }

    /// Writes the machine-readable result.
    pub fn write(r: *const Report, w: *Io.Writer) !void {
        const order = [_][]const u8{ "identity", "synthetic", "recovery" };
        const wire = .{
            .schema = schema_result,
            .status = @tagName(r.status),
            .activation_readiness = if (r.status == .offline_ready) "ready_for_bounded_live_calibration" else "blocked",
            .capture_readiness = capture_readiness,
            .verified_acquisition = false,
            .native_calls_made = false,
            .diagnostics = r.diags,
            .pending_native = r.pending_native,
            .pending_contract = r.pending_contract,
            .unresolved_operations = r.unresolved_operations,
            .calibration_order = &order,
        };
        try std.json.Stringify.value(wire, .{ .whitespace = .indent_2 }, w);
        try w.writeByte('\n');
    }
};

/// Capture readiness in every result. Only live calibration evidence can change it, and that
/// evidence is outside this module.
pub const capture_readiness = "native_calibration_required";

pub const CheckArgs = struct {
    packet_path: []const u8,
    binary_path: ?[]const u8 = null,
    inputs: []const InputPath = &.{},
    features: CompiledFeatures = .{},
};

const Builder = struct {
    arena: Allocator,
    list: std.ArrayList(Diag) = .empty,
    truncated: bool = false,

    fn add(b: *Builder, code: []const u8, location: []const u8, comptime fmt: []const u8, args: anytype) !void {
        if (b.list.items.len >= max_diags) {
            if (!b.truncated) {
                b.truncated = true;
                try b.list.append(b.arena, .{ .code = "diagnostics_truncated", .location = "", .message = "more diagnostics were dropped" });
            }
            return;
        }
        try b.list.append(b.arena, .{
            .code = code,
            .location = try b.arena.dupe(u8, location),
            .message = try std.fmt.allocPrint(b.arena, fmt, args),
        });
    }
};

fn scanForbidden(b: *Builder, v: std.json.Value, where: []const u8, depth: usize) !void {
    if (depth > 16) return;
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                for (forbidden_keys) |k| {
                    if (std.mem.eql(u8, k, kv.key_ptr.*)) {
                        try b.add("forbidden_claim", where, "key `{s}` claims a verdict, verification or capture readiness. A packet cannot supply it", .{k});
                    }
                }
                const sub = try std.fmt.allocPrint(b.arena, "{s}/{s}", .{ where, kv.key_ptr.* });
                try scanForbidden(b, kv.value_ptr.*, sub, depth + 1);
            }
        },
        .array => |a| for (a.items, 0..) |x, i| {
            const sub = try std.fmt.allocPrint(b.arena, "{s}/{d}", .{ where, i });
            try scanForbidden(b, x, sub, depth + 1);
        },
        else => {},
    }
}

/// The budgets of a packet, or null when the packet cannot be read, does not parse or holds none.
/// `check` validates their ranges. The production run passes them to the runtime and the engine.
pub fn loadBudgets(arena: Allocator, io: Io, packet_path: []const u8) ?Budgets {
    const bytes = readBounded(arena, io, packet_path, max_packet_bytes) catch return null;
    const opts: std.json.ParseOptions = .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false };
    const p = std.json.parseFromSliceLeaky(Packet, arena, bytes, opts) catch return null;
    return p.budgets;
}

/// Validates the packet at `args.packet_path` against the supplied bindings and features. Every
/// failed rule adds a diagnostic. The status is `offline_ready` only when no diagnostic exists.
/// File and parse failures are diagnostics. Only allocation failure is an error.
pub fn check(gpa: Allocator, io: Io, args: CheckArgs) !Report {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var b: Builder = .{ .arena = arena };

    if (args.features.provenance.len == 0) try b.add("runtime_features_unwired", "features", "no compiled-feature table was supplied. Every feature and route stays unavailable", .{});

    var pending_contract: std.ArrayList([]const u8) = .empty;
    var unresolved: std.ArrayList([]const u8) = .empty;

    run: {
        const bytes = readBounded(arena, io, args.packet_path, max_packet_bytes) catch |e| {
            if (e == error.OutOfMemory) return e;
            try b.add(if (e == error.TooLarge) "packet_too_large" else "packet_unreadable", "packet", "cannot read the packet. {s}", .{@errorName(e)});
            break :run;
        };
        const opts: std.json.ParseOptions = .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false };
        const tree = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, opts) catch |e| {
            if (e == error.OutOfMemory) return e;
            try b.add("packet_malformed", "packet", "the packet is not valid JSON or is truncated. {s}", .{@errorName(e)});
            break :run;
        };
        try scanForbidden(&b, tree, "", 0);
        const p = std.json.parseFromSliceLeaky(Packet, arena, bytes, opts) catch |e| {
            if (e == error.OutOfMemory) return e;
            try b.add("packet_malformed", "packet", "the packet does not match the packet shape. {s}", .{@errorName(e)});
            break :run;
        };
        try checkPacket(&b, arena, io, p, args, &pending_contract, &unresolved);
    }
    try checkFeatures(&b, &args.features);

    var native: std.ArrayList([]const u8) = .empty;
    for (postactivation_pending) |id| try native.append(arena, id);
    return .{
        .arena = arena_state,
        .status = if (b.list.items.len == 0) .offline_ready else .blocked,
        .diags = b.list.items,
        .pending_native = native.items,
        .pending_contract = pending_contract.items,
        .unresolved_operations = unresolved.items,
    };
}

fn checkFeatures(b: *Builder, f: *const CompiledFeatures) !void {
    for (std.enums.values(Feature)) |x| {
        if (f.feature(x) != .implemented) try b.add("feature_unavailable", @tagName(x), "the binary does not compile `{s}`", .{@tagName(x)});
    }
}

fn checkPacket(b: *Builder, arena: Allocator, io: Io, p: Packet, args: CheckArgs, pending_contract: *std.ArrayList([]const u8), unresolved: *std.ArrayList([]const u8)) !void {
    if (!std.mem.eql(u8, p.schema, schema_packet)) try b.add("schema_mismatch", "schema", "expected `{s}`", .{schema_packet});
    if (p.coverage.len > max_entries or p.inputs.len > max_entries or p.exceptions.len > max_entries or p.evidence.len > max_entries) {
        try b.add("packet_too_large", "packet", "a list has more than {d} entries", .{max_entries});
        return;
    }
    try checkBinary(b, io, p, args);
    try checkInputs(b, io, p, args);
    try checkCoverage(b, arena, p, args, pending_contract, unresolved);
    try checkEvidence(b, p);
    try checkBudgets(b, p);
    try checkCalibration(b, p);
    try checkPostactivation(b, p);
}

fn checkBinary(b: *Builder, io: Io, p: Packet, args: CheckArgs) !void {
    const d = p.binary orelse {
        try b.add("binary_binding_missing", "binary", "the packet binds no binary digest", .{});
        return;
    };
    if (!isHex64(d.sha256)) {
        try b.add("binary_binding_malformed", "binary", "the digest is not a lowercase SHA256", .{});
        return;
    }
    const path = args.binary_path orelse {
        try b.add("binary_missing", "binary", "no executable was supplied for the digest check", .{});
        return;
    };
    const got = hashFile(io, path, max_binary_bytes) catch |e| {
        if (e == error.OutOfMemory) return e;
        try b.add("binary_unreadable", "binary", "cannot hash the executable. {s}", .{@errorName(e)});
        return;
    };
    if (!std.mem.eql(u8, &got.sha256, d.sha256) or got.bytes != d.bytes) try b.add("stale_binary", "binary", "the executable differs from the packet binding", .{});
}

fn checkInputs(b: *Builder, io: Io, p: Packet, args: CheckArgs) !void {
    for (p.inputs, 0..) |x, i| {
        if (!idOk(x.id) or !isHex64(x.sha256)) {
            try b.add("input_binding_malformed", x.id, "the input id or digest is malformed", .{});
            continue;
        }
        for (p.inputs[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, x.id)) try b.add("duplicate_input", x.id, "the packet binds this input twice", .{});
        }
    }
    for (required_inputs) |id| {
        var bound: ?InputBinding = null;
        for (p.inputs) |x| {
            if (std.mem.eql(u8, x.id, id)) {
                bound = x;
                break;
            }
        }
        const x = bound orelse {
            try b.add("input_binding_missing", id, "the packet binds no `{s}` input", .{id});
            continue;
        };
        var supplied: ?InputPath = null;
        for (args.inputs) |s| {
            if (std.mem.eql(u8, s.id, id)) supplied = s;
        }
        const s = supplied orelse {
            try b.add("input_missing", id, "no file was supplied for `{s}`", .{id});
            continue;
        };
        if (!isHex64(x.sha256)) continue;
        const got = hashFile(io, s.path, max_input_bytes) catch |e| {
            if (e == error.OutOfMemory) return e;
            try b.add("input_unreadable", id, "cannot hash `{s}`. {s}", .{ id, @errorName(e) });
            continue;
        };
        if (!std.mem.eql(u8, &got.sha256, x.sha256) or got.bytes != x.bytes) try b.add("stale_input", id, "`{s}` differs from the packet binding", .{id});
    }
    for (args.inputs) |s| {
        var known = false;
        for (p.inputs) |x| {
            if (std.mem.eql(u8, x.id, s.id)) known = true;
        }
        if (!known) try b.add("input_unbound", s.id, "a supplied input has no packet binding", .{});
    }
}

fn exceptionApproved(e: Exception) bool {
    return plainText(e.approved_by, 200) and plainText(e.approval_ref, 200) and plainText(e.approved_at, 64) and plainText(e.reason, 400);
}

fn checkCoverage(b: *Builder, arena: Allocator, p: Packet, args: CheckArgs, pending_contract: *std.ArrayList([]const u8), unresolved: *std.ArrayList([]const u8)) !void {
    for (p.exceptions) |e| {
        if (std.meta.stringToEnum(Route, e.operation) == null) try b.add("unknown_operation", e.operation, "an exception names an unknown operation", .{});
        if (!exceptionApproved(e)) try b.add("exception_unapproved", e.operation, "the exception lacks a reason, an approver, an approval reference or an approval time", .{});
    }
    for (std.enums.values(Route)) |r| {
        const name = @tagName(r);
        var entry: ?Coverage = null;
        var count: usize = 0;
        for (p.coverage) |c| {
            if (std.mem.eql(u8, c.operation, name)) {
                entry = c;
                count += 1;
            }
        }
        if (count > 1) try b.add("duplicate_operation", name, "the packet covers `{s}` more than once", .{name});
        const c = entry orelse {
            if (r.class() == .required) try b.add("coverage_incomplete", name, "no route engine or unresolved disposition for required operation `{s}`", .{name});
            continue;
        };
        try checkEntry(b, arena, c, r, p, args, pending_contract, unresolved);
    }
    for (p.coverage) |c| {
        if (std.meta.stringToEnum(Route, c.operation) == null) try b.add("unknown_operation", c.operation, "the coverage names an unknown operation", .{});
    }
}

fn checkEntry(b: *Builder, arena: Allocator, c: Coverage, r: Route, p: Packet, args: CheckArgs, pending_contract: *std.ArrayList([]const u8), unresolved: *std.ArrayList([]const u8)) !void {
    const name = @tagName(r);
    if (c.families.len == 0 or c.families.len > 32) try b.add("families_missing", name, "`{s}` lists no applicable object family", .{name});
    for (c.families) |f| {
        if (!idOk(f)) try b.add("families_malformed", name, "a family id of `{s}` is malformed", .{name});
    }
    if (!std.mem.eql(u8, c.profile_status, "unverified")) try b.add("premature_verified_profile", name, "every export profile stays unverified until live calibration", .{});
    if (std.mem.eql(u8, c.catalog_status, "pending_contract")) {
        if (c.catalog_identifier != null) try b.add("identifier_fabricated", name, "a catalog identifier that awaits coordinated contract work cannot be certified here", .{});
        try pending_contract.append(arena, name);
    } else if (!std.mem.eql(u8, c.catalog_status, "present")) {
        try b.add("catalog_status_malformed", name, "catalog_status must be `present` or `pending_contract`", .{});
    }
    if (std.mem.eql(u8, c.disposition, "engine")) {
        if (args.features.route(r) != .implemented) try b.add("route_unsupported", name, "the binary has no route engine for `{s}`", .{name});
    } else if (std.mem.eql(u8, c.disposition, "unresolved")) {
        var approved = false;
        for (p.exceptions) |e| {
            if (std.mem.eql(u8, e.operation, name) and exceptionApproved(e)) approved = true;
        }
        if (approved) {
            try unresolved.append(arena, name);
        } else {
            try b.add("exception_unapproved", name, "an unresolved disposition for `{s}` needs an approved exception", .{name});
        }
    } else {
        try b.add("disposition_malformed", name, "disposition must be `engine` or `unresolved`", .{});
    }
}

fn checkEvidence(b: *Builder, p: Packet) !void {
    var tests: usize = 0;
    var reviews: usize = 0;
    for (p.evidence, 0..) |e, i| {
        var loc_buf: [32]u8 = undefined;
        const loc = std.fmt.bufPrint(&loc_buf, "evidence/{d}", .{i}) catch "evidence";
        const is_test = std.mem.eql(u8, e.kind, "test");
        const is_review = std.mem.eql(u8, e.kind, "review");
        if (!is_test and !is_review) {
            try b.add("evidence_malformed", loc, "kind must be `test` or `review`", .{});
            continue;
        }
        if (!isCommit(e.commit)) try b.add("evidence_malformed", loc, "commit is not a 40 digit lowercase hex revision", .{});
        if (opdir.pathProblem(e.path) != null) try b.add("evidence_malformed", loc, "path is not a valid relative path", .{});
        if (is_test and !plainText(e.command, 512)) try b.add("evidence_malformed", loc, "a test reference needs the command", .{});
        if (is_test) tests += 1 else reviews += 1;
    }
    if (tests == 0) try b.add("evidence_missing", "evidence", "no test evidence reference", .{});
    if (reviews == 0) try b.add("evidence_missing", "evidence", "no review evidence reference", .{});
}

fn checkBudgets(b: *Builder, p: Packet) !void {
    const bd = p.budgets orelse {
        try b.add("budget_missing", "budgets", "the packet has no operation or run budget", .{});
        return;
    };
    if (bd.operation_deadline_ms == 0 or bd.run_budget_ms == 0 or bd.max_attempts_per_operation == 0) {
        try b.add("budget_missing", "budgets", "a budget value is absent or zero", .{});
        return;
    }
    if (bd.operation_deadline_ms > bd.run_budget_ms) try b.add("budget_failed", "budgets", "the operation deadline exceeds the run budget", .{});
    if (bd.operation_deadline_ms > max_operation_deadline_ms) try b.add("budget_failed", "budgets", "the operation deadline exceeds {d} ms", .{max_operation_deadline_ms});
    if (bd.run_budget_ms > max_run_budget_ms) try b.add("budget_failed", "budgets", "the run budget exceeds {d} ms", .{max_run_budget_ms});
    if (bd.max_attempts_per_operation > max_attempts_per_operation) try b.add("budget_failed", "budgets", "attempts per operation exceed {d}", .{max_attempts_per_operation});
}

fn checkCalibration(b: *Builder, p: Packet) !void {
    const cal = p.calibration orelse {
        try b.add("calibration_missing", "calibration", "the packet has no calibration order", .{});
        return;
    };
    if (!cal.stop_after_identity) try b.add("identity_stop_missing", "calibration", "calibration must stop after the identity and capability checks", .{});
    if (cal.private_capture_enabled) try b.add("private_capture_enabled", "calibration", "private-drawing capture stays disabled until a separate complete calibration record passes", .{});
    if (cal.full_inventory_enabled) try b.add("full_inventory_enabled", "calibration", "full inventory stays disabled until a separate complete calibration record passes", .{});
    for (cal.steps, 0..) |s, i| {
        for (cal.steps[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, s.id)) try b.add("duplicate_step", s.id, "the calibration list repeats a step", .{});
        }
        var known = false;
        for (calibration_steps) |c| {
            if (std.mem.eql(u8, c.id, s.id)) known = true;
        }
        if (!known) try b.add("unknown_step", s.id, "the calibration list names an unknown step", .{});
    }
    for (calibration_steps) |want| {
        var found: ?CalStep = null;
        for (cal.steps) |s| {
            if (std.mem.eql(u8, s.id, want.id)) found = s;
        }
        const s = found orelse {
            try b.add("calibration_step_missing", want.id, "required calibration step `{s}` is absent", .{want.id});
            continue;
        };
        if (!std.mem.eql(u8, s.phase, @tagName(want.phase))) try b.add("calibration_phase_wrong", want.id, "`{s}` belongs to phase `{s}`", .{ want.id, @tagName(want.phase) });
    }
    var prev_idx: ?usize = null;
    for (cal.steps) |s| {
        var idx: ?usize = null;
        for (calibration_steps, 0..) |c, k| {
            if (std.mem.eql(u8, c.id, s.id)) idx = k;
        }
        const k = idx orelse continue;
        if (prev_idx) |pk| {
            if (k < pk) {
                try b.add("calibration_order", s.id, "`{s}` is out of order. Phases run identity, synthetic, recovery", .{s.id});
                break;
            }
        }
        prev_idx = k;
    }
}

fn checkPostactivation(b: *Builder, p: Packet) !void {
    for (postactivation_pending) |id| {
        var found: ?Pending = null;
        for (p.postactivation) |x| {
            if (std.mem.eql(u8, x.id, id)) found = x;
        }
        const x = found orelse {
            try b.add("postactivation_missing", id, "the packet omits post-activation check `{s}`", .{id});
            continue;
        };
        if (!std.mem.eql(u8, x.status, "pending")) try b.add("premature_resolution", id, "`{s}` needs live evidence and stays pending", .{id});
    }
}

// ---------------------------------------------------------------------------
// integration seam
// ---------------------------------------------------------------------------

/// `legacy` keeps the behavior of fake and stub drivers. `activation_gate` is the requirement
/// that native capture expansion must choose.
pub const Requirements = enum { legacy, activation_gate };

pub const GateError = error{ActivationNotReady};

/// Call before native capture expansion. Under `legacy` it returns at once. Under
/// `activation_gate` it returns `ActivationNotReady` unless a report with status `offline_ready`
/// exists. A passing gate allows bounded live calibration only.
pub fn enforce(req: Requirements, report: ?*const Report) GateError!void {
    switch (req) {
        .legacy => {},
        .activation_gate => {
            const r = report orelse return error.ActivationNotReady;
            if (r.status != .offline_ready) return error.ActivationNotReady;
        },
    }
}

/// Verified acquisition needs native evidence that this module cannot read. The answer is false.
pub fn verifiedAcquisitionAllowed(report: *const Report) bool {
    _ = report;
    return false;
}

// ---------------------------------------------------------------------------
// command line
// ---------------------------------------------------------------------------

const usage =
    \\usage:
    \\  activation prepare --plan <plan.json> --binary <exe> --out <packet.json> [--input <id>=<path>]...
    \\  activation check --packet <packet.json> --binary <exe> [--input <id>=<path>]...
    \\exit status: 0 offline_ready, 1 blocked or a refused request, 2 usage.
    \\
;

/// Router for the integration author. It uses `unavailable` features, so `check` reports
/// `runtime_features_unwired`. Use `runWith` with the compiled table.
pub fn run(gpa: Allocator, io: Io, args: []const []const u8, out: *Io.Writer) u8 {
    return runWith(gpa, io, args, out, .{});
}

/// Example. `activation prepare --plan /tmp/x/plan.json --binary ./vwx --input queue=q.txt
/// --input profiles=p.txt --input recipes=r.txt --out /tmp/x/packet.json`, then
/// `activation check --packet /tmp/x/packet.json --binary ./vwx --input queue=q.txt ...`.
pub fn runWith(gpa: Allocator, io: Io, args: []const []const u8, out: *Io.Writer, features: CompiledFeatures) u8 {
    if (args.len == 0) return usageError(out);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plan: ?[]const u8 = null;
    var packet: ?[]const u8 = null;
    var binary: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var inputs: std.ArrayList(InputPath) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return usageError(out);
        const flag = args[i];
        const val = args[i + 1];
        if (std.mem.eql(u8, flag, "--plan")) {
            plan = val;
        } else if (std.mem.eql(u8, flag, "--packet")) {
            packet = val;
        } else if (std.mem.eql(u8, flag, "--binary")) {
            binary = val;
        } else if (std.mem.eql(u8, flag, "--out")) {
            out_path = val;
        } else if (std.mem.eql(u8, flag, "--input")) {
            const eq = std.mem.indexOfScalar(u8, val, '=') orelse return usageError(out);
            inputs.append(arena, .{ .id = val[0..eq], .path = val[eq + 1 ..] }) catch return 1;
        } else return usageError(out);
    }
    if (std.mem.eql(u8, args[0], "prepare")) {
        if (plan == null or binary == null or out_path == null) return usageError(out);
        const r = prepare(gpa, io, .{ .plan_path = plan.?, .binary_path = binary.?, .inputs = inputs.items, .out_path = out_path.? }) catch |e| {
            out.print("{{\"schema\":\"{s}\",\"error\":\"{s}\"}}\n", .{ schema_prepare, @errorName(e) }) catch {};
            return 1;
        };
        out.print("{{\"schema\":\"{s}\",\"packet\":\"{s}\",\"packet_sha256\":\"{s}\",\"bytes\":{d}}}\n", .{ schema_prepare, out_path.?, &r.packet_sha256, r.bytes }) catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, args[0], "check")) {
        if (packet == null) return usageError(out);
        var rep = check(gpa, io, .{ .packet_path = packet.?, .binary_path = binary, .inputs = inputs.items, .features = features }) catch return 1;
        defer rep.deinit();
        rep.write(out) catch return 1;
        return if (rep.status == .offline_ready) 0 else 1;
    }
    return usageError(out);
}

fn usageError(out: *Io.Writer) u8 {
    out.writeAll(usage) catch {};
    return 2;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
//
// Tests use generated synthetic inputs with harmless extensions. Each filesystem test makes a
// scratch directory with `mktemp -d` under /tmp and removes it through `discard`. Tests run from
// the repository root. No test reads a drawing, a license file or a native application.

const testing = std.testing;
const Scratch = opdir.Scratch;

const commit_a = "0123456789abcdef0123456789abcdef01234567";

fn fullFeatures() CompiledFeatures {
    var f: CompiledFeatures = .{ .provenance = "test-table/1" };
    for (std.enums.values(Feature)) |x| f.setFeature(x, .implemented);
    for (std.enums.values(Route)) |r| f.setRoute(r, .implemented);
    return f;
}

const PlanOpts = struct {
    omit: ?[]const u8 = null,
    duplicate: ?[]const u8 = null,
    unresolved: ?[]const u8 = null,
    exception: enum { none, approved, unapproved } = .none,
    budgets: enum { ok, absent, zero, deadline_over_run, run_too_long, attempts } = .ok,
    verified_profile: ?[]const u8 = null,
    fabricate_id: bool = false,
    private_capture: bool = false,
    evidence: enum { ok, none, bad_commit, no_review } = .ok,
    empty_families: bool = false,
    unknown_op: bool = false,
};

const required_ops = [_][]const u8{ "dxf", "dwg", "pdf", "png", "obj", "stl", "3ds", "fbx", "parasolid", "step" };

fn planText(a: Allocator, o: PlanOpts) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.writeAll("{\"schema\":\"vwx-rosetta-activation-plan/1\",\"coverage\":[");
    var first = true;
    for (required_ops) |op| {
        if (o.omit) |x| if (std.mem.eql(u8, x, op)) continue;
        const times: usize = if (o.duplicate) |d| (if (std.mem.eql(u8, d, op)) 2 else 1) else 1;
        for (0..times) |_| {
            if (!first) try w.writeAll(",");
            first = false;
            const unresolved = if (o.unresolved) |u| std.mem.eql(u8, u, op) else false;
            const verified = if (o.verified_profile) |v| std.mem.eql(u8, v, op) else false;
            const pending = std.mem.eql(u8, op, "step") or std.mem.eql(u8, op, "parasolid");
            try w.print("{{\"operation\":\"{s}\",\"disposition\":\"{s}\",\"families\":{s},\"profile_status\":\"{s}\",\"catalog_status\":\"{s}\",\"catalog_identifier\":{s}}}", .{
                op,
                if (unresolved) "unresolved" else "engine",
                if (o.empty_families) "[]" else "[\"solid\",\"mesh\"]",
                if (verified) "verified" else "unverified",
                if (pending) "pending_contract" else "present",
                if (o.fabricate_id and std.mem.eql(u8, op, "step")) "\"step.solids\"" else "null",
            });
        }
    }
    if (o.unknown_op) try w.writeAll(",{\"operation\":\"dgn\",\"disposition\":\"engine\",\"families\":[\"x\"]}");
    try w.writeAll("],\"exceptions\":[");
    switch (o.exception) {
        .none => {},
        .approved => try w.print("{{\"operation\":\"{s}\",\"reason\":\"no trial entry for this format\",\"approved_by\":\"maintainer\",\"approval_ref\":\"approval-001\",\"approved_at\":\"2026-10-12\"}}", .{o.unresolved orelse "step"}),
        .unapproved => try w.print("{{\"operation\":\"{s}\",\"reason\":\"no trial entry for this format\",\"approved_by\":\"maintainer\",\"approval_ref\":\"\",\"approved_at\":\"2026-10-12\"}}", .{o.unresolved orelse "step"}),
    }
    try w.writeAll("],\"evidence\":[");
    switch (o.evidence) {
        .none => {},
        .ok, .bad_commit, .no_review => {
            try w.print("{{\"kind\":\"test\",\"commit\":\"{s}\",\"command\":\"zig test vwx/src/rosetta_opdir.zig\",\"path\":\"vwx/tools/research/trial-export-bundle/test-run.log\"}}", .{if (o.evidence == .bad_commit) "abc" else commit_a});
            if (o.evidence != .no_review) try w.print(",{{\"kind\":\"review\",\"commit\":\"{s}\",\"path\":\"reviews/report.md\"}}", .{commit_a});
        },
    }
    try w.writeAll("],\"budgets\":");
    switch (o.budgets) {
        .ok => try w.writeAll("{\"operation_deadline_ms\":120000,\"run_budget_ms\":1800000,\"max_attempts_per_operation\":3}"),
        .absent => try w.writeAll("null"),
        .zero => try w.writeAll("{\"operation_deadline_ms\":0,\"run_budget_ms\":1800000,\"max_attempts_per_operation\":3}"),
        .deadline_over_run => try w.writeAll("{\"operation_deadline_ms\":2000000,\"run_budget_ms\":1800000,\"max_attempts_per_operation\":3}"),
        .run_too_long => try w.writeAll("{\"operation_deadline_ms\":120000,\"run_budget_ms\":99999999,\"max_attempts_per_operation\":3}"),
        .attempts => try w.writeAll("{\"operation_deadline_ms\":120000,\"run_budget_ms\":1800000,\"max_attempts_per_operation\":9}"),
    }
    try w.print(",\"calibration\":{{\"private_capture_enabled\":{s},\"full_inventory_enabled\":false}}}}", .{if (o.private_capture) "true" else "false"});
    return aw.toOwnedSlice();
}

const Fx = struct {
    sc: Scratch,
    arena: std.heap.ArenaAllocator,
    n: usize = 0,

    fn init() !Fx {
        var f: Fx = .{ .sc = try Scratch.init(), .arena = std.heap.ArenaAllocator.init(testing.allocator) };
        errdefer f.deinit();
        const bin = try testing.allocator.alloc(u8, 100_000);
        defer testing.allocator.free(bin);
        for (bin, 0..) |*b, i| b.* = @truncate(i *% 31);
        try f.write("app.bin", bin);
        try f.write("queue.txt", "queue bytes\n");
        try f.write("profiles.txt", "profile bytes\n");
        try f.write("recipes.txt", "recipe bytes\n");
        return f;
    }

    fn deinit(f: *Fx) void {
        f.arena.deinit();
        f.sc.deinit();
    }

    fn a(f: *Fx) Allocator {
        return f.arena.allocator();
    }

    fn path(f: *Fx, name: []const u8) []u8 {
        return std.fmt.allocPrint(f.a(), "{s}/{s}", .{ f.sc.path, name }) catch @panic("oom");
    }

    fn write(f: *Fx, name: []const u8, bytes: []const u8) !void {
        const fh = try Dir.cwd().createFile(testing.io, f.path(name), .{ .exclusive = true });
        defer fh.close(testing.io);
        try fh.writeStreamingAll(testing.io, bytes);
    }

    fn append(f: *Fx, name: []const u8, bytes: []const u8) !void {
        const fh = try Dir.cwd().createFile(testing.io, f.path(name), .{ .truncate = false });
        defer fh.close(testing.io);
        const st = try fh.stat(testing.io);
        try fh.writePositionalAll(testing.io, bytes, st.size);
    }

    fn read(f: *Fx, name: []const u8) ![]u8 {
        return Dir.cwd().readFileAlloc(testing.io, f.path(name), f.a(), .limited(8 << 20));
    }

    fn inputs(f: *Fx) []const InputPath {
        const list = f.a().alloc(InputPath, 3) catch @panic("oom");
        list[0] = .{ .id = "queue", .path = f.path("queue.txt") };
        list[1] = .{ .id = "profiles", .path = f.path("profiles.txt") };
        list[2] = .{ .id = "recipes", .path = f.path("recipes.txt") };
        return list;
    }

    /// Writes the plan as `plan<n>.txt` and the packet as `packet<n>.json`. Returns the packet name.
    fn prep(f: *Fx, o: PlanOpts) ![]const u8 {
        f.n += 1;
        const plan_name = try std.fmt.allocPrint(f.a(), "plan{d}.txt", .{f.n});
        const packet_name = try std.fmt.allocPrint(f.a(), "packet{d}.json", .{f.n});
        try f.write(plan_name, try planText(f.a(), o));
        _ = try prepare(testing.allocator, testing.io, .{ .plan_path = f.path(plan_name), .binary_path = f.path("app.bin"), .inputs = f.inputs(), .out_path = f.path(packet_name) });
        return packet_name;
    }

    fn chk(f: *Fx, packet_name: []const u8, features: CompiledFeatures) !Report {
        return check(testing.allocator, testing.io, .{ .packet_path = f.path(packet_name), .binary_path = f.path("app.bin"), .inputs = f.inputs(), .features = features });
    }

    /// Writes a modified copy of a packet and returns its name.
    fn variant(f: *Fx, packet_name: []const u8, needle: []const u8, with: []const u8) ![]const u8 {
        const text = try f.read(packet_name);
        const changed = try std.mem.replaceOwned(u8, f.a(), text, needle, with);
        if (std.mem.eql(u8, text, changed)) return error.NeedleNotFound;
        f.n += 1;
        const name = try std.fmt.allocPrint(f.a(), "variant{d}.json", .{f.n});
        try f.write(name, changed);
        return name;
    }
};

fn expectBlocked(r: *const Report, code: []const u8) !void {
    if (r.status != .blocked or !r.has(code)) {
        std.debug.print("expected blocked with `{s}`. status {s}\n", .{ code, @tagName(r.status) });
        for (r.diags) |d| std.debug.print("  diag {s} at `{s}`. {s}\n", .{ d.code, d.location, d.message });
        return error.TestUnexpectedResult;
    }
}

fn expectReady(r: *const Report) !void {
    if (r.status != .offline_ready) {
        for (r.diags) |d| std.debug.print("  diag {s} at `{s}`. {s}\n", .{ d.code, d.location, d.message });
        return error.TestUnexpectedResult;
    }
}

test "compiled features default to unavailable and carry no provenance" {
    const f: CompiledFeatures = .{};
    for (std.enums.values(Feature)) |x| try testing.expectEqual(Availability.unavailable, f.feature(x));
    for (std.enums.values(Route)) |x| try testing.expectEqual(Availability.unavailable, f.route(x));
    try testing.expectEqual(@as(usize, 0), f.provenance.len);
}

test "route classes cover the required, targeted and early check lists" {
    var req: usize = 0;
    var tgt: usize = 0;
    var early: usize = 0;
    for (std.enums.values(Route)) |r| switch (r.class()) {
        .required => req += 1,
        .targeted => tgt += 1,
        .early_check => early += 1,
    };
    try testing.expectEqual(@as(usize, 10), req);
    try testing.expectEqual(@as(usize, 5), tgt);
    try testing.expectEqual(@as(usize, 3), early);
    for (required_ops) |n| try testing.expect(std.meta.stringToEnum(Route, n).?.class() == .required);
}

test "calibration order stops after identity checks and keeps early checks first" {
    var stop: usize = 0;
    var skp: usize = 0;
    var svg: usize = 0;
    var gltf: usize = 0;
    var first_synthetic: usize = calibration_steps.len;
    var first_recovery: usize = calibration_steps.len;
    var last_phase: usize = 0;
    for (calibration_steps, 0..) |s, i| {
        try testing.expect(@intFromEnum(s.phase) >= last_phase);
        last_phase = @intFromEnum(s.phase);
        if (std.mem.eql(u8, s.id, "identity_stop_gate")) stop = i;
        if (std.mem.eql(u8, s.id, "early_skp_availability")) skp = i;
        if (std.mem.eql(u8, s.id, "early_svg_availability")) svg = i;
        if (std.mem.eql(u8, s.id, "early_gltf_availability")) gltf = i;
        if (s.phase == .synthetic and first_synthetic == calibration_steps.len) first_synthetic = i;
        if (s.phase == .recovery and first_recovery == calibration_steps.len) first_recovery = i;
    }
    try testing.expect(skp < stop and svg < stop and gltf < stop);
    try testing.expect(stop + 1 == first_synthetic);
    try testing.expect(first_synthetic < first_recovery);
    for ([_][]const u8{ "edition_version_build_platform", "api_save_close_path_identity", "units_origins_visibility_codes", "menu_dialog_tab_inventory", "source_template_hash_pid", "paired_same_state_exports", "profile_options", "sidecar_manifests", "unsupported_object_families", "sketchup_interchange" }) |id| {
        var found = false;
        for (calibration_steps) |s| {
            if (std.mem.eql(u8, s.id, id)) found = true;
        }
        try testing.expect(found);
    }
}

test "a complete offline toolchain is ready to activate and native calibration stays required" {
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    var r = try fx.chk(name, fullFeatures());
    defer r.deinit();
    try expectReady(&r);
    try testing.expectEqual(postactivation_pending.len, r.pending_native.len);
    try testing.expectEqual(@as(usize, 2), r.pending_contract.len);
    try testing.expectEqualStrings("parasolid", r.pending_contract[0]);
    try testing.expectEqualStrings("step", r.pending_contract[1]);
    try testing.expect(!verifiedAcquisitionAllowed(&r));
    try enforce(.activation_gate, &r);
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try r.write(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "\"status\": \"offline_ready\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"activation_readiness\": \"ready_for_bounded_live_calibration\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"capture_readiness\": \"native_calibration_required\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"verified_acquisition\": false") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"native_calls_made\": false") != null);
    const packet = try fx.read(name);
    for (calibration_steps) |s| try testing.expect(std.mem.indexOf(u8, packet, s.id) != null);
    try testing.expect(std.mem.indexOf(u8, packet, "\"private_capture_enabled\": false") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "\"profile_status\": \"unverified\"") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "\"stop_after_identity\": true") != null);
}

test "the gate refuses without a ready report and leaves legacy behavior alone" {
    try enforce(.legacy, null);
    try testing.expectError(error.ActivationNotReady, enforce(.activation_gate, null));
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    var r = try fx.chk(name, .{});
    defer r.deinit();
    try testing.expectError(error.ActivationNotReady, enforce(.activation_gate, &r));
    try enforce(.legacy, &r);
}

test "missing runtime wiring blocks with every feature and route unavailable" {
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    var r = try fx.chk(name, .{});
    defer r.deinit();
    try expectBlocked(&r, "runtime_features_unwired");
    for (std.enums.values(Feature)) |x| try testing.expect(r.hasAt("feature_unavailable", @tagName(x)));
    for (required_ops) |op| try testing.expect(r.hasAt("route_unsupported", op));
    // A table with provenance but nothing implemented is still blocked on the features.
    var partial: CompiledFeatures = .{ .provenance = "empty-table/1" };
    partial.setRoute(.dxf, .implemented);
    var r2 = try fx.chk(name, partial);
    defer r2.deinit();
    try testing.expect(!r2.has("runtime_features_unwired"));
    try expectBlocked(&r2, "feature_unavailable");
}

test "each missing feature and each missing required route blocks on its own" {
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    for (std.enums.values(Feature)) |x| {
        var f = fullFeatures();
        f.setFeature(x, .unavailable);
        var r = try fx.chk(name, f);
        defer r.deinit();
        try expectBlocked(&r, "feature_unavailable");
        try testing.expectEqual(@as(usize, 1), r.diags.len);
        try testing.expect(r.hasAt("feature_unavailable", @tagName(x)));
    }
    for (required_ops) |op| {
        var f = fullFeatures();
        f.setRoute(std.meta.stringToEnum(Route, op).?, .unavailable);
        var r = try fx.chk(name, f);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.diags.len);
        try testing.expect(r.hasAt("route_unsupported", op));
    }
}

test "a stale binary or stale input is refused" {
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    {
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectReady(&r);
    }
    try fx.append("queue.txt", "x");
    {
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "stale_input");
        try testing.expect(r.hasAt("stale_input", "queue"));
        try testing.expectEqual(@as(usize, 1), r.diags.len);
    }
    try fx.append("profiles.txt", "x");
    try fx.append("recipes.txt", "x");
    {
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("stale_input", "profiles"));
        try testing.expect(r.hasAt("stale_input", "recipes"));
    }
    try fx.append("app.bin", "x");
    {
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "stale_binary");
    }
}

test "missing, unbound and duplicate bindings have their own diagnostics" {
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    {
        var r = try check(testing.allocator, testing.io, .{ .packet_path = fx.path(name), .binary_path = null, .inputs = fx.inputs(), .features = fullFeatures() });
        defer r.deinit();
        try expectBlocked(&r, "binary_missing");
    }
    {
        var r = try check(testing.allocator, testing.io, .{ .packet_path = fx.path(name), .binary_path = fx.path("app.bin"), .inputs = fx.inputs()[0..2], .features = fullFeatures() });
        defer r.deinit();
        try expectBlocked(&r, "input_missing");
        try testing.expect(r.hasAt("input_missing", "recipes"));
    }
    {
        const extra = try fx.a().alloc(InputPath, 4);
        @memcpy(extra[0..3], fx.inputs());
        extra[3] = .{ .id = "extra", .path = fx.path("queue.txt") };
        var r = try check(testing.allocator, testing.io, .{ .packet_path = fx.path(name), .binary_path = fx.path("app.bin"), .inputs = extra, .features = fullFeatures() });
        defer r.deinit();
        try expectBlocked(&r, "input_unbound");
    }
    {
        // Two bindings with one id, and the real `queue` binding gone.
        const v = try fx.variant(name, "\"id\": \"queue\"", "\"id\": \"recipes\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "duplicate_input");
        try testing.expect(r.hasAt("input_binding_missing", "queue"));
    }
    {
        const v = try fx.variant(name, "\"binary\": {", "\"binary\": null, \"unused_binary\": {");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "packet_malformed");
    }
    {
        var r = try check(testing.allocator, testing.io, .{ .packet_path = fx.path(name), .binary_path = fx.path("does-not-exist.bin"), .inputs = fx.inputs(), .features = fullFeatures() });
        defer r.deinit();
        try expectBlocked(&r, "binary_unreadable");
    }
}

test "truncated, malformed, oversized and unreadable packets are diagnostics" {
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    const text = try fx.read(name);
    var k: usize = 1;
    while (k < 8) : (k += 1) {
        const cut = try std.fmt.allocPrint(fx.a(), "cut{d}.json", .{k});
        try fx.write(cut, text[0 .. text.len * k / 8]);
        var r = try fx.chk(cut, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "packet_malformed");
        try testing.expectEqual(@as(usize, 1), r.diags.len);
    }
    try fx.write("empty.json", "");
    try fx.write("garbage.json", "not json at all");
    try fx.write("array.json", "[]");
    for ([_][]const u8{ "empty.json", "garbage.json", "array.json" }) |n| {
        var r = try fx.chk(n, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "packet_malformed");
    }
    {
        const v = try fx.variant(name, "{\n  \"schema\"", "{\n  \"unexpected\": 1,\n  \"schema\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "packet_malformed");
    }
    {
        const v = try fx.variant(name, "activation-packet/1", "activation-packet/2");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "schema_mismatch");
    }
    {
        const big = try testing.allocator.alloc(u8, max_packet_bytes + 1);
        defer testing.allocator.free(big);
        @memset(big, ' ');
        try fx.write("big.json", big);
        var r = try fx.chk("big.json", fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "packet_too_large");
    }
    {
        var r = try fx.chk("missing.json", fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "packet_unreadable");
    }
}

test "a FIFO packet or binary fails at once without blocking" {
    var fx = try Fx.init();
    defer fx.deinit();
    const fp = fx.path("pipe.json");
    const z = try testing.allocator.dupeZ(u8, fp);
    defer testing.allocator.free(z);
    if (opdir.mkfifo(z.ptr, 0o600) != 0) {
        std.debug.print("mkfifo failed. FIFO case skipped\n", .{});
        return;
    }
    var wd: opdir.Watchdog = .{ .path = fp };
    const th = try opdir.startWatchdog(&wd);
    const t0 = opdir.nowNs();
    var r = try fx.chk("pipe.json", fullFeatures());
    defer r.deinit();
    try expectBlocked(&r, "packet_unreadable");
    try testing.expectError(error.NotRegular, hashFile(testing.io, fp, 1 << 20));
    const t1 = opdir.nowNs();
    wd.done.store(true, .release);
    th.join();
    try testing.expect(!wd.fired.load(.acquire));
    try testing.expect(t1 - t0 < 2000 * std.time.ns_per_ms);
    std.debug.print("evidence\tactivation_fifo_ns={d}\n", .{t1 - t0});
    try testing.expectError(error.NotRegular, hashFile(testing.io, fx.sc.path, 1 << 20));
}

test "incomplete, duplicate and unknown operation coverage is refused" {
    var fx = try Fx.init();
    defer fx.deinit();
    for (required_ops) |op| {
        const name = try fx.prep(.{ .omit = op });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("coverage_incomplete", op));
        try testing.expectEqual(@as(usize, 1), r.diags.len);
    }
    {
        const name = try fx.prep(.{ .duplicate = "obj" });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("duplicate_operation", "obj"));
    }
    {
        const name = try fx.prep(.{ .unknown_op = true });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "unknown_operation");
    }
    {
        const name = try fx.prep(.{ .empty_families = true });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "families_missing");
    }
}

test "unresolved operations need an approved exception and stay listed" {
    var fx = try Fx.init();
    defer fx.deinit();
    {
        const name = try fx.prep(.{ .unresolved = "fbx" });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("exception_unapproved", "fbx"));
    }
    {
        const name = try fx.prep(.{ .unresolved = "fbx", .exception = .unapproved });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("exception_unapproved", "fbx"));
    }
    {
        const name = try fx.prep(.{ .unresolved = "fbx", .exception = .approved });
        var f = fullFeatures();
        f.setRoute(.fbx, .unavailable);
        var r = try fx.chk(name, f);
        defer r.deinit();
        try expectReady(&r);
        try testing.expectEqual(@as(usize, 1), r.unresolved_operations.len);
        try testing.expectEqualStrings("fbx", r.unresolved_operations[0]);
        try testing.expect(!verifiedAcquisitionAllowed(&r));
    }
    {
        // An engine disposition that the binary does not compile is not rescued by an exception.
        const name = try fx.prep(.{ .exception = .approved });
        var f = fullFeatures();
        f.setRoute(.step, .unavailable);
        var r = try fx.chk(name, f);
        defer r.deinit();
        try testing.expect(r.hasAt("route_unsupported", "step"));
    }
}

test "absent, zero and failed budgets are refused" {
    var fx = try Fx.init();
    defer fx.deinit();
    const cases = [_]struct { o: PlanOpts, code: []const u8 }{
        .{ .o = .{ .budgets = .absent }, .code = "budget_missing" },
        .{ .o = .{ .budgets = .zero }, .code = "budget_missing" },
        .{ .o = .{ .budgets = .deadline_over_run }, .code = "budget_failed" },
        .{ .o = .{ .budgets = .run_too_long }, .code = "budget_failed" },
        .{ .o = .{ .budgets = .attempts }, .code = "budget_failed" },
    };
    for (cases) |c| {
        const name = try fx.prep(c.o);
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, c.code);
    }
}

test "evidence references are required and carry no verdict" {
    var fx = try Fx.init();
    defer fx.deinit();
    {
        const name = try fx.prep(.{ .evidence = .none });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "evidence_missing");
    }
    {
        const name = try fx.prep(.{ .evidence = .no_review });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "evidence_missing");
    }
    {
        const name = try fx.prep(.{ .evidence = .bad_commit });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "evidence_malformed");
    }
    const ok = try fx.prep(.{});
    {
        const v = try fx.variant(ok, "\"kind\": \"review\",", "\"kind\": \"review\",\n      \"verdict\": \"pass\",");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "forbidden_claim");
    }
    {
        const v = try fx.variant(ok, "\"calibration\": {", "\"capture_ready\": true,\n  \"calibration\": {");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "forbidden_claim");
    }
}

test "a packet cannot manufacture a verified profile, an identifier or a resolved check" {
    var fx = try Fx.init();
    defer fx.deinit();
    {
        const name = try fx.prep(.{ .verified_profile = "obj" });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("premature_verified_profile", "obj"));
        try testing.expect(r.status == .blocked);
    }
    {
        const name = try fx.prep(.{ .fabricate_id = true });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("identifier_fabricated", "step"));
    }
    {
        const name = try fx.prep(.{ .private_capture = true });
        var r = try fx.chk(name, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "private_capture_enabled");
    }
    const ok = try fx.prep(.{});
    {
        const v = try fx.variant(ok, "\"status\": \"pending\"", "\"status\": \"resolved\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "premature_resolution");
        try testing.expect(r.hasAt("premature_resolution", "release_binding"));
    }
    {
        const v = try fx.variant(ok, "\"release_binding\"", "\"release_binding_x\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "postactivation_missing");
    }
    {
        const v = try fx.variant(ok, "\"catalog_status\": \"pending_contract\"", "\"catalog_status\": \"certified\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "catalog_status_malformed");
    }
}

test "calibration order, identity stop and duplicate steps are validated" {
    var fx = try Fx.init();
    defer fx.deinit();
    const ok = try fx.prep(.{});
    {
        const v = try fx.variant(ok, "\"stop_after_identity\": true", "\"stop_after_identity\": false");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "identity_stop_missing");
    }
    {
        const v = try fx.variant(ok, "\"early_skp_availability\"", "\"early_skp_availabilityx\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try testing.expect(r.hasAt("calibration_step_missing", "early_skp_availability"));
        try testing.expect(r.hasAt("unknown_step", "early_skp_availabilityx"));
    }
    {
        const v = try fx.variant(ok, "\"early_svg_availability\"", "\"early_skp_availability\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "duplicate_step");
    }
    {
        const v = try fx.variant(ok, "\"phase\": \"recovery\"", "\"phase\": \"identity\"");
        var r = try fx.chk(v, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "calibration_phase_wrong");
    }
    {
        // Swap the ids of two steps so that a later step comes first.
        const v1 = try fx.variant(ok, "\"edition_version_build_platform\"", "\"@swap@\"");
        const v2 = try fx.variant(v1, "\"budget_measurement\"", "\"edition_version_build_platform\"");
        const v3 = try fx.variant(v2, "\"@swap@\"", "\"budget_measurement\"");
        var r = try fx.chk(v3, fullFeatures());
        defer r.deinit();
        try expectBlocked(&r, "calibration_order");
    }
}

test "prepare writes only below scratch, never overwrites and is deterministic" {
    var fx = try Fx.init();
    defer fx.deinit();
    const plan_name = "plan-direct.txt";
    try fx.write(plan_name, try planText(fx.a(), .{}));
    const base: PrepareArgs = .{ .plan_path = fx.path(plan_name), .binary_path = fx.path("app.bin"), .inputs = fx.inputs(), .out_path = fx.path("one.json") };
    for ([_][]const u8{ "/Users/someone/packet.json", "relative.json", "/tmp/../etc/packet.json", "/tmp/", "/etc/packet.json", "" }) |bad| {
        var a = base;
        a.out_path = bad;
        try testing.expectError(error.OutNotScratch, prepare(testing.allocator, testing.io, a));
    }
    const first = try prepare(testing.allocator, testing.io, base);
    const bytes1 = try fx.read("one.json");
    try testing.expectEqualSlices(u8, &sha256Hex(bytes1), &first.packet_sha256);
    try testing.expectError(error.OutExists, prepare(testing.allocator, testing.io, base));
    try testing.expectEqualStrings(bytes1, try fx.read("one.json"));
    var second = base;
    second.out_path = fx.path("two.json");
    _ = try prepare(testing.allocator, testing.io, second);
    try testing.expectEqualStrings(bytes1, try fx.read("two.json"));
    // A stale partial file from an interrupted prepare is not replaced.
    try fx.write("three.json.partial", "half");
    var third = base;
    third.out_path = fx.path("three.json");
    try testing.expectError(error.OutExists, prepare(testing.allocator, testing.io, third));
    try testing.expectEqualStrings("half", try fx.read("three.json.partial"));
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(testing.io, fx.path("three.json"), .{}));
}

test "prepare refuses malformed plans, schemas and input lists" {
    var fx = try Fx.init();
    defer fx.deinit();
    const mk = struct {
        fn args(f: *Fx, plan: []const u8, out: []const u8) PrepareArgs {
            return .{ .plan_path = f.path(plan), .binary_path = f.path("app.bin"), .inputs = f.inputs(), .out_path = f.path(out) };
        }
    }.args;
    try fx.write("bad1.txt", "{\"schema\":");
    try testing.expectError(error.PlanMalformed, prepare(testing.allocator, testing.io, mk(&fx, "bad1.txt", "o1.json")));
    try fx.write("bad2.txt", "{\"schema\":\"vwx-rosetta-activation-plan/1\",\"verdict\":\"pass\"}");
    try testing.expectError(error.PlanMalformed, prepare(testing.allocator, testing.io, mk(&fx, "bad2.txt", "o2.json")));
    try fx.write("bad3.txt", "{\"schema\":\"vwx-rosetta-activation-plan/9\"}");
    try testing.expectError(error.PlanSchema, prepare(testing.allocator, testing.io, mk(&fx, "bad3.txt", "o3.json")));
    try testing.expectError(error.FileNotFound, prepare(testing.allocator, testing.io, mk(&fx, "absent.txt", "o4.json")));
    try fx.write("ok.txt", try planText(fx.a(), .{}));
    var dup = mk(&fx, "ok.txt", "o5.json");
    const two = [_]InputPath{ .{ .id = "queue", .path = fx.path("queue.txt") }, .{ .id = "queue", .path = fx.path("queue.txt") } };
    dup.inputs = &two;
    try testing.expectError(error.DuplicateInput, prepare(testing.allocator, testing.io, dup));
    const badid = [_]InputPath{.{ .id = "bad id", .path = fx.path("queue.txt") }};
    dup.inputs = &badid;
    try testing.expectError(error.InvalidInputId, prepare(testing.allocator, testing.io, dup));
    var nobin = mk(&fx, "ok.txt", "o6.json");
    nobin.binary_path = fx.path("no-binary.bin");
    try testing.expectError(error.FileNotFound, prepare(testing.allocator, testing.io, nobin));
    for ([_][]const u8{ "o1.json", "o2.json", "o3.json", "o4.json", "o5.json", "o6.json" }) |n| {
        try testing.expectError(error.FileNotFound, Dir.cwd().statFile(testing.io, fx.path(n), .{}));
    }
}

test "the command line router prepares and checks and reports usage errors" {
    var fx = try Fx.init();
    defer fx.deinit();
    const a = fx.a();
    try fx.write("cli-plan.txt", try planText(a, .{}));
    const prep_args = [_][]const u8{ "prepare", "--plan", fx.path("cli-plan.txt"), "--binary", fx.path("app.bin"), "--input", try std.fmt.allocPrint(a, "queue={s}", .{fx.path("queue.txt")}), "--input", try std.fmt.allocPrint(a, "profiles={s}", .{fx.path("profiles.txt")}), "--input", try std.fmt.allocPrint(a, "recipes={s}", .{fx.path("recipes.txt")}), "--out", fx.path("cli-packet.json") };
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expectEqual(@as(u8, 0), runWith(testing.allocator, testing.io, &prep_args, &aw.writer, .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"packet_sha256\"") != null);
    // A second prepare to the same path is refused with status 1 and an error name.
    aw.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), runWith(testing.allocator, testing.io, &prep_args, &aw.writer, .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "OutExists") != null);

    const chk_args = [_][]const u8{ "check", "--packet", fx.path("cli-packet.json"), "--binary", fx.path("app.bin"), "--input", prep_args[6], "--input", prep_args[8], "--input", prep_args[10] };
    aw.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), runWith(testing.allocator, testing.io, &chk_args, &aw.writer, fullFeatures()));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"status\": \"offline_ready\"") != null);
    // The default router has no compiled features.
    aw.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), run(testing.allocator, testing.io, &chk_args, &aw.writer));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "runtime_features_unwired") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"status\": \"blocked\"") != null);

    for ([_][]const []const u8{ &.{}, &.{"nope"}, &.{"check"}, &.{ "check", "--packet" }, &.{ "check", "--bogus", "x" }, &.{ "prepare", "--plan", "p" }, &.{ "check", "--packet", "p", "--input", "noequals" } }) |bad| {
        aw.clearRetainingCapacity();
        try testing.expectEqual(@as(u8, 2), run(testing.allocator, testing.io, bad, &aw.writer));
        try testing.expect(std.mem.indexOf(u8, aw.written(), "usage:") != null);
    }
}

test "hashing streams through a fixed buffer and check allocation does not follow file size" {
    var fx = try Fx.init();
    defer fx.deinit();
    const big_len: usize = 8 << 20;
    const block = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(block);
    var prng = std.Random.DefaultPrng.init(42);
    var h = Sha256.init(.{});
    {
        const fh = try Dir.cwd().createFile(testing.io, fx.path("big.bin"), .{ .exclusive = true });
        defer fh.close(testing.io);
        var left = big_len;
        while (left > 0) : (left -= block.len) {
            prng.random().bytes(block);
            h.update(block);
            try fh.writeStreamingAll(testing.io, block);
        }
    }
    var dg: [32]u8 = undefined;
    h.final(&dg);
    const want = std.fmt.bytesToHex(dg, .lower);
    const t0 = opdir.nowNs();
    const got = try hashFile(testing.io, fx.path("big.bin"), max_binary_bytes);
    const t1 = opdir.nowNs();
    try testing.expectEqualSlices(u8, &want, &got.sha256);
    try testing.expectEqual(@as(u64, big_len), got.bytes);
    try testing.expectError(error.TooLarge, hashFile(testing.io, fx.path("big.bin"), big_len - 1));
    try testing.expectEqual(@as(u64, big_len), (try hashFile(testing.io, fx.path("big.bin"), big_len)).bytes);

    // Check a packet bound to the small binary and one bound to the large binary.
    const small_packet = try fx.prep(.{});
    var plan_big: [1]u8 = undefined;
    _ = &plan_big;
    try fx.write("plan-big.txt", try planText(fx.a(), .{}));
    _ = try prepare(testing.allocator, testing.io, .{ .plan_path = fx.path("plan-big.txt"), .binary_path = fx.path("big.bin"), .inputs = fx.inputs(), .out_path = fx.path("packet-big.json") });
    var fa = testing.FailingAllocator.init(testing.allocator, .{});
    const t2 = opdir.nowNs();
    var r1 = try check(fa.allocator(), testing.io, .{ .packet_path = fx.path(small_packet), .binary_path = fx.path("app.bin"), .inputs = fx.inputs(), .features = fullFeatures() });
    const t3 = opdir.nowNs();
    r1.deinit();
    try testing.expect(r1.status == .offline_ready);
    var fb = testing.FailingAllocator.init(testing.allocator, .{});
    var r2 = try check(fb.allocator(), testing.io, .{ .packet_path = fx.path("packet-big.json"), .binary_path = fx.path("big.bin"), .inputs = fx.inputs(), .features = fullFeatures() });
    const t4 = opdir.nowNs();
    const ready2 = r2.status == .offline_ready;
    r2.deinit();
    try testing.expect(ready2);
    std.debug.print("evidence\tactivation_hash_bytes={d}\thash_ns={d}\tcheck_small_ns={d}\tcheck_small_alloc_bytes={d}\tcheck_big_ns={d}\tcheck_big_alloc_bytes={d}\n", .{ big_len, t1 - t0, t3 - t2, fa.allocated_bytes, t4 - t3, fb.allocated_bytes });
    try testing.expectEqual(fa.allocations, fb.allocations);
    try testing.expect(@max(fa.allocated_bytes, fb.allocated_bytes) - @min(fa.allocated_bytes, fb.allocated_bytes) <= 512);
    try testing.expect(fa.allocated_bytes < 512 * 1024);
}

test "allocation failure at every step of check leaves no leak" {
    var fx = try Fx.init();
    defer fx.deinit();
    const name = try fx.prep(.{});
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = n });
        if (check(fa.allocator(), testing.io, .{ .packet_path = fx.path(name), .binary_path = fx.path("app.bin"), .inputs = fx.inputs(), .features = fullFeatures() })) |*r| {
            var rep = r.*;
            defer rep.deinit();
            try expectReady(&rep);
            break;
        } else |e| try testing.expectEqual(error.OutOfMemory, e);
    } else return error.SweepDidNotFinish;
    std.debug.print("check sweep finished after {d} failing allocation points\n", .{n});
}

test "prepare and check leave catalogs and scratch inputs unchanged" {
    var fx = try Fx.init();
    defer fx.deinit();
    const before = try fx.read("queue.txt");
    const name = try fx.prep(.{});
    var r = try fx.chk(name, fullFeatures());
    defer r.deinit();
    try testing.expectEqualStrings(before, try fx.read("queue.txt"));
    // The report lists step and parasolid as pending contract work and certifies no identifier.
    const packet = try fx.read(name);
    try testing.expect(std.mem.indexOf(u8, packet, "\"catalog_identifier\": null") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "pending_contract") != null);
}
