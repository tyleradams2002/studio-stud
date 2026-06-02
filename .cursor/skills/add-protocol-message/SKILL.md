---
name: add-protocol-message
description: Add or change a message that crosses the Rust↔Luau bridge — updates the Rust type, the Luau handler, the schema/doc, and the protocol version together, in the correct order. Use whenever a new request/response or a shape change is needed on the bridge.
---

# Add / change a bridge message

Prevents the #1 failure mode: the two sides drifting apart. Do all steps in one change.

## Steps
1. **Additive vs breaking.** New optional field or new message = additive (no version break). Removing / renaming / retyping an existing field = breaking (version bump).
2. **Rust side (source of truth).** Define/modify the wire DTO struct(s) with `serde` derives in the protocol module. Keep DTOs separate from internal engine types.
3. **Regenerate or update the schema.** If types are codegen'd to Luau / JSON-schema, run the generator. If hand-mirrored, update the Luau type to match exactly. Never let them diverge.
4. **Luau side.** Add/adjust the handler or request builder in `plugin/.../net`. Type it (`--!strict`); handle the new field/message; keep the plugin a thin relay.
5. **Version.** If breaking, bump the protocol version and ensure both engine and plugin reject incompatible versions with a clear error.
6. **Doc + test.** Update the protocol doc with the new message/field and its meaning. Add a Rust serde round-trip test and, if feasible, a plugin-side decode check.

## Verify
End state: Rust, Luau, schema doc, and version all reflect the same contract. If you changed only one side, you are not done.
