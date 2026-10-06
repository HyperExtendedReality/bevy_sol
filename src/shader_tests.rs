use super::*;
use std::collections::HashMap;

fn text(words: &[u32]) -> String {
    let bytes: Vec<_> = words
        .iter()
        .flat_map(|w| w.to_le_bytes())
        .take_while(|b| *b != 0)
        .collect();
    String::from_utf8(bytes).unwrap()
}

#[test]
#[ignore = "requires slangc on PATH or SLANGC"]
fn slang_variants_preserve_entry_points_storage_strides_and_uniform_offsets() {
    for directions in [4, 8] {
        for (hardware, textured) in [(false, false), (false, true), (true, false), (true, true)] {
            let shader = compile_shader(
                &bevy_slang::SlangCompiler::default(),
                "gi.slang",
                directions,
                hardware,
                textured,
            );
            let bevy::shader::Source::SpirV(bytes) = shader.source else {
                panic!("expected Slang SPIR-V");
            };
            let words: Vec<_> = bytes
                .as_chunks::<4>()
                .0
                .iter()
                .map(|v| u32::from_le_bytes(*v))
                .collect();
            let mut names = HashMap::new();
            let mut arrays = HashMap::new();
            let mut strides = HashMap::new();
            let mut offsets = HashMap::new();
            let mut bindings = HashMap::new();
            let mut entries = Vec::new();
            let mut cursor = 5;
            while cursor < words.len() {
                let count = (words[cursor] >> 16) as usize;
                assert!(count > 0 && cursor + count <= words.len());
                let operands = &words[cursor + 1..cursor + count];
                match words[cursor] & 0xffff {
                    5 => {
                        names.insert(operands[0], text(&operands[1..]));
                    }
                    15 => entries.push(text(&operands[2..])),
                    29 => {
                        arrays.insert(operands[0], operands[1]);
                    }
                    71 if operands[1] == 6 => {
                        strides.insert(operands[0], operands[2]);
                    }
                    71 if operands[1] == 33 => {
                        bindings.insert(operands[0], operands[2]);
                    }
                    72 if operands[2] == 35 => {
                        offsets.insert((operands[0], operands[1]), operands[3]);
                    }
                    _ => {}
                }
                cursor += count;
            }
            for entry in STAGES {
                assert!(entries.iter().any(|name| name == entry), "missing {entry}");
            }
            for (name, binding) in [
                ("occlusion_and_bent_normal", 35),
                ("near_field_irradiance", 36),
            ] {
                let id = names.iter().find(|(_, n)| n.as_str() == name).unwrap().0;
                assert_eq!(
                    bindings[id], binding,
                    "optional reconstruction attachment {name}"
                );
            }
            for (name, bytes) in [
                ("Probe", probe_bytes(directions)),
                ("CacheEntry", CACHE_BYTES),
                ("RaySample", RAY_BYTES),
                ("CachedProbe", 16 + probe_bytes(directions)),
            ] {
                let type_id = *names
                    .iter()
                    .find(|(id, n)| {
                        n.starts_with(&format!("{name}_std430"))
                            && arrays.values().any(|element| *element == **id)
                    })
                    .unwrap()
                    .0;
                let array_id = *arrays.iter().find(|(_, elem)| **elem == type_id).unwrap().0;
                assert_eq!(
                    u64::from(strides[&array_id]),
                    bytes,
                    "Slang storage stride for {name}"
                );
            }
            let params = *names
                .iter()
                .find(|(_, n)| n.starts_with("Params_std140"))
                .unwrap()
                .0;
            assert_eq!(
                u64::from(offsets[&(params, 23)]) + 16,
                Params::min_size().get()
            );
            assert_eq!(offsets[&(params, 1)], 64); // column-major previous clip matrix
            assert_eq!(offsets[&(params, 18)], 384); // unjittered motion matrices
            assert_eq!(offsets[&(params, 19)], 448);
            assert_eq!(offsets[&(params, 20)], 512);
            assert_eq!(offsets[&(params, 21)], 528);
            assert_eq!(offsets[&(params, 22)], 544);
            assert_eq!(offsets[&(params, 23)], 560);
        }
    }
    let shader = compile_shader(
        &bevy_slang::SlangCompiler::default(),
        "composite.slang",
        4,
        false,
        false,
    );
    assert!(matches!(shader.source, bevy::shader::Source::SpirV(_)));
}
