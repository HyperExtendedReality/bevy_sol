// AMD Capsaicin GI-1.2 sampling.hlsl, screen_probes.hlsl and gi1.comp.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
// Probe radiance uses the source half-packed RGB/distance representation.
// The two packed arrays occupy the former float4 array's storage stride.
static const float PROBE_ANGLE_THRESHOLD = 0.9980267284; // cos(0.02 * pi)
uint2 probe_pack(float4 value) {
    // Positive infinity is the source's half-packed far-hit sentinel.
    // Keep it in distance, while preventing bad radiance from poisoning the CDF.
    value.rgb=safe_radiance(value.rgb);value.w=select(value.w==value.w,value.w,-1.0);
    return uint2(pack2x16float(value.xy),pack2x16float(value.zw));
}
float4 probe_unpack(uint2 value) {return float4(unpack2x16float(value.x),unpack2x16float(value.y));}
uint2 probe_pack_sh(float4 value) {
    // SH coefficients are signed. They must never pass through the nonnegative
    // radiance sanitizer. Pack across storage to preserve half quantization.
    value=select(value==value,clamp(value,float4(-60000.0),float4(60000.0)),float4(0.0));
    return uint2(pack2x16float(value.xy),pack2x16float(value.zw));
}
float3 probe_shadow_preserving_blend(float3 current,float3 previous) {
    // BlendScreenProbes: darkening responds immediately; large brightening
    // retains history with the source squared, capped luminance hysteresis.
    let a=luminance(current);let b=luminance(previous);
    let response=clamp(max(a-b-min(a,b),0.0)/max(max(a,b),1e-4),0.0,0.95);
    return lerp(current,previous,response*response);
}
float3 probe_empty_cell_backup(float3 total,uint populated,uint directions) {
    return total/(float(max(populated,1u))*float(max(directions-populated,1u)));
}
uint4 probe_quantize(float4 value) {
    // ScreenProbes_QuantizeRadiance uses integer sums at a scale of 10000.
    // Bound far endpoints before conversion, where half storage uses infinity.
    value.rgb=safe_radiance(value.rgb);value.w=clamp(value.w,0.0,min(p.cache_config.w,429496.0));
    return uint4(round(value*10000.0));
}
float4 probe_recover(uint4 value) {return float4(value)/10000.0;}
float4 probe_shadow_preserving_blend(float4 current,float4 previous) {
    let a=luminance(current.rgb);let b=luminance(previous.rgb);
    let response=clamp(max(a-b-min(a,b),0.0)/max(max(a,b),1e-4),0.0,0.95);
    return lerp(current,previous,response*response);
}
bool source_probe_projection() {return (p.restir.w&1u)!=0u;}
bool source_direct_lighting_enabled(uint flags) {return (flags&1u)==0u || (flags&2u)==0u;}
bool source_direct_lighting_enabled() {return source_direct_lighting_enabled(p.restir.w);}
float3 source_direct_radiance(float3 radiance) {return select(source_direct_lighting_enabled(),radiance,float3(0.0));}
groupshared float3 probe_atlas_radiance[64];
groupshared float3 probe_atlas_direction[64];
[shader("compute")][numthreads(64,1,1)]
void project_probe_atlas(uint3 gid:SV_DispatchThreadID,uint local:SV_GroupIndex) {
    let lane=gid.x+gid.y*65536u;let bin=lane%PROBE_DIRECTIONS;let base=local-bin;
    let valid=lane<work[0].load()*PROBE_DIRECTIONS;var index=0u;
    probe_atlas_radiance[local]=float3(0.0);probe_atlas_direction[local]=float3(0,0,1);
    if(valid) {
        index=compact_probe(lane/PROBE_DIRECTIONS);
        // ProjectScreenProbes divides atlas RGB by the probe side length.
        // Its SH alpha is the number of cells, rather than temporal age.
        probe_atlas_radiance[local]=probe_unpack(probes[index].samples[bin]).rgb/float(p.screen.w);
        probe_atlas_direction[local]=hemisphere_ray(probes[index].normal.xyz,bin_uv(bin,float2(0.5)));
    }
    GroupMemoryBarrierWithGroupSync();if(!valid||!source_probe_projection()) {return;}
    if(bin<9u && probes[index].info.w!=MISSING) {
        var coefficient=float3(0.0);
        for(var i=0u;i<PROBE_DIRECTIONS;i++) {let basis=sh_basis(probe_atlas_direction[base+i]);coefficient+=probe_atlas_radiance[base+i]*basis[bin];}
        probes[index].sh[bin]=probe_pack_sh(float4(coefficient,float(PROBE_DIRECTIONS)));
    }
}
float probe_interpolation_weight(float depth,float probe_depth,float plane_distance,float cell_size,float normal_cosine) {
    if(abs(plane_distance)>cell_size) {return 0.0;}
    let weight=clamp(1.0-abs(probe_depth-depth)/max(depth,1e-6),0.0,1.0)*max(normal_cosine,0.0);
    return pow(weight,8.0);
}
float3 probe_hemi_octahedron(float2 uv) {
    let square=2.0*uv-1.0;
    let st=float2(square.x+square.y,square.x-square.y)*0.5;
    let a=abs(st);let distance=1.0-a.x-a.y;let radius=1.0-abs(distance);
    let phi=select(radius==0.0,0.0,PI*0.25*((a.y-a.x)/max(radius,1e-20)+1.0));
    let sine_theta=radius*sqrt(max(2.0-radius*radius,0.0));
    return float3(sine_theta*sign(st.x)*cos(phi),sine_theta*sign(st.y)*sin(phi),sign(distance)*(1.0-radius*radius));
}
float2 probe_hemi_octahedron_inverse(float3 direction) {
    let a=abs(direction);let radius=sqrt(max(1.0-a.z,0.0));
    let largest=max(a.x,a.y);let ratio=select(largest==0.0,0.0,min(a.x,a.y)/max(largest,1e-20));
    var phi=atan(ratio)*2.0/PI;phi=select(a.x>=a.y,phi,1.0-phi);
    let t=phi*radius;let st=float2(radius-t,t)*sign(direction.xy);
    return 0.5*float2(st.x+st.y,st.x-st.y)+0.5;
}
float3x3 probe_frame(float3 n) {
    // GetOrthoVectors from the source, including its z==0 branch.
    let swap=abs(n.z)==0.0;let v=select(swap,n.zyx,n);
    let k=rsqrt(v.z*v.z+n.y*n.y);
    var b1=float3(0.0,-v.z*k,n.y*k);b1=select(swap,b1.zyx,b1);
    return transpose(float3x3(b1,cross(n,b1),n));
}
float probe_guide_weight(uint2 sample,uint bin) {
    let weight=luminance(probe_unpack(sample).rgb)*probe_hemi_octahedron(bin_uv(bin,float2(0.5))).z;
    return max(select(source_probe_projection(),0.0,0.001),weight);
}
groupshared float probe_sampling_scan[64];
groupshared uint probe_reuse_values[256];
groupshared uint probe_reuse_counts[64];
void probe_reuse_add(uint index,float4 value) {
    let quantized=probe_quantize(value);
    for(var channel=0u;channel<4u;channel++) {InterlockedAdd(probe_reuse_values[4u*index+channel],quantized[channel]);}
    InterlockedAdd(probe_reuse_counts[index],1u);
}
void probe_reuse_reconnect(uint base,uint bin,float3 position,float3 normal,
    float3 old_position,float3 old_normal,uint2 packed) {
    var value=probe_unpack(packed);if(value.w<=0.0) {return;}
    let old_direction=hemisphere_ray(old_normal,bin_uv(bin,float2(0.5)));var direction=old_direction;
    if(value.w<p.cache_config.w*0.99) {
        let offset=old_position+old_direction*value.w-position;let distance=length(offset);
        if(distance<=p.cache_config.z) {return;}
        direction=offset/distance;value.w=distance;
    }
    if(dot(normal,direction)<=0.0) {return;}
    value.rgb=safe_radiance(value.rgb);value.w=min(value.w,p.cache_config.w);
    probe_reuse_add(base+direction_bin(normal,direction),value);
}
[shader("compute")][numthreads(64,1,1)]
void reproject_probe_history(uint3 gid:SV_DispatchThreadID,uint local:SV_GroupIndex) {
    let lane=gid.x+gid.y*65536u;let index=lane/PROBE_DIRECTIONS;let bin=lane%PROBE_DIRECTIONS;let base=local-bin;
    let valid=index<probe_cache_count();
    for(var c=0u;c<4u;c++) {probe_reuse_values[4u*local+c]=0u;}probe_reuse_counts[local]=0u;
    GroupMemoryBarrierWithGroupSync();
    if(valid&&probes[index].info.x!=MISSING) {
        let old=previous_probes[probes[index].info.x];
        probe_reuse_reconnect(base,bin,probes[index].position.xyz,probes[index].normal.xyz,old.position.xyz,old.normal.xyz,old.samples[bin]);
        if(bin<9u) {probes[index].sh[bin]=old.sh[bin];}
        if(bin==0u) {probes[index].irradiance=old.irradiance;}
    }
    GroupMemoryBarrierWithGroupSync();if(!valid) {return;}
    var sum=float3(0.0);var populated=0u;
    for(var i=0u;i<PROBE_DIRECTIONS;i++) {
        sum+=float3(probe_reuse_values[4u*(base+i)],probe_reuse_values[4u*(base+i)+1u],probe_reuse_values[4u*(base+i)+2u])/10000.0;
        populated+=uint(probe_reuse_counts[base+i]!=0u);
    }
    let count=probe_reuse_counts[local];
    var value=probe_recover(uint4(probe_reuse_values[4u*local],probe_reuse_values[4u*local+1u],probe_reuse_values[4u*local+2u],probe_reuse_values[4u*local+3u]))/float(max(count,1u));
    if(count==0u) {value=float4(probe_empty_cell_backup(sum,populated,PROBE_DIRECTIONS),p.cache_config.w);}
    if(probes[index].position.w==0.0) {value=float4(0,0,0,-1);}
    probes[index].samples[bin]=probe_pack(value);probes[index].filtered_samples[bin]=probe_pack(value);
}
[shader("compute")][numthreads(64,1,1)]
void snapshot_reprojected_probes(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x+gid.y*65536u;if(index>=probe_cache_count()) {return;}
    previous_probes[probe_reprojected_history()+index]=probes[index];
}
[shader("compute")][numthreads(64,1,1)]
void prepare_probe_sampling(uint3 gid : SV_DispatchThreadID,uint local : SV_GroupIndex) {
    let lane=gid.x+gid.y*65536u;let bin=lane%PROBE_DIRECTIONS;
    let valid=lane<work[27].load()*PROBE_DIRECTIONS;
    let base=local-bin;
    for(var channel=0u;channel<4u;channel++) {probe_reuse_values[4u*local+channel]=0u;}
    probe_reuse_counts[local]=0u;GroupMemoryBarrierWithGroupSync();
    var index=0u;
    if(valid) {
        index=compact_fresh_probe(lane/PROBE_DIRECTIONS);let old=probes[index].info.x;
        let position=probes[index].position.xyz;let normal=probes[index].normal.xyz;
        let pixel=uint2(probes[index].info.y%p.viewport.z,probes[index].info.y/p.viewport.z);
        let tile=int2(pixel/p.screen.z);
        let cell_size=max(select(p.camera.w!=0.0,probes[index].normal.w,
            length(p.camera.xyz-position)*p.reflection_thresholds.w),p.cache_config.z*4.0);
        if(old!=MISSING && !source_probe_projection()) {
            probe_reuse_reconnect(base,bin,position,normal,previous_probes[old].position.xyz,
                previous_probes[old].normal.xyz,previous_probes[old].samples[bin]);
        }
        // SampleScreenProbes merges every compatible cached neighbor, rather
        // than using only the cache entry claimed for this probe's update.
        for(var y=-1;y<=1;y++) {for(var x=-1;x<=1;x++) {
            let tap=tile+int2(x,y);if(any(tap<int2(0))||any(tap>=int2(p.screen.xy))) {continue;}
            if(source_probe_projection()) {
                let resident=previous_probes[probe_reprojected_history()+uint(tap.x)+uint(tap.y)*p.screen.x];
                if(resident.position.w!=0.0 && abs(dot(resident.position.xyz-position,normal))<=cell_size) {
                    probe_reuse_reconnect(base,bin,position,normal,resident.position.xyz,resident.normal.xyz,resident.samples[bin]);
                }
            }
            let tile_index=uint(tap.x)+uint(tap.y)*p.screen.x;
            let head=work[probe_cache_heads()+tile_index].load();
            let count=select(source_probe_projection(),head,probe_cache_count());
            var start=0u;
            if(source_probe_projection()) {start=work[source_candidate_offsets()+tile_index].load()+work[source_candidate_blocks()+tile_index/128u].load();}
            var candidate=head;
            for(var visited=0u;visited<count&&(source_probe_projection()||candidate!=MISSING);visited++) {
                if(source_probe_projection()) {candidate=work[source_candidate_list()+start+visited].load();}
                let cached_position=probe_cache[candidate].probe.position.xyz;
                if((source_probe_projection() || old!=p.scene_info.z+candidate) && abs(dot(cached_position-position,normal))<cell_size) {
                    probe_reuse_reconnect(base,bin,position,normal,cached_position,
                        cached_probe_normal(probe_cache[candidate].probe),probe_cache[candidate].probe.samples[bin]);
                }
                if(!source_probe_projection()) {candidate=probe_cache[candidate].next;}
            }
        }}
    }
    GroupMemoryBarrierWithGroupSync();
    var weight=0.0;
    if(valid) {
        var merged=float4(0.0);
        for(var channel=0u;channel<4u;channel++) {merged[channel]=float(probe_reuse_values[4u*local+channel])/10000.0;}
        let count=probe_reuse_counts[local];merged/=float(max(count,1u));
        if(count==0u) {merged.w=-1.0;}
        let packed=probe_pack(merged);probes[index].samples[bin]=packed;
        weight=probe_guide_weight(packed,bin);
    }
    probe_sampling_scan[local]=weight;GroupMemoryBarrierWithGroupSync();
    // Segmented scan: 64 directions use one group; 16 use four independent
    // segments. All lanes, including the partial final group, reach barriers.
    for(var offset=1u;offset<PROBE_DIRECTIONS;offset<<=1u) {
        let preceding=select(bin>=offset,probe_sampling_scan[max(local,offset)-offset],0.0);
        GroupMemoryBarrierWithGroupSync();probe_sampling_scan[local]+=preceding;GroupMemoryBarrierWithGroupSync();
    }
    if(valid) {
        let total=probe_sampling_scan[local-bin+PROBE_DIRECTIONS-1u];
        // Directional filtering overwrites this scratch array later in the frame.
        probes[index].filtered_samples[bin]=uint2(asuint(probe_sampling_scan[local]),asuint(total));
    }
}
float probe_guide_pdf(uint index,uint bin) {
    let cdf=probes[index].filtered_samples[bin];
    var preceding=0.0;if(bin!=0u) {preceding=asfloat(probes[index].filtered_samples[bin-1u].x);}
    return float(PROBE_DIRECTIONS)*max(asfloat(cdf.x)-preceding,0.0)/max(asfloat(cdf.y),1e-20)/(2.0*PI);
}
uint probe_sample_cdf(uint index,float sample) {
    let target=sample*asfloat(probes[index].filtered_samples[0].y);
    var lower=0u;var upper=PROBE_DIRECTIONS-1u;
    while(lower<upper) {
        let middle=(lower+upper)/2u;
        if(asfloat(probes[index].filtered_samples[middle].x)<target) {lower=middle+1u;}
        else {upper=middle;}
    }
    return lower;
}
float4 probe_sample_direction(uint index,uint bin,Surface s,inout uint rng) {
    let frame_normal=surface_plane_normal(s);let frame=probe_frame(frame_normal);
    let view=select(p.camera.w!=0.0,p.camera_direction.xyz,normalize(p.camera.xyz-s.position));
    let local_view=mul(transpose(frame),view);
    let dominant=ggx_specular_direction(surface_shading_normal(s),view,s.roughness);
    let half_vector=normalize(view+dominant);
    let f0=lerp(float3(0.16*s.reflectance*s.reflectance),s.base,s.metallic);
    let probability=select(local_view.z>0.0,
        brdf_specular_probability(f0,dot(half_vector,view),s.base*(1.0-s.metallic)),0.0);
    if(source_probe_projection()) {
        let rotation=ggx_rotation_to_z(frame_normal);let source_view=ggx_rotate(rotation,view);
        let samples=float2(grid_random(rng),grid_random(rng));
        var direction=float3(0.0);
        if(grid_random(rng)<probability) {
            let h=ggx_bounded_normal(max(s.roughness*s.roughness,1e-6),source_view,samples);
            direction=normalize(ggx_rotate(float4(-rotation.xyz,rotation.w),reflect(-source_view,h)));
        } else {
            let sampled_bin=probe_sample_cdf(index,grid_random(rng));
            // SampleScreenProbes retains stratification in cells with no reused
            // samples; guided cells use the complete radiance CDF.
            if(probe_unpack(probes[index].samples[bin]).w>0.0 && asfloat(probes[index].filtered_samples[0].y)>0.0) {bin=sampled_bin;}
            direction=normalize(mul(frame,probe_hemi_octahedron(bin_uv(bin,float2(grid_random(rng),grid_random(rng))))));
        }
        return float4(direction,select(dot(direction,frame_normal)>0.0,1.0,0.0));
    }
    // The source's Fresnel layer selection is mixed with uniform coverage.
    // The full directional PDF compensates both material and radiance guiding.
    let specular_probability=0.5*probability;
    let guided=asfloat(probes[index].filtered_samples[0].y)>0.001*float(PROBE_DIRECTIONS)*1.001;
    let guide_probability=select(guided,0.5*(1.0-probability),0.0);
    let choice=random(rng);let samples=float2(random(rng),random(rng));
    let alpha=max(s.roughness*s.roughness,1e-6);
    var local_direction=float3(0.0);
    if(choice<specular_probability) {
        let h=ggx_bounded_normal(alpha,local_view,samples);local_direction=reflect(-local_view,h);
    } else {
        if(choice<specular_probability+guide_probability) {bin=probe_sample_cdf(index,random(rng));}
        local_direction=probe_hemi_octahedron(bin_uv(bin,samples));
    }
    let direction=normalize(mul(frame,local_direction));
    if(local_direction.z<=0.0) {return float4(direction,0.0);}
    let sampled_bin=direction_bin(s.normal,direction);
    let h=normalize(local_view+local_direction);
    let pdf=(1.0-specular_probability-guide_probability)/(2.0*PI)
        +guide_probability*probe_guide_pdf(index,sampled_bin)
        +specular_probability*ggx_bounded_pdf(alpha,alpha*alpha,h.z,local_view);
    return float4(direction,1.0/max(2.0*PI*pdf,1e-20));
}
uint2 probe_mask_dimensions(uint level) {return max(p.screen.xy>>level,uint2(1u));}
uint probe_mask_offset(uint level) {
    var offset=WORK_HEADER+p.scene_info.z+2u*p.frame.z;
    for(var i=0u;i<level;i++) {let dims=probe_mask_dimensions(i);offset+=dims.x*dims.y;}
    return offset;
}
void filter_probe_mask(uint level,uint3 gid) {
    let dims=probe_mask_dimensions(level);let index=gid.x+gid.y*65536u;
    if(index>=dims.x*dims.y) {return;}
    let previous_dims=probe_mask_dimensions(level-1u);let pos=uint2(index%dims.x,index/dims.x)*2u;
    var selected=MISSING;
    for(var y=0u;y<2u;y++) {for(var x=0u;x<2u;x++) {
        let tap=pos+uint2(x,y);
        if(any(tap>=previous_dims)) {continue;}
        let candidate=work[probe_mask_offset(level-1u)+tap.x+tap.y*previous_dims.x].load();
        if(candidate!=MISSING) {selected=candidate;break;}
    }if(selected!=MISSING) {break;}}
    work[probe_mask_offset(level)+index].store(selected);
}
uint find_closest_probe(uint2 pixel,int2 offset) {
    var pos=min(pixel/p.screen.z,p.screen.xy-1u);var dims=p.screen.xy;
    for(var level=0u;level<16u;level++) {
        let loc=int2(pos)+offset;if(any(loc<int2(0))||any(loc>=int2(dims))) {break;}
        let index=work[probe_mask_offset(level)+uint(loc.x)+uint(loc.y)*dims.x].load();
        if(index!=MISSING) {return index;}
        if(all(dims==uint2(1u))) {break;}
        dims=max(dims>>1u,uint2(1u));pos=min(pos>>1u,dims-1u);
    }
    return MISSING;
}
float4 probe_filter_read(uint index,uint bin,bool horizontal) {
    if(horizontal) {return probe_unpack(probes[index].samples[bin]);}
    return probe_unpack(probes[index].filtered_samples[bin]);
}
void filter_probe_radiance(uint3 gid,bool horizontal) {
    let lane=gid.x+gid.y*65536u;if(lane>=work[0].load()*PROBE_DIRECTIONS) {return;}
    let index=compact_probe(lane/PROBE_DIRECTIONS);let bin=lane%PROBE_DIRECTIONS;
    if(source_probe_projection() && probes[index].info.w==MISSING) {return;}
    let center_position=probes[index].position;let center_normal=probes[index].normal;
    let packed_pixel=probes[index].info.y;
    let pixel=uint2(packed_pixel%p.viewport.z,packed_pixel/p.viewport.z);
    let axis=select(horizontal,int2(1,0),int2(0,1));
    let center_depth=max(dot(p.camera.xyz-center_position.xyz,p.camera_direction.xyz),1e-6);
    let cell_size=select(p.camera.w!=0.0,center_normal.w,
        length(p.camera.xyz-center_position.xyz)*p.reflection_thresholds.w);
        var radiance=probe_filter_read(index,bin,horizontal);var distance=radiance.w;var total=1.0;
        let direction=hemisphere_ray(center_normal.xyz,bin_uv(bin,float2(0.5)));
        for(var i=0;i<6;i++) {
            let step=((i&1)*2-1)*(i/2+1);
            let neighbor_index=find_closest_probe(pixel,step*axis);if(neighbor_index==MISSING) {continue;}
            let neighbor_position=probes[neighbor_index].position;let neighbor_normal=probes[neighbor_index].normal;
            if(abs(dot(neighbor_position.xyz-center_position.xyz,center_normal.xyz))>cell_size ||
                dot(direction,neighbor_normal.xyz)<0.0) {continue;}
            let neighbor_bin=direction_bin(neighbor_normal.xyz,direction);
            let value=probe_filter_read(neighbor_index,neighbor_bin,horizontal);
            if(value.w<=0.0||distance<=0.0) {continue;}
            let hit_distance=min(value.w,distance);
            let neighbor_direction=hemisphere_ray(neighbor_normal.xyz,bin_uv(neighbor_bin,float2(0.5)));
            let hit_point=neighbor_position.xyz+neighbor_direction*hit_distance;
            let offset=hit_point-center_position.xyz;
            if(dot(offset,offset)<1e-12 || dot(direction,normalize(offset))<PROBE_ANGLE_THRESHOLD) {continue;}
            let neighbor_depth=max(dot(p.camera.xyz-neighbor_position.xyz,p.camera_direction.xyz),1e-6);
            let weight=pow(clamp(1.0-abs(neighbor_depth-center_depth)/center_depth,0.0,1.0),8.0);
            radiance+=weight*float4(safe_radiance(value.rgb),hit_distance);total+=weight;distance=radiance.w/total;
        }
        let packed=probe_pack(radiance/total);
        if(horizontal) {probes[index].filtered_samples[bin]=packed;}
        else {probes[index].samples[bin]=packed;}
}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_radiance_x(uint3 gid : SV_DispatchThreadID) {filter_probe_radiance(gid,true);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_radiance_y(uint3 gid : SV_DispatchThreadID) {filter_probe_radiance(gid,false);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_1(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(1u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_2(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(2u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_3(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(3u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_4(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(4u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_5(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(5u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_6(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(6u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_7(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(7u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_8(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(8u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_9(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(9u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_10(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(10u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_11(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(11u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_12(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(12u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_13(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(13u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_14(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(14u,gid);}
[shader("compute")][numthreads(64,1,1)]
void filter_probe_mask_15(uint3 gid : SV_DispatchThreadID) {filter_probe_mask(15u,gid);}

