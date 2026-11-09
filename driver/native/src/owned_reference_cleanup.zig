//! Owned reference cleanup. It closes one standalone task-owned reference document that a trial run
//! left open. It is a separate operation. `close-scratch`, `ui-menu` and the query-copy discard keep
//! their own policy.
//!
//! The sequence is fixed. Precheck of the operator inputs, process identity, exact temporary path and
//! the recorded digest. Full SDK path proof of the active document. One Window menu activation of the
//! unique exact title when another document is active. Two further path proofs, the second one
//! immediately before File > Close. One Close. A digest check after it. The module never saves, never
//! deletes and never retries. Every dispatched action is recorded. A dispatched action whose result is
//! not proven is uncertain and stops the operation.
//!
//! The module holds the decisions only. `Ops` carries every effect, so the tests run on a fake.

const std = @import("std");

/// Canonical temporary roots. `/tmp` is a symlink and is not a root. The first directory below a root
/// is a `mktemp -d` name: `<name>.<six alphanumerics>`.
pub const temp_roots = [_][]const u8{ @import("build_options").volume ++ "/Caches/tmp/", "/private/tmp/" };

pub const max_tolerated = 4;
pub const max_actions = 3;

fn hasControl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

fn isLowerHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

pub fn titleOf(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

/// Null when `path` is an exact canonical `.vwx` path in a `mktemp -d` directory directly below a
/// temporary root. Otherwise the reason. It inspects the text only and never touches the file system.
pub fn classifyReference(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path.len > 1024 or path[0] != '/' or hasControl(path)) return "the reference is not an absolute path without control bytes";
    if (std.mem.indexOf(u8, path, "//") != null or std.mem.indexOf(u8, path, "/./") != null or std.mem.indexOf(u8, path, "/../") != null or
        std.mem.endsWith(u8, path, "/.") or std.mem.endsWith(u8, path, "/..") or std.mem.endsWith(u8, path, "/") or std.mem.indexOfScalar(u8, path, '\\') != null)
        return "the reference path is not canonical";
    var rest: ?[]const u8 = null;
    for (temp_roots) |root| {
        if (std.mem.startsWith(u8, path, root)) {
            rest = path[root.len..];
            break;
        }
    }
    const r = rest orelse return "the reference is not below a temporary root";
    const slash = std.mem.indexOfScalar(u8, r, '/') orelse return "the reference is not inside a task temporary directory";
    const dir = r[0..slash];
    const file = r[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, file, '/') != null) return "the reference is not directly inside its temporary directory";
    const dot = std.mem.lastIndexOfScalar(u8, dir, '.') orelse return "the temporary directory is not a mktemp name";
    const suffix = dir[dot + 1 ..];
    if (dot == 0 or suffix.len != 6) return "the temporary directory is not a mktemp name";
    for (suffix) |c| if (!std.ascii.isAlphanumeric(c)) return "the temporary directory is not a mktemp name";
    if (file.len <= 4 or !std.mem.endsWith(u8, file, ".vwx") or file[0] == '.') return "the reference is not a visible .vwx file";
    return null;
}

/// Null when `name` is a plain `.vwx` window title that may stay open beside the target.
pub fn classifyTolerated(name: []const u8, target_title: []const u8) ?[]const u8 {
    if (name.len <= 4 or name.len > 256 or hasControl(name) or std.mem.indexOfScalar(u8, name, '/') != null) return "a tolerated document is not a plain title";
    if (!std.mem.endsWith(u8, name, ".vwx")) return "a tolerated document is not a .vwx title";
    if (std.mem.eql(u8, name, target_title)) return "a tolerated document has the title of the target";
    return null;
}

pub const Request = struct {
    operator_authorized: bool = false,
    pid: i32 = 0,
    expected_executable: []const u8 = "",
    reference: []const u8 = "",
    /// Recorded digest of the reference. The operator supplies it. The worker never computes it.
    reference_sha256: []const u8 = "",
    /// Titles of other documents that stay open. Default none.
    tolerated: []const []const u8 = &.{},
    /// Permits Don't Save for the exact save prompt that names the reference.
    allow_discard: bool = false,
    reason: []const u8 = "",
};

