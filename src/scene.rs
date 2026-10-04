use crate::{GiExclude, GiSettings};
use bevy::{
    mesh::{
        PrimitiveTopology, VertexAttributeValues,
        morph::{MeshMorphWeights, MorphWeights},
        skinning::{SkinnedMesh, SkinnedMeshInverseBindposes},
    },
    prelude::*,
    render::extract_resource::ExtractResource,
};
use std::{collections::HashMap, sync::Arc};
pub(crate) const TRIANGLE_WORDS: usize = 16;

/// Scene preparation counters. GPU pass durations use `RenderDiagnosticsPlugin`.
#[derive(Resource, Default, Clone, Debug)]
pub struct GiStatistics {
    pub triangles: usize,
    pub lights: usize,
    pub excluded_meshes: usize,
    pub bvh_builds: u64,
    pub bvh_refits: u64,
    pub material_updates: u64,
    pub light_updates: u64,
    pub scene_gpu_bytes: u64,
    pub error: Option<String>,
}
#[derive(Resource, Clone, Default, ExtractResource)]
pub(crate) struct GiScene {
    pub data: Option<Arc<Geometry>>,
    pub lights: Arc<Vec<Vec4>>,
    pub geometry_revision: u64,
    pub shape_revision: u64,
    pub lighting_revision: u64,
    pub revision: u64,
    /// Lighting/material/topology edits invalidate pixel histories. Pose-only
    /// refits invalidate world caches while motion vectors reproject pixels.
    pub history_revision: u64,
    instances: HashMap<Entity, (AssetId<Mesh>, AssetId<StandardMaterial>, Mat4)>,
    material_membership: Vec<(AssetId<StandardMaterial>, Option<bool>)>,
    retry: bool,
    deformations: HashMap<Entity, Deformation>,
}
#[derive(Clone)]
pub(crate) struct Geometry {
    pub packed: Vec<Vec4>,
    pub node_count: u32,
    materials: Vec<(AssetId<StandardMaterial>, u32)>,
    sources: Vec<(Entity, usize)>,
    pub textures: Vec<Handle<Image>>,
}
#[derive(Clone, Default, PartialEq)]
struct Deformation {
    joints: Vec<Mat4>,
    weights: Vec<f32>,
}
#[derive(Clone)]
struct Triangle {
    vertices: [Vec3; 3],
    normals: [Vec3; 3],
    material: AssetId<StandardMaterial>,
    source: (Entity, usize),
    uvs: [Vec4; 3],
}
impl Triangle {
    fn bounds(&self) -> (Vec3, Vec3) {
        (
            self.vertices[0].min(self.vertices[1]).min(self.vertices[2]),
            self.vertices[0].max(self.vertices[1]).max(self.vertices[2]),
        )
    }
    fn center(&self) -> Vec3 {
        (self.vertices[0] + self.vertices[1] + self.vertices[2]) / 3.0
    }
}

