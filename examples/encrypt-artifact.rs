//! Encrypts a binary file with a password so install.ps1 can decrypt it inline on any Windows machine.
//!
//! Format: [salt 16B][iv 16B][hmac-sha256 32B][ciphertext (AES-256-CBC PKCS7-padded)]
//! KDF   : PBKDF2-SHA256 × 200 000 iterations → 64 bytes
//!           bytes  0-31 = AES encryption key
//!           bytes 32-63 = HMAC-SHA256 key
//! MAC   : HMAC-SHA256 over (salt ‖ iv ‖ ciphertext) — authenticate-then-encrypt order is reversed
//!         here (encrypt-then-MAC): ciphertext is produced first, then MACed.
//!
//! PowerShell/.NET Framework 4.7.2+ can decrypt this with Rfc2898DeriveBytes + AesCryptoServiceProvider
//! + HMACSHA256 — no extra libraries, works on every Windows 10/11 machine in PS 5.1 and PS 7.
use std::{fs, path::PathBuf};

use aes::Aes256;
use anyhow::{Result, anyhow};
use cbc::Encryptor;
use cbc::cipher::{BlockEncryptMut, KeyIvInit, block_padding::Pkcs7};
use clap::Parser;
use hmac::{Hmac, KeyInit, Mac};
use pbkdf2::pbkdf2_hmac_array;
use rand::{RngCore, rngs::OsRng};
use sha2::Sha256;

type Aes256CbcEnc = Encryptor<Aes256>;
type HmacSha256 = Hmac<Sha256>;

const PBKDF2_ITERS: u32 = 200_000;

#[derive(Parser)]
struct Args {
    #[arg(long)] password: String,
    #[arg(long)] input: PathBuf,
    #[arg(long)] output: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let plaintext = fs::read(&args.input)
        .map_err(|e| anyhow!("read {:?}: {e}", args.input))?;

    let mut salt = [0u8; 16];
    let mut iv   = [0u8; 16];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut iv);

    // PBKDF2-SHA256 → 64 bytes: [enc_key 32][mac_key 32]
    let derived: [u8; 64] = pbkdf2_hmac_array::<Sha256, 64>(
        args.password.as_bytes(), &salt, PBKDF2_ITERS,
    );
    let (enc_key, mac_key) = derived.split_at(32);

    // AES-256-CBC encrypt
    let ciphertext = Aes256CbcEnc::new_from_slices(enc_key, &iv)
        .map_err(|e| anyhow!("cipher init: {e}"))?
        .encrypt_padded_vec_mut::<Pkcs7>(&plaintext);

    // HMAC-SHA256 over salt ‖ iv ‖ ciphertext (encrypt-then-MAC)
    let mut mac = HmacSha256::new_from_slice(mac_key)
        .map_err(|e| anyhow!("hmac init: {e}"))?;
    mac.update(&salt);
    mac.update(&iv);
    mac.update(&ciphertext);
    let hmac_bytes = mac.finalize().into_bytes();

    // Write: [salt 16][iv 16][hmac 32][ciphertext]
    let mut out = Vec::with_capacity(64 + ciphertext.len());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&iv);
    out.extend_from_slice(&hmac_bytes);
    out.extend_from_slice(&ciphertext);

    fs::write(&args.output, &out)
        .map_err(|e| anyhow!("write {:?}: {e}", args.output))?;
    eprintln!("Encrypted {} → {} bytes (PBKDF2-SHA256/{} + AES-256-CBC + HMAC-SHA256)",
        args.input.display(), out.len(), PBKDF2_ITERS);
    Ok(())
}
