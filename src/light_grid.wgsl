// AMD Capsaicin LightSamplerGridStream default volume build and merge estimators.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
@group(0) @binding(28) var<storage, read_write> light_grid: array<atomic<u32>>;
fn ordered_float(value: f32) -> u32 {
    let bits=bitcast<u32>(value);return select(bits^0x80000000u,~bits,(bits&0x80000000u)!=0u);
}
fn unordered_float(value: u32) -> f32 {
    return bitcast<f32>(select(~value,value^0x80000000u,(value&0x80000000u)!=0u));
}
fn request_light_location(position: vec3<f32>) {
    for(var i=0u;i<3u;i++) {atomicMin(&light_grid[i],ordered_float(position[i]));atomicMax(&light_grid[3u+i],ordered_float(position[i]));}
    atomicAdd(&light_grid[6],1u);
}
fn grid_random(state: ptr<function,u32>) -> f32 {
    let old=*state;*state=old*747796405u+2891336453u;
    var word=((old>>((old>>28u)+4u))^old)*277803737u;word=(word>>22u)^word;
    return f32(word>>8u)/16777216.0;
}
@compute @workgroup_size(1)
fn clear_light_grid_bounds() {
    for(var i=0u;i<3u;i++) {atomicStore(&light_grid[i],ordered_float(1e30));atomicStore(&light_grid[3u+i],ordered_float(-1e30));}
    atomicStore(&light_grid[6],0u);
}
fn grid_dimensions() -> vec4<u32> {return vec4(atomicLoad(&light_grid[8]),atomicLoad(&light_grid[9]),atomicLoad(&light_grid[10]),atomicLoad(&light_grid[11]));}
fn grid_minimum() -> vec3<f32> {return vec3(bitcast<f32>(atomicLoad(&light_grid[12])),bitcast<f32>(atomicLoad(&light_grid[13])),bitcast<f32>(atomicLoad(&light_grid[14])));}
fn grid_cell_size() -> vec3<f32> {return vec3(bitcast<f32>(atomicLoad(&light_grid[16])),bitcast<f32>(atomicLoad(&light_grid[17])),bitcast<f32>(atomicLoad(&light_grid[18])));}
@compute @workgroup_size(1)
fn calculate_light_grid_bounds() {
    var lower=vec3(0.0);var upper=vec3(1.0);
    if atomicLoad(&light_grid[6])>0u {
        for(var i=0u;i<3u;i++) {lower[i]=unordered_float(atomicLoad(&light_grid[i]));upper[i]=unordered_float(atomicLoad(&light_grid[3u+i]));}
    } else if p.scene_info.x>0u {lower=geometry[0].xyz;upper=geometry[1].xyz;}
    // A flat set of requested samples must still have finite grid coordinates.
    let extent=max(upper-lower,vec3(0.001));let scale=max(max(extent.x,extent.y),extent.z)/f32(p.light_grid.x);
    let cells=vec3<u32>(max(ceil(extent/scale),vec3(1.0)));let size=extent/vec3<f32>(cells);
    for(var i=0u;i<3u;i++) {
        atomicStore(&light_grid[8u+i],cells[i]);atomicStore(&light_grid[12u+i],bitcast<u32>(lower[i]));
        atomicStore(&light_grid[16u+i],bitcast<u32>(size[i]));atomicStore(&light_grid[20u+i],bitcast<u32>(extent[i]));
    }
    let slots=min(p.light_grid.y,p.scene_info.y);atomicStore(&light_grid[11],slots);
    let count=cells.x*cells.y*cells.z*slots;
    atomicStore(&work[24],(min(count,65536u)+63u)/64u);atomicStore(&work[25],(count+65535u)/65536u);atomicStore(&work[26],1u);
}
fn grid_point_weight(light_index:u32,position:vec3<f32>) -> f32 {
    let index=light_index*5u;let a=lights[index];let b=lights[index+1u];let c=lights[index+2u];let emission=lights[index+3u];
    if emission.w==0.0 {return luminance(emission.rgb);}
    var radiance=emission.rgb;
    if emission.w>=3.0 {
        let center=(a.xyz+b.xyz+c.xyz)/3.0;let vector=position-center;let distance_squared=dot(vector,vector);
        let area_normal=cross(b.xyz-a.xyz,c.xyz-a.xyz);let area2=length(area_normal);
        if distance_squared<=0.0 || area2<=0.0 {return 0.0;}
        radiance=material_emission(center,u32(b.w));
        return luminance(radiance)*(0.5*area2*abs(dot(area_normal/area2,vector/sqrt(distance_squared)))/distance_squared);
    }
    let delta=a.xyz-position;let distance_squared=dot(delta,delta);
    let range4=pow(max(a.w,1e-8),4.0);
    return luminance(radiance)*clamp(1.0-distance_squared*distance_squared/range4,0.0,1.0)/(0.0001+distance_squared);
}
fn grid_volume_weight(light_index:u32,minimum:vec3<f32>,extent:vec3<f32>) -> f32 {
    let index=light_index*5u;let a=lights[index];let b=lights[index+1u];let emission=lights[index+3u];
    if emission.w==0.0 {return luminance(emission.rgb);}
    let center=minimum+extent*0.5;
    if emission.w>0.0 && emission.w<3.0 {
        let direction=center-a.xyz;let radius_squared=dot(extent*0.5,extent*0.5);let radius=sqrt(radius_squared);
        if dot(direction,direction)>pow(radius+a.w,2.0) {return 0.0;}
        if emission.w==2.0 {
            // Hale's cone/sphere test. b.xyz is the positive cone axis here.
            let axis=-b.xyz;let sine=sqrt(max(1.0-b.w*b.w,0.0));let tangent=sine/max(b.w,1e-6);
            let offset=radius*sine;var intersects=false;
            if dot(direction+axis*offset,axis)<0.0 {
                let point=direction*sine-axis*radius;let length_a=dot(point,axis);
                intersects=dot(point,point)<=length_a*length_a*(tangent*tangent+1.0);
            } else {intersects=dot(direction,direction)<=radius_squared;}
            if !intersects {return 0.0;}
        }
    }
    if p.light_grid.z!=0u {return grid_point_weight(light_index,center);}
    var sum=0.0;
    for(var corner=0u;corner<8u;corner++) {
        let offset=vec3(f32(corner&1u),f32((corner>>1u)&1u),f32((corner>>2u)&1u));
        sum+=grid_point_weight(light_index,minimum+extent*offset);
    }
    return sum*0.125;
}
@compute @workgroup_size(64)
fn build_light_grid(@builtin(global_invocation_id) gid:vec3<u32>) {
    let lane=gid.x+gid.y*65536u;let dims=grid_dimensions();let count=dims.x*dims.y*dims.z*dims.w;
    if lane>=count || dims.w==0u {return;}
    let reservoir=lane%dims.w;let cell_index=lane/dims.w;
    let cell=vec3(cell_index%dims.x,(cell_index/dims.x)%dims.y,cell_index/(dims.x*dims.y));
    let size=grid_cell_size();let minimum=grid_minimum()+(vec3<f32>(cell)-0.5)*size;let extent=size*2.0;
    let increment=(p.frame.x<<1u)|1u;var rng=(pcg_hash(lane)+increment)*747796405u+increment;
    var selected=MISSING;var selected_weight=0.0;var total=0.0;var j=grid_random(&rng);var none_probability=1.0;
    for(var light=reservoir;light<p.scene_info.y;light+=dims.w) {
        let weight=grid_volume_weight(light,minimum,extent);if !(weight>0.0) {continue;}
        total+=weight;let probability=weight/total;j-=probability*none_probability;none_probability*=1.0-probability;
        if j<=0.0 {selected=light;selected_weight=weight;j=grid_random(&rng);none_probability=1.0;}
    }
    let address=24u+lane*4u;atomicStore(&light_grid[address],selected);
    atomicStore(&light_grid[address+1u],bitcast<u32>(selected_weight));atomicStore(&light_grid[address+2u],bitcast<u32>(total));
}
fn grid_start(position:vec3<f32>,rng:ptr<function,u32>) -> u32 {
    let dims=grid_dimensions();let size=grid_cell_size();
    let jitter=(vec3(grid_random(rng),grid_random(rng),grid_random(rng))-0.5)*size;
    let cell=vec3<u32>(clamp(floor((position+jitter-grid_minimum())/size),vec3(0.0),vec3<f32>(dims.xyz)-1.0));
    return (cell.x+dims.x*(cell.y+dims.y*cell.z))*dims.w;
}
struct GridLight {index:u32,pdf:f32}
fn grid_merge(start:u32,count:u32,position:vec3<f32>,normal:vec3<f32>,rng:ptr<function,u32>) -> GridLight {
    if count==0u {return GridLight(MISSING,0.0);}
    if (p.light_grid.w&3u)==0u {
        let slot=min(u32(grid_random(rng)*f32(count)),count-1u);let address=24u+(start+slot)*4u;
        let target=bitcast<f32>(atomicLoad(&light_grid[address+1u]));let total=bitcast<f32>(atomicLoad(&light_grid[address+2u]));
        return GridLight(atomicLoad(&light_grid[address]),target/max(total*f32(count),1e-20));
    }
    var selected=MISSING;var selected_weight=0.0;var total=0.0;var j=grid_random(rng);var none_probability=1.0;
    for(var i=0u;i<count;i++) {
        let address=24u+(start+i)*4u;let light=atomicLoad(&light_grid[address]);if light>=p.scene_info.y {continue;}
        var target=bitcast<f32>(atomicLoad(&light_grid[address+1u]));var weight=bitcast<f32>(atomicLoad(&light_grid[address+2u]));
        if (p.light_grid.w&4u)!=0u {
            // Local point/normal importance resampling retains the original
            // reservoir's inverse selection probability.
            let evaluated=evaluate_light(position,normal,light,vec2(1.0/3.0));
            let new_target=luminance(evaluated.value);weight*=new_target/max(target,1e-20);target=new_target;
        }
        if !(weight>0.0) {continue;}
        total+=weight;let probability=weight/total;j-=probability*none_probability;none_probability*=1.0-probability;
        if j<=0.0 {selected=light;selected_weight=target;j=grid_random(rng);none_probability=1.0;}
    }
    return GridLight(selected,selected_weight/max(total,1e-20));
}
fn grid_fresh_reservoir(position:vec3<f32>,normal:vec3<f32>,rng:ptr<function,u32>) -> Reservoir {
    var result=Reservoir(MISSING,vec2(0.0),0.0,0.0,0u);let count=grid_dimensions().w;if count==0u {return result;}
    let start=grid_start(position,rng);var samples:array<GridLight,8>;var added=0u;
    if (p.light_grid.w&3u)==1u {
        let segment=(count+7u)/8u;
        for(var i=0u;i<min(count,8u);i++) {
            let offset=i*segment;if offset>=count {break;} // prevent upstream unsigned segment underflow
            let sample=grid_merge(start+offset,min(segment,count-offset),position,normal,rng);
            if sample.index<p.scene_info.y && sample.pdf>0.0 {samples[added]=sample;added++;}
        }
        for(var i=0u;i<added;i++) {
            let sample=samples[i];let uv=vec2(random(rng),random(rng));let target=luminance(evaluate_light(position,normal,sample.index,uv).value);
            reservoir_add(&result,sample.index,uv,target,target*f32(added)/sample.pdf,1u,rng);
        }
    } else {
        for(var i=0u;i<8u;i++) {
            let sample=grid_merge(start,count,position,normal,rng);if sample.index>=p.scene_info.y || sample.pdf<=0.0 {continue;}
            let uv=vec2(random(rng),random(rng));let target=luminance(evaluate_light(position,normal,sample.index,uv).value);
            reservoir_add(&result,sample.index,uv,target,target/sample.pdf,1u,rng);
        }
    }
    return result;
}
