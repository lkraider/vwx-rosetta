//! Offline policy for Vectorworks desktop observations.
//!
//! The module classifies observations that a caller supplies. It starts no process, reads no file,
//! clicks nothing and links no platform API. `Observer` is the only boundary to a platform. A
//! later integration supplies an implementation. Tests supply fakes.
//!
//! The strings below come from the bounded Viewer experiment in
//! tools/research/m3d-execution/viewer-readiness-20261012-evidence/bounded-viewer-title-scope-20261012.A1Hto5/
//! (document-probe.zig and console-guard.zig). That evidence covers the Viewer only. No trial
//! release string is calibrated here.
//!
//! Title matching is not document identity. A window title carries a basename. The bridge check of
//! vs.GetFName and vs.GetFPathName in rosetta_capture.zig still has to verify the full path.
//!
//! Allocation and lifetime contract:
//! - No function in this module takes an allocator or allocates. Classification functions run over
//!   caller slices and return values that hold either static strings or sub-slices of the input.
//! - `Observation` and every slice inside it are borrowed from the `Observer`. They stay valid
//!   until the next `Observer.observe` call on the same observer or until the observer is
//!   destroyed. The caller copies any string it keeps longer.
//! - `Decision.title`, `Decision.progress` and `Decision.detail` are static strings or sub-slices
//!   of the `Observation` that produced them. They share its lifetime.
//! - `Policy` and `ExpectedDocument` borrow their strings from the caller for the duration of one
//!   call.

const std = @import("std");

/// Suffix that the Viewer appends to the title of a watermarked document.
pub const calibrated_watermark_suffix = " - WATERMARKED FILE";
/// Suffix that the Viewer adds to a converted document name before `.vwx`.
pub const calibrated_converted_marker = "_v2027";
pub const document_extension = ".vwx";
/// Title of the conversion notice and of the progress dialog.
pub const app_dialog_title = "Vectorworks";
/// Static text of the conversion notice up to the converted name. No space follows `Vectorworks.`.
pub const conversion_text_prefix = "This file was created with an older version of Vectorworks.It will be converted and opened with the new name:";
pub const watermark_text_1 = "This document is watermarked.";
pub const watermark_text_2 = "The data contained in this file may only be used in other watermarked documents.";
/// The only button name that a proposed acknowledgement may use.
pub const allowed_default_button = "OK";
pub const progress_file_prefix = "Opening File: ";
pub const default_progress_total: u8 = 11;

const max_name_len = 255;
const max_phase_len = 64;
const max_registry_len = 1 << 20;

// Console

/// Result of a console classification.
pub const ConsoleState = enum { ready, locked, wrong_console, unknown };

/// Raw console facts. A null field means the observer could not read it. A null field never
/// classifies as ready.
pub const ConsoleObservation = struct {
    /// Output of `stat -f %Su /dev/console`, trimmed.
    owner: ?[]const u8 = null,
    /// Output of `id -un`, trimmed.
    user: ?[]const u8 = null,
    /// Output of `ioreg -n Root -d1`. At most 1 MiB.
    registry: ?[]const u8 = null,
};

pub const ConsoleOptions = struct {
    /// The accepted shell guard treats an absent `CGSSessionScreenIsLocked` key as unlocked. The
    /// default refuses that case. Set true only after an observation shows that the release omits
    /// the key while unlocked.
    missing_lock_key_is_unlocked: bool = false,
};