#[allow(clippy::too_many_arguments, clippy::type_complexity)]
pub(crate) fn update_scene(
    settings: Res<GiSettings>,
    mut scene: ResMut<GiScene>,
    mut stats: ResMut<GiStatistics>,
    meshes: Res<Assets<Mesh>>,
    materials: Res<Assets<StandardMaterial>>,
    query: Query<
        (
            Entity,
            &Mesh3d,
            &MeshMaterial3d<StandardMaterial>,
            &GlobalTransform,
            Option<&SkinnedMesh>,
            Option<&MeshMorphWeights>,
        ),
        Without<GiExclude>,
    >,
    lights: Query<(Ref<DirectionalLight>, Ref<GlobalTransform>)>,
    points: Query<(Ref<PointLight>, Ref<GlobalTransform>)>,
    spots: Query<(Ref<SpotLight>, Ref<GlobalTransform>)>,
    events: (
        MessageReader<AssetEvent<Mesh>>,
        MessageReader<AssetEvent<StandardMaterial>>,
        MessageReader<AssetEvent<Image>>,
    ),
    removed: (
        RemovedComponents<DirectionalLight>,
        RemovedComponents<PointLight>,
        RemovedComponents<SpotLight>,
        RemovedComponents<GiExclude>,
    ),
    exclusions: Query<(Has<Mesh3d>, Ref<GiExclude>)>,
    bindposes: Res<Assets<SkinnedMeshInverseBindposes>>,
    joint_transforms: Query<&GlobalTransform>,
    morph_weights: Query<&MorphWeights>,
) {
    let (mut mesh_events, mut material_events, mut image_events) = events;
    let (mut removed_directional, mut removed_points, mut removed_spots, mut removed_exclusions) =
        removed;
    let mesh_changes = mesh_events.read().count() > 0;
    let material_changes = material_events.read().count() > 0;
    let image_changes = image_events.read().fold(false, |changed, event| {
        let id = match event {
            AssetEvent::Added { id }
            | AssetEvent::Modified { id }
            | AssetEvent::Removed { id }
            | AssetEvent::Unused { id }
            | AssetEvent::LoadedWithDependencies { id } => *id,
        };
        changed
            || scene
                .data
                .as_ref()
                .is_some_and(|g| g.textures.iter().any(|h| h.id() == id))
    });
    if image_changes {
        scene.geometry_revision += 1;
    }
    let light_removals = removed_directional.read().count()
        + removed_points.read().count()
        + removed_spots.read().count()
        > 0;
    let exclusion_changes =
        removed_exclusions.read().count() > 0 || exclusions.iter().any(|(_, e)| e.is_added());
    let mut deformations = HashMap::new();
    for (entity, _, _, _, skin, morph) in &query {
        if skin.is_none() && morph.is_none() {
            continue;
        }
        let Some(deformation) =
            resolve_deformation(skin, morph, &bindposes, &joint_transforms, &morph_weights)
        else {
            scene.retry = true;
            stats.error = Some(
                "deformation assets/joints unavailable; previous complete scene retained".into(),
            );
            return;
        };
        deformations.insert(entity, deformation);
    }
    let membership_changed = material_changes
        && scene.material_membership.iter().any(|(id, opaque)| {
            materials.get(*id).map(|m| traceable_alpha(m.alpha_mode)) != *opaque
        });
    let geometry_dirty = scene.data.is_none()
        || scene.retry
        || scene.instances.len() != query.iter().count()
        || mesh_changes
        || membership_changed
        || exclusion_changes
        || deformations != scene.deformations
        || query.iter().any(|(entity, m, a, t, _, _)| {
            scene.instances.get(&entity) != Some(&(m.id(), a.id(), t.to_matrix()))
        });
    let lighting_dirty = geometry_dirty
        || material_changes
        || image_changes
        || light_removals
        || lights.iter().any(|(l, t)| l.is_changed() || t.is_changed())
        || points.iter().any(|(l, t)| l.is_changed() || t.is_changed())
        || spots.iter().any(|(l, t)| l.is_changed() || t.is_changed());
    if !lighting_dirty {
        return;
    }
    let mut history_dirty = mesh_changes || material_changes || image_changes;
    if geometry_dirty {
        let mut triangles = Vec::new();
        let mut excluded = 0;
        scene.retry = false;
        for (entity, mesh, material, transform, _, _) in &query {
            let (Some(mesh), Some(mat)) = (meshes.get(&mesh.0), materials.get(&material.0)) else {
                scene.retry = true;
                continue;
            };
            if mesh.primitive_topology() != PrimitiveTopology::TriangleList
                || !traceable_alpha(mat.alpha_mode)
            {
                excluded += 1;
                continue;
            }
            let Some(VertexAttributeValues::Float32x3(_)) =
                mesh.attribute(Mesh::ATTRIBUTE_POSITION)
            else {
                excluded += 1;
                continue;
            };
            let deformation = deformations.get(&entity);
            let Some((world_positions, world_normals)) =
                deform_vertices(mesh, transform.to_matrix(), deformation)
            else {
                scene.retry = true;
                stats.error =
                    Some("invalid skin/morph vertex data; previous complete scene retained".into());
                return;
            };
            let indices: Vec<usize> = mesh
                .indices()
                .map(|i| i.iter().collect())
                .unwrap_or_else(|| (0..world_positions.len()).collect());
            for (face_index, face) in indices.as_chunks::<3>().0.iter().enumerate() {
                let [Some(a), Some(b), Some(c)] = face.map(|i| world_positions.get(i).copied())
                else {
                    continue;
                };
                let vertices = [a, b, c];
                let geometric = (b - a).cross(c - a).normalize_or_zero();
                if !vertices.iter().all(|p| p.is_finite()) || geometric == Vec3::ZERO {
                    continue;
                }
                let normals = face.map(|i| {
                    world_normals
                        .get(i)
                        .copied()
                        .filter(|n| n.is_finite() && *n != Vec3::ZERO)
                        .unwrap_or(geometric)
                });
                triangles.push(Triangle {
                    vertices,
                    normals,
                    material: material.id(),
                    source: (entity, face_index),
                    uvs: face.map(|i| {
                        let uv = |attribute| match mesh.attribute(attribute) {
                            Some(VertexAttributeValues::Float32x2(uvs)) => {
                                uvs.get(i).copied().unwrap_or_default()
                            }
                            _ => [0.0; 2],
                        };
                        let a = uv(Mesh::ATTRIBUTE_UV_0);
                        let b = uv(Mesh::ATTRIBUTE_UV_1);
                        Vec4::new(a[0], a[1], b[0], b[1])
                    }),
                });
                if triangles.len() > settings.0.max_triangles {
                    break;
                }
            }
            if triangles.len() > settings.0.max_triangles {
                break;
            }
        }
        if triangles.len() > settings.0.max_triangles {
            let error = "triangle capacity exceeded; previous complete scene retained";
            if stats.error.as_deref() != Some(error) {
                warn!("bevy_sol: {error}");
            }
            stats.error = Some(error.into());
            scene.retry = true;
            return;
        }
        let refitted = scene
            .data
            .as_ref()
            .and_then(|old| refit_geometry(old, &triangles));
        let mut geometry = if let Some(refitted) = refitted {
            stats.bvh_refits += 1;
            refitted
        } else {
            history_dirty = true;
            stats.bvh_builds += 1;
            pack_geometry(triangles)
        };
        update_materials(&mut geometry, &materials);
        stats.triangles = geometry.materials.len();
        stats.excluded_meshes = excluded + exclusions.iter().filter(|(mesh, _)| *mesh).count();
        scene.data = Some(Arc::new(geometry));
        scene.geometry_revision += 1;
        scene.shape_revision += 1;
        scene.instances = query
            .iter()
            .map(|(entity, mesh, material, transform, _, _)| {
                (entity, (mesh.id(), material.id(), transform.to_matrix()))
            })
            .collect();
        scene.material_membership = query
            .iter()
            .map(|(_, _, material, _, _, _)| {
                (
                    material.id(),
                    materials
                        .get(&material.0)
                        .map(|m| traceable_alpha(m.alpha_mode)),
                )
            })
            .collect();
        scene.deformations = deformations;
    } else if material_changes && let Some(data) = &mut scene.data {
        update_materials(Arc::make_mut(data), &materials);
        stats.material_updates += 1;
        scene.geometry_revision += 1;
    }
    let mut sources = Vec::new();
    let pi = std::f32::consts::PI;
    for (l, t) in &lights {
        let color = l.color.to_linear().to_vec3() * l.illuminance;
        sources.push([
            (-*t.forward()).extend(0.0),
            Vec4::ZERO,
            Vec4::ZERO,
            color.extend(0.0),
            Vec4::ZERO,
        ]);
    }
    for (l, t) in &points {
        let color = l.color.to_linear().to_vec3() * l.intensity / (4.0 * pi);
        sources.push([
            t.translation().extend(l.range),
            Vec4::ZERO,
            Vec4::ZERO,
            color.extend(1.0),
            Vec4::ZERO,
        ]);
    }
    for (l, t) in &spots {
        // Matches Bevy's lumen-to-candela conversion and squared spot ramp.
        let color = l.color.to_linear().to_vec3() * l.intensity / (4.0 * pi);
        sources.push([
            t.translation().extend(l.range),
            (*t.forward()).extend(l.outer_angle.cos()),
            Vec4::new(l.inner_angle.cos(), 0.0, 0.0, 0.0),
            color.extend(2.0),
            Vec4::ZERO,
        ]);
    }
    sources.retain(|l| l[3].is_finite() && l[3].truncate().max_element() > 0.0 && l[0].is_finite());
    let mut emitter_links = Vec::new();
    if let Some(geometry) = &scene.data {
        for &(_, index) in &geometry.materials {
            let i = index as usize;
            let emission = geometry.packed[i + 7].truncate();
            let emits = emission.is_finite() && emission.max_element() > 0.0;
            let emitter_index = if emits {
                sources.len() as f32 + 1.0
            } else {
                0.0
            };
            if geometry.packed[i].w != emitter_index {
                emitter_links.push((i, emitter_index));
            }
            if emits {
                let a = geometry.packed[i];
                let b = geometry.packed[i + 1];
                let c = geometry.packed[i + 2];
                let area = (b.truncate() - a.truncate())
                    .cross(c.truncate() - a.truncate())
                    .length()
                    * 0.5;
                sources.push([
                    a.truncate().extend(area),
                    b.truncate().extend(index as f32),
                    c,
                    emission.extend(3.0),
                    Vec4::new(0.0, 0.0, 0.0, geometry.packed[i + 6].w),
                ]);
            }
        }
    }
    if !emitter_links.is_empty()
        && let Some(data) = &mut scene.data
    {
        let geometry = Arc::make_mut(data);
        for (index, source) in emitter_links {
            geometry.packed[index].w = source;
        }
        scene.geometry_revision += 1;
    }
    let powers: Vec<f64> = sources
        .iter()
        .map(|l| {
            let c = l[3].truncate();
            let luminance = c.dot(Vec3::new(0.2126, 0.7152, 0.0722)).max(0.0) as f64;
            luminance
                * match l[3].w as u32 {
                    3 => l[0].w as f64 * pi as f64 * if l[4].w != 0.0 { 2.0 } else { 1.0 },
                    1 | 2 => 4.0 * pi as f64,
                    _ => 1.0,
                }
        })
        .collect();
    for (l, alias) in sources.iter_mut().zip(alias_table(&powers)) {
        l[4].x = alias.x;
        l[4].y = alias.y;
        l[4].z = alias.z;
    }
    stats.lights = sources.len();
    let mut packed: Vec<Vec4> = sources.into_iter().flatten().collect();
    if packed.is_empty() {
        packed.push(Vec4::ZERO);
    }
    if history_dirty || packed.as_slice() != scene.lights.as_slice() {
        scene.history_revision += 1;
    }
    scene.lights = Arc::new(packed);
    scene.lighting_revision += 1;
    scene.revision += 1;
    stats.light_updates += 1;
    stats.error = None;
    stats.scene_gpu_bytes = scene
        .data
        .as_ref()
        .map_or(0, |d| d.packed.len() as u64 * 16)
        + scene.lights.len() as u64 * 16;
}