/// The result of one path proof. `matches` means the bridge reported exactly the reference path.
pub const Active = union(enum) {
    matches,
    /// The bridge proved that another document or a document without a path is active.
    other: []const u8,
    /// The bridge failed for another reason. Nothing is proven.
    failed: []const u8,
};

pub const StepStatus = enum { done, refused, failed };

pub const Step = struct {
    status: StepStatus,
    /// The action may have run and its result is not proven.
    uncertain: bool = false,
    detail: []const u8 = "",
    /// Close only: Don't Save was pressed for the exact prompt.
    discarded: bool = false,
};

pub const Ops = struct {
    ptr: *anyopaque,
    exePathFn: *const fn (ptr: *anyopaque, pid: i32, buf: []u8) ?[]const u8,
    /// True when the real path of `path` is `path` itself: no symlink, no alias.
    canonicalFn: *const fn (ptr: *anyopaque, path: []const u8) bool,
    /// Lowercase hex SHA-256 of the file, or null.
    digestFn: *const fn (ptr: *anyopaque, path: []const u8) ?[]const u8,
    /// Full SDK path proof: vs.GetFName and vs.GetFPathName of the active document against `path`.
    activeFn: *const fn (ptr: *anyopaque, path: []const u8) Active,
    /// Window > title, once. Refused before the press unless the title is unique and exact.
    activateFn: *const fn (ptr: *anyopaque, title: []const u8) Step,
    /// File > Close, once, for the document `title`. A save prompt is answered only when `discard` is set and
    /// only when it names exactly `title`.
    closeFn: *const fn (ptr: *anyopaque, title: []const u8, discard: bool) Step,
    /// Called once, immediately before the first dispatched action (activation or Close). It makes the
    /// in-flight marker durable. False means the marker could not be created: nothing is dispatched.
    beginFn: ?*const fn (ptr: *anyopaque) bool = null,
};

pub const Outcome = enum {
    /// A precheck refused. No application action was dispatched.
    refused,
    /// The reference was closed and its bytes are unchanged.
    closed,
    /// A step stopped before any dispatched action changed anything, or a dispatched action is proven not to have run.
    stopped,
    /// A dispatched action has an unproven result. The operator reconciles by hand.
    uncertain,
};

pub const Action = struct { name: []const u8, status: StepStatus, uncertain: bool, detail: []const u8 };

pub const Report = struct {
    outcome: Outcome,
    detail: []const u8 = "",
    actions: [max_actions]Action = undefined,
    n_actions: usize = 0,
    proofs: u32 = 0,
    digest_before: []const u8 = "",
    digest_after: []const u8 = "",
    /// The diagnostic of the path proof that failed, as the adapter reported it. Empty when no proof failed.
    proof_detail: []const u8 = "",
    activated: bool = false,
    discarded: bool = false,
    /// beginFn returned true. A marker exists for this run.
    begun: bool = false,

    pub fn recorded(r: *const Report) []const Action {
        return r.actions[0..r.n_actions];
    }

    fn note(r: *Report, name: []const u8, st: Step) void {
        r.actions[r.n_actions] = .{ .name = name, .status = st.status, .uncertain = st.uncertain, .detail = st.detail };
        r.n_actions += 1;
    }

    fn stop(r: *Report, outcome: Outcome, detail: []const u8) Report {
        r.outcome = outcome;
        r.detail = detail;
        return r.*;
    }
};

/// Null when every operator input is well formed.
pub fn precheck(req: Request) ?[]const u8 {
    if (!req.operator_authorized) return "closing a reference needs explicit operator authorization";
    if (req.pid <= 0) return "no target process id";
    if (req.expected_executable.len == 0 or req.expected_executable[0] != '/' or hasControl(req.expected_executable)) return "the expected executable is not an absolute path";
    if (req.reason.len == 0) return "the operator gave no reason";
    if (classifyReference(req.reference)) |why| return why;
    if (!isLowerHex64(req.reference_sha256)) return "the recorded digest is not 64 lowercase hex digits";
    if (req.tolerated.len > max_tolerated) return "too many tolerated documents";
    const title = titleOf(req.reference);
    for (req.tolerated, 0..) |t, i| {
        if (classifyTolerated(t, title)) |why| return why;
        for (req.tolerated[0..i]) |p| if (std.mem.eql(u8, p, t)) return "a tolerated document is repeated";
    }
    return null;
}

