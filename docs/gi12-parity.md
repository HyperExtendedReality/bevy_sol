# GI-1.2 parity inventory

Target: AMD Capsaicin commit `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
This inventory distinguishes executable implementations from exact upstream
parity. The crate is **not a complete 1:1 port**. Passing the current regressions
does not establish equivalence or superiority to GI-1.2.

The [simple checklist](gi12-checklist.md) tracks implemented mechanisms and the
remaining completion gates, including upstream options and optional inputs.

The default transport now intentionally uses [surface Radiance Cascades](radiance-cascades.md)
instead of upstream probe reconstruction and ReSTIR reuse. The upstream estimator
remains selectable with `radiance_cascades: None`; the inventory below records
that reference path, not a claim that all its stages execute in cascade mode.

| Upstream mechanism | Current executable implementation | Remaining difference |
|---|---|---|
| Shader toolchain | Embedded Slang modules compiled by the custom `bevy_slang` crate, native SPIR-V, sparse descriptor relocation, selected specialization compiled once | External `slangc` required; native pipeline currently Vulkan only |
| Hardware triangle tracing | Native Slang `RayQuery` with alpha-tested candidates; identical triangle/shading ordering to software traversal | One world-space BLAS/TLAS instance, rebuilt on motion; no per-mesh instancing or GPU deformation/build pipeline |
| Material evaluation at ray hits | Base/emissive/metallic-roughness maps, UV0/UV1, UV transforms, masks; source sign-corrected cofactor vertex transforms, preserving magnitudes until face-oriented normalized hit interpolation, without material normal maps, single-sided backface rejection or hemisphere repair; compensated normal maps and normalized inverse-transpose vertices | CPU world-space vertex representation replaces source per-instance reconstruction; LOD zero, compensated UV-gradient tangent frames, 64-image capacity; no full layered/transmissive material model |
| Animated triangle positions | Morphs followed by weighted joint transforms; CPU BVH refit preserves leaf ordering; SourceAtlas retains world/persistent-probe caches across pose-only updates; Bevy transform/skin/morph motion vectors preserve compatible pixel and screen-probe histories during pose refits; compensated mode still clears caches | Synchronous whole-scene extraction/upload; broader animation stability/scaling and upstream moving-scene comparisons unproven |
| Screen probe allocation and reuse | Full/quarter/sixteenth spawn regions with source shared 256-frame Halton seeds and viewport-edge clamping, whole-tile best-seed reprojection with half-quantized scores, empty/override tile compaction, collision-permitting atomic patch exchanges, separate fresh/active lists and one source atlas probe per tile | Optional second-surface slots remain exclusive to compensated mode |
| Primary geometry normals | Separate source geometry/shading inputs; one camera-facing triangle query per valid pixel, depth-derived fallback, R10G10B10A2_UNORM cache prepared before probe scheduling; geometry input drives probe history/hemispheres and interpolation gates; normalized shading/details normals drive source diffuse SH receiver evaluation, denoising and reflection history | Query/depth matching replaces raster derivatives and adds tracing cost; shading inputs retain Bevy deferred representation |
| Random number generation | Renderer-owned shared MT19937 GPU seed table, deterministic seed 5489 by default, componentwise 1920x1080 minimum, retained on shrink and regenerated on growth or source option changes; modulo seed lookup, both MakeRandom overloads and source PCG draws; configurable deterministic/entropy-seeded generation; compact visibility IDs seed multibounce/fresh reservoirs, compact shadow IDs seed temporal resampling | Multiple Bevy GI views request the largest required seed count; no stratified-sampler buffer sharing; entropy uses Rust's OS-seeded hasher rather than std::random_device; atomic append order and frame-equivalent source sequences still need a matched comparison |
| Persistent probe cache | Source LRU-driven projected candidate counts, exclusive prefix scans and ordinal scatter into contiguous per-tile lists, strict XYZ frustum rejection and normalized tile-grid projection; all scattered neighbors contribute fixed-point radiance reuse; source XYZ/packed snorm10-normal metadata, normalized decoding for ownership and reconnect frames; separate source evicted/updated atlas ownership, source LRU-prefix allocation priority, exclusive claims, old-atlas eviction into MRU and in-place radiance updates that preserve cached metadata/LRU order; compensated mode retains linked lists, shared restoration and scanned free/eviction reservations | Source geometric-normal derivation differs; cache atlas/metadata are flattened into combined records; candidate/claim atomic ordering remains unverified against an upstream frame; compensated SH temporal history remains closest-history |
| Probe compaction | Active and fresh probe lists with separate GPU indirect counts; dense source first-hit/multibounce visibility streams and valid-reservoir shadow IDs with physical-ray mappings | Fixed-capacity storage; some dispatches use the fresh-ray upper bound and reject unused lanes; source allocates spawn queries separately |
| Probe importance sampling | Source equal-area hemi-octahedral map/inverse/tangent frame, half-packed radiance/distance, full Fresnel layer probability, bounded GGX branch, shared-memory CDF scan and binary search; separate geometric hemisphere and shading BRDF normals; source incident-radiance atlas reconstruction without the uniform mixture; optional compensated mixture/PDF | Primary geometry-normal derivation and Bevy shading representation differ |
| Probe radiance filtering | Fixed-point integer reuse/resolve sums, immutable reprojected neighboring atlases, source four-channel shadow-preserving hysteresis, energy-spread backup for untraced cells, first-valid mask-mip reduction, six alternating taps in each axis, endpoint angle rejection and depth weight | Flattened masks/packed arrays replace textures; far-distance quantization is guarded against half-infinity overflow |
| Probe SH projection | Default source atlas-cell projection after directional filtering, source RGB/side-length normalization, nine signed half-packed coefficients and cell-count alpha; distinct primary geometry normals; optional compensated ray estimator | Primary normal derivation differs; sanitization guards half packing |
| Probe interpolation | Source original blue-noise tile jitter with geometry-normal receiver-plane acceptance, four nearest-mask/seed-relative probes, duplicate rejection, eighth-power depth/normal weights and equal-weight low-confidence backup when all weights fail; absent source probes return black with confidence one and do not queue reflection rays; rough glossy reuse shares the same four-probe weights | Primary normal derivation differs; compensated mode retains traced missing-probe fallback and a second surface layer |
| Environment lighting | Raw HDR cubemap evaluation for misses; source virtual environment light in streamed grid/RIS/ReSTIR, oriented six-face weights, secondary ray-cone LOD, rotation, uniform/cosine hemisphere modes; source normalized face CDF with earlier-face ties, unclamped sample remapping, row-before-column probability accumulation, source complementary-probability floor and ordered Jacobian conversion; source evaluated importance PDF uses the unclamped leaf luminance/face-average sum and ceil-snapped texel lookup; compensated evaluation follows the clamped sampling hierarchy | Compensated mode samples the environment separately; black-map and exact zero-mass endpoint handling remain hardened; native scalar comparisons do not establish bitwise upstream or full-render equivalence |
| Hash-grid radiance cache | PCG/xxHash descriptors, incoming-direction classification, distance/FOV sizing, atomic accumulation, half-float radiance, 8x8 tile mip hierarchy, sample caps and 50-frame decay; SourceAtlas uses only this cache, with no auxiliary allocation/shading fallback; compensated mode retains its auxiliary cache | Allocation contention and full source trace/update equivalence still need comparison; a dummy auxiliary descriptor remains for the shared shader layout |
| Light sampling | Hit-streamed bounds, volume/centroid build, octahedral cells, overlap weights, serial/parallel reservoirs including the environment, source shared reservoir seed and wave-prefix CDF followed by ordered wave-total merge, all three merge policies, point/normal resampling, normalized matte BRDF RIS, source barycentric mapping, area/environment cone LOD and texture alpha | Compensated projection's receiver MIS retains an alias distribution; geometry normals and Bevy materials differ; native wave width affects source floating-point reduction |
| World-space ReSTIR | Independent current/previous PCG/xxHash tables, source collision probing, count scan/scatter, compacted shadow sample IDs and values, half origins/hits, snorm10 normals, RGB565 matte materials and packed reservoirs; source four strided candidates, bilateral cutoff, M cap and visibility invalidation; frame regions swap without copies | Source arrays are flattened; positions below the source minimum and degenerate footprints are hardened; exact atomic append order is unverified |
| Multibounce transport | Source compact visibility-driven cosine sampling in the quaternion frame, forced matte full dielectric BRDF and half-packed BRDF/PDF, discarded-ray probability compensation, separate direct/indirect estimates and previous-frame pending estimate; selected short secondary rays also accumulate immediately into screen probes while still updating the indirect cache; optional compensated diffuse path | Physical ray records replace source packed instance/primitive/barycentric visibility records |
| Temporal radiance feedback | Source projected-hit/velocity history with strict UV/depth bounds, previous geometry normals, probe 0.5-normal/5%-relative-depth and glossy 0.95-normal/1%-relative-depth rejection; exposure-compensated previous HDR; accepted probe samples bypass shadow tracing and filtered cache readback while accumulating into direct cache; optional and disabled with multibounce; compensated mode retains current visibility/material guards | Previous world positions replace source depth textures; source normal inputs are query-derived; Bevy motion/exposure adapters and orthographic support remain; not upstream frame-equivalent |
| Glossy transport | Bounded GGX VNDF with source quaternion rotation, original Sobol/ranking/scrambling tables and 256-frame golden-ratio blue-noise animation, full-radius hash-cell jitter, half-quantized BRDF LUT, endpoint and camera-projected virtual-hit histories with one filtered shading normal, gathered-depth rejection, clamp sampling and source gather-order integer-load fallback without a material gate; rough probe reuse with source dimension-one sampling and shared four-probe interpolation weights without hemisphere renormalization, firefly cleanup, separable and à-trous ratio estimators, half/full resolution; split vertical jitter, sampled-column lookup and low-confidence backup | Tables are losslessly byte-packed; optimized ranking dimensions wrap safely; geometry-normal derivation, representation and some thresholds differ; frame-equivalent source comparison still absent |
| GI denoising | Source nine-tap reprojection, half-quantized signed color delta/blur mask, adaptive/vignetted history cap, two separable depth/shading-normal passes and filtered history; source decoded RGB10 shading/details normal arithmetic without renormalization, preserved in full-float history; optional variance/à-trous mode; Bevy object/camera motion vectors corrected for projection jitter in both modes and primary reflection history | World-position history replaces previous depth unprojection; orthographic support added; delta/mask share a packed carrier; source-compatible rejection can reject large motions; source shading normals are quantized from Bevy deferred inputs |
| Engine integration | Bevy deferred prepass and additive exposed HDR composition, main-pass resolution overrides including viewport offsets, independent camera lifetimes | Capsaicin renderer/source material handling differs; renderer-equivalent inputs still need a matched harness |
| Accuracy evidence | Lambertian and independent GGX furnace checks, off-screen transport, texture/mask/deformation regressions | No shared multiscene path-traced ground truth, repeated performance trials or upstream image comparisons |

## Engine boundary

Source diffuse SH evaluation now uses the normalized shading/details normal,
while geometry normals continue to govern placement and interpolation gates.
A native fixture with perpendicular geometry/shading normals failed before
the correction and passes after it. This follows the pinned upstream
[InterpolateScreenProbes receiver-normal selection](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/blob/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/render_techniques/gi1/gi1.comp#L1440).
It does not resolve the separate probe-resolution-dependent SourceAtlas furnace
failures recorded in the cascade benchmark report.

`source_disable_alpha_testing` maps source `DISABLE_ALPHA_TESTING` for GI
closest-hit and shadow rays. Hardware queries use `RAY_FLAG_FORCE_OPAQUE`;
software traversal bypasses the alpha predicate. With testing enabled, source
masked hits use strict alpha greater than 0.5 and reject single-sided masked
backfaces. Opaque backfaces and all force-opaque hits bypass that rejection.
An explicit two-bit alpha type accompanies the UV-channel flags; source classification
does not infer the material type from the Bevy cutoff. Negative and NaN mask
cutoffs still denote masked materials and use the source's fixed threshold.
Compensated mode ignores the disable bit and retains the Bevy material's cutoff
and inclusive comparison. The switch does not change Bevy's primary raster
visibility. SourceAtlas now includes `AlphaMode::Blend` in the GI scene and tests
strict alpha greater than a stochastic threshold for closest and shadow rays.
Single-sided blended backfaces are rejected when alpha testing is enabled.
Compensated mode continues to exclude blended geometry. Switching projection
modes refreshes membership, deformation normal transforms and pixel histories.
Renderer-wide alpha parity remains open.
The source blend threshold hashes the interpolated mesh-buffer vertex position
and frame index, before applying the instance transform. Triangle packets now
retain three mesh-buffer positions alongside world-space traversal geometry,
with a 20-word stride. Static and morph-only positions exclude the instance
transform; skinned positions use the source animation order,
`instance_inverse * weighted_skin_matrix`, after morphing. CPU extraction/refit
tests and both native traversal fixtures verify the preserved coordinates and
their GPU barycentric interpolation. The threshold matches the pinned uint4
xxHash and upper-24-bit conversion, including conversion of the frame index to
float before bit-casting. When alpha testing is disabled, blended hit/cone
emission is multiplied by base-color alpha and its level-zero texture alpha,
as in `emissiveAlphaScaled`; masks and opaque materials are not dimmed this way.
Native source-rule comparisons do not establish upstream frame equivalence.

`source_disable_albedo_textures` maps `g_DisableAlbedoTextures` in the pinned
`gi1.frag` composition: primary diffuse albedo becomes 0.3 and primary specular
F0 becomes zero. The remaining directional-albedo LUT term and diffuse Fresnel
compensation are still evaluated. The option does not disable texture sampling
at secondary hits, alter probe sampling guides or remove emissive radiance. It
is ignored in compensated mode. Shared composition material helpers are used by
the fragment pass and both diffuse denoiser paths' specular composition. As with
other engine adapters, Bevy's separate primary direct/emissive lighting is not
overridden; matching the complete source renderer remains an open requirement.

`source_direct_lighting` maps the pinned `gi1_use_direct_lighting` option in
SourceAtlas. It gates probe sky misses, front-facing emissive probe/glossy hits,
glossy sky misses and probe temporal feedback. Glossy indirect history and
cache lighting remain available, as do world-space next-event light estimates.
It does not disable Bevy's primary direct lighting. Enabled source glossy sky
misses carry the source positive FP16 sky sentinel 65504; disabled misses retain
the invalid-distance sentinel -1. Compensated mode ignores this source option.

All source reflection trace, direction, cleanup, ratio-estimator moment/color,
split, standard-deviation, resolved and temporal/history planes now store packed
half-float pairs across dispatches, matching the source RGBA16F writes. Tracing
compresses unsanitized source radiance; cleanup/temporal stages apply their own
source sanitization. The combined allocation still reserves float4-sized records.
The source final ratio pass normalizes any positive weight, intermediate passes
require weight above 1e-3, and split fallback adds backup taps to its retained
weighted sum. Source atrous Gaussian weights include the two source normalization
factors, and roughness/neighborhood accumulation follows source X-major order.

Source reflection temporal accumulation sanitizes each final RGB channel with
the source compression/clamp/decompression operation and preserves the history
count separately. Compensated mode retains its pre/post whole-color guards.

Source primary shading normals are RGB10 round/decoded and normalized for BRDF
sampling, probe Fresnel selection, reflection PDFs and directional-albedo lookup.
History rejection retains the raw decoded value without normalization. This
adapter still starts from Bevy deferred normals rather than a source raster
shading-normal attachment.

Source firefly marking rejects sky/rough center pixels, marks negative hit
distances, and compares roughness-accepted neighbors even when their ray queue
validity bit is clear or they are sky pixels. It uses full-pixel marking radius
and strict lower/higher luminance thresholds. Source atrous reconstruction no
longer rejects neighbors solely for missing queue validity; source split
reconstruction retains the upstream roughness-only neighbor rejection.

Source glossy firefly cleanup uses the configured radius in sample-grid units
at either resolution, source separable Gaussian sample-offset weights, X-major
accumulation, center addition below 1e-3 total weight and four-channel source
sanitization. The port still uses separate immutable input/output planes instead
of the upstream in-place cleanup and explicitly rejects out-of-bounds taps.
Reflection options now preserve independent source half/full-resolution split,
marking and cleanup radii and marking thresholds. Defaults select marking radii
3/2 and cleanup radii 2/1; split radius is 11 at either resolution. The active
resolution selects the uniform values without changing shader layouts.

The local Bevy 0.19.1 renderer already exposes acceleration structures, ray queries,
and native SPIR-V passthrough through wgpu 29.0.4. The crate implements Vulkan hardware
traversal without changing Bevy source. The pinned wgpu implementation exposes
experimental ray queries through its Vulkan backend; a native DX12/DXR path
requires backend work below this crate. Changing Bevy alone does not fill the
remaining probe, cache, reservoir, or reflection algorithm gaps listed above.

## Completion criteria

To claim a 1:1 algorithm port, every upstream resource, stage, option and estimator
needs a mapped implementation, including probe patching/caching, tiled hash-cache
mips, streamed world-space ReSTIR, and reflection ratio reconstruction. Matching
Rust/SPIR-V memory layouts or passing simple scenes is insufficient.

To claim equivalent or better quality/performance additionally requires identical
scene/material/camera inputs, comparable sampling settings, reference lighting,
repeated timings on the same hardware, and error/temporal stability measurements.
Current measurements are recorded in [validation.md](validation.md).

The grid guards empty tail segments in the source's without-replacement merge
and pads degenerate bounds. The optional overlap setting applies the computed
overlap factor; the pinned source computes that factor without applying it to
returned radiance. In SourceAtlas the parallel builder uses the source per-wave
CDF selection and ordered wave-total merge, with one seed shared by each group
of 128 partial reservoirs. Every lane reaches the group barrier before losing
lanes return, avoiding the pinned source's divergent barrier. Compensated mode
retains its flat shared-memory merge. Source reduction remains hardware-wave
dependent; frame-equivalent output across different devices is not established.

Source hash lookup stops at the first empty bucket slot, matching the pinned
implementation; compensated lookup retains its search past eviction holes.
An existing metadata word holds a per-frame update claim, reset by tile clearing.
This reproduces new-tile initialization at frame zero and after integer wrap
without depending on a zero-valued timestamp, and prevents duplicate concurrent
update-list entries. Exact source atomic contention order remains unverified.
