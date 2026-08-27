// The whole of the Manifold interaction, presented to Zig as plain C functions.
//
// Two properties of manifoldc make a shim necessary rather than convenient.
// `manifold_triangulate` is not exception-safe: `manifold::Triangulate`
// rethrows `geometryErr` on invalid input and the C binding wraps it in no
// handler, so an exception would otherwise unwind across the C ABI. And every
// manifoldc object is placement-constructed into caller memory and must be
// destructed before that memory is released, which is an ownership shape with
// no Zig equivalent. Both are confined here.
//
// The interface is plain data: coordinates in, indices out, a status code for
// the result. Each operation stands alone, so replacing Manifold with an
// implementation written here is done one function at a time; see "Polygon
// triangulation and caps" in DESIGN.md.
#include <manifold/manifoldc.h>
#include <manifold/types.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>

static_assert(sizeof(ManifoldVec2) == 2 * sizeof(double),
              "a flat array of doubles is passed as ManifoldVec2");
static_assert(sizeof(int) == sizeof(uint32_t),
              "triangle indices are copied from int without conversion");

extern "C" {

// Status codes, mirrored by the seam modules that call these.
#define VERTEX_TRIANGULATE_OK 0
#define VERTEX_TRIANGULATE_INVALID 1
#define VERTEX_TRIANGULATE_OVERFLOW 2
#define VERTEX_TRIANGULATE_OUT_OF_MEMORY 3

#define VERTEX_BOOLEAN_OK 0
#define VERTEX_BOOLEAN_THREW 1
#define VERTEX_BOOLEAN_OUT_OF_MEMORY 2
// The operation completed but Manifold rejected an input or the result;
// `detail` then carries the ManifoldError.
#define VERTEX_BOOLEAN_REJECTED 3
// The result carries something other than three properties per vertex, which
// this shim does not know how to hand back.
#define VERTEX_BOOLEAN_UNEXPECTED_PROPERTIES 4

#define VERTEX_OFFSET_OK 0
#define VERTEX_OFFSET_THREW 1
#define VERTEX_OFFSET_OUT_OF_MEMORY 2

// Triangulates one simple polygon.
//
// `xy` holds `point_count` points as consecutive x, y pairs, in order around
// the polygon and winding counter-clockwise. `epsilon` is passed to Manifold
// unchanged, where a negative value selects its own tolerance. At most
// `capacity` triangles are written to `triangles` as vertex indices into the
// point array, and the number written is stored in `written`.
//
// A simple polygon of n points triangulates to exactly n - 2 triangles, so a
// caller sizing `capacity` that way never sees VERTEX_TRIANGULATE_OVERFLOW.
// Fewer than three points is not an error and writes nothing.
int vertexTriangulatePolygon(const double *xy, size_t point_count,
                             double epsilon, uint32_t *triangles,
                             size_t capacity, size_t *written) {
  *written = 0;
  if (point_count < 3) return VERTEX_TRIANGULATE_OK;

  void *polygon_mem = std::malloc(manifold_simple_polygon_size());
  void *polygons_mem = std::malloc(manifold_polygons_size());
  void *triangulation_mem = std::malloc(manifold_triangulation_size());
  if (polygon_mem == nullptr || polygons_mem == nullptr ||
      triangulation_mem == nullptr) {
    std::free(polygon_mem);
    std::free(polygons_mem);
    std::free(triangulation_mem);
    return VERTEX_TRIANGULATE_OUT_OF_MEMORY;
  }

  ManifoldSimplePolygon *polygon = nullptr;
  ManifoldPolygons *polygons = nullptr;
  ManifoldTriangulation *triangulation = nullptr;
  int status = VERTEX_TRIANGULATE_OK;

  try {
    // The cast drops const only because manifoldc takes a mutable pointer; the
    // points are copied into Manifold's own storage and are not written back.
    ManifoldVec2 *points =
        reinterpret_cast<ManifoldVec2 *>(const_cast<double *>(xy));
    polygon = manifold_simple_polygon(polygon_mem, points, point_count);
    ManifoldSimplePolygon *one[1] = {polygon};
    polygons = manifold_polygons(polygons_mem, one, 1);
    triangulation = manifold_triangulate(triangulation_mem, polygons, epsilon);

    const size_t count = manifold_triangulation_num_tri(triangulation);
    if (count > capacity) {
      status = VERTEX_TRIANGULATE_OVERFLOW;
    } else if (count != 0) {
      // Writes 3 * count ints into the caller's buffer and returns it.
      manifold_triangulation_tri_verts(triangles, triangulation);
      *written = count;
    }
  } catch (...) {
    status = VERTEX_TRIANGULATE_INVALID;
    *written = 0;
  }

  if (triangulation != nullptr) manifold_destruct_triangulation(triangulation);
  if (polygons != nullptr) manifold_destruct_polygons(polygons);
  if (polygon != nullptr) manifold_destruct_simple_polygon(polygon);
  std::free(triangulation_mem);
  std::free(polygons_mem);
  std::free(polygon_mem);
  return status;
}

// One boolean result, held between `vertexBooleanBegin` reporting its size and
// `vertexBooleanTake` copying it out. Manifold sizes the result only by
// computing it, so a caller cannot allocate ahead the way it can for a
// polygon's triangulation.
struct VertexBooleanResult {
  void *meshgl_mem;
  ManifoldMeshGL *meshgl;
};

// Frees everything a `VertexBooleanResult` holds. Safe on a null handle.
void vertexBooleanRelease(void *handle) {
  if (handle == nullptr) return;
  VertexBooleanResult *result = static_cast<VertexBooleanResult *>(handle);
  if (result->meshgl != nullptr) manifold_destruct_meshgl(result->meshgl);
  std::free(result->meshgl_mem);
  std::free(result);
}

// Copies the result into caller memory: `vert_count * 3` floats and
// `tri_count * 3` indices, both as reported by `vertexBooleanBegin`.
void vertexBooleanTake(void *handle, float *vertices, uint32_t *triangles) {
  VertexBooleanResult *result = static_cast<VertexBooleanResult *>(handle);
  manifold_meshgl_vert_properties(vertices, result->meshgl);
  manifold_meshgl_tri_verts(triangles, result->meshgl);
}

// Runs one boolean and reports the size of its result.
//
// Both inputs are meshes of `Vec3` vertices and `[3]u32` triangles, which is
// MeshGL's own layout at three properties per vertex, so nothing is converted
// on the way in. `op` is a `ManifoldOpType`. On success `*handle` owns the
// result until `vertexBooleanTake` and `vertexBooleanRelease`; on any other
// status it is null and nothing is owned.
//
// Manifold requires each input to be a closed, oriented surface and says so
// through `manifold_status` rather than by throwing, which is why the status is
// read for both inputs and for the result. The try/catch remains for everything
// that does throw: the C binding wraps none of these calls.
int vertexBooleanBegin(const float *a_vertices, size_t a_vertex_count,
                       const uint32_t *a_triangles, size_t a_triangle_count,
                       const float *b_vertices, size_t b_vertex_count,
                       const uint32_t *b_triangles, size_t b_triangle_count,
                       int op, void **handle, size_t *vertex_count,
                       size_t *triangle_count, int *detail) {
  *handle = nullptr;
  *vertex_count = 0;
  *triangle_count = 0;
  *detail = MANIFOLD_NO_ERROR;

  const size_t meshgl_size = manifold_meshgl_size();
  const size_t manifold_size = manifold_manifold_size();
  void *a_mesh_mem = std::malloc(meshgl_size);
  void *b_mesh_mem = std::malloc(meshgl_size);
  void *a_solid_mem = std::malloc(manifold_size);
  void *b_solid_mem = std::malloc(manifold_size);
  void *out_solid_mem = std::malloc(manifold_size);
  VertexBooleanResult *result =
      static_cast<VertexBooleanResult *>(std::malloc(sizeof(VertexBooleanResult)));
  void *out_mesh_mem = std::malloc(meshgl_size);

  ManifoldMeshGL *a_mesh = nullptr;
  ManifoldMeshGL *b_mesh = nullptr;
  ManifoldManifold *a_solid = nullptr;
  ManifoldManifold *b_solid = nullptr;
  ManifoldManifold *out_solid = nullptr;
  ManifoldMeshGL *out_mesh = nullptr;
  int status = VERTEX_BOOLEAN_OK;

  if (a_mesh_mem == nullptr || b_mesh_mem == nullptr || a_solid_mem == nullptr ||
      b_solid_mem == nullptr || out_solid_mem == nullptr || result == nullptr ||
      out_mesh_mem == nullptr) {
    status = VERTEX_BOOLEAN_OUT_OF_MEMORY;
  } else {
    try {
      a_mesh = manifold_meshgl(a_mesh_mem, const_cast<float *>(a_vertices),
                               a_vertex_count, 3,
                               const_cast<uint32_t *>(a_triangles), a_triangle_count);
      b_mesh = manifold_meshgl(b_mesh_mem, const_cast<float *>(b_vertices),
                               b_vertex_count, 3,
                               const_cast<uint32_t *>(b_triangles), b_triangle_count);
      a_solid = manifold_of_meshgl(a_solid_mem, a_mesh);
      b_solid = manifold_of_meshgl(b_solid_mem, b_mesh);

      ManifoldError a_status = manifold_status(a_solid);
      ManifoldError b_status = manifold_status(b_solid);
      if (a_status != MANIFOLD_NO_ERROR || b_status != MANIFOLD_NO_ERROR) {
        status = VERTEX_BOOLEAN_REJECTED;
        *detail = a_status != MANIFOLD_NO_ERROR ? a_status : b_status;
      } else {
        out_solid = manifold_boolean(out_solid_mem, a_solid, b_solid,
                                     static_cast<ManifoldOpType>(op));
        ManifoldError out_status = manifold_status(out_solid);
        if (out_status != MANIFOLD_NO_ERROR) {
          status = VERTEX_BOOLEAN_REJECTED;
          *detail = out_status;
        } else {
          out_mesh = manifold_get_meshgl(out_mesh_mem, out_solid);
          if (manifold_meshgl_num_prop(out_mesh) != 3) {
            status = VERTEX_BOOLEAN_UNEXPECTED_PROPERTIES;
          } else {
            *vertex_count = manifold_meshgl_num_vert(out_mesh);
            *triangle_count = manifold_meshgl_num_tri(out_mesh);
          }
        }
      }
    } catch (...) {
      status = VERTEX_BOOLEAN_THREW;
    }
  }

  // The inputs and the intermediate solids are done with either way; only the
  // result mesh outlives this call, and only on success.
  if (out_solid != nullptr) manifold_destruct_manifold(out_solid);
  if (b_solid != nullptr) manifold_destruct_manifold(b_solid);
  if (a_solid != nullptr) manifold_destruct_manifold(a_solid);
  if (b_mesh != nullptr) manifold_destruct_meshgl(b_mesh);
  if (a_mesh != nullptr) manifold_destruct_meshgl(a_mesh);
  std::free(out_solid_mem);
  std::free(b_solid_mem);
  std::free(a_solid_mem);
  std::free(b_mesh_mem);
  std::free(a_mesh_mem);

  if (status == VERTEX_BOOLEAN_OK) {
    result->meshgl_mem = out_mesh_mem;
    result->meshgl = out_mesh;
    *handle = result;
  } else {
    if (out_mesh != nullptr) manifold_destruct_meshgl(out_mesh);
    std::free(out_mesh_mem);
    std::free(result);
  }
  return status;
}

// One offset result, held between `vertexOffsetBegin` reporting its size and
// `vertexOffsetTake` copying it out. Offsetting may split one ring into several
// or merge several into one, so neither count is known until it has run.
struct VertexOffsetResult {
  void *polygons_mem;
  ManifoldPolygons *polygons;
};

// Frees everything a `VertexOffsetResult` holds. Safe on a null handle.
void vertexOffsetRelease(void *handle) {
  if (handle == nullptr) return;
  VertexOffsetResult *result = static_cast<VertexOffsetResult *>(handle);
  if (result->polygons != nullptr) manifold_destruct_polygons(result->polygons);
  std::free(result->polygons_mem);
  std::free(result);
}

// Copies the result out: `point_count * 2` doubles as consecutive x, y pairs,
// and `loop_count` lengths saying how those points divide into rings.
void vertexOffsetTake(void *handle, double *xy, uint32_t *loop_lengths) {
  VertexOffsetResult *result = static_cast<VertexOffsetResult *>(handle);
  const size_t loops = manifold_polygons_length(result->polygons);
  size_t written = 0;
  for (size_t i = 0; i < loops; ++i) {
    const size_t length = manifold_polygons_simple_length(result->polygons, i);
    loop_lengths[i] = static_cast<uint32_t>(length);
    for (size_t j = 0; j < length; ++j) {
      ManifoldVec2 point = manifold_polygons_get_point(result->polygons, i, j);
      xy[2 * written] = point.x;
      xy[2 * written + 1] = point.y;
      ++written;
    }
  }
}

// Offsets a set of closed rings and reports the size of the result.
//
// `xy` holds the rings end to end as consecutive x, y pairs, divided by
// `loop_lengths`. `delta` is the distance to move the boundary, outward when
// positive. `join`, `miter_limit` and `circular_segments` are Clipper2's, and
// mean what they mean there: how a convex corner is filled, how far a miter may
// run before it is cut, and how finely a round join is approximated.
//
// The rings are taken under the non-zero fill rule, so a clockwise ring inside a
// counter-clockwise one is a hole rather than a second island.
int vertexOffsetBegin(const double *xy, const uint32_t *loop_lengths,
                      size_t loop_count, double delta, int join,
                      double miter_limit, int circular_segments, void **handle,
                      size_t *point_count, size_t *out_loop_count) {
  *handle = nullptr;
  *point_count = 0;
  *out_loop_count = 0;

  void *polygons_mem = std::malloc(manifold_polygons_size());
  void *section_mem = std::malloc(manifold_cross_section_size());
  void *offset_mem = std::malloc(manifold_cross_section_size());
  void *out_polygons_mem = std::malloc(manifold_polygons_size());
  VertexOffsetResult *result =
      static_cast<VertexOffsetResult *>(std::malloc(sizeof(VertexOffsetResult)));
  ManifoldSimplePolygon **rings = static_cast<ManifoldSimplePolygon **>(
      std::malloc(loop_count * sizeof(ManifoldSimplePolygon *)));
  void *rings_mem = std::malloc(loop_count * manifold_simple_polygon_size());

  if (polygons_mem == nullptr || section_mem == nullptr || offset_mem == nullptr ||
      out_polygons_mem == nullptr || result == nullptr || rings == nullptr ||
      rings_mem == nullptr) {
    std::free(polygons_mem);
    std::free(section_mem);
    std::free(offset_mem);
    std::free(out_polygons_mem);
    std::free(result);
    std::free(rings);
    std::free(rings_mem);
    return VERTEX_OFFSET_OUT_OF_MEMORY;
  }

  size_t built = 0;
  ManifoldPolygons *polygons = nullptr;
  ManifoldCrossSection *section = nullptr;
  ManifoldCrossSection *offset = nullptr;
  ManifoldPolygons *out_polygons = nullptr;
  int status = VERTEX_OFFSET_OK;

  try {
    const double *cursor = xy;
    const size_t ring_size = manifold_simple_polygon_size();
    for (size_t i = 0; i < loop_count; ++i) {
      void *slot = static_cast<char *>(rings_mem) + i * ring_size;
      rings[i] = manifold_simple_polygon(
          slot, reinterpret_cast<ManifoldVec2 *>(const_cast<double *>(cursor)),
          loop_lengths[i]);
      cursor += 2 * loop_lengths[i];
      ++built;
    }
    polygons = manifold_polygons(polygons_mem, rings, loop_count);
    section = manifold_cross_section_of_polygons(section_mem, polygons,
                                                 MANIFOLD_FILL_RULE_NON_ZERO);
    offset = manifold_cross_section_offset(offset_mem, section, delta,
                                           static_cast<ManifoldJoinType>(join),
                                           miter_limit, circular_segments);
    out_polygons = manifold_cross_section_to_polygons(out_polygons_mem, offset);

    const size_t loops = manifold_polygons_length(out_polygons);
    size_t points = 0;
    for (size_t i = 0; i < loops; ++i) {
      points += manifold_polygons_simple_length(out_polygons, i);
    }
    *out_loop_count = loops;
    *point_count = points;
  } catch (...) {
    status = VERTEX_OFFSET_THREW;
  }

  if (offset != nullptr) manifold_destruct_cross_section(offset);
  if (section != nullptr) manifold_destruct_cross_section(section);
  if (polygons != nullptr) manifold_destruct_polygons(polygons);
  for (size_t i = 0; i < built; ++i) manifold_destruct_simple_polygon(rings[i]);
  std::free(rings_mem);
  std::free(rings);
  std::free(offset_mem);
  std::free(section_mem);
  std::free(polygons_mem);

  if (status == VERTEX_OFFSET_OK) {
    result->polygons_mem = out_polygons_mem;
    result->polygons = out_polygons;
    *handle = result;
  } else {
    if (out_polygons != nullptr) manifold_destruct_polygons(out_polygons);
    std::free(out_polygons_mem);
    std::free(result);
  }
  return status;
}

}  // extern "C"
