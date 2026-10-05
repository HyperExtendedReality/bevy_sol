// GI-1.2 Rust/Slang adaptation. Reference: AMD Capsaicin commit
// 914b91596cd119eda85fbc1d3c7ee6ac391b1452, gi1.comp and hash_grid_cache.hlsl.
// See THIRD_PARTY_NOTICES.md. Compiled to native SPIR-V with bevy_slang.
#ifndef GI_RADIANCE_CASCADES
#define GI_RADIANCE_CASCADES 0
#endif
struct Params {
    var world_from_clip: float4x4;
    var previous_clip_from_world: float4x4;
    var camera: float4;
    var camera_direction: float4;
    var sky: float4;
    var viewport: uint4;
    var screen: uint4;
    var frame: uint4;
    var scene_info: uint4;
    var cache_config: float4;
    var options: uint4;
    var quality: float4;
    var hash_config: uint4;
    var hash_sampling: float4;
    var reflection: uint4;
    var reflection_filter: float4;
    var reflection_thresholds: float4;
    var light_grid: uint4;
    var motion_clip_from_world: float4x4;
    var previous_motion_clip_from_world: float4x4;
    var environment_rotation: float4;
    var environment: float4;
    var restir: uint4;
    var restir_sampling: float4;
#if GI_RADIANCE_CASCADES
    var cascades: uint4;
    var cascade_sampling: float4;
#endif
};
bool cascades_active() {
#if GI_RADIANCE_CASCADES
    return (p.restir.w&16u)!=0u;
#else
    return false;
#endif
}
struct Probe {
    var position: float4;
    var normal: float4;
    var irradiance: float4;
    var info: uint4;
    var samples: uint2[PROBE_DIRECTIONS];
    var filtered_samples: uint2[PROBE_DIRECTIONS];
    var filtered_irradiance: float4;
    var sh: uint2[9];
    var filtered_sh: uint2[9];
};
struct CacheEntry {
    var tag: Atomic<uint>;
    var touched: Atomic<uint>;
    var primary_frame: Atomic<uint>;
    var reserved: Atomic<uint>;
    var key: int4;
    var position: float4;
    var normal: float4;
    var direct: float4;
    var indirect: float4;
    var previous_direct: float4;
    var previous_indirect: float4;
    var bounce_position: float4;
    var bounce_normal: float4;
    var bounce_info: uint4;
    var pending_indirect: float4;
    var reservoir: float4;
    var reservoir_info: uint4;
};
struct RaySample {
    // SourceAtlas uses position.w/bounce_direction.w for bit-cast visibility IDs.
    var position: float4;
    var normal: float4;
    var direction: float4;
    var info: uint4;
    var value: float4;
    var bounce_position: float4;
    var bounce_normal: float4;
    var bounce_direction: float4;
    var bounce_info: uint4;
    var probe_bounce: float4;
};
[[vk::binding(0, 0)]] ConstantBuffer<Params> p;
[[vk::binding(1, 0)]] StructuredBuffer<float4> geometry;
[[vk::binding(2, 0)]] StructuredBuffer<float4> lights;
[[vk::binding(3, 0)]] RWStructuredBuffer<Probe> previous_probes;
[[vk::binding(4, 0)]] RWStructuredBuffer<Probe> probes;
[[vk::binding(5, 0)]] RWStructuredBuffer<CacheEntry> world_cache;
[[vk::binding(6, 0)]] RWStructuredBuffer<RaySample> rays;
[[vk::binding(7, 0)]] Texture2D<float> depth;
[[vk::binding(8, 0)]] Texture2D<uint4> gbuffer;
[[vk::binding(9, 0)]] Texture2D<float4> previous_diffuse;
[[vk::binding(10, 0)]] Texture2D<float4> previous_specular;
[[vk::binding(11, 0)]] Texture2D<float4> previous_position;
[[vk::binding(12, 0)]] Texture2D<float4> previous_normal;
[[vk::binding(13, 0)]] Texture2D<float4> raw_diffuse;
[[vk::binding(14, 0)]] Texture2D<float4> raw_specular;
[[vk::binding(15, 0)]] RWTexture2D<float4> output_diffuse;
[[vk::binding(16, 0)]] RWTexture2D<float4> output_specular;
[[vk::binding(17, 0)]] RWTexture2D<float4> output_position;
[[vk::binding(18, 0)]] RWTexture2D<float4> output_normal;
[[vk::binding(19, 0)]] Texture2D<float4> moments;
[[vk::binding(20, 0)]] RWStructuredBuffer<Atomic<uint>> work;
[[vk::binding(24, 0)]] Texture2D<float4> previous_combined;
[[vk::binding(30, 0)]] Texture2D<float2> motion_vectors;
[[vk::binding(31, 0)]] TextureCube<float4> environment_map;
[[vk::binding(32, 0)]] SamplerState environment_sampler;
// Rust specializes this constant to match the configured allocation exactly.