fn isSpace(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

/// True when the concatenation of `parts` occurs in `hay` with whitespace in `hay` ignored.
/// Parts hold no whitespace. Runs without allocation, as ioreg pads its output.
fn compactContains(hay: []const u8, parts: []const []const u8) bool {
    var start: usize = 0;
    while (start < hay.len) : (start += 1) {
        if (isSpace(hay[start])) continue;
        var h = start;
        var ok = true;
        outer: for (parts) |p| {
            for (p) |c| {
                while (h < hay.len and isSpace(hay[h])) h += 1;
                if (h >= hay.len or hay[h] != c) {
                    ok = false;
                    break :outer;
                }
                h += 1;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn hasSpace(s: []const u8) bool {
    for (s) |c| if (isSpace(c)) return true;
    return false;
}

/// Classifies console facts. Returns `.unknown` for missing, empty or malformed data.
pub fn classifyConsole(obs: ConsoleObservation, opts: ConsoleOptions) ConsoleState {
    const owner = obs.owner orelse return .unknown;
    const user = obs.user orelse return .unknown;
    if (owner.len == 0 or user.len == 0 or hasSpace(owner) or hasSpace(user)) return .unknown;
    if (!std.mem.eql(u8, owner, user)) return .wrong_console;
    const reg = obs.registry orelse return .unknown;
    if (reg.len == 0 or reg.len > max_registry_len) return .unknown;
    if (compactContains(reg, &.{"\"CGSSessionScreenIsLocked\"=Yes"})) return .locked;
    if (!compactContains(reg, &.{"\"IOConsoleUsers\""}) or
        !compactContains(reg, &.{"\"kCGSSessionOnConsoleKey\"=Yes"}) or
        !compactContains(reg, &.{"\"kCGSessionLoginDoneKey\"=Yes"}) or
        !compactContains(reg, &.{ "\"kCGSSessionUserNameKey\"=\"", user, "\"" })) return .unknown;
    if (compactContains(reg, &.{"\"CGSSessionScreenIsLocked\"=No"})) return .ready;
    if (compactContains(reg, &.{"\"CGSSessionScreenIsLocked\""})) return .unknown;
    return if (opts.missing_lock_key_is_unlocked) .ready else .unknown;
}

// Titles

/// Names that a window title may carry. Strings are borrowed from the caller.
pub const ExpectedDocument = struct {
    /// Basename of the opened file, including `.vwx`.
    original: []const u8,
    /// Basename that the Viewer gives a converted file. Null when no conversion is expected.
    converted: ?[]const u8 = null,
    /// True accepts `calibrated_watermark_suffix` after a name. False accepts the bare name only.
    watermarked: bool = false,

    pub const Invalid = error{InvalidExpectedName};

    pub fn validate(e: ExpectedDocument) Invalid!void {
        try validName(e.original);
        if (e.converted) |c| {
            try validName(c);
            if (std.mem.eql(u8, c, e.original)) return error.InvalidExpectedName;
        }
    }
};

fn validName(n: []const u8) ExpectedDocument.Invalid!void {
    if (n.len <= document_extension.len or n.len > max_name_len) return error.InvalidExpectedName;
    if (!std.mem.endsWith(u8, n, document_extension)) return error.InvalidExpectedName;
    if (n[0] == ' ' or n[n.len - 1] == ' ') return error.InvalidExpectedName;
    for (n) |c| if (c < 0x20 or c == 0x7f or c == '/') return error.InvalidExpectedName;
}

/// Writes the converted basename of `original` to `buf`. Null when `original` is not a valid
/// `.vwx` basename or `buf` is too small. The result is a slice of `buf`.
pub fn convertedName(buf: []u8, original: []const u8) ?[]const u8 {
    validName(original) catch return null;
    const stem = original[0 .. original.len - document_extension.len];
    const total = stem.len + calibrated_converted_marker.len + document_extension.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..stem.len], stem);
    @memcpy(buf[stem.len..][0..calibrated_converted_marker.len], calibrated_converted_marker);
    @memcpy(buf[stem.len + calibrated_converted_marker.len ..][0..document_extension.len], document_extension);
    return buf[0..total];
}

pub const TitleKind = enum { none, original, converted };

pub const TitleMatch = struct {
    kind: TitleKind,
    /// True when the title carried the calibrated suffix.
    watermarked: bool = false,
};

/// Matches a whole window title against the expected names. A substring, another document, a
/// modified marker, a changed suffix and a bare suffix give `.none`.
pub fn matchTitle(expected: ExpectedDocument, title: []const u8) ExpectedDocument.Invalid!TitleMatch {
    try expected.validate();
    var name = title;
    var wm = false;
    if (expected.watermarked and std.mem.endsWith(u8, title, calibrated_watermark_suffix)) {
        name = title[0 .. title.len - calibrated_watermark_suffix.len];
        wm = true;
    }
    if (name.len == 0) return .{ .kind = .none };
    if (std.mem.eql(u8, name, expected.original)) return .{ .kind = .original, .watermarked = wm };
    if (expected.converted) |c| {
        if (std.mem.eql(u8, name, c)) return .{ .kind = .converted, .watermarked = wm };
    }
    return .{ .kind = .none };
}

// Progress

pub const ProgressError = error{
    TextShape,
    NotOpeningFile,
    WrongDocument,
    MalformedStep,
    MalformedNumber,
    OutOfRange,
    UnknownField,
    PhaseShape,
};

/// One progress observation. `document` and `phase` are sub-slices of the parsed text.
pub const Progress = struct {
    document: []const u8,
    step: u8,
    total: u8,
    phase: []const u8,
};

const StepLine = struct { step: u8, total: u8, phase: []const u8 };

fn parseCount(s: []const u8) ProgressError!u8 {
    if (s.len == 0 or s.len > 3 or s[0] == '0') return error.MalformedNumber;
    for (s) |c| if (c < '0' or c > '9') return error.MalformedNumber;
    return std.fmt.parseInt(u8, s, 10) catch error.OutOfRange;
}

/// Parses `Step N of M: <phase>...`. `total` is the declared M. N is in 1..M.
pub fn parseStepLine(line: []const u8, total: u8) ProgressError!StepLine {
    const head = "Step ";
    if (!std.mem.startsWith(u8, line, head)) return error.MalformedStep;
    const rest = line[head.len..];
    const of = std.mem.indexOf(u8, rest, " of ") orelse return error.MalformedStep;
    const n = try parseCount(rest[0..of]);
    const after = rest[of + 4 ..];
    const colon = std.mem.indexOf(u8, after, ": ") orelse return error.MalformedStep;
    const m = try parseCount(after[0..colon]);
    if (m != total or n < 1 or n > m) return error.OutOfRange;
    var phase = after[colon + 2 ..];
    if (!std.mem.endsWith(u8, phase, "...")) return error.PhaseShape;
    phase = phase[0 .. phase.len - 3];
    if (phase.len == 0 or phase.len > max_phase_len or phase[0] == ' ' or phase[phase.len - 1] == ' ') return error.PhaseShape;
    for (phase) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != ' ' and c != '-' and c != ',') return error.PhaseShape;
    }
    return .{ .step = n, .total = m, .phase = phase };
}

/// Parses the four static texts of the progress dialog for the expected document. The texts are
/// `Opening File: <name>`, the step line, an empty text and `Vectorworks`. Any other text count or
/// content is an unknown field. The name must be the expected original or converted basename.
pub fn parseProgress(texts: []const []const u8, expected: ExpectedDocument, total: u8) ProgressError!Progress {
    if (texts.len != 4) return error.TextShape;
    if (texts[2].len != 0 or !std.mem.eql(u8, texts[3], app_dialog_title)) return error.UnknownField;
    if (!std.mem.startsWith(u8, texts[0], progress_file_prefix)) return error.NotOpeningFile;
    const name = texts[0][progress_file_prefix.len..];
    const tm = matchTitle(expected, name) catch return error.WrongDocument;
    if (tm.kind == .none or tm.watermarked) return error.WrongDocument;
    const s = try parseStepLine(texts[1], total);
    return .{ .document = name, .step = s.step, .total = s.total, .phase = s.phase };
}

// Dialogs

pub const ModalClass = enum { none, known_conversion, known_watermark, progress, license, save, overwrite, unknown };

/// One window with the facts that the observer read. Null means unread.
pub const WindowObservation = struct {
    title: ?[]const u8 = null,
    /// AXModal. Null when the attribute was unreadable.
    modal: ?bool = null,
    /// Complete list of AXStaticText values. Null when the tree was not fully read.
    texts: ?[]const []const u8 = null,
    /// Name of AXDefaultButton. Null when absent or unreadable.
    default_button: ?[]const u8 = null,
};

fn textsEql(texts: []const []const u8, want: []const []const u8) bool {
    if (texts.len != want.len) return false;
    for (texts, want) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

fn anyContainsIgnoreCase(texts: []const []const u8, needles: []const []const u8) bool {
    for (texts) |t| for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(t, n) != null) return true;
    };
    return false;
}

