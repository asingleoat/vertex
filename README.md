# vertex

```sh
nix develop                                     # toolchain; run everything below inside it

zig build -Drelease run-viewer                  # terminal 1 — leave it up for days
zig build run-sketch --watch -Dsketch=NAME      # terminal 2 — rebuild + rerun on every save
                                                #   on Linux, add -fincremental
```

`NAME` is a file in `sketches/`, default `current`.

```zig
const std = @import("std");
const vertex = @import("vertex");
const Positions = vertex.layout.Positions;

pub fn main(init: std.process.Init) !void {
    var vx = try vertex.connect(init, .{ .name = "example" });
    defer vx.close();

    // Mesh: positions + triangles.
    const tri = try Positions.alloc(init.gpa, 3);
    defer tri.free(init.gpa);
    tri.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    try vx.mesh("tri", tri.toConst(), &.{.{ 0, 1, 2 }}, .{});

    // Quantities on it: per-vertex scalar, per-face scalar, per-vertex vector.
    try vx.scalar("tri", "height", .vertex, &.{ 0.0, 0.5, 1.0 });
    try vx.scalar("tri", "area", .face, &.{0.5});
    const normals = try Positions.alloc(init.gpa, 3);
    defer normals.free(init.gpa);
    normals.setAll(&.{ .init(0, 0, 1), .init(0, 0, 1), .init(0, 0, 1) });
    try vx.vector("tri", "normal", .vertex, normals.toConst());

    // Point cloud, with a per-point scalar.
    const cloud = try Positions.alloc(init.gpa, 2);
    defer cloud.free(init.gpa);
    cloud.setAll(&.{ .init(-1, 0, 0), .init(-1, 1, 0) });
    try vx.points("cloud", cloud.toConst(), .{});
    try vx.scalar("cloud", "weight", .point, &.{ 0.2, 0.9 });

    // Polylines and edge sets: vertices + segments.
    try vx.lines("edge", cloud.toConst(), &.{.{ 0, 1 }}, .{});

    try vx.log(.info, "hello from a sketch");

    // Frame boundary: everything above is frame 0, the update below is frame 1.
    try vx.step();
    tri.set(2, .init(0, 2, 0));
    try vx.meshPositions("tri", tri.toConst()); // topology unchanged

    try vx.finish();
}
```
