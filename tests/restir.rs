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
use bevy_sol::WorldSpaceRestirConfig;
use std::{borrow::Cow, time::Duration};

fn pcg(v: u32) -> u32 {
    let state = v.wrapping_mul(747796405).wrapping_add(2891336453);
    let word = ((state >> ((state >> 28) + 4)) ^ state).wrapping_mul(277803737);
    (word >> 22) ^ word
}
fn xx(v: u32) -> u32 {
    let mut v = v
        .wrapping_add(374761393)
        .rotate_left(17)
        .wrapping_mul(668265263);
    v = (v ^ (v >> 15)).wrapping_mul(2246822519);
    v = (v ^ (v >> 13)).wrapping_mul(3266489917);
    v ^ (v >> 16)
}
fn descriptor(position: Vec3, eye: Vec3, scale: f32, cells: u32) -> (u32, u32) {
    let level = (1000.0 * eye.distance(position) * scale)
        .max(1.0)
        .log2()
        .trunc()
        .clamp(0.0, 30.0) as u32;
    let cell = (position / (0.001 * 2.0f32.powi(level as i32)))
        .floor()
        .as_ivec3()
        .as_uvec3();
    let index = pcg(level.wrapping_add(pcg(cell
        .x
        .wrapping_add(pcg(cell.y.wrapping_add(pcg(cell.z)))))))
        % cells;
    let hash =
        xx(level.wrapping_add(xx(cell.x.wrapping_add(xx(cell.y.wrapping_add(xx(cell.z))))))).max(1);
    (index, hash)
}

