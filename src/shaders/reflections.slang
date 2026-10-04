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
uint reflection_full_index(uint layer, uint2 pixel) {
    return 1024u + 8u * reflection_count() + layer * p.viewport.z * p.viewport.w + pixel.x + pixel.y * p.viewport.z;
}
uint2 reflection_split_size() { return uint2(p.viewport.z, reflection_size().y); }
uint reflection_split_index(uint layer, uint2 pixel) {
    let size = reflection_split_size();
    return 1024u + 8u * reflection_count() + 4u * p.viewport.z * p.viewport.w + layer * size.x * size.y + pixel.x + pixel.y * size.x;
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
float3 reflection_geometric_normal(uint2 pixel, Surface s) {
    let left = surface(uint2(int2(max(int(pixel.x) - 1, 0), int(pixel.y))));
    let right = surface(min(pixel + uint2(1u, 0u), p.viewport.zw - uint2(1u)));
    let up = surface(uint2(int2(int(pixel.x), max(int(pixel.y) - 1, 0))));
    let down = surface(min(pixel + uint2(0u, 1u), p.viewport.zw - uint2(1u)));
    let dx = select(left.valid && (!right.valid || length(left.position - s.position) < length(right.position - s.position)), s.position - left.position, right.position - s.position);
    let dy = select(up.valid && (!down.valid || length(up.position - s.position) < length(down.position - s.position)), s.position - up.position, down.position - s.position);
    let product = cross(dx, dy);
    if (dot(product, product) < 1e-12) { return s.normal; }
    let n = normalize(product); return n * select(dot(n, s.normal) >= 0.0, 1.0, -1.0);
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
    let nh = clamp(dot(s.normal, normalize(half_sum)), -1.0, 1.0);
    let alpha = max(s.roughness * s.roughness, 1e-6);
    return ggx_bounded_pdf(alpha, max(alpha * alpha, 1e-6), nh, mul(transpose(tangent_frame(s.normal)), view));
}
float3 reflection_compress(float3 color) { return color / (float3(1.0) + color); }
float3 reflection_decompress(float3 color) { return color / max(float3(1.0) - color, float3(1e-3)); }
float3 reflection_cache_jitter(float3 normal,float cell_size,float2 samples) {
    // TraceReflectionsHandleHit reuses the GGX sample payload.s and source
    // GetOrthoVectors. A second RNG and half-radius displacement changed the
    // lookup distribution and introduced a different tiled artifact pattern.
    return mul(probe_frame(normal),float3((2.0*samples-1.0)*cell_size,0.0));
}
void reflection_trace(uint2 pixel, Surface s, uint seed) {
    if (any(pixel != reflection_full_pixel(pixel / p.reflection.x))) { return; }
    let half_pixel = pixel / p.reflection.x;
    reflections[reflection_sample_index(3u, half_pixel)] = float4(0.0);
    reflections[reflection_sample_index(0u, half_pixel)] = float4(0.0);
    if (!s.valid || p.options.w == 0u || s.roughness > p.reflection_filter.w) { return; }
    let view = reflection_view(s); let rotation=ggx_rotation_to_z(s.normal);
    let alpha = max(s.roughness * s.roughness, 1e-6);
    let samples=reflection_blue_noise(pixel,p.frame.x,2u);
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
        radiance = environment_radiance(direction);
        if (hit.triangle != MISSING) {
            let position = origin + direction * hit.distance; let n = hit_normal(hit, direction);
            distance = hit.distance; radiance = float3(0.0);
            if (any(n != float3(0.0))) {
                let emission = material_emission(position, hit.triangle);
                if (any(emission > float3(0.0))) { radiance = emission; }
                else {
                    let previous = visible_previous_radiance(position, n, hit.triangle);
                    if (previous.w != 0.0) { radiance = previous.rgb; }
                    else {
                        let jitter = reflection_cache_jitter(n,hash_cell_size(position),samples);
                        let cell = hash_tile_find(position+jitter,direction,distance);
                        if (cell != MISSING) { hash_touch(cell); radiance = hash_radiance(cell).rgb; }
                        else { radiance = cached_radiance(position,n,distance,hit.triangle,seed,MISSING,direction); }
                    }
                }
            }
            if (distance > 0.0 && distance < 100.0) { endpoint = float4(s.position + direction * distance - p.camera.xyz, 1.0); }
        }
    }
    reflections[reflection_sample_index(0u, half_pixel)] = float4(reflection_compress(safe_radiance(radiance)), distance);
    reflections[reflection_sample_index(1u, half_pixel)] = endpoint;
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
    let lut=sample_brdf_lut(max(dot(s.normal,reflection_view(s)),0.0),s.roughness);
    let f0 = lerp(float3(0.16 * s.reflectance * s.reflectance), s.base, s.metallic);
    return clamp(f0 * lut.x + (float3(1.0) - f0) * lut.y, float3(0.0), float3(1.0));
}
[shader("compute")][numthreads(8, 8,1)]
void mark_reflection_fireflies(uint3 gid : SV_DispatchThreadID) {
    if (any(gid.xy >= reflection_size())) { return; }
    let pixel = reflection_full_pixel(gid.xy); let id = reflection_sample_index(3u, gid.xy);
    if (any(pixel >= p.viewport.zw) || reflections[id].y == 0.0) { return; }
    let raw = reflections[reflection_sample_index(0u,gid.xy)];
    var marked = float(raw.w < 0.0);
    if (marked == 0.0 && p.reflection.w != 0u) {
        let center = luminance(raw.rgb); var lower = 0.0; var higher = 0.0;
        let radius = int(p.reflection_filter.y); let half_radius = (radius + int(p.reflection.x) - 1) / int(p.reflection.x);
        for (var y = -half_radius; y <= half_radius; y++) { for (var x = -half_radius; x <= half_radius; x++) {
            if (x == 0 && y == 0) { continue; }
            let tap = int2(gid.xy) + int2(x,y);
            if (any(tap < int2(0)) || any(tap >= int2(reflection_size())) || any(abs(int2(x,y) * int(p.reflection.x)) > int2(radius))) { continue; }
            if (reflections[reflection_sample_index(3u,uint2(tap))].y == 0.0) { continue; }
            let value = luminance(reflections[reflection_sample_index(0u,uint2(tap))].rgb);
            higher += float(value < center); lower += float(value > center);
        }}
        marked = float(lower < p.reflection_thresholds.x * (lower + higher) || higher > p.reflection_thresholds.y * (lower + higher));
    }
    // Each invocation owns its flag; never reads neighbors' written x channel.
    reflections[id].x = select(p.reflection.w != 0u, marked, 0.0);
}
[shader("compute")][numthreads(8, 8,1)]
void cleanup_reflection_fireflies(uint3 gid : SV_DispatchThreadID) {
    if (any(gid.xy >= reflection_size())) { return; }
    let id = reflection_sample_index(0u,gid.xy); let raw = reflections[id];
    let pixel = reflection_full_pixel(gid.xy); var result = raw;
    if (all(pixel < p.viewport.zw) && reflections[reflection_sample_index(3u,gid.xy)].x > 0.5) {
        let s = surface(pixel); let n = reflection_geometric_normal(pixel,s);
        let radius = int(p.reflection_filter.z); let half_radius = (radius + int(p.reflection.x) - 1) / int(p.reflection.x);
        var sum = float4(0.0); var total = 0.0;
        for (var y = -half_radius; y <= half_radius; y++) { for (var x = -half_radius; x <= half_radius; x++) {
            let tap = int2(gid.xy) + int2(x,y);
            if (any(tap < int2(0)) || any(tap >= int2(reflection_size()))) { continue; }
            let q = uint2(tap); let full = reflection_full_pixel(q);
            if (any(full >= p.viewport.zw)) { continue; }
            let flags = reflections[reflection_sample_index(3u,q)]; if (flags.x != 0.0 || flags.y == 0.0) { continue; }
            let other = surface(full); if (!other.valid) { continue; }
            let delta = float2(int2(x,y) * int(p.reflection.x));
            let w = exp(-dot(delta,delta) / pow(float(radius + 1),2.0)) * reflection_plane_weight(s,other,n);
            sum += reflections[reflection_sample_index(0u,q)] * w; total += w;
        }}
        if (total > 0.0) { result = sum / total; }
    }
    reflections[reflection_sample_index(2u,gid.xy)] = float4(safe_radiance(result.rgb), result.w);
}
void reflection_ratio_filter(uint2 pixel, int step, uint input_layer, bool last) {
    let s = surface(pixel); let full_id = reflection_full_index(0u,pixel);
    if (!s.valid || p.options.w == 0u || s.roughness > p.reflection_filter.w) {
        if (last) { reflections[full_id] = float4(0.0); reflections[reflection_full_index(1u,pixel)] = float4(0.0); }
        return;
    }
    let n = reflection_geometric_normal(pixel,s); let half_pixel = pixel / p.reflection.x;
    let half_step = max((step + int(p.reflection.x) - 1) / int(p.reflection.x),1);
    let half_radius = (2 * step + int(p.reflection.x) - 1) / int(p.reflection.x);
    var jitter = int2(0);
    if (last) {
        var mean = 0.0; var second = 0.0; var count = 0.0;
        for (var y = -4; y <= 4; y+=2) { for (var x = -4; x <= 4; x+=2) {
            let tap = int2(pixel)+int2(x,y); if (any(tap<int2(0)) || any(tap>=int2(p.viewport.zw))) { continue; }
            let r = surface(uint2(tap)).roughness; mean+=r;second+=r*r;count+=1.0;
        }}
        mean /= max(count,1.0); second /= max(count,1.0);
        let scale = clamp(4.0 * sqrt(abs(second-mean*mean)) / max(mean,1e-6),0.0,1.0);
        jitter = int2(floor((reflection_blue_noise(pixel,p.frame.x,0u)-0.5)*float(half_step)*scale+0.5));
    }
    var sum = float4(0.0); var second = float3(0.0); var total = 0.0;
    for (var y = -half_radius; y <= half_radius; y+=half_step) { for (var x = -half_radius; x <= half_radius; x+=half_step) {
        let tap = int2(half_pixel)+int2(x,y)+jitter;
        if (any(tap < int2(0)) || any(tap >= int2(reflection_size()))) { continue; }
        let q = uint2(tap); let full = reflection_full_pixel(q);
        if (any(full >= p.viewport.zw) || reflections[reflection_sample_index(3u,q)].y == 0.0) { continue; }
        let other = surface(full); if (!other.valid || other.roughness > p.reflection_filter.w) { continue; }
        let delta = float2(int2(full)-int2(pixel)); let sigma = 1.065*float(step);
        let gaussian = exp(-dot(delta,delta)/(2.0*sigma*sigma));
        let weight = gaussian * reflection_plane_weight(s,other,n) * reflection_pdf(s,reflections[reflection_sample_index(1u,q)]);
        let value = reflections[reflection_sample_index(input_layer,q)]; var squared = value.rgb*value.rgb;
        if (input_layer >= 4u) { squared = pow(reflections[reflection_sample_index(input_layer+2u,q)].rgb,float3(2.0)); }
        sum += value*weight; second += squared*weight; total += weight;
    }}
    if (total > 1e-3) { sum /= total; second /= total; }
    if (last) {
        let deviation = sqrt(abs(second-sum.rgb*sum.rgb));
        reflections[full_id] = float4(reflection_decompress(sum.rgb),sum.w);
        reflections[reflection_full_index(1u,pixel)] = float4(reflection_decompress(deviation),1.0);
    } else {
        var output_layer = 4u; if (input_layer == 4u) { output_layer = 5u; }
        reflections[reflection_sample_index(output_layer,half_pixel)] = sum;
        reflections[reflection_sample_index(output_layer+2u,half_pixel)] = float4(sqrt(max(second,float3(0.0))),1.0);
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
    if (s.valid && s.roughness<=p.reflection_filter.w && p.options.w!=0u) {
        for (var i=-half_radius;i<=half_radius;i++) {
            var tap=int2(pixel/p.reflection.x)+int2(i,0); if (vertical) { tap=int2(pixel/p.reflection.x)+int2(0,i); }
            if (any(tap<int2(0)) || any(tap>=int2(reflection_size()))) { continue; }
            let q=uint2(tap);var full=reflection_full_pixel(q);if (vertical) { full.x=pixel.x; }
            if (any(full>=p.viewport.zw)) {continue;}
            let other=surface(full);if (!other.valid || other.roughness>p.reflection_filter.w) {continue;}
            let endpoint=reflections[reflection_sample_index(1u,q)];
            let delta=select(vertical, int(full.y)-int(pixel.y), int(full.x)-int(pixel.x));
            let gaussian=exp(-float(delta*delta)/(2.0*pow(0.375*float(radius),2.0)));
            let weight=gaussian*reflection_plane_weight(s,other,n)*reflection_pdf(s,endpoint);
            var value=reflections[reflection_sample_index(2u,q)]; var squared=value.rgb*value.rgb;
            if (vertical) { let split=uint2(pixel.x,q.y); value=reflections[reflection_split_index(0u,split)];squared=pow(reflections[reflection_split_index(1u,split)].rgb,float3(2.0)); }
            sum+=value*weight;second+=squared*weight;total+=weight;
        }
    }
    if (total>1e-3) {sum/=total;second/=total;}
    if (vertical) {
        reflections[reflection_full_index(0u,pixel)]=float4(reflection_decompress(sum.rgb),sum.w);
        reflections[reflection_full_index(1u,pixel)]=float4(reflection_decompress(sqrt(abs(second-sum.rgb*sum.rgb))),1.0);
    } else {
        let split=uint2(pixel.x,pixel.y/p.reflection.x);
        reflections[reflection_split_index(0u,split)]=sum;
        reflections[reflection_split_index(1u,split)]=float4(sqrt(max(second,float3(0.0))),1.0);
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
    let raw=reflections[reflection_sample_index(2u,gid.xy/p.reflection.x)];
    reflections[reflection_full_index(0u,gid.xy)]=float4(reflection_decompress(raw.rgb),raw.w);
    reflections[reflection_full_index(1u,gid.xy)]=float4(0.0);
}
float4 reflection_previous(Surface s, float2 uv) {
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
        let disocclusion=exp(-abs(1.0-max(0.0,dot(s.normal,normal.xyz)))*1.4)
            *exp(-abs(previous_depth-center_depth)/center_depth);
        let value=reflections[reflection_full_index(3u,uint2(tap))];
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
    let s=surface(pixel);let id=reflection_full_index(2u,pixel);
    if (!s.valid || p.options.w==0u || s.roughness>p.reflection_filter.w) {reflections[id]=float4(0.0);return;}
    let current=reflections[reflection_full_index(0u,pixel)];let color=safe_radiance(current.rgb);
    var result=float4(color,1.0);
    if (p.reflection.y!=2u) {
        let ray=s.position-p.camera.xyz;let depth=max(length(ray),1e-4);
        let virtual_position=p.camera.xyz+ray/depth*(depth+current.w);
        let hit=reflection_previous(s,reproject(virtual_position));let primary=reflection_previous(s,reproject_surface(pixel,s.position));
        let deviation=reflections[reflection_full_index(1u,pixel)].rgb;
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
    reflections[id]=float4(safe_radiance(result.rgb),result.w);
}
[shader("compute")][numthreads(8,8,1)]
void snapshot_reflections(uint3 gid : SV_DispatchThreadID) {
    if (all(gid.xy<p.viewport.zw)) {reflections[reflection_full_index(3u,gid.xy)]=reflections[reflection_full_index(2u,gid.xy)];}
}