/// Classification of one modal window.
pub const DialogClass = struct {
    class: ModalClass,
    progress: ?Progress = null,
    /// Static explanation for a non-known result.
    detail: []const u8 = "",
};

fn watermarkExact(w: WindowObservation, texts: []const []const u8) bool {
    return w.title != null and w.title.?.len == 0 and textsEql(texts, &.{ watermark_text_1, watermark_text_2 });
}

fn conversionExact(w: WindowObservation, texts: []const []const u8, expected: ExpectedDocument) bool {
    const want = expected.converted orelse return false;
    const title = w.title orelse return false;
    if (!std.mem.eql(u8, title, app_dialog_title) or texts.len != 2) return false;
    if (!std.mem.startsWith(u8, texts[0], conversion_text_prefix)) return false;
    return std.mem.eql(u8, texts[0][conversion_text_prefix.len..], want) and std.mem.eql(u8, texts[1], app_dialog_title);
}

/// Classifies a modal window. Exact calibrated text gives a known class. Keyword matches give
/// license, save or overwrite for reporting. Everything else is `.unknown`. No class other than
/// the two known notices permits an action, and the button is checked separately.
pub fn classifyDialog(w: WindowObservation, expected: ExpectedDocument, progress_total: u8) DialogClass {
    const texts = w.texts orelse return .{ .class = .unknown, .detail = "dialog text unread" };
    if (watermarkExact(w, texts)) return .{ .class = .known_watermark };
    if (conversionExact(w, texts, expected)) return .{ .class = .known_conversion };
    if (w.title != null and std.mem.eql(u8, w.title.?, app_dialog_title) and texts.len > 0 and
        std.mem.startsWith(u8, texts[0], progress_file_prefix))
    {
        if (parseProgress(texts, expected, progress_total)) |p| {
            return .{ .class = .progress, .progress = p };
        } else |_| return .{ .class = .unknown, .detail = "progress dialog does not match the expected document and shape" };
    }
    // A changed body of a known notice is unknown, whatever keywords it holds.
    if (anyContainsIgnoreCase(texts, &.{ "watermarked", "will be converted" })) {
        return .{ .class = .unknown, .detail = "known notice with a changed body" };
    }
    if (anyContainsIgnoreCase(texts, &.{ "licen", "activat", "serial number", "trial" })) return .{ .class = .license, .detail = "license dialog" };
    if (anyContainsIgnoreCase(texts, &.{ "overwrite", "replace", "already exists" })) return .{ .class = .overwrite, .detail = "overwrite dialog" };
    if (anyContainsIgnoreCase(texts, &.{ "save", "changes" })) return .{ .class = .save, .detail = "save dialog" };
    return .{ .class = .unknown, .detail = "unrecognised dialog" };
}

// Observations and decisions

/// One combined observation of console, windows and dialogs.
pub const Observation = struct {
    console: ConsoleObservation = .{},
    windows: []const WindowObservation = &.{},
    /// False when the observer could not read every window or every dialog tree.
    windows_complete: bool = false,
};

pub const FailureKind = enum {
    /// The observation command or channel failed or timed out.
    transport,
    /// The target process does not exist.
    process_missing,
    /// The observer read output that it could not parse.
    malformed,
};

pub const ObserveFailure = struct {
    kind: FailureKind,
    /// Static string or a slice that the observer owns until its next call.
    detail: []const u8 = "",
};

pub const ObserveResult = union(enum) {
    observed: Observation,
    failed: ObserveFailure,
};

pub const Query = struct {
    pid: i32,
    expected: ExpectedDocument,
};

/// Injectable observation interface. It has no action method. The observer reads the console, the
/// windows of `pid` and the static texts of its modal windows in one call. The returned
/// `Observation` is borrowed until the next `observe` call.
pub const Observer = struct {
    ptr: *anyopaque,
    observeFn: *const fn (ptr: *anyopaque, query: Query) ObserveResult,

    pub fn observe(o: Observer, query: Query) ObserveResult {
        return o.observeFn(o.ptr, query);
    }
};

pub const Policy = struct {
    expected: ExpectedDocument,
    /// Caller permission to propose acknowledging the calibrated conversion notice.
    allow_conversion_ack: bool = false,
    /// Caller permission to propose acknowledging the calibrated watermark notice.
    allow_watermark_ack: bool = false,
    progress_total: u8 = default_progress_total,
    console: ConsoleOptions = .{},
    /// Exact titles of other document windows that stay open beside the expected one. Default none.
    /// Only the owned reference cleanup sets it. A tolerated window is never the expected document,
    /// never a dialog and never a target of an action.
    tolerated_documents: []const []const u8 = &.{},
};

pub const DecisionKind = enum {
    /// The expected document window is present and no dialog blocks it.
    ready,
    /// Nothing to do yet. The action is `.wait`.
    wait,
    /// A known notice qualifies for `.acknowledge`. The caller performs the click.
    proposed_action,
    transport_failure,
    process_missing,
    console_locked,
    console_wrong,
    console_unknown,
    /// A window of another document or a duplicate of the expected one.
    wrong_target,
    /// An unknown, licensing, save or overwrite dialog, an ambiguity or an incomplete observation.
    unknown_ui,
    /// A known notice is present and the caller did not permit its acknowledgement.
    not_permitted,
    invalid_expectation,
};

pub const Acknowledge = struct {
    /// Index into `Observation.windows`.
    window_index: usize,
    class: ModalClass,
    /// Static string. Equal to `allowed_default_button`.
    button: []const u8,
};

pub const ProposedAction = union(enum) {
    /// No action is proposed. The caller stops or proceeds by `kind`.
    none,
    wait,
    acknowledge: Acknowledge,
};

