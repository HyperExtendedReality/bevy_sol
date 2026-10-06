#![recursion_limit = "256"]
//! GPU differential checks against fixed values from the pinned AMD equations.
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
use bevy_sol::HashGridCacheConfig;
use std::time::Duration;

#[test]
#[ignore = "requires a Vulkan compute GPU"]
fn amd_hashing_half_packing_tile_mips_temporal_update_and_decay() {
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
            .set(WindowPlugin {
                primary_window: None,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .disable::<WinitPlugin>()
            .disable::<bevy::render::pipelined_rendering::PipelinedRenderingPlugin>(),
    );
    app.finish();
    app.cleanup();
    let render = app.sub_app(RenderApp);
    let device = render.world().resource::<RenderDevice>();
    let queue = render.world().resource::<RenderQueue>();
    let config = HashGridCacheConfig {
        num_buckets: 16,
        tiles_per_bucket: 2,
        ..default()
    };
    let buffer = |label, size, usage| {
        device.create_buffer(&BufferDescriptor {
            label: Some(label),
            size,
            usage,
            mapped_at_creation: false,
        })
    };
    let uniform = buffer(
        "hash reference params",
        576,
        BufferUsages::UNIFORM | BufferUsages::COPY_DST,
    );
    let work = buffer(
        "hash reference work",
        4628,
        BufferUsages::STORAGE | BufferUsages::COPY_DST,
    );
    let probes = buffer(
        "probe cache reference current",
        264 * 1248,
        BufferUsages::STORAGE,
    );
    let previous_probes = buffer(
        "probe cache reference previous",
        396 * 1248,
        BufferUsages::STORAGE,
    );
    let cached_probes = buffer(
        "probe cache reference persistent",
        132 * 1264,
        BufferUsages::STORAGE,
    );
    let tiles = buffer(
        "hash reference tiles",
        (16 + 32 * (5 + 340 + 512)) * 4,
        BufferUsages::STORAGE,
    );
    let result = buffer(
        "hash reference results",
        1024,
        BufferUsages::STORAGE | BufferUsages::COPY_SRC,
    );
    let staging = buffer(
        "hash reference readback",
        1024,
        BufferUsages::MAP_READ | BufferUsages::COPY_DST,
    );
    let mut words = [0u32; 144];
    words[48..52].copy_from_slice(&[4, 3, 8, 8]); // Probe mask dimensions, spacing, directions
    words[58] = 24; // Reserved primary/secondary probes
    words[60] = 0.1f32.to_bits(); // Params.cache_config.x
    words[64] = 50; // tile decay
    words[72..76].copy_from_slice(&[config.num_buckets, config.tiles_per_bucket, 8, 32]);
    words[76..80].copy_from_slice(&[16.0f32.to_bits(), 16.0f32.to_bits(), 0, 0.01f32.to_bits()]);
    let layout = device.create_bind_group_layout(
        "hash reference layout",
        &[0, 3, 4, 20, 25, 26, 29].map(|binding| BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::Buffer {
                ty: if binding == 0 {
                    BufferBindingType::Uniform
                } else {
                    BufferBindingType::Storage { read_only: false }
                },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }),
    );
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: Some("hash reference pipeline layout"),
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let group = device.create_bind_group(
        "hash reference bindings",
        &layout,
        &[
            (&uniform, 0),
            (&previous_probes, 3),
            (&probes, 4),
            (&work, 20),
            (&tiles, 25),
            (&result, 26),
            (&cached_probes, 29),
        ]
        .map(|(buffer, binding)| BindGroupEntry {
            binding,
            resource: buffer.as_entire_binding(),
        }),
    );
    let mut shader = bevy_slang::SlangCompiler::default()
        .compile_bundle(
            "checks.slang",
            &[
                ("checks.slang", include_str!("hash_checks.slang")),
                ("gi.slang", include_str!("../src/shaders/gi.slang")),
                (
                    "probe_cache.slang",
                    include_str!("../src/shaders/probe_cache.slang"),
                ),
                (
                    "gi_denoiser.slang",
                    include_str!("../src/shaders/gi_denoiser.slang"),
                ),
                (
                    "light_grid.slang",
                    include_str!("../src/shaders/light_grid.slang"),
                ),
                ("hybrid.slang", include_str!("../src/shaders/hybrid.slang")),
                (
                    "environment.slang",
                    include_str!("../src/shaders/environment.slang"),
                ),
                (
                    "screen_probes.slang",
                    include_str!("../src/shaders/screen_probes.slang"),
                ),
                (
                    "hash_grid.slang",
                    include_str!("../src/shaders/hash_grid.slang"),
                ),
                ("ggx.slang", include_str!("../src/shaders/ggx.slang")),
                (
                    "world_space_restir.slang",
                    include_str!("../src/shaders/world_space_restir.slang"),
                ),
                (
                    "reflections.slang",
                    include_str!("../src/shaders/reflections.slang"),
                ),
                (
                    "materials.slang",
                    include_str!("../src/shaders/materials.slang"),
                ),
                (
                    "raytracing.slang",
                    include_str!("../src/shaders/raytracing.slang"),
                ),
                (
                    "packing.slang",
                    include_str!("../src/shaders/packing.slang"),
                ),
            ],
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec!["GI_HARDWARE=0".into(), "GI_TEXTURED=0".into()],
                ..default()
            },
        )
        .unwrap();
    let mappings: Vec<_> = [0, 3, 4, 20, 25, 26, 29]
        .iter()
        .enumerate()
        .map(|(index, &binding)| bevy_slang::SpirvBindingRemap {
            group: 0,
            binding,
            mapped_binding: index as u32,
        })
        .collect();
    bevy_slang::remap_spirv_bindings(&mut shader, &mappings).unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!("expected SPIR-V");
    };
    // SAFETY: these embedded application shaders are compiled and validated by Slang.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("Slang hash reference checks"),
            source: ShaderSource::SpirV(std::borrow::Cow::Owned(
                bytes
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|v| u32::from_le_bytes(*v))
                    .collect(),
            )),
        })
    };
    let names = [
        "clear_hash_tiles",
        "seed_hash_test",
        "filter_probe_mask_1",
        "filter_probe_mask_2",
        "initialize_hash_tiles",
        "accumulate_hash_test",
        "update_hash_tiles",
        "read_hash_test",
    ];
    let make_pipeline = |entry: &str| {
        device.create_compute_pipeline(&RawComputePipelineDescriptor {
            label: Some(entry),
            layout: Some(&pipeline_layout),
            module: &module,
            entry_point: Some(entry),
            compilation_options: default(),
            cache: None,
        })
    };
    let pipelines: Vec<_> = names.iter().map(|entry| make_pipeline(entry)).collect();
    let readback = |mut encoder: CommandEncoder| {
        encoder.copy_buffer_to_buffer(&result, 0, &staging, 0, 1024);
        queue.submit([encoder.finish()]);
        let (send, receive) = std::sync::mpsc::channel();
        staging
            .slice(..)
            .map_async(MapMode::Read, move |status| send.send(status).unwrap());
        device
            .poll(PollType::Wait {
                submission_index: None,
                timeout: Some(Duration::from_secs(30)),
            })
            .unwrap();
        receive
            .recv_timeout(Duration::from_secs(30))
            .unwrap()
            .unwrap();
        let mapped = staging.slice(..).get_mapped_range();
        let values: Vec<_> = mapped
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v))
            .collect();
        drop(mapped);
        staging.unmap();
        values
    };
    let mut run = |frame, reset, populate: bool| {
        words[52] = frame;
        words[53] = reset;
        words[65] = 1;
        let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
        queue.write_buffer(&uniform, 0, &bytes);
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
        for (index, pipeline) in pipelines.iter().enumerate() {
            if !populate && (1..=6).contains(&index) {
                continue;
            }
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        readback(encoder)
    };
    let floats = |values: &[u32], start| {
        values[start..start + 4]
            .iter()
            .map(|v| f32::from_bits(*v))
            .collect::<Vec<_>>()
    };
    let zero = run(0, 1, true);
    assert_eq!(
        zero[29], 1,
        "new tiles at frame zero are updated exactly once"
    );
    assert_eq!(floats(&zero, 16), [10.0, 20.0, 30.0, 4.0]);
    let last_frame = run(u32::MAX, 1, true);
    assert_eq!(last_frame[29], 1);
    let wrapped = run(0, 0, true);
    assert_eq!(
        wrapped[29], 1,
        "wrapped frame zero still updates live tiles once"
    );
    assert_eq!(floats(&wrapped, 24), [2.0, 4.0, 6.0, 2.0]);
    let first = run(1, 1, true);
    for (i, expected) in [1.0, 0.43046721, 0.00390625, 0.0, 0.0, 0.0]
        .into_iter()
        .enumerate()
    {
        assert!(
            (f32::from_bits(first[149 + i]) - expected).abs() < 2e-6,
            "source probe interpolation weight {i}"
        );
    }
    for (i, expected) in [0.0, 0.2, 2.0, 3.25, 10.6525].into_iter().enumerate() {
        assert!(
            (f32::from_bits(first[144 + i]) - expected).abs() < 2e-5,
            "source shadow-preserving blend {i}"
        );
    }
    for (i, expected) in [
        [1.0, 0.0, 10.0],
        [0.5, 0.25, 9.5],
        [0.0, 0.5, 9.0],
        [0.4, 0.6, 11.2],
    ]
    .iter()
    .enumerate()
    {
        for (channel, expected) in expected.iter().enumerate() {
            assert!(
                (f32::from_bits(first[132 + 3 * i + channel]) - expected).abs() < 2e-6,
                "source area-light sample {i}"
            );
        }
    }
    assert_eq!(
        &first[128..130],
        &[0x4000bc00, 0x3800c200],
        "SH half packing preserves signed coefficients"
    );
    assert_eq!(
        &first[..10],
        &[
            13, 909915491, 7, 1, 129708002, 1051671337, 3861530882, 878055299, 1321542528,
            975606439
        ]
    );
    assert_eq!(&first[30..32], &[0x40003c00, 0x38004200]);
    assert_eq!(first[29], 1, "all four cells must share one tile");
    assert_eq!(floats(&first, 16), [10.0, 20.0, 30.0, 4.0]);
    assert_eq!(floats(&first, 20), [5.0, 10.0, 15.0, 1.0]);
    assert_eq!(floats(&first, 24), [1.0, 2.0, 3.0, 1.0]);
    let sanitized = floats(&first, 32);
    assert_eq!(sanitized[0], 0.0);
    assert!((sanitized[1] - 2.0).abs() < 1e-5);
    assert_eq!(&sanitized[2..], [0.0, 0.0]);
    let history = floats(&first, 36);
    assert!(history[3] > 62.0 && history[3] < 64.0);
    assert!(
        history[..3]
            .iter()
            .all(|v| (*v / history[3] - 1.0).abs() < 1e-5)
    );
    assert_eq!(floats(&first, 40), [1.0, 1.0, 1.0, 1.0]);
    let changing = floats(&first, 44);
    assert!(changing[3] > 3.0 && changing[3] < 4.0);
    assert!(
        changing[..3]
            .iter()
            .all(|v| (*v / changing[3] - 42.0 / 33.0).abs() < 1e-5)
    );
    let second = run(2, 0, true);
    let mapping_moments = floats(&first, 48);
    for (actual, expected) in mapping_moments
        .iter()
        .zip([0.5, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])
    {
        assert!(
            (actual - expected).abs() < 5e-5,
            "equal-area hemisphere moment: {actual} vs {expected}"
        );
    }
    for &bits in &first[52..55] {
        assert!(
            f32::from_bits(bits) < 2e-5,
            "mapping/frame error: {}",
            f32::from_bits(bits)
        );
    }
    assert_eq!(&first[55..57], &[0x40003c00, 0xbc004200]);
    assert_eq!(
        &first[62..64],
        &[0, 0x7c000000],
        "finite radiance and positive-infinity distance sentinel"
    );
    assert_eq!(
        &first[57..62],
        &[17, 17, 17, 23, u32::MAX],
        "mip search including odd border and offset rejection"
    );
    assert_eq!(floats(&second, 16), [22.0, 44.0, 66.0, 8.0]);
    assert_eq!(floats(&second, 24), [4.0, 8.0, 12.0, 2.0]);
    assert_eq!(second[29], 1, "touch once per tile per frame");
    assert_ne!(
        run(51, 0, false)[28],
        u32::MAX,
        "tile survives 49 unused frames"
    );
    assert_eq!(
        run(52, 0, false)[28],
        u32::MAX,
        "tile expires at 50 unused frames"
    );
    let cache_names = [
        "prepare_probe_cache",
        "project_probe_cache",
        "seed_probe_cache_test",
        "reuse_cached_probes",
        "scan_probe_cache_lru",
        "scan_probe_cache_blocks",
        "scatter_probe_cache_lru",
        "allocate_probe_cache",
        "update_probe_cache",
        "scan_probe_cache_lru",
        "scan_probe_cache_blocks",
        "scatter_probe_cache_lru",
        "copy_probe_cache_lru",
        "read_probe_cache_test",
    ];
    let cache_pipelines: Vec<_> = cache_names
        .iter()
        .map(|entry| make_pipeline(entry))
        .collect();
    let mut run_cache = |frame: u32| {
        words[..16].fill(0);
        for diagonal in [0, 5, 10, 15] {
            words[diagonal] = 1.0f32.to_bits();
        }
        if frame == 5 {
            words[12] = 2.0f32.to_bits();
        } // Camera leaves cached geometry.
        words[44..48].copy_from_slice(&[0, 0, 32, 24]);
        words[52] = frame;
        words[53] = u32::from(frame == 1);
        words[62] = 0.001f32.to_bits();
        words[87] = 0.02f32.to_bits();
        let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
        queue.write_buffer(&uniform, 0, &bytes);
        let cache_projection =
            Mat4::from_cols_array(&std::array::from_fn(|i| f32::from_bits(words[i]))).inverse();
        let cache_matrix_bytes: Vec<_> = cache_projection
            .to_cols_array()
            .iter()
            .flat_map(|value| value.to_le_bytes())
            .collect();
        queue.write_buffer(&work, 300, &cache_matrix_bytes);
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
        for pipeline in &cache_pipelines {
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        readback(encoder)
    };
    let initial_cache = run_cache(1);
    assert_eq!(&initial_cache[64..68], &[4, 4, 4, 0]);
    assert_eq!(&initial_cache[68..76], &[4, 5, 6, 7, 8, 9, 10, 11]);
    let mut first_slots = initial_cache[80..84].to_vec();
    first_slots.sort_unstable();
    assert_eq!(first_slots, [0, 1, 2, 3]);
    let hits = run_cache(2);
    assert_eq!(
        &hits[64..68],
        &[5, 5, 5, 5],
        "shared history restores once while update claims remain exclusive"
    );
    assert_eq!(hits[104], 24 + initial_cache[80]);
    assert_eq!(hits[108], 24 + initial_cache[80]);
    assert_eq!(&hits[68..75], &[5, 6, 7, 8, 9, 10, 11]);
    let evicted = run_cache(3);
    assert_eq!(&evicted[64..68], &[10, 12, 10, 0]);
    let allocated = &evicted[80..90];
    assert!(
        (5..12u32).all(|slot| allocated.contains(&slot)),
        "free slots are allocated before old resident tiles"
    );
    assert_eq!(
        allocated.iter().filter(|slot| **slot < 4).count(),
        3,
        "oldest touched entries precede the last MRU slot"
    );
    assert!(!allocated.contains(&4));
    let returned = run_cache(4);
    assert_eq!(&returned[64..68], &[10, 12, 10, 10]);
    let away = run_cache(5);
    assert_eq!(
        &away[64..68],
        &[0, 12, 0, 0],
        "leaving the view retains cached history"
    );
    assert_eq!(
        &away[68..80],
        &returned[68..80],
        "an untouched LRU remains stable"
    );
    let restored = run_cache(6);
    assert_eq!(
        &restored[64..68],
        &[10, 12, 10, 10],
        "history is reused when the camera returns"
    );
    for values in [&hits, &evicted, &returned, &away, &restored] {
        let mut lru = values[68..80].to_vec();
        lru.sort_unstable();
        assert_eq!(
            lru,
            (0..12).collect::<Vec<_>>(),
            "LRU must contain every cache slot exactly once"
        );
    }
    words[48..52].copy_from_slice(&[4, 33, 8, 8]);
    words[58] = 264;
    words[53] = 1;
    let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
    queue.write_buffer(&uniform, 0, &bytes);
    let scan_names = [
        "prepare_probe_cache",
        "seed_probe_scan_test",
        "scan_probe_cache_lru",
        "scan_probe_cache_blocks",
        "scatter_probe_cache_lru",
        "copy_probe_cache_lru",
        "read_probe_scan_test",
    ];
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    for entry in scan_names {
        let pipeline = make_pipeline(entry);
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        let groups = match entry {
            "prepare_probe_cache" | "scatter_probe_cache_lru" | "copy_probe_cache_lru" => 3,
            "scan_probe_cache_lru" => 2,
            _ => 1,
        };
        pass.dispatch_workgroups(groups, 1, 1);
    }
    let scanned = readback(encoder);
    assert_eq!(&scanned[..2], &[44, 88]);
    let expected: Vec<_> = (0..132)
        .filter(|slot| slot % 3 != 0)
        .chain((0..132).rev().filter(|slot| slot % 3 == 0))
        .collect();
    assert_eq!(
        &scanned[16..148],
        &expected,
        "stable LRU/MRU across a 128-lane group boundary and partial final group"
    );
    let schedule_pipeline = make_pipeline("read_probe_schedule_test");
    for dims in [
        UVec2::new(4, 3),
        UVec2::new(5, 7),
        UVec2::new(1, 33),
        UVec2::new(33, 1),
    ] {
        words[48] = dims.x;
        words[49] = dims.y;
        for mode in 0..3u32 {
            words[71] = (1.0 + 2.0 * mode as f32).to_bits();
            let axis = 1u32 << mode;
            for frame in (0..16u32).chain([255, 256, 257, 511, 512]) {
                words[52] = frame;
                let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
                queue.write_buffer(&uniform, 0, &bytes);
                let mut encoder =
                    device.create_command_encoder(&CommandEncoderDescriptor::default());
                {
                    let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
                    pass.set_pipeline(&schedule_pipeline);
                    pass.set_bind_group(0, &group, &[]);
                    pass.dispatch_workgroups(1, 1, 1);
                }
                let selected = readback(encoder);
                let radical_inverse = |mut index: u32, base: u32| {
                    let mut factor = 1.0f64;
                    let mut value = 0.0;
                    while index > 0 {
                        factor /= f64::from(base);
                        value += factor * f64::from(index % base);
                        index /= base;
                    }
                    value
                };
                let halton = Vec2::new(
                    radical_inverse((frame & 255) + 1, 2) as f32,
                    radical_inverse((frame & 255) + 1, 3) as f32,
                );
                assert!((f32::from_bits(selected[1]) - halton.x).abs() < 1e-7);
                assert!((f32::from_bits(selected[2]) - halton.y).abs() < 1e-7);
                let phase = (halton * axis as f32).as_uvec2();
                assert_eq!(selected[0], dims.x.div_ceil(axis) * dims.y.div_ceil(axis));
                for by in (0..dims.y).step_by(axis as usize) {
                    for bx in (0..dims.x).step_by(axis as usize) {
                        let mut count = 0;
                        for y in by..(by + axis).min(dims.y) {
                            for x in bx..(bx + axis).min(dims.x) {
                                count += selected[16 + (x + y * dims.x) as usize];
                            }
                        }
                        assert_eq!(
                            count, 1,
                            "one refresh per full/quarter/sixteenth block, including partial borders"
                        );
                        let chosen = UVec2::new(bx, by)
                            + phase.min(
                                (dims - UVec2::new(bx, by)).min(UVec2::splat(axis)) - UVec2::ONE,
                            );
                        assert_eq!(
                            selected[16 + (chosen.x + chosen.y * dims.x) as usize],
                            1,
                            "source global Halton phase"
                        );
                    }
                }
            }
        }
    }
    words[48..52].copy_from_slice(&[4, 3, 8, 8]);
    words[58] = 24;
    words[63] = 1000.0f32.to_bits();
    let sampling_pipelines: Vec<_> = [
        "seed_probe_sampling_test",
        "prepare_probe_sampling",
        "read_probe_sampling_test",
    ]
    .iter()
    .map(|entry| make_pipeline(entry))
    .collect();
    for view_x in [0.0f32, 4.0] {
        for roughness in [0.1f32, 0.75, 1.0] {
            for metallic in [0.0f32, 1.0] {
                words[35] = 1.0f32.to_bits(); // Orthographic view.
                let view = Vec3::new(view_x, 0.0, 1.0).normalize();
                words[36..39].copy_from_slice(&view.to_array().map(f32::to_bits));
                words[40..44].copy_from_slice(&[
                    view_x.to_bits(),
                    roughness.to_bits(),
                    metallic.to_bits(),
                    0,
                ]);
                let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
                queue.write_buffer(&uniform, 0, &bytes);
                let mut encoder =
                    device.create_command_encoder(&CommandEncoderDescriptor::default());
                for pipeline in &sampling_pipelines {
                    let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
                    pass.set_pipeline(pipeline);
                    pass.set_bind_group(0, &group, &[]);
                    pass.dispatch_workgroups(1, 1, 1);
                }
                let sampled = readback(encoder);
                let mean = sampled[..64]
                    .iter()
                    .map(|value| f64::from(f32::from_bits(*value)))
                    .sum::<f64>()
                    / 64.0;
                assert!(
                    (mean - 1.0).abs() < 0.025,
                    "compensated material/radiance mixture: view_x={view_x}, roughness={roughness}, metallic={metallic}, mean={mean}"
                );
                let integral = sampled[128..192]
                    .iter()
                    .map(|value| f64::from(f32::from_bits(*value)))
                    .sum::<f64>()
                    * (2.0 * std::f64::consts::PI / 64.0);
                assert!((integral - 1.0).abs() < 1e-5);
                assert!(
                    sampled[192..256 - 1]
                        .windows(2)
                        .all(|values| f32::from_bits(values[0]) < f32::from_bits(values[1]))
                );
                // Independent f64 Fresnel/diffuse-compensation calculation.
                let vx = f64::from(view_x);
                let len = (vx * vx + 1.0).sqrt();
                let v = [vx / len, 1.0 / len];
                let smoothness = 1.0 - f64::from(roughness);
                let blend = smoothness * (smoothness.sqrt() + f64::from(roughness));
                let dominant = [-v[0] * blend, 1.0 - blend + v[1] * blend];
                let dl = (dominant[0].powi(2) + dominant[1].powi(2)).sqrt();
                let half = [v[0] + dominant[0] / dl, v[1] + dominant[1] / dl];
                let hl = (half[0].powi(2) + half[1].powi(2)).sqrt();
                let hv = (v[0] * half[0] + v[1] * half[1]) / hl;
                let grazing = (1.0 - hv).powi(5);
                let fresnel = 0.04 + 0.96 * grazing;
                let diffuse = 0.5 * (1.0 - fresnel) * 1.05 * (1.0 - grazing);
                let expected = fresnel / (fresnel + diffuse);
                assert!((f64::from(f32::from_bits(sampled[255])) - expected).abs() < 2e-6);
                assert!(
                    sampled[64..128].iter().sum::<u32>() < 65536,
                    "uniform coverage survives any rejected GGX directions"
                );
            }
        }
    }
    words[43] = 1.0f32.to_bits(); // Two resident neighbors and no closest history.
    let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
    queue.write_buffer(&uniform, 0, &bytes);
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    for entry in [
        "seed_probe_sampling_test",
        "prepare_probe_sampling",
        "read_probe_merge_test",
    ] {
        let pipeline = make_pipeline(entry);
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(1, 1, 1);
    }
    let merged = readback(encoder);
    for bin in merged.as_chunks::<4>().0 {
        assert_eq!(
            bin[..3]
                .iter()
                .map(|v| f32::from_bits(*v))
                .collect::<Vec<_>>(),
            [4.0; 3],
            "directional history averages all compatible cached neighbors"
        );
        assert_eq!(
            f32::from_bits(bin[3]),
            1000.0,
            "far endpoints remain bounded"
        );
    }
    let pipeline = make_pipeline("read_motion_reprojection_test");
    let position = Vec3::new(0.3, -0.2, -3.0);
    let uv = |matrix: Mat4, position: Vec3| {
        let clip = matrix * position.extend(1.0);
        clip.truncate().truncate() / clip.w * Vec2::new(0.5, -0.5) + Vec2::splat(0.5)
    };
    for orthographic in [false, true] {
        for moving in [false, true] {
            for jittered in [false, true] {
                let projection = if orthographic {
                    Mat4::orthographic_rh(-2.0, 2.0, -1.5, 1.5, 0.1, 100.0)
                } else {
                    Mat4::perspective_rh(1.0, 1.5, 0.1, 100.0)
                };
                let current = projection * Mat4::from_translation(Vec3::new(-0.25, 0.1, 0.0));
                let previous = projection * Mat4::from_translation(Vec3::new(0.1, -0.15, 0.0));
                let mut previous_jittered_projection = projection;
                if jittered {
                    previous_jittered_projection.z_axis.x += 0.003;
                    previous_jittered_projection.z_axis.y -= 0.002;
                }
                let previous_jittered = previous_jittered_projection
                    * Mat4::from_translation(Vec3::new(0.1, -0.15, 0.0));
                let old_position = position
                    - if moving {
                        Vec3::new(0.2, 0.1, 0.0)
                    } else {
                        Vec3::ZERO
                    };
                let velocity = uv(current, position) - uv(previous, old_position);
                for (offset, matrix) in [(16, previous_jittered), (96, current), (112, previous)] {
                    for (word, value) in words[offset..offset + 16]
                        .iter_mut()
                        .zip(matrix.to_cols_array())
                    {
                        *word = value.to_bits();
                    }
                }
                words[40] = velocity.x.to_bits();
                words[41] = velocity.y.to_bits();
                let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
                queue.write_buffer(&uniform, 0, &bytes);
                let mut encoder =
                    device.create_command_encoder(&CommandEncoderDescriptor::default());
                {
                    let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
                    pass.set_pipeline(&pipeline);
                    pass.set_bind_group(0, &group, &[]);
                    pass.dispatch_workgroups(1, 1, 1);
                }
                let result = readback(encoder);
                let actual = Vec2::new(f32::from_bits(result[0]), f32::from_bits(result[1]));
                let expected = uv(previous_jittered, old_position);
                assert!(
                    actual.distance(expected) < 2e-6,
                    "motion: ortho={orthographic}, object={moving}, jitter={jittered}: {actual} vs {expected}"
                );
            }
        }
    }
    let pipeline = make_pipeline("read_hash_hole_test");
    for source in [0u32, 1] {
        words[139] = source;
        let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
        queue.write_buffer(&uniform, 0, &bytes);
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
        {
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        let values = readback(encoder);
        assert_eq!(values[0], if source == 1 { u32::MAX } else { values[1] });
    }
    let pipeline = make_pipeline("read_source_diffuse_normal_test");
    words[139] = 1;
    queue.write_buffer(
        &uniform,
        0,
        &words
            .iter()
            .flat_map(|v| v.to_le_bytes())
            .collect::<Vec<_>>(),
    );
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    {
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(1, 1, 1);
    }
    let values = readback(encoder);
    // Independent source RGB10 decode/normalization and l=1 cosine convolution.
    let small = 1.0_f64 / 1023.0;
    let normal_x = 1.0 / (1.0 + 2.0 * small * small).sqrt();
    let expected = 0.4886025119029199 * normal_x * (2.0 * std::f64::consts::PI / 3.0);
    for (channel, scale) in [1.0, 2.0, 4.0].into_iter().enumerate() {
        assert!(
            (f64::from(f32::from_bits(values[channel])) - expected * scale).abs() < 2e-6,
            "source diffuse SH must use shading/details normal, not placement geometry normal"
        );
    }
    assert_eq!(f32::from_bits(values[3]), 1.0);
    words[139] = 1;
    words[52] = 0;
    let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
    queue.write_buffer(&uniform, 0, &bytes);
    let pipeline = make_pipeline("concurrent_hash_claim_test");
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    {
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(1, 1, 1);
    }
    let values = readback(encoder);
    assert_eq!(
        values[0], 1,
        "64 concurrent first touches enqueue one tile at frame zero"
    );
    assert!(values[4..68].iter().all(|cell| *cell == values[1]));
    words[139] = 17; // SourceAtlas + DISABLE_SPECULAR_MATERIALS.
    words[35] = 1.0f32.to_bits();
    words[36..39].copy_from_slice(&[0, 0, 1.0f32.to_bits()]);
    let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
    queue.write_buffer(&uniform, 0, &bytes);
    let pipeline = make_pipeline("read_specular_override_test");
    let mut encoder = device.create_command_encoder(&default());
    {
        let mut pass = encoder.begin_compute_pass(&default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(1, 1, 1);
    }
    let values = readback(encoder);
    let base = [0.125f64, 0.5, 0.875];
    let quantized = base.map(|value| (value.powf(1.0 / 2.2) * 1023.0) as u32);
    assert_eq!(
        values[0],
        (quantized[0] << 20) | (quantized[1] << 10) | quantized[2]
    );
    let grazing = 0.5f64.powi(5);
    let compensation = (1.0 - (0.04 + 0.96 * grazing)) * 1.05 * (1.0 - grazing);
    for channel in 0..3 {
        let decoded = (f64::from(quantized[channel]) / 1023.0).powf(2.2);
        assert!((f64::from(f32::from_bits(values[1 + channel])) - decoded).abs() < 2e-6);
        assert!((f64::from(f32::from_bits(values[4 + channel])) - compensation).abs() < 2e-6);
        let secondary = base[channel] * 0.96 * 1.05 / std::f64::consts::PI;
        assert!((f64::from(f32::from_bits(values[7 + channel])) - secondary).abs() < 2e-6);
        assert_eq!(f32::from_bits(values[10 + channel]), base[channel] as f32);
        assert_eq!(f32::from_bits(values[13 + channel]), 0.0);
        assert_eq!(f32::from_bits(values[16 + channel]), 0.0);
    }
    assert_eq!(f32::from_bits(values[19]), 0.0);
    let mut expected_rng = 73u32;
    for _ in 0..5 {
        expected_rng = expected_rng
            .wrapping_mul(747796405)
            .wrapping_add(2891336453);
    }
    assert_eq!(
        values[20], expected_rng,
        "source diffuse-only sampling consumes five PCG draws"
    );
    assert_eq!(f32::from_bits(values[21]), 1.0);
    assert_eq!(f32::from_bits(values[22]), 0.0);
    let pipeline = make_pipeline("read_material_f0_test");
    for flags in [0, 1, 5, 17] {
        words[139] = flags;
        queue.write_buffer(
            &uniform,
            0,
            &words
                .iter()
                .flat_map(|word| word.to_le_bytes())
                .collect::<Vec<_>>(),
        );
        let mut encoder = device.create_command_encoder(&default());
        {
            let mut pass = encoder.begin_compute_pass(&default());
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        let values = readback(encoder);
        for r in 0..3 {
            let reflectance = r as f64 * 0.5;
            let dielectric = if flags & 1 != 0 {
                0.04
            } else {
                0.16 * reflectance * reflectance
            };
            for m in 0..3 {
                let metallic = m as f64 * 0.5;
                for c in 0..3 {
                    let expected = dielectric * (1.0 - metallic) + base[c] * metallic;
                    assert!(
                        (f64::from(f32::from_bits(values[9 * r + 3 * m + c])) - expected).abs()
                            < 2e-6
                    );
                }
            }
            for c in 0..3 {
                let specular = if flags & 17 == 17 {
                    0.0
                } else {
                    dielectric / 4.0
                };
                let expected =
                    (base[c] * (1.0 - dielectric) * 1.05 + specular) / std::f64::consts::PI;
                assert!(
                    (f64::from(f32::from_bits(values[32 + 4 * r + c])) - expected).abs() < 2e-6
                );
            }
            assert!(
                (f32::from_bits(values[35 + 4 * r]) - std::f32::consts::FRAC_1_PI).abs() < 2e-6
            );
        }
    }
    words[139] = 1;
    queue.write_buffer(
        &uniform,
        0,
        &words
            .iter()
            .flat_map(|word| word.to_le_bytes())
            .collect::<Vec<_>>(),
    );
    let pipeline = make_pipeline("read_source_roughness_test");
    let mut encoder = device.create_command_encoder(&default());
    {
        let mut pass = encoder.begin_compute_pass(&default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(1, 1, 1);
    }
    let values = readback(encoder);
    for (i, roughness) in [0.0f64, 0.0001, 0.01, 0.0316227766, 0.1, 1.0]
        .into_iter()
        .enumerate()
    {
        let alpha = (roughness * roughness).max(1e-6);
        let a2 = (alpha * alpha).max(1e-6);
        let ndf = 1.0 / (std::f64::consts::PI * a2);
        let specular = 0.04 * ndf / 4.0;
        let k = (1.0 - alpha * alpha) / (1.0 + alpha * alpha);
        let pdf = ndf / (2.0 * (k + 1.0));
        assert!(
            (f64::from(f32::from_bits(values[2 * i])) - specular).abs() < specular * 2e-7,
            "source squared-alpha clamp at roughness {roughness}"
        );
        assert!(
            (f64::from(f32::from_bits(values[2 * i + 1])) - pdf).abs() < pdf * 2e-7,
            "source bounded-cap alpha at roughness {roughness}"
        );
    }
    for (i, nv) in [0.0f64, -0.5].into_iter().enumerate() {
        let nh = ((1.0 + nv) * 0.5).sqrt();
        let fresnel = 0.04 + 0.96 * (1.0 - nh).powi(5);
        let denominator = (1.0 - nh * nh) / 1.00001 + nh * nh;
        let expected =
            fresnel / (std::f64::consts::PI * denominator.powi(2) * (nv.abs() + 1.0) * 2.0);
        assert!(
            (f64::from(f32::from_bits(values[16 + i])) - expected).abs() < 2e-8,
            "source grazing/back-facing GGX view {nv}"
        );
    }
    assert_eq!(
        f32::from_bits(values[18]),
        0.0,
        "source rejects below-surface half vectors"
    );
    assert_eq!(
        f32::from_bits(values[19]),
        f32::INFINITY,
        "source bounded PDF retains the singular antipodal endpoint"
    );
    let pipeline = make_pipeline("read_bent_cone_test");
    for normal in [Vec3::Z, Vec3::X, Vec3::new(1.0, 2.0, 3.0).normalize()] {
        for ao in [-1.0f32, 0.0, 0.25, 0.75, 1.0, 2.0] {
            words[40..44].copy_from_slice(&normal.extend(ao).to_array().map(f32::to_bits));
            queue.write_buffer(
                &uniform,
                0,
                &words
                    .iter()
                    .flat_map(|word| word.to_le_bytes())
                    .collect::<Vec<_>>(),
            );
            let mut encoder = device.create_command_encoder(&default());
            {
                let mut pass = encoder.begin_compute_pass(&default());
                pass.set_pipeline(&pipeline);
                pass.set_bind_group(0, &group, &[]);
                pass.dispatch_workgroups(1, 1, 1);
            }
            let values = readback(encoder);
            let [x, y, z] = normal.to_array().map(f64::from);
            let theta = (1.0 - f64::from(ao)).clamp(0.0, 1.0).sqrt().acos();
            let (s, c) = theta.sin_cos();
            let b1 = 1.023326707946489 * (1.0 - c.powi(3));
            let b2 = (4.0 - 3.0 * s.powi(3)) * s * s;
            let coefficients = [
                0.886226925452758 * s * s,
                -b1 * y,
                b1 * z,
                -b1 * x,
                0.8580855308097834 * b2 * x * y,
                -0.8580855308097834 * b2 * y * z,
                0.2477079561003757 * b2 * (3.0 * z * z - 1.0),
                -0.8580855308097834 * b2 * x * z,
                0.4290427654048917 * b2 * (x * x - y * y),
            ];
            let probe = coefficients
                .into_iter()
                .enumerate()
                .map(|(j, coefficient)| coefficient * (j + 1) as f64 * 0.125)
                .sum::<f64>()
                .max(0.0);
            for (channel, scale) in [1.0, 2.0, 4.0].into_iter().enumerate() {
                let expected = (0.2 + 1.75 * probe) * scale;
                assert!(
                    (f64::from(f32::from_bits(values[channel])) - expected).abs() < 2e-5,
                    "bent cone {normal:?}, AO {ao}, channel {channel}"
                );
                assert_eq!(
                    values[4 + channel],
                    0,
                    "missing probes suppress near-field GI"
                );
            }
            assert_eq!(values[3], 0);
            assert_eq!(f32::from_bits(values[7]), 1.0);
        }
    }
    let run = |entries: &[(&str, u32)]| {
        let mut encoder = device.create_command_encoder(&default());
        for &(entry, groups) in entries {
            let pipeline = make_pipeline(entry);
            let mut pass = encoder.begin_compute_pass(&default());
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(groups, 1, 1);
        }
        readback(encoder)
    };
    let upload = |words: &[u32; 144]| {
        queue.write_buffer(
            &uniform,
            0,
            &words
                .iter()
                .flat_map(|word| word.to_le_bytes())
                .collect::<Vec<_>>(),
        )
    };
    // IEEE binary16 expectations include signed zero, subnormals, ties-to-even,
    // values above the former clamp and overflow. NaN payloads are backend-defined.
    let cases = [
        (
            [-1.0, 60032.0, 65504.0, 65536.0],
            [0xbc00u16, 0x7b54, 0x7bff, 0x7c00],
        ),
        (
            [-65536.0, f32::INFINITY, f32::NEG_INFINITY, f32::NAN],
            [0xfc00, 0x7c00, 0xfc00, 0x7e00],
        ),
        (
            [
                2.0f32.powi(-24),
                2.0f32.powi(-25),
                3.0 * 2.0f32.powi(-25),
                -0.0,
            ],
            [1, 0, 2, 0x8000],
        ),
        (
            [f32::NAN, 2.0, 3.0, f32::INFINITY],
            [0x7e00, 0x4000, 0x4200, 0x7c00],
        ),
        (
            [0.1237199, -0.6557197, 0.74479866, 1.0],
            [0x2feb, 0xb93f, 0x39f5, 0x3c00],
        ),
    ];
    for source in [0u32, 1] {
        words[139] = source;
        for (case, (input, expected)) in cases.into_iter().enumerate() {
            words[40..44].copy_from_slice(&input.map(f32::to_bits));
            upload(&words);
            let values = run(&[
                ("read_probe_half_test", 1),
                ("read_probe_half_direction_test", 1),
                ("read_probe_spawn_half_test", 1),
            ]);
            if source == 1 {
                for (kind, packed) in values[..4].as_chunks::<2>().0.iter().enumerate() {
                    for (channel, half) in expected.into_iter().enumerate() {
                        let actual = (packed[channel / 2] >> (16 * (channel % 2))) as u16;
                        if input[channel].is_nan() {
                            assert_eq!(actual & 0x7c00, 0x7c00);
                            assert_ne!(actual & 0x03ff, 0, "source preserves NaN");
                        } else {
                            assert_eq!(
                                actual, half,
                                "source half pack {kind}, case {case}, channel {channel}"
                            );
                        }
                    }
                }
            } else {
                let (radiance, sh) = match case {
                    0 => ([0x7b53_0000, 0x7c00_7b53], [0x7b53_bc00, 0x7b53_7b53]),
                    1 => ([0, 0xbc00_0000], [0x7b53_fb53, 0x0000_fb53]),
                    2 => ([1, 0x8000_0002], [1, 0x8000_0002]),
                    3 => ([0, 0x7c00_0000], [0x4000_0000, 0x7b53_4200]),
                    _ => ([0x0000_2feb, 0x3c00_39f5], [0xb93f_2feb, 0x3c00_39f5]),
                };
                assert_eq!(values[..2], radiance, "compensated radiance pack {case}");
                assert_eq!(values[2..4], sh, "compensated SH pack {case}");
            }
            if source == 0 {
                for channel in 0..3 {
                    let actual = f32::from_bits(values[4 + channel]);
                    assert!(
                        actual.to_bits() == input[channel].to_bits()
                            || (actual.is_nan() && input[channel].is_nan())
                    );
                }
            } else if case == 4 {
                assert_eq!(
                    values[4..7],
                    [0.12371826f32, -0.6557617, 0.7446289].map(f32::to_bits),
                    "source traces decoded half directions without renormalizing"
                );
            }
            let decoded = match (source, case) {
                (1, 0) => [-1.0, 60032.0, 65504.0, f32::INFINITY],
                (1, 1) => [
                    f32::NEG_INFINITY,
                    f32::INFINITY,
                    f32::NEG_INFINITY,
                    f32::NAN,
                ],
                (1, 2) => [2.0f32.powi(-24), 0.0, 2.0f32.powi(-23), -0.0],
                (1, 4) => [0.12371826, -0.6557617, 0.7446289, 1.0],
                _ => input,
            };
            for (channel, expected) in decoded.into_iter().enumerate() {
                let actual = f32::from_bits(values[8 + channel]);
                assert!(
                    actual.to_bits() == expected.to_bits()
                        || (actual.is_nan() && expected.is_nan()),
                    "spawn half storage boundary, source {source}, case {case}, channel {channel}: {actual} != {expected}"
                );
            }
        }
    }
    words[62] = 0.001f32.to_bits();
    words[63] = 1000.0f32.to_bits();
    words[139] = 1;
    for position in [
        [0.0f32, -0.0, 0.001],
        [0.031249, -0.031249, 0.03125],
        [0.03125, -0.03125, -0.03125],
        [1024.0, -2048.0, 65536.0],
        [0.0001, -0.0001, -1000.0],
    ] {
        words[40..43].copy_from_slice(&position.map(f32::to_bits));
        upload(&words);
        let values = run(&[("read_source_ray_setup_test", 1)]);
        let normal = [0.25f32, -0.5, 1.0];
        let origin: [f32; 3] = std::array::from_fn(|c| {
            if position[c].abs() < 1.0 / 32.0 {
                position[c] + normal[c] / 65536.0
            } else {
                let step = (normal[c] * 256.0) as i32;
                f32::from_bits(
                    ((position[c].to_bits() as i32).wrapping_add(if position[c] < 0.0 {
                        -step
                    } else {
                        step
                    })) as u32,
                )
            }
        });
        assert_eq!(
            values[..3],
            origin.map(f32::to_bits),
            "source offset at {position:?}"
        );
        assert_eq!(f32::from_bits(values[3]), 0.0);
        assert_eq!(f32::from_bits(values[4]), 1e9);
        assert_eq!(f32::from_bits(values[5]), 0.0);
        assert_eq!(f32::from_bits(values[6]), 1.0 - 1.0 / 16384.0);
        assert_eq!(f32::from_bits(values[7]), f32::MAX);
        assert_eq!(
            values[8..11],
            std::array::from_fn::<_, 3, _>(|c| ([4.0, -3.0, 2.0][c] - origin[c]).to_bits())
        );
        assert_eq!(values[12..15], [0, 0, 1.0f32.to_bits()]);
        assert_eq!(
            values[16..20],
            values[20..24],
            "source quantization retains the GPU's half-infinity conversion"
        );
    }
    words[32..36].fill(0);
    words[36..39].copy_from_slice(&[0, 0, 1.0f32.to_bits()]);
    words[44..48].copy_from_slice(&[0, 0, 32, 24]);
    words[48..52].copy_from_slice(&[4, 3, 8, 8]);
    words[58] = 24;
    words[91] = 0.01f32.to_bits();
    for source in [0u32, 1] {
        words[139] = source;
        for scenario in 0..5 {
            words[52] = scenario;
            upload(&words);
            let values = run(&[
                ("seed_source_filter_test", 1),
                ("filter_probe_radiance_x", 3),
                ("filter_probe_radiance_y", 3),
                ("read_source_filter_test", 1),
            ]);
            let expected = if source == 1 || scenario == 0 || scenario == 4 {
                2.0
            } else {
                1.0
            };
            for &channel in &values[..3] {
                assert_eq!(
                    f32::from_bits(channel),
                    expected,
                    "source {source}, filter scenario {scenario}"
                );
            }
            if scenario == 0 {
                assert_eq!(f32::from_bits(values[3]), f32::INFINITY);
            }
            for &channel in &values[4..7] {
                assert_eq!(
                    f32::from_bits(channel),
                    if expected == 2.0 { 3.5 } else { 1.0 },
                    "source {source}, vertical filter scenario {scenario}"
                );
            }
        }
        let values = run(&[
            ("seed_source_sky_history_test", 1),
            ("reproject_probe_history", 24),
            ("read_source_sky_history_test", 1),
        ]);
        for &channel in &values[..3] {
            assert_eq!(
                f32::from_bits(channel),
                if source == 1 { 0.0 } else { 3.0 },
                "sky reprojection, source {source}"
            );
        }
        assert_eq!(
            f32::from_bits(values[3]),
            if source == 1 { f32::INFINITY } else { 1000.0 }
        );
    }
    words[139] = 1;
    for resident in [false, true] {
        words[43] = f32::from(resident).to_bits();
        upload(&words);
        let values = run(&[("read_source_sky_predicates_test", 1)]);
        if !resident {
            assert_eq!(
                values[0], 0,
                "reprojected sky has no positive-hemisphere samples"
            );
        }
        assert_eq!(
            values[1],
            u32::from(resident),
            "source NaN hemisphere predicate"
        );
        assert_eq!(
            values[2],
            u32::from(resident),
            "source tangent hemisphere predicate"
        );
        assert_eq!(values[3], 0);
        assert_eq!(values[4], 1);
    }
}
