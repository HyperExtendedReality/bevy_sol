# Validation — bevy_sol 0.2

Validated on **2026-10-03**, Bevy 0.19.1, Windows, NVIDIA GeForce RTX 4070 Laptop
GPU, Vulkan. AMD reference commit: `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
This records measured behavior, not completed upstream parity.

## Commands and results

| Command / configuration | Result |
|---|---|
| `cargo test --all-targets` | Eleven unit tests passed; example compiled; two real GPU tests ignored by default |
| `cargo test --tests -- --ignored --nocapture --test-threads=1` | Software GPU transport/deformation/material regression and energy check passed |
| Same command with `BEVY_SOL_TEST_HARDWARE=1` | Vulkan hardware ray-query regression and energy check passed |
| GPU regression with `BEVY_SOL_TEST_FEEDBACK=1` | Optional feedback mode with multibounce disabled passed |
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
configuration bounds, WGSL validation, and Rust/shader layouts. Software, hardware,
textured software and textured hardware shaders are validated at both 16 and 64
probe directions; allocated probe struct sizes match those specializations.

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

One software run recorded final normalized sRGB-channel means of 0.3701 for
off-screen emission, 0.3260 for bounced point lighting, 0.2363 for spot lighting,
0.1437 for directional lighting, and 1.0000 for the saturated mirror. Dark phases
must fall below 0.001 after readback advances. These are transport smoke-test
signals, not linear-radiance accuracy measurements. Random/cache ordering can
change them. The mirror phase proves contribution, not reconstruction accuracy.

Bevy emitted no GPU validation errors. Offscreen shadow-LOD-origin and readback
channel-close warnings occurred; neither failed the regressions.

## Independent energy reference

`tests/furnace.rs` renders a large plane in constant scene-linear unit sky, with
no ambient/analytic/emissive lights, orthographic normal incidence, tone mapping
disabled and floating-point RGBA32 readback. The diffuse reference is Lambertian
reflectance 0.5. Glossy references numerically integrate the GGX distribution,
Smith masking and Schlick Fresnel in f64 over 65,536 hemisphere intervals; this
reference does not use the shader's VNDF sampler. Metallic F0 is 0.5.

The expected values include Bevy's `Exposure { ev100: 0.0 }` multiplier. Default
sampling/history/denoising are enabled. Both traversal backends produced:

| Surface | Expected | Measured mean | Relative error |
|---|---:|---:|---:|
| Lambertian 0.5 | 0.416667 | 0.418468 | +0.43% |
| GGX roughness 0.35 | 0.409126 | 0.402761 | -1.56% |
| GGX roughness 0.75 | 0.261222 | 0.259443 | -0.68% |

The tolerance is 5%, accounting for deferred G-buffer quantization and Monte
Carlo reconstruction. Diffuse variation over the measured patch was
0.416992–0.420166. The rough glossy test initially measured 0.298198 and failed:
current-neighborhood-only history clipping suppressed zero-valued GGX samples.
Retaining raw-sample variance in the temporal moments and clipping envelope fixed
that measured bias. This check covers a uniform environment at normal incidence;
it does not establish general scene lighting accuracy, grazing-angle accuracy,
textured-environment accuracy or dynamic-scene stability.

## Cornell captures and cost

Current captures: [software](../screenshots/cornell-software.png) and
[hardware](../screenshots/cornell-hardware.png). Both pass red/green wall assertions.
The hardware capture has red `[119,21,17,255]`, green `[27,100,23,255]`.
The example waits for 90 actual GI dispatch measurements before requesting a
capture. It renders 640x640, 96 triangles, 12,800 reserved probes, 16 directions
per valid probe, 32,768 cache entries, four receiver next-event samples, reservoir
resampling, multibounce, reflections, three à-trous passes and FXAA. There are no
ambient or analytic lights. One CPU BVH build occurs; packed scene data is 31,648
bytes. Per-view allocation is approximately 103.3 MB, excluding Bevy targets and
hardware acceleration structures.

One hardware diagnostic-history capture measured a 3.775 ms whole-GI GPU span:

| Hardware stage | GPU ms |
|---|---:|
| Probe tracing | 0.110 |
| Extra cache-bounce tracing | 0.045 |
| Reservoir generation | 0.087 |
| Direct cache update | 0.038 |
| Probe resolve / SH | 0.522 |
| Probe filtering | 0.113 |
| Pixel gather / MIS / reflections | 1.151 |
| Temporal reconstruction | 0.341 |
| À-trous 1 / 2 / 4 | 0.287 / 0.253 / 0.278 |
| Whole GI, including copies/composition | 3.775 |

CPU encoding averaged 0.041 ms. It excludes scene extraction, deformation,
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