pub const Decision = struct {
    kind: DecisionKind,
    action: ProposedAction = .none,
    /// Class of the dialog that caused this decision, `.none` otherwise.
    modal: ModalClass = .none,
    detail: []const u8 = "",
    /// Matched document title when `kind` is `.ready`.
    title: ?[]const u8 = null,
    progress: ?Progress = null,

    /// True only for `.ready`. Every other kind means the document is not confirmed.
    pub fn isReady(d: Decision) bool {
        return d.kind == .ready;
    }
};

fn stop(kind: DecisionKind, modal: ModalClass, detail: []const u8) Decision {
    return .{ .kind = kind, .modal = modal, .detail = detail };
}

fn isTolerated(policy: Policy, title: []const u8) bool {
    for (policy.tolerated_documents) |t| if (std.mem.eql(u8, t, title)) return true;
    return false;
}

fn titleLooksLikeDocument(title: []const u8) bool {
    return std.mem.indexOf(u8, title, document_extension) != null;
}

/// Decides from one observation. Allocation free and bounded by the window and text counts.
/// Order: console, completeness, per-window checks, ambiguity, wrong target, acknowledgement,
/// progress wait, readiness.
pub fn decide(obs: Observation, policy: Policy) Decision {
    policy.expected.validate() catch return stop(.invalid_expectation, .none, "expected document name is invalid");
    switch (classifyConsole(obs.console, policy.console)) {
        .ready => {},
        .locked => return stop(.console_locked, .none, "console screen is locked"),
        .wrong_console => return stop(.console_wrong, .none, "console belongs to another user"),
        .unknown => return stop(.console_unknown, .none, "console state is unknown"),
    }
    if (!obs.windows_complete) return stop(.unknown_ui, .none, "window observation is incomplete");

    var doc_title: ?[]const u8 = null;
    var doc_count: usize = 0;
    var other_docs: usize = 0;
    var candidates: usize = 0;
    var cand: Acknowledge = undefined;
    var cand_button_ok = false;
    var progress: ?Progress = null;

    for (obs.windows, 0..) |w, i| {
        const modal = w.modal orelse return stop(.unknown_ui, .none, "window modal state unread");
        if (modal) {
            const dc = classifyDialog(w, policy.expected, policy.progress_total);
            switch (dc.class) {
                .progress => progress = dc.progress,
                .known_conversion, .known_watermark => {
                    candidates += 1;
                    cand = .{ .window_index = i, .class = dc.class, .button = allowed_default_button };
                    cand_button_ok = if (w.default_button) |b| std.mem.eql(u8, b, allowed_default_button) else false;
                },
                else => return stop(.unknown_ui, dc.class, dc.detail),
            }
            continue;
        }
        const title = w.title orelse continue;
        const tm = matchTitle(policy.expected, title) catch unreachable;
        if (tm.kind != .none) {
            doc_count += 1;
            doc_title = title;
        } else if (titleLooksLikeDocument(title) and !isTolerated(policy, title)) {
            other_docs += 1;
        }
    }

    if (candidates > 1) return stop(.unknown_ui, .none, "multiple acknowledgement candidates");
    if (doc_count > 1) return stop(.wrong_target, .none, "multiple windows match the expected document");
    if (other_docs > 0) return stop(.wrong_target, .none, "a window of another document is open");
    if (candidates == 1) {
        if (!cand_button_ok) return stop(.unknown_ui, cand.class, "default button is not OK");
        const permitted = switch (cand.class) {
            .known_conversion => policy.allow_conversion_ack,
            .known_watermark => policy.allow_watermark_ack,
            else => false,
        };
        if (!permitted) return stop(.not_permitted, cand.class, "acknowledgement not permitted by the caller");
        return .{ .kind = .proposed_action, .action = .{ .acknowledge = cand }, .modal = cand.class, .progress = progress };
    }
    if (progress != null) return .{ .kind = .wait, .action = .wait, .modal = .progress, .detail = "opening progress", .progress = progress };
    if (doc_count == 1) return .{ .kind = .ready, .title = doc_title };
    return .{ .kind = .wait, .action = .wait, .detail = "expected document window not visible" };
}

/// Runs one observation and decides. A failed observation never maps to `.ready`.
pub fn observeAndDecide(observer: Observer, pid: i32, policy: Policy) Decision {
    policy.expected.validate() catch return stop(.invalid_expectation, .none, "expected document name is invalid");
    if (pid <= 0) return stop(.process_missing, .none, "no process id");
    return switch (observer.observe(.{ .pid = pid, .expected = policy.expected })) {
        .observed => |o| decide(o, policy),
        .failed => |f| switch (f.kind) {
            .transport => stop(.transport_failure, .none, f.detail),
            .process_missing => stop(.process_missing, .none, f.detail),
            .malformed => stop(.unknown_ui, .none, f.detail),
        },
    };
}

// Tests

const testing = std.testing;

const orig = "clock-ClocKit_standard_shafts.vwx";
const conv = "clock-ClocKit_standard_shafts_v2027.vwx";
const valid_registry = "\"IOConsoleUsers\"=({\"kCGSSessionOnConsoleKey\"=Yes,\"kCGSessionLoginDoneKey\"=Yes,\"kCGSSessionUserNameKey\"=\"someone\"})";

fn expectedAll() ExpectedDocument {
    return .{ .original = orig, .converted = conv, .watermarked = true };
}

fn policyAll() Policy {
    return .{ .expected = expectedAll(), .allow_conversion_ack = true, .allow_watermark_ack = true };
}

const ready_console: ConsoleObservation = .{ .owner = "someone", .user = "someone", .registry = valid_registry ++ "\"CGSSessionScreenIsLocked\"=No" };

const watermark_texts = [_][]const u8{ watermark_text_1, watermark_text_2 };
const conversion_texts = [_][]const u8{ conversion_text_prefix ++ conv, "Vectorworks" };
const progress_texts = [_][]const u8{ "Opening File: " ++ orig, "Step 10 of 11: Generating Resource Previews...", "", "Vectorworks" };

