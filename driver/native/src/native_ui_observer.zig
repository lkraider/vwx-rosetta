//! Notification source for the native UI runtime.
//!
//! A notification is a wakeup. It carries a kind and a count, never a result. The consumer reads
//! current state after every wakeup and decides completion from that state.
//!
//! Order of use:
//! 1. `Observer.create` with a `Backend`.
//! 2. `Observer.subscribe` for the authorized pid, before the caller sends its action.
//! 3. The caller sends the action, then calls `wait` and reads current state after each return.
//! 4. `teardown` releases every resource that `subscribe` created. `destroy` frees the observer.
//!
//! Events that arrive before the first `wait` stay in a bounded per-kind counter. The counter
//! saturates at `max_count`. A saturated counter, or a `lost` event, means the consumer must rescan.
//!
//! `SystemBackend` uses AXObserver for UI events and kqueue for process exit and path changes.
//! `FakeBackend` posts events from test code and calls no native API.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Allocator = std.mem.Allocator;

const is_macos = builtin.os.tag == .macos;

// Events

pub const Kind = enum(u8) {
    window_created,
    window_destroyed,
    focus_changed,
    layout_changed,
    value_changed,
    title_changed,
    menu_opened,
    sheet_created,
    app_activated,
    /// The watched process exited. Sticky. Every later wait reports it.
    process_exit,
    file_changed,
    bridge_changed,
    /// The source cannot vouch for completeness. The consumer rescans current state.
    lost,
};

pub const kind_count = @typeInfo(Kind).@"enum".fields.len;
pub const max_count: u16 = std.math.maxInt(u16);

/// Bit set of kinds.
pub const KindSet = struct {
    bits: u32 = 0,

    pub fn has(s: KindSet, k: Kind) bool {
        return s.bits & (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(k)))) != 0;
    }

    pub fn add(s: *KindSet, k: Kind) void {
        s.bits |= @as(u32, 1) << @as(u5, @intCast(@intFromEnum(k)));
    }
};

/// Events taken since the previous take.
pub const Wake = struct {
    counts: [kind_count]u16 = [_]u16{0} ** kind_count,

    pub fn count(w: Wake, k: Kind) u16 {
        return w.counts[@intFromEnum(k)];
    }

    pub fn has(w: Wake, k: Kind) bool {
        return w.count(k) != 0;
    }

    pub fn any(w: Wake) bool {
        for (w.counts) |n| if (n != 0) return true;
        return false;
    }

    /// More than one notification of the kind arrived since the previous take.
    pub fn coalesced(w: Wake, k: Kind) bool {
        return w.count(k) > 1;
    }

    /// The counter reached `max_count`. Further notifications of the kind were counted by the
    /// cap only.
    pub fn saturated(w: Wake, k: Kind) bool {
        return w.count(k) == max_count;
    }

    /// The consumer rescans when this is true.
    pub fn needsRescan(w: Wake) bool {
        if (w.has(.lost)) return true;
        for (w.counts) |n| if (n == max_count) return true;
        return false;
    }

    pub fn processExited(w: Wake) bool {
        return w.has(.process_exit);
    }
};

pub const WaitResult = union(enum) {
    wake: Wake,
    /// No notification arrived within the timeout. The consumer polls current state and labels
    /// the observation as polling.
    timeout,
    /// A signal or `interrupt` ended the wait. The consumer reads current state.
    interrupted,
    /// `teardown` ran.
    closed,
};

// Sink

/// Event state shared by the backend threads and the waiter. Every field is atomic.
pub const Sink = struct {
    counts: [kind_count]std.atomic.Value(u16) = [_]std.atomic.Value(u16){std.atomic.Value(u16).init(0)} ** kind_count,
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Notifications posted since creation.
    posted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pipe_r: c.fd_t = -1,
    pipe_w: c.fd_t = -1,

    /// Safe from any thread. A post after teardown is dropped.
    pub fn post(s: *Sink, k: Kind) void {
        if (s.closed.load(.acquire)) return;
        const slot = &s.counts[@intFromEnum(k)];
        var cur = slot.load(.monotonic);
        while (cur != max_count) {
            cur = slot.cmpxchgWeak(cur, cur + 1, .release, .monotonic) orelse break;
        }
        if (k == .process_exit) s.exited.store(true, .release);
        _ = s.posted.fetchAdd(1, .monotonic);
        s.kick();
    }

    fn kick(s: *Sink) void {
        const b = [1]u8{1};
        // A full pipe already holds a pending wakeup, so a failed write loses nothing.
        _ = c.write(s.pipe_w, &b, 1);
    }

    fn drain(s: *Sink) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(s.pipe_r, &buf, buf.len);
            if (n <= 0) break;
            if (n < buf.len) break;
        }
    }

    fn take(s: *Sink) Wake {
        var w: Wake = .{};
        for (&s.counts, 0..) |*slot, i| w.counts[i] = slot.swap(0, .acquire);
        if (s.exited.load(.acquire) and w.counts[@intFromEnum(Kind.process_exit)] == 0) {
            w.counts[@intFromEnum(Kind.process_exit)] = 1;
        }
        return w;
    }
};

