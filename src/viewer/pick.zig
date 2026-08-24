//! GL-BACKEND-ONLY element-ID rendering and synchronous pixel readback.
//!
//! This module deliberately calls OpenGL while Sokol's offscreen framebuffer is
//! bound. The pinned GL backend executes draw calls immediately. Its generic
//! pass clear path calls `glClearBufferfv` for every color format, including
//! integer attachments, so the queried pixel is cleared explicitly with
//! `glClearBufferuiv` after applying the 1x1 scissor. Porting this viewer away
//! from Linux/GL requires replacing this entire escape hatch.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const mesh_render = @import("render/mesh.zig");
const pick_lines_shader = @import("shaders/pick_lines.zig");
const pick_mesh_shader = @import("shaders/pick_mesh.zig");
const pick_mesh_soa_shader = @import("shaders/pick_mesh_soa.zig");
const pick_points_shader = @import("shaders/pick_points.zig");
const pick_points_soa_shader = @import("shaders/pick_points_soa.zig");
const Mat4 = vertex.camera.Mat4;
const Positions = vertex.layout.Positions;
const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;
const Vec3 = vertex.layout.Vec3;

// Derived endpoint instances are the documented layout-independent f32x6
// exception and match render/lines.zig exactly.
const LineInstance = extern struct {
    p0: Vec3,
    p1: Vec3,
};

const gl_color = 0x1800;
const gl_color_attachment0 = 0x8CE0;
const gl_pack_alignment = 0x0D05;
const gl_rg_integer = 0x8228;
const gl_unsigned_int = 0x1405;

extern fn glClearBufferuiv(buffer: c_uint, drawbuffer: c_int, value: [*c]const c_uint) callconv(.c) void;
extern fn glReadBuffer(src: c_uint) callconv(.c) void;
extern fn glPixelStorei(pname: c_uint, param: c_int) callconv(.c) void;
extern fn glReadPixels(
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    format: c_uint,
    pixel_type: c_uint,
    data: ?*anyopaque,
) callconv(.c) void;

/// Picked element category derived from the owning scene structure kind.
pub const ElementKind = enum { face, point, segment };

/// One decoded ID-buffer hit. It owns no memory and remains meaningful only
/// while the referenced structure and displayed version still exist.
pub const Hit = struct {
    structure: StructureIndex,
    element: u32,
    kind: ElementKind,
};

const Target = struct {
    color_image: sg.Image = .{},
    depth_image: sg.Image = .{},
    color_view: sg.View = .{},
    depth_view: sg.View = .{},
    width: i32 = 0,
    height: i32 = 0,
};

