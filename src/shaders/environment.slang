// AMD Capsaicin lights/box_sampling.hlsl and light_sampling.hlsl, pinned in
// THIRD_PARTY_NOTICES.md. Hardened black-map handling and matching PDF descent.
bool has_environment() { return any(p.sky.rgb > 0.0) || p.environment.x > 0.0; }
#ifndef GI_GRID_ENVIRONMENT
#define GI_GRID_ENVIRONMENT 0
#endif
bool grid_environment_enabled() {
#if GI_GRID_ENVIRONMENT
    return source_probe_projection()&&has_environment();
#else
    return false;
#endif
}
uint grid_light_count() {return p.scene_info.y+uint(grid_environment_enabled());}
bool grid_environment_light(uint light) {return grid_environment_enabled()&&light==p.scene_info.y;}
float3 environment_rotate(float4 q,float3 v) {
    return v+2.0*cross(q.xyz,cross(q.xyz,v)+q.w*v);
}
float3 environment_local_radiance(float3 direction,float level) {
    if(p.environment.x<=0.0) {return p.sky.rgb;}
    return safe_radiance(p.sky.rgb+p.environment.x*environment_map.SampleLevel(environment_sampler,direction,level).rgb);
}
float3 environment_radiance(float3 direction) {
    return environment_local_radiance(environment_rotate(p.environment_rotation,direction),0.0);
}
float3 environment_radiance_cone(float3 direction,float solid_angle) {
    let level=select(solid_angle>0.0,log2(max(solid_angle/(4.0*PI),1e-30))+p.environment.w-1.0,0.0);
    return environment_local_radiance(environment_rotate(p.environment_rotation,direction),max(level,0.0));
}
float grid_environment_weight(float3 normal,bool oriented) {
#if GI_GRID_ENVIRONMENT
    var radiance=float3(0.0);var count=0u;
    for(var axis=0u;axis<3u;axis++) {
        if(oriented) {
            if(normal[axis]==0.0) {continue;}
            var direction=float3(0.0);direction[axis]=sign(normal[axis]);
            radiance+=environment_local_radiance(direction,max(p.environment.w-1.0,0.0));count++;
        } else {
            var direction=float3(0.0);direction[axis]=1.0;
            radiance+=environment_local_radiance(direction,max(p.environment.w-1.0,0.0));
            radiance+=environment_local_radiance(-direction,max(p.environment.w-1.0,0.0));count+=2u;
        }
    }
    return luminance(radiance)*(4.0*PI/float(max(count,1u)));
#else
    return 0.0;
#endif
}
static const float3 ENVIRONMENT_FACES[6]={
    float3(1,0,0),float3(-1,0,0),float3(0,1,0),float3(0,-1,0),float3(0,0,1),float3(0,0,-1)
};
float3 environment_box_position(float2 uv,uint face) {
    let normal=ENVIRONMENT_FACES[face];
    let up=select(abs(normal.y)>0.999,float3(0,0,normal.y),float3(0,1,0));
    return normal-cross(up,normal)*(uv.x*2.0-1.0)+up*(1.0-uv.y*2.0);
}
float2 environment_box_uv(float3 v,out uint face) {
    let a=abs(v);var uv=float2(0);var major=0.0;
    if(a.z>=a.x && a.z>=a.y) {
        face=select(v.z<0.0,5u,4u);major=a.z;
        uv=float2(select(v.z>0.0,-v.x,v.x),-v.y);
    } else if(a.y>=a.x) {
        face=select(v.y<0.0,3u,2u);major=a.y;
        uv=float2(v.x,select(v.y>0.0,-v.z,v.z));
    } else {
        face=select(v.x<0.0,1u,0u);major=a.x;
        uv=float2(select(v.x>0.0,v.z,-v.z),-v.y);
    }
    return uv*(0.5/major)+0.5;
}
float4 environment_child_mass(uint face,int2 offset,float width,float level) {
    var mass=float4(0);
    for(uint i=0u;i<4u;i++) {
        let uv=(float2(offset)+float2(i&1u,i>>1u)+0.5)/width;
        // A floor keeps all children reachable and avoids zero conditional PDFs.
        mass[i]=max(luminance(environment_local_radiance(environment_box_position(uv,face),level)),1e-7);
    }
    return mass;
}
float environment_face_mass(uint face) {
    return max(luminance(environment_local_radiance(ENVIRONMENT_FACES[face],p.environment.w-1.0)),0.0);
}
float4 sample_environment_importance(float2 samples) {
    var cdf=float[6](0,0,0,0,0,0);var sum=0.0;
    for(uint i=0u;i<6u;i++) {sum+=environment_face_mass(i);cdf[i]=sum;}
    if(sum<=1e-20) {
        // A black map still has a valid normalized sampling distribution.
        let z=1.0-2.0*samples.y;let radius=sqrt(max(1.0-z*z,0.0));
        return float4(radius*cos(2.0*PI*samples.x),radius*sin(2.0*PI*samples.x),z,1.0/(4.0*PI));
    }
    let target=min(samples.y,0.99999994)*sum;var face=0u;
    while(face<5u && target>=cdf[face]) {face++;}
    let previous=select(face>0u,cdf[max(face,1u)-1u],0.0);
    let mass=cdf[face]-previous;
    var r=float2(samples.x,clamp((target-previous)/mass,0.0,0.99999994));
    var pdf=mass/sum;var offset=int2(0);var width=1.0;
    for(int level=int(p.environment.w)-2;level>=0;level--) {
        offset*=2;width*=2.0;
        let m=environment_child_mass(face,offset,width,float(level));
        let rows=float2(m.x+m.y,m.z+m.w);let py=rows.x/(rows.x+rows.y);
        let y=select(r.y>py,1u,0u);let px=m[y*2u]/rows[y];let x=select(r.x>px,1u,0u);
        let probability_y=select(y==0u,py,1.0-py);let probability_x=select(x==0u,px,1.0-px);
        r=float2((r.x-select(x==0u,0.0,px))/max(probability_x,1e-20),
                 (r.y-select(y==0u,0.0,py))/max(probability_y,1e-20));
        r=clamp(r,0.0,0.99999994);
        pdf*=probability_x*probability_y;offset+=int2(x,y);
    }
    let local=normalize(environment_box_position((float2(offset)+r)/width,face));
    let cosine=dot(ENVIRONMENT_FACES[face],local);
    pdf*=width*width/(4.0*cosine*cosine*cosine);
    let inverse=float4(-p.environment_rotation.xyz,p.environment_rotation.w);
    return float4(environment_rotate(inverse,local),pdf);
}
float environment_importance_pdf(float3 direction) {
    let local=environment_rotate(p.environment_rotation,direction);uint face;
    let uv=clamp(environment_box_uv(local,face),0.0,0.99999994);
    var sum=0.0;for(uint i=0u;i<6u;i++) {sum+=environment_face_mass(i);}
    if(sum<=1e-20) {return 1.0/(4.0*PI);}
    var pdf=environment_face_mass(face)/sum;var offset=int2(0);var width=1.0;
    // Descend the same conditional probabilities as the sampler. Using only
    // leaf luminance/sum disagrees with the clamped children of dark mip nodes.
    for(int level=int(p.environment.w)-2;level>=0;level--) {
        offset*=2;width*=2.0;
        let m=environment_child_mass(face,offset,width,float(level));
        let child=uint2(floor(uv*width))-uint2(offset);
        pdf*=m[child.x+2u*child.y]/(m.x+m.y+m.z+m.w);offset+=int2(child);
    }
    let cosine=dot(ENVIRONMENT_FACES[face],local);
    return pdf*width*width/(4.0*cosine*cosine*cosine);
}
float4 sample_environment(float3 normal,float2 samples) {
    if(p.environment.y==2.0) {return sample_environment_importance(samples);}
    if(p.environment.y==0.0) {
        let z=1.0-samples.y;let radius=sqrt(max(1.0-z*z,0.0));let phi=2.0*PI*samples.x;
        let direction=normalize(mul(probe_frame(normal),float3(radius*cos(phi),radius*sin(phi),z)));
        return float4(direction,1.0/(2.0*PI));
    }
    let radius=sqrt(samples.x);let phi=2.0*PI*samples.y;
    let direction=normalize(mul(probe_frame(normal),float3(radius*cos(phi),radius*sin(phi),sqrt(1.0-samples.x))));
    return float4(direction,max(dot(normal,direction),0.0)/PI);
}
float environment_pdf(float3 normal,float3 direction) {
    if(p.environment.y==2.0) {return environment_importance_pdf(direction);}
    if(dot(normal,direction)<=0.0) {return 0.0;}
    return select(p.environment.y==0.0,1.0/(2.0*PI),dot(normal,direction)/PI);
}
