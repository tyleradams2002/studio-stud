# Phase 1 — Independent quick wins

> Hand Composer: this file + `docs/REVIEW_2026-06-02.md`. Branch: **`development`**.
> Depends on: nothing. These six steps are independent and can land in any order.

## Goal
Unblock the release signature check, stop forcing UAC, hide the dead daemon update CLI, fix the local
install test script, and install the multi-developer gitignore boundary. No behavior change to capture.

## Pre-flight
```powershell
git switch development
cargo build --workspace      # must succeed before changes
cargo test --workspace       # baseline green
```

---

## G1 — Signature: skip when absent  [S]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channels.rs` (in `verify_manifest_signature`, ~lines 128-131)
**Why:** the release manifest is intentionally unsigned (decision D2); a present real key currently makes
verification mandatory, so every release `update`/health errors.

**Change — replace:**
```rust
    let sig_b64 = manifest
        .signature
        .as_deref()
        .ok_or_else(|| anyhow!("manifest has no signature field"))?;
```
**with:**
```rust
    let Some(sig_b64) = manifest.signature.as_deref() else {
        // Unsigned channel (release): nothing to verify.
        return Ok(());
    };
```

**Add a unit test** in the existing `#[cfg(test)] mod tests` block at the bottom of the file:
```rust
    #[test]
    fn verify_skips_when_signature_absent() {
        // Real-looking embedded key path is irrelevant: absent signature => Ok regardless.
        let raw = json!({ "daemonVersion": "0.4.0", "channelSequence": 1 });
        let m: ChannelManifest = serde_json::from_value(raw.clone()).unwrap();
        assert!(verify_manifest_signature(&raw, &m).is_ok());
    }
```
**Acceptance:** `cargo test -p studio-stud verify_skips_when_signature_absent` passes; a manifest with a
present-but-wrong signature still errors (existing behavior).

---

## G2 — Setup runs asInvoker (no UAC)  [S]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\setup\manifest.xml` (line 9)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\setup\build.rs` (comment, lines 2-4)

**Why:** every write targets HKCU + `%LOCALAPPDATA%` (user-owned); read-only `health`/`update --check`
should not pop UAC (decision D5).

**Change manifest.xml — replace:**
```xml
        <!-- requireAdministrator: always prompt for elevation via UAC.
             Installation writes to user PATH (registry) and program dirs,
             which is reliable from an elevated context. -->
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
```
**with:**
```xml
        <!-- asInvoker: no elevation. All writes target HKCU (user PATH) and
             %LOCALAPPDATA% (install root, plugins, config) — user-owned, no admin needed. -->
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
```
**Update build.rs comment** (lines 2-4) to state asInvoker is intentional (HKCU/LOCALAPPDATA only), not a
cargo-test workaround.

**Acceptance:** `cargo build -p studio-stud-setup` succeeds; running `studio-stud-setup health` from a
non-elevated terminal does **not** trigger a UAC prompt.

---

## G3 — Hide the daemon-side update CLI  [S]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\cli.rs`
**Why:** update ownership moved to the setup binary; the daemon paths are gutted no-ops (decision D6).
Keep `apply_staged_on_boot` (load-bearing).

**Change — add `#[command(hide = true)]` to the `Update` subcommand (~line 164):**
```rust
    /// Deprecated: update is owned by studio-stud-setup. Kept as a no-op alias.
    #[command(hide = true)]
    Update {
        #[arg(long)]
        check: bool,
    },
```
**Hide `--no-update`** on both `Serve` (lines 145-147) and `Daemon` (lines 158-160): change each
`#[arg(long)]` above `no_update` to `#[arg(long, hide = true)]` and update the doc-comment to
`/// Deprecated no-op (update is owned by studio-stud-setup).`

Leave `cmd_serve`'s `crate::update::apply_staged_on_boot()` (`src/cli.rs:716`) untouched.

**Acceptance:** `studio-stud --help` no longer lists `update` or `--no-update`; `studio-stud update --check`
still runs; `studio-stud serve` still applies a staged `.exe.new` swap on boot.

---

## G4 — Fix `install-local.ps1`  [S]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\scripts\install-local.ps1`
**Why:** `--no-gui` is not a real flag (real one is `--silent`, `setup/src/main.rs:36-39`); `-CleanFirst`
wipes the wrong dirs so fresh-install tests are invalid.