fn doc(title: []const u8) WindowObservation {
    return .{ .title = title, .modal = false };
}

const watermark_win: WindowObservation = .{ .title = "", .modal = true, .texts = &watermark_texts, .default_button = "OK" };
const conversion_win: WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &conversion_texts, .default_button = "OK" };
const progress_win: WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &progress_texts };

fn obsOf(windows: []const WindowObservation) Observation {
    return .{ .console = ready_console, .windows = windows, .windows_complete = true };
}

test "console states from supplied data" {
    const o: ConsoleOptions = .{};
    try testing.expectEqual(ConsoleState.ready, classifyConsole(ready_console, o));
    try testing.expectEqual(ConsoleState.locked, classifyConsole(.{ .owner = "someone", .user = "someone", .registry = valid_registry ++ "\"CGSSessionScreenIsLocked\"=Yes" }, o));
    try testing.expectEqual(ConsoleState.wrong_console, classifyConsole(.{ .owner = "root", .user = "someone", .registry = valid_registry }, o));
    // Padded ioreg output.
    try testing.expectEqual(ConsoleState.ready, classifyConsole(.{ .owner = "someone", .user = "someone", .registry = "\"IOConsoleUsers\" = ( {\n \"kCGSSessionOnConsoleKey\" = Yes, \"kCGSessionLoginDoneKey\" = Yes, \"kCGSSessionUserNameKey\" = \"someone\" } )\n\"CGSSessionScreenIsLocked\" = No" }, o));
}

test "console refuses missing, empty and malformed data" {
    const o: ConsoleOptions = .{};
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{}, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "", .user = "someone", .registry = valid_registry }, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "someone", .user = null, .registry = valid_registry }, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "someone", .user = "someone", .registry = null }, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "someone", .user = "someone", .registry = "" }, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "someone", .user = "someone", .registry = valid_registry ++ "\"CGSSessionScreenIsLocked\"=invalid" }, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "someone", .user = "someone", .registry = "\"IOConsoleUsers\"=()" }, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "someone", .user = "someone", .registry = "\"IOConsoleUsers\"=({\"kCGSSessionOnConsoleKey\"=Yes,\"kCGSessionLoginDoneKey\"=Yes,\"kCGSSessionUserNameKey\"=\"other\"})\"CGSSessionScreenIsLocked\"=No" }, o));
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(.{ .owner = "some one", .user = "some one", .registry = valid_registry }, o));
}

test "missing lock key is unknown unless the caller opts in" {
    const c: ConsoleObservation = .{ .owner = "someone", .user = "someone", .registry = valid_registry };
    try testing.expectEqual(ConsoleState.unknown, classifyConsole(c, .{}));
    try testing.expectEqual(ConsoleState.ready, classifyConsole(c, .{ .missing_lock_key_is_unlocked = true }));
}

test "title matching accepts only whole expected names" {
    const e = expectedAll();
    try testing.expectEqual(TitleKind.original, (try matchTitle(e, orig)).kind);
    try testing.expectEqual(TitleKind.converted, (try matchTitle(e, conv)).kind);
    const w1 = try matchTitle(e, orig ++ calibrated_watermark_suffix);
    try testing.expect(w1.kind == .original and w1.watermarked);
    const w2 = try matchTitle(e, conv ++ " - WATERMARKED FILE");
    try testing.expect(w2.kind == .converted and w2.watermarked);
    const bad = [_][]const u8{
        "other.vwx - WATERMARKED FILE",
        "clock-ClocKit_standard_shafts_extra.vwx",
        "clock-ClocKit_standard_shafts_v2026.vwx",
        conv ++ " - WATERMARKED FILE extra",
        conv ++ "*",
        " - WATERMARKED FILE",
        conv ++ " - WATERMARKED",
        conv ++ " - watermarked file",
        conv ++ "  - WATERMARKED FILE",
        "prefix " ++ conv,
        "Vectorworks",
        "",
    };
    for (bad) |t| try testing.expectEqual(TitleKind.none, (try matchTitle(e, t)).kind);
}

test "watermark suffix and converted name follow the configuration" {
    const plain: ExpectedDocument = .{ .original = orig };
    try testing.expectEqual(TitleKind.none, (try matchTitle(plain, orig ++ calibrated_watermark_suffix)).kind);
    try testing.expectEqual(TitleKind.none, (try matchTitle(plain, conv)).kind);
    try testing.expectEqual(TitleKind.original, (try matchTitle(plain, orig)).kind);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(conv, convertedName(&buf, orig).?);
    try testing.expect(convertedName(buf[0..10], orig) == null);
    try testing.expect(convertedName(&buf, "no-extension") == null);
}

test "malformed expected names are refused" {
    const bad = [_][]const u8{ "", ".vwx", "a.txt", " a.vwx", "a.vwx ", "dir/a.vwx", "a\n.vwx" };
    for (bad) |n| try testing.expectError(error.InvalidExpectedName, matchTitle(.{ .original = n }, "a.vwx"));
    try testing.expectError(error.InvalidExpectedName, matchTitle(.{ .original = orig, .converted = orig }, orig));
}

test "progress parses the expected shape" {
    const p = try parseProgress(&progress_texts, expectedAll(), 11);
    try testing.expectEqual(@as(u8, 10), p.step);
    try testing.expectEqual(@as(u8, 11), p.total);
    try testing.expectEqualStrings("Generating Resource Previews", p.phase);
    try testing.expectEqualStrings(orig, p.document);
}

