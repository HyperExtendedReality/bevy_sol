# bevy_sol

**GI-1.2-inspired hybrid global illumination for Bevy 0.19.1.** Rust prepares the
scene, manages GPU resources, and integrates the renderer. WGSL uses Vulkan
hardware ray queries or a software triangle BVH, combines screen probes with a world radiance cache, and reconstructs
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

`HybridGiConfig` configures allocation and sampling when the plugin is added.
`HybridGi` controls intensity and reflections per camera. Increase `reset` on
camera cuts. Perspective/orthographic projections and Bevy's temporal jitter are
handled. Resize/viewport changes allocate fresh history; scene, material,
and light edits reset histories automatically. Remove `HybridGi` to disable GI
and release that camera's resources. Add `GiExclude` to exclude a mesh from
secondary-ray geometry and emissive sampling while letting it receive GI.

The library leaves window/platform setup to the application. A compute-capable
backend with seven storage buffers, four storage textures, and ten sampled
textures per stage is required.
Vulkan hardware and software traversal are tested here. `GiRayBackend::Auto`
selects hardware when the device has enabled `EXPERIMENTAL_RAY_QUERY`, otherwise
software. `Hardware` requires that feature in the application's `WgpuSettings`;
`Software` forces BVH traversal. Wgpu 29's ray queries currently require Vulkan.
Software traversal on DX12, Metal, and WebGPU remains unverified.
WebGL2 is unsupported. GPU limits are checked before scene/view allocation.
Secondary material textures additionally require texture binding arrays and
nonuniform indexing. A scene exceeding the 64-image capacity, or a device lacking
these features for a textured scene, disables GI with a diagnostic.

## Implemented

- Jittered screen probes with an adaptive second surface per tile, validated
  reprojection, and screen-continuity checks at visible geometry breaks.
- Radiance-guided uniform-hemisphere sampling with mixture-PDF compensation;
  hit-distance-based parallax redistribution of directional history.
- Nine-coefficient spherical-harmonic projection and cosine-convolved diffuse
  gathering; allocations match the configured 16 or 64 directional samples.
- GPU compaction and indirect dispatch for active probes, first-hit cache cells,
  and touched cache cells.
- Camera-distance-scaled world hash cells with expiry, full descriptor/material
  checks, normal and surface-plane rejection, and uncached shading on misses.
- Separate direct/indirect estimators and explicit extra diffuse-bounce rays,
  using current direct light at secondary cells without recursive cache feedback.
- Shadowed emissive triangles, directional, point, and spot lights, sampled from
  a weighted alias table with the correct marginal selection probability.
- Eight-candidate world-space light RIS with previous-frame temporal and spatial
  reservoir reuse, and one shadow ray for the selected light sample.
- Optional validated previous-HDR feedback at secondary hits, compensated for
  camera exposure. As upstream, feedback is disabled when multibounce is enabled.
- Per-pixel emissive next-event sampling with diffuse/GGX evaluation; power-heuristic
  MIS between area samples and cosine emitter rays reduces near-field fireflies.
  Emitter hits are excluded from probe transport to avoid counting them twice.
- GGX visible-normal glossy/mirror rays at one sample per 2x2 pixel block;
  directional probe reuse replaces rays for rough surfaces, with a smooth transition.
- Spatial probe filtering, demodulated irradiance reconstruction, validated bilinear
  temporal history, luminance moments, variance-envelope history clipping, and
  up to four edge-aware à-trous passes. Reflection filters also check the material.
- Depth/normal-aware diffuse gathering;
  disoccluded surfaces without suitable probes get a traced fallback sample.
- Secondary base-color/emissive/metallic-roughness textures, UV channels and
  transforms, normal maps, and alpha-mask candidate rejection in both backends.
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
Eleven unit checks cover
sampling probabilities, BVH structure, scene edits/capacity recovery, configuration,
WGSL variants, deformation/refitting, emitter-source remapping, and Rust/shader memory layout.
The separate floating-point furnace regression compares diffuse and glossy energy
against analytical Lambertian lighting and an independent numerical GGX integral.
See [validation](docs/validation.md), including the saved before/after captures.

Add `bevy::render::diagnostic::RenderDiagnosticsPlugin` to collect
`render/bevy_sol/elapsed_gpu` and per-stage children, in milliseconds. GPU timestamps
are available only when the backend/device supports them. CPU encoding time does
not include scene extraction, BVH building, or GPU execution.

## Quality, cost, and limitations

Start with 8-pixel probe spacing, 4x4 directions, and 32,768 world cells. Reducing
spacing from 8 to 4 quadruples probe work/storage. Increasing directions from 4
to 8 quadruples probe-ray work/storage. `reflections = false` removes reflection
rays; `multibounce = false` removes the extra cache-bounce rays. More direct samples
reduce light-sampling noise at the cost of more shadow rays. Smaller cells reduce
spatial bias but increase cache pressure and uncached work.

Defaults use four next-event light samples and three spatial-filter passes.
`denoise_iterations` accepts 0..=4; zero preserves temporal reconstruction only.
`rough_reflection_threshold` controls when probe reuse starts (default 0.7).
`adaptive_probes = false` releases the second layer's allocation. The ray capacity
is fixed; compacted dispatches trace only valid slots. Extra surfaces beyond two
still use the per-pixel fallback. The Cornell example also enables FXAA.

At 640x640, defaults reserve 12,800 probes and 204,800 probe-ray records. GPU storage
is approximately 103 MB per camera, excluding Bevy's own targets and scene buffers.
A 1080p view uses approximately 488 MB; 4K can exceed storage-buffer limits. Use coarser
probe spacing or a lower render resolution if allocation is rejected.

Meshes must retain `RenderAssetUsages::MAIN_WORLD` for CPU BVH extraction.
Secondary material texture sampling uses LOD zero; normal-map frames are derived
from triangle UV gradients. Alpha blending, transmission, custom material shading,
and the complete StandardMaterial layer stack are not reproduced. Secondary
scattering is diffuse; nested glossy/mirror paths,
caustics, and unlimited bounces are not implemented. Probe/world-cache interpolation
is approximate and can blur detail or leak light despite surface rejection.
Reflection reconstruction can blur sharp reflections and retain temporal artifacts.
`MainPassResolutionOverride` is unsupported; those views skip GI composition.

The remaining upstream differences include tiled/mipmapped hash caches, persistent
probe relocation/LRU allocation, the streamed light grid and exact visibility
reservoir stages, and Capsaicin's reflection hit reprojection, ratio estimator,
and complete denoising stack. [The parity inventory](docs/gi12-parity.md) tracks
these explicitly; this remains an incomplete port.
Moving geometry performs synchronous CPU deformation/refitting, rebuilds the
hardware scene, and resets the whole camera history. Correct animated geometry is
tested; stable temporal lighting and large animated scenes still need further work.
The historical Radiance
Cascades assessment remains in [techniques.md](docs/techniques.md).

Version 0.2 replaces `RadianceCascadesPlugin`/`RadianceCascadesConfig` and the fixed
`IrradianceVolume` API with `HybridGiPlugin`/`HybridGiConfig` and camera `HybridGi`.
There is no fixed GI domain or cascade interval to configure.
