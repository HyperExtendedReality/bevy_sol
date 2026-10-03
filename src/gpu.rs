use crate::{GiRayBackend, GiSettings, HybridGi, raytracing::RayScene, scene::GiScene};
use bevy::{
    asset::{embedded_asset, load_embedded_asset},
    camera::MainPassResolutionOverride,
    core_pipeline::{
        Core3d, Core3dSystems,
        core_3d::{main_opaque_pass_3d, main_transparent_pass_3d},
        prepass::ViewPrepassTextures,
    },
    prelude::*,
    render::{
        Render, RenderApp, RenderStartup, RenderSystems,
        camera::{ExtractedCamera, TemporalJitter},
        diagnostic::RecordDiagnostics,
        render_asset::RenderAssets,
        render_resource::*,
        renderer::{RenderContext, RenderDevice, RenderQueue, ViewQuery},
        texture::GpuImage,
        view::{ExtractedView, ViewTarget},
    },
};
use std::{borrow::Cow, num::NonZeroU32};
const MATERIAL_TEXTURE_CAPACITY: u32 = 64;
fn texture_features() -> WgpuFeatures {
    WgpuFeatures::TEXTURE_BINDING_ARRAY
        | WgpuFeatures::PARTIALLY_BOUND_BINDING_ARRAY
        | WgpuFeatures::SAMPLED_TEXTURE_AND_STORAGE_BUFFER_ARRAY_NON_UNIFORM_INDEXING
}
fn textured_shader(source: &str) -> String {
    source.replace(
        "fn material_texture(index: u32, uv: vec2<f32>) -> vec4<f32> { return vec4(1.0); }",
        include_str!("materials.wgsl"),
    )
}

const CACHE_BYTES: u64 = 256;
const RAY_BYTES: u64 = 144;
const WORK_HEADER: u64 = 24;
const BASE_STAGES: usize = 42;
const STAGES: [&str; 46] = [
    "compute_brdf_lut",
    "reset_work",
    "clear_cache",
    "clear_hash_tiles",
    "spawn_probes",
    "prepare_dispatch",
    "trace_probes",
    "compact_primary_cells",
    "prepare_dispatch",
    "trace_cache_bounces",
    "trace_hash_bounces",
    "compact_touched_cells",
    "prepare_dispatch",
    "initialize_hash_tiles",
    "generate_reservoirs",
    "update_cache_direct",
    "update_cache_indirect",
    "populate_hash_cells",
    "populate_hash_bounces",
    "update_hash_tiles",
    "resolve_hash_bounces",
    "resolve_cache_bounces",
    "resolve_probes",
    "filter_probes",
    "resolve_pixels",
    "mark_reflection_fireflies",
    "cleanup_reflection_fireflies",
    "reflection_atrous_first",
    "reflection_atrous_2",
    "reflection_atrous_4",
    "reflection_atrous_8",
    "reflection_atrous_16",
    "reflection_atrous_32",
    "reflection_atrous_64",
    "reflection_atrous_last",
    "reflection_split_x",
    "reflection_split_y",
    "reflection_no_denoiser",
    "reproject_reflections",
    "filter_pixels",
    "snapshot_reflections",
    "snapshot_cache",
    "atrous_1",
    "atrous_2",
    "atrous_4",
    "atrous_8",
];

fn probe_bytes(directions: u32) -> u64 {
    80 + u64::from(directions.pow(2)) * 16 + 9 * 16 * 2
}

fn specialized_shader(directions: u32) -> String {
    format!(
        "{}\n{}\n{}\n{}",
        include_str!("hybrid.wgsl"),
        include_str!("hash_grid.wgsl"),
        include_str!("ggx.wgsl"),
        include_str!("reflections.wgsl")
    )
    .replace(
        "const PROBE_DIRECTIONS: u32 = 64u;",
        &format!("const PROBE_DIRECTIONS: u32 = {}u;", directions.pow(2)),
    )
}

