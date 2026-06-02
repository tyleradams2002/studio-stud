//! Signs a manifest JSON payload with the ed25519 private key.
//! Prints base64-encoded signature to stdout.
//! Used by scripts/publish-channel.ps1.
use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use clap::Parser;
use ed25519_dalek::{SigningKey, Signer};

#[derive(Parser)]
struct Args {
    /// 64-byte ed25519 secret key in hex (privkey || pubkey format from keygen.rs)
    #[arg(long)] privkey: String,
    /// JSON string to sign
    #[arg(long)] payload: String,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let key_bytes = hex_decode_64(&args.privkey)
        .map_err(|e| anyhow!("bad privkey hex: {e}"))?;
    // First 32 bytes are the actual signing key scalar
    let signing_key = SigningKey::from_bytes(&key_bytes[..32].try_into().unwrap());
    let signature = signing_key.sign(args.payload.as_bytes());
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
