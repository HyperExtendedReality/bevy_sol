float3 cascade_direction(float2 uv) {
    let z=1.0-2.0*uv.y;let radius=sqrt(max(1.0-z*z,0.0));let phi=6.283185307179586*uv.x;
    return float3(radius*cos(phi),radius*sin(phi),z);
}
float2 cascade_direction_uv(float3 direction) {
    return float2(frac(atan2(direction.y,direction.x)/6.283185307179586+1.0),clamp((1.0-direction.z)*0.5,0.0,1.0));
}
float4 cascade_merge_interval(float4 near,float4 far) {
    return float4(near.rgb+near.a*far.rgb,near.a*far.a);
}
float cascade_bilinear_weight(float2 blend,uint sample) {
    return ((sample&1u)==0u ? 1.0-blend.x : blend.x)*(sample<2u ? 1.0-blend.y : blend.y);
}
uint2 cascade_angular_sample(float2 uv,uint side,uint sample,out float weight) {
    let coord=uv*float(side)-0.5;let low=int2(floor(coord));
    weight=cascade_bilinear_weight(frac(coord),sample);
    return uint2((low.x+int(sample&1u)+int(side))%int(side),clamp(low.y+int(sample>>1u),0,int(side)-1));
}
uint2 cascade_spatial_sample(float2 coord,uint2 dimensions,uint sample,out float weight) {
    weight=cascade_bilinear_weight(frac(coord),sample);
    return uint2(clamp(int2(floor(coord))+int2(sample&1u,sample>>1u),int2(0),int2(dimensions)-1));
}
float3 cascade_boundary(float3 position,float3 normal,float bias,float3 direction,float distance) {
    return position+normal*bias+direction*distance;
}
