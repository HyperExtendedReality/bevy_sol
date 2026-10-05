use bevy::{
    prelude::*,
    render::gpu_readback::{Readback, ReadbackComplete},
};
use std::io::Write;

pub const WARMUP: u32 = 512;
const WIDTH: usize = 640;
const HEIGHT: usize = 640;
const MAGIC: &[u8; 8] = b"SOLHDR01";
// Increment when scene, camera or common estimator/capture settings change.
const FINGERPRINT: u32 = 1;

#[derive(Resource)]
pub struct Capture {
    target: u32,
    count: u32,
    mean: Vec<f64>,
    m2: Vec<f64>,
    first_half: Vec<f64>,
}

impl Capture {
    fn new(target: u32, channels: usize) -> Self {
        assert!(target >= 2 && target.is_multiple_of(2));
        Self {
            target,
            count: 0,
            mean: vec![0.0; channels],
            m2: vec![0.0; channels],
            first_half: Vec::new(),
        }
    }

    pub fn complete(&self) -> bool {
        self.count == self.target
    }

    fn push(&mut self, values: impl Iterator<Item = f32>) {
        assert!(!self.complete());
        self.count += 1;
        let mut channels = 0;
        for (i, value) in values.enumerate() {
            assert!(value.is_finite(), "nonfinite HDR channel {i}");
            let delta = f64::from(value) - self.mean[i];
            self.mean[i] += delta / f64::from(self.count);
            self.m2[i] += delta * (f64::from(value) - self.mean[i]);
            channels += 1;
        }
        assert_eq!(channels, self.mean.len());
        if self.count == self.target / 2 {
            self.first_half.clone_from(&self.mean);
        }
    }

    fn variance(&self, channel: usize) -> f64 {
        self.m2[channel] / f64::from(self.count - 1)
    }

    pub fn write(
        &self,
        prefix: &str,
        scene: u32,
        compare: Option<&str>,
        metadata: &str,
        warmup: u32,
    ) {
        assert!(self.complete());
        assert!(
            self.mean.iter().any(|v| *v > 1.0),
            "capture did not retain HDR emitter values"
        );
        std::fs::create_dir_all("screenshots").expect("quality directory");
        let reference = compare.map(|path| load(path, self.count, scene, warmup));
        let mut file = std::io::BufWriter::new(
            std::fs::File::create(format!("{prefix}.bin")).expect("HDR statistics file"),
        );
        file.write_all(MAGIC).unwrap();
        for word in [
            WIDTH as u32,
            HEIGHT as u32,
            self.count,
            scene,
            FINGERPRINT,
            warmup,
        ] {
            file.write_all(&word.to_le_bytes()).unwrap();
        }
        for plane in 0..3 {
            for i in 0..self.mean.len() {
                let value = match plane {
                    0 => self.mean[i],
                    1 => self.variance(i),
                    _ => 2.0 * (self.mean[i] - self.first_half[i]),
                };
                let value = value as f32;
                assert!(value.is_finite(), "HDR statistics exceed f32 storage range");
                file.write_all(&value.to_le_bytes()).unwrap();
            }
        }
        file.flush().unwrap();
        let mut csv = String::from(
            "region,samples,mean_luminance,rms_temporal_variation,relative_temporal_variation,rms_half_window_drift,relative_half_window_drift,rms_mean_difference,relative_mean_difference\n",
        );
        // Fixed receiver regions exclude the visible HDR emitter from the main metric.
        for (name, bounds) in [
            ("receivers", [32, 180, 608, 598]),
            ("left_wall", [20, 200, 110, 450]),
            ("right_wall", [540, 200, 620, 450]),
            ("floor", [120, 535, 520, 595]),
            ("boxes", [140, 270, 500, 510]),
        ] {
            let channels: Vec<_> = (bounds[1]..bounds[3])
                .flat_map(|y| {
                    (bounds[0]..bounds[2])
                        .flat_map(move |x| (0..3).map(move |c| (y * WIDTH + x) * 3 + c))
                })
                .collect();
            let metrics = self.metrics(&channels, reference.as_deref());
            let row = format!(
                "{name},{},{:.9},{:.9},{:.9},{:.9},{:.9},{},{}\n",
                self.count,
                metrics[0],
                metrics[1],
                metrics[2],
                metrics[3],
                metrics[4],
                if reference.is_some() {
                    format!("{:.9}", metrics[5])
                } else {
                    String::new()
                },
                if reference.is_some() {
                    format!("{:.9}", metrics[6])
                } else {
                    String::new()
                }
            );
            print!("{row}");
            csv.push_str(&row);
        }
        std::fs::write(format!("{prefix}.csv"), csv).unwrap();
        std::fs::write(format!("{prefix}.txt"), format!("{metadata}width={WIDTH}\nheight={HEIGHT}\nwarmup_dispatches={warmup}\nsamples={}\nscene_fingerprint={FINGERPRINT}\ncomparison={}\n", self.count, compare.unwrap_or("none"))).unwrap();
        println!(
            "HDR quality statistics: {prefix}.bin (linear exposed RGB; comparison is not ground-truth accuracy)"
        );
    }

