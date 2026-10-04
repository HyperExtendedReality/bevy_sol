#include "gi.slang"
[[vk::binding(26,0)]] RWStructuredBuffer<float4> environment_checks;
static const float3 CHECK_DIRECTIONS[14]={
    float3(1,0,0),float3(-1,0,0),float3(0,1,0),float3(0,-1,0),float3(0,0,1),float3(0,0,-1),
    float3(1,0.4,-0.3),float3(-1,0.4,-0.3),float3(0.3,1,-0.4),float3(0.3,-1,-0.4),
    float3(0.3,0.4,1),float3(0.3,0.4,-1),float3(0.2,0.6,1),float3(-0.2,-0.6,1)
};
[shader("compute")][numthreads(64,1,1)]
void check_environment(uint3 gid:SV_DispatchThreadID) {
    if(gid.x<14u) {
        environment_checks[gid.x]=float4(environment_radiance(normalize(CHECK_DIRECTIONS[gid.x])),1.0);
    }
    var rng=hash32(gid.x+937u);
    let uv=(float2(gid.x&511u,gid.x>>9u)+float2(random(rng),random(rng)))/512.0;
    let sample=sample_environment(p.camera.xyz,uv);
    let value=environment_radiance(sample.xyz)*max(dot(p.camera.xyz,sample.xyz),0.0)/(PI*sample.w);
    let evaluated=environment_pdf(p.camera.xyz,sample.xyz);
    environment_checks[14u+gid.x]=float4(value,abs(sample.w-evaluated)/max(sample.w,1e-20));
}
