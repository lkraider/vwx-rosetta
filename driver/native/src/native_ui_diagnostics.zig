//! Read-only diagnostic capture of one window of an authorized process.
//!
//! `capture` matches the process and window, takes one window-targeted PNG, reads a bounded
//! Accessibility control tree and writes a small record of the last action, the expected condition
//! and the observed state. It sends no click, key, menu or value change. Export routes and
//! calibration records are not inputs.
//!
//! Status of this revision:
//! - Every test drives fakes. `MacBackend` runs against a fake `native_ui_runtime.Transport`, so
//!   its command lines and output parsers run. Its AppleScript sources and `screencapture` have
//!   not run on macOS and the scripts have not been compiled.
//! - Installed-window capture needs live calibration.
//!
//! Output layout. `capture` creates `<out_dir>/diag-<pid>-<n>/` and writes `window.png`,
//! `controls.tsv` and `record.json` into it. Files are written as `<name>.partial` with an
//! exclusive create and renamed without replacing. The module deletes and overwrites nothing. A
//! directory that holds an export operation marker is refused as `out_dir`.
//!
//! Allocation and lifetime contract:
//! - `capture` allocates one arena from the caller allocator. `Report.deinit` frees it.
//! - Backend replies are borrowed from the backend until its next call. `capture` copies what it
//!   keeps.
//! - Request slices are borrowed from the caller for the duration of one call.

const std = @import("std");
const nur = @import("native_ui_runtime.zig");
const opdir = @import("rosetta_opdir.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

pub const schema_record = "vwx-ui-diagnostic/1";
pub const schema_controls = "# vwx-ui-controls/1";
pub const png_name = "window.png";
pub const controls_name = "controls.tsv";
pub const record_name = "record.json";

pub const Failure = nur.Failure;
pub const FailureKind = nur.FailureKind;

pub const Limits = struct {
    max_windows: usize = 32,
    max_title: usize = 256,
    max_text: usize = 512,
    max_tree_depth: u8 = 8,
    max_tree_nodes: usize = 400,
    max_field: usize = 200,
    max_png_bytes: u64 = 64 << 20,
    max_png_side: u32 = 16384,
    max_out_dir: usize = 512,
};

/// Fault injection for tests. Production leaves the default.
pub const Hooks = struct {
    /// Name of an artifact whose publication fails after half of its bytes reached the partial
    /// file. The final name is not published.
    fail_write: ?[]const u8 = null,
};

pub const Request = struct {
    pid: i32,
    window_id: ?u32 = null,
    window_title: ?[]const u8 = null,
    out_dir: []const u8,
    reason: []const u8,
    expected_condition: []const u8 = "",
    last_action: []const u8 = "",
    timeout_ms: u32 = 20_000,
    limits: Limits = .{},
    hooks: Hooks = .{},
};

// Backend interface

pub const WindowInfo = struct {
    /// AXWindowNumber. Null when the window exposes none.
    number: ?u32 = null,
    /// Null when the title is unreadable.
    title: ?[]const u8 = null,
    /// Null when the modal attribute is unreadable.
    modal: ?bool = null,
    /// Accessibility window subrole. Empty when the backend cannot read it.
    subrole: []const u8 = "",
};

pub const Target = struct {
    pid: i32,
    window_id: ?u32,
    window_title: ?[]const u8,
    timeout_ms: u32,
};

pub const TreeLimits = struct {
    max_depth: u8,
    max_nodes: usize,
    max_field: usize,
};

pub const Node = struct {
    depth: u8,
    role: []const u8 = "",
    subrole: []const u8 = "",
    name: []const u8 = "",
    value: []const u8 = "",
    enabled: ?bool = null,
};

pub const Tree = struct {
    nodes: []const Node,
    /// True when the backend stopped at a depth or node bound.
    truncated: bool = false,
};

pub const WindowsReply = union(enum) { windows: []const WindowInfo, failed: Failure };
pub const TreeReply = union(enum) { tree: Tree, failed: Failure };
pub const CaptureReply = union(enum) { done, failed: Failure };

/// Injectable platform backend. Every call is read-only and targets `Target.pid`.
pub const Backend = struct {
    ptr: *anyopaque,
    windowsFn: *const fn (ptr: *anyopaque, t: Target) WindowsReply,
    treeFn: *const fn (ptr: *anyopaque, t: Target, lim: TreeLimits) TreeReply,
    captureFn: *const fn (ptr: *anyopaque, t: Target, path: []const u8) CaptureReply,

    pub fn windows(b: Backend, t: Target) WindowsReply {
        return b.windowsFn(b.ptr, t);
    }
    pub fn tree(b: Backend, t: Target, lim: TreeLimits) TreeReply {
        return b.treeFn(b.ptr, t, lim);
    }
    pub fn capture(b: Backend, t: Target, path: []const u8) CaptureReply {
        return b.captureFn(b.ptr, t, path);
    }
};

// Report

pub const Outcome = enum { complete, partial, identity_failed, rejected, output_failed };

pub const Selection = enum { none, window_id, window_title, window_id_and_title, only_window, only_modal };

pub const ArtifactError = struct {
    kind: FailureKind,
    detail: []const u8,
};

pub const ScreenshotResult = union(enum) {
    written: struct { path: []const u8, bytes: u64, width: u32, height: u32 },
    /// The target cannot be captured.
    unavailable: ArtifactError,
    /// A capture ran and failed or produced an invalid image.
    failed: ArtifactError,
};

pub const ControlsResult = union(enum) {
    written: struct { path: []const u8, nodes: usize, truncated: bool, bytes: u64 },
    unavailable: ArtifactError,
    failed: ArtifactError,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    outcome: Outcome = .rejected,
    diag_dir: ?[]const u8 = null,
    record_path: ?[]const u8 = null,
    windows: []const WindowInfo = &.{},
    windows_known: bool = false,
    matched: ?WindowInfo = null,
    selection: Selection = .none,
    screenshot: ScreenshotResult = .{ .unavailable = .{ .kind = .refused, .detail = "capture did not run" } },
    controls: ControlsResult = .{ .unavailable = .{ .kind = .refused, .detail = "capture did not run" } },
    errors: []const []const u8 = &.{},

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

// Text cleanup

/// Copies `s` bounded to `max` bytes. Control bytes become spaces. A string that is not valid
/// UTF-8 keeps its ASCII bytes and turns every other byte into `?`.
fn clean(a: Allocator, s: []const u8, max: usize) Allocator.Error![]const u8 {
    var n = @min(s.len, max);
    // Do not cut inside a multi-byte sequence.
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    const out = try a.dupe(u8, s[0..n]);
    for (out) |*b| {
        if (b.* < 0x20 or b.* == 0x7f) b.* = ' ';
    }
    if (!std.unicode.utf8ValidateSlice(out)) {
        for (out) |*b| {
            if (b.* >= 0x80) b.* = '?';
        }
    }
    return out;
}

fn hasControlByte(s: []const u8) bool {
    for (s) |b| if (b < 0x20 or b == 0x7f) return true;
    return false;
}

// Output directory

const OutError = error{ NotDirectory, Symlink, ExportDirectory, PathRefused, Failed, InjectedWriteFailure };

/// Null when `p` is an acceptable absolute directory spelling.
fn outDirProblem(p: []const u8, lim: Limits) ?[]const u8 {
    if (p.len == 0) return "out_dir is empty";
    if (p.len > lim.max_out_dir) return "out_dir is longer than the limit";
    if (p[0] != '/') return "out_dir is not absolute";
    if (hasControlByte(p)) return "out_dir holds a control byte";
    var it = std.mem.splitScalar(u8, p[1..], '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..") or std.mem.eql(u8, c, ".")) return "out_dir holds a dot component";
    }
    return null;
}

const OutDir = struct {
    root: Dir,
    sub: Dir,
    /// Real path of the new directory.
    path: []const u8,

    fn close(o: *OutDir, io: Io) void {
        o.sub.close(io);
        o.root.close(io);
    }
};

/// Opens `out_dir` without following a final symlink, refuses an export operation directory and
/// creates the first free `diag-<pid>-<n>` below it with a plain mkdir.
fn openOut(a: Allocator, io: Io, out_dir: []const u8, pid: i32) OutError!OutDir {
    const trimmed = if (out_dir.len > 1) std.mem.trimEnd(u8, out_dir, "/") else out_dir;
    const st = Dir.cwd().statFile(io, trimmed, .{ .follow_symlinks = false }) catch return error.Failed;
    switch (st.kind) {
        .directory => {},
        .sym_link => return error.Symlink,
        else => return error.NotDirectory,
    }
    var root = Dir.cwd().openDir(io, trimmed, .{ .follow_symlinks = false }) catch return error.Failed;
    errdefer root.close(io);
    if (root.statFile(io, opdir.open_name, .{ .follow_symlinks = false })) |_| {
        return error.ExportDirectory;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return error.Failed,
    }
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        const name = std.fmt.allocPrint(a, "diag-{d}-{d}", .{ pid, n }) catch return error.Failed;
        root.createDir(io, name, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return error.Failed,
        };
        var sub = root.openDir(io, name, .{ .follow_symlinks = false }) catch return error.Failed;
        errdefer sub.close(io);
        const real = root.realPathFileAlloc(io, name, a) catch return error.Failed;
        return .{ .root = root, .sub = sub, .path = real };
    }
    return error.Failed;
}

/// Writes `<name>.partial` exclusively, syncs it and renames it to `name` without replacing.
fn publish(io: Io, dir: Dir, name: []const u8, bytes: []const u8, hooks: Hooks) OutError!void {
    if (opdir.pathProblem(name) != null) return error.PathRefused;
    var buf: [96]u8 = undefined;
    const partial = std.fmt.bufPrint(&buf, "{s}.partial", .{name}) catch return error.PathRefused;
    const f = dir.createFile(io, partial, .{ .exclusive = true }) catch return error.Failed;
    {
        defer f.close(io);
        const fail = if (hooks.fail_write) |w| std.mem.eql(u8, w, name) else false;
        const cut = if (fail) bytes.len / 2 else bytes.len;
        f.writeStreamingAll(io, bytes[0..cut]) catch return error.Failed;
        f.sync(io) catch return error.Failed;
        if (fail) return error.InjectedWriteFailure;
    }
    dir.renamePreserve(partial, dir, name, io) catch return error.Failed;
}

// PNG check

const PngInfo = struct { bytes: u64, width: u32, height: u32 };

const png_sig = [8]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
const png_iend = [12]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 };

/// Checks the signature, the IHDR chunk and the IEND trailer of a regular file. The open does not
/// follow a symlink.
fn checkPng(io: Io, dir: Dir, name: []const u8, lim: Limits) error{Invalid}!PngInfo {
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return error.Invalid;
    if (st.kind != .file) return error.Invalid;
    if (st.size < 33 + png_iend.len or st.size > lim.max_png_bytes) return error.Invalid;
    var f = dir.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false }) catch return error.Invalid;
    defer f.close(io);
    var head: [33]u8 = undefined;
    if ((f.readPositionalAll(io, &head, 0) catch return error.Invalid) != head.len) return error.Invalid;
    if (!std.mem.eql(u8, head[0..8], &png_sig)) return error.Invalid;
    if (std.mem.readInt(u32, head[8..12], .big) != 13 or !std.mem.eql(u8, head[12..16], "IHDR")) return error.Invalid;
    const w = std.mem.readInt(u32, head[16..20], .big);
    const h = std.mem.readInt(u32, head[20..24], .big);
    if (w == 0 or h == 0 or w > lim.max_png_side or h > lim.max_png_side) return error.Invalid;
    var tail: [png_iend.len]u8 = undefined;
    if ((f.readPositionalAll(io, &tail, st.size - tail.len) catch return error.Invalid) != tail.len) return error.Invalid;
    if (!std.mem.eql(u8, &tail, &png_iend)) return error.Invalid;
    return .{ .bytes = st.size, .width = w, .height = h };
}

// Window matching

const MatchResult = union(enum) {
    matched: struct { index: usize, selection: Selection },
    failed: ArtifactError,
};

fn titleIs(w: WindowInfo, t: []const u8) bool {
    return if (w.title) |x| std.mem.eql(u8, x, t) else false;
}

fn matchWindow(windows: []const WindowInfo, id: ?u32, title: ?[]const u8) MatchResult {
    var found: ?usize = null;
    var count: usize = 0;
    if (id) |want| {
        for (windows, 0..) |w, i| {
            if (w.number != null and w.number.? == want) {
                found = i;
                count += 1;
            }
        }
        if (count == 0) return .{ .failed = .{ .kind = .wrong_identity, .detail = "no window of the process has the requested window id" } };
        if (count > 1) return .{ .failed = .{ .kind = .ambiguous_target, .detail = "more than one window has the requested window id" } };
        if (title) |t| {
            if (!titleIs(windows[found.?], t)) return .{ .failed = .{ .kind = .wrong_identity, .detail = "the window with the requested id has a different title" } };
            return .{ .matched = .{ .index = found.?, .selection = .window_id_and_title } };
        }
        return .{ .matched = .{ .index = found.?, .selection = .window_id } };
    }
    if (title) |t| {
        for (windows, 0..) |w, i| {
            if (titleIs(w, t)) {
                found = i;
                count += 1;
            }
        }
        if (count == 0) return .{ .failed = .{ .kind = .wrong_identity, .detail = "no window of the process has the requested title" } };
        if (count > 1) return .{ .failed = .{ .kind = .ambiguous_target, .detail = "more than one window has the requested title" } };
        return .{ .matched = .{ .index = found.?, .selection = .window_title } };
    }
    if (windows.len == 0) return .{ .failed = .{ .kind = .wrong_identity, .detail = "the process has no window" } };
    if (windows.len == 1) return .{ .matched = .{ .index = 0, .selection = .only_window } };
    for (windows, 0..) |w, i| {
        if (w.modal == true) {
            found = i;
            count += 1;
        }
    }
    if (count == 1) return .{ .matched = .{ .index = found.?, .selection = .only_modal } };
    return .{ .failed = .{ .kind = .ambiguous_target, .detail = "several windows and no single modal window. pass a window id or title" } };
}

// Capture

const Clock = struct {
    env: nur.Env,
    start: u64,
    total_ms: u32,

    fn left(c: Clock) ?u32 {
        const used = (c.env.now() -| c.start) / std.time.ns_per_ms;
        if (used >= c.total_ms) return null;
        return @intCast(c.total_ms - used);
    }
};

const budget_used: ArtifactError = .{ .kind = .timeout, .detail = "capture budget used" };

fn artifactOf(a: Allocator, f: Failure) Allocator.Error!ArtifactError {
    return .{ .kind = f.kind, .detail = try clean(a, f.detail, 160) };
}

const Rec = struct {
    errors: std.ArrayList([]const u8) = .empty,

    fn add(r: *Rec, a: Allocator, comptime what: []const u8, e: ArtifactError) Allocator.Error!void {
        try r.errors.append(a, try std.fmt.allocPrint(a, what ++ ": {s}: {s}", .{ @tagName(e.kind), e.detail }));
    }
    fn addText(r: *Rec, a: Allocator, text: []const u8) Allocator.Error!void {
        try r.errors.append(a, try a.dupe(u8, text));
    }
};

/// Runs one read-only diagnostic capture. Only allocation failure returns an error. Request,
/// backend and write problems are reported in the `Report`.
pub fn capture(gpa: Allocator, io: Io, backend: Backend, env: nur.Env, req: Request) Allocator.Error!Report {
    var rep: Report = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer rep.arena.deinit();
    const a = rep.arena.allocator();
    var rec: Rec = .{};

    if (requestProblem(req)) |why| {
        try rec.addText(a, why);
        rep.errors = rec.errors.items;
        rep.outcome = .rejected;
        rep.screenshot = .{ .unavailable = .{ .kind = .refused, .detail = why } };
        rep.controls = .{ .unavailable = .{ .kind = .refused, .detail = why } };
        return rep;
    }
    var out = openOut(a, io, req.out_dir, req.pid) catch |e| {
        const why: []const u8 = switch (e) {
            error.NotDirectory => "out_dir is not a directory",
            error.Symlink => "out_dir is a symbolic link",
            error.ExportDirectory => "out_dir is an export operation directory",
            error.PathRefused => "output path refused",
            else => "the diagnostic directory could not be created",
        };
        try rec.addText(a, why);
        rep.errors = rec.errors.items;
        rep.outcome = if (e == error.Failed) .output_failed else .rejected;
        rep.screenshot = .{ .unavailable = .{ .kind = .refused, .detail = why } };
        rep.controls = .{ .unavailable = .{ .kind = .refused, .detail = why } };
        return rep;
    };
    defer out.close(io);
    rep.diag_dir = out.path;

    const clock: Clock = .{ .env = env, .start = env.now(), .total_ms = req.timeout_ms };
    var target: Target = .{ .pid = req.pid, .window_id = req.window_id, .window_title = req.window_title, .timeout_ms = req.timeout_ms };

    // Identity first. No capture runs before the process and window match.
    var identity_ok = false;
    var why_not: ArtifactError = .{ .kind = .wrong_identity, .detail = "identity not established" };
    if (clock.left()) |left| {
        target.timeout_ms = left;
        switch (backend.windows(target)) {
            .failed => |f| why_not = try artifactOf(a, f),
            .windows => |ws| {
                const n = @min(ws.len, req.limits.max_windows);
                const list = try a.alloc(WindowInfo, n);
                for (ws[0..n], list) |w, *d| d.* = .{
                    .number = w.number,
                    .title = if (w.title) |t| try clean(a, t, req.limits.max_title) else null,
                    .modal = w.modal,
                };
                rep.windows = list;
                rep.windows_known = true;
                if (ws.len > n) try rec.addText(a, "window list cut at the limit");
                switch (matchWindow(list, req.window_id, req.window_title)) {
                    .failed => |f| why_not = f,
                    .matched => |m| {
                        rep.matched = list[m.index];
                        rep.selection = m.selection;
                        identity_ok = true;
                    },
                }
            },
        }
    } else why_not = budget_used;

    if (!identity_ok) {
        try rec.add(a, "identity", why_not);
        rep.screenshot = .{ .unavailable = why_not };
        rep.controls = .{ .unavailable = why_not };
        rep.outcome = .identity_failed;
    } else {
        const m = rep.matched.?;
        target.window_id = m.number;
        target.window_title = m.title;
        try takeScreenshot(a, io, backend, clock, target, req, &out, &rep, &rec);
        try readControls(a, io, backend, clock, target, req, &out, &rep, &rec);
    }

    // The record is last. It reports the results of the artifacts above.
    const json = try recordJson(a, req, &rep, rec.errors.items);
    rep.errors = rec.errors.items;
    var record_ok = true;
    publish(io, out.sub, record_name, json, req.hooks) catch |e| {
        record_ok = false;
        try rec.addText(a, if (e == error.InjectedWriteFailure) "record write failed after a partial write" else "record write failed");
        rep.errors = rec.errors.items;
    };
    if (record_ok) rep.record_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ out.path, record_name });
    if (!record_ok) {
        rep.outcome = .output_failed;
    } else if (identity_ok) {
        const shot = rep.screenshot == .written;
        const ctl = rep.controls == .written;
        rep.outcome = if (shot and ctl) .complete else .partial;
    }
    return rep;
}

fn requestProblem(req: Request) ?[]const u8 {
    if (req.pid <= 1) return "pid must be greater than 1";
    if (req.window_id) |w| if (w == 0) return "window id must not be zero";
    if (req.window_title) |t| {
        if (t.len == 0 or t.len > req.limits.max_title) return "window title is empty or too long";
        if (hasControlByte(t)) return "window title holds a control byte";
    }
    if (outDirProblem(req.out_dir, req.limits)) |why| return why;
    if (req.reason.len == 0) return "reason is empty";
    if (req.reason.len > req.limits.max_text or req.expected_condition.len > req.limits.max_text or req.last_action.len > req.limits.max_text) return "reason, expected condition or last action is too long";
    if (req.timeout_ms == 0) return "timeout must not be zero";
    return null;
}

fn takeScreenshot(a: Allocator, io: Io, backend: Backend, clock: Clock, target_in: Target, req: Request, out: *OutDir, rep: *Report, rec: *Rec) Allocator.Error!void {
    var target = target_in;
    const m = rep.matched.?;
    if (m.number == null) {
        const e: ArtifactError = .{ .kind = .screenshot_unavailable, .detail = "the window exposes no window number" };
        rep.screenshot = .{ .unavailable = e };
        try rec.add(a, "screenshot", e);
        return;
    }
    const left = clock.left() orelse {
        rep.screenshot = .{ .failed = budget_used };
        try rec.add(a, "screenshot", budget_used);
        return;
    };
    target.timeout_ms = left;
    const partial_name = png_name ++ ".partial";
    const partial = try std.fmt.allocPrint(a, "{s}/{s}", .{ out.path, partial_name });
    switch (backend.capture(target, partial)) {
        .failed => |f| {
            const e = try artifactOf(a, f);
            rep.screenshot = if (f.kind == .screenshot_unavailable) .{ .unavailable = e } else .{ .failed = e };
            try rec.add(a, "screenshot", e);
            return;
        },
        .done => {},
    }
    const info = checkPng(io, out.sub, partial_name, req.limits) catch {
        const e: ArtifactError = .{ .kind = .screenshot_unavailable, .detail = "the capture is not a valid PNG file and stays as window.png.partial" };
        rep.screenshot = .{ .failed = e };
        try rec.add(a, "screenshot", e);
        return;
    };
    out.sub.renamePreserve(partial_name, out.sub, png_name, io) catch {
        const e: ArtifactError = .{ .kind = .transport_error, .detail = "the capture could not be published as window.png" };
        rep.screenshot = .{ .failed = e };
        try rec.add(a, "screenshot", e);
        return;
    };
    rep.screenshot = .{ .written = .{
        .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ out.path, png_name }),
        .bytes = info.bytes,
        .width = info.width,
        .height = info.height,
    } };
}

fn readControls(a: Allocator, io: Io, backend: Backend, clock: Clock, target_in: Target, req: Request, out: *OutDir, rep: *Report, rec: *Rec) Allocator.Error!void {
    var target = target_in;
    const left = clock.left() orelse {
        rep.controls = .{ .failed = budget_used };
        try rec.add(a, "controls", budget_used);
        return;
    };
    target.timeout_ms = left;
    const lim = req.limits;
    const tree = switch (backend.tree(target, .{ .max_depth = lim.max_tree_depth, .max_nodes = lim.max_tree_nodes, .max_field = lim.max_field })) {
        .failed => |f| {
            const e = try artifactOf(a, f);
            rep.controls = if (f.kind == .unknown_ui or f.kind == .wrong_identity) .{ .unavailable = e } else .{ .failed = e };
            try rec.add(a, "controls", e);
            return;
        },
        .tree => |t| t,
    };
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, schema_controls);
    try buf.append(a, '\n');
    const n = @min(tree.nodes.len, lim.max_tree_nodes);
    var cut = tree.truncated or tree.nodes.len > n;
    for (tree.nodes[0..n]) |node| {
        if (node.depth > lim.max_tree_depth) {
            cut = true;
            continue;
        }
        const enabled: []const u8 = if (node.enabled) |e| (if (e) "t" else "f") else "u";
        const line = try std.fmt.allocPrint(a, "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            node.depth,
            try clean(a, node.role, lim.max_field),
            try clean(a, node.subrole, lim.max_field),
            try clean(a, node.name, lim.max_field),
            try clean(a, node.value, lim.max_field),
            enabled,
        });
        try buf.appendSlice(a, line);
    }
    if (cut) try buf.appendSlice(a, "# truncated\n");
    publish(io, out.sub, controls_name, buf.items, req.hooks) catch |e| {
        const err: ArtifactError = .{ .kind = .transport_error, .detail = if (e == error.InjectedWriteFailure) "control snapshot write failed after a partial write" else "control snapshot write failed" };
        rep.controls = .{ .failed = err };
        try rec.add(a, "controls", err);
        return;
    };
    rep.controls = .{ .written = .{
        .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ out.path, controls_name }),
        .nodes = n,
        .truncated = cut,
        .bytes = buf.items.len,
    } };
}

// Record

