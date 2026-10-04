use super::*;
use bevy::{camera::RenderTarget, window::ExitCondition, winit::WinitPlugin};
use std::time::{Duration, Instant};

fn cube(value: f32) -> bevy::prelude::Image {
    let mut image = bevy::prelude::Image::new(
        Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 6,
        },
        TextureDimension::D2,
        [value, value, value, 1.0]
            .into_iter()
            .cycle()
            .take(24)
            .flat_map(f32::to_le_bytes)
            .collect(),
        TextureFormat::Rgba32Float,
        bevy::asset::RenderAssetUsages::default(),
    );
    image.texture_view_descriptor = Some(TextureViewDescriptor {
        dimension: Some(TextureViewDimension::Cube),
        ..default()
    });
    image
}

#[test]
#[ignore = "requires Vulkan and slangc"]
fn environment_loading_reloads_and_removal_reset_rendered_histories() {
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
    .add_plugins(crate::HybridGiPlugin {
        config: crate::HybridGiConfig {
            ray_backend: GiRayBackend::Software,
            cache_capacity: 1024,
            hash_grid: crate::HashGridCacheConfig {
                num_buckets: 16,
                tiles_per_bucket: 2,
                ..default()
            },
            ..default()
        },
    });
    let (target, environment, invalid) = {
        let mut images = app
            .world_mut()
            .resource_mut::<Assets<bevy::prelude::Image>>();
        (
            images.add(bevy::prelude::Image::new_target_texture(
                32,
                32,
                TextureFormat::Rgba16Float,
                None,
            )),
            images.add(cube(1.0)),
            images.add(bevy::prelude::Image::new_target_texture(
                4,
                4,
                TextureFormat::Rgba16Float,
                None,
            )),
        )
    };
    let mesh = app
        .world_mut()
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::new(8.0, 8.0, 0.1));
    let material = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial::default());
    app.world_mut()
        .spawn((Mesh3d(mesh), MeshMaterial3d(material)));
    app.world_mut().spawn((
        Camera3d::default(),
        HybridGi::default(),
        Msaa::Off,
        RenderTarget::Image(target.into()),
        Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    app.finish();
    app.cleanup();
    let step = |app: &mut App| {
        app.update();
        let world = app.sub_app_mut(RenderApp).world_mut();
        let state = world.query::<&ViewGi>().single(world).ok()?;
        (state.frames > 0).then_some((
            state.params.get().frame.y,
            state.params.get().environment.x,
            world.resource::<GpuEnvironment>().view.id(),
        ))
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    while step(&mut app).is_none() {
        assert!(Instant::now() < deadline, "GI did not render");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(step(&mut app).unwrap().0, 0);
    app.world_mut().resource_mut::<GiEnvironmentMap>().image = Some(environment.clone());
    let loaded = step(&mut app).unwrap();
    assert_eq!((loaded.0, loaded.1), (1, 1.0));
    assert_eq!(step(&mut app).unwrap().0, 0);
    // Image updates can preserve the GPU texture-view ID. Asset revision must
    // invalidate history even when descriptor identity stays unchanged.
    *app.world_mut()
        .resource_mut::<Assets<bevy::prelude::Image>>()
        .get_mut(&environment)
        .unwrap() = cube(2.0);
    let mut reloaded = false;
    for _ in 0..4 {
        let current = step(&mut app).unwrap();
        reloaded |= current.0 == 1;
        assert_eq!(
            current.2, loaded.2,
            "reload reuses the existing texture view"
        );
    }
    assert!(reloaded, "in-place image reload must reset histories");
    app.world_mut().resource_mut::<GiEnvironmentMap>().rotation = Quat::from_rotation_y(0.7);
    assert_eq!(step(&mut app).unwrap().0, 1);
    assert_eq!(step(&mut app).unwrap().0, 0);
    app.world_mut().resource_mut::<GiEnvironmentMap>().image = Some(invalid);
    let fallback = step(&mut app).unwrap();
    assert_eq!((fallback.0, fallback.1), (1, 0.0));
    app.world_mut().resource_mut::<GiEnvironmentMap>().image = None;
    assert_eq!(step(&mut app).unwrap().0, 1);
    assert_eq!(step(&mut app).unwrap().0, 0);
    app.world_mut().resource_mut::<GiEnvironmentMap>().image = Some(environment);
    assert_eq!(step(&mut app).unwrap().0, 1);
    app.world_mut().resource_mut::<GiEnvironmentMap>().intensity = f32::NAN;
    let invalid = step(&mut app).unwrap();
    assert_eq!((invalid.0, invalid.1), (1, 0.0));
    assert_eq!(step(&mut app).unwrap().0, 0);
    // Main-pass resolution is a render-world component in Bevy. Resizing must
    // allocate matching GI targets and reset once, including a viewport offset.
    let main_camera = app
        .world_mut()
        .query_filtered::<Entity, With<Camera3d>>()
        .single(app.world())
        .unwrap();
    app.world_mut()
        .get_mut::<Camera>(main_camera)
        .unwrap()
        .viewport = Some(bevy::camera::Viewport {
        physical_position: UVec2::new(4, 2),
        physical_size: UVec2::new(24, 26),
        ..default()
    });
    step(&mut app).unwrap();
    let render_camera = {
        let render = app.sub_app_mut(RenderApp).world_mut();
        render
            .query_filtered::<Entity, With<ViewGi>>()
            .single(render)
            .unwrap()
    };
    app.sub_app_mut(RenderApp)
        .world_mut()
        .entity_mut(render_camera)
        .insert(MainPassResolutionOverride(UVec2::splat(16)));
    assert_eq!(step(&mut app).unwrap().0, 1);
    let check_size = |app: &App, expected: UVec4| {
        let state = app
            .sub_app(RenderApp)
            .world()
            .get::<ViewGi>(render_camera)
            .unwrap();
        assert_eq!(state.params.get().viewport, expected);
        assert_eq!(state.composite_params.get().viewport, expected);
        assert!(state.prepared && state.frames > 0);
    };
    check_size(&app, UVec4::new(4, 2, 16, 16));
    assert_eq!(step(&mut app).unwrap().0, 0);
    app.sub_app_mut(RenderApp)
        .world_mut()
        .entity_mut(render_camera)
        .remove::<MainPassResolutionOverride>();
    assert_eq!(step(&mut app).unwrap().0, 1);
    check_size(&app, UVec4::new(4, 2, 24, 26));
    assert_eq!(step(&mut app).unwrap().0, 0);
}
