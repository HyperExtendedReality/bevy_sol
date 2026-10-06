#include "gi.slang"
[[vk::binding(26, 0)]] RWStructuredBuffer<uint> checks;
// Pinned ScreenProbes_QuantizeRadiance, retained independently for the GPU's
// out-of-range float-to-uint behavior (including half infinity).
uint4 reference_quantize(float4 radiance) {return uint4(round(1e4f*radiance));}
[shader("compute")][numthreads(1,1,1)]
void read_probe_half_test() {
    let radiance=probe_pack(p.sky);let sh=probe_pack_sh(p.sky);
    checks[0]=radiance.x;checks[1]=radiance.y;checks[2]=sh.x;checks[3]=sh.y;
    probes[0].samples[0]=probe_pack_sample(p.sky.xyz);
}
[shader("compute")][numthreads(1,1,1)]
void read_probe_half_direction_test() {
    var direction=p.sky.xyz;
    if(source_probe_projection()) {direction=probe_unpack_sample(probes[0].samples[0]);}
    for(var i=0u;i<3u;i++) {checks[4u+i]=asuint(direction[i]);}
}
[shader("compute")][numthreads(64,1,1)]
void read_probe_spawn_half_test(uint local:SV_GroupIndex) {
    var value=select(local==0u,p.sky,float4(float(local)));
    if(source_probe_projection()) {value=float4(asfloat(probe_pack(value)),0.0,0.0);}
    probe_resolve_radiance[local]=value;
    GroupMemoryBarrierWithGroupSync();
    if(local==1u) {
        let decoded=resolved_probe_radiance(local-1u);
        for(var i=0u;i<4u;i++) {checks[8u+i]=asuint(decoded[i]);}
    }
}
[shader("compute")][numthreads(1,1,1)]
void read_source_ray_setup_test() {
    let position=p.sky.xyz;let normal=float3(0.25,-0.5,1.0);
    let origin=offset_ray_position(position,normal);
    let directional=source_light_shadow_ray(position,normal,LightSample(float3(0,0,1),1e9,float3(1),float4(0,0,1,0)));
    let positional=source_light_shadow_ray(position,normal,LightSample(float3(0,0,1),5,float3(1),float4(4,-3,2,1)));
    for(var i=0u;i<3u;i++) {checks[i]=asuint(origin[i]);checks[8u+i]=asuint(positional.direction[i]);checks[12u+i]=asuint(directional.direction[i]);}
    checks[3]=asuint(ray_min_distance());checks[4]=asuint(gi_max_distance());
    checks[5]=asuint(positional.range.x);checks[6]=asuint(positional.range.y);checks[7]=asuint(directional.range.y);
    let input=float4(1.2345,2.5678,4.125,asfloat(0x7f800000u));
    let quantized=probe_quantize(input);let reference=reference_quantize(input);
    for(var i=0u;i<4u;i++) {checks[16u+i]=quantized[i];checks[20u+i]=reference[i];}
}
[shader("compute")][numthreads(1,1,1)]
void seed_source_filter_test() {
    work[0].store(3u);
    for(var i=0u;i<15u;i++) {work[probe_mask_offset(0u)+i].store(MISSING);}
    work[probe_mask_offset(0u)+5u].store(0u);work[probe_mask_offset(0u)+6u].store(1u);work[probe_mask_offset(0u)+9u].store(2u);
    for(var index=0u;index<3u;index++) {
        work[WORK_HEADER+index].store(index);
        probes[index].position=float4(0,0,-10,1);probes[index].normal=float4(0,0,1,1);
        let seed=uint2(8u+uint(index==1u)*8u,8u+uint(index==2u)*8u);
        probes[index].info=uint4(MISSING,seed.x+seed.y*p.viewport.z,MISSING,0u);
        let distances=float2[5](float2(asfloat(0x7f800000u)),float2(0),float2(0,2),float2(2,0),float2(2));
        for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {probes[index].samples[bin]=probe_pack(float4(float3(1+2*index),distances[p.frame.x][min(index,1u)]));}
    }
}
[shader("compute")][numthreads(1,1,1)]
void read_source_filter_test() {
    let value=probe_unpack(probes[0].filtered_samples[0]);
    let final=probe_unpack(probes[0].samples[0]);
    for(var c=0u;c<4u;c++) {checks[c]=asuint(value[c]);checks[4u+c]=asuint(final[c]);}
}
[shader("compute")][numthreads(64,1,1)]
void read_source_sky_predicates_test(uint lane:SV_GroupIndex) {
    for(var c=0u;c<4u;c++) {probe_reuse_values[4u*lane+c]=0u;}
    probe_reuse_counts[lane]=0u;GroupMemoryBarrierWithGroupSync();
    probe_reuse_reconnect(0u,lane,float3(0,0,-10),float3(0,0,1),float3(0,0,-10),float3(0,0,1),
        probe_pack(float4(3,3,3,1e9)),p.sky.w!=0.0);
    GroupMemoryBarrierWithGroupSync();
    if(lane==0u) {
        var count=0u;for(var i=0u;i<PROBE_DIRECTIONS;i++) {count+=probe_reuse_counts[i];}
        checks[0]=count;
        checks[1]=uint(probe_reuse_hemisphere_allowed(asfloat(0x7fc00000u|p.frame.x),p.sky.w!=0.0));
        checks[2]=uint(probe_reuse_hemisphere_allowed(0.0,p.sky.w!=0.0));
        checks[3]=uint(probe_reuse_hemisphere_allowed(-0.5,p.sky.w!=0.0));
        checks[4]=uint(probe_reuse_hemisphere_allowed(0.5,p.sky.w!=0.0));
    }
}
[shader("compute")][numthreads(1,1,1)]
void seed_source_sky_history_test() {
    for(var index=0u;index<p.scene_info.z;index++) {probes[index].position=float4(0);probes[index].info=uint4(MISSING);}
    probes[0].position=float4(0,0,-10,1);probes[0].normal=float4(0,0,1,1);probes[0].info.x=0u;
    previous_probes[0].position=probes[0].position;previous_probes[0].normal=probes[0].normal;
    for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {previous_probes[0].samples[bin]=probe_pack(float4(3,3,3,1e9));}
}
[shader("compute")][numthreads(1,1,1)]
void read_source_sky_history_test() {
    let value=probe_unpack(probes[0].samples[0]);
    for(var c=0u;c<4u;c++) {checks[c]=asuint(value[c]);}
}
[shader("compute")][numthreads(1,1,1)]
void read_material_f0_test() {
    let base=float3(0.125,0.5,0.875);
    for(var r=0u;r<3u;r++) {
        for(var m=0u;m<3u;m++) {
            let value=material_f0(base,float(m)*0.5,float(r)*0.5,p.restir.w);
            for(var c=0u;c<3u;c++) {checks[9u*r+3u*m+c]=asuint(value[c]);}
        }
        let bounce=multibounce_brdf(base,float(r)*0.5,float3(0,0,1),float3(0,0,1),float3(0,0,1));
        for(var c=0u;c<4u;c++) {checks[32u+4u*r+c]=asuint(bounce[c]);}
    }
}
[shader("compute")][numthreads(1,1,1)]
void read_source_roughness_test() {
    let roughness=float[6](0.0,0.0001,0.01,0.0316227766,0.1,1.0);
    for(var i=0u;i<6u;i++) {
        let alpha=max(roughness[i]*roughness[i],1e-6);
        let a2=max(alpha*alpha,1e-6);
        checks[2u*i]=asuint(specular_brdf(float3(0,0,1),float3(0,0,1),float3(0,0,1),float3(0.04),roughness[i]).x);
        checks[2u*i+1u]=asuint(ggx_bounded_pdf(alpha,a2,1.0,float3(0,0,1)));
    }
    let views=float3[3](float3(1,0,0),float3(0.8660254038,0,-0.5),float3(0,0,-1));
    let lights=float3[3](float3(0,0,1),float3(0,0,1),float3(0,0,-1));
    for(var i=0u;i<3u;i++) {checks[16u+i]=asuint(specular_brdf(float3(0,0,1),views[i],lights[i],float3(0.04),1.0).x);}
    checks[19]=asuint(ggx_bounded_pdf(1.0,1.0,1.0,float3(0,0,-1)));
}
[shader("compute")][numthreads(1,1,1)]
void read_specular_override_test() {
    let base=float3(0.125,0.5,0.875);
    checks[0]=restir_pack_material(base);
    let decoded=restir_material_base(checks[0]);
    let compensation=diffuse_compensation(float3(0.1,0.4,0.9),0.5);
    let brdf=multibounce_brdf(base,1.0,float3(0,0,1),float3(0,0,1),float3(0,0,1));
    let albedo=primary_material_albedo(base,1.0,p.restir.w);
    let f0=primary_material_f0(base,1.0,1.0,p.restir.w);
    let specular=specular_brdf(float3(0,0,1),float3(0,0,1),float3(0,0,1),base,0.1);
    for(var i=0u;i<3u;i++) {
        checks[1u+i]=asuint(decoded[i]);checks[4u+i]=asuint(compensation[i]);
        checks[7u+i]=asuint(brdf[i]);checks[10u+i]=asuint(albedo[i]);
        checks[13u+i]=asuint(f0[i]);checks[16u+i]=asuint(specular[i]);
    }
    checks[19]=asuint(brdf_specular_probability(base,0.5,float3(0.0)));
    // No reused cells: the source retains this cell's stratification.
    probes[0].filtered_samples[0]=uint2(0u);probes[0].samples[0]=uint2(0u);
    let surface=Surface(float3(0.0),float3(0,0,1),base,0.1,1.0,1.0,1.0,true,float3(0,0,1));
    var rng=73u;let direction=probe_sample_direction(0u,0u,surface,rng);
    checks[20]=rng;checks[21]=asuint(direction.w);
    let sample=sample_specular_view(surface,73u,float3(0,0,1));
    checks[22]=asuint(length(sample.weight));
}
[shader("compute")][numthreads(1,1,1)]
void read_source_diffuse_normal_test() {
    for(var i=0u;i<9u;i++) {probes[0].filtered_sh[i]=probe_pack_sh(float4(0.0));}
    probes[0].filtered_sh[3]=probe_pack_sh(float4(-1.0,-2.0,-4.0,1.0));
    let receiver=Surface(float3(0.0),float3(1,0,0),float3(0.5),1.0,0.0,0.5,1.0,true,float3(0,0,1));
    let interpolation=ProbeInterpolation(uint4(0u,MISSING,MISSING,MISSING),float4(1,0,0,0),1.0);
    let value=source_diffuse_interpolation(interpolation,surface_shading_normal(receiver),1.0,float3(0.0));
    for(var i=0u;i<4u;i++) {checks[i]=asuint(value[i]);}
}
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
[shader("compute")][numthreads(1,1,1)]
void read_bent_cone_test() {
    for (var index=0u;index<2u;index++) {
        for (var j=0u;j<9u;j++) {
            probes[index].filtered_sh[j]=probe_pack_sh(float4(float3(1,2,4)*float((index+1u)*(j+1u))*0.125,1));
        }
    }
    ProbeInterpolation interpolation;
    interpolation.indices=uint4(0u,1u,MISSING,MISSING);
    interpolation.weights=float4(0.25,0.75,0,0);interpolation.hint=0;
    let value=source_diffuse_interpolation(interpolation,normalize(p.sky.xyz),p.sky.w,float3(0.2,0.4,0.8));
    interpolation.indices=uint4(MISSING);interpolation.weights=float4(0);interpolation.hint=1;
    let missing=source_diffuse_interpolation(interpolation,float3(0,0,1),1,float3(100));
    for (var i=0u;i<4u;i++) {checks[i]=asuint(value[i]);checks[4u+i]=asuint(missing[i]);}
}
