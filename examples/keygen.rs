//! Generates an ed25519 signing key pair and prints it to stdout in hex.
//! Called by scripts/keygen.ps1. Not shipped in release builds.
use ed25519_dalek::SigningKey;
use rand::rngs::OsRng;

fn main() {
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();

    // Private key = signing key bytes ++ verifying key bytes (64 bytes total, standard dalek format)
    let mut priv_bytes = [0u8; 64];
    priv_bytes[..32].copy_from_slice(signing_key.as_bytes());
    priv_bytes[32..].copy_from_slice(verifying_key.as_bytes());

    println!("PRIVATE:{}", hex_encode(&priv_bytes));
    println!("PUBLIC:{}", hex_encode(verifying_key.as_bytes()));
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
