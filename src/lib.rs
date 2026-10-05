#![recursion_limit = "256"]
//! GI-1.2-inspired hybrid lighting for Bevy 0.19.1.
//! Rust manages screen probes, a world radiance cache, and reconstructed reflections.
//! Slang/SPIR-V uses hardware ray queries or a software BVH; Bevy retains direct lighting.
mod environment;
mod gpu;
mod hash_grid;
mod light_grid;
mod radiance_cascades;
mod random;
mod raytracing;
mod reflections;
mod restir;
mod scene;
use bevy::{
    camera::Hdr,
    core_pipeline::prepass::{DeferredPrepass, DepthPrepass, MotionVectorPrepass},
    pbr::DefaultOpaqueRendererMethod,
    prelude::*,
    render::{
        extract_component::{ExtractComponent, ExtractComponentPlugin},
        extract_resource::{ExtractResource, ExtractResourcePlugin},
    },
};
pub use environment::{EnvironmentSampling, GiEnvironmentMap};
pub use hash_grid::HashGridCacheConfig;
pub use light_grid::{LightGridConfig, LightGridMerge};
pub use radiance_cascades::RadianceCascadesConfig;
pub use random::RandomConfig;
pub use reflections::{ReflectionConfig, ReflectionDenoiser};
pub use restir::WorldSpaceRestirConfig;
pub use scene::GiStatistics;

/// Diffuse temporal reconstruction and disocclusion filtering.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DiffuseDenoiser {
    /// GI-1.2 adaptive history and horizontal/vertical disocclusion blur.
    #[default]
    AdaptiveSeparable,
    /// Variance-clipped history followed by configurable à-trous passes.
    TemporalVarianceAtrous,
}

/// Probe refresh density. Retained/reprojected probes stay available every frame.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ProbeSamplingMode {
    FullSpp,
    #[default]
    QuarterSpp,
    SixteenthSpp,
}

/// Conversion from directional probe radiance to diffuse SH.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ProbeProjection {
    /// GI-1.2's filtered atlas-cell projection, including its source normalization.
    #[default]
    SourceAtlas,
    /// PDF-compensated ray integral, useful for physical energy comparisons.
    CompensatedRayIntegral,
}

/// Exclude a mesh from secondary-ray tracing. It can still receive GI.
#[derive(Component)]
pub struct GiExclude;

/// Traversal backend. Hardware requires `WgpuFeatures::EXPERIMENTAL_RAY_QUERY`
/// in the application's `WgpuSettings` before the renderer initializes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum GiRayBackend {
    /// Use hardware when the device enabled ray queries, otherwise software.
    #[default]
    Auto,
    Software,
    /// Refuse to initialize GI if the device did not enable ray queries.
    Hardware,
}

/// Enable GI on an HDR camera with `Msaa::Off`. Prepasses are inserted automatically.
#[derive(Component, Clone, Copy, ExtractComponent)]
#[require(Hdr, DepthPrepass, DeferredPrepass, MotionVectorPrepass)]
pub struct HybridGi {
    /// Finite, nonnegative multiplier for diffuse and specular indirect lighting.
    pub intensity: f32,
    /// Glossy/mirror rays plus probe reuse for rough reflections.
    pub reflections: bool,
    /// Increase on camera cuts to discard histories and cache contents.
    pub reset: u64,
}
impl Default for HybridGi {
    fn default() -> Self {
        Self {
            intensity: 1.0,
            reflections: true,
            reset: 0,
        }
    }
}

