# Radiance Cascades + Two-Level Radiance Cache

The default renderer now uses surface radiance cascades with world-space
triangle tracing. This is an intentional replacement of the GI-1.2 probe
reconstruction/ReSTIR-reuse path, not an AMD Radiance Cascades implementation.
Other GI-1.2 parity requirements remain tracked in [the inventory](gi12-parity.md).

## Architecture

1. Visible surface probes retain the screen-space cache, reprojection and LRU.
   Cascade levels use progressively coarser probe grids and finer equal-solid-angle
   sphere grids. Rays trace contiguous world-space distance intervals.
2. The persistent world-space hash cache supplies outgoing secondary-surface
   lighting, including the retained multibounce updates. Uncached cascade hits
   evaluate fresh direct lighting rather than reading an empty cache as black.

Interval geometry is traced before world-cache updates. A rotating, bounded
subset of hits from refreshed surface probes seeds the existing direct and
multibounce visibility streams, within the original ray-buffer capacity. A
separate shading pass consumes those hits after cache updates. Cascade mode no
longer dispatches legacy probe importance preparation or `trace_probes`.
Query slots are cleared before each phase, including unused tail slots.

Each interval stores RGB radiance and scalar transmittance. Coarse-to-fine merge
uses `near.rgb + near.transmittance * far.rgb`, with transmittances multiplied.
Opaque near hits block far radiance. Spatial interpolation rejects incompatible
surface normals/planes and validates visibility between the actual angular-ray
interval boundaries. A real continuation ray is used when no upper probe is
compatible. These extra visibility rays are included in the performance budget.
The last interval supplies the environment boundary condition.
Receiver irradiance is integrated with cosine weights, without GI-1.2's
source-atlas normalization. Rough reflections reuse directional cascade radiance;
sharp reflections retain the ray-traced GGX path.

Fresh light-grid RIS remains a direct-light sampler. It is not temporal/spatial
ReSTIR reuse, and is not the cascade solver. ReSTIR passes and its large table
allocation are disabled when cascades are active. The reference estimator is
retained for matched benchmarks with `radiance_cascades: None`.

## Configuration

`HybridGiConfig::radiance_cascades` defaults to three levels, a 4x4 base sphere
grid and a first interval of 0.5 world units. Each level doubles screen-probe
spacing and angular side length. The final interval reaches `max_ray_distance`.
Configuration is validated before plugin installation; per-view allocations are
checked against device limits. Histories and cascade storage are camera-local.

On a 16x16 base probe grid, each of the three levels allocates 4096 interval records.
Directions in the originating surface's inward hemisphere terminate without
traversal; diffuse/glossy surface receivers consume the outward hemisphere.
Raw/merged intervals, traced-hit data and probe metadata consume 605952 bytes. Edge dimensions
round upward, so odd viewports can require more rays per upper level.
Hash-cache lookup uses the full probe-to-hit ray distance, including the interval
start offset, so splitting a ray does not silently change its distance class.
Cascade mode reads indirect radiance from the finest hash-cache cell: climbing
indirect mips blended lit and shadowed surfaces across an opaque blocker. Direct
radiance retains its sample-count-driven mip filtering, and the reference mode
retains both original filters. This prevents the observed indirect-mip leak;
it does not establish that all cache-cell or thin-surface leakage is eliminated.

Cascade tile updates preserve direct and indirect cells that received no new
sample. The source tile-wide update decays those neighbors even when only a
different cell was queried; bounded cascade query scheduling now treats missing
observations separately from valid black samples. Black observations still
update the estimate. Reference mode retains the pinned decay equation. Tile
lifetime and scene/environment invalidation are unchanged; this adds no buffers
or passes. Stale-cell behavior during moving occlusion still needs broader tests.

## Acceptance Checklist

- [x] Configurable cascade layout, interval bounds and bounded allocations.
- [x] Separate raw and merged interval storage and descending merge dispatches.
- [x] World-space geometry tracing implemented for ray-query and software backends.
- [x] Retain screen-probe and persistent world-radiance cache levels.
- [x] Native bounded cache-query, streamed-light bounds and persistent multibounce readback on both backends.
- [x] Default cascade path bypasses ReSTIR reuse and table allocation.
- [x] Directional reconstruction for diffuse and rough glossy receivers.
- [x] 2856 native production direction/inverse and interval/nested-merge comparisons against independent f64 values.
- [x] 30036 additional native angular/spatial stencil and normal-biased boundary comparisons against independent f64 values.
- [x] Native spatial/angular interpolation and visibility-boundary fixtures on both backends.
- [x] Existing rendered emitter, opaque/masked occlusion, material and animation regression on both backends.
- [x] Existing software/hardware stochastic-blend blocker regression (transparent, fractional and opaque alpha).
- [ ] Broader thin-geometry/occlusion-boundary and camera-history acceptance.
- [x] Existing diffuse/GGX furnace: software uniform sky and hardware cubemap; hardware rotated diffuse receivers.
- [ ] Wider angular-resolution/orientation and nonuniform-environment energy comparisons.
- [ ] Multiscene image/error and temporal-noise comparisons against the reference.
- [x] Linear HDR mean/variance/drift capture and guarded reference-comparison harness.
- [ ] Resolve measured HDR mismatch/temporal variation without using a biased reference as ground truth.
- [ ] Repeated matched GPU/CPU timing and memory measurements.
- [ ] Demonstrate better performance/quality; tune or revise the design if evidence disagrees.

