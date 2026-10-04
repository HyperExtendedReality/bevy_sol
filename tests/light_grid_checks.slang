#include "gi.slang"
[[vk::binding(26,0)]] RWStructuredBuffer<float4> checks;
[shader("compute")][numthreads(1,1,1)]
void seed_grid_checks() {
    let base=probe_random_seeds();
    let seeds=uint[8](3499211612u,581869302u,3890346734u,3586334585u,545404204u,4161255391u,3922919429u,949333985u);
    work[base].store(8u);
    for(var i=0u;i<8u;i++) {work[base+1u+i].store(seeds[i]);}
    request_light_location(float3(-1.0,0.0,1.0));
    request_light_location(float3(1.0,0.0,1.0));
}
[shader("compute")][numthreads(64,1,1)]
void discard_odd_grid_checks(uint3 gid : SV_DispatchThreadID) {
    let dims=grid_dimensions();let count=dims.x*dims.y*dims.z*dims.w*grid_faces();
    if ((p.light_grid.w&8u)==0u || gid.x>=count || dims.w==0u || (gid.x%dims.w)%2u==0u) {return;}
    let address=24u+gid.x*4u;
    light_grid[address].store(MISSING);light_grid[address+1u].store(0u);light_grid[address+2u].store(0u);
}
[shader("compute")][numthreads(64,1,1)]
void read_grid_checks(uint3 gid : SV_DispatchThreadID) {
    if (gid.x==0u) {checks[0]=float4(grid_dimensions());checks[1]=float4(grid_cell_size(),float(light_grid[6].load()));}
    var rng=pcg_hash(gid.x+123u);
    let r=grid_fresh_reservoir(float3(0.0,0.0,1.0),float3(0.0,0.0,1.0),float3(0.0,0.0,1.0),MISSING,rng);
    checks[2u+gid.x]=float4(r.weight_sum/max(float(r.count),1.0),float(r.count),float(r.light),r.target_density);
}
[shader("compute")][numthreads(1,1,1)]
void material_target_checks() {
    let lut=sample_brdf_lut(1.0,1.0);
    let target=grid_target(float3(0.0,0.0,1.0),float3(0.0,0.0,1.0),float3(0.0,0.0,1.0),0u,0u,float2(0.5));
    checks[2050]=float4(target,lut,0.0);
    checks[2051]=float4(grid_volume_weight(8193u,float3(-0.5),float3(1.0),normalize(float3(1.0))),
        grid_volume_weight(8194u,float3(-0.5),float3(1.0),normalize(float3(1.0))),float(grid_parallel()),float(grid_faces()));
}

// Scalar reference for the pinned builder's per-wave CDF and wave merge.
[shader("compute")][numthreads(128,1,1)]
void parallel_source_checks(uint thread:SV_GroupIndex) {
    let wave_size=WaveGetLaneCount();
    if(thread>=4u || !source_probe_projection() || !grid_parallel()) {return;}
    let lane=thread;let slots=grid_dimensions().w;
    var ids:uint[128];var targets:float[128];var totals:float[128];var states:uint[128];
    for(var t=0u;t<128u;t++) {
        var rng=source_random(lane,p.frame.x);var j=grid_random(rng);var none=1.0;
        var total=0.0;var selected=MISSING;var target=0.0;
        for(var light=lane%slots+t*slots;light<grid_light_count();light+=128u*slots) {
            let weight=grid_reservoir_weight(lane,light);if(!(weight>0.0)) {continue;}
            total+=weight;let probability=weight/total;j-=probability*none;none*=1.0-probability;
            if(j<=0.0) {selected=light;target=weight;j=grid_random(rng);none=1.0;}
        }
        ids[t]=selected;targets[t]=target;totals[t]=total;states[t]=rng;
    }
    var wave_ids:uint[8];var wave_targets:float[8];var wave_totals:float[8];
    var first_state=0u;
    let waves=128u/wave_size;
    for(var wave=0u;wave<waves;wave++) {
        var sum=0.0;for(var t=0u;t<wave_size;t++) {sum+=totals[wave*wave_size+t];}
        var cdf=0.0;var chosen=false;
        for(var t=0u;t<wave_size;t++) {
            let index=wave*wave_size+t;cdf+=totals[index];var rng=states[index];
            let j=grid_random(rng);
            if(!chosen && j*sum<=cdf) {
                chosen=true;wave_ids[wave]=ids[index];wave_targets[wave]=targets[index];
                if(wave==0u) {first_state=rng;}
            }
        }
        wave_totals[wave]=sum;
    }
    var selected=wave_ids[0];var target=wave_targets[0];var total=wave_totals[0];
    if(waves>1u) {
        selected=MISSING;target=0.0;total=0.0;var j=grid_random(first_state);var none=1.0;
        for(var wave=0u;wave<waves;wave++) {
            let weight=wave_totals[wave];if(!(weight>0.0)) {continue;}
            total+=weight;let probability=weight/total;j-=probability*none;none*=1.0-probability;
            if(j<=0.0) {selected=wave_ids[wave];target=wave_targets[wave];j=grid_random(first_state);none=1.0;}
        }
    }
    let address=24u+lane*4u;
    checks[2052u+lane]=float4(float(selected==light_grid[address].load()),
        abs(total-asfloat(light_grid[address+2u].load()))/max(total,1.0),
        float(target==asfloat(light_grid[address+1u].load())),float(wave_size));
}
