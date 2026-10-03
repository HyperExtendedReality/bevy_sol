# GI-1.2 parity inventory

Target: AMD Capsaicin commit `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
This inventory distinguishes executable implementations from exact upstream
parity. The crate is **not a complete 1:1 port**. Passing the current regressions
does not establish equivalence or superiority to GI-1.2.

| Upstream mechanism | Current executable implementation | Remaining difference |
|---|---|---|
| Hardware triangle tracing | Vulkan WGSL ray queries with alpha-tested candidates; identical triangle/shading ordering to software traversal | One world-space BLAS/TLAS instance, rebuilt on motion; no DX12/DXR backend, per-mesh instancing, or GPU deformation/build pipeline |
| Material evaluation at ray hits | Base/emissive/metallic-roughness maps, UV0/UV1, UV transforms, normal maps, masks | LOD zero, UV-gradient tangent frames, 64-image capacity; no full layered/transmissive material model |
| Animated triangle positions | Morphs followed by weighted joint transforms; CPU BVH refit preserves leaf ordering | Synchronous whole-scene extraction/upload; lighting histories reset on pose changes; animation stability/scaling unproven |
| Screen probe allocation and reuse | Jittered primary slot and second surface slot, validated reprojection and directional parallax redistribution | Fixed two-layer capacity; no full persistent probe cache, LRU/free-list relocation or upstream patching sequence |
| Probe compaction | Active probe list and GPU indirect dispatch | Different allocation/compaction schedule from upstream |
| Probe importance sampling | Uniform hemisphere bins mixed with previous radiance distribution and compensated PDF | Different bin representation and sampling distribution from upstream |
| Probe SH projection | Nine real SH coefficients, separate filtered coefficients, cosine-convolved diffuse gather | No upstream atlas/packed sample representation or identical filtering equations |
| Hash-grid radiance cache | Camera-scaled cells with full descriptor/material checks, expiry, plane/normal rejection, compact touched lists | Uncompressed flat cells; no upstream tile allocation, descriptors, directional classification and tile mip hierarchy |
| Light sampling | Alias distribution, eight-candidate RIS, temporal and four-neighbor reservoir reuse, selected shadow test | No streamed light grid or exact upstream visibility/resampling buffers and scheduling |
| Multibounce transport | Explicit extra diffuse bounce, separate direct/indirect estimates, previous-frame pending estimate | Different cell representation and transport schedule; no general recursive/specular secondary transport |
| Temporal radiance feedback | Validated previous HDR at visible secondary hits, compensated for exposure; optional and disabled with multibounce | Different reprojection thresholds and cache integration; not upstream frame-equivalent |
| Glossy transport | GGX VNDF and mirror rays, rough probe reuse, material-aware spatial/temporal reconstruction | No reflection endpoint/virtual-hit history, separable ratio estimator, upstream firefly cleanup or complete reflection denoiser |
| GI denoising | Bilinear validated histories, demodulated diffuse, moments, temporal-variance clipping, four optional à-trous stages | Different kernels, storage, moments and history policy; not the upstream denoiser |
| Engine integration | Bevy deferred prepass and additive exposed HDR composition; independent camera lifetimes | Capsaicin renderer/source material handling differs; main-pass resolution override unsupported |
| Accuracy evidence | Lambertian and independent GGX furnace checks, off-screen transport, texture/mask/deformation regressions | No shared multiscene path-traced ground truth, repeated performance trials or upstream image comparisons |

## Engine boundary

The local Bevy 0.19.1 renderer already exposes acceleration structures and WGSL
ray queries through wgpu 29.0.4. The crate therefore implements Vulkan hardware
traversal without changing Bevy source. The pinned wgpu implementation exposes
experimental ray queries through its Vulkan backend; a native DX12/DXR path
requires backend work below this crate. Changing Bevy alone does not fill the
remaining probe, cache, reservoir, or reflection algorithm gaps listed above.

## Completion criteria

To claim a 1:1 algorithm port, every upstream resource, stage, option and estimator
needs a mapped implementation, including probe patching/caching, tiled hash-cache
mips, streamed world-space ReSTIR, and reflection ratio reconstruction. Matching
Rust/WGSL memory layouts or passing simple scenes is insufficient.

To claim equivalent or better quality/performance additionally requires identical
scene/material/camera inputs, comparable sampling settings, reference lighting,
repeated timings on the same hardware, and error/temporal stability measurements.
Current measurements are recorded in [validation.md](validation.md).
