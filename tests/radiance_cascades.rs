#![recursion_limit = "256"]
//! Native production cascade math compared with independent f64 references.
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
fn production_cascade_math_matches_independent_values() {
    let mut cases = Vec::<[f32; 16]>::new();
    let mut expected = Vec::<[f64; 4]>::new();
    for side in [2, 4, 8, 16, 32] {
        for y in 0..side {
            for x in 0..side {
                let u = (x as f64 + 0.5) / side as f64;
                let v = (y as f64 + 0.5) / side as f64;
                let z = 1.0 - 2.0 * v;
                let r = (1.0 - z * z).sqrt();
                let phi = std::f64::consts::TAU * u;
                let direction = [r * phi.cos(), r * phi.sin(), z];
                let mut input = [0.0; 16];
                input[0] = u as f32;
                input[1] = v as f32;
                cases.push(input);
                expected.push([direction[0], direction[1], direction[2], 1.0]);
                input[0..3].copy_from_slice(&direction.map(|v| v as f32));
                input[12] = 1.0;
                cases.push(input);
                expected.push([u, v, 0.0, 1.0]);
            }
        }
    }
    // Opaque, transparent and fractional intervals, including nested composition.
    for ta in [0.0_f32, 0.25, 0.5, 1.0] {
        for tb in [0.0_f32, 0.25, 0.5, 1.0] {
            for tc in [0.0_f32, 0.25, 0.5, 1.0] {
                let a = [0.25, 0.5, 1.0, ta];
                let b = [2.0, 4.0, 8.0, tb];
                let c = [16.0, 32.0, 64.0, tc];
                let mut input = [0.0; 16];
                input[..4].copy_from_slice(&a);
                input[4..8].copy_from_slice(&b);
                input[8..12].copy_from_slice(&c);
                input[12] = 2.0;
                cases.push(input);
                expected.push(std::array::from_fn(|i| {
                    if i == 3 {
                        f64::from(ta) * f64::from(tb)
                    } else {
                        f64::from(a[i]) + f64::from(ta) * f64::from(b[i])
                    }
                }));
                input[12] = 3.0;
                cases.push(input);
                expected.push(std::array::from_fn(|i| {
                    if i == 3 {
                        f64::from(ta) * f64::from(tb) * f64::from(tc)
                    } else {
                        f64::from(a[i])
                            + f64::from(ta) * f64::from(b[i])
                            + f64::from(ta) * f64::from(tb) * f64::from(c[i])
                    }
                }));
            }
        }
    }
    let transport_cases = cases.len();
    // Use exactly representable inputs around bin centers/edges, including the
    // azimuth seam and both poles. Derive expected indices/weights in f64.
    for side in [2, 4, 8, 16, 32, 64, 128] {
        for x in 0..=side {
            for offset in [0.0_f32, 0.25, 0.5, 0.75] {
                let u = (x as f32 + offset) / side as f32;
                if u > 1.0 {
                    continue;
                }
                for v in [0.0, 1.0 / 1024.0, 0.25, 0.5, 0.75, 1023.0 / 1024.0, 1.0] {
                    let coord = [
                        f64::from(u) * f64::from(side) - 0.5,
                        f64::from(v) * f64::from(side) - 0.5,
                    ];
                    let low = coord.map(f64::floor);
                    let blend = [coord[0] - low[0], coord[1] - low[1]];
                    let mut sum = 0.0;
                    for sample in 0..4 {
                        let dx = sample % 2;
                        let dy = sample / 2;
                        let weight = if dx == 0 { 1.0 - blend[0] } else { blend[0] }
                            * if dy == 0 { 1.0 - blend[1] } else { blend[1] };
                        sum += weight;
                        let mut input = [0.0; 16];
                        input[..4].copy_from_slice(&[u, v, side as f32, sample as f32]);
                        input[12] = 4.0;
                        cases.push(input);
                        expected.push([
                            (low[0] + f64::from(dx)).rem_euclid(f64::from(side)),
                            (low[1] + f64::from(dy)).clamp(0.0, f64::from(side - 1)),
                            weight,
                            1.0,
                        ]);
                    }
                    assert_eq!(sum, 1.0);
                }
            }
        }
    }
    let angular_cases = cases.len() - transport_cases;
    for dimensions in [[1, 1], [1, 5], [5, 1], [5, 3], [17, 9], [80, 80]] {
        for x in [
            -1.25,
            -0.5,
            0.0,
            0.25,
            0.75,
            dimensions[0] as f32 - 0.5,
            dimensions[0] as f32,
        ] {
            for y in [
                -1.25,
                -0.5,
                0.0,
                0.25,
                0.75,
                dimensions[1] as f32 - 0.5,
                dimensions[1] as f32,
            ] {
                let coord = [f64::from(x), f64::from(y)];
                let low = coord.map(f64::floor);
                let blend = [coord[0] - low[0], coord[1] - low[1]];
                for sample in 0..4 {
                    let dx = sample % 2;
                    let dy = sample / 2;
                    let mut input = [0.0; 16];
                    input[..4].copy_from_slice(&[x, y, 0.0, sample as f32]);
                    input[4..6].copy_from_slice(&dimensions.map(|v| v as f32));
                    input[12] = 5.0;
                    cases.push(input);
                    expected.push([
                        (low[0] + f64::from(dx)).clamp(0.0, f64::from(dimensions[0] - 1)),
                        (low[1] + f64::from(dy)).clamp(0.0, f64::from(dimensions[1] - 1)),
                        if dx == 0 { 1.0 - blend[0] } else { blend[0] }
                            * if dy == 0 { 1.0 - blend[1] } else { blend[1] },
                        1.0,
                    ]);
                }
            }
        }
    }
    let spatial_cases = cases.len() - transport_cases - angular_cases;
    for position in [[0.0, 0.0, 0.0], [-3.0, 2.0, 7.0]] {
        for normal in [[1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.6, 0.8, 0.0]] {
            for direction in [[0.0, 0.0, 1.0], [-0.8, 0.0, 0.6], [0.0, 1.0, 0.0]] {
                for bias in [0.0, 0.005, 0.125] {
                    for distance in [0.0, 0.5, 1.5, 7.5] {
                        let mut input = [0.0; 16];
                        input[..3].copy_from_slice(&position);
                        input[3] = bias;
                        input[4..7].copy_from_slice(&normal);
                        input[7] = distance;
                        input[8..11].copy_from_slice(&direction);
                        input[12] = 6.0;
                        cases.push(input);
                        expected.push(std::array::from_fn(|i| {
                            if i == 3 {
                                1.0
                            } else {
                                f64::from(position[i])
                                    + f64::from(normal[i]) * f64::from(bias)
                                    + f64::from(direction[i]) * f64::from(distance)
                            }
                        }));
                    }
                }
            }
        }
    }
    let boundary_cases = cases.len() - transport_cases - angular_cases - spatial_cases;
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
    let shader = bevy_slang::SlangCompiler::default()
        .with_source_root(concat!(env!("CARGO_MANIFEST_DIR"), "/src/shaders"))
        .compile_source(
            "radiance_cascade_checks.slang",
            include_str!("radiance_cascade_checks.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec![format!("FIXTURE_CASES={}", cases.len())],
                ..default()
            },
        )
        .unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!("expected native SPIR-V")
    };
    // SAFETY: trusted embedded test source compiled and validated by Slang.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("cascade math checks"),
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
    let make_buffer = |size, usage| {
        device.create_buffer(&BufferDescriptor {
            label: None,
            size,
            usage,
            mapped_at_creation: false,
        })
    };
    let input = make_buffer(
        cases.len() as u64 * 64,
        BufferUsages::STORAGE | BufferUsages::COPY_DST,
    );
    let output = make_buffer(
        cases.len() as u64 * 16,
        BufferUsages::STORAGE | BufferUsages::COPY_SRC,
    );
    let staging = make_buffer(
        output.size(),
        BufferUsages::MAP_READ | BufferUsages::COPY_DST,
    );
    let layout = device.create_bind_group_layout(
        "cascade math layout",
        &[0, 1].map(|binding| BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::Buffer {
                ty: BufferBindingType::Storage {
                    read_only: binding == 0,
                },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }),
    );
    let group = device.create_bind_group(
        "cascade math bindings",
        &layout,
        &[(&input, 0), (&output, 1)].map(|(buffer, binding)| BindGroupEntry {
            binding,
            resource: buffer.as_entire_binding(),
        }),
    );
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let pipeline = device.create_compute_pipeline(&RawComputePipelineDescriptor {
        label: None,
        layout: Some(&pipeline_layout),
        module: &module,
        entry_point: Some("evaluate"),
        compilation_options: default(),
        cache: None,
    });
    queue.write_buffer(
        &input,
        0,
        &cases
            .iter()
            .flatten()
            .flat_map(|v| v.to_le_bytes())
            .collect::<Vec<_>>(),
    );
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor { label: None });
    {
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
            label: None,
            timestamp_writes: None,
        });
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups((cases.len() as u32).div_ceil(64), 1, 1);
    }
    encoder.copy_buffer_to_buffer(&output, 0, &staging, 0, output.size());
    queue.submit([encoder.finish()]);
    let (send, receive) = std::sync::mpsc::channel();
    staging
        .slice(..)
        .map_async(MapMode::Read, move |result| send.send(result).unwrap());
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
    let actual: Vec<_> = mapped
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| f32::from_le_bytes(*v))
        .collect();
    for (index, (actual, expected)) in actual.as_chunks::<4>().0.iter().zip(expected).enumerate() {
        for channel in 0..4 {
            assert!(actual[channel].is_finite());
            assert!(
                (f64::from(actual[channel]) - expected[channel]).abs() < 1e-5,
                "case {index}, channel {channel}: {} versus {}",
                actual[channel],
                expected[channel]
            );
        }
    }
    drop(mapped);
    staging.unmap();
    println!(
        "{} native cascade cases passed: transport={transport_cases}, angular={angular_cases}, spatial={spatial_cases}, boundary={boundary_cases}",
        cases.len(),
    );
}
