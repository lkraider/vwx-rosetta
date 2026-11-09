//! Native Accessibility read and guarded setters for the controls of Vectorworks export dialogs.
//!
//! `vwx ui-export-control --native` reads one modal window through AXUIElement and never starts
//! System Events. The module has no clock and posts no keyboard event. It presses no button other
//! than the one checkbox, radio button or popup that the caller names, and never Save, Cancel or
//! Close. Every call reads the whole tree of the one window first. A tree that is truncated, has an
//! unreadable attribute or holds more than one candidate gives no target.
//!
//! Setters, each behind the same chain: explicit authorization token, exact expected current value,
//! a unique complete target, pid, executable, window, modal and owner checks, an immediate recheck of
//! the tree signature, one action and a read back through fresh snapshots.
//! - text_field: needs a settable AXValue. One AXValue write, no AXConfirm. The read back proves AXValue
//!   only. The application may not have committed the text to its model.
//! - checkbox and radio: one AXPress, read back must show the wanted 0 or 1. A radio takes only 1.
//! - popup: one AXPress opens the menu. The menu must be the one AXMenu child of the popup and hold
//!   exactly one enabled AXMenuItem with the wanted title. A second AXPress selects that item.
//! A failure after an action was dispatched is reported with `uncertain true`. Nothing is retried.
//! Other role kinds and the `title` selector are refused as unsupported.

const std = @import("std");
const builtin = @import("builtin");
const nur = @import("native_ui_runtime.zig");
const Allocator = std.mem.Allocator;

pub const Handle = usize;

pub const WindowRef = struct {
    h: Handle,
    title: ?[]const u8,
    /// Null when AXModal could not be read.
    modal: ?bool,
    /// AXUIElementGetPid of the window. Null when unreadable.
    owner_pid: ?i32,
};

pub const Attrs = struct {
    role: []const u8 = "",
    subrole: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    identifier: []const u8 = "",
    /// Text of a string, number or boolean AXValue. Null when the value is absent or not a scalar.
    value: ?[]const u8 = null,
    /// `string`, `number`, `boolean` or empty.
    value_kind: []const u8 = "",
    enabled: ?bool = null,
    /// AXUIElementIsAttributeSettable of AXValue. Null when it could not be read.
    value_settable: ?bool = null,
    /// AXMenuItemMarkChar.
    mark: []const u8 = "",
    /// False when an attribute read failed for a reason other than "no value".
    complete: bool = true,
};

/// Injectable AX source. A handle stays valid until the source is released. `null` replies are failures.
pub const Source = struct {
    ptr: *anyopaque,
    windowsFn: *const fn (ptr: *anyopaque, a: Allocator, pid: i32) ?[]WindowRef,
    childrenFn: *const fn (ptr: *anyopaque, a: Allocator, h: Handle) ?[]Handle,
    attrsFn: *const fn (ptr: *anyopaque, a: Allocator, h: Handle) ?Attrs,
    /// AXUIElementSetAttributeValue(AXValue, string). The AX error code, 0 for success.
    setTextFn: *const fn (ptr: *anyopaque, h: Handle, text: []const u8) i32,
    /// AXUIElementPerformAction(AXPress). The AX error code, 0 for success.
    pressFn: *const fn (ptr: *anyopaque, h: Handle) i32,
};

pub const max_nodes = 600;
pub const max_depth = 16;
const poll_count = 6;
const poll_ms = 100;

pub const Node = struct {
    h: Handle,
    parent: u32,
    depth: u8,
    a: Attrs,
    kids: []u32,
};

pub const no_parent: u32 = std.math.maxInt(u32);

pub const Snapshot = struct {
    win: WindowRef,
    nodes: []Node,
    truncated: bool,
    unreadable: bool,

    pub fn complete(s: Snapshot) bool {
        return !s.truncated and !s.unreadable;
    }

    /// Hash of the structure and of every value except static text, which may show live sizes.
    pub fn signature(s: Snapshot) u64 {
        var h = std.hash.Wyhash.init(0x4e58);
        for (s.nodes) |n| {
            h.update(std.mem.asBytes(&n.depth));
            h.update(n.a.role);
            h.update("\x00");
            h.update(n.a.subrole);
            h.update("\x00");
            h.update(n.a.title);
            h.update("\x00");
            h.update(n.a.identifier);
            h.update("\x00");
            h.update(std.mem.asBytes(&n.kids.len));
            if (!std.mem.eql(u8, n.a.role, "AXStaticText")) {
                h.update(n.a.description);
                h.update("\x00");
                h.update(n.a.value orelse "\x01");
                h.update("\x00");
                h.update(&[_]u8{if (n.a.enabled) |e| (if (e) 1 else 2) else 0});
            }
        }
        return h.final();
    }
};

const Walk = struct {
    a: Allocator,
    src: Source,
    nodes: std.ArrayList(Node) = .empty,
    truncated: bool = false,
    unreadable: bool = false,

    fn visit(w: *Walk, h: Handle, parent: u32, depth: u8) void {
        if (w.nodes.items.len >= max_nodes or depth > max_depth) {
            w.truncated = true;
            return;
        }
        const attrs = w.src.attrsFn(w.src.ptr, w.a, h) orelse {
            w.unreadable = true;
            return;
        };
        if (!attrs.complete or attrs.role.len == 0) w.unreadable = true;
        const idx: u32 = @intCast(w.nodes.items.len);
        w.nodes.append(w.a, .{ .h = h, .parent = parent, .depth = depth, .a = attrs, .kids = &.{} }) catch {
            w.unreadable = true;
            return;
        };
        const kids = w.src.childrenFn(w.src.ptr, w.a, h) orelse {
            w.unreadable = true;
            return;
        };
        var list: std.ArrayList(u32) = .empty;
        for (kids) |k| {
            const before: u32 = @intCast(w.nodes.items.len);
            w.visit(k, idx, depth + 1);
            if (w.nodes.items.len > before) list.append(w.a, before) catch {
                w.unreadable = true;
            };
        }
        w.nodes.items[idx].kids = list.toOwnedSlice(w.a) catch &.{};
    }
};

pub const SnapshotReply = union(enum) { ok: Snapshot, refused: []const u8 };

/// Reads the one modal window with exactly `title`, owned by `pid`, as a bounded tree.
pub fn snapshot(a: Allocator, src: Source, pid: i32, title: []const u8) SnapshotReply {
    const wins = src.windowsFn(src.ptr, a, pid) orelse return .{ .refused = "the window list of the process is unreadable" };
    var found: ?WindowRef = null;
    var n: u32 = 0;
    for (wins) |w| {
        const t = w.title orelse continue;
        if (!std.mem.eql(u8, t, title)) continue;
        n += 1;
        found = w;
    }
    if (n == 0) return .{ .refused = "no window has the exact title" };
    if (n > 1) return .{ .refused = "more than one window has the exact title" };
    const win = found.?;
    if (win.owner_pid == null or win.owner_pid.? != pid) return .{ .refused = "the window owner pid is unreadable or differs from --pid" };
    if (win.modal != true) return .{ .refused = "the window is not proven modal" };
    var w: Walk = .{ .a = a, .src = src };
    w.visit(win.h, no_parent, 0);
    return .{ .ok = .{ .win = win, .nodes = w.nodes.items, .truncated = w.truncated, .unreadable = w.unreadable } };
}

// Selectors

pub const Kind = union(enum) {
    /// AXTitle, or AXDescription when the title is empty, equals the text.
    label: []const u8,
    id: []const u8,
    /// The popup, checkbox... that directly follows the one AXStaticText with exactly this text.
    sibling: []const u8,
    path: []const nur.PathStep,
};

pub const Spec = struct { role: nur.Role, kind: Kind };

pub const ParseReply = union(enum) { ok: Spec, bad: []const u8, unsupported: []const u8 };

