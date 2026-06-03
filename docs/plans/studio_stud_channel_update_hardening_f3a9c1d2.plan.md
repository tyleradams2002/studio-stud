---
name: Studio Stud — Channel + Auto-Update Hardening
overview: Fix and harden the three-channel (dev/beta/release) distribution + auto-update system so that (1) auto-update actually downloads and applies new builds for real users on every channel, (2) install and update both fall back dev→beta→release so a user always has a version, (3) anti-rollback channelSequence actually increments across deploys, (4) the in-Studio plugin reflects the user's real channel for update nudges, (5) a release published ahead of beta is detected and warned (not blocked), and (6) channel identity survives config loss. Password rotation is explicitly OUT OF SCOPE. All work must preserve backward compatibility: any older daemon must keep working against any artifact, and policy.json schema rules in .cursor/rules/policy-schema-compat.mdc must be followed.
todos: []
isProject: false
---

# Studio Stud — Channel + Auto-Update Hardening (Execution Plan)

Status: READY TO EXECUTE. This plan is self-contained; the executing agent has no prior
conversation context. Read the referenced files before editing. Follow the existing code
style. Run `cargo test -p studio-stud` after each phase and keep it green.

## Background you need

Studio Stud ships on **three channels** that map to git branches and GitHub Pages paths:

| Channel | Branch | Pages manifest | Artifact |
|---------|--------|----------------|----------|
| release | `main` | `https://tyleradams2002.github.io/studio-stud/latest.json` | plain `studio-stud-setup.exe` (GitHub Release asset, via `setupUrl`) |
| beta | `beta` | `.../beta/latest.json` | encrypted `studio-stud-setup.exe.enc` (Pages, via `setupEncUrl`) |
| dev | `development` | `.../dev/latest.json` | encrypted `studio-stud-setup.exe.enc` (Pages, via `setupEncUrl`) |

- The user's channel is stored in `%LOCALAPPDATA%\StudioStud\config.json` (`StudioStudConfig.channel`).
- `studio-stud-setup` (the `setup/` crate) is the **single update owner**. The daemon (`src/`)
  only applies a previously staged exe swap on `serve` startup.
- Beta/dev artifacts are encrypted; the channel password is stored DPAPI-protected in
  `cfg.channel_key_dpapi` and decrypted with `setup_core::crypto::channel_decrypt`.
- Manifests are ed25519-signed; `channelSequence` is a monotonic counter used for anti-rollback.

### Already-implemented foundations (DO NOT re-do; build on these)

- `src/setup_core/channels.rs`:
  - `Channel` enum (`Release`/`Beta`/`Dev`), `manifest_url()`, `is_encrypted()`.
  - `fetch_manifest(channel) -> (ChannelManifest, Value)`.
  - **`fetch_manifest_with_fallback(channel) -> (ChannelManifest, Value, Channel)`** — walks
    dev→beta→release (or beta→release, or release) until one responds; returns the resolved channel.
  - `verify_manifest_signature`, `check_anti_rollback`.
  - `ChannelManifest` fields: `daemon_version`, `plugin_version`, `protocol_version`,
    `binary_url`, `plugin_url`, `setup_url`, `setup_enc_url`, `channel_sequence`, `signature`,
    `kdf_salt`, `kdf_nonce`.
- `src/update.rs`:
  - `pub fn installed_version() -> String`.
  - `pub fn is_newer(latest, current) -> bool`.
  - `fn download_to(url, dest) -> Result<u64>` — **currently dead code; reuse it** (make it `pub`).
  - `fn stage(...)`, `fn plugin_path(...)` — dead/legacy; ignore or remove if unused after this work.
  - `apply_staged_on_boot()` — daemon-side staged swap; leave as-is.
- `setup/src/main.rs`:
  - `cmd_update(check, as_json)` — already fetches with fallback, verifies signature, checks
    anti-rollback, compares `installed_version()` vs `manifest.daemon_version`, and gates updates
    with `on_fallback` (never updates while on a fallback channel — see Issue context below).
  - **`apply_user_update(cfg)` — BROKEN. This is Phase 1's target.**
- `src/setup_core/crypto.rs`: `channel_decrypt(password, blob)`, `dpapi_protect`, `dpapi_unprotect`.
- `src/setup_core/config.rs`: `StudioStudConfig { channel, channel_key_dpapi, install_root,
  plugins_dir, repos, versions, last_channel_sequence, ... }`, `load_config_or_default`, `save_config`.
