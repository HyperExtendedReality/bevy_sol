@group(1) @binding(0) var material_images: binding_array<texture_2d<f32>>;
@group(1) @binding(1) var material_samplers: binding_array<sampler>;
fn material_texture(index: u32, uv: vec2<f32>) -> vec4<f32> {
    if index == 0u { return vec4(1.0); }
    return textureSampleLevel(material_images[index - 1u], material_samplers[index - 1u], uv, 0.0);
}