/// Runs beginFn once. Null when the first action may be dispatched, else the refusal.
fn begin(rep: *Report, ops: Ops) ?[]const u8 {
    if (rep.begun) return null;
    if (ops.beginFn) |f| if (!f(ops.ptr)) return "the in-flight marker could not be created. Nothing was dispatched";
    rep.begun = true;
    return null;
}

pub fn run(req: Request, ops: Ops) Report {
    var rep: Report = .{ .outcome = .refused };
    if (precheck(req)) |why| return rep.stop(.refused, why);
    const title = titleOf(req.reference);

    var buf: [4096]u8 = undefined;
    const exe = ops.exePathFn(ops.ptr, req.pid, &buf) orelse return rep.stop(.refused, "the target process has no readable executable path");
    if (!std.mem.eql(u8, exe, req.expected_executable)) return rep.stop(.refused, "the target process runs another executable");
    if (!ops.canonicalFn(ops.ptr, req.reference)) return rep.stop(.refused, "the reference is a link or not a canonical path of an existing file");
    rep.digest_before = ops.digestFn(ops.ptr, req.reference) orelse return rep.stop(.refused, "the reference cannot be read");
    if (!std.mem.eql(u8, rep.digest_before, req.reference_sha256)) return rep.stop(.refused, "the reference digest differs from the recorded digest");

    // Proof 1 decides whether an activation is needed. Only the proof of another active document leads to one.
    switch (ops.activeFn(ops.ptr, req.reference)) {
        .matches => rep.proofs += 1,
        .failed => |why| {
            rep.proof_detail = why;
            return rep.stop(.refused, "the active document could not be proven");
        },
        .other => {
            rep.proofs += 1;
            if (begin(&rep, ops)) |why| return rep.stop(.stopped, why);
            const st = ops.activateFn(ops.ptr, title);
            rep.note("activate", st);
            switch (st.status) {
                .done => rep.activated = true,
                .refused => if (!st.uncertain) return rep.stop(.stopped, "the Window menu activation was refused before the press") else return rep.stop(.uncertain, "the Window menu activation has an unproven result"),
                .failed => return rep.stop(if (st.uncertain) .uncertain else .stopped, "the Window menu activation failed"),
            }
            // The path proof after the activation.
            switch (ops.activeFn(ops.ptr, req.reference)) {
                .matches => rep.proofs += 1,
                .other => return rep.stop(.uncertain, "after the activation another document is active. Close was not sent"),
                .failed => |why| {
                    rep.proof_detail = why;
                    return rep.stop(.uncertain, "after the activation the active document could not be proven. Close was not sent");
                },
            }
        },
    }

    // The path proof immediately before Close, and the bytes once more.
    switch (ops.activeFn(ops.ptr, req.reference)) {
        .matches => rep.proofs += 1,
        .other => return rep.stop(if (rep.activated) .uncertain else .stopped, "before Close another document is active. Close was not sent"),
        .failed => |why| {
            rep.proof_detail = why;
            return rep.stop(if (rep.activated) .uncertain else .stopped, "before Close the active document could not be proven. Close was not sent");
        },
    }
    const pre = ops.digestFn(ops.ptr, req.reference) orelse "";
    if (!std.mem.eql(u8, pre, req.reference_sha256)) return rep.stop(if (rep.activated) .uncertain else .stopped, "the reference digest changed before Close. Close was not sent");

    if (begin(&rep, ops)) |why| return rep.stop(.stopped, why);
    const cs = ops.closeFn(ops.ptr, title, req.allow_discard);
    rep.note("close", cs);
    rep.discarded = cs.discarded;
    if (cs.status != .done) {
        if (cs.uncertain) return rep.stop(.uncertain, "File > Close has an unproven result");
        return rep.stop(.stopped, "File > Close was refused before the menu step");
    }
    rep.digest_after = ops.digestFn(ops.ptr, req.reference) orelse "";
    if (!std.mem.eql(u8, rep.digest_after, req.reference_sha256)) return rep.stop(.uncertain, "the reference bytes changed or vanished after Close");
    return rep.stop(.closed, if (cs.discarded) "closed after Don't Save of the exact prompt" else "closed");
}

