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

#[test]
#[ignore = "requires Vulkan and slangc"]
fn source_probe_spawn_patch_budget_reprojection_and_quantization() {
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
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
    let bindings = [0, 3, 4, 7, 8, 20, 26, 29, 30];
    let mut shader = bevy_slang::SlangCompiler::default()
        .with_source_root(concat!(env!("CARGO_MANIFEST_DIR"), "/src/shaders"))
        .compile_source(
            "probe_schedule_checks.slang",
            include_str!("probe_schedule_checks.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec![
                    "GI_HARDWARE=0".into(),
                    "GI_TEXTURED=0".into(),
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
    let previous = buffer(192 * 480, BufferUsages::STORAGE);
    let cache = buffer(64 * 496, BufferUsages::STORAGE);
    let probes = buffer(64 * 480, BufferUsages::STORAGE);
    let work = buffer(16384, BufferUsages::STORAGE);
    let checks = buffer(2048, BufferUsages::STORAGE | BufferUsages::COPY_SRC);
    let staging = buffer(2048, BufferUsages::MAP_READ | BufferUsages::COPY_DST);
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
            usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
            view_formats: &[],
        })
    };
    let depth = texture(TextureFormat::R32Float);
    let gbuffer = texture(TextureFormat::Rgba32Uint);
    let motion = texture(TextureFormat::Rg32Float);
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
    let views = [
        depth.create_view(&default()),
        gbuffer.create_view(&default()),
        motion.create_view(&default()),
    ];
    let layout = device.create_bind_group_layout(
        "probe scheduling",
        &bindings.map(|binding| BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty: match binding {
                7 | 8 | 30 => BindingType::Texture {
                    sample_type: if binding == 8 {
                        TextureSampleType::Uint
                    } else {
                        TextureSampleType::Float { filterable: false }
                    },
                    view_dimension: TextureViewDimension::D2,
                    multisampled: false,
                },
                _ => BindingType::Buffer {
                    ty: if binding == 0 {
                        BufferBindingType::Uniform
                    } else {
                        BufferBindingType::Storage { read_only: false }
                    },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
            },
            count: None,
        }),
    );
    let group = device.create_bind_group(
        "probe scheduling",
        &layout,
        &[
            BindGroupEntry {
                binding: 0,
                resource: uniform.as_entire_binding(),
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
                binding: 7,
                resource: BindingResource::TextureView(&views[0]),
            },
            BindGroupEntry {
                binding: 8,
                resource: BindingResource::TextureView(&views[1]),
            },
            BindGroupEntry {
                binding: 20,
                resource: work.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 26,
                resource: checks.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 29,
                resource: cache.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 30,
                resource: BindingResource::TextureView(&views[2]),
            },
        ],
    );
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let names = [
        "seed_previous_schedule",
        "reset_work",
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
    for size in [UVec2::ONE, UVec2::new(36, 20), UVec2::new(40, 24)] {
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
                        pass.dispatch_workgroups(count.div_ceil(64), 1, 1);
                    }
                    encoder.copy_buffer_to_buffer(&checks, 0, &staging, 0, 2048);
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
                        data[448..464].iter().all(|v| f32::from_bits(*v) == 6.0),
                        "source cache merge includes the claimed nearest history"
                    );
                }
            }
        }
    }
}
