// Solid mesh pass for the `.soa` vertex layout: the positions blob is three
// planar float runs (all x, all y, all z), bound as three vertex buffers with
// offsets into the same sg.Buffer. Fragment stage identical to mesh.glsl.
// Regenerate mesh_soa.zig with `zig build shaders`.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    mat4 model;
};
in float px;
in float py;
in float pz;
out vec3 world_pos;
void main() {
    vec3 position = vec3(px, py, pz);
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

@program mesh_soa vs fs