const JsonShot = struct {
    result: []const u8,
    path: ?[]const u8 = null,
    bytes: ?u64 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    nodes: ?usize = null,
    truncated: ?bool = null,
    kind: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

const JsonWindow = struct { number: ?u32, title: ?[]const u8, modal: ?bool };

fn shotJson(r: ScreenshotResult) JsonShot {
    return switch (r) {
        .written => |w| .{ .result = "written", .path = png_name, .bytes = w.bytes, .width = w.width, .height = w.height },
        .unavailable => |e| .{ .result = "unavailable", .kind = @tagName(e.kind), .detail = e.detail },
        .failed => |e| .{ .result = "failed", .kind = @tagName(e.kind), .detail = e.detail },
    };
}

fn controlsJson(r: ControlsResult) JsonShot {
    return switch (r) {
        .written => |w| .{ .result = "written", .path = controls_name, .bytes = w.bytes, .nodes = w.nodes, .truncated = w.truncated },
        .unavailable => |e| .{ .result = "unavailable", .kind = @tagName(e.kind), .detail = e.detail },
        .failed => |e| .{ .result = "failed", .kind = @tagName(e.kind), .detail = e.detail },
    };
}

fn recordJson(a: Allocator, req: Request, rep: *const Report, errors: []const []const u8) Allocator.Error![]const u8 {
    const lim = req.limits;
    const wins = try a.alloc(JsonWindow, rep.windows.len);
    var modal_count: usize = 0;
    for (rep.windows, wins) |w, *d| {
        d.* = .{ .number = w.number, .title = w.title, .modal = w.modal };
        if (w.modal == true) modal_count += 1;
    }
    const matched: ?JsonWindow = if (rep.matched) |m| .{ .number = m.number, .title = m.title, .modal = m.modal } else null;
    const doc = .{
        .schema = schema_record,
        .reason = try clean(a, req.reason, lim.max_text),
        .expected_condition = try clean(a, req.expected_condition, lim.max_text),
        .last_action = try clean(a, req.last_action, lim.max_text),
        .request = .{
            .pid = req.pid,
            .window_id = req.window_id,
            .window_title = if (req.window_title) |t| try clean(a, t, lim.max_title) else null,
        },
        .identity = if (rep.matched != null) "matched" else "not_established",
        .selection = @tagName(rep.selection),
        .actual_state = .{
            .windows_listed = rep.windows_known,
            .window_count = rep.windows.len,
            .modal_count = modal_count,
            .windows = wins,
            .matched = matched,
        },
        .screenshot = shotJson(rep.screenshot),
        .controls = controlsJson(rep.controls),
        .errors = errors,
    };
    var aw: Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.written();
}

// macOS backend

const script_windows =
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  set outText to ""
    \\  tell application "System Events"
    \\    with timeout of 5 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set outText to "ok" & linefeed
    \\        repeat with probeWindow in (get every window)
    \\          set probeNumber to "-"
    \\          try
    \\            set probeNumber to (value of attribute "AXWindowNumber" of probeWindow) as text
    \\          end try
    \\          set probeTitle to "n"
    \\          try
    \\            set probeName to name of probeWindow as text
    \\            if probeName does not contain tab and probeName does not contain linefeed and probeName does not contain return then set probeTitle to "s:" & probeName
    \\          end try
    \\          set probeModal to "u"
    \\          try
    \\            set probeModalValue to value of attribute "AXModal" of probeWindow
    \\            if probeModalValue is true then
    \\              set probeModal to "t"
    \\            else if probeModalValue is false then
    \\              set probeModal to "f"
    \\            end if
    \\          end try
    \\          set outText to outText & "W" & tab & probeNumber & tab & probeTitle & tab & probeModal & linefeed
    \\        end repeat
    \\        return outText
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

// Arguments: pid, window number or "-", window title or "-", max depth, max nodes, max field.
const script_tree =
    \\property nodeCount : 0
    \\property nodeLimit : 0
    \\property depthLimit : 0
    \\property fieldLimit : 0
    \\property outText : ""
    \\property wasCut : false
    \\
    \\on flat(v)
    \\  if v is missing value then return ""
    \\  set s to v as text
    \\  set AppleScript's text item delimiters to {tab, linefeed, return}
    \\  set parts to text items of s
    \\  set AppleScript's text item delimiters to " "
    \\  set s to parts as text
    \\  set AppleScript's text item delimiters to ""
    \\  if (count of s) > fieldLimit then set s to text 1 thru fieldLimit of s
    \\  return s
    \\end flat
    \\
    \\on attr(el, attrName)
    \\  tell application "System Events"
    \\    try
    \\      return value of attribute attrName of el
    \\    end try
    \\  end tell
    \\  return missing value
    \\end attr
    \\
    \\on walk(el, depth)
    \\  global nodeCount, nodeLimit, depthLimit, outText, wasCut
    \\  if nodeCount >= nodeLimit then
    \\    set wasCut to true
    \\    return
    \\  end if
    \\  set nodeCount to nodeCount + 1
    \\  set probeEnabled to "u"
    \\  set enabledValue to my attr(el, "AXEnabled")
    \\  if enabledValue is true then set probeEnabled to "t"
    \\  if enabledValue is false then set probeEnabled to "f"
    \\  set probeName to my attr(el, "AXTitle")
    \\  if probeName is missing value or probeName is "" then set probeName to my attr(el, "AXDescription")
    \\  set outText to outText & "N" & tab & depth & tab & my flat(my attr(el, "AXRole")) & tab & my flat(my attr(el, "AXSubrole")) & tab & my flat(probeName) & tab & my flat(my attr(el, "AXValue")) & tab & probeEnabled & linefeed
    \\  set kids to {}
    \\  tell application "System Events"
    \\    try
    \\      set kids to UI elements of el
    \\    end try
    \\  end tell
    \\  if depth < depthLimit then
    \\    repeat with kid in kids
    \\      my walk(contents of kid, depth + 1)
    \\    end repeat
    \\  else if (count of kids) > 0 then
    \\    set wasCut to true
    \\  end if
    \\end walk
    \\
    \\on run argv
    \\  global nodeCount, nodeLimit, depthLimit, fieldLimit, outText, wasCut
    \\  set probePid to (item 1 of argv) as integer
    \\  set wantNumber to item 2 of argv
    \\  set wantTitle to item 3 of argv
    \\  set depthLimit to (item 4 of argv) as integer
    \\  set nodeLimit to (item 5 of argv) as integer
    \\  set fieldLimit to (item 6 of argv) as integer
    \\  set windowMatches to {}
    \\  tell application "System Events"
    \\    with timeout of 8 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        considering case
    \\          repeat with probeWindow in (get every window)
    \\            set isMatch to false
    \\            try
    \\              if wantNumber is not "-" then
    \\                set isMatch to ((value of attribute "AXWindowNumber" of probeWindow) as text) is wantNumber
    \\              else
    \\                set isMatch to (name of probeWindow as text) is wantTitle
    \\              end if
    \\            end try
    \\            if isMatch then set end of windowMatches to (contents of probeWindow)
    \\          end repeat
    \\        end considering
    \\      end tell
    \\    end timeout
    \\  end tell
    \\  if (count of windowMatches) is 0 then return "refused" & tab & "window_absent"
    \\  if (count of windowMatches) > 1 then return "refused" & tab & "window_ambiguous"
    \\  my walk(item 1 of windowMatches, 0)
    \\  if wasCut then return "ok" & linefeed & "C" & linefeed & outText
    \\  return "ok" & linefeed & outText
    \\end run
;

/// `osascript` and `screencapture` backend over an injectable transport. Every program is
/// read-only. Replies are borrowed from an arena that each public call resets.
pub const MacBackend = struct {
    transport: nur.Transport,
    env: nur.Env,
    cfg: nur.MacConfig,
    arena: std.heap.ArenaAllocator,

    pub fn init(a: Allocator, transport: nur.Transport, env: nur.Env, cfg: nur.MacConfig) MacBackend {
        return .{ .transport = transport, .env = env, .cfg = cfg, .arena = std.heap.ArenaAllocator.init(a) };
    }

    pub fn deinit(m: *MacBackend) void {
        m.arena.deinit();
    }

    pub fn backend(m: *MacBackend) Backend {
        return .{ .ptr = m, .windowsFn = windowsImpl, .treeFn = treeImpl, .captureFn = captureImpl };
    }

    fn self(ptr: *anyopaque) *MacBackend {
        return @ptrCast(@alignCast(ptr));
    }

    const Exec = union(enum) { out: nur.RunOutput, failed: Failure };

    fn exec(m: *MacBackend, timeout_ms: u32, argv: []const []const u8, lim: nur.StreamLimits) Exec {
        const o = m.transport.run(m.arena.allocator(), argv, timeout_ms, lim);
        return switch (o.status) {
            .exited => .{ .out = o },
            .timed_out => .{ .failed = .{ .kind = .timeout, .detail = "child process timed out and was killed" } },
            .spawn_failed => .{ .failed = .{ .kind = .transport_error, .detail = "child process did not start" } },
            .output_limit => .{ .failed = .{ .kind = .transport_error, .detail = "child output passed its limit" } },
            .signaled, .read_failed => .{ .failed = .{ .kind = .transport_error, .detail = "child process ended abnormally" } },
        };
    }

    const Osa = union(enum) { body: []const u8, failed: Failure };

    fn osa(m: *MacBackend, timeout_ms: u32, src: []const u8, args: []const []const u8) Osa {
        const a = m.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(a, &.{ m.cfg.osascript, "-e", src }) catch return .{ .failed = oomFailure() };
        argv.appendSlice(a, args) catch return .{ .failed = oomFailure() };
        const o = switch (m.exec(timeout_ms, argv.items, .{ .stdout = m.cfg.limits.max_stdout, .stderr = m.cfg.limits.max_stderr })) {
            .failed => |f| return .{ .failed = f },
            .out => |o| o,
        };
        const body = std.mem.trim(u8, o.stdout, " \r\n");
        if (o.exit_code != 0) {
            const err = std.mem.trim(u8, o.stderr, " \r\n");
            return .{ .failed = .{ .kind = .unknown_ui, .detail = err[0..@min(err.len, 120)] } };
        }
        const tok_end = std.mem.indexOfAny(u8, body, "\t\n") orelse body.len;
        const tok = body[0..tok_end];
        if (std.mem.eql(u8, tok, "ok")) return .{ .body = body };
        if (std.mem.eql(u8, tok, "gone")) return .{ .failed = .{ .kind = .process_lost, .detail = "process is not running" } };
        if (std.mem.eql(u8, tok, "refused")) {
            const reason = if (std.mem.indexOfScalar(u8, body, '\t')) |i| body[i + 1 ..] else "";
            if (std.mem.eql(u8, reason, "window_ambiguous")) return .{ .failed = .{ .kind = .ambiguous_target, .detail = "more than one window matches" } };
            if (std.mem.eql(u8, reason, "window_absent")) return .{ .failed = .{ .kind = .wrong_identity, .detail = "target window is absent" } };
            return .{ .failed = .{ .kind = .unknown_ui, .detail = "script refused for an unknown reason" } };
        }
        return .{ .failed = .{ .kind = .transport_error, .detail = "script output is unparsable" } };
    }

    fn oomFailure() Failure {
        return .{ .kind = .out_of_memory, .detail = "allocation failed" };
    }

    fn reset(m: *MacBackend) void {
        _ = m.arena.reset(.retain_capacity);
    }

    fn windowsImpl(ptr: *anyopaque, t: Target) WindowsReply {
        const m = self(ptr);
        m.reset();
        const a = m.arena.allocator();
        const pid = std.fmt.allocPrint(a, "{d}", .{t.pid}) catch return .{ .failed = oomFailure() };
        const body = switch (m.osa(t.timeout_ms, script_windows, &.{pid})) {
            .failed => |f| return .{ .failed = f },
            .body => |b| b,
        };
        return parseWindows(a, body, m.cfg.limits.max_windows);
    }

    fn treeImpl(ptr: *anyopaque, t: Target, lim: TreeLimits) TreeReply {
        const m = self(ptr);
        m.reset();
        const a = m.arena.allocator();
        const pid = std.fmt.allocPrint(a, "{d}", .{t.pid}) catch return .{ .failed = oomFailure() };
        const number: []const u8 = if (t.window_id) |id| (std.fmt.allocPrint(a, "{d}", .{id}) catch return .{ .failed = oomFailure() }) else "-";
        const title: []const u8 = if (t.window_id == null) (t.window_title orelse "") else "-";
        if (t.window_id == null and title.len == 0) return .{ .failed = .{ .kind = .refused, .detail = "no window id or title to target" } };
        const depth = std.fmt.allocPrint(a, "{d}", .{lim.max_depth}) catch return .{ .failed = oomFailure() };
        const nodes = std.fmt.allocPrint(a, "{d}", .{lim.max_nodes}) catch return .{ .failed = oomFailure() };
        const field = std.fmt.allocPrint(a, "{d}", .{lim.max_field}) catch return .{ .failed = oomFailure() };
        const body = switch (m.osa(t.timeout_ms, script_tree, &.{ pid, number, title, depth, nodes, field })) {
            .failed => |f| return .{ .failed = f },
            .body => |b| b,
        };
        return parseTree(a, body, lim);
    }

    /// Captures the window by number. A call without a window number fails. No call captures a
    /// screen rectangle.
    fn captureImpl(ptr: *anyopaque, t: Target, path: []const u8) CaptureReply {
        const m = self(ptr);
        m.reset();
        if (path.len < 6 or path[0] != '/' or hasControlByte(path) or !std.ascii.endsWithIgnoreCase(path, ".png.partial") and !std.ascii.endsWithIgnoreCase(path, ".png")) {
            return .{ .failed = .{ .kind = .refused, .detail = "screenshot path must be an absolute .png path" } };
        }
        const id = t.window_id orelse return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "no window number to target" } };
        if (id == 0) return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "window number is zero" } };
        const id_text = std.fmt.allocPrint(m.arena.allocator(), "{d}", .{id}) catch return .{ .failed = oomFailure() };
        switch (m.exec(t.timeout_ms, &.{ m.cfg.screencapture, "-x", "-o", "-l", id_text, path }, .{ .stdout = 4096, .stderr = 4096 })) {
            .failed => |f| return .{ .failed = f },
            .out => |o| {
                if (o.exit_code != 0) return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "screencapture failed" } };
            },
        }
        return .done;
    }
};

fn parseWindows(a: Allocator, body: []const u8, max: usize) WindowsReply {
    var list: std.ArrayList(WindowInfo) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse "", "\r"), "ok")) return .{ .failed = .{ .kind = .transport_error, .detail = "window list does not start with ok" } };
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        if (!std.mem.eql(u8, f.next() orelse "", "W")) return .{ .failed = .{ .kind = .transport_error, .detail = "window list has an unknown line" } };
        const num_s = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "window line has too few fields" } };
        const title_s = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "window line has too few fields" } };
        const modal_s = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "window line has too few fields" } };
        if (f.next() != null) return .{ .failed = .{ .kind = .transport_error, .detail = "window line has too many fields" } };
        if (list.items.len >= max) return .{ .failed = .{ .kind = .transport_error, .detail = "window list passed its limit" } };
        const number: ?u32 = if (std.fmt.parseInt(u32, num_s, 10)) |n| (if (n == 0) null else n) else |_| null;
        const title: ?[]const u8 = if (std.mem.startsWith(u8, title_s, "s:")) title_s[2..] else null;
        const modal: ?bool = if (std.mem.eql(u8, modal_s, "t")) true else if (std.mem.eql(u8, modal_s, "f")) false else null;
        list.append(a, .{ .number = number, .title = title, .modal = modal }) catch return .{ .failed = MacBackend.oomFailure() };
    }
    return .{ .windows = list.items };
}

fn parseTree(a: Allocator, body: []const u8, lim: TreeLimits) TreeReply {
    var nodes: std.ArrayList(Node) = .empty;
    var cut = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse "", "\r"), "ok")) return .{ .failed = .{ .kind = .transport_error, .detail = "control tree does not start with ok" } };
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "C")) {
            cut = true;
            continue;
        }
        var f = std.mem.splitScalar(u8, line, '\t');
        if (!std.mem.eql(u8, f.next() orelse "", "N")) return .{ .failed = .{ .kind = .transport_error, .detail = "control tree has an unknown line" } };
        const depth_s = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "control line has too few fields" } };
        const role = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "control line has too few fields" } };
        const subrole = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "control line has too few fields" } };
        const name = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "control line has too few fields" } };
        const value = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "control line has too few fields" } };
        const en = f.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "control line has too few fields" } };
        if (f.next() != null) return .{ .failed = .{ .kind = .transport_error, .detail = "control line has too many fields" } };
        const depth = std.fmt.parseInt(u8, depth_s, 10) catch return .{ .failed = .{ .kind = .transport_error, .detail = "control depth is not a number" } };
        if (nodes.items.len >= lim.max_nodes or depth > lim.max_depth) {
            cut = true;
            continue;
        }
        const enabled: ?bool = if (std.mem.eql(u8, en, "t")) true else if (std.mem.eql(u8, en, "f")) false else null;
        nodes.append(a, .{ .depth = depth, .role = role, .subrole = subrole, .name = name, .value = value, .enabled = enabled }) catch return .{ .failed = MacBackend.oomFailure() };
    }
    return .{ .tree = .{ .nodes = nodes.items, .truncated = cut } };
}

/// One window entry of the system window list.
pub const CgEntry = struct {
    pid: i64,
    name: ?[]const u8,
    number: u32,
};

/// The window number of the single entry owned by `pid` whose name equals `title` exactly. Null for
/// no entry, for several entries and for an empty title.
pub fn cgUnique(entries: []const CgEntry, pid: i32, title: []const u8) ?u32 {
    if (title.len == 0) return null;
    var found: ?u32 = null;
    for (entries) |e| {
        const name = e.name orelse continue;
        if (e.pid != pid or !std.mem.eql(u8, name, title)) continue;
        if (found != null or e.number == 0) return null;
        found = e.number;
    }
    return found;
}

/// Native Accessibility window list and control tree for `ui-diagnose`. The window list merges
/// focused, main and AXWindows entries. A window without AXWindowNumber takes the number of the
/// single system window with its exact PID and title. The control tree reuses the bounded walk
/// of `ui-dialog`. Capture stays with `MacBackend`.
/// Outcome of one Accessibility attribute read. `absent` is a legitimate "no value" and `failed`
/// is a transport or other error.
pub const Slot = enum { present, absent, failed, malformed };

/// kAXErrorAttributeUnsupported and kAXErrorNoValue. Every other nonzero code is a failed read.
pub fn axAbsent(code: i32) bool {
    return code == -25205 or code == -25212;
}

pub fn slotOf(code: i32, has_value: bool) Slot {
    if (code == 0) return if (has_value) .present else .absent;
    return if (axAbsent(code)) .absent else .failed;
}

/// What the focused, main and window-list reads of one observation returned.
pub const ListEvidence = struct {
    focused: Slot = .absent,
    main: Slot = .absent,
    windows: Slot = .absent,
    /// An AXWindows array held a null or foreign element.
    bad_element: bool = false,

    pub fn complete(e: ListEvidence) bool {
        for ([_]Slot{ e.focused, e.main, e.windows }) |s| if (s == .failed or s == .malformed) return false;
        return !e.bad_element;
    }
};

/// Completeness of the plain window facts. A window needs a known modal flag, and a non-modal
/// window needs a title read that succeeded. An empty title that was read stays valid.
pub fn windowsComplete(list: ListEvidence, infos: []const WindowInfo) bool {
    if (!list.complete()) return false;
    for (infos) |w| {
        if (w.modal == null) return false;
        if (w.modal == false and w.title == null) return false;
    }
    return true;
}

/// Native window evidence for production callers. Injected callers keep MacBackend.
pub const NativeWindowBackend = if (@import("builtin").os.tag == .macos) native_diag.NativeBackend else MacBackend;

/// Reads runtime window facts with the same native source as the diagnostic command.
pub fn readRuntimeWindows(a: Allocator, env: nur.Env, ctx: nur.Ctx, limits: nur.Limits) nur.ObserveReply {
    if (@import("builtin").os.tag == .macos) return native_diag.readRuntime(a, env, ctx, limits);
    return .{ .failed = .{ .kind = .unknown_ui, .detail = "native window observation requires macOS" } };
}

const native_diag = if (@import("builtin").os.tag == .macos) struct {
    fn readRuntime(a: Allocator, env: nur.Env, ctx: nur.Ctx, limits: nur.Limits) nur.ObserveReply {
        const deadline = env.now() + @as(u64, ctx.timeout_ms) * std.time.ns_per_ms;
        const app = switch (openApp(ctx.pid)) {
            .app => |el| el,
            .failed => |f| return .{ .failed = f },
        };
        defer native.CFRelease(app);
        _ = native.AXUIElementSetMessagingTimeout(app, 0.1);
        var list: std.ArrayList(Cand) = .empty;
        defer release(list.items);
        const evidence = collect(a, app, ctx.pid, limits.max_windows + 1, &list) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
        if (list.items.len > limits.max_windows) return .{ .failed = failed(.unknown_ui, "native window count exceeds its bound") };
        if (env.now() >= deadline) return .{ .failed = failed(.timeout, "native window observation exceeded its budget") };
        const ui = @import("native_ui.zig");
        const windows = a.alloc(ui.WindowObservation, list.items.len) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
        for (list.items, windows) |c, *window| window.* = .{ .title = c.info.title, .modal = c.info.modal };
        const infos = a.alloc(WindowInfo, list.items.len) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
        for (list.items, infos) |c, *d| d.* = c.info;
        var complete = windowsComplete(evidence, infos);
        for (list.items, windows) |c, *window| {
            if (c.info.modal == true) {
                var walk: nd.Walk = .{ .a = a, .env = env, .lim = .{ .max_nodes = 400, .max_depth = 8, .max_field = limits.max_text_len, .deadline_ns = deadline } };
                walk.visit(c.el, 0);
                if (walk.truncated or walk.timed_out) {
                    complete = false;
                    continue;
                }
                var texts: std.ArrayList([]const u8) = .empty;
                for (walk.nodes.items) |node| {
                    if (!std.mem.eql(u8, node.role, "AXStaticText")) continue;
                    if (!std.mem.eql(u8, node.value_type, "string")) {
                        complete = false;
                        continue;
                    }
                    if (texts.items.len >= limits.max_texts) {
                        complete = false;
                        break;
                    }
                    texts.append(a, node.value) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
                }
                window.texts = if (complete) texts.items else null;
                const button = nd.copyAttr(c.el, "AXDefaultButton");
                if (button != null) {
                    defer native.CFRelease(button);
                    const label = nd.readScalar(a, button, "AXTitle", limits.max_label);
                    if (std.mem.eql(u8, label.kind, "string")) window.default_button = label.text;
                }
            }
            if (env.now() >= deadline) return .{ .failed = failed(.timeout, "native window observation exceeded its budget") };
        }
        return .{ .observed = .{ .console = .{}, .windows = windows, .windows_complete = complete } };
    }

    const Ref = native.Ref;
    const nd = native_dialog;
    extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) Ref;
    extern "c" fn CFDictionaryGetValue(d: Ref, key: Ref) Ref;
    extern "c" fn CFEqual(a: Ref, b: Ref) u8;

    pub const NativeBackend = struct {
        mac: *MacBackend,
        env: nur.Env,
        arena: std.heap.ArenaAllocator,

        pub fn init(a: Allocator, mac: *MacBackend, env: nur.Env) NativeBackend {
            return .{ .mac = mac, .env = env, .arena = std.heap.ArenaAllocator.init(a) };
        }

        pub fn deinit(n: *NativeBackend) void {
            n.arena.deinit();
        }

        pub fn backend(n: *NativeBackend) Backend {
            return .{ .ptr = n, .windowsFn = windowsImpl, .treeFn = treeImpl, .captureFn = captureImpl };
        }
    };

    const Cand = struct { el: Ref, info: WindowInfo };

    fn self(ptr: *anyopaque) *NativeBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn failed(kind: FailureKind, detail: []const u8) Failure {
        return .{ .kind = kind, .detail = detail };
    }

    fn cgNumber(a: Allocator, pid: i32, title: []const u8) ?u32 {
        const list = CGWindowListCopyWindowInfo(0, 0);
        if (list == null) return null;
        defer native.CFRelease(list);
        if (native.CFGetTypeID(list) != native.CFArrayGetTypeID()) return null;
        const k_pid = native.attr("kCGWindowOwnerPID");
        defer native.CFRelease(k_pid);
        const k_name = native.attr("kCGWindowName");
        defer native.CFRelease(k_name);
        const k_num = native.attr("kCGWindowNumber");
        defer native.CFRelease(k_num);
        var entries: std.ArrayList(CgEntry) = .empty;
        const count = native.CFArrayGetCount(list);
        var i: isize = 0;
        while (i < count) : (i += 1) {
            const d = nd.CFArrayGetValueAtIndex(list, i);
            if (d == null) continue;
            const p = numberOf(CFDictionaryGetValue(d, k_pid)) orelse continue;
            const num = numberOf(CFDictionaryGetValue(d, k_num)) orelse continue;
            const nm = CFDictionaryGetValue(d, k_name);
            const name: ?[]const u8 = if (nm != null and native.CFGetTypeID(nm) == nd.CFStringGetTypeID()) nd.readStringOf(a, nm, 1024) else null;
            entries.append(a, .{ .pid = p, .name = name, .number = std.math.cast(u32, num) orelse continue }) catch return null;
        }
        return cgUnique(entries.items, pid, title);
    }

    fn numberOf(v: Ref) ?i64 {
        if (v == null or native.CFGetTypeID(v) != nd.CFNumberGetTypeID()) return null;
        var n: i64 = 0;
        if (nd.CFNumberGetValue(v, 4, &n) == 0) return null;
        return n;
    }

    fn describe(a: Allocator, el: Ref, pid: i32, max_title: usize) WindowInfo {
        const num = nd.readScalar(a, el, "AXWindowNumber", 32);
        var number: ?u32 = null;
        if (std.mem.eql(u8, num.kind, "number")) {
            if (std.fmt.parseInt(u32, num.text, 10)) |v| number = if (v == 0) null else v else |_| {}
        }
        const t = nd.readScalar(a, el, "AXTitle", max_title);
        const title: ?[]const u8 = if (std.mem.eql(u8, t.kind, "string")) t.text else null;
        if (number == null) {
            if (title) |tt| number = cgNumber(a, pid, tt);
        }
        const subrole = nd.readString(a, el, "AXSubrole", 64);
        // A failed AXModal read is unknown. Only an absent attribute falls back to the subrole.
        const modal: ?bool = switch (nd.readFlagStatus(el, "AXModal")) {
            .value => |v| v,
            .failed => null,
            .absent => if (std.mem.eql(u8, subrole, "AXStandardWindow")) false else if (std.mem.eql(u8, subrole, "AXDialog") or std.mem.eql(u8, subrole, "AXSystemDialog")) true else null,
        };
        return .{ .number = number, .title = title, .modal = modal, .subrole = subrole };
    }

    /// Takes one retained element. Duplicate and excess elements are released.
    fn addWindow(a: Allocator, el: Ref, pid: i32, max: usize, list: *std.ArrayList(Cand)) !void {
        var adopted = false;
        defer if (!adopted) native.CFRelease(el);
        if (list.items.len >= max) return;
        for (list.items) |c| if (CFEqual(c.el, el) != 0) return;
        try list.append(a, .{ .el = el, .info = describe(a, el, pid, 256) });
        adopted = true;
    }

    /// AXWindows may contain only unnamed placeholders. Include focused and main independently.
    /// The result says which reads failed, so that a caller can refuse to treat the list as whole.
    fn collect(a: Allocator, app: Ref, pid: i32, max: usize, list: *std.ArrayList(Cand)) !ListEvidence {
        var ev: ListEvidence = .{};
        for ([_][:0]const u8{ "AXFocusedWindow", "AXMainWindow" }) |key| {
            var slot: Slot = undefined;
            switch (nd.copyAttrStatus(app, key)) {
                .absent => slot = .absent,
                .failed => slot = .failed,
                .value => |el| {
                    if (native.CFGetTypeID(el) != native.AXUIElementGetTypeID()) {
                        native.CFRelease(el);
                        slot = .malformed;
                    } else {
                        slot = .present;
                        try addWindow(a, el, pid, max, list);
                    }
                },
            }
            if (key[2] == 'F') ev.focused = slot else ev.main = slot;
        }
        switch (nd.copyAttrStatus(app, "AXWindows")) {
            .absent => ev.windows = .absent,
            .failed => ev.windows = .failed,
            .value => |ws| {
                defer native.CFRelease(ws);
                if (native.CFGetTypeID(ws) != native.CFArrayGetTypeID()) {
                    ev.windows = .malformed;
                    return ev;
                }
                ev.windows = .present;
                const n = native.CFArrayGetCount(ws);
                var i: isize = 0;
                while (i < n and list.items.len < max) : (i += 1) {
                    const el = nd.CFArrayGetValueAtIndex(ws, i);
                    if (el == null or native.CFGetTypeID(el) != native.AXUIElementGetTypeID()) {
                        ev.bad_element = true;
                        continue;
                    }
                    try addWindow(a, nd.CFRetain(el), pid, max, list);
                }
            },
        }
        return ev;
    }

    fn release(list: []const Cand) void {
        for (list) |c| native.CFRelease(c.el);
    }

    const Open = union(enum) { app: Ref, failed: Failure };

    fn openApp(pid: i32) Open {
        if (native.AXIsProcessTrusted() == 0) return .{ .failed = failed(.unknown_ui, "Accessibility is not trusted for this process") };
        const app = native.AXUIElementCreateApplication(pid);
        if (app == null) return .{ .failed = failed(.process_lost, "no Accessibility application element") };
        _ = native.AXUIElementSetMessagingTimeout(app, 2.0);
        return .{ .app = app };
    }

    fn windowsImpl(ptr: *anyopaque, t: Target) WindowsReply {
        const n = self(ptr);
        _ = n.arena.reset(.retain_capacity);
        const a = n.arena.allocator();
        const app = switch (openApp(t.pid)) {
            .failed => |f| return .{ .failed = f },
            .app => |r| r,
        };
        defer native.CFRelease(app);
        var list: std.ArrayList(Cand) = .empty;
        defer release(list.items);
        _ = collect(a, app, t.pid, 64, &list) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
        const out = a.alloc(WindowInfo, list.items.len) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
        for (list.items, out) |c, *d| d.* = c.info;
        return .{ .windows = out };
    }

    fn treeImpl(ptr: *anyopaque, t: Target, lim: TreeLimits) TreeReply {
        const n = self(ptr);
        _ = n.arena.reset(.retain_capacity);
        const a = n.arena.allocator();
        const want_title: []const u8 = t.window_title orelse "";
        if (t.window_id == null and want_title.len == 0) return .{ .failed = failed(.refused, "no window id or title to target") };
        const app = switch (openApp(t.pid)) {
            .failed => |f| return .{ .failed = f },
            .app => |r| r,
        };
        defer native.CFRelease(app);
        var list: std.ArrayList(Cand) = .empty;
        defer release(list.items);
        _ = collect(a, app, t.pid, 64, &list) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
        var hit: ?Ref = null;
        var count: usize = 0;
        for (list.items) |c| {
            const ok = if (t.window_id) |id| c.info.number == id else if (c.info.title) |ct| std.mem.eql(u8, ct, want_title) else false;
            if (!ok) continue;
            hit = c.el;
            count += 1;
        }
        if (count == 0) return .{ .failed = failed(.wrong_identity, "target window is absent") };
        if (count > 1) return .{ .failed = failed(.ambiguous_target, "more than one window matches") };
        const dl: DialogLimits = .{
            .max_nodes = lim.max_nodes,
            .max_depth = lim.max_depth,
            .max_field = lim.max_field,
            .deadline_ns = n.env.now() + @as(u64, t.timeout_ms) * std.time.ns_per_ms,
        };
        var w: nd.Walk = .{ .a = a, .env = n.env, .lim = dl };
        w.visit(hit.?, 0);
        const nodes = a.alloc(Node, w.nodes.items.len) catch return .{ .failed = failed(.out_of_memory, "allocation failed") };
        for (w.nodes.items, nodes) |s, *d| d.* = .{
            .depth = s.depth,
            .role = s.role,
            .subrole = s.subrole,
            .name = if (s.title.len > 0) s.title else s.description,
            .value = s.value,
            .enabled = s.enabled,
        };
        return .{ .tree = .{ .nodes = nodes, .truncated = w.truncated } };
    }

    fn captureImpl(ptr: *anyopaque, t: Target, path: []const u8) CaptureReply {
        const n = self(ptr);
        return MacBackend.captureImpl(n.mac, t, path);
    }
} else struct {};

// Command line

pub const usage_text =
    \\usage: vwx ui-diagnose --pid N --out DIR --reason TEXT
    \\                       [--window-id N] [--window-title TITLE]
    \\                       [--expected TEXT] [--last-action TEXT] [--timeout-ms N]
    \\       vwx ui-diagnose --help
    \\
    \\Read-only capture of one window of an authorized process. The command matches the process and
    \\window, then writes window.png, controls.tsv and record.json into a new directory
    \\DIR/diag-<pid>-<n>. It sends no click, key, menu or value change. DIR must be an existing
    \\directory that is not a symbolic link and not an export operation directory.
    \\Exit 0 complete, 1 partial or failed capture, 2 usage.
    \\
;

const ParsedArgs = struct {
    req: Request,
};

const ArgError = struct { msg: []const u8 };

fn takeValue(argv: []const []const u8, i: *usize, name: []const u8, inline_value: ?[]const u8) ?[]const u8 {
    if (inline_value) |v| return v;
    _ = name;
    if (i.* + 1 >= argv.len) return null;
    i.* += 1;
    return argv[i.*];
}

