// AMD Capsaicin GI-1.2 world_space_restir.hlsl and gi1.comp.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
// The source arrays are disjoint regions of one buffer. Current and previous
// tables never alias, including during parallel resampling and visibility.
[[vk::binding(33, 0)]] RWStructuredBuffer<Atomic<uint>> restir;
uint restir_entries() {return p.restir.x*p.restir.y;}
uint restir_blocks() {return (restir_entries()+127u)/128u;}
uint restir_frame(bool previous) {return (p.frame.x&1u)^uint(previous);}
uint restir_table(bool previous) {return 16u+restir_frame(previous)*3u*restir_entries();}
uint restir_scan() {return 16u+6u*restir_entries();}
uint restir_values(bool previous) {return restir_scan()+restir_blocks()+restir_frame(previous)*p.restir.z;}
uint restir_samples() {return restir_scan()+restir_blocks()+2u*p.restir.z;}
uint restir_materials() {return restir_samples()+4u*p.restir.z;}
uint restir_normals(bool previous) {return restir_materials()+p.restir.z+restir_frame(previous)*p.restir.z;}
uint restir_reservoirs(bool previous) {return restir_materials()+3u*p.restir.z+restir_frame(previous)*4u*p.restir.z;}
uint restir_list() {return restir_materials()+11u*p.restir.z;}
uint restir_ray_capacity() {return p.scene_info.z*PROBE_DIRECTIONS;}
uint restir_pack_normal(float3 normal) {
    let v=uint3(int3(clamp(normal,float3(-1.0),float3(1.0))*511.0+0.5*sign(normal)))&uint3(1023u);
    return v.x|(v.y<<10u)|(v.z<<20u);
}
float3 restir_unpack_normal(uint value) {
    return float3(int3(value<<22u,value<<12u,value<<2u)>>22)/511.0;
}
uint restir_pack_material(float3 base) {
    if(source_specular_materials_disabled(p.restir.w)) {
        let v=uint3(pow(clamp(base,0.0,1.0),float3(1.0/2.2))*1023.0);
        return (v.x<<20u)|(v.y<<10u)|v.z;
    }
    let v=uint3(pow(clamp(base,float3(0.0),float3(1.0)),float3(1.0/2.2))*float3(31.0,63.0,31.0));
    // GenerateReservoirs forces a rough matte dielectric before packing.
    return ((v.x<<11u)|(v.y<<5u)|v.z)<<16u|255u;
}
float3 restir_material_base(uint value) {
    if(source_specular_materials_disabled(p.restir.w)) {
        return pow(float3((value>>20u)&1023u,(value>>10u)&1023u,value&1023u)/1023.0,float3(2.2));
    }
    return pow(float3((value>>27u)&31u,(value>>21u)&63u,(value>>16u)&31u)/float3(31.0,63.0,31.0),float3(2.2));
}
struct PackedReservoir {
    uint light;
    float2 uv;
    float weight;
    float count;
    float visibility;
};
uint4 restir_pack_reservoir(PackedReservoir r) {
    return uint4(r.light,pack2x16float(r.uv),asuint(r.weight),pack2x16float(float2(r.count,r.visibility)));
}
PackedReservoir restir_unpack_reservoir(uint4 v) {
    let mv=unpack2x16float(v.w);
    return PackedReservoir(v.x,unpack2x16float(v.y),asfloat(v.z),mv.x,mv.y);
}
PackedReservoir restir_load_reservoir(uint sample,bool previous) {
    let address=restir_reservoirs(previous)+4u*sample;
    return restir_unpack_reservoir(uint4(restir[address].load(),restir[address+1u].load(),restir[address+2u].load(),restir[address+3u].load()));
}
void restir_store_reservoir(uint sample,PackedReservoir r) {
    let address=restir_reservoirs(false)+4u*sample;let value=restir_pack_reservoir(r);
    for(var c=0u;c<4u;c++) {restir[address+c].store(value[c]);}
}
float restir_cell_size(float3 position,float3 eye) {
    // Unsigned source exponent is hardened at sub-millimetre distances.
    let level=max(trunc(log2(max(1000.0*distance(eye,position)*p.restir_sampling.w,1.0))),0.0);
    return 0.001*exp2(min(level,30.0));
}
uint2 restir_index_and_hash(float3 position,float3 eye) {
    let width=restir_cell_size(position,eye);let level=uint(round(log2(width*1000.0)));
    let cell=uint3(int3(floor(position/width)));
    let index=pcg_hash(level+pcg_hash(cell.x+pcg_hash(cell.y+pcg_hash(cell.z))))%p.restir.x;
    let hash=max(xx_hash(level+xx_hash(cell.x+xx_hash(cell.y+xx_hash(cell.z)))),1u);
    return uint2(index,hash);
}
bool restir_insert(uint sample,float3 position) {
    let key=restir_index_and_hash(position,p.camera.xyz);let table=restir_table(false);
    for(var collision=0u;collision<p.restir.y;collision++) {
        let entry=key.x*p.restir.y+collision;
        let found=restir[table+entry].compareExchange(0u,key.y);
        if(found!=0u&&found!=key.y) {continue;}
        let ordinal=restir[table+restir_entries()+entry].add(1u);
        let list_index=restir[0].add(1u);let address=restir_list()+4u*list_index;
        restir[address].store(sample);restir[address+1u].store(entry);restir[address+2u].store(ordinal);restir[address+3u].store(0u);
        return true;
    }
    return false;
}
uint restir_find_previous(float3 position) {
    let key=restir_index_and_hash(position,p.restir_sampling.xyz);let table=restir_table(true);
    for(var collision=0u;collision<p.restir.y;collision++) {
        let entry=key.x*p.restir.y+collision;let checksum=restir[table+entry].load();
        if(checksum==0u) {break;}
        if(checksum==key.y) {return entry;}
    }
    return MISSING;
}
[shader("compute")][numthreads(64,1,1)]
void clear_restir(uint3 gid:SV_DispatchThreadID) {
    let entry=gid.x+gid.y*65536u;if(entry>=restir_entries()) {return;}
    let table=restir_table(false);restir[table+entry].store(0u);restir[table+restir_entries()+entry].store(0u);
    if(entry==0u) {restir[0].store(0u);}
    if(p.frame.y!=0u) {
        let previous=restir_table(true);restir[previous+entry].store(0u);restir[previous+restir_entries()+entry].store(0u);
    }
}
float3 restir_jitter(float3 position,float3 normal,inout uint rng) {
    let jitter=(float2(grid_random(rng),grid_random(rng))*2.0-1.0)*restir_cell_size(position,p.camera.xyz)*sqrt(2.0);
    return position+mul(probe_frame(normal),float3(jitter,0.0));
}
void restir_generate(uint index,bool bounce) {
    var sample=index+select(bounce,restir_ray_capacity(),0u);
    let ray=rays[index];let info=select(bounce,ray.bounce_info,ray.info);
    let source=source_probe_projection();
    if(source && select(bounce,info.x,info.w)==MISSING) {return;}
    let query=select(source,source_visibility_id(index,bounce),sample);
    if(source) {work[source_shadow_ids()+query].store(MISSING);}
    else {restir_store_reservoir(sample,PackedReservoir(MISSING,float2(0.0),0.0,0.0,1.0));}
    if(!bounce && ray.info.x==EMISSIVE_PROBE_RAY) {return;}
    let position=select(bounce,ray.bounce_position.xyz,ray.position.xyz);
    let normal=select(bounce,ray.bounce_normal.xyz,ray.normal.xyz);
    if(info.y==MISSING||all(normal==float3(0.0))||grid_light_count()==0u|| (bounce&&info.x==MISSING)) {return;}
    let origin=select(bounce,ray.position.xyz,probes[index/PROBE_DIRECTIONS].position.xyz);
    let view=normalize(origin-position);var rng=pcg_hash(sample+p.frame.x);
    if(source) {rng=source_random(query,p.frame.x);}
    let fresh=grid_fresh_reservoir(position,normal,view,info.y,rng);
    if(fresh.light==MISSING||fresh.count==0u||fresh.target_density<=0.0) {return;}
    if(source) {sample=source_append_shadow(query);}
    let address=restir_samples()+4u*sample;
    restir[address].store(pack2x16float(origin.xy));restir[address+1u].store(pack2x16float(float2(origin.z,0.0)));
    restir[address+2u].store(pack2x16float(position.xy));restir[address+3u].store(pack2x16float(float2(position.z,0.0)));
    restir[restir_normals(false)+sample].store(restir_pack_normal(normal));
    let triangle=info.y;let uv=triangle_uv(triangle,barycentrics(position,triangle),0u);
    let base=geometry[triangle+13u].rgb*material_texture(uint(geometry[triangle+11u].x),uv).rgb;
    restir[restir_materials()+sample].store(restir_pack_material(base));
    restir_store_reservoir(sample,PackedReservoir(fresh.light,fresh.uv,fresh.weight_sum/(float(fresh.count)*fresh.target_density),float(fresh.count),1.0));
    restir_insert(sample,restir_jitter(position,normal,rng));
}
[shader("compute")][numthreads(64,1,1)]
void generate_restir(uint3 gid:SV_DispatchThreadID) {
    let lane=gid.x+gid.y*65536u;if(lane>=work[27].load()*PROBE_DIRECTIONS) {return;}
    var index=compact_fresh_probe(lane/PROBE_DIRECTIONS)*PROBE_DIRECTIONS+lane%PROBE_DIRECTIONS;
    if(source_probe_projection()) {
        if(lane>=work[7].load()) {return;}
        index=work[source_visibility_list(false)+lane].load();
    }
    restir_generate(index,false);
}
[shader("compute")][numthreads(64,1,1)]
void generate_restir_bounces(uint3 gid:SV_DispatchThreadID) {
    let lane=gid.x+gid.y*65536u;if(lane>=work[27].load()*PROBE_DIRECTIONS) {return;}
    var index=compact_fresh_probe(lane/PROBE_DIRECTIONS)*PROBE_DIRECTIONS+lane%PROBE_DIRECTIONS;
    if(source_probe_projection()) {
        if(lane>=work[11].load()) {return;}
        index=work[source_visibility_list(true)+lane].load();
    }
    restir_generate(index,true);
}
groupshared uint restir_prefix[128];
[shader("compute")][numthreads(128,1,1)]
void scan_restir_counts(uint3 group:SV_GroupID,uint lane:SV_GroupIndex) {
    let block=group.x+group.y*65535u;let entry=block*128u+lane;let table=restir_table(false);
    restir_prefix[lane]=select(entry<restir_entries(),restir[table+restir_entries()+min(entry,restir_entries()-1u)].load(),0u);
    GroupMemoryBarrierWithGroupSync();
    for(var step=1u;step<128u;step<<=1u) {
        var add=0u;if(lane>=step) {add=restir_prefix[lane-step];}
        GroupMemoryBarrierWithGroupSync();restir_prefix[lane]+=add;GroupMemoryBarrierWithGroupSync();
    }
    if(entry<restir_entries()) {restir[table+2u*restir_entries()+entry].store(select(lane>0u,restir_prefix[max(lane,1u)-1u],0u));}
    if(lane==127u) {restir[restir_scan()+block].store(restir_prefix[lane]);}
}
[shader("compute")][numthreads(128,1,1)]
void scan_restir_blocks(uint lane:SV_GroupIndex) {
    // Parallel scan of contiguous segments, then add each segment's exclusive
    // offset. No single invocation walks the upstream table's 32768 blocks.
    let span=(restir_blocks()+127u)/128u;let begin=lane*span;let end=min(begin+span,restir_blocks());
    var total=0u;
    for(var block=begin;block<end;block++) {total+=restir[restir_scan()+block].load();}
    restir_prefix[lane]=total;GroupMemoryBarrierWithGroupSync();
    for(var step=1u;step<128u;step<<=1u) {
        var add=0u;if(lane>=step) {add=restir_prefix[lane-step];}
        GroupMemoryBarrierWithGroupSync();restir_prefix[lane]+=add;GroupMemoryBarrierWithGroupSync();
    }
    var prefix=0u;if(lane>0u) {prefix=restir_prefix[lane-1u];}
    for(var block=begin;block<end;block++) {
        let count=restir[restir_scan()+block].load();restir[restir_scan()+block].store(prefix);prefix+=count;
    }
}
[shader("compute")][numthreads(64,1,1)]
void add_restir_block_offsets(uint3 gid:SV_DispatchThreadID) {
    let entry=gid.x+gid.y*65536u;if(entry>=restir_entries()) {return;}
    let address=restir_table(false)+2u*restir_entries()+entry;
    restir[address].store(restir[address].load()+restir[restir_scan()+entry/128u].load());
}
[shader("compute")][numthreads(64,1,1)]
void compact_restir(uint3 gid:SV_DispatchThreadID) {
    let lane=gid.x+gid.y*65536u;if(lane>=restir[0].load()) {return;}
    let address=restir_list()+4u*lane;let sample=restir[address].load();let entry=restir[address+1u].load();let ordinal=restir[address+2u].load();
    let offset=restir[restir_table(false)+2u*restir_entries()+entry].load();
    restir[restir_values(false)+offset+ordinal].store(sample);
}
float restir_target(float3 position,float3 normal,float3 view,uint material,PackedReservoir r) {
    if(r.light>=grid_light_count()) {return 0.0;}
    let selected=evaluate_light_cone(position,normal,r.light,r.uv,4.0*PI/(8.0*12000.0));let base=restir_material_base(material);let f0=float3(0.04);
    let half_vector=normalize(view+selected.direction);
    let diffuse=base*diffuse_compensation(f0,dot(half_vector,view));
    if(source_specular_materials_disabled(p.restir.w)) {
        let albedo=luminance(base);
        return select(albedo>0.0,luminance(selected.value*diffuse)/max(albedo,1e-20),luminance(selected.value));
    }
    let lut=sample_brdf_lut(clamp(dot(normal,view),0.0,1.0),1.0);
    let albedo=luminance(base)+luminance(clamp(f0*lut.x+(float3(1.0)-f0)*lut.y,float3(0.0),float3(1.0)));
    return select(albedo>0.0,luminance(selected.value*(diffuse+PI*specular_brdf(normal,view,selected.direction,f0,1.0)))/max(albedo,1e-20),luminance(selected.value));
}
void restir_merge(inout PackedReservoir result,inout float target,PackedReservoir candidate,float candidate_target,inout uint rng) {
    let sum_count=max(result.count+candidate.count,1e-30);
    let a=result.count/sum_count*target*result.weight;let b=candidate.count/sum_count*candidate_target*candidate.weight;let total=a+b;
    if(grid_random(rng)*total<b) {result.light=candidate.light;result.uv=candidate.uv;target=candidate_target;}
    result.visibility=clamp(max(result.visibility*a+candidate.visibility*b,1e-30)/max(total,1e-30),0.0,1.0);
    result.weight=total/max(target,1e-30);result.count+=candidate.count;
}
void restir_resample(uint sample) {
    var result=restir_load_reservoir(sample,false);if(result.count<=0.0||result.light>=grid_light_count()) {return;}
    let address=restir_samples()+4u*sample;
    let ox=unpack2x16float(restir[address].load());let oz=unpack2x16float(restir[address+1u].load());
    let wx=unpack2x16float(restir[address+2u].load());let wz=unpack2x16float(restir[address+3u].load());
    let origin=float3(ox,oz.x);let world=float3(wx,wz.x);let normal=restir_unpack_normal(restir[restir_normals(false)+sample].load());
    var rng=pcg_hash(sample+p.frame.x);
    if(source_probe_projection()) {rng=source_random(sample,p.frame.x);}
    let entry=restir_find_previous(restir_jitter(world,normal,rng));
    if(entry==MISSING) {return;}
    let previous=restir_table(true);let count=restir[previous+restir_entries()+entry].load();if(count==0u) {return;}
    let index=restir[previous+2u*restir_entries()+entry].load();let increment=(count+3u)/4u;
    let offset=min(uint(grid_random(rng)*float(increment)),increment-1u);
    let material=restir[restir_materials()+sample].load();let view=normalize(origin-world);
    result.count=1.0;var target=restir_target(world,normal,view,material,result);
    for(var i=0u;i<count;i+=increment) {
        let sample2=restir[restir_values(true)+index+((i+offset)%count)].load();
        var other=restir_load_reservoir(sample2,true);
        if(other.count<=0.0||other.light>=grid_light_count()||!(other.weight<1e30)) {continue;}
        let filter_normal=restir_unpack_normal(restir[restir_normals(true)+sample2].load());
        if(pow(max(dot(normal,filter_normal),0.0),4.0)<0.5) {continue;}
        other.count=min(other.count,20.0);let shifted=restir_target(world,normal,view,material,other);
        restir_merge(result,target,other,shifted,rng);
    }
    restir_store_reservoir(sample,result);
}
[shader("compute")][numthreads(64,1,1)]
void resample_restir(uint3 gid:SV_DispatchThreadID) {
    let lane=gid.x+gid.y*65536u;if(lane>=work[27].load()*PROBE_DIRECTIONS) {return;}
    let index=compact_fresh_probe(lane/PROBE_DIRECTIONS)*PROBE_DIRECTIONS+lane%PROBE_DIRECTIONS;
    if(source_probe_projection()) {
        if(rays[index].info.w!=MISSING) {
            let sample=source_lighting_id(index,false);if(sample!=MISSING) {restir_resample(sample);}
        }
        if(p.options.y!=0u && rays[index].bounce_info.x!=MISSING) {
            let sample=source_lighting_id(index,true);if(sample!=MISSING) {restir_resample(sample);}
        }
    } else {
        restir_resample(index);if(p.options.y!=0u) {restir_resample(index+restir_ray_capacity());}
    }
}
