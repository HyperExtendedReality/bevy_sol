# bevy_sol

**GI-1.2-inspired hybrid global illumination for Bevy 0.19.1.** Rust prepares the
scene, manages GPU resources, and integrates the renderer. The custom `bevy_slang`
crate compiles embedded Slang modules to native SPIR-V. Shaders use Vulkan
hardware ray queries or a software triangle BVH, combine screen probes with a world radiance cache, and reconstruct
diffuse lighting and glossy reflections. Bevy continues to render direct lights.

This is an experimental adaptation of the architecture in AMD's
[Capsaicin GI-1.2 source](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/tree/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/render_techniques/gi1).
It is not a complete port or a claim of equivalent performance or image quality.
The [source mapping and architecture](docs/hybrid-gi.md) explain the differences.
AMD's license is preserved in [third-party notices](THIRD_PARTY_NOTICES.md).

## Use

```rust
use bevy::prelude::*;
use bevy_sol::{HybridGi, HybridGiPlugin};

fn main() {
    App::new()
        .add_plugins(DefaultPlugins)
        .add_plugins(HybridGiPlugin::default())
        .add_systems(Startup, setup)
        .run();
}

fn setup(mut commands: Commands) {
    commands.spawn((
        Camera3d::default(),
        HybridGi::default(),
        Msaa::Off,
        Transform::from_xyz(0.0, 2.0, 6.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    // Spawn StandardMaterial meshes and lights.
}
```

Add the plugin after Bevy's rendering/PBR plugins. It selects the default deferred
opaque renderer; `HybridGi` requires HDR, depth, and deferred prepasses. It also
installs deferred prepasses on plain 3D cameras to preserve their direct rendering.
Use `Msaa::Off` and the default RGBA16F HDR target. Explicitly forward-rendered or
custom materials without Bevy's deferred G-buffer cannot receive this GI.

Install `slangc` on `PATH`, set `SLANGC`, or configure
`HybridGiConfig::slang_compiler` with a compiler path. Shaders compile once during
plugin initialization, with only the selected tracing/material specialization.
The dependency currently uses the sibling `../bevy_slang` checkout.

`HybridGiConfig` configures allocation and sampling when the plugin is added.
`HybridGi` controls intensity and reflections per camera. Increase `reset` on
camera cuts. Perspective/orthographic projections and Bevy's temporal jitter are
handled. Resize/viewport changes allocate fresh history; material, topology,
and light edits reset histories automatically. Pose-only refits clear world caches
while Bevy's motion-vector prepass reprojects compatible diffuse and primary
reflection pixel histories, including skinned and morphed receivers. Remove `HybridGi` to disable GI
and release that camera's resources. Add `GiExclude` to exclude a mesh from
secondary-ray geometry and emissive sampling while letting it receive GI.

The library leaves window/platform setup to the application. Vulkan with
`WgpuFeatures::PASSTHROUGH_SHADERS`, thirteen storage buffers, four storage textures,
and twelve sampled textures per stage is required. Bevy's default functionality
settings enable available adapter features; custom `WgpuSettings` must enable
passthrough explicitly. These trusted application shaders bypass Naga's importer;
Slang validates emitted SPIR-V. Sparse bindings are relocated by `bevy_slang` to
wgpu's Vulkan layout indices.
Vulkan hardware and software traversal are tested here. `GiRayBackend::Auto`
selects hardware when the device has enabled `EXPERIMENTAL_RAY_QUERY`, otherwise
software. `Hardware` requires that feature in the application's `WgpuSettings`;
`Software` forces BVH traversal. Wgpu 29's ray queries currently require Vulkan.
This native SPIR-V pipeline currently targets Vulkan for both traversal modes.
DX12, Metal, WebGPU and WebGL2 are unsupported. GPU limits are checked before
scene/view allocation.
Secondary material textures additionally require texture binding arrays and
nonuniform indexing. A scene exceeding the 64-image capacity, or a device lacking
these features for a textured scene, disables GI with a diagnostic.

