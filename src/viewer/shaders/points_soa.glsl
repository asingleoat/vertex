// Instanced screen-space round point sprites for planar position blobs.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    vec4 viewport_size_point_size_pad;
    vec4 color;
};
in float px;
in float py;
in float pz;
out vec2 uv;
flat out vec4 point_color;
void main() {
    int vertex_id = gl_VertexIndex & 3;
    vec2 corner = vec2((vertex_id & 1) == 0 ? -1.0 : 1.0,
                       (vertex_id & 2) == 0 ? -1.0 : 1.0);
    vec4 clip = mvp * vec4(px, py, pz, 1.0);
    clip.xy += corner * viewport_size_point_size_pad.z /
               viewport_size_point_size_pad.xy * clip.w;
    gl_Position = clip;
    uv = corner;
    point_color = color;
}
@end

@fs fs
in vec2 uv;
flat in vec4 point_color;
out vec4 frag_color;
void main() {
    if (length(uv) > 1.0) discard;
    frag_color = point_color;
}
@end

@program points_soa vs fs
