// Source Sobol/ranking/scrambling tables, losslessly packed as bytes.
pub(crate) const BLUE_NOISE: &[u8; 327680] = include_bytes!("data/gi12-blue-noise.bin");

/// AMD's reflection reconstruction modes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReflectionDenoiser {
    SplitRatioEstimator,
    #[default]
    AtrousRatioEstimator,
    None,
}

/// Reflection allocation and reconstruction settings from Capsaicin GI-1.2.
#[derive(Clone, Debug)]
pub struct ReflectionConfig {
    pub half_resolution: bool,
    pub denoiser: ReflectionDenoiser,
    pub high_roughness_threshold: f32,
    pub atrous_passes: u32,
    /// Half-resolution split-estimator radius, measured in full-resolution pixels.
    pub split_radius: u32,
    pub full_resolution_split_radius: u32,
    pub cleanup_fireflies: bool,
    /// Half-resolution marking radius, measured in full-resolution pixels.
    pub mark_fireflies_radius: u32,
    pub full_resolution_mark_fireflies_radius: u32,
    /// Half-resolution cleanup radius, measured in sample-grid pixels in SourceAtlas.
    pub cleanup_fireflies_radius: u32,
    pub full_resolution_cleanup_fireflies_radius: u32,
    /// Half-resolution marking thresholds.
    pub firefly_low_threshold: f32,
    pub firefly_high_threshold: f32,
    pub full_resolution_firefly_low_threshold: f32,
    pub full_resolution_firefly_high_threshold: f32,
}
impl Default for ReflectionConfig {
    fn default() -> Self {
        Self {
            half_resolution: true,
            denoiser: ReflectionDenoiser::AtrousRatioEstimator,
            high_roughness_threshold: 0.6,
            atrous_passes: 4,
            split_radius: 11,
            full_resolution_split_radius: 11,
            cleanup_fireflies: true,
            mark_fireflies_radius: 3,
            full_resolution_mark_fireflies_radius: 2,
            cleanup_fireflies_radius: 2,
            full_resolution_cleanup_fireflies_radius: 1,
            firefly_low_threshold: 0.0,
            firefly_high_threshold: 1.0,
            full_resolution_firefly_low_threshold: 0.0,
            full_resolution_firefly_high_threshold: 1.0,
        }
    }
}
impl ReflectionConfig {
    pub(crate) fn reconstruction_settings(&self) -> ([u32; 3], [f32; 2]) {
        if self.half_resolution {
            (
                [
                    self.split_radius,
                    self.mark_fireflies_radius,
                    self.cleanup_fireflies_radius,
                ],
                [self.firefly_low_threshold, self.firefly_high_threshold],
            )
        } else {
            (
                [
                    self.full_resolution_split_radius,
                    self.full_resolution_mark_fireflies_radius,
                    self.full_resolution_cleanup_fireflies_radius,
                ],
                [
                    self.full_resolution_firefly_low_threshold,
                    self.full_resolution_firefly_high_threshold,
                ],
            )
        }
    }
    pub(crate) fn validate(&self, low: f32) -> Result<(), &'static str> {
        if !self.high_roughness_threshold.is_finite()
            || !(low..=1.0).contains(&self.high_roughness_threshold)
            || !(2..=8).contains(&self.atrous_passes)
            || !(1..=32).contains(&self.split_radius)
            || !(1..=32).contains(&self.full_resolution_split_radius)
            || self.mark_fireflies_radius > 16
            || self.full_resolution_mark_fireflies_radius > 16
            || self.cleanup_fireflies_radius > 16
            || self.full_resolution_cleanup_fireflies_radius > 16
            || !self.firefly_low_threshold.is_finite()
            || !self.firefly_high_threshold.is_finite()
            || !(0.0..=1.0).contains(&self.firefly_low_threshold)
            || !(0.0..=1.0).contains(&self.firefly_high_threshold)
            || !self.full_resolution_firefly_low_threshold.is_finite()
            || !self.full_resolution_firefly_high_threshold.is_finite()
            || !(0.0..=1.0).contains(&self.full_resolution_firefly_low_threshold)
            || !(0.0..=1.0).contains(&self.full_resolution_firefly_high_threshold)
        {
            return Err("invalid reflection thresholds or reconstruction settings");
        }
        Ok(())
    }
    pub(crate) fn samples(&self, size: bevy::prelude::UVec2) -> u64 {
        let divisor = if self.half_resolution { 2 } else { 1 };
        u64::from(size.x.div_ceil(divisor)) * u64::from(size.y.div_ceil(divisor))
    }
    pub(crate) fn bytes(&self, size: bevy::prelude::UVec2) -> u64 {
        // 32x32 BRDF LUT, eight sample planes, four full-resolution planes,
        // two split-estimator intermediate planes, and losslessly packed source
        // blue-noise tables. The immutable tail needs no additional binding.
        let split_height = size.y.div_ceil(if self.half_resolution { 2 } else { 1 });
        16 * (1024
            + 8 * self.samples(size)
            + 4 * u64::from(size.x) * u64::from(size.y)
            + 2 * u64::from(size.x) * u64::from(split_height))
            + BLUE_NOISE.len() as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_resolution_defaults_and_independent_controls() {
        let mut config = ReflectionConfig::default();
        assert_eq!(config.reconstruction_settings(), ([11, 3, 2], [0.0, 1.0]));
        config.half_resolution = false;
        assert_eq!(config.reconstruction_settings(), ([11, 2, 1], [0.0, 1.0]));
        config.split_radius = 7;
        config.mark_fireflies_radius = 5;
        config.cleanup_fireflies_radius = 4;
        config.firefly_low_threshold = 0.1;
        config.firefly_high_threshold = 0.9;
        config.full_resolution_split_radius = 9;
        config.full_resolution_mark_fireflies_radius = 6;
        config.full_resolution_cleanup_fireflies_radius = 3;
        config.full_resolution_firefly_low_threshold = 0.2;
        config.full_resolution_firefly_high_threshold = 0.8;
        assert_eq!(config.reconstruction_settings(), ([9, 6, 3], [0.2, 0.8]));
        config.half_resolution = true;
        assert_eq!(config.reconstruction_settings(), ([7, 5, 4], [0.1, 0.9]));
        assert!(config.validate(0.2).is_ok());
    }

    #[test]
    fn rejects_invalid_inactive_resolution_controls() {
        let config = ReflectionConfig::default();
        for invalid in [
            ReflectionConfig {
                full_resolution_split_radius: 0,
                ..config.clone()
            },
            ReflectionConfig {
                full_resolution_mark_fireflies_radius: 17,
                ..config.clone()
            },
            ReflectionConfig {
                full_resolution_cleanup_fireflies_radius: 17,
                ..config.clone()
            },
            ReflectionConfig {
                full_resolution_firefly_low_threshold: f32::NAN,
                ..config.clone()
            },
            ReflectionConfig {
                full_resolution_firefly_high_threshold: f32::INFINITY,
                ..config.clone()
            },
            ReflectionConfig {
                full_resolution_firefly_low_threshold: -0.1,
                ..config.clone()
            },
            ReflectionConfig {
                full_resolution_firefly_high_threshold: 1.1,
                ..config
            },
        ] {
            assert!(invalid.validate(0.2).is_err());
        }
    }

    #[test]
    fn original_blue_noise_tables_are_preserved() {
        let checksum = BLUE_NOISE
            .iter()
            .fold(0xcbf2_9ce4_8422_2325u64, |hash, byte| {
                (hash ^ u64::from(*byte)).wrapping_mul(0x100_0000_01b3)
            });
        assert_eq!(checksum, 0x1bec_05a1_e2d4_d117);
    }
}
