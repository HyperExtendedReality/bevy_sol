// Persistent screen-probe cache adapting AMD Capsaicin GI-1.2's cached tiles,
// projected candidate lists, exclusive update flags and stable LRU/MRU ordering.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
// Flattened linked lists replace the source prefix-scan/scatter representation.
struct CachedProbe {
    var available: Atomic<uint>;
    var last_used: uint;
    var valid: uint;
    var next: uint;
    var probe: Probe;
};
[[vk::binding(29, 0)]] RWStructuredBuffer<CachedProbe> probe_cache;
uint probe_cache_count() {return p.screen.x*p.screen.y;}
uint probe_mask_levels() {
    var dims=p.screen.xy;var levels=1u;
    while(any(dims>uint2(1u))) {dims=max(dims>>1u,uint2(1u));levels++;}
    return levels;
}
uint probe_cache_work() {return probe_mask_offset(probe_mask_levels());}
uint probe_cache_heads() {return probe_cache_work()+20u;}
uint probe_cache_lru() {return probe_cache_heads()+probe_cache_count();}
uint probe_cache_lru_scratch() {return probe_cache_lru()+probe_cache_count();}
uint probe_cache_mru() {return probe_cache_lru_scratch()+probe_cache_count();}
uint probe_cache_reordered() {return probe_cache_mru()+probe_cache_count();}
uint probe_cache_blocks() {return probe_cache_reordered()+probe_cache_count();}
uint probe_fresh_list() {return probe_cache_blocks()+(probe_cache_count()+127u)/128u;}
uint compact_fresh_probe(uint lane) {return work[probe_fresh_list()+lane].load();}
float probe_halton_number(uint index,uint base) {
    var factor=1.0;var result=0.0;
    while(index>0u) {factor/=float(base);result+=factor*float(index%base);index/=base;}
    return result;
}
float2 probe_halton_sequence(uint frame) {
    let index=(frame&255u)+1u;
    return float2(probe_halton_number(index,2u),probe_halton_number(index,3u));
}
uint2 probe_spawn_jitter(uint size) {
    return min(uint2(probe_halton_sequence(p.frame.x)*float(size)),uint2(size-1u));
}
bool probe_should_refresh(uint2 tile) {
    let axis=1u<<(uint(p.quality.w)>>1u);let group=tile/axis;
    let extent=min(uint2(axis),p.screen.xy-group*axis);
    // Source SpawnScreenProbes uses the same Halton seed in every spawn tile.
    // Clamp the selected tile at partial borders so each region has a seed.
    let phase=min(probe_spawn_jitter(axis*p.screen.z)/p.screen.z,extent-1u);
    return all(tile==group*axis+phase);
}
float4 probe_cache_projection_column(uint column) {
    var value=float4(0.0);let first=probe_cache_work()+4u+column*4u;
    for(var row=0u;row<4u;row++) {value[row]=asfloat(work[first+row].load());}
    return value;
}
float4 probe_cache_current_clip(float3 position) {
    // Rust uploads the jittered clip matrix once per view into this header.
    let matrix=transpose(float4x4(probe_cache_projection_column(0u),probe_cache_projection_column(1u),
        probe_cache_projection_column(2u),probe_cache_projection_column(3u)));
    return mul(matrix,float4(position,1.0));
}
[shader("compute")][numthreads(64,1,1)]
void prepare_probe_cache(uint3 gid : SV_DispatchThreadID) {
    let slot=gid.x+gid.y*65536u;if(slot>=probe_cache_count()) {return;}
    probe_cache[slot].available.store(1u);
    work[probe_cache_heads()+slot].store(MISSING);
    if(slot==0u) {work[probe_cache_work()].store(0u);work[probe_cache_work()+2u].store(0u);}
    if(p.frame.y!=0u) {
        probe_cache[slot].valid=0u;probe_cache[slot].last_used=0u;
        work[probe_cache_lru()+slot].store(slot);
    }
}
[shader("compute")][numthreads(64,1,1)]
void project_probe_cache(uint3 gid : SV_DispatchThreadID) {
    let slot=gid.x+gid.y*65536u;if(slot>=probe_cache_count()||probe_cache[slot].valid==0u) {return;}
    let clip=probe_cache_current_clip(probe_cache[slot].probe.position.xyz);
    if(clip.w<=0.0) {return;}
    let uv=float2(clip.x/clip.w*0.5+0.5,0.5-clip.y/clip.w*0.5);
    if(any(uv<float2(0.0))||any(uv>=float2(1.0))) {return;}
    let tile=min(uint2(uv*float2(p.viewport.zw))/p.screen.z,p.screen.xy-1u);
    let head=work[probe_cache_heads()+tile.x+tile.y*p.screen.x].exchange(slot);
    probe_cache[slot].next=head;
}
void probe_cache_touch(uint slot) {
    let rank=work[probe_cache_work()].add(1u);
    work[probe_cache_mru()+rank].store(slot);
}
[shader("compute")][numthreads(64,1,1)]
void reuse_cached_probes(uint3 gid : SV_DispatchThreadID) {
    let index=gid.x+gid.y*65536u;if(index>=p.scene_info.z) {return;}
    probes[index].info.z=MISSING;if(probes[index].position.w==0.0) {return;}
    let position=probes[index].position.xyz;let normal=probes[index].normal.xyz;
    let pixel=uint2(probes[index].info.y%p.viewport.z,probes[index].info.y/p.viewport.z);
    let tile=int2(pixel/p.screen.z);var best=MISSING;var score=1e30;
    let cell_size=max(select(p.camera.w!=0.0,probes[index].normal.w,
        length(p.camera.xyz-position)*p.reflection_thresholds.w),p.cache_config.z*4.0);
    for(var y=-1;y<=1;y++) {for(var x=-1;x<=1;x++) {
        let tap=tile+int2(x,y);if(any(tap<int2(0))||any(tap>=int2(p.screen.xy))) {continue;}
        var candidate=work[probe_cache_heads()+uint(tap.x)+uint(tap.y)*p.screen.x].load();
        for(var visited=0u;candidate!=MISSING && visited<probe_cache_count();visited++) {
            let cached_position=probe_cache[candidate].probe.position.xyz;
            let cached_normal=probe_cache[candidate].probe.normal.xyz;
            let distance=length(cached_position-position);
            if(dot(normal,cached_normal)>0.95 && abs(dot(cached_position-position,normal))<cell_size &&
                distance<cell_size*1.5 && distance<score) {best=candidate;score=distance;}
            candidate=probe_cache[candidate].next;
        }
    }}
    if(best==MISSING) {return;}
    let restored=p.scene_info.z+best;
    if(probe_cache[best].available.compareExchange(1u,0u)==1u) {
        probes[index].info.z=best;probe_cache_touch(best);
        // One writer restores the immutable history into a separate tail.
        // Other probes may read it after this dispatch completes, while only
        // the owner updates the cached tile. No live old probe is overwritten.
        previous_probes[restored]=probe_cache[best].probe;
    }
    if(probes[index].info.x==MISSING) {probes[index].info.x=restored;}
}
[shader("compute")][numthreads(64,1,1)]
void allocate_probe_cache(uint3 gid : SV_DispatchThreadID) {
    // The scanned free list retains oldest-first order. Parallel reservations
    // consume its prefix, with one owner per slot and no serial CAS search.
    let lane=gid.x+gid.y*65536u;if(lane>=work[0].load()) {return;}
    let index=compact_probe(lane);if(probes[index].info.z!=MISSING) {return;}
    let rank=work[probe_cache_work()+2u].add(1u);
    if(rank>=work[probe_cache_work()+1u].load()) {return;}
    let slot=work[probe_cache_reordered()+rank].load();
    probe_cache[slot].available.store(0u);probes[index].info.z=slot;probe_cache_touch(slot);
}
[shader("compute")][numthreads(64,1,1)]
void update_probe_cache(uint3 gid : SV_DispatchThreadID) {
    let lane=gid.x+gid.y*65536u;if(lane>=work[0].load()) {return;}
    let index=compact_probe(lane);let slot=probes[index].info.z;
    if(slot==MISSING) {return;}
    probe_cache[slot].probe=probes[index];probe_cache[slot].last_used=p.frame.x;probe_cache[slot].valid=1u;
}
groupshared uint probe_cache_scan[128];
[shader("compute")][numthreads(128,1,1)]
void scan_probe_cache_lru(uint3 group : SV_GroupID,uint lane : SV_GroupIndex) {
    let block=group.x+group.y*65535u;let rank=block*128u+lane;
    var retained=0u;
    if(rank<probe_cache_count()) {retained=uint(probe_cache[work[probe_cache_lru()+rank].load()].available.load()!=0u);}
    probe_cache_scan[lane]=retained;GroupMemoryBarrierWithGroupSync();
    for(var offset=1u;offset<128u;offset<<=1u) {
        let preceding=select(lane>=offset,probe_cache_scan[max(lane,offset)-offset],0u);
        GroupMemoryBarrierWithGroupSync();probe_cache_scan[lane]+=preceding;GroupMemoryBarrierWithGroupSync();
    }
    if(rank<probe_cache_count()) {work[probe_cache_lru_scratch()+rank].store(probe_cache_scan[lane]);}
    if(lane==127u) {work[probe_cache_blocks()+block].store(probe_cache_scan[lane]);}
}
[shader("compute")][numthreads(1,1,1)]
void scan_probe_cache_blocks() {
    var prefix=0u;
    for(var block=0u;block<(probe_cache_count()+127u)/128u;block++) {
        let count=work[probe_cache_blocks()+block].load();work[probe_cache_blocks()+block].store(prefix);prefix+=count;
    }
    work[probe_cache_work()+1u].store(prefix);
}
[shader("compute")][numthreads(64,1,1)]
void scatter_probe_cache_lru(uint3 gid : SV_DispatchThreadID) {
    let rank=gid.x+gid.y*65536u;if(rank>=probe_cache_count()) {return;}
    let slot=work[probe_cache_lru()+rank].load();
    if(probe_cache[slot].available.load()!=0u) {
        let offset=work[probe_cache_blocks()+rank/128u].load()+work[probe_cache_lru_scratch()+rank].load()-1u;
        work[probe_cache_reordered()+offset].store(slot);
    }
    if(rank<work[probe_cache_work()].load()) {
        let retained=work[probe_cache_work()+1u].load();
        work[probe_cache_reordered()+retained+rank].store(work[probe_cache_mru()+rank].load());
    }
}
[shader("compute")][numthreads(64,1,1)]
void copy_probe_cache_lru(uint3 gid : SV_DispatchThreadID) {
    let rank=gid.x+gid.y*65536u;if(rank>=probe_cache_count()) {return;}
    work[probe_cache_lru()+rank].store(work[probe_cache_reordered()+rank].load());
}