/// Parses the arguments. Returns the request or the usage problem.
fn parseArgs(argv: []const []const u8) union(enum) { ok: Request, bad: []const u8 } {
    var pid: ?i32 = null;
    var window_id: ?u32 = null;
    var title: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var reason: ?[]const u8 = null;
    var expected: []const u8 = "";
    var last: []const u8 = "";
    var timeout: u32 = 20_000;
    var seen: [7]bool = .{false} ** 7;
    const names = [_][]const u8{ "--pid", "--window-id", "--window-title", "--out", "--reason", "--expected", "--last-action" };
    var seen_timeout = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!std.mem.startsWith(u8, arg, "--")) return .{ .bad = "unexpected argument" };
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        const inline_value: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
        const v = takeValue(argv, &i, name, inline_value) orelse return .{ .bad = "option needs a value" };
        if (std.mem.eql(u8, name, "--timeout-ms")) {
            if (seen_timeout) return .{ .bad = "option repeated" };
            seen_timeout = true;
            timeout = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = "--timeout-ms is not a number" };
            continue;
        }
        var known = false;
        for (names, 0..) |n, k| {
            if (!std.mem.eql(u8, n, name)) continue;
            if (seen[k]) return .{ .bad = "option repeated" };
            seen[k] = true;
            known = true;
        }
        if (!known) return .{ .bad = "unknown option" };
        if (std.mem.eql(u8, name, "--pid")) {
            pid = std.fmt.parseInt(i32, v, 10) catch return .{ .bad = "--pid is not a number" };
        } else if (std.mem.eql(u8, name, "--window-id")) {
            window_id = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = "--window-id is not a number" };
        } else if (std.mem.eql(u8, name, "--window-title")) {
            title = v;
        } else if (std.mem.eql(u8, name, "--out")) {
            out_dir = v;
        } else if (std.mem.eql(u8, name, "--reason")) {
            reason = v;
        } else if (std.mem.eql(u8, name, "--expected")) {
            expected = v;
        } else {
            last = v;
        }
    }
    const req: Request = .{
        .pid = pid orelse return .{ .bad = "--pid is required" },
        .window_id = window_id,
        .window_title = title,
        .out_dir = out_dir orelse return .{ .bad = "--out is required" },
        .reason = reason orelse return .{ .bad = "--reason is required" },
        .expected_condition = expected,
        .last_action = last,
        .timeout_ms = timeout,
    };
    if (requestProblem(req)) |why| return .{ .bad = why };
    return .{ .ok = req };
}

/// Production entry point. Arguments are validated before the first native call.
pub fn runCli(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    return runCliWith(gpa, io, argv, out, null);
}

/// A backend and clock for tests of the command. Production passes null.
pub const Seams = struct {
    backend: Backend,
    env: nur.Env,
};

pub fn runCliWith(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer, seams: ?Seams) u8 {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h") or std.mem.eql(u8, argv[0], "help"))) {
        out.writeAll(usage_text) catch {};
        out.flush() catch {};
        return 0;
    }
    const req = switch (parseArgs(argv)) {
        .bad => |why| {
            out.print("error\t{s}\n", .{why}) catch {};
            out.writeAll(usage_text) catch {};
            out.flush() catch {};
            return 2;
        },
        .ok => |r| r,
    };
    var report: Report = undefined;
    if (seams) |s| {
        report = capture(gpa, io, s.backend, s.env, req) catch return oomExit(out);
    } else {
        nur.installSignalHandlers();
        var pt: nur.ProcessTransport = .{ .io = io };
        var se: nur.SystemEnv = .{ .io = io };
        var mac = MacBackend.init(gpa, pt.transport(), se.env(), .{});
        defer mac.deinit();
        if (comptime @import("builtin").os.tag == .macos) {
            var nb = native_diag.NativeBackend.init(gpa, &mac, se.env());
            defer nb.deinit();
            report = capture(gpa, io, nb.backend(), se.env(), req) catch return oomExit(out);
        } else {
            report = capture(gpa, io, mac.backend(), se.env(), req) catch return oomExit(out);
        }
    }
    defer report.deinit();
    writeReport(out, &report) catch {};
    out.flush() catch {};
    return switch (report.outcome) {
        .complete => 0,
        else => 1,
    };
}

fn oomExit(out: *Io.Writer) u8 {
    out.writeAll("error\tout of memory\n") catch {};
    out.flush() catch {};
    return 1;
}

fn writeReport(out: *Io.Writer, r: *const Report) Io.Writer.Error!void {
    try out.print("outcome\t{s}\n", .{@tagName(r.outcome)});
    if (r.diag_dir) |d| try out.print("diag_dir\t{s}\n", .{d});
    if (r.record_path) |p| try out.print("record\t{s}\n", .{p});
    try out.print("selection\t{s}\n", .{@tagName(r.selection)});
    switch (r.screenshot) {
        .written => |w| try out.print("screenshot\twritten\t{s}\t{d}x{d}\t{d} bytes\n", .{ w.path, w.width, w.height, w.bytes }),
        .unavailable => |e| try out.print("screenshot\tunavailable\t{s}\t{s}\n", .{ @tagName(e.kind), e.detail }),
        .failed => |e| try out.print("screenshot\tfailed\t{s}\t{s}\n", .{ @tagName(e.kind), e.detail }),
    }
    switch (r.controls) {
        .written => |w| try out.print("controls\twritten\t{s}\t{d} nodes\ttruncated={}\n", .{ w.path, w.nodes, w.truncated }),
        .unavailable => |e| try out.print("controls\tunavailable\t{s}\t{s}\n", .{ @tagName(e.kind), e.detail }),
        .failed => |e| try out.print("controls\tfailed\t{s}\t{s}\n", .{ @tagName(e.kind), e.detail }),
    }
    for (r.errors) |e| try out.print("error\t{s}\n", .{e});
}

// Tests

const testing = std.testing;
const Scratch = opdir.Scratch;

const FakeEnv = struct {
    t: u64 = 0,

    fn env(f: *FakeEnv) nur.Env {
        return .{ .ptr = f, .nowFn = nowImpl, .sleepFn = sleepImpl };
    }
    fn nowImpl(ptr: *anyopaque) u64 {
        const f: *FakeEnv = @ptrCast(@alignCast(ptr));
        return f.t;
    }
    fn sleepImpl(_: *anyopaque, _: u32) void {}
};

/// Minimal valid PNG. The check reads the signature, IHDR and IEND only.
fn pngBytes(w: u32, h: u32) [45]u8 {
    var b: [45]u8 = undefined;
    @memcpy(b[0..8], &png_sig);
    std.mem.writeInt(u32, b[8..12], 13, .big);
    @memcpy(b[12..16], "IHDR");
    std.mem.writeInt(u32, b[16..20], w, .big);
    std.mem.writeInt(u32, b[20..24], h, .big);
    @memset(b[24..33], 0);
    @memcpy(b[33..45], &png_iend);
    return b;
}

const CaptureMode = enum { png, junk, unavailable, timeout, nothing };

const FakeBackend = struct {
    env: *FakeEnv,
    windows: []const WindowInfo = &.{},
    windows_fail: ?Failure = null,
    tree: Tree = .{ .nodes = &.{} },
    tree_fail: ?Failure = null,
    mode: CaptureMode = .png,
    /// Clock advance of each call in milliseconds.
    cost_ms: u64 = 0,
    windows_calls: usize = 0,
    tree_calls: usize = 0,
    capture_calls: usize = 0,
    last_target: ?Target = null,
    last_path: []const u8 = "",

    fn backend(f: *FakeBackend) Backend {
        return .{ .ptr = f, .windowsFn = windowsImpl, .treeFn = treeImpl, .captureFn = captureImpl };
    }
    fn self(ptr: *anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(ptr));
    }
    fn windowsImpl(ptr: *anyopaque, t: Target) WindowsReply {
        const f = self(ptr);
        f.windows_calls += 1;
        f.env.t += f.cost_ms * std.time.ns_per_ms;
        _ = t;
        if (f.windows_fail) |x| return .{ .failed = x };
        return .{ .windows = f.windows };
    }
    fn treeImpl(ptr: *anyopaque, t: Target, lim: TreeLimits) TreeReply {
        const f = self(ptr);
        f.tree_calls += 1;
        f.env.t += f.cost_ms * std.time.ns_per_ms;
        f.last_target = t;
        _ = lim;
        if (f.tree_fail) |x| return .{ .failed = x };
        return .{ .tree = f.tree };
    }
    fn captureImpl(ptr: *anyopaque, t: Target, path: []const u8) CaptureReply {
        const f = self(ptr);
        f.capture_calls += 1;
        f.env.t += f.cost_ms * std.time.ns_per_ms;
        f.last_target = t;
        f.last_path = path;
        switch (f.mode) {
            .unavailable => return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "screencapture failed" } },
            .timeout => return .{ .failed = .{ .kind = .timeout, .detail = "child process timed out and was killed" } },
            .nothing => return .done,
            .png, .junk => {},
        }
        const file = Dir.cwd().createFile(testing.io, path, .{ .exclusive = true }) catch return .{ .failed = .{ .kind = .transport_error, .detail = "fake could not create the file" } };
        defer file.close(testing.io);
        const png = pngBytes(640, 480);
        const bytes: []const u8 = if (f.mode == .png) &png else "not a png file, but long enough to pass the size check....";
        file.writeStreamingAll(testing.io, bytes) catch return .{ .failed = .{ .kind = .transport_error, .detail = "fake write failed" } };
        return .done;
    }
};

const win_main: WindowInfo = .{ .number = 101, .title = "Untitled - Vectorworks", .modal = false };
const win_modal: WindowInfo = .{ .number = 202, .title = "Vectorworks", .modal = true };
const sample_nodes = [_]Node{
    .{ .depth = 0, .role = "AXWindow", .name = "Vectorworks", .enabled = true },
    .{ .depth = 1, .role = "AXButton", .name = "OK", .enabled = true },
    .{ .depth = 1, .role = "AXStaticText", .value = "Unexpected notice" },
};

fn reqIn(s: *const Scratch) Request {
    return .{ .pid = 4242, .out_dir = s.path, .reason = "unknown_modal", .expected_condition = "export dialog", .last_action = "press Export" };
}

fn fileExists(dir: []const u8, name: []const u8) !bool {
    const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(p);
    _ = Dir.cwd().statFile(testing.io, p, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn readAt(dir: []const u8, name: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(p);
    return Dir.cwd().readFileAlloc(testing.io, p, testing.allocator, .limited(1 << 20));
}

fn jsonField(v: std.json.Value, comptime path: []const []const u8) !std.json.Value {
    var cur = v;
    inline for (path) |k| cur = cur.object.get(k) orelse return error.MissingField;
    return cur;
}

test "a matched window gives a PNG, a control snapshot and a record" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{ win_main, win_modal }, .tree = .{ .nodes = &sample_nodes } };
    var req = reqIn(&s);
    req.window_id = 202;
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer rep.deinit();
    try testing.expectEqual(Outcome.complete, rep.outcome);
    try testing.expectEqual(Selection.window_id, rep.selection);
    try testing.expectEqual(@as(?u32, 202), fb.last_target.?.window_id);
    try testing.expect(std.mem.endsWith(u8, fb.last_path, "/window.png.partial"));
    const dir = rep.diag_dir.?;
    try testing.expect(std.mem.startsWith(u8, std.fs.path.basename(dir), "diag-4242-"));
    try testing.expect(try fileExists(dir, png_name));
    try testing.expect(!(try fileExists(dir, png_name ++ ".partial")));
    try testing.expectEqual(@as(u32, 640), rep.screenshot.written.width);
    const ctl = try readAt(dir, controls_name);
    defer testing.allocator.free(ctl);
    try testing.expectEqualStrings("# vwx-ui-controls/1\n0\tAXWindow\t\tVectorworks\t\tt\n1\tAXButton\t\tOK\t\tt\n1\tAXStaticText\t\t\tUnexpected notice\tu\n", ctl);
    const rec = try readAt(dir, record_name);
    defer testing.allocator.free(rec);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, rec, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(schema_record, (try jsonField(parsed.value, &.{"schema"})).string);
    try testing.expectEqualStrings("unknown_modal", (try jsonField(parsed.value, &.{"reason"})).string);
    try testing.expectEqualStrings("export dialog", (try jsonField(parsed.value, &.{"expected_condition"})).string);
    try testing.expectEqualStrings("press Export", (try jsonField(parsed.value, &.{"last_action"})).string);
    try testing.expectEqual(@as(i64, 2), (try jsonField(parsed.value, &.{ "actual_state", "window_count" })).integer);
    try testing.expectEqual(@as(i64, 1), (try jsonField(parsed.value, &.{ "actual_state", "modal_count" })).integer);
    try testing.expectEqualStrings("written", (try jsonField(parsed.value, &.{ "screenshot", "result" })).string);
    try testing.expectEqualStrings("written", (try jsonField(parsed.value, &.{ "controls", "result" })).string);
    try testing.expect(rep.record_path != null);
}

test "a wrong window id stops before any screenshot or tree call and keeps a record" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{ win_main, win_modal }, .tree = .{ .nodes = &sample_nodes } };
    var req = reqIn(&s);
    req.window_id = 999;
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer rep.deinit();
    try testing.expectEqual(Outcome.identity_failed, rep.outcome);
    try testing.expectEqual(@as(usize, 0), fb.capture_calls);
    try testing.expectEqual(@as(usize, 0), fb.tree_calls);
    try testing.expectEqual(FailureKind.wrong_identity, rep.screenshot.unavailable.kind);
    try testing.expect(!(try fileExists(rep.diag_dir.?, png_name)));
    const rec = try readAt(rep.diag_dir.?, record_name);
    defer testing.allocator.free(rec);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, rec, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("not_established", (try jsonField(parsed.value, &.{"identity"})).string);
    try testing.expectEqual(@as(i64, 2), (try jsonField(parsed.value, &.{ "actual_state", "window_count" })).integer);
}

test "a title that does not belong to the id, or that two windows share, is refused" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    const twin: WindowInfo = .{ .number = 303, .title = "Vectorworks", .modal = true };
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{ win_main, win_modal, twin } };
    var req = reqIn(&s);
    req.window_id = 101;
    req.window_title = "Vectorworks";
    var r1 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer r1.deinit();
    try testing.expectEqual(Outcome.identity_failed, r1.outcome);
    try testing.expectEqual(FailureKind.wrong_identity, r1.screenshot.unavailable.kind);
    req.window_id = null;
    var r2 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer r2.deinit();
    try testing.expectEqual(FailureKind.ambiguous_target, r2.screenshot.unavailable.kind);
    req.window_title = "Untitled - Vectorworks";
    var r3 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer r3.deinit();
    try testing.expectEqual(Outcome.complete, r3.outcome);
    try testing.expectEqual(Selection.window_title, r3.selection);
    try testing.expectEqual(@as(usize, 1), fb.capture_calls);
}

test "without id or title one modal window is chosen and several plain windows are ambiguous" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{ win_main, win_modal }, .tree = .{ .nodes = &sample_nodes } };
    var r1 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r1.deinit();
    try testing.expectEqual(Selection.only_modal, r1.selection);
    try testing.expectEqual(@as(?u32, 202), r1.matched.?.number);
    fb.windows = &.{ win_main, .{ .number = 102, .title = "Other", .modal = false } };
    var r2 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r2.deinit();
    try testing.expectEqual(Outcome.identity_failed, r2.outcome);
    try testing.expectEqual(FailureKind.ambiguous_target, r2.controls.unavailable.kind);
    fb.windows = &.{win_main};
    var r3 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r3.deinit();
    try testing.expectEqual(Selection.only_window, r3.selection);
    fb.windows = &.{};
    var r4 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r4.deinit();
    try testing.expectEqual(Outcome.identity_failed, r4.outcome);
}

test "a lost process and a window list failure are reported as identity failures" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows_fail = .{ .kind = .process_lost, .detail = "process is not running" } };
    var r1 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r1.deinit();
    try testing.expectEqual(Outcome.identity_failed, r1.outcome);
    try testing.expectEqual(FailureKind.process_lost, r1.screenshot.unavailable.kind);
    try testing.expect(r1.record_path != null);
    try testing.expect(!r1.windows_known);
    fb.windows_fail = .{ .kind = .timeout, .detail = "child process timed out and was killed" };
    var r2 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r2.deinit();
    try testing.expectEqual(FailureKind.timeout, r2.screenshot.unavailable.kind);
    try testing.expectEqual(@as(usize, 0), fb.capture_calls);
}

test "a failed selector read keeps the screenshot and records the reason" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree_fail = .{ .kind = .unknown_ui, .detail = "target window is absent" } };
    var req = reqIn(&s);
    req.reason = "selector_failed";
    req.expected_condition = "button Export in sheet";
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer rep.deinit();
    try testing.expectEqual(Outcome.partial, rep.outcome);
    try testing.expect(rep.screenshot == .written);
    try testing.expectEqual(FailureKind.unknown_ui, rep.controls.unavailable.kind);
    try testing.expect(!(try fileExists(rep.diag_dir.?, controls_name)));
    const rec = try readAt(rep.diag_dir.?, record_name);
    defer testing.allocator.free(rec);
    try testing.expect(std.mem.indexOf(u8, rec, "button Export in sheet") != null);
    try testing.expect(std.mem.indexOf(u8, rec, "controls: unknown_ui") != null);
}

test "screenshot failures keep the control snapshot and the record" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &sample_nodes }, .mode = .unavailable };
    var r1 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r1.deinit();
    try testing.expectEqual(Outcome.partial, r1.outcome);
    try testing.expectEqual(FailureKind.screenshot_unavailable, r1.screenshot.unavailable.kind);
    try testing.expect(r1.controls == .written);
    try testing.expect(try fileExists(r1.diag_dir.?, controls_name));
    try testing.expect(try fileExists(r1.diag_dir.?, record_name));
    try testing.expect(!(try fileExists(r1.diag_dir.?, png_name)));
    fb.mode = .timeout;
    var r2 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r2.deinit();
    try testing.expectEqual(FailureKind.timeout, r2.screenshot.failed.kind);
    try testing.expect(r2.controls == .written);
    fb.mode = .nothing;
    var r3 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer r3.deinit();
    try testing.expect(r3.screenshot == .failed);
    try testing.expect(!(try fileExists(r3.diag_dir.?, png_name)));
}

test "an invalid capture file is rejected and stays as a partial file" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &sample_nodes }, .mode = .junk };
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer rep.deinit();
    try testing.expectEqual(Outcome.partial, rep.outcome);
    try testing.expect(rep.screenshot == .failed);
    try testing.expect(!(try fileExists(rep.diag_dir.?, png_name)));
    try testing.expect(try fileExists(rep.diag_dir.?, png_name ++ ".partial"));
}

test "a window without a number cannot be captured but its tree is read by title" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{.{ .number = null, .title = "Vectorworks", .modal = true }}, .tree = .{ .nodes = &sample_nodes } };
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer rep.deinit();
    try testing.expectEqual(@as(usize, 0), fb.capture_calls);
    try testing.expectEqual(FailureKind.screenshot_unavailable, rep.screenshot.unavailable.kind);
    try testing.expect(rep.controls == .written);
    try testing.expectEqualStrings("Vectorworks", fb.last_target.?.window_title.?);
}

test "partial artifact writes never publish the final name" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &sample_nodes } };
    var req = reqIn(&s);
    req.hooks = .{ .fail_write = controls_name };
    var r1 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer r1.deinit();
    try testing.expectEqual(Outcome.partial, r1.outcome);
    try testing.expect(r1.controls == .failed);
    try testing.expect(!(try fileExists(r1.diag_dir.?, controls_name)));
    try testing.expect(try fileExists(r1.diag_dir.?, controls_name ++ ".partial"));
    try testing.expect(r1.screenshot == .written);
    try testing.expect(try fileExists(r1.diag_dir.?, record_name));
    req.hooks = .{ .fail_write = record_name };
    var r2 = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer r2.deinit();
    try testing.expectEqual(Outcome.output_failed, r2.outcome);
    try testing.expect(r2.record_path == null);
    try testing.expect(!(try fileExists(r2.diag_dir.?, record_name)));
    try testing.expect(try fileExists(r2.diag_dir.?, record_name ++ ".partial"));
    try testing.expect(r2.screenshot == .written and r2.controls == .written);
    try testing.expect(r2.errors.len >= 1);
}

fn expectRejected(req: Request, fb: *FakeBackend, fe: *FakeEnv) !void {
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer rep.deinit();
    try testing.expectEqual(Outcome.rejected, rep.outcome);
    try testing.expectEqual(@as(usize, 0), fb.windows_calls);
    try testing.expectEqual(@as(usize, 0), fb.capture_calls);
    try testing.expect(rep.diag_dir == null);
    try testing.expect(rep.errors.len == 1);
}

test "unsafe requests and output directories are rejected before any backend call" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal} };
    var req = reqIn(&s);
    req.out_dir = "relative/dir";
    try expectRejected(req, &fb, &fe);
    const dots = try s.join("a/../b");
    defer testing.allocator.free(dots);
    req.out_dir = dots;
    try expectRejected(req, &fb, &fe);
    req.out_dir = "/tmp/with\nnewline";
    try expectRejected(req, &fb, &fe);
    req = reqIn(&s);
    req.pid = 1;
    try expectRejected(req, &fb, &fe);
    req.pid = 4242;
    req.window_id = 0;
    try expectRejected(req, &fb, &fe);
    req.window_id = null;
    req.window_title = "";
    try expectRejected(req, &fb, &fe);
    req.window_title = null;
    req.reason = "";
    try expectRejected(req, &fb, &fe);
    req.reason = "r";
    req.timeout_ms = 0;
    try expectRejected(req, &fb, &fe);
}

test "a missing directory, a file, a symlink and an export directory are refused as out_dir" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &sample_nodes } };
    try s.mkdir("real");
    try s.mkdir("export");
    const real = try s.join("real");
    defer testing.allocator.free(real);
    const link = try s.join("link");
    defer testing.allocator.free(link);
    try Dir.cwd().symLink(testing.io, real, link, .{ .is_directory = true });
    const file = try s.join("plain");
    defer testing.allocator.free(file);
    {
        const f = try Dir.cwd().createFile(testing.io, file, .{ .exclusive = true });
        f.close(testing.io);
    }
    const export_dir = try s.join("export");
    defer testing.allocator.free(export_dir);
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ export_dir, opdir.open_name });
        defer testing.allocator.free(p);
        const f = try Dir.cwd().createFile(testing.io, p, .{ .exclusive = true });
        f.close(testing.io);
    }
    const missing = try s.join("missing");
    defer testing.allocator.free(missing);
    var req = reqIn(&s);
    for ([_][]const u8{ link, file, export_dir }) |bad| {
        req.out_dir = bad;
        var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
        defer rep.deinit();
        try testing.expectEqual(Outcome.rejected, rep.outcome);
        try testing.expect(rep.diag_dir == null);
    }
    req.out_dir = missing;
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer rep.deinit();
    try testing.expectEqual(Outcome.output_failed, rep.outcome);
    try testing.expectEqual(@as(usize, 0), fb.windows_calls);
    // Nothing was written through the symlink or into the export directory.
    try testing.expect(!(try fileExists(real, "diag-4242-1")));
    try testing.expect(!(try fileExists(export_dir, "diag-4242-1")));
}

test "an existing diagnostic directory or a symlink with its name is never reused" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &sample_nodes } };
    try s.mkdir("elsewhere");
    try s.mkdir("diag-4242-1");
    const target = try s.join("elsewhere");
    defer testing.allocator.free(target);
    const link = try s.join("diag-4242-2");
    defer testing.allocator.free(link);
    try Dir.cwd().symLink(testing.io, target, link, .{ .is_directory = true });
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), reqIn(&s));
    defer rep.deinit();
    try testing.expectEqual(Outcome.complete, rep.outcome);
    try testing.expectEqualStrings("diag-4242-3", std.fs.path.basename(rep.diag_dir.?));
    try testing.expect(!(try fileExists(s.path, "elsewhere/" ++ record_name)));
    try testing.expect(!(try fileExists(s.path, "diag-4242-1/" ++ record_name)));
}

test "the call budget stops later steps and the record still lands" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &sample_nodes }, .cost_ms = 600 };
    var req = reqIn(&s);
    req.timeout_ms = 1000;
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer rep.deinit();
    try testing.expect(rep.screenshot == .written);
    try testing.expectEqual(FailureKind.timeout, rep.controls.failed.kind);
    try testing.expectEqual(@as(usize, 0), fb.tree_calls);
    try testing.expect(rep.record_path != null);
    try testing.expect(fb.last_target.?.timeout_ms <= 400);
}

test "tree text is cleaned and bounded" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var nodes: [10]Node = undefined;
    for (&nodes, 0..) |*n, i| n.* = .{ .depth = if (i == 9) 99 else 1, .role = "AXButton", .name = "a\tb\nc\x01d", .value = "\xff\xfe long value" ++ "x" ** 300 };
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &nodes } };
    var req = reqIn(&s);
    req.limits.max_tree_nodes = 5;
    var rep = try capture(testing.allocator, testing.io, fb.backend(), fe.env(), req);
    defer rep.deinit();
    const ctl = try readAt(rep.diag_dir.?, controls_name);
    defer testing.allocator.free(ctl);
    try testing.expect(rep.controls.written.truncated);
    try testing.expectEqual(@as(usize, 5), rep.controls.written.nodes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, ctl, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |l| : (n += 1) {
        if (n == 0 or l[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, l, '\t');
        var c: usize = 0;
        while (cols.next()) |col| : (c += 1) try testing.expect(col.len <= req.limits.max_field);
        try testing.expectEqual(@as(usize, 6), c);
    }
    try testing.expect(std.mem.indexOf(u8, ctl, "a b c d") != null);
    try testing.expect(std.mem.endsWith(u8, ctl, "# truncated\n"));
}

test "capture frees everything on every allocation failure" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{ win_main, win_modal }, .tree = .{ .nodes = &sample_nodes } };
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        if (capture(fa.allocator(), testing.io, fb.backend(), fe.env(), reqIn(&s))) |r| {
            var rep = r;
            rep.deinit();
            try testing.expect(!fa.has_induced_failure);
            return;
        } else |e| try testing.expectEqual(error.OutOfMemory, e);
    }
    return error.NeverSucceeded;
}

// MacBackend and command line tests

const FakeTransport = struct {
    const Rule = struct { needle: []const u8, stdout: []const u8, exit_code: u8 = 0, status: nur.RunStatus = .exited };
    rules: []const Rule,
    calls: std.ArrayList([]const u8) = .empty,

    fn deinit(t: *FakeTransport) void {
        for (t.calls.items) |c| testing.allocator.free(c);
        t.calls.deinit(testing.allocator);
    }
    fn transport(t: *FakeTransport) nur.Transport {
        return .{ .ptr = t, .runFn = runImpl };
    }
    fn runImpl(ptr: *anyopaque, a: Allocator, argv: []const []const u8, _: u32, _: nur.StreamLimits) nur.RunOutput {
        const t: *FakeTransport = @ptrCast(@alignCast(ptr));
        const joined = std.mem.join(testing.allocator, " ", argv) catch return .{ .status = .spawn_failed };
        t.calls.append(testing.allocator, joined) catch return .{ .status = .spawn_failed };
        for (t.rules) |r| {
            if (std.mem.indexOf(u8, joined, r.needle) == null) continue;
            if (r.status != .exited) return .{ .status = r.status };
            return .{ .status = .exited, .exit_code = r.exit_code, .stdout = a.dupe(u8, r.stdout) catch return .{ .status = .read_failed } };
        }
        return .{ .status = .spawn_failed };
    }
};

test "mac backend lists windows, reads a bounded tree and captures by window number" {
    var fe: FakeEnv = .{};
    var ft: FakeTransport = .{ .rules = &.{
        .{ .needle = "AXModal", .stdout = "ok\nW\t101\ts:Untitled\tf\nW\t202\ts:Vectorworks\tt\nW\t-\tn\tu\n" },
        .{ .needle = "walk(item 1", .stdout = "ok\nC\nN\t0\tAXWindow\t\tVectorworks\t\tt\nN\t1\tAXButton\t\tOK\t\tt\nN\t9\tAXButton\t\tdeep\t\tt\n" },
        .{ .needle = "screencapture", .stdout = "" },
    } };
    defer ft.deinit();
    var mac = MacBackend.init(testing.allocator, ft.transport(), fe.env(), .{});
    defer mac.deinit();
    const b = mac.backend();
    const t: Target = .{ .pid = 77, .window_id = 202, .window_title = "Vectorworks", .timeout_ms = 5000 };
    const w = b.windows(t).windows;
    try testing.expectEqual(@as(usize, 3), w.len);
    try testing.expectEqual(@as(?u32, 202), w[1].number);
    try testing.expectEqual(@as(?bool, true), w[1].modal);
    try testing.expectEqual(@as(?u32, null), w[2].number);
    try testing.expectEqual(@as(?[]const u8, null), w[2].title);
    const tr = b.tree(t, .{ .max_depth = 8, .max_nodes = 400, .max_field = 200 }).tree;
    try testing.expectEqual(@as(usize, 2), tr.nodes.len);
    try testing.expect(tr.truncated);
    try testing.expectEqualStrings("OK", tr.nodes[1].name);
    try testing.expect(std.mem.indexOf(u8, ft.calls.items[1], " 77 202 - 8 400 200") != null);
    try testing.expect(b.capture(t, "/tmp/x/window.png.partial") == .done);
    const last = ft.calls.items[ft.calls.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, last, "/usr/sbin/screencapture -x -o -l 202 /tmp/x/window.png.partial"));
    try testing.expect(std.mem.indexOf(u8, last, " -R") == null);
}

