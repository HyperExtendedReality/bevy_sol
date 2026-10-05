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
#[path = "support/quality.rs"]
mod quality;

fn main() {
    let benchmark = std::env::args().any(|a| a == "--benchmark");
    let quality = std::env::args().any(|a| a == "--quality");
    assert!(
        !(quality && benchmark),
        "HDR readback perturbs timing; run quality and benchmark separately"
    );
    let selected_scene = std::env::args()
        .find_map(|a| a.strip_prefix("--scene=").map(str::to_owned))
        .unwrap_or_else(|| "room".to_owned());
    assert!(
        ["room", "thin"].contains(&selected_scene.as_str()),
        "unknown scene"
    );
    let thin = selected_scene == "thin";
    let scene = if thin { "thin" } else { "room" };
    let quality_frames: u32 = std::env::args()
        .find_map(|a| a.strip_prefix("--quality-frames=").map(str::to_owned))
        .map_or(128, |v| v.parse().expect("quality frame count"));
    assert!((2..=4096).contains(&quality_frames) && quality_frames.is_multiple_of(2));
    let quality_warmup: u32 = std::env::args()
        .find_map(|a| a.strip_prefix("--quality-warmup=").map(str::to_owned))
        .map_or(quality::WARMUP, |v| {
            v.parse().expect("quality warmup count")
        });
    assert!((128..=8192).contains(&quality_warmup));
    let compare =
        std::env::args().find_map(|a| a.strip_prefix("--quality-compare=").map(str::to_owned));
    assert!(
        compare.is_none() || quality,
        "comparison requires --quality"
    );
    let headless = quality || benchmark || std::env::args().any(|a| a == "--headless");
    let restir = std::env::args().any(|a| a == "--restir");
    let multibounce = !std::env::args().any(|a| a == "--no-multibounce");
    let reference = restir || std::env::args().any(|a| a == "--reference");
    let angular_resolution = std::env::args()
        .find_map(|arg| arg.strip_prefix("--cascade-angular=").map(str::to_owned))
        .map_or(4, |value| {
            value.parse().expect("cascade angular resolution")
        });
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
    let backend = if software {
        "software"
    } else if hardware {
        "hardware"
    } else {
        "auto"
    };
    let mut transport = if restir {
        "restir".to_owned()
    } else if reference {
        "reference".to_owned()
    } else if angular_resolution != 4 {
        format!("cascades{angular_resolution}")
    } else {
        "cascades".to_owned()
    };
    if !multibounce {
        transport.push_str("-single-bounce");
    }
    let capture_path = format!("screenshots/cornell-{transport}-{backend}.png");
    let mut app = App::new();
    app.insert_resource(QualityMode {
        enabled: quality,
        thin,
    });
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
                radiance_cascades: if reference {
                    None
                } else {
                    Some(bevy_sol::RadianceCascadesConfig {
                        angular_resolution,
                        ..default()
                    })
                },
                reservoir_resampling: restir,
                multibounce,
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
        let mut last_sample = None;
        let mut sample_frames = 0;
        let mut samples = std::collections::BTreeMap::<String, Vec<f64>>::new();
        let mut quality_dispatches = 0;
        let mut quality_time = None;
        let mut quality_requested = false;
        let deadline = std::time::Instant::now()
            + std::time::Duration::from_secs(
                180 + u64::from(quality_warmup.saturating_sub(quality::WARMUP)) / 20,
            );
        for _ in 0..10000 {
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
            if quality {
                let store = app.world().resource::<bevy::diagnostic::DiagnosticsStore>();
                if let Some(measurement) = store.get_measurement(&gi_timing)
                    && quality_time != Some(measurement.time)
                {
                    quality_time = Some(measurement.time);
                    quality_dispatches += 1;
                }
                if quality_dispatches >= quality_warmup && !quality_requested {
                    quality_requested = true;
                    let image = app.world().resource::<CaptureTarget>().0.clone();
                    quality::start(app.world_mut(), image, quality_frames);
                }
                if quality_requested && app.world().resource::<quality::Capture>().complete() {
                    let adapter = app
                        .world()
                        .resource::<bevy::render::renderer::RenderAdapterInfo>();
                    let metadata = format!(
                        "adapter={}\napi={:?}\ntransport={transport}\nbackend={backend}\nscene={scene}\nmultibounce={multibounce}\nexposure_ev100=1\ntonemapping=none\nfxaa=disabled\nprofile={}\n",
                        adapter.name,
                        adapter.backend,
                        if cfg!(debug_assertions) {
                            "dev-opt1"
                        } else {
                            "release"
                        }
                    );
                    let suffix = if quality_warmup == quality::WARMUP {
                        String::new()
                    } else {
                        format!("-warmup{quality_warmup}")
                    };
                    app.world().resource::<quality::Capture>().write(
                        &format!(
                            "screenshots/cornell-{scene}-{transport}-{backend}-quality{suffix}"
                        ),
                        u32::from(thin),
                        compare.as_deref(),
                        &metadata,
                        quality_warmup,
                    );
                    return;
                }
            }
            if benchmark && warmed_up && sample_frames < 300 {
                let store = app.world().resource::<bevy::diagnostic::DiagnosticsStore>();
                if let Some(measurement) = store.get_measurement(&gi_timing)
                    && last_sample != Some(measurement.time)
                {
                    last_sample = Some(measurement.time);
                    sample_frames += 1;
                    for diagnostic in store
                        .iter()
                        .filter(|d| d.path().as_str().contains("bevy_sol"))
                    {
                        if let Some(value) = diagnostic.measurement()
                            && value.time == measurement.time
                            && value.value.is_finite()
                        {
                            samples
                                .entry(diagnostic.path().as_str().to_owned())
                                .or_default()
                                .push(value.value);
                        }
                    }
                }
            }
            if !quality && warmed_up && (!benchmark || sample_frames >= 300) && !capture_requested {
                capture_requested = true;
                let handle = app.world().resource::<CaptureTarget>().0.clone();
                std::fs::create_dir_all("screenshots").expect("screenshot directory");
                app.world_mut()
                    .spawn(Screenshot::image(handle))
                    .observe(save_to_disk(capture_path.clone()))
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
                println!(
                    "Transport: {transport}; requested backend: {backend}; resolution: 640x640; profile: {}",
                    if cfg!(debug_assertions) {
                        "dev-opt1"
                    } else {
                        "release"
                    }
                );
                if benchmark {
                    let mut csv = String::from("path,samples,p50_ms,p95_ms,p99_ms,max_ms\n");
                    for (path, values) in &mut samples {
                        values.sort_by(f64::total_cmp);
                        let percentile =
                            |q: f64| values[((values.len() - 1) as f64 * q).ceil() as usize];
                        let row = format!(
                            "{path},{},{:.6},{:.6},{:.6},{:.6}\n",
                            values.len(),
                            percentile(0.5),
                            percentile(0.95),
                            percentile(0.99),
                            values[values.len() - 1]
                        );
                        print!("{row}");
                        csv.push_str(&row);
                    }
                    assert!(
                        samples.contains_key("render/bevy_sol/elapsed_gpu"),
                        "GPU timestamps unavailable; CPU timings do not prove GPU performance"
                    );
                    std::fs::write(
                        format!("screenshots/cornell-{transport}-{backend}-timings.csv"),
                        csv,
                    )
                    .expect("timing CSV");
                }
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
#[derive(Resource)]
struct QualityMode {
    enabled: bool,
    thin: bool,
}

fn offscreen(
    mut commands: Commands,
    mut images: ResMut<Assets<Image>>,
    cameras: Query<Entity, With<Camera3d>>,
    mode: Res<QualityMode>,
) {
    let mut image = Image::new_target_texture(
        640,
        640,
        if mode.enabled {
            bevy::render::render_resource::TextureFormat::Rgba32Float
        } else {
            bevy::render::render_resource::TextureFormat::Rgba8UnormSrgb
        },
        None,
    );
    image.texture_descriptor.usage |= bevy::render::render_resource::TextureUsages::COPY_SRC;
    let handle = images.add(image);
    for entity in &cameras {
        commands
            .entity(entity)
            .insert(RenderTarget::Image(handle.clone().into()));
        if mode.enabled {
            commands
                .entity(entity)
                .insert(bevy::core_pipeline::tonemapping::Tonemapping::None)
                .remove::<Fxaa>();
        }
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
    mode: Res<QualityMode>,
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
    if mode.thin {
        let material = materials.add(StandardMaterial {
            base_color: Color::srgb(0.75, 0.75, 0.75),
            perceptual_roughness: 1.0,
            ..default()
        });
        commands.spawn((
            Mesh3d(meshes.add(Cuboid::new(0.12, 3.0, 2.0))),
            MeshMaterial3d(material),
            Transform::from_xyz(0.0, 1.5, 0.0),
        ));
    }
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
