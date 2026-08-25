//! Vertex streams: how the coordinates of many vertices are represented and
//! addressed throughout the program.
//!
//! A vertex stream is a run of `n` positions in three dimensions. It is what a
//! mesh's vertices are, what a point cloud is, and what the values of a vector
//! quantity are; it carries no connectivity and no other attributes, which
//! travel alongside it as plain slices. `Positions` is the type every part of
//! the program uses for one, and this module defines it.
//!
//! The memory layout is chosen once, at build time, by `-Dvertex_layout`.
//! Callers address vertices through the named accessors `get`, `set`, `x`, `y`
//! and `z` and never compute an offset, so selecting a different layout
//! recompiles every kernel against new offsets and strides and changes nothing
//! else. The wire format, the viewer's blob storage and the GPU vertex layout
//! are all derived from this type through `bytes` and `fromBytes`, so no
//! conversion is performed for any layout. See `STYLE.md` §3.
const std = @import("std");
const build_options = @import("build_options");

/// The memory layouts a vertex stream can have.
/// ---
/// `.aos3` stores each vertex as three consecutive `f32`, twelve bytes. It is
/// the default and the most compact, so it fits the most vertices per cache
/// line. `.aos4` pads each vertex to sixteen bytes, which casts to
/// `@Vector(4, f32)` at no cost and costs memory and wire bandwidth in
/// exchange. `.soa` stores the stream as three planar runs, all x, then all y,
/// then all z, and exposes them through `xs`, `ys` and `zs` as whole `[]f32`
/// runs a kernel can consume.
/// ---
/// The choice is made by `-Dvertex_layout` and applies to the entire build.
/// `.aos3` is the default; the other two exist to be measured against it with
/// `zig build bench` rather than assumed to be faster.
pub const Layout = enum { aos3, aos4, soa };

/// The layout this build selected, from `-Dvertex_layout`, defaulting to
/// `.aos3`. A kernel that wants a layout-specific path switches on this at
/// compile time; everything else is written against the accessors and ignores
/// it.
pub const layout: Layout = @field(Layout, @tagName(build_options.vertex_layout));

/// The alignment of every positions blob, in bytes. Large enough for any
/// `@Vector` load over the stream and for GPU staging later. `alloc` applies it,
/// and the viewer's blob store maintains it, so a stream that arrives over the
/// wire is aligned without being copied again. See `STYLE.md` §2.
pub const blob_alignment: std.mem.Alignment = .@"64";

/// A position or direction in three dimensions: three `f32`, twelve bytes,
/// owning nothing and copied freely.
/// ---
/// This is the value type the accessors speak in every layout, so kernel code
/// deals in `Vec3` whether the underlying stream is packed, padded or planar.
/// It also serves as the arithmetic type for geometry code, with `add`, `sub`,
/// `scale`, `dot`, `cross`, `length`, `normalize`, `min`, `max` and `eql`.
/// Two-dimensional work uses the same type with `z` left at zero.
pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };

    pub inline fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub inline fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub inline fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub inline fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub inline fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub inline fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }
    /// Returns `zero` for a zero-length input rather than NaN.
    pub inline fn normalize(a: Vec3) Vec3 {
        const l = a.length();
        return if (l > 0) a.scale(1.0 / l) else zero;
    }
    pub inline fn min(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .z = @min(a.z, b.z) };
    }
    pub inline fn max(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y), .z = @max(a.z, b.z) };
    }
    pub inline fn eql(a: Vec3, b: Vec3) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

/// The storage element of the `.aos4` layout: a `Vec3` padded to sixteen bytes.
/// ---
/// The padding buys alignment, so `toVector` and `fromVector` convert to and
/// from `@Vector(4, f32)` as a bitcast rather than a shuffle. It is storage
/// only: callers still read and write `Vec3` through the accessors. The padding
/// byte for byte also travels the wire in this layout, which is part of what a
/// benchmark comparing layouts is measuring.
pub const Vec3Padded = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32 = 0,

    pub inline fn fromVec3(v: Vec3) Vec3Padded {
        return .{ .x = v.x, .y = v.y, .z = v.z };
    }
    pub inline fn toVec3(v: Vec3Padded) Vec3 {
        return .{ .x = v.x, .y = v.y, .z = v.z };
    }
    pub inline fn toVector(v: Vec3Padded) @Vector(4, f32) {
        return .{ v.x, v.y, v.z, v.w };
    }
    pub inline fn fromVector(v: @Vector(4, f32)) Vec3Padded {
        return .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
    }
};