/// Owns the integer offscreen target and all pick shaders/pipelines. It owns no
/// CPU allocations; a first line-cache lookup may use renderer storage.
pub const Picker = struct {
    target: Target = .{},
    mesh_shader: sg.Shader,
    points_shader: sg.Shader,
    lines_shader: sg.Shader,
    mesh_pipeline: sg.Pipeline,
    points_pipeline: sg.Pipeline,
    lines_pipeline: sg.Pipeline,

    /// Creates GL 4.3 integer-output pipelines without CPU allocation. The
    /// returned owner must be destroyed before `sg.shutdown`.
    pub fn init() Picker {
        const mesh_shader = sg.makeShader(switch (vertex.layout.layout) {
            .aos3, .aos4 => pick_mesh_shader.pickMeshShaderDesc(sg.queryBackend()),
            .soa => pick_mesh_soa_shader.pickMeshSoaShaderDesc(sg.queryBackend()),
        });
        const points_shader = sg.makeShader(switch (vertex.layout.layout) {
            .aos3, .aos4 => pick_points_shader.pickPointsShaderDesc(sg.queryBackend()),
            .soa => pick_points_soa_shader.pickPointsSoaShaderDesc(sg.queryBackend()),
        });
        const lines_shader = sg.makeShader(pick_lines_shader.pickLinesShaderDesc(sg.queryBackend()));

        var mesh_desc = pickPipelineDesc(mesh_shader, "vertex pick mesh pipeline");
        mesh_desc.index_type = .UINT32;
        configurePositions(&mesh_desc, false);

        var points_desc = pickPipelineDesc(points_shader, "vertex pick points pipeline");
        points_desc.primitive_type = .TRIANGLE_STRIP;
        configurePositions(&points_desc, true);

        var lines_desc = pickPipelineDesc(lines_shader, "vertex pick lines pipeline");
        lines_desc.primitive_type = .TRIANGLE_STRIP;
        lines_desc.layout.buffers[0] = .{ .stride = @sizeOf(LineInstance), .step_func = .PER_INSTANCE };
        lines_desc.layout.attrs[pick_lines_shader.ATTR_pick_lines_p0] = .{
            .buffer_index = 0,
            .offset = @offsetOf(LineInstance, "p0"),
            .format = .FLOAT3,
        };
        lines_desc.layout.attrs[pick_lines_shader.ATTR_pick_lines_p1] = .{
            .buffer_index = 0,
            .offset = @offsetOf(LineInstance, "p1"),
            .format = .FLOAT3,
        };

        return .{
            .mesh_shader = mesh_shader,
            .points_shader = points_shader,
            .lines_shader = lines_shader,
            .mesh_pipeline = sg.makePipeline(mesh_desc),
            .points_pipeline = sg.makePipeline(points_desc),
            .lines_pipeline = sg.makePipeline(lines_desc),
        };
    }

    /// Draws every visible pickable structure for `scrub`, reads the requested
    /// top-left-origin framebuffer pixel inside the pass, and returns a valid hit.
    /// A line-cache OOM skips that line structure rather than retaining an error.
    pub fn query(
        self: *Picker,
        renderer: *mesh_render.Renderer,
        scene: *const Scene,
        scrub: u32,
        vp: Mat4,
        viewport: [2]i32,
        pixel: [2]u32,
    ) ?Hit {
        if (viewport[0] <= 0 or viewport[1] <= 0) return null;
        if (pixel[0] >= @as(u32, @intCast(viewport[0])) or
            pixel[1] >= @as(u32, @intCast(viewport[1]))) return null;
        self.ensureTarget(viewport[0], viewport[1]);

        var attachments: sg.Attachments = .{};
        attachments.colors[0] = self.target.color_view;
        attachments.depth_stencil = self.target.depth_view;
        var colors: [sg.max_color_attachments]sg.ColorAttachmentAction = @splat(.{});
        // `clear_value = .{}` records the required integer-zero value, but the
        // pinned GL backend selects glClearBufferfv solely from attachment slot.
        // DONTCARE avoids that invalid integer clear; glClearBufferuiv below is
        // the source-verified GL path this module relies on.
        colors[0] = .{ .load_action = .DONTCARE, .store_action = .STORE, .clear_value = .{} };
        sg.beginPass(.{
            .action = .{
                .colors = colors,
                .depth = .{ .load_action = .CLEAR, .store_action = .DONTCARE, .clear_value = 1 },
            },
            .attachments = attachments,
            .label = "vertex 1x1 pick pass",
        });

        const px: i32 = @intCast(pixel[0]);
        const py: i32 = @intCast(pixel[1]);
        sg.applyScissorRect(px, py, 1, 1, true);
        const zero: [4]c_uint = @splat(0);
        glClearBufferuiv(gl_color, 0, &zero);

        self.drawMeshes(renderer, scene, scrub, vp);
        self.drawLines(renderer, scene, scrub, vp, viewport);
        self.drawPoints(renderer, scene, scrub, vp, viewport);

        var encoded: [2]u32 = .{ 0, 0 };
        glReadBuffer(gl_color_attachment0);
        glPixelStorei(gl_pack_alignment, 1);
        // Sokol converts the top-left scissor Y to GL's bottom-left origin;
        // direct glReadPixels needs the corresponding explicit conversion.
        const read_y = viewport[1] - 1 - py;
        glReadPixels(px, read_y, 1, 1, gl_rg_integer, gl_unsigned_int, &encoded);
        glPixelStorei(gl_pack_alignment, 4);
        sg.endPass();
        return decode(scene, scrub, encoded);
    }

    /// Destroys the current target and all pick pipelines/shaders. It owns no
    /// CPU allocations and must run before the renderer and `sg.shutdown`.
    pub fn deinit(self: *Picker) void {
        self.destroyTarget();
        sg.destroyPipeline(self.lines_pipeline);
        sg.destroyPipeline(self.points_pipeline);
        sg.destroyPipeline(self.mesh_pipeline);
        sg.destroyShader(self.lines_shader);
        sg.destroyShader(self.points_shader);
        sg.destroyShader(self.mesh_shader);
        self.* = undefined;
    }

    fn ensureTarget(self: *Picker, width: i32, height: i32) void {
        if (self.target.width == width and self.target.height == height) return;
        self.destroyTarget();
        const color_image = sg.makeImage(.{
            .usage = .{ .color_attachment = true, .immutable = true },
            .width = width,
            .height = height,
            .pixel_format = .RG32UI,
            .sample_count = 1,
            .label = "vertex pick RG32UI image",
        });
        const depth_image = sg.makeImage(.{
            .usage = .{ .depth_stencil_attachment = true, .immutable = true },
            .width = width,
            .height = height,
            .pixel_format = .DEPTH,
            .sample_count = 1,
            .label = "vertex pick depth image",
        });
        self.target = .{
            .color_image = color_image,
            .depth_image = depth_image,
            .color_view = sg.makeView(.{
                .color_attachment = .{ .image = color_image },
                .label = "vertex pick color attachment",
            }),
            .depth_view = sg.makeView(.{
                .depth_stencil_attachment = .{ .image = depth_image },
                .label = "vertex pick depth attachment",
            }),
            .width = width,
            .height = height,
        };
    }

    fn destroyTarget(self: *Picker) void {
        if (self.target.width == 0) return;
        sg.destroyView(self.target.depth_view);
        sg.destroyView(self.target.color_view);
        sg.destroyImage(self.target.depth_image);
        sg.destroyImage(self.target.color_image);
        self.target = .{};
    }

    fn drawMeshes(self: *Picker, renderer: *mesh_render.Renderer, scene: *const Scene, scrub: u32, vp: Mat4) void {
        const structures = scene.structures.slice();
        const ui_states = structures.items(.ui);
        const kinds = structures.items(.kind);
        const versions = structures.items(.versions);
        for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
            if (!ui_state.visible or kind != .mesh) continue;
            const structure_index: StructureIndex = @fromBackingInt(@intCast(i));
            const version_index = scene.versionAt(structure_index, scrub) orelse continue;
            const version = version_list.items[version_index];
            const faces = scene.facesOf(version);
            if (faces.len == 0) continue;
            const positions = scene.positionsOf(version);
            var bindings: sg.Bindings = .{
                .index_buffer = renderer.gpu.bufferFor(scene, version.topology, .index),
            };
            bindPositions(&bindings, renderer.gpu.bufferFor(scene, version.positions, .vertex), positions.len());
            sg.applyPipeline(self.mesh_pipeline);
            sg.applyBindings(bindings);
            applyMeshUniforms(vp, shaderStructureId(i));
            std.debug.assert(faces.len <= std.math.maxInt(u32) / 3);
            sg.draw(0, @intCast(faces.len * 3), 1);
        }
    }

    fn drawLines(
        self: *Picker,
        renderer: *mesh_render.Renderer,
        scene: *const Scene,
        scrub: u32,
        vp: Mat4,
        viewport: [2]i32,
    ) void {
        const structures = scene.structures.slice();
        const ui_states = structures.items(.ui);
        const kinds = structures.items(.kind);
        const versions = structures.items(.versions);
        for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
            if (!ui_state.visible or kind != .lines) continue;
            const structure_index: StructureIndex = @fromBackingInt(@intCast(i));
            const version_index = scene.versionAt(structure_index, scrub) orelse continue;
            std.debug.assert(version_index < version_list.items.len);
            const entry = renderer.lines.entryForPick(scene, structure_index, version_index) catch continue orelse continue;
            const vs: pick_lines_shader.VsParams = .{
                .mvp = vp.m,
                .viewport_size_line_width_pad = .{
                    @floatFromInt(viewport[0]),
                    @floatFromInt(viewport[1]),
                    ui_state.line_width,
                    0,
                },
            };
            const fs: pick_lines_shader.FsParams = .{ .structure_id = shaderStructureId(i) };
            var bindings: sg.Bindings = .{};
            bindings.vertex_buffers[0] = entry.buffer;
            sg.applyPipeline(self.lines_pipeline);
            sg.applyBindings(bindings);
            sg.applyUniforms(pick_lines_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(pick_lines_shader.VsParams) });
            sg.applyUniforms(pick_lines_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(pick_lines_shader.FsParams) });
            sg.draw(0, 4, @intCast(entry.count));
        }
    }

    fn drawPoints(
        self: *Picker,
        renderer: *mesh_render.Renderer,
        scene: *const Scene,
        scrub: u32,
        vp: Mat4,
        viewport: [2]i32,
    ) void {
        const structures = scene.structures.slice();
        const ui_states = structures.items(.ui);
        const kinds = structures.items(.kind);
        const versions = structures.items(.versions);
        for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
            if (!ui_state.visible or kind != .points) continue;
            const structure_index: StructureIndex = @fromBackingInt(@intCast(i));
            const version_index = scene.versionAt(structure_index, scrub) orelse continue;
            const version = version_list.items[version_index];
            const positions = scene.positionsOf(version);
            if (positions.len() == 0) continue;
            var bindings: sg.Bindings = .{};
            bindPositions(&bindings, renderer.gpu.bufferFor(scene, version.positions, .vertex), positions.len());
            sg.applyPipeline(self.points_pipeline);
            sg.applyBindings(bindings);
            applyPointUniforms(vp, viewport, ui_state.point_size, shaderStructureId(i));
            sg.draw(0, 4, @intCast(positions.len()));
        }
    }
};

