// Scalar-colored solid mesh pass for interleaved position layouts.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    mat4 model;
};
in vec3 position;
in float value;
out vec3 world_pos;
out float scalar_value;
void main() {
    vec4 wp = model * vec4(position, 1.0);
    world_pos = wp.xyz;
    scalar_value = value;
    gl_Position = mvp * vec4(position, 1.0);
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec4 color;
    vec4 light_dir;
    vec2 value_range;
};
layout(binding=0) uniform texture2D cmap_tex;
layout(binding=0) uniform sampler cmap_smp;
in vec3 world_pos;
in float scalar_value;
out vec4 frag_color;
void main() {
    vec3 n = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float ndl = abs(dot(n, normalize(light_dir.xyz)));
    float t = clamp((scalar_value - value_range.x) / (value_range.y - value_range.x), 0.0, 1.0);
    vec4 mapped = texture(sampler2D(cmap_tex, cmap_smp), vec2(t, 0.5));
    frag_color = vec4(color.rgb * mapped.rgb * (0.25 + 0.75 * ndl), color.a * mapped.a);
}
@end

@program mesh_scalar vs fs
