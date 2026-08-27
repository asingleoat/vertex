const std = @import("std");
const vertex = @import("vertex");
const shapes = vertex.shapes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var vx: vertex.Connection = try vertex.connect(init, .{ .name = "circle loft to cylinder" });
    defer vx.close();

    const outline = try shapes.circle(gpa, 1, 8);
    defer outline.deinit(gpa);
    try vx.registerPolyline(gpa, "outline", outline, .{});

    const solid = try shapes.cylinder(gpa, 1, 2, 8);
    defer solid.deinit(gpa);
    try vx.registerMesh(gpa, "cylinder", solid, .{});

    // A boolean needs closed operands, which both of these are. Boring one
    // cylinder out of another leaves a tube, and the result is closed in turn,
    // so it could be an operand itself.
    const bore = try shapes.cylinder(gpa, 0.6, 4, 16);
    defer bore.deinit(gpa);
    shapes.translate(bore.vertices, .init(0, 0, -1));

    const tube = try shapes.boolean.apply(gpa, solid, bore, .subtract);
    defer tube.deinit(gpa);
    shapes.translate(tube.vertices, .init(3, 0, 0));
    try vx.registerMesh(gpa, "tube", tube, .{});

    // A box drilled by the same bore, to see the two primitives compose. The
    // block stands on the plane like the cylinder, so they line up.
    const block = try shapes.box(gpa, .init(1.6, 1.6, 2), .on_plane);
    defer block.deinit(gpa);
    const drilled = try shapes.boolean.apply(gpa, block, bore, .subtract);
    defer drilled.deinit(gpa);
    shapes.translate(drilled.vertices, .init(-3, 0, 0));
    try vx.registerMesh(gpa, "drilled-block", drilled, .{});

    // A two-dimensional profile and its offset, both closed polylines in the
    // z = 0 plane. The round join traces the true offset, so the square's four
    // corners come back as quarter arcs while its sides stay straight.
    const profile = try shapes.square(gpa, 1.5, .centered);
    defer profile.deinit(gpa);
    shapes.translate(profile.vertices, .init(0, -3, 0));
    try vx.registerPolyline(gpa, "profile", profile, .{});

    const grown = try shapes.offset.apply(gpa, profile, 0.4, .{ .circular_segments = 64 });
    defer grown.deinit(gpa);
    try vx.registerPolyline(gpa, "profile-offset", grown, .{});

    // At its own scale, which is millimetres: the boat is about 60 mm long and
    // dwarfs the unit cylinder beside it. models/ is not checked in, so a fresh
    // clone has no boat and the rest of the sketch stands on its own.
    if (vertex.readStl(gpa, init.io, .cwd(), "models/3DBenchy.stl")) |boat| {
        defer boat.deinit(gpa);
        try vx.registerMesh(gpa, "benchy", boat, .{});
    } else |err| {
        std.debug.print("skipping benchy: {t}\n", .{err});
    }

    try vx.finish();
}