test "mac backend maps script refusals, a gone process, a timeout and a missing window number" {
    var fe: FakeEnv = .{};
    var ft: FakeTransport = .{ .rules = &.{
        .{ .needle = "AXModal", .stdout = "gone" },
        .{ .needle = "walk(item 1", .stdout = "refused\twindow_ambiguous" },
        .{ .needle = "screencapture", .stdout = "", .status = .timed_out },
    } };
    defer ft.deinit();
    var mac = MacBackend.init(testing.allocator, ft.transport(), fe.env(), .{});
    defer mac.deinit();
    const b = mac.backend();
    var t: Target = .{ .pid = 77, .window_id = 202, .window_title = null, .timeout_ms = 5000 };
    try testing.expectEqual(FailureKind.process_lost, b.windows(t).failed.kind);
    try testing.expectEqual(FailureKind.ambiguous_target, b.tree(t, .{ .max_depth = 2, .max_nodes = 2, .max_field = 2 }).failed.kind);
    try testing.expectEqual(FailureKind.timeout, b.capture(t, "/tmp/x/window.png").failed.kind);
    t.window_id = null;
    try testing.expectEqual(FailureKind.screenshot_unavailable, b.capture(t, "/tmp/x/window.png").failed.kind);
    try testing.expectEqual(FailureKind.refused, b.tree(t, .{ .max_depth = 2, .max_nodes = 2, .max_field = 2 }).failed.kind);
    t.window_id = 5;
    try testing.expectEqual(FailureKind.refused, b.capture(t, "relative.png").failed.kind);
    try testing.expectEqual(FailureKind.refused, b.capture(t, "/tmp/x/window.txt").failed.kind);
}

test "mac backend rejects malformed script output" {
    var fe: FakeEnv = .{};
    var ft: FakeTransport = .{ .rules = &.{
        .{ .needle = "AXModal", .stdout = "ok\nW\t1\ts:a\n" },
        .{ .needle = "walk(item 1", .stdout = "ok\nN\tx\tAXWindow\t\tV\t\tt\n" },
    } };
    defer ft.deinit();
    var mac = MacBackend.init(testing.allocator, ft.transport(), fe.env(), .{});
    defer mac.deinit();
    const t: Target = .{ .pid = 77, .window_id = 1, .window_title = null, .timeout_ms = 5000 };
    try testing.expectEqual(FailureKind.transport_error, mac.backend().windows(t).failed.kind);
    try testing.expectEqual(FailureKind.transport_error, mac.backend().tree(t, .{ .max_depth = 2, .max_nodes = 2, .max_field = 2 }).failed.kind);
}

test "embedded scripts only read" {
    const forbidden = [_][]const u8{ "click", "keystroke", "key code", "activate", "set value", "perform action", "AXPress", "set frontmost", "do shell script", "set focused", "set selected" };
    for ([_][]const u8{ script_windows, script_tree }) |src| {
        for (forbidden) |w| try testing.expect(std.mem.indexOf(u8, src, w) == null);
    }
}

fn runArgs(argv: []const []const u8, seams: ?Seams) !struct { code: u8, text: []u8 } {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    const code = runCliWith(testing.allocator, testing.io, argv, &aw.writer, seams);
    return .{ .code = code, .text = try aw.toOwnedSlice() };
}

test "command help and argument validation make no backend call" {
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal} };
    const seams: Seams = .{ .backend = fb.backend(), .env = fe.env() };
    const help = try runArgs(&.{"--help"}, seams);
    defer testing.allocator.free(help.text);
    try testing.expectEqual(@as(u8, 0), help.code);
    try testing.expect(std.mem.startsWith(u8, help.text, "usage: vwx ui-diagnose"));
    const bad_sets = [_][]const []const u8{
        &.{},
        &.{ "--pid", "5" },
        &.{ "--pid", "x", "--out", "/tmp", "--reason", "r" },
        &.{ "--pid", "1", "--out", "/tmp", "--reason", "r" },
        &.{ "--pid", "5", "--out", "rel", "--reason", "r" },
        &.{ "--pid", "5", "--out", "/tmp", "--reason", "r", "--bogus", "1" },
        &.{ "--pid", "5", "--pid", "6", "--out", "/tmp", "--reason", "r" },
        &.{ "--pid", "5", "--out", "/tmp", "--reason" },
        &.{ "--pid", "5", "--out", "/tmp", "--reason", "r", "--window-id", "-3" },
        &.{ "--pid", "5", "--out", "/tmp", "--reason", "r", "--timeout-ms", "soon" },
        &.{ "stray", "--pid", "5" },
    };
    for (bad_sets) |argv| {
        const r = try runArgs(argv, seams);
        defer testing.allocator.free(r.text);
        try testing.expectEqual(@as(u8, 2), r.code);
        try testing.expect(std.mem.startsWith(u8, r.text, "error\t"));
    }
    try testing.expectEqual(@as(usize, 0), fb.windows_calls + fb.tree_calls + fb.capture_calls);
}

test "command runs a capture through the injected backend and reports its exit status" {
    var s = try Scratch.init();
    defer s.deinit();
    var fe: FakeEnv = .{};
    var fb: FakeBackend = .{ .env = &fe, .windows = &.{win_modal}, .tree = .{ .nodes = &sample_nodes } };
    const seams: Seams = .{ .backend = fb.backend(), .env = fe.env() };
    const argv = [_][]const u8{ "--pid=4242", "--out", s.path, "--reason", "stall", "--expected=dialog closes", "--last-action", "press Export", "--window-title", "Vectorworks", "--timeout-ms", "9000" };
    const ok = try runArgs(&argv, seams);
    defer testing.allocator.free(ok.text);
    try testing.expectEqual(@as(u8, 0), ok.code);
    try testing.expect(std.mem.startsWith(u8, ok.text, "outcome\tcomplete\n"));
    try testing.expect(std.mem.indexOf(u8, ok.text, "screenshot\twritten\t") != null);
    fb.mode = .unavailable;
    const part = try runArgs(&argv, seams);
    defer testing.allocator.free(part.text);
    try testing.expectEqual(@as(u8, 1), part.code);
    try testing.expect(std.mem.indexOf(u8, part.text, "outcome\tpartial\n") != null);
    try testing.expect(std.mem.indexOf(u8, part.text, "screenshot\tunavailable\tscreenshot_unavailable\t") != null);
}

// ui-attach

/// Identity and visibility of one running process. `ui-attach` never launches, quits, terminates
/// or reopens an application. The only action is the explicit `--focus` request, which sets
/// AXHidden to false and AXFrontmost to true on the Accessibility element of the verified pid.
pub const attach_usage_text =
    \\usage: vwx ui-attach --pid N --expected-executable ABSOLUTE_PATH [--focus]
    \\
    \\Verifies that process N runs exactly ABSOLUTE_PATH (proc_pidpath) and reports its
    \\Accessibility state. Without --focus the command reads only. With --focus it then sets
    \\AXHidden=false and AXFrontmost=true on that process and reads the state again. The command
    \\has no launch, quit, terminate or reopen route. The post_event_access_* lines show the
    \\no-prompt CGPreflightPostEventAccess result (granted, denied, unknown or unavailable). It is
    \\permission evidence, not proof that an event arrived. Exit 0 verified and requested action done,
    \\1 refused or action failed, 2 usage.
    \\
;

/// Result of CGPreflightPostEventAccess, which never prompts. It says whether this process may post
/// events to other processes. It is evidence about permission, not proof that an event arrived.
pub const PostAccess = enum {
    granted,
    denied,
    /// Not read, for example by a backend without the seam.
    unknown,
    /// The platform has no such check.
    unavailable,
};

pub const AttachState = struct {
    post_event_access: PostAccess = .unknown,
    trusted: bool,
    hidden: ?bool = null,
    frontmost: ?bool = null,
    ax_windows: ?usize = null,
    focused_window: ?bool = null,
};

/// Accessibility result codes of the two focus steps. Zero is success. Null means the step was not
/// needed because the attribute already had the wanted value.
pub const FocusOutcome = struct {
    unhide_code: ?i32 = null,
    front_code: i32 = 0,
};

pub const AttachBackend = struct {
    ptr: *anyopaque,
    /// Executable path of the pid copied into `buf`. Null when no such process exists.
    pathFn: *const fn (ptr: *anyopaque, pid: i32, buf: []u8) ?[]const u8,
    stateFn: *const fn (ptr: *anyopaque, pid: i32) AttachState,
    focusFn: *const fn (ptr: *anyopaque, pid: i32, before: AttachState) FocusOutcome,
    /// Read-only permission preflight. Null reads as `unknown`.
    postAccessFn: ?*const fn (ptr: *anyopaque) PostAccess = null,

    fn postAccess(b: AttachBackend) PostAccess {
        const f = b.postAccessFn orelse return .unknown;
        return f(b.ptr);
    }
};

pub const AttachRequest = struct {
    pid: i32,
    expected_executable: []const u8,
    focus: bool = false,
};

pub const Identity = enum { verified, mismatch, not_running };

pub const AttachResult = struct {
    identity: Identity,
    /// Borrowed from the buffer that the caller passed to `attach`.
    actual_path: ?[]const u8 = null,
    before: ?AttachState = null,
    focus_requested: bool = false,
    /// Set when the focus step ran.
    focus: ?FocusOutcome = null,
    /// Why a requested focus step did not run.
    focus_skipped: ?[]const u8 = null,
    after: ?AttachState = null,

    pub fn ok(r: AttachResult) bool {
        if (r.identity != .verified) return false;
        if (!r.focus_requested) return true;
        const f = r.focus orelse return false;
        return (f.unhide_code orelse 0) == 0 and f.front_code == 0;
    }
};

/// Verifies the executable of the pid before any other call. The focus step runs only when
/// `req.focus` is set, Accessibility is trusted and the executable still matches immediately
/// before the action.
pub fn attach(b: AttachBackend, req: AttachRequest, buf: []u8) AttachResult {
    const path = b.pathFn(b.ptr, req.pid, buf) orelse return .{ .identity = .not_running, .focus_requested = req.focus };
    if (!std.mem.eql(u8, path, req.expected_executable)) {
        return .{ .identity = .mismatch, .actual_path = path, .focus_requested = req.focus };
    }
    var r: AttachResult = .{ .identity = .verified, .actual_path = path, .focus_requested = req.focus };
    var before = b.stateFn(b.ptr, req.pid);
    before.post_event_access = b.postAccess();
    r.before = before;
    if (!req.focus) return r;
    if (!before.trusted) {
        r.focus_skipped = "Accessibility is not trusted for this process";
        return r;
    }
    var again: [4096]u8 = undefined;
    const second = b.pathFn(b.ptr, req.pid, &again);
    if (second == null or !std.mem.eql(u8, second.?, req.expected_executable)) {
        r.identity = .mismatch;
        r.focus_skipped = "the executable changed before the action";
        return r;
    }
    r.focus = b.focusFn(b.ptr, req.pid, before);
    var after = b.stateFn(b.ptr, req.pid);
    after.post_event_access = b.postAccess();
    r.after = after;
    return r;
}

const native = if (@import("builtin").os.tag == .macos) struct {
    const Ref = ?*anyopaque;
    extern "c" fn proc_pidpath(pid: c_int, buffer: ?*anyopaque, size: u32) c_int;
    extern "c" fn AXIsProcessTrusted() u8;
    extern "c" fn CGPreflightPostEventAccess() bool;
    extern "c" fn AXUIElementCreateApplication(pid: c_int) Ref;
    extern "c" fn AXUIElementGetTypeID() usize;
    extern "c" fn AXUIElementSetMessagingTimeout(el: Ref, seconds: f32) i32;
    extern "c" fn AXUIElementCopyAttributeValue(el: Ref, attr: Ref, out: *Ref) i32;
    extern "c" fn AXUIElementSetAttributeValue(el: Ref, attr: Ref, value: Ref) i32;
    extern "c" fn CFStringCreateWithCString(alloc: Ref, s: [*:0]const u8, encoding: u32) Ref;
    extern "c" fn CFRelease(r: Ref) void;
    extern "c" fn CFGetTypeID(r: Ref) usize;
    extern "c" fn CFBooleanGetTypeID() usize;
    extern "c" fn CFBooleanGetValue(r: Ref) u8;
    extern "c" fn CFArrayGetTypeID() usize;
    extern "c" fn CFArrayGetCount(r: Ref) isize;
    extern const kCFBooleanTrue: Ref;
    extern const kCFBooleanFalse: Ref;
    const utf8: u32 = 0x08000100;

    fn attr(name: [*:0]const u8) Ref {
        return CFStringCreateWithCString(null, name, utf8);
    }

    fn readBool(el: Ref, name: [*:0]const u8) ?bool {
        const k = attr(name);
        defer CFRelease(k);
        var v: Ref = null;
        if (AXUIElementCopyAttributeValue(el, k, &v) != 0 or v == null) return null;
        defer CFRelease(v);
        if (CFGetTypeID(v) != CFBooleanGetTypeID()) return null;
        return CFBooleanGetValue(v) != 0;
    }

    fn setBool(el: Ref, name: [*:0]const u8, value: bool) i32 {
        const k = attr(name);
        defer CFRelease(k);
        return AXUIElementSetAttributeValue(el, k, if (value) kCFBooleanTrue else kCFBooleanFalse);
    }

    fn pathImpl(_: *anyopaque, pid: i32, buf: []u8) ?[]const u8 {
        const n = proc_pidpath(pid, buf.ptr, @intCast(buf.len));
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    }

    fn stateImpl(_: *anyopaque, pid: i32) AttachState {
        var st: AttachState = .{ .trusted = AXIsProcessTrusted() != 0 };
        if (!st.trusted) return st;
        const el = AXUIElementCreateApplication(pid);
        if (el == null) return st;
        defer CFRelease(el);
        _ = AXUIElementSetMessagingTimeout(el, 3.0);
        st.hidden = readBool(el, "AXHidden");
        st.frontmost = readBool(el, "AXFrontmost");
        const wk = attr("AXWindows");
        defer CFRelease(wk);
        var wv: Ref = null;
        if (AXUIElementCopyAttributeValue(el, wk, &wv) == 0 and wv != null) {
            defer CFRelease(wv);
            if (CFGetTypeID(wv) == CFArrayGetTypeID()) st.ax_windows = @intCast(CFArrayGetCount(wv));
        }
        const fk = attr("AXFocusedWindow");
        defer CFRelease(fk);
        var fv: Ref = null;
        const fc = AXUIElementCopyAttributeValue(el, fk, &fv);
        st.focused_window = fc == 0 and fv != null;
        if (fv != null) CFRelease(fv);
        return st;
    }

    fn focusImpl(_: *anyopaque, pid: i32, before: AttachState) FocusOutcome {
        const el = AXUIElementCreateApplication(pid);
        if (el == null) return .{ .unhide_code = -1, .front_code = -1 };
        defer CFRelease(el);
        _ = AXUIElementSetMessagingTimeout(el, 3.0);
        var out: FocusOutcome = .{};
        if (before.hidden != false) out.unhide_code = setBool(el, "AXHidden", false);
        out.front_code = setBool(el, "AXFrontmost", true);
        return out;
    }

    var dummy: u8 = 0;

    fn postAccessImpl(_: *anyopaque) PostAccess {
        return if (CGPreflightPostEventAccess()) .granted else .denied;
    }

    fn backend() AttachBackend {
        return .{ .ptr = &dummy, .pathFn = pathImpl, .stateFn = stateImpl, .focusFn = focusImpl, .postAccessFn = postAccessImpl };
    }
} else struct {
    fn backend() ?AttachBackend {
        return null;
    }
};

const AttachArgs = union(enum) { ok: AttachRequest, bad: []const u8 };

fn parseAttachArgs(argv: []const []const u8) AttachArgs {
    var pid: ?i32 = null;
    var exe: ?[]const u8 = null;
    var focus = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--focus")) {
            if (focus) return .{ .bad = "option repeated" };
            focus = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        const is_pid = std.mem.eql(u8, name, "--pid");
        const is_exe = std.mem.eql(u8, name, "--expected-executable");
        if (!is_pid and !is_exe) return .{ .bad = "unknown option" };
        const v: []const u8 = if (eq) |e| arg[e + 1 ..] else blk: {
            if (i + 1 >= argv.len) return .{ .bad = "option needs a value" };
            i += 1;
            break :blk argv[i];
        };
        if (is_pid) {
            if (pid != null) return .{ .bad = "option repeated" };
            pid = std.fmt.parseInt(i32, v, 10) catch return .{ .bad = "--pid is not a number" };
        } else {
            if (exe != null) return .{ .bad = "option repeated" };
            exe = v;
        }
    }
    const p = pid orelse return .{ .bad = "--pid is required" };
    const e = exe orelse return .{ .bad = "--expected-executable is required" };
    if (p <= 1) return .{ .bad = "pid must be greater than 1" };
    if (e.len == 0 or e[0] != '/' or e.len > 1024 or hasControlByte(e)) return .{ .bad = "--expected-executable must be an absolute path without control bytes" };
    return .{ .ok = .{ .pid = p, .expected_executable = e, .focus = focus } };
}

fn stateLine(out: *Io.Writer, key: []const u8, s: AttachState) Io.Writer.Error!void {
    try out.print("{s}\ttrusted={} hidden={?} frontmost={?} ax_windows={?} focused_window={?}\n", .{ key, s.trusted, s.hidden, s.frontmost, s.ax_windows, s.focused_window });
}

fn writeAttach(out: *Io.Writer, req: AttachRequest, r: AttachResult) Io.Writer.Error!void {
    try out.print("pid\t{d}\nexpected_executable\t{s}\nidentity\t{s}\n", .{ req.pid, req.expected_executable, @tagName(r.identity) });
    if (r.actual_path) |p| try out.print("actual_executable\t{s}\n", .{p});
    if (r.before) |s| try stateLine(out, "state_before", s);
    if (r.before) |s| try out.print("post_event_access_before\t{s}\n", .{@tagName(s.post_event_access)});
    try out.print("focus_requested\t{}\n", .{r.focus_requested});
    if (r.focus) |f| {
        if (f.unhide_code) |c| try out.print("unhide_ax_code\t{d}\n", .{c}) else try out.writeAll("unhide_ax_code\tnot_needed\n");
        try out.print("front_ax_code\t{d}\n", .{f.front_code});
    }
    if (r.focus_skipped) |why| try out.print("focus_skipped\t{s}\n", .{why});
    if (r.after) |s| try stateLine(out, "state_after", s);
    if (r.after) |s| try out.print("post_event_access_after\t{s}\n", .{@tagName(s.post_event_access)});
    try out.print("result\t{s}\n", .{if (r.ok()) "ok" else "failed"});
}

/// `vwx ui-attach`. Exit 0 verified and the requested action done, 1 refused or failed, 2 usage.
pub fn runAttachCli(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    _ = gpa;
    _ = io;
    return runAttachWith(argv, out, if (@import("builtin").os.tag == .macos) native.backend() else native.backend());
}

pub fn runAttachWith(argv: []const []const u8, out: *Io.Writer, backend: ?AttachBackend) u8 {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h") or std.mem.eql(u8, argv[0], "help"))) {
        out.writeAll(attach_usage_text) catch {};
        out.flush() catch {};
        return 0;
    }
    const req = switch (parseAttachArgs(argv)) {
        .bad => |why| {
            out.print("error\t{s}\n", .{why}) catch {};
            out.writeAll(attach_usage_text) catch {};
            out.flush() catch {};
            return 2;
        },
        .ok => |r| r,
    };
    const b = backend orelse {
        out.writeAll("error\tui-attach needs macOS\n") catch {};
        out.flush() catch {};
        return 1;
    };
    var buf: [4096]u8 = undefined;
    const res = attach(b, req, &buf);
    writeAttach(out, req, res) catch {};
    out.flush() catch {};
    return if (res.ok()) 0 else 1;
}

const FakeAttach = struct {
    path: ?[]const u8 = "/Apps/Vectorworks",
    /// Path returned from the second pathFn call on.
    later_path: ?[]const u8 = null,
    state: AttachState = .{ .trusted = true, .hidden = true, .frontmost = false, .ax_windows = 0, .focused_window = true },
    focus_out: FocusOutcome = .{},
    path_calls: usize = 0,
    state_calls: usize = 0,
    focus_calls: usize = 0,
    focus_before: ?AttachState = null,
    access: PostAccess = .granted,
    access_calls: usize = 0,

    fn backend(f: *FakeAttach) AttachBackend {
        return .{ .ptr = f, .pathFn = pathFn, .stateFn = stateFn, .focusFn = focusFn, .postAccessFn = accessFn };
    }
    fn accessFn(ptr: *anyopaque) PostAccess {
        const f: *FakeAttach = @ptrCast(@alignCast(ptr));
        f.access_calls += 1;
        return f.access;
    }
    fn pathFn(ptr: *anyopaque, _: i32, buf: []u8) ?[]const u8 {
        const f: *FakeAttach = @ptrCast(@alignCast(ptr));
        f.path_calls += 1;
        const p = (if (f.path_calls > 1 and f.later_path != null) f.later_path else f.path) orelse return null;
        @memcpy(buf[0..p.len], p);
        return buf[0..p.len];
    }
    fn stateFn(ptr: *anyopaque, _: i32) AttachState {
        const f: *FakeAttach = @ptrCast(@alignCast(ptr));
        f.state_calls += 1;
        return f.state;
    }
    fn focusFn(ptr: *anyopaque, _: i32, before: AttachState) FocusOutcome {
        const f: *FakeAttach = @ptrCast(@alignCast(ptr));
        f.focus_calls += 1;
        f.focus_before = before;
        f.state.hidden = false;
        f.state.frontmost = true;
        return f.focus_out;
    }
};

test "ui-attach refuses another executable or a missing process before any state read or action" {
    var buf: [4096]u8 = undefined;
    var f: FakeAttach = .{ .path = "/Apps/Other" };
    const r = attach(f.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .focus = true }, &buf);
    try testing.expectEqual(Identity.mismatch, r.identity);
    try testing.expect(!r.ok());
    try testing.expectEqual(@as(usize, 0), f.state_calls + f.focus_calls);
    f.path = "/Apps/Vectorworks2";
    try testing.expectEqual(Identity.mismatch, attach(f.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .focus = true }, &buf).identity);
    f.path = null;
    const gone = attach(f.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .focus = true }, &buf);
    try testing.expectEqual(Identity.not_running, gone.identity);
    try testing.expectEqual(@as(usize, 0), f.state_calls + f.focus_calls);
}

test "ui-attach reads by default and acts only with --focus" {
    var buf: [4096]u8 = undefined;
    var f: FakeAttach = .{};
    const r = attach(f.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks" }, &buf);
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 1), f.state_calls);
    try testing.expectEqual(@as(usize, 0), f.focus_calls);
    try testing.expect(r.focus == null and r.after == null);
    const g = attach(f.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .focus = true }, &buf);
    try testing.expect(g.ok());
    try testing.expectEqual(@as(usize, 1), f.focus_calls);
    try testing.expectEqual(@as(?bool, true), f.focus_before.?.hidden);
    try testing.expectEqual(@as(?bool, true), g.after.?.frontmost);
}

test "ui-attach reports the post-event permission after the identity check and without acting" {
    var buf: [4096]u8 = undefined;
    const req: AttachRequest = .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks" };
    var other: FakeAttach = .{ .path = "/Apps/Other" };
    _ = attach(other.backend(), req, &buf);
    try testing.expectEqual(@as(usize, 0), other.access_calls);
    for ([_]PostAccess{ .granted, .denied, .unknown, .unavailable }) |v| {
        var f: FakeAttach = .{ .access = v };
        const r = attach(f.backend(), req, &buf);
        try testing.expect(r.ok());
        try testing.expectEqual(v, r.before.?.post_event_access);
        try testing.expectEqual(@as(usize, 1), f.access_calls);
        try testing.expectEqual(@as(usize, 0), f.focus_calls);
    }
    var g: FakeAttach = .{ .access = .denied };
    const fr = attach(g.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .focus = true }, &buf);
    try testing.expectEqual(PostAccess.denied, fr.before.?.post_event_access);
    try testing.expectEqual(PostAccess.denied, fr.after.?.post_event_access);
    // A backend without the seam reads as unknown and the old behavior stays.
    var h: FakeAttach = .{};
    var b = h.backend();
    b.postAccessFn = null;
    try testing.expectEqual(PostAccess.unknown, attach(b, req, &buf).before.?.post_event_access);
}

test "ui-attach output keeps the old keys and adds the permission lines" {
    var f: FakeAttach = .{ .access = .denied };
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const code = runAttachWith(&.{ "--pid", "10012", "--expected-executable", "/Apps/Vectorworks", "--focus" }, &aw.writer, f.backend());
    try testing.expectEqual(@as(u8, 0), code);
    const t = aw.written();
    try testing.expect(std.mem.indexOf(u8, t, "state_before\ttrusted=true hidden=true frontmost=false ax_windows=0 focused_window=true\n") != null);
    try testing.expect(std.mem.indexOf(u8, t, "state_after\ttrusted=true hidden=false frontmost=true") != null);
    try testing.expect(std.mem.indexOf(u8, t, "post_event_access_before\tdenied\n") != null);
    try testing.expect(std.mem.indexOf(u8, t, "post_event_access_after\tdenied\n") != null);
}

test "ui-attach focus failures, untrusted access and a changed executable are reported" {
    var buf: [4096]u8 = undefined;
    const req: AttachRequest = .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .focus = true };
    var f: FakeAttach = .{ .focus_out = .{ .unhide_code = -25205, .front_code = 0 } };
    try testing.expect(!attach(f.backend(), req, &buf).ok());
    var u: FakeAttach = .{ .state = .{ .trusted = false } };
    const ur = attach(u.backend(), req, &buf);
    try testing.expect(!ur.ok());
    try testing.expectEqual(@as(usize, 0), u.focus_calls);
    try testing.expect(ur.focus_skipped != null);
    var c: FakeAttach = .{ .later_path = "/Apps/Reused" };
    const cr = attach(c.backend(), req, &buf);
    try testing.expectEqual(Identity.mismatch, cr.identity);
    try testing.expectEqual(@as(usize, 0), c.focus_calls);
}

test "ui-attach arguments have no launch, quit, terminate or reopen route" {
    var f: FakeAttach = .{};
    var w_buf: [4096]u8 = undefined;
    const bad = [_][]const []const u8{
        &.{},
        &.{ "--pid", "10012" },
        &.{ "--expected-executable", "/Apps/Vectorworks" },
        &.{ "--pid", "1", "--expected-executable", "/Apps/Vectorworks" },
        &.{ "--pid", "x", "--expected-executable", "/Apps/Vectorworks" },
        &.{ "--pid", "5", "--expected-executable", "relative" },
        &.{ "--pid", "5", "--expected-executable", "/Apps/V", "--launch" },
        &.{ "--pid", "5", "--expected-executable", "/Apps/V", "--quit" },
        &.{ "--pid", "5", "--expected-executable", "/Apps/V", "--terminate" },
        &.{ "--pid", "5", "--expected-executable", "/Apps/V", "--reopen" },
        &.{ "--pid", "5", "--expected-executable", "/Apps/V", "--focus", "--focus" },
        &.{ "--pid", "5", "--pid", "6", "--expected-executable", "/Apps/V" },
    };
    for (bad) |argv| {
        var w: Io.Writer = .fixed(&w_buf);
        try testing.expectEqual(@as(u8, 2), runAttachWith(argv, &w, f.backend()));
    }
    try testing.expectEqual(@as(usize, 0), f.path_calls);
    var w: Io.Writer = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 0), runAttachWith(&.{ "--pid", "10012", "--expected-executable=/Apps/Vectorworks", "--focus" }, &w, f.backend()));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "identity\tverified\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "front_ax_code\t0\n") != null);
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "result\tok\n"));
    f.path = "/Apps/Other";
    var w2: Io.Writer = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 1), runAttachWith(&.{ "--pid", "10012", "--expected-executable", "/Apps/Vectorworks" }, &w2, f.backend()));
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "identity\tmismatch\n") != null);
}

// ui-dialog

