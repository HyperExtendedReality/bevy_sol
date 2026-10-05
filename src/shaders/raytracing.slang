[[vk::binding(21, 0)]] RaytracingAccelerationStructure scene_tlas;
Hit trace_impl_range(float3 origin, float3 direction, float near, float far, bool any_hit) {
    RayDesc ray;
    ray.Origin = origin; ray.Direction = direction;
    ray.TMin = near; ray.TMax = far;
    RayQuery<RAY_FLAG_NONE> query;
    let flags=(any_hit ? RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH : RAY_FLAG_NONE) |
        (source_alpha_testing_disabled() ? RAY_FLAG_FORCE_OPAQUE : RAY_FLAG_NONE);
    query.TraceRayInline(scene_tlas, flags, 0xffu, ray);
    while (query.Proceed()) {
        if (query.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE) {
            let triangle = p.scene_info.x * 2u + query.CandidatePrimitiveIndex() * TRIANGLE_WORDS;
            if (material_ray_visible(triangle, query.CandidateTriangleBarycentrics(),query.CandidateTriangleFrontFace())) {
                query.CommitNonOpaqueTriangleHit();
            }
        }
    }
    if (query.CommittedStatus() == COMMITTED_NOTHING) { return Hit(far, MISSING, float2(0.0)); }
    return Hit(query.CommittedRayT(), p.scene_info.x * 2u + query.CommittedPrimitiveIndex() * TRIANGLE_WORDS,
        query.CommittedTriangleBarycentrics());
}
