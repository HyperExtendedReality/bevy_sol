#![recursion_limit = "256"]
//! GPU differential checks against fixed values from the pinned AMD equations.
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
use bevy_sol::HashGridCacheConfig;
use std::{borrow::Cow, time::Duration};

const CHECKS: &str = r#"
@group(0) @binding(26) var<storage, read_write> checks: array<u32>;
@compute @workgroup_size(1)
fn seed_hash_test() {
    atomicStore(&work[3], 0u);
    let desc = hash_tile_descriptor(vec3(-0.25, 0.5, 0.125), vec3(1.0, 0.0, 0.0), 1.0);
    checks[0] = desc.bucket; checks[1] = desc.tag; checks[2] = desc.offset.x; checks[3] = desc.offset.y;
    let inputs = array<u32, 3>(0u, 123u, 0xffffffffu);
    for (var i = 0u; i < 3u; i++) { checks[4u+i] = pcg_hash(inputs[i]); checks[7u+i] = xx_hash(inputs[i]); }
    for (var i = 0u; i < 4u; i++) {
        let position = vec3(0.01, 0.01 + f32(i % 2u) * 0.06, 0.01 + f32(i / 2u) * 0.06);
        checks[10u+i] = hash_tile_insert(position, vec3(1.0, 0.0, 0.0), 1.0);
    }
    let packed = hash_pack(vec4(1.0, 2.0, 3.0, 0.5)); checks[30] = packed.x; checks[31] = packed.y;
}
@compute @workgroup_size(4)
fn accumulate_hash_test(@builtin(local_invocation_index) lane: u32) {
    let amount = select(f32(lane + 1u), 3.0, p.frame.x == 2u);
    hash_accumulate(checks[10u + lane], vec3(amount, amount * 2.0, amount * 3.0), false);
    if lane == 0u && p.frame.x == 1u { hash_accumulate(checks[10], vec3(5.0, 10.0, 15.0), true); }
}
@compute @workgroup_size(1)
fn read_hash_test() {
    let cell = checks[10]; let direct = hash_filtered(cell, false); let indirect = hash_filtered(cell, true);
    for (var i = 0u; i < 4u; i++) { checks[16u+i] = bitcast<u32>(direct[i]); checks[20u+i] = bitcast<u32>(indirect[i]); }
    let mip0 = hash_read(cell, false);
    for (var i = 0u; i < 4u; i++) { checks[24u+i] = bitcast<u32>(mip0[i]); }
    checks[28] = hash_tile_find(vec3(0.01), vec3(1.0, 0.0, 0.0), 1.0);
    checks[29] = atomicLoad(&work[3]);
}
"#;

