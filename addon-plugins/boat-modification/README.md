# Boat Modification (addon)

**Status: scaffold / not implemented.** This folder establishes the first
Studio Stud addon plugin. The toolbar entry and core handshake are wired up;
the authoring UI is still to be built.

## Intent

A portable Studio authoring panel for "boat modification" data. It lets a
designer edit the metadata that a game's boat-modification system consumes and
persists it as a project config through the Studio Stud daemon's write API.

Known authoring concerns to support (generic, schema-driven — not tied to any
one game):

- Slot enablement per boat
- Max tier overrides
- Allowed-item whitelists per slot
- Mount / nameplate placement metadata

## Design notes

- **Source of truth is a project config file**, written via the daemon (so it
  is policy-gated and diffable), not a binary plugin blob. Target path is
  configuration (`DEFAULT_CONFIG_PATH` placeholder for now).
- **Portable:** no PlaceIds, instance paths, or game names baked in. A project
  supplies its boat list / slot schema via config or a daemon query.
- **Version-gated:** declares `minCoreProtocolVersion`; the activation
  handshake warns when the core daemon is too old.

## Build checklist

- [ ] Define the config JSON schema (slots, tiers, whitelists, mounts).
- [ ] DockWidget UI: boat picker → slot/tier/whitelist editors → preview.
- [ ] Read current config (daemon read or project file).
- [ ] Persist via daemon write API (atomic, policy-allowed path).
- [ ] Source the boat/slot schema from config or a daemon query (no hardcoding).
- [ ] Replace `assets/` placeholder icon.

> If you have earlier plans or test snippets for this, drop them here and I'll
> fold them into the schema + UI.
