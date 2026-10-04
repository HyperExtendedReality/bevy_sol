#include "packing.slang"
struct CompositeParams {
    var viewport: uint4;
    var multiplier: float4;
    var camera: float4;
    var camera_direction: float4;
};
[[vk::binding(0, 0)]] ConstantBuffer<CompositeParams> p;
[[vk::binding(1, 0)]] Texture2D<float4> diffuse;
[[vk::binding(2, 0)]] Texture2D<float4> specular;
[[vk::binding(3, 0)]] Texture2D<uint4> gbuffer;
[[vk::binding(4, 0)]] Texture2D<float4> surface_position;
[[vk::binding(5, 0)]] Texture2D<float4> surface_normal;
float3 material_compensation(uint4 g, int2 pixel, float roughness, float3 f0) {
    let n = normalize(surface_normal.Load(int3(pixel, 0)).xyz);
    let world = surface_position.Load(int3(pixel, 0)).xyz;
    var view = normalize(p.camera.xyz-world); if (p.camera.w != 0.0) { view = p.camera_direction.xyz; }
    let smoothness = clamp(1.0-roughness,0.0,1.0); let blend = smoothness*(sqrt(smoothness)+roughness);
    let dominant = normalize(lerp(n,reflect(-view,n),blend));
    let dot_hv = clamp(abs(dot(view,normalize(view+dominant))),0.0,1.0);
    let grazing = pow(1.0-dot_hv,5.0); let fresnel = f0+(float3(1.0)-f0)*grazing;
    return (float3(1.0)-fresnel)*1.05*(1.0-grazing);
}
[shader("vertex")]
float4 vertex(uint index : SV_VertexID) : SV_Position {
    let uv = float2(float((index << 1u) & 2u), float(index & 2u));
    return float4(uv * 2.0 - float2(1.0), 0.0, 1.0);
}
[shader("fragment")]
float4 fragment(float4 position : SV_Position) : SV_Target0 {
    let pixel = int2(position.xy) - int2(p.viewport.xy);
    if (any(pixel < int2(0)) || any(pixel >= int2(p.viewport.zw))) { discard; }
    let g = gbuffer.Load(int3(int2(position.xy), 0));
    let base = pow(unpack4x8unorm(g.x).rgb, float3(2.2));
    let properties = unpack4x8unorm(g.z);
    var compensation = float3(1.0);
    if (p.multiplier.y != 0.0) {
        let f0 = lerp(float3(0.16 * properties.r * properties.r),base,properties.g);
        compensation = material_compensation(g,pixel,unpack4x8unorm(g.x).a,f0);
    }
    let material = base * (1.0 - properties.g) * compensation * properties.b;
    let irradiance=diffuse.Load(int3(pixel,0));
    let confidence=select(p.multiplier.z!=0.0,max(irradiance.w,1.0),1.0);
    let color = irradiance.rgb/confidence * material + specular.Load(int3(pixel, 0)).rgb;
    return float4(color * p.multiplier.x, 0.0);
}
