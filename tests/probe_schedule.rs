#![recursion_limit = "256"]
use bevy::{
    prelude::*,
    render::{
        RenderApp,
        render_resource::*,
        renderer::{RenderDevice, RenderQueue},
    },
    window::ExitCondition,
    winit::WinitPlugin,
};
use std::{borrow::Cow, time::Duration};

fn alpha_hash(values: [u32; 4]) -> u32 {
    let [x, y, z, frame] = values;
    let mut value = frame
        .wrapping_add(374_761_393)
        .wrapping_add(x.wrapping_mul(3_266_489_917));
    for component in [y, z] {
        value = value.rotate_left(17).wrapping_mul(668_265_263);
        value = value.wrapping_add(component.wrapping_mul(3_266_489_917));
    }
    value = value.rotate_left(17).wrapping_mul(668_265_263);
    value = (value ^ (value >> 15)).wrapping_mul(2_246_822_519);
    value = (value ^ (value >> 13)).wrapping_mul(3_266_489_917);
    value ^ (value >> 16)
}
fn blend_threshold(coordinates: &[u32], frame: u32) -> f32 {
    (alpha_hash([
        coordinates[0],
        coordinates[1],
        coordinates[2],
        (frame as f32).to_bits(),
    ]) >> 8) as f32
        * (1.0 / 16_777_216.0)
}

