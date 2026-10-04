// AMD Capsaicin GI-1.2 glossy_reflections.hlsl, gi1.comp and brdf_lut.comp.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
// Separate planes and dispatches avoid the upstream in-place cleanup race.
[[vk::binding(27, 0)]] RWStructuredBuffer<float4> reflections;
uint2 reflection_size() {
    return (p.viewport.zw + uint2(p.reflection.x - 1u)) / p.reflection.x;
}
uint reflection_count() { let size = reflection_size(); return size.x * size.y; }
uint reflection_sample_index(uint layer, uint2 pixel) {
    return 1024u + layer * reflection_count() + pixel.x + pixel.y * reflection_size().x;
}
float4 reflection_encode_sample(float4 value,bool source) {
    if(!source) {return value;}
    // Keep packed bits across dispatches so optimization cannot cancel FP16 rounding.
    return float4(asfloat(pack2x16float(value.xy)),asfloat(pack2x16float(value.zw)),0.0,0.0);
}
float4 reflection_decode_sample(float4 value,bool source) {
    if(!source) {return value;}
    return float4(unpack2x16float(asuint(value.x)),unpack2x16float(asuint(value.y)));
}
void reflection_store_sample(uint layer,uint2 pixel,float4 value) {
    reflections[reflection_sample_index(layer,pixel)]=reflection_encode_sample(value,source_probe_projection()&&layer!=3u);
}
float4 reflection_load_sample(uint layer,uint2 pixel) {
    return reflection_decode_sample(reflections[reflection_sample_index(layer,pixel)],source_probe_projection()&&layer!=3u);
}
uint reflection_full_index(uint layer, uint2 pixel) {
    return 1024u + 8u * reflection_count() + layer * p.viewport.z * p.viewport.w + pixel.x + pixel.y * p.viewport.z;
}
void reflection_store_full(uint layer,uint2 pixel,float4 value) {
    reflections[reflection_full_index(layer,pixel)]=reflection_encode_sample(value,source_probe_projection());
}
float4 reflection_load_full(uint layer,uint2 pixel) {
    return reflection_decode_sample(reflections[reflection_full_index(layer,pixel)],source_probe_projection());
}
uint2 reflection_split_size() { return uint2(p.viewport.z, reflection_size().y); }
uint reflection_split_index(uint layer, uint2 pixel) {
    let size = reflection_split_size();
    return 1024u + 8u * reflection_count() + 4u * p.viewport.z * p.viewport.w + layer * size.x * size.y + pixel.x + pixel.y * size.x;
}
void reflection_store_split(uint layer,uint2 pixel,float4 value) {
    reflections[reflection_split_index(layer,pixel)]=reflection_encode_sample(value,source_probe_projection());
}
float4 reflection_load_split(uint layer,uint2 pixel) {
    return reflection_decode_sample(reflections[reflection_split_index(layer,pixel)],source_probe_projection());
}
uint blue_noise_byte(uint base,uint index) {
    let word=asuint(reflections[base+index/16u][(index/4u)&3u]);
    return (word>>((index&3u)*8u))&255u;
}
float blue_noise_value(uint base,uint2 pixel,uint frame,uint dimension) {
    // Heitz et al. source tables: 256x256 Sobol bytes, followed by the two
    // 128x128x8 optimized tiles. The ranking tile is periodic in its eight
    // optimized dimensions, avoiding the source's out-of-range high dimensions.
    pixel&=uint2(127u);dimension&=255u;let tile=(pixel.x+pixel.y*128u)*8u+(dimension&7u);
    let rank=blue_noise_byte(base,65536u+tile);
    let value=blue_noise_byte(base,dimension+rank*256u)^blue_noise_byte(base,196608u+tile);
    return frac((0.5+float(value))/256.0+float(frame&255u)*1.61803398874989484820);
}
float2 reflection_blue_noise(uint2 pixel,uint frame,uint dimension) {
    if(dimension>=255u) {dimension=0u;}
    let base=reflection_split_index(2u,uint2(0u));
    return float2(blue_noise_value(base,pixel,frame,dimension),blue_noise_value(base,pixel,frame,dimension+1u));
}
uint2 reflection_full_pixel(uint2 sample_pixel) {
    var phase = uint2(0u);
    if (p.reflection.x == 2u) { phase = uint2(p.frame.x & 1u, (p.frame.x >> 1u) & 1u); }
    return sample_pixel * p.reflection.x + phase;
}
float3 reflection_view(Surface s) {
    if (p.camera.w != 0.0) { return p.camera_direction.xyz; }
    return normalize(p.camera.xyz - s.position);
}
float3 depth_geometry_normal(uint2 pixel, Surface s) {
    let left = surface_uncached(uint2(int2(max(int(pixel.x) - 1, 0), int(pixel.y))));
    let right = surface_uncached(min(pixel + uint2(1u, 0u), p.viewport.zw - uint2(1u)));
    let up = surface_uncached(uint2(int2(int(pixel.x), max(int(pixel.y) - 1, 0))));
    let down = surface_uncached(min(pixel + uint2(0u, 1u), p.viewport.zw - uint2(1u)));
    let dx = select(left.valid && (!right.valid || length(left.position - s.position) < length(right.position - s.position)), s.position - left.position, right.position - s.position);
    let dy = select(up.valid && (!down.valid || length(up.position - s.position) < length(down.position - s.position)), s.position - up.position, down.position - s.position);
    let product = cross(dx, dy);
    if (dot(product, product) < 1e-12) { return s.normal; }
    let n = normalize(product);
    let facing=select(source_probe_projection(),reflection_view(s),s.normal);
    return n * select(dot(n,facing)>=0.0,1.0,-1.0);
}
float3 reflection_geometric_normal(uint2 pixel, Surface s) {
    if(source_probe_projection()) {
#if GI_PRIMARY_GEOMETRY_NORMALS
        return s.geometry_normal;
#else
        let geometry_normal=trace_primary_geometry_normal(pixel,s);
        if(geometry_normal.w!=0.0) {return geometry_normal.xyz;}
#endif
    }
    return depth_geometry_normal(pixel,s);
}
[shader("compute")][numthreads(8,8,1)]
void prepare_primary_geometry_normals(uint3 gid:SV_DispatchThreadID) {
#if GI_PRIMARY_GEOMETRY_NORMALS
    let pixel=gid.xy;if(!source_probe_projection()||any(pixel>=p.viewport.zw)) {return;}
    work[previous_primary_normal_address(pixel)].store(work[primary_normal_address(pixel)].load());
    let s=surface_uncached(pixel);var packed=0u;
    if(s.valid) {
        let hit_normal=trace_primary_geometry_normal(pixel,s);
        var normal=hit_normal.xyz;
        if(hit_normal.w==0.0) {normal=depth_geometry_normal(pixel,s);}
        packed=primary_pack_geometry_normal(normal,true);
    }
    work[primary_normal_address(pixel)].store(packed);
#endif
}
float reflection_plane_weight(Surface s, Surface other, float3 geometric_normal) {
    // View depth equals camera distance projected onto the camera's forward axis.
    let view_depth = max(abs(dot(p.camera.xyz - s.position, p.camera_direction.xyz)), 1e-4);
    return 1.0 - clamp(abs(dot(geometric_normal, s.position - other.position) / view_depth) * 200.0, 0.0, 1.0);
}
float reflection_pdf(Surface s, float4 endpoint) {
    let view = reflection_view(s); var light = endpoint.xyz;
    if (endpoint.w > 0.5) { light = normalize(endpoint.xyz + p.camera.xyz - s.position); }
    let half_sum = view + light;
    if (dot(half_sum, half_sum) < 1e-12) { return 0.0; }
    let normal=surface_shading_normal(s);
    let nh = clamp(dot(normal, normalize(half_sum)), -1.0, 1.0);
    let alpha = max(s.roughness * s.roughness, 1e-6);
    return ggx_bounded_pdf(alpha, max(alpha * alpha, 1e-6), nh, mul(transpose(tangent_frame(normal)), view));
}
float3 reflection_compress(float3 color) { return color / (float3(1.0) + color); }
float3 reflection_decompress(float3 color) { return color / max(float3(1.0) - color, float3(1e-3)); }
float3 reflection_cache_jitter(float3 normal,float cell_size,float2 samples) {
    // TraceReflectionsHandleHit reuses the GGX sample payload.s and source
    // GetOrthoVectors. A second RNG and half-radius displacement changed the
    // lookup distribution and introduced a different tiled artifact pattern.
    return mul(probe_frame(normal),float3((2.0*samples-1.0)*cell_size,0.0));
}
float reflection_miss_distance(uint flags) {
    // TRACE_SKY_DISTANCE (65519) rounds to 65504 in the source R16_FLOAT image.
    return select((flags&1u)!=0u && source_direct_lighting_enabled(flags),65504.0,-1.0);
}
float4 reflection_trace_result(float3 radiance,float distance) {
    let color=select(source_probe_projection(),radiance,safe_radiance(radiance));
    return float4(reflection_compress(color),distance);
}
void reflection_trace(uint2 pixel, Surface s, uint seed) {
    if (any(pixel != reflection_full_pixel(pixel / p.reflection.x))) { return; }
    let half_pixel = pixel / p.reflection.x;
    reflections[reflection_sample_index(3u, half_pixel)] = float4(0.0);
    reflections[reflection_sample_index(0u, half_pixel)] = float4(0.0);
    if (!s.valid || p.options.w == 0u || s.roughness > p.reflection_filter.w) { return; }
    if(source_probe_projection() && source_probe_interpolation(s,pixel).indices.x==MISSING) {return;}
    let view = reflection_view(s); let rotation=ggx_rotation_to_z(surface_shading_normal(s));
    let alpha = max(s.roughness * s.roughness, 1e-6);
    let dimension=select(source_probe_projection() && s.roughness>p.quality.x,1u,2u);
    let samples=reflection_blue_noise(pixel,p.frame.x,dimension);
    let local_view = ggx_rotate(rotation,view);
    let h = ggx_bounded_normal(alpha, local_view, samples);
    let direction = normalize(ggx_rotate(float4(-rotation.xyz,rotation.w),reflect(-local_view, h)));
    var radiance = float3(0.0); var distance = -1.0; var endpoint = float4(direction, 0.0);
    if (s.roughness > p.quality.x) {
        radiance = gather_directional(s, pixel, direction).rgb;
    } else {
        let normal = reflection_geometric_normal(pixel, s);
        let origin = s.position + normal * p.cache_config.z;
        let hit = trace(origin, direction, p.cache_config.w);
        radiance = source_direct_radiance(environment_radiance(direction));
        distance = reflection_miss_distance(p.restir.w);
        if (hit.triangle != MISSING) {
            if(source_probe_projection()) {distance=-1.0;}
            let position = origin + direction * hit.distance; let n = hit_normal(hit, direction);
            if(!source_probe_projection()) {distance = hit.distance;}
            radiance = float3(0.0);
            if (any(n != float3(0.0))) {
                let emission = material_emission(position, hit.triangle);
                let front=dot(cross(geometry[hit.triangle+1u].xyz-geometry[hit.triangle].xyz,
                    geometry[hit.triangle+2u].xyz-geometry[hit.triangle].xyz),direction)<0.0;
                let emissive=select(source_probe_projection(),source_direct_lighting_enabled() && front && any(geometry[hit.triangle+7u].rgb>float3(0.0)),any(emission>float3(0.0)));
                if (emissive) { radiance = emission;distance=hit.distance; }
                else {
                    let previous = visible_previous_radiance(position, n, hit.triangle);
                    if (previous.w != 0.0) { radiance = previous.rgb;distance=hit.distance; }
                    else {
                        let jitter = reflection_cache_jitter(n,hash_cell_size(position),samples);
                        var found=false;
                        let cached=directional_cached_radiance(position+jitter,direction,hit.distance,found);
                        if (found) { radiance = cached;distance=hit.distance; }
                        else if(!source_probe_projection()) { radiance = cached_radiance(position,n,hit.distance,hit.triangle,seed,MISSING,direction); }
                    }
                }
            }
            if (distance > 0.0 && distance < 100.0) { endpoint = float4(s.position + direction * distance - p.camera.xyz, 1.0); }
        }
    }
    reflection_store_sample(0u,half_pixel,reflection_trace_result(radiance,distance));
    reflection_store_sample(1u,half_pixel,endpoint);
    reflections[reflection_sample_index(3u, half_pixel)] = float4(0.0, 1.0, 0.0, 0.0);
}
[shader("compute")][numthreads(8, 8,1)]
void compute_brdf_lut(uint3 gid : SV_DispatchThreadID) {
    if (any(gid.xy >= uint2(32u))) { return; }
    let uv = (float2(gid.xy) + 0.5) / 32.0;
    let alpha = uv.y * uv.y; let view = float3(sqrt(1.0 - uv.x * uv.x), 0.0, uv.x);
    var sum = float2(0.0);
    for (var i = 0u; i < 4096u; i++) {
        let samples = float2(float(i) / 4096.0, float(reversebits(i)) * 2.3283064365386963e-10);
        let half_vector = ggx_bounded_normal(alpha, view, samples); let light = reflect(-view, half_vector);
        let h = normalize(view + light); let nh = clamp(h.z, -1.0, 1.0);
        let fresnel = pow(1.0 - clamp(abs(dot(h, view)), 0.0, 1.0), 5.0);
        let pdf = ggx_bounded_pdf(alpha, alpha * alpha, nh, view);
        let gd = ggx_ndf(alpha * alpha, nh) / ggx_visibility_reciprocal(alpha * alpha, light.z, view.z);
        sum += float2(gd, gd * fresnel) * max(light.z, 0.0) / max(pdf, 1e-20);
    }
    // The original stores R16G16_FLOAT; preserve that quantization.
    // Keep packed bits across the buffer store. Optimizers may cancel a local
    // pack/unpack pair, losing the original R16G16_FLOAT quantization.
    let packed = pack2x16float(sum / 4096.0);
    reflections[gid.x + gid.y * 32u] = float4(asfloat(packed), 0.0, 0.0, 0.0);
}
float2 sample_brdf_lut(float dot_nv, float roughness) {
    let coord = clamp(float2(dot_nv, roughness), float2(0.0), float2(1.0)) * 32.0 - 0.5;
    let base = int2(floor(coord)); let f = frac(coord); var lut = float2(0.0);
    for (var y = 0; y < 2; y++) { for (var x = 0; x < 2; x++) {
        let tap = uint2(clamp(base + int2(x,y), int2(0), int2(31)));
        let weight = select(x==1, f.x, 1.0-f.x) * select(y==1, f.y, 1.0-f.y);
        lut += unpack2x16float(asuint(reflections[tap.x + tap.y * 32u].x)) * weight;
    }}
    return lut;
}
float3 reflection_directional_albedo(Surface s) {
    let lut=sample_brdf_lut(max(dot(surface_shading_normal(s),reflection_view(s)),0.0),s.roughness);
    let f0 = primary_material_f0(s.base,s.metallic,s.reflectance,p.restir.w);
    return clamp(f0 * lut.x + (float3(1.0) - f0) * lut.y, float3(0.0), float3(1.0));
}
[shader("compute")][numthreads(8, 8,1)]
void mark_reflection_fireflies(uint3 gid : SV_DispatchThreadID) {
    if (any(gid.xy >= reflection_size())) { return; }
    let pixel = reflection_full_pixel(gid.xy); let id = reflection_sample_index(3u, gid.xy);
    let source=source_probe_projection();
    if (any(pixel >= p.viewport.zw)) { return; }
    if(source) {
        let s=surface_uncached(pixel);
        if(!s.valid || s.roughness>p.reflection_filter.w) {return;}
    } else if(reflections[id].y==0.0) {return;}
    let raw = reflection_load_sample(0u,gid.xy);
    var marked = float(raw.w < 0.0);
    if (marked == 0.0 && p.reflection.w != 0u) {
        let center = luminance(raw.rgb); var lower = 0.0; var higher = 0.0;
        let radius = int(p.reflection_filter.y); let half_radius = (radius + int(p.reflection.x) - 1) / int(p.reflection.x);
        for (var y = -half_radius; y <= half_radius; y++) { for (var x = -half_radius; x <= half_radius; x++) {
            if (x == 0 && y == 0) { continue; }
            let offset=select(source,int2(y,x),int2(x,y));
            let tap = int2(gid.xy) + offset;
            if (any(tap < int2(0)) || any(tap >= int2(reflection_size())) || any(abs(int2(x,y) * int(p.reflection.x)) > int2(radius))) { continue; }
            let full=reflection_full_pixel(uint2(tap));
            if(any(full>=p.viewport.zw)) {continue;}
            if(source) {
                if(surface_uncached(full).roughness>p.reflection_filter.w) {continue;}
            } else if (reflections[reflection_sample_index(3u,uint2(tap))].y == 0.0) { continue; }
            let value = luminance(reflection_load_sample(0u,uint2(tap)).rgb);
            higher += float(value < center); lower += float(value > center);
        }}
        marked = float(lower < p.reflection_thresholds.x * (lower + higher) || higher > p.reflection_thresholds.y * (lower + higher));
    }
    // Each invocation owns its flag; never reads neighbors' written x channel.
    reflections[id].x = select(p.reflection.w != 0u, marked, 0.0);
}
int reflection_cleanup_radius(int radius,uint stride,bool source) {
    return select(source,radius,(radius+int(stride)-1)/int(stride));
}
float reflection_cleanup_weight(int2 offset,int radius,uint stride,bool source) {
    let denominator=pow(float(radius+1),2.0);
    if(source) {return exp(-float(offset.x*offset.x)/denominator)*exp(-float(offset.y*offset.y)/denominator);}
    let delta=float2(offset*int(stride));return exp(-dot(delta,delta)/denominator);
}
float4 source_reflection_cleanup_resolve(float4 sum,float total,float4 center) {
    if(abs(total)<1e-3) {sum+=center;total+=1.0;}
    if(total>0.0) {sum/=total;}
    return gi_denoiser_sanitize(sum);
}
[shader("compute")][numthreads(8, 8,1)]
void cleanup_reflection_fireflies(uint3 gid : SV_DispatchThreadID) {
    if (any(gid.xy >= reflection_size())) { return; }
    let raw = reflection_load_sample(0u,gid.xy);
    let pixel = reflection_full_pixel(gid.xy); var result = raw;
    if (all(pixel < p.viewport.zw) && reflections[reflection_sample_index(3u,gid.xy)].x > 0.5) {
        let s = surface(pixel); let n = reflection_geometric_normal(pixel,s);
        let source=source_probe_projection();
        let radius = int(p.reflection_filter.z); let half_radius = reflection_cleanup_radius(radius,p.reflection.x,source);
        var sum = float4(0.0); var total = 0.0;
        for (var y = -half_radius; y <= half_radius; y++) { for (var x = -half_radius; x <= half_radius; x++) {
            let offset=select(source,int2(y,x),int2(x,y));
            let tap = int2(gid.xy) + offset;
            if (any(tap < int2(0)) || any(tap >= int2(reflection_size()))) { continue; }
            let q = uint2(tap); let full = reflection_full_pixel(q);
            if (any(full >= p.viewport.zw)) { continue; }
            let flags = reflections[reflection_sample_index(3u,q)]; if (flags.x != 0.0 || (!source && flags.y == 0.0)) { continue; }
            let other = surface(full); if (!source && !other.valid) { continue; }
            let w = reflection_cleanup_weight(offset,radius,p.reflection.x,source) * reflection_plane_weight(s,other,n);
            sum += reflection_load_sample(0u,q) * w; total += w;
        }}
        if(source) {result=source_reflection_cleanup_resolve(sum,total,raw);}
        else if (total > 0.0) { result = sum / total; }
    }
    reflection_store_sample(2u,gid.xy,select(source_probe_projection(),result,float4(safe_radiance(result.rgb),result.w)));
}
float reflection_atrous_weight(int2 offset,int step,bool source) {
    let sigma=1.065*float(step);
    if(!source) {return exp(-dot(float2(offset),float2(offset))/(2.0*sigma*sigma));}
    let scale=float(step)/(sqrt(2.0*PI)*sigma);
    return (scale*exp(-float(offset.x*offset.x)/(2.0*sigma*sigma)))
        * (scale*exp(-float(offset.y*offset.y)/(2.0*sigma*sigma)));
}
bool reflection_normalizes_weight(float weight,bool final,bool source) {
    return weight>select(final&&source,0.0,1e-3);
}
void reflection_ratio_filter(uint2 pixel, int step, uint input_layer, bool last) {
    let s = surface(pixel);
    let source=source_probe_projection();
    if (!s.valid || p.options.w == 0u || s.roughness > p.reflection_filter.w) {
        if (last) { reflection_store_full(0u,pixel,float4(0.0)); reflection_store_full(1u,pixel,float4(0.0)); }
        return;
    }
    let n = reflection_geometric_normal(pixel,s); let half_pixel = pixel / p.reflection.x;
    let half_step = max((step + int(p.reflection.x) - 1) / int(p.reflection.x),1);
    let half_radius = (2 * step + int(p.reflection.x) - 1) / int(p.reflection.x);
    var jitter = int2(0);
    if (last) {
        var mean = 0.0; var second = 0.0; var count = 0.0;
        for (var y = -4; y <= 4; y+=2) { for (var x = -4; x <= 4; x+=2) {
            let offset=select(source,int2(y,x),int2(x,y));
            let tap = int2(pixel)+offset; if (any(tap<int2(0)) || any(tap>=int2(p.viewport.zw))) { continue; }
            let r = surface(uint2(tap)).roughness; mean+=r;second+=r*r;count+=1.0;
        }}
        mean /= max(count,1.0); second /= max(count,1.0);
        let scale = clamp(4.0 * sqrt(abs(second-mean*mean)) / max(mean,1e-6),0.0,1.0);
        jitter = int2(floor((reflection_blue_noise(pixel,p.frame.x,0u)-0.5)*float(half_step)*scale+0.5));
    }
    var sum = float4(0.0); var second = float3(0.0); var total = 0.0;
    for (var y = -half_radius; y <= half_radius; y+=half_step) { for (var x = -half_radius; x <= half_radius; x+=half_step) {
        let offset=select(source,int2(y,x),int2(x,y));
        let tap = int2(half_pixel)+offset+jitter;
        if (any(tap < int2(0)) || any(tap >= int2(reflection_size()))) { continue; }
        let q = uint2(tap); let full = reflection_full_pixel(q);
        if (any(full >= p.viewport.zw) || (!source && reflections[reflection_sample_index(3u,q)].y == 0.0)) { continue; }
        let other = surface(full); if (!other.valid || other.roughness > p.reflection_filter.w) { continue; }
        let gaussian = reflection_atrous_weight(int2(full)-int2(pixel),step,source);
        let weight = gaussian * reflection_plane_weight(s,other,n) * reflection_pdf(s,reflection_load_sample(1u,q));
        let value = reflection_load_sample(input_layer,q); var squared = value.rgb*value.rgb;
        if (input_layer >= 4u) { squared = pow(reflection_load_sample(input_layer+2u,q).rgb,float3(2.0)); }
        sum += value*weight; second += squared*weight; total += weight;
    }}
    if (reflection_normalizes_weight(total,last,source)) { sum /= total; second /= total; }
    if (last) {
        let deviation = sqrt(abs(second-sum.rgb*sum.rgb));
        reflection_store_full(0u,pixel,float4(reflection_decompress(sum.rgb),sum.w));
        reflection_store_full(1u,pixel,float4(reflection_decompress(deviation),1.0));
    } else {
        var output_layer = 4u; if (input_layer == 4u) { output_layer = 5u; }
        reflection_store_sample(output_layer,half_pixel,sum);
        reflection_store_sample(output_layer+2u,half_pixel,float4(sqrt(max(second,float3(0.0))),1.0));
    }
}
[shader("compute")][numthreads(8,8,1)]
void reflection_atrous_first(uint3 gid : SV_DispatchThreadID) {
    let pixel=reflection_full_pixel(gid.xy);
    if (all(gid.xy<reflection_size()) && all(pixel<p.viewport.zw)) { reflection_ratio_filter(pixel,1,2u,false); }
}
void reflection_atrous_iteration(uint2 pixel, uint iteration) {
    let full=reflection_full_pixel(pixel);
    if (all(pixel<reflection_size()) && all(full<p.viewport.zw)) { reflection_ratio_filter(full,int(1u<<iteration),4u+(iteration-1u)%2u,false); }
}
[shader("compute")][numthreads(8,8,1)] void reflection_atrous_2(uint3 gid : SV_DispatchThreadID) { reflection_atrous_iteration(gid.xy,1u); }
[shader("compute")][numthreads(8,8,1)] void reflection_atrous_4(uint3 gid : SV_DispatchThreadID) { reflection_atrous_iteration(gid.xy,2u); }
[shader("compute")][numthreads(8,8,1)] void reflection_atrous_8(uint3 gid : SV_DispatchThreadID) { reflection_atrous_iteration(gid.xy,3u); }
[shader("compute")][numthreads(8,8,1)] void reflection_atrous_16(uint3 gid : SV_DispatchThreadID) { reflection_atrous_iteration(gid.xy,4u); }
[shader("compute")][numthreads(8,8,1)] void reflection_atrous_32(uint3 gid : SV_DispatchThreadID) { reflection_atrous_iteration(gid.xy,5u); }
[shader("compute")][numthreads(8,8,1)] void reflection_atrous_64(uint3 gid : SV_DispatchThreadID) { reflection_atrous_iteration(gid.xy,6u); }
[shader("compute")][numthreads(8,8,1)]
void reflection_atrous_last(uint3 gid : SV_DispatchThreadID) {
    if (all(gid.xy<p.viewport.zw)) { reflection_ratio_filter(gid.xy,int(1u<<(p.reflection.z-1u)),4u+(p.reflection.z-2u)%2u,true); }
}
// Separable ratio estimator: horizontal full-width / sampled-height, then vertical full resolution.
void reflection_split(uint2 pixel, bool vertical) {
    let s=surface(pixel); let radius=int(p.reflection_filter.x); let half_radius=(radius+int(p.reflection.x)-1)/int(p.reflection.x);
    let n=reflection_geometric_normal(pixel,s); var sum=float4(0.0);var second=float3(0.0);var total=0.0;
    let jitter=int2(floor((reflection_blue_noise(pixel,p.frame.x,0u)-0.5)*2.0+0.5));
    if (s.valid && s.roughness<=p.reflection_filter.w && p.options.w!=0u) {
        for (var i=-half_radius;i<=half_radius;i++) {
            var tap=int2(pixel/p.reflection.x)+int2(i,0); if (vertical) { tap=int2(pixel/p.reflection.x)+int2(jitter.x,i); }
            if (any(tap<int2(0)) || any(tap>=int2(reflection_size()))) { continue; }
            let q=uint2(tap);let full=reflection_full_pixel(q);
            if (any(full>=p.viewport.zw)) {continue;}
            let other=surface(full);if ((!source_probe_projection() && !other.valid) || other.roughness>p.reflection_filter.w) {continue;}
            let endpoint=reflection_load_sample(1u,q);
            let delta=select(vertical, int(full.y)-int(pixel.y), int(full.x)-int(pixel.x));
            let gaussian=exp(-float(delta*delta)/(2.0*pow(0.375*float(radius),2.0)));
            let weight=gaussian*reflection_plane_weight(s,other,n)*reflection_pdf(s,endpoint);
            var value=reflection_load_sample(2u,q); var squared=value.rgb*value.rgb;
            if (vertical) { let split=uint2(full.x,q.y); value=reflection_load_split(0u,split);squared=pow(reflection_load_split(1u,split).rgb,float3(2.0)); }
            sum+=value*weight;second+=squared*weight;total+=weight;
        }
        if(total<1e-3) {
            // ResolveReflections_SplitRatioEstimatorX/Y retries three taps with
            // unit weights when plane/PDF rejection leaves an upsampling hole.
            if(!source_probe_projection()) {sum=float4(0.0);second=float3(0.0);total=0.0;}
            for(var i=-1;i<=1;i++) {
                let tap=int2(pixel/p.reflection.x)+select(vertical,int2(0,i),int2(i,0));
                if(any(tap<int2(0))||any(tap>=int2(reflection_size()))) {continue;}
                let q=uint2(tap);let full=reflection_full_pixel(q);if(any(full>=p.viewport.zw)) {continue;}
                let other=surface(full);if((!source_probe_projection() && !other.valid)||other.roughness>p.reflection_filter.w) {continue;}
                var value=reflection_load_sample(2u,q);var squared=value.rgb*value.rgb;
                if(vertical) {let split=uint2(full.x,q.y);value=reflection_load_split(0u,split);squared=pow(reflection_load_split(1u,split).rgb,float3(2.0));}
                sum+=value;second+=squared;total+=1.0;
            }
        }
    }
    if (reflection_normalizes_weight(total,true,source_probe_projection())) {sum/=total;second/=total;}
    if (vertical) {
        reflection_store_full(0u,pixel,float4(reflection_decompress(sum.rgb),sum.w));
        reflection_store_full(1u,pixel,float4(reflection_decompress(sqrt(abs(second-sum.rgb*sum.rgb))),1.0));
    } else {
        let split=uint2(pixel.x,pixel.y/p.reflection.x);
        reflection_store_split(0u,split,sum);
        reflection_store_split(1u,split,float4(sqrt(max(second,float3(0.0))),1.0));
    }
}
[shader("compute")][numthreads(8,8,1)]
void reflection_split_x(uint3 gid : SV_DispatchThreadID) {
    if (any(gid.xy>=reflection_split_size())) {return;}
    let pixel=uint2(gid.x,gid.y*p.reflection.x);if (pixel.y<p.viewport.w) {reflection_split(pixel,false);}
}
[shader("compute")][numthreads(8,8,1)]
void reflection_split_y(uint3 gid : SV_DispatchThreadID) {if (all(gid.xy<p.viewport.zw)) {reflection_split(gid.xy,true);} }
[shader("compute")][numthreads(8,8,1)]
void reflection_no_denoiser(uint3 gid : SV_DispatchThreadID) {
    if (any(gid.xy>=p.viewport.zw)) {return;}
    let raw=reflection_load_sample(2u,gid.xy/p.reflection.x);
    reflection_store_full(0u,gid.xy,float4(reflection_decompress(raw.rgb),raw.w));
    reflection_store_full(1u,gid.xy,float4(0.0));
}
float4 source_reflection_previous(Surface s,float2 uv) {
    let coord=uv*float2(p.viewport.zw)-0.5;let base=int2(floor(coord));let fraction=frac(coord);
    var filtered_normal=float3(0.0);var sum=float4(0.0);
    // Texture sampling clamps, while the source fallback uses integer Load.
    for(var y=0;y<2;y++) {for(var x=0;x<2;x++) {
        let tap=uint2(clamp(base+int2(x,y),int2(0),int2(p.viewport.zw)-1));
        let weight=select(x==1,fraction.x,1.0-fraction.x)*select(y==1,fraction.y,1.0-fraction.y);
        filtered_normal+=previous_normal.Load(int3(tap,0)).xyz*weight;
        sum+=reflection_load_full(3u,tap)*weight;
    }}
    let center_depth=abs(dot(p.camera.xyz-s.position,p.camera_direction.xyz));
    let normal_weight=exp(-abs(1.0-max(0.0,dot(primary_details_normal(s),filtered_normal)))*1.4);
    let offsets=int2[4](int2(0,1),int2(1,1),int2(1,0),int2(0,0));
    var all_valid=true;var best_weight=0.9;var best_index=-1;
    for(var i=0;i<4;i++) {
        let tap=uint2(clamp(base+offsets[i],int2(0),int2(p.viewport.zw)-1));
        let depth=previous_view_depth(previous_position.Load(int3(tap,0)).xyz);
        let weight=normal_weight*exp(-abs(depth-center_depth)/center_depth);
        all_valid=all_valid && weight>0.9;
        if(weight>best_weight) {best_weight=weight;best_index=i;}
    }
    if(all_valid) {return sum;}
    if(best_index<0) {return float4(0.0);}
    let tap=int2(uv*float2(p.viewport.zw))+offsets[best_index];
    if(any(tap<int2(0)) || any(tap>=int2(p.viewport.zw))) {return float4(0.0);}
    return reflection_load_full(3u,uint2(tap));
}
float4 reflection_previous(Surface s, float2 uv) {
    if(source_probe_projection()) {
        if((p.frame.y&1u)!=0u) {return float4(0.0);}
        return source_reflection_previous(s,uv);
    }
    if ((p.frame.y&1u)!=0u || any(uv<float2(0.0)) || any(uv>=float2(1.0))) {return float4(0.0);}
    let coord=uv*float2(p.viewport.zw)-0.5;let base=int2(floor(coord));let fraction=frac(coord);
    var sum=float4(0.0);var best=float4(0.0);var best_weight=0.9;var all_valid=true;
    let center_depth=max(abs(dot(p.camera.xyz-s.position,p.camera_direction.xyz)),1e-4);
    for(var y=0;y<2;y++) {for(var x=0;x<2;x++) {
        let tap=base+int2(x,y);
        if (any(tap<int2(0)) || any(tap>=int2(p.viewport.zw))) {all_valid=false;continue;}
        let pos=previous_position.Load(int3(tap, 0));let normal=previous_normal.Load(int3(tap, 0));
        if (!history_material_matches(s,pos.w)) {all_valid=false;continue;}
        var previous_depth=abs(dot(p.camera.xyz-pos.xyz,p.camera_direction.xyz));
        if (p.camera.w==0.0) {previous_depth=abs((mul(p.previous_clip_from_world,float4(pos.xyz,1.0))).w);}
        let disocclusion=exp(-abs(1.0-max(0.0,dot(primary_details_normal(s),normal.xyz)))*1.4)
            *exp(-abs(previous_depth-center_depth)/center_depth);
        let value=reflection_load_full(3u,uint2(tap));
        let weight=select(x==1, fraction.x, 1.0-fraction.x)*select(y==1, fraction.y, 1.0-fraction.y);
        sum+=value*weight;
        if (disocclusion<=0.9 || pos.w==0.0) {all_valid=false;}
        if (disocclusion>best_weight && pos.w!=0.0) {best_weight=disocclusion;best=value;}
    }}
    return select(all_valid, sum, best);
}
[shader("compute")][numthreads(8,8,1)]
void reproject_reflections(uint3 gid : SV_DispatchThreadID) {
    let pixel=gid.xy;if (any(pixel>=p.viewport.zw)) {return;}
    let s=surface(pixel);
    if (!s.valid || p.options.w==0u || s.roughness>p.reflection_filter.w) {reflection_store_full(2u,pixel,float4(0.0));return;}
    let current=reflection_load_full(0u,pixel);
    let color=select(source_probe_projection(),current.rgb,safe_radiance(current.rgb));
    var result=float4(color,1.0);
    if (p.reflection.y!=2u) {
        let ray=s.position-p.camera.xyz;let depth=max(length(ray),1e-4);
        let virtual_position=p.camera.xyz+ray/depth*(depth+current.w);
        let hit=reflection_previous(s,reproject(virtual_position));let primary=reflection_previous(s,reproject_surface(pixel,s.position));
        let deviation=reflection_load_full(1u,pixel).rgb;
        let lower=color-deviation;let upper=color+deviation;
        // Previous plane stores sums, matching the original reflection buffer.
        let hit_color=hit.rgb/max(hit.w,1.0);let primary_color=primary.rgb/max(primary.w,1.0);
        let scale=-100.0*p.sky.w;
        let hit_weight=float(hit.w>0.0)*clamp(exp2(scale*luminance(hit_color-color)),0.0,1.0);
        let primary_weight=float(primary.w>0.0)*clamp(exp2(scale*luminance(primary_color-color)),0.0,1.0);
        let weight=max(hit_weight+primary_weight,1e-7);
        let dual=(hit_weight*clamp(hit_color,lower,upper)+primary_weight*clamp(primary_color,lower,upper))/weight;
        let count=(hit_weight*hit.w+primary_weight*primary.w)/weight;
        result+=float4(dual*count,count);
        let uv=(float2(pixel)+0.5)/float2(p.viewport.zw);
        let vignette=pow(15.0*uv.x*(1.0-uv.y)*uv.y*(1.0-uv.x),0.25);
        let cap=max(8.0*vignette,1.0);if (result.w>cap) {result*=cap/result.w;}
    }
    reflection_store_full(2u,pixel,reflection_temporal_result(result));
}
float4 reflection_temporal_result(float4 lighting) {
    let sanitized=select(source_probe_projection(),gi_denoiser_sanitize(float4(lighting.rgb,0.0)).rgb,safe_radiance(lighting.rgb));
    return float4(sanitized,lighting.w);
}
[shader("compute")][numthreads(8,8,1)]
void snapshot_reflections(uint3 gid : SV_DispatchThreadID) {
    if (all(gid.xy<p.viewport.zw)) {reflections[reflection_full_index(3u,gid.xy)]=reflections[reflection_full_index(2u,gid.xy)];}
}