Insert `GiEnvironmentMap` to light the scene with a raw HDR cubemap. Its image
must have six square layers and a `Cube` texture view, as used by `Skybox`.
`intensity` scales scene-linear radiance and `rotation` turns the map into world
space. Constant `sky_radiance` is added to it. Map loading, replacement, in-place
reloads, rotation and intensity changes reset lighting histories automatically.
The sampling choices are `UniformHemisphere`, `CosineHemisphere` (default), and
`Importance`. Importance sampling uses AMD's face CDF and mip descent and requires
a power-of-two map with a complete arithmetic-average mip chain down to 1x1;
other maps use cosine sampling. Use the original radiance image, rather than
Bevy's preconvolved `EnvironmentMapLight` images. GI does not draw the skybox.

## Implemented

- Source single-layer screen-probe atlas with whole-tile best-seed reprojection,
  fixed-budget empty/override patching and separate fresh/active compaction.
  Compensated mode optionally reserves a second surface per tile.
- Persistent cached probes with projected candidates, shared restoration,
  exclusive update ownership, parallel reservations and stable LRU/MRU compaction.
- Full/quarter/sixteenth Halton spawn regions, disocclusion query redistribution
  and retained compatible seeds, including pose-only scene updates.
- Equal-area hemi-octahedral directions with material-weighted bounded GGX and
  radiance guidance and a shared-memory CDF; source atlas sampling uses the full
  Fresnel probability, with mixture-PDF compensation reserved for compensated mode.
  Half-packed RGB/hit distance and integer fixed-point directional history reuse.
- Probe-mask mip hierarchy and horizontal/vertical directional filtering with
  reconnected endpoint-angle and depth rejection, feeding rough reflection reuse.
- Source shadow-preserving directional hysteresis, blue-noise interpolation
  jitter and low-confidence relaxed interpolation when every probe weight fails.
- Raw cubemap lighting for misses and a virtual environment light integrated into
  source streamed RIS/ReSTIR; oriented grid weights, ray-cone LOD, rotation and
  mip-hierarchy importance sampling.
- Source atlas-cell SH projection after directional filtering, with signed half
  packing, source normalization and energy-spread backup for untraced cells.
  `ProbeProjection::CompensatedRayIntegral` retains PDF-compensated projection
  for physical reference comparisons. Allocations support 16 or 64 directions.
- GPU compaction and indirect dispatch for active probes, first-hit cache cells,
  and touched cache cells.
- Directional hash-cache tiles with PCG/xxHash descriptors, distance/FOV-based
  sizing, 8x8/4x4/2x2/1x1 mips, half-float storage, atomic accumulation and expiry;
  compensated mode adds an auxiliary cache with material/normal/plane checks and
  miss fallback. SourceAtlas uses only the directional cache for cached lighting.
- Separate direct/indirect estimators and extra cosine-sampled bounce rays with
  source full matte BRDF/PDF evaluation and discarded-ray survival compensation,
  using current direct light at secondary cells without recursive cache feedback.
- Shadowed emissive triangles, directional, point, and spot lights, sampled from
  a weighted alias table with the correct marginal selection probability.
- Streamed light-grid bounds from traced hits, volume-weighted reservoirs,
  random/with-replacement/without-replacement merging, optional local resampling,
  octahedral directional cells, light/cell volume overlap, parallel many-light
  building, normalized-BRDF eight-candidate RIS, and one selected shadow ray. Temporal/spatial reservoir
  reuse uses an independent world-space hash table, GPU count scan/compaction,
  source packed normals/materials/reservoirs, four stochastically strided previous
  candidates, bilateral rejection, M cap and selected shadow-ray invalidation.
  Frame regions swap without copying reservoir history. Reuse defaults off.
- Source area-light cone LOD for fresh RIS, shifted reservoir targets and selected
  visibility samples, including transformed UV footprints and texture alpha.
- Optional validated previous-HDR feedback at secondary hits, compensated for
  camera exposure. As upstream, feedback is disabled when multibounce is enabled.
- Source atlas projection includes emitter hits. The compensated projection
  instead uses per-pixel emissive next-event sampling and power-heuristic MIS,
  excluding those hits from its SH integral to avoid counting them twice.
