// Use packed conversion intrinsics without requiring native 16-bit arithmetic.
uint pack2x16float(float2 v) { return packHalf2x16(v); }
float2 unpack2x16float(uint v) { return unpackHalf2x16ToFloat(v); }
float4 unpack4x8unorm(uint v) { return unpackUnorm4x8ToFloat(v); }
