//! Vertex stream layout — STYLE.md §3 "layout is a type".
//!
//! `Positions` is the build-selected stream type. Every consumer goes through
//! its named accessors (`get`/`set`/`x`/`y`/`z`), never through stride
//! arithmetic, so switching `-Dvertex_layout` recompiles all kernels to the
//! new offsets. The wire format, blob storage and GPU strides all derive from
//! this type (`bytes()` / `fromBytes()`), so no layout ever pays a conversion.
const std = @import("std");
const build_options = @import("build_options");

pub const Layout = enum { aos3, aos4, soa };

/// Layout selected by `-Dvertex_layout` (default `.aos3`).
pub const layout: Layout = @field(Layout, @tagName(build_options.vertex_layout));

/// Alignment of every positions blob. Large enough for any `@Vector` load
/// and for future GPU staging (STYLE.md §2).
pub const blob_alignment: std.mem.Alignment = .@"64";

/// Compact 3-vector. Also the value type every accessor speaks, regardless of layout.
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

/// 16-byte element for the `.aos4` layout; converts to/from `@Vector(4, f32)` at zero cost.
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

/// A non-owning view over a vertex stream in layout `l`. Mirrors slice
/// semantics: `Const` is the read-only view, `Mut` (this type) the mutable one.
/// Both are the same bytes; `fromBytes`/`bytes` are casts, not copies.
pub fn PositionsOf(comptime l: Layout) type {
    return struct {
        pub const Layout_ = l;
        pub const Mut = @This();
        pub const Const = ConstView;

        /// Storage element. For `.soa` the stream is three planar `f32` runs
        /// (all x, then all y, then all z) in one slice.
        pub const Elem = switch (l) {
            .aos3 => Vec3,
            .aos4 => Vec3Padded,
            .soa => f32,
        };
        pub const bytes_per_vertex: u32 = switch (l) {
            .aos3 => 12,
            .aos4 => 16,
            .soa => 12,
        };
        /// GPU vertex stride for AoS layouts. `.soa` binds three buffers of stride 4.
        pub const stride: u32 = @sizeOf(Elem);

        data: []Elem,

        pub const empty: Mut = .{ .data = &.{} };

        // ---- construction ----

        /// Allocates a blob-aligned stream of `n` vertices (uninitialized).
        pub fn alloc(gpa: std.mem.Allocator, n: u32) std.mem.Allocator.Error!Mut {
            const elems = try gpa.alignedAlloc(Elem, blob_alignment, elemCount(n));
            return .{ .data = elems };
        }
        pub fn free(self: Mut, gpa: std.mem.Allocator) void {
            gpa.free(@as([]align(blob_alignment.toByteUnits()) Elem, @alignCast(self.data)));
        }
        /// Views existing blob bytes. `bytes.len` must be a multiple of `bytes_per_vertex`.
        pub fn fromBytes(b: []u8) Mut {
            std.debug.assert(b.len % bytes_per_vertex == 0);
            return .{ .data = std.mem.bytesAsSlice(Elem, @as([]align(@alignOf(Elem)) u8, @alignCast(b))) };
        }
        /// Views a caller's element slice (AoS layouts: a `[]Vec3` / `[]Vec3Padded`).
        pub fn fromSlice(elems: []Elem) Mut {
            if (l == .soa) std.debug.assert(elems.len % 3 == 0);
            return .{ .data = elems };
        }
        /// Number of bytes a stream of `n` vertices occupies in memory, on the wire, and in a blob.
        pub inline fn byteSize(n: u32) usize {
            return @as(usize, n) * bytes_per_vertex;
        }
        inline fn elemCount(n: u32) usize {
            return if (l == .soa) @as(usize, n) * 3 else n;
        }

        // ---- views ----

        pub inline fn toConst(self: Mut) Const {
            return .{ .data = self.data };
        }
        /// The stream's bytes — identical in memory, on the wire, and in the blob store.
        pub inline fn bytes(self: Mut) []u8 {
            return std.mem.sliceAsBytes(self.data);
        }
        pub inline fn len(self: Mut) u32 {
            return @intCast(if (l == .soa) self.data.len / 3 else self.data.len);
        }

        // ---- accessors (the only way kernels touch vertex data) ----

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
        /// Copies `n` vertices from a `Vec3` slice (the natural input from geometry code).
        pub fn setAll(self: Mut, src: []const Vec3) void {
            std.debug.assert(src.len == self.len());
            for (src, 0..) |v, i| self.set(@intCast(i), v);
        }

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
            /// Planar component slices — only meaningful for `.soa`; kernels
            /// reach for these inside a `comptime` layout switch.
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

/// The canonical stream type for this build.
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

test "Vec3Padded round-trips through @Vector(4, f32)" {
    const v: Vec3Padded = .fromVec3(.init(1, 2, 3));
    const w = v.toVector();
    try testing.expectEqual(@as(f32, 3), w[2]);
    try testing.expect(Vec3Padded.fromVector(w * @as(@Vector(4, f32), @splat(2))).toVec3().eql(.init(2, 4, 6)));
}

test "Vec3 arithmetic" {
    const a: Vec3 = .init(1, 0, 0);
    const b: Vec3 = .init(0, 1, 0);
    try testing.expect(a.cross(b).eql(.init(0, 0, 1)));
    try testing.expectEqual(@as(f32, 0), a.dot(b));
    try testing.expectEqual(@as(f32, 5), Vec3.init(3, 4, 0).length());
    try testing.expect(Vec3.zero.normalize().eql(Vec3.zero));
    try testing.expect(Vec3.init(0, 0, 4).normalize().eql(.init(0, 0, 1)));
}

test "alloc propagates OOM without leaking" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const p = try Positions.alloc(gpa, 16);
            defer p.free(gpa);
        }
    }.run, .{});
}