static const uint WORK_HEADER = 32u;
static const uint TRIANGLE_WORDS = 20u;
static const float PI = 3.141592653589793;
static const uint MISSING = 0xffffffffu;
static const uint EMISSIVE_PROBE_RAY = 0xfffffffeu;
static const uint CACHE_SEARCH = 16u;
uint hash32(uint x) {
    var v = x; v ^= v >> 16u; v *= 0x7feb352du; v ^= v >> 15u; v *= 0x846ca68bu; return v ^ (v >> 16u);
}
float random(inout uint state) {
    state = hash32(state + 0x9e3779b9u); return float(state >> 8u) / 16777216.0;
}
float luminance(float3 v) { return dot(v, float3(0.2126, 0.7152, 0.0722)); }
float3 safe_radiance(float3 v) {
    // Reject NaNs and infinities before temporal accumulation / half-float output.
    return select(all(v == v) && all(abs(v) < float3(1e30)), clamp(v, float3(0.0), float3(60000.0)), float3(0.0));
}
#include "environment.slang"
float3x3 tangent_frame(float3 n) {
    let up = select(abs(n.y) > 0.99, float3(0.0, 0.0, 1.0), float3(0.0, 1.0, 0.0));
    let t = normalize(cross(up, n)); return transpose(float3x3(t, cross(n, t), n));
}
float3 cosine_ray(float3 n, float2 uv) {
    let radius = sqrt(uv.x); let phi = 2.0 * PI * uv.y;
    return mul(tangent_frame(n), float3(radius * cos(phi), radius * sin(phi), sqrt(1.0 - uv.x)));
}
float2 bin_uv(uint bin, float2 jitter) {
    let a = p.screen.w; return (float2(float(bin % a), float(bin / a)) + jitter) / float(a);
}
float3 hemisphere_ray(float3 n, float2 uv) {
    return mul(probe_frame(n), probe_hemi_octahedron(uv));
}
uint direction_bin(float3 n, float3 d) {
    let local = mul(transpose(probe_frame(n)), d);
    let uv = clamp(probe_hemi_octahedron_inverse(local),float2(0.0),float2(0.99999));
    let cell = uint2(uv * float(p.screen.w)); return cell.x + cell.y * p.screen.w;
}
float[9] sh_basis(float3 d) {
    return float[9](0.2820947918, -0.4886025119 * d.y, 0.4886025119 * d.z,
        -0.4886025119 * d.x, 1.0925484306 * d.x * d.y, -1.0925484306 * d.y * d.z,
        0.3153915653 * (3.0 * d.z * d.z - 1.0), -1.0925484306 * d.x * d.z,
        0.5462742153 * (d.x * d.x - d.y * d.y));
}
float3 probe_irradiance(uint index, float3 n) {
    let basis = sh_basis(n); var color = float3(0.0);
    for (var j = 0u; j < 9u; j++) {
        let convolution = select(j == 0u, 1.0, select(j < 4u, 2.0 / 3.0, 0.25));
        color += probe_unpack(probes[index].filtered_sh[j]).rgb * basis[j] * convolution;
    }
    return max(color, float3(0.0)); // cosine-convolved SH, divided by pi
}
uint compact_probe(uint lane) { return work[WORK_HEADER + lane].load(); }
uint compact_primary(uint lane) { return work[WORK_HEADER + p.scene_info.z + lane].load(); }
uint compact_cell(uint lane) { return work[WORK_HEADER + p.scene_info.z + p.frame.z + lane].load(); }
uint transport_ray_count() {
#if GI_RADIANCE_CASCADES
    if(cascades_active()) {return p.cascades.w;}
#endif
    return work[27].load()*p.screen.w*p.screen.w;
}
uint transport_ray_index(uint lane) {
#if GI_RADIANCE_CASCADES
    if(cascades_active()) {return lane;}
#endif
    let count=p.screen.w*p.screen.w;return compact_fresh_probe(lane/count)*count+lane%count;
}
[shader("compute")][numthreads(1,1,1)]
void reset_work() {
    for (var i = 0u; i < WORK_HEADER; i++) { work[i].store(0u); }
}
[shader("compute")][numthreads(1,1,1)]
void prepare_dispatch() {
    let counts = uint[4](work[0].load(), transport_ray_count(),
        work[1].load(), work[2].load());
    for (var i = 0u; i < 4u; i++) {
        work[4u + i * 4u].store((min(counts[i], 65536u) + 63u) / 64u);
        work[5u + i * 4u].store((counts[i] + 65535u) / 65536u);
        work[6u + i * 4u].store(1u);
    }
    let tiles = work[3].load();
    work[20u].store(min(tiles, 65535u));
    work[21u].store((tiles + 65534u) / 65535u);
    work[22u].store(1u);
    let directional=work[0].load()*p.screen.w*p.screen.w;
    work[28u].store((min(directional,65536u)+63u)/64u);
    work[29u].store((directional+65535u)/65536u);
    work[30u].store(1u);
}
[shader("compute")][numthreads(64,1,1)]
void compact_primary_cells(uint3 gid : SV_DispatchThreadID) {
    let slot = gid.x + gid.y * 65536u;
    if (slot >= p.frame.z || world_cache[slot].tag.load() == 0u || world_cache[slot].primary_frame.load() != p.frame.x) { return; }
    let lane = work[1].add(1u);
    work[WORK_HEADER + p.scene_info.z + lane].store(slot);
}
[shader("compute")][numthreads(64,1,1)]
void compact_touched_cells(uint3 gid : SV_DispatchThreadID) {
    let slot = gid.x + gid.y * 65536u;
    if (slot >= p.frame.z || world_cache[slot].tag.load() == 0u || world_cache[slot].touched.load() != p.frame.x) { return; }
    let lane = work[2].add(1u);
    work[WORK_HEADER + p.scene_info.z + p.frame.z + lane].store(slot);
}
struct Hit {
    var distance: float;
    var triangle: uint;
    var uv: float2;
};
#include "materials.slang"
float2 triangle_uv(uint t, float2 bary, uint channel) {
    let second = ((uint(geometry[t + 12u].w) >> channel) & 1u) != 0u;
    let a = geometry[t + 8u]; let b = geometry[t + 9u]; let c = geometry[t + 10u];
    let uv = select(second, a.zw, a.xy) * (1.0 - bary.x - bary.y) + select(second, b.zw, b.xy) * bary.x + select(second, c.zw, c.xy) * bary.y;
    let transform = geometry[t + 14u];
    return transform.xy * uv.x + transform.zw * uv.y + geometry[t + 15u].xy;
}
float2 barycentrics(float3 position, uint t) {
    let a = geometry[t].xyz; let e1 = geometry[t + 1u].xyz - a; let e2 = geometry[t + 2u].xyz - a;
    let delta = position - a; let d00 = dot(e1, e1); let d01 = dot(e1, e2); let d11 = dot(e2, e2);
    let inverse = 1.0 / max(d00 * d11 - d01 * d01, 1e-20);
    return float2((d11 * dot(delta, e1) - d01 * dot(delta, e2)) * inverse, (d00 * dot(delta, e2) - d01 * dot(delta, e1)) * inverse);
}
float3 material_albedo(float3 position, uint t) {
    let bary = barycentrics(position, t); let indices = geometry[t + 11u]; let properties = geometry[t + 12u];
    let base = geometry[t + 13u].rgb * material_texture(uint(indices.x), triangle_uv(t, bary, 0u)).rgb;
    let metallic = properties.x * material_texture(uint(indices.w), triangle_uv(t, bary, 3u)).b;
    return clamp(base * (1.0 - metallic) * (1.0 - 0.16 * properties.y * properties.y), float3(0.0), float3(0.99));
}
float3 material_emission(float3 position, uint t) {
    let bary=barycentrics(position,t);
    return geometry[t + 7u].rgb * material_texture(uint(geometry[t + 11u].y), triangle_uv(t, bary, 1u)).rgb * material_emission_alpha(t,bary);
}
float3 material_emission_cone(float3 receiver,float3 position,uint t,float solid_angle) {
    if(solid_angle<=0.0) {return material_emission(position,t);}
    let image=uint(geometry[t+11u].y);
    let uv0=triangle_uv(t,float2(0,0),1u);let uv1=triangle_uv(t,float2(1,0),1u);let uv2=triangle_uv(t,float2(0,1),1u);
    let level=area_light_cone_lod(receiver,position,geometry[t].xyz,geometry[t+1u].xyz,geometry[t+2u].xyz,
        uv0,uv1,uv2,material_texture_size(image),solid_angle);
    let value=material_texture_lod(image,triangle_uv(t,barycentrics(position,t),1u),level);
    return safe_radiance(geometry[t+7u].rgb*value.rgb*value.a*material_emission_alpha(t,barycentrics(position,t)));
}
bool source_alpha_testing_disabled() {return (p.restir.w&9u)==9u;}
uint material_alpha_type(uint t) {return (uint(geometry[t+12u].w)>>4u)&3u;}
float material_alpha(uint t,float2 bary) {
    return geometry[t+13u].a*material_texture(uint(geometry[t+11u].x),triangle_uv(t,bary,0u)).a;
}
float material_emission_alpha(uint t,float2 bary) {
    return source_alpha_testing_disabled() && material_alpha_type(t)==2u ? material_alpha(t,bary) : 1.0;
}
float3 material_mesh_position(uint t,float2 bary) {
    return geometry[t+16u].xyz*(1.0-bary.x-bary.y)+geometry[t+17u].xyz*bary.x+geometry[t+18u].xyz*bary.y;
}
uint source_alpha_hash(uint4 values) {
    var value=values.w+374761393u+values.x*3266489917u;
    value=668265263u*((value<<17u)|(value>>15u));
    value+=values.y*3266489917u;
    value=668265263u*((value<<17u)|(value>>15u));
    value+=values.z*3266489917u;
    value=668265263u*((value<<17u)|(value>>15u));
    value=2246822519u*(value^(value>>15u));
    value=3266489917u*(value^(value>>13u));
    return value^(value>>16u);
}
float source_blend_threshold(uint t,float2 bary) {
    let values=asuint(float4(material_mesh_position(t,bary),float(p.frame.x)));
    return saturate(float(source_alpha_hash(values)>>8u)*0x1.0p-24);
}
bool material_visible(uint t, float2 bary) {
    if(source_alpha_testing_disabled()) {return true;}
    let cutoff = geometry[t + 12u].z;
    let type=material_alpha_type(t);
    if(source_probe_projection() ? type==0u : cutoff<0.0) {return true;}
    let alpha=material_alpha(t,bary);
    if(!source_probe_projection()) {return alpha>=cutoff;}
    return alpha>(type==2u ? source_blend_threshold(t,bary) : 0.5);
}
bool material_ray_visible(uint t,float2 bary,bool front_face) {
    if(source_probe_projection() && !source_alpha_testing_disabled() && material_alpha_type(t)!=0u &&
        !front_face && geometry[t+6u].w==0.0) {return false;}
    return material_visible(t,bary);
}
bool hit_box(float3 o, float3 d, float3 lo, float3 hi, float near, float far) {
    var a = near; var b = far;
    for (var axis = 0u; axis < 3u; axis++) {
        if (abs(d[axis]) < 1e-8) { if (o[axis] < lo[axis] || o[axis] > hi[axis]) { return false; } }
        else { let x = (lo[axis] - o[axis]) / d[axis]; let y = (hi[axis] - o[axis]) / d[axis]; a = max(a, min(x, y)); b = min(b, max(x, y)); }
    }
    return a <= b;
}
#if GI_HARDWARE
#include "raytracing.slang"
#else
Hit trace_impl_range(float3 o, float3 d, float near, float far, bool any_hit) {
    var hit = Hit(far, MISSING, float2(0.0)); var node = 0u;
    while ((true)) {
        if (node >= p.scene_info.x) { break; }
        let lo = geometry[node * 2u]; let hi = geometry[node * 2u + 1u];
        if (!hit_box(o, d, lo.xyz, hi.xyz, near, hit.distance)) { node = uint(hi.w); continue; }
        if (lo.w >= 0.0) {
            let index = uint(lo.w); let a = geometry[index].xyz;
            let e1 = geometry[index + 1u].xyz - a; let e2 = geometry[index + 2u].xyz - a;
            let h = cross(d, e2); let det = dot(e1, h);
            if (abs(det) > 1e-8) {
                let inv = 1.0 / det; let s = o - a; let u = dot(s, h) * inv;
                let q = cross(s, e1); let v = dot(d, q) * inv; let t = dot(e2, q) * inv;
                if (u >= 0.0 && v >= 0.0 && u + v <= 1.0 && t >= near && t < hit.distance && material_ray_visible(index, float2(u, v),det>0.0)) {
                    hit = Hit(t, index, float2(u, v)); if (any_hit) { return hit; }
                }
            }
        }
        node++;
    }
    return hit;
}
#endif
Hit trace_impl(float3 o,float3 d,float far,bool any_hit) {return trace_impl_range(o,d,p.cache_config.z,far,any_hit);}
Hit trace(float3 o, float3 d, float far) { return trace_impl(o, d, far, false); }
float3 geometric_normal(uint t) {
    return normalize(cross(geometry[t + 1u].xyz - geometry[t].xyz, geometry[t + 2u].xyz - geometry[t].xyz));
}
float3 hit_normal(Hit h, float3 ray) {
    let t = h.triangle; var gn = geometric_normal(t);
    let back = dot(gn, -ray) < 0.0;
    var n = normalize(geometry[t + 3u].xyz * (1.0 - h.uv.x - h.uv.y)
        + geometry[t + 4u].xyz * h.uv.x + geometry[t + 5u].xyz * h.uv.y);
    // GI-1.2 secondary hits use vertex normals, oriented by triangle facing.
    if (source_probe_projection()) { return select(back, -n, n); }
    if (back && geometry[t + 6u].w == 0.0) { return float3(0.0); }
    if (dot(n, gn) < 0.0) { n = -n; }
    let normal_index = uint(geometry[t + 11u].z);
    if (normal_index != 0u) {
        let uv0 = triangle_uv(t, float2(0.0), 2u); let uv1 = triangle_uv(t, float2(1.0, 0.0), 2u); let uv2 = triangle_uv(t, float2(0.0, 1.0), 2u);
        let du = uv1 - uv0; let dv = uv2 - uv0; let determinant = du.x * dv.y - du.y * dv.x;
        if (abs(determinant) > 1e-10) {
            let e1 = geometry[t + 1u].xyz - geometry[t].xyz; let e2 = geometry[t + 2u].xyz - geometry[t].xyz;
            let tangent = (e1 * dv.y - e2 * du.y) / determinant;
            let bitangent = (e2 * du.x - e1 * dv.x) / determinant;
            let orthogonal = tangent - n * dot(n, tangent);
            if (length(orthogonal) > 1e-8) {
                let tbn_t = normalize(orthogonal); let tbn_b = cross(n, tbn_t) * select(dot(cross(n, tbn_t), bitangent) >= 0.0, 1.0, -1.0);
                var mapped = material_texture(normal_index, triangle_uv(t, h.uv, 2u)).xyz * 2.0 - float3(1.0);
                if (geometry[t + 15u].w != 0.0) { mapped.z = sqrt(max(1.0 - dot(mapped.xy, mapped.xy), 0.0)); }
                mapped.y *= select(geometry[t + 15u].z != 0.0, -1.0, 1.0);
                n = normalize(tbn_t * mapped.x + tbn_b * mapped.y + n * mapped.z);
            }
        }
    }
    if (back) { n = -n; gn = -gn; }
    if (dot(n, -ray) <= 0.0) { n = gn; }
    return n;
}
float3 offset_origin(float3 position, uint t, float3 toward) {
    var n = geometric_normal(t); if (dot(n, toward) < 0.0) { n = -n; }
    return position + n * p.cache_config.z;
}
struct Lighting {
    var diffuse: float3;
    var specular: float3;
};
struct LightSample {
    var direction: float3;
    var distance: float;
    var value: float3;
};
float2 area_light_barycentrics(float2 samples) {
    // AMD sampleAreaLight/sampleAreaLightAM uses this ordering of the two
    // interpolated vertex weights. Share it between RIS and receiver MIS so
    // textured emission and alpha masks evaluate the exact sampled point.
    let root=sqrt(samples.x);return float2(1.0-root,samples.y*root);
}
float3 area_light_position(float3 a,float3 b,float3 c,float2 bary) {
    return a*(1.0-bary.x-bary.y)+b*bary.x+c*bary.y;
}
LightSample evaluate_light_cone(float3 position,float3 n,uint light_index,float2 uv,float solid_angle) {
#if GI_GRID_ENVIRONMENT
    if(grid_environment_light(light_index)) {
        let sampled=sample_environment(n,uv);let cosine=max(dot(n,sampled.xyz),0.0);
        let value=environment_radiance_cone(sampled.xyz,solid_angle)*(cosine/max(PI*sampled.w,1e-20));
        return LightSample(sampled.xyz,p.cache_config.w,value);
    }
#endif
    let index = light_index * 5u; let a = lights[index]; let b = lights[index + 1u];
    let c = lights[index + 2u]; let light = lights[index + 3u];
    var toward = a.xyz; var distance = p.cache_config.w; var attenuation = 1.0;
    if (light.w >= 1.0) {
        var light_position = a.xyz;
        if (light.w >= 3.0) {
            light_position = area_light_position(a.xyz,b.xyz,c.xyz,area_light_barycentrics(uv));
        }
        let delta = light_position - position; distance = length(delta);
        if (distance <= p.cache_config.z * 2.0) { return LightSample(n, distance, float3(0.0)); }
        toward = delta / distance; attenuation = 1.0 / (distance * distance);
        if (light.w >= 3.0) {
            let normal = normalize(cross(b.xyz - a.xyz, c.xyz - a.xyz));
            var cosine = dot(normal, -toward); if (lights[index + 4u].w != 0.0) { cosine = abs(cosine); }
            attenuation *= max(cosine, 0.0) * a.w;
        } else {
            if (distance >= a.w) { attenuation = 0.0; }
            let falloff = clamp(1.0 - pow(distance / a.w, 4.0), 0.0, 1.0); attenuation *= falloff * falloff;
            if (light.w >= 2.0) {
                let cone = clamp((dot(-toward, b.xyz) - b.w) / max(c.x - b.w, 1e-4), 0.0, 1.0);
                attenuation *= cone * cone;
            }
        }
    }
    var emission = light.rgb;
    if (light.w >= 3.0) {
        let triangle = uint(b.w); let bary = area_light_barycentrics(uv);
        emission = material_emission_cone(position,area_light_position(a.xyz,b.xyz,c.xyz,bary),triangle,solid_angle);
        if (!material_visible(triangle, bary)) { emission = float3(0.0); }
    }
    return LightSample(toward, distance, emission * (attenuation * max(dot(n, toward), 0.0) / PI));
}
LightSample evaluate_light(float3 position,float3 n,uint light_index,float2 uv) {return evaluate_light_cone(position,n,light_index,uv,0.0);}
struct Reservoir {
    var light: uint;
    var uv: float2;
    var weight_sum: float;
    var target_density: float;
    var count: uint;
};
void reservoir_add(inout Reservoir r, uint light, float2 uv, float target_density, float weight, uint count, inout uint rng) {
    r.count += count;
    if (!(weight > 0.0) || weight > 1e30) { return; }
    r.weight_sum += weight;
    if (random(rng) * r.weight_sum < weight) {
        r.light = light; r.uv = uv; r.target_density = target_density;
    }
}
[shader("compute")][numthreads(64,1,1)]
void generate_reservoirs(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; if (lane >= work[2].load()) { return; }
    let slot = compact_cell(lane);
    world_cache[slot].reservoir_info = uint4(MISSING, 0u, 0u, p.frame.x);
    world_cache[slot].reservoir = float4(0.0);
    if (grid_light_count() == 0u) { return; }
    let position = world_cache[slot].position.xyz; let n = world_cache[slot].normal.xyz;
    let triangle = uint(world_cache[slot].position.w);
    var rng = hash32(slot ^ hash32(p.frame.x + 127u));
    var r = grid_fresh_reservoir(position, n, n, triangle, rng);
    if (r.light == MISSING || r.target_density <= 0.0) { return; }
    let normalization = r.weight_sum / (float(r.count) * r.target_density);
    world_cache[slot].reservoir = float4(r.uv, normalization, r.target_density);
    world_cache[slot].reservoir_info = uint4(r.light, 0u, r.count, p.frame.x);
}
float3 reservoir_radiance(uint slot) {
    let info = world_cache[slot].reservoir_info; let r = world_cache[slot].reservoir;
    let triangle = uint(world_cache[slot].position.w); var incoming = float3(0.0);
    if (info.x < grid_light_count() && info.z != 0u) {
        let position = world_cache[slot].position.xyz;
        let sample_value = evaluate_light_cone(position,world_cache[slot].normal.xyz,info.x,r.xy,4.0*PI/(8.0*12000.0));
        let origin = offset_origin(position, triangle, sample_value.direction);
        let shadow = trace_impl(origin, sample_value.direction, max(p.cache_config.z, sample_value.distance - p.cache_config.z * 2.0), true);
        if (shadow.triangle == MISSING) { incoming = sample_value.value * r.z; }
    }
    let position = world_cache[slot].position.xyz;
    if(!grid_environment_enabled()) {incoming += sky_irradiance(world_cache[slot].normal.xyz, offset_origin(position, triangle, world_cache[slot].normal.xyz), hash32(slot ^ p.frame.x));}
    return safe_radiance(material_emission(position, triangle) + material_albedo(position, triangle) * incoming);
}
float mis_weight(float a, float b) {
    let ratio = b / max(a, 1e-20); return 1.0 / (1.0 + ratio * ratio);
}
float3 specular_brdf(float3 n, float3 view, float3 toward, float3 f0, float roughness) {
    let nv = max(dot(n, view), 1e-4); let nl = max(dot(n, toward), 1e-4); let h = normalize(view + toward);
    let nh = max(dot(n, h), 0.0); let vh = max(dot(view, h), 0.0);
    let alpha = max(roughness * roughness, 1e-6); let a2 = alpha * alpha;
    let f = f0 + (float3(1.0) - f0) * pow(1.0 - vh, 5.0);
    return f * ggx_ndf(a2, nh) / max(ggx_visibility_reciprocal(a2, nl, nv), 1e-20);
}
Lighting light_transport(float3 position, float3 n, float3 origin, uint seed, bool emissive_only, float3 f0, float3 view, float roughness) {
    var color = float3(0.0); var specular = float3(0.0);
    if (p.scene_info.y == 0u || (emissive_only && p.scene_info.w == 0u)) { return Lighting(color, specular); }
    var rng = seed;
    for (var sample_index = 0u; sample_index < p.frame.w; sample_index++) {
        let column = min(uint(random(rng) * float(p.scene_info.y)), p.scene_info.y - 1u);
        let routing = lights[column * 5u + 4u];
        let light_index = select(random(rng) < routing.x, column, uint(routing.y));
        let index = light_index * 5u; let a = lights[index]; let b = lights[index + 1u];
        let c = lights[index + 2u]; let light = lights[index + 3u]; let pmf = lights[index + 4u].z;
        let sample_uv = float2(random(rng), random(rng));
        if (pmf <= 0.0) { continue; }
        // Bevy already evaluates analytic direct lights at primary surfaces.
        if (emissive_only && light.w < 3.0) { continue; }
        var toward = a.xyz; var distance = p.cache_config.w; var attenuation = 1.0; var light_pdf = 0.0;
        if (light.w >= 1.0) {
            var light_position = a.xyz;
            if (light.w >= 3.0) {
                light_position = area_light_position(a.xyz,b.xyz,c.xyz,area_light_barycentrics(sample_uv));
            }
            let delta = light_position - position; distance = length(delta);
            if (distance <= p.cache_config.z * 2.0) { continue; }
            toward = delta / distance;
            attenuation = 1.0 / (distance * distance);
            if (light.w >= 3.0) {
                let ln = normalize(cross(b.xyz - a.xyz, c.xyz - a.xyz));
                var cosine = dot(ln, -toward);
                if (lights[index + 4u].w != 0.0) { cosine = abs(cosine); }
                attenuation *= max(cosine, 0.0) * a.w;
                light_pdf = pmf * distance * distance / max(max(cosine, 0.0) * a.w, 1e-20);
            } else {
                if (distance >= a.w) { continue; }
                let falloff = clamp(1.0 - pow(distance / a.w, 4.0), 0.0, 1.0);
                attenuation *= falloff * falloff;
                if (light.w >= 2.0) {
                    let cone = clamp((dot(-toward, b.xyz) - b.w) / max(c.x - b.w, 1e-4), 0.0, 1.0);
                    attenuation *= cone * cone;
                }
            }
        }
        let cosine = max(dot(n, toward), 0.0);
        if (cosine <= 0.0 || attenuation <= 0.0) { continue; }
        let shadow = trace_impl(origin, toward, max(p.cache_config.z, distance - p.cache_config.z * 2.0), true);
        if (shadow.triangle == MISSING) {
            var emission = light.rgb;
            if (light.w >= 3.0) {
                let bary = area_light_barycentrics(sample_uv); let triangle = uint(b.w);
                emission = material_emission(area_light_position(a.xyz,b.xyz,c.xyz,bary), triangle);
                if (!material_visible(triangle, bary)) { emission = float3(0.0); }
            }
            let incident = emission * attenuation / (pmf * float(p.frame.w));
            var dw = 1.0; var sw = 1.0;
            if (emissive_only) {
                // Pair area-light sampling with one cosine emitter-visibility ray.
                // This prevents near-field inverse-square fireflies without clipping energy.
                dw = mis_weight(float(p.frame.w) * light_pdf, cosine / PI);
                if (roughness >= p.quality.x) { sw = dw; }
            }
            color += incident * cosine / PI * dw;
            if (roughness >= 0.05 && any(f0 > float3(0.0))) {
                specular += incident * cosine * specular_brdf(n, view, toward, f0, roughness) * sw;
            }
        }
    }
    if (emissive_only) {
        let direction = cosine_ray(n, float2(random(rng), random(rng)));
        let hit = trace(origin, direction, p.cache_config.w);
        if (hit.triangle != MISSING && any(hit_normal(hit, direction) != float3(0.0))) {
            let emission = material_emission(origin + direction * hit.distance, hit.triangle);
            if (any(emission > float3(0.0))) {
                let source = uint(geometry[hit.triangle].w) - 1u;
                if (source < p.scene_info.y) {
                    let index = source * 5u; let la = lights[index]; let lb = lights[index + 1u]; let lc = lights[index + 2u];
                    let normal = normalize(cross(lb.xyz - la.xyz, lc.xyz - la.xyz));
                    var cosine = dot(normal, -direction); if (lights[index + 4u].w != 0.0) { cosine = abs(cosine); }
                    let light_pdf = lights[index + 4u].z * hit.distance * hit.distance / max(max(cosine, 0.0) * la.w, 1e-20);
                    let w = mis_weight(max(dot(n, direction), 0.0) / PI, float(p.frame.w) * light_pdf);
                    color += emission * w;
                    if (roughness >= p.quality.x && any(f0 > float3(0.0))) { specular += emission * specular_brdf(n, view, direction, f0, roughness) * PI * w; }
                }
            }
        }
    }
    return Lighting(safe_radiance(color), safe_radiance(specular));
}
float3 direct_irradiance(float3 position, float3 n, float3 origin, uint seed, bool emissive_only) {
    var radiance = light_transport(position, n, origin, seed, emissive_only, float3(0.0), n, 1.0).diffuse;
    if (!emissive_only) { radiance += sky_irradiance(n, origin, seed); }
    return radiance;
}
float3 sky_irradiance(float3 n, float3 origin, uint seed) {
    if (!has_environment()) { return float3(0.0); }
    var rng = hash32(seed + 139u);
    let sampled=sample_environment(n,float2(random(rng),random(rng)));
    let ray=sampled.xyz;let cosine=max(dot(n,ray),0.0);
    if(cosine==0.0 || sampled.w<=0.0) {return float3(0.0);}
    let shadow = trace_impl(origin, ray, p.cache_config.w, true);
    return select(shadow.triangle == MISSING, environment_radiance(ray)*(cosine/(PI*sampled.w)), float3(0.0));
}
float3 direct_radiance(float3 position, float3 n, uint triangle, uint seed) {
    let albedo = material_albedo(position, triangle);
    if (all(albedo == float3(0.0))) { return material_emission(position, triangle); }
    return safe_radiance(material_emission(position, triangle) + albedo *
        direct_irradiance(position, n, offset_origin(position, triangle, n), seed, false));
}
int4 cell_descriptor(float3 position, float3 n, float distance) {
    let desired = max(p.cache_config.x, length(position - p.camera.xyz) * p.cache_config.y);
    let lod = clamp(int(floor(log2(desired / p.cache_config.x))), 0, 20);
    let size = p.cache_config.x * exp2(float(lod));
    let normal_code = uint3(clamp(floor((n * 0.5 + float3(0.5)) * 8.0), float3(0.0), float3(7.0)));
    let flags = uint(lod) | (normal_code.x << 5u) | (normal_code.y << 8u) | (normal_code.z << 11u)
        | (uint(distance < size) << 14u);
    return int4(int3(floor(position / size)), int(flags));
}
uint descriptor_tag(int4 key) {
    return max(1u, hash32(asuint(key.x) ^ hash32(asuint(key.y) ^ hash32(asuint(key.z) ^ hash32(asuint(key.w))))));
}
uint cache_insert(float3 position, float3 n, float distance, uint triangle, bool primary) {
    if(source_probe_projection()) {return MISSING;}
    let key = cell_descriptor(position, n, distance);
    let tag = max(1u, descriptor_tag(key) ^ hash32(uint(geometry[triangle + 3u].w)));
    for (var attempt = 0u; attempt < CACHE_SEARCH; attempt++) {
        let slot = (tag + attempt) & (p.frame.z - 1u);
        var existing = world_cache[slot].tag.load();
        if (existing == 0u) {
            let claim = world_cache[slot].tag.compareExchange(0u, tag);
            if (claim == 0u) {
                // Data becomes visible to consumers only in subsequent dispatches.
                world_cache[slot].key = key; world_cache[slot].position = float4(position, float(triangle));
                world_cache[slot].normal = float4(n, distance);
                world_cache[slot].direct = float4(0.0); world_cache[slot].indirect = float4(0.0);
                world_cache[slot].previous_direct = float4(0.0); world_cache[slot].previous_indirect = float4(0.0);
                world_cache[slot].pending_indirect = float4(0.0);
                world_cache[slot].reservoir = float4(0.0);
                world_cache[slot].reservoir_info = uint4(MISSING, 0u, 0u, 0u);
                existing = tag;
            } else { existing = claim; }
        }
        if (existing == tag) {
            world_cache[slot].touched.store(p.frame.x);
            if (primary) { world_cache[slot].primary_frame.store(p.frame.x); }
            return slot;
        }
    }
    return MISSING; // Consumers shade the hit directly when the cache is full.
}
bool cache_matches(uint slot, int4 key, float3 position, float3 n, float material_token, uint tag) {
    return world_cache[slot].tag.load() == tag && all(world_cache[slot].key == key)
        && dot(world_cache[slot].normal.xyz, n) > 0.95
        && abs(dot(world_cache[slot].position.xyz - position, n)) < p.cache_config.z * 2.0
        && geometry[uint(world_cache[slot].position.w) + 3u].w == material_token;
}
uint cache_find(float3 position, float3 n, float distance, uint triangle) {
    let key = cell_descriptor(position, n, distance);
    let material_token = geometry[triangle + 3u].w;
    let tag = max(1u, descriptor_tag(key) ^ hash32(uint(material_token)));
    for (var attempt = 0u; attempt < CACHE_SEARCH; attempt++) {
        let slot = (tag + attempt) & (p.frame.z - 1u);
        // Compare full descriptors: hash collisions must never reuse unrelated light.
        if (cache_matches(slot, key, position, n, material_token, tag)) { return slot; }
    }
    return MISSING;
}
[shader("compute")][numthreads(64,1,1)]
void clear_cache(uint3 gid : SV_DispatchThreadID) {
    let slot = gid.x + gid.y * 65536u; if (slot >= p.frame.z) { return; }
    let age = p.frame.x - world_cache[slot].touched.load();
    if (p.frame.y != 0u || age > p.options.x) {
        world_cache[slot].tag.store(0u); world_cache[slot].primary_frame.store(0u);
        world_cache[slot].direct = float4(0.0); world_cache[slot].indirect = float4(0.0);
        world_cache[slot].previous_direct = float4(0.0); world_cache[slot].previous_indirect = float4(0.0);
        world_cache[slot].pending_indirect = float4(0.0);
       
    }
}
struct Surface {
    var position: float3;
    var normal: float3;
    var base: float3;
    var roughness: float;
    var metallic: float;
    var reflectance: float;
    var ao: float;
    var valid: bool;
    var geometry_normal: float3;
};
#ifndef GI_PRIMARY_GEOMETRY_NORMALS
#define GI_PRIMARY_GEOMETRY_NORMALS 0
#endif
uint primary_normal_address(uint2 pixel) {return source_candidate_end()+pixel.x+pixel.y*p.viewport.z;}
uint previous_primary_normal_address(uint2 pixel) {return primary_normal_address(pixel)+p.viewport.z*p.viewport.w;}
uint primary_pack_geometry_normal(float3 normal,bool valid) {
    if(!valid) {return 0u;}
    let encoded=uint3(round(clamp(normal*0.5+0.5,0.0,1.0)*1023.0));
    return encoded.x|(encoded.y<<10u)|(encoded.z<<20u)|0xc0000000u;
}
float3 primary_unpack_geometry_normal(uint packed) {
    let encoded=float3(float(packed&1023u),float((packed>>10u)&1023u),float((packed>>20u)&1023u))/1023.0;
    return normalize(encoded*2.0-1.0);
}
float3 surface_plane_normal(Surface s) {return select(source_probe_projection(),s.geometry_normal,s.normal);}
float3 primary_details_normal(Surface s) {
    if(!source_probe_projection()) {return s.normal;}
    // Details history uses decoded shading normals without renormalizing the
    // source R10G10B10A2_UNORM attachment.
    let encoded=round(clamp(s.normal*0.5+0.5,0.0,1.0)*1023.0)/1023.0;
    return encoded*2.0-1.0;
}
float3 surface_shading_normal(Surface s) {
    if(source_probe_projection()) {return normalize(primary_details_normal(s));}
    return s.normal;
}
float4 primary_history_details(Surface s) {
    let value=float4(primary_details_normal(s),s.roughness);
    if(source_probe_projection()) {return value;}
    // The shared full-float carrier preserves source RGB10 decode precision;
    // compensated history retains its original half-float quantization.
    return float4(unpack2x16float(pack2x16float(value.xy)),unpack2x16float(pack2x16float(value.zw)));
}
float3 world_position(uint2 pixel, float z) {
    let uv = (float2(pixel) + float2(0.5)) / float2(p.viewport.zw);
    let h = mul(p.world_from_clip, float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), z, 1.0));
    return h.xyz / h.w;
}
float3 unpack_normal(uint packed) {
    let uv = float2(float(packed & 0xfffu), float((packed >> 12u) & 0xfffu)) / 4095.0;
    let oct = uv * 2.0 - float2(1.0); var n = float3(oct, 1.0 - abs(oct.x) - abs(oct.y));
    let t = clamp(-n.z, 0.0, 1.0); n.x += select(n.x >= 0.0, -t, t); n.y += select(n.y >= 0.0, -t, t);
    return normalize(n);
}
Surface surface_uncached(uint2 pixel) {
    let coord = int2(pixel + p.viewport.xy); let z = depth.Load(int3(coord, 0));
    let g = gbuffer.Load(int3(coord, 0));
    let base_rough = unpack4x8unorm(g.x); let properties = unpack4x8unorm(g.z);
    let normal=unpack_normal(g.w);
    var s=Surface(world_position(pixel, max(z, 1e-8)),normal,pow(base_rough.rgb,float3(2.2)),
        base_rough.a,properties.g,properties.r,properties.b,z>0.0&&((g.w>>24u)&1u)==0u,normal);
    return s;
}
Surface surface(uint2 pixel) {
    var s=surface_uncached(pixel);
#if GI_PRIMARY_GEOMETRY_NORMALS
    if(source_probe_projection()&&s.valid&&all(pixel<p.viewport.zw)) {
        let packed=work[primary_normal_address(pixel)].load();
        if((packed>>30u)!=0u) {s.geometry_normal=primary_unpack_geometry_normal(packed);}
    }
#endif
    return s;
}
float4 primary_geometry_normal_from_hit(Hit hit,float3 origin,float3 direction,Surface s) {
    // The source visibility pass stores a flat, camera-facing face normal.
    if(hit.triangle==MISSING) {return float4(s.normal,0.0);}
    let tolerance=max(p.cache_config.z*2.0,length(s.position-origin)*1e-4);
    if(length(origin+direction*hit.distance-s.position)>tolerance) {return float4(s.normal,0.0);}
    var normal=geometric_normal(hit.triangle);
    if(dot(normal,-direction)<0.0) {normal=-normal;}
    return float4(normal,1.0);
}
float4 trace_primary_geometry_normal(uint2 pixel,Surface s) {
    if(!s.valid||p.scene_info.x==0u) {return float4(s.normal,0.0);}
    let origin=world_position(pixel,1.0);let delta=s.position-origin;
    let distance=length(delta);
    if(distance<=p.cache_config.z) {return float4(s.normal,0.0);}
    let direction=delta/distance;
    let hit=trace(origin,direction,distance+max(p.cache_config.z*2.0,distance*1e-4));
    return primary_geometry_normal_from_hit(hit,origin,direction,s);
}
uint material_code(Surface s) {
    let base = uint3(round(clamp(s.base, float3(0.0), float3(1.0)) * 31.0));
    return 1u + (base.x | (base.y << 5u) | (base.z << 10u)
        | (uint(round(s.metallic * 7.0)) << 15u) | (uint(round(s.reflectance * 7.0)) << 18u));
}
bool history_material_matches(Surface s, float packed) {
    if (packed <= 0.0) { return false; }
    let code = uint(packed) - 1u;
    let base = float3(float(code & 31u), float((code >> 5u) & 31u), float((code >> 10u) & 31u)) / 31.0;
    return length(base - s.base) < 0.1 && abs(float((code >> 15u) & 7u) / 7.0 - s.metallic) < 0.1
        && abs(float((code >> 18u) & 7u) / 7.0 - s.reflectance) < 0.1;
}
float footprint(Surface s, uint2 pixel) {
    let z = depth.Load(int3(int2(pixel + p.viewport.xy), 0));
    return max(length(world_position(pixel + uint2(p.screen.z, 0u), z) - s.position), p.cache_config.z * 8.0);
}
float2 reproject(float3 position) {
    let clip = mul(p.previous_clip_from_world, float4(position, 1.0));
    if (clip.w <= 0.0) { return float2(-1.0); }
    return clip.xy / clip.w * float2(0.5, -0.5) + float2(0.5);
}
float2 reproject_motion(float3 position,float2 velocity) {
    // Bevy motion vectors contain camera and object motion in unjittered UVs.
    // Remove their camera component, then offset our jittered reprojection by
    // object motion. This also handles orthographic cameras and viewports.
    let current=mul(p.motion_clip_from_world,float4(position,1.0));
    let previous=mul(p.previous_motion_clip_from_world,float4(position,1.0));
    if(current.w<=0.0 || previous.w<=0.0 || any(velocity!=velocity)) {return float2(-1.0);}
    let camera_velocity=(current.xy/current.w-previous.xy/previous.w)*float2(0.5,-0.5);
    return reproject(position)-(velocity-camera_velocity);
}
float2 reproject_surface(uint2 pixel,float3 position) {
    return reproject_motion(position,motion_vectors.Load(int3(pixel+p.viewport.xy,0)));
}
float4 feedback_radiance(float3 position, float3 n, uint triangle) {
    if (p.quality.z == 0.0) { return float4(0.0); }
    if(!source_direct_lighting_enabled()) {return float4(0.0);}
    if(source_probe_projection()) {return source_previous_radiance(position,n,false);}
    return visible_previous_radiance(position, n, triangle);
}
bool source_feedback_compatible(float3 normal,float3 previous_normal,float projected_depth,float previous_depth,bool glossy) {
    return dot(normal,previous_normal)>select(glossy,0.95,0.5)
        && abs(previous_depth-projected_depth)/projected_depth<select(glossy,0.01,0.05);
}
float previous_view_depth(float3 position) {
    if(p.camera.w==0.0) {return mul(p.previous_clip_from_world,float4(position,1.0)).w;}
    return dot(p.restir_sampling.xyz-position,normalize(p.previous_clip_from_world[2].xyz));
}
float4 source_previous_radiance(float3 position,float3 normal,bool glossy) {
#if GI_PRIMARY_GEOMETRY_NORMALS
    if((p.frame.y&1u)!=0u||p.reflection_thresholds.z==0.0) {return float4(0.0);}
    let clip=probe_cache_current_clip(position);
    if(clip.w<=0.0||clip.z/clip.w<=0.0) {return float4(0.0);}
    let uv=clip.xy/clip.w*float2(0.5,-0.5)+0.5;
    if(any(uv<=float2(0.0))||any(uv>=float2(1.0))) {return float4(0.0);}
    let current_pixel=uint2(uv*float2(p.viewport.zw));
    let previous_uv=reproject_surface(current_pixel,position);
    if(any(previous_uv<=float2(0.0))||any(previous_uv>=float2(1.0))) {return float4(0.0);}
    let pixel=uint2(previous_uv*float2(p.viewport.zw));
    let packed=work[previous_primary_normal_address(pixel)].load();
    if((packed>>30u)==0u) {return float4(0.0);}
    let previous_normal=primary_unpack_geometry_normal(packed);
    let previous_position_value=previous_position.Load(int3(pixel,0));
    let projected_depth=previous_view_depth(position);
    if(!source_feedback_compatible(normal,previous_normal,projected_depth,previous_view_depth(previous_position_value.xyz),glossy)) {return float4(0.0);}
    return float4(previous_combined.Load(int3(pixel,0)).rgb*p.camera_direction.w,1.0);
#else
    return float4(0.0);
#endif
}
float4 visible_previous_radiance(float3 position, float3 n, uint triangle) {
    if(source_probe_projection()) {return source_previous_radiance(position,n,true);}
    if ((p.frame.y&1u) != 0u || p.reflection_thresholds.z == 0.0) { return float4(0.0); }
    let clip=probe_cache_current_clip(position);
    if(clip.w<=0.0) {return float4(0.0);}
    let current_uv=clip.xy/clip.w*float2(0.5,-0.5)+0.5;
    if(any(current_uv<float2(0.0)) || any(current_uv>=float2(1.0))) {return float4(0.0);}
    let current_pixel=uint2(current_uv*float2(p.viewport.zw));
    let visible=surface(current_pixel);
    // Read velocity only from the hit's currently visible surface. An occluder's
    // motion vector must not reconnect a hidden ray hit to unrelated history.
    if(!visible.valid || dot(visible.normal,n)<0.95 ||
        length(visible.position-position)>max(footprint(visible,current_pixel)*0.1,p.cache_config.z*4.0)) {return float4(0.0);}
    let uv = reproject_surface(current_pixel,position);
    if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) { return float4(0.0); }
    let pixel = int2(uv * float2(p.viewport.zw));
    let old_position = previous_position.Load(int3(pixel, 0)); let old_normal = previous_normal.Load(int3(pixel, 0));
    let cell_size = max(p.cache_config.x, length(position - p.camera.xyz) * p.cache_config.y);
    if (old_position.w <= 0.0 || dot(n, old_normal.xyz) < 0.95
        || length(old_position.xyz - position) > cell_size * 0.5
        || abs(dot(old_position.xyz - position, n)) > p.cache_config.z * 4.0) { return float4(0.0); }
    let bary = barycentrics(position, triangle); let indices = geometry[triangle + 11u]; let properties = geometry[triangle + 12u];
    let base = geometry[triangle + 13u].rgb * material_texture(uint(indices.x), triangle_uv(triangle, bary, 0u)).rgb;
    let mr = material_texture(uint(indices.w), triangle_uv(triangle, bary, 3u));
    let s = Surface(position, n, base, geometry[triangle + 7u].w * mr.g, properties.x * mr.b, properties.y, 1.0, true,n);
    if (!history_material_matches(s, old_position.w) || abs(old_normal.w - s.roughness) > 0.08) { return float4(0.0); }
    let value = previous_combined.Load(int3(pixel, 0)).rgb * p.camera_direction.w;
    // Store reflected light only. Actual emitter radiance always bypasses the
    // spatial cache so a textured area source cannot be enlarged by cell reuse.
    return float4(max(value - material_emission(position, triangle), float3(0.0)), 1.0);
}
[shader("compute")][numthreads(64,1,1)]
void spawn_probes(uint3 gid : SV_DispatchThreadID) {
    let index = gid.x + gid.y * 65536u; let count = p.screen.x * p.screen.y; if (index >= p.scene_info.z) { return; }
    let primary_index = index % count; let layer = index / count;
    let tile = uint2(primary_index % p.screen.x, primary_index / p.screen.x); let start = tile * p.screen.z;
    let spawn_axis=1u<<(uint(p.quality.w)>>1u);
    let jitter=probe_spawn_jitter(select(probe_should_refresh(tile),spawn_axis*p.screen.z,p.screen.z))%p.screen.z;
    let offset=jitter.x+jitter.y*p.screen.z;
    probes[index].position = float4(0.0); probes[index].irradiance = float4(0.0); probes[index].info = uint4(MISSING, 0u, 0u, 0u);
    probes[index].filtered_irradiance = float4(0.0);
    if (layer==0u) {work[probe_mask_offset(0u)+primary_index].store(MISSING);}
    var primary_position = float3(0.0); var primary_normal = float3(0.0); var primary_found = false;
    for (var i = 0u; i < p.screen.z * p.screen.z; i++) {
        let local = (offset + i) % (p.screen.z * p.screen.z); let pixel = start + uint2(local % p.screen.z, local / p.screen.z);
        if (any(pixel >= p.viewport.zw)) { continue; }
        let s = surface(pixel); if (!s.valid) { continue; }
        let scale = footprint(s, pixel);
        if (layer != 0u) {
            if (!primary_found) { primary_position = s.position; primary_normal = s.normal; primary_found = true; continue; }
            if (dot(s.normal, primary_normal) > 0.95
                && abs(dot(s.position - primary_position, primary_normal)) < max(scale * 0.02, p.cache_config.z * 4.0)) { continue; }
        }
        probes[index].position = float4(s.position, 1.0); probes[index].normal = float4(s.normal, scale);
        if (layer==0u) {work[probe_mask_offset(0u)+primary_index].store(index);}
        let lane = work[0].add(1u); work[WORK_HEADER + lane].store(index);
        probes[index].info.y = pixel.x + pixel.y * p.viewport.z;
        let uv = reproject(s.position);
        if (p.frame.y == 0u && all(uv >= float2(0.0)) && all(uv < float2(1.0))) {
            let old_tile = min(uint2(uv * float2(p.viewport.zw)) / p.screen.z, p.screen.xy - uint2(1u));
            var closest = 1e30;
            for (var old_layer = 0u; old_layer < p.scene_info.z / count; old_layer++) {
            let old_index = old_tile.x + old_tile.y * p.screen.x + old_layer * count; let old = previous_probes[old_index];
            if (old.position.w > 0.0 && dot(old.normal.xyz, s.normal) > 0.95
                && length(old.position.xyz - s.position) < scale * 1.5
                && abs(dot(old.position.xyz - s.position, s.normal)) < max(scale * 0.02, p.cache_config.z * 4.0)) {
                let distance = length(old.position.xyz - s.position);
                if (distance < closest) { probes[index].info.x = old_index; closest = distance; }
            }
            }
        }
        var retained=false;
        let old_index=probes[index].info.x;
        if(p.frame.y==0u && !probe_should_refresh(tile) && old_index!=MISSING) {
            let old=previous_probes[old_index];let clip=probe_cache_current_clip(old.position.xyz);
            if(clip.w>0.0) {
                let uv=float2(clip.x/clip.w*0.5+0.5,0.5-clip.y/clip.w*0.5);
                if(all(uv>=float2(0.0))&&all(uv<float2(1.0))) {
                    let old_pixel=min(uint2(uv*float2(p.viewport.zw)),p.viewport.zw-1u);
                    let visible=surface(old_pixel);
                    if(all(old_pixel/p.screen.z==tile) && visible.valid && dot(visible.normal,old.normal.xyz)>0.95 &&
                        length(visible.position-old.position.xyz)<max(scale*0.1,p.cache_config.z*4.0)) {
                        probes[index].position=old.position;probes[index].normal=float4(old.normal.xyz,footprint(visible,old_pixel));
                        probes[index].info.y=old_pixel.x+old_pixel.y*p.viewport.z;retained=true;
                    }
                }
            }
        }
        probes[index].info.w=select(retained,MISSING,1u);
        if(!retained) {let fresh_lane=work[27].add(1u);work[probe_fresh_list()+fresh_lane].store(index);}
        break;
    }
}
[shader("compute")][numthreads(64,1,1)]
void trace_probes(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; let directions = p.screen.w * p.screen.w;
    if (lane >= work[27].load() * directions) { return; }
    let index = compact_fresh_probe(lane / directions) * directions + lane % directions;
    let probe_index = index / directions; let probe_position = probes[probe_index].position; let normal = probes[probe_index].normal;
    rays[index].info = uint4(MISSING); rays[index].value = float4(0.0);
    rays[index].probe_bounce = float4(0.0);
    rays[index].bounce_info=uint4(MISSING);
    rays[index].position = float4(0.0); rays[index].normal = float4(0.0);
    if (probe_position.w == 0.0) { return; }
    var rng = hash32(index ^ hash32(p.frame.x));
    if(source_probe_projection()) {rng=source_random(lane,p.frame.x);}
    let packed_pixel=probes[probe_index].info.y;
    var s=surface(uint2(packed_pixel%p.viewport.z,packed_pixel/p.viewport.z));
    s.position=probe_position.xyz;
    if(source_probe_projection()) {s.geometry_normal=normal.xyz;} else {s.normal=normal.xyz;}
    let sampled=probe_sample_direction(probe_index,index%directions,s,rng);let ray=sampled.xyz;
    if(sampled.w==0.0) {return;} // Below-surface GGX samples contribute zero.
    let bin=direction_bin(normal.xyz,ray);
    let origin = probe_position.xyz + normal.xyz * p.cache_config.z;
    let hit = trace(origin, ray, p.cache_config.w);
    rays[index].direction = float4(ray, hit.distance);
    rays[index].info = uint4(MISSING, hit.triangle, bin, MISSING);
    rays[index].value.w = sampled.w;
    if (hit.triangle == MISSING) { rays[index].value = float4(source_direct_radiance(environment_radiance(ray)), sampled.w); return; }
    let n = hit_normal(hit, ray);
    if (all(n == float3(0.0))) { return; }
    let position = origin + ray * hit.distance;
    request_light_location(position);
    rays[index].position = float4(position, 1.0); rays[index].normal = float4(n, float(hit.distance < hash_cell_size(position)));
    rays[index].info.w = hash_tile_insert(position, ray, hit.distance,n);
    if(source_probe_projection()) {
        if(rays[index].info.w==MISSING) {rays[index].info.z=MISSING;return;}
        let query=source_append_visibility(index,false);
        rays[index].position.w=asfloat(query);
    }
    // GenerateReservoirs patches front-facing emissive hits directly into the
    // probe and stops transport. Testing the material emissivity, rather than
    // the sampled texel, also preserves this rule for black emission texels.
    if(source_probe_projection() && source_direct_lighting_enabled() && any(geometry[hit.triangle+7u].rgb>float3(0.0)) &&
        dot(cross(geometry[hit.triangle+1u].xyz-geometry[hit.triangle].xyz,
            geometry[hit.triangle+2u].xyz-geometry[hit.triangle].xyz),ray)<0.0) {
        rays[index].info.x=EMISSIVE_PROBE_RAY;
        rays[index].value=float4(material_emission(position,hit.triangle),sampled.w);return;
    }
    rays[index].info.x = cache_insert(position, n, hit.distance, hit.triangle, true);
}
[shader("compute")][numthreads(64,1,1)]
void trace_cache_bounces(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; if (lane >= work[1].load()) { return; }
    let slot = compact_primary(lane);
    world_cache[slot].bounce_info = uint4(MISSING, MISSING, 0u, 0u);
    if (world_cache[slot].tag.load() == 0u || world_cache[slot].primary_frame.load() != p.frame.x || p.options.y == 0u) { return; }
    let origin = world_cache[slot].position.xyz; let normal = world_cache[slot].normal.xyz;
    let triangle = uint(world_cache[slot].position.w);
    var rng = hash32(slot ^ hash32(p.frame.x + 17u));
    let direction = cosine_ray(normal, float2(random(rng), random(rng)));
    let ray_origin = offset_origin(origin, triangle, direction);
    let hit = trace(ray_origin, direction, p.cache_config.w);
    world_cache[slot].bounce_info.z = 1u;
    world_cache[slot].bounce_position.w = hit.distance;
    if (hit.triangle == MISSING) { return; }
    let n = hit_normal(hit, direction);
    world_cache[slot].bounce_info.y = hit.triangle;
    world_cache[slot].bounce_normal = float4(n, 0.0);
    let position = ray_origin + direction * hit.distance;
    world_cache[slot].bounce_position = float4(position, hit.distance);
    if (all(n == float3(0.0))) { return; }
    request_light_location(position);
    world_cache[slot].bounce_info.x = cache_insert(position, n, hit.distance, hit.triangle, false);
}
[shader("compute")][numthreads(64,1,1)]
void update_cache_direct(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; if (lane >= work[2].load()) { return; }
    let slot = compact_cell(lane);
    if (slot >= p.frame.z || world_cache[slot].tag.load() == 0u || world_cache[slot].touched.load() != p.frame.x) { return; }
    var sample_value = reservoir_radiance(slot);
    sample_value = max(sample_value - material_emission(world_cache[slot].position.xyz, uint(world_cache[slot].position.w)), float3(0.0));
    let feedback = feedback_radiance(world_cache[slot].position.xyz, world_cache[slot].normal.xyz, uint(world_cache[slot].position.w));
    if (feedback.w != 0.0) { sample_value = feedback.rgb; }
    let old = world_cache[slot].previous_direct; let count = min(old.w + 1.0, float(p.options.z));
    world_cache[slot].direct = float4(lerp(old.rgb, sample_value, 1.0 / count), count);
}
[shader("compute")][numthreads(64,1,1)]
void update_cache_indirect(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; if (lane >= work[2].load()) { return; }
    let slot = compact_cell(lane);
    let sample_value = world_cache[slot].pending_indirect;
    if (p.options.y == 0u) { world_cache[slot].indirect = float4(0.0); return; }
    if (sample_value.w == 0.0) { return; }
    let old = world_cache[slot].previous_indirect;
    let count = min(old.w + sample_value.w, float(p.options.z));
    world_cache[slot].indirect = float4(lerp(old.rgb, sample_value.rgb, sample_value.w / count), count);
    world_cache[slot].pending_indirect = float4(0.0);
}
[shader("compute")][numthreads(64,1,1)]
void resolve_cache_bounces(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; if (lane >= work[1].load()) { return; }
    let slot = compact_primary(lane);
    var incoming = float3(0.0);
    let info = world_cache[slot].bounce_info;
    if (info.z != 0u) {
        if (info.y == MISSING) { incoming = float3(0.0); } // sky is already next-event sampled at the parent
        else if (any(world_cache[slot].bounce_normal.xyz != float3(0.0))) {
            let pos = world_cache[slot].bounce_position; let n = world_cache[slot].bounce_normal.xyz;
            let selected = cache_find(pos.xyz, n, pos.w, info.y);
            if (selected == MISSING) {
                incoming = direct_radiance(pos.xyz, n, info.y, hash32(slot ^ p.frame.x));
                incoming = max(incoming - material_emission(pos.xyz, info.y), float3(0.0));
            } else { incoming = world_cache[selected].direct.rgb; }
            // Emissive next-event sampling already estimates emission on this path.
            // Only reflected direct light enters the additional scattering bounce.
        }
    }
    let albedo = material_albedo(world_cache[slot].position.xyz, uint(world_cache[slot].position.w));
    let value = safe_radiance(albedo * incoming);
    // AMD GI-1.2 resolves the second-bounce direct estimator into a pending
    // first-bounce indirect sample. Accumulation consumes it next frame.
    // A valid black sample still advances the estimator; disabled transport does not.
    world_cache[slot].pending_indirect = float4(value, float(info.z != 0u));
}
float3 cached_radiance(float3 position, float3 n, float distance, uint triangle, uint seed, uint hint, float3 direction) {
    if(source_probe_projection()) {
        var found=false;return directional_cached_radiance(position,direction,distance,found,cascades_active(),n);
    }
    let cell = hash_tile_find(position, direction, distance,n);
    if (cell != MISSING) {
        let value = hash_radiance(cell);
        if (value.w > 0.0) { hash_touch(cell); return value.rgb + material_emission(position, triangle); }
    }
    let key = cell_descriptor(position, n, distance); let token = geometry[triangle + 3u].w;
    let tag = max(1u, descriptor_tag(key) ^ hash32(uint(token)));
    var slot = hint;
    if (slot == MISSING || !cache_matches(slot, key, position, n, token, tag)) { slot = cache_find(position, n, distance, triangle); }
    if (slot != MISSING && world_cache[slot].direct.w > 0.0) {
        let emission = material_emission(position, triangle);
        let feedback = feedback_radiance(position, n, triangle);
        if (feedback.w != 0.0) { return feedback.rgb + emission; }
        return world_cache[slot].direct.rgb + world_cache[slot].indirect.rgb + emission;
    }
    // Accurate uncached direct shading, plus the same bounded extra diffuse bounce.
    var value = direct_radiance(position, n, triangle, seed);
    if (p.options.y != 0u) {
        var rng = hash32(seed); let ray = cosine_ray(n, float2(random(rng), random(rng)));
        let origin = offset_origin(position, triangle, ray); let h = trace(origin, ray, p.cache_config.w);
        var incoming = float3(0.0); // sky is already included in direct_radiance
        if (h.triangle != MISSING) {
            let hn = hit_normal(h, ray); incoming = float3(0.0);
            if (any(hn != float3(0.0))) {
                incoming = max(direct_radiance(origin + ray * h.distance, hn, h.triangle, seed + 11u)
                    - material_emission(origin + ray * h.distance, h.triangle), float3(0.0));
            }
        }
        value += material_albedo(position, triangle) * incoming;
    }
    return safe_radiance(value);
}
groupshared float4 probe_resolve_radiance[64];
groupshared float4 probe_resolve_direction[64];
groupshared float3 probe_resolve_reflected[64];
groupshared uint probe_resolve_bin[64];
groupshared float4 probe_resolve_prior[64];
groupshared uint probe_resolve_prior_bin[64];
[shader("compute")][numthreads(64,1,1)]
void resolve_probes(uint3 gid : SV_DispatchThreadID,uint local : SV_GroupIndex) {
    let lane=gid.x+gid.y*65536u;let bin=lane%PROBE_DIRECTIONS;let base=local-bin;
    let valid=lane<work[0].load()*PROBE_DIRECTIONS;
    var index=0u;var info=uint4(MISSING);var position=float4(0.0);var normal=float4(0.0);
    if(valid) {index=compact_probe(lane/PROBE_DIRECTIONS);info=probes[index].info;
        position=probes[index].position;normal=probes[index].normal;}
    probe_resolve_radiance[local]=float4(0.0);probe_resolve_direction[local]=float4(0.0);
    probe_resolve_reflected[local]=float3(0.0);probe_resolve_bin[local]=MISSING;
    probe_resolve_prior[local]=float4(0.0);probe_resolve_prior_bin[local]=MISSING;
    if(valid&&info.w!=MISSING) {
        let ray_index=index*PROBE_DIRECTIONS+bin;let r=rays[ray_index];
        if(r.info.z!=MISSING) {
            var incoming=r.value.rgb;
            if(r.info.y!=MISSING&&any(r.normal.xyz!=float3(0.0))) {
                if(r.info.x==EMISSIVE_PROBE_RAY) {
                    incoming=r.value.rgb;
                } else if(r.normal.w!=0.0&&r.info.w!=MISSING) {
                    // Source short-ray visibility flag bypasses tile filtering.
                    incoming=r.value.rgb;
                    if(!source_probe_projection()) {incoming+=material_emission(r.position.xyz,r.info.y);}
                } else {incoming=cached_radiance(r.position.xyz,r.normal.xyz,r.direction.w,r.info.y,
                    hash32(ray_index+p.frame.x),r.info.x,r.direction.xyz);}
            }
            if(source_probe_projection()) {incoming+=r.probe_bounce.rgb;}
            var reflected=incoming;
            if(r.info.y!=MISSING) {reflected=max(incoming-material_emission(r.position.xyz,r.info.y),float3(0.0));}
            probe_resolve_radiance[local]=float4(incoming,r.direction.w);
            probe_resolve_direction[local]=r.direction;probe_resolve_bin[local]=r.info.z;
            probe_resolve_reflected[local]=reflected*(r.value.w/float(PROBE_DIRECTIONS));
        }
        let prior=probe_unpack(probes[index].samples[bin]);
        if(prior.w>0.0) {probe_resolve_prior[local]=prior;probe_resolve_prior_bin[local]=bin;}
    }
    // Every lane reaches this barrier, including retained and partial segments.
    GroupMemoryBarrierWithGroupSync();
    if(!valid) {return;}
    if(info.w==MISSING) {
        if(source_probe_projection()) {return;}
        if(bin==0u) {probes[index].irradiance=previous_probes[info.x].irradiance;}
        if(bin<9u) {probes[index].sh[bin]=previous_probes[info.x].sh[bin];}
        probes[index].samples[bin]=previous_probes[info.x].samples[bin];return;
    }
    var history=1.0;if(info.x!=MISSING) {history=min(previous_probes[info.x].irradiance.w+1.0,float(p.options.z));}
    let alpha=1.0/history;
    // Coefficients and irradiance sum in the original ray order. One direction
    // per lane resolves hits and reconnects history; no per-thread probe arrays.
    if(bin<9u && !source_probe_projection()) {
        var coefficient=float3(0.0);
        for(var i=0u;i<PROBE_DIRECTIONS;i++) {
            let basis=sh_basis(probe_resolve_direction[base+i].xyz);
            coefficient+=probe_resolve_reflected[base+i]*(2.0*PI*basis[bin]);
        }
        if(info.x!=MISSING) {coefficient=lerp(probe_unpack(previous_probes[info.x].sh[bin]).rgb,coefficient,alpha);}
        probes[index].sh[bin]=probe_pack_sh(float4(coefficient,history));
    }
    if(bin==9u) {
        var estimate=float3(0.0);
        for(var i=0u;i<PROBE_DIRECTIONS;i++) {
            estimate+=probe_resolve_reflected[base+i]*(2.0*max(dot(normal.xyz,probe_resolve_direction[base+i].xyz),0.0));
        }
        if(info.x!=MISSING) {estimate=lerp(previous_probes[info.x].irradiance.rgb,estimate,alpha);}
        probes[index].irradiance=float4(safe_radiance(estimate),history);
    }
    var quantized=uint4(0u);var prior=float4(0.0);var current_count=0u;var prior_count=0u;
    var total_quantized=uint3(0u);var occupied=uint2(0u);
    for(var i=0u;i<PROBE_DIRECTIONS;i++) {
        if(probe_resolve_bin[base+i]==bin) {quantized+=probe_quantize(probe_resolve_radiance[base+i]);current_count++;}
        if(probe_resolve_prior_bin[base+i]==bin) {prior+=probe_resolve_prior[base+i];prior_count++;}
        let sampled_bin=probe_resolve_bin[base+i];
        if(sampled_bin!=MISSING) {total_quantized+=probe_quantize(probe_resolve_radiance[base+i]).xyz;occupied[sampled_bin/32u]|=1u<<(sampled_bin%32u);}
    }
    prior/=float(max(prior_count,1u));let current=probe_recover(quantized)/float(max(current_count,1u));
    let populated=countbits(occupied.x)+countbits(occupied.y);
    var result=select(current_count!=0u,current,float4(probe_empty_cell_backup(float3(total_quantized)/10000.0,populated,PROBE_DIRECTIONS),p.cache_config.w));
    if(prior_count!=0u) {result=probe_shadow_preserving_blend(result,prior);}
    probes[index].samples[bin]=probe_pack(result);
}
bool probe_connected(float3 position, float3 normal, uint2 pixel, uint packed_probe_pixel, float scale) {
    // Reject interpolation across a visible break even for coplanar surfaces.
    let probe_pixel = uint2(packed_probe_pixel % p.viewport.z, packed_probe_pixel / p.viewport.z);
    for (var step = 1u; step <= 2u; step++) {
        let mid = uint2(lerp(float2(pixel), float2(probe_pixel), float(step) / 3.0));
        let s = surface(mid);
        if (!s.valid || dot(s.normal, normal) < 0.95
            || abs(dot(s.position - position, normal)) > max(scale * 0.02, p.cache_config.z * 4.0)) { return false; }
    }
    return true;
}
[shader("compute")][numthreads(64,1,1)]
void filter_probes(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; if (lane >= work[0].load()) { return; }
    let index = compact_probe(lane);
    let count = p.screen.x * p.screen.y; let center = probes[index];
    if(source_probe_projection()) {
        probes[index].filtered_irradiance=center.irradiance;
        for(var j=0u;j<9u;j++) {probes[index].filtered_sh[j]=center.sh[j];}return;
    }
    if (center.position.w == 0.0) { return; }
    let base_index = index % count; let base = int2(int(base_index % p.screen.x), int(base_index / p.screen.x));
    let pixel = uint2(center.info.y % p.viewport.z, center.info.y / p.viewport.z);
    var sum = center.irradiance.rgb; var total = 1.0;
    var coefficients: float3[9] = {};;
    for (var j = 0u; j < 9u; j++) { coefficients[j] = probe_unpack(center.sh[j]).rgb; }
    for (var y = -2; y <= 2; y++) { for (var x = -2; x <= 2; x++) {
        let tile = base + int2(x, y);
        if (any(tile < int2(0)) || any(tile >= int2(p.screen.xy))) { continue; }
        for (var layer = 0u; layer < p.scene_info.z / count; layer++) {
            let neighbor_index = uint(tile.x) + uint(tile.y) * p.screen.x + layer * count;
            if (neighbor_index == index) { continue; }
            let position = probes[neighbor_index].position; let normal = probes[neighbor_index].normal;
            if (position.w == 0.0 || dot(center.normal.xyz, normal.xyz) < 0.95) { continue; }
            let offset = position.xyz - center.position.xyz;
            if (abs(dot(offset, center.normal.xyz)) > max(center.normal.w * 0.02, p.cache_config.z * 4.0)) { continue; }
            if (!probe_connected(center.position.xyz, center.normal.xyz, pixel, probes[neighbor_index].info.y, center.normal.w)) { continue; }
            let weight = exp(-length(offset) / max(center.normal.w, normal.w));
            sum += probes[neighbor_index].irradiance.rgb * weight; total += weight;
            for (var j = 0u; j < 9u; j++) { coefficients[j] += probe_unpack(probes[neighbor_index].sh[j]).rgb * weight; }
        }
    }}
    // Only this invocation writes filtered_irradiance; all neighbors read the
    // unfiltered estimator, so no workgroup-order dependence or blur feedback.
    probes[index].filtered_irradiance = float4(sum / total, center.irradiance.w);
    for (var j = 0u; j < 9u; j++) { probes[index].filtered_sh[j] = probe_pack_sh(float4(coefficients[j] / total, center.irradiance.w)); }
}
uint4 probe_interpolation_neighbors(Surface s,uint2 pixel,float cell_size) {
    let spawn_size=p.screen.z*(1u<<(uint(p.quality.w)>>1u));
    let samples=reflection_blue_noise(pixel,p.frame.x,1u);
    let jitter=int2((2.0*samples-1.0)*float(spawn_size));
    let new_pixel=uint2(clamp(int2(pixel)+jitter,int2(0),int2(p.viewport.zw)-1));
    let new_surface=surface(new_pixel);
    var pos=pixel;
    if(new_surface.valid && abs(dot(new_surface.position-s.position,surface_plane_normal(s)))<0.5*cell_size) {pos=new_pixel;}
    var neighbors=uint4(MISSING);
    neighbors[0]=find_closest_probe(pos,int2(0));
    if(neighbors[0]!=MISSING) {
        let packed_seed=probes[neighbors[0]].info.y;
        let seed=uint2(packed_seed%p.viewport.z,packed_seed/p.viewport.z);
        let offset=int2(select(pos.x<seed.x,-1,1),select(pos.y<seed.y,-1,1));
        neighbors[1]=find_closest_probe(pos,int2(offset.x,0));
        neighbors[2]=find_closest_probe(pos,int2(0,offset.y));
        neighbors[3]=find_closest_probe(pos,offset);
        for(var i=1u;i<4u;i++) {for(var j=0u;j<i;j++) {
            if(neighbors[i]==neighbors[j]) {neighbors[i]=MISSING;break;}
        }}
    }
    return neighbors;
}
struct ProbeInterpolation {
    var indices:uint4;
    var weights:float4;
    var hint:float;
};
ProbeInterpolation probe_interpolation_weights(Surface s,uint4 neighbors,float cell_size) {
    var weights=float4(0.0);
    if(neighbors.x==MISSING) {return ProbeInterpolation(neighbors,weights,1.0);}
    let depth=max(dot(p.camera.xyz-s.position,p.camera_direction.xyz),1e-6);
    for(var i=0u;i<4u;i++) {
        if(neighbors[i]==MISSING) {continue;}
        let probe=probes[neighbors[i]];
        let probe_depth=max(dot(p.camera.xyz-probe.position.xyz,p.camera_direction.xyz),1e-6);
        let normal=surface_plane_normal(s);
        weights[i]=probe_interpolation_weight(depth,probe_depth,dot(probe.position.xyz-s.position,normal),cell_size,dot(normal,probe.normal.xyz));
    }
    var hint=1.0;
    if(dot(weights,weights)==0.0) {
        for(var i=0u;i<4u;i++) {weights[i]=float(neighbors[i]!=MISSING);}
        hint=0.0;
    }
    return ProbeInterpolation(neighbors,weights/dot(weights,float4(1.0)),hint);
}
ProbeInterpolation source_probe_interpolation(Surface s,uint2 pixel) {
    let cell_size=select(p.camera.w!=0.0,footprint(s,pixel),length(p.camera.xyz-s.position)*p.reflection_thresholds.w);
    return probe_interpolation_weights(s,probe_interpolation_neighbors(s,pixel,cell_size),cell_size);
}
float4 source_diffuse_interpolation(Surface s,ProbeInterpolation interpolation) {
    var value=float3(0.0);
    let normal=surface_shading_normal(s);
    for(var i=0u;i<4u;i++) {
        if(interpolation.indices[i]!=MISSING) {value+=interpolation.weights[i]*probe_irradiance(interpolation.indices[i],normal);}
    }
    return float4(value,interpolation.hint);
}
float4 source_directional_interpolation(ProbeInterpolation interpolation,float3 direction) {
    var value=float3(0.0);
    for(var i=0u;i<4u;i++) {
        let index=interpolation.indices[i];if(index==MISSING) {continue;}
        let normal=probes[index].normal.xyz;
        if(dot(direction,normal)<0.0) {continue;}
        value+=interpolation.weights[i]*probe_unpack(probes[index].samples[direction_bin(normal,direction)]).rgb;
    }
    return float4(value,interpolation.hint);
}
float4 gather_diffuse(Surface s, uint2 pixel) {
#if GI_RADIANCE_CASCADES
    if(cascades_active()) {return cascade_gather_diffuse(s,pixel);}
#endif
    if(source_probe_projection()) {return source_diffuse_interpolation(s,source_probe_interpolation(s,pixel));}
    let scale=footprint(s,pixel);
    let cell_size=max(select(p.camera.w!=0.0,scale,
        length(p.camera.xyz-s.position)*p.reflection_thresholds.w),p.cache_config.z*4.0);
    let neighbors=probe_interpolation_neighbors(s,pixel,cell_size);
    var value=float3(0.0);var total=0.0;var backup=float3(0.0);var backup_count=0u;
    let cell_count=p.screen.x*p.screen.y;
    let center_depth=max(dot(p.camera.xyz-s.position,p.camera_direction.xyz),1e-6);
    for(var tap=0u;tap<4u;tap++) {
        if(neighbors[tap]==MISSING) {continue;}
        for(var layer=0u;layer<p.scene_info.z/cell_count;layer++) {
            let index=neighbors[tap]+layer*cell_count;
            let position=probes[index].position;let normal=probes[index].normal;
            if(position.w==0.0) {continue;}
            let offset=position.xyz-s.position;
            let probe_depth=max(dot(p.camera.xyz-position.xyz,p.camera_direction.xyz),1e-6);
            let irradiance=probe_irradiance(index,s.normal);
            if(layer==0u) {backup+=irradiance;backup_count++;}
            let weight=probe_interpolation_weight(center_depth,probe_depth,dot(offset,s.normal),cell_size,dot(s.normal,normal.xyz));
            value+=irradiance*weight;total+=weight;
        }
    }
    if(total>0.0) {return float4(value/total,1.0);}
    // Source relaxed backup: average the available primary probes and mark the
    // result as unreliable so adaptive reconstruction responds immediately.
    if(backup_count>0u) {return float4(backup/float(backup_count),0.0);}
    // Disoccluded/thin surfaces without a compatible probe get a real traced sample.
    var rng = hash32(pixel.x + pixel.y * p.viewport.z + hash32(p.frame.x));
    let ray = cosine_ray(s.normal, float2(random(rng), random(rng)));
    let origin = s.position + s.normal * p.cache_config.z; let h = trace(origin, ray, p.cache_config.w);
    var incoming = environment_radiance(ray);
    if (h.triangle != MISSING) {
        let n = hit_normal(h, ray); incoming = float3(0.0);
        if (any(n != float3(0.0))) {
            incoming = cached_radiance(origin + ray * h.distance, n, h.distance, h.triangle, rng, MISSING, ray);
            if(!source_probe_projection()) {incoming=max(incoming-material_emission(origin+ray*h.distance,h.triangle),float3(0.0));}
        }
    }
    return float4(incoming,0.0);
}
float smith_lambda(float cosine, float alpha) {
    let c2 = max(cosine * cosine, 1e-6); return 0.5 * (sqrt(1.0 + alpha * alpha * (1.0 - c2) / c2) - 1.0);
}
struct SpecularSample {
    var direction: float3;
    var weight: float3;
};
SpecularSample sample_specular(Surface s, uint seed) {
    var view = normalize(p.camera.xyz - s.position);
    if (p.camera.w != 0.0) { view = p.camera_direction.xyz; }
    return sample_specular_view(s, seed, view);
}
SpecularSample sample_specular_view(Surface s, uint seed, float3 view) {
    let nv = max(dot(s.normal, view), 0.0001);
    let f0 = lerp(float3(0.16 * s.reflectance * s.reflectance), s.base, s.metallic);
    if (s.roughness < 0.02) {
        let fresnel = f0 + (float3(1.0) - f0) * pow(1.0 - nv, 5.0);
        return SpecularSample(reflect(-view, s.normal), fresnel);
    }
    let alpha = max(s.roughness * s.roughness, 1e-6);
    let basis = tangent_frame(s.normal); let local_view = mul(transpose(basis), view);
    var rng = seed;
    let half_vector = ggx_bounded_normal(alpha, local_view, float2(random(rng), random(rng)));
    let local_light = reflect(-local_view, half_vector);
    return SpecularSample(mul(basis, local_light), ggx_sample_weight(alpha, local_view, local_light, f0));
}
[shader("compute")][numthreads(8, 8,1)]
void resolve_pixels(uint3 gid : SV_DispatchThreadID) {
    let pixel = gid.xy; if (any(pixel >= p.viewport.zw)) { return; }
    let coord = int2(pixel); let s = surface(pixel);
    // The otherwise-unused validity channel retains a compact material signature
    // so reflected history cannot cross a coplanar material boundary under motion.
    output_position[coord] = float4(s.position, select(s.valid, float(material_code(s)), 0.0));
    output_normal[coord] = primary_history_details(s);
    reflection_trace(pixel, s, hash32(pixel.x + pixel.y * p.viewport.z + hash32(p.frame.x)));
    if (!s.valid) {
        output_diffuse[coord] = float4(0.0); output_specular[coord] = float4(0.0); return;
    }
    // Filter irradiance before remodulating the receiver material in composition.
    let seed = hash32(pixel.x + pixel.y * p.viewport.z + hash32(p.frame.x));
    var view = normalize(p.camera.xyz - s.position); if (p.camera.w != 0.0) { view = p.camera_direction.xyz; }
    let f0 = lerp(float3(0.16 * s.reflectance * s.reflectance), s.base, s.metallic);
    var direct = Lighting(float3(0.0), float3(0.0)); var indirect = float4(0.0,0.0,0.0,1.0);
    if (s.metallic < 0.999 && !source_probe_projection() && !cascades_active()) {
        direct = light_transport(s.position, s.normal, s.position + s.normal * p.cache_config.z,
            seed + 79u, true, float3(0.0), view, s.roughness);
    }
    if (s.metallic < 0.999 || (p.options.w != 0u && s.roughness > p.reflection_filter.w)) { indirect = gather_diffuse(s, pixel); }
    let diffuse = indirect.rgb + direct.diffuse;
    let hint=select((uint(p.quality.w)&1u)!=0u,
        max(indirect.w,float(any(direct.diffuse>float3(0.0)))),1.0);
    output_diffuse[coord] = float4(safe_radiance(diffuse), hint);
    output_specular[coord] = float4(0.0);
}
float4 gather_directional(Surface s, uint2 pixel, float3 direction) {
#if GI_RADIANCE_CASCADES
    if(cascades_active()) {return cascade_gather_directional(s,pixel,direction);}
#endif
    if(source_probe_projection()) {return source_directional_interpolation(source_probe_interpolation(s,pixel),direction);}
    let base = int2(pixel / p.screen.z); let scale = footprint(s, pixel);
    var color = float3(0.0); var total = 0.0;
    for (var y = -1; y <= 1; y++) { for (var x = -1; x <= 1; x++) {
        let tile = base + int2(x, y);
        if (any(tile < int2(0)) || any(tile >= int2(p.screen.xy))) { continue; }
        for (var layer = 0u; layer < p.scene_info.z / (p.screen.x * p.screen.y); layer++) {
        let index = uint(tile.x) + uint(tile.y) * p.screen.x + layer * p.screen.x * p.screen.y;
        let position = probes[index].position; let normal = probes[index].normal;
        if (position.w == 0.0 || dot(s.normal, normal.xyz) < 0.95) { continue; }
        let offset = s.position - position.xyz;
        if (abs(dot(offset, s.normal)) > max(scale * 0.02, p.cache_config.z * 4.0)) { continue; }
        if (dot(direction, normal.xyz) <= 0.0) { continue; }
        if (!probe_connected(s.position, s.normal, pixel, probes[index].info.y, scale)) { continue; }
        let w = exp(-length(offset) / max(scale, normal.w));
        color += probe_unpack(probes[index].samples[direction_bin(normal.xyz, direction)]).rgb * w; total += w;
        }
    }}
    return float4(color / max(total, 1e-5), float(total > 1e-5));
}