// Subscription request and capability report

pub const max_watches = 8;
pub const max_capabilities = 32;

pub const Watch = struct {
    path: []const u8,
    /// `file_changed` or `bridge_changed`.
    kind: Kind = .file_changed,
};

pub const Request = struct {
    pid: i32,
    /// UI and layout notifications for the pid.
    ax: bool = true,
    /// Exit notification for the pid.
    process: bool = true,
    /// A file watch reports writes and extends. A directory watch reports entries added, removed
    /// or renamed. A path that does not exist yet needs a watch on its parent directory.
    watches: []const Watch = &.{},
};

pub const Source = enum { ax, process, path };

pub const Status = enum {
    active,
    not_requested,
    unsupported_platform,
    /// The platform rejected this notification name for the target.
    unsupported_notification,
    /// The Accessibility permission is absent for this executable.
    not_trusted,
    /// The OS refused the subscription for another permission reason.
    denied,
    /// The pid had exited before subscription. The sink holds a `process_exit` event.
    process_gone,
    path_missing,
    failed,
};

pub const Capability = struct {
    source: Source,
    kind: Kind,
    /// Notification name, kqueue filter name, or `path`.
    label: []const u8,
    /// Index into `Request.watches` for `path`, otherwise 0.
    index: u8 = 0,
    status: Status,
    /// AXError or errno of the failing call. 0 when none.
    code: i32 = 0,
};

pub const Caps = struct {
    items: [max_capabilities]Capability = undefined,
    len: usize = 0,

    pub fn add(cs: *Caps, cap: Capability) void {
        if (cs.len == max_capabilities) return;
        cs.items[cs.len] = cap;
        cs.len += 1;
    }

    pub fn slice(cs: *const Caps) []const Capability {
        return cs.items[0..cs.len];
    }
};

pub const Mode = enum {
    /// Every requested subscription is active.
    notifications,
    /// Some active, some not. Kinds without an active subscription need polling.
    partial,
    /// No subscription is active. All observation is polling.
    polling,
};

// Backend

/// `subscribeFn` registers everything before it returns and reports one capability per
/// attempted subscription. `teardownFn` stops every thread and releases every resource that
/// `subscribeFn` created. `teardownFn` runs once.
pub const Backend = struct {
    ptr: *anyopaque,
    subscribeFn: *const fn (ptr: *anyopaque, sink: *Sink, req: Request, out: *Caps) void,
    teardownFn: *const fn (ptr: *anyopaque) void,
};

pub const Error = error{ AlreadySubscribed, TooManyWatches, PipeFailed, OutOfMemory };

