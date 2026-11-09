//! Offline-tested runtime for Vectorworks desktop automation.
//!
//! This module adds a transport, a backend interface, a macOS backend, typed export routes and a
//! serial runtime on top of the pure policy in native_ui.zig. Every safety decision comes from
//! `native_ui.decide`. The module imports neither the capture module nor the activation module.
//!
//! Status of this revision:
//! - Every test drives fakes. The macOS backend runs against a fake `Transport` that returns
//!   canned stdout, so its command lines and output parsers run and its AppleScript sources do not.
//! - `ProcessTransport` is tested against harmless child commands (`sh`, `sleep`) only.
//! - No route in this module is calibrated. A route record becomes a verified capture route only
//!   through evidence that matches the run binding (see `checkPhase`).
//!
//! Allocation and lifetime contract:
//! - `Runtime`, `MacBackend` and `ProcessTransport` take an allocator at init or per call. Nothing
//!   else allocates.
//! - `RunOutput` buffers belong to the caller and are released with `RunOutput.deinit`.
//! - Every slice in a backend reply is borrowed from the backend until its next call. `Runtime`
//!   copies what it keeps into the `ExportReport`.
//! - `ExportReport` owns its option, file and control records. `ExportReport.deinit` releases them
//!   with the allocator that was passed to `Runtime.init`.
//! - Routes, selectors, policies and expected outputs are borrowed from the caller for one call.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("native_ui.zig");
const nec = @import("native_export_controls.zig");
const Allocator = std.mem.Allocator;

// Limits

pub const Limits = struct {
    max_steps: usize = 32,
    max_label: usize = 64,
    max_text: usize = 128,
    max_path: usize = 512,
    max_menu_depth: usize = 4,
    max_windows: usize = 32,
    max_texts: usize = 16,
    max_text_len: usize = 512,
    max_listing: usize = 64,
    /// Entries of one recursive output listing.
    max_walk_entries: usize = 4096,
    max_stdout: usize = 256 * 1024,
    max_stderr: usize = 16 * 1024,
    max_console_stdout: usize = 1 << 20,
    /// Cap of one backend call.
    call_timeout_ms: u32 = 10_000,
    /// Deadline of one export or gate operation.
    op_deadline_ms: u32 = 120_000,
    /// Deadline of the whole runtime from `Runtime.init`.
    run_deadline_ms: u32 = 1_800_000,
    poll_ms: u32 = 250,
    /// First wait after a change of the observed state. It doubles while the state stays the same
    /// and stops growing at the fallback bound. The bound starts at `poll_ms`. With a notifier it
    /// grows up to `poll_max_ms` while notifications arrive with the changes and shrinks down to
    /// `poll_min_ms` when a change shows up after a wait that no notification ended.
    poll_min_ms: u32 = 10,
    poll_max_ms: u32 = 2_000,
    /// Factor of each growth step. At least 2.
    poll_growth: u32 = 2,
    /// No observed activity for this long raises one diagnostic capture. The observation goes on. The
    /// threshold grows with the longest gap between two changes in the operation. Zero disables the
    /// trigger.
    stall_ms: u32 = 0,
    /// Wait for a dialog to appear after a menu step.
    dialog_wait_ms: u32 = 5_000,
    max_polls: u32 = 100_000,
    /// Presses the route cancel button after a failure that left a menu dialog open and is not
    /// uncertain. A cancel that cannot run makes the failure uncertain. Production sets it.
    cancel_after_failure: bool = false,
};

// Environment

/// Monotonic clock and sleep. Tests supply a fake that advances without sleeping.
pub const Env = struct {
    ptr: *anyopaque,
    nowFn: *const fn (ptr: *anyopaque) u64,
    sleepFn: *const fn (ptr: *anyopaque, ms: u32) void,

    /// Monotonic nanoseconds from an arbitrary origin.
    pub fn now(e: Env) u64 {
        return e.nowFn(e.ptr);
    }

    pub fn sleep(e: Env, ms: u32) void {
        e.sleepFn(e.ptr, ms);
    }
};

pub const SystemEnv = struct {
    io: std.Io,

    pub fn env(s: *SystemEnv) Env {
        return .{ .ptr = s, .nowFn = nowImpl, .sleepFn = sleepImpl };
    }

    fn nowImpl(ptr: *anyopaque) u64 {
        const s: *SystemEnv = @ptrCast(@alignCast(ptr));
        return @intCast(std.Io.Clock.awake.now(s.io).toNanoseconds());
    }

    fn sleepImpl(ptr: *anyopaque, ms: u32) void {
        const s: *SystemEnv = @ptrCast(@alignCast(ptr));
        if (ms == 0) return;
        s.io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
    }
};

/// Wakeups from the app. `arm` subscribes before an action. `wait` blocks until a notification or
/// `max_ms` and returns true for a notification. A notification only wakes a wait. The runtime
/// reads the current state after every wait. `watchFn` is optional. The runtime calls it before
/// `armFn` with the export bundle directory of the operation, so a notifier may also watch that
/// directory for new or removed entries.
pub const Notifier = struct {
    ptr: *anyopaque,
    armFn: *const fn (ptr: *anyopaque, pid: i32) void,
    waitFn: *const fn (ptr: *anyopaque, max_ms: u32) bool,
    watchFn: ?*const fn (ptr: *anyopaque, dir: []const u8) void = null,

    /// Names the directory to watch, when there is one, and subscribes for `pid`.
    pub fn arm(n: Notifier, pid: i32, dir: []const u8) void {
        if (n.watchFn) |w| w(n.ptr, dir);
        n.armFn(n.ptr, pid);
    }
};

pub const DiagRequest = struct {
    pid: i32,
    window_title: []const u8,
    /// `unknown_modal`, `selector_failed`, `missing_transition` or `stall`.
    reason: []const u8,
    /// The condition that the runtime waited for.
    expected: []const u8,
    /// The last mutating call that the runtime sent.
    last_action: []const u8,
};

pub const DiagResult = struct {
    captured: bool,
    /// Directory or file of the capture, or the reason it failed. Borrowed until the next call.
    detail: []const u8 = "",
};

/// Read-only capture. The implementation writes outside every export bundle and returns.
pub const Diagnostic = struct {
    ptr: *anyopaque,
    captureFn: *const fn (ptr: *anyopaque, req: DiagRequest) DiagResult,
};

/// Interval of the next wait between two observations. It starts at `min_ms`, doubles while the
/// observed state stays the same and stops growing at `max_ms`. A change restarts it at `min_ms`.
pub const Backoff = struct {
    ms: u32,
    min_ms: u32,
    max_ms: u32,
    /// Factor of each growth step while the state stays the same. At least 2.
    growth: u32 = 2,

    pub fn init(min_ms: u32, max_ms: u32) Backoff {
        const lo: u32 = if (max_ms == 0) 0 else @max(1, @min(min_ms, max_ms));
        return .{ .ms = lo, .min_ms = lo, .max_ms = max_ms };
    }

    /// The interval to wait now. The next call returns `growth` times as much, up to `max_ms`. A
    /// change restarts at `min_ms`. A lowered `max_ms` shortens the interval at once.
    pub fn next(b: *Backoff, changed: bool) u32 {
        if (changed) b.ms = b.min_ms;
        b.ms = @min(b.ms, b.max_ms);
        const r = b.ms;
        b.ms = @min(b.max_ms, b.ms *| @max(2, b.growth));
        return r;
    }
};

/// What the waits did in one runtime. The intervals decide when to look and never whether an
/// export succeeded or an output is missing. `waits` holds the last intervals in order.
pub const Cadence = struct {
    waits: [32]u32 = [_]u32{0} ** 32,
    /// Waits made, including those that the ring no longer holds.
    count: u32 = 0,
    min_ms: u32 = 0,
    max_ms: u32 = 0,
    /// Waits that a notification ended, and waits that ran to their interval.
    woke: u32 = 0,
    timed_out: u32 = 0,
    /// A wait that ended in a notification and found a change. The fallback interval grew.
    delivered: u32 = 0,
    /// A wait that ran to its interval and found a change. The fallback interval shrank, because a
    /// notification may have been lost or may not exist.
    missed: u32 = 0,
    /// The upper bound of the fallback interval now. Starts at `Limits.poll_ms`.
    fallback_ms: u32 = 0,
    reason: CadenceReason = .none,

    fn record(c: *Cadence, ms: u32) void {
        c.waits[c.count % c.waits.len] = ms;
        if (c.count == 0 or ms < c.min_ms) c.min_ms = ms;
        if (ms > c.max_ms) c.max_ms = ms;
        c.count += 1;
    }

    /// The most recent intervals, oldest first.
    pub fn recent(c: *const Cadence, out: []u32) []u32 {
        const n = @min(@min(c.count, c.waits.len), out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) out[i] = c.waits[(c.count - n + i) % c.waits.len];
        return out[0..n];
    }
};

pub const CadenceReason = enum {
    /// No wait has adapted its bound yet.
    none,
    /// No notifier. Waits are timer polls that grow while nothing changes and restart at a change.
    no_notifier,
    /// Notifications arrived and the state had changed. The fallback bound grew.
    notifications_delivered,
    /// A wait ran to its interval and the state had changed. The fallback bound shrank.
    notification_missed,
};

/// How the completion of an export was established.
pub const CompletionVia = enum {
    /// The route declares no completion signal.
    none,
    /// An operation-specific progress indicator that is correlated with the confirm press.
    progress_transition,
};

/// The evidence that an export finished, as the runtime saw it. A confirm press, a closed dialog,
/// a stale progress value and a quiet file are not evidence. `established` is true only for a
/// correlated progress transition together with a closed dialog.
pub const Completion = struct {
    via: CompletionVia = .none,
    established: bool = false,
    /// The progress value read just before the press. Null when no indicator was shown.
    baseline: ?u32 = null,
    /// Progress readings after the press, and the last one.
    observations: u32 = 0,
    last: ?u32 = null,
    /// The identity that the route requires. Empty when the route names none.
    progress_id: []const u8 = "",
    /// Readings with another or an empty identity. They never count.
    unmatched: u32 = 0,
};
// Subprocess transport

pub const StreamLimits = struct {
    stdout: usize = 256 * 1024,
    stderr: usize = 16 * 1024,
};

pub const RunStatus = enum { exited, signaled, timed_out, output_limit, spawn_failed, read_failed };

/// Result of one child process. `stdout` and `stderr` hold at most the stream limit. The flags
/// report bytes that the limit dropped. After `timed_out` and `output_limit` the buffers hold the
/// output received so far.
pub const RunOutput = struct {
    status: RunStatus,
    exit_code: u8 = 0,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    elapsed_ns: u64 = 0,

    pub fn deinit(o: RunOutput, a: Allocator) void {
        a.free(o.stdout);
        a.free(o.stderr);
    }

    pub fn succeeded(o: RunOutput) bool {
        return o.status == .exited and o.exit_code == 0;
    }
};

/// Runs one argv with a hard deadline. The implementation owns the child. When `run` returns, the
/// child and its process group are gone.
pub const Transport = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, a: Allocator, argv: []const []const u8, timeout_ms: u32, limits: StreamLimits) RunOutput,

    pub fn run(t: Transport, a: Allocator, argv: []const []const u8, timeout_ms: u32, limits: StreamLimits) RunOutput {
        return t.runFn(t.ptr, a, argv, timeout_ms, limits);
    }
};

fn copyBounded(a: Allocator, src: []const u8, limit: usize) ?[]u8 {
    return a.dupe(u8, src[0..@min(src.len, limit)]) catch null;
}

fn killGroup(pid: std.posix.pid_t) void {
    // The child leads its own process group (pgid 0 at spawn). SIGKILL cannot be ignored.
    std.posix.kill(-pid, .KILL) catch {};
    std.posix.kill(pid, .KILL) catch {};
}

// Owned child groups

const max_owned_children = 8;
var owned_children = [_]std.atomic.Value(i32){std.atomic.Value(i32).init(0)} ** max_owned_children;

/// Records the pid of a child that `ProcessTransport` owns. Returns the slot, or `max_owned_children`
/// when the table is full.
fn registerChild(pid: i32) usize {
    for (&owned_children, 0..) |*s, i| {
        if (s.cmpxchgStrong(0, pid, .seq_cst, .seq_cst) == null) return i;
    }
    return max_owned_children;
}

fn unregisterChild(slot: usize) void {
    if (slot < max_owned_children) owned_children[slot].store(0, .seq_cst);
}

/// Kills the process groups of the children that the transport started and has not reaped. It
/// touches no other process. It uses `kill` only, so a signal handler may call it.
pub fn killOwnedChildren() void {
    for (&owned_children) |*s| {
        const pid = s.load(.seq_cst);
        if (pid > 0) {
            std.posix.kill(-pid, .KILL) catch {};
            std.posix.kill(pid, .KILL) catch {};
        }
    }
}

/// Spawns in progress. A signal that arrives while a child is between `spawn` and its registration
/// is held and applied right after the registration, so that the child does not outlive it.
var spawning = std.atomic.Value(u32).init(0);
var pending_signal = std.atomic.Value(u8).init(0);

fn terminate(code: u8) noreturn {
    killOwnedChildren();
    if (builtin.link_libc) std.c._exit(code) else std.posix.exit(code);
}

fn onTerminationSignal(sig: std.posix.SIG) callconv(.c) void {
    const code: u8 = 128 +% @as(u8, @truncate(@intFromEnum(sig)));
    if (spawning.load(.seq_cst) > 0) {
        pending_signal.store(code, .seq_cst);
        return;
    }
    terminate(code);
}

/// Called after a spawn attempt. Ends the process when a signal arrived during the spawn.
fn endSpawn() void {
    _ = spawning.fetchSub(1, .seq_cst);
    const code = pending_signal.load(.seq_cst);
    if (code != 0) terminate(code);
}

/// Installs SIGINT, SIGTERM, SIGHUP and SIGQUIT handlers. A handler kills only the owned child
/// groups and ends the process with status 128 plus the signal number. The in-flight record on disk
/// stays, because the handler removes nothing. Call it once in a production run.
pub fn installSignalHandlers() void {
    if (std.posix.Sigaction == void) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onTerminationSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.HUP, &act, null);
    std.posix.sigaction(.QUIT, &act, null);
}

/// Spawns `argv` as the leader of a new process group, with stdin ignored and both output pipes
/// read through bounded buffers. A deadline or limit hit sends SIGKILL to the whole group and
/// reaps the child before return.
pub const ProcessTransport = struct {
    io: std.Io,

    pub fn transport(p: *ProcessTransport) Transport {
        return .{ .ptr = p, .runFn = runImpl };
    }

    fn runImpl(ptr: *anyopaque, a: Allocator, argv: []const []const u8, timeout_ms: u32, lim: StreamLimits) RunOutput {
        const p: *ProcessTransport = @ptrCast(@alignCast(ptr));
        return p.exec(a, argv, timeout_ms, lim);
    }

    fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
        const d = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        return if (d < 0) 0 else @intCast(d);
    }

    fn exec(p: *ProcessTransport, a: Allocator, argv: []const []const u8, timeout_ms: u32, lim: StreamLimits) RunOutput {
        const io = p.io;
        const start = std.Io.Clock.awake.now(io);
        var out: RunOutput = .{ .status = .spawn_failed };
        _ = spawning.fetchAdd(1, .seq_cst);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        }) catch {
            endSpawn();
            return out;
        };
        const pid = child.id.?;
        const slot = registerChild(pid);
        defer unregisterChild(slot);
        // A signal that arrived during the spawn ends the process here, after the child is registered.
        endSpawn();
        // Idempotent. Covers every early return below.
        defer child.kill(io);
        const deadline: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        }) };
        var status: RunStatus = .exited;
        drain: {
            var mrb: std.Io.File.MultiReader.Buffer(2) = undefined;
            var mr: std.Io.File.MultiReader = undefined;
            mr.init(a, io, mrb.toStreams(), &.{ child.stdout.?, child.stderr.? });
            defer mr.deinit();
            while (true) {
                mr.fill(64, deadline) catch |err| {
                    status = switch (err) {
                        error.EndOfStream => .exited,
                        error.Timeout => .timed_out,
                        else => .read_failed,
                    };
                    break;
                };
                if (mr.reader(0).bufferedLen() > lim.stdout or mr.reader(1).bufferedLen() > lim.stderr) {
                    status = .output_limit;
                    break;
                }
            }
            const o0 = mr.reader(0).buffered();
            const o1 = mr.reader(1).buffered();
            out.stdout_truncated = o0.len > lim.stdout;
            out.stderr_truncated = o1.len > lim.stderr;
            out.stdout = copyBounded(a, o0, lim.stdout) orelse {
                status = .read_failed;
                break :drain;
            };
            out.stderr = copyBounded(a, o1, lim.stderr) orelse {
                a.free(out.stdout);
                out.stdout = &.{};
                status = .read_failed;
                break :drain;
            };
        }
        if (status != .exited) {
            killGroup(pid);
            out.status = status;
            out.elapsed_ns = elapsed(io, start);
            return out;
        }
        // Both pipes reached end of file. Poll for the exit within the same deadline, because
        // Child.wait has no timeout.
        while (true) {
            var raw: if (builtin.link_libc) c_int else u32 = undefined;
            const rc = std.posix.system.wait4(pid, &raw, std.posix.W.NOHANG, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc != 0) {
                        const term = std.Io.Threaded.statusToTerm(@bitCast(raw));
                        if (child.stdout) |f| f.close(io);
                        if (child.stderr) |f| f.close(io);
                        child.stdout = null;
                        child.stderr = null;
                        child.id = null;
                        switch (term) {
                            .exited => |code| {
                                out.status = .exited;
                                out.exit_code = code;
                            },
                            else => out.status = .signaled,
                        }
                        out.elapsed_ns = elapsed(io, start);
                        return out;
                    }
                },
                .INTR => continue,
                else => {
                    killGroup(pid);
                    out.status = .read_failed;
                    out.elapsed_ns = elapsed(io, start);
                    return out;
                },
            }
            const left = deadline.deadline.durationFromNow(io).raw.toNanoseconds();
            if (left <= 0) {
                killGroup(pid);
                out.status = .timed_out;
                out.elapsed_ns = elapsed(io, start);
                return out;
            }
            io.sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
        }
    }
};

// Failures

/// Typed failure distinctions that the runtime returns to its caller.
pub const FailureKind = enum {
    /// A dialog or control that the route or policy does not allow.
    unknown_ui,
    /// The window, document or process is not the expected target.
    wrong_identity,
    console_locked,
    process_lost,
    /// One backend call or one operation passed its deadline.
    timeout,
    /// The run budget passed.
    deadline_exceeded,
    transport_error,
    missing_output,
    unexpected_output,
    incomplete_options,
    screenshot_unavailable,
    /// An action was sent and its outcome is unknown. The runtime refuses further operations until
    /// `Runtime.clearReconcile`.
    uncertain_mutation,
    ambiguous_target,
    /// The backend or policy refused the action before any mutation.
    refused,
    invalid_route,
    stale_route,
    uncalibrated_route,
    scratch_not_authorized,
    output_collision,
    out_of_memory,
    /// The route declares no completion signal. The outputs are raw and unconfirmed. The call stops
    /// uncertain. No elapsed interval replaces the signal.
    completion_unavailable,
    /// The completion evidence was established and a required output was not visible when the
    /// operation deadline ended. The producer may still be publishing it.
    output_unpublished,
    /// The output tree has more entries than the walk limit. The listing in the report is bounded.
    output_capacity,
};

pub const Failure = struct {
    kind: FailureKind,
    /// Static string or a slice borrowed from the backend until its next call.
    detail: []const u8 = "",
    /// True when the action was sent and the outcome is unknown.
    uncertain: bool = false,
};

// Backend interface

/// Target of one backend call. `pid` and `expected` are required. `window_title` is the exact title
/// of the document window that the last ready observation matched. `timeout_ms` is the budget of
/// the call.
pub const Ctx = struct {
    pid: i32,
    expected: ui.ExpectedDocument,
    window_title: []const u8,
    timeout_ms: u32,
};

pub const Role = enum {
    button,
    checkbox,
    popup,
    text_field,
    radio,
    /// The Go to Folder sheet may use a combo box for its path. A set writes text like a text field.
    combo_box,
    /// A disclosure triangle (`AXDisclosureTriangle`), such as the one that expands a save panel. Its
    /// value is 1 expanded and 0 collapsed. A set presses it once, only when the value differs.
    disclosure,

    pub fn axRole(r: Role) []const u8 {
        return switch (r) {
            .button => "AXButton",
            .checkbox => "AXCheckBox",
            .popup => "AXPopUpButton",
            .text_field => "AXTextField",
            .radio => "AXRadioButton",
            .combo_box => "AXComboBox",
            .disclosure => "AXDisclosureTriangle",
        };
    }
};

/// Where a selector looks. `document_sheet` is the single sheet of the expected document window.
/// `window` is the single window with exactly this title.
/// `window_sheet` is the single sheet of the single window with exactly this title, such as the Go to
/// Folder sheet of a save panel.
pub const Container = union(enum) {
    document_sheet,
    window: []const u8,
    window_sheet: []const u8,
};

/// One step of a structural path. `index` counts from 1 among the children of the current element
/// that have `role`. `of` is the exact number of such children, so a changed layout resolves to no
/// control instead of to a neighbor.
pub const PathStep = struct { role: Role, index: u8, of: u8 };

pub const max_path_steps = 4;

/// How a selector finds its control inside the container.
pub const Via = union(enum) {
    /// The accessibility name equals `label`.
    name,
    /// The control has an AXTitleUIElement whose value equals `label`. For controls whose own name is empty.
    title_element,
    /// The control sits at this exact child path below the container. `label` is empty. Use it only
    /// when the dialog gives the control no name and no title element.
    path: []const PathStep,
};

pub const Selector = struct {
    container: Container,
    role: Role,
    /// Exact accessibility name for `name`, exact title element text for `title_element`, empty for `path`.
    label: []const u8,
    via: Via = .name,

    pub fn eql(a: Selector, b: Selector) bool {
        if (a.role != b.role or !std.mem.eql(u8, a.label, b.label)) return false;
        if (!viaEql(a.via, b.via)) return false;
        return containerEql(a.container, b.container);
    }

    /// Text for reports. A path selector has no label, so the role stands in for it.
    pub fn reportLabel(s: Selector) []const u8 {
        if (s.label.len > 0) return s.label;
        return switch (s.role) {
            .button => "unnamed button (by path)",
            .checkbox => "unnamed checkbox (by path)",
            .popup => "unnamed popup (by path)",
            .text_field => "unnamed text field (by path)",
            .radio => "unnamed radio button (by path)",
            .combo_box => "unnamed combo box (by path)",
            .disclosure => "unnamed disclosure triangle (by path)",
        };
    }
};

fn viaEql(a: Via, b: Via) bool {
    return switch (a) {
        .name => b == .name,
        .title_element => b == .title_element,
        .path => |p| switch (b) {
            .path => |q| blk: {
                if (p.len != q.len) break :blk false;
                for (p, q) |x, y| if (x.role != y.role or x.index != y.index or x.of != y.of) break :blk false;
                break :blk true;
            },
            else => false,
        },
    };
}

fn containerEql(a: Container, b: Container) bool {
    return switch (a) {
        .document_sheet => b == .document_sheet,
        .window => |t| switch (b) {
            .window => |u| std.mem.eql(u8, t, u),
            else => false,
        },
        .window_sheet => |t| switch (b) {
            .window_sheet => |u| std.mem.eql(u8, t, u),
            else => false,
        },
    };
}

pub const OptionValue = union(enum) {
    checked: bool,
    choice: []const u8,
    text: []const u8,
};

/// True when two readings of a disclosure value are the same number or the same text. AX reports
/// the value as a number, so `1`, `1.0` and `1.00` are one reading.
fn valueEquals(got: []const u8, want: []const u8) bool {
    if (std.mem.eql(u8, got, want)) return true;
    const x = std.fmt.parseFloat(f64, std.mem.trim(u8, got, " ")) catch return false;
    const y = std.fmt.parseFloat(f64, std.mem.trim(u8, want, " ")) catch return false;
    return std.math.isFinite(x) and std.math.isFinite(y) and x == y;
}

const AwaitReply = union(enum) {
    /// The control read back the wanted value. Borrowed from the backend until its next call.
    matched: []const u8,
    /// The last value before the deadline, empty when none was readable.
    timed_out: []const u8,
    failed: Failure,
};

/// Reads one control until its value equals `want` or `wait_ms` passes. Reads only. The interval grows
/// from `poll_min_ms` to `poll_ms`, as in the other waits. It sends no action.
fn awaitValue(backend: Backend, env: Env, ctx: Ctx, sel: Selector, want: []const u8, wait_ms: u32, lim: Limits) AwaitReply {
    const give_up = env.now() + @as(u64, wait_ms) * std.time.ns_per_ms;
    var bo = Backoff.init(lim.poll_min_ms, lim.poll_ms);
    var last: []const u8 = "";
    while (true) {
        switch (backend.lookup(ctx, sel)) {
            .failed => |f| return .{ .failed = f },
            .found => |c| {
                // A slice from an earlier call is not kept: the backend reuses its memory.
                last = if (c.count == 1) (c.value orelse "") else "";
                if (c.count == 1 and valueEquals(last, want)) return .{ .matched = last };
            },
        }
        if (env.now() >= give_up) return .{ .timed_out = last };
        env.sleep(bo.next(false));
    }
}

pub const Control = struct {
    /// Number of matching controls. Only 1 is actionable.
    count: u16,
    layout_id: u64,
    role: []const u8 = "",
    label: []const u8 = "",
    value: ?[]const u8 = null,
    enabled: bool = false,
};

pub const AckRequest = struct {
    title: ?[]const u8,
    texts: []const []const u8,
    button: []const u8,
    class: ui.ModalClass,
    /// True for a notice that `Runtime.acknowledgeNotice` matched by its exact text. The backend
    /// accepts it with class `.unknown` and still rechecks title, texts and the default button.
    exact_notice: bool = false,
};

/// The one button that a discard may press, with the exact label that the live prompt shows.
pub const discard_button = "Don't Save";

/// A modal to leave without saving: its exact title and texts, and the button to press. The backend
/// refuses any other button than `discard_button`.
pub const DismissRequest = struct {
    title: ?[]const u8,
    texts: []const []const u8,
    button: []const u8,
};

fn refuseDismiss(ptr: *anyopaque, ctx: Ctx, req: DismissRequest) ActionReply {
    _ = .{ ptr, ctx, req };
    return .{ .failed = .{ .kind = .refused, .detail = "this backend presses no dialog button" } };
}

/// The only chord that a route may post. It opens the Go to Folder sheet of a standard save panel.
pub const Chord = enum { go_to_folder, slash };

/// The focus state of one control. `unreadable` means the attribute gave no boolean.
pub const FocusReply = union(enum) { focused: bool, failed: Failure };

fn refuseFocused(ptr: *anyopaque, ctx: Ctx, sel: Selector) FocusReply {
    _ = .{ ptr, ctx, sel };
    return .{ .failed = .{ .kind = .refused, .detail = "this backend reads no focus state" } };
}

fn refuseChord(ptr: *anyopaque, ctx: Ctx, window_title: []const u8, chord: Chord) ActionReply {
    _ = .{ ptr, ctx, window_title, chord };
    return .{ .failed = .{ .kind = .refused, .detail = "this backend posts no keyboard events" } };
}

pub const ObserveReply = union(enum) { observed: ui.Observation, failed: Failure };
/// `value` of `done` is the control value read back after a set. Null for other actions.
pub const ActionReply = union(enum) { done: ?[]const u8, failed: Failure };
pub const LookupReply = union(enum) { found: Control, failed: Failure };
/// `present` carries the layout id of the container. `absent` reports no such container.
pub const IdentityReply = union(enum) { present: u64, absent, failed: Failure };
/// A progress reading. `id` names the indicator that the backend read, such as its window or control
/// and its document. The runtime accepts a reading only when `id` equals `Route.progress_id`. A backend
/// that cannot name the indicator leaves `id` empty, and no completion follows from its readings.
pub const ProgressReply = union(enum) { none, fraction: struct { done: u32, total: u32, id: []const u8 = "" }, failed: Failure };

/// Injectable platform backend. Every call targets `Ctx.pid` and the document in `Ctx.expected`.
/// A backend never acts on the frontmost application or on a window that it did not match by
/// exact title. A mutating call that fails after it sent its action reports `uncertain`.
pub const Backend = struct {
    ptr: *anyopaque,
    observeFn: *const fn (ptr: *anyopaque, ctx: Ctx) ObserveReply,
    acknowledgeFn: *const fn (ptr: *anyopaque, ctx: Ctx, req: AckRequest) ActionReply,
    menuFn: *const fn (ptr: *anyopaque, ctx: Ctx, path: []const []const u8) ActionReply,
    identityFn: *const fn (ptr: *anyopaque, ctx: Ctx, container: Container) IdentityReply,
    lookupFn: *const fn (ptr: *anyopaque, ctx: Ctx, sel: Selector) LookupReply,
    setValueFn: *const fn (ptr: *anyopaque, ctx: Ctx, sel: Selector, value: OptionValue) ActionReply,
    pressFn: *const fn (ptr: *anyopaque, ctx: Ctx, sel: Selector) ActionReply,
    progressFn: *const fn (ptr: *anyopaque, ctx: Ctx) ProgressReply,
    screenshotFn: *const fn (ptr: *anyopaque, ctx: Ctx, path: []const u8) ActionReply,
    /// Posts one keyboard chord to `Ctx.pid` and never to the frontmost application. It refuses
    /// unless the window with exactly `window_title` is present immediately before the post.
    chordFn: *const fn (ptr: *anyopaque, ctx: Ctx, window_title: []const u8, chord: Chord) ActionReply = refuseChord,
    /// Reads AXFocused of the one control that `sel` names. Read only.
    focusedFn: *const fn (ptr: *anyopaque, ctx: Ctx, sel: Selector) FocusReply = refuseFocused,
    /// Presses `discard_button` of the one exact modal. Default: refuse.
    dismissFn: *const fn (ptr: *anyopaque, ctx: Ctx, req: DismissRequest) ActionReply = refuseDismiss,

    pub fn dismiss(b: Backend, ctx: Ctx, req: DismissRequest) ActionReply {
        return b.dismissFn(b.ptr, ctx, req);
    }

    pub fn focused(b: Backend, ctx: Ctx, sel: Selector) FocusReply {
        return b.focusedFn(b.ptr, ctx, sel);
    }

    pub fn chord(b: Backend, ctx: Ctx, window_title: []const u8, ch: Chord) ActionReply {
        return b.chordFn(b.ptr, ctx, window_title, ch);
    }

    pub fn observe(b: Backend, ctx: Ctx) ObserveReply {
        return b.observeFn(b.ptr, ctx);
    }
    pub fn acknowledge(b: Backend, ctx: Ctx, req: AckRequest) ActionReply {
        return b.acknowledgeFn(b.ptr, ctx, req);
    }
    pub fn menu(b: Backend, ctx: Ctx, path: []const []const u8) ActionReply {
        return b.menuFn(b.ptr, ctx, path);
    }
    pub fn identity(b: Backend, ctx: Ctx, container: Container) IdentityReply {
        return b.identityFn(b.ptr, ctx, container);
    }
    pub fn lookup(b: Backend, ctx: Ctx, sel: Selector) LookupReply {
        return b.lookupFn(b.ptr, ctx, sel);
    }
    pub fn setValue(b: Backend, ctx: Ctx, sel: Selector, value: OptionValue) ActionReply {
        return b.setValueFn(b.ptr, ctx, sel, value);
    }
    pub fn press(b: Backend, ctx: Ctx, sel: Selector) ActionReply {
        return b.pressFn(b.ptr, ctx, sel);
    }
    pub fn progress(b: Backend, ctx: Ctx) ProgressReply {
        return b.progressFn(b.ptr, ctx);
    }
    pub fn screenshot(b: Backend, ctx: Ctx, path: []const u8) ActionReply {
        return b.screenshotFn(b.ptr, ctx, path);
    }
};

pub const EntryKind = enum { file, directory, symlink, other };

/// One entry of a recursive listing. `path` is relative to the listed directory, uses `/` and is
/// owned by the caller. `size` and `nlink` are set for files only.
pub const WalkEntry = struct {
    path: []u8,
    kind: EntryKind,
    size: u64 = 0,
    nlink: u64 = 1,
};

pub const WalkLimits = struct {
    max_entries: usize,
    max_depth: usize,
};

pub fn freeWalk(a: Allocator, entries: []WalkEntry) void {
    for (entries) |e| a.free(e.path);
    a.free(entries);
}

/// Why a recursive listing ended. `unknown` is a backend that reports only null.
pub const WalkInfo = struct {
    status: enum { ok, capped, too_deep, unreadable, unknown } = .ok,
};

/// File system reads that the runtime needs. The runtime never writes through this interface.
pub const Files = struct {
    ptr: *anyopaque,
    sizeFn: *const fn (ptr: *anyopaque, path: []const u8) ?u64,
    /// Returns entry names of `dir`, at most `max`. Null when the directory cannot be read. The
    /// caller frees each name and the slice. More than `max` entries returns null.
    listFn: *const fn (ptr: *anyopaque, a: Allocator, dir: []const u8, max: usize) ?[][]u8,
    /// Recursive listing without following links. Null when the tree cannot be read, holds more
    /// than `max_entries` entries or is deeper than `max_depth`. Symbolic links and special files
    /// are reported with their kind and never entered. Null when a backend supports no recursion.
    walkFn: ?*const fn (ptr: *anyopaque, a: Allocator, dir: []const u8, lim: WalkLimits) ?[]WalkEntry = null,
    /// Like `walkFn`, and it says why the listing ended. When the tree holds more entries than
    /// `max_entries` or is deeper than `max_depth`, it returns the entries read so far and sets
    /// `capped` or `too_deep`. Null only when the tree cannot be read.
    walkInfoFn: ?*const fn (ptr: *anyopaque, a: Allocator, dir: []const u8, lim: WalkLimits, info: *WalkInfo) ?[]WalkEntry = null,

    pub fn size(f: Files, path: []const u8) ?u64 {
        return f.sizeFn(f.ptr, path);
    }
    pub fn list(f: Files, a: Allocator, dir: []const u8, max: usize) ?[][]u8 {
        return f.listFn(f.ptr, a, dir, max);
    }
    pub fn walkInfo(f: Files, a: Allocator, dir: []const u8, lim: WalkLimits, info: *WalkInfo) ?[]WalkEntry {
        if (f.walkInfoFn) |w| return w(f.ptr, a, dir, lim, info);
        const r = f.walk(a, dir, lim);
        info.status = if (r == null) .unknown else .ok;
        return r;
    }
    pub fn walk(f: Files, a: Allocator, dir: []const u8, lim: WalkLimits) ?[]WalkEntry {
        const w = f.walkFn orelse return null;
        return w(f.ptr, a, dir, lim);
    }
};

pub fn freeList(a: Allocator, names: [][]u8) void {
    for (names) |n| a.free(n);
    a.free(names);
}

/// Read-only file system access through std.Io.
pub const SystemFiles = struct {
    io: std.Io,

    pub fn files(s: *SystemFiles) Files {
        return .{ .ptr = s, .sizeFn = sizeImpl, .listFn = listImpl, .walkFn = walkImpl, .walkInfoFn = walkInfoImpl };
    }

    fn sizeImpl(ptr: *anyopaque, path: []const u8) ?u64 {
        const s: *SystemFiles = @ptrCast(@alignCast(ptr));
        const st = std.Io.Dir.cwd().statFile(s.io, path, .{ .follow_symlinks = false }) catch return null;
        return st.size;
    }

    fn listImpl(ptr: *anyopaque, a: Allocator, dir: []const u8, max: usize) ?[][]u8 {
        const s: *SystemFiles = @ptrCast(@alignCast(ptr));
        var d = std.Io.Dir.openDirAbsolute(s.io, dir, .{ .iterate = true, .follow_symlinks = false }) catch return null;
        defer d.close(s.io);
        var names: std.ArrayList([]u8) = .empty;
        var ok = false;
        defer if (!ok) {
            for (names.items) |n| a.free(n);
            names.deinit(a);
        };
        var it = d.iterate();
        while (it.next(s.io) catch return null) |e| {
            if (names.items.len >= max) return null;
            const copy = a.dupe(u8, e.name) catch return null;
            names.append(a, copy) catch {
                a.free(copy);
                return null;
            };
        }
        const slice = names.toOwnedSlice(a) catch return null;
        ok = true;
        return slice;
    }

    const WalkError = error{ TooMany, TooDeep, Unreadable, OutOfMemory };

    fn walkInto(s: *SystemFiles, a: Allocator, d: std.Io.Dir, prefix: []const u8, depth: usize, out: *std.ArrayList(WalkEntry), lim: WalkLimits) WalkError!void {
        var it = d.iterate();
        while (it.next(s.io) catch return error.Unreadable) |e| {
            if (out.items.len >= lim.max_entries) return error.TooMany;
            // lstat decides the kind, so a symbolic link is never read as its target.
            const st = d.statFile(s.io, e.name, .{ .follow_symlinks = false }) catch return error.Unreadable;
            const kind: EntryKind = switch (st.kind) {
                .file => .file,
                .directory => .directory,
                .sym_link => .symlink,
                else => .other,
            };
            const path = if (prefix.len == 0)
                a.dupe(u8, e.name) catch return error.OutOfMemory
            else
                std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name }) catch return error.OutOfMemory;
            out.append(a, .{
                .path = path,
                .kind = kind,
                .size = if (kind == .file) st.size else 0,
                .nlink = if (kind == .file) @intCast(st.nlink) else 1,
            }) catch {
                a.free(path);
                return error.OutOfMemory;
            };
            if (kind == .directory) {
                if (depth + 1 > lim.max_depth) return error.TooDeep;
                var sub = d.openDir(s.io, e.name, .{ .iterate = true, .follow_symlinks = false }) catch return error.Unreadable;
                defer sub.close(s.io);
                try walkInto(s, a, sub, path, depth + 1, out, lim);
            }
        }
    }

    fn walkImpl(ptr: *anyopaque, a: Allocator, dir: []const u8, lim: WalkLimits) ?[]WalkEntry {
        const s: *SystemFiles = @ptrCast(@alignCast(ptr));
        var root = std.Io.Dir.openDirAbsolute(s.io, dir, .{ .iterate = true, .follow_symlinks = false }) catch return null;
        defer root.close(s.io);
        var out: std.ArrayList(WalkEntry) = .empty;
        walkInto(s, a, root, "", 0, &out, lim) catch {
            for (out.items) |e| a.free(e.path);
            out.deinit(a);
            return null;
        };
        return out.toOwnedSlice(a) catch {
            for (out.items) |e| a.free(e.path);
            out.deinit(a);
            return null;
        };
    }

    /// Like `walkImpl`. A tree with more entries than `max_entries` or deeper than `max_depth`
    /// returns the entries read so far and says why. Only an unreadable tree returns null.
    fn walkInfoImpl(ptr: *anyopaque, a: Allocator, dir: []const u8, lim: WalkLimits, info: *WalkInfo) ?[]WalkEntry {
        const s: *SystemFiles = @ptrCast(@alignCast(ptr));
        var root = std.Io.Dir.openDirAbsolute(s.io, dir, .{ .iterate = true, .follow_symlinks = false }) catch {
            info.status = .unreadable;
            return null;
        };
        defer root.close(s.io);
        var out: std.ArrayList(WalkEntry) = .empty;
        info.status = .ok;
        walkInto(s, a, root, "", 0, &out, lim) catch |e| switch (e) {
            error.TooMany => info.status = .capped,
            error.TooDeep => info.status = .too_deep,
            else => {
                for (out.items) |x| a.free(x.path);
                out.deinit(a);
                info.status = .unreadable;
                return null;
            },
        };
        return out.toOwnedSlice(a) catch {
            for (out.items) |x| a.free(x.path);
            out.deinit(a);
            info.status = .unreadable;
            return null;
        };
    }
};

// Routes

pub const Phase = enum { inventory, calibration, verified };
/// Internal route format. Serialize with `formatId` and parse with `formatFromId`. The internal
/// names `.tds` and `.threedm` serialize as `3ds` and `3dm`.
pub const Format = enum { obj, stl, tds, fbx, parasolid, step, pdf, dxf, dwg, png, sat, usd, iges, threedm, ifc };

/// Canonical pack identifier of a format. This is the only serialized spelling.
pub fn formatId(f: Format) []const u8 {
    return switch (f) {
        .obj => "obj",
        .stl => "stl",
        .tds => "3ds",
        .fbx => "fbx",
        .parasolid => "parasolid",
        .step => "step",
        .pdf => "pdf",
        .dxf => "dxf",
        .dwg => "dwg",
        .png => "png",
        .sat => "sat",
        .usd => "usd",
        .iges => "iges",
        .threedm => "3dm",
        .ifc => "ifc",
    };
}

/// Parses a canonical identifier. Matching is exact. Unknown spellings, including the internal
/// names `tds` and `threedm`, return null.
pub fn formatFromId(id: []const u8) ?Format {
    for (std.enums.values(Format)) |f| if (std.mem.eql(u8, formatId(f), id)) return f;
    return null;
}

/// Formats that the acquisition requires. Their routes may reach the verified phase.
pub const required_formats = [_]Format{ .obj, .stl, .tds, .fbx, .parasolid, .step, .pdf, .dxf, .dwg, .png };
/// Formats for availability checks. Their routes run inventory and calibration only. A route here
/// claims no installed support.
pub const targeted_formats = [_]Format{ .sat, .usd, .iges, .threedm, .ifc };

pub fn isTargeted(f: Format) bool {
    for (targeted_formats) |t| if (t == f) return true;
    return false;
}
pub const CalibrationStatus = enum { uncalibrated, calibrated };
pub const NameMode = enum { full_name, stem };

pub const OptionStep = struct { selector: Selector, value: OptionValue };

/// The standard macOS save panel. Its Where control is a popup that shows only the folder name, so
/// the directory is set through the Go to Folder sheet and read back from that popup. The sheet is
/// opened with one Command-Shift-G event posted to the target pid, because the panel has no
/// accessibility route to it.
pub const SavePanelDir = struct {
    /// The Where popup. Its value after navigation must be the last component of the operation directory.
    where: Selector,
    /// The path field of the Go to Folder sheet. Its container is `window_sheet`.
    sheet_field: Selector,
    /// The button of that sheet that accepts the path.
    go: Selector,
    /// The key that asks the panel for the sheet. Command-Shift-G is the default. `slash` posts one
    /// plain slash key and is explicit: it needs `focus_field`.
    initiator: Initiator = .command_shift_g,
    /// For `slash`: the exact enabled Save As name field that must hold the keyboard focus before the
    /// key is posted. It equals the name field of the destination step.
    focus_field: ?Selector = null,
};

/// How a save panel is asked for its Go to Folder sheet. Both post to the target pid only.
pub const Initiator = enum { command_shift_g, slash };

pub const DestinationStep = struct {
    name_field: Selector,
    name_mode: NameMode = .full_name,
    /// Text field that receives the operation directory. A verified route needs this or `save_panel`.
    dir_field: ?Selector = null,
    /// Standard save panel directory mechanism. Exclusive with `dir_field`.
    save_panel: ?SavePanelDir = null,
};

pub const Step = union(enum) {
    /// Menu labels. The initial route set is File then Export.
    menu: []const []const u8,
    option: OptionStep,
    destination: DestinationStep,
    confirm: Selector,
};

/// Observed context that a route was calibrated for, or that a run executes in.
pub const Binding = struct {
    release: []const u8,
    workspace: []const u8,
    /// Lowercase hex SHA-256 of the format profile.
    profile_hash: []const u8,
    /// Lowercase hex SHA-256 of the source document.
    source_digest: []const u8,
    /// Lowercase hex SHA-256 of the document state.
    state_digest: []const u8,

    pub fn eql(a: Binding, b: Binding) bool {
        return std.mem.eql(u8, a.release, b.release) and std.mem.eql(u8, a.workspace, b.workspace) and
            std.mem.eql(u8, a.profile_hash, b.profile_hash) and std.mem.eql(u8, a.source_digest, b.source_digest) and
            std.mem.eql(u8, a.state_digest, b.state_digest);
    }
};

/// Reference to calibration output. The bundle layer owns the record. This module compares the
/// binding only.
pub const Evidence = struct {
    calibration_id: []const u8,
    binding: Binding,
};

pub const Route = struct {
    id: []const u8,
    format: Format,
    steps: []const Step,
    /// Button that closes the dialog. Used by the inventory phase.
    cancel: ?Selector = null,
    /// True when the route expects a progress indicator while the export runs.
    progress: bool = false,
    /// The identity of the indicator that belongs to this export, as the backend reports it. It comes
    /// from live calibration. A route with `progress` and an empty `progress_id` has no verified
    /// completion signal, and the export stops with `completion_unavailable`. A reading with another
    /// or an empty identity never counts, whatever its value.
    progress_id: []const u8 = "",
    binding: Binding,
    status: CalibrationStatus = .uncalibrated,
    evidence: ?Evidence = null,
};

pub const ExpectedOutputs = struct {
    /// Basename of the primary file.
    primary: []const u8,
    /// Relative paths that must exist under the operation directory. Nested paths keep the exporter layout.
    required_sidecars: []const []const u8 = &.{},
    /// Extensions (with dot) that other files may have.
    allowed_sidecar_exts: []const []const u8 = &.{},
};

pub const RouteError = error{
    BadId,
    BadMenuPath,
    BadStepOrder,
    TooManySteps,
    BadSelector,
    BadValue,
    BadRoleValue,
    DuplicateOption,
    MissingDestination,
    MissingConfirm,
    MissingDirField,
    BadBinding,
    BadOutputName,
    BadSidecar,
    BadOperationDir,
};

fn hasControl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

fn validLabel(s: []const u8, max: usize) bool {
    return s.len >= 1 and s.len <= max and !hasControl(s) and s[0] != ' ' and s[s.len - 1] != ' ';
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

pub fn validateBinding(b: Binding, lim: Limits) RouteError!void {
    if (!validLabel(b.release, lim.max_label) or !validLabel(b.workspace, lim.max_label)) return error.BadBinding;
    if (!isHex64(b.profile_hash) or !isHex64(b.source_digest) or !isHex64(b.state_digest)) return error.BadBinding;
}

fn validateSelector(s: Selector, want: ?Role, lim: Limits) RouteError!void {
    if (want) |w| if (s.role != w) return error.BadSelector;
    switch (s.via) {
        .name, .title_element => if (!validLabel(s.label, lim.max_label)) return error.BadSelector,
        .path => |p| {
            if (s.label.len != 0 or p.len == 0 or p.len > max_path_steps) return error.BadSelector;
            for (p) |st| if (st.index == 0 or st.of == 0 or st.index > st.of) return error.BadSelector;
            if (p[p.len - 1].role != s.role) return error.BadSelector;
        },
    }
    switch (s.container) {
        .document_sheet => {},
        .window, .window_sheet => |t| if (!validLabel(t, 255)) return error.BadSelector,
    }
}

fn validateValue(sel: Selector, v: OptionValue, lim: Limits) RouteError!void {
    switch (sel.role) {
        .checkbox, .disclosure => if (v != .checked) return error.BadRoleValue,
        .radio => switch (v) {
            .checked => |c| if (!c) return error.BadRoleValue,
            else => return error.BadRoleValue,
        },
        .popup => switch (v) {
            .choice => |c| if (!validLabel(c, lim.max_text)) return error.BadValue,
            else => return error.BadRoleValue,
        },
        .text_field, .combo_box => switch (v) {
            .text => |t| if (t.len == 0 or t.len > lim.max_text or hasControl(t)) return error.BadValue,
            else => return error.BadRoleValue,
        },
        .button => return error.BadRoleValue,
    }
}

/// Checks the shape of a route. The order is one menu step, any option steps, one destination
/// step and one confirm step. The initial menu path is File then Export.
pub fn validateRoute(r: Route, phase: Phase, lim: Limits) RouteError!void {
    if (!validLabel(r.id, lim.max_label)) return error.BadId;
    if (r.progress_id.len > 0 and !validLabel(r.progress_id, lim.max_label)) return error.BadId;
    if (r.steps.len == 0 or r.steps.len > lim.max_steps) return error.TooManySteps;
    var stage: u8 = 0;
    for (r.steps, 0..) |st, i| {
        switch (st) {
            .menu => |path| {
                if (i != 0 or stage != 0) return error.BadStepOrder;
                if (path.len < 2 or path.len > lim.max_menu_depth) return error.BadMenuPath;
                if (!std.mem.eql(u8, path[0], "File") or !std.mem.eql(u8, path[1], "Export")) return error.BadMenuPath;
                for (path) |l| if (!validLabel(l, lim.max_label)) return error.BadMenuPath;
                stage = 1;
            },
            .option => |o| {
                if (stage != 1) return error.BadStepOrder;
                try validateSelector(o.selector, null, lim);
                try validateValue(o.selector, o.value, lim);
                for (r.steps[0..i]) |prev| switch (prev) {
                    .option => |p| if (p.selector.eql(o.selector)) return error.DuplicateOption,
                    else => {},
                };
            },
            .destination => |d| {
                if (stage != 1) return error.BadStepOrder;
                try validateSelector(d.name_field, .text_field, lim);
                if (d.dir_field) |df| try validateSelector(df, .text_field, lim);
                if (d.save_panel) |sp| {
                    if (d.dir_field != null) return error.BadSelector;
                    try validateSelector(sp.where, .popup, lim);
                    try validateSelector(sp.sheet_field, null, lim);
                    if (sp.sheet_field.role != .text_field and sp.sheet_field.role != .combo_box) return error.BadSelector;
                    try validateSelector(sp.go, .button, lim);
                    const win = switch (d.name_field.container) {
                        .window => |t| t,
                        else => return error.BadSelector,
                    };
                    // One panel: the name field, the Where popup and the sheet belong to the same window.
                    if (!containerEql(sp.where.container, d.name_field.container)) return error.BadSelector;
                    if (!containerEql(sp.sheet_field.container, .{ .window_sheet = win })) return error.BadSelector;
                    if (!containerEql(sp.go.container, sp.sheet_field.container)) return error.BadSelector;
                }
                if (d.save_panel) |sp| switch (sp.initiator) {
                    .command_shift_g => if (sp.focus_field != null) return error.BadSelector,
                    .slash => {
                        // The focus is read on the exact name field that the step sets.
                        const ff = sp.focus_field orelse return error.BadSelector;
                        try validateSelector(ff, .text_field, lim);
                        if (!ff.eql(d.name_field)) return error.BadSelector;
                    },
                };
                if (phase == .verified and d.dir_field == null and d.save_panel == null) return error.MissingDirField;
                stage = 2;
            },
            .confirm => |c| {
                if (stage != 2) return error.BadStepOrder;
                try validateSelector(c, .button, lim);
                stage = 3;
            },
        }
    }
    if (stage < 2) return error.MissingDestination;
    if (stage < 3) return error.MissingConfirm;
    if (r.cancel) |c| try validateSelector(c, .button, lim);
}

pub fn validBasename(n: []const u8) bool {
    if (n.len == 0 or n.len > 255 or hasControl(n) or n[0] == '.') return false;
    for (n) |c| if (c == '/' or c == '\\') return false;
    return true;
}

/// Deepest nesting of a sidecar path, counting its file name.
pub const max_sidecar_depth = 8;

/// A relative path of at most `max_sidecar_depth` components. Each component is a valid basename,
/// so absolute paths, empty components, `.`, `..` and hidden names are rejected.
pub fn validRelPath(p: []const u8, lim: Limits) bool {
    if (p.len == 0 or p.len > lim.max_path) return false;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| {
        if (!validBasename(c)) return false;
        depth += 1;
        if (depth > max_sidecar_depth) return false;
    }
    return true;
}

/// Extension of the last path component, with its dot. Empty when it has none.
fn extOf(n: []const u8) []const u8 {
    const base = n[(std.mem.lastIndexOfScalar(u8, n, '/') orelse return extOfBase(n)) + 1 ..];
    return extOfBase(base);
}

fn extOfBase(n: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, n, '.') orelse return "";
    return n[i..];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// True when `dir` is a leading directory of `path`, ignoring case.
fn isDirPrefix(dir: []const u8, path: []const u8) bool {
    return path.len > dir.len and path[dir.len] == '/' and eqlIgnoreCase(path[0..dir.len], dir);
}

const image_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".tga" };

/// Canonical and documented alternative primary extensions. This is filename support only. It
/// says nothing about native availability or geometry.
pub fn primaryExts(f: Format) []const []const u8 {
    return switch (f) {
        .obj => &.{".obj"},
        .stl => &.{".stl"},
        .tds => &.{".3ds"},
        .fbx => &.{".fbx"},
        .parasolid => &.{ ".x_t", ".x_b" },
        .step => &.{ ".step", ".stp" },
        .pdf => &.{".pdf"},
        .dxf => &.{".dxf"},
        .dwg => &.{".dwg"},
        .png => &.{".png"},
        .sat => &.{".sat"},
        .usd => &.{ ".usd", ".usda", ".usdc" },
        .iges => &.{ ".igs", ".iges" },
        .threedm => &.{".3dm"},
        .ifc => &.{".ifc"},
    };
}

fn sidecarAllowed(f: Format, ext: []const u8) bool {
    switch (f) {
        .obj => {
            if (eqlIgnoreCase(ext, ".mtl")) return true;
        },
        .tds => {},
        else => return false,
    }
    for (image_exts) |e| if (eqlIgnoreCase(e, ext)) return true;
    return false;
}

fn inList(list: []const []const u8, ext: []const u8) bool {
    for (list) |e| if (eqlIgnoreCase(e, ext)) return true;
    return false;
}

/// Checks the supplied output names against the route format. The primary name is a basename.
/// Sidecars are relative paths that keep the exporter's directory layout. Sidecar extensions must
/// be allowed for the format. Aliases that differ only by case and file/directory conflicts are
/// refused. A listed sidecar is an expected file. It is not a closed dependency set.
pub fn validateOutputs(format: Format, o: ExpectedOutputs, lim: Limits) RouteError!void {
    if (!validBasename(o.primary) or !inList(primaryExts(format), extOf(o.primary))) return error.BadOutputName;
    if (o.required_sidecars.len > lim.max_listing or o.allowed_sidecar_exts.len > 16) return error.BadSidecar;
    for (o.required_sidecars, 0..) |s, i| {
        if (!validRelPath(s, lim) or !sidecarAllowed(format, extOf(s)) or std.mem.eql(u8, s, o.primary)) return error.BadSidecar;
        if (eqlIgnoreCase(s, o.primary) or isDirPrefix(o.primary, s)) return error.BadSidecar;
        for (o.required_sidecars[0..i]) |p| {
            if (eqlIgnoreCase(p, s) or isDirPrefix(p, s) or isDirPrefix(s, p)) return error.BadSidecar;
        }
    }
    for (o.allowed_sidecar_exts) |e| {
        if (e.len < 2 or e[0] != '.' or std.mem.indexOfScalar(u8, e, '/') != null or !sidecarAllowed(format, e)) return error.BadSidecar;
    }
}

/// Phase gate. Returns null when the request may run, else the refusal.
pub fn checkPhase(
    phase: Phase,
    route: Route,
    run_binding: Binding,
    scratch: ?ScratchAuthorization,
    lim: Limits,
) ?Failure {
    validateRoute(route, phase, lim) catch return .{ .kind = .invalid_route, .detail = "route shape is invalid" };
    switch (phase) {
        // The inventory phase validates the route shape and then executes only its menu step.
        .inventory => return null,
        .calibration => {
            const s = scratch orelse return .{ .kind = .scratch_not_authorized, .detail = "calibration needs an authorized scratch session" };
            if (!validLabel(s.session, lim.max_label)) return .{ .kind = .scratch_not_authorized, .detail = "scratch session id is invalid" };
            validateBinding(run_binding, lim) catch return .{ .kind = .invalid_route, .detail = "run binding is invalid" };
            if (!route.binding.eql(run_binding)) return .{ .kind = .stale_route, .detail = "route binding differs from the run binding" };
            return null;
        },
        .verified => {
            if (isTargeted(route.format)) return .{ .kind = .refused, .detail = "targeted formats run inventory and calibration only" };
            validateBinding(run_binding, lim) catch return .{ .kind = .invalid_route, .detail = "run binding is invalid" };
            if (route.status != .calibrated) return .{ .kind = .uncalibrated_route, .detail = "route is not calibrated" };
            const ev = route.evidence orelse return .{ .kind = .uncalibrated_route, .detail = "route has no calibration evidence" };
            if (!validLabel(ev.calibration_id, lim.max_label)) return .{ .kind = .uncalibrated_route, .detail = "calibration id is invalid" };
            validateBinding(ev.binding, lim) catch return .{ .kind = .stale_route, .detail = "evidence binding is invalid" };
            if (!route.binding.eql(run_binding) or !ev.binding.eql(run_binding)) return .{ .kind = .stale_route, .detail = "route or evidence binding differs from the run binding" };
            return null;
        },
    }
}

/// Explicit authorization of a scratch calibration session. It never makes a route verified.
pub const ScratchAuthorization = struct {
    session: []const u8,
};

// Statistics and reports

pub const CallStat = struct {
    count: u32 = 0,
    failures: u32 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
};

pub const Stats = struct {
    observe: CallStat = .{},
    lookup: CallStat = .{},
    identity: CallStat = .{},
    action: CallStat = .{},
    progress: CallStat = .{},
    screenshot: CallStat = .{},
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    polls: u32 = 0,
    sleep_ms: u64 = 0,
    /// Waits that a notification ended.
    wakeups: u32 = 0,
    /// Waits that ran to the end of their interval. They are the polling fallback.
    poll_waits: u32 = 0,
    /// Notification subscriptions made before an action.
    arms: u32 = 0,
    diagnostics: u32 = 0,
    cadence: Cadence = .{},
    elapsed_ns: u64 = 0,
};

fn rec(stat: *CallStat, t0: u64, t1: u64, failed: bool) void {
    const d = t1 -| t0;
    stat.count += 1;
    stat.total_ns += d;
    stat.max_ns = @max(stat.max_ns, d);
    if (failed) stat.failures += 1;
}

pub const FailureReport = struct {
    /// `.uncertain_mutation` when `uncertain` is true, else equal to `cause`.
    kind: FailureKind,
    cause: FailureKind,
    uncertain: bool = false,
    /// Index of the route step that was running, when one was.
    step: ?usize = null,
    detail_buf: [160]u8 = undefined,
    detail_len: u8 = 0,
    /// Diagnostic capture beside the failure. It never replaces the failure.
    diag: DiagNote = .{},

    pub fn detail(f: *const FailureReport) []const u8 {
        return f.detail_buf[0..f.detail_len];
    }
};

/// Result of the diagnostic capture of one operation. It sits beside the failure and never changes
/// it. `captured` is false when the capture failed or was refused. `note` then says why. After a
/// capture it holds the path or the text that the hook returned.
pub const DiagNote = struct {
    attempted: bool = false,
    captured: bool = false,
    /// A static trigger name: `unknown_modal`, `selector_failed`, `missing_transition` or `stall`.
    reason: []const u8 = "",
    note_buf: [240]u8 = undefined,
    note_len: u8 = 0,

    pub fn note(d: *const DiagNote) []const u8 {
        return d.note_buf[0..d.note_len];
    }

    fn setNote(d: *DiagNote, s: []const u8) void {
        const n = @min(s.len, d.note_buf.len);
        @memcpy(d.note_buf[0..n], s[0..n]);
        d.note_len = @intCast(n);
    }
};

fn withDiag(r: FailureReport, op: *const Op) FailureReport {
    var x = r;
    x.diag = op.diag;
    return x;
}

fn makeFailure(f: Failure, step: ?usize) FailureReport {
    var r: FailureReport = .{
        .kind = if (f.uncertain) .uncertain_mutation else f.kind,
        .cause = f.kind,
        .uncertain = f.uncertain,
        .step = step,
    };
    const n = @min(f.detail.len, r.detail_buf.len);
    @memcpy(r.detail_buf[0..n], f.detail[0..n]);
    r.detail_len = @intCast(n);
    return r;
}

pub const FileRole = enum { primary, expected_sidecar, allowed_sidecar, unexpected };

pub const FileRecord = struct {
    name: []u8,
    size: u64,
    role: FileRole,
};

/// One option that the runtime set. `observed` is the value read back from the control.
pub const OptionRecord = struct {
    label: []u8,
    requested: []u8,
    observed: []u8,
};

/// One control found by inventory lookup.
pub const ControlRecord = struct {
    label: []u8,
    count: u16,
    value: []u8,
    enabled: bool,
};

/// What the file records establish. A bounded listing with expected and allowed roles is not a
/// semantic dependency closure. Only the bundle or pack layer can establish one, by parsing the
/// exported files. This module never does.
pub const DependencyClosure = enum { not_established };

pub const ExportReport = struct {
    phase: Phase,
    route_id: []const u8,
    failure: ?FailureReport = null,
    options: []OptionRecord = &.{},
    files: []FileRecord = &.{},
    controls: []ControlRecord = &.{},
    screenshot: ?FileRecord = null,
    /// True only for a verified-phase run that completed with no failure. The bundle layer still
    /// validates the files.
    verified: bool = false,
    /// Names the exporter wrote as relative paths. Entries keep the exporter layout without
    /// flattening or renaming. See `DependencyClosure`.
    dependency_closure: DependencyClosure = .not_established,
    stats: Stats = .{},
    /// Diagnostic capture of the operation. It is set after a stall trigger even when the export
    /// completed.
    diag: DiagNote = .{},
    /// How completion was established. See `Completion` and `Runtime.awaitCompletion`.
    completion: Completion = .{},

    pub fn ok(r: ExportReport) bool {
        return r.failure == null;
    }

    pub fn deinit(r: *ExportReport, a: Allocator) void {
        for (r.options) |o| {
            a.free(o.label);
            a.free(o.requested);
            a.free(o.observed);
        }
        a.free(r.options);
        for (r.files) |f| a.free(f.name);
        a.free(r.files);
        for (r.controls) |c| {
            a.free(c.label);
            a.free(c.value);
        }
        a.free(r.controls);
        if (r.screenshot) |s| a.free(s.name);
        r.* = undefined;
    }
};

pub const ReconcileInfo = struct {
    cause: FailureKind,
    step: ?usize,
};

// Selector cache

/// Remembers the layout id at which a selector resolved to one control. An entry is valid while
/// the pid and the container layout id still match. Entries hold no pointers.
pub const SelectorCache = struct {
    const cap = 16;
    const Entry = struct { used: bool = false, h1: u64 = 0, h2: u64 = 0, pid: i32 = 0, layout_id: u64 = 0 };
    entries: [cap]Entry = [_]Entry{.{}} ** cap,
    next: usize = 0,

    fn keys(sel: Selector) [2]u64 {
        var h1 = std.hash.Wyhash.init(0x51ec);
        var h2 = std.hash.Wyhash.init(0xa7c3);
        inline for (.{ &h1, &h2 }) |h| {
            h.update(&.{@intFromEnum(sel.role)});
            switch (sel.container) {
                .document_sheet => h.update("S"),
                .window => |t| {
                    h.update("W");
                    h.update(t);
                },
                .window_sheet => |t| {
                    h.update("X");
                    h.update(t);
                },
            }
            h.update(&.{0});
            h.update(sel.label);
            switch (sel.via) {
                .name => {},
                .title_element => h.update("\x01T"),
                .path => |p| {
                    h.update("\x01P");
                    for (p) |st| h.update(&.{ @intFromEnum(st.role), st.index, st.of });
                },
            }
        }
        return .{ h1.final(), h2.final() };
    }

    pub fn get(c: *const SelectorCache, sel: Selector, pid: i32) ?u64 {
        const k = keys(sel);
        for (c.entries) |e| if (e.used and e.pid == pid and e.h1 == k[0] and e.h2 == k[1]) return e.layout_id;
        return null;
    }

    pub fn put(c: *SelectorCache, sel: Selector, pid: i32, layout_id: u64) void {
        const k = keys(sel);
        for (&c.entries) |*e| if (e.used and e.pid == pid and e.h1 == k[0] and e.h2 == k[1]) {
            e.layout_id = layout_id;
            return;
        };
        c.entries[c.next] = .{ .used = true, .h1 = k[0], .h2 = k[1], .pid = pid, .layout_id = layout_id };
        c.next = (c.next + 1) % cap;
    }

    pub fn drop(c: *SelectorCache, sel: Selector, pid: i32) void {
        const k = keys(sel);
        for (&c.entries) |*e| if (e.used and e.pid == pid and e.h1 == k[0] and e.h2 == k[1]) {
            e.used = false;
        };
    }

    /// Drops every entry. Call after navigation, document replacement, restart or a layout change.
    pub fn invalidate(c: *SelectorCache) void {
        for (&c.entries) |*e| e.used = false;
    }

    pub fn count(c: *const SelectorCache) usize {
        var n: usize = 0;
        for (c.entries) |e| if (e.used) {
            n += 1;
        };
        return n;
    }
};

// Runtime

pub const ExportRequest = struct {
    phase: Phase,
    route: Route,
    /// Expected document and console options. The runtime clears both acknowledgement permissions.
    policy: ui.Policy,
    pid: i32,
    run_binding: Binding,
    /// Operation id. Names the last component of `op_dir`.
    op_id: []const u8,
    /// Absolute path of an existing empty directory for this operation only.
    op_dir: []const u8,
    outputs: ExpectedOutputs,
    scratch: ?ScratchAuthorization = null,
    /// Inventory phase only. Basename ending in `.png`, written into `op_dir`.
    screenshot_name: ?[]const u8 = null,
};

pub const GateRequest = struct {
    pid: i32,
    policy: ui.Policy,
    /// Native open may observe an incomplete window list while the app changes documents.
    wait_for_readable_windows: bool = false,
};

pub const GateReport = struct {
    failure: ?FailureReport = null,
    ready: bool = false,
    title_buf: [320]u8 = undefined,
    title_len: usize = 0,
    acknowledged_conversion: bool = false,
    acknowledged_watermark: bool = false,
    stats: Stats = .{},

    pub fn title(g: *const GateReport) []const u8 {
        return g.title_buf[0..g.title_len];
    }
};

const Op = struct {
    pid: i32,
    policy: ui.Policy,
    deadline_ns: u64,
    title_buf: [320]u8 = undefined,
    title_len: usize = 0,
    step: ?usize = null,
    /// True after the menu step of an export ran. A failure then leaves a dialog open.
    menu_open: bool = false,
    /// Static text of the last mutating call, for the diagnostic record.
    last_action: []const u8 = "",
    /// What the operation waits for now, for the diagnostic record. A selector label or a static text.
    expect_note: []const u8 = "",
    /// The export bundle directory. A diagnostic never goes there.
    bundle_dir: []const u8 = "",
    /// True once the confirm press was sent. Files may exist after it.
    confirm_sent: bool = false,
    /// True once the output listing of the operation ran.
    collected: bool = false,
    /// Progress value read just before the confirm press. Null when no indicator was shown.
    progress_baseline: ?u32 = null,
    /// The longest observed gap between two changes. The stall trigger scales with it.
    max_gap_ns: u64 = 0,
    /// True after a selector lookup failed.
    selector_failed: bool = false,
    diag: DiagNote = .{},

    fn selectorFailed(op: *Op, sel: Selector, f: Failure) Runtime.Resolved {
        op.selector_failed = true;
        op.expect_note = sel.reportLabel();
        return .{ .failed = f };
    }

    fn title(op: *const Op) []const u8 {
        return op.title_buf[0..op.title_len];
    }

    fn setTitle(op: *Op, t: []const u8) bool {
        if (t.len > op.title_buf.len) return false;
        @memcpy(op.title_buf[0..t.len], t);
        op.title_len = t.len;
        return true;
    }
};

const Builder = struct {
    options: std.ArrayList(OptionRecord) = .empty,
    files: std.ArrayList(FileRecord) = .empty,
    controls: std.ArrayList(ControlRecord) = .empty,

    fn deinit(b: *Builder, a: Allocator) void {
        for (b.options.items) |o| {
            a.free(o.label);
            a.free(o.requested);
            a.free(o.observed);
        }
        b.options.deinit(a);
        for (b.files.items) |f| a.free(f.name);
        b.files.deinit(a);
        for (b.controls.items) |c| {
            a.free(c.label);
            a.free(c.value);
        }
        b.controls.deinit(a);
    }
};

/// A durable record that an action is in flight. `begin` runs before the first mutating backend call
/// of an operation and returns false when the record cannot be written. `end` runs after the reply.
/// `definite` is true when the reply proves that the action did not leave the app in an unknown
/// state. A false value keeps the record. The caller owns the file and the startup refusal.
pub const Journal = struct {
    ptr: *anyopaque,
    beginFn: *const fn (ptr: *anyopaque, what: []const u8) bool,
    endFn: *const fn (ptr: *anyopaque, definite: bool) void,
};

pub const Runtime = struct {
    a: Allocator,
    backend: Backend,
    env: Env,
    files: Files,
    limits: Limits = .{},
    run_start: u64,
    stats: Stats = .{},
    cache: SelectorCache = .{},
    reconcile: ?ReconcileInfo = null,
    /// Exact operation directory paths that this runtime accepted. The set grows with the run. Its
    /// keys are full paths, so only a real reuse of a directory collides. It uses the page allocator
    /// because the runtime has no deinit and the keys live as long as the process.
    used: std.StringHashMapUnmanaged(void) = .empty,
    /// Durable in-flight record around each mutating backend call. Null keeps the old behavior.
    journal: ?Journal = null,
    /// Wakeups from the app. Null makes every wait a bounded poll.
    notifier: ?Notifier = null,
    /// Read-only UI capture for unknown UI, failed selectors, missing transitions and stalls.
    diagnostic: ?Diagnostic = null,
    /// Absolute directory outside every export bundle. With no `diagnostic` hook the runtime
    /// writes one window screenshot per diagnosed operation here through the backend.
    diag_dir: ?[]const u8 = null,
    diag_seq: u32 = 0,

    pub fn init(a: Allocator, backend: Backend, env: Env, files: Files, limits: Limits) Runtime {
        return .{ .a = a, .backend = backend, .env = env, .files = files, .limits = limits, .run_start = env.now() };
    }

    /// The latch set by an uncertain mutation. Null when none is pending.
    pub fn reconcileRequired(rt: *const Runtime) ?ReconcileInfo {
        return rt.reconcile;
    }

    /// Clears the latch. The caller reconciles the real application and output state first. The
    /// reason is a non-empty string that the caller records.
    pub fn clearReconcile(rt: *Runtime, reason: []const u8) bool {
        if (rt.reconcile == null or reason.len == 0) return false;
        rt.reconcile = null;
        rt.cache.invalidate();
        return true;
    }

    // Deadlines

    fn runDeadline(rt: *const Runtime) u64 {
        return rt.run_start + @as(u64, rt.limits.run_deadline_ms) * std.time.ns_per_ms;
    }

    fn newOp(rt: *Runtime, pid: i32, policy: ui.Policy) Op {
        const now = rt.env.now();
        const op_end = now + @as(u64, rt.limits.op_deadline_ms) * std.time.ns_per_ms;
        return .{ .pid = pid, .policy = policy, .deadline_ns = @min(op_end, rt.runDeadline()) };
    }

    fn expired(rt: *Runtime, op: *const Op) ?Failure {
        const now = rt.env.now();
        if (now >= rt.runDeadline()) return .{ .kind = .deadline_exceeded, .detail = "run deadline passed" };
        if (now >= op.deadline_ns) return .{ .kind = .timeout, .detail = "operation deadline passed" };
        return null;
    }

    fn ctx(rt: *Runtime, op: *const Op) Ctx {
        const now = rt.env.now();
        const left_ns = op.deadline_ns -| now;
        const left_ms: u64 = @max(1, left_ns / std.time.ns_per_ms);
        return .{
            .pid = op.pid,
            .expected = op.policy.expected,
            .window_title = op.title(),
            .timeout_ms = @intCast(@min(left_ms, rt.limits.call_timeout_ms)),
        };
    }

    fn sleepPoll(rt: *Runtime, ms: u32) void {
        rt.stats.sleep_ms += ms;
        rt.env.sleep(ms);
    }

    // Observed-condition waiting

    const Waiter = struct {
        b: Backoff,
        last: enum { none, woke, timed_out, slept } = .none,
    };

    fn waiter(rt: *const Runtime) Waiter {
        var b = Backoff.init(rt.limits.poll_min_ms, rt.fallbackNow());
        b.growth = rt.limits.poll_growth;
        return .{ .b = b };
    }

    /// Subscribes to the app's notifications. It runs before an action, so a change that the action
    /// causes cannot pass unseen. Without a notifier nothing happens and the waits poll.
    pub fn armNotifier(rt: *Runtime, pid: i32, dir: []const u8) void {
        const n = rt.notifier orelse return;
        rt.stats.arms += 1;
        n.arm(pid, dir);
    }

    /// One wait between two observations. A notification ends it early. The caller reads the
    /// current state after it returns, so a notification is a cue and the state is the evidence.
    /// With no notifier, or when a notification is lost, the wait ends after its interval, so the
    /// fallback is a bounded poll. The interval starts at `poll_min_ms`, grows while nothing changes
    /// and restarts at a change. With a notifier its upper bound adapts to what the waits showed. A
    /// change found after a wait that a notification ended shows that notifications arrive, and the
    /// bound grows toward `poll_max_ms`. A change found after a wait that ran to its interval
    /// shows that a notification may have been lost, and the bound shrinks toward `poll_min_ms`.
    /// `Stats.cadence` records the chosen intervals, the counts and the reason.
    fn waitStep(rt: *Runtime, w: *Waiter, changed: bool) void {
        const c = &rt.stats.cadence;
        if (rt.notifier != null) {
            const hi = @max(rt.limits.poll_max_ms, rt.limits.poll_ms);
            const lo = if (rt.limits.poll_ms == 0) 0 else @max(1, @min(rt.limits.poll_min_ms, rt.limits.poll_ms));
            switch (w.last) {
                .timed_out => if (changed) {
                    c.missed += 1;
                    c.fallback_ms = @max(lo, rt.fallbackNow() / 2);
                    c.reason = .notification_missed;
                },
                .woke => if (changed) {
                    c.delivered += 1;
                    c.fallback_ms = @min(hi, rt.fallbackNow() *| @max(2, rt.limits.poll_growth));
                    c.reason = .notifications_delivered;
                },
                else => {},
            }
            w.b.max_ms = rt.fallbackNow();
        } else {
            c.fallback_ms = rt.limits.poll_ms;
            c.reason = .no_notifier;
            w.b.max_ms = rt.limits.poll_ms;
        }
        const ms = w.b.next(changed);
        c.record(ms);
        if (rt.notifier) |n| {
            const t0 = rt.env.now();
            const woke = n.waitFn(n.ptr, ms);
            rt.stats.sleep_ms += (rt.env.now() -| t0) / std.time.ns_per_ms;
            if (woke) {
                rt.stats.wakeups += 1;
                c.woke += 1;
                w.last = .woke;
            } else {
                rt.stats.poll_waits += 1;
                c.timed_out += 1;
                w.last = .timed_out;
            }
            return;
        }
        rt.stats.poll_waits += 1;
        w.last = .slept;
        rt.sleepPoll(ms);
    }

    /// The upper bound of the fallback interval now.
    fn fallbackNow(rt: *const Runtime) u32 {
        const f = rt.stats.cadence.fallback_ms;
        return if (f == 0) rt.limits.poll_ms else f;
    }

    // Diagnostics

    /// Raises the stall trigger once when no activity was observed for the stall threshold. It
    /// captures the UI and returns. The observation goes on, so a slow export that completes is not
    /// cut off. The threshold is `stall_ms` or three times the longest gap between two changes in
    /// this operation, whichever is longer, so an export that works in bursts is not flagged inside
    /// its own rhythm.
    fn watchStall(rt: *Runtime, op: *Op, last_change: *u64, changed: bool) void {
        const now = rt.env.now();
        if (changed) {
            op.max_gap_ns = @max(op.max_gap_ns, now -| last_change.*);
            last_change.* = now;
            return;
        }
        if (rt.limits.stall_ms == 0) return;
        const need = @max(@as(u64, rt.limits.stall_ms) * std.time.ns_per_ms, op.max_gap_ns *| 3);
        if (now -| last_change.* >= need) rt.diagnose(op, "stall");
    }

    /// Captures the UI for a failure that needs diagnosis. An unknown dialog, a failed selector
    /// and a missing expected transition qualify. Other failures do not.
    fn diagnoseFailure(rt: *Runtime, op: *Op, f: Failure) void {
        const reason: []const u8 = if (op.selector_failed) "selector_failed" else switch (f.kind) {
            .unknown_ui, .ambiguous_target => "unknown_modal",
            .timeout => "missing_transition",
            else => return,
        };
        rt.diagnose(op, reason);
    }

    /// One read-only capture per operation. The hook, or the backend screenshot into `diag_dir`,
    /// stores files outside the export bundle. The result goes into `op.diag` and never replaces
    /// the failure of the operation. Nothing is attempted when no capture is configured.
    fn diagnose(rt: *Runtime, op: *Op, reason: []const u8) void {
        if (op.diag.attempted) return;
        if (rt.diagnostic == null and rt.diag_dir == null) return;
        op.diag.attempted = true;
        op.diag.reason = reason;
        rt.stats.diagnostics += 1;
        if (rt.diagnostic) |d| {
            const r = d.captureFn(d.ptr, .{
                .pid = op.pid,
                .window_title = op.title(),
                .reason = reason,
                .expected = op.expect_note,
                .last_action = op.last_action,
            });
            op.diag.captured = r.captured;
            op.diag.setNote(r.detail);
            return;
        }
        const dir = rt.diag_dir.?;
        const b = op.bundle_dir;
        if (b.len != 0 and std.mem.startsWith(u8, dir, b) and (dir.len == b.len or dir[b.len] == '/')) {
            op.diag.setNote("the diagnostic directory is inside the export bundle. Nothing was captured");
            return;
        }
        rt.diag_seq += 1;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/diag-{d}-{d}.png", .{ dir, op.pid, rt.diag_seq }) catch {
            op.diag.setNote("the diagnostic path is too long");
            return;
        };
        var c = rt.ctx(op);
        c.timeout_ms = rt.limits.call_timeout_ms;
        const t0 = rt.env.now();
        const r = rt.backend.screenshot(c, path);
        rec(&rt.stats.screenshot, t0, rt.env.now(), r == .failed);
        switch (r) {
            .failed => |f| {
                var nb: [240]u8 = undefined;
                op.diag.setNote(std.fmt.bufPrint(&nb, "screenshot failed: {s} {s}", .{ @tagName(f.kind), f.detail }) catch "screenshot failed");
            },
            .done => {
                const size = rt.files.size(path) orelse 0;
                if (size == 0) {
                    op.diag.setNote("the screenshot file is absent or empty");
                } else {
                    op.diag.captured = true;
                    op.diag.setNote(path);
                }
            },
        }
    }

    // Calls with statistics

    const DecisionReply = union(enum) { decision: ui.Decision, failed: Failure };
    const CloseObservation = union(enum) { decision: ui.Decision, unreadable: void, failed: Failure };

    fn observeBounded(rt: *Runtime, op: *Op) ObserveReply {
        if (rt.expired(op)) |f| return .{ .failed = f };
        const t0 = rt.env.now();
        const r = rt.backend.observe(rt.ctx(op));
        rec(&rt.stats.observe, t0, rt.env.now(), r == .failed);
        return r;
    }

    fn observeOnce(rt: *Runtime, op: *Op) DecisionReply {
        return switch (rt.observeBounded(op)) {
            .failed => |f| .{ .failed = f },
            .observed => |o| .{ .decision = ui.decide(o, op.policy) },
        };
    }

    fn observeClosed(rt: *Runtime, op: *Op) CloseObservation {
        return switch (rt.observeBounded(op)) {
            .failed => |f| .{ .failed = f },
            .observed => |o| closeObservation(o, op.policy),
        };
    }

    fn closeObservation(o: ui.Observation, policy: ui.Policy) CloseObservation {
        const d = closeDecision(o, policy);
        if (!o.windows_complete and d.kind == .unknown_ui) {
            // A known modal refuses immediately. Unreadable flags require another read.
            for (o.windows) |window| if (window.modal == true) return .{ .decision = d };
            return .{ .unreadable = {} };
        }
        return .{ .decision = d };
    }

    /// The observation after the close menu step. Without a policy it is `observeClosed`. With one, the
    /// exact save prompt of the owned document is answered once with Don't Save. Every other modal keeps
    /// the refusal of `closeDecision`. A prompt that is not readable yet, or that stands beside an
    /// incomplete window read, is waited for. The complete-observation rule is not relaxed.
    fn observeClosedWith(rt: *Runtime, op: *Op, discard: ?DiscardPolicy, st: *DiscardState) CloseObservation {
        const dp = discard orelse return rt.observeClosed(op);
        const o = switch (rt.observeBounded(op)) {
            .failed => |f| return .{ .failed = f },
            .observed => |o| o,
        };
        switch (classifyPrompt(o, dp)) {
            .none => return closeObservation(o, op.policy),
            .loading => return .{ .unreadable = {} },
            .mismatch => return .{ .decision = closeDecision(o, op.policy) },
            .exact => |at| {
                if (!o.windows_complete) return .{ .unreadable = {} };
                if (st.pressed) return .{ .failed = .{ .kind = .unknown_ui, .detail = "the save prompt appeared again after Don't Save" } };
                // Everything except the prompt must be one ready window of the owned document: console,
                // completeness, no other document and no other dialog.
                var rest: [32]ui.WindowObservation = undefined;
                if (o.windows.len > rest.len) return .{ .failed = .{ .kind = .unknown_ui, .detail = "too many windows" } };
                var k: usize = 0;
                for (o.windows, 0..) |x, i| {
                    if (i == at) continue;
                    rest[k] = x;
                    k += 1;
                }
                var filtered = o;
                filtered.windows = rest[0..k];
                const d = ui.decide(filtered, op.policy);
                if (d.kind != .ready) return .{ .failed = mapDecision(d) };
                const w = o.windows[at];
                if (rt.action(op, .dismiss, .{DismissRequest{ .title = w.title, .texts = w.texts.?, .button = discard_button }})) |f| return .{ .failed = f };
                st.pressed = true;
                rt.cache.invalidate();
                return .{ .unreadable = {} };
            },
        }
    }

    // File > Close can expose another document. Only the post-action observation uses this scope.
    fn closeDecision(o: ui.Observation, policy: ui.Policy) ui.Decision {
        const d = ui.decide(o, policy);
        if (d.kind != .wrong_target) return d;
        var matches: usize = 0;
        var title: ?[]const u8 = null;
        for (o.windows) |window| {
            if (window.modal != false) return d;
            if (window.title) |name| {
                const match = ui.matchTitle(policy.expected, name) catch return d;
                if (match.kind != .none) {
                    matches += 1;
                    title = name;
                }
            }
        }
        if (matches > 1) return d;
        if (matches == 1) return .{ .kind = .ready, .title = title };
        return .{ .kind = .wait, .action = .wait, .detail = "expected document window not visible after close" };
    }

    fn mapDecision(d: ui.Decision) Failure {
        const kind: FailureKind = switch (d.kind) {
            .console_locked => .console_locked,
            .console_wrong, .wrong_target => .wrong_identity,
            .transport_failure => .transport_error,
            .process_missing => .process_lost,
            .invalid_expectation => .refused,
            .ready, .wait, .proposed_action, .console_unknown, .unknown_ui, .not_permitted => .unknown_ui,
        };
        return .{ .kind = kind, .detail = d.detail };
    }

    /// True when the whole-run budget has passed. A caller refuses a new operation before any action.
    pub fn budgetExhausted(rt: *const Runtime) bool {
        return rt.env.now() >= rt.runDeadline();
    }

    /// Restarts the whole-run budget. The caller sets `limits.run_deadline_ms` from the activation
    /// packet and calls this when the run starts. A retry does not refresh the budget.
    pub fn restartRun(rt: *Runtime) void {
        rt.run_start = rt.env.now();
    }

    /// True when a failed mutating reply proves that the action did not run.
    fn definiteRefusal(f: Failure) bool {
        return !f.uncertain and (f.kind == .refused or f.kind == .ambiguous_target or f.kind == .unknown_ui);
    }

    fn journalBegin(rt: *Runtime, what: []const u8) ?Failure {
        const j = rt.journal orelse return null;
        if (j.beginFn(j.ptr, what)) return null;
        return .{ .kind = .refused, .detail = "the in-flight record could not be written" };
    }

    fn journalEnd(rt: *Runtime, definite: bool) void {
        if (rt.journal) |j| j.endFn(j.ptr, definite);
    }

    /// One menu, press, acknowledgement or screenshot call. A deadline refuses before the in-flight
    /// record is written. The record covers the call and stays after a reply that is not definite.
    fn action(rt: *Runtime, op: *Op, comptime which: enum { menu, press, ack, screenshot, chord, dismiss }, args: anytype) ?Failure {
        if (rt.expired(op)) |f| return f;
        const mutating = which != .screenshot;
        if (mutating) if (rt.journalBegin(@tagName(which))) |f| return f;
        if (mutating) {
            rt.armNotifier(op.pid, op.bundle_dir);
            op.last_action = @tagName(which);
        }
        const c = rt.ctx(op);
        const t0 = rt.env.now();
        const reply: ActionReply = switch (which) {
            .menu => rt.backend.menu(c, args[0]),
            .press => rt.backend.press(c, args[0]),
            .ack => rt.backend.acknowledge(c, args[0]),
            .screenshot => rt.backend.screenshot(c, args[0]),
            .chord => rt.backend.chord(c, args[0], args[1]),
            .dismiss => rt.backend.dismiss(c, args[0]),
        };
        rec(&rt.stats.action, t0, rt.env.now(), reply == .failed);
        switch (reply) {
            .done => {
                if (mutating) rt.journalEnd(true);
                return null;
            },
            .failed => |f| {
                if (mutating) rt.journalEnd(definiteRefusal(f));
                return f;
            },
        }
    }

    fn setWithReadback(rt: *Runtime, op: *Op, sel: Selector, value: OptionValue) union(enum) { observed: ?[]const u8, failed: Failure } {
        if (rt.expired(op)) |f| return .{ .failed = f };
        if (rt.journalBegin("set")) |f| return .{ .failed = f };
        rt.armNotifier(op.pid, op.bundle_dir);
        op.last_action = "set";
        const c = rt.ctx(op);
        const t0 = rt.env.now();
        const reply = rt.backend.setValue(c, sel, value);
        rec(&rt.stats.action, t0, rt.env.now(), reply == .failed);
        switch (reply) {
            .done => |v| {
                rt.journalEnd(true);
                return .{ .observed = v };
            },
            .failed => |f| {
                rt.journalEnd(!f.uncertain);
                return .{ .failed = f };
            },
        }
    }

    const Resolved = union(enum) { ok, failed: Failure };

    /// Finds exactly one enabled control. A cached layout id skips the lookup while the container
    /// identity matches. With `appear` the call retries while the control is absent, up to
    /// `dialog_wait_ms`.
    fn resolve(rt: *Runtime, op: *Op, sel: Selector, appear: bool) Resolved {
        const give_up = rt.env.now() + @as(u64, rt.limits.dialog_wait_ms) * std.time.ns_per_ms;
        var w = rt.waiter();
        while (true) {
            if (rt.expired(op)) |f| return .{ .failed = f };
            if (rt.cache.get(sel, op.pid)) |cached| {
                const t0 = rt.env.now();
                const id = rt.backend.identity(rt.ctx(op), sel.container);
                rec(&rt.stats.identity, t0, rt.env.now(), id == .failed);
                switch (id) {
                    .failed => |f| return .{ .failed = f },
                    .present => |layout| if (layout == cached) {
                        rt.stats.cache_hits += 1;
                        return .ok;
                    },
                    .absent => {},
                }
                rt.cache.drop(sel, op.pid);
            }
            rt.stats.cache_misses += 1;
            const t0 = rt.env.now();
            const r = rt.backend.lookup(rt.ctx(op), sel);
            rec(&rt.stats.lookup, t0, rt.env.now(), r == .failed);
            switch (r) {
                .failed => |f| {
                    // A sheet that the last action opens is absent for a moment. That absence is the
                    // thing being waited for, so it is retried until `dialog_wait_ms`, like a missing control.
                    if (appear and isAbsentContainer(f) and rt.env.now() < give_up) {
                        rt.waitStep(&w, false);
                        continue;
                    }
                    return .{ .failed = f };
                },
                .found => |c| {
                    if (c.count > 1) return op.selectorFailed(sel, .{ .kind = .ambiguous_target, .detail = "more than one control matches the selector" });
                    if (c.count == 1) {
                        if (!c.enabled) return op.selectorFailed(sel, .{ .kind = .refused, .detail = "control is disabled" });
                        rt.cache.put(sel, op.pid, c.layout_id);
                        return .ok;
                    }
                    if (appear and rt.env.now() < give_up) {
                        rt.waitStep(&w, false);
                        continue;
                    }
                    return op.selectorFailed(sel, .{ .kind = .unknown_ui, .detail = "control not found" });
                },
            }
        }
    }

    fn allocFail() Failure {
        return .{ .kind = .out_of_memory, .detail = "allocation failed" };
    }

    fn pushOption(rt: *Runtime, b: *Builder, label: []const u8, requested: []const u8, observed: []const u8) ?Failure {
        const l = rt.a.dupe(u8, label) catch return allocFail();
        const q = rt.a.dupe(u8, requested) catch {
            rt.a.free(l);
            return allocFail();
        };
        const o = rt.a.dupe(u8, observed) catch {
            rt.a.free(l);
            rt.a.free(q);
            return allocFail();
        };
        b.options.append(rt.a, .{ .label = l, .requested = q, .observed = o }) catch {
            rt.a.free(l);
            rt.a.free(q);
            rt.a.free(o);
            return allocFail();
        };
        return null;
    }

    /// Sets one option and checks the read back value.
    /// Sets a disclosure triangle to the requested state. The value is read first. A control that
    /// already holds it is left alone. Otherwise one press runs, and the value read back must be the
    /// requested one. The triangle may take a moment to report it, so the read back is a bounded poll
    /// of reads that sends no second press. The deadline ends the poll as a failure.
    fn setDisclosure(rt: *Runtime, op: *Op, b: *Builder, sel: Selector, value: OptionValue) ?Failure {
        const want: []const u8 = if (value == .checked and value.checked) "1" else "0";
        const t0 = rt.env.now();
        const before = rt.backend.lookup(rt.ctx(op), sel);
        rec(&rt.stats.lookup, t0, rt.env.now(), before == .failed);
        switch (before) {
            .failed => |f| return f,
            .found => |c| {
                if (c.count != 1) return op.selectorFailed(sel, .{ .kind = .ambiguous_target, .detail = "the disclosure control is not exactly one control" }).failed;
                if (!c.enabled) return op.selectorFailed(sel, .{ .kind = .refused, .detail = "control is disabled" }).failed;
                const cur = c.value orelse "";
                if (valueEquals(cur, want)) return rt.pushOption(b, sel.reportLabel(), want, cur);
            },
        }
        const got: []const u8 = switch (rt.setWithReadback(op, sel, value)) {
            .failed => |f| return f,
            .observed => |v| v orelse "",
        };
        if (valueEquals(got, want)) return rt.pushOption(b, sel.reportLabel(), want, got);
        if (rt.expired(op)) |f| {
            var uf = f;
            uf.uncertain = true;
            return uf;
        }
        const left_ms: u32 = @intCast(@min(rt.limits.dialog_wait_ms, (op.deadline_ns -| rt.env.now()) / std.time.ns_per_ms));
        const res = awaitValue(rt.backend, rt.env, rt.ctx(op), sel, want, left_ms, rt.limits);
        switch (res) {
            .failed => |f| {
                var uf = f;
                uf.uncertain = true;
                return uf;
            },
            .matched => |v| return rt.pushOption(b, sel.reportLabel(), want, v),
            .timed_out => |v| {
                if (rt.pushOption(b, sel.reportLabel(), want, v)) |f| return f;
                return .{ .kind = .incomplete_options, .detail = "the disclosure control did not read back the requested state before the deadline" };
            },
        }
    }

    fn setOption(rt: *Runtime, op: *Op, b: *Builder, sel: Selector, value: OptionValue, appear: bool) ?Failure {
        switch (rt.resolve(op, sel, appear)) {
            .failed => |f| return f,
            .ok => {},
        }
        if (sel.role == .disclosure) return rt.setDisclosure(op, b, sel, value);
        const want: []const u8 = switch (value) {
            .checked => |c| if (c) "1" else "0",
            .choice => |s| s,
            .text => |s| s,
        };
        switch (rt.setWithReadback(op, sel, value)) {
            .failed => |f| return f,
            .observed => |v| {
                const got = v orelse "";
                if (rt.pushOption(b, sel.reportLabel(), want, got)) |f| return f;
                if (v == null or !std.mem.eql(u8, got, want)) {
                    return .{ .kind = .incomplete_options, .detail = "read back value differs from the requested value" };
                }
                return null;
            },
        }
    }

    // Gate

    /// Waits until the expected document window is ready. A known conversion or watermark notice
    /// is acknowledged once when the policy permits it. Any other dialog stops the gate. Each pass
    /// reads the current state before it waits. The wait starts short, grows while the state stays
    /// the same and starts short again at a change. No change for `stall_ms` raises one diagnostic
    /// capture.
    pub fn waitForDocument(rt: *Runtime, req: GateRequest) GateReport {
        var g: GateReport = .{};
        const t_start = rt.env.now();
        var op = rt.newOp(req.pid, req.policy);
        op.expect_note = "the expected document window";
        if (rt.gateInner(req, &op, &g)) |f| {
            rt.diagnoseFailure(&op, f);
            g.failure = withDiag(makeFailure(f, null), &op);
            if (f.uncertain) rt.reconcile = .{ .cause = f.kind, .step = null };
        }
        g.stats = rt.finishStats(t_start);
        return g;
    }

    fn gateInner(rt: *Runtime, req: GateRequest, op: *Op, g: *GateReport) ?Failure {
        if (rt.reconcile != null) return .{ .kind = .uncertain_mutation, .detail = "reconciliation is pending" };
        req.policy.expected.validate() catch return .{ .kind = .refused, .detail = "expected document name is invalid" };
        if (req.pid <= 0) return .{ .kind = .process_lost, .detail = "no process id" };
        var polls: u32 = 0;
        var wt = rt.waiter();
        var last_change = rt.env.now();
        var prev: ?u32 = null;
        while (true) {
            if (polls >= rt.limits.max_polls) return .{ .kind = .timeout, .detail = "poll limit reached" };
            polls += 1;
            rt.stats.polls += 1;
            if (rt.expired(op)) |f| return f;
            const t0 = rt.env.now();
            const r = rt.backend.observe(rt.ctx(op));
            rec(&rt.stats.observe, t0, rt.env.now(), r == .failed);
            const obs = switch (r) {
                .failed => |f| return f,
                .observed => |o| o,
            };
            const d = ui.decide(obs, op.policy);
            const cur: u32 = @as(u32, @intFromEnum(d.kind)) * 64 + @intFromEnum(d.modal);
            const changed = prev == null or prev.? != cur;
            prev = cur;
            switch (d.kind) {
                .ready => {
                    const t = d.title orelse "";
                    if (t.len > g.title_buf.len) return .{ .kind = .refused, .detail = "title too long" };
                    @memcpy(g.title_buf[0..t.len], t);
                    g.title_len = t.len;
                    g.ready = true;
                    return null;
                },
                .wait => {
                    rt.watchStall(op, &last_change, changed);
                    rt.waitStep(&wt, changed);
                },
                .unknown_ui => {
                    if (!req.wait_for_readable_windows or obs.windows_complete) return mapDecision(d);
                    for (obs.windows) |window| if (window.modal != false) return mapDecision(d);
                    rt.watchStall(op, &last_change, changed);
                    rt.waitStep(&wt, changed);
                },
                .proposed_action => {
                    const ack = d.action.acknowledge;
                    const already = switch (ack.class) {
                        .known_conversion => g.acknowledged_conversion,
                        .known_watermark => g.acknowledged_watermark,
                        else => true,
                    };
                    if (already) return .{ .kind = .unknown_ui, .detail = "known notice appeared again after acknowledgement" };
                    const w = obs.windows[ack.window_index];
                    const texts = w.texts orelse &[_][]const u8{};
                    if (rt.action(op, .ack, .{AckRequest{ .title = w.title, .texts = texts, .button = ack.button, .class = ack.class }})) |f| {
                        // The click may have run. Only an explicit refusal proves that it did not.
                        var uf = f;
                        if (uf.kind != .refused and uf.kind != .ambiguous_target and uf.kind != .unknown_ui) uf.uncertain = true;
                        return uf;
                    }
                    switch (ack.class) {
                        .known_conversion => g.acknowledged_conversion = true,
                        else => g.acknowledged_watermark = true,
                    }
                    rt.cache.invalidate();
                    last_change = rt.env.now();
                    rt.waitStep(&wt, true);
                },
                else => return mapDecision(d),
            }
        }
    }

    fn finishStats(rt: *Runtime, t_start: u64) Stats {
        var s = rt.stats;
        s.elapsed_ns = rt.env.now() -| t_start;
        return s;
    }

    // Export

    fn opDirOk(dir: []const u8, op_id: []const u8, lim: Limits) bool {
        if (dir.len < 2 or dir.len > lim.max_path or dir[0] != '/' or hasControl(dir)) return false;
        if (dir[dir.len - 1] == '/') return false;
        if (std.mem.indexOf(u8, dir, "/../") != null or std.mem.endsWith(u8, dir, "/..") or std.mem.indexOf(u8, dir, "/./") != null) return false;
        if (!validBasename(op_id)) return false;
        const base = dir[std.mem.lastIndexOfScalar(u8, dir, '/').? + 1 ..];
        return std.mem.eql(u8, base, op_id);
    }

    /// Records `dir` as used. Returns false when this runtime accepted the same path before.
    fn markUsed(rt: *Runtime, dir: []const u8) bool {
        if (rt.used.contains(dir)) return false;
        const key = std.heap.page_allocator.dupe(u8, dir) catch return false;
        rt.used.put(std.heap.page_allocator, key, {}) catch return false;
        return true;
    }

    fn joinPath(a: Allocator, dir: []const u8, name: []const u8) ?[]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch null;
    }

    /// Runs one export route serially. The result reports typed failures, the options that were
    /// set with their read back values, observed output files and timing statistics. The caller
    /// owns the report and frees it with `ExportReport.deinit`.
    pub fn runExport(rt: *Runtime, req: ExportRequest) ExportReport {
        const t_start = rt.env.now();
        var rep: ExportReport = .{ .phase = req.phase, .route_id = req.route.id };
        var b: Builder = .{};
        var op = rt.newOp(req.pid, req.policy);
        op.policy.allow_conversion_ack = false;
        op.policy.allow_watermark_ack = false;
        const fail = rt.runInner(req, &op, &b, &rep);
        if (fail) |f0| {
            var f = f0;
            // The capture is read-only and runs before the cancel press, so it shows the UI that
            // caused the failure.
            rt.diagnoseFailure(&op, f);
            // A confirmed export may have written files before the failure. The report keeps them
            // for reconciliation. The listing result does not replace the original failure.
            if (op.confirm_sent and !op.collected) {
                _ = if (rt.files.walkFn != null) rt.collectWalk(req, &b) else rt.collect(req, &b);
            }
            // A failure after the menu step left the export dialog open. Close it before any
            // later bridge call. A cancel that cannot run makes the failure uncertain.
            if (!f.uncertain and rt.limits.cancel_after_failure and op.menu_open) {
                if (req.route.cancel) |c| {
                    var cop = rt.newOp(req.pid, req.policy);
                    _ = cop.setTitle(op.title());
                    if (rt.cancelSheet(&cop, c)) |cf| {
                        f = cf;
                        f.uncertain = true;
                    }
                }
            }
            rep.failure = withDiag(makeFailure(f, op.step), &op);
            if (f.uncertain) rt.reconcile = .{ .cause = f.kind, .step = op.step };
        }
        rep.options = b.options.toOwnedSlice(rt.a) catch blk: {
            if (rep.failure == null) rep.failure = makeFailure(allocFail(), op.step);
            break :blk &.{};
        };
        rep.files = b.files.toOwnedSlice(rt.a) catch blk: {
            if (rep.failure == null) rep.failure = makeFailure(allocFail(), op.step);
            break :blk &.{};
        };
        rep.controls = b.controls.toOwnedSlice(rt.a) catch blk: {
            if (rep.failure == null) rep.failure = makeFailure(allocFail(), op.step);
            break :blk &.{};
        };
        b.deinit(rt.a);
        rep.diag = op.diag;
        rep.verified = req.phase == .verified and rep.failure == null;
        rep.stats = rt.finishStats(t_start);
        return rep;
    }

    fn runInner(rt: *Runtime, req: ExportRequest, op: *Op, b: *Builder, rep: *ExportReport) ?Failure {
        op.bundle_dir = req.op_dir;
        if (rt.reconcile != null) return .{ .kind = .uncertain_mutation, .detail = "reconciliation is pending" };
        if (checkPhase(req.phase, req.route, req.run_binding, req.scratch, rt.limits)) |f| return f;
        validateOutputs(req.route.format, req.outputs, rt.limits) catch return .{ .kind = .invalid_route, .detail = "expected output names do not fit the route format" };
        req.policy.expected.validate() catch return .{ .kind = .refused, .detail = "expected document name is invalid" };
        if (req.pid <= 0) return .{ .kind = .process_lost, .detail = "no process id" };
        if (!opDirOk(req.op_dir, req.op_id, rt.limits)) return .{ .kind = .output_collision, .detail = "operation directory path is invalid" };
        for (req.outputs.required_sidecars) |s| {
            if (std.mem.indexOfScalar(u8, s, '/') != null and rt.files.walkFn == null) {
                return .{ .kind = .invalid_route, .detail = "nested sidecars need a file backend with recursive enumeration" };
            }
        }
        if (req.screenshot_name) |n| {
            if (req.phase != .inventory) return .{ .kind = .refused, .detail = "screenshots belong to the inventory phase" };
            if (!validBasename(n) or !std.ascii.endsWithIgnoreCase(n, ".png")) return .{ .kind = .invalid_route, .detail = "screenshot name is invalid" };
        }
        if (!rt.markUsed(req.op_dir)) return .{ .kind = .output_collision, .detail = "operation directory was used before" };
        const listing = rt.files.list(rt.a, req.op_dir, rt.limits.max_listing) orelse return .{ .kind = .missing_output, .detail = "operation directory is unreadable" };
        const dirty = listing.len != 0;
        freeList(rt.a, listing);
        if (dirty) return .{ .kind = .output_collision, .detail = "operation directory is not empty" };

        // Preflight identity.
        op.expect_note = "the expected document window";
        switch (rt.observeOnce(op)) {
            .failed => |f| return f,
            .decision => |d| {
                if (d.kind != .ready) return mapDecision(d);
                if (!op.setTitle(d.title orelse "")) return .{ .kind = .refused, .detail = "title too long" };
            },
        }

        var appear = false;
        var confirmed = false;
        for (req.route.steps, 0..) |st, i| {
            op.step = i;
            switch (st) {
                .menu => |path| {
                    if (rt.action(op, .menu, .{path})) |f| return f;
                    op.menu_open = true;
                    rt.cache.invalidate();
                    appear = true;
                    if (req.phase == .inventory) return rt.inventory(req, op, b, rep);
                },
                .option => |o| {
                    if (rt.setOption(op, b, o.selector, o.value, appear)) |f| return f;
                    appear = false;
                },
                .destination => |d| {
                    const name = if (d.name_mode == .stem) stemOf(req.outputs.primary) else req.outputs.primary;
                    if (d.save_panel) |sp| {
                        // The directory comes first because navigation can reset the name field. The
                        // popup is read again after the name is set, so Save is never reachable with
                        // an unverified directory.
                        if (rt.navigateSaveDir(op, b, sp, req.op_dir, appear)) |f| return f;
                        appear = false;
                        if (rt.setOption(op, b, d.name_field, .{ .text = name }, false)) |f| return f;
                        if (rt.verifySaveDir(op, b, sp, req.op_dir, false)) |f| return f;
                    } else {
                        if (rt.setOption(op, b, d.name_field, .{ .text = name }, appear)) |f| return f;
                        appear = false;
                        if (d.dir_field) |df| {
                            if (rt.setOption(op, b, df, .{ .text = req.op_dir }, false)) |f| return f;
                        }
                    }
                },
                .confirm => |c| {
                    switch (rt.resolve(op, c, appear)) {
                        .failed => |f| return f,
                        .ok => {},
                    }
                    // The progress value just before the press is the stale baseline. Only a change from
                    // it, or an indicator that was absent, belongs to this export.
                    if (hasSignal(req.route)) {
                        const tb = rt.env.now();
                        const pb = rt.backend.progress(rt.ctx(op));
                        rec(&rt.stats.progress, tb, rt.env.now(), pb == .failed);
                        switch (pb) {
                            .failed => |f| return f,
                            .none => op.progress_baseline = null,
                            .fraction => |p| op.progress_baseline = if (std.mem.eql(u8, p.id, req.route.progress_id)) p.done else null,
                        }
                    }
                    op.confirm_sent = true;
                    var f2 = rt.action(op, .press, .{c});
                    if (f2) |*f| {
                        // The press was sent. Only an explicit refusal proves it did not run.
                        if (f.kind != .refused and f.kind != .ambiguous_target and f.kind != .unknown_ui) f.uncertain = true;
                        return f.*;
                    }
                    rt.cache.invalidate();
                    confirmed = true;
                },
            }
        }
        op.step = null;
        if (!confirmed) return .{ .kind = .invalid_route, .detail = "route has no confirm step" };
        if (rt.awaitCompletion(req, op, rep)) |f| return f;
        op.collected = true;
        return if (rt.files.walkFn != null) rt.collectWalk(req, b) else rt.collect(req, b);
    }

    /// The folder name that a Where popup shows for the directory.
    fn dirBase(dir: []const u8) []const u8 {
        const t = std.mem.trimEnd(u8, dir, "/");
        return t[(std.mem.lastIndexOfScalar(u8, t, '/') orelse return t) + 1 ..];
    }

    /// Reads the Where popup. With `wait` the call retries while the popup shows another folder, up
    /// to `dialog_wait_ms`, because the popup follows the panel a moment after the sheet closes. A
    /// mismatch at the end is a failure and nothing was saved. The panel keeps showing only the last
    /// path component, so this is the strongest read back that the panel offers.
    fn verifySaveDir(rt: *Runtime, op: *Op, b: *Builder, sp: SavePanelDir, dir: []const u8, wait: bool) ?Failure {
        const want = dirBase(dir);
        if (want.len == 0) return .{ .kind = .invalid_route, .detail = "operation directory has no name" };
        const give_up = rt.env.now() + @as(u64, rt.limits.dialog_wait_ms) * std.time.ns_per_ms;
        var w = rt.waiter();
        op.expect_note = "the Where popup to show the operation directory";
        while (true) {
            if (rt.expired(op)) |f| return f;
            const t0 = rt.env.now();
            const r = rt.backend.lookup(rt.ctx(op), sp.where);
            rec(&rt.stats.lookup, t0, rt.env.now(), r == .failed);
            switch (r) {
                .failed => |f| return f,
                .found => |c| {
                    if (c.count > 1) return op.selectorFailed(sp.where, .{ .kind = .ambiguous_target, .detail = "more than one control matches the selector" }).failed;
                    const got = if (c.count == 1) (c.value orelse "") else "";
                    if (c.count == 1 and std.mem.eql(u8, got, want)) {
                        if (wait) if (rt.pushOption(b, "Where (directory)", want, got)) |f| return f;
                        return null;
                    }
                    if (wait and rt.env.now() < give_up) {
                        rt.waitStep(&w, false);
                        continue;
                    }
                    if (rt.pushOption(b, "Where (directory)", want, got)) |f| return f;
                    return .{ .kind = .incomplete_options, .detail = "the Where popup does not show the operation directory" };
                },
            }
        }
    }

    /// Points a standard save panel at the operation directory. Each step waits for its own feedback:
    /// the Go to Folder sheet to appear, its field to read back the path, the sheet to close, and the
    /// Where popup to show the folder. The confirm press stays unreachable until all of that holds.
    fn navigateSaveDir(rt: *Runtime, op: *Op, b: *Builder, sp: SavePanelDir, dir: []const u8, appear: bool) ?Failure {
        const win = switch (sp.where.container) {
            .window => |t| t,
            else => return .{ .kind = .invalid_route, .detail = "save panel selectors need a window container" },
        };
        switch (rt.resolve(op, sp.where, appear)) {
            .failed => |f| return f,
            .ok => {},
        }
        const slash = sp.initiator == .slash;
        // The slash goes to the key window's first responder. It is posted only after the exact Save As
        // field was found enabled and was read as the focused control. No focus is set here.
        if (slash) if (rt.requireSaveAsFocus(op, sp)) |f| return f;
        if (rt.action(op, .chord, .{ win, if (slash) Chord.slash else Chord.go_to_folder })) |f| {
            var cf = f;
            // The event was posted unless the backend refused it first.
            if (cf.kind != .refused and cf.kind != .ambiguous_target and cf.kind != .unknown_ui and cf.kind != .process_lost) cf.uncertain = true;
            return cf;
        }
        rt.cache.invalidate();
        // From here the key is dispatched. For the slash initiator every failure keeps the uncertainty,
        // because the key may have changed the Save As field or the panel.
        switch (rt.resolve(op, sp.sheet_field, true)) {
            .failed => |f| {
                if (!slash) return f;
                var uf = f;
                uf.uncertain = true;
                if (isAbsentContainer(f) or (f.kind == .unknown_ui and std.mem.eql(u8, f.detail, "control not found"))) {
                    uf.detail = "no Go to Folder sheet appeared after the slash key. The key may have been typed into the Save As field";
                }
                return uf;
            },
            .ok => {},
        }
        if (rt.finishNavigate(op, b, sp, dir)) |f| {
            if (!slash) return f;
            var uf = f;
            uf.uncertain = true;
            return uf;
        }
        return null;
    }

    /// Reads the focus state of the exact Save As field right before a slash is posted. The field must
    /// resolve as one enabled control and read as focused. Anything else refuses before any event.
    fn requireSaveAsFocus(rt: *Runtime, op: *Op, sp: SavePanelDir) ?Failure {
        const ff = sp.focus_field orelse return .{ .kind = .invalid_route, .detail = "the slash initiator needs the Save As focus field" };
        switch (rt.resolve(op, ff, false)) {
            .failed => |f| return f,
            .ok => {},
        }
        if (rt.expired(op)) |f| return f;
        const t0 = rt.env.now();
        const r = rt.backend.focused(rt.ctx(op), ff);
        rec(&rt.stats.lookup, t0, rt.env.now(), r == .failed);
        switch (r) {
            .failed => |f| return f,
            .focused => |on| if (!on) return op.selectorFailed(ff, .{ .kind = .refused, .detail = "the Save As field does not hold the keyboard focus. No key was posted" }).failed,
        }
        return null;
    }

    /// The steps after the sheet was found: path, Go, sheet closed, Where read back.
    fn finishNavigate(rt: *Runtime, op: *Op, b: *Builder, sp: SavePanelDir, dir: []const u8) ?Failure {
        if (rt.setOption(op, b, sp.sheet_field, .{ .text = dir }, false)) |f| return f;
        switch (rt.resolve(op, sp.go, false)) {
            .failed => |f| return f,
            .ok => {},
        }
        if (rt.action(op, .press, .{sp.go})) |f| {
            var pf = f;
            if (pf.kind != .refused and pf.kind != .ambiguous_target and pf.kind != .unknown_ui) pf.uncertain = true;
            return pf;
        }
        rt.cache.invalidate();
        // The sheet closes when the panel accepts the path. A sheet that stays open is a rejected path.
        const give_up = rt.env.now() + @as(u64, rt.limits.dialog_wait_ms) * std.time.ns_per_ms;
        var w = rt.waiter();
        op.expect_note = "the Go to Folder sheet to close";
        while (true) {
            if (rt.expired(op)) |f| return f;
            const t0 = rt.env.now();
            const id = rt.backend.identity(rt.ctx(op), sp.sheet_field.container);
            rec(&rt.stats.identity, t0, rt.env.now(), id == .failed);
            switch (id) {
                .failed => |f| return f,
                .absent => break,
                .present => {
                    if (rt.env.now() >= give_up) return .{ .kind = .unknown_ui, .detail = "the Go to Folder sheet did not close" };
                    rt.waitStep(&w, false);
                },
            }
        }
        return rt.verifySaveDir(op, b, sp, dir, true);
    }

    fn stemOf(name: []const u8) []const u8 {
        return name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
    }

    /// The observed state of the expected outputs. `primary` is the size of the primary file.
    /// `sidecars` counts required sidecars that exist with a non-zero size.
    const OutputSig = struct {
        primary: ?u64,
        sidecars: usize,
        sum: u64,

        fn eql(a: OutputSig, b: OutputSig) bool {
            return a.primary == b.primary and a.sidecars == b.sidecars and a.sum == b.sum;
        }

        /// The necessary artifact set is visible: a non-empty primary file and every required sidecar.
        fn complete(s: OutputSig, req: ExportRequest) bool {
            return s.primary != null and s.primary.? > 0 and s.sidecars == req.outputs.required_sidecars.len;
        }
    };

    fn outputSig(rt: *Runtime, req: ExportRequest, primary: []const u8) ?OutputSig {
        var s: OutputSig = .{ .primary = rt.files.size(primary), .sidecars = 0, .sum = 0 };
        for (req.outputs.required_sidecars) |name| {
            const p = joinPath(rt.a, req.op_dir, name) orelse return null;
            defer rt.a.free(p);
            const n = rt.files.size(p) orelse continue;
            if (n > 0) {
                s.sidecars += 1;
                s.sum += n;
            }
        }
        return s;
    }

    /// True when the route names a progress indicator and its identity. Only such a route has a
    /// verified completion signal.
    fn hasSignal(r: Route) bool {
        return r.progress and r.progress_id.len > 0;
    }

    /// Follows the progress indicator of one export. The indicator counts as this operation's only
    /// when it is correlated with the confirm press: it was absent before the press and appeared, or
    /// it changed from the value that the runtime read just before the press. A value equal to that
    /// stale baseline is no evidence, whatever it says. Completion is a correlated indicator at its
    /// total, or a correlated indicator that went away.
    const ProgressTrack = struct {
        baseline: ?u32,
        /// The identity that the route requires. Readings with another one are ignored.
        expected_id: []const u8,
        unmatched: u32 = 0,
        correlated: bool = false,
        done: bool = false,
        last: ?u32 = null,
        observations: u32 = 0,

        /// Returns a failure when the indicator leaves its range or goes backwards after correlation.
        fn feed(t: *ProgressTrack, pr: ProgressReply, progressed: *bool) ?Failure {
            switch (pr) {
                .failed => |f| return f,
                .none => {
                    if (t.last != null and t.correlated) t.done = true;
                },
                .fraction => |p| {
                    // A reading of another indicator, or one that names none, is no evidence.
                    if (t.expected_id.len == 0 or !std.mem.eql(u8, p.id, t.expected_id)) {
                        t.unmatched += 1;
                        return null;
                    }
                    if (p.total == 0 or p.done > p.total) return .{ .kind = .unknown_ui, .detail = "progress is out of range", .uncertain = true };
                    t.observations += 1;
                    if (!t.correlated) {
                        if (t.baseline == null or p.done != t.baseline.?) t.correlated = true;
                    } else if (t.last != null and p.done < t.last.?) {
                        return .{ .kind = .unknown_ui, .detail = "progress went backwards", .uncertain = true };
                    }
                    progressed.* = t.last == null or p.done != t.last.?;
                    t.last = p.done;
                    if (t.correlated and p.done == p.total) t.done = true;
                },
            }
            return null;
        }

        fn established(t: ProgressTrack) bool {
            return t.correlated and t.done;
        }
    };

    /// The failure of an observation that a hard budget or a failed call ended. It is uncertain,
    /// because the confirmed export may still be running. With established completion evidence a
    /// deadline means that the producer has not published every output yet. It is no missing-file
    /// verdict.
    fn endedObservation(rep: *const ExportReport, f: Failure) Failure {
        var uf = f;
        uf.uncertain = true;
        if (rep.completion.established and (f.kind == .timeout or f.kind == .deadline_exceeded)) {
            uf.kind = .output_unpublished;
            uf.detail = "completion was established and the outputs were not complete when the hard budget ended";
        }
        return uf;
    }

    /// Waits for the completion of one confirmed export and for its outputs.
    ///
    /// Completion needs evidence from the application that belongs to this operation. The route
    /// declares an operation-specific progress indicator (`Route.progress`). The evidence is a
    /// correlated transition of that indicator (`ProgressTrack`) together with a closed export
    /// dialog. A confirm press, a closed dialog alone, an unchanged stale value or a file that stopped
    /// changing is not evidence. A route without a declared indicator has no verified completion
    /// signal. The call then stops as soon as the dialog closed, with `completion_unavailable`
    /// (uncertain), the raw files in the report and no success. No elapsed interval replaces the
    /// signal.
    ///
    /// After the evidence, the call keeps observing until the primary file and every required sidecar
    /// are visible and non-empty. An output that is not there yet is a publication that is still
    /// outstanding. Nothing in this call turns elapsed time into a missing-file verdict. The operation
    /// deadline is the only bound. It ends the call with `output_unpublished` (uncertain) after the
    /// evidence and with `timeout` (uncertain) before it. The files stay in the report.
    ///
    /// Waits start short, grow while nothing changes and restart at a change (`Backoff`). They decide
    /// when to look. They decide neither success nor absence. A size change, a new file, a progress
    /// change or a dialog change counts as activity. No activity for `stall_ms` raises one diagnostic
    /// capture and the observation goes on.
    fn awaitCompletion(rt: *Runtime, req: ExportRequest, op: *Op, rep: *ExportReport) ?Failure {
        const primary = joinPath(rt.a, req.op_dir, req.outputs.primary) orelse return allocFail();
        defer rt.a.free(primary);
        op.expect_note = "the export completion signal";
        var track: ProgressTrack = .{ .baseline = op.progress_baseline, .expected_id = req.route.progress_id };
        const has_signal = hasSignal(req.route);
        var last_sig: ?OutputSig = null;
        var prev_dialog: ?bool = null;
        var polls: u32 = 0;
        var w = rt.waiter();
        var last_change = rt.env.now();
        const confirm_container = lastConfirm(req.route).container;
        rep.completion = .{ .via = if (has_signal) .progress_transition else .none, .baseline = op.progress_baseline, .progress_id = req.route.progress_id };
        while (true) {
            if (polls >= rt.limits.max_polls) return .{ .kind = .timeout, .detail = "poll limit reached after confirm", .uncertain = true };
            polls += 1;
            rt.stats.polls += 1;
            var progressed = false;
            switch (rt.observeOnce(op)) {
                .failed => |f| return endedObservation(rep, f),
                .decision => |d| switch (d.kind) {
                    .ready, .wait => {},
                    else => {
                        var uf = mapDecision(d);
                        uf.uncertain = true;
                        return uf;
                    },
                },
            }
            if (has_signal) {
                const t0 = rt.env.now();
                const pr = rt.backend.progress(rt.ctx(op));
                rec(&rt.stats.progress, t0, rt.env.now(), pr == .failed);
                if (track.feed(pr, &progressed)) |f| {
                    var uf = f;
                    uf.uncertain = true;
                    return uf;
                }
                rep.completion.observations = track.observations;
                rep.completion.unmatched = track.unmatched;
                rep.completion.last = track.last;
            }
            const t1 = rt.env.now();
            const id = rt.backend.identity(rt.ctx(op), confirm_container);
            rec(&rt.stats.identity, t1, rt.env.now(), id == .failed);
            const dialog_open = switch (id) {
                .present => true,
                .absent => false,
                .failed => |f| {
                    var uf = f;
                    uf.uncertain = true;
                    return uf;
                },
            };
            const sig = rt.outputSig(req, primary) orelse return allocFail();
            const same = last_sig != null and last_sig.?.eql(sig);
            if (!has_signal and !dialog_open) {
                return .{ .kind = .completion_unavailable, .detail = if (req.route.progress) "the route declares a progress indicator without an identity. Its readings cannot be tied to this export. The outputs are raw and unconfirmed" else "the route declares no completion signal. The outputs are raw and unconfirmed", .uncertain = true };
            }
            const evidence = has_signal and track.established() and !dialog_open;
            rep.completion.established = evidence;
            if (evidence) {
                op.expect_note = "the outputs after the completion signal";
                if (sig.complete(req)) return null;
                // An unsafe entry is a fact. It does not wait for the outputs.
                if (rt.files.walkFn != null) if (rt.unsafeNow(req)) |f| return f;
            }
            const changed = progressed or prev_dialog == null or prev_dialog.? != dialog_open or !same;
            prev_dialog = dialog_open;
            last_sig = sig;
            if (rt.expired(op)) |f| return endedObservation(rep, f);
            rt.watchStall(op, &last_change, changed);
            rt.waitStep(&w, changed);
        }
    }

    fn lastConfirm(r: Route) Selector {
        var i = r.steps.len;
        while (i > 0) {
            i -= 1;
            switch (r.steps[i]) {
                .confirm => |c| return c,
                else => {},
            }
        }
        unreachable; // validateRoute guarantees a confirm step
    }

    fn addFile(rt: *Runtime, b: *Builder, dir: []const u8, name: []const u8, role: FileRole) ?Failure {
        const path = joinPath(rt.a, dir, name) orelse return allocFail();
        defer rt.a.free(path);
        const size = rt.files.size(path) orelse 0;
        const copy = rt.a.dupe(u8, name) catch return allocFail();
        b.files.append(rt.a, .{ .name = copy, .size = size, .role = role }) catch {
            rt.a.free(copy);
            return allocFail();
        };
        return null;
    }

    /// Lists the operation directory and classifies each entry against the expected outputs.
    fn collect(rt: *Runtime, req: ExportRequest, b: *Builder) ?Failure {
        const names = rt.files.list(rt.a, req.op_dir, rt.limits.max_listing) orelse return .{ .kind = .missing_output, .detail = "operation directory is unreadable" };
        defer freeList(rt.a, names);
        var primary_seen = false;
        var unexpected: usize = 0;
        var sidecars_seen: usize = 0;
        for (names) |n| {
            var role: FileRole = .unexpected;
            if (std.mem.eql(u8, n, req.outputs.primary)) {
                role = .primary;
                primary_seen = true;
            } else if (inList2(req.outputs.required_sidecars, n)) {
                role = .expected_sidecar;
                sidecars_seen += 1;
            } else if (inList(req.outputs.allowed_sidecar_exts, extOf(n))) {
                role = .allowed_sidecar;
            } else unexpected += 1;
            if (rt.addFile(b, req.op_dir, n, role)) |f| return f;
        }
        if (!primary_seen) return .{ .kind = .missing_output, .detail = "primary output file is absent" };
        if (sidecars_seen != req.outputs.required_sidecars.len) return .{ .kind = .missing_output, .detail = "a required sidecar file is absent" };
        for (b.files.items) |f| if (f.size == 0 and f.role != .unexpected) return .{ .kind = .missing_output, .detail = "an expected output file is empty" };
        if (unexpected != 0 and req.phase == .verified) return .{ .kind = .unexpected_output, .detail = "the operation directory holds a file that the route does not expect" };
        return null;
    }

    fn inList2(list: []const []const u8, name: []const u8) bool {
        for (list) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    fn lessPath(_: void, a: WalkEntry, b: WalkEntry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }

    fn unsafeOutput(detail: []const u8) Failure {
        return .{ .kind = .unexpected_output, .detail = detail };
    }

    /// Recursive variant of `collect`. It keeps exporter-relative names. It refuses symbolic links,
    /// special files, hard-linked files, unsafe paths and case aliases in every phase. Directory
    /// entries are traversed and not recorded. The records list files and roles. They are not a
    /// semantic dependency closure.
    /// Lists the tree and applies `walkSafety`. A tree that cannot be read or is bounded by the walk
    /// limit gives no verdict here. The final collection reports it.
    fn unsafeNow(rt: *Runtime, req: ExportRequest) ?Failure {
        var info: WalkInfo = .{};
        const entries = rt.files.walkInfo(rt.a, req.op_dir, .{ .max_entries = rt.limits.max_walk_entries, .max_depth = max_sidecar_depth }, &info) orelse return null;
        defer freeWalk(rt.a, entries);
        return rt.walkSafety(req, entries);
    }

    /// The safety checks of a listed tree. They hold for every entry at any time, so a violation is a
    /// fact and not a publication that is still outstanding. A symbolic link, a special file, a
    /// hard-linked file, an unsafe path and a case alias fail here.
    fn walkSafety(rt: *Runtime, req: ExportRequest, entries: []WalkEntry) ?Failure {
        std.mem.sort(WalkEntry, entries, {}, lessPath);
        for (entries, 0..) |e, i| {
            if (!validRelPath(e.path, rt.limits)) return unsafeOutput("an entry path is unsafe");
            switch (e.kind) {
                .symlink => return unsafeOutput("the output tree holds a symbolic link"),
                .other => return unsafeOutput("the output tree holds a special file"),
                .directory => {},
                .file => if (e.nlink > 1) return unsafeOutput("the output tree holds a hard-linked file"),
            }
            for (entries[0..i]) |p| {
                if (eqlIgnoreCase(p.path, e.path)) return unsafeOutput("two entries differ only by case");
                if (p.kind == .file and isDirPrefix(p.path, e.path)) return unsafeOutput("a file is also used as a directory");
            }
            if (e.kind == .file) {
                if (!std.mem.eql(u8, e.path, req.outputs.primary) and eqlIgnoreCase(e.path, req.outputs.primary)) return unsafeOutput("an entry is a case alias of the primary name");
                for (req.outputs.required_sidecars) |s| {
                    if (!std.mem.eql(u8, e.path, s) and eqlIgnoreCase(e.path, s)) return unsafeOutput("an entry is a case alias of an expected sidecar");
                }
            }
        }
        return null;
    }

    fn collectWalk(rt: *Runtime, req: ExportRequest, b: *Builder) ?Failure {
        var info: WalkInfo = .{};
        const entries = rt.files.walkInfo(rt.a, req.op_dir, .{ .max_entries = rt.limits.max_walk_entries, .max_depth = max_sidecar_depth }, &info) orelse
            return switch (info.status) {
                .unreadable => .{ .kind = .missing_output, .detail = "operation directory is unreadable" },
                else => .{ .kind = .missing_output, .detail = "operation directory is unreadable or exceeds the walk limits" },
            };
        defer freeWalk(rt.a, entries);
        if (info.status == .capped or info.status == .too_deep) {
            // A bounded listing stays in the report. The limit is a limit of this check, and the
            // directory is neither unreadable nor shown to miss an export.
            for (entries) |e| {
                if (e.kind != .file) continue;
                const role: FileRole = if (std.mem.eql(u8, e.path, req.outputs.primary)) .primary else if (inList2(req.outputs.required_sidecars, e.path)) .expected_sidecar else if (inList(req.outputs.allowed_sidecar_exts, extOf(e.path))) .allowed_sidecar else .unexpected;
                const copy = rt.a.dupe(u8, e.path) catch return allocFail();
                b.files.append(rt.a, .{ .name = copy, .size = e.size, .role = role }) catch {
                    rt.a.free(copy);
                    return allocFail();
                };
            }
            return .{
                .kind = .output_capacity,
                .detail = if (info.status == .capped) "the output tree has more entries than the walk limit. The report holds the first entries" else "the output tree is deeper than the walk limit. The report holds the entries above it",
            };
        }
        if (rt.walkSafety(req, entries)) |f| return f;
        var primary_seen = false;
        var unexpected: usize = 0;
        var sidecars_seen: usize = 0;
        for (entries) |e| {
            if (e.kind != .file) continue;
            var role: FileRole = .unexpected;
            if (std.mem.eql(u8, e.path, req.outputs.primary)) {
                role = .primary;
                primary_seen = true;
            } else if (inList2(req.outputs.required_sidecars, e.path)) {
                role = .expected_sidecar;
                sidecars_seen += 1;
            } else if (inList(req.outputs.allowed_sidecar_exts, extOf(e.path))) {
                role = .allowed_sidecar;
            } else unexpected += 1;
            const copy = rt.a.dupe(u8, e.path) catch return allocFail();
            b.files.append(rt.a, .{ .name = copy, .size = e.size, .role = role }) catch {
                rt.a.free(copy);
                return allocFail();
            };
        }
        if (!primary_seen) return .{ .kind = .missing_output, .detail = "primary output file is absent" };
        if (sidecars_seen != req.outputs.required_sidecars.len) return .{ .kind = .missing_output, .detail = "a required sidecar file is absent" };
        for (b.files.items) |f| if (f.size == 0 and f.role != .unexpected) return .{ .kind = .missing_output, .detail = "an expected output file is empty" };
        if (unexpected != 0 and req.phase == .verified) return .{ .kind = .unexpected_output, .detail = "the operation directory holds a file that the route does not expect" };
        return null;
    }

    /// Inventory phase. Looks up every selector of the route, records the findings, optionally
    /// takes a window screenshot and closes the dialog with the route's cancel button. It sets and
    /// presses nothing else.
    fn inventory(rt: *Runtime, req: ExportRequest, op: *Op, b: *Builder, rep: *ExportReport) ?Failure {
        var first = true;
        for (req.route.steps) |st| {
            const sels: [2]?Selector = switch (st) {
                .menu => .{ null, null },
                .option => |o| .{ o.selector, null },
                .destination => |d| .{ d.name_field, d.dir_field orelse if (d.save_panel) |sp| sp.where else null },
                .confirm => |c| .{ c, null },
            };
            for (sels) |maybe| {
                const sel = maybe orelse continue;
                if (rt.lookupRecord(op, b, sel, first)) |f| return f;
                first = false;
            }
        }
        if (req.screenshot_name) |name| {
            const path = joinPath(rt.a, req.op_dir, name) orelse return allocFail();
            defer rt.a.free(path);
            if (rt.expired(op)) |f| return f;
            const c = rt.ctx(op);
            const t0 = rt.env.now();
            const r = rt.backend.screenshot(c, path);
            rec(&rt.stats.screenshot, t0, rt.env.now(), r == .failed);
            switch (r) {
                .failed => |f| return f,
                .done => {},
            }
            const size = rt.files.size(path) orelse 0;
            if (size == 0) return .{ .kind = .missing_output, .detail = "screenshot file is absent or empty" };
            const copy = rt.a.dupe(u8, name) catch return allocFail();
            rep.screenshot = .{ .name = copy, .size = size, .role = .primary };
        }
        if (req.route.cancel) |c| {
            switch (rt.resolve(op, c, false)) {
                .failed => |f| return f,
                .ok => {},
            }
            if (rt.action(op, .press, .{c})) |f| {
                var uf = f;
                if (uf.kind != .refused and uf.kind != .ambiguous_target and uf.kind != .unknown_ui) uf.uncertain = true;
                return uf;
            }
            rt.cache.invalidate();
        }
        return null;
    }

    /// Presses `sel` to close an export dialog after a failed export. Returns null when it ran.
    fn cancelSheet(rt: *Runtime, op: *Op, sel: Selector) ?Failure {
        switch (rt.resolve(op, sel, false)) {
            .failed => |f| return f,
            .ok => {},
        }
        if (rt.action(op, .press, .{sel})) |f| return f;
        rt.cache.invalidate();
        return null;
    }

    // Close

    /// Request of `closeDocument`. The policy names the document that must be open.
    pub const NoticeRequest = struct {
        pid: i32,
        /// The expected document. Exactly one non-modal window of it must be present, with no other
        /// document window and no other modal.
        policy: ui.Policy,
        /// Exact text of the first static text of the notice. Any later static text must be empty.
        message: []const u8,
        /// Exact name of the default button. Only the approved OK button is pressed.
        button: []const u8 = ui.allowed_default_button,
        /// Consecutive observations with the notice gone and the document ready.
        stable_observations: u32 = 2,
    };

    pub const NoticeReport = struct {
        failure: ?FailureReport = null,
        /// The button was pressed and the notice went away with the document window ready.
        acknowledged: bool = false,
        /// No modal window was on screen. Nothing was pressed and the call is not a failure.
        absent: bool = false,
        stats: Stats = .{},
    };

    /// Presses OK once on one exact negative-result notice of the expected document. Unlike the
    /// conversion and watermark notices this class has no calibrated title, so the match is the exact
    /// message, an empty title, the default button and a ready document beside it. Any other modal,
    /// a second modal, another document window or an incomplete observation refuses without a press.
    /// A press that is followed by a different dialog or by no change before the deadline is uncertain.
    pub fn acknowledgeNotice(rt: *Runtime, req: NoticeRequest) NoticeReport {
        const t_start = rt.env.now();
        var rep: NoticeReport = .{};
        var op = rt.newOp(req.pid, req.policy);
        op.policy.allow_conversion_ack = false;
        op.policy.allow_watermark_ack = false;
        op.expect_note = "the exact notice";
        if (rt.noticeInner(req, &op, &rep)) |f| {
            rt.diagnoseFailure(&op, f);
            rep.failure = withDiag(makeFailure(f, null), &op);
            if (f.uncertain) rt.reconcile = .{ .cause = f.kind, .step = null };
        }
        rep.stats = rt.finishStats(t_start);
        return rep;
    }

    fn noticeInner(rt: *Runtime, req: NoticeRequest, op: *Op, rep: *NoticeReport) ?Failure {
        if (rt.reconcile != null) return .{ .kind = .uncertain_mutation, .detail = "reconciliation is pending" };
        req.policy.expected.validate() catch return .{ .kind = .refused, .detail = "expected document name is invalid" };
        if (req.pid <= 0) return .{ .kind = .process_lost, .detail = "no process id" };
        if (req.message.len == 0 or !std.mem.eql(u8, req.button, ui.allowed_default_button)) return .{ .kind = .refused, .detail = "the notice or its button is not approved" };
        const obs = switch (rt.observeBounded(op)) {
            .failed => |f| return f,
            .observed => |o| o,
        };
        var modal_at: ?usize = null;
        for (obs.windows, 0..) |w, i| {
            const m = w.modal orelse return .{ .kind = .unknown_ui, .detail = "window modal state unread" };
            if (!m) continue;
            if (modal_at != null) return .{ .kind = .unknown_ui, .detail = "more than one modal window" };
            modal_at = i;
        }
        const at = modal_at orelse {
            rep.absent = true;
            return null;
        };
        const w = obs.windows[at];
        const texts = w.texts orelse return .{ .kind = .unknown_ui, .detail = "dialog text unread" };
        if (w.title == null or w.title.?.len != 0) return .{ .kind = .unknown_ui, .detail = "the notice has a title" };
        if (texts.len == 0 or !std.mem.eql(u8, texts[0], req.message)) return .{ .kind = .unknown_ui, .detail = "dialog text differs from the approved notice" };
        for (texts[1..]) |t| if (t.len != 0) return .{ .kind = .unknown_ui, .detail = "dialog holds more text than the approved notice" };
        const db = w.default_button orelse return .{ .kind = .unknown_ui, .detail = "default button is not OK" };
        if (!std.mem.eql(u8, db, req.button)) return .{ .kind = .unknown_ui, .detail = "default button is not OK" };
        // Everything except the notice must be a ready document: console, completeness, exactly one
        // window of the expected document, no other document and no other dialog.
        var rest: [32]ui.WindowObservation = undefined;
        if (obs.windows.len > rest.len) return .{ .kind = .unknown_ui, .detail = "too many windows" };
        var k: usize = 0;
        for (obs.windows, 0..) |x, i| {
            if (i == at) continue;
            rest[k] = x;
            k += 1;
        }
        var filtered = obs;
        filtered.windows = rest[0..k];
        const d = ui.decide(filtered, op.policy);
        if (d.kind != .ready) return mapDecision(d);
        if (!op.setTitle(d.title orelse "")) return .{ .kind = .refused, .detail = "title too long" };
        if (rt.action(op, .ack, .{AckRequest{ .title = w.title, .texts = texts, .button = req.button, .class = .unknown, .exact_notice = true }})) |f| {
            // The click may have run. Only an explicit refusal proves that it did not.
            var uf = f;
            if (uf.kind != .refused and uf.kind != .ambiguous_target and uf.kind != .unknown_ui) uf.uncertain = true;
            return uf;
        }
        rt.cache.invalidate();
        // The application's own answer: the notice is gone and the document is ready, twice in a row.
        var stable: u32 = 0;
        var polls: u32 = 0;
        var wt = rt.waiter();
        var last_change = rt.env.now();
        var prev: ?u32 = null;
        while (true) {
            if (polls >= rt.limits.max_polls) return .{ .kind = .timeout, .detail = "poll limit reached after the notice press", .uncertain = true };
            polls += 1;
            rt.stats.polls += 1;
            const dd = switch (rt.observeOnce(op)) {
                .failed => |f| {
                    var uf = f;
                    uf.uncertain = true;
                    return uf;
                },
                .decision => |x| x,
            };
            switch (dd.kind) {
                .ready => {
                    stable += 1;
                    if (stable >= req.stable_observations) {
                        rep.acknowledged = true;
                        return null;
                    }
                },
                .wait => {
                    if (dd.modal != .none) {
                        var uf = mapDecision(dd);
                        uf.uncertain = true;
                        return uf;
                    }
                    stable = 0;
                },
                else => {
                    var uf = mapDecision(dd);
                    uf.uncertain = true;
                    return uf;
                },
            }
            if (rt.expired(op)) |f| {
                var uf = f;
                uf.uncertain = true;
                return uf;
            }
            const cur: u32 = @intFromEnum(dd.kind);
            const changed = prev == null or prev.? != cur;
            prev = cur;
            rt.watchStall(op, &last_change, changed);
            rt.waitStep(&wt, changed);
        }
    }

    pub const CloseRequest = struct {
        pid: i32,
        policy: ui.Policy,
        /// Consecutive observations without the document window that count as closed.
        stable_observations: u32 = 2,
        /// Default null: any dialog after the close menu step stops the call as unknown UI. With a
        /// policy, the one exact save prompt of the named document is answered with Don't Save.
        discard: ?DiscardPolicy = null,
    };

    /// The owned scratch copy whose unsaved changes may be discarded. The caller proves the ownership,
    /// the read-only source and the unchanged bytes. The runtime proves the prompt: its window is a
    /// modal with an empty title, the owner is the target pid, its two texts are exactly the save
    /// prompt of `document`, and exactly one document window of that name is beside it.
    pub const DiscardPolicy = struct {
        /// Basename of the document. It equals the expected document of the policy.
        document: []const u8,
    };

    pub const CloseReport = struct {
        failure: ?FailureReport = null,
        closed: bool = false,
        /// Don't Save was pressed once for the exact prompt.
        discarded: bool = false,
        stats: Stats = .{},
    };

    const DiscardState = struct { pressed: bool = false };

    const Prompt = union(enum) { none, loading, mismatch, exact: usize };

    /// The line of the save prompt that names the document, and the second line. Observed text of the
    /// live prompt of reopened.vwx.
    fn savePromptMatches(texts: []const []const u8, doc: []const u8) bool {
        const pre = "Do you want to save the changes you made in the document \"";
        if (texts.len != 2) return false;
        const t = texts[0];
        if (t.len != pre.len + doc.len + 2) return false;
        if (!std.mem.startsWith(u8, t, pre) or !std.mem.eql(u8, t[pre.len .. pre.len + doc.len], doc) or !std.mem.eql(u8, t[pre.len + doc.len ..], "\"?")) return false;
        return std.mem.eql(u8, texts[1], "Your changes will be lost if you don't save them.");
    }

    /// Reads the modal windows of an observation. A modal whose state, title or text is not readable
    /// yet is `loading`: the call waits for the next read and never treats it as a closed document.
    fn classifyPrompt(o: ui.Observation, dp: DiscardPolicy) Prompt {
        var at: ?usize = null;
        for (o.windows, 0..) |w, i| {
            const m = w.modal orelse return .loading;
            if (!m) continue;
            if (at != null) return .mismatch;
            at = i;
        }
        const i = at orelse return .none;
        const w = o.windows[i];
        const title = w.title orelse return .loading;
        const texts = w.texts orelse return .loading;
        if (title.len != 0) return .mismatch;
        if (!savePromptMatches(texts, dp.document)) return .mismatch;
        return .{ .exact = i };
    }

    /// Closes the expected document through File > Close. The call needs one ready window of the
    /// expected document. The menu step runs once. The runtime then observes until the window is
    /// gone in `stable_observations` consecutive observations. A dialog after the menu step, an
    /// observation failure or a deadline after it is uncertain and sets the latch. A refusal before
    /// the menu step is definite. The runtime deadlines, statistics and in-flight record apply.
    pub fn closeDocument(rt: *Runtime, req: CloseRequest) CloseReport {
        const t_start = rt.env.now();
        var rep: CloseReport = .{};
        var op = rt.newOp(req.pid, req.policy);
        op.policy.allow_conversion_ack = false;
        op.policy.allow_watermark_ack = false;
        op.expect_note = "document window gone after File > Close";
        if (rt.closeInner(req, &op, &rep)) |f| {
            rt.diagnoseFailure(&op, f);
            rep.failure = withDiag(makeFailure(f, null), &op);
            if (f.uncertain) rt.reconcile = .{ .cause = f.kind, .step = null };
        }
        rep.stats = rt.finishStats(t_start);
        return rep;
    }

    fn closeInner(rt: *Runtime, req: CloseRequest, op: *Op, rep: *CloseReport) ?Failure {
        if (rt.reconcile != null) return .{ .kind = .uncertain_mutation, .detail = "reconciliation is pending" };
        req.policy.expected.validate() catch return .{ .kind = .refused, .detail = "expected document name is invalid" };
        if (req.pid <= 0) return .{ .kind = .process_lost, .detail = "no process id" };
        switch (rt.observeOnce(op)) {
            .failed => |f| return f,
            .decision => |d| {
                if (d.kind != .ready) return mapDecision(d);
                if (!op.setTitle(d.title orelse "")) return .{ .kind = .refused, .detail = "title too long" };
            },
        }
        if (req.discard) |dp| {
            if (!std.mem.eql(u8, dp.document, req.policy.expected.original)) return .{ .kind = .refused, .detail = "the discard document is not the expected document" };
        }
        if (rt.action(op, .menu, .{&[_][]const u8{ "File", "Close" }})) |f| return f;
        rt.cache.invalidate();
        var dst: DiscardState = .{};
        defer rep.discarded = dst.pressed;
        var stable: u32 = 0;
        var polls: u32 = 0;
        var w = rt.waiter();
        var last_change = rt.env.now();
        var prev: ?u32 = null;
        while (true) {
            if (polls >= rt.limits.max_polls) return .{ .kind = .timeout, .detail = "poll limit reached after the close menu", .uncertain = true };
            polls += 1;
            rt.stats.polls += 1;
            const d = switch (rt.observeClosedWith(op, req.discard, &dst)) {
                .unreadable => {
                    stable = 0;
                    const changed = prev == null or prev.? != std.math.maxInt(u32);
                    prev = std.math.maxInt(u32);
                    rt.watchStall(op, &last_change, changed);
                    rt.waitStep(&w, changed);
                    continue;
                },
                .failed => |f| {
                    var uf = f;
                    uf.uncertain = true;
                    return uf;
                },
                .decision => |d| d,
            };
            switch (d.kind) {
                .ready => stable = 0,
                .wait => {
                    if (d.modal != .none) {
                        var uf = mapDecision(d);
                        uf.uncertain = true;
                        return uf;
                    }
                    stable += 1;
                    if (stable >= req.stable_observations) {
                        rep.closed = true;
                        return null;
                    }
                },
                else => {
                    var uf = mapDecision(d);
                    uf.uncertain = true;
                    return uf;
                },
            }
            if (rt.expired(op)) |f| {
                var uf = f;
                uf.uncertain = true;
                return uf;
            }
            const cur: u32 = @intFromEnum(d.kind);
            const changed = prev == null or prev.? != cur;
            prev = cur;
            rt.watchStall(op, &last_change, changed);
            rt.waitStep(&w, changed);
        }
    }

    fn lookupRecord(rt: *Runtime, op: *Op, b: *Builder, sel: Selector, appear: bool) ?Failure {
        const give_up = rt.env.now() + @as(u64, rt.limits.dialog_wait_ms) * std.time.ns_per_ms;
        var w = rt.waiter();
        while (true) {
            if (rt.expired(op)) |f| return f;
            const t0 = rt.env.now();
            const r = rt.backend.lookup(rt.ctx(op), sel);
            rec(&rt.stats.lookup, t0, rt.env.now(), r == .failed);
            switch (r) {
                .failed => |f| return f,
                .found => |c| {
                    if (c.count == 0 and appear and rt.env.now() < give_up) {
                        rt.waitStep(&w, false);
                        continue;
                    }
                    const label = rt.a.dupe(u8, sel.reportLabel()) catch return allocFail();
                    const value = rt.a.dupe(u8, c.value orelse "") catch {
                        rt.a.free(label);
                        return allocFail();
                    };
                    b.controls.append(rt.a, .{ .label = label, .count = c.count, .value = value, .enabled = c.enabled }) catch {
                        rt.a.free(label);
                        rt.a.free(value);
                        return allocFail();
                    };
                    return null;
                },
            }
        }
    }
};

/// Merge main and focused windows with AXWindows. Some app states expose unnamed AXWindows
/// placeholders while the real document is present only through AXMainWindow or AXFocusedWindow.
/// Deduplication uses the existing name, position and size comparison.
const window_list_snippet = "\n" ++
    \\        set listedWindows to (get every window)
    \\        set windowList to {}
    \\        try
    \\          set mainWindow to value of attribute "AXMainWindow"
    \\          if mainWindow is not missing value then set end of windowList to mainWindow
    \\        end try
    \\        try
    \\          set focusWindow to value of attribute "AXFocusedWindow"
    \\          if focusWindow is not missing value then set end of listedWindows to focusWindow
    \\        end try
    \\        repeat with candidateWindow in listedWindows
    \\          set sameWindow to false
    \\          repeat with knownWindow in windowList
    \\            try
    \\              if (name of knownWindow as text) is (name of candidateWindow as text) and (position of knownWindow as text) is (position of candidateWindow as text) and (size of knownWindow as text) is (size of candidateWindow as text) then set sameWindow to true
    \\            end try
    \\          end repeat
    \\          if not sameWindow then set end of windowList to contents of candidateWindow
    \\        end repeat
    \\
;

const script_snapshot =
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  set outText to ""
    \\  tell application "System Events"
    \\    with timeout of 5 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set outText to "ok" & linefeed
++ window_list_snippet ++
    \\        repeat with probeWindow in windowList
    \\          set probeTitle to "n"
    \\          try
    \\            set probeTitle to "s:" & (name of probeWindow as text)
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
    \\          if probeModal is "u" then
    \\            try
    \\              set probeSubrole to (value of attribute "AXSubrole" of probeWindow) as text
    \\              if probeSubrole is "AXDialog" or probeSubrole is "AXSystemDialog" then set probeModal to "t"
    \\            end try
    \\          end if
    \\          set probeButton to "n"
    \\          set probeTexts to ""
    \\          set probeTree to "-"
    \\          if probeModal is "t" then
    \\            try
    \\              set probeDefault to value of attribute "AXDefaultButton" of probeWindow
    \\              if probeDefault is not missing value then set probeButton to "s:" & (name of probeDefault as text)
    \\            end try
    \\            set probeTree to "full"
    \\            try
    \\              repeat with probeElement in (get entire contents of probeWindow)
    \\                if role of probeElement is "AXStaticText" then
    \\                  set probeValue to value of probeElement
    \\                  if probeValue is not missing value then
    \\                    set probeValue to probeValue as text
    \\                    if probeValue contains tab or probeValue contains linefeed or probeValue contains return then
    \\                      set probeTexts to probeTexts & "T" & tab & "x" & linefeed
    \\                    else
    \\                      set probeTexts to probeTexts & "T" & tab & "s:" & probeValue & linefeed
    \\                    end if
    \\                  end if
    \\                end if
    \\              end repeat
    \\            on error
    \\              set probeTree to "loading"
    \\              set probeTexts to ""
    \\            end try
    \\          end if
    \\          set outText to outText & "W" & tab & probeTitle & tab & probeModal & tab & probeButton & tab & probeTree & linefeed & probeTexts
    \\        end repeat
    \\        return outText
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

/// Splits a path text `ROLE:INDEX:OF,ROLE:INDEX:OF` into a list of {role, index, of}. The pieces are
/// copied into real lists before a delimiter changes, because a `repeat with x in (text items of s)`
/// can re-evaluate its list under the delimiter that the loop body sets and then yield `AXTextField`
/// alone, which is the `item 3 of {"AXTextField"}` error of the live run.
const path_parse_handler =
    \\on parsePath(pathText)
    \\  set savedDelimiters to AppleScript's text item delimiters
    \\  set AppleScript's text item delimiters to ","
    \\  set specList to text items of pathText
    \\  set stepList to {}
    \\  repeat with specIndex from 1 to count of specList
    \\    set AppleScript's text item delimiters to ":"
    \\    set partList to text items of (item specIndex of specList)
    \\    set AppleScript's text item delimiters to ","
    \\    set end of stepList to {item 1 of partList, (item 2 of partList) as integer, (item 3 of partList) as integer}
    \\  end repeat
    \\  set AppleScript's text item delimiters to savedDelimiters
    \\  return stepList
    \\end parsePath
    \\
;

const script_control = path_parse_handler ++
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  set containerKind to item 2 of argv
    \\  set containerTitle to item 3 of argv
    \\  set probeMode to item 4 of argv
    \\  set wantRole to item 5 of argv
    \\  set wantName to item 6 of argv
    \\  set wantValue to item 7 of argv
    \\  set locatorKind to item 8 of argv
    \\  set pathText to item 9 of argv
    \\  set pathSteps to {}
    \\  if locatorKind is "path" then set pathSteps to my parsePath(pathText)
    \\  tell application "System Events"
    \\    with timeout of 8 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set windowMatches to {}
    \\        considering case
++ window_list_snippet ++
    \\        repeat with probeWindow in windowList
    \\            try
    \\              if (name of probeWindow as text) is containerTitle then set end of windowMatches to (contents of probeWindow)
    \\            end try
    \\          end repeat
    \\        end considering
    \\        if (count of windowMatches) is 0 then return "refused" & tab & "window_absent"
    \\        if (count of windowMatches) > 1 then return "refused" & tab & "window_ambiguous"
    \\        set probeContainer to item 1 of windowMatches
    \\        if containerKind is "sheet" then
    \\          set sheetList to (get every sheet of probeContainer)
    \\          if (count of sheetList) is 0 then return "refused" & tab & "window_absent"
    \\          if (count of sheetList) > 1 then return "refused" & tab & "window_ambiguous"
    \\          set probeContainer to item 1 of sheetList
    \\        end if
    \\        set probeSignature to ((position of probeContainer) as text) & ";" & ((size of probeContainer) as text) & ";" & ((count of (get every UI element of probeContainer)) as text)
    \\        if probeMode is "identity" then return "ok" & tab & probeSignature
    \\        set controlMatches to {}
    \\        considering case
    \\          if locatorKind is "path" then
    \\            set pathCurrent to probeContainer
    \\            set pathFound to true
    \\            repeat with stepNo from 1 to count of pathSteps
    \\              set pathParts to item stepNo of pathSteps
    \\              set stepKids to {}
    \\              try
    \\                repeat with pathKid in (get every UI element of pathCurrent)
    \\                  if (role of pathKid) is (item 1 of pathParts) then set end of stepKids to (contents of pathKid)
    \\                end repeat
    \\              end try
    \\              if (count of stepKids) is not (item 3 of pathParts) then
    \\                set pathFound to false
    \\                exit repeat
    \\              end if
    \\              set pathCurrent to item (item 2 of pathParts) of stepKids
    \\            end repeat
    \\            if pathFound then
    \\              try
    \\                if (role of pathCurrent) is wantRole then set end of controlMatches to pathCurrent
    \\              end try
    \\            end if
    \\          else
    \\            repeat with probeElement in (get entire contents of probeContainer)
    \\              try
    \\                if locatorKind is "title" then
    \\                  if (role of probeElement) is wantRole then
    \\                    set titleElement to missing value
    \\                    try
    \\                      set titleElement to value of attribute "AXTitleUIElement" of probeElement
    \\                    end try
    \\                    if titleElement is not missing value then
    \\                      set titleText to ""
    \\                      try
    \\                        set titleText to (value of titleElement) as text
    \\                      end try
    \\                      if titleText is wantName then set end of controlMatches to (contents of probeElement)
    \\                    end if
    \\                  end if
    \\                else if (role of probeElement) is wantRole and (name of probeElement) is wantName then
    \\                  set end of controlMatches to (contents of probeElement)
    \\                end if
    \\              end try
    \\            end repeat
    \\          end if
    \\        end considering
    \\        set matchCount to count of controlMatches
    \\        if probeMode is "focused" then
    \\          if matchCount is 0 then return "refused" & tab & "control_absent"
    \\          if matchCount > 1 then return "refused" & tab & "control_ambiguous"
    \\          set probeFocusControl to item 1 of controlMatches
    \\          set probeFocusEnabled to false
    \\          try
    \\            set probeFocusEnabled to (enabled of probeFocusControl) is true
    \\          end try
    \\          if not probeFocusEnabled then return "refused" & tab & "control_disabled"
    \\          set probeFocusValue to missing value
    \\          try
    \\            set probeFocusValue to value of attribute "AXFocused" of probeFocusControl
    \\          end try
    \\          if probeFocusValue is true then return "ok" & tab & "t"
    \\          if probeFocusValue is false then return "ok" & tab & "f"
    \\          return "ok" & tab & "u"
    \\        end if
    \\        if probeMode is "lookup" then
    \\          if matchCount is not 1 then return "ok" & tab & (matchCount as text) & tab & probeSignature
    \\          set probeControl to item 1 of controlMatches
    \\          set probeValueText to "n"
    \\          try
    \\            set probeValueText to "s:" & ((value of probeControl) as text)
    \\          end try
    \\          set probeEnabled to "0"
    \\          try
    \\            if (enabled of probeControl) is true then set probeEnabled to "1"
    \\          end try
    \\          return "ok" & tab & "1" & tab & probeSignature & tab & probeValueText & tab & probeEnabled
    \\        end if
    \\        if matchCount is 0 then return "refused" & tab & "control_absent"
    \\        if matchCount > 1 then return "refused" & tab & "control_ambiguous"
    \\        set probeControl to item 1 of controlMatches
    \\        set probeEnabled to false
    \\        try
    \\          set probeEnabled to (enabled of probeControl) is true
    \\        end try
    \\        if not probeEnabled then return "refused" & tab & "control_disabled"
    \\        try
    \\          if probeMode is "press" then
    \\            click probeControl
    \\            return "ok"
    \\          else if probeMode is "set" then
    \\            if wantRole is "AXCheckBox" or wantRole is "AXRadioButton" or wantRole is "AXDisclosureTriangle" then
    \\              if ((value of probeControl) as text) is not wantValue then click probeControl
    \\            else if wantRole is "AXPopUpButton" then
    \\              click probeControl
    \\              set menuItemRef to missing value
    \\              set menuStep to 0.01
    \\              set menuWaited to 0
    \\              repeat while menuItemRef is missing value
    \\                try
    \\                  set menuItemRef to (first menu item of menu 1 of probeControl whose name is wantValue)
    \\                end try
    \\                if menuItemRef is missing value then
    \\                  if menuWaited >= 3 then error "popup menu did not offer the value" number -1
    \\                  delay menuStep
    \\                  set menuWaited to menuWaited + menuStep
    \\                  if menuStep < 0.15 then set menuStep to menuStep * 2
    \\                end if
    \\              end repeat
    \\              click menuItemRef
    \\            else if wantRole is "AXTextField" or wantRole is "AXComboBox" then
    \\              set value of probeControl to wantValue
    \\            else
    \\              return "refused" & tab & "control_absent"
    \\            end if
    \\            return "ok" & tab & "s:" & ((value of probeControl) as text)
    \\          end if
    \\        on error probeErrorText number probeErrorNumber
    \\          return "failed_after_start" & tab & (probeErrorNumber as text)
    \\        end try
    \\        return "refused" & tab & "control_absent"
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

const script_menu =
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  tell application "System Events"
    \\    with timeout of 8 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set probeItem to missing value
    \\        try
    \\          set probeItem to menu bar item (item 2 of argv) of menu bar 1
    \\          get name of probeItem
    \\          repeat with i from 3 to count of argv
    \\            set probeItem to menu item (item i of argv) of menu 1 of probeItem
    \\            get name of probeItem
    \\          end repeat
    \\        on error
    \\          return "refused" & tab & "menu_absent"
    \\        end try
    \\        try
    \\          click probeItem
    \\        on error probeErrorText number probeErrorNumber
    \\          return "failed_after_start" & tab & (probeErrorNumber as text)
    \\        end try
    \\        return "ok"
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

const script_ack =
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  set wantTitle to item 2 of argv
    \\  set wantButton to item 3 of argv
    \\  set wantTexts to item 4 of argv
    \\  set unitSep to (ASCII character 31)
    \\  tell application "System Events"
    \\    with timeout of 5 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set matchedWindow to missing value
    \\        set matchCount to 0
++ window_list_snippet ++
    \\        repeat with probeWindow in windowList
    \\          set isModal to false
    \\          set modalKnown to false
    \\          try
    \\            set modalValue to value of attribute "AXModal" of probeWindow
    \\            set modalKnown to true
    \\            set isModal to modalValue is true
    \\          end try
    \\          if not modalKnown then
    \\            try
    \\              set probeSubrole to (value of attribute "AXSubrole" of probeWindow) as text
    \\              if probeSubrole is "AXDialog" or probeSubrole is "AXSystemDialog" then set isModal to true
    \\            end try
    \\          end if
    \\          if isModal then
    \\            set probeTitle to "n"
    \\            try
    \\              set probeTitle to "s:" & (name of probeWindow as text)
    \\            end try
    \\            set probeJoined to ""
    \\            set firstText to true
    \\            try
    \\              repeat with probeElement in (get entire contents of probeWindow)
    \\                if role of probeElement is "AXStaticText" then
    \\                  set probeValue to value of probeElement
    \\                  if probeValue is not missing value then
    \\                    if firstText then
    \\                      set probeJoined to (probeValue as text)
    \\                      set firstText to false
    \\                    else
    \\                      set probeJoined to probeJoined & unitSep & (probeValue as text)
    \\                    end if
    \\                  end if
    \\                end if
    \\              end repeat
    \\            on error
    \\              return "refused" & tab & "text_mismatch"
    \\            end try
    \\            considering case
    \\              if probeTitle is wantTitle and probeJoined is wantTexts then
    \\                set matchCount to matchCount + 1
    \\                set matchedWindow to contents of probeWindow
    \\              end if
    \\            end considering
    \\          end if
    \\        end repeat
    \\        if matchCount is 0 then return "refused" & tab & "window_absent"
    \\        if matchCount > 1 then return "refused" & tab & "window_ambiguous"
    \\        set probeDefault to missing value
    \\        try
    \\          set probeDefault to value of attribute "AXDefaultButton" of matchedWindow
    \\        end try
    \\        if probeDefault is missing value then return "refused" & tab & "default_button_not_ok"
    \\        considering case
    \\          if (name of probeDefault as text) is not wantButton then return "refused" & tab & "default_button_not_ok"
    \\        end considering
    \\        try
    \\          click probeDefault
    \\        on error probeErrorText number probeErrorNumber
    \\          return "failed_after_start" & tab & (probeErrorNumber as text)
    \\        end try
    \\        return "ok"
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

/// Presses one named button of the one modal whose title and static texts equal the request. It
/// never presses the default button by itself and never acts on a window that differs.
const script_dismiss =
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  set wantTitle to item 2 of argv
    \\  set wantButton to item 3 of argv
    \\  set wantTexts to item 4 of argv
    \\  set unitSep to (ASCII character 31)
    \\  tell application "System Events"
    \\    with timeout of 5 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set matchedWindow to missing value
    \\        set matchCount to 0
++ window_list_snippet ++
    \\        repeat with probeWindow in windowList
    \\          set isModal to false
    \\          set modalKnown to false
    \\          try
    \\            set modalValue to value of attribute "AXModal" of probeWindow
    \\            set modalKnown to true
    \\            set isModal to modalValue is true
    \\          end try
    \\          if not modalKnown then
    \\            try
    \\              set probeSubrole to (value of attribute "AXSubrole" of probeWindow) as text
    \\              if probeSubrole is "AXDialog" or probeSubrole is "AXSystemDialog" then set isModal to true
    \\            end try
    \\          end if
    \\          if isModal then
    \\            set probeTitle to "n"
    \\            try
    \\              set probeTitle to "s:" & (name of probeWindow as text)
    \\            end try
    \\            set probeJoined to ""
    \\            set firstText to true
    \\            try
    \\              repeat with probeElement in (get entire contents of probeWindow)
    \\                if role of probeElement is "AXStaticText" then
    \\                  set probeValue to value of probeElement
    \\                  if probeValue is not missing value then
    \\                    if firstText then
    \\                      set probeJoined to (probeValue as text)
    \\                      set firstText to false
    \\                    else
    \\                      set probeJoined to probeJoined & unitSep & (probeValue as text)
    \\                    end if
    \\                  end if
    \\                end if
    \\              end repeat
    \\            on error
    \\              return "refused" & tab & "text_mismatch"
    \\            end try
    \\            considering case
    \\              if probeTitle is wantTitle and probeJoined is wantTexts then
    \\                set matchCount to matchCount + 1
    \\                set matchedWindow to contents of probeWindow
    \\              end if
    \\            end considering
    \\          end if
    \\        end repeat
    \\        if matchCount is 0 then return "refused" & tab & "window_absent"
    \\        if matchCount > 1 then return "refused" & tab & "window_ambiguous"
    \\        set probeButtons to (every button of matchedWindow whose name is wantButton)
    \\        if (count of probeButtons) is not 1 then return "refused" & tab & "button_not_found"
    \\        try
    \\          click item 1 of probeButtons
    \\        on error probeErrorText number probeErrorNumber
    \\          return "failed_after_start" & tab & (probeErrorNumber as text)
    \\        end try
    \\        return "ok"
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

const script_progress =
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  tell application "System Events"
    \\    with timeout of 5 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set indicatorCount to 0
    \\        set probeValue to ""
    \\        set probeMax to ""
++ window_list_snippet ++
    \\        repeat with probeWindow in windowList
    \\          set isModal to false
    \\          set modalKnown to false
    \\          try
    \\            set modalValue to value of attribute "AXModal" of probeWindow
    \\            set modalKnown to true
    \\            set isModal to modalValue is true
    \\          end try
    \\          if not modalKnown then
    \\            try
    \\              set probeSubrole to (value of attribute "AXSubrole" of probeWindow) as text
    \\              if probeSubrole is "AXDialog" or probeSubrole is "AXSystemDialog" then set isModal to true
    \\            end try
    \\          end if
    \\          if isModal then
    \\            try
    \\              repeat with probeElement in (get entire contents of probeWindow)
    \\                if role of probeElement is "AXProgressIndicator" then
    \\                  set indicatorCount to indicatorCount + 1
    \\                  set probeValue to (value of probeElement) as text
    \\                  set probeMax to (maximum value of probeElement) as text
    \\                end if
    \\              end repeat
    \\            on error
    \\              return "refused" & tab & "progress_unreadable"
    \\            end try
    \\          end if
    \\        end repeat
    \\        if indicatorCount is 0 then return "ok" & tab & "none"
    \\        if indicatorCount > 1 then return "refused" & tab & "progress_ambiguous"
    \\        return "ok" & tab & "p" & tab & probeValue & tab & probeMax
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

const script_windowid =
    \\on run argv
    \\  set probePid to (item 1 of argv) as integer
    \\  set wantTitle to item 2 of argv
    \\  tell application "System Events"
    \\    with timeout of 5 seconds
    \\      if not (exists (first process whose unix id is probePid)) then return "gone"
    \\      tell (first process whose unix id is probePid)
    \\        set windowMatches to {}
    \\        considering case
++ window_list_snippet ++
    \\        repeat with probeWindow in windowList
    \\            try
    \\              if (name of probeWindow as text) is wantTitle then set end of windowMatches to (contents of probeWindow)
    \\            end try
    \\          end repeat
    \\        end considering
    \\        if (count of windowMatches) is 0 then return "refused" & tab & "window_absent"
    \\        if (count of windowMatches) > 1 then return "refused" & tab & "window_ambiguous"
    \\        set probeNumber to missing value
    \\        try
    \\          set probeNumber to value of attribute "AXWindowNumber" of (item 1 of windowMatches)
    \\        end try
    \\        if probeNumber is missing value then return "refused" & tab & "no_window_id"
    \\        return "ok" & tab & (probeNumber as text)
    \\      end tell
    \\    end timeout
    \\  end tell
    \\end run
;

// macOS backend

pub const MacConfig = struct {
    osascript: []const u8 = "/usr/bin/osascript",
    stat: []const u8 = "/usr/bin/stat",
    id: []const u8 = "/usr/bin/id",
    ioreg: []const u8 = "/usr/sbin/ioreg",
    screencapture: []const u8 = "/usr/sbin/screencapture",
    limits: Limits = .{},
    /// Injected window evidence. Production ProcessTransport uses native Accessibility.
    window_source: ?*const fn (Allocator, Env, Ctx, Limits) ObserveReply = null,
    /// Posts one key down and one key up with these modifier flags to the pid. False when no event was posted.
    key_post: *const fn (pid: i32, key: u16, flags: u64) bool = native_keys.post,
};

/// Keyboard events for the target pid only. `CGEventPostToPid` never reaches another application.
const native_keys = if (builtin.os.tag == .macos) struct {
    const Ref = ?*anyopaque;
    extern "c" fn CGEventCreateKeyboardEvent(source: Ref, key: u16, down: bool) Ref;
    extern "c" fn CGEventSetFlags(event: Ref, flags: u64) void;
    extern "c" fn CGEventKeyboardSetUnicodeString(event: Ref, count: usize, chars: [*]const u16) void;
    extern "c" fn CGEventKeyboardGetUnicodeString(event: Ref, max: usize, actual: *usize, chars: [*]u16) void;
    extern "c" fn CGEventPostToPid(pid: c_int, event: Ref) void;
    extern "c" fn CFRelease(r: Ref) void;

    /// Builds one key event with its flags and, for a chord that names one, its Unicode character.
    /// Nothing is posted. The caller owns the event and releases it with `release`.
    fn prepare(key: u16, down: bool, flags: u64) Ref {
        const ev = CGEventCreateKeyboardEvent(null, key, down) orelse return null;
        CGEventSetFlags(ev, flags);
        if (chordUnicode(key, flags)) |ch| {
            const chars = [_]u16{ch};
            CGEventKeyboardSetUnicodeString(ev, chars.len, &chars);
        }
        return ev;
    }

    fn release(ev: Ref) void {
        CFRelease(ev);
    }

    /// The Unicode character that the event carries, or null when it has none.
    fn unicodeOf(ev: Ref) ?u16 {
        var chars: [4]u16 = @splat(0);
        var actual: usize = 0;
        CGEventKeyboardGetUnicodeString(ev, chars.len, &actual, &chars);
        return if (actual == 1) chars[0] else null;
    }

    fn post(pid: i32, key: u16, flags: u64) bool {
        const down = prepare(key, true, flags) orelse return false;
        defer release(down);
        const up = prepare(key, false, flags) orelse return false;
        defer release(up);
        CGEventPostToPid(pid, down);
        CGEventPostToPid(pid, up);
        return true;
    }
} else struct {
    fn post(pid: i32, key: u16, flags: u64) bool {
        _ = .{ pid, key, flags };
        return false;
    }
};

const key_g: u16 = 5;
/// ANSI slash. The plain slash key is the other standard way to ask a save panel for Go to Folder.
const key_slash: u16 = 44;
const flag_shift: u64 = 0x20000;
const flag_command: u64 = 0x100000;

/// The Unicode character that a chord's events carry. CGEventCreateKeyboardEvent derives lowercase
/// `g` from keycode 5 and the flags leave it unchanged, while the menu shortcut of Go to Folder is the
/// uppercase character. Only Command-Shift-G has a mapping. Every other key and modifier set keeps the
/// character that the system derives.
fn chordUnicode(key: u16, flags: u64) ?u16 {
    if (key == key_g and flags == (flag_command | flag_shift)) return 'G';
    // Keycode 44 is a slash only on some layouts. The chord says slash, so the event carries it.
    if (key == key_slash and flags == 0) return '/';
    return null;
}

const Budget = struct {
    start: u64,
    total_ms: u32,

    fn left(b: Budget, env: Env) ?u32 {
        const used_ms = (env.now() -| b.start) / std.time.ns_per_ms;
        if (used_ms >= b.total_ms) return null;
        return @intCast(b.total_ms - used_ms);
    }
};

const ScriptReply = union(enum) { body: []const u8, failed: Failure };

fn isAbsentContainer(f: Failure) bool {
    return f.kind == .unknown_ui and !f.uncertain and std.mem.eql(u8, f.detail, refusalFailure("window_absent").detail);
}

fn refusalFailure(reason: []const u8) Failure {
    const eq = std.mem.eql;
    if (eq(u8, reason, "window_ambiguous") or eq(u8, reason, "control_ambiguous") or eq(u8, reason, "progress_ambiguous"))
        return .{ .kind = .ambiguous_target, .detail = "more than one window or control matches" };
    if (eq(u8, reason, "window_absent")) return .{ .kind = .unknown_ui, .detail = "target window or sheet is absent" };
    if (eq(u8, reason, "control_absent")) return .{ .kind = .unknown_ui, .detail = "target control is absent" };
    if (eq(u8, reason, "button_not_found")) return .{ .kind = .unknown_ui, .detail = "the dialog has not exactly one button of that name" };
    if (eq(u8, reason, "control_disabled")) return .{ .kind = .refused, .detail = "target control is disabled" };
    if (eq(u8, reason, "menu_absent")) return .{ .kind = .unknown_ui, .detail = "menu path is absent" };
    if (eq(u8, reason, "text_mismatch")) return .{ .kind = .unknown_ui, .detail = "dialog text differs from the approved text" };
    if (eq(u8, reason, "default_button_not_ok")) return .{ .kind = .unknown_ui, .detail = "default button is not the approved button" };
    if (eq(u8, reason, "no_window_id")) return .{ .kind = .screenshot_unavailable, .detail = "the window exposes no window number" };
    if (eq(u8, reason, "progress_unreadable")) return .{ .kind = .unknown_ui, .detail = "progress dialog tree is unreadable" };
    return .{ .kind = .unknown_ui, .detail = "script refused for an unknown reason" };
}

/// AppleScript and command-line backend. Every platform call goes through `Transport`, so tests
/// inject a fake. Replies are borrowed from an arena that each public call resets.
pub const MacBackend = struct {
    transport: Transport,
    env: Env,
    cfg: MacConfig,
    arena: std.heap.ArenaAllocator,

    pub fn init(a: Allocator, transport: Transport, env: Env, cfg: MacConfig) MacBackend {
        var config = cfg;
        if (builtin.os.tag == .macos and config.window_source == null and transport.runFn == ProcessTransport.runImpl) {
            config.window_source = @import("native_ui_diagnostics.zig").readRuntimeWindows;
        }
        return .{ .transport = transport, .env = env, .cfg = config, .arena = std.heap.ArenaAllocator.init(a) };
    }

    pub fn deinit(m: *MacBackend) void {
        m.arena.deinit();
    }

    pub fn backend(m: *MacBackend) Backend {
        return .{
            .ptr = m,
            .observeFn = observeImpl,
            .acknowledgeFn = acknowledgeImpl,
            .menuFn = menuImpl,
            .identityFn = identityImpl,
            .lookupFn = lookupImpl,
            .setValueFn = setValueImpl,
            .pressFn = pressImpl,
            .progressFn = progressImpl,
            .screenshotFn = screenshotImpl,
            .chordFn = chordImpl,
            .focusedFn = focusedImpl,
            .dismissFn = dismissImpl,
        };
    }

    fn self(ptr: *anyopaque) *MacBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn begin(m: *MacBackend, ctx: Ctx) Budget {
        _ = m.arena.reset(.retain_capacity);
        return .{ .start = m.env.now(), .total_ms = ctx.timeout_ms };
    }

    fn exec(m: *MacBackend, budget: Budget, argv: []const []const u8, lim: StreamLimits) union(enum) { out: RunOutput, failed: Failure } {
        const left = budget.left(m.env) orelse return .{ .failed = .{ .kind = .timeout, .detail = "call budget used" } };
        const o = m.transport.run(m.arena.allocator(), argv, left, lim);
        return switch (o.status) {
            .exited => .{ .out = o },
            .timed_out => .{ .failed = .{ .kind = .timeout, .detail = "child process timed out and was killed" } },
            .spawn_failed => .{ .failed = .{ .kind = .transport_error, .detail = "child process did not start" } },
            .output_limit => .{ .failed = .{ .kind = .transport_error, .detail = "child output passed its limit" } },
            .signaled, .read_failed => .{ .failed = .{ .kind = .transport_error, .detail = "child process ended abnormally" } },
        };
    }

    /// Runs one osascript program. `mutating` marks calls whose failure leaves the outcome unknown.
    fn osa(m: *MacBackend, budget: Budget, src: []const u8, args: []const []const u8, mutating: bool) ScriptReply {
        const a = m.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(a, &.{ m.cfg.osascript, "-e", src }) catch return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        argv.appendSlice(a, args) catch return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        const lim: StreamLimits = .{ .stdout = m.cfg.limits.max_stdout, .stderr = m.cfg.limits.max_stderr };
        const o = switch (m.exec(budget, argv.items, lim)) {
            .failed => |f| {
                var uf = f;
                uf.uncertain = mutating;
                return .{ .failed = uf };
            },
            .out => |o| o,
        };
        const body = std.mem.trim(u8, o.stdout, " \r\n");
        if (o.exit_code != 0) {
            const err = std.mem.trim(u8, o.stderr, " \r\n");
            return .{ .failed = .{
                .kind = if (mutating) .transport_error else .unknown_ui,
                .detail = err[0..@min(err.len, 120)],
                .uncertain = mutating,
            } };
        }
        const tok_end = std.mem.indexOfAny(u8, body, "\t\n") orelse body.len;
        const tok = body[0..tok_end];
        if (std.mem.eql(u8, tok, "ok")) return .{ .body = body };
        if (std.mem.eql(u8, tok, "gone")) return .{ .failed = .{ .kind = .process_lost, .detail = "process is not running" } };
        if (std.mem.eql(u8, tok, "refused")) {
            var it = std.mem.splitScalar(u8, body, '\t');
            _ = it.next();
            return .{ .failed = refusalFailure(it.next() orelse "") };
        }
        if (std.mem.eql(u8, tok, "failed_after_start")) {
            return .{ .failed = .{ .kind = .transport_error, .detail = "script error after the action started", .uncertain = true } };
        }
        return .{ .failed = .{ .kind = .transport_error, .detail = "script output is unparsable", .uncertain = mutating } };
    }

    fn pidArg(m: *MacBackend, pid: i32) ?[]const u8 {
        return std.fmt.allocPrint(m.arena.allocator(), "{d}", .{pid}) catch null;
    }

    /// Runs one console command. Null for any failure other than a deadline.
    fn consoleCmd(m: *MacBackend, budget: Budget, argv: []const []const u8, limit: usize) union(enum) { text: ?[]const u8, timeout } {
        const left = budget.left(m.env) orelse return .timeout;
        const o = m.transport.run(m.arena.allocator(), argv, @min(left, 5000), .{ .stdout = limit, .stderr = 4096 });
        if (o.status == .timed_out) return .timeout;
        if (!o.succeeded() or o.stdout_truncated) return .{ .text = null };
        return .{ .text = std.mem.trim(u8, o.stdout, " \r\n") };
    }

    // Observation

    fn observeImpl(ptr: *anyopaque, ctx: Ctx) ObserveReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        var console: ui.ConsoleObservation = .{};
        switch (m.consoleCmd(budget, &.{ m.cfg.stat, "-f", "%Su", "/dev/console" }, 1024)) {
            .timeout => return .{ .failed = .{ .kind = .timeout, .detail = "console owner query timed out" } },
            .text => |t| console.owner = t,
        }
        switch (m.consoleCmd(budget, &.{ m.cfg.id, "-un" }, 1024)) {
            .timeout => return .{ .failed = .{ .kind = .timeout, .detail = "user query timed out" } },
            .text => |t| console.user = t,
        }
        switch (m.consoleCmd(budget, &.{ m.cfg.ioreg, "-n", "Root", "-d1" }, m.cfg.limits.max_console_stdout)) {
            .timeout => return .{ .failed = .{ .kind = .timeout, .detail = "console registry query timed out" } },
            .text => |t| console.registry = t,
        }
        if (m.cfg.window_source) |read| {
            var window_ctx = ctx;
            window_ctx.timeout_ms = budget.left(m.env) orelse return .{ .failed = .{ .kind = .timeout, .detail = "window observation budget used" } };
            return switch (read(m.arena.allocator(), m.env, window_ctx, m.cfg.limits)) {
                .failed => |f| .{ .failed = f },
                .observed => |o| .{ .observed = .{ .console = console, .windows = o.windows, .windows_complete = o.windows_complete } },
            };
        }
        const pid = m.pidArg(ctx.pid) orelse return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        const body = switch (m.osa(budget, script_snapshot, &.{pid}, false)) {
            .failed => |f| return .{ .failed = f },
            .body => |b| b,
        };
        return switch (parseSnapshot(m.arena.allocator(), body, m.cfg.limits)) {
            .malformed => |why| .{ .failed = .{ .kind = .unknown_ui, .detail = why } },
            .ok => |s| .{ .observed = .{ .console = console, .windows = s.windows, .windows_complete = s.complete } },
        };
    }

    // Actions

    fn acknowledgeImpl(ptr: *anyopaque, ctx: Ctx, req: AckRequest) ActionReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const a = m.arena.allocator();
        // Only the default OK button of an exact notice is clickable.
        if (!std.mem.eql(u8, req.button, ui.allowed_default_button)) return .{ .failed = .{ .kind = .refused, .detail = "button is not the approved button" } };
        switch (req.class) {
            .known_conversion, .known_watermark => {},
            .unknown => if (!req.exact_notice or req.texts.len == 0) return .{ .failed = .{ .kind = .refused, .detail = "class is not an acknowledgeable notice" } },
            else => return .{ .failed = .{ .kind = .refused, .detail = "class is not an acknowledgeable notice" } },
        }
        const pid = m.pidArg(ctx.pid) orelse return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        const title = if (req.title) |t| std.fmt.allocPrint(a, "s:{s}", .{t}) catch return oom() else "n";
        const joined = std.mem.join(a, "\x1f", req.texts) catch return oom();
        return switch (m.osa(budget, script_ack, &.{ pid, title, req.button, joined }, true)) {
            .failed => |f| .{ .failed = f },
            .body => .{ .done = null },
        };
    }

    /// Presses `discard_button` of the one modal whose title and texts equal the request. Any other
    /// button is refused before the script runs.
    fn dismissImpl(ptr: *anyopaque, ctx: Ctx, req: DismissRequest) ActionReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const a = m.arena.allocator();
        if (!std.mem.eql(u8, req.button, discard_button)) return .{ .failed = .{ .kind = .refused, .detail = "button is not the approved discard button" } };
        if (req.texts.len == 0 or req.title == null) return .{ .failed = .{ .kind = .refused, .detail = "the dialog has no readable title and text" } };
        const pid = m.pidArg(ctx.pid) orelse return oom();
        const title = std.fmt.allocPrint(a, "s:{s}", .{req.title.?}) catch return oom();
        const joined = std.mem.join(a, "\x1f", req.texts) catch return oom();
        return switch (m.osa(budget, script_dismiss, &.{ pid, title, req.button, joined }, true)) {
            .failed => |f| .{ .failed = f },
            .body => .{ .done = null },
        };
    }

    fn oom() ActionReply {
        return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
    }

    fn menuImpl(ptr: *anyopaque, ctx: Ctx, path: []const []const u8) ActionReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        if (path.len < 2 or path.len > m.cfg.limits.max_menu_depth) return .{ .failed = .{ .kind = .refused, .detail = "menu path length is out of range" } };
        const pid = m.pidArg(ctx.pid) orelse return oom();
        var args: std.ArrayList([]const u8) = .empty;
        const a = m.arena.allocator();
        args.append(a, pid) catch return oom();
        args.appendSlice(a, path) catch return oom();
        return switch (m.osa(budget, script_menu, args.items, true)) {
            .failed => |f| .{ .failed = f },
            .body => .{ .done = null },
        };
    }

    fn controlArgs(m: *MacBackend, ctx: Ctx, container: Container, mode: []const u8, role: []const u8, label: []const u8, value: []const u8) ?[][]const u8 {
        const a = m.arena.allocator();
        const pid = m.pidArg(ctx.pid) orelse return null;
        const kind: []const u8 = switch (container) {
            .document_sheet, .window_sheet => "sheet",
            .window => "window",
        };
        const title: []const u8 = switch (container) {
            .document_sheet => ctx.window_title,
            .window, .window_sheet => |t| t,
        };
        const out = a.alloc([]const u8, 9) catch return null;
        out[0] = pid;
        out[1] = kind;
        out[2] = title;
        out[3] = mode;
        out[4] = role;
        out[5] = label;
        out[6] = value;
        out[7] = "name";
        out[8] = "";
        return out;
    }

    /// The arguments of a control call for a selector, with its locator.
    fn selectorArgs(m: *MacBackend, ctx: Ctx, sel: Selector, mode: []const u8, value: []const u8) ?[]const []const u8 {
        const out = m.controlArgs(ctx, sel.container, mode, sel.role.axRole(), sel.label, value) orelse return null;
        const w = out;
        switch (sel.via) {
            .name => {},
            .title_element => w[7] = "title",
            .path => |p| {
                w[7] = "path";
                var text: std.ArrayList(u8) = .empty;
                for (p, 0..) |st, i| {
                    if (i != 0) text.append(m.arena.allocator(), ',') catch return null;
                    text.print(m.arena.allocator(), "{s}:{d}:{d}", .{ st.role.axRole(), st.index, st.of }) catch return null;
                }
                w[8] = text.items;
            },
        }
        return out;
    }

    fn identityImpl(ptr: *anyopaque, ctx: Ctx, container: Container) IdentityReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const args = m.controlArgs(ctx, container, "identity", "", "", "") orelse return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        switch (m.osa(budget, script_control, args, false)) {
            .failed => |f| {
                if (f.kind == .unknown_ui and std.mem.eql(u8, f.detail, "target window or sheet is absent")) return .absent;
                return .{ .failed = f };
            },
            .body => |b| {
                var it = std.mem.splitScalar(u8, b, '\t');
                _ = it.next();
                const sig = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "identity output is unparsable" } };
                return .{ .present = std.hash.Wyhash.hash(0x1d, sig) };
            },
        }
    }

    fn lookupImpl(ptr: *anyopaque, ctx: Ctx, sel: Selector) LookupReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const args = m.selectorArgs(ctx, sel, "lookup", "") orelse return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        const body = switch (m.osa(budget, script_control, args, false)) {
            .failed => |f| return .{ .failed = f },
            .body => |b| b,
        };
        return parseLookup(body, sel);
    }

    fn setValueImpl(ptr: *anyopaque, ctx: Ctx, sel: Selector, value: OptionValue) ActionReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const want: []const u8 = switch (value) {
            .checked => |c| if (c) "1" else "0",
            .choice => |s| s,
            .text => |s| s,
        };
        const args = m.selectorArgs(ctx, sel, "set", want) orelse return oom();
        const body = switch (m.osa(budget, script_control, args, true)) {
            .failed => |f| return .{ .failed = f },
            .body => |b| b,
        };
        var it = std.mem.splitScalar(u8, body, '\t');
        _ = it.next();
        const v = it.next() orelse return .{ .failed = .{ .kind = .incomplete_options, .detail = "set returned no read back value", .uncertain = true } };
        return switch (decodeField(v)) {
            .str => |s| .{ .done = s },
            else => .{ .failed = .{ .kind = .incomplete_options, .detail = "set returned an unreadable value", .uncertain = true } },
        };
    }

    /// AXFocused of the one control, from the control script. Nothing is pressed or set.
    fn focusedImpl(ptr: *anyopaque, ctx: Ctx, sel: Selector) FocusReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const args = m.selectorArgs(ctx, sel, "focused", "") orelse return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        const body = switch (m.osa(budget, script_control, args, false)) {
            .failed => |f| return .{ .failed = f },
            .body => |b| b,
        };
        var it = std.mem.splitScalar(u8, body, '\t');
        _ = it.next();
        const v = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "focus output is unparsable" } };
        if (std.mem.eql(u8, v, "t")) return .{ .focused = true };
        if (std.mem.eql(u8, v, "f")) return .{ .focused = false };
        if (std.mem.eql(u8, v, "u")) return .{ .failed = .{ .kind = .unknown_ui, .detail = "the control gives no readable focus state" } };
        return .{ .failed = .{ .kind = .transport_error, .detail = "focus output is unparsable" } };
    }

    fn pressImpl(ptr: *anyopaque, ctx: Ctx, sel: Selector) ActionReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const args = m.selectorArgs(ctx, sel, "press", "") orelse return oom();
        return switch (m.osa(budget, script_control, args, true)) {
            .failed => |f| .{ .failed = f },
            .body => .{ .done = null },
        };
    }

    /// Posts the chord to the pid after the exact-title window was found, with no other app involved.
    fn chordImpl(ptr: *anyopaque, ctx: Ctx, window_title: []const u8, chord: Chord) ActionReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const args = m.controlArgs(ctx, .{ .window = window_title }, "identity", "", "", "") orelse return oom();
        switch (m.osa(budget, script_control, args, false)) {
            .failed => |f| return .{ .failed = f },
            .body => {},
        }
        const key: u16 = switch (chord) {
            .go_to_folder => key_g,
            .slash => key_slash,
        };
        const flags: u64 = switch (chord) {
            .go_to_folder => flag_command | flag_shift,
            .slash => 0,
        };
        if (!m.cfg.key_post(ctx.pid, key, flags)) return .{ .failed = .{ .kind = .refused, .detail = "the keyboard event could not be posted" } };
        return .{ .done = null };
    }

    fn progressImpl(ptr: *anyopaque, ctx: Ctx) ProgressReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        const pid = m.pidArg(ctx.pid) orelse return .{ .failed = .{ .kind = .out_of_memory, .detail = "allocation failed" } };
        const body = switch (m.osa(budget, script_progress, &.{pid}, false)) {
            .failed => |f| return .{ .failed = f },
            .body => |b| b,
        };
        return parseProgressReply(body);
    }

    /// Window-targeted capture. The window number must come from the exact-title window of the
    /// expected pid. Without a number the call fails. It never captures a screen rectangle.
    fn screenshotImpl(ptr: *anyopaque, ctx: Ctx, path: []const u8) ActionReply {
        const m = self(ptr);
        const budget = m.begin(ctx);
        if (path.len < 6 or path[0] != '/' or hasControl(path) or !std.ascii.endsWithIgnoreCase(path, ".png")) {
            return .{ .failed = .{ .kind = .refused, .detail = "screenshot path must be an absolute .png path" } };
        }
        if (ctx.window_title.len == 0) return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "no window title to target" } };
        const pid = m.pidArg(ctx.pid) orelse return oom();
        const body = switch (m.osa(budget, script_windowid, &.{ pid, ctx.window_title }, false)) {
            .failed => |f| {
                var sf = f;
                if (sf.kind == .unknown_ui) sf.kind = .screenshot_unavailable;
                return .{ .failed = sf };
            },
            .body => |b| b,
        };
        var it = std.mem.splitScalar(u8, body, '\t');
        _ = it.next();
        const num = it.next() orelse return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "window number output is unparsable" } };
        const id = std.fmt.parseInt(u32, num, 10) catch return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "window number is not an integer" } };
        if (id == 0) return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "window number is zero" } };
        const id_text = std.fmt.allocPrint(m.arena.allocator(), "{d}", .{id}) catch return oom();
        switch (m.exec(budget, &.{ m.cfg.screencapture, "-x", "-o", "-l", id_text, path }, .{ .stdout = 4096, .stderr = 4096 })) {
            .failed => |f| return .{ .failed = f },
            .out => |o| {
                if (o.exit_code != 0) return .{ .failed = .{ .kind = .screenshot_unavailable, .detail = "screencapture failed" } };
            },
        }
        return .{ .done = null };
    }
};

const FieldValue = union(enum) { null_value, str: []const u8, bad };

/// `n` is null. `s:<text>` is a string. Anything else is bad.
fn decodeField(s: []const u8) FieldValue {
    if (std.mem.eql(u8, s, "n")) return .null_value;
    if (std.mem.startsWith(u8, s, "s:")) return .{ .str = s[2..] };
    return .bad;
}

fn parseLookup(body: []const u8, sel: Selector) LookupReply {
    _ = sel;
    var it = std.mem.splitScalar(u8, body, '\t');
    _ = it.next();
    const count_s = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "lookup output is unparsable" } };
    const count = std.fmt.parseInt(u16, count_s, 10) catch return .{ .failed = .{ .kind = .transport_error, .detail = "lookup count is not a number" } };
    const sig = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "lookup output has no layout signature" } };
    const layout = std.hash.Wyhash.hash(0x1d, sig);
    if (count != 1) return .{ .found = .{ .count = count, .layout_id = layout } };
    const val = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "lookup output has no value" } };
    const en = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "lookup output has no enabled flag" } };
    if (it.next() != null) return .{ .failed = .{ .kind = .transport_error, .detail = "lookup output has an unknown field" } };
    const enabled = if (std.mem.eql(u8, en, "1")) true else if (std.mem.eql(u8, en, "0")) false else return .{ .failed = .{ .kind = .transport_error, .detail = "lookup enabled flag is invalid" } };
    const value: ?[]const u8 = switch (decodeField(val)) {
        .str => |s| s,
        .null_value => null,
        .bad => return .{ .failed = .{ .kind = .transport_error, .detail = "lookup value is invalid" } },
    };
    return .{ .found = .{ .count = 1, .layout_id = layout, .value = value, .enabled = enabled } };
}

fn parseProgressReply(body: []const u8) ProgressReply {
    var it = std.mem.splitScalar(u8, body, '\t');
    _ = it.next();
    const kind = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "progress output is unparsable" } };
    if (std.mem.eql(u8, kind, "none")) return .none;
    if (!std.mem.eql(u8, kind, "p")) return .{ .failed = .{ .kind = .transport_error, .detail = "progress output is unparsable" } };
    const v = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "progress value is missing" } };
    const mx = it.next() orelse return .{ .failed = .{ .kind = .transport_error, .detail = "progress maximum is missing" } };
    if (it.next() != null) return .{ .failed = .{ .kind = .transport_error, .detail = "progress output has an unknown field" } };
    const value = std.fmt.parseFloat(f64, v) catch return .{ .failed = .{ .kind = .unknown_ui, .detail = "progress value is not a number" } };
    const max = std.fmt.parseFloat(f64, mx) catch return .{ .failed = .{ .kind = .unknown_ui, .detail = "progress maximum is not a number" } };
    if (!(max > 0) or !(value >= 0) or value > max or !std.math.isFinite(max) or !std.math.isFinite(value)) {
        return .{ .failed = .{ .kind = .unknown_ui, .detail = "progress is out of range" } };
    }
    const scaled: u32 = @intFromFloat(@round(value / max * 1000.0));
    return .{ .fraction = .{ .done = scaled, .total = 1000 } };
}

const SnapshotResult = union(enum) {
    malformed: []const u8,
    ok: struct { windows: []ui.WindowObservation, complete: bool },
};

/// Parses the snapshot script output into window observations. Window titles, texts and buttons
/// are sub-slices of `text`. Allocation holds the window and text lists in `a`.
pub fn parseSnapshot(a: Allocator, text: []const u8, lim: Limits) SnapshotResult {
    const Pending = struct { title: ?[]const u8, modal: ?bool, button: ?[]const u8, texts_from: usize, texts_to: usize, readable: bool };
    var pend: std.ArrayList(Pending) = .empty;
    var pool: std.ArrayList([]const u8) = .empty;
    var complete = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", "\r");
    if (!std.mem.eql(u8, first, "ok")) return .{ .malformed = "snapshot does not start with ok" };
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == 'W') {
            var f = std.mem.splitScalar(u8, line, '\t');
            _ = f.next();
            const title_s = f.next() orelse return .{ .malformed = "window line has too few fields" };
            const modal_s = f.next() orelse return .{ .malformed = "window line has too few fields" };
            const button_s = f.next() orelse return .{ .malformed = "window line has too few fields" };
            const tree_s = f.next() orelse return .{ .malformed = "window line has too few fields" };
            if (f.next() != null) return .{ .malformed = "window line has too many fields" };
            if (pend.items.len >= lim.max_windows) return .{ .malformed = "too many windows" };
            const title: ?[]const u8 = switch (decodeField(title_s)) {
                .str => |s| s,
                .null_value => null,
                .bad => return .{ .malformed = "window title field is invalid" },
            };
            const modal: ?bool = if (std.mem.eql(u8, modal_s, "t")) true else if (std.mem.eql(u8, modal_s, "f")) false else if (std.mem.eql(u8, modal_s, "u")) null else return .{ .malformed = "window modal field is invalid" };
            const button: ?[]const u8 = switch (decodeField(button_s)) {
                .str => |s| s,
                .null_value => null,
                .bad => return .{ .malformed = "window button field is invalid" },
            };
            var readable = true;
            if (std.mem.eql(u8, tree_s, "loading")) {
                readable = false;
                complete = false;
            } else if (std.mem.eql(u8, tree_s, "full")) {
                if (modal != true) return .{ .malformed = "a window that is not modal has a text tree" };
            } else if (std.mem.eql(u8, tree_s, "-")) {
                if (modal == true) return .{ .malformed = "a modal window has no text tree" };
            } else return .{ .malformed = "window tree field is invalid" };
            pend.append(a, .{ .title = title, .modal = modal, .button = button, .texts_from = pool.items.len, .texts_to = pool.items.len, .readable = readable }) catch return .{ .malformed = "allocation failed" };
        } else if (line[0] == 'T') {
            if (pend.items.len == 0) return .{ .malformed = "text line before any window" };
            var f = std.mem.splitScalar(u8, line, '\t');
            _ = f.next();
            const v = f.next() orelse return .{ .malformed = "text line has no value" };
            if (f.next() != null) return .{ .malformed = "text line has too many fields" };
            const cur = &pend.items[pend.items.len - 1];
            if (!cur.readable) continue;
            switch (decodeField(v)) {
                .str => |s| {
                    if (s.len > lim.max_text_len or cur.texts_to - cur.texts_from >= lim.max_texts) {
                        cur.readable = false;
                        complete = false;
                    } else {
                        pool.append(a, s) catch return .{ .malformed = "allocation failed" };
                        cur.texts_to = pool.items.len;
                    }
                },
                .null_value, .bad => {
                    // `x` marks a text that holds a tab or line break. It cannot be compared exactly.
                    cur.readable = false;
                    complete = false;
                },
            }
        } else return .{ .malformed = "unknown line type" };
    }
    const wins = a.alloc(ui.WindowObservation, pend.items.len) catch return .{ .malformed = "allocation failed" };
    for (pend.items, wins) |p, *w| {
        w.* = .{
            .title = p.title,
            .modal = p.modal,
            .texts = if (p.modal == true and p.readable) pool.items[p.texts_from..p.texts_to] else null,
            .default_button = p.button,
        };
    }
    return .{ .ok = .{ .windows = wins, .complete = complete } };
}

// Export modal calibration CLI

pub const control_usage_text =
    \\usage: vwx ui-export-control --pid N --expected-executable ABSOLUTE_PATH --window-title TITLE
    \\                             (--control SEL | --where SEL --sheet-field SEL --go SEL)
    \\                             [--sheet] [--set VALUE | --navigate DIR] [--apply]
    \\                             [--initiator command-shift-g | --initiator slash --save-field SEL]
    \\SEL is ROLE/label/TEXT, ROLE/title/TEXT or ROLE/path/ROLE:INDEX:OF[,ROLE:INDEX:OF...] (at most 4 steps).
    \\ROLE is button, checkbox, popup, text_field, radio, combo_box or disclosure. label matches the accessibility name,
    \\title matches the AXTitleUIElement text, path is a child path with the exact sibling count.
    \\Default is read: the pid, the executable and the modal titled TITLE are matched twice, then the one
    \\control is looked up and printed. --set VALUE sets that control and reads it back. A disclosure triangle
    \\takes expanded, collapsed, 1 or 0, is left alone when it already holds the state and is pressed once
    \\otherwise. --navigate DIR opens
    \\Go to Folder in a standard save panel through one target-pid Command-Shift-G event, enters DIR, presses
    \\the --go button and reads the Where popup. It never presses Save. --sheet looks for --control in the
    \\sheet of the window. --set and --navigate change nothing without --apply. --initiator slash posts one
    \\plain slash key to the target pid instead, and only after --save-field (the exact enabled Save As field) reads
    \\AXFocused true. No focus is set. A missing sheet after the key is an uncertain failure and the key may
    \\have been typed into the Save As field. Command-Shift-G stays the default.
    \\Native route (no System Events): add --native, with --control ROLE/label|id|sibling|path/..., or
    \\--native --native-tree to print the whole window tree. sibling binds an unnamed control to the one static
    \\text before it (popup/sibling/Format:). The title selector is unsupported. A native set needs --set V
    \\--expect-current CUR and, with --apply, --authorize TOKEN, which the plan line authorization_required
    \\prints. Setters: text_field (settable AXValue, one write), checkbox and radio (one AXPress), popup (one
    \\AXPress for the menu and one for the exact item). Other kinds are refused as unsupported. No key is posted.
    \\Exit 0 ok, 1 refused or failed, 2 usage.
    \\
;

/// The lines for the maintainer who wires the command into main.zig.
pub const control_wiring_text =
    \\wiring: main.zig: const native_ui_runtime = @import("native_ui_runtime.zig");
    \\wiring: main.zig rosettaRoute: if (std.mem.eql(u8, cmd, "ui-export-control")) return native_ui_runtime.runExportControlCli;
    \\wiring: main.zig usage: add native_ui_runtime.control_usage_text after the ui-menu entry
    \\
;

const ControlArgs = struct {
    pid: i32 = 0,
    exe: []const u8 = "",
    title: []const u8 = "",
    control: ?[]const u8 = null,
    where: ?[]const u8 = null,
    sheet_field: ?[]const u8 = null,
    go: ?[]const u8 = null,
    set: ?[]const u8 = null,
    navigate: ?[]const u8 = null,
    /// `--initiator`: the key that asks for the Go to Folder sheet. The default is Command-Shift-G.
    initiator: Initiator = .command_shift_g,
    /// `--save-field`: the exact Save As field of the slash initiator.
    save_field: ?[]const u8 = null,
    sheet: bool = false,
    apply: bool = false,
    /// `--native`: read and set through AXUIElement. System Events is never started.
    native: bool = false,
    /// `--native-tree`: print the whole tree of the window with the settable flag. Needs `--native`.
    native_tree: bool = false,
    /// `--expect-current`: the exact value that a native set requires before it acts.
    expect_current: ?[]const u8 = null,
    /// `--authorize`: the token that `plan` printed for this exact change.
    authorize: ?[]const u8 = null,
};

fn parseControlArgs(argv: []const []const u8) union(enum) { ok: ControlArgs, bad: []const u8 } {
    var r: ControlArgs = .{};
    var have_pid = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const k = argv[i];
        if (std.mem.eql(u8, k, "--sheet")) {
            r.sheet = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--apply")) {
            r.apply = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--native")) {
            r.native = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--native-tree")) {
            r.native_tree = true;
            continue;
        }
        i += 1;
        if (i >= argv.len) return .{ .bad = "an option has no value" };
        const v = argv[i];
        if (std.mem.eql(u8, k, "--pid")) {
            r.pid = std.fmt.parseInt(i32, v, 10) catch return .{ .bad = "--pid is not a number" };
            if (r.pid <= 0) return .{ .bad = "--pid must be positive" };
            have_pid = true;
        } else if (std.mem.eql(u8, k, "--expected-executable")) r.exe = v else if (std.mem.eql(u8, k, "--window-title")) r.title = v else if (std.mem.eql(u8, k, "--control")) r.control = v else if (std.mem.eql(u8, k, "--where")) r.where = v else if (std.mem.eql(u8, k, "--sheet-field")) r.sheet_field = v else if (std.mem.eql(u8, k, "--go")) r.go = v else if (std.mem.eql(u8, k, "--set")) r.set = v else if (std.mem.eql(u8, k, "--navigate")) r.navigate = v else if (std.mem.eql(u8, k, "--save-field")) r.save_field = v else if (std.mem.eql(u8, k, "--expect-current")) r.expect_current = v else if (std.mem.eql(u8, k, "--authorize")) r.authorize = v else if (std.mem.eql(u8, k, "--initiator")) {
            if (std.mem.eql(u8, v, "command-shift-g")) r.initiator = .command_shift_g else if (std.mem.eql(u8, v, "slash")) r.initiator = .slash else return .{ .bad = "--initiator is command-shift-g or slash" };
        } else return .{ .bad = "unknown option" };
    }
    if (!have_pid) return .{ .bad = "--pid is required" };
    if (r.exe.len == 0 or r.exe[0] != '/' or hasControl(r.exe)) return .{ .bad = "--expected-executable must be an absolute path" };
    if (!validLabel(r.title, 255)) return .{ .bad = "--window-title is required" };
    const nav_sels = @as(u8, @intFromBool(r.where != null)) + @intFromBool(r.sheet_field != null) + @intFromBool(r.go != null);
    if (r.native_tree and (!r.native or r.control != null or r.set != null or r.navigate != null or nav_sels != 0)) return .{ .bad = "--native-tree needs --native and takes no --control, --set or --navigate" };
    if (r.native and (r.navigate != null or nav_sels != 0 or r.save_field != null)) return .{ .bad = "--native reads and sets one control and has no navigation" };
    if ((r.expect_current != null or r.authorize != null) and !(r.native and r.set != null)) return .{ .bad = "--expect-current and --authorize belong to --native --set" };
    if (r.native_tree) return .{ .ok = r };
    if (r.navigate != null) {
        if (nav_sels != 3 or r.control != null or r.set != null) return .{ .bad = "--navigate takes --where, --sheet-field and --go and no --control or --set" };
    } else if (r.control == null) {
        if (nav_sels == 3) return .{ .bad = "--where, --sheet-field and --go need --navigate DIR" };
        return .{ .bad = "--control is required" };
    } else if (nav_sels != 0) return .{ .bad = "--where, --sheet-field and --go belong to --navigate" };
    if (r.set != null and r.control == null) return .{ .bad = "--set needs --control" };
    if (r.initiator == .slash and (r.navigate == null or r.save_field == null)) return .{ .bad = "--initiator slash needs --navigate and --save-field" };
    if (r.initiator == .command_shift_g and r.save_field != null) return .{ .bad = "--save-field belongs to --initiator slash" };
    return .{ .ok = r };
}

/// `ROLE/label/TEXT`, `ROLE/title/TEXT` or `ROLE/path/ROLE:INDEX:OF,...`.
fn parseSelectorSpec(a: Allocator, spec: []const u8, container: Container) ?Selector {
    var it = std.mem.splitScalar(u8, spec, '/');
    const role = std.meta.stringToEnum(Role, it.next() orelse return null) orelse return null;
    const kind = it.next() orelse return null;
    const text = it.rest();
    if (std.mem.eql(u8, kind, "label")) return .{ .container = container, .role = role, .label = text };
    if (std.mem.eql(u8, kind, "title")) return .{ .container = container, .role = role, .label = text, .via = .title_element };
    if (!std.mem.eql(u8, kind, "path")) return null;
    var steps: std.ArrayList(PathStep) = .empty;
    var sit = std.mem.splitScalar(u8, text, ',');
    while (sit.next()) |s| {
        var p = std.mem.splitScalar(u8, s, ':');
        const r = std.meta.stringToEnum(Role, p.next() orelse return null) orelse return null;
        const idx = std.fmt.parseInt(u8, p.next() orelse return null, 10) catch return null;
        const of = std.fmt.parseInt(u8, p.next() orelse return null, 10) catch return null;
        if (p.next() != null) return null;
        steps.append(a, .{ .role = r, .index = idx, .of = of }) catch return null;
    }
    return .{ .container = container, .role = role, .label = "", .via = .{ .path = steps.items } };
}

pub const ControlDeps = struct {
    backend: Backend,
    env: Env,
    /// Executable path of the pid copied into `buf`. Null when no such process exists.
    pathOf: *const fn (pid: i32, buf: []u8) ?[]const u8,
    /// AX source of `--native`. Null refuses `--native`.
    native: ?nec.Source = null,
};

const native_pid = if (builtin.os.tag == .macos) struct {
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

const ControlGuard = enum { matched, wrong_executable, not_running, modal_absent, modal_ambiguous, not_modal, observe_failed };

/// One read of the identity: the executable of the pid and exactly one window with the title, which is modal.
fn controlGuard(d: ControlDeps, ctx: Ctx, exe: []const u8, title: []const u8) ControlGuard {
    var buf: [4096]u8 = undefined;
    const path = d.pathOf(ctx.pid, &buf) orelse return .not_running;
    if (!std.mem.eql(u8, path, exe)) return .wrong_executable;
    const obs = switch (d.backend.observe(ctx)) {
        .failed => return .observe_failed,
        .observed => |o| o,
    };
    var n: u32 = 0;
    var modal = false;
    for (obs.windows) |w| {
        const t = w.title orelse continue;
        if (!std.mem.eql(u8, t, title)) continue;
        n += 1;
        modal = w.modal orelse false;
    }
    if (n == 0) return .modal_absent;
    if (n > 1) return .modal_ambiguous;
    return if (modal) .matched else .not_modal;
}

/// `expanded` and `1` are 1. `collapsed` and `0` are 0. Anything else is null.
fn disclosureWant(v: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, v, "expanded") or std.mem.eql(u8, v, "1")) return "1";
    if (std.mem.eql(u8, v, "collapsed") or std.mem.eql(u8, v, "0")) return "0";
    return null;
}

fn flat(out: *std.Io.Writer, key: []const u8, v: []const u8) void {
    out.print("{s}\t", .{key}) catch {};
    for (v) |c| out.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c) catch {};
    out.writeByte('\n') catch {};
}

fn printFailure(out: *std.Io.Writer, f: Failure) void {
    flat(out, "failure", @tagName(f.kind));
    flat(out, "detail", f.detail);
    out.print("uncertain\t{}\n", .{f.uncertain}) catch {};
}

fn printLookup(out: *std.Io.Writer, key: []const u8, sel: Selector, r: LookupReply) ?Control {
    switch (r) {
        .failed => |f| {
            flat(out, key, "lookup failed");
            printFailure(out, f);
            return null;
        },
        .found => |c| {
            out.print("{s}\tcount\t{d}\tenabled\t{}\n", .{ key, c.count, c.enabled }) catch {};
            flat(out, "role", sel.role.axRole());
            if (c.value) |v| flat(out, "value", v) else out.writeAll("value\t(unreadable)\n") catch {};
            return c;
        },
    }
}

/// Reads one observation through the same backend as the document gate. It sends no app action.
pub fn runObserveCli(gpa: Allocator, io: std.Io, argv: []const []const u8, out: *std.Io.Writer) u8 {
    defer out.flush() catch {};
    if (argv.len != 3) {
        out.writeAll("usage: vwx ui-runtime-observe PID ABSOLUTE_EXECUTABLE DOCUMENT_TITLE\n") catch {};
        return 2;
    }
    const pid = std.fmt.parseInt(i32, argv[0], 10) catch return 2;
    const expected: ui.ExpectedDocument = .{ .original = argv[2] };
    expected.validate() catch return 2;
    if (pid <= 0 or argv[1].len == 0 or argv[1][0] != '/') return 2;
    var path_buf: [4096]u8 = undefined;
    const path = native_pid.pathOf(pid, &path_buf) orelse return 1;
    if (!std.mem.eql(u8, path, argv[1])) return 1;
    var se: SystemEnv = .{ .io = io };
    var pt: ProcessTransport = .{ .io = io };
    var mac = MacBackend.init(gpa, pt.transport(), se.env(), .{});
    defer mac.deinit();
    const reply = mac.backend().observe(.{ .pid = pid, .expected = expected, .window_title = argv[2], .timeout_ms = 3000 });
    switch (reply) {
        .failed => |failure| {
            std.json.Stringify.value(.{ .failure = failure }, .{ .whitespace = .indent_2 }, out) catch return 1;
            return 1;
        },
        .observed => |observation| {
            const policy: ui.Policy = .{ .expected = expected, .console = .{ .missing_lock_key_is_unlocked = true } };
            std.json.Stringify.value(.{ .observation = observation, .decision = ui.decide(observation, policy) }, .{ .whitespace = .indent_2 }, out) catch return 1;
            out.writeByte('\n') catch return 1;
            return 0;
        },
    }
}

pub fn runExportControlCli(gpa: Allocator, io: std.Io, argv: []const []const u8, out: *std.Io.Writer) u8 {
    if (builtin.os.tag != .macos) return runExportControlWith(gpa, argv, out, null);
    var se: SystemEnv = .{ .io = io };
    var pt: ProcessTransport = .{ .io = io };
    var mac = MacBackend.init(gpa, pt.transport(), se.env(), .{});
    defer mac.deinit();
    var ax = nec.MacSource.init(gpa);
    defer ax.deinit();
    return runExportControlWith(gpa, argv, out, .{ .backend = mac.backend(), .env = se.env(), .pathOf = native_pid.pathOf, .native = ax.source() });
}

/// `vwx ui-export-control`. It reuses `Runtime.navigateSaveDir` and `MacBackend`, so the calibration
/// measures the same code that a route runs. It posts no Save, never presses a button and acts only
/// when `--apply` is present and the modal matched twice and once more right before the action.
pub fn runExportControlWith(gpa: Allocator, argv: []const []const u8, out: *std.Io.Writer, deps: ?ControlDeps) u8 {
    defer out.flush() catch {};
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h") or std.mem.eql(u8, argv[0], "help"))) {
        out.writeAll(control_usage_text) catch {};
        out.writeAll(control_wiring_text) catch {};
        return 0;
    }
    const args = switch (parseControlArgs(argv)) {
        .bad => |why| {
            flat(out, "error", why);
            out.writeAll(control_usage_text) catch {};
            return 2;
        },
        .ok => |r| r,
    };
    const d = deps orelse {
        out.writeAll("error\tui-export-control needs macOS\n") catch {};
        return 1;
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const lim: Limits = .{};
    if (args.native) return runNativeControl(a, args, out, d, lim);

    const win: Container = .{ .window = args.title };
    const ctl_container: Container = if (args.sheet) .{ .window_sheet = args.title } else win;
    var control_sel: ?Selector = null;
    var nav: ?SavePanelDir = null;
    if (args.control) |c| {
        const sel = parseSelectorSpec(a, c, ctl_container) orelse {
            flat(out, "error", "--control is not ROLE/label|title|path/...");
            return 2;
        };
        validateSelector(sel, null, lim) catch {
            flat(out, "error", "--control selector is invalid");
            return 2;
        };
        control_sel = sel;
    } else {
        const sheet_c: Container = .{ .window_sheet = args.title };
        const w = parseSelectorSpec(a, args.where.?, win);
        const f = parseSelectorSpec(a, args.sheet_field.?, sheet_c);
        const g = parseSelectorSpec(a, args.go.?, sheet_c);
        if (w == null or f == null or g == null) {
            flat(out, "error", "a navigation selector is not ROLE/label|title|path/...");
            return 2;
        }
        var sp: SavePanelDir = .{ .where = w.?, .sheet_field = f.?, .go = g.?, .initiator = args.initiator };
        var probe_name: Selector = .{ .container = win, .role = .text_field, .label = "x" };
        if (args.save_field) |sf| {
            const ff = parseSelectorSpec(a, sf, win) orelse {
                flat(out, "error", "--save-field is not ROLE/label|title|path/...");
                return 2;
            };
            sp.focus_field = ff;
            probe_name = ff;
        }
        const probe: DestinationStep = .{ .name_field = probe_name, .save_panel = sp };
        validateRoute(.{ .id = "calibration", .format = .pdf, .steps = &.{ .{ .menu = &.{ "File", "Export" } }, .{ .destination = probe }, .{ .confirm = .{ .container = win, .role = .button, .label = "x" } } }, .binding = bind_placeholder }, .calibration, lim) catch {
            flat(out, "error", "the navigation selectors do not form a valid save panel mechanism");
            return 2;
        };
        nav = sp;
    }
    if (args.navigate) |dir| {
        if (dir.len < 2 or dir[0] != '/' or hasControl(dir) or dir.len > lim.max_text) {
            flat(out, "error", "--navigate needs an absolute directory path");
            return 2;
        }
    }
    if (args.set) |v| {
        const sel = control_sel.?;
        const val: OptionValue = switch (sel.role) {
            .checkbox, .radio => if (std.mem.eql(u8, v, "1")) .{ .checked = true } else if (std.mem.eql(u8, v, "0")) .{ .checked = false } else {
                flat(out, "error", "a checkbox or radio takes 1 or 0");
                return 2;
            },
            .disclosure => if (disclosureWant(v)) |w| .{ .checked = std.mem.eql(u8, w, "1") } else {
                flat(out, "error", "a disclosure triangle takes expanded, collapsed, 1 or 0");
                return 2;
            },
            .popup => .{ .choice = v },
            .text_field, .combo_box => .{ .text = v },
            .button => {
                flat(out, "error", "this command presses no button");
                return 2;
            },
        };
        validateValue(sel, val, lim) catch {
            flat(out, "error", "the value does not fit the role");
            return 2;
        };
    }

    const pol: ui.Policy = .{ .expected = .{ .original = "calibration.vwx" } };
    const ctx: Ctx = .{ .pid = args.pid, .expected = pol.expected, .window_title = args.title, .timeout_ms = lim.call_timeout_ms };
    out.print("pid\t{d}\n", .{args.pid}) catch {};
    flat(out, "expected_executable", args.exe);
    flat(out, "window_title", args.title);
    flat(out, "mode", if (args.set != null) "set" else if (args.navigate != null) "navigate" else "read");
    out.print("apply\t{}\n", .{args.apply}) catch {};

    // The modal is matched twice before anything is read.
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        const g = controlGuard(d, ctx, args.exe, args.title);
        out.print("guard\t{d}\t{s}\n", .{ pass + 1, @tagName(g) }) catch {};
        if (g != .matched) {
            out.writeAll("result\trefused\n") catch {};
            return 1;
        }
    }

    if (nav) |sp| {
        flat(out, "initiator", if (sp.initiator == .slash) "slash" else "command-shift-g");
        // Read first: the Where popup as it stands.
        const before = printLookup(out, "where_before", sp.where, d.backend.lookup(ctx, sp.where));
        if (before == null or before.?.count != 1) {
            out.writeAll("result\trefused\n") catch {};
            return 1;
        }
        if (sp.focus_field) |ff| {
            // Read only: the exact Save As field and its focus state, with or without --apply.
            const fl = printLookup(out, "save_field", ff, d.backend.lookup(ctx, ff));
            if (fl == null or fl.?.count != 1 or !fl.?.enabled) {
                flat(out, "refused", "the Save As field is not exactly one enabled control");
                out.writeAll("result\trefused\n") catch {};
                return 1;
            }
            switch (d.backend.focused(ctx, ff)) {
                .failed => |f| {
                    flat(out, "save_field_focused", "unreadable");
                    printFailure(out, f);
                    out.writeAll("result\trefused\n") catch {};
                    return 1;
                },
                .focused => |on| {
                    flat(out, "save_field_focused", if (on) "true" else "false");
                    if (!on) {
                        flat(out, "refused", "the Save As field does not hold the keyboard focus. No key was posted");
                        out.writeAll("result\trefused\n") catch {};
                        return 1;
                    }
                },
            }
        }
        const dir = args.navigate.?;
        if (!args.apply) {
            flat(out, "plan", "navigate to the directory; nothing was changed because --apply is absent");
            flat(out, "want_where_value", Runtime.dirBase(dir));
            out.writeAll("result\tok\n") catch {};
            return 0;
        }
        const g = controlGuard(d, ctx, args.exe, args.title);
        out.print("guard\trecheck\t{s}\n", .{@tagName(g)}) catch {};
        if (g != .matched) {
            out.writeAll("result\trefused\n") catch {};
            return 1;
        }
        var rt = Runtime.init(gpa, d.backend, d.env, no_files, lim);
        var op = rt.newOp(args.pid, pol);
        _ = op.setTitle(args.title);
        var b: Builder = .{};
        defer b.deinit(gpa);
        const fail = rt.navigateSaveDir(&op, &b, sp, dir, false);
        for (b.options.items) |o| {
            flat(out, "step", o.label);
            flat(out, "requested", o.requested);
            flat(out, "observed", o.observed);
        }
        if (fail) |f| {
            printFailure(out, f);
            flat(out, "note", if (sp.initiator == .slash) "the Go to Folder sheet may still be open, or a slash may have been typed into the Save As field. Nothing was saved" else "the Go to Folder sheet may still be open. Nothing was saved");
            out.writeAll("result\tfailed\n") catch {};
            return 1;
        }
        flat(out, "want_where_value", Runtime.dirBase(dir));
        out.writeAll("result\tok\n") catch {};
        return 0;
    }

    const sel = control_sel.?;
    const found = printLookup(out, "control", sel, d.backend.lookup(ctx, sel));
    if (found == null or found.?.count != 1) {
        out.writeAll("result\trefused\n") catch {};
        return 1;
    }
    const want_arg = args.set orelse {
        out.writeAll("result\tok\n") catch {};
        return 0;
    };
    const want = if (sel.role == .disclosure) disclosureWant(want_arg).? else want_arg;
    // A control that already holds the requested state is left alone, with or without --apply.
    if (sel.role == .disclosure and valueEquals(found.?.value orelse "", want)) {
        flat(out, "unchanged", "the control already holds the requested state. Nothing was pressed");
        out.writeAll("result\tok\n") catch {};
        return 0;
    }
    if (!args.apply) {
        flat(out, "plan", "set the control; nothing was changed because --apply is absent");
        out.writeAll("result\tok\n") catch {};
        return 0;
    }
    if (!found.?.enabled) {
        flat(out, "refused", "the control is disabled");
        out.writeAll("result\trefused\n") catch {};
        return 1;
    }
    const g = controlGuard(d, ctx, args.exe, args.title);
    out.print("guard\trecheck\t{s}\n", .{@tagName(g)}) catch {};
    if (g != .matched) {
        out.writeAll("result\trefused\n") catch {};
        return 1;
    }
    const val: OptionValue = switch (sel.role) {
        .checkbox, .radio, .disclosure => .{ .checked = std.mem.eql(u8, want, "1") },
        .popup => .{ .choice = want },
        else => .{ .text = want },
    };
    var set_same = false;
    switch (d.backend.setValue(ctx, sel, val)) {
        .failed => |f| {
            printFailure(out, f);
            out.writeAll("result\tfailed\n") catch {};
            return 1;
        },
        .done => |v| {
            flat(out, "set_readback", v orelse "(none)");
            set_same = v != null and (if (sel.role == .disclosure) valueEquals(v.?, want) else std.mem.eql(u8, v.?, want));
        },
    }
    if (sel.role == .disclosure and !set_same) {
        // One press ran. The triangle may report its new value a moment later: read only, no second press.
        switch (awaitValue(d.backend, d.env, ctx, sel, want, lim.dialog_wait_ms, lim)) {
            .failed => |f| {
                printFailure(out, f);
                out.writeAll("result\tfailed\n") catch {};
                return 1;
            },
            .matched => |v| {
                flat(out, "set_readback_after_wait", v);
                set_same = true;
            },
            .timed_out => |v| flat(out, "set_readback_after_wait", if (v.len == 0) "(unreadable)" else v),
        }
    }
    // Both reads must show the request: the value that the set returned and a fresh lookup.
    const after = printLookup(out, "control_after", sel, d.backend.lookup(ctx, sel));
    const same = set_same and after != null and after.?.count == 1 and after.?.value != null and (if (sel.role == .disclosure) valueEquals(after.?.value.?, want) else std.mem.eql(u8, after.?.value.?, want));
    flat(out, "readback_matches_request", if (same) "yes" else "no");
    out.writeAll(if (same) "result\tok\n" else "result\tfailed\n") catch {};
    return if (same) 0 else 1;
}

const NativeGate = struct {
    d: ControlDeps,
    ctx: Ctx,
    exe: []const u8,
    title: []const u8,

    fn check(p: *anyopaque) bool {
        const g: *NativeGate = @ptrCast(@alignCast(p));
        return controlGuard(g.d, g.ctx, g.exe, g.title) == .matched;
    }

    fn pause(p: *anyopaque, ms: u32) void {
        const g: *NativeGate = @ptrCast(@alignCast(p));
        g.d.env.sleep(ms);
    }
};

/// `--native`: the read and the set go through `native_export_controls`. The document gate (executable,
/// one modal window with the title) is matched twice before the read, like the System Events route, and
/// again right before the action. System Events is not started.
fn runNativeControl(a: Allocator, args: ControlArgs, out: *std.Io.Writer, d: ControlDeps, lim: Limits) u8 {
    const src = d.native orelse {
        flat(out, "error", "the native AX source is not available on this platform");
        return 1;
    };
    var req: nec.Request = .{
        .pid = args.pid,
        .exe = args.exe,
        .title = args.title,
        .mode = if (args.native_tree) .tree else if (args.set != null) .set else .read,
        .control = args.control,
        .expect_current = args.expect_current,
        .authorize = args.authorize,
        .apply = args.apply,
        .sheet = args.sheet,
    };
    if (args.control) |c| {
        const spec = switch (nec.parseSpec(a, c)) {
            .bad => |why| {
                flat(out, "error", why);
                return 2;
            },
            .unsupported => |why| {
                flat(out, "unsupported", why);
                out.writeAll("result\trefused\n") catch {};
                return 1;
            },
            .ok => |s| s,
        };
        if (args.set) |v| {
            const sel: Selector = .{ .container = .{ .window = args.title }, .role = spec.role, .label = "x" };
            const val: OptionValue = switch (spec.role) {
                .checkbox, .radio => if (std.mem.eql(u8, v, "1")) .{ .checked = true } else if (std.mem.eql(u8, v, "0")) .{ .checked = false } else {
                    flat(out, "error", "a checkbox or radio takes 1 or 0");
                    return 2;
                },
                .popup => .{ .choice = v },
                .text_field, .combo_box => .{ .text = v },
                .disclosure => .{ .checked = false },
                .button => {
                    flat(out, "error", "this command presses no button");
                    return 2;
                },
            };
            validateValue(sel, val, lim) catch {
                flat(out, "error", "the value does not fit the role");
                return 2;
            };
            req.want = v;
        }
    }
    const pol: ui.Policy = .{ .expected = .{ .original = "calibration.vwx" } };
    const ctx: Ctx = .{ .pid = args.pid, .expected = pol.expected, .window_title = args.title, .timeout_ms = lim.call_timeout_ms };
    out.print("pid\t{d}\n", .{args.pid}) catch {};
    flat(out, "expected_executable", args.exe);
    flat(out, "window_title", args.title);
    flat(out, "mode", if (args.native_tree) "native-tree" else if (args.set != null) "native-set" else "native-read");
    out.print("apply\t{}\n", .{args.apply}) catch {};
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        const g = controlGuard(d, ctx, args.exe, args.title);
        out.print("guard\t{d}\t{s}\n", .{ pass + 1, @tagName(g) }) catch {};
        if (g != .matched) {
            out.writeAll("result\trefused\n") catch {};
            return 1;
        }
    }
    var gate: NativeGate = .{ .d = d, .ctx = ctx, .exe = args.exe, .title = args.title };
    return nec.run(a, out, req, src, d.pathOf, .{ .ptr = &gate, .checkFn = NativeGate.check, .pauseFn = NativeGate.pause });
}

const bind_placeholder: Binding =.{ .release = "calibration", .workspace = "calibration", .profile_hash = "0" ** 64, .source_digest = "0" ** 64, .state_digest = "0" ** 64 };

const no_files: Files = .{ .ptr = undefined, .sizeFn = noSize, .listFn = noList };

fn noSize(p: *anyopaque, path: []const u8) ?u64 {
    _ = .{ p, path };
    return null;
}

fn noList(p: *anyopaque, a: Allocator, dir: []const u8, max: usize) ?[][]u8 {
    _ = .{ p, a, dir, max };
    return null;
}

// Features

pub const Feature = struct {
    name: []const u8,
    implemented: bool,
    /// True only when a real macOS run executed the branch. Always false in this offline revision.
    executed_on_macos: bool,
    note: []const u8,
};

/// Public description of the runtime for later wiring. Nothing here claims that a trial route works.
pub const features = [_]Feature{
    .{ .name = "console_process_window_modal_observation", .implemented = true, .executed_on_macos = false, .note = "stat, id, ioreg and one System Events snapshot per call" },
    .{ .name = "known_notice_acknowledgement", .implemented = true, .executed_on_macos = false, .note = "default OK of the exact conversion or watermark notice, re-verified by the click script" },
    .{ .name = "export_menu_navigation", .implemented = true, .executed_on_macos = false, .note = "File then Export, labels passed as argv" },
    .{ .name = "exact_control_lookup", .implemented = true, .executed_on_macos = false, .note = "exact role and name inside one window or sheet" },
    .{ .name = "option_set_with_read_back", .implemented = true, .executed_on_macos = false, .note = "checkbox, radio, popup and text field" },
    .{ .name = "destination_entry_and_confirmation", .implemented = true, .executed_on_macos = false, .note = "route supplies the name and directory fields" },
    .{ .name = "progress_and_completion_observation", .implemented = true, .executed_on_macos = false, .note = "progress indicator, dialog presence and stable primary file size" },
    .{ .name = "window_targeted_screenshot", .implemented = true, .executed_on_macos = false, .note = "needs AXWindowNumber, fails with screenshot_unavailable otherwise" },
    .{ .name = "subprocess_transport_with_deadline", .implemented = true, .executed_on_macos = true, .note = "tested with sh, sleep and yes" },
    .{ .name = "nested_sidecar_enumeration", .implemented = true, .executed_on_macos = false, .note = "bounded recursive listing without following links, relative sidecar paths, no dependency closure" },
    .{ .name = "targeted_format_inventory", .implemented = true, .executed_on_macos = false, .note = "sat, usd, iges, 3dm and ifc routes run inventory and calibration only" },
    .{ .name = "route_calibration", .implemented = false, .executed_on_macos = false, .note = "no route is calibrated" },
};

pub const supported_formats = required_formats;
pub const supported_phases = [_]Phase{ .inventory, .calibration, .verified };

/// Writes the feature list, formats, phases and default limits as plain lines.
pub fn writeFeatures(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("module native_ui_runtime\n");
    try w.writeAll("routes calibrated 0\n");
    try w.writeAll("verified_phase requires calibrated status, evidence and matching binding\n");
    for (features) |f| try w.print("feature {s} implemented={} executed_on_macos={}\n", .{ f.name, f.implemented, f.executed_on_macos });
    for (supported_formats) |f| try w.print("format {s}\n", .{formatId(f)});
    for (targeted_formats) |f| try w.print("targeted_format {s}\n", .{formatId(f)});
    try w.writeAll("dependency_closure not_established\n");
    for (supported_phases) |p| try w.print("phase {s}\n", .{@tagName(p)});
    const l: Limits = .{};
    try w.print("limits steps={d} call_timeout_ms={d} op_deadline_ms={d} run_deadline_ms={d} poll_ms={d} stdout={d} stderr={d}\n", .{ l.max_steps, l.call_timeout_ms, l.op_deadline_ms, l.run_deadline_ms, l.poll_ms, l.max_stdout, l.max_stderr });
}

// Tests

const testing = std.testing;

const orig = "clock-ClocKit_standard_shafts.vwx";
const conv = "clock-ClocKit_standard_shafts_v2027.vwx";
const conv_title = conv ++ " - WATERMARKED FILE";
const valid_registry = "\"IOConsoleUsers\"=({\"kCGSSessionOnConsoleKey\"=Yes,\"kCGSessionLoginDoneKey\"=Yes,\"kCGSSessionUserNameKey\"=\"someone\"})";
const ready_console: ui.ConsoleObservation = .{ .owner = "someone", .user = "someone", .registry = valid_registry ++ "\"CGSSessionScreenIsLocked\"=No" };
const locked_console: ui.ConsoleObservation = .{ .owner = "someone", .user = "someone", .registry = valid_registry ++ "\"CGSSessionScreenIsLocked\"=Yes" };

const bind: Binding = .{
    .release = "Vectorworks 2027 trial",
    .workspace = "Design Suite",
    .profile_hash = "a" ** 64,
    .source_digest = "b" ** 64,
    .state_digest = "c" ** 64,
};

fn sheet(role: Role, label: []const u8) Selector {
    return .{ .container = .document_sheet, .role = role, .label = label };
}

const s_materials = sheet(.checkbox, "Export Materials");
const s_quality = sheet(.popup, "Quality");
const s_scale = sheet(.text_field, "Scale");
const s_name = sheet(.text_field, "Save As:");
const s_where = sheet(.text_field, "Where:");
const s_save = sheet(.button, "Save");

const sp_win = "Export as PDF Document";
const sp_name_path = [_]PathStep{.{ .role = .text_field, .index = 1, .of = 2 }};
const sp_name: Selector = .{ .container = .{ .window = sp_win }, .role = .text_field, .label = "", .via = .{ .path = &sp_name_path } };
const sp_where: Selector = .{ .container = .{ .window = sp_win }, .role = .popup, .label = "Where:", .via = .title_element };
const sp_field: Selector = .{ .container = .{ .window_sheet = sp_win }, .role = .text_field, .label = "Go to the folder:", .via = .title_element };
const sp_go: Selector = .{ .container = .{ .window_sheet = sp_win }, .role = .button, .label = "Go" };
const sp_save: Selector = .{ .container = .{ .window = sp_win }, .role = .button, .label = "Save" };
const sp_dir: SavePanelDir = .{ .where = sp_where, .sheet_field = sp_field, .go = sp_go };
const sp_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export PDF" } },
    .{ .destination = .{ .name_field = sp_name, .save_panel = sp_dir } },
    .{ .confirm = sp_save },
};
const sp_route: Route = .{ .id = "save-panel", .format = .obj, .steps = &sp_steps, .cancel = s_cancel, .progress = true, .progress_id = "export-progress", .binding = bind };
const s_cancel = sheet(.button, "Cancel");

const obj_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export OBJ" } },
    .{ .option = .{ .selector = s_materials, .value = .{ .checked = true } } },
    .{ .option = .{ .selector = s_quality, .value = .{ .choice = "High" } } },
    .{ .option = .{ .selector = s_scale, .value = .{ .text = "1.0" } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};

const obj_route: Route = .{ .id = "obj-default", .format = .obj, .steps = &obj_steps, .cancel = s_cancel, .progress = true, .progress_id = "export-progress", .binding = bind };
const obj_outputs: ExpectedOutputs = .{ .primary = "model.obj", .required_sidecars = &.{"model.mtl"}, .allowed_sidecar_exts = &.{".png"} };

fn calibrated(r: Route) Route {
    var c = r;
    c.status = .calibrated;
    c.evidence = .{ .calibration_id = "cal-001", .binding = r.binding };
    return c;
}

const FakeEnv = struct {
    t: u64 = 1_000_000_000,
    tick: u64 = 1_000,
    slept_ms: u64 = 0,
    sleeps: [96]u32 = undefined,
    sleep_n: usize = 0,

    fn env(f: *FakeEnv) Env {
        return .{ .ptr = f, .nowFn = nowImpl, .sleepFn = sleepImpl };
    }
    fn nowImpl(ptr: *anyopaque) u64 {
        const f: *FakeEnv = @ptrCast(@alignCast(ptr));
        f.t += f.tick;
        return f.t;
    }
    fn sleepImpl(ptr: *anyopaque, ms: u32) void {
        const f: *FakeEnv = @ptrCast(@alignCast(ptr));
        f.t += @as(u64, ms) * std.time.ns_per_ms;
        f.slept_ms += ms;
        if (f.sleep_n < f.sleeps.len) f.sleeps[f.sleep_n] = ms;
        f.sleep_n += 1;
    }
};

const Call = enum { observe, ack, menu, identity, lookup, set, press, progress, screenshot, chord, focus, dismiss };

const SimCtl = struct {
    role: Role,
    label: []const u8,
    /// For a control whose own name is empty: the text of its title element, or its exact path.
    title_el: []const u8 = "",
    path: []const PathStep = &.{},
    /// True for a control inside the Go to Folder sheet.
    in_sheet: bool = false,
    /// Ignores every set, like a control that does not react to the press.
    stuck: bool = false,
    /// A set takes effect after this many lookups. Until then the old value reads back.
    lag: u32 = 0,
    pending: [8]u8 = undefined,
    pending_len: usize = 0,
    pending_n: u32 = 0,
    count: u16 = 1,
    enabled: bool = true,
    value: [96]u8 = undefined,
    value_len: usize = 0,
    readback_override: ?[]const u8 = null,

    fn setValue(c: *SimCtl, v: []const u8) void {
        @memcpy(c.value[0..v.len], v);
        c.value_len = v.len;
    }
};

/// Fake backend and file system with scripted behavior and failure injection.
const SimEntry = struct {
    path: []const u8,
    kind: EntryKind = .file,
    size: u64 = 10,
    nlink: u64 = 1,
};

const SizeStep = struct { at_ms: u64, size: u64 };

const Sim = struct {
    console: ui.ConsoleObservation = ready_console,
    pid_alive: bool = true,
    doc_title: ?[]const u8 = conv_title,
    extra: []const ui.WindowObservation = &.{},
    seq: []const []const ui.WindowObservation = &.{},
    seq_i: usize = 0,
    complete_until: u32 = std.math.maxInt(u32),
    incomplete_first: u32 = 0,
    complete_seq: []const bool = &.{},
    ctls: [16]SimCtl = undefined,
    ctl_n: usize = 0,
    dialog_open: bool = false,
    layout: u64 = 7,
    confirmed: bool = false,
    polls: u32 = 0,
    complete_after: u32 = 3,
    never_complete: bool = false,
    out_names: []const []const u8 = &.{ "model.obj", "model.mtl" },
    out_sizes: []const u64 = &.{ 1200, 80 },
    extra_files: []const []const u8 = &.{},
    progress_seq: []const u32 = &.{ 250, 500, 1000 },
    progress_i: usize = 0,
    dir_missing: bool = false,
    dir_dirty: bool = false,
    shot_made: bool = false,
    fail_call: ?Call = null,
    fail_nth: u32 = 1,
    fail: Failure = .{ .kind = .transport_error, .detail = "injected", .uncertain = true },
    counts: [12]u32 = [_]u32{0} ** 12,
    /// The button of the last dialog press that reached the fake.
    last_dismiss_button: []const u8 = "",
    /// The exact Save As field holds the keyboard focus.
    save_field_focused: bool = true,
    /// The slash key opens the sheet. False models a panel that ignores it.
    slash_opens: bool = true,
    last_chord: ?Chord = null,
    focus_at: u32 = 0,
    /// The Go to Folder sheet of a standard save panel is open.
    go_open: bool = false,
    /// A press on the notice removes the extra windows.
    ack_clears: bool = false,
    last_ack_exact: bool = false,
    /// Sheet lookups that still find no sheet after the key was posted.
    sheet_lag: u32 = 0,
    /// The panel keeps the sheet open after Go, as it does for a path that it rejects.
    reject_path: bool = false,
    /// The Where popup does not follow the sheet.
    where_frozen: bool = false,
    /// Keys posted to the pid, in order.
    chord_order: u32 = 0,
    go_pressed_at: u32 = 0,
    chord_at: u32 = 0,
    wbuf: [8]ui.WindowObservation = undefined,
    last_menu_len: usize = 0,
    walk_list: []const SimEntry = &.{},
    walk_fail: bool = false,
    /// Lookups inside the dialog that report no control before it shows up.
    late_lookups: u32 = 0,
    /// Presses seen when the last screenshot ran.
    presses_at_shot: u32 = 99,
    diag_shots: u32 = 0,
    /// A progress value that is on screen before the press and never changes.
    stale_progress: ?u32 = null,
    /// The identity of the readings that the fake reports. A route that names another one ignores them.
    progress_id: []const u8 = "export-progress",
    stale_id: []const u8 = "export-progress",
    /// Output sizes follow the fake clock. The dialog closes at the press. `steps` gives the size of
    /// model.obj and `side_ms` the time at which model.mtl appears, both after the press.
    timed: bool = false,
    clock: ?*FakeEnv = null,
    confirm_t: u64 = 0,
    steps: []const SizeStep = &.{},
    side_ms: u64 = 0,

    fn addCtl(s: *Sim, role: Role, label: []const u8, initial: []const u8) void {
        s.ctls[s.ctl_n] = .{ .role = role, .label = label };
        s.ctls[s.ctl_n].setValue(initial);
        s.ctl_n += 1;
    }

    fn standardControls(s: *Sim) void {
        s.addCtl(.checkbox, "Export Materials", "0");
        s.addCtl(.popup, "Quality", "Low");
        s.addCtl(.text_field, "Scale", "");
        s.addCtl(.text_field, "Save As:", "");
        s.addCtl(.text_field, "Where:", "");
        s.addCtl(.button, "Save", "");
        s.addCtl(.button, "Cancel", "");
    }

    fn n(s: *const Sim, c: Call) u32 {
        return s.counts[@intFromEnum(c)];
    }

    fn mutations(s: *const Sim) u32 {
        return s.n(.ack) + s.n(.menu) + s.n(.set) + s.n(.press) + s.n(.chord);
    }

    fn addRaw(s: *Sim, c: SimCtl, initial: []const u8) void {
        s.ctls[s.ctl_n] = c;
        s.ctls[s.ctl_n].setValue(initial);
        s.ctl_n += 1;
    }

    /// The controls that the observed standard save panel exposes: an unnamed filename field, a Where
    /// popup that carries its title, and the Go to Folder sheet with an unnamed path field.
    fn savePanelControls(s: *Sim) void {
        s.addRaw(.{ .role = .text_field, .label = "", .path = &sp_name_path }, "");
        s.addRaw(.{ .role = .popup, .label = "", .title_el = "Where:" }, "Documents");
        s.addRaw(.{ .role = .text_field, .label = "", .title_el = "Go to the folder:", .in_sheet = true }, "");
        s.addRaw(.{ .role = .button, .label = "Go", .in_sheet = true }, "");
        s.addCtl(.button, "Save", "");
        s.addCtl(.button, "Cancel", "");
    }

    fn total(s: *const Sim) u32 {
        var t: u32 = 0;
        for (s.counts) |c| t += c;
        return t;
    }

    fn enter(s: *Sim, c: Call) ?Failure {
        s.counts[@intFromEnum(c)] += 1;
        if (!s.pid_alive) return .{ .kind = .process_lost, .detail = "process is not running" };
        if (s.fail_call) |fc| if (fc == c and s.counts[@intFromEnum(c)] == s.fail_nth) return s.fail;
        return null;
    }

    fn timedSize(s: *const Sim, name: []const u8) ?u64 {
        const el = ((s.clock.?.t) -| s.confirm_t) / std.time.ns_per_ms;
        if (std.mem.eql(u8, name, "model.obj")) {
            var r: ?u64 = null;
            for (s.steps) |st| if (el >= st.at_ms) {
                r = st.size;
            };
            return r;
        }
        if (std.mem.eql(u8, name, "model.mtl")) return if (el >= s.side_ms) 80 else null;
        return null;
    }

    fn complete(s: *const Sim) bool {
        if (s.timed) return s.confirmed;
        return s.confirmed and !s.never_complete and s.polls >= s.complete_after;
    }

    fn find(s: *Sim, sel: Selector) ?*SimCtl {
        const sheet_sel = sel.container == .window_sheet;
        for (s.ctls[0..s.ctl_n]) |*c| {
            if (c.role != sel.role or c.in_sheet != sheet_sel) continue;
            const hit = switch (sel.via) {
                .name => c.label.len > 0 and std.mem.eql(u8, c.label, sel.label),
                .title_element => c.title_el.len > 0 and std.mem.eql(u8, c.title_el, sel.label),
                .path => |p| c.path.len > 0 and viaEql(.{ .path = c.path }, .{ .path = p }),
            };
            if (hit) return c;
        }
        return null;
    }

    fn whereCtl(s: *Sim) *SimCtl {
        for (s.ctls[0..s.ctl_n]) |*c| if (c.role == .popup and std.mem.eql(u8, c.title_el, "Where:")) return c;
        unreachable;
    }

    fn backend(s: *Sim) Backend {
        return .{
            .ptr = s,
            .observeFn = observeImpl,
            .acknowledgeFn = ackImpl,
            .menuFn = menuImpl,
            .identityFn = identityImpl,
            .lookupFn = lookupImpl,
            .setValueFn = setImpl,
            .pressFn = pressImpl,
            .progressFn = progressImpl,
            .screenshotFn = shotImpl,
            .chordFn = chordImpl,
            .focusedFn = focusedImpl,
            .dismissFn = dismissImpl,
        };
    }

    fn dismissImpl(p: *anyopaque, ctx: Ctx, req: DismissRequest) ActionReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.dismiss)) |f| return .{ .failed = f };
        s.last_dismiss_button = req.button;
        return .{ .done = null };
    }

    fn chordImpl(p: *anyopaque, ctx: Ctx, window_title: []const u8, chord: Chord) ActionReply {
        _ = .{ ctx, window_title };
        const s = me(p);
        if (s.enter(.chord)) |f| return .{ .failed = f };
        if (!s.dialog_open) return .{ .failed = .{ .kind = .refused, .detail = "window is absent" } };
        s.chord_order += 1;
        s.chord_at = s.chord_order;
        s.last_chord = chord;
        // The event is dispatched. A panel that ignores a slash does not open the sheet.
        if (chord == .slash and !s.slash_opens) return .{ .done = null };
        s.go_open = true;
        s.layout += 1;
        return .{ .done = null };
    }

    fn focusedImpl(p: *anyopaque, ctx: Ctx, sel: Selector) FocusReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.focus)) |f| return .{ .failed = f };
        s.chord_order += 1;
        s.focus_at = s.chord_order;
        const c = s.find(sel) orelse return .{ .failed = .{ .kind = .unknown_ui, .detail = "target control is absent" } };
        if (c.count != 1) return .{ .failed = .{ .kind = .ambiguous_target, .detail = "more than one control matches" } };
        return .{ .focused = s.save_field_focused };
    }

    fn files(s: *Sim) Files {
        return .{ .ptr = s, .sizeFn = sizeImpl, .listFn = listImpl };
    }

    fn me(p: *anyopaque) *Sim {
        return @ptrCast(@alignCast(p));
    }

    fn observeImpl(p: *anyopaque, ctx: Ctx) ObserveReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.observe)) |f| return .{ .failed = f };
        if (s.confirmed) s.polls += 1;
        var wins: []const ui.WindowObservation = undefined;
        if (s.seq.len > 0) {
            wins = s.seq[@min(s.seq_i, s.seq.len - 1)];
            s.seq_i += 1;
        } else {
            var k: usize = 0;
            if (s.doc_title) |t| {
                s.wbuf[k] = .{ .title = t, .modal = false };
                k += 1;
            }
            for (s.extra) |e| {
                s.wbuf[k] = e;
                k += 1;
            }
            wins = s.wbuf[0..k];
        }
        const windows_complete = if (s.complete_seq.len > 0) s.complete_seq[@min(s.n(.observe) - 1, s.complete_seq.len - 1)] else s.n(.observe) > s.incomplete_first and s.n(.observe) <= s.complete_until;
        return .{ .observed = .{ .console = s.console, .windows = wins, .windows_complete = windows_complete } };
    }

    fn ackImpl(p: *anyopaque, ctx: Ctx, req: AckRequest) ActionReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.ack)) |f| return .{ .failed = f };
        s.last_ack_exact = req.exact_notice;
        // The notice goes away when its button is pressed.
        if (s.ack_clears) s.extra = &.{};
        return .{ .done = null };
    }

    fn menuImpl(p: *anyopaque, ctx: Ctx, path: []const []const u8) ActionReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.menu)) |f| return .{ .failed = f };
        s.last_menu_len = path.len;
        s.dialog_open = true;
        s.layout += 1;
        return .{ .done = null };
    }

    fn identityImpl(p: *anyopaque, ctx: Ctx, container: Container) IdentityReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.identity)) |f| return .{ .failed = f };
        if (container == .window_sheet) return if (s.go_open and s.sheet_lag == 0) .{ .present = s.layout } else .absent;
        if (!s.dialog_open or s.complete()) return .absent;
        return .{ .present = s.layout };
    }

    fn lookupImpl(p: *anyopaque, ctx: Ctx, sel: Selector) LookupReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.lookup)) |f| return .{ .failed = f };
        if (!s.dialog_open) return .{ .found = .{ .count = 0, .layout_id = s.layout } };
        if (sel.container == .window_sheet and s.go_open and s.sheet_lag > 0) {
            s.sheet_lag -= 1;
            return .{ .failed = refusalFailure("window_absent") };
        }
        if (sel.container == .window_sheet and !s.go_open) return .{ .failed = refusalFailure("window_absent") };
        if (s.late_lookups > 0) {
            s.late_lookups -= 1;
            return .{ .found = .{ .count = 0, .layout_id = s.layout } };
        }
        const c = s.find(sel) orelse return .{ .found = .{ .count = 0, .layout_id = s.layout } };
        if (c.pending_n > 0) {
            c.pending_n -= 1;
            if (c.pending_n == 0) c.setValue(c.pending[0..c.pending_len]);
        }
        return .{ .found = .{ .count = c.count, .layout_id = s.layout, .value = c.value[0..c.value_len], .enabled = c.enabled } };
    }

    fn setImpl(p: *anyopaque, ctx: Ctx, sel: Selector, value: OptionValue) ActionReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.set)) |f| return .{ .failed = f };
        const c = s.find(sel) orelse return .{ .failed = .{ .kind = .unknown_ui, .detail = "no such control" } };
        if (c.stuck) return .{ .done = c.value[0..c.value_len] };
        if (c.lag > 0 and value == .checked) {
            const t: []const u8 = if (value.checked) "1" else "0";
            @memcpy(c.pending[0..t.len], t);
            c.pending_len = t.len;
            c.pending_n = c.lag;
            return .{ .done = c.value[0..c.value_len] };
        }
        switch (value) {
            .checked => |b| c.setValue(if (b) "1" else "0"),
            .choice => |t| c.setValue(t),
            .text => |t| c.setValue(t),
        }
        return .{ .done = c.readback_override orelse c.value[0..c.value_len] };
    }

    fn pressImpl(p: *anyopaque, ctx: Ctx, sel: Selector) ActionReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.press)) |f| return .{ .failed = f };
        if (s.find(sel) == null) return .{ .failed = .{ .kind = .unknown_ui, .detail = "no such control" } };
        if (sel.container == .window_sheet and std.mem.eql(u8, sel.label, "Go")) {
            s.chord_order += 1;
            s.go_pressed_at = s.chord_order;
            if (s.reject_path) return .{ .done = null };
            var field: []const u8 = "";
            for (s.ctls[0..s.ctl_n]) |*c| if (c.in_sheet and c.role == .text_field) {
                field = c.value[0..c.value_len];
            };
            s.go_open = false;
            s.layout += 1;
            if (!s.where_frozen) s.whereCtl().setValue(std.mem.trimEnd(u8, field[std.mem.lastIndexOfScalar(u8, field, '/').? + 1 ..], "/"));
        } else if (std.mem.eql(u8, sel.label, "Save")) {
            s.confirmed = true;
            if (s.clock) |c| s.confirm_t = c.t;
            s.layout += 1;
        } else if (std.mem.eql(u8, sel.label, "Cancel")) {
            s.dialog_open = false;
        }
        return .{ .done = null };
    }

    fn progressImpl(p: *anyopaque, ctx: Ctx) ProgressReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.progress)) |f| return .{ .failed = f };
        // A stale reading is shown before the press and, with no sequence, after it.
        if (!s.confirmed or s.progress_seq.len == 0) return if (s.stale_progress) |v| .{ .fraction = .{ .done = v, .total = 1000, .id = s.stale_id } } else .none;
        const v = s.progress_seq[@min(s.progress_i, s.progress_seq.len - 1)];
        s.progress_i += 1;
        return .{ .fraction = .{ .done = v, .total = 1000, .id = s.progress_id } };
    }

    fn shotImpl(p: *anyopaque, ctx: Ctx, path: []const u8) ActionReply {
        _ = ctx;
        const s = me(p);
        if (s.enter(.screenshot)) |f| return .{ .failed = f };
        // A capture into the diagnostic directory is not part of the operation directory listing.
        if (std.mem.indexOf(u8, path, "nur-diag") != null) s.diag_shots += 1 else s.shot_made = true;
        s.presses_at_shot = s.n(.press);
        return .{ .done = null };
    }

    fn filesWalkInfo(s: *Sim) Files {
        return .{ .ptr = s, .sizeFn = sizeImpl, .listFn = listImpl, .walkFn = walkImpl, .walkInfoFn = walkInfoImpl };
    }

    /// Like `walkImpl` and it reports a listing that the limit cut. The entries read so far return.
    fn walkInfoImpl(p: *anyopaque, a: Allocator, dir: []const u8, lim: WalkLimits, info: *WalkInfo) ?[]WalkEntry {
        _ = dir;
        const s = me(p);
        if (s.walk_fail) {
            info.status = .unreadable;
            return null;
        }
        const all: usize = if (s.complete()) s.walk_list.len else 0;
        const cnt = @min(all, lim.max_entries);
        info.status = if (all > lim.max_entries) .capped else .ok;
        const out = a.alloc(WalkEntry, cnt) catch return null;
        var made: usize = 0;
        for (s.walk_list[0..cnt]) |e| {
            const path = a.dupe(u8, e.path) catch {
                for (out[0..made]) |o| a.free(o.path);
                a.free(out);
                return null;
            };
            out[made] = .{ .path = path, .kind = e.kind, .size = e.size, .nlink = e.nlink };
            made += 1;
        }
        return out;
    }

    fn filesWalk(s: *Sim) Files {
        return .{ .ptr = s, .sizeFn = sizeImpl, .listFn = listImpl, .walkFn = walkImpl };
    }

    fn walkImpl(p: *anyopaque, a: Allocator, dir: []const u8, lim: WalkLimits) ?[]WalkEntry {
        _ = dir;
        const s = me(p);
        if (s.walk_fail or s.walk_list.len > lim.max_entries) return null;
        const cnt: usize = if (s.complete()) s.walk_list.len else 0;
        const out = a.alloc(WalkEntry, cnt) catch return null;
        var made: usize = 0;
        for (s.walk_list[0..cnt]) |e| {
            const path = a.dupe(u8, e.path) catch {
                for (out[0..made]) |o| a.free(o.path);
                a.free(out);
                return null;
            };
            out[made] = .{ .path = path, .kind = e.kind, .size = e.size, .nlink = e.nlink };
            made += 1;
        }
        return out;
    }

    fn base(path: []const u8) []const u8 {
        return path[std.mem.lastIndexOfScalar(u8, path, '/').? + 1 ..];
    }

    fn sizeImpl(p: *anyopaque, path: []const u8) ?u64 {
        const s = me(p);
        const b = base(path);
        if (std.mem.endsWith(u8, b, ".png") and (s.shot_made or s.diag_shots > 0)) return 100;
        if (s.timed) return s.timedSize(b);
        if (!s.complete()) return null;
        // A test that lists the tree through `walk` also answers size queries for those entries.
        for (s.walk_list) |e| {
            if (e.kind == .file and path.len > e.path.len and std.mem.endsWith(u8, path, e.path) and path[path.len - e.path.len - 1] == '/') return e.size;
        }
        for (s.out_names, s.out_sizes) |nm, sz| if (std.mem.eql(u8, nm, b)) return sz;
        for (s.extra_files) |nm| if (std.mem.eql(u8, nm, b)) return 5;
        return null;
    }

    fn listImpl(p: *anyopaque, a: Allocator, dir: []const u8, max: usize) ?[][]u8 {
        _ = dir;
        _ = max;
        const s = me(p);
        if (s.dir_missing) return null;
        var names: std.ArrayList([]u8) = .empty;
        const add = struct {
            fn f(l: *std.ArrayList([]u8), al: Allocator, nm: []const u8) bool {
                const c = al.dupe(u8, nm) catch return false;
                l.append(al, c) catch {
                    al.free(c);
                    return false;
                };
                return true;
            }
        }.f;
        var ok = true;
        if (s.dir_dirty) ok = add(&names, a, "stale.txt");
        if (s.complete()) {
            for (s.out_names) |nm| {
                if (s.timed and s.timedSize(nm) == null) continue;
                ok = ok and add(&names, a, nm);
            }
            for (s.extra_files) |nm| ok = ok and add(&names, a, nm);
        }
        if (s.shot_made) ok = ok and add(&names, a, "inventory.png");
        if (!ok) {
            for (names.items) |nm| a.free(nm);
            names.deinit(a);
            return null;
        }
        return names.toOwnedSlice(a) catch {
            for (names.items) |nm| a.free(nm);
            names.deinit(a);
            return null;
        };
    }
};

const Fx = struct {
    sim: Sim = .{},
    fenv: FakeEnv = .{},
    rt: Runtime = undefined,

    fn start(fx: *Fx, a: Allocator, limits: Limits) void {
        fx.sim.standardControls();
        fx.rt = Runtime.init(a, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), limits);
    }
};

fn request(phase: Phase, route: Route, dir: []const u8) ExportRequest {
    return .{
        .phase = phase,
        .route = route,
        .policy = .{ .expected = .{ .original = orig, .converted = conv, .watermarked = true } },
        .pid = 4242,
        .run_binding = bind,
        .op_id = Sim.base(dir),
        .op_dir = dir,
        .outputs = obj_outputs,
        .scratch = .{ .session = "scratch-1" },
    };
}

fn expectFail(rep: ExportReport, kind: FailureKind) !void {
    const f = rep.failure orelse return error.TestExpectedFailure;
    try testing.expectEqual(kind, f.kind);
}

fn pidGone(pid: i32) bool {
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        std.posix.kill(pid, @enumFromInt(0)) catch |e| return e == error.ProcessNotFound;
        testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

fn firstLinePid(out: []const u8) !i32 {
    const line = std.mem.sliceTo(out, '\n');
    return std.fmt.parseInt(i32, line, 10);
}

test "process transport reports exit code and both streams" {
    var pt: ProcessTransport = .{ .io = testing.io };
    const r = pt.transport().run(testing.allocator, &.{ "/bin/sh", "-c", "echo out; echo err >&2; exit 3" }, 5000, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(RunStatus.exited, r.status);
    try testing.expectEqual(@as(u8, 3), r.exit_code);
    try testing.expectEqualStrings("out\n", r.stdout);
    try testing.expectEqualStrings("err\n", r.stderr);
    try testing.expect(!r.stdout_truncated and !r.stderr_truncated);
    try testing.expect(!r.succeeded());
}

test "process transport kills the child group at the deadline and keeps partial output" {
    var pt: ProcessTransport = .{ .io = testing.io };
    const r = pt.transport().run(testing.allocator, &.{ "/bin/sh", "-c", "sleep 30 & echo $!; wait" }, 300, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(RunStatus.timed_out, r.status);
    try testing.expect(r.elapsed_ns >= 250 * std.time.ns_per_ms);
    try testing.expect(r.elapsed_ns < 5 * std.time.ns_per_s);
    // The grandchild sleeps 30 s. A group kill ends it.
    const pid = try firstLinePid(r.stdout);
    try testing.expect(pidGone(pid));
}

test "process transport kills a plain sleep and returns no output" {
    var pt: ProcessTransport = .{ .io = testing.io };
    const r = pt.transport().run(testing.allocator, &.{ "/bin/sleep", "30" }, 200, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(RunStatus.timed_out, r.status);
    try testing.expectEqual(@as(usize, 0), r.stdout.len);
    try testing.expect(r.elapsed_ns < 5 * std.time.ns_per_s);
}

test "process transport enforces the output limit and kills the flood" {
    var pt: ProcessTransport = .{ .io = testing.io };
    const r = pt.transport().run(testing.allocator, &.{ "/bin/sh", "-c", "echo $$; exec yes" }, 5000, .{ .stdout = 1000, .stderr = 100 });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(RunStatus.output_limit, r.status);
    try testing.expect(r.stdout_truncated);
    try testing.expectEqual(@as(usize, 1000), r.stdout.len);
    try testing.expect(pidGone(try firstLinePid(r.stdout)));
}

test "process transport bounds the wait of a child that closed its pipes" {
    var pt: ProcessTransport = .{ .io = testing.io };
    const r = pt.transport().run(testing.allocator, &.{ "/bin/sh", "-c", "echo $$; exec >&- 2>&-; exec sleep 30" }, 300, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(RunStatus.timed_out, r.status);
    try testing.expect(r.elapsed_ns < 5 * std.time.ns_per_s);
    try testing.expect(pidGone(try firstLinePid(r.stdout)));
}

test "process transport reports a spawn failure" {
    var pt: ProcessTransport = .{ .io = testing.io };
    const r = pt.transport().run(testing.allocator, &.{"/nonexistent/native-ui-test-binary"}, 1000, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(RunStatus.spawn_failed, r.status);
}

test "process transport reports a child killed by a signal" {
    var pt: ProcessTransport = .{ .io = testing.io };
    const r = pt.transport().run(testing.allocator, &.{ "/bin/sh", "-c", "kill -9 $$" }, 5000, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(RunStatus.signaled, r.status);
}

test "system files read sizes and listings without writing" {
    var sf: SystemFiles = .{ .io = testing.io };
    const f = sf.files();
    try testing.expect(f.size("/bin/sh").? > 0);
    try testing.expect(f.size("/nonexistent/x") == null);
    const names = f.list(testing.allocator, "/bin", 4096).?;
    defer freeList(testing.allocator, names);
    var found = false;
    for (names) |nm| if (std.mem.eql(u8, nm, "sh")) {
        found = true;
    };
    try testing.expect(found);
    try testing.expect(f.list(testing.allocator, "/nonexistent-dir", 10) == null);
    // More entries than the cap returns null.
    try testing.expect(f.list(testing.allocator, "/bin", 2) == null);
}

fn expectRouteError(want: RouteError, r: Route, phase: Phase) !void {
    try testing.expectError(want, validateRoute(r, phase, .{}));
}

fn routeWith(steps: []const Step) Route {
    return .{ .id = "r", .format = .obj, .steps = steps, .binding = bind };
}

test "route validation accepts the synthetic OBJ route in every phase" {
    try validateRoute(obj_route, .inventory, .{});
    try validateRoute(obj_route, .calibration, .{});
    try validateRoute(obj_route, .verified, .{});
}

test "route validation rejects menu paths outside File then Export" {
    const bad_paths = [_][]const []const u8{
        &.{"File"},
        &.{ "File", "Open" },
        &.{ "Edit", "Export" },
        &.{ "file", "export" },
        &.{ "File", "Export", "a", "b", "c" },
        &.{ "File", "Export", "" },
        &.{ "File", "Export", "bad\nlabel" },
    };
    for (bad_paths) |p| {
        const steps = [_]Step{ .{ .menu = p }, .{ .destination = .{ .name_field = s_name, .dir_field = s_where } }, .{ .confirm = s_save } };
        try expectRouteError(error.BadMenuPath, routeWith(&steps), .calibration);
    }
}

test "route validation enforces the allowed action order" {
    const menu: Step = .{ .menu = &.{ "File", "Export" } };
    const opt: Step = .{ .option = .{ .selector = s_materials, .value = .{ .checked = true } } };
    const dest: Step = .{ .destination = .{ .name_field = s_name, .dir_field = s_where } };
    const conf: Step = .{ .confirm = s_save };
    try expectRouteError(error.BadStepOrder, routeWith(&.{ opt, menu, dest, conf }), .calibration);
    try expectRouteError(error.BadStepOrder, routeWith(&.{ menu, dest, opt, conf }), .calibration);
    try expectRouteError(error.BadStepOrder, routeWith(&.{ menu, conf, dest }), .calibration);
    try expectRouteError(error.BadStepOrder, routeWith(&.{ menu, menu, dest, conf }), .calibration);
    try expectRouteError(error.BadStepOrder, routeWith(&.{ menu, dest, dest, conf }), .calibration);
    try expectRouteError(error.BadStepOrder, routeWith(&.{ menu, dest, conf, conf }), .calibration);
    try expectRouteError(error.BadStepOrder, routeWith(&.{ dest, conf }), .calibration);
    try expectRouteError(error.MissingDestination, routeWith(&.{menu}), .calibration);
    try expectRouteError(error.MissingDestination, routeWith(&.{ menu, opt }), .calibration);
    try expectRouteError(error.MissingConfirm, routeWith(&.{ menu, dest }), .calibration);
    try expectRouteError(error.TooManySteps, routeWith(&.{}), .calibration);
}

test "route validation rejects duplicate options, role mismatches and unbounded values" {
    const menu: Step = .{ .menu = &.{ "File", "Export" } };
    const dest: Step = .{ .destination = .{ .name_field = s_name, .dir_field = s_where } };
    const conf: Step = .{ .confirm = s_save };
    const o1: Step = .{ .option = .{ .selector = s_materials, .value = .{ .checked = true } } };
    const o2: Step = .{ .option = .{ .selector = s_materials, .value = .{ .checked = false } } };
    try expectRouteError(error.DuplicateOption, routeWith(&.{ menu, o1, o2, dest, conf }), .calibration);
    const bad_role: Step = .{ .option = .{ .selector = s_materials, .value = .{ .text = "x" } } };
    try expectRouteError(error.BadRoleValue, routeWith(&.{ menu, bad_role, dest, conf }), .calibration);
    const button_opt: Step = .{ .option = .{ .selector = s_save, .value = .{ .checked = true } } };
    try expectRouteError(error.BadRoleValue, routeWith(&.{ menu, button_opt, dest, conf }), .calibration);
    const radio_off: Step = .{ .option = .{ .selector = sheet(.radio, "Solids"), .value = .{ .checked = false } } };
    try expectRouteError(error.BadRoleValue, routeWith(&.{ menu, radio_off, dest, conf }), .calibration);
    const long = "x" ** 200;
    const long_text: Step = .{ .option = .{ .selector = s_scale, .value = .{ .text = long } } };
    try expectRouteError(error.BadValue, routeWith(&.{ menu, long_text, dest, conf }), .calibration);
    const ctl_text: Step = .{ .option = .{ .selector = s_scale, .value = .{ .text = "1\n2" } } };
    try expectRouteError(error.BadValue, routeWith(&.{ menu, ctl_text, dest, conf }), .calibration);
    const bad_label: Step = .{ .option = .{ .selector = sheet(.checkbox, " padded"), .value = .{ .checked = true } } };
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, bad_label, dest, conf }), .calibration);
    const bad_dest: Step = .{ .destination = .{ .name_field = sheet(.button, "Save As:") } };
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, bad_dest, conf }), .calibration);
    const bad_conf: Step = .{ .confirm = sheet(.text_field, "Save") };
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, dest, bad_conf }), .calibration);
}

test "verified phase needs a directory field and a valid route id" {
    const menu: Step = .{ .menu = &.{ "File", "Export" } };
    const dest_no_dir: Step = .{ .destination = .{ .name_field = s_name } };
    const conf: Step = .{ .confirm = s_save };
    try validateRoute(routeWith(&.{ menu, dest_no_dir, conf }), .calibration, .{});
    try expectRouteError(error.MissingDirField, routeWith(&.{ menu, dest_no_dir, conf }), .verified);
    var r = obj_route;
    r.id = "";
    try expectRouteError(error.BadId, r, .calibration);
}

test "binding validation needs lowercase hex digests" {
    try validateBinding(bind, .{});
    var b = bind;
    b.profile_hash = "A" ** 64;
    try testing.expectError(error.BadBinding, validateBinding(b, .{}));
    b = bind;
    b.source_digest = "a" ** 63;
    try testing.expectError(error.BadBinding, validateBinding(b, .{}));
    b = bind;
    b.release = "";
    try testing.expectError(error.BadBinding, validateBinding(b, .{}));
}

test "phase gate refuses uncalibrated, stale and unauthorized runs" {
    const lim: Limits = .{};
    try testing.expect(checkPhase(.inventory, obj_route, bind, null, lim) == null);
    // Calibration needs an authorized scratch session.
    try testing.expectEqual(FailureKind.scratch_not_authorized, checkPhase(.calibration, obj_route, bind, null, lim).?.kind);
    try testing.expectEqual(FailureKind.scratch_not_authorized, checkPhase(.calibration, obj_route, bind, .{ .session = "" }, lim).?.kind);
    try testing.expect(checkPhase(.calibration, obj_route, bind, .{ .session = "s1" }, lim) == null);
    // A scratch authorization never makes a route verified.
    try testing.expectEqual(FailureKind.uncalibrated_route, checkPhase(.verified, obj_route, bind, .{ .session = "s1" }, lim).?.kind);
    // Calibrated status without evidence is refused.
    var c = obj_route;
    c.status = .calibrated;
    try testing.expectEqual(FailureKind.uncalibrated_route, checkPhase(.verified, c, bind, null, lim).?.kind);
    // Evidence for another binding is stale.
    var stale = calibrated(obj_route);
    stale.evidence.?.binding.state_digest = "d" ** 64;
    try testing.expectEqual(FailureKind.stale_route, checkPhase(.verified, stale, bind, null, lim).?.kind);
    // Route binding for another release is stale in calibration and verification.
    var other = calibrated(obj_route);
    other.binding.release = "Vectorworks 2028 trial";
    other.evidence.?.binding = other.binding;
    try testing.expectEqual(FailureKind.stale_route, checkPhase(.verified, other, bind, null, lim).?.kind);
    try testing.expectEqual(FailureKind.stale_route, checkPhase(.calibration, other, bind, .{ .session = "s1" }, lim).?.kind);
    // Matching route, evidence and binding passes.
    try testing.expect(checkPhase(.verified, calibrated(obj_route), bind, null, lim) == null);
    // An invalid route shape is refused first.
    var bad = calibrated(obj_route);
    bad.steps = &.{};
    try testing.expectEqual(FailureKind.invalid_route, checkPhase(.verified, bad, bind, null, lim).?.kind);
}

const FmtCase = struct { format: Format, steps: []const Step, outputs: ExpectedOutputs };

const stl_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export STL" } },
    .{ .option = .{ .selector = sheet(.popup, "Format"), .value = .{ .choice = "Binary" } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};
const tds_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export 3DS" } },
    .{ .option = .{ .selector = sheet(.checkbox, "Export Textures"), .value = .{ .checked = true } } },
    .{ .option = .{ .selector = sheet(.popup, "Units"), .value = .{ .choice = "Millimeters" } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};
const fbx_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export FBX" } },
    .{ .option = .{ .selector = sheet(.popup, "Version"), .value = .{ .choice = "FBX 2020" } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};
const para_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export Parasolid" } },
    .{ .option = .{ .selector = sheet(.radio, "Visible Objects"), .value = .{ .checked = true } } },
    .{ .option = .{ .selector = sheet(.popup, "Version"), .value = .{ .choice = "Latest" } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};
const step_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export STEP" } },
    .{ .option = .{ .selector = sheet(.radio, "Solids"), .value = .{ .checked = true } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};
const pdf_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export PDF" } },
    .{ .option = .{ .selector = sheet(.checkbox, "Embed Fonts"), .value = .{ .checked = true } } },
    .{ .option = .{ .selector = sheet(.popup, "Standard"), .value = .{ .choice = "PDF/A" } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};

const fmt_cases = [_]FmtCase{
    .{ .format = .obj, .steps = &obj_steps, .outputs = obj_outputs },
    .{ .format = .stl, .steps = &stl_steps, .outputs = .{ .primary = "part.stl" } },
    .{ .format = .tds, .steps = &tds_steps, .outputs = .{ .primary = "scene.3ds", .required_sidecars = &.{"tex_001.png"}, .allowed_sidecar_exts = &.{ ".png", ".jpg" } } },
    .{ .format = .fbx, .steps = &fbx_steps, .outputs = .{ .primary = "scene.fbx" } },
    .{ .format = .parasolid, .steps = &para_steps, .outputs = .{ .primary = "part.x_t" } },
    .{ .format = .step, .steps = &step_steps, .outputs = .{ .primary = "part.step" } },
    .{ .format = .pdf, .steps = &pdf_steps, .outputs = .{ .primary = "sheet.pdf" } },
};

fn simForCase(sim: *Sim, c: FmtCase, names: *[8][]const u8, sizes: *[8]u64) void {
    for (c.steps) |st| switch (st) {
        .menu => {},
        .option => |o| sim.addCtl(o.selector.role, o.selector.label, ""),
        .destination => |d| {
            sim.addCtl(d.name_field.role, d.name_field.label, "");
            if (d.dir_field) |df| sim.addCtl(df.role, df.label, "");
        },
        .confirm => |cf| sim.addCtl(cf.role, cf.label, ""),
    };
    sim.addCtl(.button, "Cancel", "");
    var k: usize = 0;
    names[k] = c.outputs.primary;
    sizes[k] = 1000;
    k += 1;
    for (c.outputs.required_sidecars) |s| {
        names[k] = s;
        sizes[k] = 50;
        k += 1;
    }
    sim.out_names = names[0..k];
    sim.out_sizes = sizes[0..k];
}

test "synthetic routes for the common formats validate and run in calibration" {
    for (fmt_cases) |c| {
        var route: Route = .{ .id = @tagName(c.format), .format = c.format, .steps = c.steps, .cancel = s_cancel, .progress = true, .progress_id = "export-progress", .binding = bind };
        try validateRoute(route, .verified, .{});
        try validateOutputs(c.format, c.outputs, .{});
        var fx: Fx = .{};
        var names: [8][]const u8 = undefined;
        var sizes: [8]u64 = undefined;
        simForCase(&fx.sim, c, &names, &sizes);
        fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), .{});
        var req = request(.calibration, route, "/tmp/nur/op-fmt");
        req.outputs = c.outputs;
        var rep = fx.rt.runExport(req);
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.ok());
        try testing.expect(!rep.verified);
        var option_steps: usize = 0;
        for (c.steps) |st| switch (st) {
            .option => option_steps += 1,
            else => {},
        };
        // Option steps plus the name and directory fields.
        try testing.expectEqual(option_steps + 2, rep.options.len);
        try testing.expectEqual(c.outputs.required_sidecars.len + 1, rep.files.len);
        try testing.expectEqual(FileRole.primary, rep.files[0].role);
        route.status = .uncalibrated;
    }
}

test "output names are checked against the route format" {
    const lim: Limits = .{};
    try validateOutputs(.obj, obj_outputs, lim);
    try testing.expectError(error.BadOutputName, validateOutputs(.obj, .{ .primary = "model.stl" }, lim));
    try testing.expectError(error.BadOutputName, validateOutputs(.obj, .{ .primary = "dir/model.obj" }, lim));
    try testing.expectError(error.BadOutputName, validateOutputs(.obj, .{ .primary = "../model.obj" }, lim));
    try testing.expectError(error.BadOutputName, validateOutputs(.obj, .{ .primary = ".hidden.obj" }, lim));
    try testing.expectError(error.BadOutputName, validateOutputs(.obj, .{ .primary = "" }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.stl, .{ .primary = "a.stl", .required_sidecars = &.{"a.mtl"} }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "a.obj", .required_sidecars = &.{"a.exe"} }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "a.obj", .required_sidecars = &.{"a.obj"} }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.fbx, .{ .primary = "a.fbx", .allowed_sidecar_exts = &.{".png"} }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.tds, .{ .primary = "a.3ds", .allowed_sidecar_exts = &.{"png"} }, lim));
    try validateOutputs(.parasolid, .{ .primary = "a.x_b" }, lim);
    try validateOutputs(.step, .{ .primary = "a.STP" }, lim);
}

test "selector cache keeps entries only while pid and layout match" {
    var c: SelectorCache = .{};
    try testing.expect(c.get(s_save, 1) == null);
    c.put(s_save, 1, 100);
    try testing.expectEqual(@as(?u64, 100), c.get(s_save, 1));
    try testing.expect(c.get(s_save, 2) == null);
    try testing.expect(c.get(s_cancel, 1) == null);
    try testing.expect(c.get(sheet(.checkbox, "Save"), 1) == null);
    try testing.expect(c.get(.{ .container = .{ .window = "Save" }, .role = .button, .label = "Save" }, 1) == null);
    c.put(s_save, 1, 101);
    try testing.expectEqual(@as(usize, 1), c.count());
    try testing.expectEqual(@as(?u64, 101), c.get(s_save, 1));
    c.drop(s_save, 1);
    try testing.expect(c.get(s_save, 1) == null);
    c.put(s_save, 1, 1);
    c.put(s_cancel, 1, 2);
    c.invalidate();
    try testing.expectEqual(@as(usize, 0), c.count());
    // Rotation replaces the oldest entry after 16 distinct selectors.
    var labels: [20][8]u8 = undefined;
    for (0..20) |i| {
        const l = std.fmt.bufPrint(&labels[i], "L{d}", .{i}) catch unreachable;
        c.put(sheet(.button, l), 1, i);
    }
    try testing.expectEqual(@as(usize, 16), c.count());
    try testing.expect(c.get(sheet(.button, "L0"), 1) == null);
    try testing.expect(c.get(sheet(.button, "L19"), 1) != null);
}

const US = "\x1f";

/// Fake transport. The first rule whose `has` occurs in the argv joined with 0x1f answers. It
/// records each call. No process starts.
const FakeTransport = struct {
    const Rule = struct {
        has: []const u8,
        status: RunStatus = .exited,
        code: u8 = 0,
        out: []const u8 = "",
        err: []const u8 = "",
    };
    a: Allocator,
    rules: []const Rule,
    calls: std.ArrayList([]u8) = .empty,

    fn deinit(t: *FakeTransport) void {
        for (t.calls.items) |c| t.a.free(c);
        t.calls.deinit(t.a);
    }

    fn transport(t: *FakeTransport) Transport {
        return .{ .ptr = t, .runFn = runImpl };
    }

    fn runImpl(ptr: *anyopaque, a: Allocator, argv: []const []const u8, timeout_ms: u32, lim: StreamLimits) RunOutput {
        _ = timeout_ms;
        _ = lim;
        const t: *FakeTransport = @ptrCast(@alignCast(ptr));
        const joined = std.mem.join(t.a, US, argv) catch @panic("oom");
        t.calls.append(t.a, joined) catch @panic("oom");
        for (t.rules) |r| {
            if (std.mem.indexOf(u8, joined, r.has) != null) {
                return .{
                    .status = r.status,
                    .exit_code = r.code,
                    .stdout = a.dupe(u8, r.out) catch @panic("oom"),
                    .stderr = a.dupe(u8, r.err) catch @panic("oom"),
                };
            }
        }
        return .{ .status = .spawn_failed };
    }

    fn lastCall(t: *const FakeTransport) []const u8 {
        return t.calls.items[t.calls.items.len - 1];
    }
};

const mac_ctx: Ctx = .{ .pid = 4242, .expected = .{ .original = orig, .converted = conv, .watermarked = true }, .window_title = conv_title, .timeout_ms = 5000 };

const snapshot_watermark_progress =
    "ok\nW\ts:\tt\ts:OK\tfull\n" ++
    "T\ts:This document is watermarked.\n" ++
    "T\ts:The data contained in this file may only be used in other watermarked documents.\n" ++
    "W\ts:Vectorworks\tt\tn\tfull\n" ++
    "T\ts:Opening File: clock-ClocKit_standard_shafts.vwx\n" ++
    "T\ts:Step 10 of 11: Generating Resource Previews...\n" ++
    "T\ts:\n" ++
    "T\ts:Vectorworks\n" ++
    "W\ts:" ++ conv_title ++ "\tf\tn\t-\n";

const snapshot_ready = "ok\nW\ts:" ++ conv_title ++ "\tf\tn\t-\n";

fn macRules(snapshot: []const u8, registry: []const u8) [4]FakeTransport.Rule {
    return .{
        .{ .has = "/usr/bin/stat" ++ US, .out = "someone\n" },
        .{ .has = "/usr/bin/id" ++ US, .out = "someone\n" },
        .{ .has = "/usr/sbin/ioreg" ++ US, .out = registry },
        .{ .has = "set outText", .out = snapshot },
    };
}

const reg_unlocked = valid_registry ++ "\"CGSSessionScreenIsLocked\"=No";
const reg_locked = valid_registry ++ "\"CGSSessionScreenIsLocked\"=Yes";

const MacFx = struct {
    ft: FakeTransport,
    fenv: FakeEnv = .{},
    mac: MacBackend = undefined,

    fn start(fx: *MacFx) void {
        fx.mac = MacBackend.init(testing.allocator, fx.ft.transport(), fx.fenv.env(), .{});
    }
    fn stop(fx: *MacFx) void {
        fx.mac.deinit();
        fx.ft.deinit();
    }
};

fn watermarkPolicy() ui.Policy {
    return .{ .expected = mac_ctx.expected, .allow_conversion_ack = true, .allow_watermark_ack = true };
}

test "mac backend parses the recorded notice and progress snapshot into a proposed acknowledgement" {
    const rules = macRules(snapshot_watermark_progress, reg_unlocked);
    var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
    fx.start();
    defer fx.stop();
    const r = fx.mac.backend().observe(mac_ctx);
    const obs = r.observed;
    try testing.expect(obs.windows_complete);
    try testing.expectEqual(@as(usize, 3), obs.windows.len);
    const d = ui.decide(obs, watermarkPolicy());
    try testing.expectEqual(ui.DecisionKind.proposed_action, d.kind);
    try testing.expectEqual(ui.ModalClass.known_watermark, d.action.acknowledge.class);
    // No permission, no proposal.
    try testing.expectEqual(ui.DecisionKind.not_permitted, ui.decide(obs, .{ .expected = mac_ctx.expected }).kind);
    // The calls: stat, id, ioreg, osascript with the pid argument.
    try testing.expectEqual(@as(usize, 4), fx.ft.calls.items.len);
    try testing.expect(std.mem.startsWith(u8, fx.ft.calls.items[3], "/usr/bin/osascript" ++ US ++ "-e" ++ US));
    try testing.expect(std.mem.endsWith(u8, fx.ft.lastCall(), US ++ "4242"));
}

test "mac backend reports ready for the expected window only" {
    const rules = macRules(snapshot_ready, reg_unlocked);
    var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
    fx.start();
    defer fx.stop();
    const d = ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy());
    try testing.expectEqual(ui.DecisionKind.ready, d.kind);
}

test "mac backend surfaces a locked console, a wrong document and a missing console field" {
    {
        const rules = macRules(snapshot_ready, reg_locked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        const d = ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy());
        try testing.expectEqual(ui.DecisionKind.console_locked, d.kind);
    }
    {
        const rules = macRules("ok\nW\ts:other.vwx - WATERMARKED FILE\tf\tn\t-\n", reg_unlocked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        const d = ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy());
        try testing.expectEqual(ui.DecisionKind.wrong_target, d.kind);
    }
    {
        var rules = macRules(snapshot_ready, reg_unlocked);
        rules[0].status = .spawn_failed;
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        const d = ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy());
        try testing.expectEqual(ui.DecisionKind.console_unknown, d.kind);
    }
}

test "mac backend maps timeouts, a gone process and malformed snapshots to typed failures" {
    {
        var rules = macRules(snapshot_ready, reg_unlocked);
        rules[2].status = .timed_out;
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        try testing.expectEqual(FailureKind.timeout, fx.mac.backend().observe(mac_ctx).failed.kind);
    }
    {
        const rules = macRules("gone", reg_unlocked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        try testing.expectEqual(FailureKind.process_lost, fx.mac.backend().observe(mac_ctx).failed.kind);
    }
    for ([_][]const u8{ "", "nope" }) |s| {
        // Output that does not start with a known token is a transport problem.
        const rules = macRules(s, reg_unlocked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        try testing.expectEqual(FailureKind.transport_error, fx.mac.backend().observe(mac_ctx).failed.kind);
    }
    const bad = [_][]const u8{
        "ok\nX\tfoo\n",
        "ok\nW\ts:a\tf\tn\n",
        "ok\nW\ts:a\tq\tn\t-\n",
        "ok\nW\tbad\tf\tn\t-\n",
        "ok\nW\ts:a\tf\tn\tfull\n",
        "ok\nW\ts:a\tt\tn\t-\n",
        "ok\nT\ts:orphan\n",
        "ok\nW\ts:a\tt\tn\tfull\nT\ts:a\textra\n",
    };
    for (bad) |s| {
        const rules = macRules(s, reg_unlocked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        try testing.expectEqual(FailureKind.unknown_ui, fx.mac.backend().observe(mac_ctx).failed.kind);
    }
}

test "mac backend treats unreadable dialog text as an incomplete observation that stops" {
    const loading = "ok\nW\ts:Vectorworks\tt\ts:OK\tloading\nW\ts:" ++ conv_title ++ "\tf\tn\t-\n";
    const unreadable = "ok\nW\ts:Vectorworks\tt\ts:OK\tfull\nT\tx\nW\ts:" ++ conv_title ++ "\tf\tn\t-\n";
    for ([_][]const u8{ loading, unreadable }) |s| {
        const rules = macRules(s, reg_unlocked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        const obs = fx.mac.backend().observe(mac_ctx).observed;
        try testing.expect(!obs.windows_complete);
        try testing.expectEqual(ui.DecisionKind.unknown_ui, ui.decide(obs, watermarkPolicy()).kind);
    }
}

test "snapshot parser bounds windows, texts and text length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "ok\n");
    for (0..40) |_| try buf.appendSlice(a, "W\ts:w\tf\tn\t-\n");
    try testing.expect(parseSnapshot(a, buf.items, .{}) == .malformed);
    buf.clearRetainingCapacity();
    try buf.appendSlice(a, "ok\nW\ts:d\tt\tn\tfull\n");
    for (0..20) |_| try buf.appendSlice(a, "T\ts:t\n");
    const r = parseSnapshot(a, buf.items, .{});
    try testing.expect(!r.ok.complete);
    try testing.expect(r.ok.windows[0].texts == null);
    buf.clearRetainingCapacity();
    try buf.appendSlice(a, "ok\nW\ts:d\tt\tn\tfull\nT\ts:");
    try buf.appendNTimes(a, 'x', 600);
    try buf.append(a, '\n');
    const r2 = parseSnapshot(a, buf.items, .{});
    try testing.expect(!r2.ok.complete);
}

test "embedded scripts never activate an app, type keys or capture a rectangle" {
    const scripts = [_][]const u8{ script_snapshot, script_control, script_menu, script_ack, script_progress, script_windowid };
    const forbidden = [_][]const u8{ "activate", "frontmost", "keystroke", "key code", "screencapture", "do shell script", "open location", "tell application \"Vectorworks" };
    for (scripts) |s| {
        try testing.expect(std.mem.indexOf(u8, s, "first process whose unix id is probePid") != null);
        for (forbidden) |f| try testing.expect(std.mem.indexOf(u8, s, f) == null);
    }
}

fn macOnly(rules: []const FakeTransport.Rule) MacFx {
    return .{ .ft = .{ .a = testing.allocator, .rules = rules } };
}

test "mac backend lookup returns one control, many or none" {
    const sel = s_save;
    const rules = [_]FakeTransport.Rule{
        .{ .has = US ++ "lookup" ++ US ++ "AXButton" ++ US ++ "Save", .out = "ok\t1\t10,20;300,400;5\ts:\t1\n" },
        .{ .has = US ++ "lookup" ++ US ++ "AXButton" ++ US ++ "Cancel", .out = "ok\t2\t10,20;300,400;5\n" },
        .{ .has = US ++ "lookup" ++ US ++ "AXCheckBox", .out = "ok\t0\t10,20;300,400;5\n" },
        .{ .has = US ++ "lookup" ++ US ++ "AXPopUpButton" ++ US ++ "Bad1", .out = "ok\tmany\tsig\n" },
        .{ .has = US ++ "lookup" ++ US ++ "AXPopUpButton" ++ US ++ "Bad2", .out = "ok\t1\tsig\ts:v\t2\n" },
        .{ .has = US ++ "lookup" ++ US ++ "AXPopUpButton" ++ US ++ "Bad3", .out = "ok\t1\tsig\ts:v\n" },
        .{ .has = US ++ "lookup" ++ US ++ "AXPopUpButton" ++ US ++ "Bad4", .out = "ok\t1\tsig\ts:v\t1\textra\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    const one = b.lookup(mac_ctx, sel).found;
    try testing.expectEqual(@as(u16, 1), one.count);
    try testing.expect(one.enabled);
    try testing.expectEqualStrings("", one.value.?);
    const l1 = one.layout_id;
    try testing.expectEqual(@as(u16, 2), b.lookup(mac_ctx, s_cancel).found.count);
    try testing.expectEqual(@as(u16, 0), b.lookup(mac_ctx, s_materials).found.count);
    // The same signature gives the same layout id.
    try testing.expectEqual(l1, b.lookup(mac_ctx, s_save).found.layout_id);
    for ([_][]const u8{ "Bad1", "Bad2", "Bad3", "Bad4" }) |l| {
        try testing.expectEqual(FailureKind.transport_error, b.lookup(mac_ctx, sheet(.popup, l)).failed.kind);
    }
    // The call passes the container kind, title and the exact role and label as argv.
    try testing.expect(std.mem.indexOf(u8, fx.ft.calls.items[0], US ++ "4242" ++ US ++ "sheet" ++ US ++ conv_title ++ US ++ "lookup" ++ US ++ "AXButton" ++ US ++ "Save" ++ US) != null);
    // A window selector passes its own title.
    _ = b.lookup(mac_ctx, .{ .container = .{ .window = "Export Options" }, .role = .button, .label = "Save" });
    try testing.expect(std.mem.indexOf(u8, fx.ft.lastCall(), US ++ "window" ++ US ++ "Export Options" ++ US ++ "lookup") != null);
}

test "mac backend identity reports a present or absent container" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = US ++ "identity" ++ US ++ "" ++ US ++ "" ++ US ++ "" ++ US ++ "\x01", .out = "" },
        .{ .has = conv_title ++ US ++ "identity", .out = "ok\t1,2;3,4;5\n" },
        .{ .has = "Missing" ++ US ++ "identity", .out = "refused\twindow_absent\n" },
        .{ .has = "Twice" ++ US ++ "identity", .out = "refused\twindow_ambiguous\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    const p1 = b.identity(mac_ctx, .document_sheet).present;
    try testing.expectEqual(p1, b.identity(mac_ctx, .document_sheet).present);
    try testing.expect(b.identity(mac_ctx, .{ .window = "Missing" }) == .absent);
    try testing.expectEqual(FailureKind.ambiguous_target, b.identity(mac_ctx, .{ .window = "Twice" }).failed.kind);
}

test "mac backend set value reads back and marks uncertain failures" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = US ++ "set" ++ US ++ "AXCheckBox" ++ US ++ "Export Materials" ++ US ++ "1", .out = "ok\ts:1\n" },
        .{ .has = US ++ "set" ++ US ++ "AXPopUpButton" ++ US ++ "Quality", .out = "failed_after_start\t-1728\n" },
        .{ .has = US ++ "set" ++ US ++ "AXTextField" ++ US ++ "Scale", .out = "refused\tcontrol_disabled\n" },
        .{ .has = US ++ "set" ++ US ++ "AXTextField" ++ US ++ "Save As:", .status = .timed_out },
        .{ .has = US ++ "set" ++ US ++ "AXTextField" ++ US ++ "Where:", .out = "ok\tn\n" },
        .{ .has = US ++ "set" ++ US ++ "AXRadioButton", .out = "refused\tcontrol_ambiguous\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    try testing.expectEqualStrings("1", b.setValue(mac_ctx, s_materials, .{ .checked = true }).done.?);
    const f1 = b.setValue(mac_ctx, s_quality, .{ .choice = "High" }).failed;
    try testing.expect(f1.uncertain);
    const f2 = b.setValue(mac_ctx, s_scale, .{ .text = "1.0" }).failed;
    try testing.expectEqual(FailureKind.refused, f2.kind);
    try testing.expect(!f2.uncertain);
    const f3 = b.setValue(mac_ctx, s_name, .{ .text = "model.obj" }).failed;
    try testing.expectEqual(FailureKind.timeout, f3.kind);
    try testing.expect(f3.uncertain);
    try testing.expectEqual(FailureKind.incomplete_options, b.setValue(mac_ctx, s_where, .{ .text = "/tmp/x" }).failed.kind);
    const f4 = b.setValue(mac_ctx, sheet(.radio, "Solids"), .{ .checked = true }).failed;
    try testing.expectEqual(FailureKind.ambiguous_target, f4.kind);
    try testing.expect(!f4.uncertain);
}

test "mac backend press, menu and non-zero script exits" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = US ++ "press" ++ US ++ "AXButton" ++ US ++ "Save", .out = "ok\n" },
        .{ .has = US ++ "press" ++ US ++ "AXButton" ++ US ++ "Cancel", .out = "gone\n" },
        .{ .has = US ++ "press" ++ US ++ "AXButton" ++ US ++ "Quit", .code = 1, .err = "execution error: Can't get window. (-1728)\n" },
        .{ .has = US ++ "press" ++ US ++ "AXButton" ++ US ++ "Weird", .out = "banana\n" },
        .{ .has = "menu bar item", .out = "ok\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    try testing.expect(b.press(mac_ctx, s_save) == .done);
    const gone = b.press(mac_ctx, s_cancel).failed;
    try testing.expectEqual(FailureKind.process_lost, gone.kind);
    try testing.expect(!gone.uncertain);
    const exit1 = b.press(mac_ctx, sheet(.button, "Quit")).failed;
    try testing.expect(exit1.uncertain);
    try testing.expect(std.mem.indexOf(u8, exit1.detail, "-1728") != null);
    try testing.expect(b.press(mac_ctx, sheet(.button, "Weird")).failed.uncertain);
    // Menu labels go through argv, one per item.
    try testing.expect(b.menu(mac_ctx, &.{ "File", "Export", "Export OBJ" }) == .done);
    try testing.expect(std.mem.endsWith(u8, fx.ft.lastCall(), US ++ "4242" ++ US ++ "File" ++ US ++ "Export" ++ US ++ "Export OBJ"));
    const before = fx.ft.calls.items.len;
    try testing.expectEqual(FailureKind.refused, b.menu(mac_ctx, &.{"File"}).failed.kind);
    try testing.expectEqual(before, fx.ft.calls.items.len);
}

test "mac backend acknowledgement clicks only the approved button of a known class" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = "wantTexts", .out = "ok\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    const texts = [_][]const u8{ ui.watermark_text_1, ui.watermark_text_2 };
    try testing.expect(b.acknowledge(mac_ctx, .{ .title = "", .texts = &texts, .button = "OK", .class = .known_watermark }) == .done);
    const call = fx.ft.lastCall();
    try testing.expect(std.mem.indexOf(u8, call, US ++ "s:" ++ US ++ "OK" ++ US ++ ui.watermark_text_1 ++ "\x1f" ++ ui.watermark_text_2) != null);
    const before = fx.ft.calls.items.len;
    try testing.expectEqual(FailureKind.refused, b.acknowledge(mac_ctx, .{ .title = "", .texts = &texts, .button = "Cancel", .class = .known_watermark }).failed.kind);
    try testing.expectEqual(FailureKind.refused, b.acknowledge(mac_ctx, .{ .title = "", .texts = &texts, .button = "OK", .class = .unknown }).failed.kind);
    try testing.expectEqual(FailureKind.refused, b.acknowledge(mac_ctx, .{ .title = "", .texts = &texts, .button = "OK", .class = .progress }).failed.kind);
    try testing.expectEqual(before, fx.ft.calls.items.len);
    // A null title is passed as `n`.
    _ = b.acknowledge(mac_ctx, .{ .title = null, .texts = &texts, .button = "OK", .class = .known_conversion });
    try testing.expect(std.mem.indexOf(u8, fx.ft.lastCall(), US ++ "n" ++ US ++ "OK" ++ US) != null);
}

test "mac backend acknowledgement refusals keep their distinctions" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = "wantTexts", .out = "refused\ttext_mismatch\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const texts = [_][]const u8{ui.watermark_text_1};
    const f = fx.mac.backend().acknowledge(mac_ctx, .{ .title = "", .texts = &texts, .button = "OK", .class = .known_watermark }).failed;
    try testing.expectEqual(FailureKind.unknown_ui, f.kind);
    try testing.expect(!f.uncertain);
}

test "mac backend progress parses fractions and rejects out of range values" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = "AXProgressIndicator", .out = "ok\tp\t0.5\t1.0\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const p = fx.mac.backend().progress(mac_ctx).fraction;
    try testing.expectEqual(@as(u32, 500), p.done);
    try testing.expectEqual(@as(u32, 1000), p.total);
    try testing.expect(parseProgressReply("ok\tnone") == .none);
    try testing.expect(parseProgressReply("ok\tp\t2\t1").failed.kind == .unknown_ui);
    try testing.expect(parseProgressReply("ok\tp\t-1\t1").failed.kind == .unknown_ui);
    try testing.expect(parseProgressReply("ok\tp\t1\t0").failed.kind == .unknown_ui);
    try testing.expect(parseProgressReply("ok\tp\tx\t1").failed.kind == .unknown_ui);
    try testing.expect(parseProgressReply("ok\tp\tnan\t1").failed.kind == .unknown_ui);
    try testing.expect(parseProgressReply("ok\tp\t1").failed.kind == .transport_error);
    try testing.expect(parseProgressReply("ok\tq").failed.kind == .transport_error);
    try testing.expect(parseProgressReply("ok\tp\t1\t2\t3").failed.kind == .transport_error);
}

test "mac backend screenshots one identified window and never a screen rectangle" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = "AXWindowNumber", .out = "ok\t321\n" },
        .{ .has = "/usr/sbin/screencapture" ++ US, .out = "" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    try testing.expect(b.screenshot(mac_ctx, "/tmp/nur/op/inventory.png") == .done);
    const cap = fx.ft.lastCall();
    try testing.expectEqualStrings("/usr/sbin/screencapture" ++ US ++ "-x" ++ US ++ "-o" ++ US ++ "-l" ++ US ++ "321" ++ US ++ "/tmp/nur/op/inventory.png", cap);
    try testing.expect(std.mem.indexOf(u8, cap, "-R") == null);
    // The window-number call targets the pid and the exact title.
    try testing.expect(std.mem.indexOf(u8, fx.ft.calls.items[0], US ++ "4242" ++ US ++ conv_title) != null);
    const before = fx.ft.calls.items.len;
    try testing.expectEqual(FailureKind.refused, b.screenshot(mac_ctx, "relative.png").failed.kind);
    try testing.expectEqual(FailureKind.refused, b.screenshot(mac_ctx, "/tmp/x.jpg").failed.kind);
    var no_title = mac_ctx;
    no_title.window_title = "";
    try testing.expectEqual(FailureKind.screenshot_unavailable, b.screenshot(no_title, "/tmp/x.png").failed.kind);
    try testing.expectEqual(before, fx.ft.calls.items.len);
}

test "mac backend screenshot fails explicitly when window targeting is unavailable" {
    const cases = [_]struct { id_out: []const u8, cap_code: u8 }{
        .{ .id_out = "refused\tno_window_id\n", .cap_code = 0 },
        .{ .id_out = "refused\twindow_absent\n", .cap_code = 0 },
        .{ .id_out = "ok\t0\n", .cap_code = 0 },
        .{ .id_out = "ok\tabc\n", .cap_code = 0 },
        .{ .id_out = "ok\t321\n", .cap_code = 1 },
    };
    for (cases) |c| {
        const rules = [_]FakeTransport.Rule{
            .{ .has = "AXWindowNumber", .out = c.id_out },
            .{ .has = "/usr/sbin/screencapture" ++ US, .code = c.cap_code },
        };
        var fx = macOnly(&rules);
        fx.start();
        defer fx.stop();
        const f = fx.mac.backend().screenshot(mac_ctx, "/tmp/x.png").failed;
        try testing.expectEqual(FailureKind.screenshot_unavailable, f.kind);
        // No other capture command ran.
        for (fx.ft.calls.items) |call| try testing.expect(std.mem.indexOf(u8, call, "-R") == null);
    }
}

test "mac backend stops when the call budget is already used" {
    const rules = macRules(snapshot_ready, reg_unlocked);
    var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
    fx.start();
    defer fx.stop();
    var c = mac_ctx;
    c.timeout_ms = 1;
    fx.fenv.tick = 5 * std.time.ns_per_ms;
    try testing.expectEqual(FailureKind.timeout, fx.mac.backend().observe(c).failed.kind);
}

const wm_texts = [_][]const u8{ ui.watermark_text_1, ui.watermark_text_2 };
const conv_texts = [_][]const u8{ ui.conversion_text_prefix ++ conv, "Vectorworks" };
const prog_texts = [_][]const u8{ "Opening File: " ++ orig, "Step 10 of 11: Generating Resource Previews...", "", "Vectorworks" };
const save_texts = [_][]const u8{"Save changes before closing?"};
const license_texts = [_][]const u8{"Your trial license has expired."};
const overwrite_texts = [_][]const u8{"model.obj already exists. Do you want to replace it?"};
const wm_win: ui.WindowObservation = .{ .title = "", .modal = true, .texts = &wm_texts, .default_button = "OK" };
const conv_win: ui.WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &conv_texts, .default_button = "OK" };
const prog_win: ui.WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &prog_texts };
const doc_win: ui.WindowObservation = .{ .title = conv_title, .modal = false };
const save_win: ui.WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &save_texts, .default_button = "Save" };
const license_win: ui.WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &license_texts, .default_button = "OK" };
const overwrite_win: ui.WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &overwrite_texts, .default_button = "Replace" };

fn gateReq(allow: bool) GateRequest {
    return .{ .pid = 4242, .policy = .{ .expected = mac_ctx.expected, .allow_conversion_ack = allow, .allow_watermark_ack = allow } };
}

test "calibration run sets options with read back, observes outputs and records timing" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expect(!rep.verified);
    try testing.expectEqual(@as(usize, 5), rep.options.len);
    try testing.expectEqualStrings("Export Materials", rep.options[0].label);
    try testing.expectEqualStrings("1", rep.options[0].requested);
    try testing.expectEqualStrings("1", rep.options[0].observed);
    try testing.expectEqualStrings("High", rep.options[1].observed);
    try testing.expectEqualStrings("1.0", rep.options[2].observed);
    try testing.expectEqualStrings("model.obj", rep.options[3].observed);
    try testing.expectEqualStrings("/tmp/nur/op-1", rep.options[4].observed);
    try testing.expectEqual(@as(usize, 2), rep.files.len);
    try testing.expectEqualStrings("model.obj", rep.files[0].name);
    try testing.expectEqual(@as(u64, 1200), rep.files[0].size);
    try testing.expectEqual(FileRole.primary, rep.files[0].role);
    try testing.expectEqualStrings("model.mtl", rep.files[1].name);
    try testing.expectEqual(FileRole.expected_sidecar, rep.files[1].role);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
    try testing.expectEqual(@as(u32, 5), fx.sim.n(.set));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.press));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    try testing.expectEqual(@as(u32, 6), rep.stats.lookup.count);
    try testing.expectEqual(@as(u32, 6), rep.stats.cache_misses);
    try testing.expect(rep.stats.observe.count >= 4);
    try testing.expect(rep.stats.progress.count >= 3);
    try testing.expect(rep.stats.polls >= 3);
    try testing.expect(rep.stats.elapsed_ns > 0);
    try testing.expect(rep.stats.action.total_ns > 0);
    try testing.expect(fx.rt.reconcileRequired() == null);
}

test "verified run needs calibrated evidence and reports verified only on success" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var bad = fx.rt.runExport(request(.verified, obj_route, "/tmp/nur/op-1"));
    defer bad.deinit(testing.allocator);
    try expectFail(bad, .uncalibrated_route);
    try testing.expect(!bad.verified);
    // The refusal came before any backend call.
    try testing.expectEqual(@as(u32, 0), fx.sim.total());
    var good = fx.rt.runExport(request(.verified, calibrated(obj_route), "/tmp/nur/op-2"));
    defer good.deinit(testing.allocator);
    try testing.expect(good.ok());
    try testing.expect(good.verified);
    // A stale binding is refused even for a calibrated route.
    var req = request(.verified, calibrated(obj_route), "/tmp/nur/op-3");
    req.run_binding.release = "Vectorworks 2028 trial";
    var stale = fx.rt.runExport(req);
    defer stale.deinit(testing.allocator);
    try expectFail(stale, .stale_route);
}

test "locked console, lost process and invalid identity stop before any action" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.console = locked_console;
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .console_locked);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
        try testing.expect(fx.rt.reconcileRequired() == null);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.pid_alive = false;
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .process_lost);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        var req = request(.calibration, obj_route, "/tmp/nur/op-1");
        req.pid = 0;
        var rep = fx.rt.runExport(req);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .process_lost);
        req.pid = 4242;
        req.policy.expected.original = "";
        var rep2 = fx.rt.runExport(req);
        defer rep2.deinit(testing.allocator);
        try expectFail(rep2, .refused);
        try testing.expectEqual(@as(u32, 0), fx.sim.total());
    }
}

test "wrong document, wrong window and missing window stop before any action" {
    const cases = [_]struct { title: ?[]const u8, extra: []const ui.WindowObservation, kind: FailureKind }{
        .{ .title = "other.vwx - WATERMARKED FILE", .extra = &.{}, .kind = .wrong_identity },
        .{ .title = "clock-ClocKit_standard_shafts_extra.vwx", .extra = &.{}, .kind = .wrong_identity },
        .{ .title = conv_title, .extra = &.{.{ .title = "other.vwx", .modal = false }}, .kind = .wrong_identity },
        .{ .title = conv_title, .extra = &.{doc_win}, .kind = .wrong_identity },
        .{ .title = null, .extra = &.{}, .kind = .unknown_ui },
        .{ .title = conv_title ++ "*", .extra = &.{}, .kind = .wrong_identity },
    };
    for (cases) |c| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.doc_title = c.title;
        fx.sim.extra = c.extra;
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, c.kind);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
}

test "known notices, license, save and overwrite dialogs stop an export without any click" {
    const stops = [_]ui.WindowObservation{ wm_win, conv_win, prog_win, save_win, license_win, overwrite_win };
    for (stops) |w| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.extra = &.{w};
        var req = request(.calibration, obj_route, "/tmp/nur/op-1");
        // Even a policy that permits acknowledgement cannot make an export click a notice.
        req.policy.allow_conversion_ack = true;
        req.policy.allow_watermark_ack = true;
        var rep = fx.rt.runExport(req);
        defer rep.deinit(testing.allocator);
        try testing.expect(!rep.ok());
        try testing.expect(rep.failure.?.kind == .unknown_ui);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
}

test "an ambiguous control stops with the partial option record" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.ctls[1].count = 2;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .ambiguous_target);
    try testing.expectEqual(@as(?usize, 2), rep.failure.?.step);
    try testing.expect(!rep.failure.?.uncertain);
    try testing.expectEqual(@as(usize, 1), rep.options.len);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
    try testing.expect(fx.rt.reconcileRequired() == null);
}

test "a missing or disabled control stops after a bounded wait" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.ctls[0].count = 0;
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .unknown_ui);
        try testing.expectEqual(@as(?usize, 1), rep.failure.?.step);
        try testing.expect(fx.fenv.slept_ms >= 5000);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.ctls[5].enabled = false;
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .refused);
        // The confirm button was never pressed.
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.press));
    }
}

test "selector cache serves a hit only while the container layout is unchanged" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.dialog_open = true;
    var op = fx.rt.newOp(4242, .{ .expected = mac_ctx.expected });
    _ = op.setTitle(conv_title);
    try testing.expect(fx.rt.resolve(&op, s_save, false) == .ok);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.lookup));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.identity));
    // Same layout. The identity read replaces the lookup.
    try testing.expect(fx.rt.resolve(&op, s_save, false) == .ok);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.lookup));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.identity));
    try testing.expectEqual(@as(u32, 1), fx.rt.stats.cache_hits);
    // A layout change forces a new lookup.
    fx.sim.layout += 1;
    try testing.expect(fx.rt.resolve(&op, s_save, false) == .ok);
    try testing.expectEqual(@as(u32, 2), fx.sim.n(.lookup));
    try testing.expectEqual(@as(u32, 2), fx.rt.stats.cache_misses);
    // Invalidation forces a lookup without an identity read.
    fx.rt.cache.invalidate();
    const ids = fx.sim.n(.identity);
    try testing.expect(fx.rt.resolve(&op, s_save, false) == .ok);
    try testing.expectEqual(@as(u32, 3), fx.sim.n(.lookup));
    try testing.expectEqual(ids, fx.sim.n(.identity));
    // A closed dialog drops the entry and the lookup reports the control absent.
    fx.sim.dialog_open = false;
    try testing.expectEqual(FailureKind.unknown_ui, fx.rt.resolve(&op, s_save, false).failed.kind);
    // A pid change never matches a cached entry.
    fx.sim.dialog_open = true;
    try testing.expect(fx.rt.resolve(&op, s_save, false) == .ok);
    var op2 = fx.rt.newOp(4243, .{ .expected = mac_ctx.expected });
    _ = op2.setTitle(conv_title);
    const lk = fx.sim.n(.lookup);
    try testing.expect(fx.rt.resolve(&op2, s_save, false) == .ok);
    try testing.expectEqual(lk + 1, fx.sim.n(.lookup));
}

test "route and order rejection happen before any backend call" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    const reordered = [_]Step{ obj_steps[1], obj_steps[0], obj_steps[4], obj_steps[5] };
    var route = obj_route;
    route.steps = &reordered;
    var rep = fx.rt.runExport(request(.calibration, route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .invalid_route);
    var req = request(.calibration, obj_route, "/tmp/nur/op-2");
    req.outputs = .{ .primary = "model.stl" };
    var rep2 = fx.rt.runExport(req);
    defer rep2.deinit(testing.allocator);
    try expectFail(rep2, .invalid_route);
    req = request(.calibration, obj_route, "/tmp/nur/op-3");
    req.scratch = null;
    var rep3 = fx.rt.runExport(req);
    defer rep3.deinit(testing.allocator);
    try expectFail(rep3, .scratch_not_authorized);
    try testing.expectEqual(@as(u32, 0), fx.sim.total());
}

test "an option that reads back differently stops without an uncertain latch" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.ctls[1].readback_override = "Low";
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .incomplete_options);
    try testing.expectEqual(@as(usize, 2), rep.options.len);
    try testing.expectEqualStrings("High", rep.options[1].requested);
    try testing.expectEqualStrings("Low", rep.options[1].observed);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.press));
    try testing.expect(fx.rt.reconcileRequired() == null);
}

test "a failure between actions stops for reconciliation and refuses blind replay" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.fail_call = .set;
    fx.sim.fail_nth = 3;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.transport_error, rep.failure.?.cause);
    try testing.expectEqual(@as(?usize, 3), rep.failure.?.step);
    try testing.expect(rep.failure.?.uncertain);
    try testing.expectEqualStrings("injected", rep.failure.?.detail());
    try testing.expectEqual(@as(usize, 2), rep.options.len);
    try testing.expect(fx.rt.reconcileRequired() != null);
    // A new operation, even in a fresh directory, is refused and sends nothing.
    fx.sim.fail_call = null;
    const calls = fx.sim.total();
    var again = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-2"));
    defer again.deinit(testing.allocator);
    try expectFail(again, .uncertain_mutation);
    try testing.expectEqual(calls, fx.sim.total());
    const gate = fx.rt.waitForDocument(gateReq(false));
    try testing.expectEqual(FailureKind.uncertain_mutation, gate.failure.?.kind);
    try testing.expect(!fx.rt.clearReconcile(""));
    try testing.expect(fx.rt.clearReconcile("dialog state read by the operator"));
    try testing.expect(fx.rt.reconcileRequired() == null);
    var ok = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-3"));
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.ok());
}

test "a failed confirm is uncertain unless the backend proves that it did not run" {
    const cases = [_]struct { f: Failure, uncertain: bool }{
        .{ .f = .{ .kind = .transport_error, .uncertain = true }, .uncertain = true },
        .{ .f = .{ .kind = .timeout }, .uncertain = true },
        .{ .f = .{ .kind = .process_lost }, .uncertain = true },
        .{ .f = .{ .kind = .unknown_ui }, .uncertain = false },
        .{ .f = .{ .kind = .refused }, .uncertain = false },
        .{ .f = .{ .kind = .ambiguous_target }, .uncertain = false },
    };
    for (cases) |c| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.fail_call = .press;
        fx.sim.fail = c.f;
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try testing.expect(!rep.ok());
        try testing.expectEqual(c.uncertain, rep.failure.?.uncertain);
        try testing.expectEqual(c.uncertain, fx.rt.reconcileRequired() != null);
        try testing.expectEqual(@as(?usize, 5), rep.failure.?.step);
    }
}

test "an export that never completes times out as uncertain without real waiting" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .op_deadline_ms = 5000 });
    fx.sim.never_complete = true;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
    try testing.expect(fx.fenv.slept_ms >= 4000 and fx.fenv.slept_ms <= 6000);
    try testing.expect(fx.rt.reconcileRequired() != null);
    // The call budget handed to the backend never exceeds the remaining operation time.
    try testing.expect(rep.stats.polls > 10);
}

test "the run deadline stops later operations" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .run_deadline_ms = 2000 });
    fx.sim.never_complete = true;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expectEqual(FailureKind.deadline_exceeded, rep.failure.?.cause);
    try testing.expect(fx.rt.clearReconcile("checked"));
    const calls = fx.sim.total();
    var rep2 = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-2"));
    defer rep2.deinit(testing.allocator);
    try expectFail(rep2, .deadline_exceeded);
    try testing.expectEqual(calls, fx.sim.total());
    const gate = fx.rt.waitForDocument(gateReq(false));
    try testing.expectEqual(FailureKind.deadline_exceeded, gate.failure.?.kind);
}

test "backend calls receive a shrinking budget" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .op_deadline_ms = 4000, .call_timeout_ms = 10_000 });
    var op = fx.rt.newOp(4242, .{ .expected = mac_ctx.expected });
    const c1 = fx.rt.ctx(&op);
    try testing.expect(c1.timeout_ms <= 4000 and c1.timeout_ms > 3000);
    fx.fenv.slept_ms = 0;
    fx.rt.sleepPoll(2000);
    const c2 = fx.rt.ctx(&op);
    try testing.expect(c2.timeout_ms <= 2000 and c2.timeout_ms >= 1);
    fx.rt.limits.call_timeout_ms = 500;
    try testing.expectEqual(@as(u32, 500), fx.rt.ctx(&op).timeout_ms);
}

test "export progress is recorded and must not regress or leave its range" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.progress_seq = &.{ 100, 100, 600, 1000 };
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.ok());
        try testing.expect(fx.sim.n(.progress) >= 3);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.progress_seq = &.{ 500, 300 };
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.unknown_ui, rep.failure.?.cause);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.progress_seq = &.{1500};
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
    }
    {
        // A route that declares no progress indicator reads none. It has no completion signal, so the
        // export stops uncertain with the raw files in the report and no success.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        var route = obj_route;
        route.progress = false;
        var rep = fx.rt.runExport(request(.calibration, route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.completion_unavailable, rep.failure.?.cause);
        try testing.expect(!rep.completion.established and rep.completion.via == .none);
        try testing.expect(rep.files.len == 2);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.progress));
    }
}

test "a modal during completion stops as uncertain" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var rep = blk: {
        // The overwrite dialog opens after the confirm press.
        fx.sim.never_complete = false;
        fx.sim.fail_call = null;
        const seq_windows = [_]ui.WindowObservation{ doc_win, overwrite_win };
        const preflight = [_]ui.WindowObservation{doc_win};
        const seq = [_][]const ui.WindowObservation{ &preflight, &seq_windows };
        fx.sim.seq = &seq;
        break :blk fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    };
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.unknown_ui, rep.failure.?.cause);
    try testing.expect(fx.rt.reconcileRequired() != null);
}

test "output classification covers missing, empty, unexpected and allowed files" {
    {
        // The completion signal came and the sidecar is not visible. Its publication is outstanding.
        // The operation deadline ends the observation as uncertain. No missing-file verdict follows
        // from elapsed time. The primary file stays in the report.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{ .op_deadline_ms = 5000 });
        fx.sim.out_names = &.{"model.obj"};
        fx.sim.out_sizes = &.{1200};
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.output_unpublished, rep.failure.?.cause);
        try testing.expect(rep.completion.established);
        try testing.expectEqual(@as(usize, 1), rep.files.len);
        try testing.expect(rep.failure.?.uncertain);
    }
    {
        // An empty sidecar is not published yet either.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{ .op_deadline_ms = 5000 });
        fx.sim.out_sizes = &.{ 1200, 0 };
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.output_unpublished, rep.failure.?.cause);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.extra_files = &.{ "tex1.png", "debug.log" };
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.ok());
        try testing.expectEqual(@as(usize, 4), rep.files.len);
        var roles = [_]u32{0} ** 4;
        for (rep.files) |f| roles[@intFromEnum(f.role)] += 1;
        try testing.expectEqual(@as(u32, 1), roles[@intFromEnum(FileRole.primary)]);
        try testing.expectEqual(@as(u32, 1), roles[@intFromEnum(FileRole.expected_sidecar)]);
        try testing.expectEqual(@as(u32, 1), roles[@intFromEnum(FileRole.allowed_sidecar)]);
        try testing.expectEqual(@as(u32, 1), roles[@intFromEnum(FileRole.unexpected)]);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.extra_files = &.{"debug.log"};
        var rep = fx.rt.runExport(request(.verified, calibrated(obj_route), "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .unexpected_output);
        try testing.expect(!rep.verified);
        // The observed files stay in the report.
        try testing.expectEqual(@as(usize, 3), rep.files.len);
    }
}

test "operation directories are separate, empty and used once" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var ok = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.ok());
    var reuse = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer reuse.deinit(testing.allocator);
    try expectFail(reuse, .output_collision);
    const bad_dirs = [_][]const u8{ "relative/op-2", "/tmp/nur/op-2/", "/tmp/nur/../op-2", "/tmp/nur/./op-2", "/", "" };
    for (bad_dirs) |d| {
        var r = request(.calibration, obj_route, "/tmp/nur/op-9");
        r.op_dir = d;
        var rep = fx.rt.runExport(r);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .output_collision);
    }
    var mismatch = request(.calibration, obj_route, "/tmp/nur/op-4");
    mismatch.op_id = "op-5";
    var rep = fx.rt.runExport(mismatch);
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .output_collision);
    // A directory that an earlier failed attempt used is refused even when it is empty.
    var fx4: Fx = .{};
    fx4.start(testing.allocator, .{});
    fx4.sim.pid_alive = false;
    var first = fx4.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-7"));
    defer first.deinit(testing.allocator);
    try expectFail(first, .process_lost);
    fx4.sim.pid_alive = true;
    var second = fx4.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-7"));
    defer second.deinit(testing.allocator);
    try expectFail(second, .output_collision);
    // A directory that already holds a file.
    var fx2: Fx = .{};
    fx2.start(testing.allocator, .{});
    fx2.sim.dir_dirty = true;
    var dirty = fx2.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer dirty.deinit(testing.allocator);
    try expectFail(dirty, .output_collision);
    try testing.expectEqual(@as(u32, 0), fx2.sim.total());
    // A missing directory.
    var fx3: Fx = .{};
    fx3.start(testing.allocator, .{});
    fx3.sim.dir_missing = true;
    var missing = fx3.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer missing.deinit(testing.allocator);
    try expectFail(missing, .missing_output);
}

test "inventory looks up controls, takes a window screenshot and cancels without setting anything" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var req = request(.inventory, obj_route, "/tmp/nur/inv-1");
    req.scratch = null;
    req.run_binding.release = "unobserved release";
    req.screenshot_name = "inventory.png";
    var rep = fx.rt.runExport(req);
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expect(!rep.verified);
    try testing.expectEqual(@as(usize, 6), rep.controls.len);
    for (rep.controls) |c| try testing.expectEqual(@as(u16, 1), c.count);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
    // The only press is the route's cancel button.
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.press));
    try testing.expect(!fx.sim.dialog_open);
    try testing.expectEqualStrings("inventory.png", rep.screenshot.?.name);
    try testing.expectEqual(@as(u64, 100), rep.screenshot.?.size);
    try testing.expectEqual(@as(usize, 0), rep.options.len);
}

test "inventory reports an unavailable screenshot target and refuses stray screenshots" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.fail_call = .screenshot;
        fx.sim.fail = .{ .kind = .screenshot_unavailable, .detail = "no window number" };
        var req = request(.inventory, obj_route, "/tmp/nur/op-1");
        req.screenshot_name = "inventory.png";
        var rep = fx.rt.runExport(req);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .screenshot_unavailable);
        try testing.expectEqual(@as(usize, 6), rep.controls.len);
        try testing.expect(rep.screenshot == null);
        try testing.expect(fx.rt.reconcileRequired() == null);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        var req = request(.calibration, obj_route, "/tmp/nur/op-1");
        req.screenshot_name = "inventory.png";
        var rep = fx.rt.runExport(req);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .refused);
        var req2 = request(.inventory, obj_route, "/tmp/nur/op-2");
        req2.screenshot_name = "../x.png";
        var rep2 = fx.rt.runExport(req2);
        defer rep2.deinit(testing.allocator);
        try expectFail(rep2, .invalid_route);
        req2.op_dir = "/tmp/nur/op-3";
        req2.op_id = "op-3";
        req2.screenshot_name = "x.jpg";
        var rep3 = fx.rt.runExport(req2);
        defer rep3.deinit(testing.allocator);
        try expectFail(rep3, .invalid_route);
        try testing.expectEqual(@as(u32, 0), fx.sim.total());
    }
    {
        // A screenshot that the backend reported but that left no file.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.fail_call = null;
        var req = request(.inventory, obj_route, "/tmp/nur/op-1");
        req.screenshot_name = "other.png";
        var rep = fx.rt.runExport(req);
        defer rep.deinit(testing.allocator);
        // The fake writes any png name, so the file exists. A zero size is the failing case.
        try testing.expect(rep.ok());
    }
}

test "gate acknowledges the conversion and watermark notices once and waits through progress" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    const s1 = [_]ui.WindowObservation{conv_win};
    const s2 = [_]ui.WindowObservation{ wm_win, prog_win };
    const s3 = [_]ui.WindowObservation{prog_win};
    const s4 = [_]ui.WindowObservation{doc_win};
    const seq = [_][]const ui.WindowObservation{ &s1, &s2, &s3, &s4 };
    fx.sim.seq = &seq;
    const g = fx.rt.waitForDocument(gateReq(true));
    try testing.expect(g.failure == null);
    try testing.expect(g.ready);
    try testing.expectEqualStrings(conv_title, g.title());
    try testing.expect(g.acknowledged_conversion and g.acknowledged_watermark);
    try testing.expectEqual(@as(u32, 2), fx.sim.n(.ack));
    try testing.expectEqual(@as(u32, 4), fx.sim.n(.observe));
    // The waits are adaptive. Three observations ended in a wait, each starting at the first interval.
    try testing.expectEqual(@as(u32, 3), fx.rt.stats.poll_waits);
    try testing.expect(fx.fenv.slept_ms >= 3 * fx.rt.limits.poll_min_ms and fx.fenv.slept_ms < 750);
}

test "gate without permission, with a repeated notice or an unknown dialog stops" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        const s1 = [_]ui.WindowObservation{wm_win};
        const seq = [_][]const ui.WindowObservation{&s1};
        fx.sim.seq = &seq;
        const g = fx.rt.waitForDocument(gateReq(false));
        try testing.expectEqual(FailureKind.unknown_ui, g.failure.?.kind);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
        try testing.expect(!g.ready);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        const s1 = [_]ui.WindowObservation{wm_win};
        const seq = [_][]const ui.WindowObservation{&s1};
        fx.sim.seq = &seq;
        const g = fx.rt.waitForDocument(gateReq(true));
        try testing.expectEqual(FailureKind.unknown_ui, g.failure.?.kind);
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.ack));
    }
    const stops = [_]ui.WindowObservation{ save_win, license_win, overwrite_win, prog_win };
    for (stops[0..3]) |w| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        const s1 = [_]ui.WindowObservation{ doc_win, w };
        const seq = [_][]const ui.WindowObservation{&s1};
        fx.sim.seq = &seq;
        const g = fx.rt.waitForDocument(gateReq(true));
        try testing.expectEqual(FailureKind.unknown_ui, g.failure.?.kind);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
}

test "gate acknowledgement failures separate uncertain clicks from refusals" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        const s1 = [_]ui.WindowObservation{conv_win};
        const seq = [_][]const ui.WindowObservation{&s1};
        fx.sim.seq = &seq;
        fx.sim.fail_call = .ack;
        const g = fx.rt.waitForDocument(gateReq(true));
        try testing.expectEqual(FailureKind.uncertain_mutation, g.failure.?.kind);
        try testing.expect(fx.rt.reconcileRequired() != null);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        const s1 = [_]ui.WindowObservation{conv_win};
        const seq = [_][]const ui.WindowObservation{&s1};
        fx.sim.seq = &seq;
        fx.sim.fail_call = .ack;
        fx.sim.fail = .{ .kind = .unknown_ui, .detail = "text differs" };
        const g = fx.rt.waitForDocument(gateReq(true));
        try testing.expectEqual(FailureKind.unknown_ui, g.failure.?.kind);
        try testing.expect(fx.rt.reconcileRequired() == null);
    }
}

test "gate waits for progress until its deadline and reports ready immediately when it can" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{ .op_deadline_ms = 3000 });
        const s1 = [_]ui.WindowObservation{prog_win};
        const seq = [_][]const ui.WindowObservation{&s1};
        fx.sim.seq = &seq;
        const g = fx.rt.waitForDocument(gateReq(true));
        try testing.expectEqual(FailureKind.timeout, g.failure.?.kind);
        try testing.expect(fx.rt.reconcileRequired() == null);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        const g = fx.rt.waitForDocument(gateReq(true));
        try testing.expect(g.ready);
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.observe));
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.console = locked_console;
        const g = fx.rt.waitForDocument(gateReq(true));
        try testing.expectEqual(FailureKind.console_locked, g.failure.?.kind);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        var r = gateReq(true);
        r.pid = -1;
        try testing.expectEqual(FailureKind.process_lost, fx.rt.waitForDocument(r).failure.?.kind);
        r = gateReq(true);
        r.policy.expected.original = "bad";
        try testing.expectEqual(FailureKind.refused, fx.rt.waitForDocument(r).failure.?.kind);
        try testing.expectEqual(@as(u32, 0), fx.sim.total());
    }
}

test "runs allocate only report records and survive every allocation failure" {
    var count: usize = 0;
    var bytes: usize = 0;
    {
        var fa = testing.FailingAllocator.init(testing.allocator, .{});
        var fx: Fx = .{};
        fx.start(fa.allocator(), .{});
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(fa.allocator());
        try testing.expect(rep.ok());
        count = fa.allocations;
        bytes = fa.allocated_bytes;
        std.debug.print("measure runExport allocations={d} bytes={d} options={d} files={d}\n", .{ count, bytes, rep.options.len, rep.files.len });
    }
    try testing.expect(count > 0 and count < 100);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var fx: Fx = .{};
        fx.start(fa.allocator(), .{});
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(fa.allocator());
        const f = rep.failure orelse continue;
        try testing.expect(f.kind == .out_of_memory or f.kind == .missing_output);
    }
}

test "classification and gating allocate nothing" {
    var fa = testing.FailingAllocator.init(testing.allocator, .{});
    var fx: Fx = .{};
    fx.start(fa.allocator(), .{});
    const s1 = [_]ui.WindowObservation{conv_win};
    const s2 = [_]ui.WindowObservation{doc_win};
    const seq = [_][]const ui.WindowObservation{ &s1, &s2 };
    fx.sim.seq = &seq;
    const g = fx.rt.waitForDocument(gateReq(true));
    try testing.expect(g.ready);
    try testing.expectEqual(@as(usize, 0), fa.allocations);
}

test "measure classification and fake-backed run cost" {
    const io = testing.io;
    const wins = [_]ui.WindowObservation{ doc_win, prog_win, wm_win };
    const obs: ui.Observation = .{ .console = ready_console, .windows = &wins, .windows_complete = true };
    const pol = watermarkPolicy();
    var sink: u32 = 0;
    const iterations: u32 = 100_000;
    const t0 = std.Io.Clock.awake.now(io);
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const d = ui.decide(obs, pol);
        sink +%= @intFromEnum(d.kind);
    }
    const t1 = std.Io.Clock.awake.now(io);
    const per_decide = @divTrunc(t0.durationTo(t1).toNanoseconds(), iterations);
    try testing.expect(sink != 0);
    const runs: u32 = 500;
    const t2 = std.Io.Clock.awake.now(io);
    var r: u32 = 0;
    while (r < runs) : (r += 1) {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.ok());
    }
    const t3 = std.Io.Clock.awake.now(io);
    const per_run_us = @divTrunc(t2.durationTo(t3).toNanoseconds(), runs * 1000);
    std.debug.print("measure decide_ns_per_call={d} export_run_us_per_run={d} (3 windows, fake backend, {s})\n", .{ per_decide, per_run_us, @tagName(builtin.mode) });
}

test "feature description lists implemented features and no calibrated route" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeFeatures(&w);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "routes calibrated 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "format pdf\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "format parasolid\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "phase verified\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "feature route_calibration implemented=false") != null);
    // Only the subprocess transport has run in this offline revision.
    var executed: usize = 0;
    for (features) |f| if (f.executed_on_macos) {
        executed += 1;
        try testing.expectEqualStrings("subprocess_transport_with_deadline", f.name);
    };
    try testing.expectEqual(@as(usize, 1), executed);
}

test {
    testing.refAllDecls(@This());
}

// Format and nested sidecar coverage

fn countFormat(list: []const Format, f: Format) usize {
    var n: usize = 0;
    for (list) |x| if (x == f) {
        n += 1;
    };
    return n;
}

test "canonical format ids round trip and reject unknown spellings" {
    const all = std.enums.values(Format);
    try testing.expectEqual(@as(usize, 15), all.len);
    for (all, 0..) |f, i| {
        try testing.expectEqual(@as(?Format, f), formatFromId(formatId(f)));
        for (all[0..i]) |g| try testing.expect(!std.mem.eql(u8, formatId(f), formatId(g)));
    }
    // The internal names serialize under their pack ids.
    try testing.expectEqualStrings("3ds", formatId(.tds));
    try testing.expectEqualStrings("3dm", formatId(.threedm));
    try testing.expectEqual(@as(?Format, .tds), formatFromId("3ds"));
    try testing.expectEqual(@as(?Format, .threedm), formatFromId("3dm"));
    const pack_ids = [_][]const u8{ "obj", "stl", "3ds", "fbx", "parasolid", "step", "pdf", "dxf", "dwg", "png", "sat", "usd", "iges", "3dm", "ifc" };
    for (pack_ids) |id| try testing.expect(formatFromId(id) != null);
    const unknown = [_][]const u8{ "", "tds", "threedm", "3DS", "3DM", "Parasolid", "x_t", "stp", "igs", "usda", "dxf ", " dxf", "svg", "gltf", "3ds\x00", "dwg\n" };
    for (unknown) |id| try testing.expect(formatFromId(id) == null);
}

test "required formats include DXF, DWG and PNG and targeted formats stay separate" {
    const required_ids = [_][]const u8{ "obj", "stl", "3ds", "fbx", "parasolid", "step", "pdf", "dxf", "dwg", "png" };
    try testing.expectEqual(required_ids.len, required_formats.len);
    for (required_ids) |id| {
        const f = formatFromId(id).?;
        try testing.expectEqual(@as(usize, 1), countFormat(&required_formats, f));
        try testing.expectEqual(@as(usize, 1), countFormat(&supported_formats, f));
        try testing.expect(!isTargeted(f));
    }
    for ([_][]const u8{ "sat", "usd", "iges", "3dm", "ifc" }) |id| {
        const f = formatFromId(id).?;
        try testing.expectEqual(@as(usize, 1), countFormat(&targeted_formats, f));
        try testing.expectEqual(@as(usize, 0), countFormat(&supported_formats, f));
        try testing.expect(isTargeted(f));
    }
    try testing.expectEqual(@as(usize, 15), required_formats.len + targeted_formats.len);
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeFeatures(&w);
    const text = w.buffered();
    for (required_ids) |id| {
        var line: [32]u8 = undefined;
        const l = try std.fmt.bufPrint(&line, "format {s}\n", .{id});
        try testing.expect(std.mem.indexOf(u8, text, l) != null);
    }
    for ([_][]const u8{ "sat", "usd", "iges", "3dm", "ifc" }) |id| {
        var line: [48]u8 = undefined;
        const l = try std.fmt.bufPrint(&line, "targeted_format {s}\n", .{id});
        try testing.expect(std.mem.indexOf(u8, text, l) != null);
    }
    try testing.expect(std.mem.indexOf(u8, text, "format tds") == null);
    try testing.expect(std.mem.indexOf(u8, text, "format threedm") == null);
    try testing.expect(std.mem.indexOf(u8, text, "dependency_closure not_established\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "feature nested_sidecar_enumeration implemented=true executed_on_macos=false") != null);
}

const ExtCase = struct { f: Format, good: []const []const u8, bad: []const []const u8 };

const ext_cases = [_]ExtCase{
    .{ .f = .obj, .good = &.{"a.obj"}, .bad = &.{ "a.stl", "a.obj.txt", "a" } },
    .{ .f = .stl, .good = &.{"a.stl"}, .bad = &.{ "a.obj", "a.stlx" } },
    .{ .f = .tds, .good = &.{"a.3ds"}, .bad = &.{ "a.3dm", "a.3dsx" } },
    .{ .f = .fbx, .good = &.{"a.fbx"}, .bad = &.{ "a.fbxx", "a.obj" } },
    .{ .f = .parasolid, .good = &.{ "a.x_t", "a.x_b" }, .bad = &.{ "a.xt", "a.x_tx" } },
    .{ .f = .step, .good = &.{ "a.step", "a.stp", "A.STP" }, .bad = &.{ "a.stl", "a.stpx", "a.steps" } },
    .{ .f = .pdf, .good = &.{"a.pdf"}, .bad = &.{ "a.pdfa", "a.png" } },
    .{ .f = .dxf, .good = &.{ "a.dxf", "A.DXF" }, .bad = &.{ "a.dwg", "a.dxf.txt", "a.dxfx", "a" } },
    .{ .f = .dwg, .good = &.{"a.dwg"}, .bad = &.{ "a.dxf", "a.dwg.bak" } },
    .{ .f = .png, .good = &.{"a.png"}, .bad = &.{ "a.jpg", "a.pngx", "a.pdf" } },
    .{ .f = .sat, .good = &.{"a.sat"}, .bad = &.{ "a.sab", "a.step" } },
    .{ .f = .usd, .good = &.{ "a.usd", "a.usda", "a.usdc" }, .bad = &.{ "a.usdz", "a.usd2", "a.usdaa" } },
    .{ .f = .iges, .good = &.{ "a.igs", "a.iges" }, .bad = &.{ "a.ige", "a.iges2", "a.step" } },
    .{ .f = .threedm, .good = &.{"a.3dm"}, .bad = &.{ "a.3ds", "a.3dmx" } },
    .{ .f = .ifc, .good = &.{"a.ifc"}, .bad = &.{ "a.ifcx", "a.ifczip" } },
};

test "primary extensions are canonical or documented alternatives and wrong formats are refused" {
    const lim: Limits = .{};
    for (ext_cases) |c| {
        for (c.good) |n| try validateOutputs(c.f, .{ .primary = n }, lim);
        for (c.bad) |n| try testing.expectError(error.BadOutputName, validateOutputs(c.f, .{ .primary = n }, lim));
    }
    try testing.expectEqual(ext_cases.len, std.enums.values(Format).len);
    // Every format refuses the primary name of every other format that shares no extension.
    for (ext_cases) |a| for (ext_cases) |b| {
        if (a.f == b.f) continue;
        for (b.good) |n| {
            var shared = false;
            for (a.good) |m| if (std.ascii.eqlIgnoreCase(m, n)) {
                shared = true;
            };
            if (shared) continue;
            try testing.expectError(error.BadOutputName, validateOutputs(a.f, .{ .primary = n }, lim));
        }
    };
}

test "only OBJ and 3DS accept sidecars" {
    const lim: Limits = .{};
    for (ext_cases) |c| {
        if (c.f == .obj or c.f == .tds) continue;
        try testing.expectError(error.BadSidecar, validateOutputs(c.f, .{ .primary = c.good[0], .required_sidecars = &.{"tex/a.png"} }, lim));
        try testing.expectError(error.BadSidecar, validateOutputs(c.f, .{ .primary = c.good[0], .allowed_sidecar_exts = &.{".png"} }, lim));
    }
}

test "relative sidecar paths accept nested exporter layouts" {
    const lim: Limits = .{};
    try validateOutputs(.obj, .{ .primary = "model.obj", .required_sidecars = &.{ "model.mtl", "textures/wood/oak.png", "textures/wood/oak_n.png", "textures/stone/s.jpg" }, .allowed_sidecar_exts = &.{ ".png", ".jpg" } }, lim);
    try validateOutputs(.tds, .{ .primary = "scene.3ds", .required_sidecars = &.{ "tex/tex_001.png", "tex/tex_002.jpg" }, .allowed_sidecar_exts = &.{ ".png", ".jpg" } }, lim);
    // Eight components are the limit.
    try validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{"a/b/c/d/e/f/g/h.png"} }, lim);
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{"a/b/c/d/e/f/g/h/i.png"} }, lim));
    try testing.expect(validRelPath("a/b.png", lim));
    try testing.expect(!validRelPath("", lim));
    try testing.expect(!validRelPath("a" ** 600, lim));
}

test "relative sidecar paths refuse traversal, aliases and unsafe names" {
    const lim: Limits = .{};
    const bad = [_][]const u8{
        "/abs/a.png",
        "../a.png",
        "a/../b.png",
        "a//b.png",
        "a/./b.png",
        "./a.png",
        "a/b.png/",
        "a\\b.png",
        "tex/.hidden.png",
        ".tex/a.png",
        "tex/a.exe",
        "tex.d/noext",
        "tex/a.png\n",
        "",
        "/",
    };
    for (bad) |s| try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{s} }, lim));
    // Duplicates, case aliases and file/directory conflicts.
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{ "tex/a.png", "tex/a.png" } }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{ "tex/a.png", "TEX/A.png" } }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{ "a.png", "a.png/b.png" } }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{ "A.PNG/b.png", "a.png" } }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{"m.obj/x.mtl"} }, lim));
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .required_sidecars = &.{"M.OBJ"} }, lim));
    // Allowed extensions never hold a path.
    try testing.expectError(error.BadSidecar, validateOutputs(.obj, .{ .primary = "m.obj", .allowed_sidecar_exts = &.{".png/x"} }, lim));
    // The primary destination stays a basename.
    for ([_][]const u8{ "dir/m.obj", "/m.obj", "../m.obj", "a/../m.obj" }) |p| {
        try testing.expectError(error.BadOutputName, validateOutputs(.obj, .{ .primary = p }, lim));
    }
}

const extra_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export As" } },
    .{ .option = .{ .selector = sheet(.popup, "Version"), .value = .{ .choice = "Default" } } },
    .{ .destination = .{ .name_field = s_name, .dir_field = s_where } },
    .{ .confirm = s_save },
};

const extra_primary = [_]struct { f: Format, name: []const u8 }{
    .{ .f = .dxf, .name = "plan.dxf" },
    .{ .f = .dwg, .name = "plan.dwg" },
    .{ .f = .png, .name = "view.png" },
    .{ .f = .sat, .name = "solid.sat" },
    .{ .f = .usd, .name = "scene.usda" },
    .{ .f = .iges, .name = "part.igs" },
    .{ .f = .threedm, .name = "model.3dm" },
    .{ .f = .ifc, .name = "building.ifc" },
};

test "new required and targeted formats run inventory and calibration and only required ones verify" {
    for (extra_primary) |c| {
        const route: Route = .{ .id = formatId(c.f), .format = c.f, .steps = &extra_steps, .cancel = s_cancel, .progress = true, .progress_id = "export-progress", .binding = bind };
        const fcase: FmtCase = .{ .format = c.f, .steps = &extra_steps, .outputs = .{ .primary = c.name } };
        try validateRoute(route, .verified, .{});
        try validateOutputs(c.f, fcase.outputs, .{});
        // Calibration.
        {
            var fx: Fx = .{};
            var names: [8][]const u8 = undefined;
            var sizes: [8]u64 = undefined;
            simForCase(&fx.sim, fcase, &names, &sizes);
            fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), .{});
            var req = request(.calibration, route, "/tmp/nur/op-x1");
            req.outputs = fcase.outputs;
            var rep = fx.rt.runExport(req);
            defer rep.deinit(testing.allocator);
            try testing.expect(rep.ok());
            try testing.expect(!rep.verified);
            try testing.expectEqual(@as(usize, 1), rep.files.len);
            try testing.expectEqualStrings(c.name, rep.files[0].name);
        }
        // Inventory records controls and sets nothing.
        {
            var fx: Fx = .{};
            var names: [8][]const u8 = undefined;
            var sizes: [8]u64 = undefined;
            simForCase(&fx.sim, fcase, &names, &sizes);
            fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), .{});
            var req = request(.inventory, route, "/tmp/nur/op-x2");
            req.outputs = fcase.outputs;
            req.scratch = null;
            var rep = fx.rt.runExport(req);
            defer rep.deinit(testing.allocator);
            try testing.expect(rep.ok());
            try testing.expectEqual(@as(usize, 4), rep.controls.len);
            try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
        }
        // Verification: required formats pass with evidence, targeted formats are refused.
        {
            var fx: Fx = .{};
            var names: [8][]const u8 = undefined;
            var sizes: [8]u64 = undefined;
            simForCase(&fx.sim, fcase, &names, &sizes);
            fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), .{});
            var req = request(.verified, calibrated(route), "/tmp/nur/op-x3");
            req.outputs = fcase.outputs;
            var rep = fx.rt.runExport(req);
            defer rep.deinit(testing.allocator);
            if (isTargeted(c.f)) {
                try expectFail(rep, .refused);
                try testing.expectEqual(@as(u32, 0), fx.sim.total());
                try testing.expect(!rep.verified);
            } else {
                try testing.expect(rep.ok());
                try testing.expect(rep.verified);
            }
        }
    }
}

test "checkPhase refuses a verified targeted format even with matching evidence" {
    for (targeted_formats) |f| {
        const route: Route = .{ .id = formatId(f), .format = f, .steps = &extra_steps, .binding = bind };
        try testing.expectEqual(FailureKind.refused, checkPhase(.verified, calibrated(route), bind, null, .{}).?.kind);
        try testing.expect(checkPhase(.calibration, route, bind, .{ .session = "s1" }, .{}) == null);
        try testing.expect(checkPhase(.inventory, route, bind, null, .{}) == null);
    }
    for (required_formats) |f| {
        const route: Route = .{ .id = formatId(f), .format = f, .steps = &extra_steps, .binding = bind };
        try testing.expect(checkPhase(.verified, calibrated(route), bind, null, .{}) == null);
    }
}

const nested_obj_outputs: ExpectedOutputs = .{
    .primary = "model.obj",
    .required_sidecars = &.{ "model.mtl", "textures/wood/oak.png", "textures/wood/oak_n.png" },
    .allowed_sidecar_exts = &.{".png"},
};

const nested_obj_entries = [_]SimEntry{
    .{ .path = "textures/wood/oak_n.png", .size = 30 },
    .{ .path = "model.mtl", .size = 80 },
    .{ .path = "textures", .kind = .directory },
    .{ .path = "model.obj", .size = 1200 },
    .{ .path = "textures/wood", .kind = .directory },
    .{ .path = "textures/wood/oak.png", .size = 20 },
    .{ .path = "textures/extra.png", .size = 7 },
};

fn walkFx(fx: *Fx) void {
    fx.start(testing.allocator, .{});
    fx.rt.files = fx.sim.filesWalk();
}

fn nestedRequest(dir: []const u8) ExportRequest {
    var req = request(.calibration, obj_route, dir);
    req.outputs = nested_obj_outputs;
    return req;
}

test "nested OBJ, MTL and texture sidecars keep their exporter-relative names" {
    var fx: Fx = .{};
    walkFx(&fx);
    fx.sim.walk_list = &nested_obj_entries;
    var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    const want = [_]struct { name: []const u8, size: u64, role: FileRole }{
        .{ .name = "model.mtl", .size = 80, .role = .expected_sidecar },
        .{ .name = "model.obj", .size = 1200, .role = .primary },
        .{ .name = "textures/extra.png", .size = 7, .role = .allowed_sidecar },
        .{ .name = "textures/wood/oak.png", .size = 20, .role = .expected_sidecar },
        .{ .name = "textures/wood/oak_n.png", .size = 30, .role = .expected_sidecar },
    };
    try testing.expectEqual(want.len, rep.files.len);
    for (want, rep.files) |w, f| {
        try testing.expectEqualStrings(w.name, f.name);
        try testing.expectEqual(w.size, f.size);
        try testing.expectEqual(w.role, f.role);
    }
    // A listing with roles is not a dependency closure.
    try testing.expectEqual(DependencyClosure.not_established, rep.dependency_closure);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
}

test "nested 3DS texture directories are returned without flattening" {
    const outputs: ExpectedOutputs = .{ .primary = "scene.3ds", .required_sidecars = &.{ "tex/tex_001.png", "tex/tex_002.jpg" }, .allowed_sidecar_exts = &.{ ".png", ".jpg" } };
    const c: FmtCase = .{ .format = .tds, .steps = &tds_steps, .outputs = outputs };
    var fx: Fx = .{};
    var names: [8][]const u8 = undefined;
    var sizes: [8]u64 = undefined;
    simForCase(&fx.sim, c, &names, &sizes);
    fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.filesWalk(), .{});
    const entries = [_]SimEntry{
        .{ .path = "tex/tex_002.jpg", .size = 40 },
        .{ .path = "scene.3ds", .size = 1000 },
        .{ .path = "tex", .kind = .directory },
        .{ .path = "tex/tex_001.png", .size = 50 },
        .{ .path = "tex/tex_003.png", .size = 60 },
    };
    fx.sim.walk_list = &entries;
    const route: Route = .{ .id = "3ds", .format = .tds, .steps = &tds_steps, .cancel = s_cancel, .progress = true, .progress_id = "export-progress", .binding = bind };
    var req = request(.calibration, route, "/tmp/nur/op-n2");
    req.outputs = outputs;
    var rep = fx.rt.runExport(req);
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 4), rep.files.len);
    try testing.expectEqualStrings("scene.3ds", rep.files[0].name);
    try testing.expectEqualStrings("tex/tex_001.png", rep.files[1].name);
    try testing.expectEqual(FileRole.expected_sidecar, rep.files[1].role);
    try testing.expectEqualStrings("tex/tex_002.jpg", rep.files[2].name);
    try testing.expectEqualStrings("tex/tex_003.png", rep.files[3].name);
    try testing.expectEqual(FileRole.allowed_sidecar, rep.files[3].role);
}

fn expectUnsafe(extra: SimEntry, replace_at: ?usize) !void {
    var buf: [16]SimEntry = undefined;
    @memcpy(buf[0..nested_obj_entries.len], &nested_obj_entries);
    var n: usize = nested_obj_entries.len;
    if (replace_at) |i| {
        buf[i] = extra;
    } else {
        buf[n] = extra;
        n += 1;
    }
    var fx: Fx = .{};
    walkFx(&fx);
    fx.sim.walk_list = buf[0..n];
    var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n3"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unexpected_output);
    try testing.expect(!rep.failure.?.uncertain);
    try testing.expect(fx.rt.reconcileRequired() == null);
    try testing.expect(!rep.verified);
}

test "unsafe directory entries are refused in every phase" {
    // Symbolic link, special file, hard-linked file.
    try expectUnsafe(.{ .path = "textures/link.png", .kind = .symlink }, null);
    try expectUnsafe(.{ .path = "pipe", .kind = .other }, null);
    try expectUnsafe(.{ .path = "model.mtl", .size = 80, .nlink = 2 }, 1);
    // A link in place of an expected file.
    try expectUnsafe(.{ .path = "textures/wood/oak.png", .kind = .symlink }, 5);
    // Case aliases between entries and of expected names.
    try expectUnsafe(.{ .path = "Textures/wood/oak.png", .size = 20 }, null);
    try expectUnsafe(.{ .path = "Textures", .kind = .directory }, null);
    try expectUnsafe(.{ .path = "textures/wood/OAK.png", .size = 20 }, 5);
    try expectUnsafe(.{ .path = "MODEL.OBJ", .size = 5 }, null);
    try expectUnsafe(.{ .path = "MODEL.OBJ", .size = 1200 }, 3);
    // Unsafe paths.
    const paths = [_][]const u8{ "../evil.png", "/abs/x.png", "a//b.png", "./x.png", "textures/./x.png", "tex\\x.png", ".hidden.png", "textures/", "a/b/c/d/e/f/g/h/i.png" };
    for (paths) |p| try expectUnsafe(.{ .path = p }, null);
    // A file that is also used as a directory.
    try expectUnsafe(.{ .path = "textures/extra.png/inner.png" }, null);
}

test "unsafe entries also fail the verified phase and leave records unreported" {
    var fx: Fx = .{};
    walkFx(&fx);
    var buf: [16]SimEntry = undefined;
    @memcpy(buf[0..nested_obj_entries.len], &nested_obj_entries);
    buf[nested_obj_entries.len] = .{ .path = "textures/link.png", .kind = .symlink };
    fx.sim.walk_list = buf[0 .. nested_obj_entries.len + 1];
    var req = request(.verified, calibrated(obj_route), "/tmp/nur/op-n4");
    req.outputs = nested_obj_outputs;
    var rep = fx.rt.runExport(req);
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unexpected_output);
    try testing.expect(!rep.verified);
    try testing.expectEqual(@as(usize, 0), rep.files.len);
}

test "nested listings report missing, empty and unexpected sidecars and unreadable trees" {
    // A required nested texture is absent.
    {
        var fx: Fx = .{};
        walkFx(&fx);
        fx.sim.walk_list = nested_obj_entries[0..6];
        const without = [_]SimEntry{ nested_obj_entries[0], nested_obj_entries[1], nested_obj_entries[2], nested_obj_entries[3], nested_obj_entries[4] };
        fx.sim.walk_list = &without;
        var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n5"));
        defer rep.deinit(testing.allocator);
        // The completion signal came and a required nested texture is not visible. Its publication is
        // outstanding until the hard budget ends the observation as uncertain.
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.output_unpublished, rep.failure.?.cause);
        try testing.expectEqual(@as(usize, 3), rep.files.len);
    }
    // A required nested texture is empty.
    {
        var fx: Fx = .{};
        walkFx(&fx);
        var buf: [8]SimEntry = undefined;
        @memcpy(buf[0..nested_obj_entries.len], &nested_obj_entries);
        buf[0].size = 0;
        fx.sim.walk_list = buf[0..nested_obj_entries.len];
        var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n6"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.output_unpublished, rep.failure.?.cause);
    }
    // The primary is only present in a subdirectory.
    {
        var fx: Fx = .{};
        walkFx(&fx);
        const nested_primary = [_]SimEntry{ .{ .path = "sub", .kind = .directory }, .{ .path = "sub/model.obj" }, .{ .path = "model.mtl" } };
        fx.sim.walk_list = &nested_primary;
        var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n7"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.output_unpublished, rep.failure.?.cause);
    }
    // An unreadable or oversized tree.
    {
        var fx: Fx = .{};
        walkFx(&fx);
        fx.sim.walk_list = &nested_obj_entries;
        fx.sim.walk_fail = true;
        var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n8"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .missing_output);
    }
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{ .max_walk_entries = 3 });
        fx.rt.files = fx.sim.filesWalk();
        fx.sim.walk_list = &nested_obj_entries;
        var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n9"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .missing_output);
    }
    // An unexpected nested file fails the verified phase and is reported in calibration.
    {
        var fx: Fx = .{};
        walkFx(&fx);
        var buf: [16]SimEntry = undefined;
        @memcpy(buf[0..nested_obj_entries.len], &nested_obj_entries);
        buf[nested_obj_entries.len] = .{ .path = "textures/note.txt" };
        fx.sim.walk_list = buf[0 .. nested_obj_entries.len + 1];
        var req = request(.verified, calibrated(obj_route), "/tmp/nur/op-n10");
        req.outputs = nested_obj_outputs;
        var rep = fx.rt.runExport(req);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .unexpected_output);
        try testing.expectEqual(@as(usize, 6), rep.files.len);
        var fx2: Fx = .{};
        walkFx(&fx2);
        fx2.sim.walk_list = buf[0 .. nested_obj_entries.len + 1];
        var rep2 = fx2.rt.runExport(nestedRequest("/tmp/nur/op-n11"));
        defer rep2.deinit(testing.allocator);
        try testing.expect(rep2.ok());
        try testing.expectEqual(FileRole.unexpected, rep2.files[3].role);
    }
}

test "a file backend without recursion refuses nested sidecars before any call" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-n12"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .invalid_route);
    try testing.expectEqual(@as(u32, 0), fx.sim.total());
}

fn shell(a: Allocator, script: []const u8, arg: []const u8) RunOutput {
    var pt: ProcessTransport = .{ .io = testing.io };
    return pt.transport().run(a, &.{ "/bin/sh", "-c", script, "sh", arg }, 10_000, .{});
}

fn discardTree(a: Allocator, path: []const u8) bool {
    const r = shell(a, "root=$(git rev-parse --show-toplevel) && . \"$root/tools/discard.sh\" && discard \"$1\"", path);
    defer r.deinit(a);
    return r.succeeded();
}

test "system files walk a scratch tree without following links" {
    const mk = shell(testing.allocator,
        \\set -e
        \\b=$(mktemp -d /tmp/nui-walk.XXXXXX)
        \\mkdir -p $b/clean/tex/wood $b/clean/tex/empty $b/links $b/fifo $b/deep
        \\printf x > $b/clean/model.obj; printf y > $b/clean/model.mtl; printf z > $b/clean/tex/wood/oak.png
        \\printf x > $b/links/a.obj; ln -s a.obj $b/links/sym.obj; ln $b/links/a.obj $b/links/hard.obj
        \\ln -s clean $b/rootlink
        \\mkfifo $b/fifo/pipe
        \\d=$b/deep; for i in 1 2 3 4 5 6 7 8 9; do d=$d/d$i; mkdir $d; done; printf q > $d/f.png
        \\printf '%s' "$b"
    , "");
    defer mk.deinit(testing.allocator);
    try testing.expect(mk.succeeded());
    const base = try testing.allocator.dupe(u8, mk.stdout);
    defer testing.allocator.free(base);
    var ok_cleanup = false;
    defer if (!ok_cleanup) {
        _ = discardTree(testing.allocator, base);
    };

    var sf: SystemFiles = .{ .io = testing.io };
    const f = sf.files();
    const lim: WalkLimits = .{ .max_entries = 256, .max_depth = max_sidecar_depth };
    var path_buf: [256]u8 = undefined;
    {
        const dir = try std.fmt.bufPrint(&path_buf, "{s}/clean", .{base});
        const entries = f.walk(testing.allocator, dir, lim).?;
        defer freeWalk(testing.allocator, entries);
        std.mem.sort(WalkEntry, entries, {}, Runtime.lessPath);
        const want = [_]struct { p: []const u8, k: EntryKind, s: u64 }{
            .{ .p = "model.mtl", .k = .file, .s = 1 },
            .{ .p = "model.obj", .k = .file, .s = 1 },
            .{ .p = "tex", .k = .directory, .s = 0 },
            .{ .p = "tex/empty", .k = .directory, .s = 0 },
            .{ .p = "tex/wood", .k = .directory, .s = 0 },
            .{ .p = "tex/wood/oak.png", .k = .file, .s = 1 },
        };
        try testing.expectEqual(want.len, entries.len);
        for (want, entries) |w, e| {
            try testing.expectEqualStrings(w.p, e.path);
            try testing.expectEqual(w.k, e.kind);
            try testing.expectEqual(w.s, e.size);
            try testing.expectEqual(@as(u64, 1), e.nlink);
        }
        // The runtime accepts this tree as a nested OBJ export.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.rt.files = f;
        var req = request(.calibration, obj_route, dir);
        req.outputs = .{ .primary = "model.obj", .required_sidecars = &.{ "model.mtl", "tex/wood/oak.png" } };
        var bld: Builder = .{};
        defer bld.deinit(testing.allocator);
        try testing.expect(fx.rt.collectWalk(req, &bld) == null);
        try testing.expectEqual(@as(usize, 3), bld.files.items.len);
        try testing.expectEqualStrings("tex/wood/oak.png", bld.files.items[2].name);
    }
    {
        const dir = try std.fmt.bufPrint(&path_buf, "{s}/links", .{base});
        const entries = f.walk(testing.allocator, dir, lim).?;
        defer freeWalk(testing.allocator, entries);
        var links: usize = 0;
        var multi: usize = 0;
        for (entries) |e| {
            if (e.kind == .symlink) links += 1;
            if (e.kind == .file and e.nlink == 2) multi += 1;
        }
        try testing.expectEqual(@as(usize, 1), links);
        try testing.expectEqual(@as(usize, 2), multi);
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.rt.files = f;
        var req = request(.calibration, obj_route, dir);
        req.outputs = .{ .primary = "a.obj" };
        var bld: Builder = .{};
        defer bld.deinit(testing.allocator);
        try testing.expectEqual(FailureKind.unexpected_output, fx.rt.collectWalk(req, &bld).?.kind);
    }
    {
        const dir = try std.fmt.bufPrint(&path_buf, "{s}/fifo", .{base});
        const entries = f.walk(testing.allocator, dir, lim).?;
        defer freeWalk(testing.allocator, entries);
        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqual(EntryKind.other, entries[0].kind);
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.rt.files = f;
        var req = request(.calibration, obj_route, dir);
        req.outputs = .{ .primary = "m.obj" };
        var bld: Builder = .{};
        defer bld.deinit(testing.allocator);
        try testing.expectEqual(FailureKind.unexpected_output, fx.rt.collectWalk(req, &bld).?.kind);
    }
    {
        // Nine nested directories exceed the depth limit.
        const dir = try std.fmt.bufPrint(&path_buf, "{s}/deep", .{base});
        try testing.expect(f.walk(testing.allocator, dir, lim) == null);
        const deeper = f.walk(testing.allocator, dir, .{ .max_entries = 256, .max_depth = 12 }).?;
        freeWalk(testing.allocator, deeper);
    }
    {
        // A root that is a symbolic link is refused. An entry limit and a missing root give null.
        const root_link = try std.fmt.bufPrint(&path_buf, "{s}/rootlink", .{base});
        try testing.expect(f.walk(testing.allocator, root_link, lim) == null);
        const dir = try std.fmt.bufPrint(&path_buf, "{s}/clean", .{base});
        try testing.expect(f.walk(testing.allocator, dir, .{ .max_entries = 2, .max_depth = 8 }) == null);
        try testing.expect(f.walk(testing.allocator, "/nonexistent-walk-dir", lim) == null);
    }
    try testing.expect(discardTree(testing.allocator, base));
    ok_cleanup = true;
    try testing.expect(f.list(testing.allocator, base, 10) == null);
}

test "walk allocation failures free every entry" {
    var sf: SystemFiles = .{ .io = testing.io };
    const f = sf.files();
    // /bin holds enough entries for several allocations and no nested directories. Depth 0 and a
    // small entry cap keep the walk bounded.
    var count: usize = 0;
    {
        var fa = testing.FailingAllocator.init(testing.allocator, .{});
        const r = f.walk(fa.allocator(), "/usr/share/zoneinfo/America/Argentina", .{ .max_entries = 64, .max_depth = 2 });
        if (r) |entries| {
            freeWalk(fa.allocator(), entries);
            count = fa.allocations;
        }
    }
    try testing.expect(count > 0);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        if (f.walk(fa.allocator(), "/usr/share/zoneinfo/America/Argentina", .{ .max_entries = 64, .max_depth = 2 })) |entries| freeWalk(fa.allocator(), entries);
    }
}

// Observed-condition waiter and acquisition diagnostics

const FakeNotifier = struct {
    sim: *Sim,
    fenv: *FakeEnv,
    /// Waits that end early with a notification. The next waits run to their interval, as a lost
    /// notification would.
    wake_budget: u32 = 0,
    wakes: u32 = 0,
    timeouts: u32 = 0,
    arms: u32 = 0,
    /// Mutating calls that the fake backend had seen when each subscription was made.
    snaps: [16]u32 = undefined,

    fn notifier(n: *FakeNotifier) Notifier {
        return .{ .ptr = n, .armFn = armImpl, .waitFn = waitImpl };
    }

    fn armImpl(p: *anyopaque, pid: i32) void {
        _ = pid;
        const n: *FakeNotifier = @ptrCast(@alignCast(p));
        if (n.arms < n.snaps.len) n.snaps[n.arms] = n.sim.mutations();
        n.arms += 1;
    }

    fn waitImpl(p: *anyopaque, max_ms: u32) bool {
        const n: *FakeNotifier = @ptrCast(@alignCast(p));
        if (n.wake_budget > 0) {
            n.wake_budget -= 1;
            n.wakes += 1;
            n.fenv.t += std.time.ns_per_ms;
            return true;
        }
        n.timeouts += 1;
        n.fenv.t += @as(u64, max_ms) * std.time.ns_per_ms;
        return false;
    }
};

const FakeDiag = struct {
    calls: u32 = 0,
    captured: bool = true,
    reason: []const u8 = "",
    expected: []const u8 = "",
    last_action: []const u8 = "",

    fn hook(d: *FakeDiag) Diagnostic {
        return .{ .ptr = d, .captureFn = captureImpl };
    }

    fn captureImpl(p: *anyopaque, req: DiagRequest) DiagResult {
        const d: *FakeDiag = @ptrCast(@alignCast(p));
        d.calls += 1;
        d.reason = req.reason;
        d.expected = req.expected;
        d.last_action = req.last_action;
        if (!d.captured) return .{ .captured = false, .detail = "the capture module refused the window" };
        return .{ .captured = true, .detail = "/tmp/nur-diag/diag-4242-1" };
    }
};

/// A correlated progress transition at pass 8, 14 and 40. The readings stay at 300 until the last pass.
const late_done_8 = [_]u32{300} ** 7 ++ [_]u32{1000};
const late_done_14 = [_]u32{300} ** 13 ++ [_]u32{1000};
const late_done_40 = [_]u32{300} ** 39 ++ [_]u32{1000};

const surprise_texts = [_][]const u8{"Something unexpected happened"};
const surprise_win: ui.WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &surprise_texts, .default_button = "OK" };

test "waits start at the first interval, double while nothing changes and stay under poll_ms" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.complete_after = 14;
    fx.sim.progress_seq = &late_done_14;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    const want = [_]u32{ 10, 20, 40, 80, 160, 250 };
    try testing.expectEqualSlices(u32, &want, fx.fenv.sleeps[0..want.len]);
    for (fx.fenv.sleeps[0..fx.fenv.sleep_n]) |ms| try testing.expect(ms <= fx.rt.limits.poll_ms);
    // Polling is labeled. Every wait was a timer wait because no notifier is present.
    try testing.expectEqual(@as(u32, @intCast(fx.fenv.sleep_n)), rep.stats.poll_waits);
    try testing.expectEqual(@as(u32, 0), rep.stats.wakeups);
}

test "a transition that is already complete is accepted at the first observation" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.complete_after = 0;
    // The indicator appeared after the press and shows its total. No wait is needed.
    fx.sim.progress_seq = &.{1000};
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expect(rep.completion.established and rep.completion.via == .progress_transition);
    try testing.expectEqual(@as(?u32, null), rep.completion.baseline);
    try testing.expectEqual(@as(u64, 0), fx.fenv.slept_ms);
    try testing.expectEqual(@as(u32, 1), rep.stats.polls);
}

test "notifications end a wait early, a lost one falls back to the bounded poll and each action is armed first" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var nf: FakeNotifier = .{ .sim = &fx.sim, .fenv = &fx.fenv, .wake_budget = 3 };
    fx.rt.notifier = nf.notifier();
    fx.sim.complete_after = 8;
    fx.sim.progress_seq = &late_done_8;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(u32, 3), rep.stats.wakeups);
    try testing.expect(rep.stats.poll_waits >= 1);
    try testing.expectEqual(nf.timeouts, rep.stats.poll_waits);
    try testing.expectEqual(@as(u64, 0), fx.fenv.slept_ms);
    // One subscription per mutating call, each made before that call reached the backend.
    try testing.expectEqual(fx.sim.mutations(), nf.arms);
    var i: u32 = 0;
    while (i < nf.arms) : (i += 1) try testing.expectEqual(i, nf.snaps[i]);
}

test "a late control is awaited with short waits and found" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.late_lookups = 4;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(u32, 10), fx.fenv.sleeps[0]);
    try testing.expectEqual(@as(u32, 20), fx.fenv.sleeps[1]);
    try testing.expect(fx.fenv.slept_ms < 1000);
}

test "an unknown dialog is captured once before any action and its failure stays" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.rt.diag_dir = "/tmp/nur-diag";
    fx.sim.extra = &.{surprise_win};
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unknown_ui);
    const d = rep.failure.?.diag;
    try testing.expect(d.attempted and d.captured);
    try testing.expectEqualStrings("unknown_modal", d.reason);
    try testing.expectEqualStrings("/tmp/nur-diag/diag-4242-1.png", d.note());
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.screenshot));
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    try testing.expectEqual(@as(u32, 1), rep.stats.diagnostics);
    try testing.expect(fx.rt.reconcileRequired() == null);
}

test "a failed selector is captured while the dialog is still open" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .cancel_after_failure = true });
    fx.rt.diag_dir = "/tmp/nur-diag";
    fx.sim.ctls[0].count = 0;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unknown_ui);
    const d = rep.failure.?.diag;
    try testing.expect(d.captured);
    try testing.expectEqualStrings("selector_failed", d.reason);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.screenshot));
    // The cancel press comes after the capture.
    try testing.expectEqual(@as(u32, 0), fx.sim.presses_at_shot);
}

test "the diagnostic hook receives the expected condition and the last action" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .cancel_after_failure = true });
    var dg: FakeDiag = .{};
    fx.rt.diagnostic = dg.hook();
    fx.sim.ctls[0].count = 0;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unknown_ui);
    try testing.expectEqual(@as(u32, 1), dg.calls);
    try testing.expectEqualStrings("selector_failed", dg.reason);
    try testing.expectEqualStrings("Export Materials", dg.expected);
    try testing.expectEqualStrings("menu", dg.last_action);
    try testing.expect(rep.failure.?.diag.captured);
    try testing.expectEqualStrings("/tmp/nur-diag/diag-4242-1", rep.failure.?.diag.note());
    // The hook replaces the built-in screenshot.
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.screenshot));
}

test "a missing transition raises one stall capture and the wait goes on to the deadline" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .op_deadline_ms = 5000, .stall_ms = 1000 });
    fx.rt.diag_dir = "/tmp/nur-diag";
    fx.sim.never_complete = true;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
    const d = rep.failure.?.diag;
    try testing.expect(d.captured);
    try testing.expectEqualStrings("stall", d.reason);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.screenshot));
    // The stall capture did not end the wait. The deadline did.
    try testing.expect(fx.fenv.slept_ms >= 4000);
    try testing.expect(fx.rt.reconcileRequired() != null);
}

test "a slow export that completes after the stall trigger is accepted with its files" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .stall_ms = 300 });
    fx.rt.diag_dir = "/tmp/nur-diag";
    fx.sim.complete_after = 40;
    fx.sim.progress_seq = &late_done_40;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 2), rep.files.len);
    try testing.expect(rep.diag.attempted and rep.diag.captured);
    try testing.expectEqualStrings("stall", rep.diag.reason);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.screenshot));
    try testing.expect(fx.rt.reconcileRequired() == null);
}

test "a failed diagnostic capture keeps the original failure and the recovery latch" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .op_deadline_ms = 5000, .stall_ms = 1000 });
    fx.rt.diag_dir = "/tmp/nur-diag";
    fx.sim.never_complete = true;
    fx.sim.fail_call = .screenshot;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
    const d = rep.failure.?.diag;
    try testing.expect(d.attempted and !d.captured);
    try testing.expect(std.mem.startsWith(u8, d.note(), "screenshot failed"));
    try testing.expect(fx.rt.reconcileRequired() != null);
    try testing.expectEqual(FailureKind.timeout, fx.rt.reconcileRequired().?.cause);
    try testing.expect(fx.rt.clearReconcile("checked"));
}

test "a hook that fails to capture leaves the failure unchanged" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var dg: FakeDiag = .{ .captured = false };
    fx.rt.diagnostic = dg.hook();
    fx.sim.extra = &.{surprise_win};
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unknown_ui);
    try testing.expect(rep.failure.?.diag.attempted and !rep.failure.?.diag.captured);
    try testing.expectEqualStrings("the capture module refused the window", rep.failure.?.diag.note());
    try testing.expectEqualStrings("the expected document window", dg.expected);
}

test "a diagnostic directory inside the export bundle is refused" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.rt.diag_dir = "/tmp/nur/op-1/diag";
    fx.sim.extra = &.{surprise_win};
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unknown_ui);
    try testing.expect(!rep.failure.?.diag.captured);
    try testing.expect(std.mem.indexOf(u8, rep.failure.?.diag.note(), "inside the export bundle") != null);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.screenshot));
}

test "the gate captures a stalled document wait once and keeps waiting to its deadline" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .op_deadline_ms = 3000, .stall_ms = 500 });
    fx.rt.diag_dir = "/tmp/nur-diag";
    const s1 = [_]ui.WindowObservation{prog_win};
    const seq = [_][]const ui.WindowObservation{&s1};
    fx.sim.seq = &seq;
    const g = fx.rt.waitForDocument(gateReq(false));
    try testing.expectEqual(FailureKind.timeout, g.failure.?.kind);
    try testing.expectEqualStrings("stall", g.failure.?.diag.reason);
    try testing.expect(g.failure.?.diag.captured);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.screenshot));
    try testing.expect(fx.fenv.slept_ms >= 2500);
}

test "backoff starts at the minimum, doubles to the cap and restarts at a change" {
    var b = Backoff.init(10, 250);
    const want = [_]u32{ 10, 20, 40, 80, 160, 250, 250 };
    for (want) |w| try testing.expectEqual(w, b.next(false));
    try testing.expectEqual(@as(u32, 10), b.next(true));
    try testing.expectEqual(@as(u32, 20), b.next(false));
    // A minimum above the cap is clamped to the cap. A zero cap never waits.
    var c = Backoff.init(500, 100);
    try testing.expectEqual(@as(u32, 100), c.next(false));
    var z = Backoff.init(10, 0);
    try testing.expectEqual(@as(u32, 0), z.next(false));
    try testing.expectEqual(@as(u32, 0), z.next(true));
}

// Completion evidence, observation cadence and walk capacity

fn timedFx(fx: *Fx, limits: Limits, steps: []const SizeStep, side_ms: u64) void {
    fx.start(testing.allocator, limits);
    fx.sim.timed = true;
    fx.sim.clock = &fx.fenv;
    fx.sim.steps = steps;
    fx.sim.side_ms = side_ms;
}

fn noProgress() Route {
    var r = obj_route;
    r.progress = false;
    return r;
}

fn primarySize(rep: ExportReport) ?u64 {
    for (rep.files) |f| if (f.role == .primary) return f.size;
    return null;
}

fn elapsedMs(rep: ExportReport) u64 {
    return rep.stats.elapsed_ns / std.time.ns_per_ms;
}

const late_done_300 = [_]u32{300} ** 300 ++ [_]u32{1000};
const early_done = [_]u32{ 200, 600, 1000 };

test "a route with no completion signal stops uncertain with the raw prefix and no success" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 2500 }};
    timedFx(&fx, .{}, &steps, 0);
    var rep = fx.rt.runExport(request(.calibration, noProgress(), "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.completion_unavailable, rep.failure.?.cause);
    try testing.expect(rep.completion.via == .none and !rep.completion.established);
    try testing.expectEqual(@as(?u64, 2500), primarySize(rep));
    try testing.expect(fx.rt.reconcileRequired() != null);
    // No interval stood in for the signal.
    try testing.expectEqual(@as(u64, 0), fx.fenv.slept_ms);
}

test "a quiet file and a closed dialog without a progress signal are not completion" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 2500 }};
    timedFx(&fx, .{ .op_deadline_ms = 20_000 }, &steps, 0);
    fx.sim.progress_seq = &.{};
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
    try testing.expect(!rep.completion.established and rep.completion.observations == 0);
    // The observation ran to the hard budget and kept the prefix.
    try testing.expect(fx.fenv.slept_ms >= 19_000);
    try testing.expectEqual(@as(?u64, 2500), primarySize(rep));
    try testing.expect(fx.rt.reconcileRequired() != null);
}

test "a stale full progress value is not completion and a change from it is" {
    {
        var fx: Fx = .{};
        const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
        timedFx(&fx, .{ .op_deadline_ms = 10_000 }, &steps, 0);
        fx.sim.stale_progress = 1000;
        fx.sim.progress_seq = &.{};
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .uncertain_mutation);
        try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
        try testing.expectEqual(@as(?u32, 1000), rep.completion.baseline);
        try testing.expect(!rep.completion.established);
    }
    {
        var fx: Fx = .{};
        const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
        timedFx(&fx, .{}, &steps, 0);
        fx.sim.stale_progress = 1000;
        // The task of this export starts at 0 and reaches its total.
        fx.sim.progress_seq = &.{ 0, 500, 1000 };
        var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.ok());
        try testing.expect(rep.completion.established);
        try testing.expectEqual(@as(?u32, 1000), rep.completion.baseline);
    }
}

test "a progress value that never reaches its total is not completion" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
    timedFx(&fx, .{ .op_deadline_ms = 10_000 }, &steps, 0);
    fx.sim.progress_seq = &.{600};
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
    try testing.expect(!rep.completion.established and rep.completion.last.? == 600);
    try testing.expectEqual(@as(?u64, 1200), primarySize(rep));
}

test "an output that grows through a long pause is recorded at its final size once the signal comes" {
    var fx: Fx = .{};
    // A prefix at once, the rest at 60 s. The signal comes at pass 301, after about 75 s.
    const steps = [_]SizeStep{ .{ .at_ms = 0, .size = 2500 }, .{ .at_ms = 60_000, .size = 5000 } };
    timedFx(&fx, .{}, &steps, 0);
    fx.sim.progress_seq = &late_done_300;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(?u64, 5000), primarySize(rep));
    try testing.expect(elapsedMs(rep) > 60_000);
}

test "a required sidecar that appears long after the signal is awaited and accepted" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
    // 25 s after the press, far beyond any fixed grace.
    timedFx(&fx, .{}, &steps, 25_000);
    fx.sim.progress_seq = &early_done;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expect(rep.completion.established);
    try testing.expectEqual(@as(usize, 2), rep.files.len);
    try testing.expect(elapsedMs(rep) >= 25_000);
    try testing.expect(fx.rt.reconcileRequired() == null);
}

test "a sidecar that never appears after the signal ends at the hard budget as unpublished and keeps the files" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
    timedFx(&fx, .{ .op_deadline_ms = 20_000 }, &steps, 1_000_000_000);
    fx.sim.progress_seq = &early_done;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.output_unpublished, rep.failure.?.cause);
    try testing.expect(rep.completion.established);
    try testing.expectEqual(@as(?u64, 1200), primarySize(rep));
    try testing.expect(fx.rt.reconcileRequired() != null);
    // The budget ended it. No grace interval did.
    try testing.expect(fx.fenv.slept_ms >= 19_000);
}

test "a hard run budget ends an observation with no signal, keeps the prefix and latches" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 2500 }};
    timedFx(&fx, .{ .run_deadline_ms = 8_000 }, &steps, 0);
    fx.sim.progress_seq = &.{};
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.deadline_exceeded, rep.failure.?.cause);
    try testing.expectEqual(@as(?u64, 2500), primarySize(rep));
    try testing.expect(fx.rt.reconcileRequired() != null);
}

test "an unsafe entry after the signal fails at once and does not wait for the outputs" {
    var fx: Fx = .{};
    walkFx(&fx);
    const entries = [_]SimEntry{ .{ .path = "model.obj", .size = 1200 }, .{ .path = "textures/link.png", .kind = .symlink } };
    fx.sim.walk_list = &entries;
    var rep = fx.rt.runExport(nestedRequest("/tmp/nur/op-u1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unexpected_output);
    try testing.expect(!rep.failure.?.uncertain);
    try testing.expect(fx.fenv.slept_ms < 1000);
}

fn rampOf(comptime n: usize, comptime start: u32, comptime step: u32) [n]u32 {
    var a: [n]u32 = undefined;
    for (&a, 0..) |*x, i| x.* = start + @as(u32, @intCast(i)) * step;
    return a;
}

const idle_then_active = [_]u32{300} ** 8 ++ [_]u32{ 400, 400, 400, 400, 400, 400, 1000 };

test "polling intervals fall at new activity and rise during inactivity" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.complete_after = 14;
    fx.sim.progress_seq = &idle_then_active;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    var buf: [32]u32 = undefined;
    const waits = rep.stats.cadence.recent(&buf);
    // 10, 20, 40, 80, 160, 250, 250 while nothing changes. The change at the ninth reading drops it to 10.
    const want = [_]u32{ 10, 20, 40, 80, 160, 250, 250 };
    try testing.expectEqualSlices(u32, &want, waits[0..want.len]);
    try testing.expectEqual(@as(u32, 10), waits[8]);
    try testing.expectEqual(@as(u32, 20), waits[9]);
    try testing.expect(rep.stats.cadence.reason == .no_notifier);
}

test "observation intervals are adjustable" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .poll_min_ms = 5, .poll_ms = 40, .poll_growth = 3 });
    fx.sim.complete_after = 8;
    fx.sim.progress_seq = &late_done_8;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    var buf: [32]u32 = undefined;
    const waits = rep.stats.cadence.recent(&buf);
    const want = [_]u32{ 5, 15, 40, 40, 40, 40 };
    try testing.expectEqualSlices(u32, &want, waits[0..want.len]);
    try testing.expectEqual(@as(u32, 40), rep.stats.cadence.max_ms);
}

const quiet_then_change = [_]u32{300} ** 8 ++ [_]u32{ 400, 400, 400, 400, 400, 1000 };

test "a change found after a wait that no notification ended lowers the fallback bound" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var nf: FakeNotifier = .{ .sim = &fx.sim, .fenv = &fx.fenv, .wake_budget = 0 };
    fx.rt.notifier = nf.notifier();
    fx.sim.complete_after = 14;
    fx.sim.progress_seq = &quiet_then_change;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    const c = rep.stats.cadence;
    try testing.expect(c.missed >= 1 and c.delivered == 0);
    try testing.expect(c.max_ms == 250);
    try testing.expect(c.fallback_ms < 250);
    try testing.expect(c.reason == .notification_missed);
    // After the miss no wait is longer than the lowered bound.
    var buf: [32]u32 = undefined;
    const waits = rep.stats.cadence.recent(&buf);
    for (waits[8..]) |ms| try testing.expect(ms <= c.fallback_ms * 2);
}

const wake_then_quiet = [_]u32{ 50, 100, 150, 200, 250, 300, 350, 400, 450, 500 } ++ [_]u32{500} ** 12 ++ [_]u32{1000};

test "a change found after a notification raises the fallback bound and inactivity then lengthens the waits" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    var nf: FakeNotifier = .{ .sim = &fx.sim, .fenv = &fx.fenv, .wake_budget = 10 };
    fx.rt.notifier = nf.notifier();
    fx.sim.complete_after = 23;
    fx.sim.progress_seq = &wake_then_quiet;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    const c = rep.stats.cadence;
    try testing.expect(c.delivered >= 3 and c.woke == 10);
    try testing.expectEqual(@as(u32, 2000), c.fallback_ms);
    try testing.expect(c.reason == .notifications_delivered);
    // Inactivity after the notifications stop lets the waits grow past the first bound.
    try testing.expect(c.max_ms >= 1000);
}

test "the stall threshold follows the longest gap between changes" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .stall_ms = 1000 });
    fx.rt.diag_dir = "/tmp/nur-diag";
    var op = fx.rt.newOp(4242, .{ .expected = .{ .original = orig, .converted = conv, .watermarked = true } });
    // The operation changed after 5 s of quiet. The threshold is three times that.
    var last_change = fx.fenv.t;
    fx.fenv.t += 5 * std.time.ns_per_s;
    fx.rt.watchStall(&op, &last_change, true);
    try testing.expect(op.max_gap_ns >= 5 * std.time.ns_per_s);
    fx.fenv.t += 10 * std.time.ns_per_s;
    fx.rt.watchStall(&op, &last_change, false);
    try testing.expect(!op.diag.attempted);
    fx.fenv.t += 8 * std.time.ns_per_s;
    fx.rt.watchStall(&op, &last_change, false);
    try testing.expect(op.diag.attempted);
}

test "an output tree above the walk limit keeps a bounded listing and reports capacity" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .max_walk_entries = 100 });
    fx.rt.files = fx.sim.filesWalkInfo();
    var entries: std.ArrayList(SimEntry) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.path);
        entries.deinit(testing.allocator);
    }
    try entries.append(testing.allocator, .{ .path = try testing.allocator.dupe(u8, "model.obj"), .size = 1200 });
    try entries.append(testing.allocator, .{ .path = try testing.allocator.dupe(u8, "model.mtl"), .size = 80 });
    var i: usize = 0;
    while (i < 300) : (i += 1) try entries.append(testing.allocator, .{ .path = try std.fmt.allocPrint(testing.allocator, "tex{d:0>3}.png", .{i}), .size = 5 });
    fx.sim.walk_list = entries.items;
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expectEqual(FailureKind.output_capacity, rep.failure.?.cause);
    try testing.expect(!rep.failure.?.uncertain);
    try testing.expectEqual(@as(usize, 100), rep.files.len);
    try testing.expect(primarySize(rep) != null);
    // The same tree within the limit is accepted.
    var fx2: Fx = .{};
    fx2.start(testing.allocator, .{ .max_walk_entries = 400 });
    fx2.rt.files = fx2.sim.filesWalkInfo();
    fx2.sim.walk_list = entries.items;
    var rep2 = fx2.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep2.deinit(testing.allocator);
    try testing.expect(rep2.ok());
    try testing.expectEqual(@as(usize, 302), rep2.files.len);
}

test "the system walk reports capacity, depth and an unreadable tree apart" {
    var sf: SystemFiles = .{ .io = testing.io };
    const f = sf.files();
    const dir = "/usr/share/zoneinfo/America/Argentina";
    var info: WalkInfo = .{};
    const capped = f.walkInfo(testing.allocator, dir, .{ .max_entries = 3, .max_depth = 4 }, &info);
    try testing.expect(capped != null);
    defer freeWalk(testing.allocator, capped.?);
    try testing.expect(info.status == .capped);
    try testing.expectEqual(@as(usize, 3), capped.?.len);
    var info2: WalkInfo = .{};
    const whole = f.walkInfo(testing.allocator, dir, .{ .max_entries = 256, .max_depth = 4 }, &info2);
    try testing.expect(whole != null);
    defer freeWalk(testing.allocator, whole.?);
    try testing.expect(info2.status == .ok and whole.?.len > 3);
    var info3: WalkInfo = .{};
    try testing.expect(f.walkInfo(testing.allocator, "/nonexistent/vwx-walk", .{ .max_entries = 8, .max_depth = 4 }, &info3) == null);
    try testing.expect(info3.status == .unreadable);
    // The old entry point keeps its contract: null when the tree holds too many entries.
    try testing.expect(f.walk(testing.allocator, dir, .{ .max_entries = 3, .max_depth = 4 }) == null);
}

// Indicator identity

test "progress of another indicator never completes an export" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
    timedFx(&fx, .{ .op_deadline_ms = 10_000 }, &steps, 0);
    // The app shows a full progress of another operation after the press.
    fx.sim.progress_id = "other-progress";
    fx.sim.progress_seq = &.{ 200, 600, 1000 };
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
    try testing.expect(!rep.completion.established and rep.completion.unmatched >= 3);
    try testing.expectEqualStrings("export-progress", rep.completion.progress_id);
    try testing.expectEqual(@as(?u64, 1200), primarySize(rep));
}

test "an unidentified reading never completes an export" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
    timedFx(&fx, .{ .op_deadline_ms = 10_000 }, &steps, 0);
    fx.sim.progress_id = "";
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expect(!rep.completion.established and rep.completion.unmatched >= 1);
}

test "a route that declares a progress indicator without an identity is blocked" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
    timedFx(&fx, .{}, &steps, 0);
    var route = obj_route;
    route.progress_id = "";
    var rep = fx.rt.runExport(request(.calibration, route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    try testing.expectEqual(FailureKind.completion_unavailable, rep.failure.?.cause);
    try testing.expect(std.mem.indexOf(u8, rep.failure.?.detail(), "without an identity") != null);
    // The blocked route read no indicator.
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.progress));
    try testing.expectEqual(@as(?u64, 1200), primarySize(rep));
}

test "a stale full reading of another indicator is no baseline and the own transition completes" {
    var fx: Fx = .{};
    const steps = [_]SizeStep{.{ .at_ms = 0, .size = 1200 }};
    timedFx(&fx, .{}, &steps, 0);
    fx.sim.stale_progress = 1000;
    fx.sim.stale_id = "other-progress";
    var rep = fx.rt.runExport(request(.calibration, obj_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(?u32, null), rep.completion.baseline);
    try testing.expect(rep.completion.established);
}

test "the route identity must be a valid label" {
    var r = obj_route;
    r.progress_id = " padded";
    try testing.expectError(error.BadId, validateRoute(r, .calibration, .{}));
    r.progress_id = "export-progress";
    try validateRoute(r, .calibration, .{});
}

// Merge named main and focused windows with AXWindows placeholders.

const readonly_text = "File is read-only.  Do you want to open a copy of it with a new name?";

test "every window script merges main and focused windows with the AXWindows list" {
    const scripts = [_][]const u8{ script_snapshot, script_control, script_ack, script_progress, script_windowid };
    for (scripts) |s| {
        try testing.expect(std.mem.indexOf(u8, s, "set listedWindows to (get every window)") != null);
        try testing.expect(std.mem.indexOf(u8, s, "set windowList to {}") != null);
        try testing.expect(std.mem.indexOf(u8, s, "value of attribute \"AXMainWindow\"") != null);
        try testing.expect(std.mem.indexOf(u8, s, "value of attribute \"AXFocusedWindow\"") != null);
        try testing.expect(std.mem.indexOf(u8, s, "repeat with candidateWindow in listedWindows") != null);
        try testing.expect(std.mem.indexOf(u8, s, "repeat with knownWindow in windowList") != null);
        try testing.expect(std.mem.indexOf(u8, s, "if not sameWindow then set end of windowList to contents of candidateWindow") != null);
        try testing.expect(std.mem.indexOf(u8, s, "repeat with probeWindow in windowList") != null);
        try testing.expect(std.mem.indexOf(u8, s, "repeat with probeWindow in (get every window)") == null);
        try testing.expect(std.mem.indexOf(u8, s, "if (count of windowList) is 0") == null);
    }
    // Only modal text collection walks descendants. The window union stays shallow.
    try testing.expect(std.mem.indexOf(u8, script_snapshot, "get entire contents of probeWindow") != null);
    try testing.expect(std.mem.indexOf(u8, window_list_snippet, "entire contents") == null);
}

test "a focused modal that AXWindows hides is seen and the document keeps its own identity" {
    // The output that the script gives with the fallback: the document from the main window, the
    // dialog from the focused window with its subrole and its own texts.
    const snap = "ok\nW\ts:" ++ conv_title ++ "\tf\tn\t-\nW\tn\tt\ts:No\tfull\nT\ts:" ++ readonly_text ++ "\n";
    const rules = macRules(snap, reg_unlocked);
    var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
    fx.start();
    defer fx.stop();
    const obs = fx.mac.backend().observe(mac_ctx).observed;
    try testing.expectEqual(@as(usize, 2), obs.windows.len);
    // The document window keeps its own title and is not modal. The modal has no title of the document.
    try testing.expectEqualStrings(conv_title, obs.windows[0].title.?);
    try testing.expect(obs.windows[0].modal == false);
    try testing.expect(obs.windows[1].title == null and obs.windows[1].modal == true);
    const d = ui.decide(obs, watermarkPolicy());
    try testing.expectEqual(ui.DecisionKind.unknown_ui, d.kind);
}

test "a focused modal alone stops as unknown UI and an empty list keeps waiting" {
    {
        const snap = "ok\nW\tn\tt\ts:No\tfull\nT\ts:" ++ readonly_text ++ "\n";
        const rules = macRules(snap, reg_unlocked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        const d = ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy());
        try testing.expectEqual(ui.DecisionKind.unknown_ui, d.kind);
    }
    {
        // Without the fallback this is what a hidden modal looked like: no window at all.
        const rules = macRules("ok\n", reg_unlocked);
        var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
        fx.start();
        defer fx.stop();
        const d = ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy());
        try testing.expectEqual(ui.DecisionKind.wait, d.kind);
    }
}

test "a modal titled like the document never makes the document ready" {
    // The modal carries the document name. It stays a modal and no document window exists.
    const snap = "ok\nW\ts:" ++ conv_title ++ "\tt\ts:OK\tfull\nT\ts:Something unexpected\n";
    const rules = macRules(snap, reg_unlocked);
    var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
    fx.start();
    defer fx.stop();
    const d = ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy());
    try testing.expect(d.kind != .ready);
}

// Native export controls: unnamed controls, the standard save panel and the calibration command

fn spFixture(fx: *Fx) void {
    fx.sim.savePanelControls();
    fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), .{});
}

test "selectors by title element and by path compare, validate and cache apart from label selectors" {
    const by_name: Selector = .{ .container = .{ .window = sp_win }, .role = .popup, .label = "Where:" };
    try testing.expect(!by_name.eql(sp_where));
    try testing.expect(sp_where.eql(sp_where));
    try testing.expect(sp_name.eql(sp_name));
    var other = sp_name;
    other.via = .{ .path = &.{.{ .role = .text_field, .index = 1, .of = 3 }} };
    try testing.expect(!sp_name.eql(other));
    try testing.expect(!sp_field.eql(.{ .container = .{ .window = sp_win }, .role = .text_field, .label = "Go to the folder:", .via = .title_element }));
    // A route may carry the unnamed control by path and a label control beside it.
    try validateSelector(sp_name, .text_field, .{});
    try validateSelector(sp_where, .popup, .{});
    var c: SelectorCache = .{};
    c.put(by_name, 1, 5);
    try testing.expect(c.get(sp_where, 1) == null);
    c.put(sp_name, 1, 6);
    try testing.expectEqual(@as(?u64, 6), c.get(sp_name, 1));
    try testing.expect(c.get(other, 1) == null);
    // Bad paths: a label with a path, no steps, an index past the count, a last role that differs, too many steps.
    var bad = sp_name;
    bad.label = "x";
    try testing.expectError(error.BadSelector, validateSelector(bad, null, .{}));
    bad = sp_name;
    bad.via = .{ .path = &.{} };
    try testing.expectError(error.BadSelector, validateSelector(bad, null, .{}));
    bad.via = .{ .path = &.{.{ .role = .text_field, .index = 3, .of = 2 }} };
    try testing.expectError(error.BadSelector, validateSelector(bad, null, .{}));
    bad.via = .{ .path = &.{.{ .role = .popup, .index = 1, .of = 1 }} };
    try testing.expectError(error.BadSelector, validateSelector(bad, null, .{}));
    const five = [_]PathStep{.{ .role = .text_field, .index = 1, .of = 1 }} ** 5;
    bad.via = .{ .path = &five };
    try testing.expectError(error.BadSelector, validateSelector(bad, null, .{}));
    // A name or title element selector still needs a label.
    var nolabel = sp_where;
    nolabel.label = "";
    try testing.expectError(error.BadSelector, validateSelector(nolabel, null, .{}));
    // A report names a path control by its role, never by an invented name.
    try testing.expectEqualStrings("Where:", sp_where.reportLabel());
    try testing.expectEqualStrings("unnamed text field (by path)", sp_name.reportLabel());
}

test "save panel destination is validated as one panel and never next to a directory field" {
    try validateRoute(sp_route, .verified, .{});
    var d: DestinationStep = .{ .name_field = sp_name, .save_panel = sp_dir };
    const conf: Step = .{ .confirm = sp_save };
    const menu: Step = .{ .menu = &.{ "File", "Export" } };
    d.dir_field = sp_name;
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = d }, conf }), .calibration);
    d.dir_field = null;
    // Where in another window.
    var w = sp_dir;
    w.where.container = .{ .window = "Other" };
    d.save_panel = w;
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = d }, conf }), .calibration);
    // The sheet of another window.
    w = sp_dir;
    w.sheet_field.container = .{ .window_sheet = "Other" };
    w.go.container = w.sheet_field.container;
    d.save_panel = w;
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = d }, conf }), .calibration);
    // The Where control must be a popup and the Go control a button.
    w = sp_dir;
    w.where.role = .text_field;
    d.save_panel = w;
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = d }, conf }), .calibration);
    // The panel name field must sit in a window, because the sheet belongs to that window.
    d = .{ .name_field = sheet(.text_field, "Save As:"), .save_panel = sp_dir };
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = d }, conf }), .calibration);
}

test "save panel run opens Go to Folder, reads Where back and only then names the file and saves" {
    var fx: Fx = .{};
    spFixture(&fx);
    var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.chord));
    // The key went out before Go, and Save came after the Where read back.
    try testing.expect(fx.sim.chord_at == 1 and fx.sim.go_pressed_at == 2);
    try testing.expect(fx.sim.confirmed);
    try testing.expect(!fx.sim.go_open);
    try testing.expectEqualStrings("op-1", fx.sim.whereCtl().value[0..fx.sim.whereCtl().value_len]);
    // The records: the sheet path as typed, the Where read back and the file name set after it.
    try testing.expectEqual(@as(usize, 3), rep.options.len);
    try testing.expectEqualStrings("Go to the folder:", rep.options[0].label);
    try testing.expectEqualStrings("/tmp/nur/op-1", rep.options[0].observed);
    try testing.expectEqualStrings("Where (directory)", rep.options[1].label);
    try testing.expectEqualStrings("op-1", rep.options[1].requested);
    try testing.expectEqualStrings("op-1", rep.options[1].observed);
    try testing.expectEqualStrings("unnamed text field (by path)", rep.options[2].label);
    try testing.expectEqualStrings("model.obj", rep.options[2].observed);
}

test "save panel run stops before Save when the sheet stays open" {
    var fx: Fx = .{};
    fx.sim.reject_path = true;
    spFixture(&fx);
    var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unknown_ui);
    try testing.expect(!fx.sim.confirmed);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.chord));
    // Only the Go press ran. Save and the name field were not reached.
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.press));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
}

test "save panel run stops before Save when Where keeps another folder" {
    var fx: Fx = .{};
    fx.sim.where_frozen = true;
    spFixture(&fx);
    var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .incomplete_options);
    try testing.expect(!fx.sim.confirmed);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.press));
    try testing.expectEqualStrings("Documents", rep.options[rep.options.len - 1].observed);
    // The wait for the popup is bounded by the dialog wait and ends with that failure.
    try testing.expect(fx.fenv.slept_ms > 0 and fx.fenv.slept_ms <= 5_000 + 2_000);
}

test "save panel run separates a refused key from an uncertain one" {
    {
        var fx: Fx = .{};
        fx.sim.fail_call = .chord;
        fx.sim.fail = .{ .kind = .refused, .detail = "window is absent" };
        spFixture(&fx);
        var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .refused);
        try testing.expect(!rep.failure.?.uncertain);
        try testing.expect(fx.rt.reconcileRequired() == null);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
    }
    {
        var fx: Fx = .{};
        fx.sim.fail_call = .chord;
        fx.sim.fail = .{ .kind = .transport_error, .detail = "injected" };
        spFixture(&fx);
        var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.failure.?.uncertain);
        try testing.expect(fx.rt.reconcileRequired() != null);
        try testing.expect(!fx.sim.confirmed);
    }
}

test "a backend without keyboard events refuses the save panel route" {
    var fx: Fx = .{};
    fx.sim.savePanelControls();
    var be = fx.sim.backend();
    be.chordFn = refuseChord;
    fx.rt = Runtime.init(testing.allocator, be, fx.fenv.env(), fx.sim.files(), .{});
    var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .refused);
    try testing.expect(!fx.sim.confirmed);
}

test "inventory looks up the Where popup of a save panel and not the closed sheet" {
    var fx: Fx = .{};
    spFixture(&fx);
    var rep = fx.rt.runExport(request(.inventory, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 3), rep.controls.len);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.chord));
}

fn tailHas(h: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, h, needle) != null;
}

test "mac backend passes the locator of a selector and keeps label calls as they were" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = US ++ "lookup" ++ US, .out = "ok\t1\tsig\ts:v\t1\n" },
        .{ .has = US ++ "set" ++ US, .out = "ok\ts:38.0\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    _ = b.lookup(mac_ctx, s_save);
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "Save" ++ US ++ US ++ "name" ++ US));
    _ = b.lookup(mac_ctx, sp_where);
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "window" ++ US ++ sp_win ++ US ++ "lookup" ++ US ++ "AXPopUpButton" ++ US ++ "Where:" ++ US ++ US ++ "title" ++ US));
    _ = b.lookup(mac_ctx, sp_name);
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "AXTextField" ++ US ++ US ++ US ++ "path" ++ US ++ "AXTextField:1:2"));
    const deep: Selector = .{ .container = .{ .window = sp_win }, .role = .popup, .label = "", .via = .{ .path = &.{
        .{ .role = .combo_box, .index = 2, .of = 3 },
        .{ .role = .popup, .index = 1, .of = 1 },
    } } };
    try testing.expectEqualStrings("38.0", b.setValue(mac_ctx, deep, .{ .choice = "38.0" }).done.?);
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "path" ++ US ++ "AXComboBox:2:3,AXPopUpButton:1:1"));
    // The sheet of a window is the sheet kind with the window title.
    _ = b.lookup(mac_ctx, sp_field);
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "sheet" ++ US ++ sp_win ++ US ++ "lookup" ++ US ++ "AXTextField"));
    _ = b.identity(mac_ctx, .{ .window_sheet = sp_win });
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "sheet" ++ US ++ sp_win ++ US ++ "identity"));
}

test "control script waits for the popup menu with a bounded growing interval and no fixed delay" {
    try testing.expect(std.mem.indexOf(u8, script_control, "delay 0.2") == null);
    try testing.expect(std.mem.indexOf(u8, script_control, "repeat while menuItemRef is missing value") != null);
    // The wait is bounded and its end is an error, which the backend reports as a failure after the click.
    try testing.expect(std.mem.indexOf(u8, script_control, "if menuWaited >= 3 then error") != null);
    try testing.expect(std.mem.indexOf(u8, script_control, "set menuStep to menuStep * 2") != null);
    try testing.expect(std.mem.indexOf(u8, script_control, "set menuStep to 0.01") != null);
    const rules = [_]FakeTransport.Rule{.{ .has = US ++ "set" ++ US ++ "AXPopUpButton", .out = "failed_after_start\t-1\n" }};
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const f = fx.mac.backend().setValue(mac_ctx, s_quality, .{ .choice = "High" }).failed;
    try testing.expect(f.uncertain);
}

const KeyLog = struct {
    var n: u32 = 0;
    var pid: i32 = 0;
    var key: u16 = 0;
    var flags: u64 = 0;
    var ok: bool = true;
    fn post(p: i32, k: u16, f: u64) bool {
        if (!ok) return false;
        n += 1;
        pid = p;
        key = k;
        flags = f;
        return true;
    }
};

test "mac backend posts the Go to Folder chord to the pid only after the exact window is found" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = sp_win ++ US ++ "identity", .out = "ok\t1,2;3,4;5\n" },
        .{ .has = "Missing" ++ US ++ "identity", .out = "refused\twindow_absent\n" },
        .{ .has = "Twice" ++ US ++ "identity", .out = "refused\twindow_ambiguous\n" },
    };
    var fx = macOnly(&rules);
    fx.ft.rules = &rules;
    fx.mac = MacBackend.init(testing.allocator, fx.ft.transport(), fx.fenv.env(), .{ .key_post = KeyLog.post });
    defer fx.stop();
    KeyLog.n = 0;
    KeyLog.ok = true;
    const b = fx.mac.backend();
    try testing.expect(b.chord(mac_ctx, sp_win, .go_to_folder) == .done);
    try testing.expectEqual(@as(u32, 1), KeyLog.n);
    try testing.expectEqual(@as(i32, 4242), KeyLog.pid);
    try testing.expectEqual(@as(u16, 5), KeyLog.key);
    try testing.expectEqual(@as(u64, 0x120000), KeyLog.flags);
    try testing.expectEqual(FailureKind.unknown_ui, b.chord(mac_ctx, "Missing", .go_to_folder).failed.kind);
    try testing.expectEqual(FailureKind.ambiguous_target, b.chord(mac_ctx, "Twice", .go_to_folder).failed.kind);
    try testing.expectEqual(@as(u32, 1), KeyLog.n);
    KeyLog.ok = false;
    const f = b.chord(mac_ctx, sp_win, .go_to_folder).failed;
    try testing.expectEqual(FailureKind.refused, f.kind);
    try testing.expect(!f.uncertain);
}

// Calibration command

const cli_exe = "/Apps/Vectorworks";

fn cliPath(pid: i32, buf: []u8) ?[]const u8 {
    if (pid != 4242) return null;
    @memcpy(buf[0..cli_exe.len], cli_exe);
    return buf[0..cli_exe.len];
}

fn cliPathOther(pid: i32, buf: []u8) ?[]const u8 {
    _ = pid;
    const o = "/Apps/Other";
    @memcpy(buf[0..o.len], o);
    return buf[0..o.len];
}

const modal_win: ui.WindowObservation = .{ .title = sp_win, .modal = true };
const plain_win: ui.WindowObservation = .{ .title = sp_win, .modal = false };

const cli_base = [_][]const u8{ "--pid", "4242", "--expected-executable", cli_exe, "--window-title", sp_win };

fn cliRun(fx: *Fx, extra: []const []const u8, path: *const fn (i32, []u8) ?[]const u8, out: *std.Io.Writer.Allocating) u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    argv.appendSlice(testing.allocator, &cli_base) catch unreachable;
    argv.appendSlice(testing.allocator, extra) catch unreachable;
    return runExportControlWith(testing.allocator, argv.items, &out.writer, .{ .backend = fx.sim.backend(), .env = fx.fenv.env(), .pathOf = path });
}

fn cliFx(fx: *Fx, wins: []const ui.WindowObservation) void {
    fx.sim.savePanelControls();
    fx.sim.dialog_open = true;
    fx.sim.extra = wins;
}

test "calibration command reads by default, matches the modal twice and changes nothing" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const code = cliRun(&fx, &.{ "--control", "popup/title/Where:" }, cliPath, &out);
    try testing.expectEqual(@as(u8, 0), code);
    const t = out.written();
    try testing.expect(tailHas(t, "mode\tread\n"));
    try testing.expect(tailHas(t, "guard\t1\tmatched\nguard\t2\tmatched\n"));
    try testing.expect(tailHas(t, "control\tcount\t1\tenabled\ttrue\n"));
    try testing.expect(tailHas(t, "value\tDocuments\n"));
    try testing.expect(tailHas(t, "result\tok\n"));
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    try testing.expectEqual(@as(u32, 2), fx.sim.n(.observe));
}

test "calibration command sets one control only with --apply and reports the read back" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &.{ "--control", "text_field/path/text_field:1:2", "--set", "x.pdf" }, cliPath, &out));
    try testing.expect(tailHas(out.written(), "plan\tset the control"));
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &.{ "--control", "text_field/path/text_field:1:2", "--set", "x.pdf", "--apply" }, cliPath, &out));
    const t = out.written();
    try testing.expect(tailHas(t, "guard\trecheck\tmatched\n"));
    try testing.expect(tailHas(t, "set_readback\tx.pdf\n"));
    try testing.expect(tailHas(t, "readback_matches_request\tyes\n"));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
    // A read back that differs is a failure.
    fx.sim.ctls[0].readback_override = "other";
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fx, &.{ "--control", "text_field/path/text_field:1:2", "--set", "y.pdf", "--apply" }, cliPath, &out));
    try testing.expect(tailHas(out.written(), "readback_matches_request\tno\n"));
}

// Native export controls through the command

const native_tree_nodes = [_]nec.FakeAx.FNode{
    .{ .depth = 0, .role = "AXWindow", .subrole = "AXDialog", .title = sp_win },
    .{ .depth = 1, .role = "AXGroup" },
    .{ .depth = 2, .role = "AXStaticText", .value = "File Type:", .kind = "string" },
    .{ .depth = 2, .role = "AXPopUpButton", .value = "JPEG", .kind = "string" },
    .{ .depth = 1, .role = "AXTextField", .value = "extrude.asym.pdf", .kind = "string", .settable = true, .enabled = true, .id = "saveAsNameTextField" },
    .{ .depth = 1, .role = "AXCheckBox", .title = "Lock", .value = "1", .kind = "number" },
};

fn nativeFake() nec.FakeAx {
    var f: nec.FakeAx = .{ .nodes = testing.allocator.dupe(nec.FakeAx.FNode, &native_tree_nodes) catch unreachable };
    f.win_title = sp_win;
    return f;
}

fn cliRunNative(fx: *Fx, ax: *nec.FakeAx, extra: []const []const u8, path: *const fn (i32, []u8) ?[]const u8, out: *std.Io.Writer.Allocating) u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    argv.appendSlice(testing.allocator, &cli_base) catch unreachable;
    argv.append(testing.allocator, "--native") catch unreachable;
    argv.appendSlice(testing.allocator, extra) catch unreachable;
    return runExportControlWith(testing.allocator, argv.items, &out.writer, .{ .backend = fx.sim.backend(), .env = fx.fenv.env(), .pathOf = path, .native = ax.source() });
}

test "native control arguments keep their own combinations" {
    const base = [_][]const u8{ "--pid", "4242", "--expected-executable", cli_exe, "--window-title", sp_win };
    const ok = parseControlArgs(&(base ++ [_][]const u8{ "--native", "--native-tree" }));
    try testing.expect(ok == .ok and ok.ok.native and ok.ok.native_tree and ok.ok.control == null);
    try testing.expect(parseControlArgs(&(base ++ [_][]const u8{"--native-tree"})) == .bad);
    try testing.expect(parseControlArgs(&(base ++ [_][]const u8{ "--native", "--native-tree", "--control", "popup/sibling/X:" })) == .bad);
    try testing.expect(parseControlArgs(&(base ++ [_][]const u8{ "--control", "popup/label/X", "--expect-current", "a" })) == .bad);
    try testing.expect(parseControlArgs(&(base ++ [_][]const u8{ "--native", "--control", "popup/label/X", "--authorize", "a" })) == .bad);
    const set = parseControlArgs(&(base ++ [_][]const u8{ "--native", "--control", "popup/sibling/X:", "--set", "b", "--expect-current", "a", "--authorize", "t", "--apply" }));
    try testing.expect(set == .ok and set.ok.expect_current != null and set.ok.authorize != null and set.ok.apply);
    try testing.expect(parseControlArgs(&(base ++ [_][]const u8{ "--native", "--navigate", "/tmp", "--where", "a", "--sheet-field", "b", "--go", "c" })) == .bad);
    // The default stays the System Events route.
    const plain = parseControlArgs(&(base ++ [_][]const u8{ "--control", "popup/label/X" }));
    try testing.expect(plain == .ok and !plain.ok.native);
}

test "native control read matches the modal twice and starts no System Events call" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var ax = nativeFake();
    defer testing.allocator.free(ax.nodes);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), cliRunNative(&fx, &ax, &.{ "--control", "popup/sibling/File Type:" }, cliPath, &out));
    const t = out.written();
    try testing.expect(tailHas(t, "mode\tnative-read\n"));
    try testing.expect(tailHas(t, "guard\t1\tmatched\nguard\t2\tmatched\n"));
    try testing.expect(tailHas(t, "route\tnative-ax\n"));
    try testing.expect(tailHas(t, "value\tJPEG\n"));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.lookup));
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    try testing.expectEqual(@as(u32, 0), ax.sets + ax.presses);
    out.writer.end = 0;
}

test "native control set needs the exact token, rechecks the gate and uses no System Events" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var ax = nativeFake();
    defer testing.allocator.free(ax.nodes);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const sel = "text_field/id/saveAsNameTextField";
    try testing.expectEqual(@as(u8, 0), cliRunNative(&fx, &ax, &.{ "--control", sel, "--set", "trial.pdf", "--expect-current", "extrude.asym.pdf" }, cliPath, &out));
    const t = out.written();
    const marker = "authorization_required\t";
    const at = std.mem.indexOf(u8, t, marker).?;
    const token = std.mem.sliceTo(t[at + marker.len ..], '\n');
    try testing.expectEqual(@as(u32, 0), ax.sets);
    const token_copy = try testing.allocator.dupe(u8, token);
    defer testing.allocator.free(token_copy);
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRunNative(&fx, &ax, &.{ "--control", sel, "--set", "trial.pdf", "--expect-current", "extrude.asym.pdf", "--apply", "--authorize", "nope" }, cliPath, &out));
    try testing.expectEqual(@as(u32, 0), ax.sets);
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRunNative(&fx, &ax, &.{ "--control", sel, "--set", "trial.pdf", "--expect-current", "extrude.asym.pdf", "--apply", "--authorize", token_copy }, cliPath, &out));
    try testing.expect(tailHas(out.written(), "readback_matches_request\tyes\n"));
    try testing.expectEqual(@as(u32, 1), ax.sets);
    try testing.expectEqualStrings("trial.pdf", ax.nodes[4].value.?);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.lookup));
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    // The values are validated like the System Events route: a control character is a usage error.
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 2), cliRunNative(&fx, &ax, &.{ "--control", sel, "--set", "a\tb", "--expect-current", "x" }, cliPath, &out));
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 2), cliRunNative(&fx, &ax, &.{ "--control", "checkbox/label/Lock", "--set", "yes", "--expect-current", "1" }, cliPath, &out));
}

test "native control refuses a wrong executable, a plain window and an absent source before any AX call" {
    var fx: Fx = .{};
    cliFx(&fx, &.{plain_win});
    var ax = nativeFake();
    defer testing.allocator.free(ax.nodes);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), cliRunNative(&fx, &ax, &.{ "--control", "popup/sibling/File Type:" }, cliPath, &out));
    try testing.expect(tailHas(out.written(), "guard\t1\tnot_modal\n"));
    try testing.expectEqual(@as(u32, 0), ax.windows_calls);
    var fx2: Fx = .{};
    cliFx(&fx2, &.{modal_win});
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRunNative(&fx2, &ax, &.{ "--control", "popup/sibling/File Type:" }, cliPathOther, &out));
    try testing.expect(tailHas(out.written(), "wrong_executable"));
    try testing.expectEqual(@as(u32, 0), ax.windows_calls);
    // No native source: refuse, never fall back to System Events.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &cli_base);
    try argv.appendSlice(testing.allocator, &.{ "--native", "--control", "popup/sibling/File Type:" });
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), runExportControlWith(testing.allocator, argv.items, &out.writer, .{ .backend = fx2.sim.backend(), .env = fx2.fenv.env(), .pathOf = cliPath }));
    try testing.expect(tailHas(out.written(), "native AX source is not available"));
    try testing.expectEqual(@as(u32, 0), fx2.sim.n(.lookup));
    // The title selector and --sheet are refused as unsupported, not routed to System Events.
    var fx3: Fx = .{};
    cliFx(&fx3, &.{modal_win});
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRunNative(&fx3, &ax, &.{ "--control", "popup/title/Where:" }, cliPath, &out));
    try testing.expect(tailHas(out.written(), "unsupported\tthe title selector"));
    try testing.expectEqual(@as(u32, 0), fx3.sim.n(.lookup));
}

test "native tree command prints the whole tree and the usage names the native flags" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var ax = nativeFake();
    defer testing.allocator.free(ax.nodes);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), cliRunNative(&fx, &ax, &.{"--native-tree"}, cliPath, &out));
    try testing.expect(tailHas(out.written(), "mode\tnative-tree\n"));
    try testing.expect(tailHas(out.written(), "nodes\t6\ttruncated=false\tunreadable=false\n"));
    try testing.expect(tailHas(out.written(), "popup_label\t3\tFile Type:\n"));
    try testing.expect(tailHas(control_usage_text, "--native-tree"));
    try testing.expect(tailHas(control_usage_text, "--expect-current CUR"));
}

test "calibration command refuses a wrong executable, a missing or non-modal window before any lookup" {
    {
        var fx: Fx = .{};
        cliFx(&fx, &.{modal_win});
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), cliRun(&fx, &.{ "--control", "popup/title/Where:", "--apply" }, cliPathOther, &out));
        try testing.expect(tailHas(out.written(), "guard\t1\twrong_executable\n"));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.lookup) + fx.sim.n(.observe));
    }
    {
        var fx: Fx = .{};
        cliFx(&fx, &.{plain_win});
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), cliRun(&fx, &.{ "--control", "popup/title/Where:", "--set", "x", "--apply" }, cliPath, &out));
        try testing.expect(tailHas(out.written(), "guard\t1\tnot_modal\n"));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.lookup) + fx.sim.mutations());
    }
    {
        var fx: Fx = .{};
        cliFx(&fx, &.{});
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), cliRun(&fx, &.{ "--control", "popup/title/Where:" }, cliPath, &out));
        try testing.expect(tailHas(out.written(), "guard\t1\tmodal_absent\n"));
    }
    {
        // Two windows with the title are ambiguous.
        var fx: Fx = .{};
        cliFx(&fx, &.{ modal_win, modal_win });
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), cliRun(&fx, &.{ "--control", "popup/title/Where:" }, cliPath, &out));
        try testing.expect(tailHas(out.written(), "guard\t1\tmodal_ambiguous\n"));
    }
}

test "calibration command stops when the window stops being modal between the guard reads" {
    var fx: Fx = .{};
    fx.sim.savePanelControls();
    fx.sim.dialog_open = true;
    const seq = [_][]const ui.WindowObservation{ &.{modal_win}, &.{plain_win} };
    fx.sim.seq = &seq;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), cliRun(&fx, &.{ "--control", "popup/title/Where:" }, cliPath, &out));
    try testing.expect(tailHas(out.written(), "guard\t2\tnot_modal\n"));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.lookup));
}

test "calibration command navigates the save directory and prints the Where read back" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const nav = [_][]const u8{ "--where", "popup/title/Where:", "--sheet-field", "text_field/title/Go to the folder:", "--go", "button/label/Go", "--navigate", "/tmp/nur/op-9" };
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &nav, cliPath, &out));
    try testing.expect(tailHas(out.written(), "plan\tnavigate"));
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    out.writer.end = 0;
    var apply: [nav.len + 1][]const u8 = undefined;
    @memcpy(apply[0..nav.len], &nav);
    apply[nav.len] = "--apply";
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &apply, cliPath, &out));
    const t = out.written();
    try testing.expect(tailHas(t, "where_before\tcount\t1"));
    try testing.expect(tailHas(t, "observed\top-9\n"));
    try testing.expect(tailHas(t, "want_where_value\top-9\n"));
    try testing.expect(tailHas(t, "result\tok\n"));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.chord));
    // Save is never pressed.
    try testing.expect(!fx.sim.confirmed);
    // A panel that keeps the sheet open is a failure that says so.
    var fx2: Fx = .{};
    fx2.sim.reject_path = true;
    cliFx(&fx2, &.{modal_win});
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fx2, &apply, cliPath, &out));
    try testing.expect(tailHas(out.written(), "result\tfailed\n"));
    try testing.expect(tailHas(out.written(), "may still be open"));
    try testing.expect(!fx2.sim.confirmed);
}

test "calibration command rejects bad usage and prints the exact usage and wiring lines" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), cliRun(&fx, &.{}, cliPath, &out));
    try testing.expect(tailHas(out.written(), control_usage_text));
    for ([_][]const []const u8{
        &.{ "--control", "popup/bogus/x" },
        &.{ "--control", "popup/path/popup:0:1" },
        &.{ "--control", "popup/label/" },
        &.{ "--control", "button/label/Save", "--set", "x" },
        &.{ "--where", "popup/title/Where:", "--navigate", "/tmp/x" },
        &.{ "--control", "popup/label/x", "--navigate", "/tmp/x" },
        &.{ "--where", "popup/title/Where:", "--sheet-field", "text_field/title/f", "--go", "button/label/Go", "--navigate", "relative" },
        &.{ "--control", "checkbox/label/x", "--set", "maybe" },
    }) |extra| {
        out.writer.end = 0;
        try testing.expectEqual(@as(u8, 2), cliRun(&fx, extra, cliPath, &out));
    }
    try testing.expectEqual(@as(u32, 0), fx.sim.total());
    var help: std.Io.Writer.Allocating = .init(testing.allocator);
    defer help.deinit();
    try testing.expectEqual(@as(u8, 0), runExportControlWith(testing.allocator, &.{"--help"}, &help.writer, null));
    try testing.expectEqualStrings(control_usage_text ++ control_wiring_text, help.written());
    try testing.expect(tailHas(control_wiring_text, "native_ui_runtime.runExportControlCli"));
}

test "window list fragment separates AppleScript statements at every splice" {
    try testing.expect(window_list_snippet[0] == '\n');
    try testing.expect(std.mem.endsWith(u8, window_list_snippet, "\n"));
    for ([_][]const u8{ script_snapshot, script_control, script_ack, script_progress, script_windowid }) |script| {
        try testing.expect(std.mem.indexOf(u8, script, "\n        set windowList to") != null);
        try testing.expect(std.mem.indexOf(u8, script, "linefeed        set windowList") == null);
    }
}

test "mac backend injected native window source bypasses System Events and preserves console checks" {
    const Source = struct {
        fn read(_: Allocator, _: Env, _: Ctx, _: Limits) ObserveReply {
            return .{ .observed = .{ .console = .{}, .windows = &.{.{ .title = conv_title, .modal = false }}, .windows_complete = true } };
        }
    };
    const rules = macRules("bad System Events snapshot", reg_unlocked);
    var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
    fx.start();
    defer fx.stop();
    try testing.expect(fx.mac.cfg.window_source == null);
    fx.mac.cfg.window_source = Source.read;
    const observation = fx.mac.backend().observe(mac_ctx).observed;
    try testing.expectEqualStrings(conv_title, observation.windows[0].title.?);
    try testing.expectEqual(ui.DecisionKind.ready, ui.decide(observation, watermarkPolicy()).kind);
    try testing.expectEqual(@as(usize, 3), fx.ft.calls.items.len);
}

test "mac backend native window failures and unreadable modals remain blocked" {
    const Source = struct {
        fn failed(_: Allocator, _: Env, _: Ctx, _: Limits) ObserveReply {
            return .{ .failed = .{ .kind = .unknown_ui, .detail = "native window read failed" } };
        }
        fn modal(_: Allocator, _: Env, _: Ctx, _: Limits) ObserveReply {
            return .{ .observed = .{ .console = .{}, .windows = &.{.{ .title = conv_title, .modal = false }, .{ .title = "Unknown", .modal = true }}, .windows_complete = false } };
        }
    };
    const rules = macRules(snapshot_ready, reg_unlocked);
    var fx: MacFx = .{ .ft = .{ .a = testing.allocator, .rules = &rules } };
    fx.start();
    defer fx.stop();
    fx.mac.cfg.window_source = Source.failed;
    try testing.expectEqual(FailureKind.unknown_ui, fx.mac.backend().observe(mac_ctx).failed.kind);
    fx.mac.cfg.window_source = Source.modal;
    try testing.expectEqual(ui.DecisionKind.unknown_ui, ui.decide(fx.mac.backend().observe(mac_ctx).observed, watermarkPolicy()).kind);
    try testing.expectEqual(@as(usize, 6), fx.ft.calls.items.len);
}

test "close accepts another document only after the expected document was targeted" {
    const other = [_]ui.WindowObservation{.{ .title = "other.vwx", .modal = false }};
    const target = [_]ui.WindowObservation{doc_win};
    const both = [_]ui.WindowObservation{ doc_win, other[0] };
    const seq = [_][]const ui.WindowObservation{ &target, &both, &other, &other };
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.seq = &seq;
    const report = fx.rt.closeDocument(.{ .pid = 4242, .policy = gateReq(false).policy });
    try testing.expect(report.closed);
    try testing.expect(report.failure == null);
    try testing.expect(fx.rt.reconcile == null);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
    try testing.expectEqual(@as(u32, 4), fx.sim.n(.observe));

    var refused: Fx = .{};
    refused.start(testing.allocator, .{});
    refused.sim.seq = &.{&both};
    const before = refused.rt.closeDocument(.{ .pid = 4242, .policy = gateReq(false).policy });
    try testing.expect(!before.closed);
    try testing.expectEqual(FailureKind.wrong_identity, before.failure.?.kind);
    try testing.expectEqual(@as(u32, 0), refused.sim.n(.menu));
}

test "post-close checks preserve console completeness modal and ambiguity refusals" {
    const other: ui.WindowObservation = .{ .title = "other.vwx", .modal = false };
    const policy = gateReq(false).policy;
    var observation: ui.Observation = .{ .console = ready_console, .windows = &.{other}, .windows_complete = true };
    try testing.expectEqual(ui.DecisionKind.wait, Runtime.closeDecision(observation, policy).kind);
    observation.windows_complete = false;
    try testing.expectEqual(ui.DecisionKind.unknown_ui, Runtime.closeDecision(observation, policy).kind);
    observation.windows_complete = true;
    observation.console.owner = "another-user";
    try testing.expectEqual(ui.DecisionKind.console_wrong, Runtime.closeDecision(observation, policy).kind);
    observation.console = ready_console;
    observation.windows = &.{ other, license_win };
    try testing.expectEqual(ui.DecisionKind.unknown_ui, Runtime.closeDecision(observation, policy).kind);
    observation.windows = &.{ other, wm_win };
    try testing.expect(Runtime.closeDecision(observation, policy).kind != .wait);
    observation.windows = &.{ other, doc_win, doc_win };
    try testing.expectEqual(ui.DecisionKind.wrong_target, Runtime.closeDecision(observation, policy).kind);

    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.seq = &.{ &.{doc_win}, &.{ other, license_win } };
    const report = fx.rt.closeDocument(.{ .pid = 4242, .policy = policy });
    try testing.expect(!report.closed);
    try testing.expect(report.failure.?.uncertain);
    try testing.expect(fx.rt.reconcile != null);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
}

test "close never treats incomplete empty window evidence as document absence" {
    for ([_]u32{ 0, 1 }) |complete_until| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{ .max_polls = 4 });
        fx.sim.seq = &.{ &.{doc_win}, &.{}, &.{} };
        fx.sim.complete_until = complete_until;
        const report = fx.rt.closeDocument(.{ .pid = 4242, .policy = gateReq(false).policy });
        try testing.expect(!report.closed);
        const expected_kind: FailureKind = if (complete_until == 1) .uncertain_mutation else .unknown_ui;
        try testing.expectEqual(expected_kind, report.failure.?.kind);
        try testing.expectEqual(complete_until == 1, report.failure.?.uncertain);
        if (complete_until == 1) try testing.expectEqual(FailureKind.timeout, report.failure.?.cause);
        try testing.expectEqual(complete_until == 1, fx.rt.reconcile != null);
        try testing.expectEqual(complete_until, fx.sim.n(.menu));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    }
}

test "native open readiness retries incomplete non-modal evidence only when opted in" {
    for ([_]bool{ false, true }) |allow_wait| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.incomplete_first = 1;
        var req = gateReq(false);
        req.wait_for_readable_windows = allow_wait;
        const report = fx.rt.waitForDocument(req);
        try testing.expectEqual(allow_wait, report.ready);
        if (allow_wait) {
            try testing.expect(report.failure == null);
            try testing.expectEqual(@as(u32, 2), fx.sim.n(.observe));
        } else {
            try testing.expectEqual(FailureKind.unknown_ui, report.failure.?.kind);
        }
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.menu));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    }
}

test "native open readiness preserves modal console and observation failure refusals" {
    const extra = [_][]const ui.WindowObservation{ &.{license_win}, &.{wm_win}, &.{.{ .title = "Unknown", .modal = null }} };
    for (extra) |windows| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.extra = windows;
        fx.sim.incomplete_first = 1;
        var req = gateReq(true);
        req.wait_for_readable_windows = true;
        const report = fx.rt.waitForDocument(req);
        try testing.expect(!report.ready);
        try testing.expectEqual(FailureKind.unknown_ui, report.failure.?.kind);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    }
    var locked: Fx = .{};
    locked.start(testing.allocator, .{});
    locked.sim.console.registry = reg_locked;
    locked.sim.incomplete_first = 1;
    var req = gateReq(false);
    req.wait_for_readable_windows = true;
    const report = locked.rt.waitForDocument(req);
    try testing.expectEqual(FailureKind.console_locked, report.failure.?.kind);
    try testing.expect(!report.ready);
    var failed: Fx = .{};
    failed.start(testing.allocator, .{});
    failed.sim.fail_call = .observe;
    failed.sim.fail = .{ .kind = .transport_error, .detail = "read failed" };
    const failure = failed.rt.waitForDocument(req);
    try testing.expect(!failure.ready);
    try testing.expectEqual(FailureKind.transport_error, failure.failure.?.kind);
}

test "native open unreadable windows remain bounded by poll and operation limits" {
    for ([_]bool{ false, true }) |deadline| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{ .max_polls = if (deadline) 100 else 2, .op_deadline_ms = if (deadline) 1 else 1000 });
        fx.sim.complete_until = 0;
        var req = gateReq(false);
        req.wait_for_readable_windows = true;
        const report = fx.rt.waitForDocument(req);
        try testing.expect(!report.ready);
        try testing.expectEqual(FailureKind.timeout, report.failure.?.kind);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.menu));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    }
}

test "close waits for readable evidence without counting an incomplete absence sample" {
    for ([_]bool{ false, true }) |interrupted| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        if (interrupted) {
            fx.sim.seq = &.{ &.{doc_win}, &.{}, &.{}, &.{}, &.{} };
            fx.sim.complete_seq = &.{ true, true, false, true, true };
        } else {
            fx.sim.seq = &.{ &.{doc_win}, &.{.{ .title = "Vectorworks", .modal = null }}, &.{}, &.{} };
            fx.sim.complete_seq = &.{ true, false, true, true };
        }
        const report = fx.rt.closeDocument(.{ .pid = 4242, .policy = gateReq(false).policy });
        try testing.expect(report.closed);
        try testing.expect(report.failure == null);
        try testing.expect(fx.rt.reconcile == null);
        try testing.expectEqual(@as(u32, if (interrupted) 5 else 4), fx.sim.n(.observe));
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    }
}

test "close preserves immediate modal and console refusals while window reads are incomplete" {
    for ([_]bool{ false, true }) |complete| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.seq = &.{ &.{doc_win}, &.{license_win} };
        fx.sim.complete_seq = &.{ true, complete };
        const report = fx.rt.closeDocument(.{ .pid = 4242, .policy = gateReq(false).policy });
        try testing.expect(!report.closed);
        try testing.expectEqual(FailureKind.unknown_ui, report.failure.?.cause);
        try testing.expect(report.failure.?.uncertain);
        try testing.expect(fx.rt.reconcile != null);
        try testing.expectEqual(@as(u32, 2), fx.sim.n(.observe));
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
    }
    var locked: Fx = .{};
    locked.start(testing.allocator, .{});
    locked.sim.console.registry = reg_locked;
    locked.sim.complete_until = 0;
    var op = locked.rt.newOp(4242, gateReq(false).policy);
    const d = locked.rt.observeClosed(&op).decision;
    try testing.expectEqual(ui.DecisionKind.console_locked, d.kind);
}

test "close permanently unreadable observations reach the operation deadline with uncertainty" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .op_deadline_ms = 1000 });
    fx.sim.seq = &.{ &.{doc_win}, &.{} };
    fx.sim.complete_until = 1;
    const report = fx.rt.closeDocument(.{ .pid = 4242, .policy = gateReq(false).policy });
    try testing.expect(!report.closed);
    try testing.expectEqual(FailureKind.timeout, report.failure.?.cause);
    try testing.expect(report.failure.?.uncertain);
    try testing.expect(fx.rt.reconcile != null);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack));
}

// Save panel repair: path parsing in the real script and the wait for the Go to Folder sheet

/// Runs `script` with the system osascript. Null when it cannot be spawned, as in a sandbox.
fn runOsascript(a: Allocator, script: []const u8, args: []const []const u8) ?[]const u8 {
    var pt: ProcessTransport = .{ .io = testing.io };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    argv.appendSlice(a, &.{ "/usr/bin/osascript", "-e", script }) catch return null;
    argv.appendSlice(a, args) catch return null;
    const r = pt.transport().run(a, argv.items, 20_000, .{});
    defer r.deinit(a);
    if (r.status == .spawn_failed or r.status == .timed_out) return null;
    if (r.status != .exited or r.exit_code != 0) return a.dupe(u8, r.stderr) catch null;
    return a.dupe(u8, std.mem.trim(u8, r.stdout, " \r\n")) catch null;
}

const parse_probe = path_parse_handler ++
    \\on run argv
    \\  set outText to ""
    \\  repeat with stepItem in (my parsePath(item 1 of argv))
    \\    set outText to outText & (item 1 of stepItem) & "|" & (item 2 of stepItem) & "|" & (item 3 of stepItem) & ";"
    \\  end repeat
    \\  return outText
    \\end run
;

test "the real script parses the path text that the backend serializes" {
    var fx = macOnly(&.{});
    fx.start();
    defer fx.stop();
    const deep: Selector = .{ .container = .{ .window = sp_win }, .role = .popup, .label = "", .via = .{ .path = &.{
        .{ .role = .combo_box, .index = 2, .of = 3 },
        .{ .role = .popup, .index = 1, .of = 1 },
    } } };
    const one = fx.mac.selectorArgs(mac_ctx, sp_name, "lookup", "").?[8];
    try testing.expectEqualStrings("AXTextField:1:2", one);
    const two = fx.mac.selectorArgs(mac_ctx, deep, "lookup", "").?[8];
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got1 = runOsascript(a, parse_probe, &.{one}) orelse return error.SkipZigTest;
    try testing.expectEqualStrings("AXTextField|1|2;", got1);
    const got2 = runOsascript(a, parse_probe, &.{two}) orelse return error.SkipZigTest;
    try testing.expectEqualStrings("AXComboBox|2|3;AXPopUpButton|1|1;", got2);
    // The delimiters are restored for the caller.
    const keep = path_parse_handler ++
        \\on run argv
        \\  set AppleScript's text item delimiters to "#"
        \\  my parsePath(item 1 of argv)
        \\  return AppleScript's text item delimiters
        \\end run
    ;
    try testing.expectEqualStrings("#", runOsascript(a, keep, &.{one}) orelse return error.SkipZigTest);
}

test "the control script splits the path before its loop and keeps no lazy text item list" {
    try testing.expect(std.mem.indexOf(u8, script_control, "my parsePath(pathText)") != null);
    try testing.expect(std.mem.indexOf(u8, script_control, "repeat with stepNo from 1 to count of pathSteps") != null);
    // The form that failed live: a loop over `text items` whose body changes the delimiter.
    try testing.expect(std.mem.indexOf(u8, script_control, "in (text items of pathText)") == null);
    try testing.expect(std.mem.indexOf(u8, script_control, "(item 3 of pathParts) as integer") == null);
    // The handler changes the delimiter only after its list exists.
    const h = path_parse_handler;
    const list_at = std.mem.indexOf(u8, h, "set specList to text items of pathText").?;
    const loop_at = std.mem.indexOf(u8, h, "repeat with specIndex from 1 to count of specList").?;
    try testing.expect(list_at < loop_at);
    try testing.expect(std.mem.indexOf(u8, h, "repeat with specIndex in") == null);
}

test "save panel run waits for a sheet that the key opens late, within the dialog wait" {
    var fx: Fx = .{};
    fx.sim.sheet_lag = 3;
    spFixture(&fx);
    var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(u32, 0), fx.sim.sheet_lag);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.chord));
    try testing.expect(fx.fenv.slept_ms > 0);
}

test "save panel run fails at the dialog wait when the sheet never opens and never saves" {
    var fx: Fx = .{};
    fx.sim.sheet_lag = 1_000_000;
    spFixture(&fx);
    var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .unknown_ui);
    try testing.expect(!fx.sim.confirmed);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.press));
    try testing.expect(fx.fenv.slept_ms <= 5_000 + 2_000);
    try testing.expect(fx.sim.n(.lookup) > 3);
}

// Known negative notice: exact text, one press, document beside it

const stl_msg = "Export STL failed. There are no valid objects available for export.";
const stl_texts = [_][]const u8{ stl_msg, "" };
const stl_modal: ui.WindowObservation = .{ .title = "", .modal = true, .texts = &stl_texts, .default_button = "OK" };

fn noticeReq() Runtime.NoticeRequest {
    return .{ .pid = 4242, .policy = .{ .expected = .{ .original = orig, .converted = conv, .watermarked = true } }, .message = stl_msg };
}

fn noticeFx(fx: *Fx, extra: []const ui.WindowObservation) void {
    fx.sim.extra = extra;
    fx.sim.ack_clears = true;
    fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), .{});
}

test "the exact negative notice is pressed once and the ready document confirms it" {
    var fx: Fx = .{};
    noticeFx(&fx, &.{stl_modal});
    const rep = fx.rt.acknowledgeNotice(noticeReq());
    try testing.expect(rep.failure == null and rep.acknowledged and !rep.absent);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.ack));
    try testing.expect(fx.sim.last_ack_exact);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.press) + fx.sim.n(.set) + fx.sim.n(.menu));
}

test "another warning, a changed text, a second modal or a titled alert is never pressed" {
    const other_texts = [_][]const u8{ "Export STL failed. There is no disk space.", "" };
    const extra_texts = [_][]const u8{ stl_msg, "Contact support" };
    const prefix_texts = [_][]const u8{ stl_msg ++ " Retry?", "" };
    const cases = [_]ui.WindowObservation{
        .{ .title = "", .modal = true, .texts = &other_texts, .default_button = "OK" },
        .{ .title = "", .modal = true, .texts = &extra_texts, .default_button = "OK" },
        .{ .title = "", .modal = true, .texts = &prefix_texts, .default_button = "OK" },
        .{ .title = "Vectorworks", .modal = true, .texts = &stl_texts, .default_button = "OK" },
        .{ .title = "", .modal = true, .texts = &stl_texts, .default_button = "Cancel" },
        .{ .title = "", .modal = true, .texts = &stl_texts, .default_button = null },
        .{ .title = "", .modal = true, .texts = null, .default_button = "OK" },
    };
    for (cases) |c| {
        var fx: Fx = .{};
        noticeFx(&fx, &.{c});
        const rep = fx.rt.acknowledgeNotice(noticeReq());
        try testing.expect(!rep.acknowledged and !rep.absent);
        try testing.expectEqual(FailureKind.unknown_ui, rep.failure.?.cause);
        try testing.expect(!rep.failure.?.uncertain);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
    var fx: Fx = .{};
    noticeFx(&fx, &.{ stl_modal, stl_modal });
    const rep = fx.rt.acknowledgeNotice(noticeReq());
    try testing.expectEqual(FailureKind.unknown_ui, rep.failure.?.cause);
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    // The approved button is the only one that a request may name.
    var bad = noticeReq();
    bad.button = "Cancel";
    var fx2: Fx = .{};
    noticeFx(&fx2, &.{stl_modal});
    try testing.expectEqual(FailureKind.refused, fx2.rt.acknowledgeNotice(bad).failure.?.cause);
    try testing.expectEqual(@as(u32, 0), fx2.sim.total());
}

test "no notice is not a failure, and a missing or wrong document refuses the press" {
    {
        var fx: Fx = .{};
        noticeFx(&fx, &.{});
        const rep = fx.rt.acknowledgeNotice(noticeReq());
        try testing.expect(rep.failure == null and rep.absent and !rep.acknowledged);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
    {
        // The expected document window is missing.
        var fx: Fx = .{};
        fx.sim.doc_title = null;
        noticeFx(&fx, &.{stl_modal});
        const rep = fx.rt.acknowledgeNotice(noticeReq());
        try testing.expectEqual(FailureKind.unknown_ui, rep.failure.?.cause);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
    {
        // Another document is the active window.
        var fx: Fx = .{};
        fx.sim.doc_title = "other-document.vwx";
        noticeFx(&fx, &.{stl_modal});
        const rep = fx.rt.acknowledgeNotice(noticeReq());
        try testing.expectEqual(FailureKind.wrong_identity, rep.failure.?.cause);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
    {
        // A locked console refuses before the press.
        var fx: Fx = .{};
        fx.sim.console = locked_console;
        noticeFx(&fx, &.{stl_modal});
        try testing.expectEqual(FailureKind.console_locked, fx.rt.acknowledgeNotice(noticeReq()).failure.?.cause);
        try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    }
}

test "a press that fails or that the app does not answer is separated from a refusal" {
    {
        var fx: Fx = .{};
        fx.sim.fail_call = .ack;
        fx.sim.fail = .{ .kind = .refused, .detail = "default button is not the approved button" };
        noticeFx(&fx, &.{stl_modal});
        const rep = fx.rt.acknowledgeNotice(noticeReq());
        try testing.expect(!rep.failure.?.uncertain and fx.rt.reconcileRequired() == null);
    }
    {
        var fx: Fx = .{};
        fx.sim.fail_call = .ack;
        fx.sim.fail = .{ .kind = .transport_error, .detail = "injected" };
        noticeFx(&fx, &.{stl_modal});
        const rep = fx.rt.acknowledgeNotice(noticeReq());
        try testing.expect(rep.failure.?.uncertain and fx.rt.reconcileRequired() != null);
    }
    {
        // The notice stays after the press: the deadline is a failure, never an acknowledgement.
        var fx: Fx = .{};
        noticeFx(&fx, &.{stl_modal});
        fx.sim.ack_clears = false;
        const rep = fx.rt.acknowledgeNotice(noticeReq());
        try testing.expect(!rep.acknowledged and rep.failure.?.uncertain);
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.ack));
    }
}

test "mac backend accepts an exact notice only when the request says so and the text exists" {
    const rules = [_]FakeTransport.Rule{.{ .has = "script", .out = "" }};
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    const req: AckRequest = .{ .title = "", .texts = &stl_texts, .button = "OK", .class = .unknown };
    try testing.expectEqual(FailureKind.refused, b.acknowledge(mac_ctx, req).failed.kind);
    var ex = req;
    ex.exact_notice = true;
    ex.texts = &.{};
    try testing.expectEqual(FailureKind.refused, b.acknowledge(mac_ctx, ex).failed.kind);
    ex.texts = &stl_texts;
    ex.class = .license;
    try testing.expectEqual(FailureKind.refused, b.acknowledge(mac_ctx, ex).failed.kind);
    try testing.expectEqual(@as(usize, 0), fx.ft.calls.items.len);
}

// Go to Folder key characters

test "only Command-Shift-G names an uppercase character and no other chord changes" {
    try testing.expectEqual(@as(?u16, 'G'), chordUnicode(key_g, flag_command | flag_shift));
    try testing.expectEqual(@as(?u16, null), chordUnicode(key_g, 0));
    try testing.expectEqual(@as(?u16, null), chordUnicode(key_g, flag_command));
    try testing.expectEqual(@as(?u16, null), chordUnicode(key_g, flag_shift));
    try testing.expectEqual(@as(?u16, null), chordUnicode(key_g, flag_command | flag_shift | 0x80000));
    try testing.expectEqual(@as(?u16, null), chordUnicode(4, flag_command | flag_shift));
    try testing.expectEqual(@as(?u16, null), chordUnicode(0, 0));
}

test "the prepared Go to Folder events carry G on key down and key up and nothing is posted" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const flags = flag_command | flag_shift;
    for ([_]bool{ true, false }) |down| {
        const ev = native_keys.prepare(key_g, down, flags) orelse return error.SkipZigTest;
        defer native_keys.release(ev);
        try testing.expectEqual(@as(?u16, 'G'), native_keys.unicodeOf(ev));
    }
    // Another key keeps the character that the system derives. Keycode 5 without the chord stays lowercase.
    const plain = native_keys.prepare(key_g, true, 0) orelse return error.SkipZigTest;
    defer native_keys.release(plain);
    try testing.expectEqual(@as(?u16, 'g'), native_keys.unicodeOf(plain));
    const other = native_keys.prepare(4, true, flags) orelse return error.SkipZigTest;
    defer native_keys.release(other);
    try testing.expectEqual(@as(?u16, 'h'), native_keys.unicodeOf(other));
}

// Disclosure triangle of a collapsed save panel

const disc_path = [_]PathStep{.{ .role = .disclosure, .index = 1, .of = 1 }};
const disc_sel: Selector = .{ .container = .{ .window = sp_win }, .role = .disclosure, .label = "", .via = .{ .path = &disc_path } };

fn discFx(fx: *Fx, initial: []const u8) *SimCtl {
    fx.sim.savePanelControls();
    fx.sim.addRaw(.{ .role = .disclosure, .label = "", .path = &disc_path }, initial);
    fx.sim.dialog_open = true;
    fx.rt = Runtime.init(testing.allocator, fx.sim.backend(), fx.fenv.env(), fx.sim.files(), .{});
    return &fx.sim.ctls[fx.sim.ctl_n - 1];
}

fn discSet(fx: *Fx, want: bool, b: *Builder) ?Failure {
    var op = fx.rt.newOp(4242, .{ .expected = .{ .original = orig, .converted = conv, .watermarked = true } });
    return fx.rt.setOption(&op, b, disc_sel, .{ .checked = want }, false);
}

test "the disclosure role parses with its path grammar and one spelling everywhere" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sel = parseSelectorSpec(arena.allocator(), "disclosure/path/disclosure:1:1", .{ .window = sp_win }).?;
    try testing.expectEqual(Role.disclosure, sel.role);
    try testing.expect(sel.eql(disc_sel));
    try validateSelector(sel, null, .{});
    try testing.expectEqualStrings("AXDisclosureTriangle", Role.disclosure.axRole());
    try testing.expectEqualStrings("unnamed disclosure triangle (by path)", sel.reportLabel());
    // Another spelling is refused, and a path whose last role differs from the selector role is invalid.
    try testing.expect(parseSelectorSpec(arena.allocator(), "disclosuretriangle/path/disclosure:1:1", .{ .window = sp_win }) == null);
    try testing.expect(parseSelectorSpec(arena.allocator(), "disclosure/path/popup:1:1", .{ .window = sp_win }) != null);
    var bad = sel;
    bad.via = .{ .path = &.{.{ .role = .popup, .index = 1, .of = 1 }} };
    try testing.expectError(error.BadSelector, validateSelector(bad, null, .{}));
    // Values: a boolean only.
    try validateValue(sel, .{ .checked = true }, .{});
    try testing.expectError(error.BadRoleValue, validateValue(sel, .{ .text = "1" }, .{}));
    try testing.expectError(error.BadRoleValue, validateValue(sel, .{ .choice = "1" }, .{}));
    // The help names the role and the words.
    try testing.expect(tailHas(control_usage_text, "combo_box or disclosure"));
    try testing.expect(tailHas(control_usage_text, "expanded, collapsed, 1 or 0"));
    // The transport carries the same role name, the exact path with its sibling count and the set value.
    const rules = [_]FakeTransport.Rule{.{ .has = US ++ "set" ++ US, .out = "ok\ts:1\n" }};
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    try testing.expectEqualStrings("1", fx.mac.backend().setValue(mac_ctx, sel, .{ .checked = true }).done.?);
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "AXDisclosureTriangle" ++ US ++ US ++ "1" ++ US ++ "path" ++ US ++ "AXDisclosureTriangle:1:1"));
    try testing.expect(tailHas(script_control, "wantRole is \"AXDisclosureTriangle\" then"));
    try testing.expect(tailHas(script_control, "if ((value of probeControl) as text) is not wantValue then click probeControl"));
}

test "a disclosure resolves only the one triangle with the recorded sibling count" {
    var fx: Fx = .{};
    _ = discFx(&fx, "0");
    const ok = fx.sim.backend().lookup(.{ .pid = 4242, .expected = .{ .original = orig }, .window_title = "x", .timeout_ms = 1000 }, disc_sel).found;
    try testing.expectEqual(@as(u16, 1), ok.count);
    var other = disc_sel;
    other.via = .{ .path = &.{.{ .role = .disclosure, .index = 1, .of = 2 }} };
    const cx: Ctx = .{ .pid = 4242, .expected = .{ .original = orig }, .window_title = "x", .timeout_ms = 1000 };
    try testing.expectEqual(@as(u16, 0), fx.sim.backend().lookup(cx, other).found.count);
    other.via = .{ .path = &.{.{ .role = .disclosure, .index = 2, .of = 2 }} };
    try testing.expectEqual(@as(u16, 0), fx.sim.backend().lookup(cx, other).found.count);
    // The same path with another role never resolves this control.
    var role = disc_sel;
    role.role = .checkbox;
    role.via = .{ .path = &.{.{ .role = .checkbox, .index = 1, .of = 1 }} };
    try testing.expectEqual(@as(u16, 0), fx.sim.backend().lookup(cx, role).found.count);
}

test "a disclosure at the requested state is left unchanged" {
    var fx: Fx = .{};
    _ = discFx(&fx, "1");
    var b: Builder = .{};
    defer b.deinit(testing.allocator);
    try testing.expect(discSet(&fx, true, &b) == null);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.set) + fx.sim.n(.press));
    try testing.expectEqualStrings("1", b.options.items[0].observed);
    // Also a numeric reading such as 1.0 is the same state.
    var fy: Fx = .{};
    _ = discFx(&fy, "0.0");
    var b2: Builder = .{};
    defer b2.deinit(testing.allocator);
    try testing.expect(discSet(&fy, false, &b2) == null);
    try testing.expectEqual(@as(u32, 0), fy.sim.n(.set));
}

test "a disclosure is pressed once and the requested value must read back" {
    var fx: Fx = .{};
    const c = discFx(&fx, "0");
    var b: Builder = .{};
    defer b.deinit(testing.allocator);
    try testing.expect(discSet(&fx, true, &b) == null);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
    try testing.expectEqualStrings("1", c.value[0..c.value_len]);

    // Collapsing works the same way.
    var b2: Builder = .{};
    defer b2.deinit(testing.allocator);
    try testing.expect(discSet(&fx, false, &b2) == null);
    try testing.expectEqual(@as(u32, 2), fx.sim.n(.set));
    // A triangle that reports its new value a moment later is read, not pressed again.
    var fy: Fx = .{};
    const slow = discFx(&fy, "0");
    slow.lag = 4;
    var b3: Builder = .{};
    defer b3.deinit(testing.allocator);
    try testing.expect(discSet(&fy, true, &b3) == null);
    try testing.expectEqual(@as(u32, 1), fy.sim.n(.set));
    try testing.expect(fy.fenv.slept_ms > 0);
}

test "a disclosure that never reports the value fails at the deadline with one press" {
    var fx: Fx = .{};
    const c = discFx(&fx, "0");
    c.stuck = true;
    var b: Builder = .{};
    defer b.deinit(testing.allocator);
    const f = discSet(&fx, true, &b).?;
    try testing.expectEqual(FailureKind.incomplete_options, f.kind);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
    try testing.expectEqualStrings("0", b.options.items[0].observed);
    try testing.expect(fx.fenv.slept_ms > 0 and fx.fenv.slept_ms <= 5_000 + 2_000);
    // The operation deadline ends the wait as an uncertain failure.
    var fy: Fx = .{};
    const d = discFx(&fy, "0");
    d.stuck = true;
    fy.rt.limits.op_deadline_ms = 50;
    fy.rt.limits.dialog_wait_ms = 60_000;
    var b2: Builder = .{};
    defer b2.deinit(testing.allocator);
    const g = discSet(&fy, true, &b2).?;
    try testing.expect(g.kind == .timeout or g.kind == .incomplete_options);
    try testing.expectEqual(@as(u32, 1), fy.sim.n(.set));
}

test "a failed disclosure press is uncertain unless the backend refused it" {
    {
        var fx: Fx = .{};
        _ = discFx(&fx, "0");
        fx.sim.fail_call = .set;
        fx.sim.fail = .{ .kind = .transport_error, .detail = "the press did not return", .uncertain = true };
        var b: Builder = .{};
        defer b.deinit(testing.allocator);
        const f = discSet(&fx, true, &b).?;
        try testing.expect(f.uncertain);
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
    }
    {
        var fx: Fx = .{};
        _ = discFx(&fx, "0");
        fx.sim.fail_call = .set;
        fx.sim.fail = .{ .kind = .refused, .detail = "control is disabled" };
        var b: Builder = .{};
        defer b.deinit(testing.allocator);
        const f = discSet(&fx, true, &b).?;
        try testing.expect(!f.uncertain and f.kind == .refused);
    }
    {
        // A disabled triangle is refused before any press.
        var fx: Fx = .{};
        const c = discFx(&fx, "0");
        c.enabled = false;
        var b: Builder = .{};
        defer b.deinit(testing.allocator);
        try testing.expectEqual(FailureKind.refused, discSet(&fx, true, &b).?.kind);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
    }
}

test "calibration command expands and collapses a disclosure only with --apply and one press" {
    var fx: Fx = .{};
    _ = discFx(&fx, "0");
    fx.sim.extra = &.{modal_win};
    const base = [_][]const u8{ "--control", "disclosure/path/disclosure:1:1" };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // Read.
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &base, cliPath, &out));
    try testing.expect(tailHas(out.written(), "role\tAXDisclosureTriangle\n") and tailHas(out.written(), "value\t0\n"));
    // Plan without --apply.
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &(base ++ [_][]const u8{ "--set", "expanded" }), cliPath, &out));
    try testing.expect(tailHas(out.written(), "plan\tset the control"));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
    // Apply: one set, read back 1.
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &(base ++ [_][]const u8{ "--set", "expanded", "--apply" }), cliPath, &out));
    try testing.expect(tailHas(out.written(), "guard\trecheck\tmatched\n") and tailHas(out.written(), "readback_matches_request\tyes\n"));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
    // Already expanded: unchanged, with or without --apply.
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &(base ++ [_][]const u8{ "--set", "1", "--apply" }), cliPath, &out));
    try testing.expect(tailHas(out.written(), "unchanged\t"));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.set));
    // Collapse.
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &(base ++ [_][]const u8{ "--set", "collapsed", "--apply" }), cliPath, &out));
    try testing.expectEqual(@as(u32, 2), fx.sim.n(.set));
    // A reading that arrives late is read without a second press.
    var fy: Fx = .{};
    const slow = discFx(&fy, "0");
    slow.lag = 3;
    fy.sim.extra = &.{modal_win};
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRun(&fy, &(base ++ [_][]const u8{ "--set", "expanded", "--apply" }), cliPath, &out));
    try testing.expect(tailHas(out.written(), "set_readback_after_wait\t1\n"));
    try testing.expectEqual(@as(u32, 1), fy.sim.n(.set));
    // A control that never reacts fails and was pressed once.
    var fz: Fx = .{};
    const dead = discFx(&fz, "0");
    dead.stuck = true;
    fz.sim.extra = &.{modal_win};
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fz, &(base ++ [_][]const u8{ "--set", "expanded", "--apply" }), cliPath, &out));
    try testing.expect(tailHas(out.written(), "readback_matches_request\tno\n"));
    try testing.expectEqual(@as(u32, 1), fz.sim.n(.set));
    // Bad words and another spelling are usage errors before any call. The modal guard still applies.
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 2), cliRun(&fz, &(base ++ [_][]const u8{ "--set", "open" }), cliPath, &out));
    var fw: Fx = .{};
    _ = discFx(&fw, "0");
    fw.sim.extra = &.{plain_win};
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fw, &(base ++ [_][]const u8{ "--set", "expanded", "--apply" }), cliPath, &out));
    try testing.expectEqual(@as(u32, 0), fw.sim.n(.set));
}

// Save panel navigation with a plain slash key

const sp_dir_slash: SavePanelDir = .{ .where = sp_where, .sheet_field = sp_field, .go = sp_go, .initiator = .slash, .focus_field = sp_name };
const sp_slash_steps = [_]Step{
    .{ .menu = &.{ "File", "Export", "Export PDF" } },
    .{ .destination = .{ .name_field = sp_name, .save_panel = sp_dir_slash } },
    .{ .confirm = sp_save },
};
const sp_slash_route: Route = .{ .id = "save-panel-slash", .format = .obj, .steps = &sp_slash_steps, .cancel = s_cancel, .progress = true, .progress_id = "export-progress", .binding = bind };

fn slashRun(fx: *Fx) ExportReport {
    return fx.rt.runExport(request(.calibration, sp_slash_route, "/tmp/nur/op-1"));
}

test "the initiator is explicit, defaults to Command-Shift-G and needs the exact name field for a slash" {
    try testing.expectEqual(Initiator.command_shift_g, sp_dir.initiator);
    try testing.expect(sp_dir.focus_field == null);
    try validateRoute(sp_route, .verified, .{});
    try validateRoute(sp_slash_route, .verified, .{});
    const conf: Step = .{ .confirm = sp_save };
    const menu: Step = .{ .menu = &.{ "File", "Export" } };
    // A slash without a focus field, with another field, or Command-Shift-G with a focus field.
    var s = sp_dir_slash;
    s.focus_field = null;
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = .{ .name_field = sp_name, .save_panel = s } }, conf }), .calibration);
    s.focus_field = sp_where;
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = .{ .name_field = sp_name, .save_panel = s } }, conf }), .calibration);
    s.focus_field = .{ .container = .{ .window = sp_win }, .role = .text_field, .label = "", .via = .{ .path = &.{.{ .role = .text_field, .index = 2, .of = 2 }} } };
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = .{ .name_field = sp_name, .save_panel = s } }, conf }), .calibration);
    var g = sp_dir;
    g.focus_field = sp_name;
    try expectRouteError(error.BadSelector, routeWith(&.{ menu, .{ .destination = .{ .name_field = sp_name, .save_panel = g } }, conf }), .calibration);
}

test "the default route posts Command-Shift-G and reads no focus" {
    var fx: Fx = .{};
    spFixture(&fx);
    var rep = fx.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(Chord.go_to_folder, fx.sim.last_chord.?);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.focus));
}

test "the slash route reads the focus of the exact name field, then posts one slash and verifies Where" {
    var fx: Fx = .{};
    spFixture(&fx);
    var rep = slashRun(&fx);
    defer rep.deinit(testing.allocator);
    try testing.expect(rep.ok());
    try testing.expectEqual(Chord.slash, fx.sim.last_chord.?);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.focus));
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.chord));
    // Order: focus, then the key, then Go. Save only after Where read back.
    try testing.expect(fx.sim.focus_at == 1 and fx.sim.chord_at == 2 and fx.sim.go_pressed_at == 3);
    try testing.expectEqualStrings("op-1", fx.sim.whereCtl().value[0..fx.sim.whereCtl().value_len]);
    try testing.expect(fx.sim.confirmed);
}

test "a slash is never posted when the name field is not focused, unreadable, disabled or ambiguous" {
    {
        var fx: Fx = .{};
        fx.sim.save_field_focused = false;
        spFixture(&fx);
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .refused);
        try testing.expect(!rep.failure.?.uncertain and fx.rt.reconcileRequired() == null);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.chord));
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.set));
        try testing.expect(!fx.sim.confirmed);
    }
    {
        // The focus read fails.
        var fx: Fx = .{};
        fx.sim.fail_call = .focus;
        fx.sim.fail = .{ .kind = .unknown_ui, .detail = "the control gives no readable focus state" };
        spFixture(&fx);
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .unknown_ui);
        try testing.expect(!rep.failure.?.uncertain);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.chord));
    }
    {
        // A disabled name field.
        var fx: Fx = .{};
        spFixture(&fx);
        fx.sim.ctls[0].enabled = false;
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .refused);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.chord) + fx.sim.n(.focus));
    }
    {
        // Two controls match the name field.
        var fx: Fx = .{};
        spFixture(&fx);
        fx.sim.ctls[0].count = 2;
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .ambiguous_target);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.chord));
    }
    {
        // The Where popup is missing: the panel is not the expected one.
        var fx: Fx = .{};
        spFixture(&fx);
        fx.sim.ctls[1].count = 0;
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.failure != null);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.chord));
    }
}

test "no sheet after the slash is an uncertain failure with a concrete reason and no Save" {
    var fx: Fx = .{};
    fx.sim.slash_opens = false;
    spFixture(&fx);
    var rep = slashRun(&fx);
    defer rep.deinit(testing.allocator);
    try expectFail(rep, .uncertain_mutation);
    const f = rep.failure.?;
    try testing.expect(f.uncertain and f.cause == .unknown_ui);
    try testing.expect(tailHas(f.detail(), "no Go to Folder sheet appeared after the slash key"));
    try testing.expect(fx.rt.reconcileRequired() != null);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.chord));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.set) + fx.sim.n(.press));
    try testing.expect(!fx.sim.confirmed);
    // The wait is bounded by the dialog wait.
    try testing.expect(fx.fenv.slept_ms <= 5_000 + 2_000);
    // The default initiator keeps its earlier, non-uncertain failure for a sheet that never opens.
    var fy: Fx = .{};
    fy.sim.sheet_lag = 1_000_000;
    spFixture(&fy);
    var rep2 = fy.rt.runExport(request(.calibration, sp_route, "/tmp/nur/op-1"));
    defer rep2.deinit(testing.allocator);
    try expectFail(rep2, .unknown_ui);
    try testing.expect(!rep2.failure.?.uncertain);
}

test "a refused slash is not uncertain, a dispatched or failed one is, and later failures keep it" {
    {
        var fx: Fx = .{};
        fx.sim.fail_call = .chord;
        fx.sim.fail = .{ .kind = .refused, .detail = "window is absent" };
        spFixture(&fx);
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try expectFail(rep, .refused);
        try testing.expect(!rep.failure.?.uncertain and fx.rt.reconcileRequired() == null);
    }
    {
        var fx: Fx = .{};
        fx.sim.fail_call = .chord;
        fx.sim.fail = .{ .kind = .transport_error, .detail = "injected", .uncertain = true };
        spFixture(&fx);
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.failure.?.uncertain and fx.rt.reconcileRequired() != null);
        try testing.expect(!fx.sim.confirmed);
    }
    // After the key every failure is uncertain: a sheet that stays open, a Where that does not follow, a failed Go.
    {
        var fx: Fx = .{};
        fx.sim.reject_path = true;
        spFixture(&fx);
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.failure.?.uncertain and rep.failure.?.cause == .unknown_ui);
        try testing.expect(!fx.sim.confirmed);
    }
    {
        var fx: Fx = .{};
        fx.sim.where_frozen = true;
        spFixture(&fx);
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.failure.?.uncertain and rep.failure.?.cause == .incomplete_options);
        try testing.expect(!fx.sim.confirmed);
    }
    {
        var fx: Fx = .{};
        fx.sim.fail_call = .set;
        fx.sim.fail = .{ .kind = .refused, .detail = "control is disabled" };
        spFixture(&fx);
        var rep = slashRun(&fx);
        defer rep.deinit(testing.allocator);
        try testing.expect(rep.failure.?.uncertain);
        try testing.expect(!fx.sim.confirmed);
    }
}

test "mac backend posts a plain slash to the pid only after the exact window is found" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = sp_win ++ US ++ "identity", .out = "ok\t1,2;3,4;5\n" },
        .{ .has = "Missing" ++ US ++ "identity", .out = "refused\twindow_absent\n" },
        .{ .has = "Twice" ++ US ++ "identity", .out = "refused\twindow_ambiguous\n" },
    };
    var fx = macOnly(&rules);
    fx.ft.rules = &rules;
    fx.mac = MacBackend.init(testing.allocator, fx.ft.transport(), fx.fenv.env(), .{ .key_post = KeyLog.post });
    defer fx.stop();
    KeyLog.n = 0;
    KeyLog.ok = true;
    const b = fx.mac.backend();
    try testing.expect(b.chord(mac_ctx, sp_win, .slash) == .done);
    try testing.expectEqual(@as(u32, 1), KeyLog.n);
    try testing.expectEqual(@as(i32, 4242), KeyLog.pid);
    try testing.expectEqual(@as(u16, 44), KeyLog.key);
    try testing.expectEqual(@as(u64, 0), KeyLog.flags);
    // A missing or ambiguous window posts nothing.
    try testing.expectEqual(FailureKind.unknown_ui, b.chord(mac_ctx, "Missing", .slash).failed.kind);
    try testing.expectEqual(FailureKind.ambiguous_target, b.chord(mac_ctx, "Twice", .slash).failed.kind);
    try testing.expectEqual(@as(u32, 1), KeyLog.n);
    KeyLog.ok = false;
    const f = b.chord(mac_ctx, sp_win, .slash).failed;
    try testing.expect(f.kind == .refused and !f.uncertain);
    // Command-Shift-G keeps its key and flags.
    KeyLog.ok = true;
    try testing.expect(b.chord(mac_ctx, sp_win, .go_to_folder) == .done);
    try testing.expect(KeyLog.key == 5 and KeyLog.flags == 0x120000);
}

test "only the slash chord names a slash character and the platform events carry it" {
    try testing.expectEqual(@as(?u16, '/'), chordUnicode(key_slash, 0));
    try testing.expectEqual(@as(?u16, null), chordUnicode(key_slash, flag_command));
    try testing.expectEqual(@as(?u16, null), chordUnicode(key_slash, flag_shift));
    try testing.expectEqual(@as(?u16, null), chordUnicode(45, 0));
    try testing.expectEqual(@as(?u16, 'G'), chordUnicode(key_g, flag_command | flag_shift));
    try testing.expectEqual(@as(?u16, null), chordUnicode(key_g, 0));
    if (builtin.os.tag != .macos) return;
    for ([_]bool{ true, false }) |down| {
        const ev = native_keys.prepare(key_slash, down, 0) orelse return error.SkipZigTest;
        defer native_keys.release(ev);
        try testing.expectEqual(@as(?u16, '/'), native_keys.unicodeOf(ev));
    }
    // Another plain key keeps the character that the system derives.
    const other = native_keys.prepare(4, true, 0) orelse return error.SkipZigTest;
    defer native_keys.release(other);
    try testing.expectEqual(@as(?u16, 'h'), native_keys.unicodeOf(other));
}

test "mac backend reads AXFocused with a read-only script mode" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = "LBL-1", .out = "ok\tt\n" },
        .{ .has = "LBL-2", .out = "ok\tf\n" },
        .{ .has = "LBL-3", .out = "ok\tu\n" },
        .{ .has = "LBL-4", .out = "refused\tcontrol_absent\n" },
        .{ .has = "LBL-5", .out = "refused\tcontrol_ambiguous\n" },
        .{ .has = "LBL-6", .out = "refused\tcontrol_disabled\n" },
        .{ .has = "LBL-7", .out = "ok\tmaybe\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    const mk = struct {
        fn f(label: []const u8) Selector {
            return .{ .container = .{ .window = sp_win }, .role = .text_field, .label = label, .via = .title_element };
        }
    }.f;
    try testing.expect(b.focused(mac_ctx, mk("LBL-1")).focused);
    try testing.expect(!b.focused(mac_ctx, mk("LBL-2")).focused);
    try testing.expectEqual(FailureKind.unknown_ui, b.focused(mac_ctx, mk("LBL-3")).failed.kind);
    try testing.expectEqual(FailureKind.unknown_ui, b.focused(mac_ctx, mk("LBL-4")).failed.kind);
    try testing.expectEqual(FailureKind.ambiguous_target, b.focused(mac_ctx, mk("LBL-5")).failed.kind);
    try testing.expectEqual(FailureKind.refused, b.focused(mac_ctx, mk("LBL-6")).failed.kind);
    try testing.expectEqual(FailureKind.transport_error, b.focused(mac_ctx, mk("LBL-7")).failed.kind);
    try testing.expect(tailHas(fx.ft.lastCall(), US ++ "focused" ++ US ++ "AXTextField" ++ US));
    // The mode only reads: its block of the script has no click, no set and no key.
    const at = std.mem.indexOf(u8, script_control, "if probeMode is \"focused\" then").?;
    const end = std.mem.indexOfPos(u8, script_control, at, "if probeMode is \"lookup\" then").?;
    const block = script_control[at..end];
    try testing.expect(tailHas(block, "AXFocused"));
    for ([_][]const u8{ "click", "set value", "set focused", "keystroke", "key code", "perform" }) |w| try testing.expect(!tailHas(block, w));
    // A backend without the call refuses.
    var s: Sim = .{};
    var be = s.backend();
    be.focusedFn = refuseFocused;
    try testing.expectEqual(FailureKind.refused, be.focused(mac_ctx, mk("LBL-1")).failed.kind);
}

test "calibration command navigates with the slash initiator only after the field reads focused" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const nav = [_][]const u8{ "--where", "popup/title/Where:", "--sheet-field", "text_field/title/Go to the folder:", "--go", "button/label/Go", "--navigate", "/tmp/nur/op-9", "--initiator", "slash", "--save-field", "text_field/path/text_field:1:2" };
    // Without --apply: read only, with the focus state printed.
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &nav, cliPath, &out));
    try testing.expect(tailHas(out.written(), "initiator\tslash\n") and tailHas(out.written(), "save_field_focused\ttrue\n") and tailHas(out.written(), "plan\tnavigate"));
    try testing.expectEqual(@as(u32, 0), fx.sim.mutations());
    out.writer.end = 0;
    var apply: [nav.len + 1][]const u8 = undefined;
    @memcpy(apply[0..nav.len], &nav);
    apply[nav.len] = "--apply";
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &apply, cliPath, &out));
    try testing.expect(tailHas(out.written(), "observed\top-9\n") and tailHas(out.written(), "result\tok\n"));
    try testing.expectEqual(Chord.slash, fx.sim.last_chord.?);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.chord));
    try testing.expect(!fx.sim.confirmed);
    // Not focused: refused before any key, with or without --apply.
    var fy: Fx = .{};
    fy.sim.save_field_focused = false;
    cliFx(&fy, &.{modal_win});
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fy, &apply, cliPath, &out));
    try testing.expect(tailHas(out.written(), "save_field_focused\tfalse\n") and tailHas(out.written(), "No key was posted"));
    try testing.expectEqual(@as(u32, 0), fy.sim.n(.chord));
    // No sheet after the key: failed, with the typed-slash warning.
    var fz: Fx = .{};
    fz.sim.slash_opens = false;
    cliFx(&fz, &.{modal_win});
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fz, &apply, cliPath, &out));
    try testing.expect(tailHas(out.written(), "uncertain\ttrue\n") and tailHas(out.written(), "typed into the Save As field") and tailHas(out.written(), "result\tfailed\n"));
    try testing.expect(!fz.sim.confirmed);
    // The window guard still applies: a non-modal window refuses before any read of the field.
    var fw: Fx = .{};
    cliFx(&fw, &.{plain_win});
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fw, &apply, cliPath, &out));
    try testing.expectEqual(@as(u32, 0), fw.sim.n(.focus) + fw.sim.n(.chord));
    // The wrong executable refuses before any call.
    var fv: Fx = .{};
    cliFx(&fv, &.{modal_win});
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 1), cliRun(&fv, &apply, cliPathOther, &out));
    try testing.expectEqual(@as(u32, 0), fv.sim.n(.focus) + fv.sim.n(.chord) + fv.sim.n(.lookup));
}

test "the initiator options are explicit and checked" {
    var fx: Fx = .{};
    cliFx(&fx, &.{modal_win});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const base = [_][]const u8{ "--where", "popup/title/Where:", "--sheet-field", "text_field/title/Go to the folder:", "--go", "button/label/Go", "--navigate", "/tmp/nur/op-9" };
    for ([_][]const []const u8{
        &(base ++ [_][]const u8{ "--initiator", "slash" }),
        &(base ++ [_][]const u8{ "--save-field", "text_field/path/text_field:1:2" }),
        &(base ++ [_][]const u8{ "--initiator", "tab", "--save-field", "text_field/path/text_field:1:2" }),
        &(base ++ [_][]const u8{ "--initiator", "slash", "--save-field", "bogus" }),
        &.{ "--control", "popup/title/Where:", "--initiator", "slash", "--save-field", "text_field/path/text_field:1:2" },
        &(base ++ [_][]const u8{ "--initiator", "slash", "--save-field", "popup/title/Where:" }),
    }) |extra| {
        out.writer.end = 0;
        try testing.expectEqual(@as(u8, 2), cliRun(&fx, extra, cliPath, &out));
    }
    try testing.expectEqual(@as(u32, 0), fx.sim.total());
    // The explicit default is the same as no option.
    out.writer.end = 0;
    try testing.expectEqual(@as(u8, 0), cliRun(&fx, &(base ++ [_][]const u8{ "--initiator", "command-shift-g" }), cliPath, &out));
    try testing.expect(tailHas(out.written(), "initiator\tcommand-shift-g\n") and !tailHas(out.written(), "save_field"));
    try testing.expect(tailHas(control_usage_text, "--initiator slash --save-field SEL"));
}

// Don't Save for the exact save prompt of an owned query copy

const prompt_line_1 = "Do you want to save the changes you made in the document \"" ++ orig ++ "\"?";
const prompt_line_2 = "Your changes will be lost if you don't save them.";
const prompt_texts = [_][]const u8{ prompt_line_1, prompt_line_2 };
const prompt_win: ui.WindowObservation = .{ .title = "", .modal = true, .texts = &prompt_texts, .default_button = "Save" };
const discard_policy: Runtime.DiscardPolicy = .{ .document = orig };

fn discardClose(fx: *Fx, discard: ?Runtime.DiscardPolicy) Runtime.CloseReport {
    return fx.rt.closeDocument(.{ .pid = 4242, .policy = gateReq(false).policy, .discard = discard });
}

test "the exact save prompt of the owned document is answered with Don't Save once" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, prompt_win }, &.{}, &.{} };
    const rep = discardClose(&fx, discard_policy);
    try testing.expect(rep.closed and rep.discarded and rep.failure == null);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.dismiss));
    try testing.expectEqualStrings("Don't Save", fx.sim.last_dismiss_button);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.ack) + fx.sim.n(.press) + fx.sim.n(.set));
    try testing.expect(fx.rt.reconcile == null);
}

test "without a policy the save prompt keeps the default refusal and nothing is pressed" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, prompt_win } };
    const rep = discardClose(&fx, null);
    try testing.expect(!rep.closed and !rep.discarded);
    try testing.expectEqual(FailureKind.unknown_ui, rep.failure.?.cause);
    try testing.expect(rep.failure.?.uncertain and fx.rt.reconcile != null);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.dismiss));
}

test "another prompt, another document, another text or a second dialog is never answered" {
    const other_doc = [_][]const u8{ "Do you want to save the changes you made in the document \"other.vwx\"?", prompt_line_2 };
    const other_text = [_][]const u8{ prompt_line_1, "Your changes will be saved." };
    const three = [_][]const u8{ prompt_line_1, prompt_line_2, "More" };
    const one = [_][]const u8{prompt_line_1};
    const missing_quote = [_][]const u8{ "Do you want to save the changes you made in the document \"" ++ orig ++ "\"", prompt_line_2 };
    const cases = [_][]const ui.WindowObservation{
        &.{ doc_win, .{ .title = "", .modal = true, .texts = &other_doc, .default_button = "Save" } },
        &.{ doc_win, .{ .title = "", .modal = true, .texts = &other_text, .default_button = "Save" } },
        &.{ doc_win, .{ .title = "", .modal = true, .texts = &three, .default_button = "Save" } },
        &.{ doc_win, .{ .title = "", .modal = true, .texts = &one, .default_button = "Save" } },
        &.{ doc_win, .{ .title = "", .modal = true, .texts = &missing_quote, .default_button = "Save" } },
        &.{ doc_win, .{ .title = "Vectorworks", .modal = true, .texts = &prompt_texts, .default_button = "Save" } },
        &.{ doc_win, license_win },
        &.{ doc_win, overwrite_win },
        &.{ doc_win, prompt_win, prompt_win },
        &.{ doc_win, prompt_win, license_win },
        // The prompt without the document window, with another document, or with two windows of the document.
        &.{prompt_win},
        &.{ .{ .title = "other.vwx", .modal = false }, prompt_win },
        &.{ doc_win, doc_win, prompt_win },
    };
    for (cases) |obs| {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.seq = &.{ &.{doc_win}, obs };
        const rep = discardClose(&fx, discard_policy);
        try testing.expect(!rep.closed and !rep.discarded);
        try testing.expect(rep.failure.?.uncertain);
        try testing.expectEqual(@as(u32, 0), fx.sim.n(.dismiss));
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.menu));
        try testing.expect(fx.rt.reconcile != null);
    }
}

test "a discard for another document is refused before the close menu" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.seq = &.{&.{doc_win}};
    const rep = discardClose(&fx, .{ .document = "other.vwx" });
    try testing.expectEqual(FailureKind.refused, rep.failure.?.cause);
    try testing.expect(!rep.failure.?.uncertain);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.menu) + fx.sim.n(.dismiss));
}

test "a prompt that is not readable yet is waited for and never pressed early" {
    // Texts unread, then a readable prompt, then the closed document.
    var fx: Fx = .{};
    fx.start(testing.allocator, .{});
    fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, .{ .title = "", .modal = true, .texts = null } }, &.{ doc_win, prompt_win }, &.{}, &.{} };
    fx.sim.complete_seq = &.{ true, false, true, true, true };
    var rep = discardClose(&fx, discard_policy);
    try testing.expect(rep.closed and rep.discarded and rep.failure == null);
    try testing.expectEqual(@as(u32, 1), fx.sim.n(.dismiss));
    try testing.expectEqual(@as(u32, 5), fx.sim.n(.observe));
    // A title that is not readable yet is also waited for.
    var fy: Fx = .{};
    fy.start(testing.allocator, .{});
    fy.sim.seq = &.{ &.{doc_win}, &.{ doc_win, .{ .title = null, .modal = true, .texts = &prompt_texts } }, &.{ doc_win, prompt_win }, &.{}, &.{} };
    fy.sim.complete_seq = &.{ true, false, true, true, true };
    rep = discardClose(&fy, discard_policy);
    try testing.expect(rep.closed and rep.discarded);
    // A complete prompt beside an incomplete window read is not pressed until the read is complete.
    var fz: Fx = .{};
    fz.start(testing.allocator, .{});
    fz.sim.seq = &.{ &.{doc_win}, &.{ doc_win, prompt_win }, &.{ doc_win, prompt_win }, &.{}, &.{} };
    fz.sim.complete_seq = &.{ true, false, true, true, true };
    rep = discardClose(&fz, discard_policy);
    try testing.expect(rep.closed and rep.discarded);
    try testing.expectEqual(@as(u32, 1), fz.sim.n(.dismiss));
    try testing.expectEqual(@as(u32, 5), fz.sim.n(.observe));
}

test "a prompt that never becomes readable ends at the deadline as an uncertain failure" {
    var fx: Fx = .{};
    fx.start(testing.allocator, .{ .op_deadline_ms = 1000 });
    fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, .{ .title = "", .modal = true, .texts = null } } };
    fx.sim.complete_seq = &.{ true, false };
    const rep = discardClose(&fx, discard_policy);
    try testing.expect(!rep.closed and !rep.discarded);
    try testing.expectEqual(FailureKind.timeout, rep.failure.?.cause);
    try testing.expect(rep.failure.?.uncertain and fx.rt.reconcile != null);
    try testing.expectEqual(@as(u32, 0), fx.sim.n(.dismiss));
}

test "a failed press, a prompt that stays and a prompt that returns keep the uncertainty" {
    {
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, prompt_win } };
        fx.sim.fail_call = .dismiss;
        fx.sim.fail = .{ .kind = .transport_error, .detail = "injected", .uncertain = true };
        const rep = discardClose(&fx, discard_policy);
        try testing.expect(!rep.closed and !rep.discarded);
        try testing.expect(rep.failure.?.uncertain and fx.rt.reconcile != null);
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.dismiss));
    }
    {
        // A refused press still follows a dispatched close menu step.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, prompt_win } };
        fx.sim.fail_call = .dismiss;
        fx.sim.fail = .{ .kind = .unknown_ui, .detail = "the dialog has not exactly one button of that name" };
        const rep = discardClose(&fx, discard_policy);
        try testing.expect(rep.failure.?.uncertain and fx.rt.reconcile != null);
    }
    {
        // The prompt is still there after the press: it is not pressed twice.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, prompt_win }, &.{ doc_win, prompt_win } };
        const rep = discardClose(&fx, discard_policy);
        try testing.expect(!rep.closed and rep.discarded);
        try testing.expect(rep.failure.?.uncertain and tailHas(rep.failure.?.detail(), "appeared again"));
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.dismiss));
    }
    {
        // After the press another dialog appears: refused as before.
        var fx: Fx = .{};
        fx.start(testing.allocator, .{});
        fx.sim.seq = &.{ &.{doc_win}, &.{ doc_win, prompt_win }, &.{license_win} };
        const rep = discardClose(&fx, discard_policy);
        try testing.expect(rep.discarded and !rep.closed and rep.failure.?.uncertain);
        try testing.expectEqual(@as(u32, 1), fx.sim.n(.dismiss));
    }
}

test "mac backend presses only the discard button of an exact dialog and keeps its script read bound" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = "script-ok-marker", .out = "ok\n" },
        .{ .has = "on run argv", .out = "ok\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    const req: DismissRequest = .{ .title = "", .texts = &prompt_texts, .button = "Don't Save" };
    try testing.expect(b.dismiss(mac_ctx, req) == .done);
    const call = fx.ft.lastCall();
    try testing.expect(tailHas(call, US ++ "s:" ++ US ++ "Don't Save" ++ US ++ prompt_line_1 ++ "\x1f" ++ prompt_line_2));
    // Other buttons, no text and no readable title never reach the script.
    const before = fx.ft.calls.items.len;
    for ([_][]const u8{ "Save", "Cancel", "OK", "Don\u{2019}t Save", "" }) |btn| {
        var r = req;
        r.button = btn;
        try testing.expectEqual(FailureKind.refused, b.dismiss(mac_ctx, r).failed.kind);
    }
    try testing.expectEqual(FailureKind.refused, b.dismiss(mac_ctx, .{ .title = "", .texts = &.{}, .button = "Don't Save" }).failed.kind);
    try testing.expectEqual(FailureKind.refused, b.dismiss(mac_ctx, .{ .title = null, .texts = &prompt_texts, .button = "Don't Save" }).failed.kind);
    try testing.expectEqual(before, fx.ft.calls.items.len);
    // The script has the pid guard and the exact window and button match, no activation, key or default-button press.
    try testing.expect(tailHas(script_dismiss, "first process whose unix id is probePid"));
    try testing.expect(tailHas(script_dismiss, "probeTitle is wantTitle and probeJoined is wantTexts"));
    try testing.expect(tailHas(script_dismiss, "(every button of matchedWindow whose name is wantButton)"));
    try testing.expect(tailHas(script_dismiss, "is not 1 then return \"refused\" & tab & \"button_not_found\""));
    for ([_][]const u8{ "activate", "frontmost", "keystroke", "key code", "screencapture", "do shell script", "AXDefaultButton", "tell application \"Vectorworks" }) |w| try testing.expect(!tailHas(script_dismiss, w));
}

test "dismiss replies keep refusals apart from actions that may have run" {
    const rules = [_]FakeTransport.Rule{
        .{ .has = "LBL-REFUSE", .out = "refused\tbutton_not_found\n" },
        .{ .has = "LBL-ABSENT", .out = "refused\twindow_absent\n" },
        .{ .has = "LBL-AMBIG", .out = "refused\twindow_ambiguous\n" },
        .{ .has = "LBL-FAIL", .out = "failed_after_start\t-1728\n" },
        .{ .has = "LBL-GONE", .out = "gone\n" },
    };
    var fx = macOnly(&rules);
    fx.start();
    defer fx.stop();
    const b = fx.mac.backend();
    const mk = struct {
        fn f(comptime label: []const u8) DismissRequest {
            return .{ .title = "", .texts = &.{ label, prompt_line_2 }, .button = "Don't Save" };
        }
    }.f;
    const a1 = b.dismiss(mac_ctx, mk("LBL-REFUSE")).failed;
    try testing.expect(a1.kind == .unknown_ui and !a1.uncertain);
    try testing.expectEqual(FailureKind.unknown_ui, b.dismiss(mac_ctx, mk("LBL-ABSENT")).failed.kind);
    try testing.expectEqual(FailureKind.ambiguous_target, b.dismiss(mac_ctx, mk("LBL-AMBIG")).failed.kind);
    try testing.expect(b.dismiss(mac_ctx, mk("LBL-FAIL")).failed.uncertain);
    try testing.expectEqual(FailureKind.process_lost, b.dismiss(mac_ctx, mk("LBL-GONE")).failed.kind);
    // A backend without the call refuses.
    var s: Sim = .{};
    var be = s.backend();
    be.dismissFn = refuseDismiss;
    try testing.expectEqual(FailureKind.refused, be.dismiss(mac_ctx, mk("x")).failed.kind);
}
