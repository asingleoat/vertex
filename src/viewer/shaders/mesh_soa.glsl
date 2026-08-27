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
// Back faces are tinted toward red. Shading alone cannot distinguish them: the
// normal comes from screen-space derivatives of the world position, which carry
// no winding information, so gl_FrontFacing is the only available signal.
const vec3 back_face_tint = vec3(0.75, 0.18, 0.15);
void main() {
    vec3 n = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float ndl = abs(dot(n, normalize(light_dir.xyz)));
    vec3 rgb = color.rgb;
    if (!gl_FrontFacing) rgb = mix(rgb, back_face_tint, 0.75);
    frag_color = vec4(rgb * (0.25 + 0.75 * ndl), color.a);
}
@end

@program mesh_soa vs fs
