// AMD Capsaicin GI-1.2 material_sampling/material_evaluation equations.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
float4 ggx_rotation_to_z(float3 normal) {
    // QuaternionRotationZ in quaternion.hlsl. Keep the source's antipodal
    // branch so blue-noise samples produce the same oriented GGX directions.
    return select(normal.z>=-0.99999,normalize(float4(normal.y,-normal.x,0.0,1.0+normal.z)),float4(1.0,0.0,0.0,0.0));
}
float3 ggx_rotate(float4 rotation,float3 direction) {
    let axis=rotation.xyz;
    return 2.0*dot(axis,direction)*axis+(rotation.w*rotation.w-dot(axis,axis))*direction
        +2.0*rotation.w*cross(axis,direction);
}
float3 ggx_bounded_normal(float alpha, float3 view, float2 samples) {
    let stretched = normalize(float3(alpha * view.xy, view.z));
    let phi = 2.0 * PI * samples.y;
    let s = 1.0 + sign(1.0 - alpha) * length(view.xy);
    let k = (1.0 - alpha * alpha) * s * s / (s * s + alpha * alpha * view.z * view.z);
    let b = select(view.z > 0.0, k * stretched.z, stretched.z);
    let z = -b * samples.x + 1.0 - samples.x;
    let radius = sqrt(clamp(1.0 - z * z, 0.0, 1.0));
    let m = float3(radius * cos(phi), radius * sin(phi), z) + stretched;
    return normalize(float3(alpha * m.xy, m.z));
}
float ggx_ndf(float alpha_squared, float nh) {
    if (nh < 0.0) { return 0.0; }
    let denominator = (1.0 - nh * nh) / (alpha_squared + 1e-5) + nh * nh;
    return 1.0 / (PI * alpha_squared * denominator * denominator);
}
float ggx_bounded_pdf(float alpha, float alpha_squared, float nh, float3 view) {
    let axy = alpha * view.xy; let length_squared = dot(axy, axy);
    let t = sqrt(length_squared + view.z * view.z);
    let d = ggx_ndf(alpha_squared, nh);
    if (view.z >= 0.0) {
        let s = 1.0 + sign(1.0 - alpha) * length(view.xy);
        let k = (1.0 - alpha_squared) * s * s / (s * s + alpha_squared * view.z * view.z);
        return d / max(2.0 * (k * view.z + t), 1e-20);
    }
    return d * (t - view.z) / max(2.0 * length_squared, 1e-20);
}
float ggx_visibility_reciprocal(float alpha_squared, float nl, float nv) {
    let r = 1.0 - alpha_squared;
    return (abs(nl) + sqrt(alpha_squared + r * nl * nl))
        * (abs(nv) + sqrt(alpha_squared + r * nv * nv));
}
float3 ggx_sample_weight(float alpha, float3 view, float3 light, float3 f0) {
    if (light.z <= 0.0) { return float3(0.0); }
    let h = normalize(view + light); let a2 = alpha * alpha;
    let fresnel = f0 + (float3(1.0) - f0) * pow(1.0 - clamp(abs(dot(h, view)), 0.0, 1.0), 5.0);
    let pdf = ggx_bounded_pdf(alpha, a2, clamp(h.z, -1.0, 1.0), view);
    return fresnel * ggx_ndf(a2, h.z) * light.z
        / max(ggx_visibility_reciprocal(a2, light.z, view.z) * pdf, 1e-20);
}
float3 diffuse_compensation(float3 f0, float dot_hv) {
    let grazing=pow(1.0-clamp(abs(dot_hv),0.0,1.0),5.0);
    let fresnel=f0+(float3(1.0)-f0)*grazing;
    return (float3(1.0)-fresnel)*1.05*(1.0-grazing);
}
float3 ggx_specular_direction(float3 normal,float3 view,float roughness) {
    let smoothness=clamp(1.0-roughness,0.0,1.0);
    let factor=smoothness*(sqrt(smoothness)+roughness);
    return normalize(lerp(normal,reflect(-view,normal),factor));
}
float brdf_specular_probability(float3 f0,float dot_hv,float3 albedo) {
    let fresnel=f0+(float3(1.0)-f0)*pow(1.0-clamp(abs(dot_hv),0.0,1.0),5.0);
    let specular=luminance(fresnel);
    let diffuse=luminance(albedo*diffuse_compensation(f0,dot_hv));
    return clamp(specular/max(specular+diffuse,1e-20),0.0,1.0);
}
