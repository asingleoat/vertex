// GL-only integer ID pass. Instances are derived interleaved p0.xyz/p1.xyz.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    vec4 viewport_size_line_width_pad;
};
in vec3 p0;
in vec3 p1;
flat out uint element_id;
void main() {
    vec4 a = mvp * vec4(p0, 1.0);
    vec4 b = mvp * vec4(p1, 1.0);
    if (a.w <= 0.0 || b.w <= 0.0) {
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        element_id = uint(gl_InstanceIndex);
        return;
    }
    int vertex_id = gl_VertexIndex & 3;
    bool at_end = vertex_id >= 2;
    float side = (vertex_id & 1) == 0 ? -1.0 : 1.0;
    vec2 tangent_px = (b.xy / b.w - a.xy / a.w) * viewport_size_line_width_pad.xy;
    float tangent_length = length(tangent_px);
    vec2 perpendicular = tangent_length > 1.0e-6
        ? vec2(-tangent_px.y, tangent_px.x) / tangent_length
        : vec2(0.0, 1.0);
    vec4 clip = at_end ? b : a;
    clip.xy += side * perpendicular * viewport_size_line_width_pad.z /
               viewport_size_line_width_pad.xy * clip.w;
    gl_Position = clip;
    element_id = uint(gl_InstanceIndex);
}
@end

@fs fs
// sokol-shdc uniform blocks accept signed int but not uint; this cast restores
// the u32 bit pattern transported through i32.
layout(binding=1) uniform fs_params {
    int structure_id;
};
flat in uint element_id;
out uvec2 frag_id;
void main() {
    frag_id = uvec2(uint(structure_id) + 1u, element_id);
}
@end

@program pick_lines vs fs
