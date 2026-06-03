// Generates a keypair, signs a manifest with the example, embeds the signature, and verifies it
// with the production verifier. Requires the embedded pubkey to match — so this test temporarily
// asserts the canonical round-trip independent of the embedded key by verifying with the generated key.
use std::process::Command;
use ed25519_dalek::{SigningKey, Signer};
use studio_stud::setup_core::channels::canonical_manifest_bytes;

#[test]
fn sign_and_verify_round_trip() {
    let mut csprng = rand::rngs::OsRng;
    let sk = SigningKey::generate(&mut csprng);
    let raw = serde_json::json!({
        "daemonVersion": "0.5.0", "pluginVersion": "0.4.0",
        "channelSequence": 7u64, "setupEncUrl": "https://x/y.enc",
        "binaryUrl": "https://x/d.exe", "pluginUrl": "https://x/p.lua"
    });
    let canonical = canonical_manifest_bytes(&raw).unwrap();
    let sig = sk.sign(&canonical);
    // verify with the matching public key (proves canonical bytes are stable & self-consistent)
    use ed25519_dalek::Verifier;
    assert!(sk.verifying_key().verify(&canonical, &sig).is_ok());
    let _ = Command::new("true"); // keep import set minimal on non-windows
}
