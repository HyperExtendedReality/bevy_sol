#include "radiance_cascade_math.slang"
[[vk::binding(0,0)]] StructuredBuffer<float4> cases;
[[vk::binding(1,0)]] RWStructuredBuffer<float4> results;
[shader("compute")][numthreads(64,1,1)]
void evaluate(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;if(index>=FIXTURE_CASES) {return;}
    let a=cases[index*4u];let b=cases[index*4u+1u];let c=cases[index*4u+2u];let operation=cases[index*4u+3u].x;
    if(operation==0.0) {results[index]=float4(cascade_direction(a.xy),1.0);}
    else if(operation==1.0) {results[index]=float4(cascade_direction_uv(a.xyz),0.0,1.0);}
    else if(operation==2.0) {results[index]=cascade_merge_interval(a,b);}
    else if(operation==3.0) {results[index]=cascade_merge_interval(a,cascade_merge_interval(b,c));}
    else if(operation==4.0) {
        var weight=0.0;let cell=cascade_angular_sample(a.xy,uint(a.z),uint(a.w),weight);
        results[index]=float4(float2(cell),weight,1.0);
    }
    else if(operation==5.0) {
        var weight=0.0;let cell=cascade_spatial_sample(a.xy,uint2(b.xy),uint(a.w),weight);
        results[index]=float4(float2(cell),weight,1.0);
    }
    else {results[index]=float4(cascade_boundary(a.xyz,b.xyz,a.w,c.xyz,b.w),1.0);}
}