pub const Observer = struct {
    a: Allocator,
    backend: Backend,
    sink: Sink = .{},
    caps: Caps = .{},
    subscribed: bool = false,
    torn_down: bool = false,

    pub fn create(a: Allocator, backend: Backend) Error!*Observer {
        const o = try a.create(Observer);
        o.* = .{ .a = a, .backend = backend };
        var fds: [2]c.fd_t = undefined;
        if (c.pipe(&fds) != 0) {
            a.destroy(o);
            return error.PipeFailed;
        }
        o.sink.pipe_r = fds[0];
        o.sink.pipe_w = fds[1];
        for (fds) |fd| {
            const fl = c.fcntl(fd, 3); // F_GETFL
            _ = c.fcntl(fd, 4, fl | 0x4); // F_SETFL, O_NONBLOCK
            _ = c.fcntl(fd, 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
        }
        return o;
    }

    /// Call `teardown` first. No other thread may be inside `wait`.
    pub fn destroy(o: *Observer) void {
        o.teardown();
        _ = c.close(o.sink.pipe_r);
        _ = c.close(o.sink.pipe_w);
        const a = o.a;
        a.destroy(o);
    }

    /// Registers the subscriptions. Call before the action whose result the caller waits for.
    pub fn subscribe(o: *Observer, req: Request) Error!void {
        if (o.subscribed) return error.AlreadySubscribed;
        if (req.watches.len > max_watches) return error.TooManyWatches;
        o.subscribed = true;
        o.backend.subscribeFn(o.backend.ptr, &o.sink, req, &o.caps);
    }

    pub fn capabilities(o: *const Observer) []const Capability {
        return o.caps.slice();
    }

    /// Kinds that have an active subscription. A kind outside this set needs polling.
    pub fn activeKinds(o: *const Observer) KindSet {
        var s: KindSet = .{};
        for (o.caps.slice()) |cap| if (cap.status == .active) s.add(cap.kind);
        // process_gone leaves a sticky exit event, so the exit condition is observable.
        for (o.caps.slice()) |cap| if (cap.status == .process_gone) s.add(.process_exit);
        return s;
    }

    pub fn mode(o: *const Observer) Mode {
        var active: usize = 0;
        var other: usize = 0;
        for (o.caps.slice()) |cap| switch (cap.status) {
            .active, .process_gone => active += 1,
            .not_requested => {},
            else => other += 1,
        };
        if (active == 0) return .polling;
        return if (other == 0) .notifications else .partial;
    }

    /// Takes the pending events without blocking.
    pub fn poll(o: *Observer) Wake {
        o.sink.drain();
        return o.sink.take();
    }

    /// Blocks until an event, an interrupt, teardown or the timeout.
    pub fn wait(o: *Observer, timeout_ms: u32) WaitResult {
        const s = &o.sink;
        const start = monotonicNs();
        while (true) {
            if (s.closed.load(.acquire)) return .closed;
            if (s.interrupted.swap(false, .acq_rel)) return .interrupted;
            const w = s.take();
            if (w.any()) {
                s.drain();
                return .{ .wake = w };
            }
            const elapsed_ms = (monotonicNs() -| start) / std.time.ns_per_ms;
            if (elapsed_ms >= timeout_ms) return .timeout;
            const remaining: u64 = timeout_ms - elapsed_ms;
            var pfd = [1]c.pollfd{.{ .fd = s.pipe_r, .events = c.POLL.IN, .revents = 0 }};
            const rc = c.poll(&pfd, 1, @intCast(@min(remaining, std.math.maxInt(c_int))));
            // EINTR or any other poll failure. The consumer reads current state.
            if (rc < 0) return .interrupted;
            // Events posted between take() and poll() leave a pipe byte, so the loop sees them.
            s.drain();
        }
    }

    /// Ends one current or the next `wait` with `.interrupted`. Safe from any thread.
    pub fn interrupt(o: *Observer) void {
        o.sink.interrupted.store(true, .release);
        o.sink.kick();
    }

    /// Releases the resources that `subscribe` created and wakes every waiter with `.closed`.
    /// Idempotent. Safe from any thread other than a backend thread.
    pub fn teardown(o: *Observer) void {
        if (o.torn_down) return;
        o.torn_down = true;
        o.sink.closed.store(true, .release);
        if (o.subscribed) o.backend.teardownFn(o.backend.ptr);
        o.sink.kick();
    }
};

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;

fn monotonicNs() u64 {
    if (comptime is_macos) return clock_gettime_nsec_np(6); // CLOCK_MONOTONIC
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// Fake backend

/// Posts events from test code. Calls no native API.
pub const FakeBackend = struct {
    /// Status reported for each capability the fake creates.
    ax_status: Status = .active,
    process_status: Status = .active,
    path_status: Status = .active,
    /// Events posted inside `subscribeFn`, before it returns.
    during_subscribe: []const Kind = &.{},
    sink: ?*Sink = null,
    subscribe_calls: u32 = 0,
    teardown_calls: u32 = 0,
    last_pid: i32 = 0,

    pub fn backend(f: *FakeBackend) Backend {
        return .{ .ptr = f, .subscribeFn = subscribeImpl, .teardownFn = teardownImpl };
    }

    pub fn post(f: *FakeBackend, k: Kind) void {
        f.sink.?.post(k);
    }

    fn subscribeImpl(ptr: *anyopaque, sink: *Sink, req: Request, out: *Caps) void {
        const f: *FakeBackend = @ptrCast(@alignCast(ptr));
        f.sink = sink;
        f.subscribe_calls += 1;
        f.last_pid = req.pid;
        if (req.ax) {
            for (ax_names) |n| out.add(.{ .source = .ax, .kind = n.kind, .label = n.name, .status = f.ax_status });
        }
        if (req.process) {
            out.add(.{ .source = .process, .kind = .process_exit, .label = "EVFILT_PROC", .status = f.process_status });
            if (f.process_status == .process_gone) sink.post(.process_exit);
        }
        for (req.watches, 0..) |w, i| {
            out.add(.{ .source = .path, .kind = w.kind, .label = "path", .index = @intCast(i), .status = f.path_status });
        }
        for (f.during_subscribe) |k| sink.post(k);
    }

    fn teardownImpl(ptr: *anyopaque) void {
        const f: *FakeBackend = @ptrCast(@alignCast(ptr));
        f.teardown_calls += 1;
    }
};

// System backend

const AxName = struct { name: [:0]const u8, kind: Kind };

/// Notifications registered on the application element of the pid.
pub const ax_names = [_]AxName{
    .{ .name = "AXWindowCreated", .kind = .window_created },
    .{ .name = "AXUIElementDestroyed", .kind = .window_destroyed },
    .{ .name = "AXFocusedWindowChanged", .kind = .focus_changed },
    .{ .name = "AXFocusedUIElementChanged", .kind = .focus_changed },
    .{ .name = "AXLayoutChanged", .kind = .layout_changed },
    .{ .name = "AXCreated", .kind = .layout_changed },
    .{ .name = "AXWindowResized", .kind = .layout_changed },
    .{ .name = "AXValueChanged", .kind = .value_changed },
    .{ .name = "AXSelectedChildrenChanged", .kind = .value_changed },
    .{ .name = "AXTitleChanged", .kind = .title_changed },
    .{ .name = "AXMenuOpened", .kind = .menu_opened },
    .{ .name = "AXSheetCreated", .kind = .sheet_created },
    .{ .name = "AXApplicationActivated", .kind = .app_activated },
};

const ax_error_api_disabled: i32 = -25211;
const ax_error_notification_unsupported: i32 = -25207;
const ax_error_notification_already_registered: i32 = -25209;

/// ApplicationServices and CoreFoundation entry points. Link flags are
/// `-framework ApplicationServices -framework CoreFoundation`.
const mac = struct {
    const Ref = ?*anyopaque;
    const AxCallback = *const fn (observer: Ref, element: Ref, notification: Ref, refcon: ?*anyopaque) callconv(.c) void;

    extern "c" fn AXIsProcessTrusted() u8;
    extern "c" fn AXUIElementCreateApplication(pid: c.pid_t) Ref;
    extern "c" fn AXObserverCreate(pid: c.pid_t, cb: AxCallback, out: *Ref) i32;
    extern "c" fn AXObserverAddNotification(observer: Ref, element: Ref, notification: Ref, refcon: ?*anyopaque) i32;
    extern "c" fn AXObserverRemoveNotification(observer: Ref, element: Ref, notification: Ref) i32;
    extern "c" fn AXObserverGetRunLoopSource(observer: Ref) Ref;
    extern "c" fn CFStringCreateWithCString(alloc: Ref, s: [*:0]const u8, encoding: u32) Ref;
    extern "c" fn CFEqual(a: Ref, b: Ref) u8;
    extern "c" fn CFRelease(r: Ref) void;
    extern "c" fn CFRunLoopGetCurrent() Ref;
    extern "c" fn CFRunLoopAddSource(rl: Ref, src: Ref, mode: Ref) void;
    extern "c" fn CFRunLoopRemoveSource(rl: Ref, src: Ref, mode: Ref) void;
    extern "c" fn CFRunLoopRunInMode(mode: Ref, seconds: f64, return_after_source: u8) i32;
    extern "c" fn CFRunLoopStop(rl: Ref) void;
    extern const kCFRunLoopDefaultMode: Ref;

    const utf8: u32 = 0x08000100;
};

/// Longest run loop slice. `teardown` stops the loop early. The slice bounds teardown when the
/// stop signal arrives before the loop starts.
const run_loop_slice_s: f64 = 0.25;

const AxWatcher = struct {
    sink: *Sink,
    observer: mac.Ref = null,
    element: mac.Ref = null,
    source: mac.Ref = null,
    strings: [ax_names.len]mac.Ref = [_]mac.Ref{null} ** ax_names.len,
    registered: [ax_names.len]bool = [_]bool{false} ** ax_names.len,
    thread: ?std.Thread = null,
    run_loop: std.atomic.Value(?*anyopaque) = std.atomic.Value(?*anyopaque).init(null),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn callback(_: mac.Ref, _: mac.Ref, notification: mac.Ref, refcon: ?*anyopaque) callconv(.c) void {
        const w: *AxWatcher = @ptrCast(@alignCast(refcon.?));
        for (w.strings, ax_names) |s, n| {
            if (s != null and mac.CFEqual(s, notification) != 0) {
                w.sink.post(n.kind);
                return;
            }
        }
    }

    fn loop(w: *AxWatcher) void {
        const rl = mac.CFRunLoopGetCurrent();
        mac.CFRunLoopAddSource(rl, w.source, mac.kCFRunLoopDefaultMode);
        w.run_loop.store(rl, .release);
        while (!w.stop.load(.acquire)) {
            _ = mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, run_loop_slice_s, 0);
        }
        mac.CFRunLoopRemoveSource(rl, w.source, mac.kCFRunLoopDefaultMode);
    }

    fn statusOf(code: i32) Status {
        return switch (code) {
            0, ax_error_notification_already_registered => .active,
            ax_error_api_disabled => .not_trusted,
            ax_error_notification_unsupported => .unsupported_notification,
            else => .failed,
        };
    }

    /// Registers every notification. Returns null when no notification was registered.
    fn start(a: Allocator, sink: *Sink, pid: i32, out: *Caps) ?*AxWatcher {
        const first = out.len;
        if (mac.AXIsProcessTrusted() == 0) {
            for (ax_names) |n| out.add(.{ .source = .ax, .kind = n.kind, .label = n.name, .status = .not_trusted, .code = ax_error_api_disabled });
            return null;
        }
        const w = a.create(AxWatcher) catch {
            for (ax_names) |n| out.add(.{ .source = .ax, .kind = n.kind, .label = n.name, .status = .failed });
            return null;
        };
        w.* = .{ .sink = sink };
        var obs: mac.Ref = null;
        const create_code = mac.AXObserverCreate(pid, callback, &obs);
        if (create_code != 0 or obs == null) {
            for (ax_names) |n| out.add(.{ .source = .ax, .kind = n.kind, .label = n.name, .status = statusOf(create_code), .code = create_code });
            a.destroy(w);
            return null;
        }
        w.observer = obs;
        w.element = mac.AXUIElementCreateApplication(pid);
        var active: usize = 0;
        for (ax_names, 0..) |n, i| {
            w.strings[i] = mac.CFStringCreateWithCString(null, n.name.ptr, mac.utf8);
            const code = mac.AXObserverAddNotification(w.observer, w.element, w.strings[i], w);
            const st = statusOf(code);
            if (st == .active) {
                w.registered[i] = true;
                active += 1;
            }
            out.add(.{ .source = .ax, .kind = n.kind, .label = n.name, .status = st, .code = code });
        }
        if (active == 0) {
            w.release();
            a.destroy(w);
            return null;
        }
        w.source = mac.AXObserverGetRunLoopSource(w.observer);
        w.thread = std.Thread.spawn(.{}, loop, .{w}) catch {
            // Without a loop no notification is delivered.
            for (out.items[first..out.len]) |*cap| if (cap.status == .active) {
                cap.status = .failed;
            };
            w.release();
            a.destroy(w);
            return null;
        };
        return w;
    }

    fn release(w: *AxWatcher) void {
        for (ax_names, 0..) |_, i| {
            if (w.registered[i]) _ = mac.AXObserverRemoveNotification(w.observer, w.element, w.strings[i]);
            if (w.strings[i] != null) mac.CFRelease(w.strings[i]);
            w.strings[i] = null;
        }
        if (w.element != null) mac.CFRelease(w.element);
        if (w.observer != null) mac.CFRelease(w.observer);
        w.element = null;
        w.observer = null;
    }

    fn stopAndRelease(w: *AxWatcher, a: Allocator) void {
        w.stop.store(true, .release);
        if (w.run_loop.load(.acquire)) |rl| mac.CFRunLoopStop(rl);
        if (w.thread) |t| t.join();
        w.release();
        a.destroy(w);
    }
};

const Kq = struct {
    kq: c.fd_t = -1,
    watch_fds: [max_watches]c.fd_t = [_]c.fd_t{-1} ** max_watches,
    watch_kinds: [max_watches]Kind = [_]Kind{.file_changed} ** max_watches,
    sink: *Sink,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const user_ident: usize = 1;
    const proc_udata: usize = max_watches;
    /// O_EVTONLY. Opens a path for event notification only.
    const o_evtonly: u32 = 0x8000;

    fn change(ident: usize, filter: i16, flags: u16, fflags: u32, udata: usize) c.Kevent {
        return .{ .ident = ident, .filter = filter, .flags = flags, .fflags = fflags, .data = 0, .udata = udata };
    }

    /// Returns 0 on success, otherwise the errno. The call passes no event list. An event list
    /// would let this call take pending events from the loop thread, and with no list the kernel
    /// reports a failed change through errno.
    fn register(k: *Kq, ch: c.Kevent) i32 {
        const changes = [1]c.Kevent{ch};
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        var none: [1]c.Kevent = undefined;
        const rc = c.kevent(k.kq, &changes, 1, &none, 0, &zero);
        if (rc < 0) return c._errno().*;
        return 0;
    }

    fn start(a: Allocator, sink: *Sink, req: Request, out: *Caps) ?*Kq {
        const want_proc = req.process;
        if (!want_proc and req.watches.len == 0) return null;
        const k = a.create(Kq) catch {
            reportAll(req, out, .failed, 0);
            return null;
        };
        k.* = .{ .sink = sink };
        k.kq = c.kqueue();
        if (k.kq < 0) {
            reportAll(req, out, .failed, c._errno().*);
            a.destroy(k);
            return null;
        }
        _ = c.fcntl(k.kq, 2, @as(c_int, 1));
        var live: usize = 0;
        const user_add = change(user_ident, c.EVFILT.USER, c.EV.ADD | c.EV.CLEAR, 0, 0);
        if (k.register(user_add) != 0) {
            reportAll(req, out, .failed, 0);
            k.close();
            a.destroy(k);
            return null;
        }
        if (want_proc) {
            const ch = change(@intCast(req.pid), c.EVFILT.PROC, c.EV.ADD | c.EV.CLEAR, c.NOTE.EXIT, proc_udata);
            const e = k.register(ch);
            const cap_base: Capability = .{ .source = .process, .kind = .process_exit, .label = "EVFILT_PROC", .status = .active };
            if (e == 0) {
                live += 1;
                out.add(cap_base);
            } else {
                var cap = cap_base;
                cap.code = e;
                switch (@as(c.E, @enumFromInt(e))) {
                    .SRCH => {
                        cap.status = .process_gone;
                        sink.post(.process_exit);
                    },
                    .PERM, .ACCES => cap.status = .denied,
                    else => cap.status = .failed,
                }
                out.add(cap);
            }
        }
        for (req.watches, 0..) |w, i| {
            var cap: Capability = .{ .source = .path, .kind = w.kind, .label = "path", .index = @intCast(i), .status = .active };
            k.watch_kinds[i] = w.kind;
            var buf: [513]u8 = undefined;
            if (w.path.len >= buf.len) {
                cap.status = .failed;
                cap.code = @intFromEnum(c.E.NAMETOOLONG);
                out.add(cap);
                continue;
            }
            @memcpy(buf[0..w.path.len], w.path);
            buf[w.path.len] = 0;
            const flags: c.O = @bitCast(o_evtonly);
            const fd = c.open(@ptrCast(&buf), flags);
            if (fd < 0) {
                cap.code = c._errno().*;
                cap.status = switch (@as(c.E, @enumFromInt(cap.code))) {
                    .NOENT, .NOTDIR => .path_missing,
                    .ACCES, .PERM => .denied,
                    else => .failed,
                };
                out.add(cap);
                continue;
            }
            k.watch_fds[i] = fd;
            const fflags: u32 = c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.ATTRIB | c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.LINK;
            const e = k.register(change(@intCast(fd), c.EVFILT.VNODE, c.EV.ADD | c.EV.CLEAR, fflags, i));
            if (e != 0) {
                cap.status = .failed;
                cap.code = e;
            } else live += 1;
            out.add(cap);
        }
        if (live == 0) {
            k.close();
            a.destroy(k);
            return null;
        }
        k.thread = std.Thread.spawn(.{}, loop, .{k}) catch {
            for (out.items[0..out.len]) |*cap| {
                if (cap.source != .ax and cap.status == .active) cap.status = .failed;
            }
            k.close();
            a.destroy(k);
            return null;
        };
        return k;
    }

    fn reportAll(req: Request, out: *Caps, st: Status, code: i32) void {
        if (req.process) out.add(.{ .source = .process, .kind = .process_exit, .label = "EVFILT_PROC", .status = st, .code = code });
        for (req.watches, 0..) |w, i| out.add(.{ .source = .path, .kind = w.kind, .label = "path", .index = @intCast(i), .status = st, .code = code });
    }

    fn loop(k: *Kq) void {
        var evs: [8]c.Kevent = undefined;
        while (!k.stop.load(.acquire)) {
            const n = c.kevent(k.kq, &evs, 0, &evs, evs.len, null);
            if (n < 0) {
                if (@as(c.E, @enumFromInt(c._errno().*)) == .INTR) continue;
                k.sink.post(.lost);
                return;
            }
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const ev = evs[i];
                if (ev.filter == c.EVFILT.USER) continue;
                if (ev.filter == c.EVFILT.PROC) {
                    k.sink.post(.process_exit);
                } else if (ev.filter == c.EVFILT.VNODE and ev.udata < max_watches) {
                    k.sink.post(k.watch_kinds[ev.udata]);
                    // A deleted or renamed target leaves the descriptor on the old inode.
                    if (ev.fflags & (c.NOTE.DELETE | c.NOTE.RENAME) != 0) k.sink.post(.lost);
                }
            }
        }
    }

    fn close(k: *Kq) void {
        for (k.watch_fds) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
        if (k.kq >= 0) _ = c.close(k.kq);
    }

    fn stopAndClose(k: *Kq, a: Allocator) void {
        k.stop.store(true, .release);
        _ = k.register(change(user_ident, c.EVFILT.USER, 0, c.NOTE.TRIGGER, 0));
        if (k.thread) |t| t.join();
        k.close();
        a.destroy(k);
    }
};

