---
name: new-subcommand
description: Scaffold a new CLI subcommand in the Studio Stud engine following the flctl pattern (clap subcommand, handler module, stable --json output, test, dispatch wiring). Use when adding a new engine command or CLI capability.
---

# Add an engine subcommand (flctl pattern)

Every engine capability the plugin or an agent uses should be a first-class, testable, JSON-emitting subcommand.

## Steps
1. **Define the command.** Add a `clap` subcommand variant (derive API) with typed args. Name it after the action; keep args minimal and validated.
2. **Handler module.** Add a flat `src/<name>.rs` module (the repo uses flat modules, not a `commands/` directory) with `run(args) -> anyhow::Result<Output>`, where `Output` is a dedicated serde struct (`#[serde(rename_all = "camelCase")]`) — the stable JSON contract for this command.
3. **Dual output.** Implement human rendering (terse) and `--json` rendering (the `Output` struct). Agents consume the JSON; humans get the summary. Stable field names.
4. **Wire dispatch.** Add the variant to the top-level command match so `<binary> <name>` routes to the handler. Map errors to a meaningful exit code.
5. **Test.** Add a unit/integration test asserting the `Output` JSON shape for a known input. This locks the contract.
6. **Document.** One line in the CLI reference / `--help` describing the command and its JSON shape.

## Why
This is the core token-optimization move: push deterministic work behind a command with structured output, so the agent calls `<binary> <name> --json` and reads a small result instead of doing the work in-context.
