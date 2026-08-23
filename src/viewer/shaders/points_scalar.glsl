// Instanced scalar-colored point sprites for interleaved positions.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    vec4 viewport_size_point_size_pad;
    vec4 color;
};
in vec3 position;
in float value;
out vec2 uv;
flat out float scalar_value;
flat out vec4 point_color;
void main() {
    int vertex_id = gl_VertexIndex & 3;
    vec2 corner = vec2((vertex_id & 1) == 0 ? -1.0 : 1.0,
                       (vertex_id & 2) == 0 ? -1.0 : 1.0);
    vec4 clip = mvp * vec4(position, 1.0);
    clip.xy += corner * viewport_size_point_size_pad.z /
               viewport_size_point_size_pad.xy * clip.w;
    gl_Position = clip;
    uv = corner;
    scalar_value = value;
    point_color = color;
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec2 value_range;
};
layout(binding=0) uniform texture2D cmap_tex;
layout(binding=0) uniform sampler cmap_smp;
in vec2 uv;
flat in float scalar_value;
flat in vec4 point_color;
out vec4 frag_color;
void main() {
    if (length(uv) > 1.0) discard;
    float t = clamp((scalar_value - value_range.x) / (value_range.y - value_range.x), 0.0, 1.0);
    frag_color = point_color * texture(sampler2D(cmap_tex, cmap_smp), vec2(t, 0.5));
}
@end

@program points_scalar vs fs
