// The whole of the Manifold interaction, presented to Zig as one C function.
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
// the result. Replacing Manifold with an implementation written here means
// providing this one function; see "Polygon triangulation and caps" in
// DESIGN.md.
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

// Status codes, mirrored by `Status` in triangulate.zig.
#define VERTEX_TRIANGULATE_OK 0
#define VERTEX_TRIANGULATE_INVALID 1
#define VERTEX_TRIANGULATE_OVERFLOW 2
#define VERTEX_TRIANGULATE_OUT_OF_MEMORY 3

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

}  // extern "C"
