//! Independent analytic/numerical references for the renderer's energy.
//! A Lambertian plane of reflectance 0.5 in unit uniform radiance returns 0.5.
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
use bevy_sol::{
    GiRayBackend, HybridGi, HybridGiConfig, HybridGiPlugin, ReflectionConfig, ReflectionDenoiser,
};
use std::time::{Duration, Instant};

// Integrate the GGX/Smith BRDF independently in f64 over a uniform hemisphere.
// Normal incidence removes azimuth dependence; this is not the shader's sampler.
fn ggx_furnace(roughness: f64, f0: f64) -> f32 {
    let alpha2 = roughness.powi(4);
    let steps = 65_536;
    let mut integral = 0.0;
    for i in 0..steps {
        let nl = (i as f64 + 0.5) / steps as f64;
        let nh2 = (1.0 + nl) * 0.5;
        let denominator = nh2 * (alpha2 - 1.0) + 1.0;
        let distribution = alpha2 / (std::f64::consts::PI * denominator * denominator);
        let masking = 2.0 / (1.0 + (1.0 + alpha2 * (1.0 - nl * nl) / (nl * nl)).sqrt());
        let fresnel = f0 + (1.0 - f0) * (1.0 - nh2.sqrt()).powi(5);
        integral += fresnel * distribution * masking * 0.25;
    }
    (integral * 2.0 * std::f64::consts::PI / steps as f64) as f32
}

#[derive(Resource, Default)]
struct Measurement {
    frames: u32,
    mean: f32,
    min: f32,
    max: f32,
}

