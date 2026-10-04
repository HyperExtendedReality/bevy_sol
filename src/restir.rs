/// World-space reservoir table from GI-1.2's `WorldSpaceReSTIR`.
#[derive(Clone, Debug)]
pub struct WorldSpaceRestirConfig {
    /// Hash buckets. The upstream default is 262144.
    pub num_cells: u32,
    /// Collision slots per bucket. The upstream default is 16.
    pub entries_per_cell: u32,
    /// Distance/FOV cell footprint in pixels. The upstream default is 16.
    pub cell_size_pixels: f32,
}
impl Default for WorldSpaceRestirConfig {
    fn default() -> Self {
        Self {
            num_cells: 0x40000,
            entries_per_cell: 0x10,
            cell_size_pixels: 16.0,
        }
    }
}
impl WorldSpaceRestirConfig {
    pub(crate) fn validate(&self) -> Result<(), &'static str> {
        if !self.num_cells.is_power_of_two()
            || !(16..=0x40000).contains(&self.num_cells)
            || !(1..=16).contains(&self.entries_per_cell)
            || !self.cell_size_pixels.is_finite()
            || !(1.0..=256.0).contains(&self.cell_size_pixels)
        {
            return Err("invalid world-space ReSTIR table or cell footprint");
        }
        Ok(())
    }
    pub(crate) fn entries(&self) -> u32 {
        self.num_cells * self.entries_per_cell
    }
    /// GPU bytes for both frame tables, scans, packed samples and compaction lists.
    /// `ray_capacity` is the primary probe ray capacity; a second stream holds bounces.
    pub fn bytes(&self, ray_capacity: u32) -> u64 {
        let entries = u64::from(self.entries());
        (16 + 6 * entries + entries.div_ceil(128) + 21 * 2 * u64::from(ray_capacity)) * 4
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn upstream_capacity_and_flattened_layout() {
        let config = WorldSpaceRestirConfig::default();
        assert_eq!(config.entries(), 0x400000);
        assert_eq!(config.bytes(64), (16 + 6 * 0x400000 + 32768 + 21 * 128) * 4);
        assert!(config.validate().is_ok());
        assert!(
            WorldSpaceRestirConfig {
                num_cells: 17,
                ..config.clone()
            }
            .validate()
            .is_err()
        );
        assert!(
            WorldSpaceRestirConfig {
                cell_size_pixels: f32::NAN,
                ..config
            }
            .validate()
            .is_err()
        );
    }
}
