// Use packed conversion intrinsics without requiring native 16-bit arithmetic.
uint pack2x16float(float2 v) { return packHalf2x16(v); }
float2 unpack2x16float(uint v) { return unpackHalf2x16ToFloat(v); }
float4 unpack4x8unorm(uint v) { return unpackUnorm4x8ToFloat(v); }
bool source_albedo_textures_disabled(uint flags) {return (flags&5u)==5u;}
float3 primary_material_albedo(float3 base,float metallic,uint flags) {
    return select(source_albedo_textures_disabled(flags),float3(0.3),base*(1.0-metallic));
}
float3 primary_material_f0(float3 base,float metallic,float reflectance,uint flags) {
    return select(source_albedo_textures_disabled(flags),float3(0.0),lerp(float3(0.16*reflectance*reflectance),base,metallic));
}
