// GL-only integer ID pass for planar mesh positions.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};
in float px;
in float py;
in float pz;
void main() {
    gl_Position = mvp * vec4(px, py, pz, 1.0);
}
@end

@fs fs
// sokol-shdc uniform blocks accept signed int but not uint; this cast restores
// the u32 bit pattern transported through i32.
layout(binding=1) uniform fs_params {
    int structure_id;
};
out uvec2 frag_id;
void main() {
    frag_id = uvec2(uint(structure_id) + 1u, uint(gl_PrimitiveID));
}
@end

@program pick_mesh_soa vs fs