fn update_materials(geometry: &mut Geometry, materials: &Assets<StandardMaterial>) {
    let mut textures = Vec::new();
    for &(id, offset) in &geometry.materials {
        let Some(m) = materials.get(id) else {
            continue;
        };
        let i = offset as usize;
        let diffuse = m.base_color.to_linear().to_vec3()
            * (1.0 - m.metallic)
            * (1.0 - 0.16 * m.reflectance * m.reflectance);
        geometry.packed[i + 6] = diffuse
            .clamp(Vec3::ZERO, Vec3::splat(0.99))
            .extend(f32::from(m.double_sided));
        geometry.packed[i + 7] = m
            .emissive
            .to_vec3()
            .max(Vec3::ZERO)
            .extend(m.perceptual_roughness);
        let mut indices = Vec4::ZERO;
        for (channel, handle) in [
            &m.base_color_texture,
            &m.emissive_texture,
            &m.normal_map_texture,
            &m.metallic_roughness_texture,
        ]
        .into_iter()
        .enumerate()
        {
            if let Some(handle) = handle {
                let index = if let Some(index) = textures
                    .iter()
                    .position(|h: &Handle<Image>| h.id() == handle.id())
                {
                    index
                } else {
                    textures.push(handle.clone());
                    textures.len() - 1
                };
                indices[channel] = (index + 1) as f32;
            }
        }
        geometry.packed[i + 11] = indices;
        let uv1 =
            |channel: &bevy::mesh::UvChannel| u32::from(*channel == bevy::mesh::UvChannel::Uv1);
        let channels = uv1(&m.base_color_channel)
            | (uv1(&m.emissive_channel) << 1)
            | (uv1(&m.normal_map_channel) << 2)
            | (uv1(&m.metallic_roughness_channel) << 3);
        let cutoff = match m.alpha_mode {
            AlphaMode::Mask(cutoff) => cutoff,
            _ => -1.0,
        };
        geometry.packed[i + 12] = Vec4::new(m.metallic, m.reflectance, cutoff, channels as f32);
        geometry.packed[i + 13] = m.base_color.to_linear().to_vec4();
        geometry.packed[i + 14] = Vec4::new(
            m.uv_transform.matrix2.x_axis.x,
            m.uv_transform.matrix2.x_axis.y,
            m.uv_transform.matrix2.y_axis.x,
            m.uv_transform.matrix2.y_axis.y,
        );
        geometry.packed[i + 15] = Vec4::new(
            m.uv_transform.translation.x,
            m.uv_transform.translation.y,
            f32::from(m.flip_normal_map_y),
            0.0,
        );
    }
    geometry.textures = textures;
}
fn traceable_alpha(alpha: AlphaMode) -> bool {
    matches!(alpha, AlphaMode::Opaque | AlphaMode::Mask(_))
}

