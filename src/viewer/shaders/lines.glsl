// Instanced thick segments. Endpoint instances are derived render-edge data:
// interleaved p0.xyz/p1.xyz regardless of the source Positions layout.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    vec4 viewport_size_line_width_pad;
    vec4 color;
};
in vec3 p0;
in vec3 p1;
flat out vec4 line_color;
void main() {
    vec4 a = mvp * vec4(p0, 1.0);
    vec4 b = mvp * vec4(p1, 1.0);
    if (a.w <= 0.0 || b.w <= 0.0) {
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        line_color = color;
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
    line_color = color;
}
@end

@fs fs
flat in vec4 line_color;
out vec4 frag_color;
void main() {
    frag_color = line_color;
}
@end

@program lines vs fs
