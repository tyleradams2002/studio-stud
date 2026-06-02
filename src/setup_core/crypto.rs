use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};

/// Protect channel password for storage in config (DPAPI on Windows, base64 elsewhere).
pub fn dpapi_protect(plaintext: &[u8]) -> Result<String> {
    #[cfg(windows)]
    {
        return dpapi_protect_windows(plaintext);
    }
    #[cfg(not(windows))]
    {
        Ok(B64.encode(plaintext))
    }
}

pub fn dpapi_unprotect(encoded: &str) -> Result<Vec<u8>> {
    #[cfg(windows)]
    {
        return dpapi_unprotect_windows(encoded);
    }
    #[cfg(not(windows))]
    {
        Ok(B64.decode(encoded)?)
    }
}

#[cfg(windows)]
fn dpapi_protect_windows(plaintext: &[u8]) -> Result<String> {
    use std::ptr;
    type Blob = windows::Win32::Security::Cryptography::CRYPT_INTEGER_BLOB;
    let mut in_blob = Blob {
        cbData: plaintext.len() as u32,
        pbData: plaintext.as_ptr() as *mut u8,
    };
    let mut out_blob = Blob {
        cbData: 0,
        pbData: ptr::null_mut(),
    };
    unsafe {
        windows::Win32::Security::Cryptography::CryptProtectData(
            &mut in_blob,
            None,
            None,
            None,
            None,
            0,
            &mut out_blob,
        )
        .map_err(|e| anyhow!("CryptProtectData: {e}"))?;
        let slice = std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize);
        Ok(B64.encode(slice))
    }
}

#[cfg(windows)]
fn dpapi_unprotect_windows(encoded: &str) -> Result<Vec<u8>> {
    use std::ptr;
    type Blob = windows::Win32::Security::Cryptography::CRYPT_INTEGER_BLOB;
    let data = B64.decode(encoded)?;
    let mut in_blob = Blob {
        cbData: data.len() as u32,
        pbData: data.as_ptr() as *mut u8,
    };
    let mut out_blob = Blob {
        cbData: 0,
        pbData: ptr::null_mut(),
    };
    unsafe {
        windows::Win32::Security::Cryptography::CryptUnprotectData(
            &mut in_blob,
            None,
            None,
            None,
            None,
            0,
            &mut out_blob,
        )
        .map_err(|e| anyhow!("CryptUnprotectData: {e}"))?;
        Ok(std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize).to_vec())
    }
}

/// Decrypt a channel artifact blob produced by `examples/encrypt-artifact.rs`.
///
/// Format: `[salt 16B][iv 16B][hmac 32B][ciphertext (AES-256-CBC PKCS7)]`
/// KDF: PBKDF2-SHA256 × 200 000 → 64 bytes ([enc_key 32][mac_key 32])
pub fn channel_decrypt(password: &str, blob: &[u8]) -> Result<Vec<u8>> {
    use aes::Aes256;
    use cbc::Decryptor;
    use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
    use hmac::{Hmac, KeyInit, Mac};
    use pbkdf2::pbkdf2_hmac_array;
    use sha2::Sha256;
    type HmacSha256 = Hmac<Sha256>;

    if blob.len() < 64 {
        return Err(anyhow!("encrypted blob too short"));
    }
    let salt       = &blob[0..16];
    let iv         = &blob[16..32];
    let stored_mac = &blob[32..64];
    let ciphertext = &blob[64..];

    // Derive keys
    let derived: [u8; 64] = pbkdf2_hmac_array::<Sha256, 64>(
        password.as_bytes(), salt, 200_000,
    );
    let (enc_key, mac_key) = derived.split_at(32);

    // Verify MAC before decrypting
    let mut mac = HmacSha256::new_from_slice(mac_key)
        .map_err(|e| anyhow!("hmac init: {e}"))?;
    mac.update(salt);
    mac.update(iv);
    mac.update(ciphertext);
    mac.verify_slice(stored_mac)
        .map_err(|_| anyhow!("channel password incorrect or blob corrupted"))?;

    // Decrypt
    Decryptor::<Aes256>::new_from_slices(enc_key, iv)
        .map_err(|e| anyhow!("cipher init: {e}"))?
        .decrypt_padded_vec_mut::<Pkcs7>(ciphertext)
        .map_err(|e| anyhow!("AES-CBC decrypt: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dpapi_round_trip() {
        let plain = b"beta-channel-password";
        let enc = dpapi_protect(plain).unwrap();
        let dec = dpapi_unprotect(&enc).unwrap();
        assert_eq!(dec, plain);
    }
}