- Bounded GGX visible-normal glossy/mirror rays at half or full resolution, a
  half-quantized 32x32 BRDF LUT, original AMD blue-noise tables with source temporal
  animation for tracing/filter jitter, endpoint/virtual-hit reprojection, firefly cleanup,
  and separable or à-trous ratio reconstruction. Directional probes replace rays
  for rough surfaces, with a smooth transition.
  `ReflectionConfig` selects independent half/full-resolution split radii and
  firefly controls. Unprefixed radius/threshold fields configure half resolution;
  `full_resolution_*` fields configure full resolution, with source marking
  radii 3/2 and cleanup radii 2/1 respectively.
  `source_direct_lighting` maps GI-1.2's sky/emissive injection and probe-feedback
  option in SourceAtlas, while retaining reflected indirect cache lighting.
- Spatial probe filtering and demodulated irradiance reconstruction. The default
  diffuse denoiser uses GI-1.2's nine-tap reprojection, smoothed color delta,
  adaptive/vignetted history cap and two separable disocclusion-blur passes.
  A variance-clipped temporal/à-trous mode remains selectable.
- Depth/normal-aware diffuse gathering;
  disoccluded surfaces without suitable probes get a traced fallback sample.
- Secondary base-color/emissive/metallic-roughness textures, UV channels and
  transforms, and alpha-mask candidate rejection in both backends. SourceAtlas
  preserves sign-corrected cofactor-transformed vertex normals until face-oriented
  normalized interpolation at ray hits, as in GI-1.2;
  compensated mode additionally evaluates secondary normal maps.
- Skinning and morph deformation, with morphing before skinning. Stable topology
  refits the CPU BVH and preserves triangle identifiers; membership changes rebuild it.
- Separate light and geometry uploads. Material shading edits preserve BVH and
  hardware acceleration structures; geometry changes rebuild hardware structures.
- Independent histories and caches per camera; optional Bevy GPU pass timings.

## Run and validate

```text
cargo run --example cornell
cargo run --example cornell -- --headless
cargo run --example cornell -- --headless --software
cargo run --example cornell -- --headless --hardware
cargo test --all-targets
cargo test --lib -- --include-ignored
cargo test --tests -- --ignored --nocapture --test-threads=1
cargo clippy --all-targets -- -D warnings
```

The Cornell room has no ambient or analytic lights. An emissive ceiling panel
lights it through GI. WASD moves the camera, arrows move the panel, Space toggles
emission, and Escape exits. Headless mode checks the colored walls and saves
`screenshots/cornell.png` without opening a window.
Explicit backend flags save `cornell-software.png` and `cornell-hardware.png`.
On PowerShell, set `$env:BEVY_SOL_TEST_HARDWARE='1'` before the ignored tests to
exercise hardware traversal, then remove that environment variable to test software.

The real GPU regression checks off-screen emission, material edits, exclusion,
camera disable/re-enable, source deletion, bounced analytic lighting, mirror-only
reflections, textured emission, alpha masks, skinned/morphed source motion,
and a viewport resize with an offset. Coplanar red/green boundaries
must survive filtering, subpixel camera motion, and explicit camera cuts.
Unit checks cover
sampling probabilities, BVH structure, scene edits/capacity recovery, configuration,
deformation/refitting, emitter-source remapping, and configuration. An ignored
compiler check validates all eight Slang specializations and Rust/SPIR-V layouts.
Native GPU fixtures check hash equations, LUT quantization, and light-grid weights.
The separate floating-point furnace regression compares diffuse and glossy energy
against analytical Lambertian lighting and an independent numerical GGX integral.
See [validation](docs/validation.md), including the saved before/after captures.

Add `bevy::render::diagnostic::RenderDiagnosticsPlugin` to collect
`render/bevy_sol/elapsed_gpu` and per-stage children, in milliseconds. GPU timestamps
are available only when the backend/device supports them. CPU encoding time does
not include scene extraction, BVH building, or GPU execution.

## Quality, cost, and limitations

