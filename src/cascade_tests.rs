use super::*;
use bevy::math::{DVec3, DVec4};
use bevy::{
    camera::RenderTarget, light::GlobalAmbientLight, window::ExitCondition, winit::WinitPlugin,
};
use std::time::{Duration, Instant};

// Independent f64 slab intersection against the closed opaque fixture boxes.
fn segment_blocked(start: DVec3, end: DVec3, limit: f64, boxes: &[(Vec3, Vec3)]) -> bool {
    let direction = (end - start).normalize();
    boxes.iter().any(|&(size, center)| {
        let lower = (center - size * 0.5).as_dvec3();
        let upper = (center + size * 0.5).as_dvec3();
        let mut entry = f64::NEG_INFINITY;
        let mut exit = f64::INFINITY;
        for axis in 0..3 {
            if direction[axis].abs() < 1e-12 {
                if start[axis] < lower[axis] || start[axis] > upper[axis] {
                    return false;
                }
            } else {
                let a = (lower[axis] - start[axis]) / direction[axis];
                let b = (upper[axis] - start[axis]) / direction[axis];
                entry = entry.max(a.min(b));
                exit = exit.min(a.max(b));
            }
        }
        let hit = if entry >= 0.0 { entry } else { exit };
        entry <= exit && hit >= 0.0 && hit <= limit
    })
}

#[test]
fn independent_box_visibility_handles_parallel_inside_and_short_segments() {
    let boxes = [(Vec3::ONE, Vec3::ZERO)];
    let start = DVec3::new(-2.0, 0.0, 0.0);
    let end = DVec3::new(2.0, 0.0, 0.0);
    assert!(segment_blocked(start, end, 4.0, &boxes));
    assert!(!segment_blocked(start, end, 1.49, &boxes));
    assert!(!segment_blocked(
        start + DVec3::Y,
        end + DVec3::Y,
        4.0,
        &boxes
    ));
    assert!(!segment_blocked(DVec3::ZERO, end, 0.49, &boxes));
    assert!(segment_blocked(DVec3::ZERO, end, 0.51, &boxes));
    assert!(!segment_blocked(end, end + DVec3::X, 1.0, &boxes));
}

