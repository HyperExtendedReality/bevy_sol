// AMD Capsaicin GI-1.2 ReprojectGI/FilterGI and gi_denoiser.hlsl.
// Copyright (c) 2025 Advanced Micro Devices, Inc. MIT; see THIRD_PARTY_NOTICES.md.
// Previous world positions replace the source's previous depth unprojection.
// Separate input/output images preserve the original two-pass history schedule.
float4 gi_denoiser_sanitize(float4 color) {
    color=clamp(color/(float4(1.0)+color),float4(0.0),float4(1.0));
    let finite=color/max(float4(1.0)-color,float4(1e-4));
    return select(finite==finite,finite,float4(0.0));
}
float gi_denoiser_depth(Surface s) {return max(dot(p.camera.xyz-s.position,p.camera_direction.xyz),1e-6);}
float2 gi_denoiser_moments(int2 pixel) {return unpack2x16float(asuint(moments.Load(int3(pixel,0)).x));}
float4 gi_denoiser_accumulate(float4 lighting,float4 color,float2 uv,float alpha_blend) {
    if (color.w>0.0 || lighting.w<1.0) {lighting+=float4(color.rgb,select(color.w>0.0,1.0,-1.0));}
    let vignette_uv=uv*(float2(1.0)-uv.yx);let vignette=pow(15.0*vignette_uv.x*vignette_uv.y,0.25);
    let max_count=max(lerp(4.0,8.0*min(abs(lighting.w),8.0),alpha_blend)*vignette,1.0);
    if (lighting.w>max_count) {lighting*=max_count/lighting.w;}
    return lighting;
}
[shader("compute")][numthreads(8,8,1)]
void reproject_gi(uint3 gid : SV_DispatchThreadID) {
    let pixel=gid.xy;if (any(pixel>=p.viewport.zw)) {return;}
    let coord=int2(pixel);let s=surface(pixel);
    if (!s.valid) {output_diffuse[coord]=float4(0.0);output_specular[coord]=float4(0.0);output_position[coord]=float4(asfloat(pack2x16float(float2(0.0,-0.125))),0.0,0.0,0.0);return;}
    let color=raw_diffuse.Load(int3(coord,0));var lighting=float4(0.0);var color_delta=0.0;var alpha_blend=1.0;
    let uv=(float2(pixel)+0.5)/float2(p.viewport.zw);let old_uv=reproject_surface(pixel,s.position);
    if ((p.frame.y&1u)==0u && all(old_uv>float2(0.0)) && all(old_uv<float2(1.0))) {
        var cell_size=length(p.camera.xyz-s.position)*p.reflection_thresholds.w;
        if (p.camera.w!=0.0) {cell_size=footprint(s,pixel)/float(p.screen.z);}
        cell_size*=lerp(1.0,5.0,pow(1.0-max(dot(normalize(p.camera.xyz-s.position),s.normal),0.0),6.0));
        var weight=0.0;
        for(var y=-1;y<=1;y++) {for(var x=-1;x<=1;x++) {
            let st=old_uv+float2(x,y)/float2(p.viewport.zw);
            let tap=int2(clamp(floor(st*float2(p.viewport.zw)),float2(0.0),float2(p.viewport.zw)-1.0));
            let c=previous_diffuse.Load(int3(tap,0));let normal=previous_normal.Load(int3(tap,0));let position=previous_position.Load(int3(tap,0));
            if (c.w<1.0 || position.w==0.0 || all(normal.xyz==float3(0.0))) {continue;}
            if (length(s.position-position.xyz)<cell_size && dot(s.normal,normal.xyz)>0.95) {
                let subpixel=length(floor(st*float2(p.viewport.zw))+0.5-old_uv*float2(p.viewport.zw));
                let w=clamp(1.0-subpixel*0.707107,0.0,1.0);
                color_delta+=w*gi_denoiser_moments(tap).x;lighting+=w*c;weight+=w;
            }
        }}
        if (weight>0.0) {
            let sign_delta=sign(color_delta);
            color_delta=gi_denoiser_sanitize(float4(abs(color_delta)/weight)).x*sign_delta;
            lighting=gi_denoiser_sanitize(lighting/weight);
        }
        if (color.w>0.0) {
            let luma_a=luminance(color.rgb);let luma_b=luminance(lighting.rgb/max(lighting.w,1.0));
            color_delta=lerp(color_delta,luma_a-luma_b,1.0/8.0);
            alpha_blend=clamp(1.0-abs(color_delta)/max(luma_b,1e-4),0.0,1.0);
        }
    }
    let blur_mask=max(8.0-lighting.w,0.0);
    lighting=gi_denoiser_accumulate(lighting,color,uv,alpha_blend);
    var specular=float4(0.0);
    if (p.options.w!=0u) {
        let albedo=reflection_directional_albedo(s);
        if (s.roughness>p.reflection_filter.w) {specular=float4(lighting.rgb/max(lighting.w,1.0)*albedo,1.0);}
        else {let reflection=reflections[reflection_full_index(2u,pixel)];specular=float4(reflection.rgb/max(reflection.w,1.0)*albedo,reflection.w);}
    }
    output_diffuse[coord]=lighting;output_specular[coord]=specular;
    // Source delta/mask images are R16_FLOAT. Preserve their quantization across
    // the store rather than relying on an optimizable local pack/unpack pair.
    output_position[coord]=float4(asfloat(pack2x16float(float2(color_delta,blur_mask/8.0))),0.0,0.0,0.0);
}
void filter_gi(uint2 pixel,int2 direction) {
    if (any(pixel>=p.viewport.zw)) {return;}
    let coord=int2(pixel);let s=surface(pixel);var lighting=raw_diffuse.Load(int3(coord,0));
    let mask=gi_denoiser_moments(coord).y*8.0;
    let radius=select(mask>0.0,int(max(mask,1.0)+0.5),0);
    if (s.valid && radius>0) {
        var weight=1.0;var color=lighting.rgb/max(lighting.w,1.0);let center_depth=gi_denoiser_depth(s);
        for(var r=-radius;r<=radius;r++) {
            let tap=clamp(coord+r*direction,int2(0),int2(p.viewport.zw)-1);
            let c=raw_diffuse.Load(int3(tap,0));if (!(c.w>0.0)) {continue;}
            let neighbor=surface(uint2(tap));let depth=gi_denoiser_depth(neighbor);
            let difference=1.0-center_depth/depth;
            let depth_factor=exp2(-select(lighting.w>0.0,200.0,20.0)*abs(difference));
            let normal_factor=pow(max(dot(neighbor.normal,s.normal),0.0),4.0);
            let w=depth_factor*select(lighting.w>0.0,normal_factor,1.0);
            color+=w*c.rgb/max(c.w,1.0);weight+=w;
        }
        lighting.rgb=color/weight*max(lighting.w,1.0);
    }
    var specular=raw_specular.Load(int3(coord,0));
    if (s.valid && direction.y>0 && p.options.w!=0u && s.roughness>p.reflection_filter.w) {
        specular=float4(lighting.rgb/max(lighting.w,1.0)*reflection_directional_albedo(s),1.0);
    }
    output_diffuse[coord]=lighting;output_specular[coord]=specular;
}
[shader("compute")][numthreads(8,8,1)]
void filter_gi_x(uint3 gid : SV_DispatchThreadID) {filter_gi(gid.xy,int2(1,0));}
[shader("compute")][numthreads(8,8,1)]
void filter_gi_y(uint3 gid : SV_DispatchThreadID) {filter_gi(gid.xy,int2(0,1));}