test "progress rejects malformed, unknown and out of range text" {
    const e = expectedAll();
    const mk = struct {
        fn t(line: []const u8) [4][]const u8 {
            return .{ "Opening File: " ++ orig, line, "", "Vectorworks" };
        }
    }.t;
    var a = mk("Step 12 of 11: Generating Resource Previews...");
    try testing.expectError(error.OutOfRange, parseProgress(&a, e, 11));
    a = mk("Step 0 of 11: Generating Resource Previews...");
    try testing.expectError(error.MalformedNumber, parseProgress(&a, e, 11));
    a = mk("Step 10 of 12: Generating Resource Previews...");
    try testing.expectError(error.OutOfRange, parseProgress(&a, e, 11));
    a = mk("Step -1 of 11: Generating Resource Previews...");
    try testing.expectError(error.MalformedNumber, parseProgress(&a, e, 11));
    a = mk("Step 1x of 11: Generating Resource Previews...");
    try testing.expectError(error.MalformedNumber, parseProgress(&a, e, 11));
    a = mk("Step 999 of 11: Generating Resource Previews...");
    try testing.expectError(error.OutOfRange, parseProgress(&a, e, 11));
    a = mk("Step 9999 of 11: Generating Resource Previews...");
    try testing.expectError(error.MalformedNumber, parseProgress(&a, e, 11));
    a = mk("Step 10 11: Generating Resource Previews...");
    try testing.expectError(error.MalformedStep, parseProgress(&a, e, 11));
    a = mk("Step 10 of 11 Generating Resource Previews...");
    try testing.expectError(error.MalformedStep, parseProgress(&a, e, 11));
    a = mk("Step 10 of 11: Generating Resource Previews");
    try testing.expectError(error.PhaseShape, parseProgress(&a, e, 11));
    a = mk("Step 10 of 11: ...");
    try testing.expectError(error.PhaseShape, parseProgress(&a, e, 11));
    a = mk("Step 10 of 11: <b>...");
    try testing.expectError(error.PhaseShape, parseProgress(&a, e, 11));
    const extra = [_][]const u8{ "Opening File: " ++ orig, "Step 10 of 11: Generating Resource Previews...", "", "Vectorworks", "extra" };
    try testing.expectError(error.TextShape, parseProgress(&extra, e, 11));
    const field = [_][]const u8{ "Opening File: " ++ orig, "Step 10 of 11: Generating Resource Previews...", "Cancel", "Vectorworks" };
    try testing.expectError(error.UnknownField, parseProgress(&field, e, 11));
}

test "progress for another document is rejected" {
    const other = [_][]const u8{ "Opening File: other.vwx", "Step 10 of 11: Generating Resource Previews...", "", "Vectorworks" };
    try testing.expectError(error.WrongDocument, parseProgress(&other, expectedAll(), 11));
    const sub = [_][]const u8{ "Opening File: x" ++ orig, "Step 10 of 11: Generating Resource Previews...", "", "Vectorworks" };
    try testing.expectError(error.WrongDocument, parseProgress(&sub, expectedAll(), 11));
    const not_open = [_][]const u8{ "Saving File: " ++ orig, "Step 10 of 11: Generating Resource Previews...", "", "Vectorworks" };
    try testing.expectError(error.NotOpeningFile, parseProgress(&not_open, expectedAll(), 11));
}

test "calibrated notices classify and propose only the default OK" {
    var d = decide(obsOf(&.{watermark_win}), policyAll());
    try testing.expectEqual(DecisionKind.proposed_action, d.kind);
    try testing.expectEqual(ModalClass.known_watermark, d.action.acknowledge.class);
    try testing.expectEqual(@as(usize, 0), d.action.acknowledge.window_index);
    try testing.expectEqualStrings("OK", d.action.acknowledge.button);
    d = decide(obsOf(&.{conversion_win}), policyAll());
    try testing.expectEqual(DecisionKind.proposed_action, d.kind);
    try testing.expectEqual(ModalClass.known_conversion, d.action.acknowledge.class);
    // Watermark beside passive progress. The recorded run acknowledged it.
    d = decide(obsOf(&.{ progress_win, watermark_win }), policyAll());
    try testing.expectEqual(DecisionKind.proposed_action, d.kind);
    try testing.expectEqual(@as(usize, 1), d.action.acknowledge.window_index);
}

test "acknowledgement needs caller permission" {
    var p = policyAll();
    p.allow_watermark_ack = false;
    var d = decide(obsOf(&.{watermark_win}), p);
    try testing.expectEqual(DecisionKind.not_permitted, d.kind);
    try testing.expectEqual(ProposedAction.none, d.action);
    p = policyAll();
    p.allow_conversion_ack = false;
    d = decide(obsOf(&.{conversion_win}), p);
    try testing.expectEqual(DecisionKind.not_permitted, d.kind);
    try testing.expectEqual(ProposedAction.none, d.action);
    // Withholding the conversion permission leaves the watermark permission intact.
    d = decide(obsOf(&.{watermark_win}), p);
    try testing.expectEqual(DecisionKind.proposed_action, d.kind);
    // The default policy permits nothing.
    d = decide(obsOf(&.{watermark_win}), .{ .expected = expectedAll() });
    try testing.expectEqual(DecisionKind.not_permitted, d.kind);
}

test "changed button stops the notice" {
    var w = watermark_win;
    for ([_]?[]const u8{ null, "Cancel", "ok", "OK ", "" }) |b| {
        w.default_button = b;
        const d = decide(obsOf(&.{w}), policyAll());
        try testing.expectEqual(DecisionKind.unknown_ui, d.kind);
        try testing.expectEqual(ProposedAction.none, d.action);
    }
    var c = conversion_win;
    c.default_button = "Cancel";
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{c}), policyAll()).kind);
}

test "changed body or title stops the notice" {
    const wm_bodies = [_][]const []const u8{
        &.{watermark_text_1},
        &.{ watermark_text_1, watermark_text_2, "Extra." },
        &.{ watermark_text_1, "Save changes?" },
        &.{ watermark_text_1, "The data contained in this file may only be used in other watermarked documents" },
        &.{ "This document is Watermarked.", watermark_text_2 },
    };
    for (wm_bodies) |b| {
        var w = watermark_win;
        w.texts = b;
        const d = decide(obsOf(&.{w}), policyAll());
        try testing.expectEqual(DecisionKind.unknown_ui, d.kind);
        try testing.expectEqual(ModalClass.unknown, d.modal);
    }
    var w = watermark_win;
    w.title = "Vectorworks";
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{w}), policyAll()).kind);
    w.title = null;
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{w}), policyAll()).kind);
    // Conversion naming another file, with changed spacing, or not expected at all.
    const other_conv = [_][]const u8{ conversion_text_prefix ++ "other_v2027.vwx", "Vectorworks" };
    var c = conversion_win;
    c.texts = &other_conv;
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{c}), policyAll()).kind);
    const spaced = [_][]const u8{ "This file was created with an older version of Vectorworks. It will be converted and opened with the new name: " ++ conv, "Vectorworks" };
    c.texts = &spaced;
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{c}), policyAll()).kind);
    var p = policyAll();
    p.expected.converted = null;
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{conversion_win}), p).kind);
}