fn check_cascade_merges(
    words: &[u32],
    tiles: UVec2,
    config: &crate::RadianceCascadesConfig,
    params: &Params,
    boxes: &[(Vec3, Vec3)],
    black: bool,
) -> (usize, usize, usize) {
    let read = |record: usize| {
        DVec4::from_array(std::array::from_fn(|i| {
            f64::from(f32::from_bits(words[record * 4 + i]))
        }))
    };
    let sphere = |u: f64, v: f64| {
        let z = 1.0 - 2.0 * v;
        let r = (1.0 - z * z).max(0.0).sqrt();
        let phi = std::f64::consts::TAU * u;
        DVec3::new(r * phi.cos(), r * phi.sin(), z)
    };
    let probes = config.probes(tiles) as usize;
    let rays = params.cascades.z as usize;
    let raw = probes * 3;
    let merged = raw + rays;
    let bias = f64::from(params.cache_config.z);
    let mut probe_offset = 0;
    let mut ray_offset = 0;
    let mut checked = 0;
    let mut blocked = 0;
    let mut fallbacks = 0;
    for level in 0..config.levels {
        let dims = config.dimensions(tiles, level);
        let side = config.angular_resolution << level;
        for probe in 0..dims.element_product() as usize {
            let address = (probe_offset + probe) * 3;
            let position = read(address);
            let normal = read(address + 1).truncate();
            let pixel = read(address + 2);
            for bin in 0..side * side {
                let record = ray_offset + probe * (side * side) as usize + bin as usize;
                let near = read(raw + record);
                let actual = read(merged + record);
                if near.w == 0.0 || position.w == 0.0 || level + 1 == config.levels {
                    assert_eq!(near, actual, "terminated interval changed at {record}");
                    continue;
                }
                let upper_dims = config.dimensions(tiles, level + 1);
                let upper_side = side * 2;
                let upper_probe_offset = probe_offset + dims.element_product() as usize;
                let upper_ray_offset = ray_offset + (dims.element_product() * side * side) as usize;
                let distance = f64::from(config.interval(level + 1, params.cache_config.w).0);
                let u = (f64::from(bin % side) + 0.5) / f64::from(side);
                let v = (f64::from(bin / side) + 0.5) / f64::from(side);
                let start = position.truncate() + normal * bias + sphere(u, v) * distance;
                let scale = f64::from(params.screen.z * (1 << (level + 1)));
                let coord = [pixel.x / scale - 0.5, pixel.y / scale - 0.5];
                let angular = [
                    u * f64::from(upper_side) - 0.5,
                    v * f64::from(upper_side) - 0.5,
                ];
                let mut far = DVec4::ZERO;
                let mut total = 0.0;
                for dy in 0..2 {
                    for dx in 0..2 {
                        let spatial_weight = (if dx == 0 {
                            1.0 - coord[0].rem_euclid(1.0)
                        } else {
                            coord[0].rem_euclid(1.0)
                        }) * (if dy == 0 {
                            1.0 - coord[1].rem_euclid(1.0)
                        } else {
                            coord[1].rem_euclid(1.0)
                        });
                        let x = (coord[0].floor() + f64::from(dx))
                            .clamp(0.0, f64::from(upper_dims.x - 1))
                            as usize;
                        let y = (coord[1].floor() + f64::from(dy))
                            .clamp(0.0, f64::from(upper_dims.y - 1))
                            as usize;
                        let parent = x + y * upper_dims.x as usize;
                        let other_address = (upper_probe_offset + parent) * 3;
                        let other = read(other_address);
                        let other_normal = read(other_address + 1).truncate();
                        if other.w == 0.0
                            || normal.dot(other_normal) < 0.5
                            || (other.truncate() - position.truncate()).dot(normal).abs()
                                > (distance * 0.25).max(bias * 4.0)
                        {
                            continue;
                        }
                        let mut radiance = DVec4::ZERO;
                        let mut angular_total = 0.0;
                        for ay in 0..2 {
                            for ax in 0..2 {
                                let bx = (angular[0].floor() + f64::from(ax))
                                    .rem_euclid(f64::from(upper_side))
                                    as usize;
                                let by = (angular[1].floor() + f64::from(ay))
                                    .clamp(0.0, f64::from(upper_side - 1))
                                    as usize;
                                let direction = sphere(
                                    (bx as f64 + 0.5) / f64::from(upper_side),
                                    (by as f64 + 0.5) / f64::from(upper_side),
                                );
                                let end =
                                    other.truncate() + other_normal * bias + direction * distance;
                                let length = start.distance(end);
                                if length > bias * 2.0
                                    && segment_blocked(start, end, length - bias, boxes)
                                {
                                    if spatial_weight > 0.0 {
                                        blocked += 1;
                                    }
                                    continue;
                                }
                                let weight = (if ax == 0 {
                                    1.0 - angular[0].rem_euclid(1.0)
                                } else {
                                    angular[0].rem_euclid(1.0)
                                }) * (if ay == 0 {
                                    1.0 - angular[1].rem_euclid(1.0)
                                } else {
                                    angular[1].rem_euclid(1.0)
                                });
                                radiance += read(
                                    merged
                                        + upper_ray_offset
                                        + parent * (upper_side * upper_side) as usize
                                        + bx
                                        + by * upper_side as usize,
                                ) * weight;
                                angular_total += weight;
                            }
                        }
                        if angular_total == 0.0 {
                            continue;
                        }
                        far += radiance / angular_total * spatial_weight;
                        total += spatial_weight;
                    }
                }
                if total > 0.0 {
                    far /= total;
                    let expected = DVec4::new(
                        near.x + near.w * far.x,
                        near.y + near.w * far.y,
                        near.z + near.w * far.z,
                        near.w * far.w,
                    );
                    assert!(
                        (actual - expected).abs().max_element() < 2e-4,
                        "merge {record}: {actual:?} versus {expected:?}"
                    );
                    checked += 1;
                } else if black {
                    let begin = f64::from(config.interval(level, params.cache_config.w).1);
                    let direction = sphere(u, v);
                    let origin = position.truncate() + normal * bias + direction * begin;
                    let length = f64::from(params.cache_config.w) - begin;
                    // Black base/F0 does not remove Schlick's grazing term.
                    // Hit shading requires a BRDF oracle; clear rays have an
                    // exact unit-sky boundary independent of cache sampling.
                    if segment_blocked(origin, origin + direction * length, length, boxes) {
                        continue;
                    }
                    let expected = (near.truncate() + DVec3::ONE * near.w).extend(0.0);
                    assert!(
                        (actual - expected).abs().max_element() < 2e-4,
                        "fallback {record}: {actual:?} versus {expected:?}"
                    );
                    fallbacks += 1;
                }
            }
        }
        probe_offset += dims.element_product() as usize;
        ray_offset += (dims.element_product() * side * side) as usize;
    }
    (checked, blocked, fallbacks)
}