// -------------------------------------------------------------------------------------------------
// Tests. A fake carries every effect. No application, file or process is touched.
// -------------------------------------------------------------------------------------------------

const testing = std.testing;
const test_root = @import("build_options").volume;

const sha_a = "a" ** 64;
const sha_b = "b" ** 64;
const ref_a = test_root ++ "/Caches/tmp/rosetta-export-expansion-20261015.PaJbkB/extrude.asym.vwx";
const ref_b = test_root ++ "/Caches/tmp/trial-live-observation-20261015.zpNvyR/readiness-initial.vwx";
const test_exe = "/Applications/Vectorworks 2027/Vectorworks 2027.app/Contents/MacOS/Vectorworks";

const Fake = struct {
    exe_path: ?[]const u8 = test_exe,
    canonical: bool = true,
    digests: []const []const u8 = &.{sha_a},
    digest_calls: usize = 0,
    /// One entry per path proof. The last repeats.
    proofs: []const Active = &.{.matches},
    proof_calls: usize = 0,
    activate: Step = .{ .status = .done },
    activate_calls: usize = 0,
    activated_title: []const u8 = "",
    close: Step = .{ .status = .done },
    close_calls: usize = 0,
    close_title: []const u8 = "",
    close_discard: bool = false,
    begin_ok: bool = true,
    begin_calls: usize = 0,

    fn beginFn(p: *anyopaque) bool {
        const f = self(p);
        f.begin_calls += 1;
        return f.begin_ok;
    }

    fn ops(f: *Fake) Ops {
        return .{ .beginFn = beginFn, .ptr = f, .exePathFn = exePath, .canonicalFn = canonical_, .digestFn = digest, .activeFn = active, .activateFn = activateFn, .closeFn = closeFn };
    }
    fn self(p: *anyopaque) *Fake {
        return @ptrCast(@alignCast(p));
    }
    fn exePath(p: *anyopaque, _: i32, buf: []u8) ?[]const u8 {
        const e = self(p).exe_path orelse return null;
        @memcpy(buf[0..e.len], e);
        return buf[0..e.len];
    }
    fn canonical_(p: *anyopaque, _: []const u8) bool {
        return self(p).canonical;
    }
    fn digest(p: *anyopaque, _: []const u8) ?[]const u8 {
        const f = self(p);
        const i = @min(f.digest_calls, f.digests.len - 1);
        f.digest_calls += 1;
        return f.digests[i];
    }
    fn active(p: *anyopaque, _: []const u8) Active {
        const f = self(p);
        const i = @min(f.proof_calls, f.proofs.len - 1);
        f.proof_calls += 1;
        return f.proofs[i];
    }
    fn activateFn(p: *anyopaque, title: []const u8) Step {
        const f = self(p);
        f.activate_calls += 1;
        f.activated_title = title;
        return f.activate;
    }
    fn closeFn(p: *anyopaque, title: []const u8, discard: bool) Step {
        const f = self(p);
        f.close_calls += 1;
        f.close_title = title;
        f.close_discard = discard;
        return f.close;
    }
};

fn goodReq() Request {
    return .{ .operator_authorized = true, .pid = 4242, .expected_executable = test_exe, .reference = ref_a, .reference_sha256 = sha_a, .reason = "pending fixture needs the references closed" };
}

fn expectNoAction(f: *const Fake) !void {
    try testing.expectEqual(@as(usize, 0), f.activate_calls);
    try testing.expectEqual(@as(usize, 0), f.close_calls);
}

