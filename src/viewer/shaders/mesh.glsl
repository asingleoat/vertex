// Solid mesh pass. Flat shading from screen-space derivatives of the world
// position (DESIGN.md "Rendering") — no normals or vertex duplication needed.
// Regenerate mesh.zig with `zig build shaders` (sokol-shdc from the dev shell).
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
layout(binding=1) uniform fs_params {
    vec4 color;
    vec4 light_dir; // xyz used
};
in vec3 world_pos;
out vec4 frag_color;
void main() {
    vec3 n = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float ndl = abs(dot(n, normalize(light_dir.xyz)));
    frag_color = vec4(color.rgb * (0.25 + 0.75 * ndl), color.a);
}
@end

@program mesh vs fs
