> Historical assessment of the pre-0.2 Radiance Cascades renderer, written on
> 2026-10-01. Its architecture, API, timings and recommendations describe that
> earlier implementation. The user subsequently chose a GI-1.2-style overhaul;
> see [the current architecture](hybrid-gi.md) and [validation](validation.md).
# Real-time GI research and a direction for bevy_sol

Research date: **2026-10-01**. This is an engineering assessment of the current
Bevy 0.19.1 crate, not a benchmark proving that one solver wins.

**Recommendation:** visibility-aware gathering, cheaper scene updates, then a
Split Radiance Cascades comparison. For a hardware-RT quality tier, evaluate
Bevy Solari before writing another path tracer. GI-1.2 is the strongest hybrid
cache design reference among the supplied links; ReSTIR PT Enhanced is the
strongest full-path-tracing reference.

This assumes the crate should retain its current compute-only rendering path.
If high-end ray-tracing hardware is the sole target, compare Solari first.

## Current architecture and bottlenecks

The source flow is:

1. `scene.rs::update_scene` extracts world-space triangles, constant materials,
   and analytic lights. `build_scene` builds a CPU BVH and surface-adjacent probe
   allocation, including coarse interpolation parents.
2. `gpu.rs::prepare` uploads geometry and allocates RGBA32F cascade interval
   buffers when the scene revision changes.
3. `dispatch` runs `trace_cascade` coarse-to-fine. Every allocated probe traces
   every directional bin over its cascade interval. A miss interpolates the
   already-merged upper cascade. Hits evaluate all analytic lights and their
   shadows, plus previous-frame diffuse feedback.
4. `resolve_irradiance` reduces the directional field to six cosine lobes,
   blends history, and copies the texture for feedback and Bevy's native
   `IrradianceVolume` shading.

| Constraint observed in source | Consequence |
|---|---|
| `interpolate_upper` lacks visibility weights; `sample_previous` uses linear texture sampling | Light can cross occluders during merging and feedback |
| Final six-lobe output has no distance/visibility data | Native volume shading cannot reject a probe behind the receiving surface's wall |
| Light/material/transform changes all trigger `build_scene` and GPU reallocation/history reset | Even changing light intensity rebuilds unchanged geometry and probe storage |
| Every allocated probe/bin is traced, and hit shading loops over every analytic light | Sparse storage alone does not bound updates or many-light shadow-ray cost |

These are source findings, not measurements of which GPU stage dominates. The
interval alpha is binary hit/miss transmittance, **not hit distance**. Distance
reconstruction needs additional data; replacing alpha without changing interval
composition changes the algorithm.

The README's 1.787 ms result is a prior development measurement of a 96-triangle
Cornell room on an RTX 4070 Laptop, with 2,509,568 interval samples and 43.8 MB
estimated allocation. It was not rerun for this report. Interval samples exclude
extra shadow rays. This cannot establish competitiveness against large-scene
published renderers.

## The supplied techniques

### ReSTIR PT Enhanced — May 2026

