// Face-target scalar mesh pass for interleaved positions. Values are pulled
// from the quantity blob by primitive index through a readonly storage buffer.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    mat4 model;
};
in vec3 position;
out vec3 world_pos;
void main() {
    vec4 wp = model * vec4(position, 1.0);
    world_pos = wp.xyz;
    gl_Position = mvp * vec4(position, 1.0);
}
@end

@fs fs
struct scalar_item {
    float value;
};
layout(binding=1) readonly buffer face_values {
    scalar_item items[];
};
layout(binding=1) uniform fs_params {
    vec4 color;
    vec4 light_dir;
    vec2 value_range;
};
layout(binding=0) uniform texture2D cmap_tex;
layout(binding=0) uniform sampler cmap_smp;
in vec3 world_pos;
out vec4 frag_color;
// Back faces are tinted toward red. Shading alone cannot distinguish them: the
// normal comes from screen-space derivatives of the world position, which carry
// no winding information, so gl_FrontFacing is the only available signal.
const vec3 back_face_tint = vec3(0.75, 0.18, 0.15);
void main() {
    vec3 n = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float ndl = abs(dot(n, normalize(light_dir.xyz)));
    float scalar_value = items[gl_PrimitiveID].value;
    float t = clamp((scalar_value - value_range.x) / (value_range.y - value_range.x), 0.0, 1.0);
    vec4 mapped = texture(sampler2D(cmap_tex, cmap_smp), vec2(t, 0.5));
    vec3 rgb = color.rgb * mapped.rgb;
    if (!gl_FrontFacing) rgb = mix(rgb, back_face_tint, 0.75);
    frag_color = vec4(rgb * (0.25 + 0.75 * ndl), color.a * mapped.a);
}
@end

@program mesh_face_scalar vs fs
