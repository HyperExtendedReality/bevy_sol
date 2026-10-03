// GI-1.2-inspired Rust/WGSL adaptation. Reference: AMD Capsaicin commit
// 914b91596cd119eda85fbc1d3c7ee6ac391b1452, gi1.comp and hash_grid_cache.hlsl.
// See THIRD_PARTY_NOTICES.md. Shader is standalone for Naga validation.
struct Params {
    world_from_clip: mat4x4<f32>, previous_clip_from_world: mat4x4<f32>,
    camera: vec4<f32>, camera_direction: vec4<f32>, sky: vec4<f32>, viewport: vec4<u32>,
    screen: vec4<u32>, frame: vec4<u32>, scene_info: vec4<u32>,
    cache_config: vec4<f32>, options: vec4<u32>, quality: vec4<f32>,
    hash_config: vec4<u32>, hash_sampling: vec4<f32>,
    reflection: vec4<u32>, reflection_filter: vec4<f32>, reflection_thresholds: vec4<f32>,
}
struct Probe {
    position: vec4<f32>, normal: vec4<f32>, irradiance: vec4<f32>, info: vec4<u32>,
    samples: array<vec4<f32>, PROBE_DIRECTIONS>,
    filtered_irradiance: vec4<f32>,
    sh: array<vec4<f32>, 9>, filtered_sh: array<vec4<f32>, 9>,
}
struct CacheEntry {
    tag: atomic<u32>, touched: atomic<u32>, primary_frame: atomic<u32>, reserved: atomic<u32>,
    key: vec4<i32>, position: vec4<f32>, normal: vec4<f32>,
    direct: vec4<f32>, indirect: vec4<f32>, previous_direct: vec4<f32>, previous_indirect: vec4<f32>,
    bounce_position: vec4<f32>, bounce_normal: vec4<f32>, bounce_info: vec4<u32>,
    pending_indirect: vec4<f32>,
    reservoir: vec4<f32>, reservoir_info: vec4<u32>,
    previous_reservoir: vec4<f32>, previous_reservoir_info: vec4<u32>,
}
struct RaySample {
    position: vec4<f32>, normal: vec4<f32>, direction: vec4<f32>,
    info: vec4<u32>, value: vec4<f32>,
    bounce_position: vec4<f32>, bounce_normal: vec4<f32>,
    bounce_direction: vec4<f32>, bounce_info: vec4<u32>,
}
@group(0) @binding(0) var<uniform> p: Params;
@group(0) @binding(1) var<storage, read> geometry: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> lights: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read> previous_probes: array<Probe>;
@group(0) @binding(4) var<storage, read_write> probes: array<Probe>;
@group(0) @binding(5) var<storage, read_write> world_cache: array<CacheEntry>;
@group(0) @binding(6) var<storage, read_write> rays: array<RaySample>;
@group(0) @binding(7) var depth: texture_depth_2d;
@group(0) @binding(8) var gbuffer: texture_2d<u32>;
@group(0) @binding(9) var previous_diffuse: texture_2d<f32>;
@group(0) @binding(10) var previous_specular: texture_2d<f32>;
@group(0) @binding(11) var previous_position: texture_2d<f32>;
@group(0) @binding(12) var previous_normal: texture_2d<f32>;
@group(0) @binding(13) var raw_diffuse: texture_2d<f32>;
@group(0) @binding(14) var raw_specular: texture_2d<f32>;
@group(0) @binding(15) var output_diffuse: texture_storage_2d<rgba16float, write>;
@group(0) @binding(16) var output_specular: texture_storage_2d<rgba16float, write>;
@group(0) @binding(17) var output_position: texture_storage_2d<rgba32float, write>;
@group(0) @binding(18) var output_normal: texture_storage_2d<rgba16float, write>;
@group(0) @binding(19) var moments: texture_2d<f32>;
@group(0) @binding(20) var<storage, read_write> work: array<atomic<u32>>;
@group(0) @binding(24) var previous_combined: texture_2d<f32>;
// Rust specializes this constant to match the configured allocation exactly.
const PROBE_DIRECTIONS: u32 = 64u;
const WORK_HEADER: u32 = 24u;
const TRIANGLE_WORDS: u32 = 16u;
const PI: f32 = 3.141592653589793;
const MISSING: u32 = 0xffffffffu;
const CACHE_SEARCH: u32 = 16u;
fn hash32(x: u32) -> u32 {
    var v = x; v ^= v >> 16u; v *= 0x7feb352du; v ^= v >> 15u; v *= 0x846ca68bu; return v ^ (v >> 16u);
}
fn random(state: ptr<function, u32>) -> f32 {
    *state = hash32(*state + 0x9e3779b9u); return f32(*state >> 8u) / 16777216.0;
}
fn luminance(v: vec3<f32>) -> f32 { return dot(v, vec3(0.2126, 0.7152, 0.0722)); }
fn safe_radiance(v: vec3<f32>) -> vec3<f32> {
    // Reject NaNs and infinities before temporal accumulation / half-float output.
    return select(vec3(0.0), clamp(v, vec3(0.0), vec3(60000.0)), all(v == v) && all(abs(v) < vec3(1e30)));
}
fn tangent_frame(n: vec3<f32>) -> mat3x3<f32> {
    let up = select(vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0), abs(n.y) > 0.99);
    let t = normalize(cross(up, n)); return mat3x3(t, cross(n, t), n);
}
fn cosine_ray(n: vec3<f32>, uv: vec2<f32>) -> vec3<f32> {
    let radius = sqrt(uv.x); let phi = 2.0 * PI * uv.y;
    return tangent_frame(n) * vec3(radius * cos(phi), radius * sin(phi), sqrt(1.0 - uv.x));
}
fn bin_uv(bin: u32, jitter: vec2<f32>) -> vec2<f32> {
    let a = p.screen.w; return (vec2<f32>(f32(bin % a), f32(bin / a)) + jitter) / f32(a);
}
fn hemisphere_ray(n: vec3<f32>, uv: vec2<f32>) -> vec3<f32> {
    let z = 1.0 - uv.x; let radius = sqrt(max(1.0 - z * z, 0.0)); let phi = 2.0 * PI * uv.y;
    return tangent_frame(n) * vec3(radius * cos(phi), radius * sin(phi), z);
}
fn direction_bin(n: vec3<f32>, d: vec3<f32>) -> u32 {
    let local = transpose(tangent_frame(n)) * d;
    let phi = fract(atan2(local.y, local.x) / (2.0 * PI) + 1.0);
    let uv = vec2(clamp(1.0 - local.z, 0.0, 0.99999), phi);
    let cell = vec2<u32>(uv * f32(p.screen.w)); return cell.x + cell.y * p.screen.w;
}
fn sh_basis(d: vec3<f32>) -> array<f32, 9> {
    return array<f32, 9>(0.2820947918, -0.4886025119 * d.y, 0.4886025119 * d.z,
        -0.4886025119 * d.x, 1.0925484306 * d.x * d.y, -1.0925484306 * d.y * d.z,
        0.3153915653 * (3.0 * d.z * d.z - 1.0), -1.0925484306 * d.x * d.z,
        0.5462742153 * (d.x * d.x - d.y * d.y));
}
fn probe_irradiance(index: u32, n: vec3<f32>) -> vec3<f32> {
    let basis = sh_basis(n); var color = vec3(0.0);
    for (var j = 0u; j < 9u; j++) {
        let convolution = select(select(0.25, 2.0 / 3.0, j < 4u), 1.0, j == 0u);
        color += probes[index].filtered_sh[j].rgb * basis[j] * convolution;
    }
    return max(color, vec3(0.0)); // cosine-convolved SH, divided by pi
}
fn compact_probe(lane: u32) -> u32 { return atomicLoad(&work[WORK_HEADER + lane]); }
fn compact_primary(lane: u32) -> u32 { return atomicLoad(&work[WORK_HEADER + p.scene_info.z + lane]); }
fn compact_cell(lane: u32) -> u32 { return atomicLoad(&work[WORK_HEADER + p.scene_info.z + p.frame.z + lane]); }
@compute @workgroup_size(1)
fn reset_work() {
    for (var i = 0u; i < WORK_HEADER; i++) { atomicStore(&work[i], 0u); }
}
@compute @workgroup_size(1)
fn prepare_dispatch() {
    let counts = array<u32, 4>(atomicLoad(&work[0]), atomicLoad(&work[0]) * p.screen.w * p.screen.w,
        atomicLoad(&work[1]), atomicLoad(&work[2]));
    for (var i = 0u; i < 4u; i++) {
        atomicStore(&work[4u + i * 4u], (min(counts[i], 65536u) + 63u) / 64u);
        atomicStore(&work[5u + i * 4u], (counts[i] + 65535u) / 65536u);
        atomicStore(&work[6u + i * 4u], 1u);
    }
    let tiles = atomicLoad(&work[3]);
    atomicStore(&work[20u], min(tiles, 65535u));
    atomicStore(&work[21u], (tiles + 65534u) / 65535u);
    atomicStore(&work[22u], 1u);
}
@compute @workgroup_size(64)
fn compact_primary_cells(@builtin(global_invocation_id) gid: vec3<u32>) {
    let slot = gid.x + gid.y * 65536u;
    if slot >= p.frame.z || atomicLoad(&world_cache[slot].tag) == 0u || atomicLoad(&world_cache[slot].primary_frame) != p.frame.x { return; }
    let lane = atomicAdd(&work[1], 1u);
    atomicStore(&work[WORK_HEADER + p.scene_info.z + lane], slot);
}
@compute @workgroup_size(64)
fn compact_touched_cells(@builtin(global_invocation_id) gid: vec3<u32>) {
    let slot = gid.x + gid.y * 65536u;
    if slot >= p.frame.z || atomicLoad(&world_cache[slot].tag) == 0u || atomicLoad(&world_cache[slot].touched) != p.frame.x { return; }
    let lane = atomicAdd(&work[2], 1u);
    atomicStore(&work[WORK_HEADER + p.scene_info.z + p.frame.z + lane], slot);
}
struct Hit { distance: f32, triangle: u32, uv: vec2<f32> }
fn material_texture(index: u32, uv: vec2<f32>) -> vec4<f32> { return vec4(1.0); }
fn triangle_uv(t: u32, bary: vec2<f32>, channel: u32) -> vec2<f32> {
    let second = ((u32(geometry[t + 12u].w) >> channel) & 1u) != 0u;
    let a = geometry[t + 8u]; let b = geometry[t + 9u]; let c = geometry[t + 10u];
    let uv = select(a.xy, a.zw, second) * (1.0 - bary.x - bary.y) + select(b.xy, b.zw, second) * bary.x + select(c.xy, c.zw, second) * bary.y;
    let transform = geometry[t + 14u];
    return transform.xy * uv.x + transform.zw * uv.y + geometry[t + 15u].xy;
}
fn barycentrics(position: vec3<f32>, t: u32) -> vec2<f32> {
    let a = geometry[t].xyz; let e1 = geometry[t + 1u].xyz - a; let e2 = geometry[t + 2u].xyz - a;
    let delta = position - a; let d00 = dot(e1, e1); let d01 = dot(e1, e2); let d11 = dot(e2, e2);
    let inverse = 1.0 / max(d00 * d11 - d01 * d01, 1e-20);
    return vec2((d11 * dot(delta, e1) - d01 * dot(delta, e2)) * inverse, (d00 * dot(delta, e2) - d01 * dot(delta, e1)) * inverse);
}
fn material_albedo(position: vec3<f32>, t: u32) -> vec3<f32> {
    let bary = barycentrics(position, t); let indices = geometry[t + 11u]; let properties = geometry[t + 12u];
    let base = geometry[t + 13u].rgb * material_texture(u32(indices.x), triangle_uv(t, bary, 0u)).rgb;
    let metallic = properties.x * material_texture(u32(indices.w), triangle_uv(t, bary, 3u)).b;
    return clamp(base * (1.0 - metallic) * (1.0 - 0.16 * properties.y * properties.y), vec3(0.0), vec3(0.99));
}
fn material_emission(position: vec3<f32>, t: u32) -> vec3<f32> {
    return geometry[t + 7u].rgb * material_texture(u32(geometry[t + 11u].y), triangle_uv(t, barycentrics(position, t), 1u)).rgb;
}
fn material_visible(t: u32, bary: vec2<f32>) -> bool {
    let cutoff = geometry[t + 12u].z;
    return cutoff < 0.0 || geometry[t + 13u].a * material_texture(u32(geometry[t + 11u].x), triangle_uv(t, bary, 0u)).a >= cutoff;
}
fn hit_box(o: vec3<f32>, d: vec3<f32>, lo: vec3<f32>, hi: vec3<f32>, near: f32, far: f32) -> bool {
    var a = near; var b = far;
    for (var axis = 0u; axis < 3u; axis++) {
        if abs(d[axis]) < 1e-8 { if o[axis] < lo[axis] || o[axis] > hi[axis] { return false; } }
        else { let x = (lo[axis] - o[axis]) / d[axis]; let y = (hi[axis] - o[axis]) / d[axis]; a = max(a, min(x, y)); b = min(b, max(x, y)); }
    }
    return a <= b;
}
fn trace_impl(o: vec3<f32>, d: vec3<f32>, far: f32, any_hit: bool) -> Hit {
    var hit = Hit(far, MISSING, vec2(0.0)); var node = 0u;
    loop {
        if node >= p.scene_info.x { break; }
        let lo = geometry[node * 2u]; let hi = geometry[node * 2u + 1u];
        if !hit_box(o, d, lo.xyz, hi.xyz, p.cache_config.z, hit.distance) { node = u32(hi.w); continue; }
        if lo.w >= 0.0 {
            let index = u32(lo.w); let a = geometry[index].xyz;
            let e1 = geometry[index + 1u].xyz - a; let e2 = geometry[index + 2u].xyz - a;
            let h = cross(d, e2); let det = dot(e1, h);
            if abs(det) > 1e-8 {
                let inv = 1.0 / det; let s = o - a; let u = dot(s, h) * inv;
                let q = cross(s, e1); let v = dot(d, q) * inv; let t = dot(e2, q) * inv;
                if u >= 0.0 && v >= 0.0 && u + v <= 1.0 && t >= p.cache_config.z && t < hit.distance && material_visible(index, vec2(u, v)) {
                    hit = Hit(t, index, vec2(u, v)); if any_hit { return hit; }
                }
            }
        }
        node++;
    }
    return hit;
}
fn trace(o: vec3<f32>, d: vec3<f32>, far: f32) -> Hit { return trace_impl(o, d, far, false); }
fn geometric_normal(t: u32) -> vec3<f32> {
    return normalize(cross(geometry[t + 1u].xyz - geometry[t].xyz, geometry[t + 2u].xyz - geometry[t].xyz));
}
fn hit_normal(h: Hit, ray: vec3<f32>) -> vec3<f32> {
    let t = h.triangle; var gn = geometric_normal(t);
    let back = dot(gn, -ray) < 0.0;
    if back && geometry[t + 6u].w == 0.0 { return vec3(0.0); }
    var n = normalize(geometry[t + 3u].xyz * (1.0 - h.uv.x - h.uv.y)
        + geometry[t + 4u].xyz * h.uv.x + geometry[t + 5u].xyz * h.uv.y);
    if dot(n, gn) < 0.0 { n = -n; }
    let normal_index = u32(geometry[t + 11u].z);
    if normal_index != 0u {
        let uv0 = triangle_uv(t, vec2(0.0), 2u); let uv1 = triangle_uv(t, vec2(1.0, 0.0), 2u); let uv2 = triangle_uv(t, vec2(0.0, 1.0), 2u);
        let du = uv1 - uv0; let dv = uv2 - uv0; let determinant = du.x * dv.y - du.y * dv.x;
        if abs(determinant) > 1e-10 {
            let e1 = geometry[t + 1u].xyz - geometry[t].xyz; let e2 = geometry[t + 2u].xyz - geometry[t].xyz;
            let tangent = (e1 * dv.y - e2 * du.y) / determinant;
            let bitangent = (e2 * du.x - e1 * dv.x) / determinant;
            let orthogonal = tangent - n * dot(n, tangent);
            if length(orthogonal) > 1e-8 {
                let tbn_t = normalize(orthogonal); let tbn_b = cross(n, tbn_t) * select(-1.0, 1.0, dot(cross(n, tbn_t), bitangent) >= 0.0);
                var mapped = material_texture(normal_index, triangle_uv(t, h.uv, 2u)).xyz * 2.0 - vec3(1.0);
                if geometry[t + 15u].w != 0.0 { mapped.z = sqrt(max(1.0 - dot(mapped.xy, mapped.xy), 0.0)); }
                mapped.y *= select(1.0, -1.0, geometry[t + 15u].z != 0.0);
                n = normalize(tbn_t * mapped.x + tbn_b * mapped.y + n * mapped.z);
            }
        }
    }
    if back { n = -n; gn = -gn; }
    if dot(n, -ray) <= 0.0 { n = gn; }
    return n;
}
fn offset_origin(position: vec3<f32>, t: u32, toward: vec3<f32>) -> vec3<f32> {
    var n = geometric_normal(t); if dot(n, toward) < 0.0 { n = -n; }
    return position + n * p.cache_config.z;
}
struct Lighting { diffuse: vec3<f32>, specular: vec3<f32> }
struct LightSample { direction: vec3<f32>, distance: f32, value: vec3<f32> }
fn evaluate_light(position: vec3<f32>, n: vec3<f32>, light_index: u32, uv: vec2<f32>) -> LightSample {
    let index = light_index * 5u; let a = lights[index]; let b = lights[index + 1u];
    let c = lights[index + 2u]; let light = lights[index + 3u];
    var toward = a.xyz; var distance = p.cache_config.w; var attenuation = 1.0;
    if light.w >= 1.0 {
        var light_position = a.xyz;
        if light.w >= 3.0 {
            let u = sqrt(uv.x); let v = uv.y;
            light_position = a.xyz * (1.0 - u) + b.xyz * (u * (1.0 - v)) + c.xyz * (u * v);
        }
        let delta = light_position - position; distance = length(delta);
        if distance <= p.cache_config.z * 2.0 { return LightSample(n, distance, vec3(0.0)); }
        toward = delta / distance; attenuation = 1.0 / (distance * distance);
        if light.w >= 3.0 {
            let normal = normalize(cross(b.xyz - a.xyz, c.xyz - a.xyz));
            var cosine = dot(normal, -toward); if lights[index + 4u].w != 0.0 { cosine = abs(cosine); }
            attenuation *= max(cosine, 0.0) * a.w;
        } else {
            if distance >= a.w { attenuation = 0.0; }
            let falloff = clamp(1.0 - pow(distance / a.w, 4.0), 0.0, 1.0); attenuation *= falloff * falloff;
            if light.w >= 2.0 {
                let cone = clamp((dot(-toward, b.xyz) - b.w) / max(c.x - b.w, 1e-4), 0.0, 1.0);
                attenuation *= cone * cone;
            }
        }
    }
    var emission = light.rgb;
    if light.w >= 3.0 {
        let u = sqrt(uv.x); let triangle = u32(b.w); let bary = vec2(u * (1.0 - uv.y), u * uv.y);
        emission = material_emission(a.xyz * (1.0 - bary.x - bary.y) + b.xyz * bary.x + c.xyz * bary.y, triangle);
        if !material_visible(triangle, bary) { emission = vec3(0.0); }
    }
    return LightSample(toward, distance, emission * (attenuation * max(dot(n, toward), 0.0) / PI));
}
struct Reservoir { light: u32, uv: vec2<f32>, weight_sum: f32, target_density: f32, count: u32 }
fn reservoir_add(r: ptr<function, Reservoir>, light: u32, uv: vec2<f32>, target_density: f32,
    weight: f32, count: u32, rng: ptr<function, u32>) {
    (*r).count += count;
    if !(weight > 0.0) || weight > 1e30 { return; }
    (*r).weight_sum += weight;
    if random(rng) * (*r).weight_sum < weight {
        (*r).light = light; (*r).uv = uv; (*r).target_density = target_density;
    }
}
fn reservoir_reuse(r: ptr<function, Reservoir>, slot: u32, position: vec3<f32>, n: vec3<f32>, rng: ptr<function, u32>) {
    let info = world_cache[slot].previous_reservoir_info;
    let old = world_cache[slot].previous_reservoir;
    if info.x >= p.scene_info.y || info.z == 0u || info.w != p.frame.x - 1u || old.z <= 0.0 { return; }
    let target_density = luminance(evaluate_light(position, n, info.x, old.xy).value);
    let count = min(info.z, 8u * p.options.z);
    reservoir_add(r, info.x, old.xy, target_density, target_density * old.z * f32(count), count, rng);
}
@compute @workgroup_size(64)
fn generate_reservoirs(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[2]) { return; }
    let slot = compact_cell(lane);
    world_cache[slot].reservoir_info = vec4(MISSING, 0u, 0u, p.frame.x);
    world_cache[slot].reservoir = vec4(0.0);
    if p.quality.y == 0.0 || p.scene_info.y == 0u { return; }
    let position = world_cache[slot].position.xyz; let n = world_cache[slot].normal.xyz;
    var rng = hash32(slot ^ hash32(p.frame.x + 127u));
    var r = Reservoir(MISSING, vec2(0.0), 0.0, 0.0, 0u);
    // Eight fresh RIS candidates; only the selected sample needs a shadow ray.
    for (var i = 0u; i < 8u; i++) {
        let column = min(u32(random(&rng) * f32(p.scene_info.y)), p.scene_info.y - 1u);
        let routing = lights[column * 5u + 4u];
        let light = select(u32(routing.y), column, random(&rng) < routing.x);
        let uv = vec2(random(&rng), random(&rng));
        let target_density = luminance(evaluate_light(position, n, light, uv).value);
        reservoir_add(&r, light, uv, target_density, target_density / max(lights[light * 5u + 4u].z, 1e-20), 1u, &rng);
    }
    reservoir_reuse(&r, slot, position, n, &rng);
    // Reuse previous-frame reservoirs only. No invocation reads another's current output.
    let size = p.cache_config.x * exp2(f32(u32(world_cache[slot].key.w) & 31u));
    let basis = tangent_frame(n); let triangle = u32(world_cache[slot].position.w);
    for (var i = 0u; i < 4u; i++) {
        let jitter = (vec2(random(&rng), random(&rng)) * 2.0 - vec2(1.0)) * size * 1.41421356;
        let candidate = cache_find(position + basis[0] * jitter.x + basis[1] * jitter.y, n, world_cache[slot].normal.w, triangle);
        if candidate == MISSING || candidate == slot { continue; }
        if dot(n, world_cache[candidate].normal.xyz) < 0.95 { continue; }
        reservoir_reuse(&r, candidate, position, n, &rng);
    }
    if r.light == MISSING || r.target_density <= 0.0 { return; }
    let normalization = r.weight_sum / (f32(r.count) * r.target_density);
    world_cache[slot].reservoir = vec4(r.uv, normalization, r.target_density);
    world_cache[slot].reservoir_info = vec4(r.light, 0u, r.count, p.frame.x);
}
fn reservoir_radiance(slot: u32) -> vec3<f32> {
    let info = world_cache[slot].reservoir_info; let r = world_cache[slot].reservoir;
    let triangle = u32(world_cache[slot].position.w); var incoming = vec3(0.0);
    if info.x < p.scene_info.y && info.z != 0u {
        let position = world_cache[slot].position.xyz;
        let sample_value = evaluate_light(position, world_cache[slot].normal.xyz, info.x, r.xy);
        let origin = offset_origin(position, triangle, sample_value.direction);
        let shadow = trace_impl(origin, sample_value.direction, max(p.cache_config.z, sample_value.distance - p.cache_config.z * 2.0), true);
        if shadow.triangle == MISSING { incoming = sample_value.value * r.z; }
    }
    let position = world_cache[slot].position.xyz;
    incoming += sky_irradiance(world_cache[slot].normal.xyz, offset_origin(position, triangle, world_cache[slot].normal.xyz), hash32(slot ^ p.frame.x));
    return safe_radiance(material_emission(position, triangle) + material_albedo(position, triangle) * incoming);
}
fn mis_weight(a: f32, b: f32) -> f32 {
    let ratio = b / max(a, 1e-20); return 1.0 / (1.0 + ratio * ratio);
}
fn specular_brdf(n: vec3<f32>, view: vec3<f32>, toward: vec3<f32>, f0: vec3<f32>, roughness: f32) -> vec3<f32> {
    let nv = max(dot(n, view), 1e-4); let nl = max(dot(n, toward), 1e-4); let h = normalize(view + toward);
    let nh = max(dot(n, h), 0.0); let vh = max(dot(view, h), 0.0);
    let alpha = max(roughness * roughness, 1e-6); let a2 = alpha * alpha;
    let f = f0 + (vec3(1.0) - f0) * pow(1.0 - vh, 5.0);
    return f * ggx_ndf(a2, nh) / max(ggx_visibility_reciprocal(a2, nl, nv), 1e-20);
}
fn light_transport(position: vec3<f32>, n: vec3<f32>, origin: vec3<f32>, seed: u32,
    emissive_only: bool, f0: vec3<f32>, view: vec3<f32>, roughness: f32) -> Lighting {
    var color = vec3(0.0); var specular = vec3(0.0);
    if p.scene_info.y == 0u || (emissive_only && p.scene_info.w == 0u) { return Lighting(color, specular); }
    var rng = seed;
    for (var sample_index = 0u; sample_index < p.frame.w; sample_index++) {
        let column = min(u32(random(&rng) * f32(p.scene_info.y)), p.scene_info.y - 1u);
        let routing = lights[column * 5u + 4u];
        let light_index = select(u32(routing.y), column, random(&rng) < routing.x);
        let index = light_index * 5u; let a = lights[index]; let b = lights[index + 1u];
        let c = lights[index + 2u]; let light = lights[index + 3u]; let pmf = lights[index + 4u].z;
        let sample_uv = vec2(random(&rng), random(&rng));
        if pmf <= 0.0 { continue; }
        // Bevy already evaluates analytic direct lights at primary surfaces.
        if emissive_only && light.w < 3.0 { continue; }
        var toward = a.xyz; var distance = p.cache_config.w; var attenuation = 1.0; var light_pdf = 0.0;
        if light.w >= 1.0 {
            var light_position = a.xyz;
            if light.w >= 3.0 {
                let u = sqrt(sample_uv.x); let v = sample_uv.y;
                light_position = a.xyz * (1.0 - u) + b.xyz * (u * (1.0 - v)) + c.xyz * (u * v);
            }
            let delta = light_position - position; distance = length(delta);
            if distance <= p.cache_config.z * 2.0 { continue; }
            toward = delta / distance;
            attenuation = 1.0 / (distance * distance);
            if light.w >= 3.0 {
                let ln = normalize(cross(b.xyz - a.xyz, c.xyz - a.xyz));
                var cosine = dot(ln, -toward);
                if lights[index + 4u].w != 0.0 { cosine = abs(cosine); }
                attenuation *= max(cosine, 0.0) * a.w;
                light_pdf = pmf * distance * distance / max(max(cosine, 0.0) * a.w, 1e-20);
            } else {
                if distance >= a.w { continue; }
                let falloff = clamp(1.0 - pow(distance / a.w, 4.0), 0.0, 1.0);
                attenuation *= falloff * falloff;
                if light.w >= 2.0 {
                    let cone = clamp((dot(-toward, b.xyz) - b.w) / max(c.x - b.w, 1e-4), 0.0, 1.0);
                    attenuation *= cone * cone;
                }
            }
        }
        let cosine = max(dot(n, toward), 0.0);
        if cosine <= 0.0 || attenuation <= 0.0 { continue; }
        let shadow = trace_impl(origin, toward, max(p.cache_config.z, distance - p.cache_config.z * 2.0), true);
        if shadow.triangle == MISSING {
            var emission = light.rgb;
            if light.w >= 3.0 {
                let u = sqrt(sample_uv.x); let bary = vec2(u * (1.0 - sample_uv.y), u * sample_uv.y); let triangle = u32(b.w);
                emission = material_emission(a.xyz * (1.0 - bary.x - bary.y) + b.xyz * bary.x + c.xyz * bary.y, triangle);
                if !material_visible(triangle, bary) { emission = vec3(0.0); }
            }
            let incident = emission * attenuation / (pmf * f32(p.frame.w));
            var dw = 1.0; var sw = 1.0;
            if emissive_only {
                // Pair area-light sampling with one cosine emitter-visibility ray.
                // This prevents near-field inverse-square fireflies without clipping energy.
                dw = mis_weight(f32(p.frame.w) * light_pdf, cosine / PI);
                if roughness >= p.quality.x { sw = dw; }
            }
            color += incident * cosine / PI * dw;
            if roughness >= 0.05 && any(f0 > vec3(0.0)) {
                specular += incident * cosine * specular_brdf(n, view, toward, f0, roughness) * sw;
            }
        }
    }
    if emissive_only {
        let direction = cosine_ray(n, vec2(random(&rng), random(&rng)));
        let hit = trace(origin, direction, p.cache_config.w);
        if hit.triangle != MISSING && any(hit_normal(hit, direction) != vec3(0.0)) {
            let emission = material_emission(origin + direction * hit.distance, hit.triangle);
            if any(emission > vec3(0.0)) {
                let source = u32(geometry[hit.triangle].w) - 1u;
                if source < p.scene_info.y {
                    let index = source * 5u; let la = lights[index]; let lb = lights[index + 1u]; let lc = lights[index + 2u];
                    let normal = normalize(cross(lb.xyz - la.xyz, lc.xyz - la.xyz));
                    var cosine = dot(normal, -direction); if lights[index + 4u].w != 0.0 { cosine = abs(cosine); }
                    let light_pdf = lights[index + 4u].z * hit.distance * hit.distance / max(max(cosine, 0.0) * la.w, 1e-20);
                    let w = mis_weight(max(dot(n, direction), 0.0) / PI, f32(p.frame.w) * light_pdf);
                    color += emission * w;
                    if roughness >= p.quality.x && any(f0 > vec3(0.0)) { specular += emission * specular_brdf(n, view, direction, f0, roughness) * PI * w; }
                }
            }
        }
    }
    return Lighting(safe_radiance(color), safe_radiance(specular));
}
fn direct_irradiance(position: vec3<f32>, n: vec3<f32>, origin: vec3<f32>, seed: u32, emissive_only: bool) -> vec3<f32> {
    var radiance = light_transport(position, n, origin, seed, emissive_only, vec3(0.0), n, 1.0).diffuse;
    if !emissive_only { radiance += sky_irradiance(n, origin, seed); }
    return radiance;
}
fn sky_irradiance(n: vec3<f32>, origin: vec3<f32>, seed: u32) -> vec3<f32> {
    if all(p.sky.rgb == vec3(0.0)) { return vec3(0.0); }
    var rng = hash32(seed + 139u); let ray = cosine_ray(n, vec2(random(&rng), random(&rng)));
    let shadow = trace_impl(origin, ray, p.cache_config.w, true);
    return select(vec3(0.0), p.sky.rgb, shadow.triangle == MISSING);
}
fn direct_radiance(position: vec3<f32>, n: vec3<f32>, triangle: u32, seed: u32) -> vec3<f32> {
    let albedo = material_albedo(position, triangle);
    if all(albedo == vec3(0.0)) { return material_emission(position, triangle); }
    return safe_radiance(material_emission(position, triangle) + albedo *
        direct_irradiance(position, n, offset_origin(position, triangle, n), seed, false));
}
fn cell_descriptor(position: vec3<f32>, n: vec3<f32>, distance: f32) -> vec4<i32> {
    let desired = max(p.cache_config.x, length(position - p.camera.xyz) * p.cache_config.y);
    let lod = clamp(i32(floor(log2(desired / p.cache_config.x))), 0, 20);
    let size = p.cache_config.x * exp2(f32(lod));
    let normal_code = vec3<u32>(clamp(floor((n * 0.5 + vec3(0.5)) * 8.0), vec3(0.0), vec3(7.0)));
    let flags = u32(lod) | (normal_code.x << 5u) | (normal_code.y << 8u) | (normal_code.z << 11u)
        | (u32(distance < size) << 14u);
    return vec4(vec3<i32>(floor(position / size)), i32(flags));
}
fn descriptor_tag(key: vec4<i32>) -> u32 {
    return max(1u, hash32(bitcast<u32>(key.x) ^ hash32(bitcast<u32>(key.y) ^ hash32(bitcast<u32>(key.z) ^ hash32(bitcast<u32>(key.w))))));
}
fn cache_insert(position: vec3<f32>, n: vec3<f32>, distance: f32, triangle: u32, primary: bool) -> u32 {
    let key = cell_descriptor(position, n, distance);
    let tag = max(1u, descriptor_tag(key) ^ hash32(u32(geometry[triangle + 3u].w)));
    for (var attempt = 0u; attempt < CACHE_SEARCH; attempt++) {
        let slot = (tag + attempt) & (p.frame.z - 1u);
        var existing = atomicLoad(&world_cache[slot].tag);
        if existing == 0u {
            let claim = atomicCompareExchangeWeak(&world_cache[slot].tag, 0u, tag);
            if claim.exchanged {
                // Data becomes visible to consumers only in subsequent dispatches.
                world_cache[slot].key = key; world_cache[slot].position = vec4(position, f32(triangle));
                world_cache[slot].normal = vec4(n, distance);
                world_cache[slot].direct = vec4(0.0); world_cache[slot].indirect = vec4(0.0);
                world_cache[slot].previous_direct = vec4(0.0); world_cache[slot].previous_indirect = vec4(0.0);
                world_cache[slot].pending_indirect = vec4(0.0);
                world_cache[slot].reservoir = vec4(0.0); world_cache[slot].previous_reservoir = vec4(0.0);
                world_cache[slot].reservoir_info = vec4(MISSING, 0u, 0u, 0u); world_cache[slot].previous_reservoir_info = vec4(MISSING, 0u, 0u, 0u);
                existing = tag;
            } else { existing = claim.old_value; }
        }
        if existing == tag {
            atomicStore(&world_cache[slot].touched, p.frame.x);
            if primary { atomicStore(&world_cache[slot].primary_frame, p.frame.x); }
            return slot;
        }
    }
    return MISSING; // Consumers shade the hit directly when the cache is full.
}
fn cache_matches(slot: u32, key: vec4<i32>, position: vec3<f32>, n: vec3<f32>, material_token: f32, tag: u32) -> bool {
    return atomicLoad(&world_cache[slot].tag) == tag && all(world_cache[slot].key == key)
        && dot(world_cache[slot].normal.xyz, n) > 0.95
        && abs(dot(world_cache[slot].position.xyz - position, n)) < p.cache_config.z * 2.0
        && geometry[u32(world_cache[slot].position.w) + 3u].w == material_token;
}
fn cache_find(position: vec3<f32>, n: vec3<f32>, distance: f32, triangle: u32) -> u32 {
    let key = cell_descriptor(position, n, distance);
    let material_token = geometry[triangle + 3u].w;
    let tag = max(1u, descriptor_tag(key) ^ hash32(u32(material_token)));
    for (var attempt = 0u; attempt < CACHE_SEARCH; attempt++) {
        let slot = (tag + attempt) & (p.frame.z - 1u);
        // Compare full descriptors: hash collisions must never reuse unrelated light.
        if cache_matches(slot, key, position, n, material_token, tag) { return slot; }
    }
    return MISSING;
}
@compute @workgroup_size(64)
fn clear_cache(@builtin(global_invocation_id) gid: vec3<u32>) {
    let slot = gid.x + gid.y * 65536u; if slot >= p.frame.z { return; }
    let age = p.frame.x - atomicLoad(&world_cache[slot].touched);
    if p.frame.y != 0u || age > p.options.x {
        atomicStore(&world_cache[slot].tag, 0u); atomicStore(&world_cache[slot].primary_frame, 0u);
        world_cache[slot].direct = vec4(0.0); world_cache[slot].indirect = vec4(0.0);
        world_cache[slot].previous_direct = vec4(0.0); world_cache[slot].previous_indirect = vec4(0.0);
        world_cache[slot].pending_indirect = vec4(0.0);
        world_cache[slot].previous_reservoir = vec4(0.0); world_cache[slot].previous_reservoir_info = vec4(MISSING, 0u, 0u, 0u);
    }
}
struct Surface { position: vec3<f32>, normal: vec3<f32>, base: vec3<f32>, roughness: f32, metallic: f32, reflectance: f32, ao: f32, valid: bool }
fn world_position(pixel: vec2<u32>, z: f32) -> vec3<f32> {
    let uv = (vec2<f32>(pixel) + vec2(0.5)) / vec2<f32>(p.viewport.zw);
    let h = p.world_from_clip * vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), z, 1.0);
    return h.xyz / h.w;
}
fn unpack_normal(packed: u32) -> vec3<f32> {
    let uv = vec2(f32(packed & 0xfffu), f32((packed >> 12u) & 0xfffu)) / 4095.0;
    let oct = uv * 2.0 - vec2(1.0); var n = vec3(oct, 1.0 - abs(oct.x) - abs(oct.y));
    let t = clamp(-n.z, 0.0, 1.0); n.x += select(t, -t, n.x >= 0.0); n.y += select(t, -t, n.y >= 0.0);
    return normalize(n);
}
fn surface(pixel: vec2<u32>) -> Surface {
    let coord = vec2<i32>(pixel + p.viewport.xy); let z = textureLoad(depth, coord, 0);
    let g = textureLoad(gbuffer, coord, 0);
    let base_rough = unpack4x8unorm(g.x); let properties = unpack4x8unorm(g.z);
    return Surface(world_position(pixel, max(z, 1e-8)), unpack_normal(g.w), pow(base_rough.rgb, vec3(2.2)),
        base_rough.a, properties.g, properties.r, properties.b, z > 0.0 && ((g.w >> 24u) & 1u) == 0u);
}
fn material_code(s: Surface) -> u32 {
    let base = vec3<u32>(round(clamp(s.base, vec3(0.0), vec3(1.0)) * 31.0));
    return 1u + (base.x | (base.y << 5u) | (base.z << 10u)
        | (u32(round(s.metallic * 7.0)) << 15u) | (u32(round(s.reflectance * 7.0)) << 18u));
}
fn history_material_matches(s: Surface, packed: f32) -> bool {
    if packed <= 0.0 { return false; }
    let code = u32(packed) - 1u;
    let base = vec3(f32(code & 31u), f32((code >> 5u) & 31u), f32((code >> 10u) & 31u)) / 31.0;
    return length(base - s.base) < 0.1 && abs(f32((code >> 15u) & 7u) / 7.0 - s.metallic) < 0.1
        && abs(f32((code >> 18u) & 7u) / 7.0 - s.reflectance) < 0.1;
}
fn footprint(s: Surface, pixel: vec2<u32>) -> f32 {
    let z = textureLoad(depth, vec2<i32>(pixel + p.viewport.xy), 0);
    return max(length(world_position(pixel + vec2(p.screen.z, 0u), z) - s.position), p.cache_config.z * 8.0);
}
fn reproject(position: vec3<f32>) -> vec2<f32> {
    let clip = p.previous_clip_from_world * vec4(position, 1.0);
    if clip.w <= 0.0 { return vec2(-1.0); }
    return clip.xy / clip.w * vec2(0.5, -0.5) + vec2(0.5);
}
fn feedback_radiance(position: vec3<f32>, n: vec3<f32>, triangle: u32) -> vec4<f32> {
    if p.quality.z == 0.0 { return vec4(0.0); }
    return visible_previous_radiance(position, n, triangle);
}
fn visible_previous_radiance(position: vec3<f32>, n: vec3<f32>, triangle: u32) -> vec4<f32> {
    if p.frame.y != 0u || p.reflection_thresholds.z == 0.0 { return vec4(0.0); }
    let uv = reproject(position);
    if any(uv < vec2(0.0)) || any(uv >= vec2(1.0)) { return vec4(0.0); }
    let pixel = vec2<i32>(uv * vec2<f32>(p.viewport.zw));
    let old_position = textureLoad(previous_position, pixel, 0); let old_normal = textureLoad(previous_normal, pixel, 0);
    let cell_size = max(p.cache_config.x, length(position - p.camera.xyz) * p.cache_config.y);
    if old_position.w <= 0.0 || dot(n, old_normal.xyz) < 0.95
        || length(old_position.xyz - position) > cell_size * 0.5
        || abs(dot(old_position.xyz - position, n)) > p.cache_config.z * 4.0 { return vec4(0.0); }
    let bary = barycentrics(position, triangle); let indices = geometry[triangle + 11u]; let properties = geometry[triangle + 12u];
    let base = geometry[triangle + 13u].rgb * material_texture(u32(indices.x), triangle_uv(triangle, bary, 0u)).rgb;
    let mr = material_texture(u32(indices.w), triangle_uv(triangle, bary, 3u));
    let s = Surface(position, n, base, geometry[triangle + 7u].w * mr.g, properties.x * mr.b, properties.y, 1.0, true);
    if !history_material_matches(s, old_position.w) || abs(old_normal.w - s.roughness) > 0.08 { return vec4(0.0); }
    let value = textureLoad(previous_combined, pixel, 0).rgb * p.camera_direction.w;
    // Store reflected light only. Actual emitter radiance always bypasses the
    // spatial cache so a textured area source cannot be enlarged by cell reuse.
    return vec4(max(value - material_emission(position, triangle), vec3(0.0)), 1.0);
}
@compute @workgroup_size(64)
fn spawn_probes(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x + gid.y * 65536u; let count = p.screen.x * p.screen.y; if index >= p.scene_info.z { return; }
    let primary_index = index % count; let layer = index / count;
    let tile = vec2(primary_index % p.screen.x, primary_index / p.screen.x); let start = tile * p.screen.z;
    let seed = hash32(primary_index ^ hash32(p.frame.x)); let offset = seed % (p.screen.z * p.screen.z);
    probes[index].position = vec4(0.0); probes[index].irradiance = vec4(0.0); probes[index].info = vec4(MISSING, 0u, 0u, 0u);
    probes[index].filtered_irradiance = vec4(0.0);
    var primary_position = vec3(0.0); var primary_normal = vec3(0.0); var primary_found = false;
    for (var i = 0u; i < p.screen.z * p.screen.z; i++) {
        let local = (offset + i) % (p.screen.z * p.screen.z); let pixel = start + vec2(local % p.screen.z, local / p.screen.z);
        if any(pixel >= p.viewport.zw) { continue; }
        let s = surface(pixel); if !s.valid { continue; }
        let scale = footprint(s, pixel);
        if layer != 0u {
            if !primary_found { primary_position = s.position; primary_normal = s.normal; primary_found = true; continue; }
            if dot(s.normal, primary_normal) > 0.95
                && abs(dot(s.position - primary_position, primary_normal)) < max(scale * 0.02, p.cache_config.z * 4.0) { continue; }
        }
        probes[index].position = vec4(s.position, 1.0); probes[index].normal = vec4(s.normal, scale);
        let lane = atomicAdd(&work[0], 1u); atomicStore(&work[WORK_HEADER + lane], index);
        probes[index].info.y = pixel.x + pixel.y * p.viewport.z;
        let uv = reproject(s.position);
        if p.frame.y == 0u && all(uv >= vec2(0.0)) && all(uv < vec2(1.0)) {
            let old_tile = min(vec2<u32>(uv * vec2<f32>(p.viewport.zw)) / p.screen.z, p.screen.xy - vec2(1u));
            var closest = 1e30;
            for (var old_layer = 0u; old_layer < p.scene_info.z / count; old_layer++) {
            let old_index = old_tile.x + old_tile.y * p.screen.x + old_layer * count; let old = previous_probes[old_index];
            if old.position.w > 0.0 && dot(old.normal.xyz, s.normal) > 0.95
                && length(old.position.xyz - s.position) < scale * 1.5
                && abs(dot(old.position.xyz - s.position, s.normal)) < max(scale * 0.02, p.cache_config.z * 4.0) {
                let distance = length(old.position.xyz - s.position);
                if distance < closest { probes[index].info.x = old_index; closest = distance; }
            }
            }
        }
        break;
    }
}
@compute @workgroup_size(64)
fn trace_probes(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; let directions = p.screen.w * p.screen.w;
    if lane >= atomicLoad(&work[0]) * directions { return; }
    let index = compact_probe(lane / directions) * directions + lane % directions;
    let probe_index = index / directions; let probe_position = probes[probe_index].position; let normal = probes[probe_index].normal;
    rays[index].info = vec4(MISSING); rays[index].value = vec4(0.0);
    rays[index].position = vec4(0.0); rays[index].normal = vec4(0.0);
    if probe_position.w == 0.0 { return; }
    var rng = hash32(index ^ hash32(p.frame.x)); var bin = index % directions; var importance = 1.0;
    let old = probes[probe_index].info.x;
    if old != MISSING {
        var total = 0.0;
        for (var i = 0u; i < directions; i++) { total += max(0.001, luminance(previous_probes[old].samples[i].rgb)); }
        if random(&rng) < 0.5 {
            let selected = random(&rng) * total; var cumulative = 0.0;
            for (var i = 0u; i < directions; i++) {
                cumulative += max(0.001, luminance(previous_probes[old].samples[i].rgb));
                if cumulative >= selected { bin = i; break; }
            }
        }
        importance = 0.5 + 0.5 * f32(directions) * max(0.001, luminance(previous_probes[old].samples[bin].rgb)) / total;
    }
    let ray = hemisphere_ray(normal.xyz, bin_uv(bin, vec2(random(&rng), random(&rng))));
    let origin = probe_position.xyz + normal.xyz * p.cache_config.z;
    let hit = trace(origin, ray, p.cache_config.w);
    rays[index].direction = vec4(ray, hit.distance);
    rays[index].info = vec4(MISSING, hit.triangle, bin, MISSING);
    rays[index].value.w = 1.0 / importance;
    if hit.triangle == MISSING { rays[index].value = vec4(p.sky.rgb, 1.0 / importance); return; }
    let n = hit_normal(hit, ray);
    if all(n == vec3(0.0)) { return; }
    let position = origin + ray * hit.distance;
    rays[index].position = vec4(position, 1.0); rays[index].normal = vec4(n, f32(hit.distance < hash_cell_size(position)));
    rays[index].info.x = cache_insert(position, n, hit.distance, hit.triangle, true);
    rays[index].info.w = hash_tile_insert(position, ray, hit.distance);
}
@compute @workgroup_size(64)
fn trace_cache_bounces(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[1]) { return; }
    let slot = compact_primary(lane);
    world_cache[slot].bounce_info = vec4(MISSING, MISSING, 0u, 0u);
    if atomicLoad(&world_cache[slot].tag) == 0u || atomicLoad(&world_cache[slot].primary_frame) != p.frame.x || p.options.y == 0u { return; }
    let origin = world_cache[slot].position.xyz; let normal = world_cache[slot].normal.xyz;
    let triangle = u32(world_cache[slot].position.w);
    var rng = hash32(slot ^ hash32(p.frame.x + 17u));
    let direction = cosine_ray(normal, vec2(random(&rng), random(&rng)));
    let ray_origin = offset_origin(origin, triangle, direction);
    let hit = trace(ray_origin, direction, p.cache_config.w);
    world_cache[slot].bounce_info.z = 1u;
    world_cache[slot].bounce_position.w = hit.distance;
    if hit.triangle == MISSING { return; }
    let n = hit_normal(hit, direction);
    world_cache[slot].bounce_info.y = hit.triangle;
    world_cache[slot].bounce_normal = vec4(n, 0.0);
    let position = ray_origin + direction * hit.distance;
    world_cache[slot].bounce_position = vec4(position, hit.distance);
    if all(n == vec3(0.0)) { return; }
    world_cache[slot].bounce_info.x = cache_insert(position, n, hit.distance, hit.triangle, false);
}
@compute @workgroup_size(64)
fn update_cache_direct(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[2]) { return; }
    let slot = compact_cell(lane);
    if slot >= p.frame.z || atomicLoad(&world_cache[slot].tag) == 0u || atomicLoad(&world_cache[slot].touched) != p.frame.x { return; }
    var sample_value = vec3(0.0);
    if p.quality.y != 0.0 { sample_value = reservoir_radiance(slot); }
    else { sample_value = direct_radiance(world_cache[slot].position.xyz, world_cache[slot].normal.xyz,
        u32(world_cache[slot].position.w), hash32(slot ^ hash32(p.frame.x + 41u))); }
    sample_value = max(sample_value - material_emission(world_cache[slot].position.xyz, u32(world_cache[slot].position.w)), vec3(0.0));
    let feedback = feedback_radiance(world_cache[slot].position.xyz, world_cache[slot].normal.xyz, u32(world_cache[slot].position.w));
    if feedback.w != 0.0 { sample_value = feedback.rgb; }
    let old = world_cache[slot].previous_direct; let count = min(old.w + 1.0, f32(p.options.z));
    world_cache[slot].direct = vec4(mix(old.rgb, sample_value, 1.0 / count), count);
}
@compute @workgroup_size(64)
fn update_cache_indirect(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[2]) { return; }
    let slot = compact_cell(lane);
    let sample_value = world_cache[slot].pending_indirect;
    if p.options.y == 0u { world_cache[slot].indirect = vec4(0.0); return; }
    if sample_value.w == 0.0 { return; }
    let old = world_cache[slot].previous_indirect;
    let count = min(old.w + sample_value.w, f32(p.options.z));
    world_cache[slot].indirect = vec4(mix(old.rgb, sample_value.rgb, sample_value.w / count), count);
    world_cache[slot].pending_indirect = vec4(0.0);
}
@compute @workgroup_size(64)
fn resolve_cache_bounces(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[1]) { return; }
    let slot = compact_primary(lane);
    var incoming = vec3(0.0);
    let info = world_cache[slot].bounce_info;
    if info.z != 0u {
        if info.y == MISSING { incoming = vec3(0.0); } // sky is already next-event sampled at the parent
        else if any(world_cache[slot].bounce_normal.xyz != vec3(0.0)) {
            let pos = world_cache[slot].bounce_position; let n = world_cache[slot].bounce_normal.xyz;
            let selected = cache_find(pos.xyz, n, pos.w, info.y);
            if selected == MISSING {
                incoming = direct_radiance(pos.xyz, n, info.y, hash32(slot ^ p.frame.x));
                incoming = max(incoming - material_emission(pos.xyz, info.y), vec3(0.0));
            } else { incoming = world_cache[selected].direct.rgb; }
            // Emissive next-event sampling already estimates emission on this path.
            // Only reflected direct light enters the additional scattering bounce.
        }
    }
    let albedo = material_albedo(world_cache[slot].position.xyz, u32(world_cache[slot].position.w));
    let value = safe_radiance(albedo * incoming);
    // AMD GI-1.2 resolves the second-bounce direct estimator into a pending
    // first-bounce indirect sample. Accumulation consumes it next frame.
    // A valid black sample still advances the estimator; disabled transport does not.
    world_cache[slot].pending_indirect = vec4(value, f32(info.z != 0u));
}
fn cached_radiance(position: vec3<f32>, n: vec3<f32>, distance: f32, triangle: u32, seed: u32, hint: u32, direction: vec3<f32>) -> vec3<f32> {
    let cell = hash_tile_find(position, direction, distance);
    if cell != MISSING {
        let value = hash_radiance(cell);
        if value.w > 0.0 { hash_touch(cell); return value.rgb + material_emission(position, triangle); }
    }
    let key = cell_descriptor(position, n, distance); let token = geometry[triangle + 3u].w;
    let tag = max(1u, descriptor_tag(key) ^ hash32(u32(token)));
    var slot = hint;
    if slot == MISSING || !cache_matches(slot, key, position, n, token, tag) { slot = cache_find(position, n, distance, triangle); }
    if slot != MISSING && world_cache[slot].direct.w > 0.0 {
        let emission = material_emission(position, triangle);
        let feedback = feedback_radiance(position, n, triangle);
        if feedback.w != 0.0 { return feedback.rgb + emission; }
        return world_cache[slot].direct.rgb + world_cache[slot].indirect.rgb + emission;
    }
    // Accurate uncached direct shading, plus the same bounded extra diffuse bounce.
    var value = direct_radiance(position, n, triangle, seed);
    if p.options.y != 0u {
        var rng = hash32(seed); let ray = cosine_ray(n, vec2(random(&rng), random(&rng)));
        let origin = offset_origin(position, triangle, ray); let h = trace(origin, ray, p.cache_config.w);
        var incoming = vec3(0.0); // sky is already included in direct_radiance
        if h.triangle != MISSING {
            let hn = hit_normal(h, ray); incoming = vec3(0.0);
            if any(hn != vec3(0.0)) {
                incoming = max(direct_radiance(origin + ray * h.distance, hn, h.triangle, seed + 11u)
                    - material_emission(origin + ray * h.distance, h.triangle), vec3(0.0));
            }
        }
        value += material_albedo(position, triangle) * incoming;
    }
    return safe_radiance(value);
}
@compute @workgroup_size(64)
fn resolve_probes(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[0]) { return; }
    let index = compact_probe(lane);
    let probe = probes[index]; if probe.position.w == 0.0 { return; }
    let count = p.screen.w * p.screen.w; var estimate = vec3(0.0);
    var sums: array<vec4<f32>, PROBE_DIRECTIONS>; var bin_counts: array<u32, PROBE_DIRECTIONS>;
    var coefficients: array<vec3<f32>, 9>;
    for (var i = 0u; i < count; i++) {
        let r = rays[index * count + i]; var incoming = r.value.rgb;
        if r.info.y != MISSING && any(r.normal.xyz != vec3(0.0)) {
            if r.normal.w != 0.0 && r.info.w != MISSING {
                // Short connecting rays bypass tile mip filtering, as in
                // GenerateReservoirs' visibility/resolve high-bit flag.
                incoming = r.value.rgb + material_emission(r.position.xyz, r.info.y);
            } else { incoming = cached_radiance(r.position.xyz, r.normal.xyz, r.direction.w, r.info.y,
                hash32(index * count + i + p.frame.x), r.info.x, r.direction.xyz);
            }
        }
        // Explicit next-event sampling replaces emitter hits in the diffuse
        // integral. Directional bins retain emission for reflection reuse.
        var reflected = incoming;
        if r.info.y != MISSING { reflected = max(incoming - material_emission(r.position.xyz, r.info.y), vec3(0.0)); }
        let weight = r.value.w / f32(count);
        estimate += reflected * (2.0 * max(dot(probe.normal.xyz, r.direction.xyz), 0.0)) * weight;
        let basis = sh_basis(r.direction.xyz);
        for (var j = 0u; j < 9u; j++) { coefficients[j] += reflected * (2.0 * PI * basis[j] * weight); }
        let bin = r.info.z;
        sums[bin] += vec4(incoming, r.direction.w); bin_counts[bin]++;
    }
    let old_index = probe.info.x; var history = 1.0;
    if old_index != MISSING { history = min(previous_probes[old_index].irradiance.w + 1.0, f32(p.options.z)); }
    let alpha = 1.0 / history;
    if old_index != MISSING { estimate = mix(previous_probes[old_index].irradiance.rgb, estimate, alpha); }
    probes[index].irradiance = vec4(safe_radiance(estimate), history);
    for (var j = 0u; j < 9u; j++) {
        var value = coefficients[j];
        if old_index != MISSING { value = mix(previous_probes[old_index].sh[j].rgb, value, alpha); }
        probes[index].sh[j] = vec4(value, history);
    }
    var prior_sums: array<vec4<f32>, PROBE_DIRECTIONS>; var prior_counts: array<u32, PROBE_DIRECTIONS>;
    if old_index != MISSING {
        let old = previous_probes[old_index];
        // Reconnect each finite endpoint once, then redistribute its directional bin.
        for (var old_bin = 0u; old_bin < count; old_bin++) {
                let old_ray = hemisphere_ray(old.normal.xyz, bin_uv(old_bin, vec2(0.5)));
                let prior_sample = old.samples[old_bin]; var direction = old_ray;
                if prior_sample.w < p.cache_config.w * 0.99 {
                    let offset = old.position.xyz + old_ray * prior_sample.w - probe.position.xyz;
                    if length(offset) > p.cache_config.z { direction = normalize(offset); }
                }
                if dot(direction, probe.normal.xyz) > 0.0 {
                    let bin = direction_bin(probe.normal.xyz, direction);
                    prior_sums[bin] += prior_sample; prior_counts[bin]++;
                }
            }
        }
    for (var bin = 0u; bin < count; bin++) {
        let prior_valid = prior_counts[bin] > 0u;
        let prior = prior_sums[bin] / f32(max(prior_counts[bin], 1u));
        if bin_counts[bin] > 0u {
            let current = sums[bin] / f32(bin_counts[bin]);
            if prior_valid { probes[index].samples[bin] = vec4(mix(prior.rgb, current.rgb, alpha), current.w); }
            else { probes[index].samples[bin] = current; }
        } else { probes[index].samples[bin] = prior; }
    }
}
fn probe_connected(position: vec3<f32>, normal: vec3<f32>, pixel: vec2<u32>, packed_probe_pixel: u32, scale: f32) -> bool {
    // Reject interpolation across a visible break even for coplanar surfaces.
    let probe_pixel = vec2(packed_probe_pixel % p.viewport.z, packed_probe_pixel / p.viewport.z);
    for (var step = 1u; step <= 2u; step++) {
        let mid = vec2<u32>(mix(vec2<f32>(pixel), vec2<f32>(probe_pixel), f32(step) / 3.0));
        let s = surface(mid);
        if !s.valid || dot(s.normal, normal) < 0.95
            || abs(dot(s.position - position, normal)) > max(scale * 0.02, p.cache_config.z * 4.0) { return false; }
    }
    return true;
}
@compute @workgroup_size(64)
fn filter_probes(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[0]) { return; }
    let index = compact_probe(lane);
    let count = p.screen.x * p.screen.y; let center = probes[index];
    if center.position.w == 0.0 { return; }
    let base_index = index % count; let base = vec2<i32>(i32(base_index % p.screen.x), i32(base_index / p.screen.x));
    let pixel = vec2(center.info.y % p.viewport.z, center.info.y / p.viewport.z);
    var sum = center.irradiance.rgb; var total = 1.0;
    var coefficients: array<vec3<f32>, 9>;
    for (var j = 0u; j < 9u; j++) { coefficients[j] = center.sh[j].rgb; }
    for (var y = -2; y <= 2; y++) { for (var x = -2; x <= 2; x++) {
        let tile = base + vec2(x, y);
        if any(tile < vec2(0)) || any(tile >= vec2<i32>(p.screen.xy)) { continue; }
        for (var layer = 0u; layer < p.scene_info.z / count; layer++) {
            let neighbor_index = u32(tile.x) + u32(tile.y) * p.screen.x + layer * count;
            if neighbor_index == index { continue; }
            let position = probes[neighbor_index].position; let normal = probes[neighbor_index].normal;
            if position.w == 0.0 || dot(center.normal.xyz, normal.xyz) < 0.95 { continue; }
            let offset = position.xyz - center.position.xyz;
            if abs(dot(offset, center.normal.xyz)) > max(center.normal.w * 0.02, p.cache_config.z * 4.0) { continue; }
            if !probe_connected(center.position.xyz, center.normal.xyz, pixel, probes[neighbor_index].info.y, center.normal.w) { continue; }
            let weight = exp(-length(offset) / max(center.normal.w, normal.w));
            sum += probes[neighbor_index].irradiance.rgb * weight; total += weight;
            for (var j = 0u; j < 9u; j++) { coefficients[j] += probes[neighbor_index].sh[j].rgb * weight; }
        }
    }}
    // Only this invocation writes filtered_irradiance; all neighbors read the
    // unfiltered estimator, so no workgroup-order dependence or blur feedback.
    probes[index].filtered_irradiance = vec4(sum / total, center.irradiance.w);
    for (var j = 0u; j < 9u; j++) { probes[index].filtered_sh[j] = vec4(coefficients[j] / total, center.irradiance.w); }
}
fn gather_diffuse(s: Surface, pixel: vec2<u32>) -> vec3<f32> {
    let coord = vec2<f32>(pixel) / f32(p.screen.z) - vec2(0.5);
    let base = vec2<i32>(floor(coord)); var value = vec3(0.0); var total = 0.0;
    let scale = footprint(s, pixel);
    for (var y = -1; y <= 2; y++) { for (var x = -1; x <= 2; x++) {
        let tile = base + vec2(x, y);
        if any(tile < vec2(0)) || any(tile >= vec2<i32>(p.screen.xy)) { continue; }
        for (var layer = 0u; layer < p.scene_info.z / (p.screen.x * p.screen.y); layer++) {
        let index = u32(tile.x) + u32(tile.y) * p.screen.x + layer * p.screen.x * p.screen.y; let position = probes[index].position; let normal = probes[index].normal;
        if position.w == 0.0 || dot(s.normal, normal.xyz) < 0.95 { continue; }
        let offset = s.position - position.xyz;
        if abs(dot(offset, s.normal)) > max(scale * 0.02, p.cache_config.z * 4.0) { continue; }
        if !probe_connected(s.position, s.normal, pixel, probes[index].info.y, scale) { continue; }
        let weight = exp(-length(offset) / max(scale, normal.w)) * pow(max(dot(s.normal, normal.xyz), 0.0), 16.0);
        value += probe_irradiance(index, s.normal) * weight; total += weight;
        }
    }}
    if total > 1e-5 { return value / total; }
    // Disoccluded/thin surfaces without a compatible probe get a real traced sample.
    var rng = hash32(pixel.x + pixel.y * p.viewport.z + hash32(p.frame.x));
    let ray = cosine_ray(s.normal, vec2(random(&rng), random(&rng)));
    let origin = s.position + s.normal * p.cache_config.z; let h = trace(origin, ray, p.cache_config.w);
    var incoming = p.sky.rgb;
    if h.triangle != MISSING {
        let n = hit_normal(h, ray); incoming = vec3(0.0);
        if any(n != vec3(0.0)) {
            incoming = max(cached_radiance(origin + ray * h.distance, n, h.distance, h.triangle, rng, MISSING, ray)
                - material_emission(origin + ray * h.distance, h.triangle), vec3(0.0));
        }
    }
    return incoming;
}
fn smith_lambda(cosine: f32, alpha: f32) -> f32 {
    let c2 = max(cosine * cosine, 1e-6); return 0.5 * (sqrt(1.0 + alpha * alpha * (1.0 - c2) / c2) - 1.0);
}
struct SpecularSample { direction: vec3<f32>, weight: vec3<f32> }
fn sample_specular(s: Surface, seed: u32) -> SpecularSample {
    var view = normalize(p.camera.xyz - s.position);
    if p.camera.w != 0.0 { view = p.camera_direction.xyz; }
    return sample_specular_view(s, seed, view);
}
fn sample_specular_view(s: Surface, seed: u32, view: vec3<f32>) -> SpecularSample {
    let nv = max(dot(s.normal, view), 0.0001);
    let f0 = mix(vec3(0.16 * s.reflectance * s.reflectance), s.base, s.metallic);
    if s.roughness < 0.02 {
        let fresnel = f0 + (vec3(1.0) - f0) * pow(1.0 - nv, 5.0);
        return SpecularSample(reflect(-view, s.normal), fresnel);
    }
    let alpha = max(s.roughness * s.roughness, 1e-6);
    let basis = tangent_frame(s.normal); let local_view = transpose(basis) * view;
    var rng = seed;
    let half_vector = ggx_bounded_normal(alpha, local_view, vec2(random(&rng), random(&rng)));
    let local_light = reflect(-local_view, half_vector);
    return SpecularSample(basis * local_light, ggx_sample_weight(alpha, local_view, local_light, f0));
}
@compute @workgroup_size(8, 8)
fn resolve_pixels(@builtin(global_invocation_id) gid: vec3<u32>) {
    let pixel = gid.xy; if any(pixel >= p.viewport.zw) { return; }
    let coord = vec2<i32>(pixel); let s = surface(pixel);
    // The otherwise-unused validity channel retains a compact material signature
    // so reflected history cannot cross a coplanar material boundary under motion.
    textureStore(output_position, coord, vec4(s.position, select(0.0, f32(material_code(s)), s.valid)));
    textureStore(output_normal, coord, vec4(s.normal, s.roughness));
    reflection_trace(pixel, s, hash32(pixel.x + pixel.y * p.viewport.z + hash32(p.frame.x)));
    if !s.valid {
        textureStore(output_diffuse, coord, vec4(0.0)); textureStore(output_specular, coord, vec4(0.0)); return;
    }
    // Filter irradiance before remodulating the receiver material in composition.
    let seed = hash32(pixel.x + pixel.y * p.viewport.z + hash32(p.frame.x));
    var view = normalize(p.camera.xyz - s.position); if p.camera.w != 0.0 { view = p.camera_direction.xyz; }
    let f0 = mix(vec3(0.16 * s.reflectance * s.reflectance), s.base, s.metallic);
    var direct = Lighting(vec3(0.0), vec3(0.0)); var indirect = vec3(0.0);
    if s.metallic < 0.999 {
        direct = light_transport(s.position, s.normal, s.position + s.normal * p.cache_config.z,
            seed + 79u, true, vec3(0.0), view, s.roughness);
    }
    if s.metallic < 0.999 || (p.options.w != 0u && s.roughness > p.reflection_filter.w) { indirect = gather_diffuse(s, pixel); }
    let diffuse = indirect + direct.diffuse;
    textureStore(output_diffuse, coord, vec4(safe_radiance(diffuse), 1.0));
    textureStore(output_specular, coord, vec4(0.0));
}
fn gather_directional(s: Surface, pixel: vec2<u32>, direction: vec3<f32>) -> vec4<f32> {
    let base = vec2<i32>(pixel / p.screen.z); let scale = footprint(s, pixel);
    var color = vec3(0.0); var total = 0.0;
    for (var y = -1; y <= 1; y++) { for (var x = -1; x <= 1; x++) {
        let tile = base + vec2(x, y);
        if any(tile < vec2(0)) || any(tile >= vec2<i32>(p.screen.xy)) { continue; }
        for (var layer = 0u; layer < p.scene_info.z / (p.screen.x * p.screen.y); layer++) {
        let index = u32(tile.x) + u32(tile.y) * p.screen.x + layer * p.screen.x * p.screen.y;
        let position = probes[index].position; let normal = probes[index].normal;
        if position.w == 0.0 || dot(s.normal, normal.xyz) < 0.95 { continue; }
        let offset = s.position - position.xyz;
        if abs(dot(offset, s.normal)) > max(scale * 0.02, p.cache_config.z * 4.0) { continue; }
        if dot(direction, normal.xyz) <= 0.0 { continue; }
        if !probe_connected(s.position, s.normal, pixel, probes[index].info.y, scale) { continue; }
        let w = exp(-length(offset) / max(scale, normal.w));
        color += probes[index].samples[direction_bin(normal.xyz, direction)].rgb * w; total += w;
        }
    }}
    return vec4(color / max(total, 1e-5), f32(total > 1e-5));
}