#[test]
#[ignore = "requires a Vulkan compute GPU"]
fn amd_hashing_half_packing_tile_mips_temporal_update_and_decay() {
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
    );
    app.finish();
    app.cleanup();
    let render = app.sub_app(RenderApp);
    let device = render.world().resource::<RenderDevice>();
    let queue = render.world().resource::<RenderQueue>();
    let config = HashGridCacheConfig {
        num_buckets: 16,
        tiles_per_bucket: 2,
        ..default()
    };
    let buffer = |label, size, usage| {
        device.create_buffer(&BufferDescriptor {
            label: Some(label),
            size,
            usage,
            mapped_at_creation: false,
        })
    };
    let uniform = buffer(
        "hash reference params",
        368,
        BufferUsages::UNIFORM | BufferUsages::COPY_DST,
    );
    let work = buffer("hash reference work", 96, BufferUsages::STORAGE);
    let tiles = buffer(
        "hash reference tiles",
        (16 + 32 * (5 + 340 + 512)) * 4,
        BufferUsages::STORAGE,
    );
    let result = buffer(
        "hash reference results",
        128,
        BufferUsages::STORAGE | BufferUsages::COPY_SRC,
    );
    let staging = buffer(
        "hash reference readback",
        128,
        BufferUsages::MAP_READ | BufferUsages::COPY_DST,
    );
    let mut words = [0u32; 92];
    words[60] = 0.1f32.to_bits(); // Params.cache_config.x
    words[64] = 50; // tile decay
    words[72..76].copy_from_slice(&[config.num_buckets, config.tiles_per_bucket, 8, 32]);
    words[76..80].copy_from_slice(&[16.0f32.to_bits(), 16.0f32.to_bits(), 0, 0.01f32.to_bits()]);
    let layout = device.create_bind_group_layout(
        "hash reference layout",
        &[0, 20, 25, 26].map(|binding| BindGroupLayoutEntry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::Buffer {
                ty: if binding == 0 {
                    BufferBindingType::Uniform
                } else {
                    BufferBindingType::Storage { read_only: false }
                },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }),
    );
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: Some("hash reference pipeline layout"),
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let group = device.create_bind_group(
        "hash reference bindings",
        &layout,
        &[(&uniform, 0), (&work, 20), (&tiles, 25), (&result, 26)].map(|(buffer, binding)| {
            BindGroupEntry {
                binding,
                resource: buffer.as_entire_binding(),
            }
        }),
    );
    let source = format!(
        "{}\n{}\n{}\n{}\n{CHECKS}",
        include_str!("../src/hybrid.wgsl"),
        include_str!("../src/hash_grid.wgsl"),
        include_str!("../src/ggx.wgsl"),
        include_str!("../src/reflections.wgsl")
    );
    let module = device.create_and_validate_shader_module(ShaderModuleDescriptor {
        label: Some("hash reference checks"),
        source: ShaderSource::Wgsl(Cow::Owned(source)),
    });
    let names = [
        "clear_hash_tiles",
        "seed_hash_test",
        "initialize_hash_tiles",
        "accumulate_hash_test",
        "update_hash_tiles",
        "read_hash_test",
    ];
    let pipelines: Vec<_> = names
        .iter()
        .map(|entry| {
            device.create_compute_pipeline(&RawComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&pipeline_layout),
                module: &module,
                entry_point: Some(entry),
                compilation_options: default(),
                cache: None,
            })
        })
        .collect();
    let mut run = |frame, reset, populate: bool| {
        words[52] = frame;
        words[53] = reset;
        words[65] = 1;
        let bytes: Vec<_> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
        queue.write_buffer(&uniform, 0, &bytes);
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
        for (index, pipeline) in pipelines.iter().enumerate() {
            if !populate && (1..=4).contains(&index) {
                continue;
            }
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        encoder.copy_buffer_to_buffer(&result, 0, &staging, 0, 128);
        queue.submit([encoder.finish()]);
        let (send, receive) = std::sync::mpsc::channel();
        staging
            .slice(..)
            .map_async(MapMode::Read, move |status| send.send(status).unwrap());
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
        let values: Vec<_> = mapped
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v))
            .collect();
        drop(mapped);
        staging.unmap();
        values
    };
    let floats = |values: &[u32], start| {
        values[start..start + 4]
            .iter()
            .map(|v| f32::from_bits(*v))
            .collect::<Vec<_>>()
    };
    let first = run(1, 1, true);
    assert_eq!(
        &first[..10],
        &[
            13, 909915491, 7, 1, 129708002, 1051671337, 3861530882, 878055299, 1321542528,
            975606439
        ]
    );
    assert_eq!(&first[30..32], &[0x40003c00, 0x38004200]);
    assert_eq!(first[29], 1, "all four cells must share one tile");
    assert_eq!(floats(&first, 16), [10.0, 20.0, 30.0, 4.0]);
    assert_eq!(floats(&first, 20), [5.0, 10.0, 15.0, 1.0]);
    assert_eq!(floats(&first, 24), [1.0, 2.0, 3.0, 1.0]);
    let second = run(2, 0, true);
    assert_eq!(floats(&second, 16), [22.0, 44.0, 66.0, 8.0]);
    assert_eq!(floats(&second, 24), [4.0, 8.0, 12.0, 2.0]);
    assert_eq!(second[29], 1, "touch once per tile per frame");
    assert_ne!(
        run(51, 0, false)[28],
        u32::MAX,
        "tile survives 49 unused frames"
    );
    assert_eq!(
        run(52, 0, false)[28],
        u32::MAX,
        "tile expires at 50 unused frames"
    );
}
