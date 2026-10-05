# Cascade Benchmark Evidence

This is an initial engineering baseline, not proof of general superiority.
The goal remains matched visual quality, lower noise and better performance than
the retained GI-1.2/ReSTIR path across representative scenes.

## Reproduce

Run sequentially on the same idle adapter; concurrent GPU work invalidates a
comparison. Set `SLANGC` and `WGPU_BACKEND=vulkan`, then:

```text
cargo run --example cornell -j 1 -- --benchmark --hardware
cargo run --example cornell -j 1 -- --benchmark --hardware --reference
cargo run --example cornell -j 1 -- --benchmark --hardware --restir
cargo run --example cornell -j 1 -- --benchmark --hardware --cascade-angular=8
```

`--benchmark` is headless. It waits for 90 actual GI dispatch measurements, then
collects 300 distinct measurement timestamps, not application startup frames.
It emits per-stage CPU/GPU p50/p95/p99/max values to CSV and captures the same
stationary Cornell scene. Missing GPU timestamps fail the benchmark rather than
being reported as zero. Files are generated in `screenshots/`; each mode has its
own filename. Archive a run's files before repeating it.

The same scene, camera, seed, 640x640 resolution, 8-pixel probe spacing, 64 cache
update directions, four direct samples, multibounce and reflection settings are
used in all modes. `--reference` disables cascades without enabling ReSTIR;
`--restir` explicitly enables the retained world-space ReSTIR implementation.
Only `--cascade-angular=8` changes the cascade angular budget.

## Initial Measurements

Local Vulkan adapter: NVIDIA GeForce RTX 4070 Laptop GPU. Optimized development
profile (crate opt-level 1, dependencies opt-level 3), render diagnostics enabled.
Base checkout `ad30fd368e5f092804a303ef39bfa765ca94c659`, with the uncommitted
cascade implementation and benchmark harness. Not a shipping/release benchmark.

| Transport | GPU p50 ms | GPU p95 ms | GPU p99 ms | Samples |
|---|---:|---:|---:|---:|
| Cascades, 4x4 base sphere | 3.568640 | 3.717120 | 3.794944 | 303 |
| GI-1.2 reference, ReSTIR off | 3.279872 | 3.401728 | 3.471360 | 303 |
| GI-1.2 reference, ReSTIR on | 4.097024 | 4.457472 | 4.558848 | 303 |
| Cascades, 8x8 base sphere | 4.986880 | 5.021696 | 5.051392 | 300 |
| Cascades, 8x8, inward-interval termination | 4.381696 | 4.665344 | 4.734976 | 300 |
| Cascades, 8x8, shared cache-hit queries | 4.237312 | 4.670464 | 4.692992 | 300 |
| Cascades, 8x8, grouped bounds/angular precomputation | 4.112384 | 4.462592 | 4.490240 | 300 |
| Cascades, 8x8, finest-cell indirect-cache lookup | 4.038656 | 4.420608 | 4.494336 | 300 |

The first three runs collected three extra samples while the screenshot completed;
the harness now caps collection at exactly 300. The later rows are subsequent
optimization, not another identical repeat of the fourth row.
The first five captures predate the subsequent correction that supplies total
probe-to-hit distance (rather than interval-local distance) to hash-cache lookup.
They are preserved as development baselines; rerun before judging the current
worktree's performance or rendered output.

At the initial 4x4 budget, cascades is faster than ReSTIR-on but slower than
ReSTIR-off in this scene. Its screenshot has noticeably uneven floor lighting.
The 8x8 budget reduces that visible artifact, but costs more than either reference
mode. Terminating intervals in each surface's inward hemisphere reduces work;
it does not yet establish matched-quality performance superiority.

Per-stage evidence in the first cascade run: interval tracing p50 0.289792 ms,
merge levels 0/1 p50 0.135168/0.139264 ms, retained `trace_probes` p50 0.157696 ms,
`prepare_probe_sampling` p50 0.132096 ms, hash direct population p50 0.253952 ms.
The current cascade path reuses a bounded rotating subset of its traced hits for
world-cache updates, eliminating legacy importance preparation and probe tracing.
Hit metadata adds 16 bytes per interval. The grouped-bounds revision still failed
the hardware opaque-blend multibounce blocker regression; its timing is not an
accepted quality result. Finest-cell indirect lookup passes the unchanged blend
blocker regression on both backends and the persistent-multibounce readback.
Its latest idle-adapter measurement is close to the historical ReSTIR-on timing,
not evidence of a statistically significant speedup. The captured walls are
darker (red sample 117/23/18, green 29/101/25 versus prior 127/26/20 and 32/108/27);
matched image/error and convergence checks are needed before judging fidelity.

## Remaining Gates

