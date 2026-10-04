use bevy::{
    anti_alias::fxaa::Fxaa,
    camera::{Exposure, Hdr, RenderTarget},
    light::GlobalAmbientLight,
    prelude::*,
    render::{
        diagnostic::RenderDiagnosticsPlugin,
        view::screenshot::{Screenshot, ScreenshotCaptured, save_to_disk},
    },
    window::ExitCondition,
    winit::WinitPlugin,
};
use bevy_sol::{GiRayBackend, GiStatistics, HybridGi, HybridGiConfig, HybridGiPlugin};

fn main() {
    let headless = std::env::args().any(|a| a == "--headless");
    let software = std::env::args().any(|a| a == "--software");
    let hardware = std::env::args().any(|a| a == "--hardware");
    assert!(!(software && hardware), "select a single traversal backend");
    let ray_backend = if software {
        GiRayBackend::Software
    } else if hardware {
        GiRayBackend::Hardware
    } else {
        GiRayBackend::Auto
    };
    let capture_path = if software {
        "screenshots/cornell-software.png"
    } else if hardware {
        "screenshots/cornell-hardware.png"
    } else {
        "screenshots/cornell.png"
    };
    let mut app = App::new();
    if headless {
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
    } else {
        app.add_plugins(DefaultPlugins);
    }
    app.add_plugins(RenderDiagnosticsPlugin)
        .insert_resource(GlobalAmbientLight {
            brightness: 0.0,
            ..default()
        })
        .add_plugins(HybridGiPlugin {
            config: HybridGiConfig {
                ray_backend,
                min_cell_size: 0.08,
                cell_size_scale: 0.005,
                direct_samples: 4,
                probe_directions: 8,
                ..default()
            },
        })
        .add_systems(Startup, setup)
        .add_systems(Update, controls);
    if headless {
        app.add_systems(Startup, offscreen.after(setup));
        app.finish();
        app.cleanup();
        let mut capture_requested = false;
        let gi_timing = bevy::diagnostic::DiagnosticPath::new("render/bevy_sol/elapsed_cpu");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        for _ in 0..600 {
            app.update();
            assert!(
                app.world().resource::<Messages<AppExit>>().is_empty(),
                "renderer requested exit; inspect errors above"
            );
            // Shader compilation can consume most of an application-frame warm-up.
            // Count actual GI dispatch measurements before judging convergence.
            let warmed_up = app
                .world()
                .resource::<bevy::diagnostic::DiagnosticsStore>()
                .get(&gi_timing)
                .is_some_and(|diagnostic| diagnostic.history_len() >= 90);
            if warmed_up && !capture_requested {
                capture_requested = true;
                let handle = app.world().resource::<CaptureTarget>().0.clone();
                std::fs::create_dir_all("screenshots").expect("screenshot directory");
                app.world_mut()
                    .spawn(Screenshot::image(handle))
                    .observe(save_to_disk(capture_path))
                    .observe(
                        |event: On<ScreenshotCaptured>, mut complete: ResMut<CaptureComplete>| {
                            let image = event
                                .image
                                .clone()
                                .try_into_dynamic()
                                .expect("RGBA screenshot")
                                .to_rgba8();
                            let red = image.get_pixel(60, 320).0;
                            let green = image.get_pixel(580, 320).0;
                            println!("Cornell wall samples: red={red:?}, green={green:?}");
                            assert!(red[0] > 20 && red[0] > red[1], "red wall must receive GI");
                            assert!(
                                green[1] > 20 && green[1] > green[0],
                                "green wall must receive GI"
                            );
                            complete.0 = true;
                        },
                    );
            }
            if app.world().resource::<CaptureComplete>().0 {
                println!("{:?}", app.world().resource::<GiStatistics>());
                let adapter = app
                    .world()
                    .resource::<bevy::render::renderer::RenderAdapterInfo>();
                println!("Adapter: {} ({:?})", adapter.name, adapter.backend);
                let store = app.world().resource::<bevy::diagnostic::DiagnosticsStore>();
                for diagnostic in store
                    .iter()
                    .filter(|d| d.path().as_str().contains("bevy_sol"))
                {
                    if let Some(value) = diagnostic.average() {
                        println!("{}: {value:.3} ms", diagnostic.path().as_str());
                    }
                }
                return;
            }
            if std::time::Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("headless screenshot did not complete");
    } else {
        app.run();
    }
}

#[derive(Resource)]
struct CaptureTarget(Handle<Image>);
#[derive(Resource, Default)]
struct CaptureComplete(bool);

fn offscreen(
    mut commands: Commands,
    mut images: ResMut<Assets<Image>>,
    cameras: Query<Entity, With<Camera3d>>,
) {
    let handle = images.add(Image::new_target_texture(
        640,
        640,
        bevy::render::render_resource::TextureFormat::Rgba8UnormSrgb,
        None,
    ));
    for entity in &cameras {
        commands
            .entity(entity)
            .insert(RenderTarget::Image(handle.clone().into()));
    }
    commands.insert_resource(CaptureTarget(handle));
    commands.insert_resource(CaptureComplete::default());
}

#[derive(Component)]
struct Emitter;

fn setup(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
) {
    let white = materials.add(StandardMaterial {
        base_color: Color::srgb(0.75, 0.75, 0.75),
        perceptual_roughness: 1.0,
        ..default()
    });
    let red = materials.add(StandardMaterial {
        base_color: Color::srgb(0.8, 0.04, 0.025),
        perceptual_roughness: 1.0,
        ..default()
    });
    let green = materials.add(StandardMaterial {
        base_color: Color::srgb(0.035, 0.65, 0.09),
        perceptual_roughness: 1.0,
        ..default()
    });
    for (size, position, material) in [
        (
            Vec3::new(6.0, 0.2, 6.0),
            Vec3::new(0.0, -0.1, 0.0),
            white.clone(),
        ),
        (
            Vec3::new(6.0, 0.2, 6.0),
            Vec3::new(0.0, 4.1, 0.0),
            white.clone(),
        ),
        (
            Vec3::new(6.0, 4.0, 0.2),
            Vec3::new(0.0, 2.0, -3.0),
            white.clone(),
        ),
        (Vec3::new(0.2, 4.0, 6.0), Vec3::new(-3.0, 2.0, 0.0), red),
        (Vec3::new(0.2, 4.0, 6.0), Vec3::new(3.0, 2.0, 0.0), green),
        (
            Vec3::new(1.4, 2.4, 1.4),
            Vec3::new(-1.2, 1.2, -0.5),
            white.clone(),
        ),
        (Vec3::new(1.3, 1.3, 1.3), Vec3::new(1.1, 0.65, 0.6), white),
    ] {
        commands.spawn((
            Mesh3d(meshes.add(Cuboid::from_size(size))),
            MeshMaterial3d(material),
            Transform::from_translation(position),
        ));
    }
    let emitter = materials.add(StandardMaterial {
        emissive: LinearRgba::rgb(12.0, 10.5, 8.0),
        base_color: Color::BLACK,
        ..default()
    });
    commands.spawn((
        Emitter,
        Mesh3d(meshes.add(Cuboid::new(2.2, 0.08, 2.2))),
        MeshMaterial3d(emitter),
        Transform::from_xyz(0.0, 3.85, 0.0),
    ));
    commands.spawn((
        Camera3d::default(),
        HybridGi::default(),
        Hdr,
        Exposure { ev100: 1.0 },
        Msaa::Off,
        Fxaa::default(),
        Transform::from_xyz(0.0, 2.5, 8.5).looking_at(Vec3::new(0.0, 1.8, 0.0), Vec3::Y),
    ));
    info!(
        "GI-only Cornell room. WASD: move camera; arrows: move emitter; Space: toggle emission; Escape: quit."
    );
}

fn controls(
    keys: Res<ButtonInput<KeyCode>>,
    time: Res<Time>,
    stats: Res<GiStatistics>,
    mut cameras: Query<&mut Transform, (With<Camera3d>, Without<Emitter>)>,
    mut emitters: Query<(&mut Transform, &MeshMaterial3d<StandardMaterial>), With<Emitter>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    mut exit: MessageWriter<AppExit>,
) {
    if keys.just_pressed(KeyCode::Escape) {
        exit.write(AppExit::Success);
    }
    let speed = time.delta_secs() * 2.0;
    for mut camera in &mut cameras {
        let x = f32::from(keys.pressed(KeyCode::KeyD)) - f32::from(keys.pressed(KeyCode::KeyA));
        let z = f32::from(keys.pressed(KeyCode::KeyS)) - f32::from(keys.pressed(KeyCode::KeyW));
        camera.translation += Vec3::new(x, 0.0, z) * speed;
    }
    for (mut transform, material) in &mut emitters {
        let x = f32::from(keys.pressed(KeyCode::ArrowRight))
            - f32::from(keys.pressed(KeyCode::ArrowLeft));
        if x != 0.0 {
            transform.translation.x += x * speed;
        }
        if keys.just_pressed(KeyCode::Space) {
            if let Some(mut material) = materials.get_mut(&material.0) {
                material.emissive = if material.emissive.red > 0.0 {
                    LinearRgba::BLACK
                } else {
                    LinearRgba::rgb(12.0, 10.5, 8.0)
                };
            }
            info!("{stats:?}");
        }
    }
}