/// `ROLE/label/TEXT`, `ROLE/id/IDENT`, `ROLE/sibling/TEXT` or `ROLE/path/ROLE:INDEX:OF,...`.
pub fn parseSpec(a: Allocator, spec: []const u8) ParseReply {
    var it = std.mem.splitScalar(u8, spec, '/');
    const role = std.meta.stringToEnum(nur.Role, it.next() orelse return .{ .bad = "the selector has no role" }) orelse return .{ .bad = "the selector role is unknown" };
    const kind = it.next() orelse return .{ .bad = "the selector has no kind" };
    const text = it.rest();
    if (std.mem.eql(u8, kind, "title")) return .{ .unsupported = "the title selector (AXTitleUIElement) is not implemented natively. Use sibling, id, label or path" };
    if (text.len == 0) return .{ .bad = "the selector text is empty" };
    if (std.mem.eql(u8, kind, "label")) return .{ .ok = .{ .role = role, .kind = .{ .label = text } } };
    if (std.mem.eql(u8, kind, "id")) return .{ .ok = .{ .role = role, .kind = .{ .id = text } } };
    if (std.mem.eql(u8, kind, "sibling")) return .{ .ok = .{ .role = role, .kind = .{ .sibling = text } } };
    if (!std.mem.eql(u8, kind, "path")) return .{ .bad = "the selector kind is not label, id, sibling or path" };
    var steps: std.ArrayList(nur.PathStep) = .empty;
    var sit = std.mem.splitScalar(u8, text, ',');
    while (sit.next()) |s| {
        var p = std.mem.splitScalar(u8, s, ':');
        const r = std.meta.stringToEnum(nur.Role, p.next() orelse return .{ .bad = "a path step has no role" }) orelse return .{ .bad = "a path step role is unknown" };
        const idx = std.fmt.parseInt(u8, p.next() orelse return .{ .bad = "a path step has no index" }, 10) catch return .{ .bad = "a path step index is not a number" };
        const of = std.fmt.parseInt(u8, p.next() orelse return .{ .bad = "a path step has no count" }, 10) catch return .{ .bad = "a path step count is not a number" };
        if (p.next() != null or idx == 0 or of == 0 or idx > of) return .{ .bad = "a path step is malformed" };
        if (steps.items.len >= nur.max_path_steps) return .{ .bad = "a path has too many steps" };
        steps.append(a, .{ .role = r, .index = idx, .of = of }) catch return .{ .bad = "allocation failed" };
    }
    if (steps.items.len == 0 or steps.items[steps.items.len - 1].role != role) return .{ .bad = "the last path step must have the selector role" };
    return .{ .ok = .{ .role = role, .kind = .{ .path = steps.items } } };
}

pub const Resolved = union(enum) {
    one: u32,
    none: []const u8,
    many: usize,
};

fn isText(n: Node, text: []const u8) bool {
    if (!std.mem.eql(u8, n.a.role, "AXStaticText")) return false;
    const v = n.a.value orelse n.a.title;
    return std.mem.eql(u8, v, text);
}

pub fn resolve(s: Snapshot, spec: Spec) Resolved {
    const role = spec.role.axRole();
    switch (spec.kind) {
        .label, .id => {
            var count: usize = 0;
            var at: u32 = 0;
            for (s.nodes, 0..) |n, i| {
                if (!std.mem.eql(u8, n.a.role, role)) continue;
                const hit = switch (spec.kind) {
                    .label => |t| std.mem.eql(u8, n.a.title, t) or (n.a.title.len == 0 and std.mem.eql(u8, n.a.description, t)),
                    .id => |t| std.mem.eql(u8, n.a.identifier, t),
                    else => unreachable,
                };
                if (hit) {
                    count += 1;
                    at = @intCast(i);
                }
            }
            if (count == 0) return .{ .none = "no control of the role matches" };
            if (count > 1) return .{ .many = count };
            return .{ .one = at };
        },
        .sibling => |t| {
            var count: usize = 0;
            var at: u32 = 0;
            for (s.nodes, 0..) |n, i| if (isText(n, t)) {
                count += 1;
                at = @intCast(i);
            };
            if (count == 0) return .{ .none = "no static text has the label" };
            if (count > 1) return .{ .many = count };
            const parent = s.nodes[at].parent;
            if (parent == no_parent) return .{ .none = "the label has no parent" };
            const kids = s.nodes[parent].kids;
            for (kids, 0..) |k, pos| {
                if (k != at) continue;
                if (pos + 1 >= kids.len) return .{ .none = "no sibling follows the label" };
                const nx = kids[pos + 1];
                if (!std.mem.eql(u8, s.nodes[nx].a.role, role)) return .{ .none = "the sibling that follows the label has another role" };
                return .{ .one = nx };
            }
            return .{ .none = "the label is not among the children of its parent" };
        },
        .path => |steps| {
            var cur: u32 = 0;
            for (steps) |st| {
                var matching: usize = 0;
                var pick: u32 = 0;
                for (s.nodes[cur].kids) |k| {
                    if (!std.mem.eql(u8, s.nodes[k].a.role, st.role.axRole())) continue;
                    matching += 1;
                    if (matching == st.index) pick = k;
                }
                if (matching != st.of) return .{ .none = "a path step has another sibling count" };
                cur = pick;
            }
            if (cur == 0) return .{ .none = "the path is empty" };
            return .{ .one = cur };
        },
    }
}

// Command

pub const Mode = enum { tree, read, set };

pub const Request = struct {
    pid: i32,
    exe: []const u8,
    title: []const u8,
    mode: Mode,
    /// `--control`, as given. Null only for the tree.
    control: ?[]const u8 = null,
    /// The wanted value: 0 or 1 for a checkbox or radio, the item title for a popup, the text for a text field.
    want: ?[]const u8 = null,
    expect_current: ?[]const u8 = null,
    authorize: ?[]const u8 = null,
    apply: bool = false,
    /// `--sheet` was given. The native route reads windows only.
    sheet: bool = false,
};

/// The immediate recheck of the document gate and the pause between read backs.
pub const Gate = struct {
    ptr: *anyopaque,
    checkFn: *const fn (ptr: *anyopaque) bool,
    pauseFn: *const fn (ptr: *anyopaque, ms: u32) void,
};

pub const PathOf = *const fn (pid: i32, buf: []u8) ?[]const u8;

fn flat(out: *std.Io.Writer, key: []const u8, v: []const u8) void {
    out.print("{s}\t", .{key}) catch {};
    for (v) |c| out.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c) catch {};
    out.writeByte('\n') catch {};
}

fn flatOpt(out: *std.Io.Writer, key: []const u8, v: ?[]const u8) void {
    if (v) |s| flat(out, key, s) else out.print("{s}\t(unreadable)\n", .{key}) catch {};
}

fn refuse(out: *std.Io.Writer, why: []const u8) u8 {
    flat(out, "refused", why);
    out.writeAll("result\trefused\n") catch {};
    return 1;
}

fn failUncertain(out: *std.Io.Writer, why: []const u8) u8 {
    flat(out, "failure", "unknown_ui");
    flat(out, "detail", why);
    out.writeAll("uncertain\ttrue\nresult\tfailed\n") catch {};
    return 1;
}

fn processOk(req: Request, pathOf: PathOf) bool {
    var buf: [4096]u8 = undefined;
    const p = pathOf(req.pid, &buf) orelse return false;
    return std.mem.eql(u8, p, req.exe);
}

fn writeTree(out: *std.Io.Writer, s: Snapshot) void {
    out.print("nodes\t{d}\ttruncated={}\tunreadable={}\n", .{ s.nodes.len, s.truncated, s.unreadable }) catch {};
    for (s.nodes) |n| {
        out.print("node\t{d}\t", .{n.depth}) catch {};
        for ([_][]const u8{ n.a.role, n.a.subrole, n.a.title, n.a.value orelse "", n.a.description }) |f| {
            for (f) |c| out.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c) catch {};
            out.writeByte('\t') catch {};
        }
        (if (n.a.enabled) |e| out.print("{}", .{e}) else out.writeAll("null")) catch {};
        out.writeByte('\t') catch {};
        for (n.a.identifier) |c| out.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c) catch {};
        out.print("\t{s}\t", .{n.a.value_kind}) catch {};
        (if (n.a.value_settable) |e| out.print("settable={}", .{e}) else out.writeAll("settable=null")) catch {};
        out.writeByte('\n') catch {};
    }
    // The label that each popup would bind to: the static text directly before it.
    for (s.nodes, 0..) |n, i| {
        if (!std.mem.eql(u8, n.a.role, "AXPopUpButton") or n.parent == no_parent) continue;
        const kids = s.nodes[n.parent].kids;
        for (kids, 0..) |k, pos| {
            if (k != i) continue;
            if (pos > 0 and std.mem.eql(u8, s.nodes[kids[pos - 1]].a.role, "AXStaticText")) {
                const lt = s.nodes[kids[pos - 1]].a;
                out.print("popup_label\t{d}\t", .{i}) catch {};
                for (lt.value orelse lt.title) |c| out.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c) catch {};
                out.writeByte('\n') catch {};
            }
        }
    }
}