Defaults use 8-pixel probe spacing, 8x8 directions, quarter-rate refresh, and
32,768 world cells. `ProbeSamplingMode` selects full, quarter, or sixteenth refresh;
invalid history traces fresh immediately. Reducing
spacing from 8 to 4 quadruples probe work/storage. Increasing directions from 4
to 8 quadruples probe-ray work/storage. `reflections = false` removes reflection
rays; `multibounce = false` removes the extra cache-bounce rays. More direct samples
reduce light-sampling noise at the cost of more shadow rays. Smaller cells reduce
spatial bias but increase cache pressure and uncached work.

Defaults use four next-event light samples and adaptive separable diffuse denoising.
`DiffuseDenoiser::TemporalVarianceAtrous` selects the variance filter;
`denoise_iterations` then accepts 0..=4, with zero preserving temporal reconstruction only.
`rough_reflection_threshold` controls when probe reuse starts (default 0.2);
`reflection.high_roughness_threshold` sets the end of the transition (default 0.6).
Reflection reconstruction has its own configuration and four à-trous passes by default.
SourceAtlas allocates one probe per tile. In compensated mode,
`adaptive_probes = false` releases the optional second layer. Ray capacity is fixed;
compacted dispatches trace only valid slots. Unrepresented surfaces use the
per-pixel fallback in compensated mode; SourceAtlas returns black with the
source confidence hint when no probe exists. The Cornell example also enables FXAA.

At 640x640, defaults reserve 6,400 probes, 6,400 cached probes, and 409,600 probe-ray
records. Enabling world-space reservoir reuse adds approximately 170 MB at that resolution.
SourceAtlas also uploads an MT19937 random seed table, with a componentwise
1920x1080 minimum (approximately 8.3 MB shared across cameras). The renderer
retains its table when resolution shrinks and regenerates it on growth or
source-compatible option changes. `random` defaults to
deterministic generation with seed 5489; disabling `random.deterministic` uses
an entropy-seeded table.
Source visibility lists and visibility-to-shadow mappings reserve another 16
bytes per probe ray (approximately 6.6 MB at 640x640 with default spacing).
`WorldSpaceRestirConfig` controls its table capacity and distance/FOV footprint.
Bevy's render-world `MainPassResolutionOverride` is supported; GI allocations,
jitter, composition, feedback and cache footprints use the main-pass dimensions.
The source-sized directional hash cache alone reserves approximately 899 MB per camera,
in addition to probe, reflection, history and scene buffers. 4K can exceed storage-buffer limits.
Reduce `hash_grid.num_buckets` for smaller caches, use coarser probe spacing, or
lower the render resolution if allocation is rejected.

Meshes must retain `RenderAssetUsages::MAIN_WORLD` for CPU BVH extraction.
Secondary material texture sampling uses LOD zero; compensated normal-map frames
are derived from triangle UV gradients. Alpha blending, transmission, custom material shading,
and the complete StandardMaterial layer stack are not reproduced. Secondary
scattering is diffuse; nested glossy/mirror paths,
caustics, and unlimited bounces are not implemented. Probe/world-cache interpolation
is approximate and can blur detail or leak light despite surface rejection.
Reflection reconstruction can blur sharp reflections and retain temporal artifacts.
Render-world `MainPassResolutionOverride` resizes GI composition and histories.

The remaining upstream differences include source renderer/visibility representation,
packed cache representation,
and exact animated-surface history handling.
Implemented hash-cache, grid and reflection stages still have differences in
representation, sampling and scheduling. [The parity inventory](docs/gi12-parity.md) tracks
these explicitly; this remains an incomplete port.
Moving geometry performs synchronous CPU deformation/refitting, rebuilds the
hardware scene, and retains SourceAtlas world/persistent-probe caches across
pose-only updates. Compensated mode resets those caches; motion vectors preserve
compatible pixel and screen-probe histories in both modes. Correct animated geometry is
tested; stable temporal lighting and large animated scenes still need further work.
The historical Radiance
Cascades assessment remains in [techniques.md](docs/techniques.md).

Version 0.2 replaces `RadianceCascadesPlugin`/`RadianceCascadesConfig` and the fixed
`IrradianceVolume` API with `HybridGiPlugin`/`HybridGiConfig` and camera `HybridGi`.
There is no fixed GI domain or cascade interval to configure.