/// AXObserver for UI notifications and kqueue for process exit and path changes.
/// Every call needs the Accessibility permission, a live pid or existing paths. Unit tests use
/// `FakeBackend`. Only the kqueue part runs in unit tests, on a child and scratch files.
pub const SystemBackend = struct {
    a: Allocator,
    ax: ?*AxWatcher = null,
    kq: ?*Kq = null,

    pub fn backend(s: *SystemBackend) Backend {
        return .{ .ptr = s, .subscribeFn = subscribeImpl, .teardownFn = teardownImpl };
    }

    fn unsupported(req: Request, out: *Caps) void {
        if (req.ax) for (ax_names) |n| out.add(.{ .source = .ax, .kind = n.kind, .label = n.name, .status = .unsupported_platform });
        Kq.reportAll(req, out, .unsupported_platform, 0);
    }

    fn subscribeImpl(ptr: *anyopaque, sink: *Sink, req: Request, out: *Caps) void {
        const s: *SystemBackend = @ptrCast(@alignCast(ptr));
        if (comptime !is_macos) return unsupported(req, out);
        // The kqueue part registers first. A process that exits during AX setup is still reported.
        s.kq = Kq.start(s.a, sink, req, out);
        if (req.ax) s.ax = AxWatcher.start(s.a, sink, req.pid, out);
    }

    fn teardownImpl(ptr: *anyopaque) void {
        const s: *SystemBackend = @ptrCast(@alignCast(ptr));
        if (comptime !is_macos) return;
        if (s.ax) |w| w.stopAndRelease(s.a);
        if (s.kq) |k| k.stopAndClose(s.a);
        s.ax = null;
        s.kq = null;
    }
};