fn printNode(out: *std.Io.Writer, key: []const u8, s: Snapshot, idx: u32) void {
    const n = s.nodes[idx];
    out.print("{s}\tnode\t{d}\tdepth\t{d}\tenabled\t{s}\tsettable\t{s}\n", .{
        key,
        idx,
        n.depth,
        if (n.a.enabled) |e| (if (e) "true" else "false") else "unreadable",
        if (n.a.value_settable) |e| (if (e) "true" else "false") else "unreadable",
    }) catch {};
    flat(out, "role", n.a.role);
    flat(out, "value_kind", n.a.value_kind);
    flatOpt(out, "value", n.a.value);
}

const Target = struct { snap: Snapshot, idx: u32 };

/// One snapshot and the one control that `spec` names in it, or a refusal reason.
fn locate(a: Allocator, src: Source, req: Request, spec: Spec) union(enum) { ok: Target, refused: []const u8 } {
    const s = switch (snapshot(a, src, req.pid, req.title)) {
        .refused => |why| return .{ .refused = why },
        .ok => |s| s,
    };
    if (!s.complete()) return .{ .refused = "the tree of the window is truncated or has an unreadable attribute, so the target is not proven unique" };
    return switch (resolve(s, spec)) {
        .none => |why| .{ .refused = why },
        .many => .{ .refused = "more than one control matches, the target is not unique" },
        .one => |i| .{ .ok = .{ .snap = s, .idx = i } },
    };
}

fn numberText(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    const x = std.fmt.parseFloat(f64, s) catch return null;
    if (x == 0) return "0";
    if (x == 1) return "1";
    return null;
}

/// The text a control reads as for the comparison with the expected and wanted values.
fn readText(role: nur.Role, n: Node) ?[]const u8 {
    switch (role) {
        .checkbox, .radio => {
            if (!std.mem.eql(u8, n.a.value_kind, "number")) return null;
            return numberText(n.a.value);
        },
        .text_field, .popup => {
            if (!std.mem.eql(u8, n.a.value_kind, "string")) return null;
            return n.a.value;
        },
        else => return null,
    }
}

pub fn authorizationToken(a: Allocator, req: Request) ?[]const u8 {
    return std.fmt.allocPrint(a, "native-set pid={d} window={s} control={s} from={s} to={s}", .{ req.pid, req.title, req.control orelse "", req.expect_current orelse "", req.want orelse "" }) catch null;
}

pub const supported_roles = "text_field, checkbox, radio, popup";

pub fn run(a: Allocator, out: *std.Io.Writer, req: Request, src: Source, pathOf: PathOf, gate: Gate) u8 {
    flat(out, "route", "native-ax");
    flat(out, "native_mode", @tagName(req.mode));
    if (req.sheet) return refuse(out, "--sheet is not supported by the native route");
    if (!processOk(req, pathOf)) return refuse(out, "the executable of the pid is not the expected executable");

    if (req.mode == .tree) {
        const s = switch (snapshot(a, src, req.pid, req.title)) {
            .refused => |why| return refuse(out, why),
            .ok => |s| s,
        };
        writeTree(out, s);
        out.print("signature\t{x}\n", .{s.signature()}) catch {};
        if (!s.complete()) return refuse(out, "the tree is incomplete");
        out.writeAll("result\tok\n") catch {};
        return 0;
    }

    const spec = switch (parseSpec(a, req.control orelse return refuse(out, "no control"))) {
        .bad => |why| return refuse(out, why),
        .unsupported => |why| {
            flat(out, "unsupported", why);
            out.writeAll("result\trefused\n") catch {};
            return 1;
        },
        .ok => |sp| sp,
    };
    const t1 = switch (locate(a, src, req, spec)) {
        .refused => |why| return refuse(out, why),
        .ok => |t| t,
    };
    printNode(out, "control", t1.snap, t1.idx);
    const node = t1.snap.nodes[t1.idx];
    out.print("signature\t{x}\n", .{t1.snap.signature()}) catch {};
    if (req.mode == .read) {
        out.writeAll("result\tok\n") catch {};
        return 0;
    }

    // Set. The authorization and the expected value come first, with or without --apply.
    switch (spec.role) {
        .text_field, .checkbox, .radio, .popup => {},
        else => {
            flat(out, "unsupported", "this control kind has no native setter. Supported: " ++ supported_roles);
            out.writeAll("result\trefused\n") catch {};
            return 1;
        },
    }
    const want = req.want orelse return refuse(out, "no wanted value");
    const expect = req.expect_current orelse return refuse(out, "--expect-current is required for a native set");
    const cur = readText(spec.role, node) orelse return refuse(out, "the current value is unreadable or has an unexpected type");
    if (!std.mem.eql(u8, cur, expect)) {
        flat(out, "current", cur);
        return refuse(out, "the current value is not the expected value");
    }
    if (node.a.enabled != true) return refuse(out, "the control is not enabled");
    if (spec.role == .text_field and node.a.value_settable != true) return refuse(out, "AXValue of the text field is not settable");
    if (spec.role == .radio and !std.mem.eql(u8, want, "1")) return refuse(out, "a radio button can only be selected");
    if (std.mem.eql(u8, cur, want)) {
        flat(out, "unchanged", "the control already holds the wanted value. Nothing was changed");
        out.writeAll("result\tok\n") catch {};
        return 0;
    }
    const token = authorizationToken(a, req) orelse return refuse(out, "allocation failed");
    if (!req.apply) {
        flat(out, "plan", "set the control natively; nothing was changed because --apply is absent");
        flat(out, "authorization_required", token);
        out.writeAll("result\tok\n") catch {};
        return 0;
    }
    const given = req.authorize orelse return refuse(out, "--authorize is required with --apply");
    if (!std.mem.eql(u8, given, token)) return refuse(out, "--authorize does not equal the authorization of this exact change");

    // Immediate recheck: the document gate, the process and a second proof that must equal the first.
    if (!gate.checkFn(gate.ptr)) return refuse(out, "the document gate no longer matches");
    if (!processOk(req, pathOf)) return refuse(out, "the executable of the pid changed");
    const t2 = switch (locate(a, src, req, spec)) {
        .refused => |why| return refuse(out, why),
        .ok => |t| t,
    };
    if (t2.snap.signature() != t1.snap.signature() or t2.idx != t1.idx) return refuse(out, "the dialog changed between the proof and the action");
    const n2 = t2.snap.nodes[t2.idx];
    const cur2 = readText(spec.role, n2) orelse return refuse(out, "the current value became unreadable");
    if (!std.mem.eql(u8, cur2, expect) or n2.a.enabled != true) return refuse(out, "the control changed between the proof and the action");

    switch (spec.role) {
        .text_field => {
            flat(out, "dispatch", "AXValue write");
            const code = src.setTextFn(src.ptr, n2.h, want);
            if (code != 0) {
                var b: [64]u8 = undefined;
                return failUncertain(out, std.fmt.bufPrint(&b, "AXValue write returned AX error {d} after dispatch", .{code}) catch "AXValue write failed");
            }
        },
        .checkbox, .radio => {
            flat(out, "dispatch", "AXPress");
            const code = src.pressFn(src.ptr, n2.h);
            if (code != 0) {
                var b: [64]u8 = undefined;
                return failUncertain(out, std.fmt.bufPrint(&b, "AXPress returned AX error {d} after dispatch", .{code}) catch "AXPress failed");
            }
        },
        .popup => if (popupSelect(a, out, src, n2, want, gate, req, pathOf)) |rc| return rc,
        else => unreachable,
    }
    return readBack(a, out, src, req, spec, want, gate);
}