/// Runs one pick query through `picker`; the returned hit owns no memory. A
/// first line-cache lookup may use the renderer's retained allocator.
pub fn query(
    picker: *Picker,
    renderer: *mesh_render.Renderer,
    scene: *const Scene,
    scrub: u32,
    vp: Mat4,
    viewport: [2]i32,
    pixel: [2]u32,
) ?Hit {
    return picker.query(renderer, scene, scrub, vp, viewport, pixel);
}

fn pickPipelineDesc(shader: sg.Shader, label: [*c]const u8) sg.PipelineDesc {
    var colors: [sg.max_color_attachments]sg.ColorTargetState = @splat(.{});
    colors[0].pixel_format = .RG32UI;
    return .{
        .shader = shader,
        .depth = .{ .pixel_format = .DEPTH, .compare = .LESS_EQUAL, .write_enabled = true },
        .color_count = 1,
        .colors = colors,
        .cull_mode = .NONE,
        .sample_count = 1,
        .label = label,
    };
}

fn configurePositions(desc: *sg.PipelineDesc, instanced: bool) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            desc.layout.buffers[0] = .{
                .stride = @intCast(Positions.stride),
                .step_func = if (instanced) .PER_INSTANCE else .PER_VERTEX,
            };
            desc.layout.attrs[0] = .{
                .buffer_index = 0,
                .offset = @intCast(@offsetOf(Positions.Elem, "x")),
                .format = .FLOAT3,
            };
        },
        .soa => inline for (0..3) |i| {
            desc.layout.buffers[i] = .{
                .stride = @sizeOf(f32),
                .step_func = if (instanced) .PER_INSTANCE else .PER_VERTEX,
            };
            desc.layout.attrs[i] = .{ .buffer_index = i, .format = .FLOAT };
        },
    }
}

