// GL-only integer ID pass for interleaved mesh positions.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};
in vec3 position;
void main() {
    gl_Position = mvp * vec4(position, 1.0);
}
@end

@fs fs
// sokol-shdc uniform blocks accept signed int but not uint. The CPU transports
// the u32 bit pattern through i32 and this cast restores it for the uvec2 ID.
layout(binding=1) uniform fs_params {
    int structure_id;
};
out uvec2 frag_id;
void main() {
    frag_id = uvec2(uint(structure_id) + 1u, uint(gl_PrimitiveID));
}
@end

@program pick_mesh vs fs