/// Opens the menu with one press, proves the menu and the exact item, presses the item. Null on success
/// of both dispatches. The read back follows in the caller.
fn popupSelect(a: Allocator, out: *std.Io.Writer, src: Source, popup: Node, want: []const u8, gate: Gate, req: Request, pathOf: PathOf) ?u8 {
    flat(out, "dispatch", "AXPress popup");
    const code = src.pressFn(src.ptr, popup.h);
    if (code != 0) return failUncertain(out, "the popup press returned an AX error after dispatch. The menu may be open");
    const kids = src.childrenFn(src.ptr, a, popup.h) orelse return failUncertain(out, "the popup was pressed and its children are unreadable. The menu may be open");
    var menu: ?Handle = null;
    var menus: u32 = 0;
    for (kids) |k| {
        const at = src.attrsFn(src.ptr, a, k) orelse return failUncertain(out, "the popup was pressed and a child is unreadable. The menu may be open");
        if (std.mem.eql(u8, at.role, "AXMenu")) {
            menus += 1;
            menu = k;
        }
    }
    if (menus != 1) return failUncertain(out, "the popup was pressed but exactly one AXMenu child is not proven. No item was pressed. The menu may be open");
    const menu_items = src.childrenFn(src.ptr, a, menu.?) orelse return failUncertain(out, "the menu items are unreadable. No item was pressed. The menu may be open");
    var hit: ?Handle = null;
    var hits: u32 = 0;
    for (menu_items) |it| {
        const at = src.attrsFn(src.ptr, a, it) orelse return failUncertain(out, "a menu item is unreadable. No item was pressed. The menu may be open");
        if (!std.mem.eql(u8, at.role, "AXMenuItem") or !std.mem.eql(u8, at.title, want)) continue;
        if (at.enabled != true) return failUncertain(out, "the wanted menu item is not enabled. No item was pressed. The menu may be open");
        hits += 1;
        hit = it;
    }
    if (hits != 1) return failUncertain(out, "the wanted menu item is not exactly one. No item was pressed. The menu may be open");
    flat(out, "menu_item", want);
    if (!gate.checkFn(gate.ptr) or !processOk(req, pathOf)) return failUncertain(out, "the document gate no longer matches after the menu opened. No item was pressed. The menu may be open");
    flat(out, "dispatch", "AXPress menu item");
    if (src.pressFn(src.ptr, hit.?) != 0) return failUncertain(out, "the menu item press returned an AX error after dispatch");
    return null;
}

fn readBack(a: Allocator, out: *std.Io.Writer, src: Source, req: Request, spec: Spec, want: []const u8, gate: Gate) u8 {
    var last: []const u8 = "(unreadable)";
    var i: u32 = 0;
    while (i < poll_count) : (i += 1) {
        if (i > 0) gate.pauseFn(gate.ptr, poll_ms);
        const t = switch (locate(a, src, req, spec)) {
            .refused => |why| {
                flat(out, "readback_refused", why);
                continue;
            },
            .ok => |t| t,
        };
        const n = t.snap.nodes[t.idx];
        if (readText(spec.role, n)) |v| {
            last = v;
            if (std.mem.eql(u8, v, want)) {
                // A popup must also have closed its menu again: no AXMenu child.
                var menu_open = false;
                if (spec.role == .popup) {
                    for (n.kids) |k| if (std.mem.eql(u8, t.snap.nodes[k].a.role, "AXMenu")) {
                        menu_open = true;
                    };
                }
                if (menu_open) {
                    flat(out, "readback_refused", "the popup menu is still open");
                    continue;
                }
                flat(out, "set_readback", v);
                flat(out, "readback_matches_request", "yes");
                out.writeAll("result\tok\n") catch {};
                return 0;
            }
        }
    }
    flat(out, "set_readback", last);
    flat(out, "readback_matches_request", "no");
    out.writeAll("uncertain\ttrue\nresult\tfailed\n") catch {};
    return 1;
}

// macOS source

pub const MacSource = if (builtin.os.tag == .macos) struct {
    const Ref = ?*anyopaque;
    extern "c" fn AXUIElementCreateApplication(pid: c_int) Ref;
    extern "c" fn AXUIElementSetMessagingTimeout(el: Ref, seconds: f32) i32;
    extern "c" fn AXUIElementCopyAttributeValue(el: Ref, attr: Ref, out: *Ref) i32;
    extern "c" fn AXUIElementSetAttributeValue(el: Ref, attr: Ref, value: Ref) i32;
    extern "c" fn AXUIElementIsAttributeSettable(el: Ref, attr: Ref, out: *u8) i32;
    extern "c" fn AXUIElementPerformAction(el: Ref, action: Ref) i32;
    extern "c" fn AXUIElementGetPid(el: Ref, pid: *c_int) i32;
    extern "c" fn CFStringCreateWithCString(alloc: Ref, s: [*:0]const u8, encoding: u32) Ref;
    extern "c" fn CFStringGetTypeID() usize;
    extern "c" fn CFStringGetCString(s: Ref, buf: [*]u8, size: isize, encoding: u32) u8;
    extern "c" fn CFRelease(r: Ref) void;
    extern "c" fn CFRetain(r: Ref) Ref;
    extern "c" fn CFGetTypeID(r: Ref) usize;
    extern "c" fn CFBooleanGetTypeID() usize;
    extern "c" fn CFBooleanGetValue(r: Ref) u8;
    extern "c" fn CFArrayGetTypeID() usize;
    extern "c" fn CFArrayGetCount(r: Ref) isize;
    extern "c" fn CFArrayGetValueAtIndex(r: Ref, i: isize) Ref;
    extern "c" fn CFNumberGetTypeID() usize;
    extern "c" fn CFNumberIsFloatType(n: Ref) u8;
    extern "c" fn CFNumberGetValue(n: Ref, kind: i32, out: *anyopaque) u8;
    const utf8: u32 = 0x08000100;
    const ax_no_value: i32 = -25212;
    const ax_attr_unsupported: i32 = -25205;
    const buf_len = 4096;

    gpa: Allocator,
    app: Ref = null,
    pid: i32 = 0,
    /// Retained elements that handles refer to. Released in `deinit`.
    refs: std.ArrayList(Ref) = .empty,

    pub fn init(gpa: Allocator) @This() {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *@This()) void {
        for (m.refs.items) |r| CFRelease(r);
        m.refs.deinit(m.gpa);
        if (m.app) |p| CFRelease(p);
    }

    pub fn source(m: *@This()) Source {
        return .{ .ptr = m, .windowsFn = windowsImpl, .childrenFn = childrenImpl, .attrsFn = attrsImpl, .setTextFn = setTextImpl, .pressFn = pressImpl };
    }

    fn self(p: *anyopaque) *@This() {
        return @ptrCast(@alignCast(p));
    }

    fn key(name: [*:0]const u8) Ref {
        return CFStringCreateWithCString(null, name, utf8);
    }

    fn el(h: Handle) Ref {
        return @ptrFromInt(h);
    }

    /// Retains and keeps the element. Returns its handle.
    fn keep(m: *@This(), r: Ref) ?Handle {
        const k = CFRetain(r);
        m.refs.append(m.gpa, k) catch {
            CFRelease(k);
            return null;
        };
        return @intFromPtr(k);
    }

    const Read = union(enum) { value: Ref, absent, failed };

    fn copy(e: Ref, name: [*:0]const u8) Read {
        const k = key(name);
        defer CFRelease(k);
        var v: Ref = null;
        const code = AXUIElementCopyAttributeValue(e, k, &v);
        if (code == 0 and v != null) return .{ .value = v };
        if (v != null) CFRelease(v);
        if (code == ax_no_value or code == ax_attr_unsupported or code == 0) return .absent;
        return .failed;
    }

    /// A string attribute. Null when it failed or does not fit the buffer: a text is never cut.
    fn str(a: Allocator, e: Ref, name: [*:0]const u8, ok: *bool) []const u8 {
        switch (copy(e, name)) {
            .absent => return "",
            .failed => {
                ok.* = false;
                return "";
            },
            .value => |v| {
                defer CFRelease(v);
                if (CFGetTypeID(v) != CFStringGetTypeID()) {
                    ok.* = false;
                    return "";
                }
                var tmp: [buf_len]u8 = undefined;
                if (CFStringGetCString(v, &tmp, tmp.len, utf8) == 0) {
                    ok.* = false;
                    return "";
                }
                return a.dupe(u8, std.mem.sliceTo(&tmp, 0)) catch {
                    ok.* = false;
                    return "";
                };
            },
        }
    }

    fn flag(e: Ref, name: [*:0]const u8) ?bool {
        switch (copy(e, name)) {
            .value => |v| {
                defer CFRelease(v);
                if (CFGetTypeID(v) != CFBooleanGetTypeID()) return null;
                return CFBooleanGetValue(v) != 0;
            },
            else => return null,
        }
    }

    fn windowsImpl(ptr: *anyopaque, a: Allocator, pid: i32) ?[]WindowRef {
        const m = self(ptr);
        if (m.app == null or m.pid != pid) {
            if (m.app) |p| CFRelease(p);
            m.app = AXUIElementCreateApplication(pid);
            m.pid = pid;
        }
        if (m.app == null) return null;
        _ = AXUIElementSetMessagingTimeout(m.app, 2.0);
        const arr = switch (copy(m.app, "AXWindows")) {
            .value => |v| v,
            else => return null,
        };
        defer CFRelease(arr);
        if (CFGetTypeID(arr) != CFArrayGetTypeID()) return null;
        const n: usize = @intCast(CFArrayGetCount(arr));
        var list: std.ArrayList(WindowRef) = .empty;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const w = CFArrayGetValueAtIndex(arr, @intCast(i));
            const h = m.keep(w) orelse return null;
            var ok = true;
            const title = str(a, w, "AXTitle", &ok);
            var opid: c_int = 0;
            const got = AXUIElementGetPid(w, &opid) == 0;
            list.append(a, .{ .h = h, .title = if (ok) title else null, .modal = flag(w, "AXModal"), .owner_pid = if (got) opid else null }) catch return null;
        }
        return list.items;
    }

    fn childrenImpl(ptr: *anyopaque, a: Allocator, h: Handle) ?[]Handle {
        const m = self(ptr);
        const arr = switch (copy(el(h), "AXChildren")) {
            .value => |v| v,
            .absent => return &.{},
            .failed => return null,
        };
        defer CFRelease(arr);
        if (CFGetTypeID(arr) != CFArrayGetTypeID()) return null;
        const n: usize = @intCast(CFArrayGetCount(arr));
        if (n > max_nodes) return null;
        const out = a.alloc(Handle, n) catch return null;
        for (out, 0..) |*slot, i| slot.* = m.keep(CFArrayGetValueAtIndex(arr, @intCast(i))) orelse return null;
        return out;
    }

    fn attrsImpl(ptr: *anyopaque, a: Allocator, h: Handle) ?Attrs {
        _ = ptr;
        const e = el(h);
        var ok = true;
        var r: Attrs = .{};
        r.role = str(a, e, "AXRole", &ok);
        r.subrole = str(a, e, "AXSubrole", &ok);
        r.title = str(a, e, "AXTitle", &ok);
        r.description = str(a, e, "AXDescription", &ok);
        r.identifier = str(a, e, "AXIdentifier", &ok);
        r.mark = str(a, e, "AXMenuItemMarkChar", &ok);
        r.enabled = flag(e, "AXEnabled");
        switch (copy(e, "AXValue")) {
            .absent => {},
            .failed => ok = false,
            .value => |v| {
                defer CFRelease(v);
                const t = CFGetTypeID(v);
                if (t == CFStringGetTypeID()) {
                    var tmp: [buf_len]u8 = undefined;
                    if (CFStringGetCString(v, &tmp, tmp.len, utf8) == 0) {
                        ok = false;
                    } else {
                        r.value = a.dupe(u8, std.mem.sliceTo(&tmp, 0)) catch null;
                        r.value_kind = "string";
                    }
                } else if (t == CFBooleanGetTypeID()) {
                    r.value = if (CFBooleanGetValue(v) != 0) "1" else "0";
                    r.value_kind = "boolean";
                } else if (t == CFNumberGetTypeID()) {
                    if (CFNumberIsFloatType(v) != 0) {
                        var f: f64 = 0;
                        if (CFNumberGetValue(v, 13, &f) != 0) r.value = std.fmt.allocPrint(a, "{d}", .{f}) catch null;
                    } else {
                        var i: i64 = 0;
                        if (CFNumberGetValue(v, 4, &i) != 0) r.value = std.fmt.allocPrint(a, "{d}", .{i}) catch null;
                    }
                    r.value_kind = "number";
                    if (r.value == null) ok = false;
                }
            },
        }
        const vk = key("AXValue");
        defer CFRelease(vk);
        var s: u8 = 0;
        if (AXUIElementIsAttributeSettable(e, vk, &s) == 0) r.value_settable = s != 0;
        r.complete = ok;
        return r;
    }

    fn setTextImpl(ptr: *anyopaque, h: Handle, text: []const u8) i32 {
        const m = self(ptr);
        const z = m.gpa.dupeZ(u8, text) catch return -1;
        defer m.gpa.free(z);
        const v = CFStringCreateWithCString(null, z.ptr, utf8);
        if (v == null) return -1;
        defer CFRelease(v);
        const k = key("AXValue");
        defer CFRelease(k);
        return AXUIElementSetAttributeValue(el(h), k, v);
    }

    fn pressImpl(ptr: *anyopaque, h: Handle) i32 {
        _ = ptr;
        const k = key("AXPress");
        defer CFRelease(k);
        return AXUIElementPerformAction(el(h), k);
    }
} else struct {
    pub fn init(gpa: Allocator) @This() {
        _ = gpa;
        return .{};
    }
    pub fn deinit(m: *@This()) void {
        _ = m;
    }
    pub fn source(m: *@This()) Source {
        return .{ .ptr = m, .windowsFn = noWindows, .childrenFn = noChildren, .attrsFn = noAttrs, .setTextFn = noSet, .pressFn = noSet2 };
    }
    fn noWindows(p: *anyopaque, a: Allocator, pid: i32) ?[]WindowRef {
        _ = .{ p, a, pid };
        return null;
    }
    fn noChildren(p: *anyopaque, a: Allocator, h: Handle) ?[]Handle {
        _ = .{ p, a, h };
        return null;
    }
    fn noAttrs(p: *anyopaque, a: Allocator, h: Handle) ?Attrs {
        _ = .{ p, a, h };
        return null;
    }
    fn noSet(p: *anyopaque, h: Handle, t: []const u8) i32 {
        _ = .{ p, h, t };
        return -1;
    }
    fn noSet2(p: *anyopaque, h: Handle) i32 {
        _ = .{ p, h };
        return -1;
    }
};

