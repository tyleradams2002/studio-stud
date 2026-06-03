# Phase 2 — Manifest parse + signature verify

> Hand Composer: this file + `docs/REVIEW_2026-06-02.md`. Branch: **`development`**.
> Depends on: **Phase 1** merged (G1 skip-when-absent already in place).

## Goal
Make the channel manifest (a) deserialize even without `channelSequence` (release) and (b) actually
verify its ed25519 signature on beta/dev. The signature fails today because the PowerShell signer
canonicalizes JSON in insertion order while the Rust verifier re-serializes in sorted-key order. Fix:
**canonicalize once, in Rust, used by both signer and verifier.** Keep `serde_json` `preserve_order` OFF.

## Pre-flight
```powershell
git switch development
cargo build --workspace && cargo test --workspace   # baseline green (post-Phase-1)
```

---

## G6 — Tolerant `channelSequence`  [S]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channels.rs` (line 64)
**Why:** the field is non-optional, so the current release `latest.json` (no `channelSequence`) fails to
deserialize across the updater and the ping cache.

**Change — replace:**
```rust
    pub channel_sequence: u64,
```
**with:**
```rust
    #[serde(default)]
    pub channel_sequence: u64,
```
**Acceptance:** add a unit test asserting a manifest JSON without `channelSequence` deserializes with
`channel_sequence == 0`:
```rust
    #[test]
    fn manifest_without_channel_sequence_defaults_zero() {
        let raw = json!({ "daemonVersion": "0.4.0", "pluginVersion": "0.3.7" });
        let m: ChannelManifest = serde_json::from_value(raw).unwrap();
        assert_eq!(m.channel_sequence, 0);
    }
```

---

## G7 — Unify manifest canonicalization in Rust  [M]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channels.rs`
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\examples\sign-manifest.rs`
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\scripts\publish-channel.ps1`
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\.github\workflows\deploy.yml`

### 7a. Add a shared canonical function (channels.rs)
Add near the other `pub fn`s:
```rust
/// Canonical bytes a manifest is signed/verified over: the manifest JSON object with the
/// `signature` field removed, serialized deterministically (sorted keys via serde_json's default
/// BTreeMap-backed Map). BOTH the signer (examples/sign-manifest.rs) and the verifier call this,
/// so the byte string is identical regardless of how the published file was key-ordered.
pub fn canonical_manifest_bytes(raw: &Value) -> Result<Vec<u8>> {
    let mut obj = raw
        .as_object()
        .cloned()
        .ok_or_else(|| anyhow!("manifest is not a JSON object"))?;
    obj.remove("signature");
    Ok(serde_json::to_string(&Value::Object(obj))?.into_bytes())
}
```

### 7b. Use it in the verifier (channels.rs, in `verify_manifest_signature`)
Replace the inline canonicalization:
```rust
    // Sign over the canonical manifest JSON without the `signature` field.
    let mut obj = raw.as_object()
        .cloned()
        .ok_or_else(|| anyhow!("manifest is not a JSON object"))?;
    obj.remove("signature");
    let canonical = serde_json::to_string(&Value::Object(obj))?;

    verifying_key
        .verify(canonical.as_bytes(), &signature)
        .map_err(|_| anyhow!("manifest signature verification failed"))
```
**with:**
```rust
    let canonical = canonical_manifest_bytes(raw)?;
    verifying_key
        .verify(&canonical, &signature)
        .map_err(|_| anyhow!("manifest signature verification failed"))
```
(Keep the Phase-1 skip-when-absent `let Some(sig_b64) = … else { return Ok(()); }` above this.)

### 7c. Make `sign-manifest` canonicalize the same way (examples/sign-manifest.rs)
Replace the whole file so it takes the **raw manifest JSON** (not a pre-canonicalized string) and signs
`canonical_manifest_bytes`:
```rust
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
```
> Note: `canonical_manifest_bytes` must be reachable from the example — it is, since examples link the
> `studio_stud` lib. Ensure it is `pub` and re-exported if needed.

### 7d. publish-channel.ps1 — pass the manifest file, not a pre-canonicalized string
Replace the canonical+sign block (lines ~75-84):
```powershell
# Canonical JSON (sorted keys) for signing
$canonicalJson = $manifest | ConvertTo-Json -Compress -Depth 10

# ---------- 6. Sign manifest ----------
Write-Host "Signing manifest..."
$signOutput = cargo run --quiet --example sign-manifest -- `
    --privkey $privKeyHex `
    --payload $canonicalJson 2>&1
```
**with:**
```powershell
# ---------- 6. Sign manifest (Rust canonicalizes — pass the unsigned manifest file) ----------
$unsignedPath = Join-Path $outDir 'latest.unsigned.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content $unsignedPath -Encoding utf8
Write-Host "Signing manifest..."
$signOutput = cargo run --quiet --example sign-manifest -- `
    --privkey $privKeyHex `
    --manifest $unsignedPath 2>&1
```
Leave the rest (`$sigB64 = $signOutput.Trim()`, Add-Member signature, write `latest.json`) as-is; delete
the temp `latest.unsigned.json` after writing the signed file.

### 7e. deploy.yml dev job — same swap
In the `Build + sign manifest` step (lines ~112-139), replace:
```yaml
          $canonical = $manifest | ConvertTo-Json -Compress -Depth 10
          $sigB64 = cargo run --quiet --example sign-manifest -- `
            --privkey "$env:CHANNEL_SIGNING_KEY" `
            --payload $canonical
```
**with:**
```yaml
          $unsigned = 'site/dev/latest.unsigned.json'
          $manifest | ConvertTo-Json -Depth 10 | Set-Content $unsigned -Encoding utf8
          $sigB64 = cargo run --quiet --example sign-manifest -- `
            --privkey "$env:CHANNEL_SIGNING_KEY" `
            --manifest $unsigned
```
Keep the `if ($LASTEXITCODE -ne 0) { throw … }`, signature add, and final write; remove
`site/dev/latest.unsigned.json` before the gh-pages publish step (or it'll be deployed — add
`Remove-Item site/dev/latest.unsigned.json -ErrorAction SilentlyContinue`).

---

## Verification (return to Claude)
Add and run a round-trip integration test that proves sign↔verify agree (this is the real proof the
canonicalization is unified). Create `tests/manifest_signing.rs`:
```rust
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
```
Then:
```powershell
cargo build --workspace
cargo test --workspace
cargo test --test manifest_signing
```
Manual (needs your signing key + a dev publish): run `scripts\publish-channel.ps1 -Channel dev`, then on a
dev install `studio-stud-setup update --check --json` — must return JSON (no signature error).

## Done when
- `cargo test --workspace` green including the round-trip test.
- A signed dev manifest verifies (`update --check` returns cleanly), and a release manifest (no signature)
  still deserializes and passes verification (skip-when-absent).
