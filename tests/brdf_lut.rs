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
use std::time::Duration;
#[test]
#[ignore = "requires Vulkan and slangc"]
fn bounded_ggx_lut_preserves_mirror_energy() {
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
    let world = app.sub_app(RenderApp).world();
    let device = world.resource::<RenderDevice>();
    let queue = world.resource::<RenderQueue>();
    let mut shader = bevy_slang::SlangCompiler::default()
        .with_source_root(concat!(env!("CARGO_MANIFEST_DIR"), "/src/shaders"))
        .compile_source(
            "blue_noise_checks.slang",
            include_str!("blue_noise_checks.slang"),
            &bevy_slang::SlangSettings {
                optimization: Some(2),
                defines: vec!["GI_HARDWARE=0".into(), "GI_TEXTURED=0".into()],
                ..default()
            },
        )
        .unwrap();
    bevy_slang::remap_spirv_bindings(
        &mut shader,
        &[bevy_slang::SpirvBindingRemap {
            group: 0,
            binding: 27,
            mapped_binding: 0,
        }],
    )
    .unwrap();
    let bevy::shader::Source::SpirV(bytes) = shader.source else {
        panic!();
    };
    // SAFETY: trusted application source compiled with Slang's SPIR-V validation.
    let module = unsafe {
        device.create_shader_module(ShaderModuleDescriptor {
            label: Some("bounded GGX LUT test"),
            source: ShaderSource::SpirV(std::borrow::Cow::Owned(
                bytes
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|v| u32::from_le_bytes(*v))
                    .collect(),
            )),
        })
    };
    let buffer = device.create_buffer(&BufferDescriptor {
        label: None,
        size: 16384 + 327680,
        usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let staging = device.create_buffer(&BufferDescriptor {
        label: None,
        size: 16384,
        usage: BufferUsages::MAP_READ | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let layout = device.create_bind_group_layout(
        "LUT test",
        &[BindGroupLayoutEntry {
            binding: 27,
            visibility: ShaderStages::COMPUTE,
            ty: BindingType::Buffer {
                ty: BufferBindingType::Storage { read_only: false },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }],
    );
    let group = device.create_bind_group(
        "LUT",
        &layout,
        &[BindGroupEntry {
            binding: 27,
            resource: buffer.as_entire_binding(),
        }],
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
        entry_point: Some("compute_brdf_lut"),
        compilation_options: default(),
        cache: None,
    });
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    {
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(4, 4, 1);
    }
    encoder.copy_buffer_to_buffer(&buffer, 0, &staging, 0, 16384);
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
    let words: Vec<_> = data
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| u32::from_le_bytes(*v))
        .collect();
    let mirror = words[31 * 4];
    assert_eq!(
        mirror & 0xffff,
        0x3c00,
        "mirror directional albedo must quantize to half-float one"
    );
    assert!(
        mirror >> 16 < 0x1000,
        "normal-incidence Fresnel grazing term must approach zero"
    );
    assert!(
        words[(31 + 31 * 32) * 4] & 0xffff < 0x3800,
        "rough GGX must lose energy through masking"
    );
    drop(data);
    staging.unmap();
    let noise = include_bytes!("../src/data/gi12-blue-noise.bin");
    queue.write_buffer(&buffer, 16384, noise);
    let pipeline = device.create_compute_pipeline(&RawComputePipelineDescriptor {
        label: Some("AMD blue-noise table differential"),
        layout: Some(&pipeline_layout),
        module: &module,
        entry_point: Some("check_blue_noise"),
        compilation_options: default(),
        cache: None,
    });
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    {
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(16, 1, 1);
    }
    encoder.copy_buffer_to_buffer(&buffer, 0, &staging, 0, 16384);
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
    for (sample, bytes) in data.as_chunks::<4>().0.iter().enumerate() {
        let x = ((sample * 73) % 131) & 127;
        let y = (((sample * 97) / 131) % 137) & 127;
        let dimension = sample % 256;
        let tile = (x + y * 128) * 8 + dimension % 8;
        let rank = usize::from(noise[65536 + tile]);
        let value = noise[dimension + rank * 256] ^ noise[196608 + tile];
        let frame = if sample % 3 == 0 { 256 } else { sample * 17 };
        let expected = ((0.5 + f32::from(value)) / 256.0
            + (frame & 255) as f32 * std::f32::consts::GOLDEN_RATIO)
            .fract();
        let actual = f32::from_le_bytes(*bytes);
        let error = (actual - expected).abs();
        assert!((0.0..1.0).contains(&actual));
        assert!(
            error.min(1.0 - error) < 5e-5,
            "sample {sample}: {actual} vs {expected}"
        );
    }
    drop(data);
    staging.unmap();
    let pipeline = device.create_compute_pipeline(&RawComputePipelineDescriptor {
        label: Some("AMD reflection sampling frame differential"),
        layout: Some(&pipeline_layout),
        module: &module,
        entry_point: Some("check_reflection_sampling_frame"),
        compilation_options: default(),
        cache: None,
    });
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    {
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(16, 1, 1);
    }
    encoder.copy_buffer_to_buffer(&buffer, 0, &staging, 0, 16384);
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
    let normals = [
        Vec3::Z,
        Vec3::X,
        Vec3::Y,
        Vec3::NEG_Z,
        Vec3::new(0.001, 0.0, -1.0).normalize(),
        Vec3::new(-1.0, 2.0, 3.0).normalize(),
        Vec3::new(1.0, -3.0, 0.0).normalize(),
        Vec3::new(1.0, 2.0, -3.0).normalize(),
    ];
    for (i, bytes) in data.as_chunks::<16>().0.iter().enumerate() {
        let actual = Vec4::from_array(std::array::from_fn(|channel| {
            f32::from_le_bytes(bytes.as_chunks::<4>().0[channel])
        }));
        let normal = normals[i % 8];
        // Independent source GetOrthoVectors construction, including z==0.
        let swap = normal.z == 0.0;
        let v = if swap {
            Vec3::new(normal.z, normal.y, normal.x)
        } else {
            normal
        };
        let k = (v.z * v.z + normal.y * normal.y).sqrt().recip();
        let mut tangent = Vec3::new(0.0, -v.z * k, normal.y * k);
        if swap {
            tangent = Vec3::new(tangent.z, tangent.y, tangent.x);
        }
        let sample = |dimension: usize| {
            let tile = (((i % 131) & 127) + ((i / 131) & 127) * 128) * 8 + dimension;
            let rank = usize::from(noise[65536 + tile]);
            let value = noise[dimension + rank * 256] ^ noise[196608 + tile];
            ((0.5 + f32::from(value)) / 256.0
                + ((i * 17) & 255) as f32 * std::f32::consts::GOLDEN_RATIO)
                .fract()
        };
        let expected = 2.0
            * ((2.0 * sample(2) - 1.0) * tangent + (2.0 * sample(3) - 1.0) * normal.cross(tangent));
        assert!(
            actual.truncate().distance(expected) < 4e-4,
            "jitter {i}: {actual} vs {expected}"
        );
        // The source snaps normals near -Z to its antipodal branch.
        assert!(actual.w < 0.0011, "rotation {i}: {actual}");
    }
}