// Tests

const testing = std.testing;

/// A scripted AX tree for the tests of this module and of the command in native_ui_runtime.zig.
pub const FakeAx = if (builtin.is_test) struct {
    pub const FNode = struct {
        depth: u8,
        role: []const u8,
        subrole: []const u8 = "",
        title: []const u8 = "",
        value: ?[]const u8 = null,
        kind: []const u8 = "",
        enabled: ?bool = true,
        id: []const u8 = "",
        settable: ?bool = null,
    };
    const SetMode = enum { apply, ignore, fail };
    const PressMode = enum { toggle, ignore, fail };
    const menu_h: Handle = 100000;

    nodes: []FNode,
    win_title: []const u8 = "Export Image File",
    modal: ?bool = true,
    owner: ?i32 = 4242,
    twin: bool = false,
    set_mode: SetMode = .apply,
    press_mode: PressMode = .toggle,
    menu_items: []const []const u8 = &.{},
    menu_disabled: bool = false,
    menu_open: ?usize = null,
    sets: u32 = 0,
    presses: u32 = 0,
    windows_calls: u32 = 0,
    drift_after: u32 = std.math.maxInt(u32),
    drift_idx: usize = 0,
    last_set: []const u8 = "",
    pressed: [8]Handle = undefined,

    pub fn init(a: Allocator, tree: []const FNode) @This() {
        return .{ .nodes = a.dupe(FNode, tree) catch unreachable };
    }

    pub fn source(f: *@This()) Source {
        return .{ .ptr = f, .windowsFn = windowsImpl, .childrenFn = childrenImpl, .attrsFn = attrsImpl, .setTextFn = setImpl, .pressFn = pressImpl };
    }

    fn me(p: *anyopaque) *@This() {
        return @ptrCast(@alignCast(p));
    }

    fn windowsImpl(p: *anyopaque, a: Allocator, pid: i32) ?[]WindowRef {
        _ = pid;
        const f = me(p);
        f.windows_calls += 1;
        if (f.windows_calls > f.drift_after) f.nodes[f.drift_idx].title = "drifted";
        const w: WindowRef = .{ .h = 1, .title = f.win_title, .modal = f.modal, .owner_pid = f.owner };
        const out = a.alloc(WindowRef, if (f.twin) 2 else 1) catch return null;
        for (out) |*o| o.* = w;
        return out;
    }

    fn childrenImpl(p: *anyopaque, a: Allocator, h: Handle) ?[]Handle {
        const f = me(p);
        var list: std.ArrayList(Handle) = .empty;
        if (h == menu_h) {
            for (f.menu_items, 0..) |_, i| list.append(a, menu_h + 1 + i) catch return null;
            return list.items;
        }
        if (h > f.nodes.len) return &.{};
        const i = h - 1;
        const d = f.nodes[i].depth;
        var j = i + 1;
        while (j < f.nodes.len and f.nodes[j].depth > d) : (j += 1) {
            if (f.nodes[j].depth == d + 1) list.append(a, j + 1) catch return null;
        }
        if (f.menu_open != null and f.menu_open.? == i) list.append(a, menu_h) catch return null;
        return list.items;
    }

    fn attrsImpl(p: *anyopaque, a: Allocator, h: Handle) ?Attrs {
        _ = a;
        const f = me(p);
        if (h == menu_h) return .{ .role = "AXMenu" };
        if (h > menu_h) return .{ .role = "AXMenuItem", .title = f.menu_items[h - menu_h - 1], .enabled = !f.menu_disabled };
        const n = f.nodes[h - 1];
        return .{ .role = n.role, .subrole = n.subrole, .title = n.title, .value = n.value, .value_kind = n.kind, .enabled = n.enabled, .identifier = n.id, .value_settable = n.settable };
    }

    fn setImpl(p: *anyopaque, h: Handle, text: []const u8) i32 {
        const f = me(p);
        f.sets += 1;
        f.last_set = text;
        switch (f.set_mode) {
            .apply => f.nodes[h - 1].value = text,
            .ignore => {},
            .fail => return -25200,
        }
        return 0;
    }

    fn pressImpl(p: *anyopaque, h: Handle) i32 {
        const f = me(p);
        if (f.presses < f.pressed.len) f.pressed[f.presses] = h;
        f.presses += 1;
        switch (f.press_mode) {
            .fail => return -25204,
            .ignore => return 0,
            .toggle => {},
        }
        if (h > menu_h) {
            f.nodes[f.menu_open.?].value = f.menu_items[h - menu_h - 1];
            f.menu_open = null;
            return 0;
        }
        const n = &f.nodes[h - 1];
        if (std.mem.eql(u8, n.role, "AXCheckBox")) n.value = if (std.mem.eql(u8, n.value.?, "1")) "0" else "1";
        if (std.mem.eql(u8, n.role, "AXRadioButton")) n.value = "1";
        if (std.mem.eql(u8, n.role, "AXPopUpButton") and f.menu_items.len > 0) f.menu_open = h - 1;
        return 0;
    }
} else struct {};

