const std = @import("std");

/// A Zig test binary runs the tests of the files its root references. The rosetta_capture.zig root
/// reaches the tests of every module except native_script_dispatch.zig.
const test_roots = [_][]const u8{
    "src/main.zig",
    "src/rosetta_capture.zig",
    "src/native_script_dispatch.zig",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const options = b.addOptions();
    options.addOption([]const u8, "volume", b.option(
        []const u8,
        "volume",
        "Machine root of the scratch allow-lists (default: /Volumes/volxxxx)",
    ) orelse "/Volumes/volxxxx");

    const exe = b.addExecutable(.{
        .name = "vwx",
        .root_module = module(b, "src/main.zig", target, optimize, options),
    });
    // An unstripped binary holds the cache path and the mtime of its object file in a debug-map
    // entry, so two builds of one commit differ and BUILD.tsv could not record one digest.
    exe.root_module.strip = true;
    b.installArtifact(exe);

    const test_step = b.step("test", "Run the tests of every module");
    for (test_roots) |root| {
        const t = b.addTest(.{ .root_module = module(b, root, target, optimize, options) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

fn module(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    m.addOptions("build_options", options);
    if (target.result.os.tag == .macos) {
        m.linkFramework("ApplicationServices", .{});
        m.linkFramework("CoreFoundation", .{});
        m.linkFramework("CoreServices", .{});
    }
    return m;
}
