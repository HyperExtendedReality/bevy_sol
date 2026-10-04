use bevy::{prelude::*, render::extract_resource::ExtractResource};

/// Direction distribution used for next-event environment lighting.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EnvironmentSampling {
    UniformHemisphere,
    #[default]
    CosineHemisphere,
    /// AMD's face CDF and four-child mip descent. Requires a power-of-two
    /// cubemap with a complete arithmetic-average mip chain down to 1x1.
    Importance,
}

/// Raw scene-linear environment radiance shared by GI cameras.
///
/// Use the original cubemap (for example a `Skybox` image), rather than Bevy's
/// preconvolved diffuse/specular `EnvironmentMapLight` images. Changing this
/// resource or reloading its image invalidates accumulated lighting.
#[derive(Resource, Clone, Debug, PartialEq, ExtractResource)]
pub struct GiEnvironmentMap {
    /// A square, six-layer image with a `Cube` texture view. `None` disables it.
    pub image: Option<Handle<Image>>,
    /// Finite, nonnegative radiance multiplier. Camera exposure is applied later.
    pub intensity: f32,
    /// Rotation from cubemap space into world space; must be a unit quaternion.
    pub rotation: Quat,
    /// Next-event sampling distribution. Probe/glossy ray misses evaluate the
    /// cubemap directly along their traced direction.
    pub sampling: EnvironmentSampling,
}

impl Default for GiEnvironmentMap {
    fn default() -> Self {
        Self {
            image: None,
            intensity: 1.0,
            rotation: Quat::IDENTITY,
            sampling: EnvironmentSampling::default(),
        }
    }
}

impl GiEnvironmentMap {
    pub fn validate(&self) -> Result<(), &'static str> {
        if !self.intensity.is_finite() || self.intensity < 0.0 {
            return Err("environment intensity must be finite and nonnegative");
        }
        if !self.rotation.is_finite() || (self.rotation.length_squared() - 1.0).abs() > 1e-4 {
            return Err("environment rotation must be a finite unit quaternion");
        }
        Ok(())
    }
}

#[derive(Resource, Clone, Default, ExtractResource)]
pub(crate) struct EnvironmentRevision(pub u64);

pub(crate) fn track_environment(
    environment: Res<GiEnvironmentMap>,
    mut revision: ResMut<EnvironmentRevision>,
    mut events: MessageReader<AssetEvent<Image>>,
    mut previous: Local<GiEnvironmentMap>,
) {
    // Invalid settings are disabled in the renderer. Stable NaN payloads must
    // not look like a new configuration every frame and keep clearing caches.
    let mut changed = environment.image != previous.image
        || environment.intensity.to_bits() != previous.intensity.to_bits()
        || environment.rotation.to_array().map(f32::to_bits)
            != previous.rotation.to_array().map(f32::to_bits)
        || environment.sampling != previous.sampling;
    for event in events.read() {
        changed |= environment.image.as_ref().is_some_and(|image| {
            event.is_added(image.id())
                || event.is_modified(image.id())
                || event.is_removed(image.id())
                || event.is_loaded_with_dependencies(image.id())
        });
    }
    if changed {
        revision.0 = revision.0.wrapping_add(1);
        *previous = environment.clone();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn environment_edits_and_image_reloads_invalidate_lighting() {
        let mut app = App::new();
        app.init_resource::<GiEnvironmentMap>()
            .init_resource::<EnvironmentRevision>()
            .add_message::<AssetEvent<Image>>()
            .add_systems(Update, track_environment);
        let id: AssetId<Image> = AssetId::Uuid {
            uuid: bevy::asset::uuid::Uuid::from_u128(1),
        };
        let unrelated: AssetId<Image> = AssetId::Uuid {
            uuid: bevy::asset::uuid::Uuid::from_u128(2),
        };
        app.world_mut().resource_mut::<GiEnvironmentMap>().image = Some(Handle::Uuid(
            bevy::asset::uuid::Uuid::from_u128(1),
            std::marker::PhantomData,
        ));
        app.update();
        assert_eq!(app.world().resource::<EnvironmentRevision>().0, 1);
        app.world_mut()
            .write_message(AssetEvent::Modified { id: unrelated });
        app.update();
        assert_eq!(app.world().resource::<EnvironmentRevision>().0, 1);
        app.world_mut().write_message(AssetEvent::Modified { id });
        app.update();
        assert_eq!(app.world().resource::<EnvironmentRevision>().0, 2);
        app.world_mut().resource_mut::<GiEnvironmentMap>().rotation = Quat::from_rotation_y(0.5);
        app.update();
        assert_eq!(app.world().resource::<EnvironmentRevision>().0, 3);
        app.world_mut().resource_mut::<GiEnvironmentMap>().image = None;
        app.update();
        assert_eq!(app.world().resource::<EnvironmentRevision>().0, 4);
        app.world_mut().resource_mut::<GiEnvironmentMap>().intensity = f32::NAN;
        app.update();
        assert_eq!(app.world().resource::<EnvironmentRevision>().0, 5);
        app.update();
        assert_eq!(app.world().resource::<EnvironmentRevision>().0, 5);
        assert!(GiEnvironmentMap::default().validate().is_ok());
        assert!(
            GiEnvironmentMap {
                intensity: -1.0,
                ..default()
            }
            .validate()
            .is_err()
        );
        assert!(
            GiEnvironmentMap {
                rotation: Quat::from_xyzw(0.0, 0.0, 0.0, 0.0),
                ..default()
            }
            .validate()
            .is_err()
        );
    }
}