pub const test_exe = "/Apps/Vectorworks";

pub fn testPath(pid: i32, buf: []u8) ?[]const u8 {
    if (pid != 4242) return null;
    @memcpy(buf[0..test_exe.len], test_exe);
    return buf[0..test_exe.len];
}

const TestGate = struct {
    ok: bool = true,
    checks: u32 = 0,
    pauses: u32 = 0,
    fn check(p: *anyopaque) bool {
        const g: *TestGate = @ptrCast(@alignCast(p));
        g.checks += 1;
        return g.ok;
    }
    fn pause(p: *anyopaque, ms: u32) void {
        _ = ms;
        const g: *TestGate = @ptrCast(@alignCast(p));
        g.pauses += 1;
    }
    fn gate(g: *TestGate) Gate {
        return .{ .ptr = g, .checkFn = check, .pauseFn = pause };
    }
};

const F = FakeAx.FNode;

const image_tree = [_]F{
    .{ .depth = 0, .role = "AXWindow", .subrole = "AXDialog", .title = "Export Image File" },
    .{ .depth = 1, .role = "AXGroup" },
    .{ .depth = 2, .role = "AXStaticText", .value = "Width:", .kind = "string" },
    .{ .depth = 2, .role = "AXTextField", .value = "6", .kind = "string", .settable = false, .enabled = false },
    .{ .depth = 2, .role = "AXStaticText", .value = "Width:", .kind = "string" },
    .{ .depth = 2, .role = "AXTextField", .value = "0,083", .kind = "string", .settable = true },
    .{ .depth = 1, .role = "AXGroup" },
    .{ .depth = 2, .role = "AXStaticText", .value = "File Type:", .kind = "string" },
    .{ .depth = 2, .role = "AXPopUpButton", .value = "JPEG", .kind = "string" },
    .{ .depth = 2, .role = "AXStaticText", .value = "Color:", .kind = "string" },
    .{ .depth = 2, .role = "AXPopUpButton", .value = "Full color", .kind = "string" },
    .{ .depth = 2, .role = "AXCheckBox", .title = "Save Alpha Channel", .value = "0", .kind = "number", .enabled = false },
    .{ .depth = 2, .role = "AXCheckBox", .title = "Lock Aspect Ratio", .value = "1", .kind = "number" },
    .{ .depth = 2, .role = "AXRadioButton", .title = "Current View", .value = "0", .kind = "number" },
    .{ .depth = 2, .role = "AXRadioButton", .title = "All Visible Objects", .value = "1", .kind = "number" },
    .{ .depth = 1, .role = "AXButton", .title = "Save..." },
    .{ .depth = 1, .role = "AXButton", .title = "Cancel" },
};

const panel_tree = [_]F{
    .{ .depth = 0, .role = "AXWindow", .subrole = "AXDialog", .title = "Export STEP File", .id = "save-panel" },
    .{ .depth = 1, .role = "AXTextField", .value = "extrude.asym.step", .kind = "string", .id = "saveAsNameTextField", .settable = true },
    .{ .depth = 1, .role = "AXButton", .title = "Save", .id = "OKButton" },
};

fn mkReq(mode: Mode, control: ?[]const u8, want: ?[]const u8, expect: ?[]const u8) Request {
    return .{ .pid = 4242, .exe = test_exe, .title = "Export Image File", .mode = mode, .control = control, .want = want, .expect_current = expect };
}

fn withAuth(a: Allocator, r: Request) Request {
    var x = r;
    x.apply = true;
    x.authorize = authorizationToken(a, r);
    return x;
}

const Run = struct { code: u8, text: []const u8 };

fn go(a: Allocator, f: *FakeAx, g: *TestGate, r: Request) Run {
    var out: std.Io.Writer.Allocating = .init(a);
    const code = run(a, &out.writer, r, f.source(), testPath, g.gate());
    return .{ .code = code, .text = out.written() };
}

fn has(t: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, t, needle) != null;
}

test "native tree read lists every node, the popup labels and a stable signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = FakeAx.init(a, &image_tree);
    var g: TestGate = .{};
    const r = go(a, &f, &g, .{ .pid = 4242, .exe = test_exe, .title = "Export Image File", .mode = .tree });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(has(r.text, "nodes\t17\ttruncated=false\tunreadable=false\n"));
    try testing.expect(has(r.text, "node\t2\tAXPopUpButton\t\t\tJPEG\t\ttrue\t\tstring\tsettable=null\n"));
    try testing.expect(has(r.text, "node\t2\tAXTextField\t\t\t0,083\t\ttrue\t\tstring\tsettable=true\n"));
    try testing.expect(has(r.text, "popup_label\t8\tFile Type:\n"));
    try testing.expect(has(r.text, "popup_label\t10\tColor:\n"));
    try testing.expectEqual(@as(u32, 0), f.sets + f.presses);
    const r2 = go(a, &f, &g, .{ .pid = 4242, .exe = test_exe, .title = "Export Image File", .mode = .tree });
    const sig = "signature\t";
    const k1 = std.mem.indexOf(u8, r.text, sig).?;
    const k2 = std.mem.indexOf(u8, r2.text, sig).?;
    try testing.expectEqualStrings(std.mem.sliceTo(r.text[k1..], '\n'), std.mem.sliceTo(r2.text[k2..], '\n'));
}

test "native tree refuses a truncated tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var big: std.ArrayList(F) = .empty;
    try big.append(a, .{ .depth = 0, .role = "AXWindow", .title = "Export Image File" });
    var i: usize = 0;
    while (i < max_nodes + 5) : (i += 1) try big.append(a, .{ .depth = 1, .role = "AXGroup" });
    var f = FakeAx.init(a, big.items);
    var g: TestGate = .{};
    const r = go(a, &f, &g, .{ .pid = 4242, .exe = test_exe, .title = "Export Image File", .mode = .tree });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(has(r.text, "truncated=true"));
    try testing.expect(has(r.text, "refused\tthe tree is incomplete\n"));
    // A named control is not proven in a truncated tree either.
    const r2 = go(a, &f, &g, mkReq(.read, "popup/sibling/File Type:", null, null));
    try testing.expectEqual(@as(u8, 1), r2.code);
    try testing.expect(has(r2.text, "truncated or has an unreadable attribute"));
}

