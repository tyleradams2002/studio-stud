# Studio Stud — Addon Plugins

Studio Stud is the **core plugin + daemon**. Addon plugins are **separate,
standalone Studio plugins** that build on that core to add new items, panels,
and authoring features. Each addon is its own `.plugin.lua` (or folder plugin)
and ships independently of the core.

## Principles

1. **Portable, never project-specific.** Like the core tool, an addon must
   install into *any* project and work. Do not hardcode PlaceIds, instance
   paths, asset ids, or game-specific names. Read those from configuration
   (plugin settings, a project config file, or daemon policy).
2. **Build on the core via the daemon.** The integration point is the local
   Studio Stud daemon's HTTP API (`http://127.0.0.1:31878/studio-stud/...`) —
   the same daemon the core plugin uses. Addons talk to it through the shared
   [`sdk/AddonSdk.lua`](sdk/AddonSdk.lua).
3. **Self-contained.** An addon folder carries everything it needs (its plugin
   script, a copy of the SDK, assets, manifest). No cross-addon dependencies.
4. **Version-gated.** Each addon declares the minimum core protocol it needs and
   performs a handshake on activation, so it can tell the user when the core
   needs updating — mirroring the core plugin ↔ daemon handshake.

## Layout

```
addon-plugins/
  README.md            # this file
  sdk/
    AddonSdk.lua        # canonical shared SDK (copied into each addon folder)
  _template/            # scaffold — copy this to start a new addon
    addon.json
    Addon.plugin.lua
    AddonSdk.lua        # copy kept in sync from sdk/AddonSdk.lua
    README.md
  boat-modification/    # first addon (skeleton)
    addon.json
    BoatModification.plugin.lua
    AddonSdk.lua
    README.md
```

One folder per addon. The folder name is the addon id (kebab-case).

## `addon.json` manifest

```json
{
  "name": "boat-modification",
  "displayName": "Boat Modification",
  "version": "0.1.0",
  "description": "What the addon does.",
  "entry": "BoatModification.plugin.lua",
  "minCorePluginVersion": "0.3.7",
  "minCoreProtocolVersion": 1,
  "addonProtocolVersion": 1
}
```

## Creating a new addon

1. Copy `_template/` to `addon-plugins/<your-addon-id>/`.
2. Rename `Addon.plugin.lua` → `<YourAddon>.plugin.lua` and edit `addon.json`.
3. Keep `AddonSdk.lua` in the folder in sync with `sdk/AddonSdk.lua`.
4. Build your feature behind the SDK handshake. Stay portable.

## Installing an addon into a project (Studio)

Until the installer learns an `addon add` step, install manually:

1. Copy the addon folder into the project (e.g. alongside
   `.studio-stud-tool/`, in `.studio-stud-tool/addons/<addon-id>/`).
2. In Studio, load the addon's `*.plugin.lua` as a **local plugin** (folder
   plugins keep `AddonSdk` reachable as a sibling `ModuleScript`).
3. Start the core: `.\studio-stud serve`. The addon's activation handshake
   confirms the daemon is reachable and new enough.

> Planned: a `studio-stud addon add <id>` CLI step + `latest.json` entries so
> addons install and version-check exactly like the core.

## Loading model: folder plugin vs single file

- **Folder plugin (recommended):** the addon folder contains the main script
  plus `AddonSdk` as a sibling `ModuleScript`; the script does
  `require(script.Parent.AddonSdk)`.
- **Single file:** inline `sdk/AddonSdk.lua` at the top of the plugin and drop
  the require.