fn bindPositions(bindings: *sg.Bindings, buffer: sg.Buffer, count: u32) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => bindings.vertex_buffers[0] = buffer,
        .soa => {
            const component_bytes = @as(u64, count) * @sizeOf(f32);
            std.debug.assert(component_bytes * 2 <= std.math.maxInt(i32));
            inline for (0..3) |i| bindings.vertex_buffers[i] = buffer;
            bindings.vertex_buffer_offsets[1] = @intCast(component_bytes);
            bindings.vertex_buffer_offsets[2] = @intCast(component_bytes * 2);
        },
    }
}

fn applyMeshUniforms(vp: Mat4, structure_id: i32) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            const vs: pick_mesh_shader.VsParams = .{ .mvp = vp.m };
            const fs: pick_mesh_shader.FsParams = .{ .structure_id = structure_id };
            sg.applyUniforms(pick_mesh_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(pick_mesh_shader.VsParams) });
            sg.applyUniforms(pick_mesh_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(pick_mesh_shader.FsParams) });
        },
        .soa => {
            const vs: pick_mesh_soa_shader.VsParams = .{ .mvp = vp.m };
            const fs: pick_mesh_soa_shader.FsParams = .{ .structure_id = structure_id };
            sg.applyUniforms(pick_mesh_soa_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(pick_mesh_soa_shader.VsParams) });
            sg.applyUniforms(pick_mesh_soa_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(pick_mesh_soa_shader.FsParams) });
        },
    }
}