Performance and quality superiority are **not established**. Surface placement,
angular discretization and coarse-probe interpolation still require validation.
The [benchmark evidence](cascade-benchmarks.md) records matched Cornell timings
and visible limitations: the 4x4 budget is faster than ReSTIR-on in the initial
run, but slower than ReSTIR-off and visibly coarser. Higher angular resolution
improves the capture. The latest corrected 8x8 run is close to the historical
ReSTIR-on timing, but repeated matched measurements and fidelity/error checks
are still missing.
The new HDR capture reports 33.64% receiver mean-image NRMSE versus ReSTIR-off,
with 1.48% temporal variation versus 0.45%. SourceAtlas itself fails an added
analytic furnace check (4x4: 0.288330; 8x8: 0.540039; both versus 0.416667 expected); this is not an
independent accuracy baseline. See the benchmark report for scope and commands.
The initial rendered test exposed opaque-blocker leakage. Spatial and angular
boundary-visibility validation fixed that unchanged regression on both backends.
Software uniform-environment and hardware cubemap furnaces passed: Lambertian mean 0.416016 versus
0.416667 expected; GGX roughness 0.1/0.35/0.75 remained within the existing analytic
tolerances. A subsequent quadrature check exposed orientation-dependent bias;
cosine normalization now preserves constant radiance across orientations. The
hardware cubemap test also passes for X-facing and diagonal diffuse receivers
(means 0.416016 and 0.415831 versus 0.416667 expected). None of these tests establishes
superiority over the reference estimator.

Shared cascade-hit cache updates subsequently exposed an opaque-alpha leak in
the hardware blend regression (mean 0.012882, required below 0.001). Disabling
multibounce isolated indirect transport; restricting only indirect cache lookup
to the finest cells passed the unchanged full hardware blend regression with
multibounce enabled. The software blend regression also passes (opaque receiver
mean 0.000886, below the unchanged 0.001 threshold). Broader occlusion coverage
remains required for this revision; this is not proof of universally leak-free
cache transport.

References: [Radiance Cascades theory](https://github.com/Raikiri/RadianceCascadesPaper),
[AMD GI-1.2](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin#gi-12).

## Native Reconstruction Checks

With `SLANGC` set and `WGPU_BACKEND=vulkan`:

```text
cargo test --test radiance_cascades -j 1 -- --ignored --nocapture
cargo test --lib gpu::cascade_tests -j 1 -- --ignored --nocapture --test-threads=1
```

The first command compares 32892 production GPU math results with independent
f64 values: directions, interval composition, angular wrapping/pole clamping,
spatial edge clamping and normal-biased interval boundaries. The second reads
production cascade buffers in an odd-sized viewport with a 0.12-unit thin box.
It reconstructs valid-parent merges independently in f64, using a separate slab
intersection against the fixture boxes to reject occluded angular boundaries.
It also checks exact unit-sky continuation values for analytically clear fallback
rays, opaque/terminal interval preservation, bounded query streams and persistent
multibounce values. Set `BEVY_SOL_TEST_HARDWARE=1` to repeat on hardware ray queries;
leave it unset for software traversal.

Both backends pass 21642 independently reconstructed valid-parent merges and
37923 rejected boundary samples with nonzero spatial weight in each 24-frame
fixture. The black-base variant additionally passes 1551 exact clear-ray sky
fallbacks, with multibounce disabled and no persisted indirect samples.

Fallback-hit BRDF/cache shading is not proven by the unit-sky check. Black base
color and zero F0 do not eliminate the retained Schlick grazing term, so treating
every such hit as zero radiance would be an invalid oracle. These fixtures are
also not multiscene image/noise or upstream full-frame parity comparisons.

Cascade hit shading requires a populated direct-cache estimate, not merely an
allocated tile. An allocated tile with zero samples now falls back to direct
shading while retaining any populated indirect estimate; a populated black
direct estimate remains valid. The native hash fixture checks these cases,
nonzero radiance/count division, missing tiles and unchanged
reference-path tile-presence behavior. This does not establish convergence or
fix the measured image/variation gap. The HDR numbers above precede this cache
fallback correction and the reference shading-normal correction.