fn compatible(a: Surface, b: Surface, scale: f32) -> bool {
    return b.valid && dot(a.normal, b.normal) > 0.95
        && abs(dot(b.position - a.position, a.normal)) < max(scale * 0.05, p.cache_config.z * 4.0);
}
fn same_specular_material(a: Surface, b: Surface) -> bool {
    return abs(a.roughness - b.roughness) < 0.08 && abs(a.metallic - b.metallic) < 0.05
        && length(a.base - b.base) < 0.1 && abs(a.reflectance - b.reflectance) < 0.05;
}
@compute @workgroup_size(8, 8)
fn filter_pixels(@builtin(global_invocation_id) gid: vec3<u32>) {
    let pixel=gid.xy;if any(pixel>=p.viewport.zw) {return;}
    let coord=vec2<i32>(pixel);let s=surface(pixel);
    if !s.valid {
        textureStore(output_diffuse,coord,vec4(0.0));textureStore(output_specular,coord,vec4(0.0));
        textureStore(output_position,coord,vec4(0.0));return;
    }
    var diffuse=textureLoad(raw_diffuse,coord,0);var mean=vec3(0.0);var second=vec3(0.0);var total=0.0;
    let scale=footprint(s,pixel)/f32(p.screen.z);
    for(var y=-2;y<=2;y++) {for(var x=-2;x<=2;x++) {
        let tap=coord+vec2(x,y);if any(tap<vec2(0)) || any(tap>=vec2<i32>(p.viewport.zw)) {continue;}
        if !compatible(s,surface(vec2<u32>(tap)),scale) {continue;}
        let weight=exp(-f32(x*x+y*y)*0.35);let d=textureLoad(raw_diffuse,tap,0).rgb;
        mean+=d*weight;second+=d*d*weight;total+=weight;
    }}
    mean/=max(total,1e-5);second/=max(total,1e-5);
    let sigma=sqrt(max(second-mean*mean,vec3(0.0)));
    var old=vec4(0.0);var old_m=vec2(0.0);var history_weight=0.0;let uv=reproject(s.position);
    if p.frame.y==0u && all(uv>=vec2(0.0)) && all(uv<vec2(1.0)) {
        let previous_texel=uv*vec2<f32>(p.viewport.zw)-0.5;let base=vec2<i32>(floor(previous_texel));let fraction=fract(previous_texel);
        for(var y=0;y<2;y++) {for(var x=0;x<2;x++) {
            let tap=base+vec2(x,y);if any(tap<vec2(0)) || any(tap>=vec2<i32>(p.viewport.zw)) {continue;}
            let pos=textureLoad(previous_position,tap,0);let normal=textureLoad(previous_normal,tap,0);
            if pos.w==0.0 || dot(s.normal,normal.xyz)<0.95 || length(pos.xyz-s.position)>max(scale*2.0,p.cache_config.z*4.0)
                || abs(dot(pos.xyz-s.position,s.normal))>max(scale*0.05,p.cache_config.z*4.0) {continue;}
            let w=select(1.0-fraction.x,fraction.x,x==1)*select(1.0-fraction.y,fraction.y,y==1);
            old+=textureLoad(previous_diffuse,tap,0)*w;old_m+=textureLoad(moments,tap,0).xy*w;history_weight+=w;
        }}
    }
    var m=vec2(luminance(diffuse.rgb),pow(luminance(diffuse.rgb),2.0));
    if history_weight>1e-5 {
        old/=history_weight;old_m/=history_weight;
        let margin=max(sigma*3.0,max(mean*0.15,vec3(0.01)));let count=min(old.w+1.0,f32(p.options.z));let alpha=1.0/max(count,1.0);
        diffuse=vec4(mix(clamp(old.rgb,mean-margin,mean+margin),diffuse.rgb,alpha),count);m=mix(old_m,m,alpha);
    }
    var specular=vec4(0.0);
    if p.options.w!=0u {
        let albedo=reflection_directional_albedo(s);
        if s.roughness>p.reflection_filter.w {specular=vec4(diffuse.rgb*albedo,1.0);}
        else {let reflection=reflections[reflection_full_index(2u,pixel)];specular=vec4(reflection.rgb/max(reflection.w,1.0)*albedo,reflection.w);}
    }
    textureStore(output_diffuse,coord,vec4(safe_radiance(diffuse.rgb),diffuse.w));
    textureStore(output_specular,coord,vec4(safe_radiance(specular.rgb),specular.w));
    textureStore(output_position,coord,vec4(m,0.0,0.0));
}
fn atrous(pixel: vec2<u32>, step: i32) {
    if any(pixel >= p.viewport.zw) { return; }
    let coord = vec2<i32>(pixel); let s = surface(pixel);
    let cd = textureLoad(raw_diffuse, coord, 0); let cs = textureLoad(raw_specular, coord, 0);
    if !s.valid { textureStore(output_diffuse, coord, vec4(0.0)); textureStore(output_specular, coord, vec4(0.0)); return; }
    let m = textureLoad(moments, coord, 0);
    let scale = footprint(s, pixel) / f32(p.screen.z);
    // Moment variance includes temporal noise; an early-history floor avoids
    // rejecting every sample during disocclusions and cache warm-up.
    let ds = max(sqrt(max(m.y - m.x * m.x, 0.0)) * 3.0, max(luminance(cd.rgb) * 0.35, 0.02));

    var d = vec3(0.0); var dw = 0.0; 
    let kernel = array<f32, 5>(1.0, 4.0, 6.0, 4.0, 1.0);
    for (var y = -2; y <= 2; y++) { for (var x = -2; x <= 2; x++) {
        let tap = coord + vec2(x, y) * step;
        if any(tap < vec2(0)) || any(tap >= vec2<i32>(p.viewport.zw)) { continue; }
        let ns = surface(vec2<u32>(tap)); if !compatible(s, ns, scale) { continue; }
        let td = textureLoad(raw_diffuse, tap, 0); let ts = textureLoad(raw_specular, tap, 0);
        let nw = pow(max(dot(s.normal, ns.normal), 0.0), 32.0);
        let w = kernel[u32(x + 2)] * kernel[u32(y + 2)] * nw;
        let wd = w * exp(-abs(luminance(td.rgb) - luminance(cd.rgb)) / ds);
        d += td.rgb * wd; dw += wd;

    }}
    textureStore(output_diffuse, coord, vec4(safe_radiance(d / max(dw, 1e-5)), cd.w));
    textureStore(output_specular, coord, cs);
}
@compute @workgroup_size(8, 8)
fn atrous_1(@builtin(global_invocation_id) gid: vec3<u32>) { atrous(gid.xy, 1); }
@compute @workgroup_size(8, 8)
fn atrous_2(@builtin(global_invocation_id) gid: vec3<u32>) { atrous(gid.xy, 2); }
@compute @workgroup_size(8, 8)
fn atrous_4(@builtin(global_invocation_id) gid: vec3<u32>) { atrous(gid.xy, 4); }
@compute @workgroup_size(8, 8)
fn atrous_8(@builtin(global_invocation_id) gid: vec3<u32>) { atrous(gid.xy, 8); }
@compute @workgroup_size(64)
fn snapshot_cache(@builtin(global_invocation_id) gid: vec3<u32>) {
    let lane = gid.x + gid.y * 65536u; if lane >= atomicLoad(&work[2]) { return; }
    let slot = compact_cell(lane);
    world_cache[slot].previous_direct = world_cache[slot].direct;
    world_cache[slot].previous_indirect = world_cache[slot].indirect;
    world_cache[slot].previous_reservoir = world_cache[slot].reservoir;
    world_cache[slot].previous_reservoir_info = world_cache[slot].reservoir_info;
}


