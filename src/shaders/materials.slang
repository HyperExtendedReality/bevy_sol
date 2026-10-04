#if GI_TEXTURED
[[vk::binding(0, 1)]] Texture2D<float4> material_images[64];
[[vk::binding(1, 1)]] SamplerState material_samplers[64];
float4 material_texture_lod(uint index,float2 uv,float level) {
    if (index == 0u) { return float4(1.0); }
    let descriptor = NonUniformResourceIndex(index - 1u);
    return material_images[descriptor].SampleLevel(material_samplers[descriptor], uv, level);
}
float2 material_texture_size(uint index) {
    if(index==0u) {return float2(1.0);}
    var width=0u;var height=0u;material_images[NonUniformResourceIndex(index-1u)].GetDimensions(width,height);
    return float2(width,height);
}
#else
float4 material_texture_lod(uint index,float2 uv,float level) {return float4(1.0);}
float2 material_texture_size(uint index) {return float2(1.0);}
#endif
float4 material_texture(uint index,float2 uv) {return material_texture_lod(index,uv,0.0);}
// evaluateAreaLightConeAM: ray-cone projection from Ray Tracing Gems ch. 20.
float area_light_cone_lod(float3 source,float3 hit,float3 a,float3 b,float3 c,float2 uv0,float2 uv1,float2 uv2,float2 texels,float solid_angle) {
    if(solid_angle<=0.0) {return 0.0;}
    let area_normal=cross(b-a,c-a);let twice_area=length(area_normal);let offset=source-hit;let distance=length(offset);
    let edge0=uv1-uv0;let edge1=uv2-uv0;let uv_area=texels.x*texels.y*abs(edge0.x*edge1.y-edge1.x*edge0.y);
    if(twice_area<=0.0||uv_area<=0.0||distance<=0.0) {return 0.0;}
    let cosine=abs(dot(offset/distance,area_normal/twice_area));
    let width=min(0.5*twice_area,solid_angle*distance);
    return 0.5*log2(uv_area/twice_area)+log2(max(width/max(cosine,1e-20),1e-20));
}