/// Constructs the vertex stream type for layout `l`.
///
/// Ordinary code uses `Positions`, the instantiation for this build. This
/// function exists so that `bench/` can instantiate all three layouts side by
/// side on the same inputs, and so that a test can pin the properties of a
/// layout the build did not select.
///
/// The returned type is a view over memory rather than a container, mirroring
/// slice semantics: `Mut` is the writable view and `Const` the read-only one,
/// both over the same bytes, and `fromBytes` and `bytes` are casts rather than
/// copies.
pub fn PositionsOf(comptime l: Layout) type {
    return struct {
        pub const Layout_ = l;
        pub const Mut = @This();
        pub const Const = ConstView;

        /// The element the stream is stored as: `Vec3` for `.aos3`,
        /// `Vec3Padded` for `.aos4`, and `f32` for `.soa`, where one slice holds
        /// three planar runs, all x followed by all y followed by all z.
        /// Callers rarely name this type, because the accessors take and return
        /// `Vec3` in every layout.
        pub const Elem = switch (l) {
            .aos3 => Vec3,
            .aos4 => Vec3Padded,
            .soa => f32,
        };
        /// The bytes one vertex occupies, which is twelve for `.aos3` and
        /// `.soa` and sixteen for `.aos4`. This is the figure that relates a
        /// vertex count to a byte count in memory, on the wire and in a blob.
        pub const bytes_per_vertex: u32 = switch (l) {
            .aos3 => 12,
            .aos4 => 16,
            .soa => 12,
        };
        /// The vertex stride to give the GPU for the array-of-structures
        /// layouts. `.soa` instead binds one buffer per component, each of
        /// stride four, which is the only place the renderer switches on the
        /// layout.
        pub const stride: u32 = @sizeOf(Elem);

        data: []Elem,

        /// A stream of no vertices. Useful as an initializer and as the
        /// argument for a structure that currently has no data.
        pub const empty: Mut = .{ .data = &.{} };

        // ---- construction ----

        /// Allocates an uninitialized stream of `n` vertices from `gpa`,
        /// aligned to `blob_alignment`.
        ///
        /// The caller owns the result and releases it with `free` and the same
        /// allocator. The contents are undefined until written, normally with
        /// `setAll` or a loop over `set`.
        pub fn alloc(gpa: std.mem.Allocator, n: u32) std.mem.Allocator.Error!Mut {
            const elems = try gpa.alignedAlloc(Elem, blob_alignment, elemCount(n));
            return .{ .data = elems };
        }
        /// Releases a stream obtained from `alloc`, using the same allocator.
        /// Do not call it on a view produced by `fromBytes` or `fromSlice`,
        /// which do not own their memory.
        pub fn free(self: Mut, gpa: std.mem.Allocator) void {
            gpa.free(@as([]align(blob_alignment.toByteUnits()) Elem, @alignCast(self.data)));
        }
        /// Views existing bytes as a vertex stream, without copying.
        ///
        /// The length must be a multiple of `bytes_per_vertex`, and the bytes
        /// must be aligned for `Elem`. The view is valid for as long as that
        /// memory is, and does not own it. This is how the viewer reads a
        /// stream out of a blob and how a sketch writes into a shared buffer.
        pub fn fromBytes(b: []u8) Mut {
            std.debug.assert(b.len % bytes_per_vertex == 0);
            return .{ .data = std.mem.bytesAsSlice(Elem, @as([]align(@alignOf(Elem)) u8, @alignCast(b))) };
        }
        /// Views a slice the caller already holds as a vertex stream, without
        /// copying. In the array-of-structures layouts that slice is a
        /// `[]Vec3` or `[]Vec3Padded`; in `.soa` it is a `[]f32` whose length
        /// is a multiple of three. The view does not own the slice and is valid
        /// only as long as it is, which makes this the way to send a stack
        /// array or an existing buffer without allocating.
        pub fn fromSlice(elems: []Elem) Mut {
            if (l == .soa) std.debug.assert(elems.len % 3 == 0);
            return .{ .data = elems };
        }
        /// The number of bytes `n` vertices occupy, which is the same figure
        /// in memory, on the wire and in a blob. Use it to size a shared buffer
        /// or to check a payload length.
        pub inline fn byteSize(n: u32) usize {
            return @as(usize, n) * bytes_per_vertex;
        }
        inline fn elemCount(n: u32) usize {
            return if (l == .soa) @as(usize, n) * 3 else n;
        }

        // ---- views ----

        /// Returns the read-only view of the same bytes. Nothing is copied,
        /// and the result is what every function that only reads a stream
        /// takes, including the client's message calls and the kernels.
        pub inline fn toConst(self: Mut) Const {
            return .{ .data = self.data };
        }
        /// The stream as raw bytes. Sending a stream writes these bytes
        /// directly, with no serialization step.
        pub inline fn bytes(self: Mut) []u8 {
            return std.mem.sliceAsBytes(self.data);
        }
        /// The number of vertices in the stream, not the number of elements or
        /// bytes; the three differ in `.soa` and `.aos4`.
        pub inline fn len(self: Mut) u32 {
            return @intCast(if (l == .soa) self.data.len / 3 else self.data.len);
        }

        // ---- accessors (the only way kernels touch vertex data) ----

        /// The vertex at `i` as a `Vec3`, whatever the layout stores. Indices
        /// are vertex indices and are `u32`.
        pub inline fn get(self: Mut, i: u32) Vec3 {
            return self.toConst().get(i);
        }
        pub inline fn x(self: Mut, i: u32) f32 {
            return self.toConst().x(i);
        }
        pub inline fn y(self: Mut, i: u32) f32 {
            return self.toConst().y(i);
        }
        pub inline fn z(self: Mut, i: u32) f32 {
            return self.toConst().z(i);
        }
        /// Writes the vertex at `i`, converting to the stored layout.
        pub inline fn set(self: Mut, i: u32, v: Vec3) void {
            switch (l) {
                .aos3 => self.data[i] = v,
                .aos4 => self.data[i] = .fromVec3(v),
                .soa => {
                    const n = self.data.len / 3;
                    self.data[i] = v.x;
                    self.data[n + i] = v.y;
                    self.data[2 * n + i] = v.z;
                },
            }
        }
        /// Writes the whole stream from a `Vec3` slice, which must have
        /// exactly `len()` elements. Geometry code that computes into a
        /// `[]Vec3` transfers its result with one call.
        pub fn setAll(self: Mut, src: []const Vec3) void {
            std.debug.assert(src.len == self.len());
            for (src, 0..) |v, i| self.set(@intCast(i), v);
        }

        /// The read-only view over a vertex stream. It offers the same
        /// accessors as the mutable view, minus the ones that write, and is what
        /// functions that only read a stream should take.
        const ConstView = struct {
            data: []const Elem,

            pub const empty: Const = .{ .data = &.{} };

            pub fn fromBytes(b: []const u8) Const {
                std.debug.assert(b.len % bytes_per_vertex == 0);
                return .{ .data = std.mem.bytesAsSlice(Elem, @as([]align(@alignOf(Elem)) const u8, @alignCast(b))) };
            }
            pub fn fromSlice(elems: []const Elem) Const {
                if (l == .soa) std.debug.assert(elems.len % 3 == 0);
                return .{ .data = elems };
            }
            pub inline fn bytes(self: Const) []const u8 {
                return std.mem.sliceAsBytes(self.data);
            }
            pub inline fn len(self: Const) u32 {
                return @intCast(if (l == .soa) self.data.len / 3 else self.data.len);
            }
            pub inline fn get(self: Const, i: u32) Vec3 {
                return switch (l) {
                    .aos3 => self.data[i],
                    .aos4 => self.data[i].toVec3(),
                    .soa => .{ .x = self.x(i), .y = self.y(i), .z = self.z(i) },
                };
            }
            pub inline fn x(self: Const, i: u32) f32 {
                return switch (l) {
                    .aos3, .aos4 => self.data[i].x,
                    .soa => self.data[i],
                };
            }
            pub inline fn y(self: Const, i: u32) f32 {
                return switch (l) {
                    .aos3, .aos4 => self.data[i].y,
                    .soa => self.data[self.data.len / 3 + i],
                };
            }
            pub inline fn z(self: Const, i: u32) f32 {
                return switch (l) {
                    .aos3, .aos4 => self.data[i].z,
                    .soa => self.data[2 * (self.data.len / 3) + i],
                };
            }
            /// The x components of every vertex as one contiguous run.
            ///
            /// Only the `.soa` layout stores the stream this way, so this and
            /// its `ys` and `zs` counterparts are available only there and are
            /// reached from inside a compile-time switch on the layout. They
            /// exist so that a kernel written for planar data can take whole
            /// `[]f32` runs rather than reading component by component.
            pub inline fn xs(self: Const) []const f32 {
                comptime std.debug.assert(l == .soa);
                return self.data[0 .. self.data.len / 3];
            }
            pub inline fn ys(self: Const) []const f32 {
                comptime std.debug.assert(l == .soa);
                const n = self.data.len / 3;
                return self.data[n .. 2 * n];
            }
            pub inline fn zs(self: Const) []const f32 {
                comptime std.debug.assert(l == .soa);
                const n = self.data.len / 3;
                return self.data[2 * n ..];
            }
        };
    };
}