test "license, save, overwrite and unknown dialogs stop" {
    const cases = [_]struct { text: []const u8, class: ModalClass }{
        .{ .text = "License activation required", .class = .license },
        .{ .text = "Your trial has expired", .class = .license },
        .{ .text = "Save changes?", .class = .save },
        .{ .text = "Overwrite file?", .class = .overwrite },
        .{ .text = "A file named x already exists", .class = .overwrite },
        .{ .text = "Something else", .class = .unknown },
    };
    for (cases) |c| {
        const texts = [_][]const u8{c.text};
        const w: WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &texts, .default_button = "OK" };
        const d = decide(obsOf(&.{ doc(conv), w }), policyAll());
        try testing.expectEqual(DecisionKind.unknown_ui, d.kind);
        try testing.expectEqual(c.class, d.modal);
        try testing.expectEqual(ProposedAction.none, d.action);
    }
    // Unread text.
    const unread: WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = null, .default_button = "OK" };
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{unread}), policyAll()).kind);
    // An unknown dialog stops even beside a known notice.
    const texts = [_][]const u8{"Save changes?"};
    const sv: WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &texts, .default_button = "OK" };
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{ watermark_win, sv }), policyAll()).kind);
}

test "multiple candidates stop" {
    const d = decide(obsOf(&.{ watermark_win, watermark_win }), policyAll());
    try testing.expectEqual(DecisionKind.unknown_ui, d.kind);
    try testing.expectEqual(ProposedAction.none, d.action);
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{ conversion_win, watermark_win }), policyAll()).kind);
}

test "progress waits and never acknowledges" {
    var d = decide(obsOf(&.{progress_win}), policyAll());
    try testing.expectEqual(DecisionKind.wait, d.kind);
    try testing.expectEqual(ProposedAction.wait, d.action);
    try testing.expectEqual(@as(u8, 10), d.progress.?.step);
    // The document window beside progress is not readiness.
    d = decide(obsOf(&.{ doc(conv), progress_win }), policyAll());
    try testing.expectEqual(DecisionKind.wait, d.kind);
    try testing.expect(!d.isReady());
}

test "unrelated progress is unknown and never readiness" {
    const other = [_][]const u8{ "Opening File: other.vwx", "Step 10 of 11: Generating Resource Previews...", "", "Vectorworks" };
    const w: WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &other };
    const d = decide(obsOf(&.{ doc(conv), w }), policyAll());
    try testing.expectEqual(DecisionKind.unknown_ui, d.kind);
    try testing.expect(!d.isReady());
    const bad = [_][]const u8{ "Opening File: " ++ orig, "Step 12 of 11: Generating Resource Previews...", "", "Vectorworks" };
    const w2: WindowObservation = .{ .title = "Vectorworks", .modal = true, .texts = &bad };
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{w2}), policyAll()).kind);
}

test "ready requires exactly the expected document window" {
    var d = decide(obsOf(&.{doc(conv ++ calibrated_watermark_suffix)}), policyAll());
    try testing.expectEqual(DecisionKind.ready, d.kind);
    try testing.expectEqualStrings(conv ++ calibrated_watermark_suffix, d.title.?);
    d = decide(obsOf(&.{doc(orig)}), policyAll());
    try testing.expectEqual(DecisionKind.ready, d.kind);
    // No windows or an unrelated non-document window waits.
    d = decide(obsOf(&.{}), policyAll());
    try testing.expectEqual(DecisionKind.wait, d.kind);
    d = decide(obsOf(&.{doc("Palettes")}), policyAll());
    try testing.expectEqual(DecisionKind.wait, d.kind);
}

test "wrong document and duplicates are wrong target" {
    var d = decide(obsOf(&.{doc("other.vwx - WATERMARKED FILE")}), policyAll());
    try testing.expectEqual(DecisionKind.wrong_target, d.kind);
    d = decide(obsOf(&.{doc("clock-ClocKit_standard_shafts_extra.vwx")}), policyAll());
    try testing.expectEqual(DecisionKind.wrong_target, d.kind);
    d = decide(obsOf(&.{doc(conv ++ "*")}), policyAll());
    try testing.expectEqual(DecisionKind.wrong_target, d.kind);
    d = decide(obsOf(&.{ doc(conv), doc("other.vwx") }), policyAll());
    try testing.expectEqual(DecisionKind.wrong_target, d.kind);
    d = decide(obsOf(&.{ doc(conv), doc(orig) }), policyAll());
    try testing.expectEqual(DecisionKind.wrong_target, d.kind);
    // A wrong document stops before a known notice is proposed.
    d = decide(obsOf(&.{ doc("other.vwx"), watermark_win }), policyAll());
    try testing.expectEqual(DecisionKind.wrong_target, d.kind);
    try testing.expectEqual(ProposedAction.none, d.action);
}

test "console and incompleteness precede window decisions" {
    var o = obsOf(&.{doc(conv)});
    o.console.registry = valid_registry ++ "\"CGSSessionScreenIsLocked\"=Yes";
    try testing.expectEqual(DecisionKind.console_locked, decide(o, policyAll()).kind);
    o.console.owner = "root";
    try testing.expectEqual(DecisionKind.console_wrong, decide(o, policyAll()).kind);
    o.console = .{};
    try testing.expectEqual(DecisionKind.console_unknown, decide(o, policyAll()).kind);
    o = obsOf(&.{doc(conv)});
    o.windows_complete = false;
    try testing.expectEqual(DecisionKind.unknown_ui, decide(o, policyAll()).kind);
    const unread: WindowObservation = .{ .title = conv };
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{unread}), policyAll()).kind);
    try testing.expectEqual(DecisionKind.unknown_ui, decide(.{ .console = ready_console }, policyAll()).kind);
}