**Change 1 — headless flag (line 87):**
```powershell
    & $SetupExe install --silent
```
**Change 2 — clean targets (lines 53-77):** the real install root is `%LOCALAPPDATA%\Programs\StudioStud`
and the PATH bin is `…\Programs\StudioStud\bin`; config lives at `%LOCALAPPDATA%\StudioStud\config.json`.
Replace the `$installRoot` / `$shimDir` logic with:
```powershell
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\StudioStud'
    Write-Host "[2/4] CleanFirst: removing $installRoot ..."
    if (Test-Path $installRoot) {
        $lockFile = Join-Path $env:LOCALAPPDATA 'StudioStud\daemon.lock'
        if (Test-Path $lockFile) {
            try {
                $lock = Get-Content $lockFile | ConvertFrom-Json
                if ($lock.port) {
                    Invoke-RestMethod "http://127.0.0.1:$($lock.port)/studio-stud/admin/shutdown" `
                        -Method Post -TimeoutSec 3 | Out-Null
                    Start-Sleep -Milliseconds 800
                }
            } catch {}
        }
        Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Clear the registry/config too so the installer treats this as a fresh machine.
    $configDir = Join-Path $env:LOCALAPPDATA 'StudioStud'
    if (Test-Path $configDir) { Remove-Item $configDir -Recurse -Force -ErrorAction SilentlyContinue }
```
(Drop the old `studio-stud-bin` shim removal — that path never existed in the current layout.)

**Acceptance:** `scripts\install-local.ps1 -CleanFirst -Headless` runs the silent install end-to-end and,
after the PATH refresh, `studio-stud --version` prints. (Note: silent install still needs the daemon/plugin
locally — run `scripts\build-local.ps1` + `cargo build --release -p studio-stud-setup` first, or use the
dev `target\debug` siblings. Full clean-machine install is Phase 4.)

---

## G5 — Consumer-repo `.studio-stud/.gitignore` boundary  [S]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\install.rs` (`write_starter_policy`, lines 92-111)
**Why:** the consumer `.studio-stud/` folder mixes committed shared config with per-machine state; without
a managed ignore, a dev can commit local state and clobber concurrent teammates (decision D9). The current
early-return on existing `policy.json` means existing installs never get the gitignore — fix that too.

**Change — add a module const near the top of `install.rs` (after the existing `const` lines ~11-12):**
```rust
const STUDIO_STUD_DIR_GITIGNORE: &str = "\
# Studio Stud — per-repo managed folder.
# COMMITTED (shared across all developers): policy.json, addons/, this file.
# IGNORED (per-machine, never commit): everything else
#   .installed, base-ledger/, stash/, merge/, write.token, *.tmp, cache/
*
!.gitignore
!policy.json
!addons/
!addons/**
";
```
**Replace the body of `write_starter_policy`** so the gitignore is written independent of policy existence:
```rust
pub fn write_starter_policy(repo_root: &Path) -> Result<()> {
    let policy_dir = repo_root.join(".studio-stud");
    fs::create_dir_all(&policy_dir)?;

    let gitignore_path = policy_dir.join(".gitignore");
    if !gitignore_path.is_file() {
        fs::write(&gitignore_path, STUDIO_STUD_DIR_GITIGNORE)?;
    }

    let policy_path = policy_dir.join("policy.json");
    if !policy_path.is_file() {
        let starter = json!({
            "version": 1,
            "allowedPlaceIds": [],
            "allowedWritePaths": [],
            "requireGeneratedHeaderPaths": [],
            "maxPatchBytes": 1048576,
            "maxPatchItems": 500,
            "maxDeleteCount": 50,
        });
        fs::write(&policy_path, serde_json::to_string_pretty(&starter)?)?;
    }

    let marker = repo_root.join(REPO_MARKER);
    if !marker.is_file() {
        fs::write(&marker, crate::util::now_utc())?;
    }
    Ok(())
}
```
**Acceptance:** `studio-stud-setup repo-repair <some-test-repo>` produces `.studio-stud/.gitignore`; in that
repo, `git status` would track `policy.json` and ignore a stub `.studio-stud/.installed`. Re-running on a
repo that already has `policy.json` still creates the missing `.gitignore`.

---

## G5b — Dev-repo `.gitignore` correction (this repo)  [S]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\.gitignore`
**Why:** `package-release.ps1` and the Phase-4 bundle write to `dist/`, which is **not** ignored — built
exes / the bundle ZIP could be committed by accident.

**Change — under the `# Rust build output` section (after `/bin`), add:**
```gitignore
/dist
```
Do **not** touch the `secrets/*` + `!secrets/channel-signing.pub` force-include (that pub key is compiled
in via `include_str!` at `src/setup_core/channels.rs:13-14` and must stay committed).

**Acceptance:** after `scripts\package-release.ps1`, `git status` shows no `dist/` entries;
`git check-ignore secrets/channel-signing.pub` prints nothing (still committed).

---

## Verification (return to Claude)
Run together after Composer reports done:
```powershell
cargo build --workspace
cargo test --workspace
cargo test -p studio-stud verify_skips_when_signature_absent
studio-stud --help            # no 'update'; no '--no-update' under serve
studio-stud-setup health      # no UAC prompt
git check-ignore secrets/channel-signing.pub   # prints nothing
```
- Confirm `.gitignore` now ignores `/dist`.
- Confirm `write_starter_policy` emits `.studio-stud/.gitignore` (point Claude at a temp repo or the unit
  behavior).

## Done when
All commands above pass, `cargo test --workspace` is green, and no capture/live/write code was touched.