#[test]
#[ignore = "requires Vulkan and slangc"]
fn source_probe_spawn_patch_budget_reprojection_and_quantization() {
    let hardware = std::env::var("BEVY_SOL_TEST_HARDWARE").as_deref() == Ok("1");
    let mut wgpu = bevy::render::settings::WgpuSettings::default();
    if hardware {
        wgpu.features |= WgpuFeatures::EXPERIMENTAL_RAY_QUERY;
    }
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
            .set(bevy::render::RenderPlugin {
                render_creation: bevy::render::settings::RenderCreation::Automatic(Box::new(wgpu)),
                ..default()
            })
            .set(WindowPlugin {
                primary_window: None,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .disable::<bevy::log::LogPlugin>()
            .disable::<WinitPlugin>()
            .disable::<bevy::render::pipelined_rendering::PipelinedRenderingPlugin>(),
    );
    app.finish();
    app.cleanup();
    let world = app.sub_app(RenderApp).world();
    let device = world.resource::<RenderDevice>();
    let queue = world.resource::<RenderQueue>();
    let mut bindings = vec![
        0, 1, 3, 4, 5, 6, 7, 8, 11, 12, 18, 20, 25, 26, 27, 29, 30, 34,
    ];
    if hardware {
        bindings.push(21);
        bindings.sort_unstable();
    }
    let mut shader = bevy_slang::SlangCompiler::default()
        .with_source_root(concat!(env!("CARGO_MANIFEST_DIR"), "/src/shaders"))
        .compile_source(
            "probe_schedule_checks.slang",
            include_str!("probe_schedule_checks.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec![
                    format!("GI_HARDWARE={}", u32::from(hardware)),
                    "GI_TEXTURED=0".into(),
                    "GI_SOURCE_RANDOM_BUFFER=2".into(),
                    "GI_PRIMARY_GEOMETRY_NORMALS=1".into(),
                    "PROBE_DIRECTIONS=16".into(),
                ],
                ..default()
            },
        )
        .unwrap();
    bevy_slang::remap_spirv_bindings(
        &mut shader,
        &bindings
            .iter()
            .enumerate()
            .map(|(i, &binding)| bevy_slang::SpirvBindingRemap {
                group: 0,
                binding,
                mapped_binding: i as u32,
            })
            .collect::<Vec<_>>(),
    )
    .unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!()
    };
    // SAFETY: Slang validates the embedded fixture before native SPIR-V loading.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("source probe scheduling checks"),
            source: ShaderSource::SpirV(Cow::Owned(
                bytes
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|v| u32::from_le_bytes(*v))
                    .collect(),
            )),
        })
    };
    let buffer = |size, usage| {
        device.create_buffer(&BufferDescriptor {
            label: None,
            size,
            usage,
            mapped_at_creation: false,
        })
    };
    let uniform = buffer(576, BufferUsages::UNIFORM | BufferUsages::COPY_DST);
    let geometry = buffer(960, BufferUsages::STORAGE | BufferUsages::COPY_DST);
    let mut triangles = [[0.0f32; 4]; 60];
    for base in [0, 20] {
        triangles[base + 1][0] = 1.0;
        triangles[base + 2][1] = 1.0;
        let sign = if base == 0 { 1.0 } else { -1.0 };
        triangles[base + 3] = [0.0, 0.0, sign, 0.0];
        triangles[base + 4] = [0.6 * sign, 0.0, 0.8 * sign, 0.0];
        triangles[base + 5] = [0.0, 0.8 * sign, 0.6 * sign, 0.0];
        triangles[base + 9][0] = 1.0;
        triangles[base + 10][1] = 1.0;
        triangles[base + 11][2] = 1.0;
        triangles[base + 14] = [1.0, 0.0, 0.0, 1.0];
    }
    triangles[41][0] = 2.0;
    triangles[42][1] = 1.0;
    triangles[43] = [0.0, 0.0, 2.0, 0.0];
    triangles[44] = [0.3, 0.0, 1.6, 0.0];
    triangles[45] = [0.0, 0.8, 1.2, 0.0];
    let geometry_bytes: Vec<_> = triangles
        .iter()
        .flatten()
        .flat_map(|v| v.to_le_bytes())
        .collect();
    queue.write_buffer(&geometry, 0, &geometry_bytes);
    let tlas = hardware.then(|| {
        let vertices = device.create_buffer_with_data(&BufferInitDescriptor {
            label: Some("alpha fixture triangle"),
            contents: &[
                0.0f32, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
            ]
            .into_iter()
            .flat_map(f32::to_le_bytes)
            .collect::<Vec<_>>(),
            usage: BufferUsages::BLAS_INPUT,
        });
        let size = BlasTriangleGeometrySizeDescriptor {
            vertex_format: VertexFormat::Float32x3,
            vertex_count: 3,
            index_format: None,
            index_count: None,
            flags: AccelerationStructureGeometryFlags::empty(),
        };
        let blas = device.wgpu_device().create_blas(
            &CreateBlasDescriptor {
                label: None,
                flags: AccelerationStructureFlags::PREFER_FAST_TRACE,
                update_mode: AccelerationStructureUpdateMode::Build,
            },
            BlasGeometrySizeDescriptors::Triangles {
                descriptors: vec![size.clone()],
            },
        );
        let mut tlas = device.wgpu_device().create_tlas(&CreateTlasDescriptor {
            label: None,
            flags: AccelerationStructureFlags::PREFER_FAST_TRACE,
            update_mode: AccelerationStructureUpdateMode::Build,
            max_instances: 1,
        });
        tlas[0] = Some(TlasInstance::new(
            &blas,
            [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0],
            0,
            0xff,
        ));
        let mut encoder = device.create_command_encoder(&default());
        encoder.build_acceleration_structures(
            &[BlasBuildEntry {
                blas: &blas,
                geometry: BlasGeometries::TriangleGeometries(vec![BlasTriangleGeometry {
                    size: &size,
                    vertex_buffer: &vertices,
                    first_vertex: 0,
                    vertex_stride: 16,
                    index_buffer: None,
                    first_index: None,
                    transform_buffer: None,
                    transform_buffer_offset: None,
                }]),
            }],
            &[],
        );
        encoder.build_acceleration_structures(&[], [&tlas]);
        queue.submit([encoder.finish()]);
        tlas
    });
    let auxiliary = buffer(256, BufferUsages::STORAGE);
    let rays = buffer(64 * 160, BufferUsages::STORAGE);
    let hash_tiles = buffer(1024, BufferUsages::STORAGE);
    let previous = buffer(192 * 480, BufferUsages::STORAGE);
    let cache = buffer(192 * 496, BufferUsages::STORAGE);
    let probes = buffer(64 * 480, BufferUsages::STORAGE);
    let work = buffer(262144, BufferUsages::STORAGE);
    let seeds = buffer(32, BufferUsages::STORAGE | BufferUsages::COPY_DST);
    let seed_words = [
        3499211612u32,
        581869302,
        3890346734,
        3586334585,
        545404204,
        4161255391,
        3922919429,
        949333985,
    ];
    queue.write_buffer(
        &seeds,
        0,
        &seed_words
            .into_iter()
            .flat_map(u32::to_le_bytes)
            .collect::<Vec<_>>(),
    );
    let checks = buffer(6992, BufferUsages::STORAGE | BufferUsages::COPY_SRC);
    let staging = buffer(6992, BufferUsages::MAP_READ | BufferUsages::COPY_DST);
    let reflections = buffer(400000, BufferUsages::STORAGE);
    let texture = |format| {
        device.create_texture(&TextureDescriptor {
            label: None,
            size: Extent3d {
                width: 40,
                height: 24,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format,
            usage: TextureUsages::TEXTURE_BINDING
                | TextureUsages::COPY_DST
                | TextureUsages::COPY_SRC
                | if format == TextureFormat::Rgba32Float {
                    TextureUsages::STORAGE_BINDING | TextureUsages::COPY_SRC
                } else {
                    TextureUsages::empty()
                },
            view_formats: &[],
        })
    };
    let depth = texture(TextureFormat::R32Float);
    let gbuffer = texture(TextureFormat::Rgba32Uint);
    let motion = texture(TextureFormat::Rg32Float);
    let details = texture(TextureFormat::Rgba32Float);
    let details_history = texture(TextureFormat::Rgba32Float);
    let positions = texture(TextureFormat::Rgba32Float);
    let marking_depth = texture(TextureFormat::R32Float);
    let marking_gbuffer = texture(TextureFormat::Rgba32Uint);
    let upload_texture = |texture: &Texture, bytes: &[u8], stride: u32| {
        queue.write_texture(
            texture.as_image_copy(),
            bytes,
            TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(40 * stride),
                rows_per_image: Some(24),
            },
            Extent3d {
                width: 40,
                height: 24,
                depth_or_array_layers: 1,
            },
        )
    };
    upload_texture(&motion, &vec![0; 40 * 24 * 8], 8);
    upload_texture(
        &marking_depth,
        &(0..40 * 24)
            .flat_map(|i| if i % 13 == 0 { 0.0f32 } else { 0.5 }.to_le_bytes())
            .collect::<Vec<_>>(),
        4,
    );
    upload_texture(
        &marking_gbuffer,
        &(0..40 * 24)
            .flat_map(|i| {
                [
                    if i % 7 == 0 { 255u32 << 24 } else { 0 },
                    0,
                    0,
                    2048 | (2048 << 12),
                ]
            })
            .flat_map(u32::to_le_bytes)
            .collect::<Vec<_>>(),
        16,
    );
    upload_texture(
        &positions,
        &(0..40 * 24)
            .flat_map(|i| [0.0f32, 0.0, if i == 5 { -2.0 } else { -1.0 }, 0.0])
            .flat_map(f32::to_le_bytes)
            .collect::<Vec<_>>(),
        16,
    );
    let views = [
        depth.create_view(&default()),
        gbuffer.create_view(&default()),
        motion.create_view(&default()),
        details.create_view(&default()),
        details_history.create_view(&default()),
        positions.create_view(&default()),
    ];
    let layout = device.create_bind_group_layout(
        "probe scheduling",
        &bindings
            .iter()
            .copied()
            .map(|binding| BindGroupLayoutEntry {
                binding,
                visibility: ShaderStages::COMPUTE,
                ty: match binding {
                    21 => BindingType::AccelerationStructure {
                        vertex_return: false,
                    },
                    7 | 8 | 11 | 12 | 30 => BindingType::Texture {
                        sample_type: if binding == 8 {
                            TextureSampleType::Uint
                        } else {
                            TextureSampleType::Float { filterable: false }
                        },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    18 => BindingType::StorageTexture {
                        access: StorageTextureAccess::WriteOnly,
                        format: TextureFormat::Rgba32Float,
                        view_dimension: TextureViewDimension::D2,
                    },
                    _ => BindingType::Buffer {
                        ty: if binding == 0 {
                            BufferBindingType::Uniform
                        } else {
                            BufferBindingType::Storage {
                                read_only: binding == 1 || binding == 34,
                            }
                        },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                },
                count: None,
            })
            .collect::<Vec<_>>(),
    );
    let mut group_entries = vec![
        BindGroupEntry {
            binding: 0,
            resource: uniform.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 1,
            resource: geometry.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 3,
            resource: previous.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 4,
            resource: probes.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 5,
            resource: auxiliary.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 6,
            resource: rays.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 7,
            resource: BindingResource::TextureView(&views[0]),
        },
        BindGroupEntry {
            binding: 8,
            resource: BindingResource::TextureView(&views[1]),
        },
        BindGroupEntry {
            binding: 11,
            resource: BindingResource::TextureView(&views[5]),
        },
        BindGroupEntry {
            binding: 12,
            resource: BindingResource::TextureView(&views[4]),
        },
        BindGroupEntry {
            binding: 18,
            resource: BindingResource::TextureView(&views[3]),
        },
        BindGroupEntry {
            binding: 20,
            resource: work.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 25,
            resource: hash_tiles.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 26,
            resource: checks.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 27,
            resource: reflections.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 29,
            resource: cache.as_entire_binding(),
        },
        BindGroupEntry {
            binding: 30,
            resource: BindingResource::TextureView(&views[2]),
        },
        BindGroupEntry {
            binding: 34,
            resource: seeds.as_entire_binding(),
        },
    ];
    if let Some(tlas) = &tlas {
        group_entries.push(BindGroupEntry {
            binding: 21,
            resource: BindingResource::AccelerationStructure(tlas),
        });
    }
    let group = device.create_bind_group("probe scheduling", &layout, &group_entries);
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let names = [
        "seed_previous_schedule",
        "seed_primary_normal_history",
        "reset_work",
        "prepare_primary_geometry_normals",
        "reproject_screen_probes",
        "reproject_probe_history",
        "snapshot_reprojected_probes",
        "schedule_screen_probes",
        "patch_screen_probes",
        "commit_screen_probes",
        "compact_screen_probes",
        "read_schedule",
        "seed_source_sampling_checks",
        "read_source_sampling_checks",
        "seed_source_cache_merge",
        "prepare_probe_sampling",
        "read_source_cache_merge",
        "seed_source_cache_ownership",
        "reuse_cached_probes",
        "update_probe_cache",
        "scan_probe_cache_lru",
        "scan_probe_cache_blocks",
        "scatter_probe_cache_lru",
        "copy_probe_cache_lru",
        "read_source_cache_ownership",
        "seed_multibounce_bypass",
        "resolve_hash_bounces",
        "read_multibounce_bypass",
        "read_source_random_checks",
        "read_source_directional_cache",
        "read_source_interpolation",
        "read_source_query_streams",
        "read_source_hit_normals",
        "read_source_primary_input",
        "read_source_details_input",
        "read_source_details_history",
        "read_source_feedback_rules",
        "seed_source_reflection_history",
        "read_source_reflection_history",
        "seed_source_reflection_storage",
        "snapshot_reflections",
        "read_source_cleanup_rules",
        "seed_source_marking_samples",
        "mark_reflection_fireflies",
        "read_source_marking_flags",
    ];
    let pipelines: Vec<_> = names
        .iter()
        .map(|name| {
            device.create_compute_pipeline(&RawComputePipelineDescriptor {
                label: Some(name),
                layout: Some(&pipeline_layout),
                module: &module,
                entry_point: Some(name),
                compilation_options: default(),
                cache: None,
            })
        })
        .collect();
    for (size, reflection_stride) in [UVec2::ONE, UVec2::new(36, 20), UVec2::new(40, 24)]
        .into_iter()
        .flat_map(|size| [1u32, 2].map(|stride| (size, stride)))
    {
        let tiles = (size + 7) / 8;
        for mode in [0u32, 2, 4] {
            let spawn_size = 8 << (mode >> 1);
            let regions = (size + spawn_size - 1) / spawn_size;
            let budget = regions.x * regions.y;
            for frame in [0u32, 7, 255] {
                for (reset, hole, sky) in [
                    (true, u32::MAX, false),
                    (false, u32::MAX, false),
                    (false, 0, false),
                    (true, u32::MAX, true),
                ] {
                    let mut params = [0u32; 144];
                    for offset in [0, 16, 96, 112] {
                        params[offset..offset + 16]
                            .copy_from_slice(&Mat4::IDENTITY.to_cols_array().map(f32::to_bits));
                    }
                    params[35] = 1.0f32.to_bits();
                    params[38] = 1.0f32.to_bits();
                    params[44..48].copy_from_slice(&[0, 0, size.x, size.y]);
                    params[48..52].copy_from_slice(&[tiles.x, tiles.y, 8, 4]);
                    params[52..54].copy_from_slice(&[frame, u32::from(reset)]);
                    params[58] = 2 * tiles.x * tiles.y;
                    params[62] = 0.002f32.to_bits();
                    params[63] = 1000.0f32.to_bits();
                    params[67] = hole;
                    params[71] = (mode as f32).to_bits();
                    params[72..76].copy_from_slice(&[1, 1, 1, 1]);
                    params[76] = 16.0f32.to_bits();
                    params[77] = 16.0f32.to_bits();
                    params[78] = 0.5f32.to_bits();
                    params[80] = reflection_stride;
                    params[83] = 1;
                    params[85] = 3.0f32.to_bits();
                    params[87] = 0.6f32.to_bits();
                    params[88] = 0.25f32.to_bits();
                    params[89] = 0.75f32.to_bits();
                    params[91] = 1.0f32.to_bits();
                    params[139] = 1;
                    queue.write_buffer(
                        &uniform,
                        0,
                        &params
                            .iter()
                            .flat_map(|v| v.to_le_bytes())
                            .collect::<Vec<_>>(),
                    );
                    upload_texture(
                        &depth,
                        &vec![if sky { 0.0f32 } else { 0.5 }; 40 * 24]
                            .iter()
                            .flat_map(|v| v.to_le_bytes())
                            .collect::<Vec<_>>(),
                        4,
                    );
                    let normal = 2048 | (2048 << 12);
                    upload_texture(
                        &gbuffer,
                        &(0..40 * 24)
                            .flat_map(|_| [0u32, 0, 0, normal])
                            .flat_map(|v| v.to_le_bytes())
                            .collect::<Vec<_>>(),
                        16,
                    );
                    let mut encoder = device.create_command_encoder(&default());
                    for (i, pipeline) in pipelines.iter().enumerate() {
                        if names[i] == "seed_source_marking_samples" {
                            for (source, destination) in
                                [(&marking_depth, &depth), (&marking_gbuffer, &gbuffer)]
                            {
                                encoder.copy_texture_to_texture(
                                    source.as_image_copy(),
                                    destination.as_image_copy(),
                                    Extent3d {
                                        width: 40,
                                        height: 24,
                                        depth_or_array_layers: 1,
                                    },
                                );
                            }
                        }
                        if names[i] == "read_source_details_history"
                            || names[i] == "read_source_reflection_history"
                        {
                            encoder.copy_texture_to_texture(
                                details.as_image_copy(),
                                details_history.as_image_copy(),
                                Extent3d {
                                    width: 40,
                                    height: 24,
                                    depth_or_array_layers: 1,
                                },
                            );
                        }
                        let mut pass = encoder.begin_compute_pass(&default());
                        pass.set_pipeline(pipeline);
                        pass.set_bind_group(0, &group, &[]);
                        let count = if names[i] == "reproject_probe_history" {
                            tiles.x * tiles.y * 16
                        } else if names[i].contains("source_sampling") {
                            64
                        } else {
                            2 * tiles.x * tiles.y
                        };
                        if names[i] == "prepare_primary_geometry_normals" {
                            pass.dispatch_workgroups(size.x.div_ceil(8), size.y.div_ceil(8), 1);
                        } else if matches!(
                            names[i],
                            "seed_source_marking_samples" | "mark_reflection_fireflies"
                        ) {
                            let samples = (size + reflection_stride - 1) / reflection_stride;
                            pass.dispatch_workgroups(
                                samples.x.div_ceil(8),
                                samples.y.div_ceil(8),
                                1,
                            );
                        } else {
                            pass.dispatch_workgroups(count.div_ceil(64), 1, 1);
                        }
                    }
                    encoder.copy_buffer_to_buffer(&checks, 0, &staging, 0, 6992);
                    queue.submit([encoder.finish()]);
                    let (send, receive) = std::sync::mpsc::channel();
                    staging
                        .slice(..)
                        .map_async(MapMode::Read, move |r| send.send(r).unwrap());
                    device
                        .poll(PollType::Wait {
                            submission_index: None,
                            timeout: Some(Duration::from_secs(30)),
                        })
                        .unwrap();
                    receive.recv().unwrap().unwrap();
                    let data: Vec<_> = staging
                        .slice(..)
                        .get_mapped_range()
                        .as_chunks::<4>()
                        .0
                        .iter()
                        .map(|v| u32::from_le_bytes(*v))
                        .collect();
                    staging.unmap();
                    let sample_size = (size + reflection_stride - 1) / reflection_stride;
                    let phase = if reflection_stride == 2 {
                        UVec2::new(frame & 1, (frame >> 1) & 1)
                    } else {
                        UVec2::ZERO
                    };
                    for y in 0..sample_size.y {
                        for x in 0..sample_size.x {
                            let index = x + y * sample_size.x;
                            let full = UVec2::new(x, y) * reflection_stride + phase;
                            let full_index = full.x + 40 * full.y;
                            let expected = if full.cmpge(size).any()
                                || full_index.is_multiple_of(13)
                                || full_index.is_multiple_of(7)
                            {
                                false
                            } else if index.is_multiple_of(11) {
                                true
                            } else {
                                let center = index % 5;
                                let mut lower = 0;
                                let mut higher = 0;
                                let radius = 3u32.div_ceil(reflection_stride) as i32;
                                for dx in -radius..=radius {
                                    for dy in -radius..=radius {
                                        if (dx == 0 && dy == 0)
                                            || dx.abs() * reflection_stride as i32 > 3
                                            || dy.abs() * reflection_stride as i32 > 3
                                        {
                                            continue;
                                        }
                                        let tap = IVec2::new(x as i32 + dx, y as i32 + dy);
                                        if tap.cmplt(IVec2::ZERO).any()
                                            || tap.cmpge(sample_size.as_ivec2()).any()
                                        {
                                            continue;
                                        }
                                        let full = tap.as_uvec2() * reflection_stride + phase;
                                        if full.cmpge(size).any()
                                            || (full.x + 40 * full.y).is_multiple_of(7)
                                        {
                                            continue;
                                        }
                                        let value =
                                            (tap.x as u32 + tap.y as u32 * sample_size.x) % 5;
                                        lower += u32::from(value > center);
                                        higher += u32::from(value < center);
                                    }
                                }
                                lower * 4 < lower + higher || higher * 4 > 3 * (lower + higher)
                            };
                            assert_eq!(
                                data[788 + index as usize],
                                u32::from(expected),
                                "source marking {size:?}, stride {reflection_stride}, frame {frame}, ({x},{y})"
                            );
                        }
                    }
                    let sigma = 1.065_f64 * 4.0;
                    let gaussian = (-13.0 / (2.0 * sigma * sigma)).exp();
                    let scale = 4.0 / ((2.0 * std::f64::consts::PI).sqrt() * sigma);
                    for (actual, expected) in data[782..784]
                        .iter()
                        .zip([gaussian * scale * scale, gaussian])
                    {
                        assert!((f64::from(f32::from_bits(*actual)) - expected).abs() < 1e-6);
                    }
                    assert_eq!(
                        data[784..788],
                        [1, 0, 0, 0],
                        "source final positive-weight normalization"
                    );
                    for values in data[742..782].as_chunks::<4>().0 {
                        for (actual, expected) in values.iter().zip([
                            1.000_976_6_f32,
                            -0.333_007_8,
                            10.0078125,
                            7.003_906_3,
                        ]) {
                            assert_eq!(
                                *actual,
                                expected.to_bits(),
                                "reconstruction/history FP16 storage"
                            );
                        }
                    }
                    assert!(
                        f32::from_bits(data[727]).is_nan(),
                        "trace defers NaN cleanup"
                    );
                    for (index, expected) in [
                        (726, 0.666_503_9_f32),
                        (728, 0.799_804_7),
                        (729, 65504.0),
                        (730, 1.000_976_6),
                        (731, -0.333_007_8),
                        (732, 10.0078125),
                        (733, 1.0),
                        (734, 0.123_474_12),
                        (735, 0.234_619_14),
                        (736, 0.345_703_13),
                        (737, -1.0),
                        (738, 1.0006),
                        (739, -0.333),
                        (740, 10.004),
                        (741, 1.0),
                    ] {
                        assert_eq!(
                            data[index],
                            expected.to_bits(),
                            "reflection storage {index}"
                        );
                    }
                    assert_eq!(data[719..723], [1, 0, 1, 1]);
                    assert_eq!(
                        data[723..726],
                        [
                            65504.0f32.to_bits(),
                            (-1.0f32).to_bits(),
                            (-1.0f32).to_bits()
                        ]
                    );
                    for (actual, expected) in data[715..719].iter().zip([2.0, 0.0, 4.0, 7.0]) {
                        assert!(
                            (f32::from_bits(*actual) - expected).abs() < 1e-5,
                            "source temporal sanitization preserves finite channels and count"
                        );
                    }
                    assert_eq!(
                        data[700..702],
                        [3, 2],
                        "cleanup radius uses source sample units"
                    );
                    for (actual, expected) in data[702..712].iter().zip([
                        (-13.0f32 / 16.0).exp(),
                        (-52.0f32 / 16.0).exp(),
                        0.5005 / 1.0005,
                        0.2505 / 1.0005,
                        0.75 / 1.0005,
                        0.0,
                        0.5,
                        0.25,
                        0.75,
                        2.0,
                    ]) {
                        assert!(
                            (f32::from_bits(*actual) - expected).abs() < 1e-5,
                            "source cleanup: {} vs {expected}",
                            f32::from_bits(*actual)
                        );
                    }
                    if size.x >= 8 && size.y >= 3 {
                        for (actual, expected) in
                            data[694..700].iter().zip([4.8, 4.0, 9.0, 4.0, 1.0, 0.0])
                        {
                            assert!(
                                (f32::from_bits(*actual) - expected).abs() < 1e-5,
                                "source reflection gather: {} vs {expected}",
                                f32::from_bits(*actual)
                            );
                        }
                    }
                    assert!(
                        data[1] <= budget,
                        "spawn budget: {size:?} mode={mode} frame={frame}"
                    );
                    assert_eq!(data[4], if sky { 0 } else { budget });
                    if reset {
                        assert_eq!(data[0], if sky { 0 } else { budget });
                    } else if hole == u32::MAX {
                        assert_eq!(data[0], tiles.x * tiles.y);
                        assert_eq!(data[3], budget);
                    } else {
                        assert!(data[0] >= tiles.x * tiles.y - 1);
                    }
                    let records = data[32..32 + 4 * (tiles.x * tiles.y) as usize]
                        .as_chunks::<4>()
                        .0;
                    assert_eq!(records.iter().map(|v| v[0]).sum::<u32>(), data[0]);
                    assert_eq!(
                        records
                            .iter()
                            .filter(|v| v[0] == 1)
                            .map(|v| v[1])
                            .sum::<u32>(),
                        data[1]
                    );
                    for (index, record) in records.iter().enumerate().filter(|(_, v)| v[0] != 0) {
                        let pixel = UVec2::new(record[2] % size.x, record[2] / size.x);
                        assert!(pixel.cmplt(size).all());
                        assert_eq!((pixel.x / 8 + pixel.y / 8 * tiles.x) as usize, index);
                    }
                    assert_eq!(data[8..12], [2, 12346, 23456, 173457]);
                    // Independent normal-incidence matte dielectric BRDF / cosine PDF.
                    let bounce = 0.5 * (1.0 - 0.04) * 1.05 + 0.04 / 4.0;
                    assert!((f32::from_bits(data[16]) - bounce).abs() < 0.001);
                    assert!((f32::from_bits(data[17]) - bounce / 0.3).abs() < 0.003);
                    assert_eq!(f32::from_bits(data[18]), 0.0);
                    let expected = [
                        8.0 - 7.0 * 0.5625,
                        8.0 - 7.0 * 0.5625,
                        8.0 - 7.0 * 0.5625,
                        10.0 - 8.0 * 0.5625,
                    ];
                    for (actual, expected) in data[12..16].iter().zip(expected) {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-5);
                    }
                    assert!(
                        data[256..320].iter().all(|v| f32::from_bits(*v) > 0.99),
                        "source full GGX layer probability"
                    );
                    assert!(
                        data[320..384].iter().all(|v| *v == 3),
                        "source diffuse CDF has no added uniform mixture"
                    );
                    assert!(
                        data[384..448].iter().all(|v| f32::from_bits(*v) == 1.0),
                        "source atlas reconstruction stores incident radiance"
                    );
                    assert!(
                        data[448..464]
                            .iter()
                            .all(|v| f32::from_bits(*v)
                                == if tiles.x * tiles.y > 1 { 8.0 } else { 6.0 }),
                        "source cache merge includes every scattered candidate, including the claimed nearest history"
                    );
                    match frame {
                        0 => {
                            assert_eq!(data[470], 0, "cold fresh probes are not cached");
                            assert_eq!(data[472..474], [0, 0]);
                            assert_eq!(data[476..478], [u32::MAX, u32::MAX]);
                        }
                        7 => {
                            assert_eq!(
                                data[680], 0x2010_0000,
                                "eviction packs the old geometry normal"
                            );
                            assert_eq!(data[470..473], [1, 0, 1]);
                            assert_eq!(data[473], u32::from(mode != 0));
                            assert_eq!(
                                f32::from_bits(data[474]),
                                17.0,
                                "evict the old atlas, not the fresh one"
                            );
                            assert_eq!(data[476], if mode == 4 { 0 } else { u32::MAX });
                            assert_eq!(data[477], if mode == 0 { 0 } else { 0x80000000 });
                        }
                        255 => {
                            assert_eq!(
                                data[680], 0x1ff0_0000,
                                "radiance updates preserve packed metadata"
                            );
                            assert_eq!(data[470..474], [1, 1, 0, 0]);
                            assert_eq!(f32::from_bits(data[474]), 9.0);
                            assert!(
                                (f32::from_bits(data[475]) - 0.01).abs() < 1e-6,
                                "updates preserve the cached surface position"
                            );
                            assert_eq!(data[476..478], [0, u32::MAX]);
                        }
                        _ => unreachable!(),
                    }
                    let cache_count = tiles.x * tiles.y;
                    assert_eq!(data[478], u32::from(frame == 7 && cache_count > 1));
                    assert_eq!(data[479], if frame == 7 { 0 } else { cache_count - 1 });
                    assert!(data[480..488].iter().all(|v| f32::from_bits(*v) == 0.125));
                    assert!(data[488..496].iter().all(|v| f32::from_bits(*v) == 0.0));
                    assert_eq!(
                        data[496..498],
                        [16, 2000],
                        "bypass still accumulates into the indirect cache"
                    );
                    let seeds = [3499211612u32, 581869302, 3890346734, 3586334585];
                    for (lane, seed) in seeds.into_iter().enumerate() {
                        let output = |state: u32| {
                            let word =
                                ((state >> ((state >> 28) + 4)) ^ state).wrapping_mul(277803737);
                            (word >> 22) ^ word
                        };
                        let increment = (frame << 1) | 1;
                        let state = seed
                            .wrapping_add(increment)
                            .wrapping_mul(747796405)
                            .wrapping_add(increment);
                        assert_eq!(data[498 + lane], output(state));
                        assert_eq!(
                            data[502 + lane],
                            output(state),
                            "seed-table modulo addressing"
                        );
                        assert_eq!(
                            data[506 + lane],
                            output(seed.wrapping_mul(747796405).wrapping_add(2891336453))
                        );
                    }
                    assert_eq!(
                        data[512],
                        u32::MAX,
                        "source does not allocate auxiliary cells"
                    );
                    assert_eq!(data[513], 123, "source leaves auxiliary cells untouched");
                    assert_eq!(
                        data[514..518],
                        [0; 4],
                        "missing directional cache stays black"
                    );
                    assert_eq!(
                        data[518..522],
                        [1.0f32.to_bits(), 2.0f32.to_bits(), 3.0f32.to_bits(), 1]
                    );
                    assert_eq!(
                        data[522..526],
                        [0, 0, 0, 1],
                        "empty live cache is a valid black result"
                    );
                    assert!(data[528..532].iter().all(|v| f32::from_bits(*v) == 0.25));
                    assert_eq!(
                        data[532..536],
                        [
                            2.5f32.to_bits(),
                            2.5f32.to_bits(),
                            2.5f32.to_bits(),
                            1.0f32.to_bits()
                        ]
                    );
                    assert_eq!(data[536], 0, "relaxed interpolation marks low confidence");
                    assert_eq!(
                        data[537..541],
                        [2.5f32.to_bits(), 2.5f32.to_bits(), 2.5f32.to_bits(), 0]
                    );
                    assert_eq!(
                        data[541..545],
                        [1.5f32.to_bits(), 1.5f32.to_bits(), 1.5f32.to_bits(), 0]
                    );
                    assert_eq!(
                        data[545..549],
                        [0, 0, 0, 1.0f32.to_bits()],
                        "missing probes retain the source black/confident result"
                    );
                    assert_eq!(data[549..553], [0, 0, 0, 1.0f32.to_bits()]);
                    for (actual, expected) in
                        data[553..557]
                            .iter()
                            .zip([256.0 / 258.0, 1.0 / 258.0, 1.0 / 258.0, 0.0])
                    {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                    }
                    assert_eq!(data[560..563], [16, 8, 12]);
                    let mut first_ids = Vec::new();
                    let mut bounce_ids = Vec::new();
                    let mut shadow_ids = Vec::new();
                    for lane in 0..16 {
                        let record = &data[564 + 4 * lane..568 + 4 * lane];
                        first_ids.push(record[0]);
                        if lane % 2 == 0 {
                            assert!(record[1] < 8);
                            shadow_ids.push(record[1]);
                        } else {
                            assert_eq!(record[1], u32::MAX);
                        }
                        if lane < 8 {
                            bounce_ids.push(record[2]);
                            if lane % 2 == 1 {
                                assert!((8..12).contains(&record[3]));
                                shadow_ids.push(record[3]);
                            } else {
                                assert_eq!(record[3], u32::MAX);
                            }
                        } else {
                            assert_eq!(record[2..4], [u32::MAX; 2]);
                        }
                    }
                    first_ids.sort_unstable();
                    bounce_ids.sort_unstable();
                    shadow_ids.sort_unstable();
                    assert_eq!(first_ids, (0..16).collect::<Vec<_>>());
                    assert_eq!(bounce_ids, (16..24).collect::<Vec<_>>());
                    assert_eq!(shadow_ids, (0..12).collect::<Vec<_>>());
                    let expected = Vec3::new(0.15, 0.4, 0.75).normalize();
                    assert_eq!(data[685], 0xe000_0200);
                    assert_eq!(data[686..693], [1, 0, 0, 0, 1, 0, 0]);
                    assert_eq!(f32::from_bits(data[693]), 10.0);
                    let snorm = expected.map(|v| (v * 511.0).round());
                    let snorm_bits =
                        snorm.x as u32 | ((snorm.y as u32) << 10) | ((snorm.z as u32) << 20);
                    assert_eq!(data[681], snorm_bits);
                    for (actual, expected) in data[682..685]
                        .iter()
                        .zip((snorm / 511.0).normalize().to_array())
                    {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                    }
                    let scaled = Vec3::new(0.075, 0.4, 1.5).normalize();
                    assert_eq!(data[644..648], [0, 0, 1.0f32.to_bits(), 1.0f32.to_bits()]);
                    assert_eq!(f32::from_bits(data[650]), -1.0);
                    assert_eq!(f32::from_bits(data[651]), 1.0);
                    assert_eq!(data[655], 0);
                    assert_eq!(data[656] >> 30, if sky { 0 } else { 3 });
                    assert_eq!(data[657], 0xe008_03ff);
                    let geometry_normal = Vec3::new(1.0, 1.0 / 1023.0, 1.0 / 1023.0).normalize();
                    if !sky {
                        for (actual, expected) in
                            data[658..661].iter().zip(geometry_normal.to_array())
                        {
                            assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                        }
                        assert!(f32::from_bits(data[661]) > 0.99);
                    }
                    assert_eq!(data[662..666], [0.25f32.to_bits(); 4]);
                    assert_eq!(data[666], 1.0f32.to_bits());
                    let decode_details = |normal: Vec3| {
                        normal.map(|v| ((v * 0.5 + 0.5) * 1023.0).round() / 1023.0 * 2.0 - 1.0)
                    };
                    let shading = decode_details(expected).normalize();
                    for (actual, expected) in data[712..715].iter().zip(shading.to_array()) {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                    }
                    assert!(
                        (shading - expected).length() > 1e-4,
                        "fixture must distinguish Bevy and RGB10 shading normals"
                    );
                    let x_details = decode_details(Vec3::X);
                    let y_details = decode_details(Vec3::Y);
                    for (actual, expected) in data[667..670].iter().zip([
                        x_details.dot(y_details).powi(4),
                        x_details.dot(x_details).powi(4),
                        1.0,
                    ]) {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                    }
                    assert!(
                        f32::from_bits(data[668]) > 1.0,
                        "details normals must not be renormalized"
                    );
                    for (actual, expected) in data[670..676].iter().zip(
                        x_details
                            .to_array()
                            .into_iter()
                            .chain(decode_details(expected).to_array()),
                    ) {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                    }
                    for (actual, expected) in data[676..680]
                        .iter()
                        .zip(decode_details(expected).extend(0.5).to_array())
                    {
                        assert!(
                            (f32::from_bits(*actual) - expected).abs() < 1e-6,
                            "details history must preserve RGB10 decode precision"
                        );
                    }
                    for (actual, expected) in data[652..655].iter().zip(expected.to_array()) {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                    }
                    for (actual, expected) in data[640..643].iter().zip(scaled.to_array()) {
                        assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                    }
                    for (record, normal) in data[628..640]
                        .as_chunks::<4>()
                        .0
                        .iter()
                        .zip([expected, -expected, -expected])
                    {
                        for (actual, expected) in record[..3].iter().zip(normal.to_array()) {
                            assert!((f32::from_bits(*actual) - expected).abs() < 1e-6);
                        }
                    }
                }
            }
        }
    }
    let candidate_names = [
        "seed_source_candidate_projection",
        "prepare_probe_cache",
        "project_probe_cache",
        "scan_source_candidates",
        "scan_source_candidate_blocks",
        "scatter_source_candidates",
        "read_source_candidate_projection",
    ];
    let mut params = [0u32; 144];
    params[44..48].copy_from_slice(&[0, 0, 130, 68]);
    params[48..52].copy_from_slice(&[17, 9, 8, 4]);
    params[58] = 153;
    params[139] = 1;
    queue.write_buffer(
        &uniform,
        0,
        &params
            .into_iter()
            .flat_map(u32::to_le_bytes)
            .collect::<Vec<_>>(),
    );
    let mut encoder = device.create_command_encoder(&default());
    for name in candidate_names {
        let pipeline = device.create_compute_pipeline(&RawComputePipelineDescriptor {
            label: Some(name),
            layout: Some(&pipeline_layout),
            module: &module,
            entry_point: Some(name),
            compilation_options: default(),
            cache: None,
        });
        let mut pass = encoder.begin_compute_pass(&default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        let groups = match name {
            "scan_source_candidates" => 2,
            "scan_source_candidate_blocks" => 1,
            _ => 3,
        };
        pass.dispatch_workgroups(groups, 1, 1);
    }
    encoder.copy_buffer_to_buffer(&checks, 0, &staging, 0, 2776);
    queue.submit([encoder.finish()]);
    let (send, receive) = std::sync::mpsc::channel();
    staging
        .slice(..)
        .map_async(MapMode::Read, move |r| send.send(r).unwrap());
    device
        .poll(PollType::Wait {
            submission_index: None,
            timeout: Some(Duration::from_secs(30)),
        })
        .unwrap();
    receive.recv().unwrap().unwrap();
    let data: Vec<_> = staging
        .slice(..)
        .get_mapped_range()
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| u32::from_le_bytes(*v))
        .collect();
    staging.unmap();
    assert_eq!(data[0], 145);
    let mut expected = vec![Vec::new(); 153];
    for slot in 8..153u32 {
        let tile = if slot == 8 {
            16
        } else if slot % 2 == 0 {
            128
        } else {
            slot
        };
        expected[tile as usize].push(slot);
    }
    let mut prefix = 0;
    for (tile, slots) in expected.iter_mut().enumerate() {
        assert_eq!(data[1 + 3 * tile], slots.len() as u32);
        assert_eq!(data[2 + 3 * tile], prefix as u32);
        let mut actual: Vec<_> = (prefix..prefix + slots.len())
            .map(|i| data[3 + 3 * i])
            .collect();
        actual.sort_unstable();
        slots.sort_unstable();
        assert_eq!(&actual, slots);
        prefix += slots.len();
    }
    triangles[12] = [0.75, 0.5, -1.0, 0.0];
    triangles[13] = [0.2, 0.4, 0.8, 1.0];
    queue.write_buffer(
        &geometry,
        0,
        &triangles
            .iter()
            .flatten()
            .flat_map(|v| v.to_le_bytes())
            .collect::<Vec<_>>(),
    );
    let composition = device.create_compute_pipeline(&RawComputePipelineDescriptor {
        label: Some("source primary composition option"),
        layout: Some(&pipeline_layout),
        module: &module,
        entry_point: Some("read_source_composition_output"),
        compilation_options: default(),
        cache: None,
    });
    for flags in 0..8u32 {
        params[139] = flags;
        queue.write_buffer(
            &uniform,
            0,
            &params
                .into_iter()
                .flat_map(u32::to_le_bytes)
                .collect::<Vec<_>>(),
        );
        let mut encoder = device.create_command_encoder(&default());
        {
            let mut pass = encoder.begin_compute_pass(&default());
            pass.set_pipeline(&composition);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        encoder.copy_buffer_to_buffer(&checks, 0, &staging, 0, 52);
        queue.submit([encoder.finish()]);
        let (send, receive) = std::sync::mpsc::channel();
        staging
            .slice(..)
            .map_async(MapMode::Read, move |r| send.send(r).unwrap());
        device
            .poll(PollType::Wait {
                submission_index: None,
                timeout: Some(Duration::from_secs(30)),
            })
            .unwrap();
        receive.recv().unwrap().unwrap();
        let data: Vec<_> = staging
            .slice(..)
            .get_mapped_range()
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v))
            .collect();
        staging.unmap();
        let disabled = flags & 5 == 5;
        let diffuse = if disabled { [0.3; 3] } else { [0.05, 0.1, 0.2] };
        let f0 = if disabled {
            [0.0; 3]
        } else {
            [0.16, 0.31, 0.61]
        };
        let specular = f0.map(|v| v * 0.75 + (1.0 - v) * 0.125);
        for (actual, expected) in data[..12].iter().zip(
            diffuse
                .into_iter()
                .chain(f0)
                .chain(specular)
                .chain([0.048, 0.096, 0.192]),
        ) {
            assert!(
                (f32::from_bits(*actual) - expected).abs() < 1e-6,
                "source composition option flags {flags}: {} != {expected}",
                f32::from_bits(*actual)
            );
        }
        assert_eq!(data[12], u32::from(disabled));
    }
    let alpha_pipeline = device.create_compute_pipeline(&RawComputePipelineDescriptor {
        label: Some("source alpha closest and shadow traversal"),
        layout: Some(&pipeline_layout),
        module: &module,
        entry_point: Some("read_source_alpha_traversal"),
        compilation_options: default(),
        cache: None,
    });
    params[56] = 1;
    params[62] = 0.001f32.to_bits();
    triangles.fill([0.0; 4]);
    triangles[0] = [-0.001, -0.001, -0.001, 2.0];
    triangles[1] = [1.001, 1.001, 0.001, 1.0];
    triangles[3][0] = 1.0;
    triangles[4][1] = 1.0;
    triangles[9] = [2.0, 4.0, 8.0, 0.0];
    triangles[18] = [10.0, 20.0, 30.0, 0.0];
    triangles[19] = [15.0, 10.0, 5.0, 0.0];
    triangles[20] = [-5.0, 5.0, 15.0, 0.0];
    for flags in 0..16u32 {
        params[139] = flags;
        for double_sided in [false, true] {
            triangles[8][3] = f32::from(double_sided);
            for (alpha_type, cutoff) in [
                (0u32, -1.0f32),
                (1, -1.0),
                (1, 0.25),
                (1, 0.5),
                (1, 0.75),
                (1, f32::NAN),
                (2, -1.0),
            ] {
                triangles[14][2] = cutoff;
                triangles[14][3] = (alpha_type << 4) as f32;
                let frames: &[u32] = if alpha_type == 2 {
                    &[0, 1, 17, 16_777_216, 16_777_217, u32::MAX]
                } else {
                    &[0]
                };
                for &frame in frames {
                    params[52] = frame;
                    queue.write_buffer(
                        &uniform,
                        0,
                        &params
                            .into_iter()
                            .flat_map(u32::to_le_bytes)
                            .collect::<Vec<_>>(),
                    );
                    let threshold = blend_threshold(
                        &[8.0f32.to_bits(), 15.0f32.to_bits(), 22.0f32.to_bits()],
                        frame,
                    );
                    let mut alphas = vec![0.0f32, 0.49, 0.5, 0.51, 1.0];
                    if alpha_type == 2 {
                        alphas.extend([threshold, f32::from_bits(threshold.to_bits() + 1)]);
                    }
                    for alpha in alphas {
                        triangles[15][3] = alpha;
                        queue.write_buffer(
                            &geometry,
                            0,
                            &triangles
                                .iter()
                                .flatten()
                                .flat_map(|v| v.to_le_bytes())
                                .collect::<Vec<_>>(),
                        );
                        let mut encoder = device.create_command_encoder(&default());
                        {
                            let mut pass = encoder.begin_compute_pass(&default());
                            pass.set_pipeline(&alpha_pipeline);
                            pass.set_bind_group(0, &group, &[]);
                            pass.dispatch_workgroups(1, 1, 1);
                        }
                        encoder.copy_buffer_to_buffer(&checks, 0, &staging, 0, 104);
                        queue.submit([encoder.finish()]);
                        let (send, receive) = std::sync::mpsc::channel();
                        staging
                            .slice(..)
                            .map_async(MapMode::Read, move |r| send.send(r).unwrap());
                        device
                            .poll(PollType::Wait {
                                submission_index: None,
                                timeout: Some(Duration::from_secs(30)),
                            })
                            .unwrap();
                        receive.recv().unwrap().unwrap();
                        let data: Vec<_> = staging
                            .slice(..)
                            .get_mapped_range()
                            .as_chunks::<4>()
                            .0
                            .iter()
                            .map(|v| u32::from_le_bytes(*v))
                            .collect();
                        staging.unmap();
                        let source = flags & 1 != 0;
                        let disabled = flags & 9 == 9;
                        let direct_threshold = blend_threshold(&data[7..10], frame);
                        let front_threshold = blend_threshold(&data[17..20], frame);
                        let back_threshold = blend_threshold(&data[20..23], frame);
                        assert_eq!(data[10], direct_threshold.to_bits());
                        assert_eq!(data[23], front_threshold.to_bits());
                        assert_eq!(data[24], back_threshold.to_bits());
                        assert_eq!(
                            data[25],
                            alpha_hash([data[7], data[8], data[9], (frame as f32).to_bits()])
                        );
                        let visible = disabled
                            || if source {
                                alpha_type == 0
                                    || alpha
                                        > if alpha_type == 2 {
                                            direct_threshold
                                        } else {
                                            0.5
                                        }
                            } else {
                                cutoff < 0.0 || alpha >= cutoff
                            };
                        let front_visible = if source && !disabled && alpha_type == 2 {
                            alpha > front_threshold
                        } else {
                            visible
                        };
                        let back_visible =
                            (if source && !disabled && alpha_type == 2 {
                                alpha > back_threshold
                            } else {
                                visible
                            }) && (!source || disabled || alpha_type == 0 || double_sided);
                        let front_hit = if front_visible { 2 } else { u32::MAX };
                        let back_hit = if back_visible { 2 } else { u32::MAX };
                        assert_eq!(
                            data[..7],
                            [
                                u32::from(visible),
                                front_hit,
                                (if front_visible { 1.0f32 } else { 2.0 }).to_bits(),
                                front_hit,
                                back_hit,
                                back_hit,
                                u32::from(disabled)
                            ],
                            "alpha traversal flags {flags}, double-sided {double_sided}, type {alpha_type}, cutoff {cutoff}, alpha {alpha}, frame {frame}"
                        );
                        for (actual, expected) in data[7..10].iter().zip([8.0f32, 15.0, 22.0]) {
                            assert!((f32::from_bits(*actual) - expected).abs() < 1e-5);
                        }
                        let scale = if disabled && alpha_type == 2 {
                            alpha
                        } else {
                            1.0
                        };
                        for (&actual, expected) in
                            data[11..17].iter().zip([2.0, 4.0, 8.0, 2.0, 4.0, 8.0])
                        {
                            assert_eq!(
                                actual,
                                (expected * scale).to_bits(),
                                "blend emission flags {flags}, type {alpha_type}, alpha {alpha}"
                            );
                        }
                    }
                }
            }
        }
    }
}