fn resolve_deformation(
    skin: Option<&SkinnedMesh>,
    morph: Option<&MeshMorphWeights>,
    bindposes: &Assets<SkinnedMeshInverseBindposes>,
    joint_transforms: &Query<&GlobalTransform>,
    morph_weights: &Query<&MorphWeights>,
) -> Option<Deformation> {
    let mut deformation = Deformation::default();
    if let Some(skin) = skin {
        let inverse = bindposes.get(&skin.inverse_bindposes)?;
        if inverse.len() != skin.joints.len() {
            return None;
        }
        for (joint, inverse) in skin.joints.iter().zip(inverse.iter()) {
            let matrix = joint_transforms.get(*joint).ok()?.to_matrix() * *inverse;
            if !matrix.is_finite() {
                return None;
            }
            deformation.joints.push(matrix);
        }
    }
    deformation.weights = match morph {
        Some(MeshMorphWeights::Value { weights }) => weights.clone(),
        Some(MeshMorphWeights::Reference(entity)) => {
            morph_weights.get(*entity).ok()?.weights().to_vec()
        }
        None => Vec::new(),
    };
    deformation
        .weights
        .iter()
        .all(|w| w.is_finite())
        .then_some(deformation)
}

/// Match Bevy's morph-before-skin order and world-space joint matrices.
fn deform_vertices(
    mesh: &Mesh,
    transform: Mat4,
    deformation: Option<&Deformation>,
) -> Option<(Vec<Vec3>, Vec<Vec3>)> {
    let VertexAttributeValues::Float32x3(positions) = mesh.attribute(Mesh::ATTRIBUTE_POSITION)?
    else {
        return None;
    };
    let normals = match mesh.attribute(Mesh::ATTRIBUTE_NORMAL) {
        Some(VertexAttributeValues::Float32x3(normals)) => Some(normals),
        _ => None,
    };
    let morphs = mesh.morph_targets();
    let mut world_positions = Vec::with_capacity(positions.len());
    let mut world_normals = Vec::with_capacity(positions.len());
    for (vertex, position) in positions.iter().enumerate() {
        let mut position = Vec3::from(*position);
        let mut normal = normals
            .and_then(|n| n.get(vertex))
            .map_or(Vec3::ZERO, |n| Vec3::from(*n));
        let mut world = transform;
        if let Some(deformation) = deformation {
            for (target, weight) in deformation.weights.iter().enumerate() {
                if *weight == 0.0 {
                    continue;
                }
                let delta = morphs?.get(target * positions.len() + vertex)?;
                position += delta.position * *weight;
                normal += delta.normal * *weight;
            }
            if !deformation.joints.is_empty() {
                let VertexAttributeValues::Uint16x4(indices) =
                    mesh.attribute(Mesh::ATTRIBUTE_JOINT_INDEX)?
                else {
                    return None;
                };
                let VertexAttributeValues::Float32x4(weights) =
                    mesh.attribute(Mesh::ATTRIBUTE_JOINT_WEIGHT)?
                else {
                    return None;
                };
                let indices = indices.get(vertex)?;
                let weights = weights.get(vertex)?;
                world = Mat4::ZERO;
                for (&index, &weight) in indices.iter().zip(weights) {
                    if !weight.is_finite() {
                        return None;
                    }
                    // Match Bevy's weighted matrix without renormalizing authored weights.
                    world += *deformation.joints.get(usize::from(index))? * weight;
                }
            }
        }
        world_positions.push(world.transform_point3(position));
        world_normals
            .push((Mat3::from_mat4(world).inverse().transpose() * normal).normalize_or_zero());
    }
    Some((world_positions, world_normals))
}

