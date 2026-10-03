//! Real GPU regression: off-screen emissive transport and history invalidation.
//! Run: cargo test --test gpu -- --ignored --nocapture
use bevy::{
    camera::{Exposure, RenderTarget},
    core_pipeline::tonemapping::Tonemapping,
    light::GlobalAmbientLight,
    prelude::*,
    render::{
        gpu_readback::{Readback, ReadbackComplete},
        render_resource::TextureFormat,
    },
    window::ExitCondition,
    winit::WinitPlugin,
};
use bevy_sol::{GiExclude, GiRayBackend, GiStatistics, HybridGi, HybridGiConfig, HybridGiPlugin};
use std::time::{Duration, Instant};

#[derive(Resource, Default)]
struct Samples {
    generation: u32,
    mean: f32,
    left: Vec3,
    right: Vec3,
}

#[test]
#[ignore = "requires a compute-capable GPU"]
fn offscreen_emission_and_history_invalidation() {
    let mut app = App::new();
    let hardware = std::env::var("BEVY_SOL_TEST_HARDWARE").as_deref() == Ok("1");
    let feedback = std::env::var("BEVY_SOL_TEST_FEEDBACK").as_deref() == Ok("1");
    let mut wgpu = bevy::render::settings::WgpuSettings::default();
    if hardware {
        wgpu.features |= bevy::render::settings::WgpuFeatures::EXPERIMENTAL_RAY_QUERY;
    }
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
            .disable::<WinitPlugin>()
            .disable::<bevy::render::pipelined_rendering::PipelinedRenderingPlugin>(),
    )
    .init_resource::<Samples>()
    .insert_resource(GlobalAmbientLight {
        brightness: 0.0,
        ..default()
    })
    .add_plugins(HybridGiPlugin {
        config: HybridGiConfig {
            reflection: bevy_sol::ReflectionConfig {
                half_resolution: std::env::var("BEVY_SOL_TEST_FULL_REFLECTIONS").as_deref()
                    != Ok("1"),
                denoiser: match std::env::var("BEVY_SOL_TEST_REFLECTION_MODE").as_deref() {
                    Ok("split") => bevy_sol::ReflectionDenoiser::SplitRatioEstimator,
                    Ok("none") => bevy_sol::ReflectionDenoiser::None,
                    _ => bevy_sol::ReflectionDenoiser::AtrousRatioEstimator,
                },
                ..default()
            },
            hash_grid: bevy_sol::HashGridCacheConfig {
                num_buckets: 256,
                tiles_per_bucket: 4,
                ..default()
            },
            temporal_feedback: feedback,
            multibounce: !feedback,
            ray_backend: if hardware {
                GiRayBackend::Hardware
            } else {
                GiRayBackend::Software
            },
            cache_capacity: 4096,
            direct_samples: 2,
            history_samples: 8,
            ..default()
        },
    });
    let mut target_image = Image::new_target_texture(128, 128, TextureFormat::Rgba8UnormSrgb, None);
    target_image.texture_descriptor.usage |= bevy::render::render_resource::TextureUsages::COPY_SRC;
    let image = app
        .world_mut()
        .resource_mut::<Assets<Image>>()
        .add(target_image);
    let wall = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(6.0, 6.0, 0.1));
    let emitter_mesh = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(4.0, 0.1, 3.0));
    let white = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::srgb(0.8, 0.8, 0.8),
            perceptual_roughness: 1.0,
            ..default()
        });
    let emission = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::BLACK,
            emissive: LinearRgba::rgb(8.0, 4.0, 2.0),
            ..default()
        });
    let receiver = app
        .world_mut()
        .spawn((Mesh3d(wall), MeshMaterial3d(white.clone())))
        .id();
    let emitter = app
        .world_mut()
        .spawn((
            Mesh3d(emitter_mesh),
            MeshMaterial3d(emission.clone()),
            Transform::from_xyz(0.0, 3.0, 2.0),
        ))
        .id();
    let camera = app
        .world_mut()
        .spawn((
            Camera3d::default(),
            Camera {
                clear_color: Color::BLACK.into(),
                ..default()
            },
            HybridGi {
                reflections: false,
                ..default()
            },
            Msaa::Off,
            Tonemapping::None,
            Exposure { ev100: 0.0 },
            RenderTarget::Image(image.clone().into()),
            Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
        ))
        .id();
    app.world_mut()
        .spawn(Readback::texture(image.clone()))
        .observe(
            |event: On<ReadbackComplete>, mut samples: ResMut<Samples>| {
                // 128 RGBA8 pixels occupy 512 bytes: no padded-row ambiguity. Inspect only
                // the central receiver, where the off-screen emitter cannot be rasterized.
                let mut total = 0u64;
                for y in 48..80 {
                    for x in 48..80 {
                        let i = (y * 128 + x) * 4;
                        total += u64::from(event.data[i])
                            + u64::from(event.data[i + 1])
                            + u64::from(event.data[i + 2]);
                    }
                }
                samples.mean = total as f32 / (32.0 * 32.0 * 3.0 * 255.0);
                for (left, start) in [(true, 48), (false, 72)] {
                    let mut color = Vec3::ZERO;
                    for y in 48..80 {
                        for x in start..start + 8 {
                            let i = (y * 128 + x) * 4;
                            color += Vec3::new(
                                f32::from(event.data[i]),
                                f32::from(event.data[i + 1]),
                                f32::from(event.data[i + 2]),
                            );
                        }
                    }
                    color /= 32.0 * 8.0 * 255.0;
                    if left {
                        samples.left = color;
                    } else {
                        samples.right = color;
                    }
                }
                samples.generation += 1;
            },
        );
    app.finish();
    app.cleanup();
    pump_until(&mut app, |s| s.generation > 40 && s.mean > 0.08);
    println!(
        "Off-screen emitter receiver mean: {:.4}",
        app.world().resource::<Samples>().mean
    );
    let builds = app.world().resource::<GiStatistics>().bvh_builds;
    // An off-screen emissive texture must affect transport, not only raster shading.
    let black_texture = app
        .world_mut()
        .resource_mut::<Assets<Image>>()
        .add(Image::new_fill(
            bevy::render::render_resource::Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 1,
            },
            bevy::render::render_resource::TextureDimension::D2,
            &[0, 0, 0, 255],
            TextureFormat::Rgba8UnormSrgb,
            bevy::asset::RenderAssetUsages::default(),
        ));
    app.world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .get_mut(&emission)
        .unwrap()
        .emissive_texture = Some(black_texture);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 16 && s.mean < 0.001
    });
    app.world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .get_mut(&emission)
        .unwrap()
        .emissive_texture = None;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && s.mean > 0.08
    });
    // Secondary geometry must follow joint motion and morph weights while retaining
    // stable triangle IDs. The emissive mesh stays off-screen throughout.
    let emitter_mesh = app.world().get::<Mesh3d>(emitter).unwrap().0.clone();
    let vertex_count = app
        .world()
        .resource::<Assets<Mesh>>()
        .get(&emitter_mesh)
        .unwrap()
        .count_vertices();
    {
        let mut meshes = app.world_mut().resource_mut::<Assets<Mesh>>();
        let mut mesh = meshes.get_mut(&emitter_mesh).unwrap();
        mesh.insert_attribute(
            Mesh::ATTRIBUTE_JOINT_INDEX,
            bevy::mesh::VertexAttributeValues::Uint16x4(vec![[0, 0, 0, 0]; vertex_count]),
        );
        mesh.insert_attribute(
            Mesh::ATTRIBUTE_JOINT_WEIGHT,
            vec![[1.0, 0.0, 0.0, 0.0]; vertex_count],
        );
        mesh.set_morph_targets(vec![
            bevy::mesh::morph::MorphAttributes::new(
                Vec3::Y * 10000.0,
                Vec3::ZERO,
                Vec3::ZERO
            );
            vertex_count
        ]);
    }
    let joint = app
        .world_mut()
        .spawn(Transform::from_xyz(0.0, 3.0, 2.0))
        .id();
    let inverse = app
        .world_mut()
        .resource_mut::<Assets<bevy::mesh::skinning::SkinnedMeshInverseBindposes>>()
        .add(vec![Mat4::IDENTITY]);
    app.world_mut().entity_mut(emitter).insert((
        bevy::mesh::skinning::SkinnedMesh {
            inverse_bindposes: inverse,
            joints: vec![joint],
        },
        bevy::mesh::morph::MeshMorphWeights::Value { weights: vec![0.0] },
    ));
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && s.mean > 0.08
    });
    let builds_before_motion = app.world().resource::<GiStatistics>().bvh_builds;
    app.world_mut()
        .get_mut::<Transform>(joint)
        .unwrap()
        .translation
        .y = 10003.0;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 16 && s.mean < 0.001
    });
    app.world_mut()
        .get_mut::<Transform>(joint)
        .unwrap()
        .translation
        .y = 3.0;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && s.mean > 0.08
    });
    app.world_mut()
        .entity_mut(emitter)
        .insert(bevy::mesh::morph::MeshMorphWeights::Value { weights: vec![1.0] });
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 16 && s.mean < 0.001
    });
    app.world_mut()
        .entity_mut(emitter)
        .insert(bevy::mesh::morph::MeshMorphWeights::Value { weights: vec![0.0] });
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && s.mean > 0.08
    });
    assert_eq!(
        app.world().resource::<GiStatistics>().bvh_builds,
        builds_before_motion
    );
    assert!(app.world().resource::<GiStatistics>().bvh_refits >= 4);
    // Alpha-tested shadow traversal must skip a transparent blocker in both backends.
    let blocker_mesh = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(8.0, 0.2, 8.0));
    let blocker_material = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::srgba(0.0, 0.0, 0.0, 0.0),
            alpha_mode: AlphaMode::Mask(0.5),
            ..default()
        });
    let blocker = app
        .world_mut()
        .spawn((
            Mesh3d(blocker_mesh),
            MeshMaterial3d(blocker_material.clone()),
            Transform::from_xyz(0.0, 1.5, 1.0),
        ))
        .id();
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && s.mean > 0.08
    });
    app.world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .get_mut(&blocker_material)
        .unwrap()
        .base_color = Color::BLACK;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && s.mean < 0.001
    });
    app.world_mut().despawn(blocker);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && s.mean > 0.08
    });
    // Demodulated filtering must preserve a coplanar red/green material boundary.
    // Move the camera by a subpixel amount to exercise validated bilinear history.
    let split_mesh = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(3.0, 6.0, 0.1));
    let mut split_panels = Vec::new();
    for (x, color) in [
        (-1.5, Color::srgb(0.8, 0.02, 0.02)),
        (1.5, Color::srgb(0.02, 0.8, 0.02)),
    ] {
        let material = app
            .world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .add(StandardMaterial {
                base_color: color,
                perceptual_roughness: 1.0,
                ..default()
            });
        split_panels.push(
            app.world_mut()
                .spawn((
                    Mesh3d(split_mesh.clone()),
                    MeshMaterial3d(material),
                    Transform::from_xyz(x, 0.0, 0.1),
                ))
                .id(),
        );
    }
    let color_boundary = |s: &Samples| s.left.x > s.left.y * 3.0 && s.right.y > s.right.x * 3.0;
    app.world_mut()
        .get_mut::<HybridGi>(camera)
        .unwrap()
        .reflections = true;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 24 && color_boundary(s)
    });
    app.world_mut()
        .get_mut::<Transform>(camera)
        .unwrap()
        .translation += Vec3::new(0.037, 0.019, 0.0);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 16 && color_boundary(s)
    });
    app.world_mut().get_mut::<HybridGi>(camera).unwrap().reset += 1;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 16 && color_boundary(s)
    });
    for panel in split_panels {
        app.world_mut().despawn(panel);
    }
    app.world_mut()
        .get_mut::<HybridGi>(camera)
        .unwrap()
        .reflections = false;
    *app.world_mut().get_mut::<Transform>(camera).unwrap() =
        Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 16 && s.mean > 0.08
    });
    assert!(app.world().resource::<GiStatistics>().bvh_builds > builds);
    let builds = app.world().resource::<GiStatistics>().bvh_builds;
    app.world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .get_mut(&emission)
        .unwrap()
        .emissive = LinearRgba::BLACK;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    assert_eq!(
        app.world().resource::<GiStatistics>().bvh_builds,
        builds,
        "material edits must preserve BVH topology"
    );
    app.world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .get_mut(&emission)
        .unwrap()
        .emissive = LinearRgba::rgb(8.0, 4.0, 2.0);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
    app.world_mut().entity_mut(emitter).insert(GiExclude);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    app.world_mut().entity_mut(emitter).remove::<GiExclude>();
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
    // Camera disable must leave no stale composition in the direct renderer.
    app.world_mut().entity_mut(camera).remove::<HybridGi>();
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    app.world_mut().entity_mut(camera).insert(HybridGi {
        reflections: false,
        ..default()
    });
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
    app.world_mut().despawn(emitter);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    // The lamp is behind the visible wall. An off-screen panel beyond its edge
    // reflects the lamp onto the front; direct raster lighting there is zero.
    let panel = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(3.0, 4.0, 0.1));
    app.world_mut().spawn((
        Mesh3d(panel),
        MeshMaterial3d(white),
        Transform::from_xyz(4.0, 0.0, 2.0),
    ));
    let point = app
        .world_mut()
        .spawn((
            PointLight {
                intensity: 4000.0,
                range: 20.0,
                ..default()
            },
            Transform::from_xyz(4.0, 1.0, -1.0),
        ))
        .id();
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 30 && s.mean > 0.03
    });
    println!(
        "Point-light indirect receiver mean: {:.4}",
        app.world().resource::<Samples>().mean
    );
    let builds = app.world().resource::<GiStatistics>().bvh_builds;
    app.world_mut()
        .get_mut::<PointLight>(point)
        .unwrap()
        .intensity = 0.0;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    assert_eq!(app.world().resource::<GiStatistics>().bvh_builds, builds);
    app.world_mut().despawn(point);
    let spot = app
        .world_mut()
        .spawn((
            SpotLight {
                intensity: 4000.0,
                range: 20.0,
                ..default()
            },
            Transform::from_xyz(4.0, 1.0, -1.0).looking_at(Vec3::new(4.0, 0.0, 2.0), Vec3::Y),
        ))
        .id();
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 30 && s.mean > 0.03
    });
    println!(
        "Spot-light indirect receiver mean: {:.4}",
        app.world().resource::<Samples>().mean
    );
    app.world_mut().despawn(spot);
    let directional = app
        .world_mut()
        .spawn((
            DirectionalLight {
                illuminance: 8.0,
                ..default()
            },
            Transform::from_rotation(Quat::from_rotation_y(std::f32::consts::PI)),
        ))
        .id();
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 30 && s.mean > 0.03
    });
    println!(
        "Directional-light indirect receiver mean: {:.4}",
        app.world().resource::<Samples>().mean
    );
    app.world_mut().despawn(directional);
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    assert_eq!(app.world().resource::<GiStatistics>().bvh_builds, builds);
    println!("{:?}", app.world().resource::<GiStatistics>());
    // A source behind the camera can only appear on this metallic receiver
    // through reflection rays. Diffuse GI is zero for a pure metal.
    let silver = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::srgb(0.9, 0.9, 0.9),
            metallic: 1.0,
            perceptual_roughness: 0.0,
            ..default()
        });
    app.world_mut()
        .entity_mut(receiver)
        .insert(MeshMaterial3d(silver));
    let reflection_source = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(6.0, 6.0, 0.1));
    app.world_mut().spawn((
        Mesh3d(reflection_source),
        MeshMaterial3d(emission),
        Transform::from_xyz(0.0, 0.0, 6.0),
    ));
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    app.world_mut()
        .get_mut::<HybridGi>(camera)
        .unwrap()
        .reflections = true;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
    println!(
        "Mirror receiver mean: {:.4}",
        app.world().resource::<Samples>().mean
    );
    app.world_mut().get_mut::<Camera>(camera).unwrap().viewport = Some(bevy::camera::Viewport {
        physical_position: UVec2::splat(32),
        physical_size: UVec2::splat(64),
        ..default()
    });
    app.world_mut().get_mut::<HybridGi>(camera).unwrap().reset += 1;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
    app.world_mut()
        .entity_mut(camera)
        .insert(bevy::render::camera::TemporalJitter {
            offset: Vec2::new(0.4, -0.3),
        });
    app.world_mut().get_mut::<HybridGi>(camera).unwrap().reset += 1;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
    app.world_mut()
        .entity_mut(camera)
        .remove::<bevy::render::camera::TemporalJitter>();
    app.world_mut()
        .entity_mut(camera)
        .insert(Projection::Orthographic(OrthographicProjection {
            scaling_mode: bevy::camera::ScalingMode::FixedVertical {
                viewport_height: 4.0,
            },
            ..OrthographicProjection::default_3d()
        }));
    app.world_mut().get_mut::<HybridGi>(camera).unwrap().reset += 1;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
    app.world_mut()
        .get_mut::<HybridGi>(camera)
        .unwrap()
        .reflections = false;
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 12 && s.mean < 0.001
    });
    // A plain camera must still render standard deferred materials without GI.
    app.world_mut().spawn((
        Camera3d::default(),
        Camera {
            order: 1,
            ..default()
        },
        Msaa::Off,
        Exposure { ev100: 0.0 },
        RenderTarget::Image(image.into()),
        Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::new(0.0, 0.0, 6.0), Vec3::Y),
    ));
    let generation = app.world().resource::<Samples>().generation;
    pump_until(&mut app, |s| {
        s.generation > generation + 20 && s.mean > 0.08
    });
}
#[track_caller]
fn pump_until(app: &mut App, predicate: impl Fn(&Samples) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(45);
    while Instant::now() < deadline {
        app.update();
        assert!(
            app.world().resource::<Messages<AppExit>>().is_empty(),
            "renderer requested exit; inspect validation errors above"
        );
        if predicate(app.world().resource::<Samples>()) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!(
        "GPU receiver did not reach expected lighting: generation={}, mean={}",
        app.world().resource::<Samples>().generation,
        app.world().resource::<Samples>().mean
    );
}
