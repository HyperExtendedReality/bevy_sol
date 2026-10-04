#include "gi.slang"
[[vk::binding(26,0)]] RWStructuredBuffer<uint> restir_checks;
[shader("compute")][numthreads(64,1,1)]
void seed_restir_scan(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;if(index>=restir_entries()) {return;}
    restir[restir_table(false)+restir_entries()+index].store(index%7u);
}
[shader("compute")][numthreads(64,1,1)]
void read_restir_scan(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;let entry=index*max(p.screen.x,1u);if(entry>=restir_entries()) {return;}
    restir_checks[index]=restir[restir_table(false)+2u*restir_entries()+entry].load();
}
[shader("compute")][numthreads(64,1,1)]
void insert_restir_checks(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;if(index>=128u) {return;}
    let address=1024u+4u*index;
    let position=float3(asfloat(restir_checks[address]),asfloat(restir_checks[address+1u]),asfloat(restir_checks[address+2u]));
    restir_checks[256u+index]=uint(restir_insert(index,position));
}
[shader("compute")][numthreads(64,1,1)]
void read_restir_insert(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;if(index==0u) {restir_checks[400]=restir[0].load();}
    if(index<restir[0].load()) {restir_checks[512u+index]=restir[restir_values(false)+index].load();}
}
[shader("compute")][numthreads(64,1,1)]
void read_restir_lookup(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x;if(index>=128u) {return;}
    let address=1024u+4u*index;
    let position=float3(asfloat(restir_checks[address]),asfloat(restir_checks[address+1u]),asfloat(restir_checks[address+2u]));
    let entry=restir_find_previous(position);
    restir_checks[768u+index]=entry;
    if(entry!=MISSING) {restir_checks[896u+index]=restir[restir_table(true)+restir_entries()+entry].load();}
    let key=restir_index_and_hash(position,p.restir_sampling.xyz);
    restir_checks[1536u+2u*index]=key.x;restir_checks[1537u+2u*index]=key.y;
}
[shader("compute")][numthreads(1,1,1)]
void seed_restir_resample() {
    let world=float3(0.0,0.0,-1.0);let normal=float3(0,0,1);var rng=pcg_hash(p.frame.x+1u);
    let mode=p.restir.w;let previous_normal=select(mode==1u,-normal,normal);
    restir[restir_normals(false)+127u].store(restir_pack_normal(previous_normal));
    restir_store_reservoir(127u,PackedReservoir(0u,float2(0.2,0.7),select(mode==2u,0.0,4.0),80.0,1.0));
    restir_insert(127u,restir_jitter(world,normal,rng));
}
[shader("compute")][numthreads(1,1,1)]
void check_restir_resample() {
    let world=float3(0,0,-1);let address=restir_samples();
    restir[address].store(0u);restir[address+1u].store(0u);
    restir[address+2u].store(pack2x16float(world.xy));restir[address+3u].store(pack2x16float(float2(world.z,0.0)));
    restir[restir_normals(false)].store(restir_pack_normal(float3(0,0,1)));restir[restir_materials()].store(restir_pack_material(float3(0.5)));
    restir_store_reservoir(0u,PackedReservoir(0u,float2(0.2,0.7),2.0,8.0,1.0));
    restir_resample(0u);let result=restir_load_reservoir(0u,false);
    restir_checks[0]=asuint(result.weight);restir_checks[1]=asuint(result.count);restir_checks[2]=asuint(result.visibility);
    restir_checks[3]=restir_pack_normal(float3(-0.6,0.8,0.0));
    restir_checks[4]=restir_pack_material(float3(0.25,0.5,0.75));
}
[shader("compute")][numthreads(64,1,1)]
void seed_atlas_checks(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x/PROBE_DIRECTIONS;let bin=gid.x%PROBE_DIRECTIONS;if(index>=3u) {return;}
    if(bin==0u) {
        work[0].store(3u);work[WORK_HEADER+index].store(index);
        probes[index].normal=float4(select(index==0u,float3(0,0,1),select(index==1u,float3(0,0,-1),float3(1,0,0))),1.0);
    }
    probes[index].samples[bin]=probe_pack(float4(float((bin%7u)+1u)/4.0,float((bin%11u)+1u)/8.0,float((bin%13u)+1u)/16.0,10.0));
}
[shader("compute")][numthreads(64,1,1)]
void read_atlas_checks(uint3 gid:SV_DispatchThreadID) {
    let index=gid.x/9u;let coefficient=gid.x%9u;if(index>=3u) {return;}
    let value=probe_unpack(probes[index].sh[coefficient]);
    for(var c=0u;c<4u;c++) {restir_checks[4u*gid.x+c]=asuint(value[c]);}
    if(gid.x==0u) {
        for(var i=0u;i<5u;i++) {restir_checks[128u+i]=asuint(probe_empty_cell_backup(float3(64.0),uint[5](0u,1u,32u,63u,64u)[i],64u).x);}
    }
}
[shader("compute")][numthreads(1,1,1)]
void read_cone_checks() {
    let a=float3(0);let b=float3(2,0,0);let c=float3(0,2,0);let uv0=float2(0);let uv1=float2(1,0);let uv2=float2(0,1);let size=float2(256,128);
    restir_checks[0]=asuint(area_light_cone_lod(float3(0,0,1),a,a,b,c,uv0,uv1,uv2,size,0.0));
    restir_checks[1]=asuint(area_light_cone_lod(float3(0,0,1),a,a,b,c,uv0,uv1,uv2,size,0.01));
    restir_checks[2]=asuint(area_light_cone_lod(float3(0,0,100),a,a,b,c,uv0,uv1,uv2,size,0.01));
    restir_checks[3]=asuint(area_light_cone_lod(float3(0,0,100),a,a,b,c,uv0,uv1,uv2,size,1.0));
    restir_checks[4]=asuint(area_light_cone_lod(float3(1,0,1),a,a,b,c,uv0,uv1,uv2,size,0.01));
    restir_checks[5]=asuint(area_light_cone_lod(float3(0,0,1),a,a,b,c,uv0,uv0,uv0,size,0.01));
    restir_checks[6]=asuint(area_light_cone_lod(float3(0,0,-1),a,a,b,c,uv0,uv1,uv2,size,0.01));
}
