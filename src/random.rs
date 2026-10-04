//! Seed-table generation used by Capsaicin's RandomNumberGenerator component.
use bevy::prelude::UVec2;

/// Upstream random-number generator options.
#[derive(Clone, Debug)]
pub struct RandomConfig {
    pub deterministic: bool,
    pub seed: u32,
}

impl Default for RandomConfig {
    fn default() -> Self {
        Self {
            deterministic: true,
            seed: 5489,
        }
    }
}

pub(crate) fn seed_count(size: UVec2) -> Option<u32> {
    size.x.max(1920).checked_mul(size.y.max(1080))
}

impl RandomConfig {
    pub(crate) fn seeds(&self, count: u32) -> Vec<u32> {
        use std::hash::BuildHasher;
        let seed = if self.deterministic {
            self.seed
        } else {
            std::collections::hash_map::RandomState::new().hash_one(self.seed) as u32
        };
        let mut generator = Mt19937::new(seed);
        (0..count).map(|_| generator.next()).collect()
    }
}

#[derive(Default)]
pub(crate) struct SeedTable {
    pub seeds: Vec<u32>,
    config: Option<RandomConfig>,
}

impl SeedTable {
    pub fn update(&mut self, count: u32, config: &RandomConfig) -> bool {
        let changed = self.config.as_ref().is_none_or(|old| {
            old.deterministic != config.deterministic
                || (config.deterministic && old.seed != config.seed)
        });
        self.config = Some(config.clone());
        if changed || count as usize > self.seeds.len() {
            self.seeds = config.seeds(count);
            true
        } else {
            false
        }
    }
}

// std::mt19937's 32-bit specialization, including its single-word seeding.
struct Mt19937 {
    words: [u32; 624],
    index: usize,
}

impl Mt19937 {
    fn new(seed: u32) -> Self {
        let mut words = [0; 624];
        words[0] = seed;
        for i in 1..624 {
            words[i] = 1812433253u32
                .wrapping_mul(words[i - 1] ^ (words[i - 1] >> 30))
                .wrapping_add(i as u32);
        }
        Self { words, index: 624 }
    }

    fn next(&mut self) -> u32 {
        if self.index == 624 {
            for i in 0..624 {
                let bits = (self.words[i] & 0x80000000) | (self.words[(i + 1) % 624] & 0x7fffffff);
                self.words[i] = self.words[(i + 397) % 624]
                    ^ (bits >> 1)
                    ^ if bits & 1 != 0 { 0x9908b0df } else { 0 };
            }
            self.index = 0;
        }
        let mut value = self.words[self.index];
        self.index += 1;
        value ^= value >> 11;
        value ^= (value << 7) & 0x9d2c5680;
        value ^= (value << 15) & 0xefc60000;
        value ^ (value >> 18)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_standard_mt19937_seed_and_twist_sequences() {
        let config = RandomConfig::default();
        let values = config.seeds(10000);
        assert_eq!(
            values[..10],
            [
                3499211612, 581869302, 3890346734, 3586334585, 545404204, 4161255391, 3922919429,
                949333985, 2715962298, 1323567403,
            ]
        );
        assert_eq!(values[9999], 4123659995);
        assert_eq!(
            RandomConfig {
                seed: 0,
                ..config.clone()
            }
            .seeds(1),
            [2357136044]
        );
        assert_eq!(RandomConfig { seed: 1, ..config }.seeds(1), [1791095845]);
    }

    #[test]
    fn source_seed_table_uses_componentwise_minimum_dimensions() {
        assert_eq!(seed_count(UVec2::ONE), Some(1920 * 1080));
        assert_eq!(seed_count(UVec2::new(4000, 1)), Some(4000 * 1080));
        assert_eq!(seed_count(UVec2::new(1, 4000)), Some(1920 * 4000));
        assert_eq!(seed_count(UVec2::splat(u32::MAX)), None);
    }

    #[test]
    fn renderer_seed_table_retains_growth_and_reinitializes_on_source_option_changes() {
        let mut table = SeedTable::default();
        let mut config = RandomConfig::default();
        assert!(table.update(8, &config));
        let prefix = table.seeds.clone();
        assert!(!table.update(4, &config));
        assert_eq!(table.seeds, prefix);
        assert!(table.update(16, &config));
        assert_eq!(table.seeds[..8], prefix);
        config.seed = 1;
        assert!(table.update(4, &config));
        assert_eq!(table.seeds, config.seeds(4));
        config.deterministic = false;
        assert!(table.update(8, &config));
        let entropy_seeds = table.seeds.clone();
        config.seed = 2;
        assert!(!table.update(4, &config));
        assert_eq!(table.seeds, entropy_seeds);
        config.deterministic = true;
        assert!(table.update(4, &config));
        assert_eq!(table.seeds, config.seeds(4));
    }
}
