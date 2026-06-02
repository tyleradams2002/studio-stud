# Studio Stud — version compatibility

| Component | Source of truth | Notes |
|-----------|-----------------|-------|
| Daemon | `Cargo.toml` `version` | `studio-stud.exe` |
| Setup | `setup/Cargo.toml` `version` | `studio-stud-setup.exe` |
| Plugin | `PLUGIN_VERSION` in `plugin/StudioStud.plugin.lua` | Roblox plugins folder |
| Protocol | `PROTOCOL_VERSION` in `src/util.rs` | Handshake gate |

## Addon hot-load

Folder plugins copied into `%LOCALAPPDATA%/Roblox/Plugins/<addon-id>/` may require a **Studio reload** before the addon toolbar appears. The Addons settings section shows a hint after enable/disable.

## Channels

- **release** — plaintext artifacts on GitHub Pages `/`
- **beta** / **dev** — encrypted at rest; password stored only in local `secrets/channel-passwords.json`; published via `scripts/publish-channel.ps1` (not CI)
