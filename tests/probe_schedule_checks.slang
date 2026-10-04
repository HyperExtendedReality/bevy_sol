#include "gi.slang"
[[vk::binding(26,0)]] RWStructuredBuffer<uint> checks;
[shader("compute")][numthreads(64,1,1)]
void seed_previous_schedule(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;if(index>=probe_cache_count()) {return;}
    let tile=uint2(index%p.screen.x,index/p.screen.x);
    let pixel=min(tile*p.screen.z+p.screen.z/2u,p.viewport.zw-1u);let s=surface(pixel);
    previous_probes[index].position=float4(s.position,float(index!=p.options.w));
    previous_probes[index].normal=float4(s.normal,footprint(s,pixel));
    previous_probes[index].irradiance=float4(2,2,2,8);
    previous_probes[index].info=uint4(MISSING,pixel.x+pixel.y*p.viewport.z,MISSING,MISSING);
    for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {previous_probes[index].samples[bin]=probe_pack(float4(2,2,2,10));}
    for(var bin=0u;bin<9u;bin++) {previous_probes[index].sh[bin]=probe_pack_sh(float4(1,1,1,PROBE_DIRECTIONS));}
}
[shader("compute")][numthreads(64,1,1)]
void read_schedule(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;if(index>=probe_cache_count()) {return;}
    if(index==0u) {
        checks[0]=work[0].load();checks[1]=work[27].load();
        for(var i=0u;i<3u;i++) {checks[2u+i]=work[probe_patch_work()+i].load();}
        let q=probe_quantize(float4(0.00016,1.23456,2.34564,17.34567));
        for(var i=0u;i<4u;i++) {checks[8u+i]=q[i];}
        let blended=probe_shadow_preserving_blend(float4(8,8,8,10),float4(1,1,1,2));
        for(var i=0u;i<4u;i++) {checks[12u+i]=asuint(blended[i]);}
        let brdf=multibounce_brdf(float3(0.5),0.5,float3(0,0,1),float3(0,0,1),float3(0,0,1));
        let packed=float4(unpack2x16float(pack2x16float(brdf.xy)),unpack2x16float(pack2x16float(brdf.zw)));
        checks[16]=asuint(multibounce_radiance(float3(1),packed,0.0).x);
        checks[17]=asuint(multibounce_radiance(float3(1),packed,0.7).x);
        checks[18]=asuint(multibounce_radiance(float3(1),packed,1.0).x);
    }
    checks[32u+4u*index]=uint(probes[index].position.w!=0.0);
    checks[33u+4u*index]=uint(probes[index].info.w!=MISSING);
    checks[34u+4u*index]=probes[index].info.y;
    checks[35u+4u*index]=probes[index].info.x;
}
[shader("compute")][numthreads(64,1,1)]
void seed_source_sampling_checks(uint lane:SV_GroupIndex) {
    if(lane>=PROBE_DIRECTIONS) {return;}
    probes[0].samples[lane]=probe_pack(float4(1,1,1,10));
    probes[0].filtered_samples[lane]=uint2(asuint(select(lane>=3u,1.0,0.0)),asuint(1.0));
}
[shader("compute")][numthreads(64,1,1)]
void read_source_sampling_checks(uint lane:SV_GroupIndex) {
    let bin=lane%PROBE_DIRECTIONS;
    var rng=pcg_hash(lane+17u);
    let mirror=Surface(float3(0),float3(0,0,1),float3(0),0.01,0.0,0.5,1.0,true);
    let specular=probe_sample_direction(0u,bin,mirror,rng);
    checks[256u+lane]=asuint(specular.z);
    let diffuse=Surface(float3(0),float3(0,0,1),float3(1),1.0,0.0,0.0,1.0,true);
    let sampled=probe_sample_direction(0u,bin,diffuse,rng);
    checks[320u+lane]=direction_bin(diffuse.normal,sampled.xyz);
    checks[384u+lane]=asuint(sampled.w);
}
[shader("compute")][numthreads(64,1,1)]
void seed_source_cache_merge(uint lane:SV_GroupIndex) {
    if(lane<probe_cache_count()) {
        work[probe_cache_heads()+lane].store(MISSING);
        previous_probes[probe_reprojected_history()+lane].position.w=0.0;
    }
    if(lane==0u) {
        work[27].store(1u);work[probe_fresh_list()].store(0u);
        work[probe_cache_heads()].store(0u);probe_cache[0].next=MISSING;
        probes[0].position=float4(0,0,0.5,1);probes[0].normal=float4(0,0,1,0.1);
        // The claimed nearest cache is not a separate source history input.
        probes[0].info.x=p.scene_info.z;probes[0].info.y=0u;
        probe_cache[0].probe.position=probes[0].position;probe_cache[0].probe.normal=probes[0].normal;
    }
    if(lane<PROBE_DIRECTIONS) {probe_cache[0].probe.samples[lane]=probe_pack(float4(6,6,6,10));}
}
[shader("compute")][numthreads(64,1,1)]
void read_source_cache_merge(uint lane:SV_GroupIndex) {
    if(lane<PROBE_DIRECTIONS) {checks[448u+lane]=asuint(probe_unpack(probes[0].samples[lane]).x);}
}