#[test]
#[ignore = "requires a compute-capable GPU"]
fn uniform_environment_preserves_diffuse_and_glossy_energy() {
    let hardware = std::env::var("BEVY_SOL_TEST_HARDWARE").as_deref() == Ok("1");
    let cubemap = std::env::var("BEVY_SOL_TEST_CUBEMAP").as_deref() == Ok("1");
    let mut wgpu = bevy::render::settings::WgpuSettings::default();
    if hardware {
        wgpu.features |= bevy::render::settings::WgpuFeatures::EXPERIMENTAL_RAY_QUERY;
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
    .init_resource::<Measurement>()
    .add_plugins(HybridGiPlugin {
        config: HybridGiConfig {
            radiance_cascades: if std::env::var("BEVY_SOL_TEST_REFERENCE").as_deref() == Ok("1") {
                None
            } else {
                Some(default())
            },
            // Physical reference integrals use the PDF-compensated estimator.
            probe_projection: if std::env::var("BEVY_SOL_TEST_SOURCE_PROJECTION").as_deref()
                == Ok("1")
            {
                bevy_sol::ProbeProjection::SourceAtlas
            } else {
                bevy_sol::ProbeProjection::CompensatedRayIntegral
            },
            probe_sampling: match std::env::var("BEVY_SOL_TEST_PROBE_MODE").as_deref() {
                Ok("full") => bevy_sol::ProbeSamplingMode::FullSpp,
                Ok("sixteenth") => bevy_sol::ProbeSamplingMode::SixteenthSpp,
                _ => bevy_sol::ProbeSamplingMode::QuarterSpp,
            },
            probe_directions: if std::env::var("BEVY_SOL_TEST_PROBE_DIRECTIONS").as_deref()
                == Ok("8")
            {
                8
            } else {
                4
            },
            diffuse_denoiser: if std::env::var("BEVY_SOL_TEST_DIFFUSE_MODE").as_deref()
                == Ok("atrous")
            {
                bevy_sol::DiffuseDenoiser::TemporalVarianceAtrous
            } else {
                bevy_sol::DiffuseDenoiser::AdaptiveSeparable
            },
            reflection: ReflectionConfig {
                half_resolution: std::env::var("BEVY_SOL_TEST_FULL_REFLECTIONS").as_deref()
                    != Ok("1"),
                denoiser: match std::env::var("BEVY_SOL_TEST_REFLECTION_MODE").as_deref() {
                    Ok("split") => ReflectionDenoiser::SplitRatioEstimator,
                    Ok("none") => ReflectionDenoiser::None,
                    _ => ReflectionDenoiser::AtrousRatioEstimator,
                },
                ..default()
            },
            hash_grid: bevy_sol::HashGridCacheConfig {
                num_buckets: 256,
                tiles_per_bucket: 4,
                ..default()
            },
            ray_backend: if hardware {
                GiRayBackend::Hardware
            } else {
                GiRayBackend::Software
            },
            sky_radiance: if cubemap {
                Vec3::splat(0.25)
            } else {
                Vec3::ONE
            },
            cache_capacity: 1024,
            ..default()
        },
    });
    if cubemap {
        use bevy::render::render_resource::{
            Extent3d, TextureDimension, TextureViewDescriptor, TextureViewDimension,
        };
        let mut cube = Image::new(
            Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 6,
            },
            TextureDimension::D2,
            [1.0f32, 1.0, 1.0, 1.0]
                .into_iter()
                .cycle()
                .take(24)
                .flat_map(f32::to_le_bytes)
                .collect(),
            TextureFormat::Rgba32Float,
            bevy::asset::RenderAssetUsages::default(),
        );
        cube.texture_view_descriptor = Some(TextureViewDescriptor {
            dimension: Some(TextureViewDimension::Cube),
            ..default()
        });
        let handle = app.world_mut().resource_mut::<Assets<Image>>().add(cube);
        app.insert_resource(bevy_sol::GiEnvironmentMap {
            image: Some(handle),
            intensity: 0.75,
            rotation: Quat::from_rotation_y(0.7),
            sampling: bevy_sol::EnvironmentSampling::Importance,
        });
    }
    let mut image = Image::new_target_texture(64, 64, TextureFormat::Rgba32Float, None);
    image.texture_descriptor.usage |= bevy::render::render_resource::TextureUsages::COPY_SRC;
    let target = app.world_mut().resource_mut::<Assets<Image>>().add(image);
    let mesh = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(8.0, 8.0, 0.1));
    let material = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::linear_rgb(0.5, 0.5, 0.5),
            reflectance: 0.0,
            perceptual_roughness: 1.0,
            ..default()
        });
    let receiver = app
        .world_mut()
        .spawn((
            Mesh3d(mesh),
            MeshMaterial3d(material.clone()),
            Transform::IDENTITY,
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
            Projection::Orthographic(OrthographicProjection {
                scaling_mode: bevy::camera::ScalingMode::FixedVertical {
                    viewport_height: 2.0,
                },
                ..OrthographicProjection::default_3d()
            }),
            Tonemapping::None,
            Exposure { ev100: 0.0 },
            RenderTarget::Image(target.clone().into()),
            Transform::from_xyz(0.0, 0.0, 3.0).looking_at(Vec3::ZERO, Vec3::Y),
        ))
        .id();
    app.world_mut().spawn(Readback::texture(target)).observe(
        |event: On<ReadbackComplete>, mut result: ResMut<Measurement>| {
            let mut sum = 0.0;
            let mut min = f32::INFINITY;
            let mut max = 0.0_f32;
            for y in 24..40 {
                for x in 24..40 {
                    for channel in 0..3 {
                        let offset = ((y * 64 + x) * 4 + channel) * 4;
                        let value =
                            f32::from_le_bytes(event.data[offset..offset + 4].try_into().unwrap());
                        assert!(value.is_finite(), "non-finite radiance");
                        sum += value;
                        min = min.min(value);
                        max = max.max(value);
                    }
                }
            }
            result.mean = sum / (16.0 * 16.0 * 3.0);
            result.min = min;
            result.max = max;
            result.frames += 1;
        },
    );
    app.finish();
    app.cleanup();
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        app.update();
        assert!(
            app.world().resource::<Messages<AppExit>>().is_empty(),
            "GPU validation failure"
        );
        let result = app.world().resource::<Measurement>();
        if result.frames >= 80 && result.mean > 0.2 {
            let expected = 0.5 * Exposure { ev100: 0.0 }.exposure();
            println!(
                "Lambertian furnace: mean={:.6}, range={:.6}..{:.6}, expected={expected:.6}",
                result.mean, result.min, result.max
            );
            assert!(
                (result.mean - expected).abs() < expected * 0.05,
                "energy bias exceeds 5%, including G-buffer quantization"
            );
            assert!(
                result.max - result.min < 0.04,
                "uniform environment must converge spatially"
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "GI did not produce reference measurement"
        );
    }
    if std::env::var("BEVY_SOL_TEST_REFERENCE").as_deref() != Ok("1") {
        for normal in [Vec3::X, Vec3::ONE.normalize()] {
            let rotation = Quat::from_rotation_arc(Vec3::Z, normal);
            app.world_mut()
                .get_mut::<Transform>(receiver)
                .unwrap()
                .rotation = rotation;
            *app.world_mut().get_mut::<Transform>(camera).unwrap() =
                Transform::from_translation(normal * 3.0)
                    .looking_at(Vec3::ZERO, rotation * Vec3::Y);
            *app.world_mut().resource_mut::<Measurement>() = Measurement::default();
            let deadline = Instant::now() + Duration::from_secs(60);
            loop {
                app.update();
                assert!(app.world().resource::<Messages<AppExit>>().is_empty());
                let result = app.world().resource::<Measurement>();
                if result.frames >= 80 {
                    let expected = 0.5 * Exposure { ev100: 0.0 }.exposure();
                    println!(
                        "Rotated Lambertian furnace normal={normal:?}: mean={:.6}, expected={expected:.6}",
                        result.mean
                    );
                    assert!((result.mean - expected).abs() < expected * 0.05);
                    assert!(result.max - result.min < 0.04);
                    break;
                }
                assert!(Instant::now() < deadline, "rotated furnace timed out");
            }
        }
        *app.world_mut().get_mut::<Transform>(receiver).unwrap() = Transform::IDENTITY;
        *app.world_mut().get_mut::<Transform>(camera).unwrap() =
            Transform::from_xyz(0.0, 0.0, 3.0).looking_at(Vec3::ZERO, Vec3::Y);
    }
    for roughness in [0.1, 0.35, 0.75] {
        {
            let mut materials = app.world_mut().resource_mut::<Assets<StandardMaterial>>();
            let mut surface = materials.get_mut(&material).unwrap();
            surface.metallic = 1.0;
            surface.perceptual_roughness = roughness;
        }
        app.world_mut()
            .entity_mut(camera)
            .get_mut::<HybridGi>()
            .unwrap()
            .reflections = true;
        *app.world_mut().resource_mut::<Measurement>() = Measurement::default();
        let expected = ggx_furnace(f64::from(roughness), 0.5) * Exposure { ev100: 0.0 }.exposure();
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            app.update();
            assert!(
                app.world().resource::<Messages<AppExit>>().is_empty(),
                "GPU validation failure"
            );
            let result = app.world().resource::<Measurement>();
            if result.frames >= 160 && result.mean > 0.1 {
                println!(
                    "GGX furnace roughness={roughness}: mean={:.6}, expected={expected:.6}",
                    result.mean
                );
                assert!(
                    (result.mean - expected).abs() < expected * 0.05,
                    "glossy energy bias exceeds 5%, including G-buffer quantization"
                );
                break;
            }
            assert!(
                Instant::now() < deadline,
                "glossy furnace did not converge: roughness={roughness}, frames={}, mean={}, range={}..{}",
                result.frames,
                result.mean,
                result.min,
                result.max
            );
        }
    }
}