- [ ] Repeat each configuration in interleaved order with stable thermal/power state.
- [ ] Release-profile and instrumentation-overhead measurements.
- [ ] Software-backend and larger/animated/off-screen scenes.
- [ ] Independent high-sample reference images and HDR error metrics.
- [ ] Temporal variance and bias comparisons, including thin occluders.
- [ ] Complete per-view memory accounting, not just scene-buffer memory.
- [x] Shared cascade cache-hit queries retain bounded multibounce streams, stored indirect radiance and existing blend occlusion regressions on both backends.
- [ ] Achieve comparable quality and lower cost; no unconditional speed claim yet.

## Linear HDR Quality Capture

`--no-multibounce` isolates single-bounce transport and adds `-single-bounce` to
the capture name. `--quality-warmup=N` selects 128..8192 actual GI measurements
before capture (default 512). Nondefault warmups have distinct output names;
binary comparison rejects mismatched warmups. These controls are diagnostics,
not production quality recommendations.

Run quality captures separately from timing: RGBA32Float readback and CPU
statistics perturb performance. `--quality` disables tonemapping and FXAA but
keeps the shared camera/exposure and GI settings. It waits for 512 actual GI
dispatch measurements, then accumulates 128 RGB readbacks with f64 Welford moments.
Temporal variation includes convergence drift, not just stationary sampling noise;
the difference between the first/second half means is reported separately.

```text
cargo run --example cornell -j 1 -- --quality --hardware --reference
cargo run --example cornell -j 1 -- --quality --hardware --restir --quality-compare=screenshots/cornell-room-reference-hardware-quality.bin
cargo run --example cornell -j 1 -- --quality --hardware --cascade-angular=8 --quality-compare=screenshots/cornell-room-reference-hardware-quality.bin
```

Use `--scene=thin` to add a 0.12-unit interior occluder, and compare against that
scene's own `cornell-thin-reference-hardware-quality.bin`. `--quality-frames=N`
accepts even counts from 2 through 4096; compared captures must use equal counts.
Binary headers reject mismatched scene IDs, dimensions, sample counts, warmup
and common capture/scene revision. Metadata records adapter, backend, transport,
exposure and build profile. Bright HDR values above 1 are retained and asserted.

Initial room captures on the same RTX 4070 Laptop Vulkan adapter, dev-opt1:

These captures precede the empty-tile cascade fallback and reference SH
shading-normal corrections. They remain historical evidence, not measurements
of the latest shader revision; repeat matched captures before drawing a current
performance/quality conclusion.

| Mode | Receiver Mean Luminance | Relative Temporal Variation | Relative Half-Window Drift | Mean-Image NRMSE vs ReSTIR-Off |
|---|---:|---:|---:|---:|
| Reference, ReSTIR off | 0.153975 | 0.4511% | 0.5271% | -- |
| Reference, ReSTIR on | 0.139677 | 0.4392% | 0.5238% | 9.1507% |
| Cascades, 4x4 (default) | 0.094792 | 1.4698% | 1.7332% | 43.8130% |
| Cascades, 8x8 | 0.104704 | 1.4835% | 2.1803% | 33.6438% |

The receiver region excludes the visible emitter. CSV files also report fixed
left/right wall, floor and box regions. Relative variation/drift use the candidate
mean-image RGB RMS as denominator; NRMSE uses the comparison mean-image RGB RMS.
These data contradict a matched-quality/reduced-variation claim for the current
8x8 cascade configuration. They are single static-scene development captures,
not repeated trials or error against independent path-traced truth.

The reference is not ground truth: the optional SourceAtlas reference furnace
runs fail the unchanged 5% physical-energy gate (4x4: 0.288330; 8x8: 0.540039;
both versus 0.416667 expected). Reproduce with `BEVY_SOL_TEST_HARDWARE=1`,
`BEVY_SOL_TEST_REFERENCE=1`, `BEVY_SOL_TEST_SOURCE_PROJECTION=1`, then
`cargo test --test furnace -j 1 -- --ignored --nocapture`.
Set `BEVY_SOL_TEST_PROBE_DIRECTIONS=8` for the second case. Probe-resolution
dependence makes the current SourceAtlas path unsuitable as an energy oracle.
The default compensated furnace remains a separate gate. Do not fix the HDR
difference by blindly scaling cascade radiance to the SourceAtlas reference.

The thin-box scene confirms the comparison problem: reference receiver mean
0.136430 and relative variation/drift 0.4913%/0.5838%; cascades8 mean 0.092563,
variation/drift 2.1484%/2.9454%, mean-image NRMSE 32.9216%. These are another
single development capture pair, not independent accuracy evidence. Quality
captures and the analytic furnace probes may run concurrently; none of their
timestamps is used as a performance measurement.

Binary format: ASCII magic `SOLHDR01`, six little-endian u32 fields (width,
height, samples, scene ID, common revision, warmup), then three top-down RGB f32
planes: temporal mean, unbiased temporal variance, signed second-half minus
first-half mean. CSV/TXT sidecars provide region metrics and capture metadata.