#[test]
#[ignore = "requires Vulkan and slangc"]
fn cascade_hit_queries_feed_bounded_cache_and_multibounce_streams() {
    run_cascade_fixture(false);
}

#[test]
#[ignore = "requires Vulkan and slangc"]
fn cascade_sky_fallback_matches_analytic_geometry() {
    run_cascade_fixture(true);
}

fn run_cascade_fixture(black: bool) {
    let hardware = std::env::var("BEVY_SOL_TEST_HARDWARE").as_deref() == Ok("1");
    let mut wgpu = bevy::render::settings::WgpuSettings::default();
    if hardware {
        wgpu.features |= WgpuFeatures::EXPERIMENTAL_RAY_QUERY;
    }
    let cascade = crate::RadianceCascadesConfig {
        angular_resolution: 8,
        ..default()
    };
    let mut app = App::new();
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
            .disable::<bevy::log::LogPlugin>()
            .disable::<WinitPlugin>()
            .disable::<bevy::render::pipelined_rendering::PipelinedRenderingPlugin>(),
    )
    .insert_resource(GlobalAmbientLight {
        brightness: 0.0,
        ..default()
    })
    .add_plugins(crate::HybridGiPlugin {
        config: crate::HybridGiConfig {
            radiance_cascades: Some(cascade.clone()),
            probe_directions: 4,
            ray_backend: if hardware {
                GiRayBackend::Hardware
            } else {
                GiRayBackend::Software
            },
            cache_capacity: 1024,
            multibounce: !black,
            sky_radiance: Vec3::ONE,
            hash_grid: crate::HashGridCacheConfig {
                num_buckets: 128,
                tiles_per_bucket: 4,
                discard_multibounce_ray_probability: 0.0,
                ..default()
            },
            ..default()
        },
    });
    let image = app
        .world_mut()
        .resource_mut::<Assets<bevy::image::Image>>()
        .add(bevy::image::Image::new_target_texture(
            40,
            24,
            TextureFormat::Rgba16Float,
            None,
        ));
    let white = app
        .world_mut()
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: if black {
                Color::BLACK
            } else {
                Color::linear_rgb(0.6, 0.6, 0.6)
            },
            reflectance: if black { 0.0 } else { 0.5 },
            perceptual_roughness: 1.0,
            ..default()
        });
    let boxes = [
        (Vec3::new(6.0, 6.0, 0.1), Vec3::ZERO),
        (Vec3::new(0.1, 6.0, 6.0), Vec3::new(-3.0, 0.0, 1.5)),
        (Vec3::new(0.1, 6.0, 6.0), Vec3::new(3.0, 0.0, 1.5)),
        (Vec3::new(6.0, 0.1, 6.0), Vec3::new(0.0, 3.0, 1.5)),
        (Vec3::new(6.0, 0.1, 6.0), Vec3::new(0.0, -3.0, 1.5)),
        (Vec3::new(0.12, 3.0, 2.0), Vec3::new(0.5, 0.5, 1.4)),
    ];
    for (size, position) in boxes {
        let mesh = app
            .world_mut()
            .resource_mut::<Assets<Mesh>>()
            .add(Cuboid::from_size(size));
        app.world_mut().spawn((
            Mesh3d(mesh),
            MeshMaterial3d(white.clone()),
            Transform::from_translation(position),
        ));
    }
    app.world_mut().spawn((
        Camera3d::default(),
        HybridGi {
            reflections: false,
            ..default()
        },
        Msaa::Off,
        RenderTarget::Image(image.into()),
        Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    app.finish();
    app.cleanup();
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        app.update();
        let world = app.sub_app_mut(RenderApp).world_mut();
        if world
            .query::<&ViewGi>()
            .iter(world)
            .any(|view| view.frames >= 12)
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "cascade pipelines did not render"
        );
    }
    let mut primary_hits = 0;
    let mut bounce_hits = 0;
    let mut unused_tail_checked = false;
    let mut cached_indirect_checked = false;
    let mut merge_checked = 0;
    let mut blocked_boundaries = 0;
    let mut fallbacks_checked = 0;
    for _ in 0..24 {
        app.update();
        assert!(app.world().resource::<Messages<AppExit>>().is_empty());
        let world = app.sub_app_mut(RenderApp).world_mut();
        let device = world.resource::<RenderDevice>().clone();
        let queue = world.resource::<RenderQueue>().clone();
        let view = world.query::<&ViewGi>().single(world).unwrap();
        let params = view.params.get();
        let queries = params.cascades.w;
        let stride = params.cascade_sampling.y as u32;
        let phase = params.frame.x % stride;
        assert_eq!(
            (queries, stride),
            cascade.cache_queries(view.tiles, view.probes_count * 16)
        );
        assert!(u64::from(queries) * RAY_BYTES <= view.rays.size());
        let work_bytes = WORK_HEADER * 4;
        let query_bytes = u64::from(queries) * RAY_BYTES;
        let cascade_bytes = view.cascades.size();
        let probes_bytes = view.probes.size();
        let grid_offset = work_bytes + query_bytes + cascade_bytes + probes_bytes;
        let hash_offset = grid_offset + 96;
        let staging = device.create_buffer(&BufferDescriptor {
            label: Some("cascade query acceptance"),
            size: hash_offset + view.hash_tiles.size(),
            usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor { label: None });
        encoder.copy_buffer_to_buffer(&view.work, 0, &staging, 0, work_bytes);
        encoder.copy_buffer_to_buffer(&view.rays, 0, &staging, work_bytes, query_bytes);
        encoder.copy_buffer_to_buffer(
            &view.cascades,
            0,
            &staging,
            work_bytes + query_bytes,
            cascade_bytes,
        );
        encoder.copy_buffer_to_buffer(
            &view.probes,
            0,
            &staging,
            work_bytes + query_bytes + cascade_bytes,
            probes_bytes,
        );
        encoder.copy_buffer_to_buffer(&view.light_grid, 0, &staging, grid_offset, 96);
        encoder.copy_buffer_to_buffer(
            &view.hash_tiles,
            0,
            &staging,
            hash_offset,
            view.hash_tiles.size(),
        );
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
        let words: Vec<_> = mapped
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v))
            .collect();
        let work = &words[..WORK_HEADER as usize];
        assert!(work[7] <= queries && work[11] <= work[7]);
        primary_hits += work[7];
        bounce_hits += work[11];
        let ray_words = &words[WORK_HEADER as usize..((work_bytes + query_bytes) / 4) as usize];
        let cascade_words = &words[((work_bytes + query_bytes) / 4) as usize
            ..((work_bytes + query_bytes + cascade_bytes) / 4) as usize];
        let (checked, blocked, fallbacks) =
            check_cascade_merges(cascade_words, view.tiles, &cascade, params, &boxes, black);
        merge_checked += checked;
        blocked_boundaries += blocked;
        fallbacks_checked += fallbacks;
        let probe_words = &words
            [((work_bytes + query_bytes + cascade_bytes) / 4) as usize..(grid_offset / 4) as usize];
        let grid_words = &words[(grid_offset / 4) as usize..(hash_offset / 4) as usize];
        let hash_words = &words[(hash_offset / 4) as usize..];
        let cells_per_tile: u32 = (0..4).map(|mip| (params.hash_config.z >> mip).pow(2)).sum();
        let values_start = 16 + params.hash_config.w * 5;
        for cell in 0..params.hash_config.w * cells_per_tile {
            let address = (values_start + cell * 4 + 2) as usize;
            let count_half = hash_words[address + 1] >> 16;
            let rgb_nonzero = (hash_words[address] | (hash_words[address + 1] & 0xffff)) != 0;
            if count_half > 0 && count_half < 0x7c00 && rgb_nonzero {
                cached_indirect_checked = true;
                break;
            }
        }
        let grid_min = Vec3::new(
            f32::from_bits(grid_words[12]),
            f32::from_bits(grid_words[13]),
            f32::from_bits(grid_words[14]),
        );
        let grid_max = grid_min
            + Vec3::new(
                f32::from_bits(grid_words[20]),
                f32::from_bits(grid_words[21]),
                f32::from_bits(grid_words[22]),
            );
        let metadata_records = cascade.probes(view.tiles) as usize * 3;
        let hit_base = (metadata_records + 2 * params.cascades.z as usize) * 4;
        let mut ray_offset = 0;
        let mut metadata_offset = 0;
        for level in 0..cascade.levels {
            let dims = cascade.dimensions(view.tiles, level);
            let directions = cascade.directions(level);
            let side = cascade.angular_resolution << level;
            for ordinal in 0..dims.element_product() * directions {
                let record = ray_offset + ordinal;
                if cascade_words[hit_base + record as usize * 4 + 2] == u32::MAX {
                    continue;
                }
                let address = (metadata_offset + ordinal / directions) as usize * 12;
                let position = Vec3::new(
                    f32::from_bits(cascade_words[address]),
                    f32::from_bits(cascade_words[address + 1]),
                    f32::from_bits(cascade_words[address + 2]),
                );
                let normal = Vec3::new(
                    f32::from_bits(cascade_words[address + 4]),
                    f32::from_bits(cascade_words[address + 5]),
                    f32::from_bits(cascade_words[address + 6]),
                );
                let bin = ordinal % directions;
                let z = 1.0 - 2.0 * (bin / side) as f32 / side as f32 - 1.0 / side as f32;
                let radius = (1.0 - z * z).max(0.0).sqrt();
                let phi = std::f32::consts::TAU * ((bin % side) as f32 + 0.5) / side as f32;
                let direction = Vec3::new(radius * phi.cos(), radius * phi.sin(), z);
                let distance = f32::from_bits(cascade_words[hit_base + record as usize * 4 + 3]);
                let point = position + normal * params.cache_config.z + direction * distance;
                assert!(
                    (point.cmpge(grid_min - Vec3::splat(1e-4))
                        & point.cmple(grid_max + Vec3::splat(1e-4)))
                    .all(),
                    "fallback hit outside streamed light bounds: {point:?}, {grid_min:?}..{grid_max:?}"
                );
            }
            ray_offset += dims.element_product() * directions;
            metadata_offset += dims.element_product();
        }
        for slot in 0..queries as usize {
            let record = slot as u32 * stride + phase;
            let ray = &ray_words[slot * 40..(slot + 1) * 40];
            if record >= params.cascades.z {
                assert_eq!(ray[13], u32::MAX, "tail slot retained an old hit");
                assert_eq!(ray[32], u32::MAX, "tail slot retained an old bounce");
                unused_tail_checked = true;
                continue;
            }
            let mut ordinal = record;
            let mut probe_offset = 0;
            let mut owner = 0;
            for level in 0..cascade.levels {
                let dims = cascade.dimensions(view.tiles, level);
                let directions = cascade.directions(level);
                let level_count = dims.element_product() * directions;
                if ordinal < level_count {
                    owner = cascade_words[(probe_offset + ordinal / directions) as usize * 12 + 10];
                    break;
                }
                ordinal -= level_count;
                probe_offset += dims.element_product();
            }
            let fresh =
                probe_words[owner as usize * (probe_bytes(4) / 4) as usize + 15] != u32::MAX;
            let triangle = cascade_words[hit_base + record as usize * 4 + 2];
            assert_eq!(
                ray[13],
                if fresh { triangle } else { u32::MAX },
                "query slot {slot}, frame {}",
                params.frame.x
            );
            if ray[13] != u32::MAX {
                let distance = f32::from_bits(cascade_words[hit_base + record as usize * 4 + 3]);
                assert_eq!(
                    f32::from_bits(ray[11]),
                    distance,
                    "cache seed lost the interval offset"
                );
            } else {
                assert_eq!(ray[32], u32::MAX, "inactive query retained an old bounce");
            }
        }
        drop(mapped);
        staging.unmap();
    }
    assert!(
        unused_tail_checked,
        "fixture must cover a phase with no final-slot writer"
    );
    assert!(
        primary_hits > 0 && (black || bounce_hits > 0),
        "both cache visibility streams must be populated: primary={primary_hits}, bounce={bounce_hits}"
    );
    assert!(
        black || cached_indirect_checked,
        "multibounce radiance never reached persistent cache values"
    );
    if black {
        assert!(
            fallbacks_checked > 100,
            "fixture did not cover continuation fallback: {fallbacks_checked}"
        );
        assert_eq!(bounce_hits, 0);
        assert!(!cached_indirect_checked);
    }
    assert!(
        merge_checked > 100 && blocked_boundaries > 100,
        "fixture must exercise interpolation and rejected boundary rays: {merge_checked}, {blocked_boundaries}"
    );
    println!(
        "Independent spatial/angular merges={merge_checked}, occluded boundaries={blocked_boundaries}, fallbacks={fallbacks_checked}"
    );
    println!(
        "Bounded cascade cache streams: primary={primary_hits}, multibounce={bounce_hits}; sparse tail reset verified"
    );
}
