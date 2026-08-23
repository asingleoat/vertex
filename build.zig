const std = @import("std");
const Build = std.Build;
const cimgui = @import("cimgui");

/// Vertex stream memory layout. Selected once per build; the `vertex` module's
/// `Positions` type, the wire format, blob storage and GPU strides all derive
/// from it (STYLE.md §3). Changing it is a protocol version bump.
pub const Layout = enum { aos3, aos4, soa };

pub fn build(b: *Build) !void {
    const target = resolveTarget(b);
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });

    const vertex_layout = b.option(Layout, "vertex_layout", "Vertex stream layout (default: aos3)") orelse .aos3;
    const sketch_name = b.option([]const u8, "sketch", "Sketch to run with `zig build run-sketch` (default: current)") orelse "current";

    const build_options = b.addOptions();
    build_options.addOption(Layout, "vertex_layout", vertex_layout);

    // ---- `vertex`: pure core (geometry, protocol, scene) + client library ----
    const mod_vertex = b.addModule("vertex", .{
        .root_source_file = b.path("src/vertex.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_vertex.addOptions("build_options", build_options);

    // ---- tests ----
    const test_step = b.step("test", "Run unit tests");
    const vertex_tests = b.addTest(.{ .root_module = mod_vertex });
    test_step.dependOn(&b.addRunArtifact(vertex_tests).step);

    // ---- viewer: sokol + imgui edges ----
    const cimgui_conf = cimgui.getConfig(false);
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .gl = true,
        .with_sokol_imgui = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));

    const mod_viewer = b.createModule(.{
        .root_source_file = b.path("src/viewer/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // sokol + imgui are C/C++; be explicit so libc startup is linked
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "vertex", .module = mod_vertex },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
        },
    });
    mod_viewer.addOptions("build_options", build_options);
    const viewer = b.addExecutable(.{ .name = "vertex-view", .root_module = mod_viewer });
    b.installArtifact(viewer);
    b.step("run-viewer", "Run the viewer").dependOn(&b.addRunArtifact(viewer).step);

    // ---- sketches: one exe per sketches/*.zig ----
    const run_sketch_step = b.step("run-sketch", "Build and run -Dsketch=<name> (default: current)");
    var found_sketch = false;
    if (try listZigFiles(b, "sketches")) |names| for (names) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("sketches/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vertex", .module = mod_vertex }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("sketch-{s}", .{name}), .root_module = mod });
        b.installArtifact(exe);
        if (std.mem.eql(u8, name, sketch_name)) {
            const run = b.addRunArtifact(exe);
            run.has_side_effects = true; // always re-run under --watch
            run_sketch_step.dependOn(&run.step);
            found_sketch = true;
        }
    };
    if (!found_sketch) run_sketch_step.dependOn(&b.addFail(b.fmt("no sketch named '{s}' in sketches/", .{sketch_name})).step);

    // ---- benches: one ReleaseFast exe per bench/*.zig ----
    const bench_step = b.step("bench", "Build and run all benchmarks (ReleaseFast)");
    if (try listZigFiles(b, "bench")) |names| for (names) |name| {
        const mod_bench_vertex = b.createModule(.{
            .root_source_file = b.path("src/vertex.zig"),
            .target = target,
            .optimize = .fast,
        });
        mod_bench_vertex.addOptions("build_options", build_options);
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("bench/{s}.zig", .{name})),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "vertex", .module = mod_bench_vertex }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("bench-{s}", .{name}), .root_module = mod });
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        bench_step.dependOn(&run.step);
    };

    // ---- shaders: regenerate src/viewer/shaders/*.zig from *.glsl via sokol-shdc (from PATH) ----
    const shaders_step = b.step("shaders", "Regenerate src/viewer/shaders/*.zig with sokol-shdc (output is checked in)");
    if (try listFiles(b, "src/viewer/shaders", ".glsl")) |names| for (names) |name| {
        const cmd = b.addSystemCommand(&.{
            "sokol-shdc",
            "-i",
            b.fmt("src/viewer/shaders/{s}.glsl", .{name}),
            "-o",
            b.fmt("src/viewer/shaders/{s}.zig", .{name}),
            "-l",
            "glsl430",
            "-f",
            "sokol_zig",
        });
        cmd.has_side_effects = true;
        shaders_step.dependOn(&cmd.step);
    };

    // ---- check: compile everything without installing (for zls) ----
    const check_step = b.step("check", "Type-check all artifacts without installing");
    check_step.dependOn(&viewer.step);
    check_step.dependOn(&vertex_tests.step);
}

/// Native builds inside the nix dev shell: zig's compiler detects the native
/// dynamic linker by probing /usr/bin/env (the *system* glibc) while the shell
/// links against nixpkgs' glibc, and executables whose interpreter and libc
/// disagree fail to load. flake.nix exports ZIG_DYNAMIC_LINKER and
/// ZIG_GLIBC_VERSION; with them the target is pinned to the shell's glibc.
/// That makes zig treat the target as non-native, which disables its
/// NIX_CFLAGS_COMPILE/NIX_LDFLAGS discovery, so the shell also exports the
/// system libraries sokol links as ZIG_SEARCH_PREFIXES (a graph-wide
/// mechanism that dependencies see too). Only those libraries are added —
/// leaking nixpkgs' glibc headers in breaks zig's bundled libc++ build.
fn resolveTarget(b: *Build) Build.ResolvedTarget {
    var query = b.standardTargetOptionsQueryOnly(.{});
    const env = b.graph.environ_map;
    if (query.isNative()) if (nonEmpty(env.get("ZIG_DYNAMIC_LINKER"))) |dl| {
        query.dynamic_linker = .init(dl);
        query.cpu_model = .native;
        // Without an explicit ABI zig falls back to probing /lib64, which on
        // NixOS is a musl stub; this shell is glibc.
        query.abi = .gnu;
        if (nonEmpty(env.get("ZIG_GLIBC_VERSION"))) |v| query.glibc_version = parseMajorMinor(v);
        var prefixes = std.mem.tokenizeScalar(u8, env.get("ZIG_SEARCH_PREFIXES") orelse "", ':');
        while (prefixes.next()) |prefix| b.addSearchPrefix(prefix);
    };
    return b.resolveTargetQuery(query);
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn parseMajorMinor(text: []const u8) ?std.SemanticVersion {
    var it = std.mem.splitScalar(u8, text, '.');
    const major = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = 0 };
}

fn listZigFiles(b: *Build, dir: []const u8) !?[]const []const u8 {
    return listFiles(b, dir, ".zig");
}

/// Names (without extension) of files in `dir` ending in `ext`, sorted. Null if the dir is absent.
/// The configure phase is cached on zig master; declaring the directory as a
/// configure dependency makes a new sketch/bench file re-run it.
fn listFiles(b: *Build, dir: []const u8, ext: []const u8) !?[]const []const u8 {
    const io = b.graph.io;
    // `dependOnDirectory` is the right declaration, but the maker's directory
    // mode is still a TODO on zig master (lib/compiler/Maker.zig), so it does
    // not yet invalidate anything. Poison the configure cache until it does;
    // the configure phase for this build.zig is cheap.
    b.dependOnDirectory(b.path(dir));
    b.graph.poisonCache();
    var d = b.root.openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer d.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ext)) continue;
        try names.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - ext.len]));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return names.items;
}
