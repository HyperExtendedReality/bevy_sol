use bevy::math::UVec2;

/// Surface radiance cascades trace world-space intervals from visible probes.
/// Each level doubles probe spacing and angular resolution in each dimension.
#[derive(Clone, Debug)]
pub struct RadianceCascadesConfig {
    /// 1..=5 levels. The last interval extends to `max_ray_distance`.
    pub levels: u32,
    /// Base equal-solid-angle sphere grid side length: 2, 4 or 8.
    pub angular_resolution: u32,
    /// Length of the first world-space interval, in world units.
    pub first_interval: f32,
}

impl Default for RadianceCascadesConfig {
    fn default() -> Self {
        Self {
            levels: 3,
            angular_resolution: 4,
            first_interval: 0.5,
        }
    }
}

impl RadianceCascadesConfig {
    pub fn validate(&self, max_distance: f32) -> Result<(), &'static str> {
        if !(1..=5).contains(&self.levels)
            || ![2, 4, 8].contains(&self.angular_resolution)
            || !self.first_interval.is_finite()
            || self.first_interval <= 0.0
            || !max_distance.is_finite()
            || max_distance <= 0.0
            || self.interval(self.levels - 1, max_distance).0 >= max_distance
        {
            return Err("invalid radiance cascade levels, angular resolution or interval");
        }
        Ok(())
    }

    pub fn dimensions(&self, tiles: UVec2, level: u32) -> UVec2 {
        let scale = 1u32 << level;
        UVec2::new(tiles.x.div_ceil(scale), tiles.y.div_ceil(scale)).max(UVec2::ONE)
    }

    pub fn directions(&self, level: u32) -> u32 {
        (self.angular_resolution << level).pow(2)
    }

    pub fn interval(&self, level: u32, max_distance: f32) -> (f32, f32) {
        let near = self.first_interval * ((1u32 << level) - 1) as f32;
        let far = if level + 1 == self.levels {
            max_distance
        } else {
            self.first_interval * ((1u32 << (level + 1)) - 1) as f32
        };
        (near, far)
    }

    pub fn probes(&self, tiles: UVec2) -> u64 {
        (0..self.levels)
            .map(|level| {
                let dims = self.dimensions(tiles, level);
                u64::from(dims.x) * u64::from(dims.y)
            })
            .sum()
    }

    pub fn rays(&self, tiles: UVec2) -> u64 {
        (0..self.levels)
            .map(|level| {
                let dims = self.dimensions(tiles, level);
                u64::from(dims.x) * u64::from(dims.y) * u64::from(self.directions(level))
            })
            .sum()
    }

    pub fn bytes(&self, tiles: UVec2) -> u64 {
        // Metadata: position, normal, seed. Raw/merged intervals and traced hits.
        16 * (3 * self.probes(tiles) + 3 * self.rays(tiles))
    }

    pub(crate) fn cache_queries(&self, tiles: UVec2, capacity: u32) -> (u32, u32) {
        let rays = self.rays(tiles);
        let stride = rays.div_ceil(u64::from(capacity)).max(1);
        (rays.div_ceil(stride) as u32, stride as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intervals_are_contiguous_and_last_level_reaches_the_ray_bound() {
        let config = RadianceCascadesConfig::default();
        assert_eq!(config.interval(0, 1000.0), (0.0, 0.5));
        assert_eq!(config.interval(1, 1000.0), (0.5, 1.5));
        assert_eq!(config.interval(2, 1000.0), (1.5, 1000.0));
        assert!(config.validate(1.0).is_err());
        for distance in [0.0, -1.0, f32::NAN, f32::INFINITY] {
            assert!(config.validate(distance).is_err());
        }
        for levels in [0, 6, u32::MAX] {
            assert!(
                RadianceCascadesConfig {
                    levels,
                    ..config.clone()
                }
                .validate(1000.0)
                .is_err()
            );
        }
    }

    #[test]
    fn spatial_and_angular_scaling_preserve_even_view_ray_budgets() {
        let config = RadianceCascadesConfig::default();
        let tiles = UVec2::splat(16);
        for level in 0..config.levels {
            let dims = config.dimensions(tiles, level);
            assert_eq!(dims.element_product() * config.directions(level), 4096);
        }
        assert_eq!(config.rays(tiles), 12288);
        assert_eq!(config.probes(tiles), 336);
        assert_eq!(config.bytes(tiles), 605952);
        assert_eq!(config.dimensions(UVec2::new(17, 9), 1), UVec2::new(9, 5));
        assert_eq!(config.dimensions(UVec2::ONE, 4), UVec2::ONE);
    }

    #[test]
    fn rotating_cache_queries_stay_within_the_existing_ray_budget() {
        for tiles in [UVec2::ONE, UVec2::new(17, 9), UVec2::splat(80)] {
            for levels in 1..=5 {
                for angular_resolution in [2, 4, 8] {
                    let config = RadianceCascadesConfig {
                        levels,
                        angular_resolution,
                        ..Default::default()
                    };
                    for directions in [16, 64] {
                        let capacity = tiles.element_product() * directions;
                        let (queries, stride) = config.cache_queries(tiles, capacity);
                        assert!(queries <= capacity);
                        assert_eq!(
                            u64::from(queries),
                            config.rays(tiles).div_ceil(u64::from(stride))
                        );
                        // Every interval is selected in one phase, with a unique slot.
                        for record in 0..config.rays(tiles) {
                            assert!(record / u64::from(stride) < u64::from(queries));
                        }
                    }
                }
            }
        }
    }
}