// Tests

const testing = std.testing;

fn newObserver(f: *FakeBackend) !*Observer {
    return Observer.create(testing.allocator, f.backend());
}

test "events before the first wait are preserved" {
    var f: FakeBackend = .{ .during_subscribe = &.{ .window_created, .sheet_created } };
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 42 });
    f.post(.layout_changed);
    const r = o.wait(0);
    try testing.expect(r == .wake);
    try testing.expect(r.wake.has(.window_created));
    try testing.expect(r.wake.has(.sheet_created));
    try testing.expect(r.wake.has(.layout_changed));
    try testing.expectEqual(@as(i32, 42), f.last_pid);
    try testing.expect(o.wait(0) == .timeout);
}

test "coalesced notifications count and saturate" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    f.post(.value_changed);
    f.post(.value_changed);
    f.post(.value_changed);
    var w = o.wait(0).wake;
    try testing.expectEqual(@as(u16, 3), w.count(.value_changed));
    try testing.expect(w.coalesced(.value_changed));
    try testing.expect(!w.needsRescan());
    var i: u32 = 0;
    while (i < @as(u32, max_count) + 10) : (i += 1) f.post(.title_changed);
    w = o.wait(0).wake;
    try testing.expect(w.saturated(.title_changed));
    try testing.expect(w.needsRescan());
    // Counters restart after a take.
    f.post(.title_changed);
    try testing.expectEqual(@as(u16, 1), o.wait(0).wake.count(.title_changed));
}

