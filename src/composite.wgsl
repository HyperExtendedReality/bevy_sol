struct CompositeParams {
    viewport: vec4<u32>, multiplier: vec4<f32>,
    camera: vec4<f32>, camera_direction: vec4<f32>,
}
@group(0) @binding(0) var<uniform> p: CompositeParams;
@group(0) @binding(1) var diffuse: texture_2d<f32>;
@group(0) @binding(2) var specular: texture_2d<f32>;
@group(0) @binding(3) var gbuffer: texture_2d<u32>;
@group(0) @binding(4) var surface_position: texture_2d<f32>;
@group(0) @binding(5) var surface_normal: texture_2d<f32>;
fn material_compensation(g: vec4<u32>, pixel: vec2<i32>, roughness: f32, f0: vec3<f32>) -> vec3<f32> {
    let n = normalize(textureLoad(surface_normal,pixel,0).xyz);
    let world = textureLoad(surface_position,pixel,0).xyz;
    var view = normalize(p.camera.xyz-world); if p.camera.w != 0.0 { view = p.camera_direction.xyz; }
    let smoothness = clamp(1.0-roughness,0.0,1.0); let blend = smoothness*(sqrt(smoothness)+roughness);
    let dominant = normalize(mix(n,reflect(-view,n),blend));
    let dot_hv = clamp(abs(dot(view,normalize(view+dominant))),0.0,1.0);
    let grazing = pow(1.0-dot_hv,5.0); let fresnel = f0+(vec3(1.0)-f0)*grazing;
    return (vec3(1.0)-fresnel)*1.05*(1.0-grazing);
}
@vertex
fn vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
    let uv = vec2(f32((index << 1u) & 2u), f32(index & 2u));
    return vec4(uv * 2.0 - vec2(1.0), 0.0, 1.0);
}
@fragment
fn fragment(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    let pixel = vec2<i32>(position.xy) - vec2<i32>(p.viewport.xy);
    if any(pixel < vec2(0)) || any(pixel >= vec2<i32>(p.viewport.zw)) { discard; }
    let g = textureLoad(gbuffer, vec2<i32>(position.xy), 0);
    let base = pow(unpack4x8unorm(g.x).rgb, vec3(2.2));
    let properties = unpack4x8unorm(g.z);
    var compensation = vec3(1.0);
    if p.multiplier.y != 0.0 {
        let f0 = mix(vec3(0.16 * properties.r * properties.r),base,properties.g);
        compensation = material_compensation(g,pixel,unpack4x8unorm(g.x).a,f0);
    }
    let material = base * (1.0 - properties.g) * compensation * properties.b;
    let color = textureLoad(diffuse, pixel, 0).rgb * material + textureLoad(specular, pixel, 0).rgb;
    return vec4(color * p.multiplier.x, 0.0);
}