test "invalid expectation is refused" {
    var p = policyAll();
    p.expected.original = "";
    try testing.expectEqual(DecisionKind.invalid_expectation, decide(obsOf(&.{doc(conv)}), p).kind);
}

const Fake = struct {
    result: ObserveResult,
    calls: u32 = 0,
    last: ?Query = null,

    fn observe(ptr: *anyopaque, q: Query) ObserveResult {
        const f: *Fake = @ptrCast(@alignCast(ptr));
        f.calls += 1;
        f.last = q;
        return f.result;
    }

    fn observer(f: *Fake) Observer {
        return .{ .ptr = f, .observeFn = observe };
    }
};

test "runner failures map to distinct non-ready decisions" {
    const p = policyAll();
    var f: Fake = .{ .result = .{ .failed = .{ .kind = .transport, .detail = "osascript timed out" } } };
    var d = observeAndDecide(f.observer(), 123, p);
    try testing.expectEqual(DecisionKind.transport_failure, d.kind);
    try testing.expectEqualStrings("osascript timed out", d.detail);
    try testing.expectEqual(ProposedAction.none, d.action);
    f.result = .{ .failed = .{ .kind = .process_missing } };
    d = observeAndDecide(f.observer(), 123, p);
    try testing.expectEqual(DecisionKind.process_missing, d.kind);
    f.result = .{ .failed = .{ .kind = .malformed, .detail = "bad tsv" } };
    d = observeAndDecide(f.observer(), 123, p);
    try testing.expectEqual(DecisionKind.unknown_ui, d.kind);
    try testing.expect(!d.isReady());
    try testing.expectEqual(@as(u32, 3), f.calls);
}

test "observer receives the query and invalid input skips it" {
    var f: Fake = .{ .result = .{ .observed = obsOf(&.{doc(conv)}) } };
    var d = observeAndDecide(f.observer(), 4242, policyAll());
    try testing.expectEqual(DecisionKind.ready, d.kind);
    try testing.expectEqual(@as(i32, 4242), f.last.?.pid);
    try testing.expectEqualStrings(orig, f.last.?.expected.original);
    d = observeAndDecide(f.observer(), 0, policyAll());
    try testing.expectEqual(DecisionKind.process_missing, d.kind);
    d = observeAndDecide(f.observer(), -5, policyAll());
    try testing.expectEqual(DecisionKind.process_missing, d.kind);
    var p = policyAll();
    p.expected.original = "bad";
    d = observeAndDecide(f.observer(), 4242, p);
    try testing.expectEqual(DecisionKind.invalid_expectation, d.kind);
    try testing.expectEqual(@as(u32, 1), f.calls);
}

test "observed locked console through the runner is not ready" {
    var o = obsOf(&.{doc(conv)});
    o.console.registry = valid_registry ++ "\"CGSSessionScreenIsLocked\"=Yes";
    var f: Fake = .{ .result = .{ .observed = o } };
    const d = observeAndDecide(f.observer(), 77, policyAll());
    try testing.expectEqual(DecisionKind.console_locked, d.kind);
    try testing.expectEqual(ProposedAction.none, d.action);
}

test "policy functions take no allocator" {
    inline for (.{ classifyConsole, matchTitle, parseStepLine, parseProgress, classifyDialog, decide, observeAndDecide }) |f| {
        inline for (@typeInfo(@TypeOf(f)).@"fn".params) |param| {
            try testing.expect(param.type.? != std.mem.Allocator);
        }
    }
}

test "tolerated documents default to none and only exact titles stay beside the expected window" {
    var p = policyAll();
    try testing.expectEqual(@as(usize, 0), p.tolerated_documents.len);
    const other = [_][]const u8{"ref-b.vwx"};
    // Default: another document window is a wrong target.
    try testing.expectEqual(DecisionKind.wrong_target, decide(obsOf(&.{ doc(orig), doc("ref-b.vwx") }), p).kind);
    p.tolerated_documents = &other;
    const d = decide(obsOf(&.{ doc(orig), doc("ref-b.vwx"), doc("Untitled-1") }), p);
    try testing.expectEqual(DecisionKind.ready, d.kind);
    try testing.expectEqualStrings(orig, d.title.?);
    // Exact match only: a different case, a prefix or a third document is still another document.
    try testing.expectEqual(DecisionKind.wrong_target, decide(obsOf(&.{ doc(orig), doc("REF-B.vwx") }), p).kind);
    try testing.expectEqual(DecisionKind.wrong_target, decide(obsOf(&.{ doc(orig), doc("ref-b.vwx.bak.vwx") }), p).kind);
    try testing.expectEqual(DecisionKind.wrong_target, decide(obsOf(&.{ doc(orig), doc("ref-b.vwx"), doc("ref-c.vwx") }), p).kind);
    // A tolerated window never stands in for the expected document, and a duplicate expected window stays refused.
    try testing.expectEqual(DecisionKind.wait, decide(obsOf(&.{doc("ref-b.vwx")}), p).kind);
    try testing.expectEqual(DecisionKind.wrong_target, decide(obsOf(&.{ doc(orig), doc(orig) }), p).kind);
}

test "a tolerated document does not relax dialogs" {
    const other = [_][]const u8{"ref-b.vwx"};
    var p = policyAll();
    p.tolerated_documents = &other;
    const save_win: WindowObservation = .{ .title = "", .modal = true, .texts = &.{ "Do you want to save the changes you made in the document \"ref-b.vwx\"?", "Your changes will be lost if you don't save them." } };
    try testing.expectEqual(DecisionKind.unknown_ui, decide(obsOf(&.{ doc(orig), doc("ref-b.vwx"), save_win }), p).kind);
}
