#include "gi.slang"
[[vk::binding(26,0)]] RWStructuredBuffer<float4> checks;
[shader("compute")][numthreads(1,1,1)]
void seed_grid_checks() {
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