test "sibling selector binds anonymous popups to one exact label and refuses duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = FakeAx.init(a, &image_tree);
    var g: TestGate = .{};
    const r = go(a, &f, &g, mkReq(.read, "popup/sibling/File Type:", null, null));
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(has(r.text, "control\tnode\t8\t"));
    try testing.expect(has(r.text, "value\tJPEG\n"));
    const r2 = go(a, &f, &g, mkReq(.read, "popup/sibling/Color:", null, null));
    try testing.expect(has(r2.text, "value\tFull color\n"));
    // "Width:" occurs twice: no unique binding.
    const r3 = go(a, &f, &g, mkReq(.read, "text_field/sibling/Width:", null, null));
    try testing.expectEqual(@as(u8, 1), r3.code);
    try testing.expect(has(r3.text, "not unique"));
    // The sibling after "Color:" is a popup, not a checkbox.
    const r4 = go(a, &f, &g, mkReq(.read, "checkbox/sibling/Color:", null, null));
    try testing.expect(has(r4.text, "another role"));
    const r5 = go(a, &f, &g, mkReq(.read, "popup/sibling/Format:", null, null));
    try testing.expect(has(r5.text, "no static text has the label"));
    // Read never acts.
    try testing.expectEqual(@as(u32, 0), f.sets + f.presses);
    // title is unsupported, not silently routed elsewhere.
    const r6 = go(a, &f, &g, mkReq(.read, "popup/title/Where:", null, null));
    try testing.expectEqual(@as(u8, 1), r6.code);
    try testing.expect(has(r6.text, "unsupported\tthe title selector"));
}

test "path, label and id selectors resolve with exact counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = FakeAx.init(a, &image_tree);
    var g: TestGate = .{};
    try testing.expect(has(go(a, &f, &g, mkReq(.read, "checkbox/label/Lock Aspect Ratio", null, null)).text, "value\t1\n"));
    try testing.expect(has(go(a, &f, &g, mkReq(.read, "radio/label/Current View", null, null)).text, "value\t0\n"));
    // A path walks direct children of known roles with the exact sibling count. AXGroup is not a Role.
    try testing.expect(has(go(a, &f, &g, mkReq(.read, "popup/path/popup:1:2", null, null)).text, "another sibling count"));
    try testing.expect(go(a, &f, &g, mkReq(.read, "popup/path/popup:3:2", null, null)).code == 1);
    var p = FakeAx.init(a, &panel_tree);
    p.win_title = "Export STEP File";
    const r = go(a, &p, &g, .{ .pid = 4242, .exe = test_exe, .title = "Export Image File", .mode = .read, .control = "text_field/id/saveAsNameTextField" });
    try testing.expect(has(r.text, "refused\tno window has the exact title\n"));
    const r2 = go(a, &p, &g, .{ .pid = 4242, .exe = test_exe, .title = "Export STEP File", .mode = .read, .control = "text_field/id/saveAsNameTextField" });
    try testing.expect(has(r2.text, "value\textrude.asym.step\n"));
    try testing.expect(has(go(a, &p, &g, .{ .pid = 4242, .exe = test_exe, .title = "Export STEP File", .mode = .read, .control = "text_field/path/text_field:1:1" }).text, "value\textrude.asym.step\n"));
    try testing.expect(has(go(a, &p, &g, .{ .pid = 4242, .exe = test_exe, .title = "Export STEP File", .mode = .read, .control = "button/label/Save" }).text, "role\tAXButton\n"));
    try testing.expect(has(r2.text, "value\textrude.asym.step\n"));
    // Wrong executable, wrong owner, not modal and twin windows refuse before any lookup.
    var bad = FakeAx.init(a, &image_tree);
    bad.owner = 99;
    try testing.expect(has(go(a, &bad, &g, mkReq(.read, "popup/sibling/File Type:", null, null)).text, "owner pid"));
    bad.owner = 4242;
    bad.modal = false;
    try testing.expect(has(go(a, &bad, &g, mkReq(.read, "popup/sibling/File Type:", null, null)).text, "not proven modal"));
    bad.modal = null;
    try testing.expect(has(go(a, &bad, &g, mkReq(.read, "popup/sibling/File Type:", null, null)).text, "not proven modal"));
    bad.modal = true;
    bad.twin = true;
    try testing.expect(has(go(a, &bad, &g, mkReq(.read, "popup/sibling/File Type:", null, null)).text, "more than one window"));
    var wrong = mkReq(.read, "popup/sibling/File Type:", null, null);
    wrong.pid = 7;
    try testing.expect(has(go(a, &f, &g, wrong).text, "executable of the pid"));
}

const save_sel = "text_field/id/saveAsNameTextField";

fn panelReq(want: []const u8, expect: []const u8) Request {
    var r = mkReq(.set, save_sel, want, expect);
    r.title = "Export STEP File";
    return r;
}

fn panelFake(a: Allocator) FakeAx {
    var p = FakeAx.init(a, &panel_tree);
    p.win_title = "Export STEP File";
    return p;
}