pub const dialog_usage_text =
    \\usage: vwx ui-dialog --pid N --expected-executable ABSOLUTE_PATH [--timeout-ms N]
    \\                     [--expected-text TEXT --press BUTTON_LABEL]
    \\       vwx ui-dialog --pid N --expected-executable ABSOLUTE_PATH [--window-title TITLE]
    \\                     (--read-field ID | --read-enabled ID | --read-popup ID)...
    \\
    \\--read-* prints one attribute of the control whose AXIdentifier is ID and prints no tree.
    \\--read-field reads AXValue of an AXTextField or AXComboBox. --read-enabled reads AXEnabled.
    \\--read-popup reads AXValue of an AXPopUpButton. Up to 4 --read-* options share one descent.
    \\--window-title selects the one window with exact AXTitle TITLE among AXFocusedWindow,
    \\AXMainWindow and AXWindows. The descent reads AXRole, AXIdentifier and AXChildren of each
    \\element in one AXUIElementCopyMultipleAttributeValues request. It skips the children of
    \\AXBrowser, AXOutline, AXTable and AXList, so file listing rows cost no request. Each target
    \\then costs one AXUIElementCopyAttributeValue request. Output lines:
    \\  lookup<TAB>status=S<TAB>visited=N<TAB>pruned=N<TAB>ax_calls=N<TAB>reason
    \\  read<TAB>field|enabled|popup<TAB>ID<TAB>read|missing|duplicate|wrong_role|read_failed<TAB>
    \\      matches<TAB>role<TAB>value
    \\status window_absent means no window has TITLE, or two windows have it. Exit 0 when every
    \\target reads, 1 otherwise.
    \\
    \\Reads the focused (else main) Accessibility window of process N after an exact proc_pidpath
    \\check. Prints a bounded control tree, the notice text and the button labels. A node line ends
    \\with enabled, AXIdentifier, the AXValue kind (string, number or boolean) and the AXMinValue and
    \\AXMaxValue of a numeric value. Checkbox and progress values print as true, false or a number.
    \\owner_ax (AXUIElementGetPid) and owner_cg (kCGWindowOwnerPID of the system window with the
    \\selected window's AXWindowNumber) report the process that owns the selected window, each from
    \\its own source. They are evidence only and nothing is posted to that process.
    \\Without --press
    \\the command reads only. With --expected-text and --press it presses one AXButton through
    \\AXPress when the window is modal, the joined static text equals TEXT after whitespace
    \\normalization of both texts, and exactly one enabled button has the exact label. The checks run
    \\twice, the second time immediately before the press. The command has no key, coordinate,
    \\menu, launch, quit or close route. Exit 0 read or pressed, 1 refused or failed, 2 usage.
    \\
;

pub const DialogSource = enum { focused, main, only_window };

pub const DNode = struct {
    depth: u8,
    role: []const u8 = "",
    subrole: []const u8 = "",
    title: []const u8 = "",
    value: []const u8 = "",
    description: []const u8 = "",
    enabled: ?bool = null,
    /// AXIdentifier.
    identifier: []const u8 = "",
    /// Kind of AXValue: "string", "number", "boolean" or "" when absent or of another type.
    value_type: []const u8 = "",
    /// AXMinValue and AXMaxValue of a numeric value, as text. Empty when absent.
    min_value: []const u8 = "",
    max_value: []const u8 = "",
};

pub const OwnerState = enum { not_read, read, failed, no_window_number, no_match, ambiguous };

/// Evidence of the process that owns the selected window, from one named source. It is evidence
/// only. Nothing is posted to this process.
pub const OwnerPid = struct {
    state: OwnerState = .not_read,
    pid: i32 = 0,
    /// Accessibility result code when the state is `failed`.
    code: i32 = 0,
    window_number: ?u32 = null,
};

/// The owner pid of the single system window entry with this number. Other entries are not
/// reported.
pub fn cgOwner(entries: []const CgEntry, number: ?u32) OwnerPid {
    const n = number orelse return .{ .state = .no_window_number };
    var out: OwnerPid = .{ .state = .no_match, .window_number = n };
    for (entries) |e| {
        if (e.number != n) continue;
        if (out.state != .no_match) return .{ .state = .ambiguous, .window_number = n };
        const pid = std.math.cast(i32, e.pid) orelse return .{ .state = .failed, .window_number = n };
        out = .{ .state = .read, .pid = pid, .window_number = n };
    }
    return out;
}

pub const DialogWindow = struct {
    source: DialogSource,
    modal: ?bool = null,
    title: []const u8 = "",
    nodes: []const DNode = &.{},
    truncated: bool = false,
    timed_out: bool = false,
    /// AXUIElementGetPid of the selected window.
    owner_ax: OwnerPid = .{},
    /// kCGWindowOwnerPID of the system window that has the AXWindowNumber of the selected window.
    owner_cg: OwnerPid = .{},
};

pub const DialogRead = union(enum) { window: DialogWindow, failed: []const u8 };

pub const DialogLimits = struct {
    max_nodes: usize = 200,
    max_depth: u8 = 8,
    max_field: usize = 1024,
    /// Monotonic deadline of the traversal in the clock of the backend.
    deadline_ns: u64 = 0,
};

pub const PressStatus = enum { pressed, no_window, not_modal, button_missing, button_duplicate, button_disabled, ax_error };

pub const PressOutcome = struct { status: PressStatus, code: i32 = 0 };

pub const DialogBackend = struct {
    ptr: *anyopaque,
    pathFn: *const fn (ptr: *anyopaque, pid: i32, buf: []u8) ?[]const u8,
    /// Reads the window. Strings are allocated in `a`.
    readFn: *const fn (ptr: *anyopaque, a: Allocator, pid: i32, lim: DialogLimits) DialogRead,
    /// Resolves the same window again, requires a modal window and exactly one enabled AXButton
    /// with this exact title, and performs AXPress on it.
    pressFn: *const fn (ptr: *anyopaque, pid: i32, label: []const u8, lim: DialogLimits) PressOutcome,
    /// Selects the window, finds each target by AXIdentifier and reads one attribute of each.
    lookupFn: *const fn (ptr: *anyopaque, a: Allocator, pid: i32, title: ?[]const u8, targets: []const ReadTarget, lim: DialogLimits) Lookup,
    nowFn: *const fn (ptr: *anyopaque) u64,
};

/// `--read-field` reads AXValue of an AXTextField or AXComboBox. `--read-enabled` reads AXEnabled
/// of any role. `--read-popup` reads AXValue of an AXPopUpButton, which is the title of its
/// selected item.
pub const ReadKind = enum { field, enabled, popup };

pub const ReadTarget = struct { kind: ReadKind, id: []const u8 };

pub const max_targets = 4;

/// The lookup descent skips the children of these roles. A save panel file listing is an
/// AXBrowser, AXOutline, AXTable or AXList, and its rows are most of the panel nodes.
pub const pruned_roles = [_][]const u8{ "AXBrowser", "AXOutline", "AXTable", "AXList" };

pub fn prunedRole(role: []const u8) bool {
    for (pruned_roles) |r| if (std.mem.eql(u8, r, role)) return true;
    return false;
}

pub fn roleFits(kind: ReadKind, role: []const u8) bool {
    return switch (kind) {
        .field => std.mem.eql(u8, role, "AXTextField") or std.mem.eql(u8, role, "AXComboBox"),
        .enabled => true,
        .popup => std.mem.eql(u8, role, "AXPopUpButton"),
    };
}

pub const TargetStatus = enum { read, missing, duplicate, wrong_role, read_failed };

pub const TargetResult = struct {
    status: TargetStatus = .missing,
    role: []const u8 = "",
    value: []const u8 = "",
    /// Elements outside pruned subtrees that carry the identifier.
    matches: usize = 0,
};

pub const LookupStatus = enum { read, no_window, window_absent, window_duplicate, incomplete };

pub const Lookup = struct {
    status: LookupStatus,
    why: []const u8 = "",
    title: []const u8 = "",
    results: [max_targets]TargetResult = @splat(.{}),
    /// Elements whose role, identifier and children were read.
    visited: usize = 0,
    /// Elements whose children were skipped because of `pruned_roles`.
    pruned: usize = 0,
    /// Accessibility attribute requests sent to the process, window selection included.
    ax_calls: usize = 0,
};

pub const DialogRequest = struct {
    pid: i32,
    expected_executable: []const u8,
    timeout_ms: u32 = 5000,
    expected_text: ?[]const u8 = null,
    press: ?[]const u8 = null,
    /// Exact AXTitle of the window for `--read-*`. Null uses the focused, main or only window.
    window_title: ?[]const u8 = null,
    targets: [max_targets]ReadTarget = undefined,
    targets_n: usize = 0,
};

pub const DialogStatus = enum {
    read,
    pressed,
    not_running,
    identity_mismatch,
    read_failed,
    refused_not_modal,
    refused_text_changed,
    refused_button_missing,
    refused_button_duplicate,
    refused_button_disabled,
    refused_identity_changed,
    press_failed,
    window_absent,
    target_failed,
};

pub const DialogReport = struct {
    status: DialogStatus,
    actual_path: ?[]const u8 = null,
    window: ?DialogWindow = null,
    message: []const u8 = "",
    press: ?PressOutcome = null,
    after: ?DialogRead = null,
    after_message: []const u8 = "",
    read_failure: ?[]const u8 = null,
    lookup: ?Lookup = null,

    pub fn ok(r: DialogReport) bool {
        return r.status == .read or r.status == .pressed;
    }
};

/// Collapses runs of ASCII whitespace to one space and trims both ends.
pub fn normalizeWhitespace(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending = false;
    for (s) |b| {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
            pending = out.items.len > 0;
            continue;
        }
        if (pending) try out.append(a, ' ');
        pending = false;
        try out.append(a, b);
    }
    return out.items;
}

/// Static text values of the window joined by one space.
fn dialogMessage(a: Allocator, w: DialogWindow) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (w.nodes) |n| {
        if (!std.mem.eql(u8, n.role, "AXStaticText") or n.value.len == 0) continue;
        if (!first) try out.append(a, ' ');
        first = false;
        try out.appendSlice(a, n.value);
    }
    return out.items;
}

const Gate = union(enum) { go, refuse: DialogStatus };

fn gate(w: DialogWindow, message: []const u8, expected_norm: []const u8, label: []const u8) Gate {
    if (w.modal != true) return .{ .refuse = .refused_not_modal };
    if (!std.mem.eql(u8, expected_norm, message)) return .{ .refuse = .refused_text_changed };
    var count: usize = 0;
    var enabled = false;
    for (w.nodes) |n| {
        if (std.mem.eql(u8, n.role, "AXButton") and std.mem.eql(u8, n.title, label)) {
            count += 1;
            enabled = n.enabled == true;
        }
    }
    if (count == 0) return .{ .refuse = .refused_button_missing };
    if (count > 1) return .{ .refuse = .refused_button_duplicate };
    if (!enabled) return .{ .refuse = .refused_button_disabled };
    return .go;
}

pub fn dialog(a: Allocator, b: DialogBackend, req: DialogRequest, buf: []u8) Allocator.Error!DialogReport {
    const path = b.pathFn(b.ptr, req.pid, buf) orelse return .{ .status = .not_running };
    if (!std.mem.eql(u8, path, req.expected_executable)) return .{ .status = .identity_mismatch, .actual_path = path };
    var lim: DialogLimits = .{};
    const budget_ns = @as(u64, req.timeout_ms) * std.time.ns_per_ms;
    lim.deadline_ns = b.nowFn(b.ptr) + budget_ns;
    var rep: DialogReport = .{ .status = .read, .actual_path = path };
    if (req.targets_n > 0) {
        const targets = req.targets[0..req.targets_n];
        const lk = b.lookupFn(b.ptr, a, req.pid, req.window_title, targets, lim);
        rep.lookup = lk;
        rep.status = switch (lk.status) {
            .read => .read,
            .no_window, .window_absent, .window_duplicate => .window_absent,
            .incomplete => .target_failed,
        };
        if (rep.status == .read) {
            for (lk.results[0..targets.len]) |r| if (r.status != .read) {
                rep.status = .target_failed;
            };
        }
        return rep;
    }
    const first = switch (b.readFn(b.ptr, a, req.pid, lim)) {
        .failed => |why| return .{ .status = .read_failed, .actual_path = path, .read_failure = why },
        .window => |w| w,
    };
    rep.window = first;
    rep.message = try dialogMessage(a, first);
    const label = req.press orelse return rep;
    const expected_norm = try normalizeWhitespace(a, req.expected_text orelse "");
    switch (gate(first, try normalizeWhitespace(a, rep.message), expected_norm, label)) {
        .refuse => |s| {
            rep.status = s;
            return rep;
        },
        .go => {},
    }
    // Second check immediately before the press.
    var again: [4096]u8 = undefined;
    const p2 = b.pathFn(b.ptr, req.pid, &again);
    if (p2 == null or !std.mem.eql(u8, p2.?, req.expected_executable)) {
        rep.status = .refused_identity_changed;
        return rep;
    }
    lim.deadline_ns = b.nowFn(b.ptr) + budget_ns;
    const second = switch (b.readFn(b.ptr, a, req.pid, lim)) {
        .failed => |why| {
            rep.status = .read_failed;
            rep.read_failure = why;
            return rep;
        },
        .window => |w| w,
    };
    rep.window = second;
    rep.message = try dialogMessage(a, second);
    switch (gate(second, try normalizeWhitespace(a, rep.message), expected_norm, label)) {
        .refuse => |s| {
            rep.status = s;
            return rep;
        },
        .go => {},
    }
    lim.deadline_ns = b.nowFn(b.ptr) + budget_ns;
    const out = b.pressFn(b.ptr, req.pid, label, lim);
    rep.press = out;
    rep.status = if (out.status == .pressed) .pressed else .press_failed;
    // Observation after the press. A failed read here does not change the press result.
    lim.deadline_ns = b.nowFn(b.ptr) + budget_ns;
    rep.after = b.readFn(b.ptr, a, req.pid, lim);
    if (rep.after.? == .window) rep.after_message = try dialogMessage(a, rep.after.?.window);
    return rep;
}

const native_dialog = if (@import("builtin").os.tag == .macos) struct {
    const Ref = native.Ref;
    extern "c" fn CFRetain(r: Ref) Ref;
    extern "c" fn CFStringGetTypeID() usize;
    extern "c" fn CFStringGetCString(s: Ref, buf: [*]u8, size: isize, encoding: u32) u8;
    extern "c" fn CFArrayGetValueAtIndex(arr: Ref, idx: isize) Ref;
    extern "c" fn AXUIElementGetPid(el: Ref, pid: *c_int) i32;
    extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) Ref;
    extern "c" fn CFDictionaryGetValue(d: Ref, key: Ref) Ref;
    extern "c" fn CFNumberGetTypeID() usize;
    extern "c" fn CFNumberIsFloatType(n: Ref) u8;
    extern "c" fn CFNumberGetValue(n: Ref, kind: i32, out: *anyopaque) u8;
    extern "c" fn AXUIElementPerformAction(el: Ref, action: Ref) i32;

    pub const Dlg = struct {
        env: nur.Env,

        pub fn backend(d: *Dlg) DialogBackend {
            return .{ .ptr = d, .pathFn = pathFn, .readFn = readFn, .pressFn = pressFn, .lookupFn = lookupFn, .nowFn = nowFn };
        }
    };

    fn pathFn(_: *anyopaque, pid: i32, buf: []u8) ?[]const u8 {
        return native.pathImpl(undefined, pid, buf);
    }

    fn nowFn(ptr: *anyopaque) u64 {
        const d: *Dlg = @ptrCast(@alignCast(ptr));
        return d.env.now();
    }

    const AttrRead = union(enum) { value: Ref, absent, failed };

    /// Like `copyAttr`, but tells "no value" from a failed read. A value is retained.
    fn copyAttrStatus(el: Ref, name: [*:0]const u8) AttrRead {
        const k = native.attr(name);
        defer native.CFRelease(k);
        var v: Ref = null;
        const code = native.AXUIElementCopyAttributeValue(el, k, &v);
        if (code != 0 and v != null) native.CFRelease(v);
        return switch (slotOf(code, v != null)) {
            .present => .{ .value = v },
            .absent => .absent,
            else => .failed,
        };
    }

    const FlagRead = union(enum) { value: bool, absent, failed };

    fn readFlagStatus(el: Ref, name: [*:0]const u8) FlagRead {
        switch (copyAttrStatus(el, name)) {
            .absent => return .absent,
            .failed => return .failed,
            .value => |v| {
                defer native.CFRelease(v);
                if (native.CFGetTypeID(v) != native.CFBooleanGetTypeID()) return .failed;
                return .{ .value = native.CFBooleanGetValue(v) != 0 };
            },
        }
    }

    fn copyAttr(el: Ref, name: [*:0]const u8) Ref {
        const k = native.attr(name);
        defer native.CFRelease(k);
        var v: Ref = null;
        if (native.AXUIElementCopyAttributeValue(el, k, &v) != 0) return null;
        return v;
    }

    fn readStringOf(a: Allocator, v: Ref, max: usize) []const u8 {
        var tmp: [4096]u8 = undefined;
        if (CFStringGetCString(v, &tmp, tmp.len, native.utf8) == 0) return "";
        const s = std.mem.sliceTo(&tmp, 0);
        return a.dupe(u8, s[0..@min(s.len, max)]) catch "";
    }

    fn readString(a: Allocator, el: Ref, name: [*:0]const u8, max: usize) []const u8 {
        const v = copyAttr(el, name);
        if (v == null) return "";
        defer native.CFRelease(v);
        if (native.CFGetTypeID(v) != CFStringGetTypeID()) return "";
        return readStringOf(a, v, max);
    }

    const Scalar = struct { text: []const u8 = "", kind: []const u8 = "" };

    /// Text and kind of a string, number or boolean attribute. Numbers print as integers or as the
    /// shortest decimal of a finite double. Other types and a missing attribute give an empty result.
    fn readScalar(a: Allocator, el: Ref, name: [*:0]const u8, max: usize) Scalar {
        const v = copyAttr(el, name);
        if (v == null) return .{};
        defer native.CFRelease(v);
        const t = native.CFGetTypeID(v);
        if (t == CFStringGetTypeID()) return .{ .text = readStringOf(a, v, max), .kind = "string" };
        if (t == native.CFBooleanGetTypeID()) {
            return .{ .text = if (native.CFBooleanGetValue(v) != 0) "true" else "false", .kind = "boolean" };
        }
        if (t == CFNumberGetTypeID()) {
            if (CFNumberIsFloatType(v) != 0) {
                var d: f64 = 0;
                if (CFNumberGetValue(v, 6, &d) == 0 or !std.math.isFinite(d)) return .{ .kind = "number" };
                return .{ .text = std.fmt.allocPrint(a, "{d}", .{d}) catch "", .kind = "number" };
            }
            var n: i64 = 0;
            if (CFNumberGetValue(v, 4, &n) == 0) return .{ .kind = "number" };
            return .{ .text = std.fmt.allocPrint(a, "{d}", .{n}) catch "", .kind = "number" };
        }
        return .{};
    }

    fn readFlag(el: Ref, name: [*:0]const u8) ?bool {
        return native.readBool(el, name);
    }

    const Pick = struct { el: Ref, source: DialogSource };

    /// Focused window, else main window, else the only entry of AXWindows. AXWindows can be empty
    /// while the other two exist. The returned element is retained.
    fn pick(app: Ref) ?Pick {
        const f = copyAttr(app, "AXFocusedWindow");
        if (f != null) return .{ .el = f, .source = .focused };
        const m = copyAttr(app, "AXMainWindow");
        if (m != null) return .{ .el = m, .source = .main };
        const ws = copyAttr(app, "AXWindows");
        if (ws == null) return null;
        defer native.CFRelease(ws);
        if (native.CFGetTypeID(ws) != native.CFArrayGetTypeID() or native.CFArrayGetCount(ws) != 1) return null;
        const only = CFArrayGetValueAtIndex(ws, 0);
        if (only == null) return null;
        return .{ .el = CFRetain(only), .source = .only_window };
    }

    const Walk = struct {
        a: Allocator,
        env: nur.Env,
        lim: DialogLimits,
        nodes: std.ArrayList(DNode) = .empty,
        truncated: bool = false,
        timed_out: bool = false,
        /// Press mode. Retained matching buttons.
        want: ?[]const u8 = null,
        found: [4]Ref = .{ null, null, null, null },
        found_n: usize = 0,
        found_enabled: [4]bool = .{ false, false, false, false },
        found_total: usize = 0,

        fn visit(w: *Walk, el: Ref, depth: u8) void {
            if (w.timed_out) return;
            if (w.env.now() >= w.lim.deadline_ns) {
                w.timed_out = true;
                w.truncated = true;
                return;
            }
            if (w.nodes.items.len >= w.lim.max_nodes) {
                w.truncated = true;
                return;
            }
            const f = w.lim.max_field;
            const val = readScalar(w.a, el, "AXValue", f);
            const numeric = std.mem.eql(u8, val.kind, "number");
            const n: DNode = .{
                .depth = depth,
                .role = readString(w.a, el, "AXRole", f),
                .subrole = readString(w.a, el, "AXSubrole", f),
                .title = readString(w.a, el, "AXTitle", f),
                .value = val.text,
                .description = readString(w.a, el, "AXDescription", f),
                .enabled = readFlag(el, "AXEnabled"),
                .identifier = readString(w.a, el, "AXIdentifier", f),
                .value_type = val.kind,
                .min_value = if (numeric) readScalar(w.a, el, "AXMinValue", f).text else "",
                .max_value = if (numeric) readScalar(w.a, el, "AXMaxValue", f).text else "",
            };
            w.nodes.append(w.a, n) catch {
                w.truncated = true;
                return;
            };
            if (w.want) |label| {
                if (std.mem.eql(u8, n.role, "AXButton") and std.mem.eql(u8, n.title, label)) {
                    w.found_total += 1;
                    if (w.found_n < w.found.len) {
                        w.found[w.found_n] = CFRetain(el);
                        w.found_enabled[w.found_n] = n.enabled == true;
                        w.found_n += 1;
                    }
                }
            }
            const kids = copyAttr(el, "AXChildren");
            if (kids == null) return;
            defer native.CFRelease(kids);
            if (native.CFGetTypeID(kids) != native.CFArrayGetTypeID()) return;
            const count = native.CFArrayGetCount(kids);
            if (count > 0 and depth >= w.lim.max_depth) {
                w.truncated = true;
                return;
            }
            var i: isize = 0;
            while (i < count) : (i += 1) {
                const child = CFArrayGetValueAtIndex(kids, i);
                if (child == null) continue;
                w.visit(child, depth + 1);
                if (w.timed_out) return;
            }
        }

        fn releaseFound(w: *Walk) void {
            for (w.found[0..w.found_n]) |r| native.CFRelease(r);
            w.found_n = 0;
        }
    };

    fn readFn(ptr: *anyopaque, a: Allocator, pid: i32, lim: DialogLimits) DialogRead {
        const d: *Dlg = @ptrCast(@alignCast(ptr));
        if (native.AXIsProcessTrusted() == 0) return .{ .failed = "Accessibility is not trusted for this process" };
        const app = native.AXUIElementCreateApplication(pid);
        if (app == null) return .{ .failed = "no Accessibility application element" };
        defer native.CFRelease(app);
        _ = native.AXUIElementSetMessagingTimeout(app, 2.0);
        const p = pick(app) orelse return .{ .failed = "no focused window, main window or single AXWindows entry" };
        defer native.CFRelease(p.el);
        var w: Walk = .{ .a = a, .env = d.env, .lim = lim };
        w.visit(p.el, 0);
        return .{ .window = .{
            .source = p.source,
            .modal = readFlag(p.el, "AXModal"),
            .title = readString(a, p.el, "AXTitle", lim.max_field),
            .nodes = w.nodes.items,
            .truncated = w.truncated,
            .timed_out = w.timed_out,
            .owner_ax = ownerAx(p.el),
            .owner_cg = ownerCg(a, p.el),
        } };
    }

    fn ownerAx(el: Ref) OwnerPid {
        var pid: c_int = 0;
        const code = AXUIElementGetPid(el, &pid);
        if (code != 0) return .{ .state = .failed, .code = code };
        return .{ .state = .read, .pid = pid };
    }

    fn numberVal(v: Ref) ?i64 {
        if (v == null or native.CFGetTypeID(v) != CFNumberGetTypeID()) return null;
        var n: i64 = 0;
        if (CFNumberGetValue(v, 4, &n) == 0) return null;
        return n;
    }

    /// Correlates by window number only. The list is read once and only the number and owner pid of
    /// each entry are kept, never names or bounds.
    fn ownerCg(a: Allocator, el: Ref) OwnerPid {
        const num = readScalar(a, el, "AXWindowNumber", 32);
        var number: ?u32 = null;
        if (std.mem.eql(u8, num.kind, "number")) {
            if (std.fmt.parseInt(u32, num.text, 10)) |v| number = if (v == 0) null else v else |_| {}
        }
        if (number == null) return cgOwner(&.{}, null);
        const list = CGWindowListCopyWindowInfo(0, 0);
        if (list == null) return .{ .state = .failed, .window_number = number };
        defer native.CFRelease(list);
        if (native.CFGetTypeID(list) != native.CFArrayGetTypeID()) return .{ .state = .failed, .window_number = number };
        const k_pid = native.attr("kCGWindowOwnerPID");
        defer native.CFRelease(k_pid);
        const k_num = native.attr("kCGWindowNumber");
        defer native.CFRelease(k_num);
        var entries: std.ArrayList(CgEntry) = .empty;
        const count = native.CFArrayGetCount(list);
        var i: isize = 0;
        while (i < count) : (i += 1) {
            const d = CFArrayGetValueAtIndex(list, i);
            if (d == null) continue;
            const wn = numberVal(CFDictionaryGetValue(d, k_num)) orelse continue;
            if (wn != number.?) continue;
            const p = numberVal(CFDictionaryGetValue(d, k_pid)) orelse return .{ .state = .failed, .window_number = number };
            entries.append(a, .{ .pid = p, .name = null, .number = number.? }) catch return .{ .state = .failed, .window_number = number };
        }
        return cgOwner(entries.items, number);
    }

    fn pressFn(ptr: *anyopaque, pid: i32, label: []const u8, lim: DialogLimits) PressOutcome {
        const d: *Dlg = @ptrCast(@alignCast(ptr));
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const app = native.AXUIElementCreateApplication(pid);
        if (app == null) return .{ .status = .no_window };
        defer native.CFRelease(app);
        _ = native.AXUIElementSetMessagingTimeout(app, 2.0);
        const p = pick(app) orelse return .{ .status = .no_window };
        defer native.CFRelease(p.el);
        if (readFlag(p.el, "AXModal") != true) return .{ .status = .not_modal };
        var w: Walk = .{ .a = arena.allocator(), .env = d.env, .lim = lim, .want = label };
        defer w.releaseFound();
        w.visit(p.el, 0);
        if (w.found_total == 0) return .{ .status = .button_missing };
        if (w.found_total > 1) return .{ .status = .button_duplicate };
        if (!w.found_enabled[0]) return .{ .status = .button_disabled };
        const act = native.attr("AXPress");
        defer native.CFRelease(act);
        const code = AXUIElementPerformAction(w.found[0], act);
        return .{ .status = if (code == 0) .pressed else .ax_error, .code = code };
    }

    extern "c" fn CFEqual(x: Ref, y: Ref) u8;
    extern "c" fn CFArrayCreate(alloc: Ref, values: [*]const Ref, n: isize, callbacks: ?*const anyopaque) Ref;
    extern "c" fn AXUIElementCopyMultipleAttributeValues(el: Ref, attrs: Ref, options: u32, out: *Ref) i32;
    extern const kCFTypeArrayCallBacks: u8;

    const lookup_max_nodes = 2000;
    const lookup_max_depth = 30;

    fn countedAttr(lk: *Lookup, el: Ref, name: [*:0]const u8) Ref {
        lk.ax_calls += 1;
        return copyAttr(el, name);
    }

    fn stringAt(a: Allocator, arr: Ref, i: isize) []const u8 {
        const v = CFArrayGetValueAtIndex(arr, i);
        if (v == null or native.CFGetTypeID(v) != CFStringGetTypeID()) return "";
        return readStringOf(a, v, 256);
    }

    /// The one window titled `title` among AXFocusedWindow, AXMainWindow and AXWindows, or the
    /// `pick` window when `title` is null. The returned element is retained.
    fn lookupWindow(a: Allocator, app: Ref, title: ?[]const u8, lk: *Lookup) ?Ref {
        const want = title orelse {
            const p = pick(app) orelse {
                lk.ax_calls += 3;
                lk.status = .no_window;
                lk.why = "no focused window, main window or single AXWindows entry";
                return null;
            };
            lk.ax_calls += @as(usize, @intFromEnum(p.source)) + 1;
            lk.title = readString(a, p.el, "AXTitle", 1024);
            lk.ax_calls += 1;
            return p.el;
        };
        var seen: [64]Ref = undefined;
        var seen_n: usize = 0;
        const focused = countedAttr(lk, app, "AXFocusedWindow");
        if (focused != null) {
            seen[seen_n] = focused;
            seen_n += 1;
        }
        const main = countedAttr(lk, app, "AXMainWindow");
        if (main != null) {
            seen[seen_n] = main;
            seen_n += 1;
        }
        const ws = countedAttr(lk, app, "AXWindows");
        defer if (ws != null) native.CFRelease(ws);
        if (ws != null and native.CFGetTypeID(ws) == native.CFArrayGetTypeID()) {
            var i: isize = 0;
            while (i < native.CFArrayGetCount(ws) and seen_n < seen.len) : (i += 1) {
                const w = CFArrayGetValueAtIndex(ws, i);
                if (w != null) {
                    seen[seen_n] = CFRetain(w);
                    seen_n += 1;
                }
            }
        }
        var hit: Ref = null;
        var hits: usize = 0;
        for (seen[0..seen_n], 0..) |w, i| {
            var dup = false;
            for (seen[0..i]) |earlier| dup = dup or CFEqual(earlier, w) != 0;
            if (dup) continue;
            lk.ax_calls += 1;
            if (!std.mem.eql(u8, readString(a, w, "AXTitle", 1024), want)) continue;
            hits += 1;
            if (hit == null) hit = CFRetain(w);
        }
        for (seen[0..seen_n]) |w| native.CFRelease(w);
        if (hits == 1) {
            lk.title = want;
            return hit;
        }
        if (hit != null) native.CFRelease(hit);
        lk.status = if (hits == 0) .window_absent else .window_duplicate;
        lk.why = if (hits == 0) "no window has this exact title" else "more than one window has this exact title";
        return null;
    }

    const Descent = struct {
        a: Allocator,
        env: nur.Env,
        lim: DialogLimits,
        /// CFArray of AXRole, AXIdentifier and AXChildren.
        keys: Ref,
        targets: []const ReadTarget,
        found: [max_targets]Ref = @splat(null),
        lk: *Lookup,

        fn visit(s: *Descent, el: Ref, depth: u8) void {
            if (s.lk.status == .incomplete) return;
            if (s.env.now() >= s.lim.deadline_ns or s.lk.visited >= lookup_max_nodes) {
                s.lk.status = .incomplete;
                s.lk.why = if (s.lk.visited >= lookup_max_nodes) "node limit reached" else "deadline passed";
                return;
            }
            s.lk.visited += 1;
            s.lk.ax_calls += 1;
            var vals: Ref = null;
            const code = AXUIElementCopyMultipleAttributeValues(el, s.keys, 0, &vals);
            if (vals == null) return;
            defer native.CFRelease(vals);
            if (code != 0 or native.CFGetTypeID(vals) != native.CFArrayGetTypeID() or native.CFArrayGetCount(vals) != 3) return;
            const role = stringAt(s.a, vals, 0);
            const ident = stringAt(s.a, vals, 1);
            for (s.targets, 0..) |t, i| {
                if (ident.len == 0 or !std.mem.eql(u8, t.id, ident)) continue;
                const r = &s.lk.results[i];
                r.matches += 1;
                if (r.matches == 1) {
                    r.role = role;
                    s.found[i] = CFRetain(el);
                }
            }
            if (prunedRole(role)) {
                s.lk.pruned += 1;
                return;
            }
            if (depth >= lookup_max_depth) return;
            const kids = CFArrayGetValueAtIndex(vals, 2);
            if (kids == null or native.CFGetTypeID(kids) != native.CFArrayGetTypeID()) return;
            var i: isize = 0;
            while (i < native.CFArrayGetCount(kids)) : (i += 1) {
                const child = CFArrayGetValueAtIndex(kids, i);
                if (child != null) s.visit(child, depth + 1);
            }
        }
    };

    fn lookupFn(ptr: *anyopaque, a: Allocator, pid: i32, title: ?[]const u8, targets: []const ReadTarget, lim: DialogLimits) Lookup {
        const d: *Dlg = @ptrCast(@alignCast(ptr));
        var lk: Lookup = .{ .status = .read };
        if (native.AXIsProcessTrusted() == 0) return .{ .status = .no_window, .why = "Accessibility is not trusted for this process" };
        const app = native.AXUIElementCreateApplication(pid);
        if (app == null) return .{ .status = .no_window, .why = "no Accessibility application element" };
        defer native.CFRelease(app);
        _ = native.AXUIElementSetMessagingTimeout(app, 2.0);
        const win = lookupWindow(a, app, title, &lk) orelse return lk;
        defer native.CFRelease(win);
        const names = [_]Ref{ native.attr("AXRole"), native.attr("AXIdentifier"), native.attr("AXChildren") };
        defer for (names) |n| native.CFRelease(n);
        const keys = CFArrayCreate(null, &names, names.len, &kCFTypeArrayCallBacks);
        if (keys == null) return .{ .status = .no_window, .why = "CFArrayCreate failed" };
        defer native.CFRelease(keys);
        var s: Descent = .{ .a = a, .env = d.env, .lim = lim, .keys = keys, .targets = targets, .lk = &lk };
        defer for (s.found) |r| if (r != null) native.CFRelease(r);
        s.visit(win, 0);
        if (lk.status != .read) return lk;
        for (targets, 0..) |t, i| {
            const r = &lk.results[i];
            if (r.matches == 0) continue;
            if (r.matches > 1) {
                r.status = .duplicate;
                continue;
            }
            if (!roleFits(t.kind, r.role)) {
                r.status = .wrong_role;
                continue;
            }
            lk.ax_calls += 1;
            switch (copyAttrStatus(s.found[i], if (t.kind == .enabled) "AXEnabled" else "AXValue")) {
                .absent, .failed => r.status = .read_failed,
                .value => |v| {
                    defer native.CFRelease(v);
                    const tid = native.CFGetTypeID(v);
                    if (t.kind == .enabled and tid == native.CFBooleanGetTypeID()) {
                        r.value = if (native.CFBooleanGetValue(v) != 0) "true" else "false";
                        r.status = .read;
                    } else if (t.kind != .enabled and tid == CFStringGetTypeID()) {
                        r.value = readStringOf(a, v, lim.max_field);
                        r.status = .read;
                    } else r.status = .read_failed;
                },
            }
        }
        return lk;
    }
} else struct {};

