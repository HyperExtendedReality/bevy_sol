#include "gi.slang"
[shader("compute")][numthreads(8,8,1)]
void seed_source_marking_samples(uint3 gid:SV_DispatchThreadID) {
    if(any(gid.xy>=reflection_size())) {return;}
    let index=gid.x+gid.y*reflection_size().x;
    let value=float(index%5u)*0.25;
    reflection_store_sample(0u,gid.xy,float4(value,value,value,select(index%11u==0u,-1.0,1.0)));
    reflections[reflection_sample_index(3u,gid.xy)]=float4(0.0);
}
[shader("compute")][numthreads(1,1,1)]
void read_source_marking_flags() {
    let size=reflection_size();
    for(var y=0u;y<size.y;y++) {for(var x=0u;x<size.x;x++) {
        checks[788u+x+y*size.x]=uint(reflections[reflection_sample_index(3u,uint2(x,y))].x);
    }}
}
[shader("compute")][numthreads(1,1,1)]
void seed_source_reflection_storage() {
    reflection_store_sample(0u,uint2(0),reflection_trace_result(float3(2.0,asfloat(0x7fc00000u),4.0),65519.0));
    reflection_store_sample(1u,uint2(0),float4(1.0006,-0.333,10.004,1.0));
    reflection_store_sample(2u,uint2(0),float4(0.12345,0.23456,0.34567,-1.0));
    reflection_store_sample(3u,uint2(0),reflection_encode_sample(float4(1.0006,-0.333,10.004,1.0),false));
    let rounded=float4(1.0006,-0.333,10.004,7.003);
    for(var layer=4u;layer<8u;layer++) {reflection_store_sample(layer,uint2(0),rounded);}
    for(var layer=0u;layer<3u;layer++) {reflection_store_full(layer,uint2(0),rounded);}
    reflection_store_full(3u,uint2(0),float4(0.0));
    for(var layer=0u;layer<2u;layer++) {reflection_store_split(layer,uint2(0),rounded);}
}
[shader("compute")][numthreads(1,1,1)]
void read_source_cleanup_rules() {
    checks[700]=uint(reflection_cleanup_radius(3,2u,true));
    checks[701]=uint(reflection_cleanup_radius(3,2u,false));
    checks[702]=asuint(reflection_cleanup_weight(int2(3,2),3,2u,true));
    checks[703]=asuint(reflection_cleanup_weight(int2(3,2),3,2u,false));
    let center=float4(0.5,0.25,0.75,-1);
    let fallback=source_reflection_cleanup_resolve(float4(0.0005,0.0005,0,0),0.0005,center);
    let accepted=source_reflection_cleanup_resolve(float4(0.001,0.0005,0.0015,0.004),0.002,center);
    for(var i=0u;i<4u;i++) {checks[704u+i]=asuint(fallback[i]);checks[708u+i]=asuint(accepted[i]);}
    let temporal=reflection_temporal_result(float4(2.0,asfloat(0x7fc00000u),4.0,7.0));
    for(var i=0u;i<4u;i++) {checks[715u+i]=asuint(temporal[i]);}
    checks[719]=uint(source_direct_lighting_enabled(1u));
    checks[720]=uint(source_direct_lighting_enabled(3u));
    checks[721]=uint(source_direct_lighting_enabled(0u));
    checks[722]=uint(source_direct_lighting_enabled(2u));
    checks[723]=asuint(reflection_miss_distance(1u));
    checks[724]=asuint(reflection_miss_distance(3u));
    checks[725]=asuint(reflection_miss_distance(0u));
    for(var layer=0u;layer<3u;layer++) {
        let value=reflection_load_sample(layer,uint2(0));
        for(var channel=0u;channel<4u;channel++) {checks[726u+layer*4u+channel]=asuint(value[channel]);}
    }
    let unrounded=reflection_load_sample(3u,uint2(0));
    for(var channel=0u;channel<4u;channel++) {checks[738u+channel]=asuint(unrounded[channel]);}
    for(var layer=4u;layer<8u;layer++) {
        let value=reflection_load_sample(layer,uint2(0));
        for(var channel=0u;channel<4u;channel++) {checks[742u+(layer-4u)*4u+channel]=asuint(value[channel]);}
    }
    for(var layer=0u;layer<4u;layer++) {
        let value=reflection_load_full(layer,uint2(0));
        for(var channel=0u;channel<4u;channel++) {checks[758u+layer*4u+channel]=asuint(value[channel]);}
    }
    for(var layer=0u;layer<2u;layer++) {
        let value=reflection_load_split(layer,uint2(0));
        for(var channel=0u;channel<4u;channel++) {checks[774u+layer*4u+channel]=asuint(value[channel]);}
    }
    checks[782]=asuint(reflection_atrous_weight(int2(3,2),4,true));
    checks[783]=asuint(reflection_atrous_weight(int2(3,2),4,false));
    checks[784]=uint(reflection_normalizes_weight(0.0005,true,true));
    checks[785]=uint(reflection_normalizes_weight(0.0005,false,true));
    checks[786]=uint(reflection_normalizes_weight(0.0005,true,false));
    checks[787]=uint(reflection_normalizes_weight(0.0,true,true));
}
[shader("compute")][numthreads(1,1,1)]
void seed_source_reflection_history() {
    if(any(p.viewport.zw<uint2(8,3))) {return;}
    for(var y=0u;y<3u;y++) {for(var x=0u;x<8u;x++) {
        let normal=select(x==1u && y==0u,float3(0,0,-1),float3(0,0,1));
        output_normal[uint2(x,y)]=float4(normal,0.0);
        reflection_store_full(3u,uint2(x,y),float4(float(1u+2u*y*2u+2u*(x%4u)),0,0,4));
    }}
}
[shader("compute")][numthreads(1,1,1)]
void read_source_reflection_history() {
    if(any(p.viewport.zw<uint2(8,3))) {return;}
    var s=Surface();s.normal=float3(0,0,1);s.position=float3(0,0,-1);s.roughness=1.0;
    let mixed=source_reflection_previous(s,float2(0.6,1.4)/float2(p.viewport.zw));
    let fallback=source_reflection_previous(s,float2(4.6,1.4)/float2(p.viewport.zw));
    let border=source_reflection_previous(s,float2(-0.1,-0.1));
    s.position.z=-1.2;
    let rejected=source_reflection_previous(s,float2(0.6,1.4)/float2(p.viewport.zw));
    checks[694]=asuint(mixed.x);checks[695]=asuint(mixed.w);
    checks[696]=asuint(fallback.x);checks[697]=asuint(fallback.w);
    checks[698]=asuint(border.x);checks[699]=asuint(rejected.w);
}
[shader("compute")][numthreads(1,1,1)]
void seed_primary_normal_history() {work[primary_normal_address(uint2(0))].store(primary_pack_geometry_normal(float3(0,-1,0),true));}
[shader("compute")][numthreads(1,1,1)]
void read_source_feedback_rules() {
    checks[685]=work[previous_primary_normal_address(uint2(0))].load();
    let normal=float3(0,0,1);let moderate=float3(sqrt(0.4375),0,0.75);
    checks[686]=uint(source_feedback_compatible(normal,moderate,10.0,10.4,false));
    checks[687]=uint(source_feedback_compatible(normal,moderate,10.0,10.4,true));
    checks[688]=uint(source_feedback_compatible(normal,float3(sqrt(0.75),0,0.5),10.0,10.0,false));
    checks[689]=uint(source_feedback_compatible(normal,normal,10.0,10.5,false));
    checks[690]=uint(source_feedback_compatible(normal,normal,10.0,10.09,true));
    checks[691]=uint(source_feedback_compatible(normal,normal,10.0,10.11,true));
    checks[692]=uint(source_feedback_compatible(normal,float3(sqrt(1.0-0.95*0.95),0,0.95),10.0,10.0,true));
    checks[693]=asuint(previous_view_depth(float3(0,0,-10)));
}
[shader("compute")][numthreads(1,1,1)]
void read_source_hit_normals() {
    let front=hit_normal(Hit(1.0,0u,float2(0.25,0.5)),float3(0,0,-1));
    let back=hit_normal(Hit(1.0,0u,float2(0.25,0.5)),float3(0,0,1));
    let authored=hit_normal(Hit(1.0,20u,float2(0.25,0.5)),float3(0,0,-1));
    let scaled=hit_normal(Hit(1.0,40u,float2(0.25,0.5)),float3(0,0,-1));
    for(var i=0u;i<3u;i++) {checks[628u+i]=asuint(front[i]);checks[632u+i]=asuint(back[i]);checks[636u+i]=asuint(authored[i]);}
    for(var i=0u;i<3u;i++) {checks[640u+i]=asuint(scaled[i]);}
    let s=Surface(float3(0.25,0.5,0),front,float3(1),0.5,0.0,0.5,1.0,true,front);
    let primary=primary_geometry_normal_from_hit(Hit(1.0,0u,float2(0.25,0.5)),float3(0.25,0.5,1),float3(0,0,-1),s);
    let back_primary=primary_geometry_normal_from_hit(Hit(1.0,0u,float2(0.25,0.5)),float3(0.25,0.5,-1),float3(0,0,1),s);
    let unmatched=primary_geometry_normal_from_hit(Hit(2.0,0u,float2(0.25,0.5)),float3(0.25,0.5,1),float3(0,0,-1),s);
    for(var i=0u;i<4u;i++) {checks[644u+i]=asuint(primary[i]);checks[648u+i]=asuint(back_primary[i]);checks[652u+i]=asuint(unmatched[i]);}
}
[shader("compute")][numthreads(64,1,1)]
void seed_source_random_checks(uint lane:SV_GroupIndex) {
    let base=probe_random_seeds();
    let values=uint[8](3499211612u,581869302u,3890346734u,3586334585u,545404204u,4161255391u,3922919429u,949333985u);
    if(lane==0u) {work[base].store(8u);}
    if(lane<8u) {work[base+1u+lane].store(values[lane]);}
}
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
    let mirror=Surface(float3(0),float3(0,0,1),float3(0),0.01,0.0,0.5,1.0,true,float3(0,0,1));
    let specular=probe_sample_direction(0u,bin,mirror,rng);
    checks[256u+lane]=asuint(specular.z);
    let diffuse=Surface(float3(0),float3(0,0,1),float3(1),1.0,0.0,0.0,1.0,true,float3(0,0,1));
    let sampled=probe_sample_direction(0u,bin,diffuse,rng);
    checks[320u+lane]=direction_bin(diffuse.normal,sampled.xyz);
    checks[384u+lane]=asuint(sampled.w);
}
[shader("compute")][numthreads(64,1,1)]
void seed_source_cache_merge(uint lane:SV_GroupIndex) {
    if(lane<probe_cache_count()) {
        work[probe_cache_heads()+lane].store(0u);
        work[source_candidate_offsets()+lane].store(0u);
        previous_probes[probe_reprojected_history()+lane].position.w=0.0;
    }
    if(lane==0u) {
        work[27].store(1u);work[probe_fresh_list()].store(0u);
        work[probe_cache_heads()].store(select(probe_cache_count()>1u,2u,1u));probe_cache[0].next=MISSING;
        work[source_candidate_offsets()].store(0u);work[source_candidate_blocks()].store(0u);work[source_candidate_list()].store(0u);
        probes[0].position=float4(0,0,0.5,1);probes[0].normal=float4(0,0,1,0.1);
        // The claimed nearest cache is not a separate source history input.
        probes[0].info.x=p.scene_info.z;probes[0].info.y=0u;
        probe_cache[0].probe.position=probes[0].position;probe_cache[0].probe.normal=probes[0].normal;
        probe_cache[0].probe.position.w=asfloat(restir_pack_normal(probe_cache[0].probe.normal.xyz));
        if(probe_cache_count()>1u) {
            work[source_candidate_list()+1u].store(1u);
            probe_cache[1].probe.position=probe_cache[0].probe.position;
            probe_cache[1].probe.normal=probe_cache[0].probe.normal;
        }
    }
    if(lane<PROBE_DIRECTIONS) {
        probe_cache[0].probe.samples[lane]=probe_pack(float4(6,6,6,10));
        if(probe_cache_count()>1u) {probe_cache[1].probe.samples[lane]=probe_pack(float4(10,10,10,10));}
    }
}
[shader("compute")][numthreads(64,1,1)]
void read_source_cache_merge(uint lane:SV_GroupIndex) {
    if(lane<PROBE_DIRECTIONS) {checks[448u+lane]=asuint(probe_unpack(probes[0].samples[lane]).x);}
}
[shader("compute")][numthreads(64,1,1)]
void seed_source_cache_ownership(uint lane:SV_GroupIndex) {
    if(lane<p.scene_info.z) {probes[lane].position.w=0.0;}
    if(lane<probe_cache_count()) {
        probe_cache[lane].available.store(1u);probe_cache[lane].valid=0u;
        work[probe_cache_lru()+lane].store(lane);work[probe_cache_source_ranks()+lane].store(lane);
        work[probe_cache_heads()+lane].store(0u);work[source_candidate_offsets()+lane].store(0u);
    }
    GroupMemoryBarrierWithGroupSync();
    if(lane==0u) {
        work[0].store(1u);work[WORK_HEADER].store(0u);
        work[probe_cache_work()].store(0u);work[probe_cache_work()+2u].store(0u);
        probes[0].position=float4(0,0,0.5,1);probes[0].normal=float4(0,0,1,0.1);
        probes[0].info=uint4(MISSING,0u,MISSING,1u);
        let old_index=probe_reprojected_history();
        previous_probes[old_index].position=float4(0,0,0.5,float(p.frame.x==7u));
        previous_probes[old_index].normal=float4(0,0,-1,0.1);
        let existing=p.frame.x==255u || (p.frame.x==7u && p.quality.w!=2.0);
        if(existing) {
            probe_cache[0].valid=1u;probe_cache[0].next=MISSING;work[probe_cache_heads()].store(1u);
            work[source_candidate_blocks()].store(0u);work[source_candidate_list()].store(0u);
            probe_cache[0].probe.position=float4(select(p.frame.x==255u,0.01,0.0),0,0.5,1);
            probe_cache[0].probe.normal=float4(0,0,select(p.frame.x==255u || p.quality.w==4.0,1.0,-1.0),0.1);
            probe_cache[0].probe.position.w=asfloat(restir_pack_normal(probe_cache[0].probe.normal.xyz));
        }
    }
    if(lane<PROBE_DIRECTIONS) {
        probes[0].samples[lane]=probe_pack(float4(9,9,9,10));
        previous_probes[probe_reprojected_history()].samples[lane]=probe_pack(float4(17,17,17,10));
        probe_cache[0].probe.samples[lane]=probe_pack(float4(6,6,6,10));
    }
}
[shader("compute")][numthreads(64,1,1)]
void read_source_cache_ownership(uint lane:SV_GroupIndex) {
    if(lane!=0u) {return;}
    checks[470]=probe_cache[0].valid;checks[471]=probe_cache[0].available.load();
    checks[472]=work[probe_cache_work()].load();checks[473]=work[probe_cache_work()+2u].load();
    checks[474]=asuint(probe_unpack(probe_cache[0].probe.samples[0]).x);
    checks[475]=asuint(probe_cache[0].probe.position.x);
    checks[476]=probes[0].info.z;checks[477]=work[probe_cache_evicted()].load();
    checks[478]=work[probe_cache_lru()].load();
    checks[479]=work[probe_cache_lru()+probe_cache_count()-1u].load();
    checks[680]=asuint(probe_cache[0].probe.position.w);
}
[shader("compute")][numthreads(64,1,1)]
void seed_multibounce_bypass(uint lane:SV_GroupIndex) {
    if(lane==0u) {
        work[27].store(1u);work[probe_fresh_list()].store(0u);
        hash_write(0u,false,float4(2,4,6,16));
        let base=hash_scratch_base(0u,uint2(0u),true);
        for(var i=0u;i<4u;i++) {hash_tiles[base+i].store(0u);}
    }
    if(lane>=PROBE_DIRECTIONS) {return;}
    rays[lane].info.w=0u;rays[lane].probe_bounce=float4(0.0);
    rays[lane].bounce_info=uint4(0u,MISSING,pack2x16float(float2(0.5)),pack2x16float(float2(0.5,1.0)));
    rays[lane].bounce_normal.w=float(lane<PROBE_DIRECTIONS/2u);
}
[shader("compute")][numthreads(64,1,1)]
void read_multibounce_bypass(uint lane:SV_GroupIndex) {
    if(lane<PROBE_DIRECTIONS) {checks[480u+lane]=asuint(rays[lane].probe_bounce.x);}
    if(lane==0u) {
        let base=hash_scratch_base(0u,uint2(0u),true);
        checks[496]=hash_tiles[base+3u].load();checks[497]=hash_tiles[base].load();
    }
}
[shader("compute")][numthreads(64,1,1)]
void read_source_random_checks(uint lane:SV_GroupIndex) {
    if(lane>=4u) {return;}
    var state=source_random(lane,p.frame.x);checks[498u+lane]=grid_random_uint(state);
    state=source_random(lane+8u,p.frame.x);checks[502u+lane]=grid_random_uint(state);
    state=source_random(lane);checks[506u+lane]=grid_random_uint(state);
}
[shader("compute")][numthreads(1,1,1)]
void read_source_directional_cache() {
    let position=float3(0,0,0.5);let normal=float3(0,0,1);let distance=10.0;
    world_cache[0].tag.store(123u);world_cache[0].direct=float4(99.0);
    checks[512]=cache_insert(position,normal,distance,0u,true);
    checks[513]=world_cache[0].tag.load();
    let desc=hash_tile_descriptor(position,normal,distance);let meta=hash_tile_meta(0u);
    hash_tiles[meta].store(0u);
    var found=false;let absent=directional_cached_radiance(position,normal,distance,found);
    checks[514]=asuint(absent.x);checks[515]=asuint(absent.y);checks[516]=asuint(absent.z);checks[517]=uint(found);
    hash_tiles[meta].store(desc.tag);hash_write(0u,false,float4(2,4,6,2));hash_write(0u,true,float4(0.0));
    let present=directional_cached_radiance(position,normal,distance,found);
    checks[518]=asuint(present.x);checks[519]=asuint(present.y);checks[520]=asuint(present.z);checks[521]=uint(found);
    hash_write(0u,false,float4(0.0));
    let empty=directional_cached_radiance(position,normal,distance,found);
    checks[522]=asuint(empty.x);checks[523]=asuint(empty.y);checks[524]=asuint(empty.z);checks[525]=uint(found);
}
[shader("compute")][numthreads(1,1,1)]
void read_source_interpolation() {
    let s=Surface(float3(0,0,0.5),float3(0,0,1),float3(1),0.35,0.0,0.5,1.0,true,float3(0,0,1));
    for(var i=0u;i<4u;i++) {
        probes[i].position=float4(s.position,1);probes[i].normal=float4(s.normal,1);
        for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {probes[i].samples[bin]=probe_pack(float4(float3(float(i+1u)),10));}
    }
    let neighbors=uint4(0,1,2,3);
    var interpolation=probe_interpolation_weights(s,neighbors,0.1);
    for(var i=0u;i<4u;i++) {checks[528u+i]=asuint(interpolation.weights[i]);}
    let weighted=source_directional_interpolation(interpolation,s.normal);
    for(var i=0u;i<4u;i++) {checks[532u+i]=asuint(weighted[i]);}
    for(var i=0u;i<4u;i++) {probes[i].position.z=2.0;}
    interpolation=probe_interpolation_weights(s,neighbors,0.1);checks[536]=asuint(interpolation.hint);
    let backup=source_directional_interpolation(interpolation,s.normal);
    for(var i=0u;i<4u;i++) {checks[537u+i]=asuint(backup[i]);}
    probes[3].normal.xyz=-s.normal;
    let rejected=source_directional_interpolation(interpolation,s.normal);
    for(var i=0u;i<4u;i++) {checks[541u+i]=asuint(rejected[i]);}
    interpolation=probe_interpolation_weights(s,uint4(MISSING),0.1);
    let missing_diffuse=source_diffuse_interpolation(s,interpolation);
    let missing_directional=source_directional_interpolation(interpolation,s.normal);
    for(var i=0u;i<4u;i++) {checks[545u+i]=asuint(missing_diffuse[i]);checks[549u+i]=asuint(missing_directional[i]);}
    let receiver=Surface(float3(0,0,-2),s.normal,s.base,s.roughness,s.metallic,s.reflectance,s.ao,true,s.geometry_normal);
    for(var i=0u;i<4u;i++) {probes[i].position=float4(receiver.position,1);probes[i].normal=float4(s.normal,1);}
    probes[1].position.z=-3.0;probes[2].normal.xyz=float3(sqrt(0.75),0,0.5);probes[3].normal.xyz=-s.normal;
    interpolation=probe_interpolation_weights(receiver,neighbors,10.0);
    for(var i=0u;i<4u;i++) {checks[553u+i]=asuint(interpolation.weights[i]);}
}
[shader("compute")][numthreads(64,1,1)]
void read_source_query_streams(uint lane:SV_GroupIndex) {
    if(lane==0u) {work[7].store(0u);work[11].store(0u);work[15].store(0u);}
    GroupMemoryBarrierWithGroupSync();
    let index=31u-min(lane,31u);
    if(lane<16u) {rays[index].position.w=asfloat(source_append_visibility(index,false));}
    if(lane<8u) {rays[index].bounce_direction.w=asfloat(source_append_visibility(index,true));}
    GroupMemoryBarrierWithGroupSync();
    if(lane<16u) {work[source_shadow_ids()+source_visibility_id(index,false)].store(MISSING);}
    if(lane<8u) {work[source_shadow_ids()+source_visibility_id(index,true)].store(MISSING);}
    GroupMemoryBarrierWithGroupSync();
    if(lane<16u && lane%2u==0u) {source_append_shadow(source_visibility_id(index,false));}
    GroupMemoryBarrierWithGroupSync();
    if(lane<8u && lane%2u==1u) {source_append_shadow(source_visibility_id(index,true));}
    GroupMemoryBarrierWithGroupSync();
    if(lane==0u) {checks[560]=work[7].load();checks[561]=work[11].load();checks[562]=work[15].load();}
    if(lane<16u) {
        let first=source_visibility_id(index,false);let a=564u+4u*lane;
        checks[a]=first;checks[a+1u]=work[source_shadow_ids()+first].load();
        if(lane<8u) {let second=source_visibility_id(index,true);checks[a+2u]=second;checks[a+3u]=work[source_shadow_ids()+second].load();}
        else {checks[a+2u]=MISSING;checks[a+3u]=MISSING;}
        if(work[source_visibility_list(false)+first].load()!=index) {checks[a]=MISSING;}
        if(lane<8u && work[source_visibility_list(true)+asuint(rays[index].bounce_direction.w)].load()!=index) {checks[a+2u]=MISSING;}
    }
}
[shader("compute")][numthreads(1,1,1)]
void read_source_primary_input() {
    checks[656]=work[primary_normal_address(uint2(0))].load();
    let packed=primary_pack_geometry_normal(float3(1,0,0),true);
    work[primary_normal_address(uint2(0))].store(packed);
    let loaded=surface(uint2(0));
    checks[657]=packed;
    for(var i=0u;i<3u;i++) {checks[658u+i]=asuint(loaded.geometry_normal[i]);}
    checks[661]=asuint(loaded.normal.z);
    let receiver=Surface(float3(0),float3(1,0,0),float3(1),0.5,0.0,0.5,1.0,true,float3(0,0,1));
    for(var i=0u;i<4u;i++) {probes[i].position=float4(receiver.position,1);probes[i].normal=float4(receiver.geometry_normal,1);}
    let interpolation=probe_interpolation_weights(receiver,uint4(0,1,2,3),0.1);
    for(var i=0u;i<4u;i++) {checks[662u+i]=asuint(interpolation.weights[i]);}
    checks[666]=asuint(interpolation.hint);
}
[shader("compute")][numthreads(1,1,1)]
void read_source_details_input() {
    var a=Surface(float3(0),float3(1,0,0),float3(1),0.5,0.0,0.5,1.0,true,float3(0,0,1));
    var b=a;b.normal=float3(0,1,0);
    checks[667]=asuint(gi_denoiser_normal_factor(a,b));
    checks[668]=asuint(gi_denoiser_normal_factor(a,a));
    checks[669]=asuint(dot(surface_plane_normal(a),surface_plane_normal(b)));
    let raw=primary_details_normal(a);
    for(var i=0u;i<3u;i++) {checks[670u+i]=asuint(raw[i]);}
    a.normal=normalize(float3(0.15,0.4,0.75));
    let smooth=primary_details_normal(a);
    for(var i=0u;i<3u;i++) {checks[673u+i]=asuint(smooth[i]);}
    let shading=surface_shading_normal(a);
    for(var i=0u;i<3u;i++) {checks[712u+i]=asuint(shading[i]);}
    var cached=source_cache_metadata(probes[0]);
    cached.normal.xyz=a.normal;cached=source_cache_metadata(cached);
    checks[681]=asuint(cached.position.w);
    cached.normal.xyz=float3(1,0,0);
    let decoded=cached_probe_normal(cached);
    for(var i=0u;i<3u;i++) {checks[682u+i]=asuint(decoded[i]);}
    output_normal[int2(0)]=primary_history_details(a);
}
[shader("compute")][numthreads(1,1,1)]
void read_source_details_history() {
    let stored=previous_normal.Load(int3(0));
    for(var i=0u;i<4u;i++) {checks[676u+i]=asuint(stored[i]);}
}
[shader("compute")][numthreads(64,1,1)]
void seed_source_candidate_projection(uint3 gid:SV_DispatchThreadID) {
    let slot=gid.x;if(slot>=probe_cache_count()) {return;}
    work[probe_cache_lru()+slot].store(probe_cache_count()-1u-slot);
    probe_cache[slot].valid=1u;
    let tile=select(slot>=9u&&(slot&1u)==0u,128u,slot);
    let uv=(float2(tile%p.screen.x,tile/p.screen.x)+0.5)/float2(p.screen.xy);
    var position=float3(uv*float2(2,-2)+float2(-1,1),0.5);
    if(slot==0u) {position.x=-1.0;}if(slot==1u) {position.x=1.0;}
    if(slot==2u) {position.y=-1.0;}if(slot==3u) {position.y=1.0;}
    if(slot==4u) {position.z=0.0;}if(slot==5u) {position.z=1.0;}
    if(slot==6u) {position.z=-0.1;}if(slot==7u) {position.z=1.1;}
    if(slot==8u) {position.xy=float2(0.9,0.8);}
    probe_cache[slot].probe.position=float4(position,1.0);
    if(slot<16u) {work[probe_cache_work()+4u+slot].store(asuint(float(slot%5u==0u)));}
}
[shader("compute")][numthreads(64,1,1)]
void read_source_candidate_projection(uint3 gid:SV_DispatchThreadID) {
    let tile=gid.x;if(tile>=probe_cache_count()) {return;}
    if(tile==0u) {checks[0]=work[probe_cache_work()+3u].load();}
    checks[1u+3u*tile]=work[probe_cache_heads()+tile].load();
    checks[2u+3u*tile]=work[source_candidate_offsets()+tile].load()+work[source_candidate_blocks()+tile/128u].load();
    if(tile<work[probe_cache_work()+3u].load()) {checks[3u+3u*tile]=work[source_candidate_list()+tile].load();}
}
[shader("compute")][numthreads(1,1,1)]
void read_source_composition_output() {
    for(var i=0u;i<1024u;i++) {reflections[i]=float4(asfloat(pack2x16float(float2(0.75,0.125))),0.0,0.0,0.0);}
    let base=float3(0.2,0.4,0.8);
    let s=Surface(float3(0,0,-1),float3(0,0,1),base,0.35,0.75,0.5,1.0,true,float3(0,0,1));
    let diffuse=primary_material_albedo(base,s.metallic,p.restir.w);
    let f0=primary_material_f0(base,s.metallic,s.reflectance,p.restir.w);
    let specular=reflection_directional_albedo(s);
    let secondary=material_albedo(float3(0.2,0.2,0),0u);
    for(var i=0u;i<3u;i++) {
        checks[i]=asuint(diffuse[i]);checks[3u+i]=asuint(f0[i]);
        checks[6u+i]=asuint(specular[i]);checks[9u+i]=asuint(secondary[i]);
    }
    checks[12]=uint(source_albedo_textures_disabled(p.restir.w));
}
[shader("compute")][numthreads(1,1,1)]
void read_source_alpha_traversal() {
    let front=trace_impl(float3(0.2,0.2,1),float3(0,0,-1),2.0,false);
    let front_shadow=trace_impl(float3(0.2,0.2,1),float3(0,0,-1),2.0,true);
    let back=trace_impl(float3(0.2,0.2,-1),float3(0,0,1),2.0,false);
    let back_shadow=trace_impl(float3(0.2,0.2,-1),float3(0,0,1),2.0,true);
    checks[0]=uint(material_visible(2u,float2(0.2)));
    checks[1]=front.triangle;checks[2]=asuint(front.distance);checks[3]=front_shadow.triangle;
    checks[4]=back.triangle;checks[5]=back_shadow.triangle;
    checks[6]=uint(source_alpha_testing_disabled());
    let mesh_position=material_mesh_position(2u,float2(0.2));
    for(var i=0u;i<3u;i++) {checks[7u+i]=asuint(mesh_position[i]);}
    checks[10]=asuint(source_blend_threshold(2u,float2(0.2)));
    let emission=material_emission(float3(0.2,0.2,0),2u);
    let cone=material_emission_cone(float3(0.2,0.2,1),float3(0.2,0.2,0),2u,0.125);
    var front_bary=float2(0.2);var back_bary=float2(0.2);
#if GI_HARDWARE
    // Obtain candidate barycentrics without alpha rejection for the CPU oracle.
    RayDesc ray;ray.Origin=float3(0.2,0.2,1);ray.Direction=float3(0,0,-1);ray.TMin=p.cache_config.z;ray.TMax=2.0;
    RayQuery<RAY_FLAG_FORCE_OPAQUE> front_reference;
    front_reference.TraceRayInline(scene_tlas,RAY_FLAG_NONE,0xffu,ray);
    while(front_reference.Proceed()) {}
    front_bary=front_reference.CommittedTriangleBarycentrics();
    ray.Origin.z=-1;ray.Direction.z=1;
    RayQuery<RAY_FLAG_FORCE_OPAQUE> back_reference;
    back_reference.TraceRayInline(scene_tlas,RAY_FLAG_NONE,0xffu,ray);
    while(back_reference.Proceed()) {}
    back_bary=back_reference.CommittedTriangleBarycentrics();
#endif
    let front_mesh=material_mesh_position(2u,front_bary);let back_mesh=material_mesh_position(2u,back_bary);
    for(var i=0u;i<3u;i++) {
        checks[11u+i]=asuint(emission[i]);checks[14u+i]=asuint(cone[i]);
        checks[17u+i]=asuint(front_mesh[i]);checks[20u+i]=asuint(back_mesh[i]);
    }
    checks[23]=asuint(source_blend_threshold(2u,front_bary));checks[24]=asuint(source_blend_threshold(2u,back_bary));
    checks[25]=source_alpha_hash(asuint(float4(mesh_position,float(p.frame.x))));
}
