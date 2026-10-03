@group(0) @binding(21) var scene_tlas: acceleration_structure;
fn trace_impl(o: vec3<f32>, d: vec3<f32>, far: f32, any_hit: bool) -> Hit {
    let flags = select(0u, RAY_FLAG_TERMINATE_ON_FIRST_HIT, any_hit);
    var query: ray_query;
    rayQueryInitialize(&query, scene_tlas, RayDesc(flags, 0xffu, p.cache_config.z, far, o, d));
    while rayQueryProceed(&query) {
        let candidate = rayQueryGetCandidateIntersection(&query);
        if candidate.kind == RAY_QUERY_INTERSECTION_TRIANGLE {
            let triangle = p.scene_info.x * 2u + candidate.primitive_index * TRIANGLE_WORDS;
            if material_visible(triangle, candidate.barycentrics) { rayQueryConfirmIntersection(&query); }
        }
    }
    let h = rayQueryGetCommittedIntersection(&query);
    if h.kind == RAY_QUERY_INTERSECTION_NONE { return Hit(far, MISSING, vec2(0.0)); }
    return Hit(h.t, p.scene_info.x * 2u + h.primitive_index * TRIANGLE_WORDS, h.barycentrics);
}
