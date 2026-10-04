# Third-party notices

The GI-1.2 architecture and algorithm reference is AMD Capsaicin:
https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin

Reference commit: 914b91596cd119eda85fbc1d3c7ee6ac391b1452.
Files inspected: gi1.cpp, gi1.h, gi1.comp, gi1_shared.h, screen_probes.hlsl,
hash_grid_cache.hlsl, glossy_reflections.hlsl, world_space_restir.hlsl, gi1.frag,
and gi_denoiser.hlsl under src/core/src/render_techniques/gi1. Additional adapted
equations come from hash.hlsl, pack.hlsl, random_number_generator.hlsl,
material_evaluation.hlsl, material_sampling.hlsl, reservoir.hlsl,
light_sampling.hlsl, light_sampling_volume.hlsl, light_evaluation.hlsl,
box_sampling.hlsl, sampling/quaternion/SH/transform helpers,
brdf_lut.comp, the light_sampler_grid_stream component, and
blue_noise_sampler.hlsl/blue_noise_sampler_samples.h. The original blue-noise
tables are included losslessly in src/data/gi12-blue-noise.bin. The adaptation uses
Rust and Slang and includes
material/full-descriptor validation and portable software traversal specific to
this crate. This notice preserves the original project's MIT license.

Copyright © 2023-2025 Advanced Micro Devices, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files(the “Software”), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions :

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