bool compatible(Surface a, Surface b, float scale) {
    return b.valid && dot(surface_plane_normal(a), surface_plane_normal(b)) > 0.95
        && abs(dot(b.position - a.position, surface_plane_normal(a))) < max(scale * 0.05, p.cache_config.z * 4.0);
}
bool same_specular_material(Surface a, Surface b) {
    return abs(a.roughness - b.roughness) < 0.08 && abs(a.metallic - b.metallic) < 0.05
        && length(a.base - b.base) < 0.1 && abs(a.reflectance - b.reflectance) < 0.05;
}
[shader("compute")][numthreads(8, 8,1)]
void filter_pixels(uint3 gid : SV_DispatchThreadID) {
    let pixel=gid.xy;if (any(pixel>=p.viewport.zw)) {return;}
    let coord=int2(pixel);let s=surface(pixel);
    if (!s.valid) {
        output_diffuse[coord] = float4(0.0);output_specular[coord] = float4(0.0);
        output_position[coord] = float4(0.0);return;
    }
    var diffuse=raw_diffuse.Load(int3(coord, 0));var mean=float3(0.0);var second=float3(0.0);var total=0.0;
    let scale=footprint(s,pixel)/float(p.screen.z);
    for(var y=-2;y<=2;y++) {for(var x=-2;x<=2;x++) {
        let tap=coord+int2(x,y);if (any(tap<int2(0)) || any(tap>=int2(p.viewport.zw))) {continue;}
        if (!compatible(s,surface(uint2(tap)),scale)) {continue;}
        let weight=exp(-float(x*x+y*y)*0.35);let d=raw_diffuse.Load(int3(tap, 0)).rgb;
        mean+=d*weight;second+=d*d*weight;total+=weight;
    }}
    mean/=max(total,1e-5);second/=max(total,1e-5);
    let sigma=sqrt(max(second-mean*mean,float3(0.0)));
    var old=float4(0.0);var old_m=float2(0.0);var history_weight=0.0;let uv=reproject_surface(pixel,s.position);
    if ((p.frame.y&1u)==0u && all(uv>=float2(0.0)) && all(uv<float2(1.0))) {
        let previous_texel=uv*float2(p.viewport.zw)-0.5;let base=int2(floor(previous_texel));let fraction=frac(previous_texel);
        for(var y=0;y<2;y++) {for(var x=0;x<2;x++) {
            let tap=base+int2(x,y);if (any(tap<int2(0)) || any(tap>=int2(p.viewport.zw))) {continue;}
            let pos=previous_position.Load(int3(tap, 0));let normal=previous_normal.Load(int3(tap, 0));
            if (pos.w==0.0 || dot(primary_details_normal(s),normal.xyz)<0.95 || length(pos.xyz-s.position)>max(scale*2.0,p.cache_config.z*4.0)
                || abs(dot(pos.xyz-s.position,surface_plane_normal(s)))>max(scale*0.05,p.cache_config.z*4.0)) {continue;}
            let w=select(x==1, fraction.x, 1.0-fraction.x)*select(y==1, fraction.y, 1.0-fraction.y);
            old+=previous_diffuse.Load(int3(tap, 0))*w;old_m+=moments.Load(int3(tap, 0)).xy*w;history_weight+=w;
        }}
    }
    var m=float2(luminance(diffuse.rgb),pow(luminance(diffuse.rgb),2.0));
    if (history_weight>1e-5) {
        old/=history_weight;old_m/=history_weight;
        let margin=max(sigma*3.0,max(mean*0.15,float3(0.01)));let count=min(old.w+1.0,float(p.options.z));let alpha=1.0/max(count,1.0);
        diffuse=float4(lerp(clamp(old.rgb,mean-margin,mean+margin),diffuse.rgb,alpha),count);m=lerp(old_m,m,alpha);
    }
    var specular=float4(0.0);
    if (p.options.w!=0u) {
        let albedo=reflection_directional_albedo(s);
        if (s.roughness>p.reflection_filter.w) {specular=float4(diffuse.rgb*albedo,1.0);}
        else {let reflection=reflection_load_full(2u,pixel);specular=float4(reflection.rgb/max(reflection.w,1.0)*albedo,reflection.w);}
    }
    output_diffuse[coord] = float4(safe_radiance(diffuse.rgb),diffuse.w);
    output_specular[coord] = float4(safe_radiance(specular.rgb),specular.w);
    output_position[coord] = float4(m,0.0,0.0);
}
void atrous(uint2 pixel, int step) {
    if (any(pixel >= p.viewport.zw)) { return; }
    let coord = int2(pixel); let s = surface(pixel);
    let cd = raw_diffuse.Load(int3(coord, 0)); let cs = raw_specular.Load(int3(coord, 0));
    if (!s.valid) { output_diffuse[coord] = float4(0.0); output_specular[coord] = float4(0.0); return; }
    let m = moments.Load(int3(coord, 0));
    let scale = footprint(s, pixel) / float(p.screen.z);
    // Moment variance includes temporal noise; an early-history floor avoids
    // rejecting every sample during disocclusions and cache warm-up.
    let ds = max(sqrt(max(m.y - m.x * m.x, 0.0)) * 3.0, max(luminance(cd.rgb) * 0.35, 0.02));

    var d = float3(0.0); var dw = 0.0; 
    let kernel = float[5](1.0, 4.0, 6.0, 4.0, 1.0);
    for (var y = -2; y <= 2; y++) { for (var x = -2; x <= 2; x++) {
        let tap = coord + int2(x, y) * step;
        if (any(tap < int2(0)) || any(tap >= int2(p.viewport.zw))) { continue; }
        let ns = surface(uint2(tap)); if (!compatible(s, ns, scale)) { continue; }
        let td = raw_diffuse.Load(int3(tap, 0)); let ts = raw_specular.Load(int3(tap, 0));
        let nw = pow(max(dot(surface_plane_normal(s), surface_plane_normal(ns)), 0.0), 32.0);
        let w = kernel[uint(x + 2)] * kernel[uint(y + 2)] * nw;
        let wd = w * exp(-abs(luminance(td.rgb) - luminance(cd.rgb)) / ds);
        d += td.rgb * wd; dw += wd;

    }}
    output_diffuse[coord] = float4(safe_radiance(d / max(dw, 1e-5)), cd.w);
    output_specular[coord] = cs;
}
[shader("compute")][numthreads(8, 8,1)]
void atrous_1(uint3 gid : SV_DispatchThreadID) { atrous(gid.xy, 1); }
[shader("compute")][numthreads(8, 8,1)]
void atrous_2(uint3 gid : SV_DispatchThreadID) { atrous(gid.xy, 2); }
[shader("compute")][numthreads(8, 8,1)]
void atrous_4(uint3 gid : SV_DispatchThreadID) { atrous(gid.xy, 4); }
[shader("compute")][numthreads(8, 8,1)]
void atrous_8(uint3 gid : SV_DispatchThreadID) { atrous(gid.xy, 8); }
[shader("compute")][numthreads(64,1,1)]
void snapshot_cache(uint3 gid : SV_DispatchThreadID) {
    let lane = gid.x + gid.y * 65536u; if (lane >= work[2].load()) { return; }
    let slot = compact_cell(lane);
    world_cache[slot].previous_direct = world_cache[slot].direct;
    world_cache[slot].previous_indirect = world_cache[slot].indirect;
}


