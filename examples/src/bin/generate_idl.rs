/// Generate IDL JSON for the whisper-wall program.
///
/// Usage:
///   cargo run --bin generate_idl > whisper-wall-idl.json

spel_framework::generate_idl!("../methods/guest/src/bin/whisper_wall.rs");
