#include "gi.slang"
[[vk::binding(26, 0)]] RWStructuredBuffer<uint> checks;
[shader("compute")][numthreads(1,1,1)]
void read_motion_reprojection_test() {
    let position=float3(0.3,-0.2,-3.0);
    let uv=reproject_motion(position,p.sky.xy);
    checks[0]=asuint(uv.x);checks[1]=asuint(uv.y);
}
[shader("compute")][numthreads(1,1,1)]
void seed_probe_sampling_test() {
    work[27].store(1u);work[probe_fresh_list()].store(0u);probes[0].info.x=0u;
    probes[0].info.y=16u+12u*p.viewport.z;probes[0].position=float4(0.0,0.0,0.5,1.0);
    probes[0].normal=float4(0.0,0.0,1.0,0.1);
    previous_probes[0].position=probes[0].position;previous_probes[0].normal=probes[0].normal;
    for(var tile=0u;tile<probe_cache_count();tile++) {work[probe_cache_heads()+tile].store(MISSING);}
    for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {
        previous_probes[0].samples[bin]=probe_pack(float4(float(bin%7u)+0.125,float(bin%3u),0.5,1e9));
    }
    if(p.sky.w!=0.0) {
        probes[0].info.x=MISSING;
        let tile=2u+p.screen.x;work[probe_cache_heads()+tile].store(0u);
        for(var slot=0u;slot<2u;slot++) {
            probe_cache[slot].next=select(slot==0u,1u,MISSING);
            probe_cache[slot].probe.position=probes[0].position;probe_cache[slot].probe.normal=probes[0].normal;
            for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {
                probe_cache[slot].probe.samples[bin]=probe_pack(float4(float3(2.0+4.0*float(slot)),1e9));
            }
        }
    }
}
[shader("compute")][numthreads(64,1,1)]
void read_probe_merge_test(uint bin : SV_GroupIndex) {
    let value=probe_unpack(probes[0].samples[bin]);
    for(var channel=0u;channel<4u;channel++) {checks[4u*bin+channel]=asuint(value[channel]);}
}
[shader("compute")][numthreads(64,1,1)]
void read_probe_sampling_test(uint lane : SV_GroupIndex) {
    let view=normalize(float3(p.sky.x,0.0,1.0));
    let s=Surface(float3(0.0),float3(0.0,0.0,1.0),float3(0.5),p.sky.y,p.sky.z,0.5,1.0,true,float3(0,0,1));
    var rng=hash32(lane+73u);var energy=0.0;var rejected=0u;
    for(var i=0u;i<2048u;i++) {
        let sampled=probe_sample_direction(0u,i%PROBE_DIRECTIONS,s,rng);
        energy+=2.0*max(sampled.z,0.0)*sampled.w/2048.0;rejected+=uint(sampled.w==0.0);
    }
    checks[lane]=asuint(energy);checks[64u+lane]=rejected;
    let cdf=probes[0].filtered_samples[lane];checks[128u+lane]=asuint(probe_guide_pdf(0u,lane));
    if(lane<63u) {checks[192u+lane]=cdf.x;}
    if(lane==0u) {
        let dot_hv=dot(view,normalize(view+ggx_specular_direction(s.normal,view,s.roughness)));
        checks[255]=asuint(brdf_specular_probability(float3(0.04),dot_hv,float3(0.5)));
    }
}
[shader("compute")][numthreads(1,1,1)]
void seed_probe_cache_test() {
    let active=select(p.frame.x==5u,0u,select(p.frame.x<3u,select(p.frame.x==2u,5u,4u),10u));
    work[0].store(active);
    for(var i=0u;i<p.scene_info.z;i++) {
        probes[i].position=float4(0.0);probes[i].info=uint4(MISSING);
        if(i>=active) {continue;}
        let position_index=select(p.frame.x==2u&&i==4u,0u,i);
        probes[i].position=float4(float(position_index)*0.05,0.0,select(p.frame.x<3u,0.5,0.8),1.0);
        probes[i].normal=float4(0.0,0.0,1.0,0.1);
        probes[i].info=uint4(MISSING,16u+12u*p.viewport.z,MISSING,0u);
        probes[i].irradiance=float4(1.0);probes[i].filtered_irradiance=float4(1.0);
        for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {
            probes[i].samples[bin]=probe_pack(float4(1.0,1.0,1.0,1e9));
            probes[i].filtered_samples[bin]=probes[i].samples[bin];
        }
        for(var j=0u;j<9u;j++) {probes[i].sh[j]=uint2(0u);probes[i].filtered_sh[j]=uint2(0u);}
        work[WORK_HEADER+i].store(i);
    }
}
[shader("compute")][numthreads(1,1,1)]
void read_probe_cache_test() {
    checks[64]=work[probe_cache_work()].load();var valid=0u;var updated=0u;var reused=0u;
    for(var i=0u;i<probe_cache_count();i++) {
        valid+=uint(probe_cache[i].valid!=0u);updated+=uint(probe_cache[i].valid!=0u&&probe_cache[i].last_used==p.frame.x);
        checks[68u+i]=work[probe_cache_lru()+i].load();
    }
    for(var i=0u;i<p.scene_info.z;i++) {
        checks[80u+i]=probes[i].info.z;checks[104u+i]=probes[i].info.x;
        reused+=uint(probes[i].position.w!=0.0&&probes[i].info.x!=MISSING);
    }
    checks[65]=valid;checks[66]=updated;checks[67]=reused;
}
[shader("compute")][numthreads(1,1,1)]
void seed_probe_scan_test() {
    let touched=(probe_cache_count()+2u)/3u;work[probe_cache_work()].store(touched);
    for(var rank=0u;rank<probe_cache_count();rank++) {probe_cache[rank].available.store(uint(rank%3u!=0u));}
    for(var rank=0u;rank<touched;rank++) {work[probe_cache_mru()+rank].store(3u*(touched-rank-1u));}
}
[shader("compute")][numthreads(1,1,1)]
void read_probe_scan_test() {
    checks[0]=work[probe_cache_work()].load();checks[1]=work[probe_cache_work()+1u].load();
    for(var rank=0u;rank<probe_cache_count();rank++) {checks[16u+rank]=work[probe_cache_lru()+rank].load();}
}
[shader("compute")][numthreads(1,1,1)]
void read_probe_schedule_test() {
    var fresh=0u;
    for(var y=0u;y<p.screen.y;y++) {for(var x=0u;x<p.screen.x;x++) {
        let selected=uint(probe_should_refresh(uint2(x,y)));fresh+=selected;
        checks[16u+x+y*p.screen.x]=selected;
    }}
    checks[0]=fresh;
    let halton=probe_halton_sequence(p.frame.x);checks[1]=asuint(halton.x);checks[2]=asuint(halton.y);
}
[shader("compute")][numthreads(1,1,1)]
void seed_hash_test() {
    work[3].store(0u);
    let desc = hash_tile_descriptor(float3(-0.25, 0.5, 0.125), float3(1.0, 0.0, 0.0), 1.0);
    checks[0] = desc.bucket; checks[1] = desc.tag; checks[2] = desc.offset.x; checks[3] = desc.offset.y;
    let inputs = uint[3](0u, 123u, 0xffffffffu);
    for (var i = 0u; i < 3u; i++) { checks[4u+i] = pcg_hash(inputs[i]); checks[7u+i] = xx_hash(inputs[i]); }
    for (var i = 0u; i < 4u; i++) {
        let position = float3(0.01, 0.01 + float(i % 2u) * 0.06, 0.01 + float(i / 2u) * 0.06);
        checks[10u+i] = hash_tile_insert(position, float3(1.0, 0.0, 0.0), 1.0);
    }
    let packed = hash_pack(float4(1.0, 2.0, 3.0, 0.5)); checks[30] = packed.x; checks[31] = packed.y;
    let sanitized=gi_denoiser_sanitize(float4(asfloat(0x7fc00000u|p.frame.x),2.0,-1.0,0.0));
    var history=float4(0.0);var corner=float4(0.0);
    for(var i=0u;i<64u+p.frame.x;i++) {
        history=gi_denoiser_accumulate(history,float4(1.0),float2(0.5),1.0);
        corner=gi_denoiser_accumulate(corner,float4(1.0),float2(0.0),1.0);
    }
    let changing=gi_denoiser_accumulate(float4(32.0),float4(10.0,10.0,10.0,1.0),float2(0.5),0.0);
    for(var i=0u;i<4u;i++) {checks[32u+i]=asuint(sanitized[i]);checks[36u+i]=asuint(history[i]);checks[40u+i]=asuint(corner[i]);checks[44u+i]=asuint(changing[i]);}
    var moments=float4(0.0);var roundtrip_error=0.0;var length_error=0.0;
    for(var y=0u;y<256u;y++) {for(var x=0u;x<256u;x++) {
        let uv=(float2(x,y)+0.5)/256.0;let d=probe_hemi_octahedron(uv);
        moments+=float4(d.z,d.z*d.z,d.x*d.x,d.y*d.y)/65536.0;
        roundtrip_error=max(roundtrip_error,length(uv-probe_hemi_octahedron_inverse(d)));
        length_error=max(length_error,abs(length(d)-1.0));
    }}
    for(var i=0u;i<4u;i++) {checks[48u+i]=asuint(moments[i]);}
    checks[52]=asuint(roundtrip_error);checks[53]=asuint(length_error);
    var frame_error=0.0;let normals=float3[4](float3(1.0,0.0,0.0),float3(0.0,1.0,0.0),float3(0.0,0.0,1.0),normalize(float3(1.0,2.0,3.0)));
    for(var i=0u;i<4u;i++) {
        let frame=probe_frame(normals[i]);let direction=mul(frame,probe_hemi_octahedron(float2(0.125,0.875)));
        frame_error=max(frame_error,abs(length(direction)-1.0));
        frame_error=max(frame_error,length(mul(frame,float3(0.0,0.0,1.0))-normals[i]));
        frame_error=max(frame_error,length(probe_hemi_octahedron_inverse(mul(transpose(frame),direction))-float2(0.125,0.875)));
    }
    checks[54]=asuint(frame_error);
    let packed_probe=probe_pack(float4(1.0,2.0,3.0,-1.0));checks[55]=packed_probe.x;checks[56]=packed_probe.y;
    let packed_sh=probe_pack_sh(float4(-1.0,2.0,-3.0,0.5));checks[128]=packed_sh.x;checks[129]=packed_sh.y;
    let blend_current=float3[5](float3(0),float3(0.2),float3(2.0),float3(4.0),float3(100.0));
    for(uint i=0u;i<5u;i++) {checks[144u+i]=asuint(probe_shadow_preserving_blend(blend_current[i],float3(1.0)).x);}
    checks[149]=asuint(probe_interpolation_weight(10.0,10.0,0.0,1.0,1.0));
    checks[150]=asuint(probe_interpolation_weight(10.0,11.0,0.0,1.0,1.0));
    checks[151]=asuint(probe_interpolation_weight(10.0,10.0,0.0,1.0,0.5));
    checks[152]=asuint(probe_interpolation_weight(10.0,10.0,1.01,1.0,1.0));
    checks[153]=asuint(probe_interpolation_weight(10.0,10.0,0.0,1.0,-0.5));
    checks[154]=asuint(probe_interpolation_weight(10.0,20.0,0.0,1.0,1.0));
    let light_samples=float2[4](float2(0.0,0.0),float2(0.25,0.5),float2(1.0,0.5),float2(0.36,1.0));
    for(var i=0u;i<4u;i++) {
        let bary=area_light_barycentrics(light_samples[i]);
        let point=area_light_position(float3(1,2,3),float3(5,2,3),float3(1,8,3),bary);
        checks[132u+3u*i]=asuint(bary.x);checks[133u+3u*i]=asuint(bary.y);checks[134u+3u*i]=asuint(point.x+point.y+point.z);
    }
    let packed_nonfinite=probe_pack(float4(asfloat(0x7fc00000u|p.frame.x),2.0,3.0,asfloat(0x7f800000u)));
    checks[62]=packed_nonfinite.x;checks[63]=packed_nonfinite.y;
    for(var i=0u;i<12u;i++) {work[probe_mask_offset(0u)+i].store(MISSING);}
    work[probe_mask_offset(0u)+2u].store(17u);work[probe_mask_offset(0u)+11u].store(23u);
}
[shader("compute")][numthreads(4,1,1)]
void accumulate_hash_test(uint lane : SV_GroupIndex) {
    let amount = p.frame.x == 2u ? 3.0 : float(lane + 1u);
    hash_accumulate(checks[10u + lane], float3(amount, amount * 2.0, amount * 3.0), false);
    if (lane == 0u && p.frame.x == 1u) { hash_accumulate(checks[10], float3(5.0, 10.0, 15.0), true); }
}
[shader("compute")][numthreads(1,1,1)]
void read_hash_test() {
    let cell = checks[10]; let direct = hash_filtered(cell, false); let indirect = hash_filtered(cell, true);
    for (var i = 0u; i < 4u; i++) { checks[16u+i] = asuint(direct[i]); checks[20u+i] = asuint(indirect[i]); }
    let mip0 = hash_read(cell, false);
    for (var i = 0u; i < 4u; i++) { checks[24u+i] = asuint(mip0[i]); }
    checks[28] = hash_tile_find(float3(0.01), float3(1.0, 0.0, 0.0), 1.0);
    checks[29] = work[3].load();
    checks[57]=find_closest_probe(uint2(16u,0u),int2(0));
    checks[58]=find_closest_probe(uint2(24u,8u),int2(0));
    checks[59]=find_closest_probe(uint2(0u,16u),int2(0));
    checks[60]=find_closest_probe(uint2(24u,16u),int2(0));
    checks[61]=find_closest_probe(uint2(16u,0u),int2(1,0));
}
[shader("compute")][numthreads(1,1,1)]
void read_hash_hole_test() {
    let desc=hash_tile_descriptor(float3(0.01),float3(1,0,0),1.0);
    let first=desc.bucket*p.hash_config.y;
    hash_tiles[hash_tile_meta(first)].store(0u);
    hash_tiles[hash_tile_meta(first+1u)].store(desc.tag);
    checks[0]=hash_tile_find(float3(0.01),float3(1,0,0),1.0);
    checks[1]=hash_cell_index(first+1u,desc.offset,0u);
}
[shader("compute")][numthreads(64,1,1)]
void concurrent_hash_claim_test(uint lane:SV_GroupIndex) {
    let desc=hash_tile_descriptor(float3(0.01),float3(1,0,0),1.0);
    let first=desc.bucket*p.hash_config.y;
    if(lane==0u) {
        work[3].store(0u);
        for(var tile=first;tile<first+p.hash_config.y;tile++) {
            for(var i=0u;i<4u;i++) {hash_tiles[hash_tile_meta(tile)+i].store(0u);}
        }
    }
    GroupMemoryBarrierWithGroupSync();
    checks[4u+lane]=hash_tile_insert(float3(0.01),float3(1,0,0),1.0);
    GroupMemoryBarrierWithGroupSync();
    if(lane==0u) {checks[0]=work[3].load();checks[1]=hash_cell_index(first,desc.offset,0u);}
}
