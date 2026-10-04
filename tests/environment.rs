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

fn pixels(case: usize) -> [[Vec3; 16]; 6] {
    std::array::from_fn(|face| {
        std::array::from_fn(|pixel| match case {
            0 => Vec3::new(0.5, 1.0, 2.0),
            1 | 3 if face == 4 => {
                if pixel % 5 == 0 {
                    Vec3::new(12.0, 3.0, 1.0)
                } else {
                    Vec3::ZERO
                }
            }
            1 if face != 5 => Vec3::new(0.1, 0.3, 0.5) * (pixel + 1) as f32 / 16.0,
            _ => Vec3::ZERO,
        })
    })
}

// Independent Vulkan cube lookup. AMD's importance sampler uses a different
// face-plane parameterization; this reference integrates world directions.
fn lookup(pixels: &[[Vec3; 16]; 6], direction: Vec3) -> Vec3 {
    let a = direction.abs();
    let (face, sc, tc, major) = if a.z >= a.x && a.z >= a.y {
        if direction.z > 0.0 {
            (4, direction.x, -direction.y, a.z)
        } else {
            (5, -direction.x, -direction.y, a.z)
        }
    } else if a.y >= a.x {
        if direction.y > 0.0 {
            (2, direction.x, direction.z, a.y)
        } else {
            (3, direction.x, -direction.z, a.y)
        }
    } else if direction.x > 0.0 {
        (0, -direction.z, -direction.y, a.x)
    } else {
        (1, direction.z, -direction.y, a.x)
    };
    let x = (((sc / major + 1.0) * 2.0) as usize).min(3);
    let y = (((tc / major + 1.0) * 2.0) as usize).min(3);
    pixels[face][x + 4 * y]
}

fn reference(pixels: &[[Vec3; 16]; 6], rotation: Quat, sky: Vec3, scale: f32) -> Vec3 {
    let mut sum = bevy::math::DVec3::ZERO;
    let steps = 512;
    for y in 0..steps {
        let z = (y as f64 + 0.5) / steps as f64;
        let radius = (1.0 - z * z).sqrt();
        for x in 0..steps {
            let phi = (x as f64 + 0.5) * std::f64::consts::TAU / steps as f64;
            let direction = Vec3::new(
                (radius * phi.cos()) as f32,
                (radius * phi.sin()) as f32,
                z as f32,
            );
            sum += (sky + scale * lookup(pixels, rotation.conjugate() * direction)).as_dvec3()
                * (2.0 * z);
        }
    }
    (sum / (steps * steps) as f64).as_vec3()
}