#[derive(Clone, Copy, Default, ShaderType)]
struct Params {
    world_from_clip: Mat4,
    previous_clip_from_world: Mat4,
    camera: Vec4,
    camera_direction: Vec4,
    sky: Vec4,
    viewport: UVec4,
    screen: UVec4,
    frame: UVec4,
    scene_info: UVec4,
    cache_config: Vec4,
    options: UVec4,
    quality: Vec4,
    hash_config: UVec4,
    hash_sampling: Vec4,
    reflection: UVec4,
    reflection_filter: Vec4,
    reflection_thresholds: Vec4,
}
#[derive(Clone, Copy, Default, ShaderType)]
struct CompositeParams {
    viewport: UVec4,
    multiplier: Vec4,
    camera: Vec4,
    camera_direction: Vec4,
}
#[derive(Resource)]
struct Pipelines {
    layout: BindGroupLayoutDescriptor,
    material_layout: Option<BindGroupLayoutDescriptor>,
    composite_layout: BindGroupLayoutDescriptor,
    compute: Vec<CachedComputePipelineId>,
    composite: CachedRenderPipelineId,
    hardware: bool,
    textured: bool,
}
#[derive(Resource)]
struct HybridShader {
    software: Handle<Shader>,
    hardware: Handle<Shader>,
    textured_software: Handle<Shader>,
    textured_hardware: Handle<Shader>,
}
#[derive(Resource, Default)]
struct GpuScene {
    geometry: StorageBuffer<Vec<Vec4>>,
    lights: StorageBuffer<Vec<Vec4>>,
    geometry_revision: u64,
    lighting_revision: u64,
    revision: u64,
    ready: bool,
    ray_scene: Option<RayScene>,
    texture_views: Vec<TextureView>,
    texture_samplers: Vec<Sampler>,
    fallback: Option<(TextureView, Sampler)>,
    material_group: Option<BindGroup>,
}
struct Image {
    texture: Texture,
    view: TextureView,
}
impl Image {
    fn new(device: &RenderDevice, size: UVec2, format: TextureFormat) -> Self {
        let texture = device.create_texture(&TextureDescriptor {
            label: Some("bevy_sol history"),
            size: Extent3d {
                width: size.x,
                height: size.y,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format,
            usage: TextureUsages::TEXTURE_BINDING
                | TextureUsages::STORAGE_BINDING
                | TextureUsages::COPY_SRC
                | TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = texture.create_view(&TextureViewDescriptor::default());
        Self { texture, view }
    }
    fn copy_to(&self, other: &Self, encoder: &mut CommandEncoder, size: UVec2) {
        encoder.copy_texture_to_texture(
            self.texture.as_image_copy(),
            other.texture.as_image_copy(),
            Extent3d {
                width: size.x,
                height: size.y,
                depth_or_array_layers: 1,
            },
        );
    }
}
#[derive(Component)]
struct ViewGi {
    size: UVec2,
    tiles: UVec2,
    probes_count: u32,
    frames: u32,
    last_revision: u64,
    last_reset: u64,
    previous_clip: Mat4,
    params: UniformBuffer<Params>,
    composite_params: UniformBuffer<CompositeParams>,
    probes: Buffer,
    previous_probes: Buffer,
    cache: Buffer,
    hash_tiles: Buffer,
    reflections: Buffer,
    rays: Buffer,
    work: Buffer,
    indirect: Buffer,
    raw_diffuse: Image,
    raw_specular: Image,
    diffuse: Image,
    specular: Image,
    previous_diffuse: Image,
    previous_specular: Image,
    position: Image,
    previous_position: Image,
    normal: Image,
    previous_normal: Image,
    previous_combined: Image,
    previous_exposure: f32,
    previous_intensity: f32,
    moments: Image,
    previous_moments: Image,
    spatial_diffuse: Image,
    spatial_specular: Image,
    resolve_group: Option<BindGroup>,
    filter_group: Option<BindGroup>,
    spatial_groups: Vec<BindGroup>,
    composite_group: Option<BindGroup>,
    next_clip: Mat4,
    next_revision: u64,
    next_reset: u64,
    prepared: bool,
}

pub(crate) fn install(app: &mut App) {
    embedded_asset!(app, "hybrid.wgsl");
    embedded_asset!(app, "composite.wgsl");
    let settings = app.world().resource::<GiSettings>().clone();
    let directions = settings.0.probe_directions;
    let source = specialized_shader(directions);
    let hardware_source = crate::raytracing::hardware_shader(&source);
    let mut shaders = app.world_mut().resource_mut::<Assets<Shader>>();
    let textured_software = shaders.add(Shader::from_wgsl(
        textured_shader(&source),
        "bevy_sol/textured_software.wgsl",
    ));
    let textured_hardware = shaders.add(Shader::from_wgsl(
        textured_shader(&hardware_source),
        "bevy_sol/textured_hardware.wgsl",
    ));
    let software = shaders.add(Shader::from_wgsl(source, "bevy_sol/hybrid.wgsl"));
    let hardware = shaders.add(Shader::from_wgsl(hardware_source, "bevy_sol/hardware.wgsl"));
    let Some(render) = app.get_sub_app_mut(RenderApp) else {
        return;
    };
    render.insert_resource(HybridShader {
        software,
        hardware,
        textured_software,
        textured_hardware,
    });
    render.insert_resource(settings);
    render
        .init_resource::<GpuScene>()
        .add_systems(RenderStartup, init_pipelines)
        .add_systems(
            Render,
            (prepare_scene, prepare_views)
                .chain()
                .in_set(RenderSystems::PrepareBindGroups),
        )
        .add_systems(
            Core3d,
            dispatch
                .after(main_opaque_pass_3d)
                .before(main_transparent_pass_3d)
                .in_set(Core3dSystems::MainPass),
        );
}
fn buffer_layout(binding: u32, read_only: bool, bytes: u64) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility: ShaderStages::COMPUTE,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Storage { read_only },
            has_dynamic_offset: false,
            min_binding_size: BufferSize::new(bytes),
        },
        count: None,
    }
}
fn texture_layout(binding: u32, sample_type: TextureSampleType) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility: ShaderStages::COMPUTE,
        ty: BindingType::Texture {
            sample_type,
            view_dimension: TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    }
}
fn init_pipelines(
    mut commands: Commands,
    cache: Res<PipelineCache>,
    assets: Res<AssetServer>,
    shader: Res<HybridShader>,
    device: Res<RenderDevice>,
    settings: Res<GiSettings>,
) {
    let limits = device.limits();
    let hardware = settings.0.ray_backend != GiRayBackend::Software
        && device
            .features()
            .contains(WgpuFeatures::EXPERIMENTAL_RAY_QUERY);
    let textured = device.features().contains(texture_features())
        && limits.max_binding_array_elements_per_shader_stage >= MATERIAL_TEXTURE_CAPACITY * 2
        && limits.max_binding_array_sampler_elements_per_shader_stage >= MATERIAL_TEXTURE_CAPACITY;
    if settings.0.ray_backend == GiRayBackend::Hardware && !hardware {
        warn!(
            "bevy_sol: hardware traversal requires EXPERIMENTAL_RAY_QUERY in WgpuSettings; GI disabled"
        );
        return;
    }
    if limits.max_storage_buffers_per_shader_stage < 9
        || limits.max_storage_textures_per_shader_stage < 4
        || limits.max_sampled_textures_per_shader_stage < 10
    {
        warn!("bevy_sol: device does not support the hybrid GI binding requirements");
        return;
    }
    let mut entries = vec![
        BindGroupLayoutEntry {
            binding: 0,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::Buffer {
                ty: BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: Some(Params::min_size()),
            },
            count: None,
        },
        buffer_layout(1, true, 16),
        buffer_layout(2, true, 16),
        buffer_layout(3, true, probe_bytes(settings.0.probe_directions)),
        buffer_layout(4, false, probe_bytes(settings.0.probe_directions)),
        buffer_layout(5, false, CACHE_BYTES),
        buffer_layout(6, false, RAY_BYTES),
        texture_layout(7, TextureSampleType::Depth),
        texture_layout(8, TextureSampleType::Uint),
    ];
    for binding in 9..=14 {
        entries.push(texture_layout(
            binding,
            TextureSampleType::Float { filterable: false },
        ));
    }
    for binding in 15..=18 {
        entries.push(BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::StorageTexture {
                access: StorageTextureAccess::WriteOnly,
                format: if binding == 17 {
                    TextureFormat::Rgba32Float
                } else {
                    TextureFormat::Rgba16Float
                },
                view_dimension: TextureViewDimension::D2,
            },
            count: None,
        });
    }
    entries.push(texture_layout(
        19,
        TextureSampleType::Float { filterable: false },
    ));
    entries.push(buffer_layout(20, false, WORK_HEADER * 4));
    if hardware {
        entries.push(BindGroupLayoutEntry {
            binding: 21,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::AccelerationStructure {
                vertex_return: false,
            },
            count: None,
        });
    }
    let material_layout = if textured {
        let mut image = texture_layout(0, TextureSampleType::Float { filterable: true });
        image.count = NonZeroU32::new(MATERIAL_TEXTURE_CAPACITY);
        Some(BindGroupLayoutDescriptor::new(
            "bevy_sol material textures",
            &[
                image,
                BindGroupLayoutEntry {
                    binding: 1,
                    visibility: ShaderStages::COMPUTE,
                    ty: BindingType::Sampler(SamplerBindingType::Filtering),
                    count: NonZeroU32::new(MATERIAL_TEXTURE_CAPACITY),
                },
            ],
        ))
    } else {
        None
    };
    entries.push(texture_layout(
        24,
        TextureSampleType::Float { filterable: false },
    ));
    entries.push(buffer_layout(25, false, 64));
    entries.push(buffer_layout(27, false, 16384));
    let layout = BindGroupLayoutDescriptor::new("bevy_sol hybrid", &entries);
    let shader = match (hardware, textured) {
        (false, false) => shader.software.clone(),
        (true, false) => shader.hardware.clone(),
        (false, true) => shader.textured_software.clone(),
        (true, true) => shader.textured_hardware.clone(),
    };
    let compute = STAGES
        .iter()
        .map(|&entry| {
            cache.queue_compute_pipeline(ComputePipelineDescriptor {
                label: Some(Cow::Borrowed(entry)),
                layout: std::iter::once(layout.clone())
                    .chain(material_layout.iter().cloned())
                    .collect(),
                shader: shader.clone(),
                entry_point: Some(Cow::Borrowed(entry)),
                ..default()
            })
        })
        .collect();
    let mut entries = vec![BindGroupLayoutEntry {
        binding: 0,
        visibility: ShaderStages::FRAGMENT,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: Some(CompositeParams::min_size()),
        },
        count: None,
    }];
    for binding in 1..=2 {
        let mut entry = texture_layout(binding, TextureSampleType::Float { filterable: false });
        entry.visibility = ShaderStages::FRAGMENT;
        entries.push(entry);
    }
    let mut entry = texture_layout(3, TextureSampleType::Uint);
    entry.visibility = ShaderStages::FRAGMENT;
    entries.push(entry);
    for binding in 4..=5 {
        let mut entry = texture_layout(binding, TextureSampleType::Float { filterable: false });
        entry.visibility = ShaderStages::FRAGMENT;
        entries.push(entry);
    }
    let composite_layout = BindGroupLayoutDescriptor::new("bevy_sol composite", &entries);
    let shader = load_embedded_asset!(assets.as_ref(), "composite.wgsl");
    let composite = cache.queue_render_pipeline(RenderPipelineDescriptor {
        label: Some(Cow::Borrowed("bevy_sol indirect lighting")),
        layout: vec![composite_layout.clone()],
        vertex: VertexState {
            shader: shader.clone(),
            entry_point: Some(Cow::Borrowed("vertex")),
            ..default()
        },
        fragment: Some(FragmentState {
            shader,
            entry_point: Some(Cow::Borrowed("fragment")),
            targets: vec![Some(ColorTargetState {
                format: TextureFormat::Rgba16Float,
                blend: Some(BlendState {
                    color: BlendComponent {
                        src_factor: BlendFactor::One,
                        dst_factor: BlendFactor::One,
                        operation: BlendOperation::Add,
                    },
                    alpha: BlendComponent {
                        src_factor: BlendFactor::Zero,
                        dst_factor: BlendFactor::One,
                        operation: BlendOperation::Add,
                    },
                }),
                write_mask: ColorWrites::ALL,
            })],
            ..default()
        }),
        ..default()
    });
    commands.insert_resource(Pipelines {
        layout,
        material_layout,
        composite_layout,
        compute,
        composite,
        hardware,
        textured,
    });
}
fn prepare_scene(
    scene: Res<GiScene>,
    mut gpu: ResMut<GpuScene>,
    device: Res<RenderDevice>,
    queue: Res<RenderQueue>,
    pipelines: Option<Res<Pipelines>>,
    images: Res<RenderAssets<GpuImage>>,
    cache: Res<PipelineCache>,
) {
    if gpu.revision == scene.revision && gpu.ready {
        return;
    }
    let Some(data) = scene.data.as_ref() else {
        gpu.ready = false;
        return;
    };
    let Some(pipelines) = pipelines else {
        gpu.ready = false;
        return;
    };
    if data.textures.len() > MATERIAL_TEXTURE_CAPACITY as usize
        || (!data.textures.is_empty() && !pipelines.textured)
    {
        warn_once!(
            "bevy_sol: material textures exceed capacity or require texture binding arrays; GI disabled for this scene"
        );
        gpu.ready = false;
        return;
    }
    if gpu.fallback.is_none() {
        let texture = device.create_texture(&TextureDescriptor {
            label: Some("bevy_sol unused material binding"),
            size: Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: TextureFormat::Rgba8Unorm,
            usage: TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        gpu.fallback = Some((
            texture.create_view(&TextureViewDescriptor::default()),
            device.create_sampler(&SamplerDescriptor::default()),
        ));
    }
    gpu.texture_views.clear();
    gpu.texture_samplers.clear();
    for texture in &data.textures {
        let Some(image) = images.get(texture) else {
            gpu.ready = false;
            return;
        };
        if image.texture_descriptor.dimension != TextureDimension::D2
            || image.texture_descriptor.size.depth_or_array_layers != 1
            || image
                .texture_descriptor
                .format
                .sample_type(None, Some(device.features()))
                != Some(TextureSampleType::Float { filterable: true })
        {
            warn_once!(
                "bevy_sol: secondary materials require filterable two-dimensional float textures; GI disabled"
            );
            gpu.ready = false;
            return;
        }
        gpu.texture_views.push(image.texture_view.clone());
        gpu.texture_samplers.push(image.sampler.clone());
    }
    if let Some(layout) = &pipelines.material_layout {
        let Some(fallback) = &gpu.fallback else {
            gpu.ready = false;
            return;
        };
        let views: Vec<_> = if gpu.texture_views.is_empty() {
            vec![&*fallback.0]
        } else {
            gpu.texture_views.iter().map(|v| &**v).collect()
        };
        let samplers: Vec<_> = if gpu.texture_samplers.is_empty() {
            vec![&*fallback.1]
        } else {
            gpu.texture_samplers.iter().map(|s| &**s).collect()
        };
        let group = device.create_bind_group(
            "bevy_sol secondary material textures",
            &cache.get_bind_group_layout(layout),
            &[
                BindGroupEntry {
                    binding: 0,
                    resource: BindingResource::TextureViewArray(&views),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: BindingResource::SamplerArray(&samplers),
                },
            ],
        );
        gpu.material_group = Some(group);
    }
    let limit = device.limits().max_storage_buffer_binding_size;
    if data.packed.len() as u64 * 16 > limit || scene.lights.len() as u64 * 16 > limit {
        warn_once!("bevy_sol: scene exceeds GPU storage-buffer limits");
        gpu.ready = false;
        return;
    }
    if gpu.geometry_revision != scene.geometry_revision {
        let mut packed = data.packed.clone();
        for triangle in packed[data.node_count as usize * 2..]
            .as_chunks_mut::<{ crate::scene::TRIANGLE_WORDS }>()
            .0
        {
            let normal = triangle[11].z as usize;
            if normal != 0 {
                let format = images
                    .get(&data.textures[normal - 1])
                    .map(|image| image.texture_descriptor.format);
                triangle[15].w = f32::from(format.is_some_and(|format| format.components() == 2));
            }
        }
        gpu.geometry.set(packed);
        gpu.geometry.write_buffer(&device, &queue);
        gpu.geometry_revision = scene.geometry_revision;
    }
    if gpu.lighting_revision != scene.lighting_revision {
        gpu.lights.set(scene.lights.as_ref().clone());
        gpu.lights.write_buffer(&device, &queue);
        gpu.lighting_revision = scene.lighting_revision;
    }
    gpu.revision = scene.revision;
    if pipelines.hardware
        && gpu
            .ray_scene
            .as_ref()
            .is_none_or(|rt| rt.revision != scene.shape_revision)
    {
        gpu.ray_scene = Some(RayScene::build(&device, &queue, data, scene.shape_revision));
    }
    gpu.ready = true;
}
fn storage(device: &RenderDevice, label: &'static str, size: u64) -> Buffer {
    device.create_buffer(&BufferDescriptor {
        label: Some(label),
        size,
        usage: BufferUsages::STORAGE
            | BufferUsages::COPY_SRC
            | BufferUsages::COPY_DST
            | BufferUsages::INDIRECT,
        mapped_at_creation: false,
    })
}
fn allocate_view(device: &RenderDevice, size: UVec2, settings: &GiSettings) -> Option<ViewGi> {
    let c = &settings.0;
    let tiles = UVec2::new(
        size.x.div_ceil(c.probe_spacing),
        size.y.div_ceil(c.probe_spacing),
    );
    let probes_count = tiles
        .x
        .checked_mul(tiles.y)?
        .checked_mul(if c.adaptive_probes { 2 } else { 1 })?;
    let rays_count = probes_count.checked_mul(c.probe_directions.pow(2))?;
    let limits = device.limits();
    let sizes = [
        u64::from(probes_count) * probe_bytes(c.probe_directions),
        u64::from(rays_count) * RAY_BYTES,
        u64::from(c.cache_capacity) * CACHE_BYTES,
        (WORK_HEADER + u64::from(probes_count) + 2 * u64::from(c.cache_capacity)) * 4,
        c.hash_grid.bytes(),
        c.reflection.bytes(size),
    ];
    if size.x == 0
        || size.y == 0
        || u64::from(size.x) * u64::from(size.y) > u64::from(c.max_view_pixels)
        || size.max_element() > limits.max_texture_dimension_2d
        || sizes
            .iter()
            .any(|&n| n > limits.max_storage_buffer_binding_size || n > limits.max_buffer_size)
        || limits.max_storage_buffers_per_shader_stage < 9
        || limits.max_storage_textures_per_shader_stage < 4
    {
        warn_once!(
            "bevy_sol: GI view exceeds configured capacity or GPU limits; reduce resolution/probe density/cache size"
        );
        return None;
    }
    Some(ViewGi {
        size,
        tiles,
        probes_count,
        frames: 0,
        last_revision: 0,
        last_reset: 0,
        previous_clip: Mat4::IDENTITY,
        params: UniformBuffer::default(),
        composite_params: UniformBuffer::default(),
        probes: storage(device, "bevy_sol screen probes", sizes[0]),
        previous_probes: storage(device, "bevy_sol previous probes", sizes[0]),
        cache: storage(device, "bevy_sol world cache", sizes[2]),
        hash_tiles: storage(device, "bevy_sol directional hash tiles", sizes[4]),
        reflections: storage(
            device,
            "bevy_sol reflection reconstruction and BRDF LUT",
            sizes[5],
        ),
        rays: storage(device, "bevy_sol ray work", sizes[1]),
        work: storage(device, "bevy_sol compact work and dispatch", sizes[3]),
        indirect: storage(device, "bevy_sol indirect dispatch arguments", 80),
        raw_diffuse: Image::new(device, size, TextureFormat::Rgba16Float),
        raw_specular: Image::new(device, size, TextureFormat::Rgba16Float),
        diffuse: Image::new(device, size, TextureFormat::Rgba16Float),
        specular: Image::new(device, size, TextureFormat::Rgba16Float),
        previous_diffuse: Image::new(device, size, TextureFormat::Rgba16Float),
        previous_specular: Image::new(device, size, TextureFormat::Rgba16Float),
        position: Image::new(device, size, TextureFormat::Rgba32Float),
        previous_position: Image::new(device, size, TextureFormat::Rgba32Float),
        normal: Image::new(device, size, TextureFormat::Rgba16Float),
        previous_normal: Image::new(device, size, TextureFormat::Rgba16Float),
        previous_combined: Image::new(device, size, TextureFormat::Rgba16Float),
        previous_exposure: 1.0,
        previous_intensity: 1.0,
        moments: Image::new(device, size, TextureFormat::Rgba32Float),
        previous_moments: Image::new(device, size, TextureFormat::Rgba32Float),
        spatial_diffuse: Image::new(device, size, TextureFormat::Rgba16Float),
        spatial_specular: Image::new(device, size, TextureFormat::Rgba16Float),
        resolve_group: None,
        filter_group: None,
        spatial_groups: Vec::new(),
        composite_group: None,
        next_clip: Mat4::IDENTITY,
        next_revision: 0,
        next_reset: 0,
        prepared: false,
    })
}
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
fn prepare_views(
    mut commands: Commands,
    settings: Res<GiSettings>,
    scene: Res<GiScene>,
    gpu: Res<GpuScene>,
    pipelines: Option<Res<Pipelines>>,
    cache: Res<PipelineCache>,
    device: Res<RenderDevice>,
    queue: Res<RenderQueue>,
    mut views: Query<(
        Entity,
        &ExtractedView,
        &ExtractedCamera,
        &ViewPrepassTextures,
        &HybridGi,
        &Msaa,
        Option<&mut ViewGi>,
        Option<&TemporalJitter>,
        Option<&MainPassResolutionOverride>,
    )>,
    removed: Query<Entity, (With<ViewGi>, Without<HybridGi>)>,
) {
    for entity in &removed {
        commands.entity(entity).remove::<ViewGi>();
    }
    let Some(pipelines) = pipelines else {
        return;
    };
    if !gpu.ready {
        return;
    }
    for (entity, view, camera, prepass, gi, msaa, mut state, jitter, resolution_override) in
        &mut views
    {
        if let Some(state) = state.as_mut() {
            state.prepared = false;
        }
        if resolution_override.is_some() {
            warn_once!(
                "bevy_sol: main-pass resolution overrides are not supported; GI skipped for this view"
            );
            continue;
        }
        if *msaa != Msaa::Off
            || !camera.hdr
            || view.target_format != TextureFormat::Rgba16Float
            || !gi.intensity.is_finite()
            || gi.intensity < 0.0
        {
            warn_once!(
                "bevy_sol: HybridGi requires HDR, Msaa::Off, and finite nonnegative intensity"
            );
            continue;
        }
        let (Some(_), Some(_)) = (prepass.depth_view(), prepass.deferred_view()) else {
            continue;
        };
        let size = UVec2::new(view.viewport.z, view.viewport.w);
        if state.as_ref().is_none_or(|s| s.size != size) {
            let Some(mut new) = allocate_view(&device, size, &settings) else {
                continue;
            };
            prepare_view(
                &mut new, view, camera, prepass, gi, &scene, &gpu, &pipelines, &cache, &device,
                &queue, &settings, jitter,
            );
            commands.entity(entity).insert(new);
        } else if let Some(mut state) = state {
            prepare_view(
                &mut state, view, camera, prepass, gi, &scene, &gpu, &pipelines, &cache, &device,
                &queue, &settings, jitter,
            );
        }
    }
}
#[allow(clippy::too_many_arguments)]
fn prepare_view(
    state: &mut ViewGi,
    view: &ExtractedView,
    camera: &ExtractedCamera,
    prepass: &ViewPrepassTextures,
    gi: &HybridGi,
    scene: &GiScene,
    gpu: &GpuScene,
    pipelines: &Pipelines,
    cache: &PipelineCache,
    device: &RenderDevice,
    queue: &RenderQueue,
    settings: &GiSettings,
    jitter: Option<&TemporalJitter>,
) {
    let c = &settings.0;
    let mut projection = view.clip_from_view;
    let Some(data) = scene.data.as_ref() else {
        return;
    };
    let view_from_world = view.world_from_view.to_matrix().inverse();
    let clip = if let Some(jitter) = jitter {
        jitter.jitter_projection(&mut projection, view.viewport.zw().as_vec2());
        projection * view_from_world
    } else {
        view.clip_from_world.unwrap_or(projection * view_from_world)
    };
    let reset = state.frames == 0
        || state.last_revision != scene.revision
        || state.last_reset != gi.reset
        || state.frames == u32::MAX;
    // Lighting invalidation clears estimators, not the random sequence. Repeated
    // scene edits must not freeze jitter and light samples at frame one.
    let frame = state.frames.checked_add(1).unwrap_or(1);
    state.params.set(Params {
        world_from_clip: clip.inverse(),
        previous_clip_from_world: state.previous_clip,
        camera: view
            .world_from_view
            .translation()
            .extend(f32::from(view.clip_from_view.w_axis.w == 1.0)),
        camera_direction: (-*view.world_from_view.forward())
            .extend(1.0 / state.previous_exposure.max(1e-8)),
        sky: c.sky_radiance.extend(camera.exposure),
        viewport: view.viewport,
        screen: UVec4::new(
            state.tiles.x,
            state.tiles.y,
            c.probe_spacing,
            c.probe_directions,
        ),
        frame: UVec4::new(frame, u32::from(reset), c.cache_capacity, c.direct_samples),
        scene_info: UVec4::new(
            data.node_count,
            (scene.lights.len() / 5) as u32,
            state.probes_count,
            scene
                .lights
                .iter()
                .skip(3)
                .step_by(5)
                .filter(|light| light.w == 3.0)
                .count() as u32,
        ),
        cache_config: Vec4::new(
            c.min_cell_size,
            c.cell_size_scale,
            c.ray_bias,
            c.max_ray_distance,
        ),
        options: UVec4::new(
            c.cache_lifetime,
            u32::from(c.multibounce),
            c.history_samples,
            u32::from(gi.reflections),
        ),
        quality: Vec4::new(
            c.rough_reflection_threshold,
            f32::from(c.reservoir_resampling),
            f32::from(
                c.temporal_feedback
                    && !c.multibounce
                    && gi.intensity == 1.0
                    && state.previous_intensity == 1.0,
            ),
            0.0,
        ),
        hash_config: UVec4::new(
            c.hash_grid.num_buckets,
            c.hash_grid.tiles_per_bucket,
            c.hash_grid.tile_cell_ratio,
            c.hash_grid.tiles(),
        ),
        hash_sampling: Vec4::new(
            c.hash_grid.max_sample_count,
            c.hash_grid.max_multibounce_sample_count,
            c.hash_grid.discard_multibounce_ray_probability,
            if view.clip_from_view.w_axis.w == 1.0 {
                c.cell_size_scale
            } else {
                let height = view.viewport.w as f32;
                let width = view.viewport.z as f32;
                let fov = 2.0 * (1.0 / view.clip_from_view.y_axis.y).atan();
                (fov * c.hash_grid.cell_size_pixels * (1.0 / height).max(height / (width * width)))
                    .clamp(1e-6, 1.5)
                    .tan()
            },
        ),
        reflection: UVec4::new(
            if c.reflection.half_resolution { 2 } else { 1 },
            match c.reflection.denoiser {
                crate::ReflectionDenoiser::SplitRatioEstimator => 0,
                crate::ReflectionDenoiser::AtrousRatioEstimator => 1,
                crate::ReflectionDenoiser::None => 2,
            },
            c.reflection.atrous_passes,
            u32::from(c.reflection.cleanup_fireflies),
        ),
        reflection_filter: Vec4::new(
            c.reflection.split_radius as f32,
            c.reflection.mark_fireflies_radius as f32,
            c.reflection.cleanup_fireflies_radius as f32,
            c.reflection.high_roughness_threshold,
        ),
        reflection_thresholds: Vec4::new(
            c.reflection.firefly_low_threshold,
            c.reflection.firefly_high_threshold,
            f32::from(gi.intensity == 1.0 && state.previous_intensity == 1.0),
            0.0,
        ),
    });
    state.params.write_buffer(device, queue);
    state.composite_params.set(CompositeParams {
        viewport: view.viewport,
        multiplier: Vec4::new(
            gi.intensity * camera.exposure,
            f32::from(gi.reflections),
            0.0,
            0.0,
        ),
        camera: view
            .world_from_view
            .translation()
            .extend(f32::from(view.clip_from_view.w_axis.w == 1.0)),
        camera_direction: (-*view.world_from_view.forward()).extend(0.0),
    });
    state.composite_params.write_buffer(device, queue);
    state.next_clip = clip;
    state.next_revision = scene.revision;
    state.next_reset = gi.reset;
    state.prepared = true;
    let (
        Some(params),
        Some(geometry),
        Some(lights),
        Some(depth),
        Some(gbuffer),
        Some(composite_params),
    ) = (
        state.params.binding(),
        gpu.geometry.binding(),
        gpu.lights.binding(),
        prepass.depth_view(),
        prepass.deferred_view(),
        state.composite_params.binding(),
    )
    else {
        state.prepared = false;
        return;
    };
    let group = |input_d: &Image,
                 input_s: &Image,
                 out_d: &Image,
                 out_s: &Image,
                 moment_input: &Image,
                 out_position: &Image| {
        let values = [
            params.clone(),
            geometry.clone(),
            lights.clone(),
            state.previous_probes.as_entire_binding(),
            state.probes.as_entire_binding(),
            state.cache.as_entire_binding(),
            state.rays.as_entire_binding(),
            BindingResource::TextureView(depth),
            BindingResource::TextureView(gbuffer),
            BindingResource::TextureView(&state.previous_diffuse.view),
            BindingResource::TextureView(&state.previous_specular.view),
            BindingResource::TextureView(&state.previous_position.view),
            BindingResource::TextureView(&state.previous_normal.view),
            BindingResource::TextureView(&input_d.view),
            BindingResource::TextureView(&input_s.view),
            BindingResource::TextureView(&out_d.view),
            BindingResource::TextureView(&out_s.view),
            BindingResource::TextureView(&out_position.view),
            BindingResource::TextureView(&state.normal.view),
            BindingResource::TextureView(&moment_input.view),
            state.work.as_entire_binding(),
        ];
        let mut entries: Vec<_> = values
            .into_iter()
            .enumerate()
            .map(|(binding, resource)| BindGroupEntry {
                binding: binding as u32,
                resource,
            })
            .collect();
        if let Some(rt) = &gpu.ray_scene {
            entries.push(BindGroupEntry {
                binding: 21,
                resource: BindingResource::AccelerationStructure(&rt.tlas),
            });
        }
        entries.push(BindGroupEntry {
            binding: 24,
            resource: BindingResource::TextureView(&state.previous_combined.view),
        });
        entries.push(BindGroupEntry {
            binding: 25,
            resource: state.hash_tiles.as_entire_binding(),
        });
        entries.push(BindGroupEntry {
            binding: 27,
            resource: state.reflections.as_entire_binding(),
        });
        device.create_bind_group(
            "bevy_sol compute",
            &cache.get_bind_group_layout(&pipelines.layout),
            &entries,
        )
    };
    let resolve_group = group(
        &state.previous_diffuse,
        &state.previous_specular,
        &state.raw_diffuse,
        &state.raw_specular,
        &state.previous_moments,
        &state.position,
    );
    let filter_group = group(
        &state.raw_diffuse,
        &state.raw_specular,
        &state.diffuse,
        &state.specular,
        &state.previous_moments,
        &state.moments,
    );
    let spatial_groups = vec![
        group(
            &state.diffuse,
            &state.specular,
            &state.spatial_diffuse,
            &state.spatial_specular,
            &state.moments,
            &state.position,
        ),
        group(
            &state.spatial_diffuse,
            &state.spatial_specular,
            &state.raw_diffuse,
            &state.raw_specular,
            &state.moments,
            &state.position,
        ),
        group(
            &state.raw_diffuse,
            &state.raw_specular,
            &state.spatial_diffuse,
            &state.spatial_specular,
            &state.moments,
            &state.position,
        ),
        group(
            &state.spatial_diffuse,
            &state.spatial_specular,
            &state.raw_diffuse,
            &state.raw_specular,
            &state.moments,
            &state.position,
        ),
    ];
    state.resolve_group = Some(resolve_group);
    state.filter_group = Some(filter_group);
    state.spatial_groups = spatial_groups;
    let (final_d, final_s) = match c.denoise_iterations {
        0 => (&state.diffuse, &state.specular),
        n if n % 2 == 1 => (&state.spatial_diffuse, &state.spatial_specular),
        _ => (&state.raw_diffuse, &state.raw_specular),
    };
    state.composite_group = Some(device.create_bind_group(
        "bevy_sol composite",
        &cache.get_bind_group_layout(&pipelines.composite_layout),
        &[
            BindGroupEntry {
                binding: 0,
                resource: composite_params,
            },
            BindGroupEntry {
                binding: 1,
                resource: BindingResource::TextureView(&final_d.view),
            },
            BindGroupEntry {
                binding: 2,
                resource: BindingResource::TextureView(&final_s.view),
            },
            BindGroupEntry {
                binding: 3,
                resource: BindingResource::TextureView(gbuffer),
            },
            BindGroupEntry {
                binding: 4,
                resource: BindingResource::TextureView(&state.position.view),
            },
            BindGroupEntry {
                binding: 5,
                resource: BindingResource::TextureView(&state.normal.view),
            },
        ],
    ));
}
fn dispatch(
    view: ViewQuery<(&ViewTarget, &mut ViewGi, &HybridGi, &Msaa, &ExtractedCamera)>,
    pipelines: Option<Res<Pipelines>>,
    gpu: Res<GpuScene>,
    settings: Res<GiSettings>,
    cache: Res<PipelineCache>,
    mut ctx: RenderContext,
) {
    let (target, mut state, gi, msaa, camera) = view.into_inner();
    let Some(pipelines) = pipelines else {
        return;
    };
    if !gpu.ready
        || !state.prepared
        || *msaa != Msaa::Off
        || !camera.hdr
        || !gi.intensity.is_finite()
        || gi.intensity < 0.0
    {
        return;
    }
    let Some(composite) = cache.get_render_pipeline(pipelines.composite) else {
        return;
    };
    let Some(compute) = pipelines
        .compute
        .iter()
        .map(|id| cache.get_compute_pipeline(*id))
        .collect::<Option<Vec<_>>>()
    else {
        return;
    };
    let (Some(resolve_group), Some(filter_group), Some(composite_group)) = (
        &state.resolve_group,
        &state.filter_group,
        &state.composite_group,
    ) else {
        return;
    };
    let linear = |count: u32| (count.min(65536).div_ceil(64), count.div_ceil(65536), 1);
    let pixels = (state.size.x.div_ceil(8), state.size.y.div_ceil(8), 1);
    let world = linear(settings.0.cache_capacity);
    let diagnostics = ctx.diagnostic_recorder();
    let encoder = ctx.command_encoder();
    let timing = diagnostics
        .as_ref()
        .map(|d| d.time_span(encoder, "bevy_sol"));
    for (index, pipeline) in compute.iter().enumerate() {
        if index >= BASE_STAGES + settings.0.denoise_iterations as usize {
            break;
        }
        let reflection = &settings.0.reflection;
        let stage = STAGES[index];
        let enabled = match stage {
            "compute_brdf_lut" => state.frames == 0,
            "reflection_split_x" | "reflection_split_y" => {
                reflection.denoiser == crate::ReflectionDenoiser::SplitRatioEstimator
            }
            "reflection_no_denoiser" => reflection.denoiser == crate::ReflectionDenoiser::None,
            name if name.starts_with("reflection_atrous_") => {
                let iteration = match name {
                    "reflection_atrous_2" => Some(1),
                    "reflection_atrous_4" => Some(2),
                    "reflection_atrous_8" => Some(3),
                    "reflection_atrous_16" => Some(4),
                    "reflection_atrous_32" => Some(5),
                    "reflection_atrous_64" => Some(6),
                    _ => None,
                };
                reflection.denoiser == crate::ReflectionDenoiser::AtrousRatioEstimator
                    && iteration.is_none_or(|i| i < reflection.atrous_passes - 1)
            }
            _ => true,
        };
        if !enabled {
            continue;
        }
        let stage_timing = diagnostics
            .as_ref()
            .map(|d| d.time_span(encoder, STAGES[index]));
        // Separate passes make cache allocation/direct/indirect dependencies explicit.
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
            label: Some(STAGES[index]),
            timestamp_writes: None,
        });
        pass.set_pipeline(pipeline);
        if pipelines.textured {
            let Some(group) = &gpu.material_group else {
                return;
            };
            pass.set_bind_group(1, group, &[]);
        }
        pass.set_bind_group(
            0,
            if STAGES[index] == "filter_pixels" {
                filter_group
            } else if index >= BASE_STAGES {
                &state.spatial_groups[index - BASE_STAGES]
            } else {
                resolve_group
            },
            &[],
        );
        let indirect_offset = match STAGES[index] {
            "trace_probes"
            | "populate_hash_cells"
            | "trace_hash_bounces"
            | "populate_hash_bounces"
            | "resolve_hash_bounces" => Some(32),
            "initialize_hash_tiles" | "update_hash_tiles" => Some(80),
            "trace_cache_bounces" | "resolve_cache_bounces" => Some(48),
            "generate_reservoirs"
            | "update_cache_direct"
            | "update_cache_indirect"
            | "snapshot_cache" => Some(64),
            "resolve_probes" | "filter_probes" => Some(16),
            _ => None,
        };
        if let Some(offset) = indirect_offset {
            pass.dispatch_workgroups_indirect(&state.indirect, offset - 16);
        } else {
            let (x, y, z) = match STAGES[index] {
                "compute_brdf_lut" => (4, 4, 1),
                "reset_work" | "prepare_dispatch" => (1, 1, 1),
                "clear_cache" | "compact_primary_cells" | "compact_touched_cells" => world,
                "clear_hash_tiles" => linear(settings.0.hash_grid.tiles()),
                "spawn_probes" => linear(state.probes_count),
                _ => pixels,
            };
            pass.dispatch_workgroups(x, y, z);
        }
        drop(pass);
        if STAGES[index] == "prepare_dispatch" {
            // Indirect input cannot also be a read/write storage binding in the
            // same dispatch. Copy the five argument records to a separate buffer.
            encoder.copy_buffer_to_buffer(&state.work, 16, &state.indirect, 0, 80);
        }
        if let Some(timing) = stage_timing {
            timing.end(encoder);
        }
    }
    encoder.copy_buffer_to_buffer(
        &state.probes,
        0,
        &state.previous_probes,
        0,
        u64::from(state.probes_count) * probe_bytes(settings.0.probe_directions),
    );
    state
        .diffuse
        .copy_to(&state.previous_diffuse, encoder, state.size);
    state
        .specular
        .copy_to(&state.previous_specular, encoder, state.size);
    state
        .position
        .copy_to(&state.previous_position, encoder, state.size);
    state
        .normal
        .copy_to(&state.previous_normal, encoder, state.size);
    state
        .moments
        .copy_to(&state.previous_moments, encoder, state.size);
    {
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("bevy_sol add indirect lighting"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: target.main_texture_view(),
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Load,
                    store: StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(composite);
        pass.set_bind_group(0, composite_group, &[]);
        pass.draw(0..3, 0..1);
    }
    if let Some(timing) = timing {
        timing.end(encoder);
    }
    let mut source = target.main_texture().as_image_copy();
    source.origin.x = state.params.get().viewport.x;
    source.origin.y = state.params.get().viewport.y;
    encoder.copy_texture_to_texture(
        source,
        state.previous_combined.texture.as_image_copy(),
        Extent3d {
            width: state.size.x,
            height: state.size.y,
            depth_or_array_layers: 1,
        },
    );
    state.previous_exposure = camera.exposure;
    state.previous_intensity = gi.intensity;
    state.frames = state.params.get().frame.x;
    state.previous_clip = state.next_clip;
    state.last_revision = state.next_revision;
    state.last_reset = state.next_reset;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shader_variants_validate_and_use_exact_probe_capacity() {
        for directions in [4, 8] {
            let software = specialized_shader(directions);
            let hardware = crate::raytracing::hardware_shader(&software);
            let textured = textured_shader(&software);
            let textured_hardware = textured_shader(&hardware);
            for source in [&software, &hardware, &textured, &textured_hardware] {
                let module = naga::front::wgsl::parse_str(source)
                    .unwrap_or_else(|e| panic!("{}", e.emit_to_string(source)));
                naga::valid::Validator::new(
                    naga::valid::ValidationFlags::all(),
                    naga::valid::Capabilities::all(),
                )
                .validate(&module)
                .unwrap_or_else(|e| panic!("{}", e.emit_to_string(source)));
                let probe = module
                    .types
                    .iter()
                    .find(|(_, t)| t.name.as_deref() == Some("Probe"))
                    .unwrap()
                    .1;
                let naga::TypeInner::Struct { span, .. } = probe.inner else {
                    panic!("Probe must be a struct")
                };
                assert_eq!(u64::from(span), probe_bytes(directions));
                for entry in STAGES {
                    assert!(
                        module.entry_points.iter().any(|e| e.name == entry),
                        "missing stage {entry}"
                    );
                }
            }
        }
    }
    #[test]
    fn storage_and_uniform_layouts_match_wgsl() {
        let module = naga::front::wgsl::parse_str(&specialized_shader(8)).unwrap();
        for (name, bytes) in [
            ("Probe", probe_bytes(8)),
            ("CacheEntry", CACHE_BYTES),
            ("RaySample", RAY_BYTES),
            ("Params", Params::min_size().get()),
        ] {
            let ty = module
                .types
                .iter()
                .find(|(_, ty)| ty.name.as_deref() == Some(name))
                .unwrap()
                .1;
            let naga::TypeInner::Struct { span, .. } = ty.inner else {
                panic!("expected struct")
            };
            assert_eq!(u64::from(span), bytes, "Rust/GPU buffer layout for {name}");
        }
    }
}