- `setup/src/gui.rs`: `run_install`, `InstallApp` (the GUI installer; `run_install` is the headless-ish
  core but currently reads from the `InstallApp` struct).

### Hard constraints (apply to ALL phases)

1. **Backward compatibility is mandatory.** An older daemon/setup binary must keep working against
   any manifest or artifact produced after this work. Never remove or rename a manifest field; only
   add optional fields. Follow `.cursor/rules/policy-schema-compat.mdc` for any `policy.json` change
   (do not reintroduce a manual version constant).
2. **Fallback never causes an update.** If the user's channel hasn't published yet and we resolve to
   a fallback channel, we must NOT update them onto the fallback channel's version. We keep them
   running and switch them to their real channel only once it publishes. (Already implemented in
   `cmd_update` via `on_fallback`; preserve this behavior everywhere.)
3. **Setup binary stays the single update owner.** Do not move download/apply into the daemon.
4. **Windows is the only runtime target.** DPAPI + the encrypted-channel path only work on Windows.
5. After building the `setup` crate, a stale `studio-stud-setup.exe` process can lock the output and
   block rebuilds. If a build fails with `os error 5 / Access is denied` on that exe, stop the
   process and rebuild.

### Decisions already made (do not re-litigate)

- **Issue #5 (release ahead of beta):** WARN ONLY. Never hard-block a release publish.
- **Issue #7 (channel publishes an older version than installed):** SWITCH to match the channel.
  Being on your channel is the contract; if dev publishes v0.4.9 while you run v0.5.0 (from a prior
  release fallback), switch down to v0.4.9 and print a clear note. Anti-rollback still applies
  (a published manifest with a lower `channelSequence` than the recorded floor is still rejected).
- **Password rotation: OUT OF SCOPE.** Do not implement re-prompt-on-decrypt-failure in this plan.

---

## Phase 1 — Make auto-update actually download and apply (CRITICAL)

**Problem.** `apply_user_update()` in `setup/src/main.rs` copies the daemon/plugin from
compile-time `env!("CARGO_MANIFEST_DIR")` paths. Those are build-machine paths that do not exist on
a user's machine, so auto-update detects correctly but applies nothing. It never downloads from the
network.

**Goal.** Rewrite the apply path to download the real artifact for the resolved channel, then run a
**silent reinstall** that lays down the new daemon + plugin, then advance the anti-rollback floor.

### 1a. Add a silent install mode to the setup binary

- In `setup/src/main.rs`, add a `--silent` flag to the `Install` subcommand (clap).
- Refactor `setup/src/gui.rs::run_install` so its core install logic (lay payload, install core
  plugin, install path shim, register repos, write config) is callable **without the GUI** using the
  existing saved config. Extract a function, e.g.:
  ```rust
  // setup/src/install_flow.rs (new) or a pub fn in gui.rs
  pub fn run_install_headless(
      install_root: &Path,
      plugins_dir: &Path,
      daemon_src: &Path,
      plugin_src: &Path,
      repos: &[String],
  ) -> anyhow::Result<()>;
  ```
  The GUI's `run_install` should call this same function so there is ONE install code path.
- `studio-stud-setup install --silent` reads `load_config_or_default()` for `install_root`,
  `plugins_dir`, and `repos`, and runs `run_install_headless` using daemon/plugin sources found
  **next to the running setup exe** (the downloaded payload), NOT `CARGO_MANIFEST_DIR`.

### 1b. Rewrite `apply_user_update`

New signature (pass the data `cmd_update` already has):
```rust
fn apply_user_update(
    cfg: &StudioStudConfig,
    manifest: &ChannelManifest,
    resolved: Channel,
) -> Result<()>;
```

Logic:
1. Stop the running daemon if present (existing code: `read_daemon_lock_port` +
   `stop_daemon_graceful`). Keep it.
2. Download the setup artifact to `%TEMP%\studio-stud-setup.exe`:
   - `Channel::Release`: download `manifest.setup_url` directly (make `update::download_to` `pub`
     and reuse it).
   - `Channel::Beta` / `Channel::Dev`: download `manifest.setup_enc_url` to a temp `.enc`, recover
     the password via `dpapi_unprotect(cfg.channel_key_dpapi)`, `channel_decrypt(password, blob)`,
     write the plaintext exe to `%TEMP%\studio-stud-setup.exe`.
     - If `channel_key_dpapi` is missing or decrypt fails: return a clear error instructing the user
       to reinstall via the channel installer. (Do NOT implement re-prompt — out of scope.)
