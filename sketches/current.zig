const std = @import("std");
const vertex = @import("vertex");

pub fn main() void {
    std.debug.print("sketch stub v2: layout={s}\n", .{@tagName(vertex.build_options.vertex_layout)});
}