/// Configure allocation and sampling before adding the plugin.
#[derive(Clone, Debug)]
pub struct HybridGiConfig {
    /// Default transport reconstruction. None selects the legacy GI-1.2 reference.
    /// ReSTIR dispatches and allocations are disabled whenever cascades are enabled.
    pub radiance_cascades: Option<RadianceCascadesConfig>,
    pub probe_projection: ProbeProjection,
    pub random: RandomConfig,
    /// Slang compiler invoked once during shader initialization. Uses SLANGC/PATH by default.
    pub slang_compiler: bevy_slang::SlangCompiler,
    pub ray_backend: GiRayBackend,
    /// Directional tiled radiance cache. Defaults match Capsaicin GI-1.2.
    pub hash_grid: HashGridCacheConfig,
    pub reflection: ReflectionConfig,
    pub light_grid: LightGridConfig,
    pub diffuse_denoiser: DiffuseDenoiser,
    pub probe_sampling: ProbeSamplingMode,
    /// Primary probe tile width: 4, 8, or 16 pixels.
    pub probe_spacing: u32,
    /// 4 or 8; squared directions per refreshed probe. Default: 64, as in GI-1.2.
    pub probe_directions: u32,
    /// Reserve a second surface probe in compensated mode. SourceAtlas uses one.
    pub adaptive_probes: bool,
    /// Power of two, 1024..=262144 entries per camera.
    pub cache_capacity: u32,
    /// Minimum world-cache cell width, in world units.
    pub min_cell_size: f32,
    /// Cell width grows with camera distance, quantized to powers of two.
    pub cell_size_scale: f32,
    /// Unused entries expire after this many rendered GI frames.
    pub cache_lifetime: u32,
    /// Rays beyond this distance return the environment radiance.
    pub max_ray_distance: f32,
    /// Surface offset and minimum intersection distance, in world units.
    pub ray_bias: f32,
    /// Constant scene-linear radiance added to `GiEnvironmentMap` in all directions.
    pub sky_radiance: Vec3,
    /// Explicit extra transport bounce between world-cache cells.
    pub multibounce: bool,
    /// GI-1.2 direct probe/glossy emission and environment contributions, and probe feedback.
    /// SourceAtlas only; does not disable cached indirect lighting or Bevy direct lighting.
    pub source_direct_lighting: bool,
    /// Source final-composition override: diffuse albedo 0.3 and specular F0 zero.
    /// Secondary material evaluation is unchanged. Ignored in compensated mode.
    pub source_disable_albedo_textures: bool,
    /// Force opaque GI closest-hit and shadow traversal in SourceAtlas.
    /// Blend emission is scaled by base alpha when disabled; otherwise hits are stochastic.
    /// Bevy's primary raster alpha testing is unchanged. Ignored in compensated mode.
    pub source_disable_alpha_testing: bool,
    /// 1..=8 weighted next-event samples per receiver pixel and uncached shading.
    pub direct_samples: u32,
    /// Reference-mode only: temporal/spatial reuse of streamed-grid light reservoirs.
    /// Fresh eight-candidate RIS is always used. Default false, as in GI-1.2.
    /// Compensated probe projection and uncached shading retain next-event sampling.
    pub reservoir_resampling: bool,
    /// Independent world-space table used when `reservoir_resampling` is enabled.
    pub world_space_restir: WorldSpaceRestirConfig,
    /// Reuse validated previous HDR lighting at visible secondary hits.
    /// As in Capsaicin, enabled only when `multibounce` is false. Default: false.
    pub temporal_feedback: bool,
    /// Temporal sample-count cap for probes/caches and the variance denoiser.
    pub history_samples: u32,
    /// Variance-denoiser à-trous passes, 0..=4. Adaptive mode uses two separable passes.
    pub denoise_iterations: u32,
    /// Low reflection roughness threshold. Above it, reuse directional probes.
    pub rough_reflection_threshold: f32,
    /// Reject oversized geometry instead of truncating it.
    pub max_triangles: usize,
    /// Reject oversized per-camera allocations.
    pub max_view_pixels: u32,
}
impl Default for HybridGiConfig {
    fn default() -> Self {
        Self {
            radiance_cascades: Some(RadianceCascadesConfig::default()),
            probe_projection: ProbeProjection::default(),
            random: RandomConfig::default(),
            slang_compiler: bevy_slang::SlangCompiler::default(),
            ray_backend: GiRayBackend::Auto,
            hash_grid: HashGridCacheConfig::default(),
            reflection: ReflectionConfig::default(),
            light_grid: LightGridConfig::default(),
            diffuse_denoiser: DiffuseDenoiser::default(),
            probe_sampling: ProbeSamplingMode::default(),
            probe_spacing: 8,
            probe_directions: 8,
            adaptive_probes: true,
            cache_capacity: 32768,
            min_cell_size: 0.1,
            cell_size_scale: 0.01,
            cache_lifetime: 50,
            max_ray_distance: 1000.0,
            ray_bias: 0.002,
            sky_radiance: Vec3::ZERO,
            multibounce: true,
            source_direct_lighting: true,
            source_disable_albedo_textures: false,
            source_disable_alpha_testing: false,
            direct_samples: 4,
            reservoir_resampling: false,
            world_space_restir: WorldSpaceRestirConfig::default(),
            temporal_feedback: false,
            history_samples: 32,
            denoise_iterations: 3,
            rough_reflection_threshold: 0.2,
            max_triangles: 250_000,
            max_view_pixels: 8_294_400,
        }
    }
}
impl HybridGiConfig {
    pub fn validate(&self) -> Result<(), &'static str> {
        if let Some(cascades) = &self.radiance_cascades {
            cascades.validate(self.max_ray_distance)?;
        }
        self.hash_grid.validate()?;
        self.reflection.validate(self.rough_reflection_threshold)?;
        self.light_grid.validate()?;
        self.world_space_restir.validate()?;
        if ![4, 8, 16].contains(&self.probe_spacing) || ![4, 8].contains(&self.probe_directions) {
            return Err("probe_spacing must be 4/8/16 and probe_directions 4/8");
        }
        if !self.cache_capacity.is_power_of_two()
            || !(1024..=262144).contains(&self.cache_capacity)
            || !(1..=10000).contains(&self.cache_lifetime)
            || !(1..=8).contains(&self.direct_samples)
            || !(1..=128).contains(&self.history_samples)
            || self.denoise_iterations > 4
            || !(1..=1_000_000).contains(&self.max_triangles)
            || !(1..=33_177_600).contains(&self.max_view_pixels)
        {
            return Err("invalid cache, sampling, or scene capacity");
        }
        if !self.min_cell_size.is_finite()
            || self.min_cell_size <= 0.0
            || !self.cell_size_scale.is_finite()
            || self.cell_size_scale <= 0.0
            || !self.max_ray_distance.is_finite()
            || self.max_ray_distance <= 0.0
            || !self.ray_bias.is_finite()
            || self.ray_bias <= 0.0
            || self.ray_bias >= self.min_cell_size * 0.25
            || self.max_ray_distance <= self.ray_bias * 2.0
            || !self.sky_radiance.is_finite()
            || self.sky_radiance.min_element() < 0.0
            || !self.rough_reflection_threshold.is_finite()
            || !(0.1..=1.0).contains(&self.rough_reflection_threshold)
        {
            return Err("invalid cell scale, ray bounds, or environment radiance");
        }
        Ok(())
    }
}

