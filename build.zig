const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const cimgui = @import("cimgui");

/// Vertex stream memory layout. Selected once per build; the `vertex` module's
/// `Positions` type, the wire format, blob storage and GPU strides all derive
/// from it (STYLE.md §3). Changing it is a protocol version bump.
pub const Layout = enum { aos3, aos4, soa };

pub fn build(b: *Build) !void {
    const target = resolveTarget(b);
    // `-Drelease` is the user-facing build: sketches are compute and the viewer
    // is left running for days, so it is ReleaseFast. Development and every
    // verification path deliberately stay in Debug (`zig build`, `zig build
    // test`, `scripts/smoke.sh`) or ReleaseSafe, where the safety checks this
    // index-heavy core relies on are still live (STYLE.md §5).
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });

    const vertex_layout = b.option(Layout, "vertex_layout", "Vertex stream layout (default: aos3)") orelse .aos3;
    const sketch_name = b.option([]const u8, "sketch", "Sketch to run with `zig build run-sketch` (default: current)") orelse "current";

    // sokol's `auto` backend resolves to Metal on Darwin and to GL elsewhere.
    // GL is requested explicitly where it is intended, and the result is passed
    // to our own code as a build option. The readback in `pick.zig` is a raw GL
    // escape hatch and exists exactly when this is true; see the portability
    // table in DESIGN.md.
    const gl_backend = !target.result.os.tag.isDarwin();

    const build_options = b.addOptions();
    build_options.addOption(Layout, "vertex_layout", vertex_layout);
    build_options.addOption(bool, "gl_backend", gl_backend);
    // One module, imported everywhere. `addOptions` creates a new module on
    // each call and two modules cannot share a source file, so the viewer
    // importing `build_options` directly while `vertex` holds its own copy is a
    // compile error.
    const options_module = build_options.createModule();

    // ---- `vertex`: pure core (geometry, protocol, scene) + client library ----
    const mod_vertex = b.addModule("vertex", .{
        .root_source_file = b.path("src/vertex.zig"),
        .target = target,
        .optimize = optimize,
        // Polygon triangulation is Manifold behind the C++ shim below, which
        // reaches every consumer of this module: the viewer, sketches and the
        // stepping libraries all link libc, libc++ and libmanifoldc.
        .link_libc = true,
        .link_libcpp = true,
    });
    mod_vertex.addImport("build_options", options_module);
    addManifold(b, mod_vertex);

    // ---- tests ----
    const test_step = b.step("test", "Run unit tests");
    const vertex_tests = b.addTest(.{ .root_module = mod_vertex });
    test_step.dependOn(&b.addRunArtifact(vertex_tests).step);

    // ---- viewer: sokol + imgui edges ----
    const cimgui_conf = cimgui.getConfig(false);
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .gl = gl_backend,
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
    mod_viewer.addImport("build_options", options_module);
    addRuntimeLibPaths(b, mod_viewer);
    const viewer_tests = b.addTest(.{ .root_module = mod_viewer });
    test_step.dependOn(&b.addRunArtifact(viewer_tests).step);
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

    // ---- stepping libraries: one dylib per steps/*.zig ----
    const step_step = b.step("step", "Build and install steps/<name>.zig as a dynamic library");
    var found_step = false;
    if (try listZigFiles(b, "steps")) |names| for (names) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("steps/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "vertex", .module = mod_vertex }},
        });
        mod.addImport("build_options", options_module);
        const library = b.addLibrary(.{
            .name = b.fmt("step-{s}", .{name}),
            .linkage = .dynamic,
            .root_module = mod,
        });
        const install = b.addInstallArtifact(library, .{});
        b.getInstallStep().dependOn(&install.step);
        if (std.mem.eql(u8, name, sketch_name)) {
            step_step.dependOn(&install.step);
            found_step = true;
        }
    };
    if (!found_step) step_step.dependOn(&b.addFail(b.fmt("no stepping sketch named '{s}' in steps/", .{sketch_name})).step);

    // ---- benches: one ReleaseFast exe per bench/*.zig ----
    const bench_step = b.step("bench", "Build and run all benchmarks (ReleaseFast)");
    if (try listZigFiles(b, "bench")) |names| for (names) |name| {
        const mod_bench_vertex = b.createModule(.{
            .root_source_file = b.path("src/vertex.zig"),
            .target = target,
            .optimize = .fast,
        });
        mod_bench_vertex.addImport("build_options", options_module);
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
            // Each generated file carries every backend the project targets,
            // so that a Linux checkout and a macOS checkout produce identical
            // output and neither needs to regenerate for the other.
            if (isGlOnlyShader(name)) "glsl430" else "glsl430:metal_macos",
            "-f",
            "sokol_zig",
        });
        cmd.has_side_effects = true;
        // shdc output isn't zig-fmt clean; format it so `zig fmt --check` stays green.
        const fmt = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", b.fmt("src/viewer/shaders/{s}.zig", .{name}) });
        fmt.has_side_effects = true;
        fmt.step.dependOn(&cmd.step);
        shaders_step.dependOn(&fmt.step);
    };

    // ---- docs: zig's autodoc for the `vertex` module ----
    // The two modules under api/ are written to be read as source, but the same
    // doc comments also render as a browsable site. Run `zig build docs` and
    // open zig-out/docs/index.html; the page fetches sources.tar, so it may
    // need serving over HTTP rather than opening from the file system.
    const docs_obj = b.addObject(.{ .name = "vertex", .root_module = mod_vertex });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Emit HTML documentation to zig-out/docs").dependOn(&install_docs.step);

    // ---- check: compile everything without installing (for zls) ----
    const check_step = b.step("check", "Type-check all artifacts without installing");
    check_step.dependOn(&viewer.step);
    check_step.dependOn(&vertex_tests.step);
    check_step.dependOn(&viewer_tests.step);
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
    // This applies to Linux only. The nixpkgs Darwin cc wrapper also publishes
    // a nix-support/dynamic-linker, holding /usr/lib/dyld, so the shell hook's
    // test for that file is not a test of the platform. Pinning here would force
    // abi=gnu on a macOS target and break the C and C++ dependencies, sokol and
    // cimgui.
    const host_is_linux = (query.os_tag orelse builtin.os.tag) == .linux;
    if (host_is_linux) if (query.isNative()) if (nonEmpty(env.get("ZIG_DYNAMIC_LINKER"))) |dl| {
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

/// Links Manifold and compiles the shim that confines it; see "Polygon
/// triangulation and caps" in DESIGN.md.
///
/// The prefix comes from MANIFOLD_PREFIX, which flake.nix exports on every
/// platform. The two mechanisms already in this file cannot carry it: darwin
/// unsets NIX_CFLAGS_COMPILE and NIX_LDFLAGS to restore zig's SDK detection,
/// and ZIG_SEARCH_PREFIXES is exported only on linux, where it also feeds the
/// glibc pin. The lib directory is added as an rpath as well as a search path,
/// so a sketch built here runs outside the dev shell.
fn addManifold(b: *Build, mod: *Build.Module) void {
    const prefix = nonEmpty(b.graph.environ_map.get("MANIFOLD_PREFIX")) orelse
        std.debug.panic("MANIFOLD_PREFIX is not set; build inside `nix develop`", .{});
    const include_dir = std.fs.path.join(b.allocator, &.{ prefix, "include" }) catch @panic("OOM");
    const lib_dir = std.fs.path.join(b.allocator, &.{ prefix, "lib" }) catch @panic("OOM");
    mod.addIncludePath(.{ .cwd_relative = include_dir });
    mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    mod.addRPath(.{ .cwd_relative = lib_dir });
    mod.linkSystemLibrary("manifoldc", .{});
    mod.addCSourceFile(.{
        .file = b.path("src/geometry/manifold_shim.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
}

/// The viewer links nix-provided GL/X11 libraries; embed their lib dirs as
/// rpaths so it runs outside the dev shell too, plus NixOS's GL driver dir
/// (/run/opengl-driver/lib) which libglvnd needs to find the vendor driver.
fn addRuntimeLibPaths(b: *Build, mod: *Build.Module) void {
    const prefixes = b.graph.environ_map.get("ZIG_SEARCH_PREFIXES") orelse "";
    var it = std.mem.tokenizeScalar(u8, prefixes, ':');
    while (it.next()) |prefix| {
        const lib_dir = std.fs.path.join(b.allocator, &.{ prefix, "lib" }) catch @panic("OOM");
        mod.addRPath(.{ .cwd_relative = lib_dir });
    }
    mod.addRPath(.{ .cwd_relative = "/run/opengl-driver/lib" });
}

/// Reports whether a shader cannot be translated to MSL. `gl_PrimitiveID` in a
/// fragment shader requires MSL 2.2; SPIRV-Cross rejects anything below that
/// ("PrimitiveId on macOS requires MSL 2.2") and sokol-shdc exposes no flag for
/// the MSL version, as checked against both the pinned build and
/// sokol-tools-bin master on 2026-08-24. The renderer tests the generated
/// descriptor for a source, so this list determines only what is generated and
/// never what runs.
fn isGlOnlyShader(name: []const u8) bool {
    const gl_only = [_][]const u8{
        "mesh_face_scalar",
        "mesh_face_scalar_soa",
        "pick_mesh",
        "pick_mesh_soa",
    };
    for (gl_only) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
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