fn escapeInto(out: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        0...8, 11, 12, 14...31, 127 => try out.writeByte('?'),
        else => try out.writeByte(c),
    };
}

fn kv(out: *Io.Writer, key: []const u8, s: []const u8) Io.Writer.Error!void {
    try out.print("{s}\t", .{key});
    try escapeInto(out, s);
    try out.writeByte('\n');
}

fn writeDialogWindow(out: *Io.Writer, w: DialogWindow, message: []const u8) Io.Writer.Error!void {
    try out.print("source\t{s}\nmodal\t{?}\n", .{ @tagName(w.source), w.modal });
    try kv(out, "window_title", w.title);
    try kv(out, "message", message);
    try out.print("nodes\t{d}\ttruncated={}\ttimed_out={}\n", .{ w.nodes.len, w.truncated, w.timed_out });
    for (w.nodes) |n| {
        try out.print("node\t{d}\t", .{n.depth});
        for ([_][]const u8{ n.role, n.subrole, n.title, n.value, n.description }) |f| {
            try escapeInto(out, f);
            try out.writeByte('\t');
        }
        try out.print("{?}", .{n.enabled});
        for ([_][]const u8{ n.identifier, n.value_type, n.min_value, n.max_value }) |f| {
            try out.writeByte('\t');
            try escapeInto(out, f);
        }
        try out.writeByte('\n');
    }
    for (w.nodes) |n| {
        if (!std.mem.eql(u8, n.role, "AXButton")) continue;
        try out.writeAll("button\t");
        try escapeInto(out, n.title);
        try out.print("\t{?}\n", .{n.enabled});
    }
}

fn writeOwner(out: *Io.Writer, key: []const u8, source: []const u8, requested: i32, o: OwnerPid) Io.Writer.Error!void {
    try out.print("{s}\tsource={s} state={s}", .{ key, source, @tagName(o.state) });
    if (o.window_number) |n| try out.print(" window_number={d}", .{n});
    switch (o.state) {
        .read => try out.print(" pid={d} requested_pid={d} same_as_requested={}", .{ o.pid, requested, o.pid == requested }),
        .failed => try out.print(" code={d}", .{o.code}),
        else => {},
    }
    try out.writeByte('\n');
}

fn writeDialog(out: *Io.Writer, req: DialogRequest, r: DialogReport) Io.Writer.Error!void {
    try out.print("pid\t{d}\nstatus\t{s}\n", .{ req.pid, @tagName(r.status) });
    if (r.actual_path) |p| try kv(out, "actual_executable", p);
    if (r.read_failure) |why| try kv(out, "read_failure", why);
    if (r.window) |w| {
        try writeDialogWindow(out, w, r.message);
        try writeOwner(out, "owner_ax", "AXUIElementGetPid", req.pid, w.owner_ax);
        try writeOwner(out, "owner_cg", "kCGWindowOwnerPID", req.pid, w.owner_cg);
    }
    if (r.lookup) |lk| {
        try kv(out, "window_title", lk.title);
        try out.print("lookup\tstatus={s}\tvisited={d}\tpruned={d}\tax_calls={d}\t", .{ @tagName(lk.status), lk.visited, lk.pruned, lk.ax_calls });
        try escapeInto(out, lk.why);
        try out.writeByte('\n');
        if (lk.status == .read) for (req.targets[0..req.targets_n], lk.results[0..req.targets_n]) |t, res| {
            try out.print("read\t{s}\t", .{@tagName(t.kind)});
            try escapeInto(out, t.id);
            try out.print("\t{s}\t{d}\t", .{ @tagName(res.status), res.matches });
            try escapeInto(out, res.role);
            try out.writeByte('\t');
            try escapeInto(out, res.value);
            try out.writeByte('\n');
        };
    }
    if (r.press) |p| try out.print("press_status\t{s}\npress_ax_code\t{d}\n", .{ @tagName(p.status), p.code });
    if (r.after) |af| switch (af) {
        .failed => |why| try kv(out, "after_read_failure", why),
        .window => |w| {
            try out.print("after_nodes\t{d}\tmodal={?}\n", .{ w.nodes.len, w.modal });
            try kv(out, "after_message", r.after_message);
        },
    };
    try out.print("result\t{s}\n", .{if (r.ok()) "ok" else "failed"});
}

fn parseDialogArgs(argv: []const []const u8) union(enum) { ok: DialogRequest, bad: []const u8 } {
    var req: DialogRequest = .{ .pid = 0, .expected_executable = "" };
    var have_pid = false;
    var have_exe = false;
    var have_timeout = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        const known = [_][]const u8{ "--pid", "--expected-executable", "--timeout-ms", "--expected-text", "--press", "--window-title", "--read-field", "--read-enabled", "--read-popup" };
        var is_known = false;
        for (known) |k| is_known = is_known or std.mem.eql(u8, k, name);
        if (!is_known) return .{ .bad = "unknown option" };
        const v: []const u8 = if (eq) |e| arg[e + 1 ..] else blk: {
            if (i + 1 >= argv.len) return .{ .bad = "option needs a value" };
            i += 1;
            break :blk argv[i];
        };
        if (std.mem.eql(u8, name, "--pid")) {
            if (have_pid) return .{ .bad = "option repeated" };
            have_pid = true;
            req.pid = std.fmt.parseInt(i32, v, 10) catch return .{ .bad = "--pid is not a number" };
        } else if (std.mem.eql(u8, name, "--expected-executable")) {
            if (have_exe) return .{ .bad = "option repeated" };
            have_exe = true;
            req.expected_executable = v;
        } else if (std.mem.eql(u8, name, "--timeout-ms")) {
            if (have_timeout) return .{ .bad = "option repeated" };
            have_timeout = true;
            req.timeout_ms = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = "--timeout-ms is not a number" };
        } else if (std.mem.eql(u8, name, "--expected-text")) {
            if (req.expected_text != null) return .{ .bad = "option repeated" };
            req.expected_text = v;
        } else if (std.mem.eql(u8, name, "--window-title")) {
            if (req.window_title != null) return .{ .bad = "option repeated" };
            if (v.len == 0 or v.len > 1024 or hasControlByte(v)) return .{ .bad = "--window-title needs 1 to 1024 bytes without control bytes" };
            req.window_title = v;
        } else if (std.mem.startsWith(u8, name, "--read-")) {
            if (req.targets_n == max_targets) return .{ .bad = "at most 4 --read-* options" };
            if (v.len == 0 or v.len > 256 or hasControlByte(v)) return .{ .bad = "--read-* needs an AXIdentifier of 1 to 256 bytes without control bytes" };
            const kind = std.meta.stringToEnum(ReadKind, name["--read-".len..]).?;
            req.targets[req.targets_n] = .{ .kind = kind, .id = v };
            req.targets_n += 1;
        } else {
            if (req.press != null) return .{ .bad = "option repeated" };
            req.press = v;
        }
    }
    if (!have_pid) return .{ .bad = "--pid is required" };
    if (!have_exe) return .{ .bad = "--expected-executable is required" };
    if (req.pid <= 1) return .{ .bad = "pid must be greater than 1" };
    const e = req.expected_executable;
    if (e.len == 0 or e[0] != '/' or e.len > 1024 or hasControlByte(e)) return .{ .bad = "--expected-executable must be an absolute path without control bytes" };
    if ((req.expected_text == null) != (req.press == null)) return .{ .bad = "--expected-text and --press are used together" };
    if (req.targets_n > 0 and req.press != null) return .{ .bad = "--read-* and --press are used separately" };
    if (req.window_title != null and req.targets_n == 0) return .{ .bad = "--window-title is used with --read-*" };
    if (req.press) |p| {
        if (p.len == 0 or p.len > 256 or hasControlByte(p)) return .{ .bad = "--press needs a non-empty label without control bytes" };
        if (req.expected_text.?.len == 0 or req.expected_text.?.len > 2048) return .{ .bad = "--expected-text must be 1 to 2048 bytes" };
    }
    if (req.timeout_ms == 0 or req.timeout_ms > 60_000) return .{ .bad = "--timeout-ms must be 1 to 60000" };
    return .{ .ok = req };
}

/// `vwx ui-dialog`. Exit 0 read or pressed, 1 refused or failed, 2 usage.
pub fn runDialogCli(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    if (@import("builtin").os.tag != .macos) return runDialogWith(gpa, argv, out, null);
    var se: nur.SystemEnv = .{ .io = io };
    var d: native_dialog.Dlg = .{ .env = se.env() };
    return runDialogWith(gpa, argv, out, d.backend());
}

pub fn runDialogWith(gpa: Allocator, argv: []const []const u8, out: *Io.Writer, backend: ?DialogBackend) u8 {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h") or std.mem.eql(u8, argv[0], "help"))) {
        out.writeAll(dialog_usage_text) catch {};
        out.flush() catch {};
        return 0;
    }
    const req = switch (parseDialogArgs(argv)) {
        .bad => |why| {
            out.print("error\t{s}\n", .{why}) catch {};
            out.writeAll(dialog_usage_text) catch {};
            out.flush() catch {};
            return 2;
        },
        .ok => |r| r,
    };
    const b = backend orelse {
        out.writeAll("error\tui-dialog needs macOS\n") catch {};
        out.flush() catch {};
        return 1;
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    const rep = dialog(arena.allocator(), b, req, &buf) catch {
        out.writeAll("error\tout of memory\n") catch {};
        out.flush() catch {};
        return 1;
    };
    writeDialog(out, req, rep) catch {};
    out.flush() catch {};
    return if (rep.ok()) 0 else 1;
}

const FakeDialog = struct {
    path: ?[]const u8 = "/Apps/Vectorworks",
    later_path: ?[]const u8 = null,
    /// Windows returned by successive reads. The last entry repeats.
    reads: []const DialogRead,
    press_out: PressOutcome = .{ .status = .pressed },
    path_calls: usize = 0,
    read_calls: usize = 0,
    press_calls: usize = 0,
    pressed_label: []const u8 = "",
    clock: u64 = 0,
    lookup: Lookup = .{ .status = .no_window },
    lookup_calls: usize = 0,
    lookup_title: ?[]const u8 = null,
    lookup_targets: usize = 0,

    fn backend(f: *FakeDialog) DialogBackend {
        return .{ .ptr = f, .pathFn = pathFn, .readFn = readFn, .pressFn = pressFn, .lookupFn = lookupFn, .nowFn = nowFn };
    }
    fn lookupFn(ptr: *anyopaque, _: Allocator, _: i32, title: ?[]const u8, targets: []const ReadTarget, _: DialogLimits) Lookup {
        const f: *FakeDialog = @ptrCast(@alignCast(ptr));
        f.lookup_calls += 1;
        f.lookup_title = title;
        f.lookup_targets = targets.len;
        return f.lookup;
    }
    fn pathFn(ptr: *anyopaque, _: i32, buf: []u8) ?[]const u8 {
        const f: *FakeDialog = @ptrCast(@alignCast(ptr));
        f.path_calls += 1;
        const p = (if (f.path_calls > 1 and f.later_path != null) f.later_path else f.path) orelse return null;
        @memcpy(buf[0..p.len], p);
        return buf[0..p.len];
    }
    fn readFn(ptr: *anyopaque, _: Allocator, _: i32, _: DialogLimits) DialogRead {
        const f: *FakeDialog = @ptrCast(@alignCast(ptr));
        const i = @min(f.read_calls, f.reads.len - 1);
        f.read_calls += 1;
        return f.reads[i];
    }
    fn pressFn(ptr: *anyopaque, _: i32, label: []const u8, _: DialogLimits) PressOutcome {
        const f: *FakeDialog = @ptrCast(@alignCast(ptr));
        f.press_calls += 1;
        f.pressed_label = label;
        return f.press_out;
    }
    fn nowFn(ptr: *anyopaque) u64 {
        const f: *FakeDialog = @ptrCast(@alignCast(ptr));
        f.clock += 1;
        return f.clock;
    }
};

const notice_nodes = [_]DNode{
    .{ .depth = 0, .role = "AXWindow", .enabled = true },
    .{ .depth = 1, .role = "AXStaticText", .value = "File is read-only." },
    .{ .depth = 1, .role = "AXStaticText", .value = "Do you want to open a copy of it with a new name?" },
    .{ .depth = 1, .role = "AXButton", .title = "No", .enabled = true },
    .{ .depth = 1, .role = "AXButton", .title = "Yes", .enabled = true },
};
const notice_text = "File is read-only.\n  Do you want to open a copy of it with a new name?  ";
const notice_read: DialogRead = .{ .window = .{ .source = .main, .modal = true, .nodes = &notice_nodes } };

fn pressReq(label: []const u8, text: []const u8) DialogRequest {
    return .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .expected_text = text, .press = label };
}

test "ui-dialog reads the notice text and the buttons without any action by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    var f: FakeDialog = .{ .reads = &.{notice_read} };
    const r = try dialog(arena.allocator(), f.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks" }, &buf);
    try testing.expectEqual(DialogStatus.read, r.status);
    try testing.expectEqualStrings("File is read-only. Do you want to open a copy of it with a new name?", r.message);
    try testing.expectEqual(@as(usize, 0), f.press_calls);
    try testing.expectEqual(@as(usize, 1), f.read_calls);
}

test "ui-dialog presses one exactly named button after both guard reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    var f: FakeDialog = .{ .reads = &.{notice_read} };
    const r = try dialog(arena.allocator(), f.backend(), pressReq("No", notice_text), &buf);
    try testing.expectEqual(DialogStatus.pressed, r.status);
    try testing.expectEqual(@as(usize, 1), f.press_calls);
    try testing.expectEqualStrings("No", f.pressed_label);
    // Two guard reads and one read after the press.
    try testing.expectEqual(@as(usize, 3), f.read_calls);
    try testing.expectEqual(@as(usize, 2), f.path_calls);
}

fn expectRefused(want: DialogStatus, f: *FakeDialog, req: DialogRequest) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    const r = try dialog(arena.allocator(), f.backend(), req, &buf);
    try testing.expectEqual(want, r.status);
    try testing.expect(!r.ok());
    try testing.expectEqual(@as(usize, 0), f.press_calls);
}

test "ui-dialog prints identifiers, typed values and numeric bounds after the enabled column" {
    const nodes = [_]DNode{
        .{ .depth = 0, .role = "AXWindow", .enabled = true },
        .{ .depth = 1, .role = "AXCheckBox", .title = "Layers", .value = "true", .value_type = "boolean", .enabled = true, .identifier = "opt.layers" },
        .{ .depth = 1, .role = "AXProgressIndicator", .value = "0.25", .value_type = "number", .min_value = "0", .max_value = "1", .identifier = "export.progress" },
    };
    const read: DialogRead = .{ .window = .{ .source = .focused, .modal = true, .nodes = &nodes } };
    var f: FakeDialog = .{ .reads = &.{read} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const code = runDialogWith(arena.allocator(), &.{ "--pid", "10012", "--expected-executable", "/Apps/Vectorworks" }, &aw.writer, f.backend());
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "node\t1\tAXCheckBox\t\tLayers\ttrue\t\ttrue\topt.layers\tboolean\t\t\n") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "node\t1\tAXProgressIndicator\t\t\t0.25\t\tnull\texport.progress\tnumber\t0\t1\n") != null);
}

test "ui-menu reports the node count and truncation of the selected subtree" {
    var f: FakeMenu = .{ .reads = &.{menu_read} };
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const code = runMenuWith(testing.allocator, &.{ "--pid", "10012", "--expected-executable", "/Apps/Vectorworks", "--item", "File", "--item", "Export" }, &aw.writer, f.backend());
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "selected\t4\ttruncated=false\n") != null);
}

test "Accessibility error codes split no value from failed reads" {
    try testing.expectEqual(Slot.present, slotOf(0, true));
    try testing.expectEqual(Slot.absent, slotOf(0, false));
    try testing.expectEqual(Slot.absent, slotOf(-25212, false)); // kAXErrorNoValue
    try testing.expectEqual(Slot.absent, slotOf(-25205, false)); // kAXErrorAttributeUnsupported
    try testing.expectEqual(Slot.failed, slotOf(-25204, false)); // kAXErrorCannotComplete
    try testing.expectEqual(Slot.failed, slotOf(-25202, false)); // kAXErrorInvalidUIElement
    try testing.expectEqual(Slot.failed, slotOf(-25211, false)); // kAXErrorAPIDisabled
    try testing.expectEqual(Slot.failed, slotOf(-1, true));
}

const doc_win: WindowInfo = .{ .title = "Plan.vwx", .modal = false };

test "window evidence is incomplete when the focused, main and window list reads all fail" {
    const all_failed: ListEvidence = .{ .focused = .failed, .main = .failed, .windows = .failed };
    try testing.expect(!all_failed.complete());
    try testing.expect(!windowsComplete(all_failed, &.{}));
    try testing.expect(!windowsComplete(.{ .focused = .failed }, &.{doc_win}));
    try testing.expect(!windowsComplete(.{ .main = .failed }, &.{doc_win}));
    try testing.expect(!windowsComplete(.{ .windows = .failed }, &.{doc_win}));
}

test "window evidence is incomplete for a malformed window list" {
    try testing.expect(!windowsComplete(.{ .windows = .malformed }, &.{}));
    try testing.expect(!windowsComplete(.{ .focused = .malformed }, &.{doc_win}));
    try testing.expect(!windowsComplete(.{ .main = .malformed }, &.{doc_win}));
    try testing.expect(!windowsComplete(.{ .windows = .present, .bad_element = true }, &.{doc_win}));
}

test "a non-modal window needs a readable title and every window a known modal flag" {
    const ok: ListEvidence = .{ .focused = .present, .main = .present, .windows = .present };
    try testing.expect(windowsComplete(ok, &.{doc_win}));
    try testing.expect(!windowsComplete(ok, &.{.{ .title = null, .modal = false }}));
    try testing.expect(!windowsComplete(ok, &.{.{ .title = "Plan.vwx", .modal = null }}));
    try testing.expect(!windowsComplete(ok, &.{ doc_win, .{ .title = null, .modal = null } }));
    // A modal window without a title does not break the other facts. Its text is checked apart.
    try testing.expect(windowsComplete(ok, &.{.{ .title = null, .modal = true }}));
}

test "a palette window with a successfully read empty title stays complete" {
    const ok: ListEvidence = .{ .focused = .present, .main = .present, .windows = .present };
    try testing.expect(windowsComplete(ok, &.{ doc_win, .{ .title = "", .modal = false } }));
}

test "legitimate no-value focused and main windows and an empty window list are complete" {
    const none: ListEvidence = .{ .focused = .absent, .main = .absent, .windows = .present };
    try testing.expect(windowsComplete(none, &.{}));
    try testing.expect(windowsComplete(none, &.{doc_win}));
    try testing.expect(windowsComplete(.{ .focused = .absent, .main = .present, .windows = .absent }, &.{doc_win}));
}

test "window list entries resolve to a number only by exact pid and title" {
    const entries = [_]CgEntry{
        .{ .pid = 10012, .name = "Export DWG", .number = 41 },
        .{ .pid = 999, .name = "Export DWG", .number = 42 },
        .{ .pid = 10012, .name = null, .number = 43 },
        .{ .pid = 10012, .name = "Doc", .number = 44 },
        .{ .pid = 10012, .name = "Doc", .number = 45 },
    };
    try testing.expectEqual(@as(?u32, 41), cgUnique(&entries, 10012, "Export DWG"));
    try testing.expectEqual(@as(?u32, null), cgUnique(&entries, 10012, "Doc"));
    try testing.expectEqual(@as(?u32, null), cgUnique(&entries, 10012, "export dwg"));
    try testing.expectEqual(@as(?u32, null), cgUnique(&entries, 10012, ""));
    try testing.expectEqual(@as(?u32, 42), cgUnique(&entries, 999, "Export DWG"));
}

test "window owner evidence correlates by window number only and names each source" {
    const entries = [_]CgEntry{
        .{ .pid = 500, .name = null, .number = 7 },
        .{ .pid = 41318, .name = null, .number = 8 },
        .{ .pid = 600, .name = null, .number = 9 },
        .{ .pid = 601, .name = null, .number = 9 },
    };
    var o = cgOwner(&entries, 7);
    try testing.expectEqual(OwnerState.read, o.state);
    try testing.expectEqual(@as(i32, 500), o.pid);
    try testing.expectEqual(OwnerState.no_match, cgOwner(&entries, 99).state);
    try testing.expectEqual(OwnerState.ambiguous, cgOwner(&entries, 9).state);
    o = cgOwner(&entries, null);
    try testing.expectEqual(OwnerState.no_window_number, o.state);
    try testing.expectEqual(OwnerState.failed, cgOwner(&.{.{ .pid = 1 << 40, .name = null, .number = 5 }}, 5).state);
}

test "ui-dialog prints the owner evidence of each source after the old fields" {
    const win: DialogRead = .{ .window = .{
        .source = .focused,
        .modal = true,
        .nodes = &notice_nodes,
        .owner_ax = .{ .state = .read, .pid = 777 },
        .owner_cg = .{ .state = .no_window_number },
    } };
    var f: FakeDialog = .{ .reads = &.{win} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const code = runDialogWith(arena.allocator(), &.{ "--pid", "41318", "--expected-executable", "/Apps/Vectorworks" }, &aw.writer, f.backend());
    try testing.expectEqual(@as(u8, 0), code);
    const t = aw.written();
    try testing.expect(std.mem.indexOf(u8, t, "owner_ax\tsource=AXUIElementGetPid state=read pid=777 requested_pid=41318 same_as_requested=false\n") != null);
    try testing.expect(std.mem.indexOf(u8, t, "owner_cg\tsource=kCGWindowOwnerPID state=no_window_number\n") != null);
    try testing.expect(std.mem.indexOf(u8, t, "button\tNo\ttrue\n") != null);
    // A failed AX owner read is stated, not hidden.
    var g: FakeDialog = .{ .reads = &.{.{ .window = .{ .source = .main, .owner_ax = .{ .state = .failed, .code = -25204 } } }} };
    var aw2: Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    _ = runDialogWith(arena.allocator(), &.{ "--pid", "41318", "--expected-executable", "/Apps/Vectorworks" }, &aw2.writer, g.backend());
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "owner_ax\tsource=AXUIElementGetPid state=failed code=-25204\n") != null);
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "owner_cg\tsource=kCGWindowOwnerPID state=not_read\n") != null);
}

test "ui-dialog makes no window read when the executable guard fails, so no owner is read" {
    var f: FakeDialog = .{ .path = "/Apps/Other", .reads = &.{notice_read} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const code = runDialogWith(arena.allocator(), &.{ "--pid", "41318", "--expected-executable", "/Apps/Vectorworks" }, &aw.writer, f.backend());
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expectEqual(@as(usize, 0), f.read_calls);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "owner_") == null);
}

test "ui-dialog refuses a wrong executable, a nonmodal window and a changed notice" {
    var f: FakeDialog = .{ .path = "/Apps/Other", .reads = &.{notice_read} };
    try expectRefused(.identity_mismatch, &f, pressReq("No", notice_text));
    try testing.expectEqual(@as(usize, 0), f.read_calls);
    var g: FakeDialog = .{ .path = null, .reads = &.{notice_read} };
    try expectRefused(.not_running, &g, pressReq("No", notice_text));
    var nm = notice_read;
    nm.window.modal = false;
    var h: FakeDialog = .{ .reads = &.{nm} };
    try expectRefused(.refused_not_modal, &h, pressReq("No", notice_text));
    var u = notice_read;
    u.window.modal = null;
    var h2: FakeDialog = .{ .reads = &.{u} };
    try expectRefused(.refused_not_modal, &h2, pressReq("No", notice_text));
    var c: FakeDialog = .{ .reads = &.{notice_read} };
    try expectRefused(.refused_text_changed, &c, pressReq("No", "File is read-only. Do you want to open a copy?"));
    try expectRefused(.refused_text_changed, &c, pressReq("No", "file is read-only. Do you want to open a copy of it with a new name?"));
}

