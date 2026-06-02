# Live convergence fixtures

- `baseline.json` — initial capture ingested via `studio-stud ingest`.
- `delta_struct.json` — single delta batch covering add child, remove duplicate sibling, reparent subtree, rename-with-descendants, and intra-root move.
- `full_after.json` — authoritative end state from a fresh full ingest; convergence compares `live-dump` `state` + `fingerprint` against this path without an intervening verify.

Place id: `999001`.
