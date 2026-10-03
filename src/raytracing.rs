//! Hardware traversal shares exactly the same triangle ordering and shading data
//! as software traversal. Wgpu owns acceleration-structure synchronization/lifetime.
use crate::scene::Geometry;
use bevy::{
    prelude::*,
    render::{
        render_resource::*,
        renderer::{RenderDevice, RenderQueue},
    },
};

pub(crate) struct RayScene {
    pub tlas: Tlas,
    pub revision: u64,
}

impl RayScene {
    pub fn build(
        device: &RenderDevice,
        queue: &RenderQueue,
        geometry: &Geometry,
        revision: u64,
    ) -> Self {
        let mut vertices = Vec::new();
        for triangle in geometry.packed[geometry.node_count as usize * 2..]
            .as_chunks::<{ crate::scene::TRIANGLE_WORDS }>()
            .0
        {
            for vertex in &triangle[..3] {
                for coordinate in vertex.to_array() {
                    vertices.extend_from_slice(&coordinate.to_ne_bytes());
                }
            }
        }
        let mut tlas = device.wgpu_device().create_tlas(&CreateTlasDescriptor {
            label: Some("bevy_sol hardware scene"),
            flags: AccelerationStructureFlags::PREFER_FAST_TRACE,
            update_mode: AccelerationStructureUpdateMode::Build,
            max_instances: 1,
        });
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor {
            label: Some("bevy_sol build hardware scene"),
        });
        if !vertices.is_empty() {
            let buffer = device.create_buffer_with_data(&BufferInitDescriptor {
                label: Some("bevy_sol raytracing vertices"),
                contents: &vertices,
                usage: BufferUsages::BLAS_INPUT,
            });
            let size = BlasTriangleGeometrySizeDescriptor {
                vertex_format: VertexFormat::Float32x3,
                vertex_count: (vertices.len() / 16) as u32,
                index_format: None,
                index_count: None,
                flags: AccelerationStructureGeometryFlags::empty(),
            };
            let blas = device.wgpu_device().create_blas(
                &CreateBlasDescriptor {
                    label: Some("bevy_sol triangles"),
                    flags: AccelerationStructureFlags::PREFER_FAST_TRACE,
                    update_mode: AccelerationStructureUpdateMode::Build,
                },
                BlasGeometrySizeDescriptors::Triangles {
                    descriptors: vec![size.clone()],
                },
            );
            let build = BlasBuildEntry {
                blas: &blas,
                geometry: BlasGeometries::TriangleGeometries(vec![BlasTriangleGeometry {
                    size: &size,
                    vertex_buffer: &buffer,
                    first_vertex: 0,
                    vertex_stride: 16,
                    index_buffer: None,
                    first_index: None,
                    transform_buffer: None,
                    transform_buffer_offset: None,
                }]),
            };
            tlas[0] = Some(TlasInstance::new(
                &blas,
                [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0],
                0,
                0xff,
            ));
            encoder.build_acceleration_structures(&[build], &[]);
        }
        encoder.build_acceleration_structures(&[], [&tlas]);
        queue.submit([encoder.finish()]);
        Self { tlas, revision }
    }
}

pub(crate) fn hardware_shader(software: &str) -> String {
    let start = software
        .find("fn trace_impl(")
        .expect("trace_impl shader contract");
    let end = software[start..]
        .find("fn trace(")
        .expect("trace shader contract")
        + start;
    let mut shader = software.to_owned();
    shader.replace_range(start..end, include_str!("raytracing.wgsl"));
    shader.insert_str(0, "enable wgpu_ray_query;\n");
    shader
}
