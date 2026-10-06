// Ported from AMD Capsaicin hash_grid_cache.hlsl and UpdateTiles in gi1.comp,
// commit 914b91596cd119eda85fbc1d3c7ee6ac391b1452. See THIRD_PARTY_NOTICES.md.
[[vk::binding(25, 0)]] RWStructuredBuffer<Atomic<uint>> hash_tiles;
groupshared uint2[64] tile_direct;
groupshared uint2[64] tile_indirect;
groupshared uint tile_group_active;
uint pcg_hash(uint value) {
    let state = value * 747796405u + 2891336453u;
    let word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
uint xx_hash(uint value) {
    var ret = value + 374761393u;
    ret = 668265263u * ((ret << 17u) | (ret >> 15u));
    ret = 2246822519u * (ret ^ (ret >> 15u));
    ret = 3266489917u * (ret ^ (ret >> 13u));
    return ret ^ (ret >> 16u);
}
uint hash_tile_meta(uint tile) { return 16u + p.hash_config.w + tile * 4u; }
uint hash_mip_count() {
    var count = 0u;
    for (var mip = 0u; mip < 4u; mip++) { let size = p.hash_config.z >> mip; count += size * size; }
    return count;
}
uint hash_cell_index(uint tile, uint2 offset, uint mip) {
    var first = 0u;
    for (var i = 0u; i < mip; i++) { let size = p.hash_config.z >> i; first += size * size; }
    let size = p.hash_config.z >> mip;
    return tile * hash_mip_count() + first + (offset.x >> mip) + (offset.y >> mip) * size;
}
uint hash_value_base(uint cell, bool indirect) {
    return 16u + p.hash_config.w * 5u + cell * 4u + select(indirect, 2u, 0u);
}
uint hash_scratch_base(uint tile, uint2 offset, bool indirect) {
    let base = 16u + p.hash_config.w * (5u + hash_mip_count() * 4u);
    return base + (tile * p.hash_config.z * p.hash_config.z + offset.x + offset.y * p.hash_config.z) * 8u + select(indirect, 4u, 0u);
}
uint2 hash_pack(float4 value) { return uint2(pack2x16float(value.xy), pack2x16float(value.zw)); }
float4 hash_unpack(uint2 value) { return float4(unpack2x16float(value.x), unpack2x16float(value.y)); }
float4 hash_read(uint cell, bool indirect) {
    let base = hash_value_base(cell, indirect);
    return hash_unpack(uint2(hash_tiles[base].load(), hash_tiles[base + 1u].load()));
}
void hash_write(uint cell, bool indirect, float4 value) {
    let base = hash_value_base(cell, indirect); let packed = hash_pack(value);
    hash_tiles[base].store(packed.x); hash_tiles[base + 1u].store(packed.y);
}
struct HashTileDesc {
    var bucket: uint;
    var tag: uint;
    var offset: uint2;
};
float hash_cell_size(float3 position) {
    let step = max(length(position - p.camera.xyz) * p.hash_sampling.w, p.cache_config.x);
    return 0.001 * exp2(floor(log2(1000.0 * step)));
}
HashTileDesc hash_tile_descriptor(float3 position, float3 direction, float distance) {
    let step = max(length(position - p.camera.xyz) * p.hash_sampling.w, p.cache_config.x);
    let level = floor(log2(1000.0 * step));
    let cell_size = 0.001 * exp2(level); let tile_size = cell_size * float(p.hash_config.z);
    let c = asuint(int3(floor(position / tile_size)));
    let d = uint3(floor(float3(0.5) + (direction * 0.5 + float3(0.5)) * 4.0));
    let l = uint(level); let t = uint(distance < tile_size);
    let bucket = pcg_hash(l + pcg_hash(c.x + pcg_hash(c.y + pcg_hash(c.z + pcg_hash(d.x + pcg_hash(d.y + pcg_hash(d.z + pcg_hash(t)))))))) % p.hash_config.x;
    let tag = max(1u, xx_hash(l + xx_hash(c.x + xx_hash(c.y + xx_hash(c.z + xx_hash(d.x + xx_hash(d.y + xx_hash(d.z + xx_hash(t)))))))));
    let e = uint3(clamp(floor(position / cell_size) - floor(position / tile_size) * float(p.hash_config.z), float3(0.0), float3(float(p.hash_config.z - 1u))));
    let a = abs(direction); var offset = e.xy;
    if (a.x == max(max(a.x, a.y), a.z)) { offset = e.yz; }
    else if (a.y == max(max(a.x, a.y), a.z)) { offset = e.xz; }
    return HashTileDesc(bucket, tag, offset);
}
uint hash_tile_insert(float3 position, float3 direction, float distance) {
    let desc = hash_tile_descriptor(position, direction, distance);
    for (var offset = 0u; offset < p.hash_config.y; offset++) {
        let tile = desc.bucket * p.hash_config.y + offset; let metadata = hash_tile_meta(tile);
        var existing = hash_tiles[metadata].load();
        // Slang's native compare-exchange is strong and needs no retry loop.
        if (existing == 0u) {
            let claim = hash_tiles[metadata].compareExchange(0u, desc.tag);
            if (claim == 0u) {
                hash_tiles[metadata + 2u].store(p.frame.x); existing = desc.tag;
            }
            else { existing = claim; }
        }
        if (existing != desc.tag) { continue; }
        hash_tiles[metadata + 1u].store(p.frame.x);
        // A frame-local claim also handles new tiles at frame zero/wraparound.
        if (hash_tiles[metadata + 3u].exchange(1u) == 0u) {
            let lane = work[3].add(1u); hash_tiles[16u + lane].store(tile);
        }
        return hash_cell_index(tile, desc.offset, 0u);
    }
    return MISSING;
}
uint hash_tile_find(float3 position, float3 direction, float distance) {
    let desc = hash_tile_descriptor(position, direction, distance);
    for (var offset = 0u; offset < p.hash_config.y; offset++) {
        let tile = desc.bucket * p.hash_config.y + offset;
        let tag=hash_tiles[hash_tile_meta(tile)].load();
        if(tag==desc.tag) { return hash_cell_index(tile, desc.offset, 0u); }
        if(source_probe_projection() && tag==0u) {return MISSING;}
        // Compensated mode searches past holes left by eviction.
    }
    return MISSING;
}
float4 hash_filtered(uint cell, bool indirect) {
    let tile = cell / hash_mip_count(); let linear = cell % hash_mip_count();
    let offset = uint2(linear % p.hash_config.z, linear / p.hash_config.z);
    var value = hash_read(cell, indirect);
    let required = select(indirect, p.hash_sampling.y, p.hash_sampling.x);
    for (var mip = 1u; mip < 4u; mip++) {
        if (p.hash_config.z >> mip == 0u || value.w >= required) { break; }
        value = hash_read(hash_cell_index(tile, offset, mip), indirect);
    }
    return value;
}
float4 hash_radiance(uint cell) {
    let direct = hash_filtered(cell, false); var indirect = float4(0.0);
    if (p.options.y != 0u) { indirect = hash_filtered(cell, true); }
    return float4(direct.rgb / max(direct.w, 1.0) + indirect.rgb / max(indirect.w, 1.0), float(direct.w > 0.0));
}
void hash_touch(uint cell) {
    hash_tiles[hash_tile_meta(cell / hash_mip_count()) + 1u].store(p.frame.x);
}
float3 directional_cached_radiance(float3 position,float3 direction,float distance,out bool found) {
    let cell=hash_tile_find(position,direction,distance);found=cell!=MISSING;
    if(!found) {return float3(0.0);}
    hash_touch(cell);let value=hash_radiance(cell);
    return value.rgb;
}
void hash_accumulate(uint cell, float3 value, bool indirect) {
    let tile = cell / hash_mip_count(); let linear = cell % hash_mip_count();
    let base = hash_scratch_base(tile, uint2(linear % p.hash_config.z, linear / p.hash_config.z), indirect);
    let quantized = uint3(round(safe_radiance(value) * 1000.0));
    if(any(quantized!=uint3(0u))) {
        hash_tiles[base].add(quantized.x); hash_tiles[base + 1u].add(quantized.y);
        hash_tiles[base + 2u].add(quantized.z);
    }
    hash_tiles[base + 3u].add(1u);
}
[shader("compute")][numthreads(64,1,1)]
void clear_hash_tiles(uint3 gid : SV_DispatchThreadID) {
    let tile = gid.x + gid.y * 65536u; if (tile >= p.hash_config.w) { return; }
    let metadata = hash_tile_meta(tile);
    hash_tiles[metadata+3u].store(0u);
    if (p.frame.y != 0u || p.frame.x - hash_tiles[metadata + 1u].load() >= p.options.x) {
        hash_tiles[metadata].store(0u); hash_tiles[metadata + 1u].store(0u);
        hash_tiles[metadata + 2u].store(0u);
    }
}
[shader("compute")][numthreads(64,1,1)]
void initialize_hash_tiles(uint3 group : SV_GroupID, uint lane : SV_GroupIndex) {
    let index = group.x + group.y * 65535u; if (index >= work[3].load()) { return; }
    let tile = hash_tiles[16u + index].load(); let size = p.hash_config.z;
    if (lane >= size * size) { return; }
    let offset = uint2(lane % size, lane / size);
    // Direct scratch is per-frame. Indirect scratch contains the previous
    // frame's UpdateMultibounceCells result and survives until UpdateTiles.
    for (var i = 0u; i < 4u; i++) { hash_tiles[hash_scratch_base(tile, offset, false) + i].store(0u); }
    if (hash_tiles[hash_tile_meta(tile) + 2u].load() == p.frame.x) {
        for (var i = 0u; i < 4u; i++) { hash_tiles[hash_scratch_base(tile, offset, true) + i].store(0u); }
        let cell = hash_cell_index(tile, offset, 0u);
        hash_write(cell, false, float4(0.0)); hash_write(cell, true, float4(0.0));
    }
}
uint2 hash_temporal_update(uint cell, uint tile, uint2 offset, bool indirect) {
    let base = hash_scratch_base(tile, offset, indirect);
    let fresh = float4(float(hash_tiles[base].load()) / 1000.0, float(hash_tiles[base + 1u].load()) / 1000.0,
        float(hash_tiles[base + 2u].load()) / 1000.0, float(hash_tiles[base + 3u].load()));
    let prior = hash_read(cell, indirect);
    let count = min(prior.w + fresh.w, select(indirect, p.hash_sampling.y, p.hash_sampling.x));
    var value = fresh / max(fresh.w, 1.0);
    if (prior.w > 0.0) { value = lerp(prior / max(prior.w, 1.0), value, 1.0 / max(count, 1.0)); }
    // Preserve GI-1.2's summed radiance/count representation for mip selection.
    let packed = hash_pack(value * count);
    let dst = hash_value_base(cell, indirect);
    hash_tiles[dst].store(packed.x); hash_tiles[dst + 1u].store(packed.y);
    for (var i = 0u; i < 4u; i++) { hash_tiles[base + i].store(0u); }
    return packed;
}
[shader("compute")][numthreads(64,1,1)]
void update_hash_tiles(uint3 group : SV_GroupID, uint lane : SV_GroupIndex) {
    let index = group.x + group.y * 65535u;
    if (lane == 0u) { tile_group_active = uint(index < work[3].load()); }
    GroupMemoryBarrierWithGroupSync(); let group_enabled = tile_group_active;
    // Uniform return before barriers; every remaining lane participates in all mips.
    if (group_enabled == 0u) { return; }
    let tile = hash_tiles[16u + index].load(); let size = p.hash_config.z;
    let offset = uint2(lane % size, lane / size);
    if (lane < size * size) {
        let cell = hash_cell_index(tile, offset, 0u);
        tile_direct[lane] = hash_temporal_update(cell, tile, offset, false);
        tile_indirect[lane] = hash_temporal_update(cell, tile, offset, true);
    }
    for (var mip = 1u; mip < 4u; mip++) {
        GroupMemoryBarrierWithGroupSync();
        let stride = 1u << (mip - 1u); let step = stride * 2u;
        if (lane < size * size && step <= size && all(offset % uint2(step) == uint2(0u))) {
            let indices = uint4(lane, lane + stride, lane + stride * size, lane + stride * (size + 1u));
            var direct = float4(0.0); var indirect = float4(0.0);
            for (var i = 0u; i < 4u; i++) { direct += hash_unpack(tile_direct[indices[i]]); indirect += hash_unpack(tile_indirect[indices[i]]); }
            tile_direct[lane] = hash_pack(direct); tile_indirect[lane] = hash_pack(indirect);
            let cell = hash_cell_index(tile, offset, mip);
            hash_write(cell, false, direct); hash_write(cell, true, indirect);
        }
    }
}
[shader("compute")][numthreads(64,1,1)]
void populate_hash_cells(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u;
    if (lane >= transport_ray_count()) { return; }
    let index = transport_ray_index(lane); let ray = rays[index];
    if (ray.info.w == MISSING || ray.info.y == MISSING || all(ray.normal.xyz == float3(0.0))) { return; }
    var has_reservoir=false;
    if(ray.info.x==EMISSIVE_PROBE_RAY) {return;}
    let feedback = feedback_radiance(ray.position.xyz, ray.normal.xyz, ray.info.y);
    if(source_probe_projection()&&feedback.w>0.0) {
        rays[index].value=float4(feedback.rgb,ray.value.w);
        rays[index].normal.w=1.0;
        hash_accumulate(ray.info.w,feedback.rgb,false);
        return;
    }
    var sample=index;if(source_probe_projection()) {sample=source_lighting_id(index,false);}
    var direct = directional_direct_radiance(ray.position.xyz, ray.normal.xyz, -ray.direction.xyz, ray.info.y, hash32(index ^ p.frame.x), sample, has_reservoir);
    if (feedback.w > 0.0) { direct = feedback.rgb; }
    rays[index].value = float4(direct, ray.value.w);
    hash_accumulate(ray.info.w, direct, false);
}
float3 bounce_albedo(float3 position, uint triangle) {
    // GI-1.2 forces metallicity=0 and roughness=1 for the second-bounce BRDF.
    let base = geometry[triangle + 13u].rgb * material_texture(uint(geometry[triangle + 11u].x), triangle_uv(triangle, barycentrics(position, triangle), 0u)).rgb;
    let reflectance = geometry[triangle + 12u].y;
    return clamp(base * (1.0 - 0.16 * reflectance * reflectance), float3(0.0), float3(0.99));
}
float4 multibounce_brdf(float3 base, float reflectance, float3 normal, float3 view, float3 direction) {
    let f0 = material_f0(base,0.0,reflectance,p.restir.w);
    let half_vector = normalize(view + direction); let cosine = max(dot(normal, direction), 0.0);
    let value = cosine * (base * diffuse_compensation(f0, dot(half_vector, view)) / PI
        + specular_brdf(normal, view, direction, f0, 1.0));
    return float4(value, cosine / PI);
}
float3 multibounce_radiance(float3 incoming, float4 brdf, float discard_probability) {
    if (brdf.w <= 0.0 || discard_probability >= 1.0) { return float3(0.0); }
    return incoming * brdf.rgb / (brdf.w * (1.0 - discard_probability));
}
float3 directional_direct_radiance(float3 position, float3 n, float3 view, uint triangle, uint seed, uint reservoir_slot, out bool has_reservoir) {
    has_reservoir=false;
    if(source_probe_projection() && p.quality.y!=0.0 && reservoir_slot==MISSING) {return float3(0.0);}
    let bary = barycentrics(position, triangle); let indices = geometry[triangle + 11u]; let properties = geometry[triangle + 12u];
    let base = geometry[triangle + 13u].rgb * material_texture(uint(indices.x), triangle_uv(triangle, bary, 0u)).rgb;
    // GenerateReservoirs/GenerateMultibounceReservoirs in GI-1.2 force a
    // matte dielectric BRDF before packing the material for PopulateCells.
    let metallic = 0.0; let roughness = 1.0;
    let f0 = material_f0(base,metallic,properties.y,p.restir.w);
    let origin = offset_origin(position, triangle, n);
    var light = Lighting(float3(0.0), float3(0.0)); var used_reservoir = false;
    if (grid_light_count() > 0u) {
        var info = uint4(MISSING,0u,0u,p.frame.x); var reservoir = float4(0.0);
        if (p.quality.y != 0.0 && reservoir_slot != MISSING) {
            let stored=restir_load_reservoir(reservoir_slot,false);
            info=uint4(stored.light,0u,uint(stored.count),p.frame.x);
            reservoir=float4(stored.uv,stored.weight,0.0);
        } else {
            var rng = hash32(seed + 127u);
            if(source_probe_projection()) {rng=source_random(reservoir_slot,p.frame.x);}
            let fresh = grid_fresh_reservoir(position,n,view,triangle,rng);
            info = uint4(fresh.light,0u,fresh.count,p.frame.x);
            if (fresh.target_density > 0.0 && fresh.count > 0u) {
                reservoir = float4(fresh.uv,fresh.weight_sum/(float(fresh.count)*fresh.target_density),fresh.target_density);
            }
        }
        if (info.x < grid_light_count() && info.z > 0u && info.w == p.frame.x) {
            // The RIS normalization is from the source location; evaluate the
            // selected light and its visibility at this actual visibility hit.
            used_reservoir = true;
            has_reservoir=true;
            let selected = evaluate_light_cone(position,n,info.x,reservoir.xy,4.0*PI/(8.0*12000.0));
            let hit = trace_light_shadow(position,n,triangle,selected);
            if (hit.triangle == MISSING) {
                let half_vector=normalize(view+selected.direction);
                light.diffuse = selected.value * reservoir.z * diffuse_compensation(f0,dot(half_vector,view));
                if (roughness >= 0.05) { light.specular = selected.value * (PI * reservoir.z) * specular_brdf(n, view, selected.direction, f0, roughness); }
            } else if(p.quality.y!=0.0 && reservoir_slot!=MISSING) {
                // PopulateCellsHandleHit preserves M but zeros W before history.
                var stored=restir_load_reservoir(reservoir_slot,false);stored.weight=0.0;
                restir_store_reservoir(reservoir_slot,stored);
            }
        }
    }
    if (!used_reservoir && !source_probe_projection()) { light = light_transport(position, n, origin, seed, false, f0, view, roughness); }
    var value = base * light.diffuse + light.specular;
    if(!grid_environment_enabled()) {value+=bounce_albedo(position, triangle) * sky_irradiance(n, origin, seed);}
    if (has_environment() && !grid_environment_enabled()) {
        let surface_value = Surface(position, n, base, roughness, metallic, properties.y, 1.0, true,n);
        let sample_value = sample_specular_view(surface_value, seed + 47u, view);
        if (any(sample_value.weight > float3(0.0))) {
            let hit = trace_impl(origin, sample_value.direction, p.cache_config.w, true);
            if (hit.triangle == MISSING) { value += environment_radiance(sample_value.direction) * sample_value.weight; }
        }
    }
    return safe_radiance(value);
}
[shader("compute")][numthreads(64,1,1)]
void trace_hash_bounces(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u;
    if (lane >= transport_ray_count()) { return; }
    let source = source_probe_projection();
    if(source && lane>=work[7].load()) {return;}
    var index=transport_ray_index(lane);
    if(source) {index=work[source_visibility_list(false)+lane].load();}
    rays[index].bounce_info = uint4(MISSING);
    let ray = rays[index];
    if (p.options.y == 0u || ray.info.w == MISSING || ray.info.y == MISSING || all(ray.normal.xyz == float3(0.0))) { return; }
    var rng = hash32(index ^ hash32(p.frame.x + 179u));
    if(source) {rng=source_random(lane,p.frame.x);}
    var discard_sample: float;
    if (source) { discard_sample = grid_random(rng); } else { discard_sample = random(rng); }
    if (discard_sample <= p.hash_sampling.z) { return; }
    var direction: float3;
    if (source) {
        let uv = float2(grid_random(rng), grid_random(rng));
        let radius = sqrt(uv.x); let phi = 2.0 * PI * uv.y;
        let rotation = ggx_rotation_to_z(ray.normal.xyz);
        direction = normalize(ggx_rotate(float4(-rotation.xyz, rotation.w),
            float3(radius * cos(phi), radius * sin(phi), sqrt(1.0 - uv.x))));
    } else { direction = cosine_ray(ray.normal.xyz, float2(random(rng), random(rng))); }
    let origin = select(source,offset_ray_position(ray.position.xyz,ray.normal.xyz),offset_origin(ray.position.xyz,ray.info.y,direction));
    let hit = trace(origin, direction, gi_max_distance()); if (hit.triangle == MISSING) { return; }
    let n = hit_normal(hit, direction); if (all(n == float3(0.0))) { return; }
    let position = origin + direction * hit.distance;
    request_light_location(position);
    let cell = hash_tile_insert(position, direction, hit.distance);
    rays[index].bounce_position = float4(position, hit.distance);
    rays[index].bounce_normal = float4(n, float(distance(ray.position.xyz,position)<hash_cell_size(position)));
    rays[index].bounce_direction = float4(direction, 0.0);
    rays[index].bounce_info = uint4(cell, hit.triangle, 1u, cache_insert(position, n, hit.distance, hit.triangle, false));
    if (source) {
        let triangle = ray.info.y; let bary = barycentrics(ray.position.xyz, triangle);
        let base = geometry[triangle + 13u].rgb * material_texture(uint(geometry[triangle + 11u].x), triangle_uv(triangle, bary, 0u)).rgb;
        let brdf = multibounce_brdf(base, geometry[triangle + 12u].y, ray.normal.xyz, -ray.direction.xyz, direction);
        rays[index].bounce_info.z = pack2x16float(brdf.xy);
        rays[index].bounce_info.w = pack2x16float(brdf.zw);
    }
}
[shader("compute")][numthreads(64,1,1)]
void populate_hash_bounces(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u;
    if (lane >= transport_ray_count()) { return; }
    let index=transport_ray_index(lane);let ray = rays[index];
    if (ray.bounce_info.x == MISSING) { return; }
    var has_reservoir=false;
    var sample=index+restir_ray_capacity();if(source_probe_projection()) {sample=source_lighting_id(index,true);}
    let value = directional_direct_radiance(ray.bounce_position.xyz, ray.bounce_normal.xyz, -ray.bounce_direction.xyz,
        ray.bounce_info.y, hash32(lane ^ hash32(p.frame.x + 181u)), sample, has_reservoir);
    if(source_probe_projection() && !has_reservoir) {rays[index].bounce_normal.w=0.0;}
    hash_accumulate(ray.bounce_info.x, value, false);
}
[shader("compute")][numthreads(64,1,1)]
void resolve_hash_bounces(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u;
    if (lane >= transport_ray_count()) { return; }
    let index=transport_ray_index(lane);let ray = rays[index];
    if (ray.bounce_info.x == MISSING) { return; }
    let direct = hash_filtered(ray.bounce_info.x, false);
    let incoming = direct.rgb / max(direct.w, 1.0);
    var value: float3;
    if(source_probe_projection()) {
        value=multibounce_radiance(incoming, float4(unpack2x16float(ray.bounce_info.z), unpack2x16float(ray.bounce_info.w)), p.hash_sampling.z);
        if(ray.bounce_normal.w!=0.0) {rays[index].probe_bounce=float4(value,1.0);}
    } else {
        value=multibounce_radiance(incoming,float4(bounce_albedo(ray.position.xyz,ray.info.y),1.0),
            0.0);
    }
    hash_accumulate(ray.info.w, value, true);
}

