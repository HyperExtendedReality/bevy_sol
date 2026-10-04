#include "gi.slang"
[shader("compute")][numthreads(64,1,1)]
void check_blue_noise(uint3 gid : SV_DispatchThreadID) {
    var result=float4(0.0);
    for(var channel=0u;channel<4u;channel++) {
        let sample=4u*gid.x+channel;
        let pixel=uint2((sample*73u)%131u,((sample*97u)/131u)%137u);
        let frame=select(sample%3u==0u,256u,sample*17u);
        result[channel]=blue_noise_value(1024u,pixel,frame,sample%256u);
    }
    reflections[gid.x]=result;
}
[shader("compute")][numthreads(64,1,1)]
void check_reflection_sampling_frame(uint3 gid : SV_DispatchThreadID) {
    let i=gid.x;
    let normals=float3[8](float3(0,0,1),float3(1,0,0),float3(0,1,0),float3(0,0,-1),
        normalize(float3(0.001,0,-1)),normalize(float3(-1,2,3)),normalize(float3(1,-3,0)),normalize(float3(1,2,-3)));
    let normal=normals[i%8u];let rotation=ggx_rotation_to_z(normal);
    let vector=normalize(float3(float(i%13u)-6.0,2.0,3.0));
    let local=ggx_rotate(rotation,vector);
    let restored=ggx_rotate(float4(-rotation.xyz,rotation.w),local);
    let z=ggx_rotate(rotation,normal);
    let samples=float2(blue_noise_value(1024u,uint2(i%131u,i/131u),i*17u,2u),
        blue_noise_value(1024u,uint2(i%131u,i/131u),i*17u,3u));
    reflections[i]=float4(reflection_cache_jitter(normal,2.0,samples),
        max(length(restored-vector),length(z-float3(0,0,1))));
}