#[test]
#[ignore = "requires Vulkan and slangc"]
fn cubemap_orientation_importance_pdf_and_energy() {
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
            "environment_checks.slang",
            include_str!("environment_checks.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec!["GI_HARDWARE=0".into(), "GI_TEXTURED=0".into()],
                ..default()
            },
        )
        .unwrap();
    bevy_slang::remap_spirv_bindings(
        &mut shader,
        &[0, 26, 31, 32].map(|binding| bevy_slang::SpirvBindingRemap {
            group: 0,
            binding,
            mapped_binding: match binding {
                0 => 0,
                26 => 1,
                31 => 2,
                _ => 3,
            },
        }),
    )
    .unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!()
    };
    // SAFETY: trusted embedded fixture compiled and validated by Slang.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("environment differential"),
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
    const SAMPLES: usize = 262144;
    let size = ((14 + SAMPLES) * 16) as u64;
    let buffer = |size, usage| {
        device.create_buffer(&BufferDescriptor {
            label: None,
            size,
            usage,
            mapped_at_creation: false,
        })
    };
    let uniform = buffer(576, BufferUsages::UNIFORM | BufferUsages::COPY_DST);
    let output = buffer(size, BufferUsages::STORAGE | BufferUsages::COPY_SRC);
    let staging = buffer(size, BufferUsages::MAP_READ | BufferUsages::COPY_DST);
    let layout = device.create_bind_group_layout(
        "environment checks",
        &[
            BindGroupLayoutEntry {
                binding: 0,
                visibility: ShaderStages::COMPUTE,
                ty: BindingType::Buffer {
                    ty: BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            BindGroupLayoutEntry {
                binding: 26,
                visibility: ShaderStages::COMPUTE,
                ty: BindingType::Buffer {
                    ty: BufferBindingType::Storage { read_only: false },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            BindGroupLayoutEntry {
                binding: 31,
                visibility: ShaderStages::COMPUTE,
                ty: BindingType::Texture {
                    sample_type: TextureSampleType::Float { filterable: false },
                    view_dimension: TextureViewDimension::Cube,
                    multisampled: false,
                },
                count: None,
            },
            BindGroupLayoutEntry {
                binding: 32,
                visibility: ShaderStages::COMPUTE,
                ty: BindingType::Sampler(SamplerBindingType::NonFiltering),
                count: None,
            },
        ],
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
        entry_point: Some("check_environment"),
        compilation_options: default(),
        cache: None,
    });
    let sampler = device.create_sampler(&SamplerDescriptor::default());
    let directions = [
        Vec3::X,
        -Vec3::X,
        Vec3::Y,
        -Vec3::Y,
        Vec3::Z,
        -Vec3::Z,
        Vec3::new(1.0, 0.4, -0.3),
        Vec3::new(-1.0, 0.4, -0.3),
        Vec3::new(0.3, 1.0, -0.4),
        Vec3::new(0.3, -1.0, -0.4),
        Vec3::new(0.3, 0.4, 1.0),
        Vec3::new(0.3, 0.4, -1.0),
        Vec3::new(0.2, 0.6, 1.0),
        Vec3::new(-0.2, -0.6, 1.0),
    ];
    for case in 0..4 {
        let pixels = pixels(case);
        let texture = device.create_texture(&TextureDescriptor {
            label: None,
            size: Extent3d {
                width: 4,
                height: 4,
                depth_or_array_layers: 6,
            },
            mip_level_count: 3,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: TextureFormat::Rgba32Float,
            usage: TextureUsages::COPY_DST | TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        for face in 0..6u32 {
            let mut mip = pixels[face as usize].to_vec();
            for level in 0..3 {
                let width = 4 >> level;
                let bytes: Vec<_> = mip
                    .iter()
                    .flat_map(|v| v.extend(1.0).to_array())
                    .flat_map(f32::to_le_bytes)
                    .collect();
                queue.write_texture(
                    TexelCopyTextureInfo {
                        texture: &texture,
                        mip_level: level,
                        origin: Origin3d {
                            x: 0,
                            y: 0,
                            z: face,
                        },
                        aspect: TextureAspect::All,
                    },
                    &bytes,
                    TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(width * 16),
                        rows_per_image: Some(width),
                    },
                    Extent3d {
                        width,
                        height: width,
                        depth_or_array_layers: 1,
                    },
                );
                if width > 1 {
                    mip = (0..width / 2)
                        .flat_map(|y| (0..width / 2).map(move |x| (x, y)))
                        .map(|(x, y)| {
                            let i = (2 * x + 2 * y * width) as usize;
                            (mip[i]
                                + mip[i + 1]
                                + mip[i + width as usize]
                                + mip[i + width as usize + 1])
                                * 0.25
                        })
                        .collect();
                }
            }
        }
        let view = texture.create_view(&TextureViewDescriptor {
            dimension: Some(TextureViewDimension::Cube),
            ..default()
        });
        let group = device.create_bind_group(
            "environment checks",
            &layout,
            &[
                BindGroupEntry {
                    binding: 0,
                    resource: uniform.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 26,
                    resource: output.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 31,
                    resource: BindingResource::TextureView(&view),
                },
                BindGroupEntry {
                    binding: 32,
                    resource: BindingResource::Sampler(&sampler),
                },
            ],
        );
        for rotation in [
            Quat::IDENTITY,
            Quat::from_rotation_z(0.17) * Quat::from_rotation_y(0.7) * Quat::from_rotation_x(0.3),
        ] {
            for mode in 0..3 {
                let sky = if case >= 2 {
                    Vec3::ZERO
                } else {
                    Vec3::splat(0.025)
                };
                let mut words = [0u32; 144];
                words[34] = 1.0f32.to_bits();
                words[40..43].copy_from_slice(&sky.to_array().map(f32::to_bits));
                words[128..132].copy_from_slice(&rotation.conjugate().to_array().map(f32::to_bits));
                words[132..136].copy_from_slice(&[0.8f32, mode as f32, 4.0, 3.0].map(f32::to_bits));
                queue.write_buffer(
                    &uniform,
                    0,
                    &words
                        .into_iter()
                        .flat_map(u32::to_le_bytes)
                        .collect::<Vec<_>>(),
                );
                let mut encoder =
                    device.create_command_encoder(&CommandEncoderDescriptor::default());
                {
                    let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
                    pass.set_pipeline(&pipeline);
                    pass.set_bind_group(0, &group, &[]);
                    pass.dispatch_workgroups(SAMPLES as u32 / 64, 1, 1);
                }
                encoder.copy_buffer_to_buffer(&output, 0, &staging, 0, size);
                queue.submit([encoder.finish()]);
                let (send, recv) = std::sync::mpsc::channel();
                staging
                    .slice(..)
                    .map_async(MapMode::Read, move |v| send.send(v).unwrap());
                device
                    .poll(PollType::Wait {
                        submission_index: None,
                        timeout: Some(Duration::from_secs(30)),
                    })
                    .unwrap();
                recv.recv().unwrap().unwrap();
                let data = staging.slice(..).get_mapped_range();
                let values: Vec<_> = data
                    .as_chunks::<16>()
                    .0
                    .iter()
                    .map(|bytes| {
                        Vec4::from_array(std::array::from_fn(|i| {
                            f32::from_le_bytes(bytes[i * 4..i * 4 + 4].try_into().unwrap())
                        }))
                    })
                    .collect();
                for (i, direction) in directions.iter().enumerate() {
                    let expected =
                        sky + 0.8 * lookup(&pixels, rotation.conjugate() * direction.normalize());
                    assert!(
                        values[i].truncate().abs_diff_eq(expected, 1e-5),
                        "orientation {case}/{mode}/{i}: {} vs {expected}",
                        values[i]
                    );
                }
                let mut sum = bevy::math::DVec3::ZERO;
                for value in &values[14..] {
                    assert!(value.is_finite(), "nonfinite sample {value}");
                    assert!(
                        value.w < 0.004,
                        "sample/PDF disagreement {case}/{mode}: {value}"
                    );
                    sum += value.truncate().as_dvec3();
                }
                let mean = (sum / SAMPLES as f64).as_vec3();
                let expected = reference(&pixels, rotation, sky, 0.8);
                println!("environment case={case} mode={mode} mean={mean} reference={expected}");
                assert!(
                    mean.abs_diff_eq(expected, 0.015 * expected.max_element().max(0.1)),
                    "environment energy {mean} vs {expected}"
                );
                drop(data);
                staging.unmap();
            }
        }
    }
}