3. Launch the downloaded setup: `studio-stud-setup.exe install --silent` and wait for it to finish.
   That child process performs the actual file replacement (it has the new daemon+plugin embedded
   next to it OR downloads them — see 1c).
4. On success, record the sequence floor and persist:
   ```rust
   cfg_mut.last_channel_sequence.insert(resolved.as_str().into(), json!(manifest.channel_sequence));
   save_config(&cfg_mut)?;
   ```
5. `update::apply_staged_on_boot()` stays as the daemon-side safety net.

### 1c. Where do the new daemon.exe + plugin.lua come from?

The downloaded `studio-stud-setup.exe` must be able to lay down the new daemon and plugin. Two
options — pick **Option A** (simplest, matches today's release packaging):

- **Option A (recommended):** The setup artifact is the full installer that already contains/locates
  the daemon + plugin payload (this is how the GitHub Release `studio-stud-setup.exe` + the
  `package-release.ps1` bundle work). `run_install_headless` lays the bundled payload. Verify by
  reading `scripts/package-release.ps1` to confirm what the setup exe ships with. If the setup exe
  needs the daemon/plugin alongside it, ensure the download step fetches `binary_url` and
  `plugin_url` too and places them where `run_install_headless` expects.
- Option B (only if A is infeasible): setup downloads `binary_url` + `plugin_url` from the manifest
  itself. More moving parts; avoid unless required.

Document which option you implemented in the file you touch.

### 1d. Update `cmd_update` call site

Change the existing `apply_user_update(&cfg)?;` call to pass the manifest + resolved channel that
`cmd_update` already computed. Do not refetch.

### Phase 1 tests

- Unit-test the artifact-selection logic: given a `Channel` + a `ChannelManifest`, assert the correct
  URL (`setup_url` vs `setup_enc_url`) is chosen and missing-URL produces a clear error.
- Unit-test that `last_channel_sequence` is written for the resolved channel after a simulated apply
  (factor the sequence-write into a small testable function).
- The actual network download + decrypt + silent reinstall is NOT unit-testable here (needs real
  secrets + published artifact). Leave a `// MANUAL SMOKE TEST:` comment describing the steps.

---

## Phase 2 — Install-time fallback (dev→beta→release)

**Problem.** `site/install.ps1` fetches a single channel manifest and hard-errors if it's missing.
A user installing on dev/beta before that channel's first publish cannot install at all.

**Fix.** In `site/install.ps1`, replace the single `$manifestUrl` fetch with an ordered list and try
each until one succeeds (mirrors `fetch_manifest_with_fallback`):

```powershell
$urls = switch ($Channel) {
    'dev'  { @("$PagesBase/dev/latest.json", "$PagesBase/beta/latest.json", "$PagesBase/latest.json") }
    'beta' { @("$PagesBase/beta/latest.json", "$PagesBase/latest.json") }
    default { @("$PagesBase/latest.json") }
}
$manifest = $null; $resolvedUrl = $null
foreach ($u in $urls) {
    try { $manifest = Invoke-RestMethod $u -ErrorAction Stop; $resolvedUrl = $u; break } catch {}
}
if (-not $manifest) { throw "No manifest reachable for channel '$Channel' (tried: $($urls -join ', '))." }
```

Then the existing release-vs-encrypted branch logic keys off whether the resolved manifest has
`setupUrl` (plain/release) or `setupEncUrl` (encrypted). If it fell back to release while installing
beta/dev, the artifact is the plain release exe — handle that (no password prompt needed).
Print a clear note when falling back. Keep `install-beta.ps1` / `install-dev.ps1` unchanged (they
just call `install.ps1 -Channel ...`).

### Phase 2 tests
PowerShell isn't unit-tested in this repo. Add a comment block at the top of the fallback section
describing the manual test (point `-PagesBase` at a fixture or rely on the live site).

---

## Phase 3 — Make anti-rollback `channelSequence` actually increment

**Problem.** In `.github/workflows/deploy.yml`, both the beta and dev jobs read the previous
`channelSequence` from `site/beta/latest.json` / `site/dev/latest.json` **in the repo checkout**.
That file is never committed back after a deploy, so `prevSeq` is always 0 and `nextSeq` is always 1.
The sequence never increases, so `check_anti_rollback` can never detect a rollback.

**Fix.** Read the previous sequence from the **live gh-pages manifest**, not the repo checkout.

In `deploy.yml`, in both the beta and dev "Build + sign manifest" steps, before computing `$nextSeq`:
```powershell
$prevSeq = 0
try {
  $live = Invoke-RestMethod "https://tyleradams2002.github.io/studio-stud/beta/latest.json" -ErrorAction Stop
  if ($live.channelSequence) { $prevSeq = [int]$live.channelSequence }
} catch { $prevSeq = 0 }   # 404 on first-ever publish → start at 0
$nextSeq = $prevSeq + 1
```
(Use the `/dev/latest.json` URL in the dev job.)

Apply the **same fix** to `scripts/publish-channel.ps1` (local publish path) so local and CI agree.

For the **release** channel: `scripts/package-release.ps1` hardcodes `channelSequence = 1`. Change it
to read the live release manifest the same way and increment. (Release is published by CI on tag; the
committed `site/latest.json` is the seed — read the LIVE one for the floor.)

### Phase 3 tests
CI-only; cannot run locally. Recommend the executor validate on a throwaway branch and confirm the
published `channelSequence` increments across two deploys. Add a comment in `deploy.yml` explaining
why it reads the live manifest (so it isn't "fixed" back later).

---

## Phase 4 — Plugin reflects the user's real channel

**Problem.** `plugin/StudioStud.plugin.lua` line ~20 hardcodes
`UPDATE_MANIFEST_URL = ".../latest.json"` (release). Beta/dev users never see an in-Studio
"update available" nudge for their channel.

**Fix (keep all channel logic in Rust).**
1. The daemon already loads `cfg.channel` for `serve`. In `src/http.rs`, the `/studio-stud/ping`
   handler should resolve the channel manifest (with fallback, best-effort, throttled/cached so it
   doesn't hit the network on every ping) and ADD two fields to the ping JSON response:
   `latestDaemonVersion` (string) and `updateAvailable` (bool, false while on fallback).
   - These are **additive** fields → no `PROTOCOL_VERSION` bump.
   - Network failure → omit the fields or set `updateAvailable=false`; never block ping.
   - Cache the manifest result in the daemon for ~daily to avoid per-ping network calls.
2. In `plugin/StudioStud.plugin.lua`, stop fetching `latest.json` directly. Read
   `latestDaemonVersion` / `updateAvailable` from the ping response and show the existing
   "Update available" status line based on those. Remove `UPDATE_MANIFEST_URL` usage (the
   `UPDATE_INSTALL_HINT` string can stay).

### Phase 4 tests
- Rust: extend an existing ping/http test to assert the new fields are present and that
  `updateAvailable` is `false` when on fallback / when no newer version.
- Plugin Luau has no automated tests; describe the manual Studio check in a comment.

---

## Phase 5 — Version-direction guardrails (warn-only)

**Issue #7 — channel publishes older than installed (SWITCH + note).**
In `cmd_update` (`setup/src/main.rs`), when NOT on fallback (resolved == requested):
- Today: `update_available = is_newer(manifest, installed)`.
- Change to: if `manifest.daemon_version != installed`, treat it as an update REGARDLESS of
  direction (newer OR older), because matching your channel is the contract. Anti-rollback
  (`check_anti_rollback`) still guards against a manifest whose `channelSequence` is below the
  recorded floor, so a malicious downgrade is still rejected; a legitimate channel downgrade
  (higher sequence, lower version) is allowed.
- When the version goes DOWN, print a clear note:
  `note: switching to <channel> v<X> (was v<Y>) — matching your channel's current build`.
- Keep `on_fallback` behavior unchanged (fallback still never updates).

**Issue #5 — release ahead of beta (WARN ONLY, never block).**
- Add a step to the release deploy path that, after computing the release version, fetches the live
  beta manifest and if `release_version` is newer than `beta_version`, emits a GitHub Actions
  warning (`::warning::Release vX is ahead of beta vY — beta users will not receive this until it is
  promoted to beta.`). Do NOT fail the job. Implement in `.github/workflows/deploy.yml` (release job)
  or `promote.yml`, wherever the release version is known.

### Phase 5 tests
- Rust: unit-test the new direction logic — equal versions → no update; different (either direction)
  + not fallback → update; fallback → no update.
- CI warn step: comment-documented manual check.

---

## Phase 7 — Channel identity survives config loss

**Problem.** If `config.json` is missing/corrupt, `load_config_or_default()` silently returns the
default (channel = release) and an empty `last_channel_sequence`, silently switching the user to
release and zeroing their anti-rollback floor.

**Fix.**
1. In `src/setup_core/config.rs`, distinguish "missing" from "corrupt". On a parse error in
   `load_config`, back up the bad file to `config.json.corrupt-<timestamp>` and log a warning, rather
   than silently defaulting. (`load_config_or_default` may still fall back to default, but the backup
   + warning must happen.)
2. Persist a minimal channel marker outside `config.json` so identity survives its loss. Reuse the
   installed `version.json` next to the daemon exe (already written by the install/update flow): add
   `channel` and `lastChannelSequence` keys to it. On config load failure, seed `channel` and
   `last_channel_sequence` from `version.json` if present.
   - `version.json` is written by `src/update.rs` (`write_version_json`) and
     `scripts/package-release.ps1`. Adding keys is additive; older readers ignore them.

### Phase 7 tests
- Unit-test: corrupt config file → backup created + warning path taken (factor the backup into a
  testable function using a temp dir + `STUDIO_STUD_CONFIG` env override, which `config_path()`
  already honors).
- Unit-test: missing config + present `version.json` with `channel=beta` → resolved channel is beta.

---

## Execution order & checkpoints

1. **Phase 1** (apply update) — unblocks everything. Land + green tests first.
2. **Phase 2** (install fallback) — independent, small.
3. **Phase 3** (rollback sequence) — CI only, isolated.
4. **Phase 5** (#7 direction + #5 warn) — small Rust + small CI.
5. **Phase 4** (plugin via ping) — larger surface, additive protocol.
6. **Phase 7** (config hardening) — defensive.

After EACH phase:
- `cargo test -p studio-stud` must pass (58 tests today).
- `cargo build -p studio-stud-setup` must compile (kill any locked `studio-stud-setup.exe` first).
- Do not introduce new clippy warnings beyond the pre-existing dead-code ones in `src/update.rs`
  (`download_to`/`stage`/`plugin_path` — Phase 1 will consume `download_to`).

## Out of scope (do not implement)
- Password rotation / re-prompt on decrypt failure.
- Hard-blocking a release publish when beta is behind (warn only).
- Any server-side infrastructure.
- Reintroducing a manual policy version constant (`MAX_POLICY_VERSION`) — the policy schema is now
  kept backward-compatible by construction per `.cursor/rules/policy-schema-compat.mdc`.

## Definition of done
- A real user on any channel running `studio-stud-setup update` downloads and installs the correct
  artifact for their resolved channel (verified by manual smoke test on Windows with secrets).
- Installing on an unpublished channel falls back and succeeds.
- Published `channelSequence` increments across consecutive deploys.
- Beta/dev users see an accurate "update available" nudge in Studio.
- A channel that publishes an older build switches the user down with a clear note; a malicious
  rollback (lower sequence) is still rejected.
- Release-ahead-of-beta emits a CI warning, not a failure.
- Corrupt/missing config no longer silently changes channel; channel identity is recoverable from
  `version.json`.
- `cargo test -p studio-stud` green; `setup` crate compiles.

---

## Manual verification checklist (PENDING — run before treating this work as done)

Track these for a later session. Requires Windows, channel secrets, and/or a CI deploy.

- [ ] **`studio-stud-setup update` end-to-end** — on a real install, run `update --check` then `update`;
      confirm `%LOCALAPPDATA%\Programs\StudioStud\bin\` (or configured install root) reflects the new
      daemon version from the correct channel manifest.
- [ ] **Beta/dev encrypted update** — beta user with `channel_key_dpapi` in config; push a new beta
      build, run `studio-stud-setup update`, confirm decrypt + apply. (If password not stored at
      install, expect the clear reinstall error — wiring password storage at install is still a gap.)
- [ ] **Install fallback** — run `install-dev.ps1` or `install-beta.ps1` before that channel's first
      publish; confirm fallback note and successful install via release manifest.
- [ ] **`channelSequence` increment** — deploy twice to the same channel on a throwaway branch;
      confirm live `latest.json` sequence increases (beta/dev/release as applicable).
- [ ] **Release-ahead-of-beta CI warn** — merge to main with release version > beta; confirm
      `::warning::` in deploy job logs (not a failure).
- [ ] **Studio update nudge** — beta/dev user: Connect in Studio; confirm status shows channel-aware
      update from ping (not release-only `latest.json` fetch).
- [ ] **Switch-down note** — dev channel publishes older version than installed; run
      `studio-stud-setup update --check` and confirm switch-down note + apply behavior.
- [ ] **Config recovery** — corrupt `config.json` (invalid JSON); confirm backup file created and
      channel restored from `install_root/version.json` on next load.