test "native text setter plans by default and needs authorization, expected value and a settable field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = panelFake(a);
    var g: TestGate = .{};
    const plan = go(a, &f, &g, panelReq("trial-step.step", "extrude.asym.step"));
    try testing.expectEqual(@as(u8, 0), plan.code);
    try testing.expect(has(plan.text, "plan\tset the control natively; nothing was changed because --apply is absent\n"));
    try testing.expect(has(plan.text, "authorization_required\tnative-set pid=4242 window=Export STEP File control=text_field/id/saveAsNameTextField from=extrude.asym.step to=trial-step.step\n"));
    try testing.expectEqual(@as(u32, 0), f.sets + f.presses);
    // apply without a token, with another token, without --expect-current, with another current value.
    var r = panelReq("trial-step.step", "extrude.asym.step");
    r.apply = true;
    try testing.expect(has(go(a, &f, &g, r).text, "--authorize is required"));
    r.authorize = "yes";
    try testing.expect(has(go(a, &f, &g, r).text, "does not equal the authorization"));
    var other = panelReq("other.step", "extrude.asym.step");
    other.apply = true;
    other.authorize = authorizationToken(a, panelReq("trial-step.step", "extrude.asym.step"));
    try testing.expect(has(go(a, &f, &g, other).text, "does not equal the authorization"));
    var none = panelReq("trial-step.step", "x");
    none.expect_current = null;
    try testing.expect(has(go(a, &f, &g, none).text, "--expect-current is required"));
    try testing.expect(has(go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.stp"))).text, "not the expected value"));
    // A field with an unsettable AXValue and a disabled field refuse.
    f.nodes[1].settable = false;
    try testing.expect(has(go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step"))).text, "not settable"));
    f.nodes[1].settable = null;
    try testing.expect(has(go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step"))).text, "not settable"));
    f.nodes[1].settable = true;
    f.nodes[1].enabled = false;
    try testing.expect(has(go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step"))).text, "not enabled"));
    try testing.expectEqual(@as(u32, 0), f.sets + f.presses);
    try testing.expectEqual(@as(u32, 0), g.checks);
}

test "native text setter writes once, reads back through a fresh snapshot and never presses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = panelFake(a);
    var g: TestGate = .{};
    const r = go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step")));
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(has(r.text, "dispatch\tAXValue write\n"));
    try testing.expect(has(r.text, "set_readback\ttrial-step.step\n"));
    try testing.expect(has(r.text, "readback_matches_request\tyes\n"));
    try testing.expectEqual(@as(u32, 1), f.sets);
    try testing.expectEqual(@as(u32, 0), f.presses);
    try testing.expectEqualStrings("trial-step.step", f.last_set);
    try testing.expectEqual(@as(u32, 1), g.checks);
    // The Save button of the panel was not touched.
    try testing.expectEqualStrings("Save", f.nodes[2].title);
    // A second run now sees another current value and does not write.
    const again = go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step")));
    try testing.expect(has(again.text, "not the expected value"));
    try testing.expectEqual(@as(u32, 1), f.sets);
    // The wanted value already present is left alone.
    const same = go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "trial-step.step")));
    try testing.expectEqual(@as(u8, 0), same.code);
    try testing.expect(has(same.text, "unchanged\t"));
    try testing.expectEqual(@as(u32, 1), f.sets);
}

test "native text setter keeps an unproven outcome uncertain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = panelFake(a);
    var g: TestGate = .{};
    f.set_mode = .ignore;
    const ignored = go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step")));
    try testing.expectEqual(@as(u8, 1), ignored.code);
    try testing.expect(has(ignored.text, "readback_matches_request\tno\n"));
    try testing.expect(has(ignored.text, "uncertain\ttrue\nresult\tfailed\n"));
    try testing.expectEqual(@as(u32, 1), f.sets);
    try testing.expectEqual(@as(u32, poll_count - 1), g.pauses);
    var h = panelFake(a);
    h.set_mode = .fail;
    const failed = go(a, &h, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step")));
    try testing.expectEqual(@as(u8, 1), failed.code);
    try testing.expect(has(failed.text, "AX error -25200 after dispatch"));
    try testing.expect(has(failed.text, "uncertain\ttrue\n"));
    try testing.expectEqual(@as(u32, 1), h.sets);
}

test "native setters refuse when the recheck, the gate or the tree changed, before any action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = panelFake(a);
    var g: TestGate = .{ .ok = false };
    const r = go(a, &f, &g, withAuth(a, panelReq("trial-step.step", "extrude.asym.step")));
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(has(r.text, "document gate no longer matches"));
    try testing.expectEqual(@as(u32, 0), f.sets);
    // The dialog changes between the proof and the action.
    var d = panelFake(a);
    d.drift_after = 1;
    d.drift_idx = 2;
    var g2: TestGate = .{};
    const r2 = go(a, &d, &g2, withAuth(a, panelReq("trial-step.step", "extrude.asym.step")));
    try testing.expect(has(r2.text, "dialog changed between the proof and the action"));
    try testing.expectEqual(@as(u32, 0), d.sets);
    // A live static text (a size label) does not count as a change.
    var s = FakeAx.init(a, &image_tree);
    s.drift_after = 1;
    s.drift_idx = 2;
    s.nodes[2].title = "";
    var g3: TestGate = .{};
    const sib = go(a, &s, &g3, withAuth(a, mkReq(.set, "checkbox/label/Lock Aspect Ratio", "0", "1")));
    try testing.expectEqual(@as(u8, 1), sib.code);
}

test "native checkbox and radio take one guarded press with exact read back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = FakeAx.init(a, &image_tree);
    var g: TestGate = .{};
    const cb = go(a, &f, &g, withAuth(a, mkReq(.set, "checkbox/label/Lock Aspect Ratio", "0", "1")));
    try testing.expectEqual(@as(u8, 0), cb.code);
    try testing.expect(has(cb.text, "dispatch\tAXPress\n"));
    try testing.expect(has(cb.text, "set_readback\t0\n"));
    try testing.expectEqual(@as(u32, 1), f.presses);
    try testing.expectEqual(@as(u32, 0), f.sets);
    // Already holds the wanted state: no press.
    const same = go(a, &f, &g, withAuth(a, mkReq(.set, "checkbox/label/Lock Aspect Ratio", "0", "0")));
    try testing.expect(has(same.text, "unchanged\t"));
    try testing.expectEqual(@as(u32, 1), f.presses);
    // A disabled checkbox refuses.
    const dis = go(a, &f, &g, withAuth(a, mkReq(.set, "checkbox/label/Save Alpha Channel", "1", "0")));
    try testing.expect(has(dis.text, "not enabled"));
    // Expected value must be exact.
    try testing.expect(has(go(a, &f, &g, withAuth(a, mkReq(.set, "checkbox/label/Lock Aspect Ratio", "1", "1"))).text, "not the expected value"));
    // A radio can only be selected.
    const off = go(a, &f, &g, withAuth(a, mkReq(.set, "radio/label/All Visible Objects", "0", "1")));
    try testing.expect(has(off.text, "can only be selected"));
    const rad = go(a, &f, &g, withAuth(a, mkReq(.set, "radio/label/Current View", "1", "0")));
    try testing.expectEqual(@as(u8, 0), rad.code);
    try testing.expectEqual(@as(u32, 2), f.presses);
    // A press that changes nothing is an uncertain failure, one press only.
    var h = FakeAx.init(a, &image_tree);
    h.press_mode = .ignore;
    const ig = go(a, &h, &g, withAuth(a, mkReq(.set, "checkbox/label/Lock Aspect Ratio", "0", "1")));
    try testing.expectEqual(@as(u8, 1), ig.code);
    try testing.expect(has(ig.text, "uncertain\ttrue\n"));
    try testing.expectEqual(@as(u32, 1), h.presses);
    h.press_mode = .fail;
    const fl = go(a, &h, &g, withAuth(a, mkReq(.set, "checkbox/label/Lock Aspect Ratio", "0", "1")));
    try testing.expect(has(fl.text, "AXPress returned AX error -25204 after dispatch"));
    try testing.expectEqual(@as(u32, 2), h.presses);
}

const items = [_][]const u8{ "JPEG", "PNG", "TIFF" };

test "native popup selects the exact item through the menu with two presses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = FakeAx.init(a, &image_tree);
    f.menu_items = &items;
    var g: TestGate = .{};
    const r = go(a, &f, &g, withAuth(a, mkReq(.set, "popup/sibling/File Type:", "PNG", "JPEG")));
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(has(r.text, "menu_item\tPNG\n"));
    try testing.expect(has(r.text, "set_readback\tPNG\n"));
    try testing.expectEqual(@as(u32, 2), f.presses);
    try testing.expectEqual(@as(Handle, 9), f.pressed[0]);
    try testing.expectEqual(@as(Handle, 100002), f.pressed[1]);
    try testing.expectEqual(@as(u32, 0), f.sets);
    try testing.expect(f.menu_open == null);
}

test "native popup refuses to press an item it did not prove and reports the open menu" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: TestGate = .{};
    // No menu appears.
    var none = FakeAx.init(a, &image_tree);
    const r0 = go(a, &none, &g, withAuth(a, mkReq(.set, "popup/sibling/File Type:", "PNG", "JPEG")));
    try testing.expectEqual(@as(u8, 1), r0.code);
    try testing.expect(has(r0.text, "exactly one AXMenu child is not proven"));
    try testing.expectEqual(@as(u32, 1), none.presses);
    // The item is absent.
    var miss = FakeAx.init(a, &image_tree);
    miss.menu_items = &.{ "JPEG", "TIFF" };
    const r1 = go(a, &miss, &g, withAuth(a, mkReq(.set, "popup/sibling/File Type:", "PNG", "JPEG")));
    try testing.expect(has(r1.text, "not exactly one"));
    try testing.expect(has(r1.text, "uncertain\ttrue\n"));
    try testing.expectEqual(@as(u32, 1), miss.presses);
    // The item is duplicated.
    var dup = FakeAx.init(a, &image_tree);
    dup.menu_items = &.{ "PNG", "PNG" };
    try testing.expect(has(go(a, &dup, &g, withAuth(a, mkReq(.set, "popup/sibling/File Type:", "PNG", "JPEG"))).text, "not exactly one"));
    try testing.expectEqual(@as(u32, 1), dup.presses);
    // The item is disabled.
    var dis = FakeAx.init(a, &image_tree);
    dis.menu_items = &items;
    dis.menu_disabled = true;
    try testing.expect(has(go(a, &dis, &g, withAuth(a, mkReq(.set, "popup/sibling/File Type:", "PNG", "JPEG"))).text, "not enabled"));
    try testing.expectEqual(@as(u32, 1), dis.presses);
    // The gate fails after the menu opened: the item is not pressed.
    var late = FakeAx.init(a, &image_tree);
    late.menu_items = &items;
    var gl: TestGate = .{};
    const GateAfter = struct {
        fn check(p: *anyopaque) bool {
            const t: *TestGate = @ptrCast(@alignCast(p));
            t.checks += 1;
            return t.checks < 2;
        }
    };
    var sink: std.Io.Writer.Allocating = .init(a);
    const r2 = run(a, &sink.writer, withAuth(a, mkReq(.set, "popup/sibling/File Type:", "PNG", "JPEG")), late.source(), testPath, .{ .ptr = &gl, .checkFn = GateAfter.check, .pauseFn = TestGate.pause });
    try testing.expectEqual(@as(u8, 1), r2);
    try testing.expectEqual(@as(u32, 1), late.presses);
    // A wrong expected current value never presses.
    var wrong = FakeAx.init(a, &image_tree);
    wrong.menu_items = &items;
    try testing.expect(has(go(a, &wrong, &g, withAuth(a, mkReq(.set, "popup/sibling/File Type:", "PNG", "TIFF"))).text, "not the expected value"));
    try testing.expectEqual(@as(u32, 0), wrong.presses);
}

test "unsupported control kinds are reported and never acted on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = FakeAx.init(a, &image_tree);
    var g: TestGate = .{};
    f.nodes[15].role = "AXButton";
    const r = go(a, &f, &g, withAuth(a, mkReq(.set, "button/label/Save...", "1", "0")));
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(has(r.text, "unsupported\tthis control kind has no native setter. Supported: text_field, checkbox, radio, popup\n"));
    try testing.expectEqual(@as(u32, 0), f.sets + f.presses);
    var sheet = mkReq(.read, "popup/sibling/File Type:", null, null);
    sheet.sheet = true;
    try testing.expect(has(go(a, &f, &g, sheet).text, "--sheet is not supported"));
    try testing.expect(parseSpec(a, "popup/bogus/x") == .bad);
    try testing.expect(parseSpec(a, "popup/label/") == .bad);
    try testing.expect(parseSpec(a, "popup/title/Where:") == .unsupported);
}
