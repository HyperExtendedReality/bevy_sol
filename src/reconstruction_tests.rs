use super::*;
use bevy::{
    camera::{Exposure, RenderTarget, Viewport},
    core_pipeline::tonemapping::Tonemapping,
    light::GlobalAmbientLight,
    render::gpu_readback::{Readback, ReadbackComplete},
    window::ExitCondition,
    winit::WinitPlugin,
};
use std::time::{Duration, Instant};

#[derive(Resource, Default)]
struct Sample {
    frames: u32,
    color: Vec3,
}

fn input(size: u32, pixel: impl Fn(u32, u32) -> [f32; 4]) -> bevy::prelude::Image {
    let pixel = &pixel;
    bevy::prelude::Image::new(
        Extent3d {
            width: size,
            height: size,
            depth_or_array_layers: 1,
        },
        TextureDimension::D2,
        (0..size)
            .flat_map(|y| (0..size).flat_map(move |x| pixel(x, y)))
            .flat_map(f32::to_le_bytes)
            .collect(),
        TextureFormat::Rgba32Float,
        bevy::asset::RenderAssetUsages::default(),
    )
}

fn settle(app: &mut App, expected: impl Fn(Vec3) -> bool) -> Vec3 {
    let start = app.world().resource::<Sample>().frames;
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        app.update();
        let sample = app.world().resource::<Sample>();
        if sample.frames > start + 24 && expected(sample.color) {
            return sample.color;
        }
        assert!(
            Instant::now() < deadline,
            "reconstruction did not converge: {:?}",
            sample.color
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
#[ignore = "requires Vulkan and slangc"]
fn source_optional_inputs_and_irradiance_units() {
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
    )
    .init_resource::<Sample>()
    .insert_resource(GlobalAmbientLight {
        brightness: 0.0,
        ..default()
    })
    .add_plugins(crate::HybridGiPlugin {
        config: crate::HybridGiConfig {
            ray_backend: GiRayBackend::Software,
            source_disable_specular_materials: true,
            sky_radiance: Vec3::ONE,
            probe_sampling: crate::ProbeSamplingMode::FullSpp,
            cache_capacity: 1024,
            hash_grid: crate::HashGridCacheConfig {
                num_buckets: 16,
                tiles_per_bucket: 2,
                ..default()
            },
            ..default()
        },
    });
    let (target, closed, forward, backward, near, invalid, unsampled) = {
        let mut images = app
            .world_mut()
            .resource_mut::<Assets<bevy::prelude::Image>>();
        let mut target =
            bevy::prelude::Image::new_target_texture(32, 32, TextureFormat::Rgba32Float, None);
        target.texture_descriptor.usage |= TextureUsages::COPY_SRC;
        let mut unsampled = input(32, |_, _| [100.0; 4]);
        unsampled.texture_descriptor.usage |= TextureUsages::RENDER_ATTACHMENT;
        unsampled.texture_view_descriptor = Some(TextureViewDescriptor {
            usage: Some(TextureUsages::RENDER_ATTACHMENT),
            ..default()
        });
        (
            images.add(target),
            images.add(input(32, |_, _| [0.5, 0.5, 1.0, 0.0])),
            images.add(input(32, |_, _| [0.5, 0.5, 1.0, 1.0])),
            images.add(input(32, |_, _| [0.5, 0.5, 0.0, 1.0])),
            images.add(input(32, |x, y| {
                [2.0 + x as f32 * 0.25, 4.0 + y as f32 * 0.25, 6.0, 1.0]
            })),
            images.add(input(2, |_, _| [100.0; 4])),
            images.add(unsampled),
        )
    };
    let mesh = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(8.0, 8.0, 0.1));
    let material = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::linear_rgb(0.5, 0.5, 0.5),
            perceptual_roughness: 1.0,
            ..default()
        });
    app.world_mut()
        .spawn((Mesh3d(mesh), MeshMaterial3d(material)));
    let camera = app
        .world_mut()
        .spawn((
            Camera3d::default(),
            HybridGi {
                reflections: false,
                ..default()
            },
            Msaa::Off,
            Tonemapping::None,
            Exposure { ev100: 0.0 },
            RenderTarget::Image(target.clone().into()),
            Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
        ))
        .id();
    app.world_mut().spawn(Readback::texture(target)).observe(
        |event: On<ReadbackComplete>, mut sample: ResMut<Sample>| {
            sample.color = Vec3::from_array(std::array::from_fn(|c| {
                let offset = ((16 * 32 + 16) * 4 + c) * 4;
                f32::from_le_bytes(event.data[offset..offset + 4].try_into().unwrap())
            }));
            sample.frames += 1;
        },
    );
    app.finish();
    app.cleanup();
    let baseline = settle(&mut app, |color| color.min_element() > 0.08);
    app.world_mut()
        .entity_mut(camera)
        .insert(GiReconstructionInputs {
            occlusion_and_bent_normal: closed.clone(),
            near_field_irradiance: None,
        });
    settle(&mut app, |color| color.abs().max_element() < 0.002);
    app.world_mut()
        .get_mut::<GiReconstructionInputs>(camera)
        .unwrap()
        .near_field_irradiance = Some(near.clone());
    let expected =
        Vec3::new(6.0, 8.0, 6.0) * 0.5 * Exposure { ev100: 0.0 }.exposure() / std::f32::consts::PI;
    settle(&mut app, |color| {
        (color - expected).abs().max_element() < 0.02
    });
    app.world_mut().get_mut::<Camera>(camera).unwrap().viewport = Some(Viewport {
        physical_position: UVec2::new(4, 2),
        physical_size: UVec2::new(24, 26),
        ..default()
    });
    settle(&mut app, |color| {
        (color - expected).abs().max_element() < 0.02
    });
    app.world_mut()
        .get_mut::<GiReconstructionInputs>(camera)
        .unwrap()
        .near_field_irradiance = Some(invalid.clone());
    settle(&mut app, |color| color.abs().max_element() < 0.002);
    app.world_mut()
        .get_mut::<GiReconstructionInputs>(camera)
        .unwrap()
        .near_field_irradiance = Some(unsampled);
    settle(&mut app, |color| color.abs().max_element() < 0.002);
    app.world_mut()
        .get_mut::<GiReconstructionInputs>(camera)
        .unwrap()
        .occlusion_and_bent_normal = forward;
    let front = settle(&mut app, |color| color.min_element() > 0.08);
    app.world_mut()
        .get_mut::<GiReconstructionInputs>(camera)
        .unwrap()
        .occlusion_and_bent_normal = backward;
    settle(&mut app, |color| {
        color.max_element() < front.min_element() * 0.3
    });
    app.world_mut()
        .entity_mut(camera)
        .insert(GiReconstructionInputs {
            occlusion_and_bent_normal: invalid,
            near_field_irradiance: Some(near),
        });
    settle(&mut app, |color| {
        color.min_element() > baseline.min_element() * 0.5
    });
    app.world_mut()
        .entity_mut(camera)
        .remove::<GiReconstructionInputs>();
    settle(&mut app, |color| {
        color.min_element() > baseline.min_element() * 0.5
    });
}
