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
    pub split_radius: u32,
    pub cleanup_fireflies: bool,
    pub mark_fireflies_radius: u32,
    pub cleanup_fireflies_radius: u32,
    pub firefly_low_threshold: f32,
    pub firefly_high_threshold: f32,
}
impl Default for ReflectionConfig {
    fn default() -> Self {
        Self {
            half_resolution: true,
            denoiser: ReflectionDenoiser::AtrousRatioEstimator,
            high_roughness_threshold: 0.6,
            atrous_passes: 4,
            split_radius: 11,
            cleanup_fireflies: true,
            mark_fireflies_radius: 3,
            cleanup_fireflies_radius: 2,
            firefly_low_threshold: 0.0,
            firefly_high_threshold: 1.0,
        }
    }
}
impl ReflectionConfig {
    pub(crate) fn validate(&self, low: f32) -> Result<(), &'static str> {
        if !self.high_roughness_threshold.is_finite()
            || !(low..=1.0).contains(&self.high_roughness_threshold)
            || !(2..=8).contains(&self.atrous_passes)
            || !(1..=32).contains(&self.split_radius)
            || self.mark_fireflies_radius > 16
            || self.cleanup_fireflies_radius > 16
            || !self.firefly_low_threshold.is_finite()
            || !self.firefly_high_threshold.is_finite()
            || !(0.0..=1.0).contains(&self.firefly_low_threshold)
            || !(0.0..=1.0).contains(&self.firefly_high_threshold)
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
        // and two split-estimator intermediate planes.
        let split_height = size.y.div_ceil(if self.half_resolution { 2 } else { 1 });
        16 * (1024
            + 8 * self.samples(size)
            + 4 * u64::from(size.x) * u64::from(size.y)
            + 2 * u64::from(size.x) * u64::from(split_height))
    }
}
