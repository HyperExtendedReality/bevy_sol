use super::*;
use bevy::{
    camera::{Exposure, RenderTarget},
    light::GlobalAmbientLight,
    window::ExitCondition,
    winit::WinitPlugin,
};
use std::time::{Duration, Instant};

#[test]
#[ignore = "requires Vulkan and slangc"]
fn moving_receiver_preserves_history_and_reads_bevy_motion_vectors() {
    let hardware = std::env::var("BEVY_SOL_TEST_HARDWARE").as_deref() == Ok("1");
    let motion = std::env::var("BEVY_SOL_TEST_MOTION").unwrap_or_else(|_| "rigid".into());
    let mut wgpu = bevy::render::settings::WgpuSettings::default();
    if hardware {
        wgpu.features |= WgpuFeatures::EXPERIMENTAL_RAY_QUERY;
    }
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
            .set(WindowPlugin {
                primary_window: None,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .set(bevy::render::RenderPlugin {
                render_creation: bevy::render::settings::RenderCreation::Automatic(Box::new(wgpu)),
                ..default()
            })
            .disable::<WinitPlugin>()
            .disable::<bevy::render::pipelined_rendering::PipelinedRenderingPlugin>(),
    )
    .insert_resource(GlobalAmbientLight {
        brightness: 0.0,
        ..default()
    })
    .add_plugins(crate::HybridGiPlugin {
        config: crate::HybridGiConfig {
            ray_backend: if hardware {
                GiRayBackend::Hardware
            } else {
                GiRayBackend::Software
            },
            sky_radiance: Vec3::ONE,
            diffuse_denoiser: if std::env::var("BEVY_SOL_TEST_DIFFUSE_MODE").as_deref()
                == Ok("atrous")
            {
                crate::DiffuseDenoiser::TemporalVarianceAtrous
            } else {
                crate::DiffuseDenoiser::AdaptiveSeparable
            },
            cache_capacity: 1024,
            hash_grid: crate::HashGridCacheConfig {
                num_buckets: 256,
                tiles_per_bucket: 4,
                ..default()
            },
            ..default()
        },
    });
    let image = app
        .world_mut()
        .resource_mut::<Assets<bevy::image::Image>>()
        .add(bevy::image::Image::new_target_texture(
            32,
            32,
            TextureFormat::Rgba16Float,
            None,
        ));
    let mut receiver_mesh = Mesh::from(Cuboid::new(4.0, 4.0, 0.1));
    let vertex_count = receiver_mesh.count_vertices();
    if motion == "skin" {
        receiver_mesh.insert_attribute(
            Mesh::ATTRIBUTE_JOINT_INDEX,
            bevy::mesh::VertexAttributeValues::Uint16x4(vec![[0, 0, 0, 0]; vertex_count]),
        );
        receiver_mesh.insert_attribute(
            Mesh::ATTRIBUTE_JOINT_WEIGHT,
            vec![[1.0, 0.0, 0.0, 0.0]; vertex_count],
        );
    }
    if motion == "morph" {
        receiver_mesh.set_morph_targets(vec![
            bevy::mesh::morph::MorphAttributes::new(
                Vec3::X,
                Vec3::ZERO,
                Vec3::ZERO
            );
            vertex_count
        ]);
    }
    let mesh = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(receiver_mesh);
    let material = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::linear_rgb(0.5, 0.5, 0.5),
            perceptual_roughness: 1.0,
            ..default()
        });
    let receiver = app
        .world_mut()
        .spawn((Mesh3d(mesh), MeshMaterial3d(material), Transform::default()))
        .id();
    let joint = app.world_mut().spawn(Transform::default()).id();
    if motion == "skin" {
        let inverse = app
            .world_mut()
            .resource_mut::<Assets<bevy::mesh::skinning::SkinnedMeshInverseBindposes>>()
            .add(vec![Mat4::IDENTITY]);
        app.world_mut()
            .entity_mut(receiver)
            .insert(bevy::mesh::skinning::SkinnedMesh {
                inverse_bindposes: inverse,
                joints: vec![joint],
            });
    }
    if motion == "morph" {
        app.world_mut()
            .entity_mut(receiver)
            .insert(bevy::mesh::morph::MeshMorphWeights::Value { weights: vec![0.0] });
    }
    app.world_mut().spawn((
        Camera3d::default(),
        HybridGi {
            reflections: false,
            ..default()
        },
        Msaa::Off,
        Exposure { ev100: 0.0 },
        RenderTarget::Image(image.into()),
        Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    app.finish();
    app.cleanup();
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        app.update();
        let world = app.sub_app_mut(RenderApp).world_mut();
        if world
            .query::<&ViewGi>()
            .iter(world)
            .any(|view| view.frames >= 100)
        {
            break;
        }
        assert!(Instant::now() < deadline, "GI pipelines did not render");
        std::thread::sleep(Duration::from_millis(5));
    }
    let world = app.sub_app_mut(RenderApp).world_mut();
    let device = world.resource::<RenderDevice>().clone();
    let queue = world.resource::<RenderQueue>().clone();
    let shader = bevy_slang::SlangCompiler::default()
        .compile_source(
            "motion_history.slang",
            r#"
        [[vk::binding(0,0)]] Texture2D<float2> velocity;
        [[vk::binding(1,0)]] Texture2D<float4> history;
        [[vk::binding(2,0)]] RWStructuredBuffer<float4> result;
        [shader("compute")][numthreads(1,1,1)] void read_history() {
            let color=history.Load(int3(16,16,0));
            result[0]=float4(velocity.Load(int3(16,16,0)),color.w,color.x/max(color.w,1.0));
        }
    "#,
            &bevy_slang::SlangSettings::default(),
        )
        .unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!()
    };
    // SAFETY: the fixed embedded test shader is compiled and validated by Slang.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("motion history regression"),
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
    let layout = device.create_bind_group_layout(
        "motion history",
        &[
            texture_layout(0, TextureSampleType::Float { filterable: false }),
            texture_layout(1, TextureSampleType::Float { filterable: false }),
            buffer_layout(2, false, 16),
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
        entry_point: Some("read_history"),
        compilation_options: default(),
        cache: None,
    });
    let result = device.create_buffer(&BufferDescriptor {
        label: None,
        size: 16,
        usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let staging = device.create_buffer(&BufferDescriptor {
        label: None,
        size: 16,
        usage: BufferUsages::MAP_READ | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let read = |app: &mut App| {
        let world = app.sub_app_mut(RenderApp).world_mut();
        let (view, prepass) = world
            .query::<(&ViewGi, &ViewPrepassTextures)>()
            .single(world)
            .unwrap();
        let group = device.create_bind_group(
            "motion history",
            &layout,
            &[
                BindGroupEntry {
                    binding: 0,
                    resource: BindingResource::TextureView(prepass.motion_vectors_view().unwrap()),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: BindingResource::TextureView(&view.previous_diffuse.view),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: result.as_entire_binding(),
                },
            ],
        );
        let reset = view.params.get().frame.y;
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
        {
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        encoder.copy_buffer_to_buffer(&result, 0, &staging, 0, 16);
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
        let values = Vec4::from_array(std::array::from_fn(|i| {
            f32::from_le_bytes(data.as_chunks::<4>().0[i])
        }));
        drop(data);
        staging.unmap();
        (reset, values)
    };
    let (_, stationary) = read(&mut app);
    assert!(stationary.z > 20.0, "warm history: {stationary}");
    for frame in 1..=12 {
        if motion == "morph" {
            app.world_mut().entity_mut(receiver).insert(
                bevy::mesh::morph::MeshMorphWeights::Value {
                    weights: vec![frame as f32 * 0.002],
                },
            );
        } else {
            app.world_mut()
                .get_mut::<Transform>(if motion == "skin" { joint } else { receiver })
                .unwrap()
                .translation
                .x = frame as f32 * 0.002;
        }
        app.update();
        let (reset, moving) = read(&mut app);
        assert_eq!(
            reset, 2,
            "pose changes clear caches, preserving pixel histories"
        );
        assert!(
            moving.x > 0.0001 && moving.x < 0.001,
            "receiver velocity: {moving}"
        );
        assert!(moving.y.abs() < 1e-5, "horizontal motion: {moving}");
        assert!(moving.z > 20.0, "moving history must not restart: {moving}");
        assert!(
            (moving.w - stationary.w).abs() < 0.05,
            "uniform lighting stays stable: {moving} vs {stationary}"
        );
    }
}
