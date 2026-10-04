# GI-1.2 parity inventory

Target: AMD Capsaicin commit `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
This inventory distinguishes executable implementations from exact upstream
parity. The crate is **not a complete 1:1 port**. Passing the current regressions
does not establish equivalence or superiority to GI-1.2.

| Upstream mechanism | Current executable implementation | Remaining difference |
|---|---|---|
| Shader toolchain | Embedded Slang modules compiled by the custom `bevy_slang` crate, native SPIR-V, sparse descriptor relocation, selected specialization compiled once | External `slangc` required; native pipeline currently Vulkan only |
| Hardware triangle tracing | Native Slang `RayQuery` with alpha-tested candidates; identical triangle/shading ordering to software traversal | One world-space BLAS/TLAS instance, rebuilt on motion; no per-mesh instancing or GPU deformation/build pipeline |
| Material evaluation at ray hits | Base/emissive/metallic-roughness maps, UV0/UV1, UV transforms, normal maps, masks | LOD zero, UV-gradient tangent frames, 64-image capacity; no full layered/transmissive material model |
| Animated triangle positions | Morphs followed by weighted joint transforms; CPU BVH refit preserves leaf ordering; Bevy transform/skin/morph motion vectors preserve compatible pixel histories during pose refits | Synchronous whole-scene extraction/upload; world/probe caches reset on pose changes; broader animation stability/scaling unproven |
| Screen probe allocation and reuse | Full/quarter/sixteenth refresh with source shared 256-frame Halton phase/seed placement, retained compatible seeds, separate fresh/active compaction, disocclusion tracing, primary/second surface slots and source mask-mip lookup | Partial borders clamp to valid tiles; fixed two-layer capacity; refreshes are scheduled per grid tile rather than the complete upstream empty/override atlas patch sequence |
| Persistent probe cache | Projected candidates, shared restored histories, exclusive update flags, parallel scanned free/eviction list, stable LRU/MRU compaction, and merged directional histories from all compatible cached neighbors; survives leaving/returning to the view | Linked lists replace prefix-scattered candidate lists; SH temporal history remains closest-history; atlas relocation/update representation differs; floating-point CAS replaces source fixed-point sums |
| Probe compaction | Active and fresh probe lists with separate GPU indirect counts | Fixed ray capacity includes all-fresh resets; source allocates its spawn queries separately |
| Probe importance sampling | Source equal-area hemi-octahedral map/inverse/tangent frame, half-packed radiance/distance, Fresnel/diffuse layer probability, bounded GGX branch, shared-memory CDF scan and binary search, uniform mixture and compensated PDF | Half uniform coverage retained; compensated ray-integral estimator differs from source atlas-cell reconstruction; random sequence differs |
| Probe radiance filtering | Source shadow-preserving luminance hysteresis, energy-spread backup for untraced cells, first-valid mask-mip reduction, nearest-probe search, six alternating taps in each axis, endpoint angle rejection and depth weight | Flattened masks/packed arrays replace textures; source atlas relocation/patch scheduling remains incomplete; floating-point accumulation replaces fixed-point atomics |
| Probe SH projection | Default source atlas-cell projection after directional filtering, source RGB/side-length normalization, nine signed half-packed coefficients and cell-count alpha; optional compensated ray estimator | Geometry normals still come from Bevy's deferred shading normal; source atlas patch scheduling differs; sanitization guards half packing |
| Probe interpolation | Source original blue-noise tile jitter with receiver-plane acceptance, four nearest-mask/seed-relative probes, duplicate rejection, eighth-power depth/normal weights and equal-weight low-confidence backup when all weights fail | A second surface layer and traced fallback for absent probes supplement the source; geometric normals are approximated by the deferred normal; SH projection still differs |
| Environment lighting | Raw HDR cubemap evaluation for probe/reflection misses and shadowed diffuse/specular secondary lighting; rotation, uniform/cosine hemisphere modes, source face CDF and four-child mip descent with matching PDF | Environment is sampled separately from the streamed light-grid RIS distribution; ray-cone LOD remains absent; black-map and zero-child handling hardened; importance PDF follows the clamped hierarchy instead of the source unclamped leaf approximation |
| Hash-grid radiance cache | PCG/xxHash descriptors, incoming-direction classification, distance/FOV sizing, atomic accumulation, half-float radiance, 8x8 tile mip hierarchy, sample caps and 50-frame decay; auxiliary surface cache | Auxiliary cache representation and scheduling differ; allocation contention and full source trace/update equivalence still need comparison |
| Light sampling | Hit-streamed bounds, volume/centroid build, octahedral cells, overlap weights, serial/parallel reservoirs, all three merge policies, point/normal resampling, normalized matte BRDF RIS, source barycentric mapping, area-light cone LOD and texture alpha | Random seeds/reduction order differ; environment remains outside streamed RIS; compensated projection's receiver MIS retains an alias distribution; geometry normals and Bevy materials differ |
| World-space ReSTIR | Independent current/previous PCG/xxHash tables, source collision probing, count scan/scatter, compacted values, half origins/hits, snorm10 normals, RGB565 matte materials and packed reservoirs; source four strided candidates, bilateral cutoff, M cap and visibility invalidation; frame regions swap without copies | Source arrays are flattened; sample IDs retain fixed ray slots instead of compacted shadow IDs; auxiliary cache shading remains separate; source random seed buffer is not reproduced; positions below the source minimum and degenerate footprints are hardened |
| Multibounce transport | Explicit extra diffuse bounce, separate direct/indirect estimates, previous-frame pending estimate | Different cell representation and transport schedule; no general recursive/specular secondary transport |
| Temporal radiance feedback | Validated previous HDR at visible secondary hits, compensated for exposure; optional and disabled with multibounce | Different reprojection thresholds and cache integration; not upstream frame-equivalent |
| Glossy transport | Bounded GGX VNDF with source quaternion rotation, original Sobol/ranking/scrambling tables and 256-frame golden-ratio blue-noise animation for tracing/filter jitter, reused GGX sample for full-radius hash-cell jitter in the source tangent frame, half-quantized BRDF LUT, endpoint and virtual-hit histories, rough probe reuse, firefly marking/cleanup, separable and à-trous ratio estimators, half/full resolution | Tables are losslessly byte-packed; optimized ranking dimensions wrap safely; geometry-normal derivation, representation and some thresholds differ; virtual-hit history still uses camera reprojection; frame-equivalent source comparison still absent |
| GI denoising | Source nine-tap reprojection, half-quantized signed color delta/blur mask, adaptive/vignetted history cap, two separable depth/normal passes and filtered history; optional variance/à-trous mode; Bevy object/camera motion vectors corrected for projection jitter in both modes and primary reflection history | World-position history replaces previous depth unprojection; orthographic support added; delta/mask share a packed carrier; source-compatible position/normal rejection can reject large motions; world/probe cache histories still reset on pose changes |
| Engine integration | Bevy deferred prepass and additive exposed HDR composition, main-pass resolution overrides including viewport offsets, independent camera lifetimes | Capsaicin renderer/source material handling differs; renderer-equivalent inputs still need a matched harness |
| Accuracy evidence | Lambertian and independent GGX furnace checks, off-screen transport, texture/mask/deformation regressions | No shared multiscene path-traced ground truth, repeated performance trials or upstream image comparisons |

## Engine boundary

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
returned radiance. The parallel builder merges 128 partial reservoirs using
shared memory, preserving light strata and probabilities without assuming a
fixed hardware wave size. These changes preserve the intended estimators but
do not produce bit-identical source random sequences.
