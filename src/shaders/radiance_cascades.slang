// Surface Radiance Cascades: spatially coarser, angularly finer world-space intervals.
// The world hash cache remains the persistent secondary-surface lighting level.
#include "radiance_cascade_math.slang"
[[vk::binding(35,0)]] RWStructuredBuffer<float4> cascade_data;

uint2 cascade_dimensions(uint level) {
    let scale=1u<<level;return max((p.screen.xy+scale-1u)/scale,uint2(1u));
}
uint cascade_side(uint level) {return p.cascades.y<<level;}
uint cascade_direction_count(uint level) {let side=cascade_side(level);return side*side;}
uint cascade_probe_offset(uint level) {
    var offset=0u;for(var i=0u;i<level;i++) {let dims=cascade_dimensions(i);offset+=dims.x*dims.y;}return offset;
}
uint cascade_ray_offset(uint level) {
    var offset=0u;for(var i=0u;i<level;i++) {let dims=cascade_dimensions(i);offset+=dims.x*dims.y*cascade_direction_count(i);}return offset;
}
uint cascade_probe_count() {return cascade_probe_offset(p.cascades.x);}
uint cascade_raw_base() {return 3u*cascade_probe_count();}
uint cascade_merged_base() {return cascade_raw_base()+p.cascades.z;}
uint cascade_hits_base() {return cascade_merged_base()+p.cascades.z;}
uint cascade_ray_level(uint record,out uint ordinal) {
    ordinal=record;var level=0u;
    while(level<p.cascades.x) {let dims=cascade_dimensions(level);let count=dims.x*dims.y*cascade_direction_count(level);
        if(ordinal<count) {break;}ordinal-=count;level++;}
    return level;
}
void request_cascade_light_locations(float3 position) {
    // Fallback shading consumes all interval hits, not just cache-update seeds.
    // Reduce bounds per active subgroup before touching the streamed grid.
    let lower=WaveActiveMin(position);let upper=WaveActiveMax(position);
    let count=WaveActiveCountBits(true);
    if(WaveIsFirstLane()) {
        for(var axis=0u;axis<3u;axis++) {
            light_grid[axis].min(ordered_float(lower[axis]));
            light_grid[3u+axis].max(ordered_float(upper[axis]));
        }
        light_grid[6].add(count);
    }
}
float2 cascade_interval(uint level) {
    let near=p.cascade_sampling.x*float((1u<<level)-1u);
    let far=level+1u==p.cascades.x ? p.cache_config.w : p.cascade_sampling.x*float((1u<<(level+1u))-1u);
    return float2(near,far);
}
float4 cascade_read_direction(uint level,uint probe,float3 direction) {
    let side=cascade_side(level);let uv=cascade_direction_uv(direction);var value=float4(0.0);
    for(var sample=0u;sample<4u;sample++) {
        var weight=0.0;let cell=cascade_angular_sample(uv,side,sample,weight);
        value+=weight*cascade_data[cascade_merged_base()+cascade_ray_offset(level)+probe*side*side+cell.x+cell.y*side];
    }return value;
}
float3 cascade_outgoing(float3 position,Hit hit,float3 direction,uint seed,float ray_distance) {
    let normal=hit_normal(hit,direction);if(all(normal==float3(0.0))) {return float3(0.0);}
    var found=false;
    var reflected=directional_cached_radiance(position,direction,ray_distance,found,true,normal);
    if(!found) {
        var sampled=false;
        // Missing direct samples do not invalidate a populated indirect estimate.
        reflected+=directional_direct_radiance(position,normal,-direction,hit.triangle,seed,seed,sampled);
    }
    return safe_radiance(source_direct_radiance(material_emission(position,hit.triangle))+reflected);
}
[shader("compute")][numthreads(64,1,1)]
void prepare_cascade_probes(uint3 gid:SV_DispatchThreadID) {
    var ordinal=gid.x+gid.y*65536u;var level=0u;
    if(ordinal<p.cascades.w) {
        // Sparse phases may leave slots without writers. Consumers guard on
        // these validity fields; valid hit/bounce writers overwrite their data.
        rays[ordinal].info=uint4(MISSING);rays[ordinal].bounce_info=uint4(MISSING);
    }
    while(level<p.cascades.x) {let dims=cascade_dimensions(level);if(ordinal<dims.x*dims.y) {break;}ordinal-=dims.x*dims.y;level++;}
    if(level>=p.cascades.x) {return;}
    let dims=cascade_dimensions(level);let tile=uint2(ordinal%dims.x,ordinal/dims.x);
    let pixel=min((tile*(1u<<level)+(1u<<level)/2u)*p.screen.z+p.screen.z/2u,p.viewport.zw-1u);
    var index=min(pixel.y/p.screen.z,p.screen.y-1u)*p.screen.x+min(pixel.x/p.screen.z,p.screen.x-1u);
    if(probes[index].position.w==0.0) {index=find_closest_probe(pixel,int2(0));}
    let address=3u*(cascade_probe_offset(level)+ordinal);
    cascade_data[address]=float4(0.0);cascade_data[address+1u]=float4(0.0);cascade_data[address+2u]=float4(0.0);
    if(index==MISSING || probes[index].position.w==0.0) {return;}
    cascade_data[address]=probes[index].position;
    cascade_data[address+1u]=probes[index].normal;
    let packed=probes[index].info.y;
    cascade_data[address+2u]=float4(float(packed%p.viewport.z),float(packed/p.viewport.z),asfloat(index),0.0);
}
[shader("compute")][numthreads(64,1,1)]
void trace_cascade_intervals(uint3 gid:SV_DispatchThreadID) {
    let record=gid.x+gid.y*65536u;if(record>=p.cascades.z) {return;}
    var ordinal=0u;let level=cascade_ray_level(record,ordinal);
    let side=cascade_side(level);let probe=ordinal/(side*side);let bin=ordinal%(side*side);
    let address=3u*(cascade_probe_offset(level)+probe);let position=cascade_data[address];
    cascade_data[cascade_hits_base()+record]=float4(0.0,0.0,asfloat(MISSING),0.0);
    var value=float4(0.0,0.0,0.0,1.0);
    if(position.w!=0.0) {
        let direction=cascade_direction((float2(bin%side,bin/side)+0.5)/float(side));
        let normal=cascade_data[address+1u].xyz;
        // Surface receivers only consume their outward hemisphere. Terminate
        // inward intervals instead of tracing them into the source surface.
        if(dot(normal,direction)<=0.0) {cascade_data[cascade_raw_base()+record]=float4(0.0);return;}
        let range=cascade_interval(level);
        let origin=position.xyz+normal*p.cache_config.z;
        let segment=origin+direction*range.x;let hit=trace_impl_range(segment,direction,0.0,range.y-range.x,false);
        if(hit.triangle!=MISSING) {
            value=float4(0.0);
            let ray_distance=range.x+hit.distance;
            cascade_data[cascade_hits_base()+record]=float4(hit.uv,asfloat(hit.triangle),ray_distance);
            let point=segment+direction*hit.distance;
            request_cascade_light_locations(point);
            let stride=uint(p.cascade_sampling.y);
            let owner=asuint(cascade_data[address+2u].z);
            if(record%stride==p.frame.x%stride && probes[owner].info.w!=MISSING) {
                let index=record/stride;let n=hit_normal(hit,direction);
                if(all(n==float3(0.0))) {cascade_data[cascade_raw_base()+record]=value;return;}
                rays[index].position=float4(point,1.0);rays[index].normal=float4(n,float(ray_distance<hash_cell_size(point)));
                rays[index].direction=float4(direction,ray_distance);rays[index].value=float4(0.0,0.0,0.0,1.0);
                rays[index].info=uint4(MISSING,hit.triangle,bin,hash_tile_insert(point,direction,ray_distance,n));
                if(source_probe_projection()) {
                    if(rays[index].info.w!=MISSING) {rays[index].position.w=asfloat(source_append_visibility(index,false));}
                    if(source_direct_lighting_enabled() && any(geometry[hit.triangle+7u].rgb>float3(0.0)) &&
                        dot(cross(geometry[hit.triangle+1u].xyz-geometry[hit.triangle].xyz,
                            geometry[hit.triangle+2u].xyz-geometry[hit.triangle].xyz),direction)<0.0) {
                        rays[index].info.x=EMISSIVE_PROBE_RAY;
                    }
                } else {rays[index].info.x=cache_insert(point,n,ray_distance,hit.triangle,true);}
            }
        }
        else if(level+1u==p.cascades.x) {value=float4(source_direct_radiance(environment_radiance(direction)),0.0);}
    }
    cascade_data[cascade_raw_base()+record]=value;
}
[shader("compute")][numthreads(64,1,1)]
void shade_cascade_intervals(uint3 gid:SV_DispatchThreadID) {
    let record=gid.x+gid.y*65536u;if(record>=p.cascades.z) {return;}
    let data=cascade_data[cascade_hits_base()+record];let triangle=asuint(data.z);
    if(triangle==MISSING) {return;}
    var ordinal=0u;let level=cascade_ray_level(record,ordinal);let side=cascade_side(level);
    let bin=ordinal%(side*side);let address=3u*(cascade_probe_offset(level)+ordinal/(side*side));
    let direction=cascade_direction((float2(bin%side,bin/side)+0.5)/float(side));
    let origin=cascade_data[address].xyz+cascade_data[address+1u].xyz*p.cache_config.z;
    let hit=Hit(data.w,triangle,data.xy);
    cascade_data[cascade_raw_base()+record]=float4(cascade_outgoing(origin+direction*data.w,hit,direction,record,data.w),0.0);
}
float4 cascade_upper(uint level,float2 pixel,float3 position,float3 normal,float3 direction,float2 direction_uv,out bool valid) {
    let dims=cascade_dimensions(level);let coord=pixel/(float(p.screen.z)*float(1u<<level))-0.5;
    var value=float4(0.0);var total=0.0;
    let side=cascade_side(level);
    let near=cascade_interval(level).x;
    let start=cascade_boundary(position,normal,p.cache_config.z,direction,near);
    var offsets: float3[4]={};var weights: float[4]={};var bins: uint[4]={};
    // All spatial candidates share the same four angular samples. Generate
    // their boundary offsets once, using the original bin UV rather than atan2.
    for(var sample=0u;sample<4u;sample++) {
        var weight=0.0;let cell=cascade_angular_sample(direction_uv,side,sample,weight);
        offsets[sample]=cascade_direction((float2(cell)+0.5)/float(side))*near;
        weights[sample]=weight;
        bins[sample]=cell.x+cell.y*side;
    }
    for(var spatial=0u;spatial<4u;spatial++) {
        var weight=0.0;let tile=cascade_spatial_sample(coord,dims,spatial,weight);let probe=tile.x+tile.y*dims.x;
        let address=3u*(cascade_probe_offset(level)+probe);let other=cascade_data[address];
        if(other.w==0.0 || dot(normal,cascade_data[address+1u].xyz)<0.5) {continue;}
        let plane=abs(dot(other.xyz-position,normal));
        if(plane>max(cascade_interval(level).x*0.25,p.cache_config.z*4.0)) {continue;}
        let origin=other.xyz+cascade_data[address+1u].xyz*p.cache_config.z;
        var radiance=float4(0.0);var angular_weight=0.0;
        for(var sample=0u;sample<4u;sample++) {
            // Validate the actual angular-ray boundary, retaining the blocker
            // rejection that prevents shifted interval origins skipping geometry.
            let bridge=origin+offsets[sample]-start;let distance=length(bridge);
            if(distance>p.cache_config.z*2.0 && trace_impl_range(start,bridge/distance,0.0,distance-p.cache_config.z,true).triangle!=MISSING) {continue;}
            radiance+=weights[sample]*cascade_data[cascade_merged_base()+cascade_ray_offset(level)+probe*side*side+bins[sample]];
            angular_weight+=weights[sample];
        }
        if(angular_weight==0.0) {continue;}
        radiance/=angular_weight;
        value+=weight*radiance;total+=weight;
    }valid=total>0.0;return value/max(total,1e-20);
}
void cascade_merge_level(uint3 gid,uint level) {
    if(level>=p.cascades.x) {return;}
    let ordinal=gid.x+gid.y*65536u;let dims=cascade_dimensions(level);let side=cascade_side(level);
    if(ordinal>=dims.x*dims.y*side*side) {return;}
    let record=cascade_ray_offset(level)+ordinal;let near=cascade_data[cascade_raw_base()+record];var merged=near;
    let address=3u*(cascade_probe_offset(level)+ordinal/(side*side));let position=cascade_data[address];
    if(near.a>0.0 && position.w!=0.0 && level+1u<p.cascades.x) {
        let bin=ordinal%(side*side);let direction_uv=(float2(bin%side,bin/side)+0.5)/float(side);
        let direction=cascade_direction(direction_uv);
        var valid=false;var far=cascade_upper(level+1u,cascade_data[address+2u].xy,position.xyz,cascade_data[address+1u].xyz,direction,direction_uv,valid);
        if(!valid) {
            let origin=position.xyz+cascade_data[address+1u].xyz*p.cache_config.z+direction*cascade_interval(level).y;
            let hit=trace_impl_range(origin,direction,0.0,p.cache_config.w-cascade_interval(level).y,false);
            far=float4(hit.triangle==MISSING ? source_direct_radiance(environment_radiance(direction)) : cascade_outgoing(origin+direction*hit.distance,hit,direction,record,cascade_interval(level).y+hit.distance),0.0);
        }
        merged=cascade_merge_interval(near,far);
    }
    cascade_data[cascade_merged_base()+record]=merged;
}
[shader("compute")][numthreads(64,1,1)] void merge_cascade_4(uint3 gid:SV_DispatchThreadID) {cascade_merge_level(gid,4u);}
[shader("compute")][numthreads(64,1,1)] void merge_cascade_3(uint3 gid:SV_DispatchThreadID) {cascade_merge_level(gid,3u);}
[shader("compute")][numthreads(64,1,1)] void merge_cascade_2(uint3 gid:SV_DispatchThreadID) {cascade_merge_level(gid,2u);}
[shader("compute")][numthreads(64,1,1)] void merge_cascade_1(uint3 gid:SV_DispatchThreadID) {cascade_merge_level(gid,1u);}
[shader("compute")][numthreads(64,1,1)] void merge_cascade_0(uint3 gid:SV_DispatchThreadID) {cascade_merge_level(gid,0u);}
[shader("compute")][numthreads(64,1,1)]
void resolve_cascade_probes(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x+gid.y*65536u;let count=p.screen.x*p.screen.y;
    if(index>=count || probes[index].position.w==0.0) {return;}
    let side=cascade_side(0u);var irradiance=float3(0.0);var cosine_sum=0.0;
    for(var bin=0u;bin<side*side;bin++) {
        let direction=cascade_direction((float2(bin%side,bin/side)+0.5)/float(side));
        let cosine=max(dot(probes[index].normal.xyz,direction),0.0);
        irradiance+=cascade_data[cascade_merged_base()+index*side*side+bin].rgb*cosine;cosine_sum+=cosine;
    }
    // Normalize finite-grid cosine quadrature so a uniform environment retains
    // unit irradiance/pi for every surface orientation, not only the grid axis.
    irradiance/=max(cosine_sum,1e-20);
    probes[index].irradiance=float4(safe_radiance(irradiance),1.0);
    probes[index].filtered_irradiance=probes[index].irradiance;
    for(var bin=0u;bin<PROBE_DIRECTIONS;bin++) {
        let direction=hemisphere_ray(probes[index].normal.xyz,bin_uv(bin,float2(0.5)));
        probes[index].samples[bin]=probe_pack(float4(cascade_read_direction(0u,index,direction).rgb,p.cache_config.w));
        probes[index].filtered_samples[bin]=probes[index].samples[bin];
    }
}
float4 cascade_gather_diffuse(Surface s,uint2 pixel) {
    let weights=source_probe_interpolation(s,pixel);var value=float3(0.0);
    for(var i=0u;i<4u;i++) {if(weights.indices[i]!=MISSING) {value+=weights.weights[i]*probes[weights.indices[i]].irradiance.rgb;}}
    return float4(value,weights.hint);
}
float4 cascade_gather_directional(Surface s,uint2 pixel,float3 direction) {
    let weights=source_probe_interpolation(s,pixel);var value=float3(0.0);
    for(var i=0u;i<4u;i++) {if(weights.indices[i]!=MISSING) {value+=weights.weights[i]*cascade_read_direction(0u,weights.indices[i],direction).rgb;}}
    return float4(value,weights.hint);
}