test "reference path classification is exact and touches nothing" {
    try testing.expect(classifyReference(ref_a) == null);
    try testing.expect(classifyReference(ref_b) == null);
    try testing.expect(classifyReference("/private/tmp/work.AbC123/x.vwx") == null);
    const bad = [_][]const u8{
        "",
        "relative/x.vwx",
        "/",
        "/Users/someone/plans/project.vwx",
        "/tmp/work.AbC123/x.vwx", // /tmp is a symlink and no root
        "/private/tmp/wt/trial-capture-wiring/x.vwx", // a worktree is not a task temporary directory
        "/private/tmp/x.vwx", // no temporary directory
        test_root ++ "/Caches/tmp/x.vwx",
        test_root ++ "/Caches/tmp/run.PaJbkB/sub/x.vwx",
        test_root ++ "/Caches/tmp/run.PaJbkB/../other.AbCdEf/x.vwx",
        test_root ++ "/Caches/tmp/run.PaJbkB//x.vwx",
        test_root ++ "/Caches/tmp/run.PaJbkB/./x.vwx",
        test_root ++ "/Caches/tmp/run.PaJbkB/x.vwx/",
        test_root ++ "/Caches/tmp/run.PaJbkB/x.vwx.bak",
        test_root ++ "/Caches/tmp/run.PaJbkB/.vwx",
        test_root ++ "/Caches/tmp/run.PaJbkB/.hidden.vwx",
        test_root ++ "/Caches/tmp/run.PaJb/x.vwx",
        test_root ++ "/Caches/tmp/run.PaJb!k/x.vwx",
        test_root ++ "/Caches/tmp/.PaJbkB/x.vwx",
        test_root ++ "/Caches/tmpx/run.PaJbkB/x.vwx",
        test_root ++ "/Caches/tmp/run.PaJbkB/x\n.vwx",
    };
    for (bad) |p| try testing.expect(classifyReference(p) != null);
    try testing.expect(classifyTolerated("readiness-initial.vwx", "extrude.asym.vwx") == null);
    for ([_][]const u8{ "", ".vwx", "a/b.vwx", "a.txt", "extrude.asym.vwx", "a\x01.vwx" }) |n| try testing.expect(classifyTolerated(n, "extrude.asym.vwx") != null);
}

test "every operator input is required before any effect" {
    const cases = [_]Request{
        .{ .pid = 4242, .expected_executable = test_exe, .reference = ref_a, .reference_sha256 = sha_a, .reason = "r" },
        .{ .operator_authorized = true, .expected_executable = test_exe, .reference = ref_a, .reference_sha256 = sha_a, .reason = "r" },
        .{ .operator_authorized = true, .pid = 4242, .reference = ref_a, .reference_sha256 = sha_a, .reason = "r" },
        .{ .operator_authorized = true, .pid = 4242, .expected_executable = "Vectorworks", .reference = ref_a, .reference_sha256 = sha_a, .reason = "r" },
        .{ .operator_authorized = true, .pid = 4242, .expected_executable = test_exe, .reference = ref_a, .reference_sha256 = sha_a },
        .{ .operator_authorized = true, .pid = 4242, .expected_executable = test_exe, .reference_sha256 = sha_a, .reason = "r" },
        .{ .operator_authorized = true, .pid = 4242, .expected_executable = test_exe, .reference = "/Users/someone/x.vwx", .reference_sha256 = sha_a, .reason = "r" },
        .{ .operator_authorized = true, .pid = 4242, .expected_executable = test_exe, .reference = ref_a, .reason = "r" },
        .{ .operator_authorized = true, .pid = 4242, .expected_executable = test_exe, .reference = ref_a, .reference_sha256 = "A" ** 64, .reason = "r" },
        .{ .operator_authorized = true, .pid = 4242, .expected_executable = test_exe, .reference = ref_a, .reference_sha256 = "abc", .reason = "r" },
    };
    for (cases) |c| {
        var f: Fake = .{};
        const rep = run(c, f.ops());
        try testing.expectEqual(Outcome.refused, rep.outcome);
        try testing.expectEqual(@as(usize, 0), rep.n_actions);
        try testing.expectEqual(@as(usize, 0), f.proof_calls);
        try testing.expectEqual(@as(usize, 0), f.digest_calls);
        try expectNoAction(&f);
    }
}

