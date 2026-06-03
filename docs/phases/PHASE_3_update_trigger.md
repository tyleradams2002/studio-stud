# Phase 3 — Auto-update trigger off `channelSequence`

> Hand Composer: this file + `docs/REVIEW_2026-06-02.md`. Branch: **`development`**.
> Depends on: **Phase 2** (manifest parses + verifies).

## Goal
Make "push to dev → my machine auto-updates" actually fire. Today updates trigger only when
`manifest.daemonVersion != installed`, but `Cargo.toml` stays `0.4.0` across dev pushes, so it never
fires. CI already increments a monotonic `channelSequence` per publish — use it as the freshness signal,
falling back to semver only when no sequence baseline is recorded yet.

## Pre-flight
```powershell
git switch development
cargo build --workspace && cargo test --workspace
```

---

## G8 — `channelSequence`-based update availability  [M]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channels.rs`
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\setup\src\main.rs` (`cmd_update`, lines 121-174)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channel_update.rs` (`refresh_fields`, lines 49-73)

### 8a. New availability function (channels.rs)
Add beside `channel_update_available`:
```rust
/// Sequence-aware update check. Prefer the monotonic `channelSequence` (advances on every publish,
/// even when the semver version is unchanged). Fall back to a semver compare only when no baseline
/// sequence has been recorded yet (e.g. a just-installed machine that hasn't stored one).
pub fn channel_update_available_seq(
    on_fallback: bool,
    manifest_seq: u64,
    last_seen_seq: u64,
    manifest_version: &str,
    installed: &str,
) -> bool {
    if on_fallback {
        return false;
    }
    if last_seen_seq == 0 {
        return !manifest_version.is_empty()
            && manifest_version != installed
            && crate::update::is_newer(manifest_version, installed);
    }
    manifest_seq > last_seen_seq
}
```
Add a unit test:
```rust
    #[test]
    fn seq_trigger_fires_on_higher_sequence_same_version() {
        // baseline seq 3, published seq 4, same version => update
        assert!(channel_update_available_seq(false, 4, 3, "0.4.0", "0.4.0"));
        // no baseline yet, same version => no update (semver fallback)
        assert!(!channel_update_available_seq(false, 4, 0, "0.4.0", "0.4.0"));
        // fallback channel => never
        assert!(!channel_update_available_seq(true, 9, 1, "0.9.0", "0.4.0"));
    }
```

### 8b. Use it in `cmd_update` (setup/src/main.rs)
Replace the availability computation:
```rust
    let update_available =
        channel_update_available(on_fallback, &manifest.daemon_version, &installed);
```
**with:**
```rust
    let last_seen_seq = cfg
        .last_channel_sequence
        .get(resolved.as_str())
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    let update_available = channel_update_available_seq(
        on_fallback,
        manifest.channel_sequence,
        last_seen_seq,
        &manifest.daemon_version,
        &installed,
    );
```
Update the import line (`use studio_stud::setup_core::channels::{…}`) to add
`channel_update_available_seq`. Keep `channel_update_available` import only if still used elsewhere
(it isn't after this — remove to avoid an unused-import warning).

### 8c. Use it in the ping cache (channel_update.rs `refresh_fields`)
Replace:
```rust
        let on_fallback = resolved != requested;
        let update_available =
            channel_update_available(on_fallback, &manifest.daemon_version, &installed);
```
**with:**
```rust
        let on_fallback = resolved != requested;
        let last_seen_seq = self
            .cfg
            .last_channel_sequence
            .get(resolved.as_str())
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let update_available = channel_update_available_seq(
            on_fallback,
            manifest.channel_sequence,
            last_seen_seq,
            &manifest.daemon_version,
            &installed,
        );
```
Update the `use super::channels::{…}` import accordingly.

> Note: the install/update flow already records the channel sequence via
> `record_channel_sequence` (`setup/src/update_apply.rs:51`), so after one update the baseline advances
> and subsequent checks compare correctly. Fresh-install seq baselining lands cleanly in Phase 4 when the
> install fetches the channel bundle; until then a fresh install reports via the semver fallback (no false
> "update available").

**Acceptance:** unit test `seq_trigger_fires_on_higher_sequence_same_version` passes; `cargo build
--workspace` clean (no unused-import warnings).

---

## Verification (return to Claude)
```powershell
cargo build --workspace
cargo test --workspace
cargo test -p studio-stud seq_trigger_fires_on_higher_sequence_same_version
```
Manual (needs a dev publish): publish the dev channel twice with no version bump; on a dev install,
`studio-stud-setup update --check --json` should report `updateAvailable:true` after the second publish,
and `false` immediately after running `studio-stud-setup update`.

## Done when
`cargo test --workspace` green; a same-version dev republish makes `update --check` report an available
update, and applying it clears the flag.