/// The vertex stream type this build uses, being `PositionsOf(layout)`.
/// ---
/// A `Positions` value provides a stream of vertex coordinates. Any additional
/// structure, such as connectivity information for segments `[]const [2]u32` or
/// triangles `[]const [3]u32`, or scalar values `[]const f32` attached to the
/// vertices, must be carried alongside it.
/// ---
/// The same representation is used in memory, on the wire and on the GPU, so
/// no destination requires a conversion.
/// ---
/// It is a view rather than a container. `Mut` and `Const` mirror `[]T` and
/// `[]const T`: copying one copies the view and not the data, and the memory
/// belongs to whoever allocated it. `alloc` and `free` cover the common case of
/// owning that memory; `fromBytes` and `fromSlice` wrap memory that already
/// exists, such as a blob, a shared buffer or a stack array.
/// ---
/// The layout in memory is selected at build time and is invisible to callers,
/// who address vertices through `get`, `set`, `x`, `y` and `z`. See `Layout`
/// for the available choices and the reasons they exist.
pub const Positions = PositionsOf(layout);

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;
const all_layouts = [_]Layout{ .aos3, .aos4, .soa };

test "element sizes are exactly the documented strides" {
    try testing.expectEqual(12, @sizeOf(Vec3));
    try testing.expectEqual(16, @sizeOf(Vec3Padded));
    try testing.expectEqual(12, PositionsOf(.aos3).stride);
    try testing.expectEqual(16, PositionsOf(.aos4).stride);
    try testing.expectEqual(4, PositionsOf(.soa).stride);
    inline for (all_layouts) |l| {
        const P = PositionsOf(l);
        try testing.expectEqual(P.byteSize(7), @as(usize, 7) * P.bytes_per_vertex);
    }
}