test "ui-dialog refuses a missing, duplicate or disabled button" {
    var f: FakeDialog = .{ .reads = &.{notice_read} };
    try expectRefused(.refused_button_missing, &f, pressReq("Cancel", notice_text));
    try expectRefused(.refused_button_missing, &f, pressReq("no", notice_text));
    const dup = [_]DNode{ notice_nodes[0], notice_nodes[1], notice_nodes[2], notice_nodes[3], notice_nodes[3] };
    var d: FakeDialog = .{ .reads = &.{.{ .window = .{ .source = .focused, .modal = true, .nodes = &dup } }} };
    try expectRefused(.refused_button_duplicate, &d, pressReq("No", notice_text));
    const dis = [_]DNode{ notice_nodes[0], notice_nodes[1], notice_nodes[2], .{ .depth = 1, .role = "AXButton", .title = "No", .enabled = false } };
    var e: FakeDialog = .{ .reads = &.{.{ .window = .{ .source = .focused, .modal = true, .nodes = &dis } }} };
    try expectRefused(.refused_button_disabled, &e, pressReq("No", notice_text));
}

test "ui-dialog rechecks identity and text immediately before the press" {
    var f: FakeDialog = .{ .later_path = "/Apps/Reused", .reads = &.{notice_read} };
    try expectRefused(.refused_identity_changed, &f, pressReq("No", notice_text));
    const other = [_]DNode{ notice_nodes[0], .{ .depth = 1, .role = "AXStaticText", .value = "Save changes?" }, notice_nodes[3] };
    const changed: DialogRead = .{ .window = .{ .source = .main, .modal = true, .nodes = &other } };
    var g: FakeDialog = .{ .reads = &.{ notice_read, changed } };
    try expectRefused(.refused_text_changed, &g, pressReq("No", notice_text));
    try testing.expectEqual(@as(usize, 2), g.read_calls);
    var nm = notice_read;
    nm.window.modal = false;
    var h: FakeDialog = .{ .reads = &.{ notice_read, nm } };
    try expectRefused(.refused_not_modal, &h, pressReq("No", notice_text));
    const failed: DialogRead = .{ .failed = "no focused window, main window or single AXWindows entry" };
    var k: FakeDialog = .{ .reads = &.{ notice_read, failed } };
    try expectRefused(.read_failed, &k, pressReq("No", notice_text));
}

test "ui-dialog reports a failed press and a read failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    var f: FakeDialog = .{ .reads = &.{notice_read}, .press_out = .{ .status = .ax_error, .code = -25200 } };
    const r = try dialog(arena.allocator(), f.backend(), pressReq("Yes", notice_text), &buf);
    try testing.expectEqual(DialogStatus.press_failed, r.status);
    try testing.expectEqual(@as(i32, -25200), r.press.?.code);
    var g: FakeDialog = .{ .reads = &.{.{ .failed = "Accessibility is not trusted for this process" }} };
    const rr = try dialog(arena.allocator(), g.backend(), .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks" }, &buf);
    try testing.expectEqual(DialogStatus.read_failed, rr.status);
}

test "ui-dialog normalizes observed and expected notice whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a b c", try normalizeWhitespace(arena.allocator(), "  a \t b\n\nc  "));
    try testing.expectEqualStrings("", try normalizeWhitespace(arena.allocator(), " \n "));
    const actual_messages = [_][]const u8{
        "File is read-only.\nDo you want to open a copy of it with a new name?",
        "File is read-only.  Do you want to open a copy of it with a new name?",
    };
    for (actual_messages) |actual| {
        const nodes = [_]DNode{ notice_nodes[0], .{ .depth = 1, .role = "AXStaticText", .value = actual }, notice_nodes[3] };
        var f: FakeDialog = .{ .reads = &.{.{ .window = .{ .source = .main, .modal = true, .nodes = &nodes } }} };
        var buf: [4096]u8 = undefined;
        const r = try dialog(arena.allocator(), f.backend(), pressReq("No", notice_text), &buf);
        try testing.expectEqual(DialogStatus.pressed, r.status);
        try testing.expectEqual(@as(usize, 1), f.press_calls);
        try testing.expectEqualStrings(actual, r.message);
    }
}

test "ui-dialog arguments need both guards and have no key, close or launch route" {
    var f: FakeDialog = .{ .reads = &.{notice_read} };
    var w_buf: [8192]u8 = undefined;
    const bad = [_][]const []const u8{
        &.{},
        &.{ "--pid", "10012" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--press", "No" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--expected-text", "t" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--expected-text", "t", "--press", "" },
        &.{ "--pid", "10012", "--expected-executable", "rel" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--key", "return" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--close" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--click", "1,2" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--timeout-ms", "0" },
        &.{ "--pid", "10012", "--pid", "5", "--expected-executable", "/Apps/V" },
    };
    for (bad) |argv| {
        var w: Io.Writer = .fixed(&w_buf);
        try testing.expectEqual(@as(u8, 2), runDialogWith(testing.allocator, argv, &w, f.backend()));
    }
    try testing.expectEqual(@as(usize, 0), f.path_calls);
    var w: Io.Writer = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 0), runDialogWith(testing.allocator, &.{ "--pid", "10012", "--expected-executable", "/Apps/Vectorworks", "--expected-text", notice_text, "--press", "No" }, &w, f.backend()));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "status\tpressed\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "button\tNo\ttrue\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "message\tFile is read-only. Do you want") != null);
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "result\tok\n"));
}

const save_panel_argv = [_][]const u8{
    "--pid",          "10012",                  "--expected-executable", "/Apps/Vectorworks",
    "--window-title", "Export as PDF Document", "--read-field",          "saveAsNameTextField",
    "--read-enabled", "OKButton",               "--read-popup",          "where popup",
};

test "ui-dialog --read-* prints one value per target and no tree" {
    var results: [max_targets]TargetResult = @splat(.{});
    results[0] = .{ .status = .read, .role = "AXTextField", .value = "a.pdf", .matches = 1 };
    results[1] = .{ .status = .read, .role = "AXButton", .value = "true", .matches = 1 };
    results[2] = .{ .status = .read, .role = "AXPopUpButton", .value = "tmp", .matches = 1 };
    var f: FakeDialog = .{ .reads = &.{notice_read}, .lookup = .{
        .status = .read,
        .title = "Export as PDF Document",
        .results = results,
        .visited = 31,
        .pruned = 2,
        .ax_calls = 38,
    } };
    var w_buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 0), runDialogWith(testing.allocator, &save_panel_argv, &w, f.backend()));
    const o = w.buffered();
    try testing.expectEqual(@as(usize, 1), f.lookup_calls);
    try testing.expectEqual(@as(usize, 0), f.read_calls);
    try testing.expectEqual(@as(usize, 0), f.press_calls);
    try testing.expectEqual(@as(usize, 3), f.lookup_targets);
    try testing.expectEqualStrings("Export as PDF Document", f.lookup_title.?);
    try testing.expect(std.mem.indexOf(u8, o, "lookup\tstatus=read\tvisited=31\tpruned=2\tax_calls=38\t\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "read\tfield\tsaveAsNameTextField\tread\t1\tAXTextField\ta.pdf\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "read\tenabled\tOKButton\tread\t1\tAXButton\ttrue\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "read\tpopup\twhere popup\tread\t1\tAXPopUpButton\ttmp\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "node\t") == null);
    try testing.expect(std.mem.endsWith(u8, o, "result\tok\n"));
}

test "ui-dialog --read-* exits 1 for an absent window and for an unresolved target" {
    var w_buf: [4096]u8 = undefined;
    var f: FakeDialog = .{ .reads = &.{notice_read}, .lookup = .{ .status = .window_absent, .why = "no window has this exact title" } };
    var w: Io.Writer = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 1), runDialogWith(testing.allocator, &save_panel_argv, &w, f.backend()));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "status\twindow_absent\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "read\t") == null);

    var results: [max_targets]TargetResult = @splat(.{});
    results[0] = .{ .status = .read, .role = "AXTextField", .value = "a.pdf", .matches = 1 };
    results[1] = .{ .status = .duplicate, .matches = 2 };
    var g: FakeDialog = .{ .reads = &.{notice_read}, .lookup = .{ .status = .read, .results = results } };
    w = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 1), runDialogWith(testing.allocator, save_panel_argv[0..10], &w, g.backend()));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "status\ttarget_failed\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "read\tenabled\tOKButton\tduplicate\t2\t\t\n") != null);
}

test "ui-dialog --read-* arguments" {
    var f: FakeDialog = .{ .reads = &.{notice_read} };
    var w_buf: [8192]u8 = undefined;
    const base = [_][]const u8{ "--pid", "10012", "--expected-executable", "/Apps/V" };
    const bad = [_][]const []const u8{
        &(base ++ [_][]const u8{ "--window-title", "T" }),
        &(base ++ [_][]const u8{ "--read-field", "" }),
        &(base ++ [_][]const u8{ "--read-value", "x" }),
        &(base ++ [_][]const u8{ "--read-field", "a", "--expected-text", "t", "--press", "No" }),
        &(base ++ [_][]const u8{ "--read-field", "a", "--read-field", "b", "--read-field", "c", "--read-field", "d", "--read-field", "e" }),
        &(base ++ [_][]const u8{ "--read-field", "a", "--window-title", "T", "--window-title", "U" }),
    };
    for (bad) |argv| {
        var w: Io.Writer = .fixed(&w_buf);
        try testing.expectEqual(@as(u8, 2), runDialogWith(testing.allocator, argv, &w, f.backend()));
    }
    try testing.expectEqual(@as(usize, 0), f.path_calls);
}

test "lookup role rules" {
    try testing.expect(prunedRole("AXOutline"));
    try testing.expect(!prunedRole("AXGroup"));
    try testing.expect(roleFits(.field, "AXTextField"));
    try testing.expect(!roleFits(.field, "AXButton"));
    try testing.expect(roleFits(.popup, "AXPopUpButton"));
    try testing.expect(roleFits(.enabled, "AXButton"));
}

// ui-menu

pub const menu_usage_text =
    \\usage: vwx ui-menu --pid N --expected-executable ABSOLUTE_PATH [--item LABEL]... [--materialize]
    \\                   [--press] [--timeout-ms N]
    \\
    \\Lists the native Accessibility menu bar of process N after an exact proc_pidpath check. Each
    \\--item is one exact menu label of the selected path, in order. With items the output holds the
    \\subtree of the selected entry only. The walk resolves the exact path first and descends into
    \\that entry alone. The selected line reports the node count and truncation of that subtree.
    \\Default is read only. --materialize opens the menus on the
    \\selected path with AXPress on a menu bar item or AXOpen on a submenu item when they list no
    \\items. --press activates the leaf of the exact path with AXPress. It needs two or more items
    \\and accepts only About items, File > Export items and these exact paths:
    \\View > Zoom > Fit To Objects, View > Standard Views > Top/Plan, View > Rendering > Wireframe,
    \\View > Class Options, View > Class Options > Show Others, View > Layer Options,
    \\View > Layer Options > Show Others, File > Close, Tools > Workspaces > Architect and
    \\Tools > Workspaces > Rosetta glTF. Any other label holding Quit, Close,
    \\Delete, Remove, Erase, Empty, Revert, Move to Trash or Overwrite is refused. A missing or
    \\ambiguous path match is refused. Traversal is bounded by node count, depth and
    \\--timeout-ms. The command has no launch, quit or terminate route. Exit 0 read or pressed,
    \\1 refused or failed, 2 usage.
    \\
;

pub const max_menu_path = 6;

pub const MenuNode = struct {
    depth: u8,
    role: []const u8 = "",
    title: []const u8 = "",
    enabled: ?bool = null,
    /// The item has a child AXMenu.
    submenu: bool = false,
    /// The child menu lists at least one item.
    expanded: bool = false,
};

pub const MenuTree = struct {
    nodes: []const MenuNode = &.{},
    truncated: bool = false,
    timed_out: bool = false,
    opened: usize = 0,
};

pub const MenuRead = union(enum) { menu: MenuTree, failed: []const u8 };

pub const MenuLimits = struct {
    max_nodes: usize = 400,
    max_depth: u8 = 5,
    max_field: usize = 256,
    deadline_ns: u64 = 0,
};

pub const MenuPressStatus = enum { pressed, no_menu_bar, path_missing, path_ambiguous, not_an_item, leaf_has_submenu, leaf_disabled, open_failed, ax_error };

pub const MenuPressOutcome = struct { status: MenuPressStatus, code: i32 = 0 };

pub const MenuBackend = struct {
    ptr: *anyopaque,
    pathFn: *const fn (ptr: *anyopaque, pid: i32, buf: []u8) ?[]const u8,
    /// Reads the menu bar. Strings are allocated in `a`. Items of the selected `path` are opened
    /// only when `materialize` is set.
    readFn: *const fn (ptr: *anyopaque, a: Allocator, pid: i32, path: []const []const u8, materialize: bool, lim: MenuLimits) MenuRead,
    /// Resolves the exact path again and performs AXPress on its single enabled leaf item.
    pressFn: *const fn (ptr: *anyopaque, pid: i32, path: []const []const u8, lim: MenuLimits) MenuPressOutcome,
    nowFn: *const fn (ptr: *anyopaque) u64,
};

pub const MenuRequest = struct {
    pid: i32,
    expected_executable: []const u8,
    items: []const []const u8 = &.{},
    materialize: bool = false,
    press: bool = false,
    timeout_ms: u32 = 8000,
    /// Exact title of one open document. Only the owned reference cleanup sets it. With it a press
    /// accepts the one path Window > title and nothing else. ui-menu never sets it.
    window_document: []const u8 = "",
};

pub const MenuStatus = enum {
    read,
    pressed,
    not_running,
    identity_mismatch,
    read_failed,
    refused_policy,
    refused_path_missing,
    refused_path_ambiguous,
    refused_not_an_item,
    refused_leaf_submenu,
    refused_leaf_disabled,
    refused_identity_changed,
    press_failed,
};

pub const MenuReport = struct {
    status: MenuStatus,
    actual_path: ?[]const u8 = null,
    tree: ?MenuTree = null,
    /// Index range of the selected subtree in `tree.nodes`.
    sel_from: usize = 0,
    sel_to: usize = 0,
    reason: []const u8 = "",
    press: ?MenuPressOutcome = null,

    pub fn ok(r: MenuReport) bool {
        return r.status == .read or r.status == .pressed;
    }
};

const Resolve = union(enum) {
    found: struct { index: usize, end: usize },
    missing,
    ambiguous,
};

/// Finds the entry at `path` in the flat depth-first node list. Every step needs exactly one exact
/// title match among the children of the previous step.
pub fn resolvePath(nodes: []const MenuNode, path: []const []const u8) Resolve {
    var from: usize = 0;
    var to: usize = nodes.len;
    var found: usize = 0;
    for (path, 0..) |label, d| {
        var hit: ?usize = null;
        var count: usize = 0;
        var i = from;
        while (i < to) : (i += 1) {
            if (nodes[i].depth == d and std.mem.eql(u8, nodes[i].title, label)) {
                hit = i;
                count += 1;
            }
        }
        if (count == 0) return .missing;
        if (count > 1) return .ambiguous;
        found = hit.?;
        from = found + 1;
        var end = from;
        while (end < to and nodes[end].depth > d) end += 1;
        to = end;
    }
    var end = found + 1;
    while (end < nodes.len and nodes[end].depth > path.len - 1) end += 1;
    return .{ .found = .{ .index = found, .end = end } };
}

const menu_deny_prefixes = [_][]const u8{ "quit", "close", "delete", "remove", "erase", "empty", "revert", "move to trash", "overwrite" };

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Exact full label sequences the export driver may press. A leaf label alone never matches.
/// This list is checked before the label deny list, so File > Close is allowed while Close under
/// any other parent, and Close All under File, stay refused.
const menu_press_allow = [_][]const []const u8{
    &.{ "View", "Zoom", "Fit To Objects" },
    &.{ "View", "Standard Views", "Top/Plan" },
    &.{ "View", "Rendering", "Wireframe" },
    &.{ "View", "Class Options" },
    &.{ "View", "Class Options", "Show Others" },
    &.{ "View", "Layer Options" },
    &.{ "View", "Layer Options", "Show Others" },
    &.{ "File", "Close" },
    &.{ "Tools", "Workspaces", "Architect" },
    &.{ "Tools", "Workspaces", "Rosetta glTF" },
};

fn isAllowedExactPath(path: []const []const u8) bool {
    for (menu_press_allow) |allowed| {
        if (allowed.len != path.len) continue;
        for (allowed, path) |a, l| {
            if (!std.mem.eql(u8, a, l)) break;
        } else return true;
    }
    return false;
}

/// Null when the path may be pressed. Otherwise the reason.
pub fn pressPolicy(path: []const []const u8) ?[]const u8 {
    if (path.len < 2) return "a press needs at least two items";
    if (isAllowedExactPath(path)) return null;
    for (path) |label| {
        const t = std.mem.trim(u8, label, " ");
        for (menu_deny_prefixes) |p| {
            if (startsWithFold(t, p)) return "the path holds a Quit, Close or destructive label";
        }
    }
    if (startsWithFold(path[path.len - 1], "About")) return null;
    if (path.len >= 3 and std.mem.eql(u8, path[0], "File") and startsWithFold(path[1], "Export")) return null;
    return "only About items, File > Export items and the allowed exact paths may be pressed";
}

/// Null when the path is exactly Window > the authorized document title.
pub fn windowDocumentPolicy(path: []const []const u8, title: []const u8) ?[]const u8 {
    if (title.len == 0 or title.len > 256 or hasControlByte(title) or std.mem.indexOfScalar(u8, title, 0x2f) != null) return "the authorized document title is not a plain title";
    if (!std.mem.endsWith(u8, title, ".vwx")) return "the authorized document title is not a .vwx title";
    if (path.len != 2 or !std.mem.eql(u8, path[0], "Window") or !std.mem.eql(u8, path[1], title)) return "only Window > the authorized document title may be pressed";
    return null;
}

fn pressPolicyFor(req: MenuRequest) ?[]const u8 {
    if (req.window_document.len > 0) return windowDocumentPolicy(req.items, req.window_document);
    return pressPolicy(req.items);
}

fn menuStatusOf(r: Resolve) ?MenuStatus {
    return switch (r) {
        .found => null,
        .missing => .refused_path_missing,
        .ambiguous => .refused_path_ambiguous,
    };
}

fn leafGate(nodes: []const MenuNode, idx: usize) ?MenuStatus {
    const n = nodes[idx];
    if (!std.mem.eql(u8, n.role, "AXMenuItem")) return .refused_not_an_item;
    if (n.submenu) return .refused_leaf_submenu;
    if (n.enabled != true) return .refused_leaf_disabled;
    return null;
}

pub fn menu(a: Allocator, b: MenuBackend, req: MenuRequest, buf: []u8) MenuReport {
    if (req.press) if (pressPolicyFor(req)) |why| return .{ .status = .refused_policy, .reason = why };
    const path = b.pathFn(b.ptr, req.pid, buf) orelse return .{ .status = .not_running };
    if (!std.mem.eql(u8, path, req.expected_executable)) return .{ .status = .identity_mismatch, .actual_path = path };
    var lim: MenuLimits = .{};
    if (req.items.len > lim.max_depth) lim.max_depth = @intCast(req.items.len);
    const budget_ns = @as(u64, req.timeout_ms) * std.time.ns_per_ms;
    lim.deadline_ns = b.nowFn(b.ptr) + budget_ns;
    var rep: MenuReport = .{ .status = .read, .actual_path = path };
    const first = switch (b.readFn(b.ptr, a, req.pid, req.items, req.materialize or req.press, lim)) {
        .failed => |why| {
            rep.status = .read_failed;
            rep.reason = why;
            return rep;
        },
        .menu => |t| t,
    };
    rep.tree = first;
    rep.sel_to = first.nodes.len;
    if (req.items.len == 0) return rep;
    const r1 = resolvePath(first.nodes, req.items);
    if (menuStatusOf(r1)) |s| {
        rep.status = s;
        return rep;
    }
    rep.sel_from = r1.found.index;
    rep.sel_to = r1.found.end;
    if (!req.press) return rep;
    if (leafGate(first.nodes, r1.found.index)) |s| {
        rep.status = s;
        return rep;
    }
    // Second read and identity check immediately before the press.
    var again: [4096]u8 = undefined;
    const p2 = b.pathFn(b.ptr, req.pid, &again);
    if (p2 == null or !std.mem.eql(u8, p2.?, req.expected_executable)) {
        rep.status = .refused_identity_changed;
        return rep;
    }
    lim.deadline_ns = b.nowFn(b.ptr) + budget_ns;
    const second = switch (b.readFn(b.ptr, a, req.pid, req.items, true, lim)) {
        .failed => |why| {
            rep.status = .read_failed;
            rep.reason = why;
            return rep;
        },
        .menu => |t| t,
    };
    rep.tree = second;
    const r2 = resolvePath(second.nodes, req.items);
    if (menuStatusOf(r2)) |s| {
        rep.status = s;
        return rep;
    }
    rep.sel_from = r2.found.index;
    rep.sel_to = r2.found.end;
    if (leafGate(second.nodes, r2.found.index)) |s| {
        rep.status = s;
        return rep;
    }
    lim.deadline_ns = b.nowFn(b.ptr) + budget_ns;
    const out = b.pressFn(b.ptr, req.pid, req.items, lim);
    rep.press = out;
    rep.status = if (out.status == .pressed) .pressed else .press_failed;
    return rep;
}

/// The menu backend of the running system. Null off macOS.
pub const SystemMenu = if (@import("builtin").os.tag == .macos) native_menu.Mn else struct { env: nur.Env };

pub fn systemMenuBackend(m: *SystemMenu) ?MenuBackend {
    if (@import("builtin").os.tag != .macos) return null;
    return m.backend();
}

const native_menu = if (@import("builtin").os.tag == .macos) struct {
    const Ref = native.Ref;
    const nd = native_dialog;

    pub const Mn = struct {
        env: nur.Env,

        pub fn backend(m: *Mn) MenuBackend {
            return .{ .ptr = m, .pathFn = pathFn, .readFn = readFn, .pressFn = pressFn, .nowFn = nowFn };
        }
    };

    fn pathFn(_: *anyopaque, pid: i32, buf: []u8) ?[]const u8 {
        return native.pathImpl(undefined, pid, buf);
    }
    fn nowFn(ptr: *anyopaque) u64 {
        const m: *Mn = @ptrCast(@alignCast(ptr));
        return m.env.now();
    }

    fn roleIs(el: Ref, role: []const u8) bool {
        var tmp: [64]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&tmp);
        return std.mem.eql(u8, nd.readString(fba.allocator(), el, "AXRole", 60), role);
    }

    /// Retained child AXMenu of an item, or null.
    fn menuOf(el: Ref) Ref {
        const kids = nd.copyAttr(el, "AXChildren");
        if (kids == null) return null;
        defer native.CFRelease(kids);
        if (native.CFGetTypeID(kids) != native.CFArrayGetTypeID()) return null;
        const n = native.CFArrayGetCount(kids);
        var i: isize = 0;
        while (i < n) : (i += 1) {
            const c = nd.CFArrayGetValueAtIndex(kids, i);
            if (c != null and roleIs(c, "AXMenu")) return nd.CFRetain(c);
        }
        return null;
    }

    /// Retained array of the entries of a menu bar or of a menu.
    fn childArray(el: Ref) Ref {
        const kids = nd.copyAttr(el, "AXChildren");
        if (kids == null) return null;
        if (native.CFGetTypeID(kids) != native.CFArrayGetTypeID()) {
            native.CFRelease(kids);
            return null;
        }
        return kids;
    }

    fn countOf(arr: Ref) isize {
        return if (arr == null) 0 else native.CFArrayGetCount(arr);
    }

    /// Performs the opening action. A menu bar item takes AXPress. A submenu item takes AXOpen and
    /// then AXPress, because AXPress on an item with a submenu only opens that submenu.
    fn openAction(el: Ref, bar_item: bool) i32 {
        if (!bar_item) {
            const open = native.attr("AXOpen");
            defer native.CFRelease(open);
            const c = nd.AXUIElementPerformAction(el, open);
            if (c == 0) return 0;
        }
        const press = native.attr("AXPress");
        defer native.CFRelease(press);
        return nd.AXUIElementPerformAction(el, press);
    }

    fn cancelAction(el: Ref) void {
        const cancel = native.attr("AXCancel");
        defer native.CFRelease(cancel);
        _ = nd.AXUIElementPerformAction(el, cancel);
    }

    /// Waits until the menu lists items or the deadline passes. Returns the item count.
    fn awaitItems(env: nur.Env, menu_el: Ref, deadline_ns: u64) isize {
        var tries: usize = 0;
        while (true) : (tries += 1) {
            const arr = childArray(menu_el);
            const n = countOf(arr);
            if (arr != null) native.CFRelease(arr);
            if (n > 0 or tries >= 8 or env.now() >= deadline_ns) return n;
            env.sleep(25);
        }
    }

    const MWalk = struct {
        a: Allocator,
        env: nur.Env,
        lim: MenuLimits,
        path: []const []const u8,
        materialize: bool,
        nodes: std.ArrayList(MenuNode) = .empty,
        truncated: bool = false,
        timed_out: bool = false,
        opened: [8]Ref = .{null} ** 8,
        opened_n: usize = 0,
        opened_count: usize = 0,

        /// `all` lists every entry. `path` lists only the entries whose title equals the path label of
        /// their depth and descends into the first of them. `subtree` lists everything below the
        /// selected path entry.
        const Mode = enum { all, path, subtree };

        fn visit(w: *MWalk, parent: Ref, depth: u8, bar: bool, mode: Mode) void {
            if (w.timed_out) return;
            var menu_el: Ref = null;
            defer if (menu_el != null) native.CFRelease(menu_el);
            var arr: Ref = null;
            if (bar) {
                arr = childArray(parent);
            } else {
                menu_el = menuOf(parent);
                if (menu_el == null) return;
                arr = childArray(menu_el);
            }
            defer if (arr != null) native.CFRelease(arr);
            const n = countOf(arr);
            var hit_here = false;
            var i: isize = 0;
            while (i < n) : (i += 1) {
                if (w.env.now() >= w.lim.deadline_ns) {
                    w.timed_out = true;
                    w.truncated = true;
                    return;
                }
                if (w.nodes.items.len >= w.lim.max_nodes) {
                    w.truncated = true;
                    return;
                }
                const el = nd.CFArrayGetValueAtIndex(arr, i);
                if (el == null) continue;
                const title = nd.readString(w.a, el, "AXTitle", w.lim.max_field);
                const role = nd.readString(w.a, el, "AXRole", 64);
                if (mode == .path and (depth >= w.path.len or !std.mem.eql(u8, title, w.path[depth]))) continue;
                // A second match is only listed. The path is ambiguous and is refused.
                const here = mode == .path and !hit_here;
                if (mode == .path) hit_here = true;
                var sub = menuOf(el);
                if (w.materialize and here) {
                    const listed: isize = if (sub != null) blk: {
                        const a2 = childArray(sub);
                        const c = countOf(a2);
                        if (a2 != null) native.CFRelease(a2);
                        break :blk c;
                    } else 0;
                    if (listed == 0 and (bar or sub != null) and w.opened_n < w.opened.len) {
                        if (openAction(el, bar) == 0) {
                            w.opened_count += 1;
                            if (bar) {
                                w.opened[w.opened_n] = nd.CFRetain(el);
                                w.opened_n += 1;
                            }
                            if (sub == null) sub = menuOf(el);
                            if (sub != null) _ = awaitItems(w.env, sub, w.lim.deadline_ns);
                        }
                    }
                }
                var expanded = false;
                if (sub != null) {
                    const a3 = childArray(sub);
                    expanded = countOf(a3) > 0;
                    if (a3 != null) native.CFRelease(a3);
                    native.CFRelease(sub);
                }
                w.nodes.append(w.a, .{
                    .depth = depth,
                    .role = role,
                    .title = title,
                    .enabled = nd.readFlag(el, "AXEnabled"),
                    .submenu = menuHas(el),
                    .expanded = expanded,
                }) catch {
                    w.truncated = true;
                    return;
                };
                if (expanded) {
                    if (depth + 1 >= w.lim.max_depth) {
                        w.truncated = true;
                    } else {
                        if (mode != .path) {
                            w.visit(el, depth + 1, false, mode);
                        } else if (here) {
                            w.visit(el, depth + 1, false, if (depth + 1 == w.path.len) .subtree else .path);
                        }
                    }
                }
                if (w.timed_out) return;
            }
        }

        fn menuHas(el: Ref) bool {
            const m = menuOf(el);
            if (m == null) return false;
            native.CFRelease(m);
            return true;
        }

        fn closeOpened(w: *MWalk) void {
            var k = w.opened_n;
            while (k > 0) {
                k -= 1;
                cancelAction(w.opened[k]);
                native.CFRelease(w.opened[k]);
            }
            w.opened_n = 0;
        }
    };

    fn readFn(ptr: *anyopaque, a: Allocator, pid: i32, path: []const []const u8, materialize: bool, lim: MenuLimits) MenuRead {
        const m: *Mn = @ptrCast(@alignCast(ptr));
        if (native.AXIsProcessTrusted() == 0) return .{ .failed = "Accessibility is not trusted for this process" };
        const app = native.AXUIElementCreateApplication(pid);
        if (app == null) return .{ .failed = "no Accessibility application element" };
        defer native.CFRelease(app);
        _ = native.AXUIElementSetMessagingTimeout(app, 2.0);
        const bar = nd.copyAttr(app, "AXMenuBar");
        if (bar == null) return .{ .failed = "the process exposes no AXMenuBar" };
        defer native.CFRelease(bar);
        var w: MWalk = .{ .a = a, .env = m.env, .lim = lim, .path = path, .materialize = materialize };
        w.visit(bar, 0, true, if (path.len == 0) .all else .path);
        w.closeOpened();
        return .{ .menu = .{ .nodes = w.nodes.items, .truncated = w.truncated, .timed_out = w.timed_out, .opened = w.opened_count } };
    }

    fn pressFn(ptr: *anyopaque, pid: i32, path: []const []const u8, lim: MenuLimits) MenuPressOutcome {
        const m: *Mn = @ptrCast(@alignCast(ptr));
        const app = native.AXUIElementCreateApplication(pid);
        if (app == null) return .{ .status = .no_menu_bar };
        defer native.CFRelease(app);
        _ = native.AXUIElementSetMessagingTimeout(app, 2.0);
        const bar = nd.copyAttr(app, "AXMenuBar");
        if (bar == null) return .{ .status = .no_menu_bar };
        defer native.CFRelease(bar);
        var held: [2 * max_menu_path + 2]Ref = .{null} ** (2 * max_menu_path + 2);
        var held_n: usize = 0;
        defer for (held[0..held_n]) |r| native.CFRelease(r);
        var arrs_parent: Ref = bar;
        var is_bar = true;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        for (path, 0..) |label, d| {
            var menu_el: Ref = null;
            var arr: Ref = null;
            if (is_bar) {
                arr = childArray(arrs_parent);
            } else {
                menu_el = menuOf(arrs_parent);
                if (menu_el == null) return .{ .status = .path_missing };
                held[held_n] = menu_el;
                held_n += 1;
                arr = childArray(menu_el);
            }
            if (arr == null) return .{ .status = .path_missing };
            held[held_n] = arr;
            held_n += 1;
            var hit: Ref = null;
            var count: usize = 0;
            const n = countOf(arr);
            var i: isize = 0;
            while (i < n) : (i += 1) {
                const el = nd.CFArrayGetValueAtIndex(arr, i);
                if (el == null) continue;
                const t = nd.readString(arena.allocator(), el, "AXTitle", lim.max_field);
                if (std.mem.eql(u8, t, label)) {
                    hit = el;
                    count += 1;
                }
            }
            if (count == 0) return .{ .status = .path_missing };
            if (count > 1) return .{ .status = .path_ambiguous };
            if (d + 1 == path.len) {
                if (!roleIs(hit, "AXMenuItem")) return .{ .status = .not_an_item };
                const sm = menuOf(hit);
                if (sm != null) {
                    native.CFRelease(sm);
                    return .{ .status = .leaf_has_submenu };
                }
                if (nd.readFlag(hit, "AXEnabled") != true) return .{ .status = .leaf_disabled };
                const act = native.attr("AXPress");
                defer native.CFRelease(act);
                const code = nd.AXUIElementPerformAction(hit, act);
                return .{ .status = if (code == 0) .pressed else .ax_error, .code = code };
            }
            // Open the next level when it lists no items.
            var sub = menuOf(hit);
            if (sub == null) {
                if (openAction(hit, is_bar) != 0) return .{ .status = .open_failed };
                sub = menuOf(hit);
            } else {
                const a2 = childArray(sub);
                const c = countOf(a2);
                if (a2 != null) native.CFRelease(a2);
                if (c == 0 and openAction(hit, is_bar) != 0) {
                    native.CFRelease(sub);
                    return .{ .status = .open_failed };
                }
            }
            if (sub == null) return .{ .status = .path_missing };
            native.CFRelease(sub);
            // Wait for the opened menu through the item itself.
            const sub2 = menuOf(hit);
            if (sub2 == null) return .{ .status = .path_missing };
            const listed = awaitItems(m.env, sub2, lim.deadline_ns);
            native.CFRelease(sub2);
            if (listed == 0) return .{ .status = .open_failed };
            arrs_parent = hit;
            is_bar = false;
        }
        return .{ .status = .path_missing };
    }
} else struct {};