#[test]
#[ignore = "requires Vulkan and slangc"]
fn source_hash_collisions_scan_compaction_and_temporal_resampling() {
    for directions in [4, 8] {
        run_source_checks(directions);
    }
}
fn run_source_checks(directions: u32) {
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
    let mut shader = bevy_slang::SlangCompiler::default()
        .with_source_root(concat!(env!("CARGO_MANIFEST_DIR"), "/src/shaders"))
        .compile_source(
            "restir_checks.slang",
            include_str!("restir_checks.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec![
                    "GI_HARDWARE=0".into(),
                    "GI_TEXTURED=0".into(),
                    format!("PROBE_DIRECTIONS={}", directions.pow(2)),
                ],
                ..default()
            },
        )
        .unwrap();
    let bindings = [0, 1, 2, 4, 20, 26, 27, 33];
    bevy_slang::remap_spirv_bindings(
        &mut shader,
        &bindings
            .iter()
            .enumerate()
            .map(|(i, &binding)| bevy_slang::SpirvBindingRemap {
                group: 0,
                binding,
                mapped_binding: i as u32,
            })
            .collect::<Vec<_>>(),
    )
    .unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!()
    };
    // SAFETY: embedded application source is compiled and validated by Slang.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("ReSTIR source checks"),
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
    let make_buffer = |size, usage| {
        device.create_buffer(&BufferDescriptor {
            label: None,
            size,
            usage,
            mapped_at_creation: false,
        })
    };
    let uniform = make_buffer(576, BufferUsages::UNIFORM | BufferUsages::COPY_DST);
    let geometry = make_buffer(256, BufferUsages::STORAGE);
    let lights = make_buffer(80, BufferUsages::STORAGE | BufferUsages::COPY_DST);
    let probes = make_buffer(
        3 * u64::from(80 + 16 * directions.pow(2) + 144),
        BufferUsages::STORAGE,
    );
    let work = make_buffer(512, BufferUsages::STORAGE);
    let checks = make_buffer(
        8192,
        BufferUsages::STORAGE | BufferUsages::COPY_SRC | BufferUsages::COPY_DST,
    );
    let lut = make_buffer(16384, BufferUsages::STORAGE);
    let config = WorldSpaceRestirConfig {
        num_cells: 32768,
        entries_per_cell: 2,
        ..default()
    };
    let table = make_buffer(config.bytes(64), BufferUsages::STORAGE);
    let staging = make_buffer(8192, BufferUsages::MAP_READ | BufferUsages::COPY_DST);
    let layout = device.create_bind_group_layout(
        "ReSTIR checks",
        &bindings.map(|binding| BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::Buffer {
                ty: if binding == 0 {
                    BufferBindingType::Uniform
                } else {
                    BufferBindingType::Storage {
                        read_only: matches!(binding, 1 | 2),
                    }
                },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }),
    );
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let names = [
        "clear_restir",
        "seed_restir_scan",
        "scan_restir_counts",
        "scan_restir_blocks",
        "add_restir_block_offsets",
        "read_restir_scan",
        "insert_restir_checks",
        "compact_restir",
        "read_restir_insert",
        "read_restir_lookup",
        "seed_restir_resample",
        "check_restir_resample",
        "seed_atlas_checks",
        "project_probe_atlas",
        "read_atlas_checks",
        "read_cone_checks",
        "read_diffuse_only_target",
    ];
    let pipelines: Vec<_> = names
        .iter()
        .map(|name| {
            device.create_compute_pipeline(&RawComputePipelineDescriptor {
                label: Some(name),
                layout: Some(&pipeline_layout),
                module: &module,
                entry_point: Some(name),
                compilation_options: default(),
                cache: None,
            })
        })
        .collect();
    let group = device.create_bind_group(
        "ReSTIR checks",
        &layout,
        &bindings
            .into_iter()
            .zip([
                &uniform, &geometry, &lights, &probes, &work, &checks, &lut, &table,
            ])
            .map(|(binding, buffer)| BindGroupEntry {
                binding,
                resource: buffer.as_entire_binding(),
            })
            .collect::<Vec<_>>(),
    );
    let mut params = [0u32; 144];
    params[52] = 7;
    params[53] = 1;
    params[57] = 1;
    params[58] = 1;
    params[136..140].copy_from_slice(&[128, 2, 128, 0]);
    params[143] = 0.01f32.to_bits();
    let upload = |params: &[u32; 144]| {
        queue.write_buffer(
            &uniform,
            0,
            &params
                .iter()
                .flat_map(|v| v.to_le_bytes())
                .collect::<Vec<_>>(),
        )
    };
    upload(&params);
    queue.write_buffer(
        &lights,
        0,
        &[
            0.0f32, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
        ]
        .iter()
        .flat_map(|v| v.to_le_bytes())
        .collect::<Vec<_>>(),
    );
    let dispatch = |stages: &[(&str, u32)]| {
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
        for &(name, count) in stages {
            let index = names.iter().position(|n| *n == name).unwrap();
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
            pass.set_pipeline(&pipelines[index]);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(count, 1, 1);
        }
        encoder.copy_buffer_to_buffer(&checks, 0, &staging, 0, 8192);
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
        let data: Vec<_> = staging
            .slice(..)
            .get_mapped_range()
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v))
            .collect();
        staging.unmap();
        data
    };
    let scan = [
        ("scan_restir_counts", 2),
        ("scan_restir_blocks", 1),
        ("add_restir_block_offsets", 4),
    ];
    let mut stages = vec![("clear_restir", 4), ("seed_restir_scan", 4)];
    stages.extend(scan);
    stages.push(("read_restir_scan", 4));
    let data = dispatch(&stages);
    let mut prefix = 0;
    for (i, &actual) in data[..256].iter().enumerate() {
        assert_eq!(actual, prefix, "scan entry {i}");
        prefix += i as u32 % 7;
    }
    // 512 block totals require several blocks per scan lane, exercising the
    // second-level scan's segment offsets rather than only its small-table path.
    params[136] = 32768;
    params[48] = 256;
    upload(&params);
    let data = dispatch(&[
        ("clear_restir", 1024),
        ("seed_restir_scan", 1024),
        ("scan_restir_counts", 512),
        ("scan_restir_blocks", 1),
        ("add_restir_block_offsets", 1024),
        ("read_restir_scan", 4),
    ]);
    for (i, &actual) in data[..256].iter().enumerate() {
        let entry = i as u32 * 256;
        let remainder = entry % 7;
        assert_eq!(
            actual,
            (entry / 7) * 21 + remainder * (remainder.saturating_sub(1)) / 2,
            "large scan entry {entry}"
        );
    }
    params[136] = 128;
    params[48] = 0;
    upload(&params);
    // Equal keys must share a collision slot, preserving every insertion ordinal.
    // Distinct checksums with the same bucket exhaust exactly two slots.
    let mut colliders = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for i in 0..100000 {
        let pos = Vec3::new(i as f32 * 0.137 - 500.0, -1.25, -3.5);
        let key = descriptor(pos, Vec3::ZERO, 0.01, 128);
        if key.0 == 0 && seen.insert(key.1) {
            colliders.push(pos);
            if colliders.len() == 3 {
                break;
            }
        }
    }
    assert_eq!(colliders.len(), 3);
    for positions in [
        vec![Vec3::new(-1.25, 2.5, -3.75); 128],
        (0..128).map(|i| colliders[i % 3]).collect(),
    ] {
        params[52] = 7;
        upload(&params);
        let input: Vec<_> = positions
            .iter()
            .flat_map(|v| v.extend(0.0).to_array())
            .flat_map(f32::to_le_bytes)
            .collect();
        queue.write_buffer(&checks, 4096, &input);
        let mut stages = vec![("clear_restir", 4), ("insert_restir_checks", 2)];
        stages.extend(scan);
        stages.extend([("compact_restir", 2), ("read_restir_insert", 2)]);
        dispatch(&stages);
        params[52] = 8;
        upload(&params);
        let data = dispatch(&[("read_restir_lookup", 2)]);
        let successful: Vec<_> = (0..128)
            .filter(|&i| data[256 + i] != 0)
            .map(|i| i as u32)
            .collect();
        assert_eq!(data[400] as usize, successful.len());
        let mut compacted = data[512..512 + successful.len()].to_vec();
        compacted.sort();
        assert_eq!(compacted, successful);
        if positions[0] == positions[1] {
            assert_eq!(successful.len(), 128);
            assert!(data[896..1024].iter().all(|&n| n == 128));
        } else {
            assert!((85..=86).contains(&successful.len()));
        }
        for (i, pos) in positions.iter().enumerate() {
            let key = descriptor(*pos, Vec3::ZERO, 0.01, 128);
            assert_eq!(
                (data[1536 + 2 * i], data[1537 + 2 * i]),
                key,
                "independent source hash {i}"
            );
            if data[768 + i] != u32::MAX {
                assert_eq!(data[768 + i] / 2, descriptor(*pos, Vec3::ZERO, 0.01, 128).0);
            }
        }
    }
    for mode in 0..3 {
        params[52] = 7 + mode % 2;
        // Fixture scenarios must not toggle the SourceAtlas projection flag.
        params[43] = mode;
        params[139] = 0;
        upload(&params);
        let mut stages = vec![("clear_restir", 4), ("seed_restir_resample", 1)];
        stages.extend(scan);
        stages.push(("compact_restir", 2));
        dispatch(&stages);
        params[52] += 1;
        upload(&params);
        let data = dispatch(&[("check_restir_resample", 1)]);
        let expected = match mode {
            0 => (82.0 / 21.0, 21.0),
            1 => (2.0, 1.0),
            _ => (2.0 / 21.0, 21.0),
        };
        assert!(
            (f32::from_bits(data[0]) - expected.0).abs() < 1e-5,
            "mode {mode}: {}",
            f32::from_bits(data[0])
        );
        assert_eq!(f32::from_bits(data[1]), expected.1);
        assert_eq!(f32::from_bits(data[2]), 1.0);
        let normal = |v: f32| ((v * 511.0 + 0.5 * v.signum()) as i32 as u32) & 1023;
        assert_eq!(data[3], normal(-0.6) | (normal(0.8) << 10));
        let rgb = |v: f32, max: f32| (v.powf(1.0 / 2.2) * max) as u32;
        assert_eq!(
            data[4],
            ((rgb(0.25, 31.0) << 11) | (rgb(0.5, 63.0) << 5) | rgb(0.75, 31.0)) << 16 | 255
        );
    }
    params[139] = 17;
    upload(&params);
    let data = dispatch(&[("read_diffuse_only_target", 1)]);
    let grazing = (1.0 - (std::f64::consts::PI / 8.0).cos()).powi(5);
    let expected = 0.96 * (1.0 - grazing).powi(2) * 1.05 / std::f64::consts::PI;
    assert!((f64::from(f32::from_bits(data[0])) - expected).abs() < 2e-6);
    assert!((f32::from_bits(data[1]) - std::f32::consts::FRAC_1_PI).abs() < 2e-6);
    assert_eq!(f32::from_bits(data[2]), 0.0);
    params[51] = directions;
    params[139] = 1;
    upload(&params);
    let data = dispatch(&[
        ("seed_atlas_checks", (3 * directions.pow(2)).div_ceil(64)),
        ("project_probe_atlas", (3 * directions.pow(2)).div_ceil(64)),
        ("read_atlas_checks", 1),
    ]);
    for (i, expected) in [1.0, 64.0 / 63.0, 0.0625, 64.0 / 63.0, 1.0]
        .into_iter()
        .enumerate()
    {
        assert!(
            (f32::from_bits(data[128 + i]) - expected).abs() < 1e-6,
            "empty-cell energy spread {i}"
        );
    }
    for normal in 0..3 {
        let mut expected = [[0.0f64; 3]; 9];
        for bin in 0..directions.pow(2) {
            let u = 2.0 * ((bin % directions) as f64 + 0.5) / f64::from(directions) - 1.0;
            let v = 2.0 * ((bin / directions) as f64 + 0.5) / f64::from(directions) - 1.0;
            let sx = (u + v) / 2.0;
            let sy = (u - v) / 2.0;
            let z = 1.0 - sx.abs() - sy.abs();
            let radius = 1.0 - z.abs();
            let phi = if radius == 0.0 {
                0.0
            } else {
                std::f64::consts::FRAC_PI_4 * ((sy.abs() - sx.abs()) / radius + 1.0)
            };
            let sine = radius * (2.0 - radius * radius).sqrt();
            let dx = sine * sx.signum() * phi.cos();
            let dy = sine * sy.signum() * phi.sin();
            let dz = z.signum() * (1.0 - radius * radius);
            let [x, y, z] = match normal {
                0 => [dy, -dx, dz],
                1 => [dy, dx, -dz],
                _ => [dz, -dx, -dy],
            };
            let basis = [
                0.2820947918,
                -0.4886025119 * y,
                0.4886025119 * z,
                -0.4886025119 * x,
                1.0925484306 * x * y,
                -1.0925484306 * y * z,
                0.3153915653 * (3.0 * z * z - 1.0),
                -1.0925484306 * x * z,
                0.5462742153 * (x * x - y * y),
            ];
            let radiance = [
                (bin % 7 + 1) as f64 / 4.0,
                (bin % 11 + 1) as f64 / 8.0,
                (bin % 13 + 1) as f64 / 16.0,
            ];
            for j in 0..9 {
                for c in 0..3 {
                    expected[j][c] += basis[j] * radiance[c] / f64::from(directions);
                }
            }
        }
        for (j, expected) in expected.iter().enumerate() {
            let address = 4 * (normal * 9 + j);
            for (c, &reference) in expected.iter().enumerate() {
                let actual = f32::from_bits(data[address + c]) as f64;
                assert!(
                    (actual - reference).abs() < 0.0005 + reference.abs() * 0.001,
                    "atlas SH normal {normal} coefficient {j} channel {c}: {actual} vs {reference}"
                );
            }
            assert_eq!(f32::from_bits(data[address + 3]), directions.pow(2) as f32);
        }
    }
    let data = dispatch(&[("read_cone_checks", 1)]);
    for (i, expected) in [0.0, -0.14385619, 6.5, 7.5, 0.85614381, 0.0, -0.14385619]
        .into_iter()
        .enumerate()
    {
        assert!(
            (f32::from_bits(data[i]) - expected).abs() < 2e-6,
            "source area cone LOD {i}"
        );
    }
}
