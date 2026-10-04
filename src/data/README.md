# GI-1.2 blue-noise tables

`gi12-blue-noise.bin` contains the original Sobol256x256, RankingTiles and
ScramblingTiles arrays, in that order, from AMD Capsaicin commit
`914b91596cd119eda85fbc1d3c7ee6ac391b1452`:
[blue_noise_sampler_samples.h](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/blob/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/components/blue_noise_sampler/blue_noise_sampler_samples.h).

All original uint32 values fit in a byte. This lossless representation uses
327,680 bytes, rather than 1,310,720 bytes. The GPU reads packed bytes from the
immutable tail of the existing reflection buffer. It requires no extra descriptor.
The source SHA-256 of the converted bytes is
`68e7e92a8124ee62bf285c38814ba7044730a756d58c72b2fe1f39e2a6bd25da`.
The importer rejects unexpected counts or values and is reproducible:

```text
node tools/import_blue_noise.mjs target/gi12-reference/blue_noise_sampler_samples.h
```

Copyright (c) 2025 Advanced Micro Devices, Inc. Distributed under the original
MIT license preserved in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
The sampler implements Heitz et al.'s screen-space blue-noise error distribution,
with the source 256-frame golden-ratio animation and optimized tile dimensions.