    fn metrics(&self, channels: &[usize], reference: Option<&[f32]>) -> [f64; 7] {
        assert!(!channels.is_empty());
        let mut signal = 0.0;
        let mut variation = 0.0;
        let mut drift = 0.0;
        let mut error = 0.0;
        let mut reference_signal = 0.0;
        let mut luminance = 0.0;
        for &i in channels {
            signal += self.mean[i].powi(2);
            variation += self.variance(i);
            drift += (2.0 * (self.mean[i] - self.first_half[i])).powi(2);
            luminance += self.mean[i] * [0.2126, 0.7152, 0.0722][i % 3];
            if let Some(reference) = reference {
                error += (self.mean[i] - f64::from(reference[i])).powi(2);
                reference_signal += f64::from(reference[i]).powi(2);
            }
        }
        let n = channels.len() as f64;
        [
            luminance * 3.0 / n,
            (variation / n).sqrt(),
            (variation / signal.max(1e-30)).sqrt(),
            (drift / n).sqrt(),
            (drift / signal.max(1e-30)).sqrt(),
            (error / n).sqrt(),
            (error / reference_signal.max(1e-30)).sqrt(),
        ]
    }
}

pub fn start(world: &mut World, image: Handle<Image>, target: u32) {
    world.insert_resource(Capture::new(target, WIDTH * HEIGHT * 3));
    world.spawn(Readback::texture(image)).observe(
        |event: On<ReadbackComplete>, mut capture: ResMut<Capture>| {
            if capture.complete() {
                return;
            }
            // 640 RGBA32 pixels form 10240-byte rows, already aligned to 256.
            assert_eq!(event.data.len(), WIDTH * HEIGHT * 16);
            capture.push(event.data.as_chunks::<16>().0.iter().flat_map(|pixel| {
                pixel[..12]
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|v| f32::from_le_bytes(*v))
            }));
        },
    );
}

fn load(path: &str, samples: u32, scene: u32, warmup: u32) -> Vec<f32> {
    let bytes = std::fs::read(path).expect("comparison HDR statistics");
    decode(&bytes, samples, scene, warmup)
}

fn decode(bytes: &[u8], samples: u32, scene: u32, warmup: u32) -> Vec<f32> {
    assert!(bytes.len() >= 32, "truncated HDR header");
    let header = &bytes[..32];
    assert_eq!(&header[..8], MAGIC, "incompatible HDR format");
    let actual: Vec<_> = header[8..]
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| u32::from_le_bytes(*v))
        .collect();
    assert_eq!(
        actual,
        [
            WIDTH as u32,
            HEIGHT as u32,
            samples,
            scene,
            FINGERPRINT,
            warmup
        ],
        "comparison must match scene, camera/capture revision, warmup, resolution and sample count"
    );
    let bytes = &bytes[32..];
    assert_eq!(
        bytes.len(),
        WIDTH * HEIGHT * 3 * 4 * 3,
        "truncated HDR statistics"
    );
    let values: Vec<_> = bytes[..WIDTH * HEIGHT * 3 * 4]
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| f32::from_le_bytes(*v))
        .collect();
    assert!(values.iter().all(|v| v.is_finite()));
    values
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hdr_moments_and_reference_metrics_preserve_bright_values_and_drift() {
        let mut capture = Capture::new(4, 3);
        for value in [1.0, 3.0, 5.0, 7.0] {
            capture.push([value; 3].into_iter());
        }
        assert!(capture.complete());
        assert_eq!(capture.mean, [4.0; 3]);
        assert_eq!(capture.first_half, [2.0; 3]);
        assert!((capture.variance(0) - 20.0 / 3.0).abs() < 1e-12);
        let metrics = capture.metrics(&[0, 1, 2], Some(&[2.0; 3]));
        assert!((metrics[0] - 4.0).abs() < 1e-12);
        assert!((metrics[1] - (20.0_f64 / 3.0).sqrt()).abs() < 1e-12);
        assert_eq!(metrics[3], 4.0);
        assert_eq!(metrics[4], 1.0);
        assert_eq!(metrics[5], 2.0);
        assert_eq!(metrics[6], 1.0);
    }

    #[test]
    fn constant_frames_have_zero_temporal_variation() {
        let mut capture = Capture::new(2, 3);
        capture.push([12.0, 0.25, 0.5].into_iter());
        capture.push([12.0, 0.25, 0.5].into_iter());
        let metrics = capture.metrics(&[0, 1, 2], None);
        assert_eq!(metrics[1..5], [0.0; 4]);
        assert_eq!(capture.mean[0], 12.0);
    }

    #[test]
    fn serialized_comparisons_reject_mismatched_or_invalid_captures() {
        let mut bytes = MAGIC.to_vec();
        for value in [WIDTH as u32, HEIGHT as u32, 128, 0, FINGERPRINT, WARMUP] {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes.resize(32 + WIDTH * HEIGHT * 3 * 4 * 3, 0);
        bytes[32..36].copy_from_slice(&12.0_f32.to_le_bytes());
        assert_eq!(decode(&bytes, 128, 0, WARMUP)[0], 12.0);
        assert!(std::panic::catch_unwind(|| decode(&bytes, 128, 1, WARMUP)).is_err());
        assert!(std::panic::catch_unwind(|| decode(&bytes, 64, 0, WARMUP)).is_err());
        assert!(std::panic::catch_unwind(|| decode(&bytes, 128, 0, 2048)).is_err());
        assert!(
            std::panic::catch_unwind(|| decode(&bytes[..bytes.len() - 4], 128, 0, WARMUP)).is_err()
        );
        bytes[28..32].copy_from_slice(&2048_u32.to_le_bytes());
        assert_eq!(decode(&bytes, 128, 0, 2048)[0], 12.0);
        bytes[32..36].copy_from_slice(&f32::NAN.to_le_bytes());
        assert!(std::panic::catch_unwind(|| decode(&bytes, 128, 0, 2048)).is_err());
    }
}