/// Installs hybrid GI and selects Bevy's deferred opaque material rendering.
#[derive(Default)]
pub struct HybridGiPlugin {
    pub config: HybridGiConfig,
}
#[derive(Resource, Clone, ExtractResource)]
pub(crate) struct GiSettings(pub HybridGiConfig);
impl Plugin for HybridGiPlugin {
    fn build(&self, app: &mut App) {
        self.config.validate().expect("Invalid HybridGiConfig");
        app.insert_resource(GiSettings(self.config.clone()))
            .insert_resource(DefaultOpaqueRendererMethod::deferred())
            .init_resource::<GiStatistics>()
            .init_resource::<scene::GiScene>()
            .init_resource::<GiEnvironmentMap>()
            .init_resource::<environment::EnvironmentRevision>()
            .add_plugins((
                ExtractResourcePlugin::<GiSettings>::default(),
                ExtractResourcePlugin::<scene::GiScene>::default(),
                ExtractResourcePlugin::<GiEnvironmentMap>::default(),
                ExtractResourcePlugin::<environment::EnvironmentRevision>::default(),
                ExtractComponentPlugin::<HybridGi>::default(),
            ))
            .add_systems(
                PostUpdate,
                scene::update_scene.after(TransformSystems::Propagate),
            )
            .add_systems(PostUpdate, environment::track_environment)
            .add_systems(
                PostUpdate,
                ensure_deferred_cameras.before(bevy::core_pipeline::core_3d::check_msaa),
            );
    }
    fn finish(&self, app: &mut App) {
        gpu::install(app);
    }
}

// Bevy chooses opaque material methods globally. Plain cameras must also have
// the deferred prepasses so they continue to render when GI is disabled there.
#[allow(clippy::type_complexity)]
fn ensure_deferred_cameras(
    mut commands: Commands,
    cameras: Query<
        Entity,
        (
            With<Camera3d>,
            Or<(Without<DepthPrepass>, Without<DeferredPrepass>)>,
        ),
    >,
) {
    for entity in &cameras {
        commands
            .entity(entity)
            .insert((DepthPrepass, DeferredPrepass));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_invalid_and_unbounded_settings() {
        let c = HybridGiConfig::default();
        assert!(c.validate().is_ok());
        for invalid in [
            HybridGiConfig {
                cache_capacity: 3000,
                ..c.clone()
            },
            HybridGiConfig {
                ray_bias: f32::NAN,
                ..c.clone()
            },
            HybridGiConfig {
                min_cell_size: 0.0,
                ..c.clone()
            },
            HybridGiConfig {
                sky_radiance: Vec3::splat(-1.0),
                ..c.clone()
            },
            HybridGiConfig {
                probe_directions: 16,
                ..c.clone()
            },
            HybridGiConfig {
                history_samples: 0,
                ..c.clone()
            },
            HybridGiConfig {
                denoise_iterations: 5,
                ..c.clone()
            },
            HybridGiConfig {
                rough_reflection_threshold: f32::NAN,
                ..c.clone()
            },
            HybridGiConfig {
                rough_reflection_threshold: 0.0,
                ..c
            },
        ] {
            assert!(invalid.validate().is_err());
        }
    }
}