The authors report **2–3x faster execution than their earlier ReSTIR PT baseline**,
with better error and robustness. Changes include reciprocal spatial neighbor
selection, footprint-based reconnection, duplication maps to reduce correlation,
and unified direct/indirect reservoirs.
[NVIDIA publication](https://research.nvidia.com/labs/rtr/publication/lin2026restirptenhanced/).

**Fit assessment:** strong for diffuse/specular path tracing, but a different
architecture. This crate has no per-pixel path reservoirs, path-shift machinery,
secondary BSDF sampling, motion-vector reuse, or screen-space denoiser. Reservoir
selection added to cascade bins would not implement ReSTIR PT. Software traversal
is mathematically possible; repeated path and visibility queries may still be
expensive on this BVH.

Adopt these ideas after selecting a path-tracing backend. Measure candidate
generation, reuse, cache updates, and denoising together. The speedup is not a
prediction for this crate or evidence of superiority over GI-1.2 at equal budgets.

### Original Radiance Cascades — the Google Drive paper

The Drive file is Alexander Sannikov's **“Radiance Cascades: A Novel Approach to
Calculating Global Illumination [WIP]”**, a 36-page document. It separates near-field
spatial detail from far-field angular detail. Its introduction describes Path of
Exile 2's flatland-like screen-space hierarchy and screen-space ray marching,
motivated by its fixed camera.
[Supplied paper](https://drive.google.com/file/d/1L6v1_7HY2X-LV3Ofb6oyTIxgEaP4LOI6/view).

**Fit assessment:** foundational to this crate, but that implementation does not
establish cost or quality for a freely navigable 3D world volume. Cascade storage
scaling does not make triangle traversal or hit shading scene-independent. The
[author's repository](https://github.com/Raikiri/RadianceCascadesPaper) explicitly
says this work was not published in JCGT despite using its template.

### AMD GI-1.0 / GI-1.1 / GI-1.2

GI-1.0 combines screen-probe radiance with world-space hash cells. Useful features
include temporal probe reuse, redistribution of a fixed ray budget into
disocclusions, radiance-guided directions, and parallax-aware reuse using hit
distance. Table 1 reports **1.932–3.124 ms on RX 6900 XT**, at 1080p and 1/4 sample
per pixel, including traversal, caches/sampling, interpolation, and denoising.
These are DXR 1.1 GI-1.0 results, not GI-1.2 or portable WGSL timings.
[GI-1.0 report, sections 2 and 5](https://gpuopen.com/download/GPUOpen2022_GI1_0.pdf).

GI-1.1 adds glossy reflections: rough surfaces can use probes; sharper reflections
need rays and reconstruction. At 1080p on RX 7900 XTX, its total times are
**4.11–5.08 ms**, including diffuse GI. Reflection work adds roughly 1 ms.
[GI-1.1 paper, sections 2 and 3](https://gpuopen.com/download/publications/SA2023_RealTimeReflection.pdf).

GI-1.2, announced **November 20, 2025**, improves multibounce lighting with explicit
additional-bounce sampling in the hash cache. Rays from first-bounce cells create
second-bounce cells; their direct illumination becomes indirect samples at the
first-bounce cells, with the receiving BRDF applied. Separate direct/indirect
estimators accumulate across frames.
[AMD GI-1.2 explanation](https://gpuopen.com/learn/gi-1-2-multibounce-indirect-rendering/).

[Capsaicin](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin) confirms GI-1.2,
diffuse/specular indirect lighting, and an expectation of separate direct
lighting. Its implementation requires Direct3D 12 Ultimate; it is not a Bevy or
WGSL dependency.

**Fit assessment:** borrow scheduling/cache design, not the framework. Screen
probes require depth, normals/materials, motion vectors, per-view history,
reconstruction, and composition. A world cache supports off-screen hits, but
coverage and latency need testing. Explicit cache bounces are a larger change
than increasing `bounce_strength`.

## Additional contenders

| Technique | Why it matters | Role here |
|---|---|---|
| Split Radiance Cascades, July 2026 | Sparse world probes and surface-origin ray splitting | First algorithmic comparison for portable diffuse GI |
| Bevy Solari | Existing Bevy ray-tracing scene/material integration and lighting | First hardware-RT comparison |
| DDGI visibility-aware reconstruction | Rejects inappropriate probe contributions | Borrow reconstruction before raising ray counts |
| SHaRC | Sparse path updates and cached outgoing radiance | Non-neural cache reference for an eventual path tracer |
| Brixelizer GI | Compute-based GI implementation in HLSL | Alternative software-GI baseline |
| NVIDIA NRC / AMD FSR Radiance Caching | Online learned caches shorten path tracing | Later hardware-specific experiment |

### Split Radiance Cascades

Freeman and Sannikov's **July 22, 2026** preprint introduces sparse 3D hash probes
and surface-origin ray splitting: traced contributions are assigned to cascade
intervals according to hit distance. It demonstrates single-frame and temporal
versions.
[Paper abstract](https://arxiv.org/abs/2607.20384).

This changes ray generation, accumulation, and reconstruction as well as probe
allocation. The current solver separately traces every level's intervals. A
prototype must retain off-screen transport and handle misses under camera motion;
a speed/quality win remains unproven here.

[Chandra](https://github.com/entropylost/chandra) identifies `algorithm/rc.rs`,
`trace.rs`, and `splat.rs` as the merging/splitting, tracing, and shading paths.
Its [manifest](https://github.com/entropylost/chandra/blob/main/Cargo.toml) uses
local `keter`/`yesod` dependencies. Rust source does not make it a drop-in
Bevy/wgpu dependency. Port the algorithm experimentally, not its runtime.

### Solari and the version boundary

The maintainer's **August 29, 2026** report describes moving from screen probes
and cascades to unified direct/indirect diffuse/specular path tracing with a world
cache. With DLSS Ray Reconstruction, ReSTIR can be optional.
[Maintainer report](https://jms55.github.io/posts/2026-08-29-bevy-sixth-birthday/).

The neighboring local checkout at `C:/Dev/Bevy/bevy/crates/bevy_solari` confirms
`initial_path.wesl`, `restir.wesl`, `no_restir.wesl`, and world-cache passes. Its
`SolariPlugins::required_wgpu_features` requires experimental ray queries and
binding arrays. That checkout is **0.20.0-dev**; this crate uses **0.19.1**. Do not
assume the described development renderer is available unchanged by enabling one
feature on 0.19.1. Pin a compatible version or maintain a separate development
version comparison.

**Fit assessment:** reuse and measure this before duplicating BLAS/TLAS handling,
secondary materials, caches, and reconstruction. Quality depends on the complete
denoising pipeline; compare raw and reconstructed output separately.

### DDGI, SHaRC, and surface caches

DDGI's transferable contribution is a **visibility-aware moment-based
interpolant**.
[Original research](https://research.nvidia.com/publication/2019-05_dynamic-diffuse-global-illumination-ray-traced-irradiance-fields).

SHaRC uses sparse paths to update a world-space radiance cache, resolves history,
and terminates render paths when cached radiance is usable. Short segments and
narrow glossy footprints require care. The guide's 2^22-entry baseline costs
**160 MiB for its three main buffers**. A hash cache is not automatically smaller
than this bounded grid.
[SHaRC guide](https://github.com/NVIDIA-RTX/RTXGI/blob/main/Docs/SharcGuide.md).

Lumen's surface cache stores material/lighting data for ray-hit lookup, with
coverage and update costs. It complements a transport solver. Constant-material
shading here is cheap: profile the all-light shadow loop before building mesh-card
captures. Cache repeated hit lighting when measured reuse warrants it.
[Lumen technical details](https://dev.epicgames.com/documentation/en-us/unreal-engine/lumen-technical-details-in-unreal-engine).

### Newer ReSTIR work and neural caches

Two **July 2026** papers extend the path-tracing shortlist:

- **Compatibility-Guided Neighbor Selection:** reports 6–29% lower SMAPE and
  22–49% lower temporal covariance at 2–5% incremental cost for the evaluated
  pixel-space ReSTIR configurations. Relevant after spatial reservoirs exist.
  [Publication](https://research.nvidia.com/labs/rtr/publication/junkins2026compatibility/).
- **Multi-Layer Reservoir Splatting:** retains samples across multiple screen-space
  layers to improve temporal reuse under disocclusion. A targeted temporal-quality
  improvement, not a standalone solver.
  [Publication](https://research.nvidia.com/labs/rtr/publication/hong2026multilayer/).

Do not assume these compose with reciprocal neighbor selection without checking
the estimator and proposal probabilities.

[RTXGI](https://github.com/NVIDIA-RTX/RTXGI) supplies NVIDIA NRC and SHaRC examples;
its NRC requires Tensor Cores. AMD's
[FSR Radiance Caching](https://gpuopen.com/amd-fsr-radiancecaching/) is a technical
preview targeting RDNA 4 and DirectX 12. Both learn online from traced samples.
Their runtime/hardware integration makes them poor first changes to portable WGSL.

[Brixelizer GI](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/brixelizer-gi/)
is compute-based, implemented in HLSL with CS 6.6 requirements. Compute-based does
not mean directly compatible with WGSL/WebGPU. Evaluate it separately if profiling
justifies changing the tracing representation.

## Concrete implementation order

These are proposals, **not renderer changes implemented by this research**.

| Priority | Change and existing entry points | Acceptance evidence |
|---|---|---|
| 1 | Two-room/thin-wall reference scene; per-stage timings around `gpu.rs::dispatch` | Isolate trace/merge/gather/feedback errors and costs |
| 2 | Preserve distance/visibility; gather at receiver positions; update `interpolate_upper` and `sample_previous` consistently | Less cross-wall light without unacceptable darkening/cost |
| 3 | Separate light/material updates from geometry rebuilds in `scene.rs::update_scene` and `gpu.rs::prepare` | Light animation stops rebuilding unchanged BVH/probes and reallocating buffers |
| 4 | Prototype Split RC surface-origin rays and interval accumulation, initially reusing current triangle traversal | Better error/time/memory tradeoff at matched content |
| 5 | Demand/age/variance-based updates and selective history invalidation, if justified | Stable lighting response during occluder/light/camera changes |
| 6 | Compare compatible Solari for sharper indirect specular/full GI | Benefit on intended minimum hardware with reconstruction included |

Priority 2 has a real boundary: stock Bevy 0.19.1 `IrradianceVolume` sampling has
no visibility input. Filling or relocating invalid probes can improve the native
fallback but cannot make its hardware trilinear interpolation visibility-aware at
an arbitrary surface. Full receiver-aware reconstruction requires a custom material
sampling path or a per-view pass composed with Bevy's shading. Avoid double-counting
existing diffuse GI during composition.

A screen-space AO multiplier alone does not recover missing indirect radiance or
fix off-screen visibility. Preserve the existing off-screen-emitter behavior.

For tiny emitters/many lights, test emitter/light importance sampling and shared
hit-lighting caches after measuring costs. Mixing a stochastic estimator with
cascade quadrature needs correct weighting and double-counting control; sampled
emission cannot simply be added on top.

## Benchmark that decides the choice

Use the same geometry, material model, exposure, camera path, internal resolution,
light units, and converged diffuse path-traced reference. Begin with constant opaque
materials supported by this tracer. Test textures, alpha masks, smooth normals, and
deformation separately as capability differences.

| Scene or sequence | What it exposes |
|---|---|
| Two rooms, thin wall, emitter in one room | Interpolation leaks, invalid probes, feedback propagation |
| Small emissive panel outside the camera | Emitter sampling, cache coverage, camera dependence |
| Moving door and instant light toggle | Stale history, occlusion response, rebuild spikes |
| Dense textured scene and many moving lights | Hit-shading cost, material mismatch, update scaling |
| Fast camera motion, cuts, disocclusions | Cache warm-up, temporal correlation, reprojection failure |
| Roughness sweep including mirrors for specular candidates | Directional detail and denoising bias |

Report total GI GPU median/p95 and peak memory, CPU scene-update median/p95,
linear-HDR error including a relative measure such as SMAPE, and lighting-settling
time. Include traversal, caches, reconstruction, composition, denoising, and
acceleration-structure updates. Show quality at equal GPU budgets, e.g. 2/4/8 ms,
and document native resolution/upscaling. Frame generation does not reduce GI
computation or lighting latency.

Retain the existing unit/WGSL and emitter/light GPU regressions when implementing
changes. Add one focused leak/response regression before changing reconstruction.
No renderer tests were run for this documentation-only update.

## Evidence limits

The GI-1.0/GI-1.1 reports, AMD GI-1.2 explanation, SDK guides, original RC
introduction through Drive, and local renderer sources were inspected. ReSTIR PT
Enhanced and Split RC assessment uses official abstracts/project information:
their full PDFs exceeded the web reader's size limit. Check detailed shift equations,
Split RC accumulation rules, and numerical implementation choices against complete
papers before a port. No head-to-head benchmarks were run; published timing tables
use different hardware/workloads.

