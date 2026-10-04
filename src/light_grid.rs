/// Streamed-grid reservoir merge policies from Capsaicin.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LightGridMerge {
    Random,
    #[default]
    WithoutReplacement,
    WithReplacement,
}
/// GPU light-grid bounds, reservoir allocation, and sampling policy.
#[derive(Clone, Debug)]
pub struct LightGridConfig {
    pub max_cells_per_axis: u32,
    pub reservoirs_per_cell: u32,
    pub merge: LightGridMerge,
    pub resample: bool,
    pub centroid_build: bool,
    /// Eight directional reservoir sets per cell, selected by the normal's signs.
    pub octahedron_sampling: bool,
    /// Weight punctual lights by approximate light/cell volume overlap.
    pub cell_overlap: bool,
    /// Build large light lists with 128 cooperating threads per reservoir.
    pub parallel_build: bool,
}
impl Default for LightGridConfig {
    fn default() -> Self {
        Self {
            max_cells_per_axis: 16,
            reservoirs_per_cell: 64,
            merge: LightGridMerge::WithoutReplacement,
            resample: false,
            centroid_build: false,
            octahedron_sampling: false,
            cell_overlap: false,
            parallel_build: false,
        }
    }
}
impl LightGridConfig {
    pub(crate) fn validate(&self) -> Result<(), &'static str> {
        if !(1..=32).contains(&self.max_cells_per_axis)
            || !(1..=256).contains(&self.reservoirs_per_cell)
        {
            return Err("invalid streamed light-grid capacity");
        }
        Ok(())
    }
    /// Maximum GPU allocation for the configured grid, including its bounds.
    pub fn bytes(&self) -> u64 {
        (24 + u64::from(self.max_cells_per_axis.pow(3))
            * u64::from(self.reservoirs_per_cell)
            * 4
            * if self.octahedron_sampling { 8 } else { 1 })
            * 4
    }
}
