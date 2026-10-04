// AMD Capsaicin LightSamplerGridStream default volume build and merge estimators.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
[[vk::binding(28, 0)]] RWStructuredBuffer<Atomic<uint>> light_grid;
uint ordered_float(float value) {
    let bits=asuint(value);return select((bits&0x80000000u)!=0u, ~bits, bits^0x80000000u);
}
float unordered_float(uint value) {
    return asfloat(select((value&0x80000000u)!=0u, value^0x80000000u, ~value));
}
void request_light_location(float3 position) {
    for(var i=0u;i<3u;i++) {light_grid[i].min(ordered_float(position[i]));light_grid[3u+i].max(ordered_float(position[i]));}
    light_grid[6].add(1u);
}
uint grid_random_uint(inout uint state) {
    let old=state;state=old*747796405u+2891336453u;
    var word=((old>>((old>>28u)+4u))^old)*277803737u;word=(word>>22u)^word;
    return word;
}
float grid_random(inout uint state) {return float(grid_random_uint(state)>>8u)/16777216.0;}
[shader("compute")][numthreads(1,1,1)]
void clear_light_grid_bounds() {
    for(var i=0u;i<3u;i++) {light_grid[i].store(ordered_float(1e30));light_grid[3u+i].store(ordered_float(-1e30));}
    light_grid[6].store(0u);
}
uint4 grid_dimensions() {return uint4(light_grid[8].load(),light_grid[9].load(),light_grid[10].load(),light_grid[11].load());}
float3 grid_minimum() {return float3(asfloat(light_grid[12].load()),asfloat(light_grid[13].load()),asfloat(light_grid[14].load()));}
float3 grid_cell_size() {return float3(asfloat(light_grid[16].load()),asfloat(light_grid[17].load()),asfloat(light_grid[18].load()));}
uint grid_faces() {return select((p.light_grid.z&2u)!=0u,8u,1u);}
bool grid_parallel() {return (p.light_grid.z&8u)!=0u && grid_light_count()>128u*p.light_grid.y;}
[shader("compute")][numthreads(1,1,1)]
void calculate_light_grid_bounds() {
    var lower=float3(0.0);var upper=float3(1.0);
    if (light_grid[6].load()>0u) {
        for(var i=0u;i<3u;i++) {lower[i]=unordered_float(light_grid[i].load());upper[i]=unordered_float(light_grid[3u+i].load());}
    } else if (p.scene_info.x>0u) {lower=geometry[0].xyz;upper=geometry[1].xyz;}
    // A flat set of requested samples must still have finite grid coordinates.
    let extent=max(upper-lower,float3(0.001));let scale=max(max(extent.x,extent.y),extent.z)/float(p.light_grid.x);
    let cells=min(uint3(max(ceil(extent/scale),float3(1.0))),uint3(p.light_grid.x));let size=extent/float3(cells);
    for(var i=0u;i<3u;i++) {
        light_grid[8u+i].store(cells[i]);light_grid[12u+i].store(asuint(lower[i]));
        light_grid[16u+i].store(asuint(size[i]));light_grid[20u+i].store(asuint(extent[i]));
    }
    let slots=min(p.light_grid.y,grid_light_count());light_grid[11].store(slots);
    let count=cells.x*cells.y*cells.z*slots*grid_faces();
    if (grid_parallel()) {work[24].store(min(count,65535u));work[25].store((count+65534u)/65535u);}
    else {work[24].store((min(count,65536u)+63u)/64u);work[25].store((count+65535u)/65536u);}
    work[26].store(1u);
}
float grid_point_weight(uint light_index, float3 position) {
    if(grid_environment_light(light_index)) {return grid_environment_weight(float3(0.0),false);}
    let index=light_index*5u;let a=lights[index];let b=lights[index+1u];let c=lights[index+2u];let emission=lights[index+3u];
    if (emission.w==0.0) {return luminance(emission.rgb);}
    var radiance=emission.rgb;
    if (emission.w>=3.0) {
        let center=(a.xyz+b.xyz+c.xyz)/3.0;let vector=position-center;let distance_squared=dot(vector,vector);
        let area_normal=cross(b.xyz-a.xyz,c.xyz-a.xyz);let area2=length(area_normal);
        if (distance_squared<=0.0 || area2<=0.0) {return 0.0;}
        radiance=material_emission(center,uint(b.w));
        return luminance(radiance)*(0.5*area2*abs(dot(area_normal/area2,vector/sqrt(distance_squared)))/distance_squared);
    }
    let delta=a.xyz-position;let distance_squared=dot(delta,delta);
    let range4=pow(max(a.w,1e-8),4.0);
    return luminance(radiance)*clamp(1.0-distance_squared*distance_squared/range4,0.0,1.0)/(0.0001+distance_squared);
}
float grid_point_normal_weight(uint light_index,float3 position,float3 normal) {
    if(grid_environment_light(light_index)) {return grid_environment_weight(environment_rotate(p.environment_rotation,normal),true);}
    let index=light_index*5u;let a=lights[index];let b=lights[index+1u];let c=lights[index+2u];let kind=lights[index+3u].w;
    var cosine=0.0;
    if (kind==0.0) {cosine=clamp(dot(a.xyz,normal),0.0,1.0);}
    else if (kind>=3.0) {
        // Average the three vertex angles so a partially visible triangle is retained.
        cosine=(clamp(dot(normalize(a.xyz-position),normal),0.0,1.0)
            +clamp(dot(normalize(b.xyz-position),normal),0.0,1.0)
            +clamp(dot(normalize(c.xyz-position),normal),0.0,1.0))/3.0;
    } else {let vector=a.xyz-position;cosine=dot(vector,vector)>0.0?clamp(dot(normalize(vector),normal),0.0,1.0):0.0;}
    return grid_point_weight(light_index,position)*cosine;
}
float grid_volume_weight(uint light_index, float3 minimum, float3 extent,float3 normal) {
    if(grid_environment_light(light_index)) {
        return grid_environment_weight(environment_rotate(p.environment_rotation,normal),grid_faces()==8u);
    }
    let index=light_index*5u;let a=lights[index];let b=lights[index+1u];let emission=lights[index+3u];
    let directional=grid_faces()==8u;
    if (emission.w==0.0) {return select(directional && dot(a.xyz,normal)<=-0.7071,0.0,luminance(emission.rgb));}
    let center=minimum+extent*0.5;
    var light_position=a.xyz;
    if (emission.w>=3.0) {light_position=(a.xyz+b.xyz+lights[index+2u].xyz)/3.0;}
    let inside=all(light_position>=minimum) && all(light_position<=minimum+extent);
    if (directional && !inside) {
        if (emission.w>=3.0) {
            if (dot(a.xyz-center,normal)<=-0.7071 && dot(b.xyz-center,normal)<=-0.7071 && dot(lights[index+2u].xyz-center,normal)<=-0.7071) {return 0.0;}
        } else if (dot(a.xyz-center,normal)<=-0.7071) {return 0.0;}
    }
    var overlap=1.0;
    if (emission.w>0.0 && emission.w<3.0) {
        let direction=center-a.xyz;let radius_squared=dot(extent*0.5,extent*0.5);let radius=sqrt(radius_squared);
        if (dot(direction,direction)>pow(radius+a.w,2.0)) {return 0.0;}
        var radius2=a.w;var distance_squared=dot(direction,direction);
        var cone_offset=0.0;var cone_tangent=0.0;
        if (emission.w==2.0) {
            // Hale's cone/sphere test. b.xyz is the positive cone axis here.
            let axis=-b.xyz;let sine=sqrt(max(1.0-b.w*b.w,0.0));let tangent=sine/max(b.w,1e-6);
            let offset=radius*sine;var intersects=false;
            if (dot(direction+axis*offset,axis)<0.0) {
                let point=direction*sine-axis*radius;let length_a=dot(point,axis);
                intersects=dot(point,point)<=length_a*length_a*(tangent*tangent+1.0);
            } else {intersects=dot(direction,direction)<=radius_squared;}
            if (!intersects) {return 0.0;}
            cone_offset=dot(direction,axis);cone_tangent=tangent;
            radius2=cone_offset*cone_offset*(tangent*tangent+1.0);
            let compare=direction+axis*cone_offset;distance_squared=dot(compare,compare);
        }
        if ((p.light_grid.z&4u)!=0u) {
            let difference=radius-radius2;let difference_squared=difference*difference;
            if (distance_squared>difference_squared) {
                let distance=sqrt(distance_squared);let combined=radius+radius2;
                overlap=pow(combined-distance,2.0)*(distance_squared+2.0*distance*combined-3.0*difference_squared)/(16.0*distance*radius_squared*radius);
            } else if (radius>radius2) {
                if (emission.w==2.0) {overlap=cone_tangent*abs(cone_offset)*sqrt(max(radius_squared-dot(direction,direction)+cone_offset*cone_offset,0.0))/(radius_squared*radius);}
                else {overlap=radius2*radius2*radius2/(radius_squared*radius);}
            }
            overlap=clamp(overlap,0.0,1.0);
        }
    }
    if ((p.light_grid.z&1u)!=0u) {return overlap*grid_point_weight(light_index,center);}
    var sum=0.0;
    for(var corner=0u;corner<8u;corner++) {
        let offset=float3(float(corner&1u),float((corner>>1u)&1u),float((corner>>2u)&1u));
        let point=minimum+extent*offset;
        var weight=grid_point_weight(light_index,point);
        let vector=point-light_position;
        if (directional && !inside && dot(vector,vector)>0.0 && dot(normalize(vector),normal)>=0.7071) {weight=0.0;}
        sum+=weight;
    }
    return overlap*sum*0.125;
}
float grid_reservoir_weight(uint reservoir_index,uint light) {
    let dims=grid_dimensions();let faces=grid_faces();let face=(reservoir_index/dims.w)%faces;
    let cell_index=reservoir_index/(dims.w*faces);
    let cell=uint3(cell_index%dims.x,(cell_index/dims.x)%dims.y,cell_index/(dims.x*dims.y));
    let normal=normalize(float3(select((face&1u)!=0u,-1.0,1.0),select((face&2u)!=0u,-1.0,1.0),select((face&4u)!=0u,-1.0,1.0)));
    let size=grid_cell_size();let minimum=grid_minimum()+(float3(cell)-0.5)*size;
    return grid_volume_weight(light,minimum,size*2.0,normal);
}
[shader("compute")][numthreads(64,1,1)]
void build_light_grid(uint3 gid : SV_DispatchThreadID) {
    let lane=gid.x+gid.y*65536u;let dims=grid_dimensions();let count=dims.x*dims.y*dims.z*dims.w*grid_faces();
    if (lane>=count || dims.w==0u) {return;}
    let reservoir=lane%dims.w;
    let increment=(p.frame.x<<1u)|1u;var rng=(pcg_hash(lane)+increment)*747796405u+increment;
    if(source_probe_projection()) {rng=source_random(lane,p.frame.x);}
    var selected=MISSING;var selected_weight=0.0;var total=0.0;var j=grid_random(rng);var none_probability=1.0;
    for(var light=reservoir;light<grid_light_count();light+=dims.w) {
        let weight=grid_reservoir_weight(lane,light);if (!(weight>0.0)) {continue;}
        total+=weight;let probability=weight/total;j-=probability*none_probability;none_probability*=1.0-probability;
        if (j<=0.0) {selected=light;selected_weight=weight;j=grid_random(rng);none_probability=1.0;}
    }
    let address=24u+lane*4u;light_grid[address].store(selected);
    light_grid[address+1u].store(asuint(selected_weight));light_grid[address+2u].store(asuint(total));
}
groupshared uint grid_partial_light[128];
groupshared float grid_partial_target[128];
groupshared float grid_partial_total[128];
[shader("compute")][numthreads(128,1,1)]
void build_light_grid_parallel(uint3 group : SV_GroupID,uint thread : SV_GroupIndex) {
    let lane=group.x+group.y*65535u;let dims=grid_dimensions();let count=dims.x*dims.y*dims.z*dims.w*grid_faces();
    if (lane>=count || dims.w==0u) {return;}
    var rng=pcg_hash(lane*128u+thread+p.frame.x);
    if(source_probe_projection()) {rng=source_random(lane,p.frame.x);}
    var selected=MISSING;var selected_weight=0.0;var total=0.0;var j=grid_random(rng);var none_probability=1.0;
    for(var light=lane%dims.w+thread*dims.w;light<grid_light_count();light+=128u*dims.w) {
        let weight=grid_reservoir_weight(lane,light);if (!(weight>0.0)) {continue;}
        total+=weight;let probability=weight/total;j-=probability*none_probability;none_probability*=1.0-probability;
        if (j<=0.0) {selected=light;selected_weight=weight;j=grid_random(rng);none_probability=1.0;}
    }
    var partial_count=128u;
    if(source_probe_projection()) {
        let cdf=WavePrefixSum(total)+total;
        total=WaveActiveSum(total);j=grid_random(rng);
        let valid=j*total<=cdf;
        let first=WavePrefixCountBits(valid);
        let winner=valid && first==0u;
        let wave_size=WaveGetLaneCount();
        if(wave_size==128u) {
            if(winner) {
                let address=24u+lane*4u;light_grid[address].store(selected);
                light_grid[address+1u].store(asuint(selected_weight));light_grid[address+2u].store(asuint(total));
            }
            return;
        }
        let wave=thread/wave_size;
        if(winner) {
            grid_partial_light[wave]=selected;grid_partial_target[wave]=selected_weight;grid_partial_total[wave]=total;
        }
        // Unlike the source's early return, every lane reaches the group barrier.
        GroupMemoryBarrierWithGroupSync();
        if(!winner || wave!=0u) {return;}
        partial_count=128u/wave_size;
    } else {
        grid_partial_light[thread]=selected;grid_partial_target[thread]=selected_weight;grid_partial_total[thread]=total;
        GroupMemoryBarrierWithGroupSync();
        if (thread!=0u) {return;}
    }
    selected=MISSING;selected_weight=0.0;total=0.0;j=grid_random(rng);none_probability=1.0;
    for(var i=0u;i<partial_count;i++) {
        let weight=grid_partial_total[i];if (!(weight>0.0)) {continue;}
        total+=weight;let probability=weight/total;j-=probability*none_probability;none_probability*=1.0-probability;
        if (j<=0.0) {selected=grid_partial_light[i];selected_weight=grid_partial_target[i];j=grid_random(rng);none_probability=1.0;}
    }
    let address=24u+lane*4u;light_grid[address].store(selected);light_grid[address+1u].store(asuint(selected_weight));light_grid[address+2u].store(asuint(total));
}
uint grid_start(float3 position,float3 normal,inout uint rng) {
    let dims=grid_dimensions();let size=grid_cell_size();
    let jitter=(float3(grid_random(rng),grid_random(rng),grid_random(rng))-0.5)*size;
    let cell=uint3(clamp(floor((position+jitter-grid_minimum())/size),float3(0.0),float3(dims.xyz)-1.0));
    let face=select(grid_faces()==8u,uint(normal.x<0.0)+2u*uint(normal.y<0.0)+4u*uint(normal.z<0.0),0u);
    return ((cell.x+dims.x*(cell.y+dims.y*cell.z))*grid_faces()+face)*dims.w;
}
struct GridLight {
    var index: uint;
    var pdf: float;
};
GridLight grid_merge(uint start, uint count, float3 position, float3 normal, inout uint rng) {
    if (count==0u) {return GridLight(MISSING,0.0);}
    if ((p.light_grid.w&3u)==0u) {
        let slot=min(uint(grid_random(rng)*float(count)),count-1u);let address=24u+(start+slot)*4u;
        let target=asfloat(light_grid[address+1u].load());let total=asfloat(light_grid[address+2u].load());
        return GridLight(light_grid[address].load(),target/max(total*float(count),1e-20));
    }
    var selected=MISSING;var selected_weight=0.0;var total=0.0;var j=grid_random(rng);var none_probability=1.0;
    for(var i=0u;i<count;i++) {
        let address=24u+(start+i)*4u;let light=light_grid[address].load();if (light>=grid_light_count()) {continue;}
        var target=asfloat(light_grid[address+1u].load());var weight=asfloat(light_grid[address+2u].load());
        if ((p.light_grid.w&4u)!=0u) {
            // Local point/normal importance resampling retains the original
            // reservoir's inverse selection probability.
            let new_target=grid_point_normal_weight(light,position,normal);weight*=new_target/max(target,1e-20);target=new_target;
        }
        if (!(weight>0.0)) {continue;}
        total+=weight;let probability=weight/total;j-=probability*none_probability;none_probability*=1.0-probability;
        if (j<=0.0) {selected=light;selected_weight=target;j=grid_random(rng);none_probability=1.0;}
    }
    return GridLight(selected,selected_weight/max(total,1e-20));
}
// Reservoir_EvaluateTargetPdfNormalized. GI-1.2's GenerateReservoirs forces
// secondary materials to roughness=1 and metallicity=0 before evaluating RIS.
float grid_target_cone(float3 position,float3 normal,float3 view,uint triangle,uint light,float2 uv,float solid_angle) {
    let sample=evaluate_light_cone(position,normal,light,uv,solid_angle);
    if (triangle==MISSING || all(sample.value==float3(0.0))) {return luminance(sample.value);}
    let base=geometry[triangle+13u].rgb*material_texture(uint(geometry[triangle+11u].x),triangle_uv(triangle,barycentrics(position,triangle),0u)).rgb;
    let reflectance=geometry[triangle+12u].y;let f0=float3(0.16*reflectance*reflectance);
    let half_vector=normalize(view+sample.direction);
    let diffuse=base*diffuse_compensation(f0,dot(half_vector,view));
    let specular=specular_brdf(normal,view,sample.direction,f0,1.0);
    let lut=sample_brdf_lut(clamp(dot(normal,view),0.0,1.0),1.0);
    let albedo=luminance(base)+luminance(clamp(f0*lut.x+(float3(1.0)-f0)*lut.y,float3(0.0),float3(1.0)));
    if (!(albedo>0.0)) {return luminance(sample.value);}
    return luminance(sample.value*(diffuse+PI*specular))/albedo;
}
float grid_target(float3 position,float3 normal,float3 view,uint triangle,uint light,float2 uv) {
    return grid_target_cone(position,normal,view,triangle,light,uv,4.0*PI/(8.0*1.5));
}
Reservoir grid_fresh_reservoir(float3 position, float3 normal, float3 view, uint triangle, inout uint rng) {
    var result=Reservoir(MISSING,float2(0.0),0.0,0.0,0u);let count=grid_dimensions().w;if (count==0u) {return result;}
    let start=grid_start(position,normal,rng);var samples: GridLight[8] = {};var added=0u;
    if ((p.light_grid.w&3u)==1u) {
        let segment=(count+7u)/8u;
        for(var i=0u;i<min(count,8u);i++) {
            let offset=i*segment;if (offset>=count) {break;} // prevent upstream unsigned segment underflow
            let sample=grid_merge(start+offset,min(segment,count-offset),position,normal,rng);
            if (sample.index<grid_light_count() && sample.pdf>0.0) {samples[added]=sample;added++;}
        }
        for(var i=0u;i<added;i++) {
            let sample=samples[i];let uv=float2(random(rng),random(rng));let target=grid_target(position,normal,view,triangle,sample.index,uv);
            reservoir_add(result,sample.index,uv,target,target*float(added)/sample.pdf,1u,rng);
        }
    } else {
        for(var i=0u;i<8u;i++) {
            let sample=grid_merge(start,count,position,normal,rng);
            // Empty uniformly selected slots are zero-contribution draws. Dropping
            // them from M would condition on success and brighten sparse cells.
            if (sample.index>=grid_light_count() || sample.pdf<=0.0) {result.count++;continue;}
            let uv=float2(random(rng),random(rng));let target=grid_target(position,normal,view,triangle,sample.index,uv);
            reservoir_add(result,sample.index,uv,target,target/sample.pdf,1u,rng);
        }
    }
    return result;
}