fn applyPointUniforms(vp: Mat4, viewport: [2]i32, point_size: f32, structure_id: i32) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            const vs: pick_points_shader.VsParams = .{
                .mvp = vp.m,
                .viewport_size_point_size_pad = .{
                    @floatFromInt(viewport[0]),
                    @floatFromInt(viewport[1]),
                    point_size,
                    0,
                },
            };
            const fs: pick_points_shader.FsParams = .{ .structure_id = structure_id };
            sg.applyUniforms(pick_points_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(pick_points_shader.VsParams) });
            sg.applyUniforms(pick_points_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(pick_points_shader.FsParams) });
        },
        .soa => {
            const vs: pick_points_soa_shader.VsParams = .{
                .mvp = vp.m,
                .viewport_size_point_size_pad = .{
                    @floatFromInt(viewport[0]),
                    @floatFromInt(viewport[1]),
                    point_size,
                    0,
                },
            };
            const fs: pick_points_soa_shader.FsParams = .{ .structure_id = structure_id };
            sg.applyUniforms(pick_points_soa_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(pick_points_soa_shader.VsParams) });
            sg.applyUniforms(pick_points_soa_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(pick_points_soa_shader.FsParams) });
        },
    }
}

fn shaderStructureId(index: usize) i32 {
    return @bitCast(@as(u32, @intCast(index)));
}

fn decode(scene: *const Scene, scrub: u32, encoded: [2]u32) ?Hit {
    if (encoded[0] == 0) return null;
    const raw_structure = encoded[0] - 1;
    if (raw_structure >= scene.structures.len) return null;
    const structure_index: StructureIndex = @fromBackingInt(raw_structure);
    const structures = scene.structures.slice();
    const i: usize = raw_structure;
    if (!structures.items(.ui)[i].visible) return null;
    const version_index = scene.versionAt(structure_index, scrub) orelse return null;
    const version = structures.items(.versions)[i].items[version_index];
    const kind: ElementKind = switch (structures.items(.kind)[i]) {
        .mesh => .face,
        .points => .point,
        .lines => .segment,
    };
    const element_count: usize = switch (kind) {
        .face => scene.facesOf(version).len,
        .point => scene.positionsOf(version).len(),
        .segment => scene.segmentsOf(version).len,
    };
    if (encoded[1] >= element_count) return null;
    return .{ .structure = structure_index, .element = encoded[1], .kind = kind };
}

comptime {
    std.debug.assert(@sizeOf(vertex.layout.Vec3) == 12);
    std.debug.assert(@sizeOf(LineInstance) == 24);
}
