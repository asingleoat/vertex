// GL-only integer ID pass for instanced interleaved point positions.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    vec4 viewport_size_point_size_pad;
};
in vec3 position;
out vec2 uv;
flat out uint element_id;
void main() {
    int vertex_id = gl_VertexIndex & 3;
    vec2 corner = vec2((vertex_id & 1) == 0 ? -1.0 : 1.0,
                       (vertex_id & 2) == 0 ? -1.0 : 1.0);
    vec4 clip = mvp * vec4(position, 1.0);
    clip.xy += corner * viewport_size_point_size_pad.z /
               viewport_size_point_size_pad.xy * clip.w;
    gl_Position = clip;
    uv = corner;
    element_id = uint(gl_InstanceIndex);
}
@end

@fs fs
// sokol-shdc uniform blocks accept signed int but not uint; this cast restores
// the u32 bit pattern transported through i32.
layout(binding=1) uniform fs_params {
    int structure_id;
};
in vec2 uv;
flat in uint element_id;
out uvec2 frag_id;
void main() {
    if (length(uv) > 1.0) discard;
    frag_id = uvec2(uint(structure_id) + 1u, element_id);
}
@end

@program pick_points vs fs
