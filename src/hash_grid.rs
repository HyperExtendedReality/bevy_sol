//! AMD GI-1.2 directional tile layout. See THIRD_PARTY_NOTICES.md.

/// Fixed hash buckets and 1/2/4/8-square directional tiles with up to four mips.
#[derive(Clone, Debug)]
pub struct HashGridCacheConfig {
    pub num_buckets: u32,
    pub tiles_per_bucket: u32,
    pub tile_cell_ratio: u32,
    /// Upstream screen-space cell-size option, converted with the camera FOV.
    pub cell_size_pixels: f32,
    pub max_sample_count: f32,
    pub max_multibounce_sample_count: f32,
    /// Upstream stochastic thinning of secondary-bounce rays. Default: 0.7.
    pub discard_multibounce_ray_probability: f32,
}
impl Default for HashGridCacheConfig {
    fn default() -> Self {
        Self {
            num_buckets: 1 << 14,
            tiles_per_bucket: 1 << 4,
            tile_cell_ratio: 8,
            cell_size_pixels: 32.0,
            max_sample_count: 16.0,
            max_multibounce_sample_count: 16.0,
            discard_multibounce_ray_probability: 0.7,
        }
    }
}
impl HashGridCacheConfig {
    pub fn validate(&self) -> Result<(), &'static str> {
        if !self.num_buckets.is_power_of_two()
            || !(16..=65536).contains(&self.num_buckets)
            || !self.tiles_per_bucket.is_power_of_two()
            || !(1..=256).contains(&self.tiles_per_bucket)
            || ![1, 2, 4, 8].contains(&self.tile_cell_ratio)
            || self.num_buckets * self.tiles_per_bucket > 1 << 20
            || !self.cell_size_pixels.is_finite()
            || !(0.1..=1024.0).contains(&self.cell_size_pixels)
            || [self.max_sample_count, self.max_multibounce_sample_count]
                .iter()
                .any(|v| !v.is_finite() || !(1.0..=128.0).contains(v))
            || !self.discard_multibounce_ray_probability.is_finite()
            || !(0.0..=1.0).contains(&self.discard_multibounce_ray_probability)
        {
            return Err("invalid tiled hash-grid dimensions or sampling limits");
        }
        Ok(())
    }
    pub(crate) fn tiles(&self) -> u32 {
        self.num_buckets * self.tiles_per_bucket
    }
    pub(crate) fn cells_per_tile(&self) -> u32 {
        (0..4).map(|mip| (self.tile_cell_ratio >> mip).pow(2)).sum()
    }
    pub(crate) fn bytes(&self) -> u64 {
        // Header, compact updated-tile list, tile metadata, packed direct/indirect
        // mip values, and integer direct/indirect mip-zero accumulation scratch.
        (16 + u64::from(self.tiles())
            * (5 + 4 * u64::from(self.cells_per_tile())
                + 8 * u64::from(self.tile_cell_ratio.pow(2))))
            * 4
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn upstream_tile_layout_and_memory_are_preserved() {
        let c = HashGridCacheConfig::default();
        assert_eq!(c.tiles(), 262144);
        assert_eq!(c.cells_per_tile(), 85);
        assert_eq!(c.bytes(), 898629696);
        assert!(c.validate().is_ok());
        for (ratio, count) in [(1, 1), (2, 5), (4, 21), (8, 85)] {
            assert_eq!(
                HashGridCacheConfig {
                    tile_cell_ratio: ratio,
                    ..c.clone()
                }
                .cells_per_tile(),
                count
            );
        }
        assert!(
            HashGridCacheConfig {
                tile_cell_ratio: 16,
                ..c
            }
            .validate()
            .is_err()
        );
    }
}
