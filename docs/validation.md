# Validation — bevy_sol 0.2

Validated on **2026-10-03**, Bevy 0.19.1, Windows, NVIDIA GeForce RTX 4070 Laptop
GPU, Vulkan, wgpu 29.0.4, Slang 2026.19 and the custom `bevy_slang` crate.
AMD reference commit: `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
This records measured behavior, not completed upstream parity.

## Commands and results

| Command / configuration | Result |
|---|---|
| `cargo test --all-targets` | Unit tests passed; example compiled; compiler/GPU fixtures ignored by default |
| `cargo test --lib -- --include-ignored` | All eight Slang tracing/texture/direction specializations compiled; entry points, storage strides and uniform offsets matched |
| `cargo test --lib moving_receiver -- --ignored`, with `BEVY_SOL_TEST_MOTION=rigid/skin/morph` | GPU motion vectors and diffuse history preservation passed in software and hardware; hardware rigid motion also passed with variance diffuse filtering |
| `cargo test --tests -- --ignored --nocapture --test-threads=1` | Software GPU transport/deformation/material regression and energy check passed |
| Same command with `BEVY_SOL_TEST_HARDWARE=1` | Vulkan hardware ray-query regression and energy check passed |
| Software and hardware with `BEVY_SOL_TEST_PROBE_DIRECTIONS=8` | Default 64-direction quarter refresh, material/radiance mixture, merged persistent history, cooperative resolve and four-probe gathering passed |
| Software furnace/transport with `BEVY_SOL_TEST_DIFFUSE_MODE=atrous`, reflection mode `split` and full-resolution reflections | Variance diffuse mode and full-resolution separable reflections passed |
| Hardware furnace/transport with `BEVY_SOL_TEST_PROBE_DIRECTIONS=8`, probe mode `sixteenth`, reflection mode `none`, full resolution, `BEVY_SOL_TEST_FEEDBACK=1` and `BEVY_SOL_TEST_RESAMPLING=1` | 64-direction packed probes, sixteenth refresh, raw reflections, feedback with multibounce disabled, and temporal/spatial reservoir reuse passed |
| `cargo test --test brdf_lut --test hash_grid --test light_grid -- --include-ignored` | Quantized LUT, pinned hash/cache equations, streamed grid estimators/options and parallel build passed |
| `cargo test --test environment -- --ignored --nocapture` | Cube orientation and 262,144 stratified samples per configuration passed for all three direction distributions, two rotations, and constant/textured/black/single-bright-face maps; sampled/evaluated PDF agreement and independent hemisphere energy checked |
| `cargo test --lib environment_loading -- --ignored` | Loading, in-place uploads with unchanged texture-view identity, rotation, removal and invalid-image/config fallback reset rendered histories |
| Latest environment-loading fixture | Also passed render-world main-pass override resize/removal with viewport origin (4,2), matching GI/composition dimensions and a single history reset |
| `cargo test --test restir -- --ignored --nocapture` | Source PCG/xxHash CPU comparisons, concurrent insertion ordinals, two-slot collision exhaustion, scans crossing 128 entries, compaction, previous-frame lookup and both frame-swap directions; packed formats, source M normalization/cap, normal rejection and zero-W histories checked |
| Native atlas/cone checks in the ReSTIR fixture | 16 and 64 directions, including a partial workgroup: independent CPU reference for all nine signed atlas SH coefficients at three normal orientations; source empty-bin backup and area-light cone LOD checked |
| Latest software transport, 16 directions, source atlas, reservoir reuse enabled | Emitter/point/spot/directional means 0.3696/0.2771/0.2061/0.1213; dark phases, geometry/material/texture/deformation invalidation and mirror (1.0) passed |
| Latest hardware transport, 64 directions, source atlas, reservoir reuse enabled | Means 0.5182/0.3877/0.3020/0.1591; same regression phases and mirror (1.0) passed with the source table capacity and history regions swapped in place |
| Furnace with `BEVY_SOL_TEST_CUBEMAP=1`, directions `8`, software and hardware | Unit raw RGBA32Float cubemap scaled by 0.75 plus constant sky 0.25 preserved Lambertian/GGX energy |
| `cargo test --manifest-path ../bevy_slang/Cargo.toml --lib -- --include-ignored` | Six tests passed, including real compiler bundle/include/entry-point/error checks |
| `cargo run --example cornell -- --headless --software` | Colored-wall assertions and capture passed |
| `cargo run --example cornell -- --headless --hardware` | Colored-wall assertions and capture passed |
| `cargo clippy --all-targets -- -D warnings` | Passed |
| `cargo fmt --check` | Passed |

PowerShell hardware selection:

```powershell
$env:BEVY_SOL_TEST_HARDWARE='1'
cargo test --tests -- --ignored --nocapture --test-threads=1
Remove-Item Env:BEVY_SOL_TEST_HARDWARE
```

Unit checks cover Walker alias probabilities, BVH offsets/escape indices,
capacity rejection/recovery, membership/shading edits, emitter links, light-only
updates, joint motion/refitting, morph-before-skin transforms and normals,
configuration bounds, Slang compilation, and Rust/SPIR-V layouts. Software, hardware,
textured software and textured hardware shaders are validated at both 16 and 64
probe directions; allocated probe struct sizes match those specializations.

`tests/hash_grid.rs` checks fixed PCG/xxHash values, half packing, atomic
accumulation, all tile mip levels, temporal caps and 50-frame decay. It also checks
per-channel denoiser NaN recovery, stable/vignetted history confidence, abrupt
lighting changes, the source equal-area hemi-octahedral mapping and inverse,
orientation frames, packed radiance/far-distance sentinels, and probe-mask mip
lookup across empty cells and odd-sized borders. Mapping moments use 65,536
stratified directions and independent analytic hemisphere integrals.
Persistent cache checks cover exclusive owners/shared restoration, free-before-eviction
ordering, leaving/returning to a view, stable compaction across a 128-lane boundary
and a partial workgroup, and all refresh modes across odd/one-dimensional borders.
Native sampling checks integrate the compensated material/radiance mixture over
131,072 draws for each normal/grazing view, dielectric/metal, and roughness combination;
the reference for constant incident radiance is one. They check CDF normalization,
monotonicity, independent f64 Fresnel layer probabilities, and averaging two cached
directional histories without a selected previous probe.
Signed SH half-packing checks preserve negative coefficient bits; the shader
layout checks enforce the smaller probe/cache strides in both direction variants.
`tests/brdf_lut.rs` catches loss of half quantization and sparse descriptor
relocation errors. It also compares 4,096 GPU blue-noise samples with the original
tables on the CPU, across tile borders, 256 dimensions and frame wrapping. A
pinned checksum validates the lossless table bytes.
`tests/light_grid.rs` checks zero/one/7/12/65/8,193 lights,
all merge modes, local resampling, centroid/volume weights, octahedral culling,
volume overlap, serial/parallel builders, sparse/empty reservoir slots, flat bounds, and an independent
normalized matte BRDF target. Non-random merge estimates reproduce the known
directional-light sum in every sample; random merge means must stay within 2%.

## Lighting and geometry regression

`tests/gpu.rs` renders a 128x128 receiver with ambient disabled. A central 32x32
readback excludes the visible source. Emission, exclusion, camera GI removal/
readdition and source deletion must turn the receiver signal on/off. Material and
light edits preserve BVH topology. Off-screen point/spot/directional lighting
reaches the receiver through a reflector, exercising bounced transport.

The new phases verify that a black emissive texture removes lighting, removing
that texture restores it, moving the emitter with a joint or a morph removes
lighting, and restoring the pose restores it. Pose edits must increase refit
counts without rebuilding CPU topology. An alpha-masked blocker transmits light
when transparent and occludes it after its alpha factor changes. Both software
intersections and hardware candidate acceptance execute these checks.

Red/green coplanar receivers retain material edges under subpixel camera motion
and explicit history reset. A purely metallic receiver isolates reflection
routing; disabling reflections makes it black and enabling them produces a
signal. Offset viewport resizing, temporal jitter, orthographic reflection views,
and a plain camera without GI are also checked.

The current default traversal runs recorded normalized sRGB-channel means of 0.4997 for
off-screen emission, approximately 0.3557 for bounced point lighting, 0.2726 for spot lighting,
0.1711 for directional lighting, and 1.0000 for the saturated mirror. Dark phases
must fall below 0.001 after readback advances. These are transport smoke-test
signals, not linear-radiance accuracy measurements. Random/cache ordering can
change them. The mirror phase proves contribution, not reconstruction accuracy.

Bevy emitted no GPU validation errors. Offscreen shadow-LOD-origin and readback
channel-close warnings occurred; neither failed the regressions.

`src/motion_tests.rs` reads the actual Bevy RG16 motion-vector texture and the
diffuse history count on a 32x32 uniform-environment receiver. After 100 rendered
GI frames, twelve small translations must keep more than 20 history samples,
produce positive horizontal velocity, and preserve lighting within 0.05. Rigid,
single-joint skinned, and morph-target receivers pass. Pose-only changes must use
cache reset flag 2 while preserving pixel history; material/light/topology changes
use full reset flag 1. A scene unit test checks this invalidation distinction.
These simple motions do not establish stability for arbitrary animated scenes.

The native hash fixture also compares motion reprojection with independent CPU
projections for perspective/orthographic cameras, camera/object translation, and
projection jitter. The reflection fixture checks source quaternion rotation and
blue-noise hash-cell jitter, including the near-antipodal normal branch.
The probe refresh fixture checks the global Halton phase and radical inverses,
including the 255/256-frame wrap and partial viewport borders. Fixed triangle
samples also check source barycentric ordering and light-point interpolation.
The same fixture checks source shadow-preserving directional hysteresis and
probe interpolation plane/depth/normal weights, including zero-weight rejection.

## Cubemap lighting

`tests/environment.rs` uploads six raw 4x4 float faces and their arithmetic-average
2x2/1x1 mip levels. Its independent CPU reference uses Vulkan cube addressing and
a 512x512 uniform-hemisphere quadrature. All 24 combinations of four maps,
three sampling modes and two rotations pass. A fourth map isolates one bright
face with five zero-energy faces, covering leading empty CDF intervals. The
textured maps include bright patterns and black texels. The tested mean errors are below 0.1%;
black maps return finite zero lighting. Sampled and evaluated importance PDFs
agree within 0.4% for every tested sample. The assertions allow 1.5% integration
error to account for finite quadrature and samples.

The full-render furnace also runs with a rotated, unfilterable RGBA32Float cube.
After the source probe jitter/hysteresis changes, software and hardware measured Lambertian
0.418382 against 0.416667, and GGX 0.416016/0.408447/0.261623 against
0.416423/0.409126/0.261222 at roughness 0.1/0.35/0.75. The rendered-history fixture
checks asset revisions even when Bevy updates a GPU texture in place. These checks
do not establish arbitrary-scene accuracy or upstream frame equivalence;
environment RIS integration and cone filtering remain unmapped.

## Independent energy reference

`tests/furnace.rs` renders a large plane in constant scene-linear unit sky, with
no ambient/analytic/emissive lights, orthographic normal incidence, tone mapping
disabled and floating-point RGBA32 readback. The diffuse reference is Lambertian
reflectance 0.5. Glossy references numerically integrate the GGX distribution,
Smith masking and Schlick Fresnel in f64 over 65,536 hemisphere intervals; this
reference does not use the shader's VNDF sampler. Metallic F0 is 0.5.

The expected values include Bevy's `Exposure { ev100: 0.0 }` multiplier. Default
64-direction quarter refresh, persistent merged histories, material-aware sampling,
half-packed SH, source adaptive denoising, and blue-noise reflections are enabled:

| Surface | Expected | Software mean / error | Hardware mean / error |
|---|---:|---:|---:|
| Lambertian 0.5 | 0.416667 | 0.418382 / +0.41% | 0.418382 / +0.41% |
| GGX roughness 0.1 | 0.416423 | 0.416016 / -0.10% | 0.416016 / -0.10% |
| GGX roughness 0.35 | 0.409126 | 0.408447 / -0.17% | 0.405273 / -0.94% |
| GGX roughness 0.75 | 0.261222 | 0.261623 / +0.15% | 0.261623 / +0.15% |

The furnace explicitly selects `ProbeProjection::CompensatedRayIntegral` to
compare physical integrals. Default `SourceAtlas` uses AMD's different atlas
normalization, checked directly against the source SH equations in the native
fixture. Furnace columns retain prior software and latest hardware measurements.
The tolerance is 5%, accounting for deferred G-buffer quantization and Monte
Carlo reconstruction. Diffuse variation over the measured patch was
0.417725–0.418945 in the current cubemap runs. Cache/atomic ordering and Monte Carlo history
can change individual measurements. The default diffuse filter uses source adaptive confidence
and separable reconstruction. In the retained variance-filter mode, the rough
glossy test previously measured 0.298198 and failed because neighborhood-only
history clipping suppressed zero-valued GGX samples; retaining raw-sample
variance fixed that measured bias. Both diffuse modes still pass the furnace.
This check covers a uniform environment at normal incidence;
it does not establish general scene lighting accuracy, grazing-angle accuracy,
textured-environment accuracy or dynamic-scene stability.

## Cornell captures and cost

Current captures: [software](../screenshots/cornell-software.png) and
[hardware](../screenshots/cornell-hardware.png). Both pass red/green wall assertions.
The hardware capture has red `[122,24,19,255]`, green `[30,103,25,255]`;
software has red `[121,24,19,255]`, green `[31,104,26,255]`.
The example waits for 90 actual GI dispatch measurements before requesting a
capture. It renders 640x640, 96 triangles, 12,800 reserved probes, 6,400 persistent
cached probes, 64 directions per refreshed probe with quarter refresh, 32,768 auxiliary cache entries, 16,384 directional hash buckets
with 16 tiles each, four receiver next-event samples, the streamed light grid,
multibounce, cached-neighbor history merging, material-aware sampling with a
shared-memory CDF, a probe-mask mip hierarchy, two directional probe-filter passes,
half-resolution reflections with four ratio-filter passes, two adaptive diffuse
filter passes, source blue-noise reflection sampling and FXAA. Reservoir reuse defaults off. There are no
ambient or analytic lights. One CPU BVH build occurs; packed scene data is 31,648
bytes. Per-view allocation is approximately 1.186 GB, excluding Bevy targets and
hardware acceleration structures.

Prior baseline shader diagnostic histories, before the source atlas/ReSTIR changes, measured 9.641 ms and 9.601 ms
whole-GI GPU spans in hardware; software measured 6.340 ms. Earlier in this turn,
captures measured 4.666 ms hardware and 6.387 ms software. Concurrent GPU activity
was subsequently observed at 99% utilization and 86–88°C after the GI processes
had exited. These runs cannot establish a controlled before/after performance
comparison or attribute the timing difference to the code. The repeated 9.601 ms
hardware history is broken down below:

| Hardware stage | GPU ms |
|---|---:|
| Cache reservations | 0.010 |
| History merge / sampling CDF | 0.304 |
| Probe tracing | 0.658 |
| Extra cache-bounce tracing | 0.064 |
| Streamed light-grid build | 0.190 |
| Reservoir generation | 0.170 |
| Direct cache update | 0.055 |
| Probe resolve / SH | 0.528 |
| Directional probe filtering X / Y | 0.295 / 0.265 |
| SH coefficient filtering | 0.172 |
| Pixel gather / MIS / reflections | 0.872 |
| Adaptive temporal reconstruction | 0.390 |
| Diffuse filtering X / Y | 0.082 / 0.077 |
| Whole GI, including copies/composition | 9.601 |

CPU encoding averaged 0.095 ms for repeated hardware and 0.075 ms for software. It excludes scene extraction, deformation,
BVH/BLAS/TLAS construction and GPU execution. These are short development-profile
observations, not repeated controlled trials, percentiles or power-normalized
benchmarks. Diagnostic stage averages need not sum to the span. There is no AMD
GI-1.2 executable measured with matching inputs here; no comparative ranking can
be inferred.

## Historical captures

The retained [cornell-before.png](../screenshots/cornell-before.png),
[cornell.png](../screenshots/cornell.png) and
[quality-metrics.json](../screenshots/quality-metrics.json) predate the new hardware,
materials, SH and reservoir work. They remain historical evidence for the earlier
filtering changes. Their recorded wall-noise RMS changed from 1.656 to 0.906 on red,
1.175 to 0.684 on green, and 0.630 to 0.313 on the back wall. The captures also
changed warm-up, sample count, filters and FXAA, so these are not isolated
algorithm comparisons. Lower variation alone does not establish accuracy or
preserved detail. `tools/compare_captures.py` computes that diagnostic.

Animation geometry correctness now has rendered regression coverage. Stable
animated lighting, large-world scaling, non-Vulkan backends, complete GI-1.2
algorithm parity and equivalent/better image quality remain unestablished.
See [gi12-parity.md](gi12-parity.md) for the outstanding implementation work.