test "a lost event requests a rescan" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    f.post(.lost);
    try testing.expect(o.wait(0).wake.needsRescan());
}

test "process exit is sticky" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    f.post(.process_exit);
    try testing.expect(o.wait(0).wake.processExited());
    try testing.expect(o.wait(0).wake.processExited());
    try testing.expect(o.poll().processExited());
}

test "a pid gone before subscription reports an exit event" {
    var f: FakeBackend = .{ .process_status = .process_gone };
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1, .ax = false });
    try testing.expect(o.wait(0).wake.processExited());
    try testing.expect(o.activeKinds().has(.process_exit));
}

test "unsupported subscriptions report polling" {
    var f: FakeBackend = .{ .ax_status = .not_trusted, .process_status = .denied, .path_status = .path_missing };
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1, .watches = &.{.{ .path = "/nonexistent", .kind = .bridge_changed }} });
    try testing.expectEqual(Mode.polling, o.mode());
    try testing.expectEqual(@as(u32, 0), o.activeKinds().bits);
    try testing.expectEqual(ax_names.len + 2, o.capabilities().len);
    for (o.capabilities()) |cap| try testing.expect(cap.status != .active);
    try testing.expect(o.wait(0) == .timeout);
}

test "mixed subscriptions report a partial mode and their active kinds" {
    var f: FakeBackend = .{ .ax_status = .unsupported_notification };
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    try testing.expectEqual(Mode.partial, o.mode());
    try testing.expect(o.activeKinds().has(.process_exit));
    try testing.expect(!o.activeKinds().has(.window_created));
}

