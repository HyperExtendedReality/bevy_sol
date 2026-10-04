#![recursion_limit = "256"]
//! Native GPU checks of streamed bounds and the light-grid RIS estimators.
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
use std::time::Duration;

#[test]
#[ignore = "requires Vulkan and slangc"]
fn streamed_grid_flat_bounds_and_merge_weights() {
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
    let world = app.sub_app(RenderApp).world();
    let device = world.resource::<RenderDevice>();
    let queue = world.resource::<RenderQueue>();
    let mut shader = bevy_slang::SlangCompiler::default()
        .with_source_root(concat!(env!("CARGO_MANIFEST_DIR"), "/src/shaders"))
        .compile_source(
            "light_grid_checks.slang",
            include_str!("light_grid_checks.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec![
                    "GI_HARDWARE=0".into(),
                    "GI_TEXTURED=0".into(),
                    "GI_SOURCE_RANDOM_BUFFER=1".into(),
                ],
                ..default()
            },
        )
        .unwrap();
    let bindings = [0, 1, 2, 20, 26, 27, 28];
    let mappings: Vec<_> = bindings
        .iter()
        .enumerate()
        .map(|(i, &binding)| bevy_slang::SpirvBindingRemap {
            group: 0,
            binding,
            mapped_binding: i as u32,
        })
        .collect();
    bevy_slang::remap_spirv_bindings(&mut shader, &mappings).unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!("expected SPIR-V");
    };
    // SAFETY: trusted embedded test source compiled and validated by Slang.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("streamed light-grid checks"),
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
    let make_buffer = |size, usage| {
        device.create_buffer(&BufferDescriptor {
            label: None,
            size,
            usage,
            mapped_at_creation: false,
        })
    };
    let uniform = make_buffer(576, BufferUsages::UNIFORM | BufferUsages::COPY_DST);
    let geometry = make_buffer(256, BufferUsages::STORAGE | BufferUsages::COPY_DST);
    let lights = make_buffer(8195 * 80, BufferUsages::STORAGE | BufferUsages::COPY_DST);
    let work = make_buffer(512, BufferUsages::STORAGE);
    let grid = make_buffer((24 + 4 * 4 * 4 * 64 * 4) * 4, BufferUsages::STORAGE);
    const SAMPLES: usize = 2048;
    let output_bytes = ((SAMPLES + 8) * 16) as u64;
    let lut = make_buffer(16384, BufferUsages::STORAGE);
    let output = make_buffer(output_bytes, BufferUsages::STORAGE | BufferUsages::COPY_SRC);
    let staging = make_buffer(
        output_bytes,
        BufferUsages::MAP_READ | BufferUsages::COPY_DST,
    );
    let layout = device.create_bind_group_layout(
        "grid check layout",
        &bindings.map(|binding| BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::Buffer {
                ty: if binding == 0 {
                    BufferBindingType::Uniform
                } else {
                    BufferBindingType::Storage {
                        read_only: binding == 1 || binding == 2,
                    }
                },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }),
    );
    let group = device.create_bind_group(
        "grid check bindings",
        &layout,
        &[
            (&uniform, 0),
            (&geometry, 1),
            (&lights, 2),
            (&work, 20),
            (&output, 26),
            (&lut, 27),
            (&grid, 28),
        ]
        .map(|(buffer, binding)| BindGroupEntry {
            binding,
            resource: buffer.as_entire_binding(),
        }),
    );
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let pipelines = [
        "compute_brdf_lut",
        "clear_light_grid_bounds",
        "seed_grid_checks",
        "calculate_light_grid_bounds",
        "build_light_grid",
        "build_light_grid_parallel",
        "parallel_source_checks",
        "discard_odd_grid_checks",
        "read_grid_checks",
        "material_target_checks",
    ]
    .map(|entry| {
        device.create_compute_pipeline(&RawComputePipelineDescriptor {
            label: Some(entry),
            layout: Some(&pipeline_layout),
            module: &module,
            entry_point: Some(entry),
            compilation_options: default(),
            cache: None,
        })
    });
    let mut packed_lights = vec![0.0f32; 8195 * 20];
    for i in 0..8193 {
        packed_lights[i * 20 + 2] = 1.0;
        packed_lights[i * 20 + 12..i * 20 + 15].fill((i + 1) as f32);
    }
    packed_lights[8193 * 20..8193 * 20 + 3].fill(-1.0 / 3.0f32.sqrt());
    packed_lights[8193 * 20 + 12..8193 * 20 + 15].fill(1.0);
    packed_lights[8194 * 20 + 3] = 0.5;
    packed_lights[8194 * 20 + 12..8194 * 20 + 15].fill(1.0);
    packed_lights[8194 * 20 + 15] = 1.0;
    let light_bytes: Vec<_> = packed_lights.iter().flat_map(|v| v.to_le_bytes()).collect();
    queue.write_buffer(&lights, 0, &light_bytes);
    let mut triangle = [0.0f32; 64];
    triangle[0..3].copy_from_slice(&[-1.0, -1.0, 0.0]);
    triangle[4..7].copy_from_slice(&[1.0, -1.0, 0.0]);
    triangle[8..11].copy_from_slice(&[-1.0, 1.0, 0.0]);
    triangle[49] = 0.5;
    triangle[52..55].fill(0.5);
    let triangle_bytes: Vec<_> = triangle.iter().flat_map(|v| v.to_le_bytes()).collect();
    queue.write_buffer(&geometry, 0, &triangle_bytes);
    for (projection, frame) in [(0u32, 1u32), (1, 0), (1, 7), (1, 255)] {
        for light_count in [0u32, 1, 7, 12, 65, 8193] {
            for mode in 0..3u32 {
                for resample in [false, true] {
                    for flags in [0u32, 1, 2, 3, 4, 8, 10, 15] {
                        for sparse in [false, true] {
                            let slots = light_count.min(64);
                            let mut params = [0u32; 144];
                            params[52] = frame;
                            params[57] = light_count;
                            params[62] = 0.001f32.to_bits();
                            params[63] = 100.0f32.to_bits();
                            params[139] = projection;
                            params[92..96].copy_from_slice(&[
                                4,
                                64,
                                flags,
                                mode | (u32::from(resample) << 2) | (u32::from(sparse) << 3),
                            ]);
                            let param_bytes: Vec<_> =
                                params.iter().flat_map(|v| v.to_le_bytes()).collect();
                            queue.write_buffer(&uniform, 0, &param_bytes);
                            let mut encoder =
                                device.create_command_encoder(&CommandEncoderDescriptor::default());
                            let parallel = flags & 8 != 0 && light_count > 128 * 64;
                            let faces = if flags & 2 != 0 { 8 } else { 1 };
                            for (index, pipeline) in pipelines.iter().enumerate() {
                                if (index == 4 && parallel) || (index == 5 && !parallel) {
                                    continue;
                                }
                                let mut pass =
                                    encoder.begin_compute_pass(&ComputePassDescriptor::default());
                                pass.set_pipeline(pipeline);
                                pass.set_bind_group(0, &group, &[]);
                                let groups = match index {
                                    4 | 7 => (4 * slots * faces).div_ceil(64).max(1),
                                    5 => (4 * slots * faces).max(1),
                                    8 => SAMPLES as u32 / 64,
                                    0 => 4,
                                    _ => 1,
                                };
                                pass.dispatch_workgroups(groups, if index == 0 { 4 } else { 1 }, 1);
                            }
                            encoder.copy_buffer_to_buffer(&output, 0, &staging, 0, output_bytes);
                            queue.submit([encoder.finish()]);
                            let (send, recv) = std::sync::mpsc::channel();
                            staging
                                .slice(..)
                                .map_async(MapMode::Read, move |status| send.send(status).unwrap());
                            device
                                .poll(PollType::Wait {
                                    submission_index: None,
                                    timeout: Some(Duration::from_secs(30)),
                                })
                                .unwrap();
                            recv.recv().unwrap().unwrap();
                            let data = staging.slice(..).get_mapped_range();
                            let values: Vec<_> = data
                                .as_chunks::<4>()
                                .0
                                .iter()
                                .map(|v| f32::from_le_bytes(*v))
                                .collect();
                            assert_eq!(&values[0..4], &[4.0, 1.0, 1.0, slots as f32]);
                            assert_eq!(values[7], 2.0);
                            assert!(values[4..7].iter().all(|v| v.is_finite() && *v > 0.0));
                            let sum = if sparse {
                                light_count.div_ceil(2).pow(2)
                            } else {
                                light_count * (light_count + 1) / 2
                            };
                            let expected = sum as f32 / std::f32::consts::PI;
                            let normalized = &values[(SAMPLES + 2) * 4..(SAMPLES + 3) * 4];
                            let reference = (0.5 * 0.96 * 1.05 + 0.04 * 0.25)
                                / std::f32::consts::PI
                                / (0.5 + 0.04 * normalized[1] + 0.96 * normalized[2]);
                            assert!(
                                (normalized[0] - reference).abs() < 1e-5,
                                "normalized BRDF target {normalized:?}, expected {reference}"
                            );
                            let options = &values[(SAMPLES + 3) * 4..(SAMPLES + 4) * 4];
                            assert_eq!(options[0], if faces == 8 { 0.0 } else { 1.0 });
                            let overlap = if flags & 4 != 0 {
                                (0.5 / 0.75f32.sqrt()).powi(3)
                            } else {
                                1.0
                            };
                            let point_weight = if flags & 1 != 0 {
                                10000.0 * overlap
                            } else {
                                0.0
                            };
                            assert!(
                                (options[1] - point_weight).abs() < point_weight * 0.0001 + 1e-5,
                                "cell overlap {options:?}, flags={flags}"
                            );
                            assert_eq!(options[2], f32::from(parallel));
                            assert_eq!(options[3], faces as f32);
                            if projection == 1 && parallel {
                                for check in values[(SAMPLES + 4) * 4..].as_chunks::<4>().0 {
                                    assert_eq!(
                                        check[0], 1.0,
                                        "source wave light selection {check:?}"
                                    );
                                    assert!(check[1] < 1e-6, "source wave total {check:?}");
                                    assert_eq!(check[2], 1.0, "source wave target {check:?}");
                                    assert!([16.0, 32.0, 64.0, 128.0].contains(&check[3]));
                                }
                            }
                            let samples = &values[8..(SAMPLES + 2) * 4];
                            let mean = samples.as_chunks::<4>().0.iter().map(|v| v[0]).sum::<f32>()
                                / SAMPLES as f32;
                            assert!(
                                (mean - expected).abs() <= expected * 0.02 + 1e-5,
                                "RIS mean {mean}, expected {expected}, lights={light_count}, mode={mode}, resample={resample}, flags={flags}, sparse={sparse}"
                            );
                            for sample in samples.as_chunks::<4>().0 {
                                assert!(sample.iter().all(|v| v.is_finite()));
                                if light_count == 0 {
                                    assert_eq!(sample[1], 0.0);
                                } else {
                                    let count = if mode == 1 {
                                        let segment = slots.div_ceil(8);
                                        (0..slots)
                                            .step_by(segment as usize)
                                            .filter(|start| {
                                                !sparse
                                                    || (*start..(start + segment).min(slots))
                                                        .any(|i| i % 2 == 0)
                                            })
                                            .count() as u32
                                    } else {
                                        8
                                    };
                                    assert_eq!(sample[1], count as f32);
                                    if sample[3] > 0.0 {
                                        assert!(sample[2] < light_count as f32);
                                    } else {
                                        // A random merge can draw eight empty slots. It still
                                        // has eight draws, contributes zero, and has no light.
                                        assert!(mode == 0 && sparse);
                                        assert_eq!(sample[0], 0.0);
                                        assert_eq!(sample[2], u32::MAX as f32);
                                    }
                                    if mode != 0 {
                                        assert!(
                                            (sample[0] - expected).abs() < expected * 0.0001 + 1e-5
                                        );
                                    }
                                }
                            }
                            drop(data);
                            staging.unmap();
                        }
                    }
                }
            }
        }
    }
}
