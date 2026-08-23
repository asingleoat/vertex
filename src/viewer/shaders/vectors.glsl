// Instanced arrows. Base/direction instances are interleaved derived data,
// independent of the source Positions layout.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    vec4 scale_factor_pad;
    vec4 color;
};
in vec3 unit_position;
in vec3 base;
in vec3 dir;
out vec3 world_pos;
flat out vec4 arrow_color;
void main() {
    float dir_length = length(dir);
    vec3 z_axis = dir_length > 1.0e-8 ? dir / dir_length : vec3(0.0, 0.0, 1.0);
    vec3 up = abs(z_axis.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 x_axis = normalize(cross(up, z_axis));
    vec3 y_axis = cross(z_axis, x_axis);
    float arrow_length = clamp(dir_length * scale_factor_pad.x, 0.0, 1.0e4);
    float thickness = clamp(dir_length * scale_factor_pad.x, 0.0, 1.0e3);
    vec3 local = vec3(unit_position.xy * thickness, unit_position.z * arrow_length);
    world_pos = base + x_axis * local.x + y_axis * local.y + z_axis * local.z;
    gl_Position = mvp * vec4(world_pos, 1.0);
    arrow_color = color;
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec4 light_dir;
};
in vec3 world_pos;
flat in vec4 arrow_color;
out vec4 frag_color;
void main() {
    vec3 n = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float ndl = abs(dot(n, normalize(light_dir.xyz)));
    frag_color = vec4(arrow_color.rgb * (0.25 + 0.75 * ndl), arrow_color.a);
}
@end

@program vectors vs fs
