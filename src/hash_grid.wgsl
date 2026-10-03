// Ported from AMD Capsaicin hash_grid_cache.hlsl and UpdateTiles in gi1.comp,
// commit 914b91596cd119eda85fbc1d3c7ee6ac391b1452. See THIRD_PARTY_NOTICES.md.
@group(0) @binding(25) var<storage, read_write> hash_tiles: array<atomic<u32>>;
var<workgroup> tile_direct: array<vec2<u32>, 64>;
var<workgroup> tile_indirect: array<vec2<u32>, 64>;
var<workgroup> tile_group_active: u32;
fn pcg_hash(value: u32) -> u32 {
    let state = value * 747796405u + 2891336453u;
    let word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
fn xx_hash(value: u32) -> u32 {
    var ret = value + 374761393u;
    ret = 668265263u * ((ret << 17u) | (ret >> 15u));
    ret = 2246822519u * (ret ^ (ret >> 15u));
    ret = 3266489917u * (ret ^ (ret >> 13u));
    return ret ^ (ret >> 16u);
}
fn hash_tile_meta(tile: u32) -> u32 { return 16u + p.hash_config.w + tile * 4u; }
fn hash_mip_count() -> u32 {
    var count = 0u;
    for (var mip = 0u; mip < 4u; mip++) { let size = p.hash_config.z >> mip; count += size * size; }
    return count;
}
fn hash_cell_index(tile: u32, offset: vec2<u32>, mip: u32) -> u32 {
    var first = 0u;
    for (var i = 0u; i < mip; i++) { let size = p.hash_config.z >> i; first += size * size; }
    let size = p.hash_config.z >> mip;
    return tile * hash_mip_count() + first + (offset.x >> mip) + (offset.y >> mip) * size;
}
fn hash_value_base(cell: u32, indirect: bool) -> u32 {
    return 16u + p.hash_config.w * 5u + cell * 4u + select(0u, 2u, indirect);
}
fn hash_scratch_base(tile: u32, offset: vec2<u32>, indirect: bool) -> u32 {
    let base = 16u + p.hash_config.w * (5u + hash_mip_count() * 4u);
    return base + (tile * p.hash_config.z * p.hash_config.z + offset.x + offset.y * p.hash_config.z) * 8u + select(0u, 4u, indirect);
}
fn hash_pack(value: vec4<f32>) -> vec2<u32> { return vec2(pack2x16float(value.xy), pack2x16float(value.zw)); }
fn hash_unpack(value: vec2<u32>) -> vec4<f32> { return vec4(unpack2x16float(value.x), unpack2x16float(value.y)); }
fn hash_read(cell: u32, indirect: bool) -> vec4<f32> {
    let base = hash_value_base(cell, indirect);
    return hash_unpack(vec2(atomicLoad(&hash_tiles[base]), atomicLoad(&hash_tiles[base + 1u])));
}
fn hash_write(cell: u32, indirect: bool, value: vec4<f32>) {
    let base = hash_value_base(cell, indirect); let packed = hash_pack(value);
    atomicStore(&hash_tiles[base], packed.x); atomicStore(&hash_tiles[base + 1u], packed.y);
}
struct HashTileDesc { bucket: u32, tag: u32, offset: vec2<u32> }
fn hash_cell_size(position: vec3<f32>) -> f32 {
    let step = max(length(position - p.camera.xyz) * p.hash_sampling.w, p.cache_config.x);
    return 0.001 * exp2(floor(log2(1000.0 * step)));
}
fn hash_tile_descriptor(position: vec3<f32>, direction: vec3<f32>, distance: f32) -> HashTileDesc {
    let step = max(length(position - p.camera.xyz) * p.hash_sampling.w, p.cache_config.x);
    let level = floor(log2(1000.0 * step));
    let cell_size = 0.001 * exp2(level); let tile_size = cell_size * f32(p.hash_config.z);
    let c = bitcast<vec3<u32>>(vec3<i32>(floor(position / tile_size)));
    let d = vec3<u32>(floor(vec3(0.5) + (direction * 0.5 + vec3(0.5)) * 4.0));
    let l = u32(level); let t = u32(distance < tile_size);
    let bucket = pcg_hash(l + pcg_hash(c.x + pcg_hash(c.y + pcg_hash(c.z + pcg_hash(d.x + pcg_hash(d.y + pcg_hash(d.z + pcg_hash(t)))))))) % p.hash_config.x;
    let tag = max(1u, xx_hash(l + xx_hash(c.x + xx_hash(c.y + xx_hash(c.z + xx_hash(d.x + xx_hash(d.y + xx_hash(d.z + xx_hash(t)))))))));
    let e = vec3<u32>(clamp(floor(position / cell_size) - floor(position / tile_size) * f32(p.hash_config.z), vec3(0.0), vec3(f32(p.hash_config.z - 1u))));
    let a = abs(direction); var offset = e.xy;
    if a.x == max(max(a.x, a.y), a.z) { offset = e.yz; }
    else if a.y == max(max(a.x, a.y), a.z) { offset = e.xz; }
    return HashTileDesc(bucket, tag, offset);
}
fn hash_tile_insert(position: vec3<f32>, direction: vec3<f32>, distance: f32) -> u32 {
    let desc = hash_tile_descriptor(position, direction, distance);
    for (var offset = 0u; offset < p.hash_config.y; offset++) {
        let tile = desc.bucket * p.hash_config.y + offset; let metadata = hash_tile_meta(tile);
        var existing = atomicLoad(&hash_tiles[metadata]);
        // WGSL compare-exchange is weak; retry a spurious failure at the same slot.
        loop {
            if existing != 0u { break; }
            let claim = atomicCompareExchangeWeak(&hash_tiles[metadata], 0u, desc.tag);
            if claim.exchanged { atomicStore(&hash_tiles[metadata + 2u], p.frame.x); existing = desc.tag; break; }
            existing = claim.old_value;
        }
        if existing != desc.tag { continue; }
        let previous_frame = atomicExchange(&hash_tiles[metadata + 1u], p.frame.x);
        if previous_frame != p.frame.x {
            let lane = atomicAdd(&work[3], 1u); atomicStore(&hash_tiles[16u + lane], tile);
        }
        return hash_cell_index(tile, desc.offset, 0u);
    }
    return MISSING;
}
fn hash_tile_find(position: vec3<f32>, direction: vec3<f32>, distance: f32) -> u32 {
    let desc = hash_tile_descriptor(position, direction, distance);
    for (var offset = 0u; offset < p.hash_config.y; offset++) {
        let tile = desc.bucket * p.hash_config.y + offset;
        if atomicLoad(&hash_tiles[hash_tile_meta(tile)]) == desc.tag { return hash_cell_index(tile, desc.offset, 0u); }
        // Search past evicted holes; the original early exit can miss live tiles.
    }
    return MISSING;
}
fn hash_filtered(cell: u32, indirect: bool) -> vec4<f32> {
    let tile = cell / hash_mip_count(); let linear = cell % hash_mip_count();
    let offset = vec2(linear % p.hash_config.z, linear / p.hash_config.z);
    var value = hash_read(cell, indirect);
    let required = select(p.hash_sampling.x, p.hash_sampling.y, indirect);
    for (var mip = 1u; mip < 4u; mip++) {
        if p.hash_config.z >> mip == 0u || value.w >= required { break; }
        value = hash_read(hash_cell_index(tile, offset, mip), indirect);
    }
    return value;
}
fn hash_radiance(cell: u32) -> vec4<f32> {
    let direct = hash_filtered(cell, false); var indirect = vec4(0.0);
    if p.options.y != 0u { indirect = hash_filtered(cell, true); }
    return vec4(direct.rgb / max(direct.w, 1.0) + indirect.rgb / max(indirect.w, 1.0), f32(direct.w > 0.0));
}
fn hash_touch(cell: u32) {
    atomicStore(&hash_tiles[hash_tile_meta(cell / hash_mip_count()) + 1u], p.frame.x);
}
fn hash_accumulate(cell: u32, value: vec3<f32>, indirect: bool) {
    let tile = cell / hash_mip_count(); let linear = cell % hash_mip_count();
    let base = hash_scratch_base(tile, vec2(linear % p.hash_config.z, linear / p.hash_config.z), indirect);
    let quantized = vec3<u32>(round(safe_radiance(value) * 1000.0));
    atomicAdd(&hash_tiles[base], quantized.x); atomicAdd(&hash_tiles[base + 1u], quantized.y);
    atomicAdd(&hash_tiles[base + 2u], quantized.z); atomicAdd(&hash_tiles[base + 3u], 1u);
}
@compute @workgroup_size(64)
fn clear_hash_tiles(@builtin(global_invocation_id) gid: vec3<u32>) {
    let tile = gid.x + gid.y * 65536u; if tile >= p.hash_config.w { return; }
    let metadata = hash_tile_meta(tile);
    if p.frame.y != 0u || p.frame.x - atomicLoad(&hash_tiles[metadata + 1u]) >= p.options.x {
        atomicStore(&hash_tiles[metadata], 0u); atomicStore(&hash_tiles[metadata + 1u], 0u);
        atomicStore(&hash_tiles[metadata + 2u], 0u);
    }
}
@compute @workgroup_size(64)
fn initialize_hash_tiles(@builtin(workgroup_id) group: vec3<u32>, @builtin(local_invocation_index) lane: u32) {
    let index = group.x + group.y * 65535u; if index >= atomicLoad(&work[3]) { return; }
    let tile = atomicLoad(&hash_tiles[16u + index]); let size = p.hash_config.z;
    if lane >= size * size { return; }
    let offset = vec2(lane % size, lane / size);
    // Direct scratch is per-frame. Indirect scratch contains the previous
    // frame's UpdateMultibounceCells result and survives until UpdateTiles.
    for (var i = 0u; i < 4u; i++) { atomicStore(&hash_tiles[hash_scratch_base(tile, offset, false) + i], 0u); }
    if atomicLoad(&hash_tiles[hash_tile_meta(tile) + 2u]) == p.frame.x {
        for (var i = 0u; i < 4u; i++) { atomicStore(&hash_tiles[hash_scratch_base(tile, offset, true) + i], 0u); }
        let cell = hash_cell_index(tile, offset, 0u);
        hash_write(cell, false, vec4(0.0)); hash_write(cell, true, vec4(0.0));
    }
}
fn hash_temporal_update(cell: u32, tile: u32, offset: vec2<u32>, indirect: bool) -> vec2<u32> {
    let base = hash_scratch_base(tile, offset, indirect);
    let fresh = vec4(f32(atomicLoad(&hash_tiles[base])) / 1000.0, f32(atomicLoad(&hash_tiles[base + 1u])) / 1000.0,
        f32(atomicLoad(&hash_tiles[base + 2u])) / 1000.0, f32(atomicLoad(&hash_tiles[base + 3u])));
    let prior = hash_read(cell, indirect);
    let count = min(prior.w + fresh.w, select(p.hash_sampling.x, p.hash_sampling.y, indirect));
    var value = fresh / max(fresh.w, 1.0);
    if prior.w > 0.0 { value = mix(prior / max(prior.w, 1.0), value, 1.0 / max(count, 1.0)); }
    // Preserve GI-1.2's summed radiance/count representation for mip selection.
    let packed = hash_pack(value * count);
    let dst = hash_value_base(cell, indirect);
    atomicStore(&hash_tiles[dst], packed.x); atomicStore(&hash_tiles[dst + 1u], packed.y);
    for (var i = 0u; i < 4u; i++) { atomicStore(&hash_tiles[base + i], 0u); }
    return packed;
}
@compute @workgroup_size(64)
fn update_hash_tiles(@builtin(workgroup_id) group: vec3<u32>, @builtin(local_invocation_index) lane: u32) {
    let index = group.x + group.y * 65535u;
    if lane == 0u { tile_group_active = u32(index < atomicLoad(&work[3])); }
    let group_enabled = workgroupUniformLoad(&tile_group_active);
    // Uniform return before barriers; every remaining lane participates in all mips.
    if group_enabled == 0u { return; }
    let tile = atomicLoad(&hash_tiles[16u + index]); let size = p.hash_config.z;
    let offset = vec2(lane % size, lane / size);
    if lane < size * size {
        let cell = hash_cell_index(tile, offset, 0u);
        tile_direct[lane] = hash_temporal_update(cell, tile, offset, false);
        tile_indirect[lane] = hash_temporal_update(cell, tile, offset, true);
    }
    for (var mip = 1u; mip < 4u; mip++) {
        workgroupBarrier();
        let stride = 1u << (mip - 1u); let step = stride * 2u;
        if lane < size * size && step <= size && all(offset % vec2(step) == vec2(0u)) {
            let indices = vec4(lane, lane + stride, lane + stride * size, lane + stride * (size + 1u));
            var direct = vec4(0.0); var indirect = vec4(0.0);
            for (var i = 0u; i < 4u; i++) { direct += hash_unpack(tile_direct[indices[i]]); indirect += hash_unpack(tile_indirect[indices[i]]); }
            tile_direct[lane] = hash_pack(direct); tile_indirect[lane] = hash_pack(indirect);
            let cell = hash_cell_index(tile, offset, mip);
            hash_write(cell, false, direct); hash_write(cell, true, indirect);
        }
    }
}
@compute @workgroup_size(64)
fn populate_hash_cells(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; let count = p.screen.w * p.screen.w;
    if lane >= atomicLoad(&work[0]) * count { return; }
    let index = compact_probe(lane / count) * count + lane % count; let ray = rays[index];
    if ray.info.w == MISSING || ray.info.y == MISSING || all(ray.normal.xyz == vec3(0.0)) { return; }
    var direct = directional_direct_radiance(ray.position.xyz, ray.normal.xyz, -ray.direction.xyz, ray.info.y, hash32(index ^ p.frame.x), ray.info.x);
    let feedback = feedback_radiance(ray.position.xyz, ray.normal.xyz, ray.info.y);
    if feedback.w > 0.0 { direct = feedback.rgb; }
    rays[index].value = vec4(direct, ray.value.w);
    hash_accumulate(ray.info.w, direct, false);
}
fn bounce_albedo(position: vec3<f32>, triangle: u32) -> vec3<f32> {
    // GI-1.2 forces metallicity=0 and roughness=1 for the second-bounce BRDF.
    let base = geometry[triangle + 13u].rgb * material_texture(u32(geometry[triangle + 11u].x), triangle_uv(triangle, barycentrics(position, triangle), 0u)).rgb;
    let reflectance = geometry[triangle + 12u].y;
    return clamp(base * (1.0 - 0.16 * reflectance * reflectance), vec3(0.0), vec3(0.99));
}
fn directional_direct_radiance(position: vec3<f32>, n: vec3<f32>, view: vec3<f32>, triangle: u32, seed: u32, reservoir_slot: u32) -> vec3<f32> {
    let bary = barycentrics(position, triangle); let indices = geometry[triangle + 11u]; let properties = geometry[triangle + 12u];
    let base = geometry[triangle + 13u].rgb * material_texture(u32(indices.x), triangle_uv(triangle, bary, 0u)).rgb;
    // GenerateReservoirs/GenerateMultibounceReservoirs in GI-1.2 force a
    // matte dielectric BRDF before packing the material for PopulateCells.
    let metallic = 0.0; let roughness = 1.0;
    let f0 = mix(vec3(0.16 * properties.y * properties.y), base, metallic);
    let origin = offset_origin(position, triangle, n);
    var light = Lighting(vec3(0.0), vec3(0.0)); var used_reservoir = false;
    if p.quality.y != 0.0 && reservoir_slot != MISSING {
        let info = world_cache[reservoir_slot].reservoir_info;
        let reservoir = world_cache[reservoir_slot].reservoir;
        if info.x < p.scene_info.y && info.z > 0u && info.w == p.frame.x {
            // The RIS normalization is from the source location; evaluate the
            // selected light and its visibility at this actual visibility hit.
            used_reservoir = true;
            let selected = evaluate_light(position, n, info.x, reservoir.xy);
            let shadow_origin = offset_origin(position, triangle, selected.direction);
            let hit = trace_impl(shadow_origin, selected.direction, max(p.cache_config.z, selected.distance - p.cache_config.z * 2.0), true);
            if hit.triangle == MISSING {
                light.diffuse = selected.value * reservoir.z;
                if roughness >= 0.05 { light.specular = selected.value * (PI * reservoir.z) * specular_brdf(n, view, selected.direction, f0, roughness); }
            }
        }
    }
    if !used_reservoir { light = light_transport(position, n, origin, seed, false, f0, view, roughness); }
    var value = bounce_albedo(position, triangle) * (light.diffuse + sky_irradiance(n, origin, seed)) + light.specular;
    if any(p.sky.rgb > vec3(0.0)) {
        let surface_value = Surface(position, n, base, roughness, metallic, properties.y, 1.0, true);
        let sample_value = sample_specular_view(surface_value, seed + 47u, view);
        if any(sample_value.weight > vec3(0.0)) {
            let hit = trace_impl(origin, sample_value.direction, p.cache_config.w, true);
            if hit.triangle == MISSING { value += p.sky.rgb * sample_value.weight; }
        }
    }
    return safe_radiance(value);
}
@compute @workgroup_size(64)
fn trace_hash_bounces(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; let count = p.screen.w * p.screen.w;
    if lane >= atomicLoad(&work[0]) * count { return; }
    let index = compact_probe(lane / count) * count + lane % count;
    rays[index].bounce_info = vec4(MISSING);
    let ray = rays[index];
    if p.options.y == 0u || ray.info.w == MISSING || ray.info.y == MISSING || all(ray.normal.xyz == vec3(0.0)) { return; }
    var rng = hash32(index ^ hash32(p.frame.x + 179u));
    if random(&rng) <= p.hash_sampling.z { return; }
    let direction = cosine_ray(ray.normal.xyz, vec2(random(&rng), random(&rng)));
    let origin = offset_origin(ray.position.xyz, ray.info.y, direction);
    let hit = trace(origin, direction, p.cache_config.w); if hit.triangle == MISSING { return; }
    let n = hit_normal(hit, direction); if all(n == vec3(0.0)) { return; }
    let position = origin + direction * hit.distance;
    let cell = hash_tile_insert(position, direction, hit.distance);
    rays[index].bounce_position = vec4(position, hit.distance);
    rays[index].bounce_normal = vec4(n, 0.0); rays[index].bounce_direction = vec4(direction, 0.0);
    rays[index].bounce_info = vec4(cell, hit.triangle, 1u, cache_insert(position, n, hit.distance, hit.triangle, false));
}
@compute @workgroup_size(64)
fn populate_hash_bounces(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; let count = p.screen.w * p.screen.w;
    if lane >= atomicLoad(&work[0]) * count { return; }
    let ray = rays[compact_probe(lane / count) * count + lane % count];
    if ray.bounce_info.x == MISSING { return; }
    let value = directional_direct_radiance(ray.bounce_position.xyz, ray.bounce_normal.xyz, -ray.bounce_direction.xyz,
        ray.bounce_info.y, hash32(lane ^ hash32(p.frame.x + 181u)), ray.bounce_info.w);
    hash_accumulate(ray.bounce_info.x, value, false);
}
@compute @workgroup_size(64)
fn resolve_hash_bounces(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; let count = p.screen.w * p.screen.w;
    if lane >= atomicLoad(&work[0]) * count { return; }
    let ray = rays[compact_probe(lane / count) * count + lane % count];
    if ray.bounce_info.x == MISSING { return; }
    let direct = hash_filtered(ray.bounce_info.x, false);
    let incoming = direct.rgb / max(direct.w, 1.0);
    hash_accumulate(ray.info.w, bounce_albedo(ray.position.xyz, ray.info.y) * incoming, true);
}

