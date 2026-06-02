# Snapshot Studio state

Capture and inspect the current Studio DataModel through the engine instead of guessing whether a change landed.

1. Ensure `studio-stud serve` is running and Studio has the plugin loaded (polling is automatic). If not, ask me to start it.
2. `.\studio-stud capture` to refresh the live capture (one live SQLite DB per place — there is no capture history to diff against).
3. `.\studio-stud analyze <PLACE> --report context` for an overview, then bounded `.\studio-stud query <PLACE> ...` to drill into the part you care about.

Report only what's relevant to the change — the affected subtree / properties, not the whole place. If the engine is unavailable, read-only Roblox Studio MCP is the fallback for a quick spot-check. See `consumer-template/.cursor/rules/studio-stud.mdc` for full query/audit reference.