fn writeMenu(out: *Io.Writer, req: MenuRequest, r: MenuReport) Io.Writer.Error!void {
    try out.print("pid\t{d}\nstatus\t{s}\n", .{ req.pid, @tagName(r.status) });
    if (r.actual_path) |p| try kv(out, "actual_executable", p);
    if (r.reason.len > 0) try kv(out, "reason", r.reason);
    for (req.items) |it| try kv(out, "item", it);
    if (r.tree) |t| {
        try out.print("nodes\t{d}\ttruncated={}\ttimed_out={}\topened={d}\n", .{ t.nodes.len, t.truncated, t.timed_out, t.opened });
        if (r.status == .read or r.status == .pressed or r.status == .press_failed) {
            // A targeted read walks only the selected subtree, so its flag is that subtree's.
            if (req.items.len > 0) try out.print("selected\t{d}\ttruncated={}\n", .{ r.sel_to - r.sel_from, t.truncated });
            for (t.nodes[r.sel_from..r.sel_to]) |n| {
                try out.print("menu\t{d}\t", .{n.depth});
                try escapeInto(out, n.role);
                try out.writeByte('\t');
                try escapeInto(out, n.title);
                try out.print("\t{?}\tsubmenu={}\texpanded={}\n", .{ n.enabled, n.submenu, n.expanded });
            }
        }
    }
    if (r.press) |p| try out.print("press_status\t{s}\npress_ax_code\t{d}\n", .{ @tagName(p.status), p.code });
    try out.print("result\t{s}\n", .{if (r.ok()) "ok" else "failed"});
}

const MenuArgs = union(enum) { ok: MenuRequest, bad: []const u8 };

fn parseMenuArgs(a: Allocator, argv: []const []const u8) Allocator.Error!MenuArgs {
    var req: MenuRequest = .{ .pid = 0, .expected_executable = "" };
    var items: std.ArrayList([]const u8) = .empty;
    var have_pid = false;
    var have_exe = false;
    var have_timeout = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--materialize")) {
            if (req.materialize) return .{ .bad = "option repeated" };
            req.materialize = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--press")) {
            if (req.press) return .{ .bad = "option repeated" };
            req.press = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        const known = [_][]const u8{ "--pid", "--expected-executable", "--timeout-ms", "--item" };
        var is_known = false;
        for (known) |k| is_known = is_known or std.mem.eql(u8, k, name);
        if (!is_known) return .{ .bad = "unknown option" };
        const v: []const u8 = if (eq) |e| arg[e + 1 ..] else blk: {
            if (i + 1 >= argv.len) return .{ .bad = "option needs a value" };
            i += 1;
            break :blk argv[i];
        };
        if (std.mem.eql(u8, name, "--pid")) {
            if (have_pid) return .{ .bad = "option repeated" };
            have_pid = true;
            req.pid = std.fmt.parseInt(i32, v, 10) catch return .{ .bad = "--pid is not a number" };
        } else if (std.mem.eql(u8, name, "--expected-executable")) {
            if (have_exe) return .{ .bad = "option repeated" };
            have_exe = true;
            req.expected_executable = v;
        } else if (std.mem.eql(u8, name, "--timeout-ms")) {
            if (have_timeout) return .{ .bad = "option repeated" };
            have_timeout = true;
            req.timeout_ms = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = "--timeout-ms is not a number" };
        } else {
            if (v.len == 0 or v.len > 256 or hasControlByte(v)) return .{ .bad = "--item needs a non-empty label without control bytes" };
            if (items.items.len >= max_menu_path) return .{ .bad = "too many --item labels" };
            try items.append(a, v);
        }
    }
    if (!have_pid) return .{ .bad = "--pid is required" };
    if (!have_exe) return .{ .bad = "--expected-executable is required" };
    if (req.pid <= 1) return .{ .bad = "pid must be greater than 1" };
    const e = req.expected_executable;
    if (e.len == 0 or e[0] != '/' or e.len > 1024 or hasControlByte(e)) return .{ .bad = "--expected-executable must be an absolute path without control bytes" };
    if (req.press and items.items.len < 2) return .{ .bad = "--press needs two or more --item labels" };
    if (req.timeout_ms == 0 or req.timeout_ms > 60_000) return .{ .bad = "--timeout-ms must be 1 to 60000" };
    req.items = items.items;
    return .{ .ok = req };
}

/// `vwx ui-menu`. Exit 0 read or pressed, 1 refused or failed, 2 usage.
pub fn runMenuCli(gpa: Allocator, io: Io, argv: []const []const u8, out: *Io.Writer) u8 {
    if (@import("builtin").os.tag != .macos) return runMenuWith(gpa, argv, out, null);
    var se: nur.SystemEnv = .{ .io = io };
    var m: native_menu.Mn = .{ .env = se.env() };
    return runMenuWith(gpa, argv, out, m.backend());
}

pub fn runMenuWith(gpa: Allocator, argv: []const []const u8, out: *Io.Writer, backend: ?MenuBackend) u8 {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h") or std.mem.eql(u8, argv[0], "help"))) {
        out.writeAll(menu_usage_text) catch {};
        out.flush() catch {};
        return 0;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = parseMenuArgs(arena.allocator(), argv) catch return 1;
    const req = switch (parsed) {
        .bad => |why| {
            out.print("error\t{s}\n", .{why}) catch {};
            out.writeAll(menu_usage_text) catch {};
            out.flush() catch {};
            return 2;
        },
        .ok => |r| r,
    };
    const b = backend orelse {
        out.writeAll("error\tui-menu needs macOS\n") catch {};
        out.flush() catch {};
        return 1;
    };
    var buf: [4096]u8 = undefined;
    const rep = menu(arena.allocator(), b, req, &buf);
    writeMenu(out, req, rep) catch {};
    out.flush() catch {};
    return if (rep.ok()) 0 else 1;
}

const FakeMenu = struct {
    path: ?[]const u8 = "/Apps/Vectorworks",
    later_path: ?[]const u8 = null,
    reads: []const MenuRead,
    press_out: MenuPressOutcome = .{ .status = .pressed },
    path_calls: usize = 0,
    read_calls: usize = 0,
    press_calls: usize = 0,
    last_materialize: bool = false,
    last_depth: u8 = 0,
    last_nodes: usize = 0,
    pressed: [max_menu_path][]const u8 = undefined,
    pressed_n: usize = 0,
    clock: u64 = 0,

    fn backend(f: *FakeMenu) MenuBackend {
        return .{ .ptr = f, .pathFn = pathFn, .readFn = readFn, .pressFn = pressFn, .nowFn = nowFn };
    }
    fn pathFn(ptr: *anyopaque, _: i32, buf: []u8) ?[]const u8 {
        const f: *FakeMenu = @ptrCast(@alignCast(ptr));
        f.path_calls += 1;
        const p = (if (f.path_calls > 1 and f.later_path != null) f.later_path else f.path) orelse return null;
        @memcpy(buf[0..p.len], p);
        return buf[0..p.len];
    }
    fn readFn(ptr: *anyopaque, _: Allocator, _: i32, _: []const []const u8, materialize: bool, lim: MenuLimits) MenuRead {
        const f: *FakeMenu = @ptrCast(@alignCast(ptr));
        const i = @min(f.read_calls, f.reads.len - 1);
        f.read_calls += 1;
        f.last_materialize = materialize;
        f.last_depth = lim.max_depth;
        f.last_nodes = lim.max_nodes;
        return f.reads[i];
    }
    fn pressFn(ptr: *anyopaque, _: i32, path: []const []const u8, _: MenuLimits) MenuPressOutcome {
        const f: *FakeMenu = @ptrCast(@alignCast(ptr));
        f.press_calls += 1;
        for (path, 0..) |p, k| f.pressed[k] = p;
        f.pressed_n = path.len;
        return f.press_out;
    }
    fn nowFn(ptr: *anyopaque) u64 {
        const f: *FakeMenu = @ptrCast(@alignCast(ptr));
        f.clock += 1;
        return f.clock;
    }
};

const menu_nodes = [_]MenuNode{
    .{ .depth = 0, .role = "AXMenuBarItem", .title = "Vectorworks", .enabled = true, .submenu = true, .expanded = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "About Vectorworks 2027", .enabled = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "Quit Vectorworks", .enabled = true },
    .{ .depth = 0, .role = "AXMenuBarItem", .title = "File", .enabled = true, .submenu = true, .expanded = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "Save", .enabled = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "Export", .enabled = true, .submenu = true, .expanded = true },
    .{ .depth = 2, .role = "AXMenuItem", .title = "Export STL…", .enabled = true },
    .{ .depth = 2, .role = "AXMenuItem", .title = "Export OBJ…", .enabled = false },
    .{ .depth = 2, .role = "AXMenuItem", .title = "Close", .enabled = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "Close", .enabled = true },
    .{ .depth = 0, .role = "AXMenuBarItem", .title = "Edit", .enabled = true, .submenu = true, .expanded = false },
};
const menu_read: MenuRead = .{ .menu = .{ .nodes = &menu_nodes } };

fn menuReq(items: []const []const u8, press: bool) MenuRequest {
    return .{ .pid = 10012, .expected_executable = "/Apps/Vectorworks", .items = items, .press = press };
}

fn runMenu(f: *FakeMenu, req: MenuRequest) MenuReport {
    var buf: [4096]u8 = undefined;
    return menu(testing.allocator, f.backend(), req, &buf);
}

test "ui-menu path resolution needs exactly one exact title at each level" {
    const sub = resolvePath(&menu_nodes, &.{ "File", "Export" }).found;
    try testing.expectEqual(@as(usize, 5), sub.index);
    try testing.expectEqual(@as(usize, 9), sub.end);
    try testing.expectEqual(@as(usize, 0), resolvePath(&menu_nodes, &.{"Vectorworks"}).found.index);
    try testing.expect(resolvePath(&menu_nodes, &.{ "File", "export" }) == .missing);
    try testing.expect(resolvePath(&menu_nodes, &.{ "File", "Export", "Export STL" }) == .missing);
    try testing.expect(resolvePath(&menu_nodes, &.{ "File", "Close" }) == .found);
    // The two Close items sit at different depths of different parents.
    try testing.expectEqual(@as(usize, 8), resolvePath(&menu_nodes, &.{ "File", "Export", "Close" }).found.index);
    const dup = [_]MenuNode{
        .{ .depth = 0, .title = "File" },
        .{ .depth = 1, .title = "Save" },
        .{ .depth = 1, .title = "Save" },
    };
    try testing.expect(resolvePath(&dup, &.{ "File", "Save" }) == .ambiguous);
    const dup0 = [_]MenuNode{ .{ .depth = 0, .title = "File" }, .{ .depth = 0, .title = "File" } };
    try testing.expect(resolvePath(&dup0, &.{"File"}) == .ambiguous);
}

test "ui-menu reads by default, selects a subtree and widens the depth bound to the path" {
    var f: FakeMenu = .{ .reads = &.{menu_read} };
    var r = runMenu(&f, menuReq(&.{}, false));
    try testing.expectEqual(MenuStatus.read, r.status);
    try testing.expectEqual(@as(usize, 11), r.sel_to);
    try testing.expect(!f.last_materialize);
    r = runMenu(&f, menuReq(&.{ "File", "Export" }, false));
    try testing.expectEqual(MenuStatus.read, r.status);
    try testing.expectEqual(@as(usize, 4), r.sel_to - r.sel_from);
    try testing.expectEqual(@as(usize, 0), f.press_calls);
    try testing.expectEqual(@as(u8, 5), f.last_depth);
    try testing.expectEqual(@as(usize, 400), f.last_nodes);
    r = runMenu(&f, menuReq(&.{ "A", "B", "C", "D", "E", "F" }, false));
    try testing.expectEqual(@as(u8, 6), f.last_depth);
    try testing.expectEqual(MenuStatus.refused_path_missing, r.status);
}

test "ui-menu presses About and File Export leaves after two reads and an identity recheck" {
    var f: FakeMenu = .{ .reads = &.{menu_read} };
    var r = runMenu(&f, menuReq(&.{ "Vectorworks", "About Vectorworks 2027" }, true));
    try testing.expectEqual(MenuStatus.pressed, r.status);
    try testing.expectEqual(@as(usize, 1), f.press_calls);
    try testing.expectEqual(@as(usize, 2), f.read_calls);
    try testing.expectEqual(@as(usize, 2), f.path_calls);
    try testing.expect(f.last_materialize);
    try testing.expectEqualStrings("About Vectorworks 2027", f.pressed[1]);
    var g: FakeMenu = .{ .reads = &.{menu_read} };
    r = runMenu(&g, menuReq(&.{ "File", "Export", "Export STL…" }, true));
    try testing.expectEqual(MenuStatus.pressed, r.status);
    try testing.expectEqual(@as(usize, 3), g.pressed_n);
}

fn expectMenuRefused(want: MenuStatus, f: *FakeMenu, req: MenuRequest) !void {
    const r = runMenu(f, req);
    try testing.expectEqual(want, r.status);
    try testing.expect(!r.ok());
    try testing.expectEqual(@as(usize, 0), f.press_calls);
}

test "ui-menu refuses Quit, Close, destructive and other paths before any native call" {
    var f: FakeMenu = .{ .reads = &.{menu_read} };
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "Vectorworks", "Quit Vectorworks" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "File", "Close All" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "Edit", "Close" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "File", "Export", "Close" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "File", "Save" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "File", "Delete Everything", "About X" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "File", "Move to Trash" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "Edit", "Erase Selection" }, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{"File"}, true));
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "Window", "Export STL…" }, true));
    try testing.expectEqual(@as(usize, 0), f.path_calls + f.read_calls);
}

test "ui-menu presses the allowed exact paths" {
    for (menu_press_allow) |p| try testing.expect(pressPolicy(p) == null);
    try testing.expectEqual(@as(usize, 10), menu_press_allow.len);
    try testing.expect(pressPolicy(&.{ "File", "Close" }) == null);
    try testing.expect(pressPolicy(&.{ "View", "Class Options", "Show Others" }) == null);
    try testing.expect(pressPolicy(&.{ "View", "Layer Options", "Show Others" }) == null);
}

test "ui-menu keeps Quit, other Close paths and Delete refused and matches paths in full" {
    try testing.expect(pressPolicy(&.{ "File", "Close All" }) != null);
    try testing.expect(pressPolicy(&.{ "Edit", "Close" }) != null);
    try testing.expect(pressPolicy(&.{ "File", "Quit" }) != null);
    try testing.expect(pressPolicy(&.{ "View", "Delete Class", "Layer Options" }) != null);
    try testing.expect(pressPolicy(&.{ "View", "Zoom", "Delete Zoom" }) != null);
    try testing.expect(pressPolicy(&.{ "View", "Fit To Objects" }) != null);
    try testing.expect(pressPolicy(&.{ "Edit", "Zoom", "Fit To Objects" }) != null);
    try testing.expect(pressPolicy(&.{ "View", "Other", "Fit To Objects" }) != null);
    try testing.expect(pressPolicy(&.{ "View", "Zoom", "Fit To Objects", "More" }) != null);
    try testing.expect(pressPolicy(&.{ "View", "Zoom" }) != null);
    try testing.expect(pressPolicy(&.{ "view", "class options" }) != null);
}

test "ui-menu refusal text names both allowlists" {
    const why = pressPolicy(&.{ "File", "Save" }).?;
    try testing.expect(std.mem.indexOf(u8, why, "About items") != null);
    try testing.expect(std.mem.indexOf(u8, why, "File > Export items") != null);
    try testing.expect(std.mem.indexOf(u8, why, "allowed exact paths") != null);
}

test "ui-menu refuses a wrong executable, a missing or ambiguous path and a bad leaf" {
    var f: FakeMenu = .{ .path = "/Apps/Other", .reads = &.{menu_read} };
    try expectMenuRefused(.identity_mismatch, &f, menuReq(&.{ "File", "Export", "Export STL…" }, true));
    try testing.expectEqual(@as(usize, 0), f.read_calls);
    var g: FakeMenu = .{ .path = null, .reads = &.{menu_read} };
    try expectMenuRefused(.not_running, &g, menuReq(&.{}, false));
    var h: FakeMenu = .{ .reads = &.{menu_read} };
    try expectMenuRefused(.refused_path_missing, &h, menuReq(&.{ "File", "Export", "Export 3DS…" }, true));
    try expectMenuRefused(.refused_leaf_disabled, &h, menuReq(&.{ "File", "Export", "Export OBJ…" }, true));
    const subleaf = [_]MenuNode{ .{ .depth = 0, .role = "AXMenuBarItem", .title = "Vectorworks", .submenu = true, .expanded = true }, .{ .depth = 1, .role = "AXMenuItem", .title = "About More", .enabled = true, .submenu = true, .expanded = true } };
    var s: FakeMenu = .{ .reads = &.{.{ .menu = .{ .nodes = &subleaf } }} };
    try expectMenuRefused(.refused_leaf_submenu, &s, menuReq(&.{ "Vectorworks", "About More" }, true));
    const dup = [_]MenuNode{
        .{ .depth = 0, .role = "AXMenuBarItem", .title = "File", .submenu = true, .expanded = true },
        .{ .depth = 1, .role = "AXMenuItem", .title = "Export", .submenu = true, .expanded = true },
        .{ .depth = 2, .role = "AXMenuItem", .title = "Export STL…", .enabled = true },
        .{ .depth = 2, .role = "AXMenuItem", .title = "Export STL…", .enabled = true },
    };
    var d: FakeMenu = .{ .reads = &.{.{ .menu = .{ .nodes = &dup } }} };
    try expectMenuRefused(.refused_path_ambiguous, &d, menuReq(&.{ "File", "Export", "Export STL…" }, true));
    const bar_only = [_]MenuNode{.{ .depth = 0, .role = "AXMenuBarItem", .title = "About Box", .enabled = true }};
    var b: FakeMenu = .{ .reads = &.{.{ .menu = .{ .nodes = &bar_only } }} };
    try expectMenuRefused(.refused_path_missing, &b, menuReq(&.{ "About Box", "About Y" }, true));
    const as_bar = [_]MenuNode{ .{ .depth = 0, .role = "AXMenuBarItem", .title = "Vectorworks", .submenu = true, .expanded = true }, .{ .depth = 1, .role = "AXMenuBarItem", .title = "About X", .enabled = true } };
    var e: FakeMenu = .{ .reads = &.{.{ .menu = .{ .nodes = &as_bar } }} };
    try expectMenuRefused(.refused_not_an_item, &e, menuReq(&.{ "Vectorworks", "About X" }, true));
}

test "ui-menu rechecks identity and the path immediately before the press" {
    var f: FakeMenu = .{ .later_path = "/Apps/Reused", .reads = &.{menu_read} };
    try expectMenuRefused(.refused_identity_changed, &f, menuReq(&.{ "File", "Export", "Export STL…" }, true));
    const moved = [_]MenuNode{ menu_nodes[3], .{ .depth = 1, .role = "AXMenuItem", .title = "Export", .submenu = true, .expanded = true } };
    var g: FakeMenu = .{ .reads = &.{ menu_read, .{ .menu = .{ .nodes = &moved } } } };
    try expectMenuRefused(.refused_path_missing, &g, menuReq(&.{ "File", "Export", "Export STL…" }, true));
    try testing.expectEqual(@as(usize, 2), g.read_calls);
    var h: FakeMenu = .{ .reads = &.{ menu_read, .{ .failed = "the process exposes no AXMenuBar" } } };
    try expectMenuRefused(.read_failed, &h, menuReq(&.{ "File", "Export", "Export STL…" }, true));
    var k: FakeMenu = .{ .reads = &.{menu_read}, .press_out = .{ .status = .ax_error, .code = -25200 } };
    const r = runMenu(&k, menuReq(&.{ "Vectorworks", "About Vectorworks 2027" }, true));
    try testing.expectEqual(MenuStatus.press_failed, r.status);
    try testing.expectEqual(@as(i32, -25200), r.press.?.code);
}

test "ui-menu arguments are bounded and have no launch, quit or key route" {
    var f: FakeMenu = .{ .reads = &.{menu_read} };
    var w_buf: [16384]u8 = undefined;
    const bad = [_][]const []const u8{
        &.{},
        &.{ "--pid", "10012" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--press" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--press", "--item", "File" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--item", "" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--launch" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--quit" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--key", "x" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--item", "1", "--item", "2", "--item", "3", "--item", "4", "--item", "5", "--item", "6", "--item", "7" },
        &.{ "--pid", "10012", "--expected-executable", "/Apps/V", "--timeout-ms", "70000" },
        &.{ "--pid", "10012", "--expected-executable", "rel" },
        &.{ "--pid", "10012", "--pid", "5", "--expected-executable", "/Apps/V" },
    };
    for (bad) |argv| {
        var w: Io.Writer = .fixed(&w_buf);
        try testing.expectEqual(@as(u8, 2), runMenuWith(testing.allocator, argv, &w, f.backend()));
    }
    try testing.expectEqual(@as(usize, 0), f.path_calls);
    var w: Io.Writer = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 0), runMenuWith(testing.allocator, &.{ "--pid", "10012", "--expected-executable", "/Apps/Vectorworks", "--item", "File", "--item", "Export", "--materialize" }, &w, f.backend()));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "menu\t2\tAXMenuItem\tExport STL…\ttrue\tsubmenu=false\texpanded=false\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "menu\t0\tAXMenuBarItem\tEdit") == null);
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "result\tok\n"));
    try testing.expect(f.last_materialize);
}

test "ui-menu reports a truncated read and a deadline" {
    const t: MenuRead = .{ .menu = .{ .nodes = &menu_nodes, .truncated = true, .timed_out = true } };
    var f: FakeMenu = .{ .reads = &.{t} };
    var w_buf: [16384]u8 = undefined;
    var w: Io.Writer = .fixed(&w_buf);
    try testing.expectEqual(@as(u8, 0), runMenuWith(testing.allocator, &.{ "--pid", "10012", "--expected-executable", "/Apps/Vectorworks" }, &w, f.backend()));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "nodes\t11\ttruncated=true\ttimed_out=true\topened=0\n") != null);
}

const window_nodes = [_]MenuNode{
    .{ .depth = 0, .role = "AXMenuBarItem", .title = "File", .enabled = true, .submenu = true, .expanded = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "Close", .enabled = true },
    .{ .depth = 0, .role = "AXMenuBarItem", .title = "Window", .enabled = true, .submenu = true, .expanded = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "Untitled-1", .enabled = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "ref-a.vwx", .enabled = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "ref-b.vwx", .enabled = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "ref-dup.vwx", .enabled = true },
    .{ .depth = 1, .role = "AXMenuItem", .title = "ref-dup.vwx", .enabled = true },
};
const window_read: MenuRead = .{ .menu = .{ .nodes = &window_nodes } };

fn windowReq(items: []const []const u8, title: []const u8) MenuRequest {
    var r = menuReq(items, true);
    r.window_document = title;
    return r;
}

test "window document press accepts only Window and the authorized exact title" {
    var f: FakeMenu = .{ .reads = &.{window_read} };
    const rep = runMenu(&f, windowReq(&.{ "Window", "ref-a.vwx" }, "ref-a.vwx"));
    try testing.expectEqual(MenuStatus.pressed, rep.status);
    try testing.expectEqual(@as(usize, 1), f.press_calls);
    try testing.expectEqualStrings("ref-a.vwx", f.pressed[1]);
    // Another title, another menu, a longer path, a Close label and a non-document title are refused before any read.
    const refused = [_]struct { items: []const []const u8, title: []const u8 }{
        .{ .items = &.{ "Window", "ref-b.vwx" }, .title = "ref-a.vwx" },
        .{ .items = &.{ "File", "ref-a.vwx" }, .title = "ref-a.vwx" },
        .{ .items = &.{ "Window", "ref-a.vwx", "x" }, .title = "ref-a.vwx" },
        .{ .items = &.{ "File", "Close" }, .title = "Close" },
        .{ .items = &.{ "Window", "Untitled-1" }, .title = "Untitled-1" },
        .{ .items = &.{ "Window", "a/b.vwx" }, .title = "a/b.vwx" },
    };
    for (refused) |c| {
        var g: FakeMenu = .{ .reads = &.{window_read} };
        try expectMenuRefused(.refused_policy, &g, windowReq(c.items, c.title));
    }
}

test "window document press refuses a duplicate or missing title and an identity change" {
    var f: FakeMenu = .{ .reads = &.{window_read} };
    try expectMenuRefused(.refused_path_ambiguous, &f, windowReq(&.{ "Window", "ref-dup.vwx" }, "ref-dup.vwx"));
    var g: FakeMenu = .{ .reads = &.{window_read} };
    try expectMenuRefused(.refused_path_missing, &g, windowReq(&.{ "Window", "gone.vwx" }, "gone.vwx"));
    var h: FakeMenu = .{ .reads = &.{window_read}, .later_path = "/Apps/Other" };
    try expectMenuRefused(.refused_identity_changed, &h, windowReq(&.{ "Window", "ref-a.vwx" }, "ref-a.vwx"));
}

test "ui-menu policy is unchanged without a window document" {
    try testing.expect(pressPolicy(&.{ "Window", "ref-a.vwx" }) != null);
    var f: FakeMenu = .{ .reads = &.{window_read} };
    try expectMenuRefused(.refused_policy, &f, menuReq(&.{ "Window", "ref-a.vwx" }, true));
}