test "get/set round-trip and bytes/fromBytes are casts in every layout" {
    inline for (all_layouts) |l| {
        const P = PositionsOf(l);
        const n: u32 = 5;
        const p = try P.alloc(testing.allocator, n);
        defer p.free(testing.allocator);
        try testing.expectEqual(n, p.len());
        for (0..n) |i| {
            const f: f32 = @floatFromInt(i);
            p.set(@intCast(i), .init(f, f + 0.5, -f));
        }
        for (0..n) |i| {
            const f: f32 = @floatFromInt(i);
            const v = p.get(@intCast(i));
            try testing.expect(v.eql(.init(f, f + 0.5, -f)));
            try testing.expectEqual(f, p.x(@intCast(i)));
            try testing.expectEqual(f + 0.5, p.y(@intCast(i)));
            try testing.expectEqual(-f, p.z(@intCast(i)));
        }
        // Wire/blob bytes are the same memory.
        const b = p.bytes();
        try testing.expectEqual(P.byteSize(n), b.len);
        try testing.expectEqual(@intFromPtr(p.data.ptr), @intFromPtr(b.ptr));
        const view = P.Const.fromBytes(b);
        try testing.expectEqual(n, view.len());
        try testing.expect(view.get(3).eql(p.get(3)));
        try testing.expectEqual(@intFromPtr(b.ptr), @intFromPtr(view.bytes().ptr));
    }
}

test "soa planar accessors" {
    const P = PositionsOf(.soa);
    const p = try P.alloc(testing.allocator, 3);
    defer p.free(testing.allocator);
    p.setAll(&.{ .init(1, 2, 3), .init(4, 5, 6), .init(7, 8, 9) });
    const c = p.toConst();
    try testing.expectEqualSlices(f32, &.{ 1, 4, 7 }, c.xs());
    try testing.expectEqualSlices(f32, &.{ 2, 5, 8 }, c.ys());
    try testing.expectEqualSlices(f32, &.{ 3, 6, 9 }, c.zs());
}

test "alloc propagates OOM without leaking" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const p = try Positions.alloc(gpa, 16);
            defer p.free(gpa);
        }
    }.run, .{});
}