test "not requested sources leave the mode at notifications" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1, .ax = false, .process = false });
    try testing.expectEqual(Mode.polling, o.mode());
}

test "a second subscribe and too many watches are rejected" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    const many = [_]Watch{.{ .path = "/tmp" }} ** (max_watches + 1);
    try testing.expectError(error.TooManyWatches, o.subscribe(.{ .pid = 1, .watches = &many }));
    try o.subscribe(.{ .pid = 1 });
    try testing.expectError(error.AlreadySubscribed, o.subscribe(.{ .pid = 1 }));
    try testing.expectEqual(@as(u32, 1), f.subscribe_calls);
}

test "wait times out without events" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    const t0 = monotonicNs();
    try testing.expect(o.wait(60) == .timeout);
    try testing.expect(monotonicNs() - t0 >= 50 * std.time.ns_per_ms);
}

const PostLater = struct {
    f: *FakeBackend,
    delay_ms: u32,

    fn run(p: *PostLater) void {
        var ts: c.timespec = .{ .sec = 0, .nsec = @as(isize, p.delay_ms) * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
        p.f.post(.sheet_created);
    }
};

test "a blocked wait wakes on a later post from another thread" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    var p: PostLater = .{ .f = &f, .delay_ms = 30 };
    const t = try std.Thread.spawn(.{}, PostLater.run, .{&p});
    const r = o.wait(5_000);
    t.join();
    try testing.expect(r == .wake);
    try testing.expect(r.wake.has(.sheet_created));
}

const InterruptLater = struct {
    o: *Observer,
    teardown: bool,

    fn run(p: *InterruptLater) void {
        var ts: c.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
        if (p.teardown) p.o.teardown() else p.o.interrupt();
    }
};

test "interrupt ends a wait and the next wait continues" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    var p: InterruptLater = .{ .o = o, .teardown = false };
    const t = try std.Thread.spawn(.{}, InterruptLater.run, .{&p});
    try testing.expect(o.wait(5_000) == .interrupted);
    t.join();
    try testing.expect(o.wait(0) == .timeout);
    f.post(.window_created);
    try testing.expect(o.wait(0) == .wake);
}

test "an interrupt before the wait is not lost" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    o.interrupt();
    try testing.expect(o.wait(5_000) == .interrupted);
}

test "teardown wakes a blocked wait and runs the backend teardown once" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    try o.subscribe(.{ .pid = 1 });
    var p: InterruptLater = .{ .o = o, .teardown = true };
    const t = try std.Thread.spawn(.{}, InterruptLater.run, .{&p});
    try testing.expect(o.wait(5_000) == .closed);
    t.join();
    o.teardown();
    o.destroy();
    try testing.expectEqual(@as(u32, 1), f.teardown_calls);
}

