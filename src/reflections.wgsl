// AMD Capsaicin GI-1.2 glossy_reflections.hlsl, gi1.comp and brdf_lut.comp.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
// Separate planes and dispatches avoid the upstream in-place cleanup race.
@group(0) @binding(27) var<storage, read_write> reflections: array<vec4<f32>>;
fn reflection_size() -> vec2<u32> {
    return (p.viewport.zw + vec2(p.reflection.x - 1u)) / p.reflection.x;
}
fn reflection_count() -> u32 { let size = reflection_size(); return size.x * size.y; }
fn reflection_sample_index(layer: u32, pixel: vec2<u32>) -> u32 {
    return 1024u + layer * reflection_count() + pixel.x + pixel.y * reflection_size().x;
}
fn reflection_full_index(layer: u32, pixel: vec2<u32>) -> u32 {
    return 1024u + 8u * reflection_count() + layer * p.viewport.z * p.viewport.w + pixel.x + pixel.y * p.viewport.z;
}
fn reflection_split_size() -> vec2<u32> { return vec2(p.viewport.z, reflection_size().y); }
fn reflection_split_index(layer: u32, pixel: vec2<u32>) -> u32 {
    let size = reflection_split_size();
    return 1024u + 8u * reflection_count() + 4u * p.viewport.z * p.viewport.w + layer * size.x * size.y + pixel.x + pixel.y * size.x;
}
fn reflection_full_pixel(sample_pixel: vec2<u32>) -> vec2<u32> {
    var phase = vec2(0u);
    if p.reflection.x == 2u { phase = vec2(p.frame.x & 1u, (p.frame.x >> 1u) & 1u); }
    return sample_pixel * p.reflection.x + phase;
}
fn reflection_view(s: Surface) -> vec3<f32> {
    if p.camera.w != 0.0 { return p.camera_direction.xyz; }
    return normalize(p.camera.xyz - s.position);
}
fn reflection_geometric_normal(pixel: vec2<u32>, s: Surface) -> vec3<f32> {
    let left = surface(vec2<u32>(vec2(max(i32(pixel.x) - 1, 0), i32(pixel.y))));
    let right = surface(min(pixel + vec2(1u, 0u), p.viewport.zw - vec2(1u)));
    let up = surface(vec2<u32>(vec2(i32(pixel.x), max(i32(pixel.y) - 1, 0))));
    let down = surface(min(pixel + vec2(0u, 1u), p.viewport.zw - vec2(1u)));
    let dx = select(right.position - s.position, s.position - left.position,
        left.valid && (!right.valid || length(left.position - s.position) < length(right.position - s.position)));
    let dy = select(down.position - s.position, s.position - up.position,
        up.valid && (!down.valid || length(up.position - s.position) < length(down.position - s.position)));
    let product = cross(dx, dy);
    if dot(product, product) < 1e-12 { return s.normal; }
    let n = normalize(product); return n * select(-1.0, 1.0, dot(n, s.normal) >= 0.0);
}
fn reflection_plane_weight(s: Surface, other: Surface, geometric_normal: vec3<f32>) -> f32 {
    // View depth equals camera distance projected onto the camera's forward axis.
    let view_depth = max(abs(dot(p.camera.xyz - s.position, p.camera_direction.xyz)), 1e-4);
    return 1.0 - clamp(abs(dot(geometric_normal, s.position - other.position) / view_depth) * 200.0, 0.0, 1.0);
}
fn reflection_pdf(s: Surface, endpoint: vec4<f32>) -> f32 {
    let view = reflection_view(s); var light = endpoint.xyz;
    if endpoint.w > 0.5 { light = normalize(endpoint.xyz + p.camera.xyz - s.position); }
    let half_sum = view + light;
    if dot(half_sum, half_sum) < 1e-12 { return 0.0; }
    let nh = clamp(dot(s.normal, normalize(half_sum)), -1.0, 1.0);
    let alpha = max(s.roughness * s.roughness, 1e-6);
    return ggx_bounded_pdf(alpha, max(alpha * alpha, 1e-6), nh, transpose(tangent_frame(s.normal)) * view);
}
fn reflection_compress(color: vec3<f32>) -> vec3<f32> { return color / (vec3(1.0) + color); }
fn reflection_decompress(color: vec3<f32>) -> vec3<f32> { return color / max(vec3(1.0) - color, vec3(1e-3)); }
fn reflection_trace(pixel: vec2<u32>, s: Surface, seed: u32) {
    if any(pixel != reflection_full_pixel(pixel / p.reflection.x)) { return; }
    let half_pixel = pixel / p.reflection.x;
    reflections[reflection_sample_index(3u, half_pixel)] = vec4(0.0);
    reflections[reflection_sample_index(0u, half_pixel)] = vec4(0.0);
    if !s.valid || p.options.w == 0u || s.roughness > p.reflection_filter.w { return; }
    let view = reflection_view(s); let basis = tangent_frame(s.normal);
    let alpha = max(s.roughness * s.roughness, 1e-6); var rng = seed;
    let local_view = transpose(basis) * view;
    let h = ggx_bounded_normal(alpha, local_view, vec2(random(&rng), random(&rng)));
    let direction = normalize(basis * reflect(-local_view, h));
    var radiance = vec3(0.0); var distance = -1.0; var endpoint = vec4(direction, 0.0);
    if s.roughness > p.quality.x {
        radiance = gather_directional(s, pixel, direction).rgb;
    } else {
        let normal = reflection_geometric_normal(pixel, s);
        let origin = s.position + normal * p.cache_config.z;
        let hit = trace(origin, direction, p.cache_config.w);
        radiance = p.sky.rgb;
        if hit.triangle != MISSING {
            let position = origin + direction * hit.distance; let n = hit_normal(hit, direction);
            distance = hit.distance; radiance = vec3(0.0);
            if any(n != vec3(0.0)) {
                let emission = material_emission(position, hit.triangle);
                if any(emission > vec3(0.0)) { radiance = emission; }
                else {
                    let previous = visible_previous_radiance(position, n, hit.triangle);
                    if previous.w != 0.0 { radiance = previous.rgb; }
                    else {
                        let jitter = tangent_frame(n) * vec3((vec2(random(&rng),random(&rng))-0.5)*hash_cell_size(position),0.0);
                        let cell = hash_tile_find(position+jitter,direction,distance);
                        if cell != MISSING { hash_touch(cell); radiance = hash_radiance(cell).rgb; }
                        else { radiance = cached_radiance(position,n,distance,hit.triangle,seed,MISSING,direction); }
                    }
                }
            }
            if distance > 0.0 && distance < 100.0 { endpoint = vec4(s.position + direction * distance - p.camera.xyz, 1.0); }
        }
    }
    reflections[reflection_sample_index(0u, half_pixel)] = vec4(reflection_compress(safe_radiance(radiance)), distance);
    reflections[reflection_sample_index(1u, half_pixel)] = endpoint;
    reflections[reflection_sample_index(3u, half_pixel)] = vec4(0.0, 1.0, 0.0, 0.0);
}
@compute @workgroup_size(8, 8)
fn compute_brdf_lut(@builtin(global_invocation_id) gid: vec3<u32>) {
    if any(gid.xy >= vec2(32u)) { return; }
    let uv = (vec2<f32>(gid.xy) + 0.5) / 32.0;
    let alpha = uv.y * uv.y; let view = vec3(sqrt(1.0 - uv.x * uv.x), 0.0, uv.x);
    var sum = vec2(0.0);
    for (var i = 0u; i < 4096u; i++) {
        let samples = vec2(f32(i) / 4096.0, f32(reverseBits(i)) * 2.3283064365386963e-10);
        let half_vector = ggx_bounded_normal(alpha, view, samples); let light = reflect(-view, half_vector);
        let h = normalize(view + light); let nh = clamp(h.z, -1.0, 1.0);
        let fresnel = pow(1.0 - clamp(abs(dot(h, view)), 0.0, 1.0), 5.0);
        let pdf = ggx_bounded_pdf(alpha, alpha * alpha, nh, view);
        let gd = ggx_ndf(alpha * alpha, nh) / ggx_visibility_reciprocal(alpha * alpha, light.z, view.z);
        sum += vec2(gd, gd * fresnel) * max(light.z, 0.0) / max(pdf, 1e-20);
    }
    // The original stores R16G16_FLOAT; preserve that quantization.
    let quantized = unpack2x16float(pack2x16float(sum / 4096.0));
    reflections[gid.x + gid.y * 32u] = vec4(quantized, 0.0, 0.0);
}
fn reflection_directional_albedo(s: Surface) -> vec3<f32> {
    let coord = clamp(vec2(max(dot(s.normal, reflection_view(s)), 0.0), s.roughness), vec2(0.0), vec2(1.0)) * 32.0 - 0.5;
    let base = vec2<i32>(floor(coord)); let f = fract(coord); var lut = vec2(0.0);
    for (var y = 0; y < 2; y++) { for (var x = 0; x < 2; x++) {
        let tap = vec2<u32>(clamp(base + vec2(x,y), vec2(0), vec2(31)));
        let weight = select(1.0-f.x, f.x, x==1) * select(1.0-f.y, f.y, y==1);
        lut += reflections[tap.x + tap.y * 32u].xy * weight;
    }}
    let f0 = mix(vec3(0.16 * s.reflectance * s.reflectance), s.base, s.metallic);
    return clamp(f0 * lut.x + (vec3(1.0) - f0) * lut.y, vec3(0.0), vec3(1.0));
}
@compute @workgroup_size(8, 8)
fn mark_reflection_fireflies(@builtin(global_invocation_id) gid: vec3<u32>) {
    if any(gid.xy >= reflection_size()) { return; }
    let pixel = reflection_full_pixel(gid.xy); let id = reflection_sample_index(3u, gid.xy);
    if any(pixel >= p.viewport.zw) || reflections[id].y == 0.0 { return; }
    let raw = reflections[reflection_sample_index(0u,gid.xy)];
    var marked = f32(raw.w < 0.0);
    if marked == 0.0 && p.reflection.w != 0u {
        let center = luminance(raw.rgb); var lower = 0.0; var higher = 0.0;
        let radius = i32(p.reflection_filter.y); let half_radius = (radius + i32(p.reflection.x) - 1) / i32(p.reflection.x);
        for (var y = -half_radius; y <= half_radius; y++) { for (var x = -half_radius; x <= half_radius; x++) {
            if x == 0 && y == 0 { continue; }
            let tap = vec2<i32>(gid.xy) + vec2(x,y);
            if any(tap < vec2(0)) || any(tap >= vec2<i32>(reflection_size())) || any(abs(vec2(x,y) * i32(p.reflection.x)) > vec2(radius)) { continue; }
            if reflections[reflection_sample_index(3u,vec2<u32>(tap))].y == 0.0 { continue; }
            let value = luminance(reflections[reflection_sample_index(0u,vec2<u32>(tap))].rgb);
            higher += f32(value < center); lower += f32(value > center);
        }}
        marked = f32(lower < p.reflection_thresholds.x * (lower + higher) || higher > p.reflection_thresholds.y * (lower + higher));
    }
    // Each invocation owns its flag; never reads neighbors' written x channel.
    reflections[id].x = select(0.0, marked, p.reflection.w != 0u);
}
@compute @workgroup_size(8, 8)
fn cleanup_reflection_fireflies(@builtin(global_invocation_id) gid: vec3<u32>) {
    if any(gid.xy >= reflection_size()) { return; }
    let id = reflection_sample_index(0u,gid.xy); let raw = reflections[id];
    let pixel = reflection_full_pixel(gid.xy); var result = raw;
    if all(pixel < p.viewport.zw) && reflections[reflection_sample_index(3u,gid.xy)].x > 0.5 {
        let s = surface(pixel); let n = reflection_geometric_normal(pixel,s);
        let radius = i32(p.reflection_filter.z); let half_radius = (radius + i32(p.reflection.x) - 1) / i32(p.reflection.x);
        var sum = vec4(0.0); var total = 0.0;
        for (var y = -half_radius; y <= half_radius; y++) { for (var x = -half_radius; x <= half_radius; x++) {
            let tap = vec2<i32>(gid.xy) + vec2(x,y);
            if any(tap < vec2(0)) || any(tap >= vec2<i32>(reflection_size())) { continue; }
            let q = vec2<u32>(tap); let full = reflection_full_pixel(q);
            if any(full >= p.viewport.zw) { continue; }
            let flags = reflections[reflection_sample_index(3u,q)]; if flags.x != 0.0 || flags.y == 0.0 { continue; }
            let other = surface(full); if !other.valid { continue; }
            let delta = vec2<f32>(vec2(x,y) * i32(p.reflection.x));
            let w = exp(-dot(delta,delta) / pow(f32(radius + 1),2.0)) * reflection_plane_weight(s,other,n);
            sum += reflections[reflection_sample_index(0u,q)] * w; total += w;
        }}
        if total > 0.0 { result = sum / total; }
    }
    reflections[reflection_sample_index(2u,gid.xy)] = vec4(safe_radiance(result.rgb), result.w);
}
fn reflection_ratio_filter(pixel: vec2<u32>, step: i32, input_layer: u32, last: bool) {
    let s = surface(pixel); let full_id = reflection_full_index(0u,pixel);
    if !s.valid || p.options.w == 0u || s.roughness > p.reflection_filter.w {
        if last { reflections[full_id] = vec4(0.0); reflections[reflection_full_index(1u,pixel)] = vec4(0.0); }
        return;
    }
    let n = reflection_geometric_normal(pixel,s); let half_pixel = pixel / p.reflection.x;
    let half_step = max((step + i32(p.reflection.x) - 1) / i32(p.reflection.x),1);
    let half_radius = (2 * step + i32(p.reflection.x) - 1) / i32(p.reflection.x);
    var jitter = vec2(0);
    if last {
        var mean = 0.0; var second = 0.0; var count = 0.0;
        for (var y = -4; y <= 4; y+=2) { for (var x = -4; x <= 4; x+=2) {
            let tap = vec2<i32>(pixel)+vec2(x,y); if any(tap<vec2(0)) || any(tap>=vec2<i32>(p.viewport.zw)) { continue; }
            let r = surface(vec2<u32>(tap)).roughness; mean+=r;second+=r*r;count+=1.0;
        }}
        mean /= max(count,1.0); second /= max(count,1.0);
        let scale = clamp(4.0 * sqrt(abs(second-mean*mean)) / max(mean,1e-6),0.0,1.0);
        var rng = hash32(pixel.x + pixel.y*p.viewport.z + hash32(p.frame.x+761u));
        jitter = vec2<i32>(floor((vec2(random(&rng),random(&rng))-0.5)*f32(half_step)*scale+0.5));
    }
    var sum = vec4(0.0); var second = vec3(0.0); var total = 0.0;
    for (var y = -half_radius; y <= half_radius; y+=half_step) { for (var x = -half_radius; x <= half_radius; x+=half_step) {
        let tap = vec2<i32>(half_pixel)+vec2(x,y)+jitter;
        if any(tap < vec2(0)) || any(tap >= vec2<i32>(reflection_size())) { continue; }
        let q = vec2<u32>(tap); let full = reflection_full_pixel(q);
        if any(full >= p.viewport.zw) || reflections[reflection_sample_index(3u,q)].y == 0.0 { continue; }
        let other = surface(full); if !other.valid || other.roughness > p.reflection_filter.w { continue; }
        let delta = vec2<f32>(vec2<i32>(full)-vec2<i32>(pixel)); let sigma = 1.065*f32(step);
        let gaussian = exp(-dot(delta,delta)/(2.0*sigma*sigma));
        let weight = gaussian * reflection_plane_weight(s,other,n) * reflection_pdf(s,reflections[reflection_sample_index(1u,q)]);
        let value = reflections[reflection_sample_index(input_layer,q)]; var squared = value.rgb*value.rgb;
        if input_layer >= 4u { squared = pow(reflections[reflection_sample_index(input_layer+2u,q)].rgb,vec3(2.0)); }
        sum += value*weight; second += squared*weight; total += weight;
    }}
    if total > 1e-3 { sum /= total; second /= total; }
    if last {
        let deviation = sqrt(abs(second-sum.rgb*sum.rgb));
        reflections[full_id] = vec4(reflection_decompress(sum.rgb),sum.w);
        reflections[reflection_full_index(1u,pixel)] = vec4(reflection_decompress(deviation),1.0);
    } else {
        var output_layer = 4u; if input_layer == 4u { output_layer = 5u; }
        reflections[reflection_sample_index(output_layer,half_pixel)] = sum;
        reflections[reflection_sample_index(output_layer+2u,half_pixel)] = vec4(sqrt(max(second,vec3(0.0))),1.0);
    }
}
@compute @workgroup_size(8,8)
fn reflection_atrous_first(@builtin(global_invocation_id) gid: vec3<u32>) {
    let pixel=reflection_full_pixel(gid.xy);
    if all(gid.xy<reflection_size()) && all(pixel<p.viewport.zw) { reflection_ratio_filter(pixel,1,2u,false); }
}
fn reflection_atrous_iteration(pixel: vec2<u32>, iteration: u32) {
    let full=reflection_full_pixel(pixel);
    if all(pixel<reflection_size()) && all(full<p.viewport.zw) { reflection_ratio_filter(full,i32(1u<<iteration),4u+(iteration-1u)%2u,false); }
}
@compute @workgroup_size(8,8) fn reflection_atrous_2(@builtin(global_invocation_id) gid: vec3<u32>) { reflection_atrous_iteration(gid.xy,1u); }
@compute @workgroup_size(8,8) fn reflection_atrous_4(@builtin(global_invocation_id) gid: vec3<u32>) { reflection_atrous_iteration(gid.xy,2u); }
@compute @workgroup_size(8,8) fn reflection_atrous_8(@builtin(global_invocation_id) gid: vec3<u32>) { reflection_atrous_iteration(gid.xy,3u); }
@compute @workgroup_size(8,8) fn reflection_atrous_16(@builtin(global_invocation_id) gid: vec3<u32>) { reflection_atrous_iteration(gid.xy,4u); }
@compute @workgroup_size(8,8) fn reflection_atrous_32(@builtin(global_invocation_id) gid: vec3<u32>) { reflection_atrous_iteration(gid.xy,5u); }
@compute @workgroup_size(8,8) fn reflection_atrous_64(@builtin(global_invocation_id) gid: vec3<u32>) { reflection_atrous_iteration(gid.xy,6u); }
@compute @workgroup_size(8,8)
fn reflection_atrous_last(@builtin(global_invocation_id) gid: vec3<u32>) {
    if all(gid.xy<p.viewport.zw) { reflection_ratio_filter(gid.xy,i32(1u<<(p.reflection.z-1u)),4u+(p.reflection.z-2u)%2u,true); }
}
// Separable ratio estimator: horizontal full-width / sampled-height, then vertical full resolution.
fn reflection_split(pixel: vec2<u32>, vertical: bool) {
    let s=surface(pixel); let radius=i32(p.reflection_filter.x); let half_radius=(radius+i32(p.reflection.x)-1)/i32(p.reflection.x);
    let n=reflection_geometric_normal(pixel,s); var sum=vec4(0.0);var second=vec3(0.0);var total=0.0;
    if s.valid && s.roughness<=p.reflection_filter.w && p.options.w!=0u {
        for (var i=-half_radius;i<=half_radius;i++) {
            var tap=vec2<i32>(pixel/p.reflection.x)+vec2(i,0); if vertical { tap=vec2<i32>(pixel/p.reflection.x)+vec2(0,i); }
            if any(tap<vec2(0)) || any(tap>=vec2<i32>(reflection_size())) { continue; }
            let q=vec2<u32>(tap);var full=reflection_full_pixel(q);if vertical { full.x=pixel.x; }
            if any(full>=p.viewport.zw) {continue;}
            let other=surface(full);if !other.valid || other.roughness>p.reflection_filter.w {continue;}
            let endpoint=reflections[reflection_sample_index(1u,q)];
            let delta=select(i32(full.x)-i32(pixel.x),i32(full.y)-i32(pixel.y),vertical);
            let gaussian=exp(-f32(delta*delta)/(2.0*pow(0.375*f32(radius),2.0)));
            let weight=gaussian*reflection_plane_weight(s,other,n)*reflection_pdf(s,endpoint);
            var value=reflections[reflection_sample_index(2u,q)]; var squared=value.rgb*value.rgb;
            if vertical { let split=vec2(pixel.x,q.y); value=reflections[reflection_split_index(0u,split)];squared=pow(reflections[reflection_split_index(1u,split)].rgb,vec3(2.0)); }
            sum+=value*weight;second+=squared*weight;total+=weight;
        }
    }
    if total>1e-3 {sum/=total;second/=total;}
    if vertical {
        reflections[reflection_full_index(0u,pixel)]=vec4(reflection_decompress(sum.rgb),sum.w);
        reflections[reflection_full_index(1u,pixel)]=vec4(reflection_decompress(sqrt(abs(second-sum.rgb*sum.rgb))),1.0);
    } else {
        let split=vec2(pixel.x,pixel.y/p.reflection.x);
        reflections[reflection_split_index(0u,split)]=sum;
        reflections[reflection_split_index(1u,split)]=vec4(sqrt(max(second,vec3(0.0))),1.0);
    }
}
@compute @workgroup_size(8,8)
fn reflection_split_x(@builtin(global_invocation_id) gid: vec3<u32>) {
    if any(gid.xy>=reflection_split_size()) {return;}
    let pixel=vec2(gid.x,gid.y*p.reflection.x);if pixel.y<p.viewport.w {reflection_split(pixel,false);}
}
@compute @workgroup_size(8,8)
fn reflection_split_y(@builtin(global_invocation_id) gid: vec3<u32>) {if all(gid.xy<p.viewport.zw) {reflection_split(gid.xy,true);} }
@compute @workgroup_size(8,8)
fn reflection_no_denoiser(@builtin(global_invocation_id) gid: vec3<u32>) {
    if any(gid.xy>=p.viewport.zw) {return;}
    let raw=reflections[reflection_sample_index(2u,gid.xy/p.reflection.x)];
    reflections[reflection_full_index(0u,gid.xy)]=vec4(reflection_decompress(raw.rgb),raw.w);
    reflections[reflection_full_index(1u,gid.xy)]=vec4(0.0);
}
fn reflection_previous(s: Surface, uv: vec2<f32>) -> vec4<f32> {
    if p.frame.y!=0u || any(uv<vec2(0.0)) || any(uv>=vec2(1.0)) {return vec4(0.0);}
    let coord=uv*vec2<f32>(p.viewport.zw)-0.5;let base=vec2<i32>(floor(coord));let fraction=fract(coord);
    var sum=vec4(0.0);var best=vec4(0.0);var best_weight=0.9;var all_valid=true;
    let center_depth=max(abs(dot(p.camera.xyz-s.position,p.camera_direction.xyz)),1e-4);
    for(var y=0;y<2;y++) {for(var x=0;x<2;x++) {
        let tap=base+vec2(x,y);
        if any(tap<vec2(0)) || any(tap>=vec2<i32>(p.viewport.zw)) {all_valid=false;continue;}
        let pos=textureLoad(previous_position,tap,0);let normal=textureLoad(previous_normal,tap,0);
        if !history_material_matches(s,pos.w) {all_valid=false;continue;}
        var previous_depth=abs(dot(p.camera.xyz-pos.xyz,p.camera_direction.xyz));
        if p.camera.w==0.0 {previous_depth=abs((p.previous_clip_from_world*vec4(pos.xyz,1.0)).w);}
        let disocclusion=exp(-abs(1.0-max(0.0,dot(s.normal,normal.xyz)))*1.4)
            *exp(-abs(previous_depth-center_depth)/center_depth);
        let value=reflections[reflection_full_index(3u,vec2<u32>(tap))];
        let weight=select(1.0-fraction.x,fraction.x,x==1)*select(1.0-fraction.y,fraction.y,y==1);
        sum+=value*weight;
        if disocclusion<=0.9 || pos.w==0.0 {all_valid=false;}
        if disocclusion>best_weight && pos.w!=0.0 {best_weight=disocclusion;best=value;}
    }}
    return select(best,sum,all_valid);
}
@compute @workgroup_size(8,8)
fn reproject_reflections(@builtin(global_invocation_id) gid: vec3<u32>) {
    let pixel=gid.xy;if any(pixel>=p.viewport.zw) {return;}
    let s=surface(pixel);let id=reflection_full_index(2u,pixel);
    if !s.valid || p.options.w==0u || s.roughness>p.reflection_filter.w {reflections[id]=vec4(0.0);return;}
    let current=reflections[reflection_full_index(0u,pixel)];let color=safe_radiance(current.rgb);
    var result=vec4(color,1.0);
    if p.reflection.y!=2u {
        let ray=s.position-p.camera.xyz;let depth=max(length(ray),1e-4);
        let virtual_position=p.camera.xyz+ray/depth*(depth+current.w);
        let hit=reflection_previous(s,reproject(virtual_position));let primary=reflection_previous(s,reproject(s.position));
        let deviation=reflections[reflection_full_index(1u,pixel)].rgb;
        let lower=color-deviation;let upper=color+deviation;
        // Previous plane stores sums, matching the original reflection buffer.
        let hit_color=hit.rgb/max(hit.w,1.0);let primary_color=primary.rgb/max(primary.w,1.0);
        let scale=-100.0*p.sky.w;
        let hit_weight=f32(hit.w>0.0)*clamp(exp2(scale*luminance(hit_color-color)),0.0,1.0);
        let primary_weight=f32(primary.w>0.0)*clamp(exp2(scale*luminance(primary_color-color)),0.0,1.0);
        let weight=max(hit_weight+primary_weight,1e-7);
        let dual=(hit_weight*clamp(hit_color,lower,upper)+primary_weight*clamp(primary_color,lower,upper))/weight;
        let count=(hit_weight*hit.w+primary_weight*primary.w)/weight;
        result+=vec4(dual*count,count);
        let uv=(vec2<f32>(pixel)+0.5)/vec2<f32>(p.viewport.zw);
        let vignette=pow(15.0*uv.x*(1.0-uv.y)*uv.y*(1.0-uv.x),0.25);
        let cap=max(8.0*vignette,1.0);if result.w>cap {result*=cap/result.w;}
    }
    reflections[id]=vec4(safe_radiance(result.rgb),result.w);
}
@compute @workgroup_size(8,8)
fn snapshot_reflections(@builtin(global_invocation_id) gid: vec3<u32>) {
    if all(gid.xy<p.viewport.zw) {reflections[reflection_full_index(3u,gid.xy)]=reflections[reflection_full_index(2u,gid.xy)];}
}
