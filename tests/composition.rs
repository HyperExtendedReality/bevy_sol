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
fn source_primary_albedo_override_renders_through_production_composition() {
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
            "composite.slang",
            include_str!("../src/shaders/composite.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                ..default()
            },
        )
        .unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!("expected native SPIR-V")
    };
    // SAFETY: Slang validates the production shader before native SPIR-V loading.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("production GI composition fixture"),
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
    let uniform = device.create_buffer(&BufferDescriptor {
        label: None,
        size: 64,
        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let extent = Extent3d {
        width: 1,
        height: 1,
        depth_or_array_layers: 1,
    };
    let input = |format, bytes: &[u8]| {
        let texture = device.create_texture(&TextureDescriptor {
            label: None,
            size: extent,
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format,
            usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            texture.as_image_copy(),
            bytes,
            TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(16),
                rows_per_image: Some(1),
            },
            extent,
        );
        texture
    };
    let float_bytes = |values: [f32; 4]| {
        values
            .into_iter()
            .flat_map(f32::to_le_bytes)
            .collect::<Vec<_>>()
    };
    let diffuse = input(
        TextureFormat::Rgba32Float,
        &float_bytes([2.0, 3.0, 4.0, 2.0]),
    );
    let specular = input(
        TextureFormat::Rgba32Float,
        &float_bytes([0.2, 0.1, 0.3, 1.0]),
    );
    let gbuffer = input(
        TextureFormat::Rgba32Uint,
        &[
            u32::from_le_bytes([64, 128, 192, 128]),
            0,
            u32::from_le_bytes([128, 191, 153, 0]),
            0,
        ]
        .into_iter()
        .flat_map(u32::to_le_bytes)
        .collect::<Vec<_>>(),
    );
    let position = input(
        TextureFormat::Rgba32Float,
        &float_bytes([0.0, 0.0, -1.0, 1.0]),
    );
    let normal = input(
        TextureFormat::Rgba32Float,
        &float_bytes([0.0, 0.0, 1.0, 1.0]),
    );
    let views = [&diffuse, &specular, &gbuffer, &position, &normal]
        .map(|texture| texture.create_view(&default()));
    let mut entries = vec![BindGroupLayoutEntry {
        binding: 0,
        visibility: ShaderStages::FRAGMENT,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: BufferSize::new(64),
        },
        count: None,
    }];
    for binding in 1..=5 {
        entries.push(BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Texture {
                sample_type: if binding == 3 {
                    TextureSampleType::Uint
                } else {
                    TextureSampleType::Float { filterable: false }
                },
                view_dimension: TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        });
    }
    let layout = device.create_bind_group_layout(None, &entries);
    let mut bindings = vec![BindGroupEntry {
        binding: 0,
        resource: uniform.as_entire_binding(),
    }];
    bindings.extend(views.iter().enumerate().map(|(i, view)| BindGroupEntry {
        binding: i as u32 + 1,
        resource: BindingResource::TextureView(view),
    }));
    let group = device.create_bind_group(None, &layout, &bindings);
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let pipeline = device.create_render_pipeline(&RawRenderPipelineDescriptor {
        label: None,
        layout: Some(&pipeline_layout),
        vertex: RawVertexState {
            module: &module,
            entry_point: Some("vertex"),
            compilation_options: default(),
            buffers: &[],
        },
        primitive: default(),
        depth_stencil: None,
        multisample: default(),
        fragment: Some(RawFragmentState {
            module: &module,
            entry_point: Some("fragment"),
            compilation_options: default(),
            targets: &[Some(ColorTargetState {
                format: TextureFormat::Rgba32Float,
                blend: None,
                write_mask: ColorWrites::ALL,
            })],
        }),
        multiview_mask: None,
        cache: None,
    });
    let target = device.create_texture(&TextureDescriptor {
        label: None,
        size: extent,
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: TextureFormat::Rgba32Float,
        usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let target_view = target.create_view(&default());
    let staging = device.create_buffer(&BufferDescriptor {
        label: None,
        size: 256,
        usage: BufferUsages::MAP_READ | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    for flags in [0u32, 1, 4, 5, 7] {
        for reflections in [false, true] {
            for normalize_confidence in [false, true] {
                let mut params = [0u32; 16];
                params[..4].copy_from_slice(&[0, 0, 1, 1]);
                params[4..8].copy_from_slice(&[
                    1.7f32.to_bits(),
                    f32::from(reflections).to_bits(),
                    f32::from(normalize_confidence).to_bits(),
                    (flags as f32).to_bits(),
                ]);
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
                    let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                        color_attachments: &[Some(RenderPassColorAttachment {
                            view: &target_view,
                            depth_slice: None,
                            resolve_target: None,
                            ops: Operations {
                                load: LoadOp::Clear(default()),
                                store: StoreOp::Store,
                            },
                        })],
                        ..default()
                    });
                    pass.set_pipeline(&pipeline);
                    pass.set_bind_group(0, &group, &[]);
                    pass.draw(0..3, 0..1);
                }
                encoder.copy_texture_to_buffer(
                    target.as_image_copy(),
                    TexelCopyBufferInfo {
                        buffer: &staging,
                        layout: TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(256),
                            rows_per_image: Some(1),
                        },
                    },
                    extent,
                );
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
                let actual: Vec<_> = staging.slice(..).get_mapped_range()[..16]
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|v| f32::from_le_bytes(*v))
                    .collect();
                staging.unmap();
                let disabled = flags & 5 == 5;
                let metallic = 191.0f32 / 255.0;
                let reflectance = 128.0f32 / 255.0;
                for channel in 0..3 {
                    let base = ([64.0f32, 128.0, 192.0][channel] / 255.0).powf(2.2);
                    let albedo = if disabled {
                        0.3
                    } else {
                        base * (1.0 - metallic)
                    };
                    let f0 = if disabled {
                        0.0
                    } else {
                        0.16 * reflectance * reflectance * (1.0 - metallic) + base * metallic
                    };
                    let compensation = if reflections { (1.0 - f0) * 1.05 } else { 1.0 };
                    let irradiance =
                        [2.0, 3.0, 4.0][channel] / if normalize_confidence { 2.0 } else { 1.0 };
                    let expected =
                        (irradiance * albedo * compensation * 0.6 + [0.2, 0.1, 0.3][channel]) * 1.7;
                    assert!(
                        (actual[channel] - expected).abs() < 1e-5,
                        "flags {flags}, reflections {reflections}, confidence {normalize_confidence}, channel {channel}: {} != {expected}",
                        actual[channel]
                    );
                }
                assert_eq!(actual[3], 0.0);
            }
        }
    }
}