test "posts after teardown are dropped and teardown without subscribe calls no backend" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    o.teardown();
    try testing.expectEqual(@as(u32, 0), f.teardown_calls);
    o.sink.post(.window_created);
    try testing.expect(o.wait(0) == .closed);
    try testing.expectEqual(@as(u64, 0), o.sink.posted.load(.monotonic));
}

test "concurrent posters keep a bounded exact count" {
    var f: FakeBackend = .{};
    const o = try newObserver(&f);
    defer o.destroy();
    try o.subscribe(.{ .pid = 1 });
    const Poster = struct {
        fn run(s: *Sink) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) s.post(.value_changed);
        }
    };
    var ts: [4]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, Poster.run, .{&o.sink});
    for (ts) |t| t.join();
    try testing.expectEqual(@as(u16, 4000), o.wait(0).wake.count(.value_changed));
}

// System backend tests. These use kqueue on a forked child and on scratch files. No AX call runs.

extern "c" fn fork() c.pid_t;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;

fn sleepMs(ms: isize) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = ms * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, null);
}

test "system backend reports the exit of a child process" {
    if (comptime !is_macos) return error.SkipZigTest;
    const pid = fork();
    if (pid == 0) {
        sleepMs(300);
        c._exit(0);
    }
    try testing.expect(pid > 0);
    var sb: SystemBackend = .{ .a = testing.allocator };
    const o = try Observer.create(testing.allocator, sb.backend());
    defer o.destroy();
    try o.subscribe(.{ .pid = pid, .ax = false });
    try testing.expectEqual(Mode.notifications, o.mode());
    try testing.expectEqual(Status.active, o.capabilities()[0].status);
    // The child sleeps, so no exit arrives before this short wait ends.
    try testing.expect(o.wait(0) == .timeout);
    const r = o.wait(10_000);
    try testing.expect(r == .wake and r.wake.processExited());
    _ = c.waitpid(pid, null, 0);
    // A reaped pid is gone.
    var sb2: SystemBackend = .{ .a = testing.allocator };
    const o2 = try Observer.create(testing.allocator, sb2.backend());
    defer o2.destroy();
    try o2.subscribe(.{ .pid = pid, .ax = false });
    try testing.expectEqual(Status.process_gone, o2.capabilities()[0].status);
    try testing.expect(o2.wait(0).wake.processExited());
}

test "system backend reports scratch directory and file changes and cleans up" {
    if (comptime !is_macos) return error.SkipZigTest;
    var tmpl = "/tmp/nui-obs.XXXXXX".*;
    const base = mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const dir: []const u8 = std.mem.span(base);
    var cleaned = false;
    defer if (!cleaned) discardScratch(dir);

    var file_buf: [64]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&file_buf, "{s}/out.bin", .{dir});
    {
        const fd = c.open(file.ptr, @as(c.O, @bitCast(@as(u32, 0x0200 | 0x0001))), @as(c.mode_t, 0o644)); // O_CREAT | O_WRONLY
        try testing.expect(fd >= 0);
        _ = c.close(fd);
    }
    var sb: SystemBackend = .{ .a = testing.allocator };
    const o = try Observer.create(testing.allocator, sb.backend());
    defer o.destroy();
    var missing_buf: [64]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buf, "{s}/absent", .{dir});
    try o.subscribe(.{ .pid = 1, .ax = false, .process = false, .watches = &.{
        .{ .path = dir, .kind = .bridge_changed },
        .{ .path = file, .kind = .file_changed },
        .{ .path = missing, .kind = .file_changed },
    } });
    try testing.expectEqual(Mode.partial, o.mode());
    try testing.expectEqual(Status.active, o.capabilities()[0].status);
    try testing.expectEqual(Status.active, o.capabilities()[1].status);
    try testing.expectEqual(Status.path_missing, o.capabilities()[2].status);
    try testing.expect(o.wait(0) == .timeout);

    // A write to the file after subscription, with the first wait made later.
    {
        const fd = c.open(file.ptr, @as(c.O, @bitCast(@as(u32, 0x0001))));
        try testing.expect(fd >= 0);
        _ = c.write(fd, "x", 1);
        _ = c.close(fd);
    }
    var w = o.wait(5_000).wake;
    try testing.expect(w.has(.file_changed));
    // A new entry in the directory.
    var new_buf: [64]u8 = undefined;
    const newf = try std.fmt.bufPrintZ(&new_buf, "{s}/reply.json", .{dir});
    {
        const fd = c.open(newf.ptr, @as(c.O, @bitCast(@as(u32, 0x0200 | 0x0001))), @as(c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        _ = c.close(fd);
    }
    w = o.wait(5_000).wake;
    try testing.expect(w.has(.bridge_changed));
    o.teardown();
    try testing.expectEqual(@as(?*Kq, null), sb.kq);
    cleaned = true;
    discardScratch(dir);
}

fn discardScratch(dir: []const u8) void {
    var buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&buf, "root=$(git rev-parse --show-toplevel) && . \"$root/tools/discard.sh\" && discard '{s}'", .{dir}) catch return;
    _ = system(cmd.ptr);
}
