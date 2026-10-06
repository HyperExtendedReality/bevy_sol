# Validation — bevy_sol 0.2

Validated through **2026-10-05**, Bevy 0.19.1, Windows, NVIDIA GeForce RTX 4070 Laptop
GPU, Vulkan, wgpu 29.0.4, Slang 2026.19 and the custom `bevy_slang` crate.
AMD reference commit: `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
This records measured behavior, not completed upstream parity.

## 2026-10-05 GI-1.2 baseline

The renderer now runs the GI-1.2 screen-probe/cache pipeline as its sole transport
architecture, including source probe sampling, filtering, SH reconstruction and
optional world-space reservoir resampling. Exact upstream parity remains open.

Validation after cleanup: all-target tests passed (23 CPU unit tests and three
example checks), all eight production Slang variants passed storage-stride and
uniform-offset checks, and native hash-cache and ReSTIR fixtures passed. The
ReSTIR fixture now stores its scenario selector independently of the production
projection flags, so its bilateral rejection case cannot change the lookup RNG.
The rendered software probe regression with resampling enabled passed emission,
blocking, analytic lights, scene/history edits and mirror reflection checks.
The compensated diffuse/GGX furnace passed, including two rotated receivers.
Formatting, clippy with warnings denied, and whitespace checks passed.

The source specular-material override also has native and rendered coverage.
Composition checks include a nonzero specular input, pure-metal albedo and the
combined albedo override. Native checks verify gamma RGB10 reservoir packing,
F0 0.04 secondary diffuse compensation, zero specular BRDF/sample weight and
the five-draw PCG sequence. ReSTIR target checks pass at 4x4 and 8x8 probe
resolutions, including black-albedo fallback and invalid-light rejection.
The software transport regression with resampling and the specular override
enabled passed material/history edits, emission, blocking and analytic lights.
Its metallic receiver mean was 0.7177, with diffuse GI remaining present through
reflection toggles, viewport changes, jitter and orthographic projection.
These checks map the GI option; they do not establish renderer-wide or full-frame
upstream equivalence.

Native material checks now vary reflectance and metallicity independently,
verifying source F0 0.04 across primary and secondary helpers and multibounce.
Composition retains source diffuse compensation with glossy tracing disabled.
GGX checks verify the separate squared-alpha floor at six roughness values,
the bounded-cap PDF using unclamped alpha squared, signed grazing/back-facing
visibility, below-surface half-vector rejection and the singular PDF endpoint.
The hardware transport regression with 64-direction probes, ReSTIR resampling
and full-resolution reflections passed; emitter/point/spot/directional receiver
means were 0.5243/0.3933/0.3195/0.1781, and the metallic reflection receiver mean
was 1.0. All eight production shader variants passed storage/uniform layout
checks. Clippy with warnings denied and formatting/whitespace checks passed.

## 2026-10-05 optional reconstruction inputs

The `GiReconstructionInputs` camera component maps the source combined
AO/bent-normal attachment and optional near-field irradiance. The native
hash/probe fixture checks source SH cone coefficients against independent
double-precision equations across three normals and six AO values, including
out-of-range AO clamping, probe interpolation weights and the missing-probe early return.
Source diffuse reconstruction now keeps irradiance units through denoising;
composition and rough reflection fallback apply `1/pi` afterward.

The rendered input fixture passed AO-zero suppression, bent-normal hemisphere
selection, known near-field irradiance/exposure composition, full-target pixel
coordinates at an offset viewport, invalid inputs and component removal.
The production composition fixture passed both estimator unit conventions.
All eight production shader variants passed the attachment-binding, storage
stride and uniform-offset checks. Hardware ReSTIR transport with 64-direction
probes and full-resolution reflections passed, with emitter/point/spot/directional
means 0.5346/0.3955/0.3205/0.1780 and mirror mean 1.0. All-target tests passed
(23 CPU tests and three example checks), as did clippy with warnings denied.
These are local mechanism/regression checks. Upstream AO/near-field producers,
identical-input frame comparisons and SourceAtlas furnace discrepancies remain
outside this evidence.

## 2026-10-05 ray setup and probe sky arithmetic

SourceAtlas now uses the pinned integer/additive position offset, zero TMin and
the `1e9` GI closest-hit range. Selected point/spot/area lights retain their
sampled position for the source unnormalized shadow segment ending at
`1 - 1/16384`; directional/environment shadows use float maximum. Probe spawn
radiance is half-packed before fixed-point blending, and source distance
quantization retains the upstream unclamped conversion.

The native hash/probe fixture passed signed-zero, 1/32 boundary and large-position
offset checks, both shadow range conventions, half-infinity conversion against
the pinned quantizer, both directional filter passes with zero/infinite/finite
distances, source sky reprojection and the distinct resident/reprojected predicates
at negative, zero, positive and NaN dot products. NaN direction remapping and
atomic ordering still require matched backend/frame evidence.

The rendered regression initially exposed orthographic self-intersection: depth
reconstruction error was larger than the source position offset. The existing
validated primary query now retains its triangle index; orthographic surface
positions are recovered on that plane along the viewing ray before tracing.
This adds four bytes per pixel without another query. Hardware transport with
64-direction probes, ReSTIR and full-resolution reflections passed after the fix,
including viewport, jitter and orthographic changes: emitter/point/spot/directional
means 0.5279/0.3595/0.2896/0.1512, mirror 1.0. Software 16-direction ReSTIR
transport also passed (0.4078/0.2301/0.1745/0.0946, mirror 1.0), as did the optional
reconstruction-input fixture and hardware native scheduling/alpha checks.
All eight production shader variants, all-target tests (23 CPU and three example
checks), clippy with warnings denied, formatting and whitespace checks passed.
This is mechanism/regression evidence, not completed upstream image parity.

SourceAtlas furnace checks still fail the 5% energy tolerance. With software
traversal, the Lambertian means were 0.283511 at 4x4 directions and 0.515575 at
8x8 directions, versus 0.416667 expected (about -32% and +24%). Both runs stop
at the diffuse assertion before checking glossy energy. This remains an open
resolution-dependent discrepancy; matched upstream frames are needed before
changing the source estimator.

## 2026-10-05 probe half storage boundaries

Source probe radiance and SH conversion now match the raw pinned `packHalf4`
instead of clamping/sanitizing before conversion. Native checks passed signed
values, 60032 and 65504, half overflow, positive/negative infinity, NaNs,
subnormals, ties-to-even and signed zero; compensated sanitation is checked
separately. Source sample directions now cross a dedicated dispatch in the
existing ray record and are decoded without renormalization. Spawn radiance
crosses packed shared storage before fixed-point blending. Native checks verify
both storage boundaries, including half rounding of a unit direction.

The initial local pack/unpack expression failed the native rounding check:
the decoded direction retained the original float values even though the emitted
SPIR-V contained both conversions. The storage boundaries fix that observed
failure without requiring native 16-bit arithmetic or extra buffer allocation.
This verifies local conversion behavior; source backend NaN payload identity and
full-frame equivalence remain unverified. The probe CDF audit also identified an
open mismatch: the current inclusive scan uses half-rounded reuse values, while
the source builds a normalized exclusive scan from full-precision reuse and
selects guidance using per-cell sample counts.

## 2026-10-04 continuation

Triangle packets now preserve the source mesh-buffer positions needed by
stochastic alpha hashing instead of substituting world-space hit positions.
The packet stride grows from 16 to 20 words; world-space traversal positions,
normal/material tokens and emitter links retain their existing offsets.
Static/morph-only vertices exclude the instance transform; skinned vertices
apply `instance_inverse * weighted_skin_matrix` after morphing, matching the
pinned `generate_animated_vertices.comp`. CPU tests verify static/morph/skin
coordinates and refits with independent world/mesh positions and preserved
metadata. Both software and hardware native fixtures passed, including GPU
barycentric interpolation of deliberately distinct mesh coordinates across
all 960 alpha cases. The 22 CPU unit tests, serial all-target tests, all eight
production shader variants, clippy and formatting/whitespace checks passed.
Rendered ReSTIR transport passed on software (16 directions) and hardware
(64 directions, full-resolution atrous reflections), including masks,
deformation and history edits. Emitter/point/spot/directional receiver means
were 0.3879/0.2900/0.2328/0.1225 and 0.5256/0.3842/0.3158/0.1779 respectively;
both mirror means were 1.0. This verifies the required blend coordinate input
and widened-packet regression coverage, not stochastic blending or full parity.
The compensated 64-direction cubemap/split-reflection furnace also passed:
Lambertian mean 0.418382 versus 0.416667, and GGX means
0.416016/0.403487/0.261623 versus 0.416423/0.409126/0.261222.

Source opaque/masked material classification now uses an explicit bit beside
the existing UV-channel flags, rather than inferring type from cutoff sign.
This fixes negative and NaN mask cutoffs being treated as opaque or bypassing
masked backface rejection. Source masks retain strict alpha greater than 0.5;
compensated mode retains its cutoff behavior. The new CPU packet test verifies
all cutoff bits, mask identity and independent UV0/UV1 channel selection.
The software native matrix now covers 960 cases, including negative and NaN
masked cutoffs, and passed with the existing scheduler/cache/reflection checks.
Serial all-target tests and clippy passed.
The same 960-case native matrix passed on hardware queries. All eight production
shader variants, formatting and whitespace checks passed; the packet and uniform
strides are unchanged.
The alpha-enabled hardware 64-direction full-resolution atrous/ReSTIR regression
passed with emitter/point/spot/directional means 0.5392/0.3903/0.3154/0.1777 and
mirror mean 1.0, including transparent-mask traversal and material/history edits.

The pinned mesh shader confirms that source stochastic alpha hashes the
interpolated mesh-buffer position before its instance transform, not the traced
world position. This identifies an additional required input for the unimplemented
blend path; no world-position substitute has been added.

`source_disable_alpha_testing` now maps source force-opaque GI closest-hit and
shadow traversal, including hardware `RAY_FLAG_FORCE_OPAQUE`. Auditing the pinned
`src/core/src/ray_tracing/trace_ray.hlsl` also corrected source masked-alpha
comparison to strict alpha greater than 0.5 and source single-sided masked
backface rejection. Opaque and disabled-alpha traversal bypass that rejection;
compensated mode retains its configured inclusive cutoff and ignores the option.
The native fixture traces actual front/back closest and shadow rays through one
masked triangle across all 16 flag combinations, two sidedness states, four
cutoffs and five alpha values (640 cases). All cases passed, including equality
at 0.5 and separation of source thresholds from Bevy cutoffs. The existing 216
scheduler/reflection cases, 153-tile candidate fixture and composition flag checks
also passed. Clippy passed. Blended geometry and primary raster alpha handling
are still separate unimplemented source-parity requirements.
The fixture can now select hardware ray queries with `BEVY_SOL_TEST_HARDWARE=1`.
It builds a non-opaque single-triangle BLAS/TLAS and runs the same alpha matrix
against real queries. All 640 hardware cases passed as well, explicitly verifying
front/back orientation rather than relying on a closed blocker. All eight
production shader variants, serial all-target tests, clippy, formatting and
whitespace checks passed. Alpha-disabled software 16-direction split/ReSTIR
transport passed with emitter/point/spot/directional means
0.3927/0.2838/0.2323/0.1234. Alpha-disabled hardware 64-direction full-resolution
atrous/ReSTIR transport passed with means 0.5325/0.3970/0.3162/0.1779. Both runs
require the transparent masked blocker to reduce transport below 0.001 when
alpha testing is disabled, and both mirror means were 1.0.
The alpha-enabled hardware 64-direction full-resolution atrous/ReSTIR rerun
also passed, requiring the transparent blocker to leave transport above 0.08.
Emitter/point/spot/directional means were 0.5224/0.3914/0.3163/0.1772 and the
mirror mean was 1.0.
The software native fixture rerun after the hardware harness addition passed
all 640 alpha cases and the existing scheduler/cache/reflection checks again.

`source_disable_albedo_textures` now maps the source final-composition override,
not a blanket texture-sampling disable. It sets primary diffuse albedo to 0.3
and primary F0 to zero, retaining LUT grazing response and diffuse compensation.
Secondary material evaluation and primary probe guides remain unchanged; the
option is ignored in compensated projection. The native scheduler fixture passed
all 216 cases and its eight source/direct/albedo flag combinations. Independent
expected values distinguish overridden diffuse/F0/directional albedo from the
unchanged secondary material albedo.

The new `composition` test renders the production Slang fragment into an RGBA32F
target and reads back its actual color. All 20 flag/reflection-compensation/
confidence-normalization cases passed against independent CPU equations,
including compensated projection with the override bit set. This tests viewport,
material quantization, confidence, ambient occlusion and exposure composition
without scene or transport noise. Clippy passed serially after a parallel run
reported dependency lookup errors; no generated files were deleted. An interrupted
shader-variant run failed to write a temporary SPIR-V output; disk space was
subsequently checked and was available, so this was not treated as a shader error.
The retry passed all eight production shader variants. Serial all-target tests,
formatting and whitespace checks passed. Software 16-direction split/ReSTIR
transport passed with emitter/point/spot/directional means
0.4083/0.2867/0.2358/0.1229. Hardware 64-direction full-resolution atrous/ReSTIR
transport passed with means 0.5166/0.3923/0.3159/0.1781; both mirror means were 1.0.
The warning-free production composition fixture rerun also passed. Complete
renderer parity, specular-disable and alpha-disable options remain open.
The compensated 64-direction cubemap/split furnace passed with Lambertian
0.418382 and GGX 0.416016/0.404119/0.261623 at roughness 0.1/0.35/0.75.

Source firefly marking now uses surface sky/roughness rejection for centers,
negative-distance marking, full-pixel box radius and strict luminance thresholds.
Neighbors are rejected for roughness/bounds, not sky or missing ray queue validity.
Source atrous reconstruction also no longer uses queue validity as a neighbor
gate, and source split reconstruction uses its roughness-only neighbor gate.
The native fixture deliberately clears every queue-valid bit and varies radiance,
negative hit distance, sky depth and roughness across both reflection resolutions,
frame phases and viewport edges. Its independent CPU oracle checks every flag.
All 216 scheduler/reflection cases and the 153-tile candidate fixture passed
again after the fixture lint cleanup.

All eight production shader variants passed, as did clippy, serial all-target
tests, formatting and whitespace checks. Software 16-direction split/ReSTIR
transport passed with emitter/point/spot/directional means
0.3979/0.2922/0.2332/0.1192. Hardware 64-direction full-resolution atrous/ReSTIR
transport passed with means 0.5325/0.3915/0.3168/0.1785; both mirror means were 1.0.
The compensated 64-direction cubemap/split furnace passed with Lambertian
0.418382 and GGX 0.416016/0.404119/0.261623 at roughness 0.1/0.35/0.75.
These are local regressions, not identical-input upstream comparisons. Source
raster attachments, cleanup boundary/in-place behavior and other inventory gaps
remain unverified or incomplete.

Source reflection format mapping now includes both split planes, all atrous
color/moment intermediates, resolved color/distance, standard deviation and
temporal/history planes. Each RGBA16F write persists packed half words between
dispatches; both diffuse composition paths decode the temporal result, and
history snapshots preserve the stored bits. The native fixture tests every
plane against independent exact FP16 values, including fractional history
counts and snapshot copy. It now explicitly configures reflection stride 1/2;
the old zero stride made reflection indexing invalid. Both valid strides run
the scheduler/ownership matrix, expanding it from 108 to 216 cases. All cases
and the 153-tile candidate fixture passed.

The source ratio reconstruction audit also corrected normalized separable
Gaussian weights, X-major accumulation, positive-weight normalization in final
atrous and split passes, and preservation of the split weighted sum when adding
fallback taps. Native checks compare Gaussian weights with independent f64
equations and distinguish zero/0.0005 final/intermediate normalization. All eight
production shader variants and clippy passed. Serial all-target tests, formatting
and whitespace checks passed. Software 16-direction split/ReSTIR transport passed
with emitter/point/spot/directional means 0.3979/0.2905/0.2366/0.1215. Hardware
64-direction full-resolution atrous/ReSTIR transport passed with means
0.5224/0.3943/0.3172/0.1789; both mirror means were 1.0.
The compensated 64-direction cubemap/split furnace passed with Lambertian
0.418382 and GGX 0.416016/0.404119/0.261623 at roughness 0.1/0.35/0.75.
The combined allocation still reserves float4-sized records; boundary taps,
renderer inputs and matched upstream frame comparisons remain separate gaps.

The direct-lighting option now maps `gi1_use_direct_lighting` for SourceAtlas:
probe/glossy sky and emissive injection and probe temporal feedback are gated,
while indirect reflection history and world-space next-event estimates remain.
Enabled glossy misses use the positive half-float sky distance 65504; disabled
misses retain -1. Native checks cover both source states and compensated flags.
The uniform-sky motion fixture passed with direct injection both enabled and
disabled. The disabled result was 0.0000017294612, below the 1e-4 numerical-floor
tolerance; its sixty-sample history and moving-cache retention remain checked.

Source reflection trace radiance/distance, direction and cleanup planes now
preserve RGBA16F rounding through packed half-float words stored between
dispatches. Native independent expected values verify compressed 2/4 becoming
0.66650390625/0.7998046875, 65519 becoming 65504, direction and cleanup rounding,
and preserved full-float values when the encoder is disabled. A NaN channel
survives source tracing while finite channels survive independently, leaving
sanitization to the source cleanup/temporal stages. All 108 scheduling cases
and the 153-tile cache fixture passed. All eight production shader variants,
clippy, formatting and whitespace checks passed. The initial all-target build
ran out of disk space during parallel linking; a serial `-j 1` retry passed
without deleting files.
Software 16-direction ReSTIR transport passed with emitter/point/spot/directional
means 0.3879/0.2856/0.2413/0.1264. Hardware 64-direction full-resolution transport
passed with means 0.5406/0.3879/0.3170/0.1778; both mirror means were 1.0.
The compensated 64-direction cubemap/split-reflection furnace passed with
Lambertian 0.418382 and GGX 0.416016/0.404039/0.261254 at roughness
0.1/0.35/0.75. Other reflection intermediates still retain full-float storage,
and upstream frame equivalence remains unproven.

Source reflection temporal accumulation now retains the unsanitized current RGB
through the source dual-history equations and applies the pinned
`GIDenoiser_RemoveNaNs`-equivalent per-channel compression/clamp/decompression
only to the final RGB sum. The history count bypasses color sanitization. This
replaces the compensated `safe_radiance` behavior that discarded all RGB when
one component was invalid. Compensated mode keeps its previous pre/post guards.
The native fixture checks `(2, NaN, 4, 7)` becoming `(2, 0, 4, 7)`, preserving
finite channels and count. The 108 scheduling cases and 153-tile candidate
fixture passed, as did clippy.
All eight production shader variants passed. Feedback-disabled ReSTIR transport
passed on software with 16 probe directions (emitter/point/spot/directional means
0.4113/0.2880/0.2399/0.1254) and hardware with 64 probe directions
(0.5224/0.3870/0.3161/0.1775); both mirror means were 1.0. The compensated
64-direction cubemap/split-reflection furnace retained Lambertian 0.418382 and
GGX 0.416016/0.404119/0.261623. All-target tests, formatting and whitespace checks
passed.

Source primary BRDF shading normals now normalize the decoded RGB10 attachment
value, rather than using the Bevy deferred octahedral normal directly. The shared
accessor feeds probe Fresnel layer selection, glossy GGX rotation, ratio-estimator
PDF evaluation and directional-albedo LUT lookup. Denoiser grazing evaluation
uses the same accessor; history details and their rejection arithmetic retain the
unnormalized RGB10 decode. Compensated mode retains its existing normal. A native
non-axis-aligned fixture compares the accessor against independent CPU RGB10
round/decode/normalize arithmetic and requires a measurable difference from the
unquantized input. All 108 scheduling cases and the 153-tile candidate fixture
passed, as did clippy. Quantization is still applied after Bevy deferred decoding;
this does not provide the dedicated source raster shading-normal attachment.
All eight production shader variants passed. Feedback-disabled ReSTIR transport
passed with software 16-direction probes (emitter/point/spot/directional means
0.3979/0.2875/0.2421/0.1226) and hardware 64-direction probes
(0.5166/0.4020/0.3178/0.1767); both mirror means were 1.0. The compensated
64-direction cubemap/split-reflection furnace retained Lambertian 0.418382 and
GGX 0.416016/0.404119/0.261623. All-target tests, formatting and whitespace
checks passed.

Reflection settings now preserve the pinned host's independent half/full-resolution
split radii, firefly marking/cleanup radii and low/high marking thresholds.
The previous shared settings applied half-resolution defaults to full-resolution
rendering. Full resolution now selects source marking radius 2 and cleanup radius 1;
half resolution retains 3 and 2. Both split radii default to 11 and both threshold
pairs to 0/1. Existing unprefixed controls now configure half resolution; new
`full_resolution_*` controls configure full resolution. CPU tests verify exact
source defaults, independent overrides, resolution selection and rejection of
invalid inactive-resolution settings. Uniform selection uses the same tested
method, retaining the production shader layout. All-target tests (19 unit tests)
and clippy passed. Hardware full-resolution 16-direction ReSTIR transport passed
with emitter/point/spot/directional means 0.3823/0.2877/0.2369/0.1231 and mirror 1.0.
The compensated full-resolution 64-direction cubemap/split-reflection furnace
passed with Lambertian 0.418382 and GGX 0.416016/0.403487/0.261623. Formatting
and whitespace checks passed. No shader code or resource strides changed in
this option-mapping correction.

Source firefly cleanup now uses the pinned sample-grid radius directly, including
half-resolution rendering, instead of converting it to a half radius. Source
Gaussian weights multiply the two one-dimensional sample-offset terms, and the
neighbor loop accumulates in source X-major order. Source omits the compensated
valid-sample gate, adds the center value to the retained neighbor sum when total
weight is below 1e-3, and applies `GIDenoiser_RemoveNaNs`-equivalent sanitization
to all four channels. Compensated cleanup retains its converted radius,
full-resolution-offset weights, validity checks and prior normalization behavior.
Native checks verify radius 3 versus 2 at half resolution, weights for offset
(3,2), retained near-zero neighbor contributions, ordinary normalization and
negative hit-distance sanitization. The 108 scheduling cases and 153-tile
candidate fixture passed. Separate cleanup output still intentionally avoids
the upstream in-place read/write race; out-of-bounds texture behavior and
renderer geometry/depth inputs remain different.
All eight production shader variants passed. Feedback-disabled 16-direction
ReSTIR transport passed with software half-resolution reflections
(emitter/point/spot/directional means 0.4113/0.2886/0.2375/0.1247) and hardware
full-resolution reflections (0.3823/0.2868/0.2344/0.1232); both mirror means were
1.0. The compensated 64-direction cubemap/split-reflection furnace retained
Lambertian 0.418382 and GGX 0.416016/0.404119/0.261623. All-target tests, clippy,
formatting and whitespace checks passed.

Source reflection history now follows `ReprojectReflections`: one bilinearly
filtered shading/details normal supplies the common exponential normal weight
for all four gathered depths. All accepted depths retain bilinear color/count;
partial acceptance selects the earliest maximum in source gather order
(-,+)/(+,+)/(+,-)/(-,-), then loads the source integer-UV-plus-offset fallback.
Source clamp sampling replaces UV rejection and omits the compensated material
gate. Compensated mode retains its per-tap normals, material gate and UV checks.
Native checks cover a low-weight reversed normal that must retain bilinear history,
partial-depth acceptance and tied fallback selection, negative-UV clamp sampling,
and complete depth rejection, with zero material identifiers in the previous
positions. The 108 scheduling cases and 153-tile candidate fixture passed.
Previous world-position-derived depth and Bevy shading inputs still differ from
the dedicated upstream textures. The border-spawn inventory was also corrected:
the pinned spawn and patch stages clamp seeds to the viewport just as this port does.
All eight production shader variants passed. Feedback-disabled 16-direction
ReSTIR transport passed on software (emitter/point/spot/directional means
0.3979/0.2933/0.2415/0.1248) and hardware (0.3823/0.2920/0.2355/0.1207), with
mirror 1.0 in both. The compensated 64-direction cubemap/split-reflection furnace
retained Lambertian 0.418382 and GGX 0.416016/0.404119/0.261623. All-target tests,
clippy, formatting and whitespace checks passed.

SourceAtlas now retains world/persistent-probe caches across pose-only scene
revisions, matching the pinned host's hash-clear and probe-allocation conditions:
ordinary animation does not request a cache clear. Material/light/topology history
invalidation remains unchanged; compensated mode retains its pose-triggered clear.
The native motion regression seeds a persistent probe outside the frustum and a
recently touched hash-tile marker, then reads both back over twelve pose updates.
Rigid, skinned and morphed receivers passed on software and hardware traversal:
both source markers persist, Bevy velocity is nonzero, diffuse history stays above
twenty samples and uniform-sky luminance remains stable. These small-motion checks
do not establish moving-scene image equivalence or large-scene performance.
The software compensated rigid-motion regression also passed: the old probe
timestamp is cleared or replaced by a same-frame allocation, and the old hash
marker clears while pixel history persists.
Feedback-disabled 16-direction ReSTIR transport passed after this change on
software (emitter/point/spot/directional means 0.3979/0.2847/0.2403/0.1262) and
hardware (0.4113/0.2839/0.2335/0.1207); both mirror means were 1.0. Material,
light, mask and deformation regressions passed, as did all-target tests, clippy,
formatting and whitespace checks.

Source temporal feedback now separates probe and glossy history rejection,
matching the pinned `PopulateCells` and reflection-hit paths: strict projected
and previous UV bounds, positive projected depth, previous geometry normals,
probe normal dot >0.5 and relative depth error <5%, glossy normal dot >0.95 and
relative depth error <1%. One additional packed geometry-normal plane retains
the previous frame before current primary normals are prepared. Source skips
the compensated current-visibility/material/roughness guards and emission
subtraction. Accepted probe feedback enters the direct-cache accumulator and
the unfiltered probe path, bypassing the shadow trace. Native checks cover both
threshold sets, strict normal/depth endpoints, the previous-normal copy and orthographic
view-depth evaluation. All 108 scheduling cases and the 153-tile candidate test
passed, as did all eight production shader variants and clippy.
Software 16-direction ReSTIR transport with feedback enabled and multibounce
disabled passed: emitter/point/spot/directional means were
0.4106/0.2860/0.2382/0.1220 and mirror 1.0. This does not prove equivalent source
frames: previous world-position history, query-derived primary normals and
Bevy motion/exposure adapters remain different inputs.
Hardware 64-direction ReSTIR transport with feedback enabled passed with means
0.5166/0.3863/0.3180/0.1764 and mirror 1.0. All-target tests, formatting and
whitespace checks passed.
Feedback-disabled software 16-direction ReSTIR transport also passed with means
0.4113/0.2841/0.2350/0.1233 and mirror 1.0.
The compensated 64-direction cubemap/split-reflection furnace retained
Lambertian 0.418382 and GGX 0.416016/0.404119/0.261623.

The follow-up cache audit found and corrected the radiance-reuse reader that
still walked linked lists after the source candidate scatter conversion.
Source radiance reuse now consumes every candidate in the contiguous tile range;
compensated mode retains its linked-list reader without touching source-only
scratch arrays. Cached surface metadata now stores XYZ plus the source packed
snorm10 normal in the fourth word, using normalized decode for ownership and
reconnection frames. Eviction writes this metadata; radiance updates preserve it.
The native fixture checks positive/negative packed-axis bits after real cache
updates, non-axis-aligned packing against a CPU reference, decoding independent
of the redundant float-normal field, and one/two-candidate radiance means of
6/8. All 108 scheduling/ownership cases and the 153-tile scatter check passed.
Software 16-direction ReSTIR transport passed with emitter/point/spot/directional
means 0.3979/0.2888/0.2384/0.1236 and mirror 1.0.
Hardware 64-direction means were 0.5224/0.3977/0.3182/0.1778, with mirror 1.0.
All eight production shader variants, all-target tests, clippy and formatting
passed. Source raster inputs, flattened cache storage and frame-equivalent
atomic ordering remain separate differences; these are not upstream image tests.
The compensated 64-direction cubemap/split-reflection furnace retained
Lambertian 0.418382 and GGX 0.416016/0.404119/0.261623.

Source cached-probe projection now follows `CountScreenProbes` plus exclusive
scan and `ScatterScreenProbes`, replacing source linked-list candidates with
contiguous per-tile ranges. Projection traverses the LRU, rejects exact screen
and near/far boundaries, and maps normalized coordinates to the ceil-sized
tile grid rather than dividing projected viewport pixels by probe spacing.
Native checks cover 153 tiles across two scan blocks, 145 accepted candidates,
many candidates in one tile, reversed LRU mapping, partial viewport dimensions,
and exact/beyond-frustum boundaries. Candidate sets, tile counts and every
exclusive offset are compared against a CPU reference; intra-tile atomic
ordering is not asserted. Existing 108 scheduling/cache-ownership cases passed.
Software 16-direction ReSTIR transport passed with emitter/point/spot/directional
means 0.4113/0.2861/0.2339/0.1250 and mirror 1.0. All-target tests, clippy and
formatting passed. At this stage source packed metadata and matched upstream
frame validation remained incomplete; the metadata follow-up is recorded above.
All eight production shader variants passed. Hardware 64-direction ReSTIR
transport means were 0.5166/0.3959/0.3182/0.1773, with mirror mean 1.0.
The compensated 64-direction cubemap/split-reflection furnace retained
Lambertian 0.418382 and GGX 0.416016/0.404119/0.261623.

The following checks were rerun while implementing source atlas spawn/patch and
reprojection, fixed-point probe reuse, integrated environment RIS and multibounce
BRDF/PDF transport. They supplement, rather than replace, the earlier matrix below.

| Check | Result |
|---|---|
| Native source probe scheduler | 108 combinations of full/quarter/sixteenth mode, Halton frames, one-pixel/odd/partial extents, reset/history/disocclusion/sky; fixed spawn budget, seed ownership and compaction passed |
| Native source sampling/accumulation | Fixed-point quantization, four-channel shadow-preserving blend, full GGX selection, pure radiance-CDF selection with no uniform mixture, incident-radiance weights, claimed-nearest cache inclusion and half-packed matte multibounce BRDF/PDF with survival compensation passed |
| Native environment fixture | 96 configurations covering all three sampling distributions, two rotations, four maps and separate/grid sampling with each merge policy; independent hemisphere energy, PDF agreement and RIS counts passed |
| ReSTIR/hash/light grid fixtures | GPU collision/packing/mip/estimator checks passed; the ReSTIR count scan also covers 32,768 cells and 512 block totals |
| Hardware source transport, 64 directions, ReSTIR enabled | Emitter/point/spot/directional means 0.5317/0.3975/0.3116/0.1765, mirror 1.0; dark phases and geometry/material/texture/deformation invalidation passed |
| Software source transport, 16 directions, ReSTIR enabled | Emitter/point/spot/directional means 0.4090/0.2660/0.2364/0.1215, mirror 1.0; regression phases passed |
| Hardware moving receiver, rigid/skin/morph | Pose-only cache reset preserves compatible reprojected screen-probe and pixel histories; uniform-environment stability passed in all three modes; software rigid/skin also passed |
| Software compensated furnace, raw cubemap plus sky, 64 directions, split reflections | Lambertian mean 0.418382 versus 0.416667; GGX means 0.416016/0.404119/0.261623 versus 0.416423/0.409126/0.261222; all tolerances passed |
| Slang specialization fixture | All eight tracing/texture/direction variants, entry points, uniform offsets and storage strides passed |
| Rust/build checks | `cargo test --all-targets` passed (13 non-GPU unit tests); `cargo clippy --all-targets -- -D warnings`, formatting and whitespace checks passed |

These tests do not establish image or performance equivalence to Capsaicin.

The pinned visibility writer was verified to produce flat face normals from
raster derivatives, separately from smooth/normal-mapped shading normals.
Source glossy geometry-normal decisions now query the scene from the pixel's
near-plane position and use the camera-facing triangle normal when the hit
matches the deferred surface depth. Unmatched surfaces retain the previous
depth-derived fallback. Native checks cover a flat normal distinct from the
authored smooth normal, backface orientation and a wrong-depth hit rejection.
The native probe fixture, all eight shader variants, software/hardware ReSTIR
transport and the compensated furnace passed. Hardware 64-direction emitter/
point/spot/directional means were 0.5242/0.3884/0.3170/0.1765, with mirror 1.0.
The compensated furnace retained Lambertian 0.418382 and GGX
0.416016/0.404119/0.261623. All-target tests, clippy and formatting passed.
These checks preceded the cached primary-normal pass described below. That pass
still uses a query adaptation rather than the source raster normal attachment.

Source primary geometry normals are now prepared once per viewport pixel before
probe scheduling, using the pinned R10G10B10A2_UNORM representation. Matched
visibility hits use camera-facing triangle normals; unmatched surfaces retain
the depth-derived fallback. Probe spawning/history, sampling hemispheres, SH
evaluation and receiver-plane/interpolation weights use this separate input;
material BRDF calculations retain the shading normal. The subsequent source
audit below corrects which input drives denoising and reflection history.
The native fixture checks valid/sky cache writes, exact packed bits, independent
geometry/shading-normal loading and receiver weights with orthogonal normals.
This removes repeated glossy queries but adds one primary trace per valid pixel.
Raster derivatives, depth matching and fallback behavior remain parity gaps.
The 108-case native fixture and all eight production shader variants passed.
Software 16-direction ReSTIR transport passed with emitter/point/spot/directional
means 0.4113/0.2854/0.2400/0.1235; hardware 64-direction means were
0.5325/0.3958/0.3154/0.1766. Mirror mean was 1.0 in both runs. The compensated
64-direction cubemap/split-reflection furnace retained Lambertian 0.418382 and
GGX 0.416016/0.404119/0.261623. All-target tests, clippy and formatting passed.
These regressions do not establish matched upstream image equivalence.

The pinned `ReprojectGI`, `FilterGI` and `ReprojectReflections` kernels read the
shading-normal/details attachments, not the geometry-normal attachment. Their
history and filter decisions now use RGB10-quantized decoded shading normals
without renormalizing them, except for the explicit grazing-angle calculation.
The normal history carrier is RGBA32_FLOAT to avoid a second half-float rounding;
compensated mode explicitly retains its previous half-float history precision.
Native checks use matching geometry normals with orthogonal shading normals,
verify the fourth-power normal weight and non-unit decoded magnitudes, and
write/copy/read a non-axis-aligned shading normal through the GPU history image.
The primary source raster attachments are still absent; quantizing the Bevy
deferred normal does not remove that renderer-input difference.
The updated native fixture and all eight production shader variants passed.
Software 16-direction ReSTIR transport means were 0.3465/0.2909/0.2335/0.1254
for emitter/point/spot/directional lighting; hardware 64-direction means were
0.5224/0.3888/0.3188/0.1777. Mirror mean was 1.0 in both runs. All-target tests,
clippy, formatting and whitespace checks passed.
The compensated 64-direction cubemap/split-reflection furnace retained
Lambertian 0.418382 and GGX 0.416016/0.404119/0.261623.

Source vertex extraction now follows `getNormalTransform`: sign-corrected
cofactor transforms retain unnormalized vertex magnitudes until hit interpolation.
Compensated extraction keeps normalized inverse-transpose vertices. CPU tests
verify nonuniform scale, mirroring and rotation, packed magnitudes, the independent
inverse-transpose-times-absolute-determinant identity, and a measurably different
interpolated result from premature per-vertex normalization. The native
108-case probe fixture checks the scaled packed triangle through `hit_normal`.
Scene tests, the native fixture, software 16-direction ReSTIR transport and the
compensated 64-direction cubemap/split-reflection furnace passed. The furnace
retained Lambertian 0.418382 and GGX 0.416016/0.404119/0.261623. CPU extraction
and Bevy skin/morph processing still replace the source per-instance/GPU pipeline;
this change does not establish full animation or primary-normal parity.
Hardware 64-direction ReSTIR transport also passed, with emitter/point/spot/
directional means 0.5242/0.3915/0.3194/0.1765 and mirror 1.0. All-target tests,
clippy, formatting and whitespace checks passed.

The source MT19937 seed table is now owned by the renderer and bound once as a
shared read-only GPU buffer, instead of copied into each camera's work buffer.
It retains its allocation and values on resolution shrink or camera removal,
regenerates on growth or deterministic-option changes, and ignores seed edits
while nondeterministic mode remains active, matching the pinned component's
owned-buffer policy. CPU lifecycle tests passed alongside the MT vectors.
The native 108-case probe fixture now reads the shared-buffer path and verifies
both MakeRandom overloads and modulo indexing. All eight shader variants passed.
Software 16-direction ReSTIR transport passed with emitter/point/spot/directional
means 0.4112/0.2955/0.2350/0.1210; hardware 64-direction means were
0.5165/0.3908/0.3184/0.1775, with mirror 1.0 in both. The compensated 64-direction
cubemap/split-reflection furnace retained Lambertian 0.418382 and GGX
0.416016/0.404119/0.261623. All-target tests, clippy and formatting passed.
Multiple Bevy views select the largest required table count; stratified-sampler
sharing and std::random_device entropy are not reproduced. These tests are not
a matched upstream sequence or image comparison.

Source environment importance sampling now normalizes the face CDF before
selection, keeps exact CDF ties on the earlier face, uses unclamped remapping,
and accumulates row then column probabilities with the pinned complementary
probability floor of 1e-7. Pixel-area, plane-area, cubic-cosine and face-PDF
conversions follow the source order. Compensated sampling keeps its prior
remapping. The native 96-configuration environment fixture passed, including
32 direction/PDF samples per source configuration against a scalar CPU port,
with CDF and child-boundary samples, sparse maps, black maps and two rotations.
The black-map fallback and exact zero-mass CDF endpoint handling remain
deliberate hardening differences. All eight shader variants, all-target tests,
clippy and formatting passed; this is not bitwise upstream image evidence.

Source evaluated environment importance PDFs now use the pinned
`boxLuminancePDF` leaf estimator, including `nearestSampleBox` ceil snapping,
unclamped leaf luminance, summed face-average luminance and cube Jacobian.
Compensated evaluation retains the clamped hierarchy PDF. The native environment
fixture passed all 96 configurations, with a separate CPU leaf-PDF comparison
for 14 directions across all source/grid configurations. This includes sparse
faces, exact texel boundaries, and both rotations. The retained black-map uniform
fallback is explicitly a hardening difference; sampler CDF/remap guards and
floating-point ordering remain separate parity work.
All eight production Slang variants, all-target tests, clippy, formatting and
whitespace checks passed. Hardware 64-direction ReSTIR transport also passed:
emitter/point/spot/directional means were 0.5256/0.3942/0.3177/0.1758 and mirror
mean was 1.0. These regressions are not a matched upstream image comparison.

Source secondary-hit normals now follow the face-oriented interpolated vertex
normal used by GI-1.2 probe, multibounce and reflection hits. SourceAtlas does
not apply secondary normal maps, reject hits according to material sidedness,
or repair authored normals against the triangle/view hemisphere. Compensated
mode retains those operations. The native 108-case probe fixture checks smooth
barycentric interpolation, a single-sided backface, and authored reversed normals
with a nonzero normal-map index and a valid UV frame. All eight production shader
variants passed. Software 16-direction ReSTIR transport passed with emitter/
point/spot/directional means 0.3926/0.2876/0.2375/0.1238; hardware 64-direction
means were 0.5242/0.4052/0.3180/0.1785, with mirror 1.0 in both runs. The compensated
64-direction cubemap/split-reflection furnace retained Lambertian 0.418382 and
GGX 0.416016/0.404119/0.261623. All-target tests, clippy, formatting and whitespace
checks passed. CPU vertex transformation and primary geometric-normal inputs
remain separate parity gaps; these checks do not establish upstream equivalence.

The subsequent source-cache ownership checks cover cold starts without caching fresh
tiles, old-atlas eviction into newly allocated or existing cache entries, and in-place
radiance updates preserving the cached surface position. Software/hardware transport
regressions passed after separating these paths (16/64 directions, ReSTIR enabled).

The multibounce bypass fixture executes `resolve_hash_bounces` with half-packed
BRDF/PDF values, a survival probability of 0.5 and sixteen queries. Eight short
queries produce immediate red-channel probe contributions of 0.125; eight long
queries produce zero immediate contribution. All sixteen still accumulate into
the indirect cache (count 16, fixed-point red sum 2000). The additional per-ray
probe value increases the ray-record stride to 160 bytes.

The source RNG now uses an uploaded MT19937 seed table matching the pinned
component's deterministic default (5489) and componentwise 1920x1080 minimum.
CPU tests match standard MT19937 vectors for seeds 0, 1 and 5489, including
the 10,000th output. Native shader checks cover both `MakeRandom` overloads,
PCG outputs and modulo table lookup at frames 0, 7 and 255. The full 108-case
probe fixture passed with this table enabled. Production software/hardware
ReSTIR transport also passed after upload wiring: emitter/point/spot/directional
means were 0.3980/0.2856/0.2392/0.1263 (software, 16 directions) and
0.5270/0.3934/0.3176/0.1757 (hardware, 64 directions), with mirror 1.0.
All eight Slang variants and 16 selected unit/compiler tests passed.
These checks validate the RNG primitives, not frame-equivalent compact query
ordering or parallel light-grid reduction.

The subsequent light-grid change matches the source's shared per-reservoir
seed, native-wave prefix-CDF selection and ordered wave-total merge. A scalar
shader oracle checked 432 selected light IDs and target weights, plus total
weights within relative error 1e-6, using uploaded MT19937 seeds at frames
0, 7 and 255. The expanded 2,304-configuration grid fixture passed both source
and compensated modes, all merge policies, resampling, centroid/octahedral/
overlap/parallel options and sparse cells. All eight production Slang variants
compiled after the change; clippy and formatting passed. The source group
barrier is made uniform; equivalence on other hardware wave widths still needs
runtime coverage.

SourceAtlas now skips auxiliary surface-cache allocation, compaction, bounce
tracing, reservoir generation and update stages; the shared descriptor layout
retains one dummy cache entry. Cached probe/reflection lighting uses only the
directional hash cache, and a missing reflection cell retains the source's
no-estimate distance sentinel. Front-facing emissive materials terminate source
reflection transport even when the sampled emission texel is black. The native
108-case probe fixture verifies no auxiliary insertion/mutation, missing-cell
zero lighting, summed-radiance normalization and valid black cache entries.
Software and hardware ReSTIR transport passed after the reduced allocations
(16 directions): emitter/point/spot/directional means were
0.4135/0.2836/0.2377/0.1263 and 0.3823/0.2873/0.2401/0.1267, respectively;
mirror means were 1.0. A software 64-direction run also passed before the
allocation reduction. All eight Slang variants, all-target tests, clippy and
formatting passed. The compensated 64-direction cubemap furnace with split
reflections also passed, retaining Lambertian mean 0.418382 and GGX means
0.416016/0.404119/0.261623. These regressions do not establish upstream image
equivalence.

Source receiver interpolation now shares the four nearest-mask/seed-relative
probe indices and normalized eighth-power weights between diffuse SH and rough
glossy atlas reuse. Native checks cover analytic depth/normal weights
256/258, 1/258, 1/258 and zero, equal-weight relaxed backup with confidence zero,
negative-hemisphere rejection without weight renormalization, and missing-probe
black lighting with confidence one. Source missing probes no longer trace a
diffuse fallback or queue reflection rays; intermediate-roughness sampling uses
blue-noise dimension one, as in InterpolateScreenProbes. The 108-case native
fixture and all eight production shader variants passed. ReSTIR transport
passed in software (16 directions) and hardware (64): emitter/point/spot/
directional means were 0.4112/0.2869/0.2393/0.1279 and
0.5256/0.3924/0.3165/0.1763, respectively, with mirror 1.0.
The compensated 64-direction cubemap/split-reflection furnace retained its
previous Lambertian and GGX means and passed. All-target tests, clippy,
formatting and whitespace checks also passed.

SourceAtlas now appends dense first-hit and multibounce visibility streams,
including emissive first hits, and dense shadow sample IDs for valid ReSTIR
reservoirs. Multibounce uses the first visibility ID as its RNG seed; fresh
reservoirs use the combined visibility ID; temporal resampling uses the compact
shadow ID. Missing reservoirs retain an invalid mapping rather than triggering
another fresh draw. Exhausted hash allocation no longer leaves a traced zero
sample in the source probe cell. The ray-record ABI remains 160 bytes; four
query/mapping words per ray are reserved in the work buffer.
The 108-case native fixture verifies 16 contiguous first-hit IDs, eight
contiguous bounce IDs offset by the first-hit count, 12 contiguous shadow IDs,
round-trip physical-ray mappings and invalid-reservoir gaps. Hardware ReSTIR
transport (64 directions) passed with emitter/point/spot/directional means
0.5256/0.3896/0.3166/0.1763; software transport without ReSTIR (16 directions)
passed at 0.4112/0.2850/0.2369/0.1268. A software ReSTIR run also passed during
wiring. Mirror means were 1.0. The compensated cubemap furnace retained its
previous means. All eight shader variants, all-target tests, clippy, formatting
and whitespace checks passed. Atomic append ordering has not been compared
frame-for-frame with the upstream executable.

Hash-cache lifecycle checks now include a cold frame zero, allocation at
`u32::MAX`, history retention across wrap to frame zero, and 64 concurrent
insertions enqueuing one tile. They verify the update count and direct mip-zero
radiance/count, in addition to the existing packing, mips, temporal and decay
checks. A controlled bucket hole verifies that source lookup stops at the empty
slot while compensated lookup finds the later live tile. The expanded native
fixture passed. Software SourceAtlas/ReSTIR transport (16 directions) passed
with emitter/point/spot/directional means 0.3980/0.2840/0.2386/0.1245 and mirror
1.0. All eight Slang variants, all-target tests, clippy and formatting passed.

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
black maps return finite zero lighting. In the separate/compensated cases,
sampled and evaluated importance PDFs agree within 0.4% for every tested sample.
Source/grid evaluated PDFs are checked against the source leaf formula instead.
The assertions allow 1.5% integration
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
