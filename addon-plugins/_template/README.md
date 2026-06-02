# Addon Template

Starter scaffold for a Studio Stud addon plugin.

## Start a new addon

1. Copy this folder to `addon-plugins/<your-addon-id>/`.
2. Rename `Addon.plugin.lua` → `<YourAddon>.plugin.lua`.
3. Edit `addon.json` (`name`, `displayName`, `version`, `entry`, version gates).
4. Keep `AddonSdk.lua` in sync with `../sdk/AddonSdk.lua`.
5. Replace the demo body in the plugin script with your feature.

## Files

| File | Purpose |
|------|---------|
| `addon.json` | Manifest: id, version, entry, core compatibility gates. |
| `Addon.plugin.lua` | Plugin entry point. Creates a toolbar button + handshake. |
| `AddonSdk.lua` | Copy of the shared SDK (daemon HTTP + version handshake). |
| `assets/` | Optional icons/images for the addon. |

## Rules

- **Portable:** no project-specific PlaceIds, paths, or asset ids baked in.
- **Build on the core via the daemon** using the SDK; don't reach into the core
  plugin's internals.
- **Version-gate:** keep `minCoreProtocolVersion` accurate; the activation
  handshake warns the user when the core is too old.