/// Preserve leaf ordering and refit bounds when topology and membership match.
/// Readers retain their old Arc; no in-flight scene is modified.
fn refit_geometry(old: &Geometry, triangles: &[Triangle]) -> Option<Geometry> {
    if old.materials.len() != triangles.len() || old.node_count == 0 {
        return None;
    }
    let by_source: HashMap<_, _> = triangles.iter().map(|t| (t.source, t)).collect();
    let mut geometry = old.clone();
    for (source, &(material, offset)) in old.sources.iter().zip(&old.materials) {
        let triangle = by_source.get(source)?;
        if triangle.material != material {
            return None;
        }
        let offset = offset as usize;
        for i in 0..3 {
            geometry.packed[offset + i] =
                triangle.vertices[i].extend(geometry.packed[offset + i].w);
            geometry.packed[offset + 3 + i] =
                triangle.normals[i].extend(geometry.packed[offset + 3 + i].w);
            geometry.packed[offset + 8 + i] = triangle.uvs[i];
        }
    }
    for node in (0..old.node_count as usize).rev() {
        let offset = node * 2;
        let (lo, hi) = if geometry.packed[offset].w >= 0.0 {
            let triangle = geometry.packed[offset].w as usize;
            let a = geometry.packed[triangle].truncate();
            let b = geometry.packed[triangle + 1].truncate();
            let c = geometry.packed[triangle + 2].truncate();
            (a.min(b).min(c), a.max(b).max(c))
        } else {
            let left = (node + 1) * 2;
            let right = geometry.packed[left + 1].w as usize * 2;
            (
                geometry.packed[left]
                    .truncate()
                    .min(geometry.packed[right].truncate()),
                geometry.packed[left + 1]
                    .truncate()
                    .max(geometry.packed[right + 1].truncate()),
            )
        };
        geometry.packed[offset] = lo.extend(geometry.packed[offset].w);
        geometry.packed[offset + 1] = hi.extend(geometry.packed[offset + 1].w);
    }
    Some(geometry)
}
fn pack_geometry(mut triangles: Vec<Triangle>) -> Geometry {
    let mut packed = Vec::new();
    if !triangles.is_empty() {
        build_bvh(&mut triangles, 0, &mut packed);
    }
    let node_count = packed.len() as u32 / 2;
    let base = packed.len() as f32;
    for node in packed.as_chunks_mut::<2>().0 {
        if node[0].w >= 0.0 {
            node[0].w = base + node[0].w * TRIANGLE_WORDS as f32;
        }
    }
    let mut materials = Vec::new();
    let mut sources = Vec::new();
    let mut material_tokens = HashMap::new();
    for t in triangles {
        sources.push(t.source);
        materials.push((t.material, packed.len() as u32));
        let next_token = material_tokens.len() as f32 + 1.0;
        let token = *material_tokens.entry(t.material).or_insert(next_token);
        packed.extend(t.vertices.map(|v| v.extend(0.0)));
        packed.extend(t.normals.map(|n| n.extend(token)));
        packed.extend([Vec4::ZERO, Vec4::ZERO]);
        packed.extend(t.uvs);
        packed.extend([Vec4::ZERO; 5]);
    }
    if packed.is_empty() {
        packed.push(Vec4::ZERO);
    }
    Geometry {
        packed,
        node_count,
        materials,
        sources,
        textures: Vec::new(),
    }
}
// Depth-first stackless traversal; hi.w is the first node after this subtree.
fn build_bvh(triangles: &mut [Triangle], start: usize, nodes: &mut Vec<Vec4>) {
    let index = nodes.len();
    let (lo, hi) = triangles.iter().map(Triangle::bounds).fold(
        (Vec3::splat(f32::INFINITY), Vec3::splat(f32::NEG_INFINITY)),
        |(a, b), (c, d)| (a.min(c), b.max(d)),
    );
    nodes.extend([lo.extend(-1.0), hi.extend(0.0)]);
    if triangles.len() == 1 {
        nodes[index].w = start as f32;
    } else {
        let extent = hi - lo;
        let axis = if extent.x >= extent.y && extent.x >= extent.z {
            0
        } else if extent.y >= extent.z {
            1
        } else {
            2
        };
        let mid = triangles.len() / 2;
        triangles.select_nth_unstable_by(mid, |a, b| a.center()[axis].total_cmp(&b.center()[axis]));
        let (left, right) = triangles.split_at_mut(mid);
        build_bvh(left, start, nodes);
        build_bvh(right, start + mid, nodes);
    }
    nodes[index + 1].w = (nodes.len() / 2) as f32;
}

