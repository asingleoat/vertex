const std = @import("std");
const vertex = @import("vertex");
const sokol = @import("sokol");
const ig = @import("cimgui");

pub fn main() void {
    std.debug.print("vertex-view stub: layout={s} sokol={s}\n", .{ @tagName(vertex.build_options.vertex_layout), @typeName(sokol.gfx.Buffer) });
    _ = ig;
}
