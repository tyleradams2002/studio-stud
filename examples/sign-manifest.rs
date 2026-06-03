//! Signs a manifest JSON file with the ed25519 private key, using the SAME canonicalization the
//! daemon/setup verifier uses (studio_stud::setup_core::channels::canonical_manifest_bytes).
//! Prints base64 signature to stdout. Used by scripts/publish-channel.ps1 and deploy.yml.
use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use clap::Parser;
use ed25519_dalek::{Signer, SigningKey};
use studio_stud::setup_core::channels::canonical_manifest_bytes;

#[derive(Parser)]
struct Args {
    /// 64-byte ed25519 secret key in hex (privkey || pubkey from keygen.rs)
    #[arg(long)] privkey: String,
    /// Path to the unsigned manifest JSON (any key order; `signature` is ignored if present)
    #[arg(long)] manifest: std::path::PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let key_bytes = hex_decode_64(&args.privkey).map_err(|e| anyhow!("bad privkey hex: {e}"))?;
    let signing_key = SigningKey::from_bytes(&key_bytes[..32].try_into().unwrap());
    let text = std::fs::read_to_string(&args.manifest)
        .map_err(|e| anyhow!("read {:?}: {e}", args.manifest))?;
    let raw: serde_json::Value = serde_json::from_str(&text)?;
    let canonical = canonical_manifest_bytes(&raw)?;
    let signature = signing_key.sign(&canonical);
    println!("{}", B64.encode(signature.to_bytes()));
    Ok(())
}

fn hex_decode_64(s: &str) -> Result<[u8; 64]> {
    let s = s.trim();
    let bytes: Vec<u8> = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16))
        .collect::<Result<_, _>>()
        .map_err(|e| anyhow!("hex: {e}"))?;
    bytes.try_into().map_err(|_| anyhow!("expected 64 bytes"))
}