/// Walker alias sampling. Returns threshold, alternate index, and marginal PMF.
fn alias_table(weights: &[f64]) -> Vec<Vec3> {
    if weights.is_empty() {
        return Vec::new();
    }
    let max = weights
        .iter()
        .copied()
        .filter(|w| w.is_finite())
        .fold(0.0_f64, f64::max);
    let normalized: Vec<_> = weights
        .iter()
        .map(|w| {
            if max > 0.0 && w.is_finite() {
                w.max(0.0) / max
            } else {
                0.0
            }
        })
        .collect();
    let sum: f64 = normalized.iter().sum();
    let n = weights.len();
    let pmf: Vec<_> = normalized
        .iter()
        .map(|w| if sum > 0.0 { w / sum } else { 1.0 / n as f64 })
        .collect();
    let mut scaled: Vec<_> = pmf.iter().map(|w| w * n as f64).collect();
    let (mut small, mut large) = (Vec::new(), Vec::new());
    for (i, w) in scaled.iter().enumerate() {
        if *w < 1.0 {
            small.push(i);
        } else {
            large.push(i);
        }
    }
    let mut table: Vec<_> = pmf
        .iter()
        .enumerate()
        .map(|(i, w)| Vec3::new(1.0, i as f32, *w as f32))
        .collect();
    while !small.is_empty() && !large.is_empty() {
        let s = small.pop().expect("nonempty small list");
        let l = large.pop().expect("nonempty large list");
        table[s].x = scaled[s] as f32;
        table[s].y = l as f32;
        scaled[l] += scaled[s] - 1.0;
        if scaled[l] < 1.0 {
            small.push(l);
        } else {
            large.push(l);
        }
    }
    table
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn morph_then_skin_matches_world_positions_and_inverse_transpose_normals() {
        let mut mesh = Mesh::new(
            PrimitiveTopology::TriangleList,
            bevy::asset::RenderAssetUsages::MAIN_WORLD,
        );
        mesh.insert_attribute(Mesh::ATTRIBUTE_POSITION, vec![[1.0, 0.0, 0.0]]);
        mesh.insert_attribute(Mesh::ATTRIBUTE_NORMAL, vec![[1.0, 1.0, 0.0]]);
        mesh.insert_attribute(
            Mesh::ATTRIBUTE_JOINT_INDEX,
            VertexAttributeValues::Uint16x4(vec![[0, 0, 0, 0]]),
        );
        mesh.insert_attribute(Mesh::ATTRIBUTE_JOINT_WEIGHT, vec![[1.0, 0.0, 0.0, 0.0]]);
        mesh.set_morph_targets(vec![bevy::mesh::morph::MorphAttributes::new(
            Vec3::Y,
            Vec3::Z,
            Vec3::ZERO,
        )]);
        let world = Mat4::from_scale_rotation_translation(
            Vec3::new(2.0, 1.0, 0.5),
            Quat::from_rotation_z(0.7),
            Vec3::new(3.0, 2.0, 1.0),
        );
        let deformation = Deformation {
            joints: vec![world],
            weights: vec![0.5],
        };
        let (positions, normals) = deform_vertices(
            &mesh,
            Mat4::from_translation(Vec3::splat(100.0)),
            Some(&deformation),
        )
        .unwrap();
        assert!(positions[0].distance(world.transform_point3(Vec3::new(1.0, 0.5, 0.0))) < 1e-5);
        let expected =
            (Mat3::from_mat4(world).inverse().transpose() * Vec3::new(1.0, 1.0, 0.5)).normalize();
        assert!(normals[0].distance(expected) < 1e-5);
        assert!(
            deform_vertices(
                &mesh,
                Mat4::IDENTITY,
                Some(&Deformation {
                    joints: vec![world],
                    weights: vec![1.0, 1.0]
                })
            )
            .is_none()
        );
    }
    #[test]
    fn joint_motion_updates_geometry_and_refits_without_changing_leaf_ids() {
        let (mut app, entity, _) = scene_app();
        let mesh = app.world().get::<Mesh3d>(entity).unwrap().0.clone();
        let vertices = app
            .world()
            .resource::<Assets<Mesh>>()
            .get(&mesh)
            .unwrap()
            .count_vertices();
        {
            let mut meshes = app.world_mut().resource_mut::<Assets<Mesh>>();
            let mut mesh = meshes.get_mut(&mesh).unwrap();
            mesh.insert_attribute(
                Mesh::ATTRIBUTE_JOINT_INDEX,
                VertexAttributeValues::Uint16x4(vec![[0, 0, 0, 0]; vertices]),
            );
            mesh.insert_attribute(
                Mesh::ATTRIBUTE_JOINT_WEIGHT,
                vec![[1.0, 0.0, 0.0, 0.0]; vertices],
            );
        }
        let joint = app.world_mut().spawn(GlobalTransform::IDENTITY).id();
        let inverse = app
            .world_mut()
            .resource_mut::<Assets<SkinnedMeshInverseBindposes>>()
            .add(vec![Mat4::IDENTITY]);
        app.world_mut().entity_mut(entity).insert(SkinnedMesh {
            joints: vec![joint],
            inverse_bindposes: inverse,
        });
        app.update();
        let before = app
            .world()
            .resource::<GiScene>()
            .data
            .as_ref()
            .unwrap()
            .clone();
        app.world_mut()
            .entity_mut(joint)
            .insert(GlobalTransform::from_translation(Vec3::new(2.0, 1.0, 0.0)));
        app.update();
        let after = app.world().resource::<GiScene>().data.as_ref().unwrap();
        assert_eq!(before.sources, after.sources);
        assert_eq!(before.node_count, after.node_count);
        assert_eq!(before.materials, after.materials);
        assert!(
            after.packed[0]
                .truncate()
                .distance(before.packed[0].truncate() + Vec3::new(2.0, 1.0, 0.0))
                < 1e-5
        );
        for (&(_, offset), &(_, old_offset)) in after.materials.iter().zip(&before.materials) {
            assert_eq!(offset, old_offset);
            assert!(
                after.packed[offset as usize].truncate().distance(
                    before.packed[old_offset as usize].truncate() + Vec3::new(2.0, 1.0, 0.0)
                ) < 1e-5
            );
        }
        assert_eq!(app.world().resource::<GiStatistics>().bvh_builds, 1);
        assert_eq!(app.world().resource::<GiStatistics>().bvh_refits, 2);
    }
    fn scene_app() -> (App, Entity, Handle<StandardMaterial>) {
        let mut app = App::new();
        app.insert_resource(GiSettings(crate::HybridGiConfig::default()))
            .init_resource::<GiScene>()
            .init_resource::<GiStatistics>()
            .init_resource::<Assets<Mesh>>()
            .init_resource::<Assets<StandardMaterial>>()
            .init_resource::<Assets<SkinnedMeshInverseBindposes>>()
            .add_message::<AssetEvent<Mesh>>()
            .add_message::<AssetEvent<StandardMaterial>>()
            .add_message::<AssetEvent<Image>>()
            .add_systems(Update, update_scene);
        let mesh = app
            .world_mut()
            .resource_mut::<Assets<Mesh>>()
            .add(Cuboid::default());
        let material = app
            .world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .add(StandardMaterial::default());
        let entity = app
            .world_mut()
            .spawn((
                Mesh3d(mesh),
                MeshMaterial3d(material.clone()),
                GlobalTransform::IDENTITY,
            ))
            .id();
        app.update();
        (app, entity, material)
    }
    #[test]
    fn shading_edits_preserve_geometry_and_membership_edits_rebuild_it() {
        let (mut app, mesh, material) = scene_app();
        assert_eq!(app.world().resource::<GiStatistics>().triangles, 12);
        let point = app
            .world_mut()
            .spawn((PointLight::default(), GlobalTransform::IDENTITY))
            .id();
        app.update();
        app.world_mut()
            .get_mut::<PointLight>(point)
            .unwrap()
            .intensity *= 2.0;
        app.update();
        assert_eq!(app.world().resource::<GiStatistics>().bvh_builds, 1);
        app.world_mut().despawn(point);
        app.update();
        assert_eq!(app.world().resource::<GiStatistics>().lights, 0);
        app.world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .get_mut(&material)
            .unwrap()
            .emissive = LinearRgba::WHITE;
        app.world_mut()
            .write_message(AssetEvent::Modified { id: material.id() });
        // Bevy's material extraction may also mark the handle component changed.
        app.world_mut()
            .get_mut::<MeshMaterial3d<StandardMaterial>>(mesh)
            .unwrap()
            .set_changed();
        app.update();
        assert_eq!(app.world().resource::<GiStatistics>().bvh_builds, 1);
        assert_eq!(app.world().resource::<GiStatistics>().material_updates, 1);
        assert_eq!(app.world().resource::<GiStatistics>().lights, 12);
        app.world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .get_mut(&material)
            .unwrap()
            .alpha_mode = AlphaMode::Blend;
        app.world_mut()
            .write_message(AssetEvent::Modified { id: material.id() });
        app.update();
        assert_eq!(app.world().resource::<GiStatistics>().triangles, 0);
        assert_eq!(app.world().resource::<GiStatistics>().lights, 0);
        app.world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .get_mut(&material)
            .unwrap()
            .alpha_mode = AlphaMode::Opaque;
        app.world_mut()
            .write_message(AssetEvent::Modified { id: material.id() });
        app.update();
        assert_eq!(app.world().resource::<GiStatistics>().triangles, 12);
        app.world_mut().entity_mut(mesh).insert(GiExclude);
        app.update();
        assert_eq!(app.world().resource::<GiStatistics>().triangles, 0);
        app.world_mut().entity_mut(mesh).remove::<GiExclude>();
        app.update();
        assert_eq!(app.world().resource::<GiStatistics>().triangles, 12);
    }
    #[test]
    fn triangle_limit_retains_a_complete_scene_and_recovers() {
        let (mut app, entity, _) = scene_app();
        let revision = app.world().resource::<GiScene>().revision;
        app.world_mut().resource_mut::<GiSettings>().0.max_triangles = 1;
        *app.world_mut().get_mut::<GlobalTransform>(entity).unwrap() =
            GlobalTransform::from_translation(Vec3::X);
        app.update();
        assert_eq!(app.world().resource::<GiScene>().revision, revision);
        assert_eq!(app.world().resource::<GiStatistics>().triangles, 12);
        assert!(app.world().resource::<GiStatistics>().error.is_some());
        app.world_mut().resource_mut::<GiSettings>().0.max_triangles = 12;
        app.update();
        assert!(app.world().resource::<GiScene>().revision > revision);
        assert!(app.world().resource::<GiStatistics>().error.is_none());
    }
    #[test]
    fn pose_refits_preserve_pixel_history_but_material_and_light_edits_reset_it() {
        let (mut app, entity, material) = scene_app();
        let history = app.world().resource::<GiScene>().history_revision;
        let revision = app.world().resource::<GiScene>().revision;
        *app.world_mut().get_mut::<GlobalTransform>(entity).unwrap() =
            GlobalTransform::from_translation(Vec3::new(0.01, 0.0, 0.0));
        app.update();
        assert!(app.world().resource::<GiScene>().revision > revision);
        assert_eq!(app.world().resource::<GiScene>().history_revision, history);
        assert_eq!(app.world().resource::<GiStatistics>().bvh_refits, 1);
        app.world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .get_mut(&material)
            .unwrap()
            .base_color = Color::BLACK;
        app.world_mut()
            .write_message(AssetEvent::Modified { id: material.id() });
        app.update();
        let updated_history = app.world().resource::<GiScene>().history_revision;
        assert!(updated_history > history);
        app.world_mut()
            .spawn((PointLight::default(), GlobalTransform::IDENTITY));
        app.update();
        assert!(app.world().resource::<GiScene>().history_revision > updated_history);
    }
    #[test]
    fn emitter_links_follow_light_reordering_without_rebuilding_bvh() {
        let (mut app, _, material) = scene_app();
        app.world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .get_mut(&material)
            .unwrap()
            .emissive = LinearRgba::WHITE;
        app.world_mut()
            .write_message(AssetEvent::Modified { id: material.id() });
        let light = app
            .world_mut()
            .spawn((
                PointLight {
                    intensity: f32::NAN,
                    ..default()
                },
                GlobalTransform::IDENTITY,
            ))
            .id();
        app.update();
        let check = |app: &App, count: usize| {
            let scene = app.world().resource::<GiScene>();
            assert_eq!(scene.lights.len() / 5, count);
            for &(_, offset) in &scene.data.as_ref().unwrap().materials {
                let vertex = scene.data.as_ref().unwrap().packed[offset as usize];
                let source = vertex.w as usize - 1;
                assert_eq!(scene.lights[source * 5 + 3].w, 3.0);
                assert_eq!(scene.lights[source * 5].truncate(), vertex.truncate());
            }
            assert_eq!(app.world().resource::<GiStatistics>().bvh_builds, 1);
        };
        check(&app, 12);
        app.world_mut()
            .get_mut::<PointLight>(light)
            .unwrap()
            .intensity = 100.0;
        app.update();
        check(&app, 13);
        let data = app.world().resource::<GiScene>().data.clone().unwrap();
        app.world_mut()
            .get_mut::<PointLight>(light)
            .unwrap()
            .intensity = 101.0;
        app.update();
        check(&app, 13);
        assert!(
            Arc::ptr_eq(
                &data,
                app.world().resource::<GiScene>().data.as_ref().unwrap()
            ),
            "intensity edits must not clone geometry"
        );
        app.world_mut().despawn(light);
        app.update();
        check(&app, 12);
    }
    #[test]
    fn weighted_sampler_preserves_the_distribution() {
        for weights in [
            vec![1.0, 3.0, 6.0],
            vec![0.0, 0.0],
            vec![f64::MAX, f64::MAX],
            vec![0.0, 7.0],
        ] {
            let table = alias_table(&weights);
            let mut probability = vec![0.0; table.len()];
            for (i, entry) in table.iter().enumerate() {
                probability[i] += entry.x / table.len() as f32;
                probability[entry.y as usize] += (1.0 - entry.x) / table.len() as f32;
            }
            for (p, t) in probability.iter().zip(&table) {
                assert!((p - t.z).abs() < 1e-6);
            }
        }
    }
    #[test]
    fn bvh_leaf_offsets_and_escape_indices_are_valid() {
        let mut materials = Assets::<StandardMaterial>::default();
        let material = materials.add(StandardMaterial::default());
        let t = Triangle {
            vertices: [Vec3::ZERO, Vec3::X, Vec3::Y],
            normals: [Vec3::Z; 3],
            material: material.id(),
            source: (Entity::PLACEHOLDER, 0),
            uvs: [Vec4::ZERO; 3],
        };
        let geometry = pack_geometry(vec![t.clone(), t]);
        assert_eq!(geometry.node_count, 3);
        assert_eq!(geometry.packed[1].w, 3.0);
        assert_eq!(geometry.packed[2].w, 6.0);
        assert_eq!(geometry.packed[4].w, 22.0);
        assert_eq!(pack_geometry(Vec::new()).node_count, 0);
    }
}