test "tolerated documents default to empty and are checked" {
    try testing.expectEqual(@as(usize, 0), (Request{}).tolerated.len);
    var r = goodReq();
    r.tolerated = &.{"readiness-initial.vwx"};
    try testing.expect(precheck(r) == null);
    r.tolerated = &.{"extrude.asym.vwx"};
    try testing.expect(precheck(r) != null);
    r.tolerated = &.{ "readiness-initial.vwx", "readiness-initial.vwx" };
    try testing.expect(precheck(r) != null);
    r.tolerated = &.{ "a.vwx", "b.vwx", "c.vwx", "d.vwx", "e.vwx" };
    try testing.expect(precheck(r) != null);
}

test "a wrong executable, a link or a changed digest refuses before any proof or action" {
    var f: Fake = .{ .exe_path = "/Applications/Other.app/Contents/MacOS/Other" };
    try testing.expectEqual(Outcome.refused, run(goodReq(), f.ops()).outcome);
    try testing.expectEqual(@as(usize, 0), f.proof_calls);
    f = .{ .exe_path = null };
    try testing.expectEqual(Outcome.refused, run(goodReq(), f.ops()).outcome);
    f = .{ .canonical = false };
    try testing.expectEqual(Outcome.refused, run(goodReq(), f.ops()).outcome);
    try testing.expectEqual(@as(usize, 0), f.digest_calls);
    f = .{ .digests = &.{sha_b} };
    const rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.refused, rep.outcome);
    try testing.expectEqual(@as(usize, 0), f.proof_calls);
    try expectNoAction(&f);
    f = .{ .digests = &.{""} };
    try testing.expectEqual(Outcome.refused, run(goodReq(), f.ops()).outcome);
}

test "an active reference is proven twice and closed once without an activation" {
    var f: Fake = .{};
    const rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.closed, rep.outcome);
    try testing.expectEqual(@as(u32, 2), rep.proofs);
    try testing.expectEqual(@as(usize, 0), f.activate_calls);
    try testing.expectEqual(@as(usize, 1), f.close_calls);
    try testing.expectEqualStrings("extrude.asym.vwx", f.close_title);
    try testing.expect(!f.close_discard);
    try testing.expect(!rep.activated and !rep.discarded);
    try testing.expectEqual(@as(usize, 1), rep.n_actions);
    try testing.expectEqualStrings("close", rep.recorded()[0].name);
    try testing.expectEqualStrings(sha_a, rep.digest_after);
}

test "activation from another document needs the exact title and three proofs" {
    var f: Fake = .{ .proofs = &.{ .{ .other = "the active document has no path" }, .matches, .matches } };
    const rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.closed, rep.outcome);
    try testing.expect(rep.activated);
    try testing.expectEqual(@as(u32, 3), rep.proofs);
    try testing.expectEqual(@as(usize, 1), f.activate_calls);
    try testing.expectEqualStrings("extrude.asym.vwx", f.activated_title);
    try testing.expectEqual(@as(usize, 1), f.close_calls);
    try testing.expectEqual(@as(usize, 2), rep.n_actions);
    try testing.expectEqualStrings("activate", rep.recorded()[0].name);
    try testing.expectEqualStrings("close", rep.recorded()[1].name);
}

test "an unproven first path stops before any action" {
    var f: Fake = .{ .proofs = &.{.{ .failed = "the bridge did not answer" }} };
    const rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.refused, rep.outcome);
    try testing.expectEqual(@as(usize, 1), f.proof_calls);
    try expectNoAction(&f);
}

test "a refused activation is definite and an unproven activation is uncertain. Neither closes" {
    var f: Fake = .{ .proofs = &.{.{ .other = "x" }}, .activate = .{ .status = .refused, .detail = "ambiguous title" } };
    var rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.stopped, rep.outcome);
    try testing.expectEqual(@as(usize, 0), f.close_calls);
    try testing.expectEqual(@as(usize, 1), rep.n_actions);
    f = .{ .proofs = &.{.{ .other = "x" }}, .activate = .{ .status = .failed, .uncertain = true, .detail = "press failed" } };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.uncertain, rep.outcome);
    try testing.expectEqual(@as(usize, 1), f.activate_calls);
    try testing.expectEqual(@as(usize, 0), f.close_calls);
    try testing.expect(rep.recorded()[0].uncertain);
}

