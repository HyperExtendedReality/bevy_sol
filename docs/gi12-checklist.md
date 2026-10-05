# GI-1.2 1:1 parity checklist

Reference: Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
Status: **1:1 parity is not complete.**

The requested architecture now replaces ReSTIR reuse/probe reconstruction with
Radiance Cascades while retaining the two cache levels. Track that intentional
exception and its performance/quality gates in [the cascade checklist](radiance-cascades.md).
The checked upstream mechanisms below describe the retained reference path;
ReSTIR, SH projection and legacy probe reconstruction do not run in cascade mode.

`[x]` means implemented with local test coverage, not proven identical to upstream.
`[ ]` means missing, partial or awaiting parity verification. Checked mechanisms
still have exact-parity requirements in the remaining-work section.
See [the detailed inventory](gi12-parity.md) and [validation evidence](validation.md).

## Implemented mechanisms

- [x] Slang/SPIR-V shader compilation and production specializations.
- [x] Software traversal and hardware ray queries, including alpha masks.
- [x] Ray-hit material textures, UV channels/transforms and face-oriented normals.
- [x] Morph-before-skin deformation and CPU BVH refits.
- [x] Preserved mesh-buffer positions for stochastic alpha hashing, including deformation/refits.
- [x] Source caches retained during pose-only updates; Bevy object motion vectors.
- [x] Full/quarter/sixteenth probe spawning, Halton phases and edge clamping.
- [x] Probe reprojection, empty/override compaction and atomic patching.
- [x] Separate primary geometry and shading normal inputs.
- [x] Source diffuse SH receiver evaluation uses normalized shading/details normals, with a native regression fixture.
- [x] Shared MT19937 seed table and source PCG draws.
- [x] Persistent probe LRU, projected candidate scans/scatter and atlas ownership.
- [x] Active/fresh probe and visibility/shadow query compaction.
- [x] Equal-area probe importance sampling and shared CDF construction.
- [x] Fixed-point radiance reuse, hysteresis, mask mips and directional filtering.
- [x] Signed half-packed SH projection and four-probe interpolation.
- [x] Cubemap evaluation, source environment RIS/ReSTIR and importance PDFs.
- [x] Tiled hash-grid descriptors, atomic accumulation, mips, caps and decay.
- [x] Streamed light-grid bounds, reservoir builders and merge policies.
- [x] World ReSTIR hashing, candidate reuse, packed reservoirs and frame swapping.
- [x] Multibounce BRDF/PDF transport, discarded-ray compensation and pending estimates.
- [x] Probe and glossy temporal radiance feedback with distinct rejection rules.
- [x] Source direct-lighting option for sky/emissive injection and probe feedback.
- [x] Source albedo-texture disable option: primary diffuse albedo 0.3 and specular F0 zero.
- [x] Source GI alpha-disable switch, explicit mask types, strict threshold and masked sidedness.
- [x] GGX reflection sampling, source blue-noise tables and BRDF LUT.
- [x] Half/full reflection modes with independent radii and firefly thresholds.
- [x] Reflection history gathering, firefly cleanup and ratio reconstruction modes.
- [x] Source firefly marking rules for sky, roughness, hit distance and unqueued neighbors.
- [x] Source atrous/split reconstruction neighbor gates independent of ray queue validity.
- [x] Source FP16 rounding at every reflection reconstruction/history pass boundary.
- [x] Source ratio-estimator Gaussian, accumulation order and final/fallback weight rules.
- [x] Per-channel reflection temporal sanitization with preserved history count.
- [x] Adaptive/separable diffuse denoising and motion/jitter reprojection.
- [x] Bevy HDR composition, viewport offsets and independent camera lifetimes.
- [x] Native fixtures and rendered transport, furnace, texture/mask and motion tests.

## Remaining parity work

- [ ] Map every upstream resource, stage, option, default and estimator with evidence.
- [ ] Match per-instance geometry reconstruction, acceleration structures and GPU deformation.
- [ ] Match source raster geometry/shading normals, visibility and material attachments.
- [ ] Match source material evaluation and texture LOD/gradient behavior.
- [ ] Map specular-material override.
- [ ] Match source stochastic alpha blending, including disabled-alpha emissive scaling.
- [ ] Match renderer-wide primary visibility and alpha behavior.
- [ ] Map optional occlusion input.
- [ ] Map optional bent-normal input.
- [ ] Map optional near-field GI input.
- [ ] Map source probe, hash-cache and reflection debug views.
- [ ] Map source cache statistics options.
- [ ] Match shared RNG ownership and entropy options; compare actual frame sequences.
- [ ] Match source cache/query resource representations and allocation capacities.
- [ ] Verify candidate claims, append ordering and cache contention against source frames.
- [ ] Match remaining source texture formats.
- [ ] Match remaining rounding at each pass boundary.
- [ ] Match probe sky filtering.
- [ ] Resolve SourceAtlas physical-energy/probe-resolution bias; optional furnace checks currently fail at both 4x4 and 8x8.
- [ ] Match source ray distances and offsets.
- [ ] Match source environment/light sampling endpoints and wave reductions.
- [ ] Match source previous-depth reconstruction and motion/exposure adapters.
- [ ] Match reflection boundary taps, cleanup update behavior and remaining thresholds.
- [ ] Build a harness with identical scene, material, camera and sampling inputs.
- [ ] Compare full frames and temporal sequences with the pinned source implementation.
- [ ] Compare multiple scenes with shared reference lighting and quantify image error.
- [ ] Measure repeated performance and temporal stability on the same hardware.
- [ ] Pass a requirement-by-requirement completion audit before declaring 1:1 parity.
