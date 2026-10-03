// AMD Capsaicin GI-1.2 material_sampling/material_evaluation equations.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
fn ggx_bounded_normal(alpha: f32, view: vec3<f32>, samples: vec2<f32>) -> vec3<f32> {
    let stretched = normalize(vec3(alpha * view.xy, view.z));
    let phi = 2.0 * PI * samples.y;
    let s = 1.0 + sign(1.0 - alpha) * length(view.xy);
    let k = (1.0 - alpha * alpha) * s * s / (s * s + alpha * alpha * view.z * view.z);
    let b = select(stretched.z, k * stretched.z, view.z > 0.0);
    let z = -b * samples.x + 1.0 - samples.x;
    let radius = sqrt(clamp(1.0 - z * z, 0.0, 1.0));
    let m = vec3(radius * cos(phi), radius * sin(phi), z) + stretched;
    return normalize(vec3(alpha * m.xy, m.z));
}
fn ggx_ndf(alpha_squared: f32, nh: f32) -> f32 {
    if nh < 0.0 { return 0.0; }
    let denominator = (1.0 - nh * nh) / (alpha_squared + 1e-5) + nh * nh;
    return 1.0 / (PI * alpha_squared * denominator * denominator);
}
fn ggx_bounded_pdf(alpha: f32, alpha_squared: f32, nh: f32, view: vec3<f32>) -> f32 {
    let axy = alpha * view.xy; let length_squared = dot(axy, axy);
    let t = sqrt(length_squared + view.z * view.z);
    let d = ggx_ndf(alpha_squared, nh);
    if view.z >= 0.0 {
        let s = 1.0 + sign(1.0 - alpha) * length(view.xy);
        let k = (1.0 - alpha_squared) * s * s / (s * s + alpha_squared * view.z * view.z);
        return d / max(2.0 * (k * view.z + t), 1e-20);
    }
    return d * (t - view.z) / max(2.0 * length_squared, 1e-20);
}
fn ggx_visibility_reciprocal(alpha_squared: f32, nl: f32, nv: f32) -> f32 {
    let r = 1.0 - alpha_squared;
    return (abs(nl) + sqrt(alpha_squared + r * nl * nl))
        * (abs(nv) + sqrt(alpha_squared + r * nv * nv));
}
fn ggx_sample_weight(alpha: f32, view: vec3<f32>, light: vec3<f32>, f0: vec3<f32>) -> vec3<f32> {
    if light.z <= 0.0 { return vec3(0.0); }
    let h = normalize(view + light); let a2 = alpha * alpha;
    let fresnel = f0 + (vec3(1.0) - f0) * pow(1.0 - clamp(abs(dot(h, view)), 0.0, 1.0), 5.0);
    let pdf = ggx_bounded_pdf(alpha, a2, clamp(h.z, -1.0, 1.0), view);
    return fresnel * ggx_ndf(a2, h.z) * light.z
        / max(ggx_visibility_reciprocal(a2, light.z, view.z) * pdf, 1e-20);
}