test "a wrong path after the activation or before Close stops before Close" {
    var f: Fake = .{ .proofs = &.{ .{ .other = "x" }, .{ .other = "the active document is ref-b" } } };
    var rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.uncertain, rep.outcome);
    try testing.expectEqual(@as(usize, 0), f.close_calls);
    try testing.expect(rep.activated);
    f = .{ .proofs = &.{ .{ .other = "x" }, .matches, .{ .other = "the active document is ref-b" } } };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.uncertain, rep.outcome);
    try testing.expectEqual(@as(usize, 0), f.close_calls);
    // Without an activation the second proof is the one before Close. Nothing was dispatched.
    f = .{ .proofs = &.{ .matches, .{ .other = "the active document is ref-b" } } };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.stopped, rep.outcome);
    try testing.expectEqual(@as(usize, 0), rep.n_actions);
    try expectNoAction(&f);
    f = .{ .proofs = &.{ .matches, .{ .failed = "timeout" } } };
    try testing.expectEqual(Outcome.stopped, run(goodReq(), f.ops()).outcome);
    try expectNoAction(&f);
}

test "a digest that changes before Close stops before Close" {
    var f: Fake = .{ .digests = &.{ sha_a, sha_b } };
    const rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.stopped, rep.outcome);
    try expectNoAction(&f);
}

test "Close runs once. An unproven Close is uncertain and is never retried" {
    var f: Fake = .{ .close = .{ .status = .failed, .uncertain = true, .detail = "a dialog followed the menu step" } };
    var rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.uncertain, rep.outcome);
    try testing.expectEqual(@as(usize, 1), f.close_calls);
    try testing.expectEqual(@as(usize, 1), rep.n_actions);
    try testing.expect(rep.recorded()[0].uncertain);
    // A refusal before the menu step is definite.
    f = .{ .close = .{ .status = .refused, .detail = "no ready window" } };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.stopped, rep.outcome);
    try testing.expectEqual(@as(usize, 1), f.close_calls);
}

test "Don't Save needs the explicit flag and the bytes stay as recorded" {
    var f: Fake = .{ .close = .{ .status = .done, .discarded = true } };
    var req = goodReq();
    req.allow_discard = true;
    var rep = run(req, f.ops());
    try testing.expectEqual(Outcome.closed, rep.outcome);
    try testing.expect(rep.discarded and f.close_discard);
    // A changed or missing file after Close is uncertain.
    f = .{ .digests = &.{ sha_a, sha_a, sha_b } };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.uncertain, rep.outcome);
    f = .{ .digests = &.{ sha_a, sha_a, "" } };
    try testing.expectEqual(Outcome.uncertain, run(goodReq(), f.ops()).outcome);
}

test "the operation has no save, delete or retry route" {
    // Structural: the effect interface names exactly these functions.
    // beginFn only makes the in-flight marker durable. It never touches the application.
    const names = comptime std.meta.fieldNames(Ops);
    try testing.expectEqual(@as(usize, 8), names.len);
    inline for (names) |n| {
        try testing.expect(std.mem.indexOf(u8, n, "save") == null and std.mem.indexOf(u8, n, "delete") == null and std.mem.indexOf(u8, n, "retry") == null);
    }
}

test "the in-flight marker is made once before the first action and a failed marker dispatches nothing" {
    var f: Fake = .{ .proofs = &.{ .{ .other = "x" }, .matches } };
    var rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.closed, rep.outcome);
    try testing.expectEqual(@as(usize, 1), f.begin_calls);
    try testing.expect(rep.begun);
    f = .{ .begin_ok = false };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.stopped, rep.outcome);
    try testing.expectEqual(@as(usize, 0), rep.n_actions);
    try expectNoAction(&f);
    f = .{ .proofs = &.{ .{ .other = "x" }, .matches }, .begin_ok = false };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.stopped, rep.outcome);
    try expectNoAction(&f);
    f = .{ .digests = &.{sha_b} };
    rep = run(goodReq(), f.ops());
    try testing.expectEqual(Outcome.refused, rep.outcome);
    try testing.expectEqual(@as(usize, 0), f.begin_calls);
}
