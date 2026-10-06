# GI-1.2 1:1 parity checklist

Reference: Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
Status: **1:1 parity is not complete.**

The sole target is a 1:1 port of GI-1.2: screen probes, persistent radiance
caches, reservoir importance sampling and optional world-space ReSTIR-style
resampling, source probe reconstruction, and reflections. Resampling improves
lighting samples gathered at probe/cache hits; probe transport stays intact.

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
- [x] Optional packed AO/bent-normal and near-field irradiance camera attachments, source SH cone evaluation and irradiance units through denoising.
- [x] Shared MT19937 seed table and source PCG draws.
- [x] Persistent probe LRU, projected candidate scans/scatter and atlas ownership.
- [x] Active/fresh probe and visibility/shadow query compaction.
- [x] Equal-area probe importance sampling and shared CDF construction.
- [x] Fixed-point radiance reuse, hysteresis, mask mips and directional filtering.
- [x] Source sky/zero-distance probe filtering, distinct resident/reprojected hemisphere predicates, unclamped fixed-point conversion and half-packed spawn radiance before blending.
- [x] Source ULP/additive position offsets, zero ray TMin, 1e9 GI range and unnormalized point-shadow segments with 1/16384 endpoint exclusion.
- [x] Signed half-packed SH projection and four-probe interpolation.
- [x] Raw source probe radiance/SH half packing and stored half sample directions decoded without renormalization; packed shared spawn radiance before blending.
- [x] Cubemap evaluation, source environment RIS/ReSTIR and importance PDFs.
- [x] Tiled hash-grid descriptors, atomic accumulation, mips, caps and decay.
- [x] Streamed light-grid bounds, reservoir builders and merge policies.
- [x] World ReSTIR hashing, candidate reuse, packed reservoirs and frame swapping.
- [x] Multibounce BRDF/PDF transport, discarded-ray compensation and pending estimates.
- [x] Probe and glossy temporal radiance feedback with distinct rejection rules.
- [x] Source direct-lighting option for sky/emissive injection and probe feedback.
- [x] Source albedo-texture disable option: primary diffuse albedo 0.3 and specular F0 zero.
- [x] Source specular-material disable option: diffuse probe sampling, RGB10 reservoir materials, secondary diffuse compensation and GI reflection suppression.
- [x] Source dielectric F0 0.04 in probe sampling, hit shading, reservoir targets, multibounce and primary GI composition.
- [x] Source GGX squared-alpha clamp, unclamped bounded-cap alpha, signed visibility cosines and singular PDF endpoint.
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
- [ ] Match source stochastic alpha blending, including disabled-alpha emissive scaling.
- [ ] Match renderer-wide primary visibility and alpha behavior.
- [ ] Map source probe, hash-cache and reflection debug views.
- [ ] Map source cache statistics options.
- [ ] Match shared RNG ownership and entropy options; compare actual frame sequences.
- [ ] Match source cache/query resource representations and allocation capacities.
- [ ] Verify candidate claims, append ordering and cache contention against source frames.
- [ ] Match remaining source texture formats.
- [ ] Match remaining rounding at each pass boundary.
- [ ] Resolve SourceAtlas physical-energy/probe-resolution bias; optional furnace checks currently fail at both 4x4 and 8x8.
- [ ] Match source environment/light sampling endpoints and wave reductions.
- [ ] Match the source normalized exclusive probe CDF, full-precision reuse weights and per-cell reuse-count sampling gate.
- [ ] Match source previous-depth reconstruction and motion/exposure adapters.
- [ ] Match reflection boundary taps, cleanup update behavior and remaining thresholds.
- [ ] Build a harness with identical scene, material, camera and sampling inputs.
- [ ] Compare full frames and temporal sequences with the pinned source implementation.
- [ ] Compare multiple scenes with shared reference lighting and quantify image error.
- [ ] Measure repeated performance and temporal stability on the same hardware.
- [ ] Pass a requirement-by-requirement completion audit before declaring 1:1 parity.
