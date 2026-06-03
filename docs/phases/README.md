# Studio Stud — Phased Resolution (Composer hand-off)

These phase docs split the resolution plan in [`../REVIEW_2026-06-02.md`](../REVIEW_2026-06-02.md)
(section G) into self-contained, executable units.

## How to run a phase
1. **Hand Composer two files:** `docs/REVIEW_2026-06-02.md` (the overall design + decisions) **and**
   the one phase doc (e.g. `docs/phases/PHASE_1_quick_wins.md`).
2. Composer works on branch **`development`** (your dev → main flow). One phase = one focused change set.
3. When Composer reports the phase done, **come back to Claude** and run the phase's
   *"Verification (return to Claude)"* section together. Claude runs the build/test commands and
   confirms the acceptance criteria before you promote.
4. Only start the next phase after the prior phase's verification is green (see dependency order).

## Phases & dependency order
| Phase | File | Covers (review IDs) | Depends on |
|------|------|---------------------|-----------|
| 1 | `PHASE_1_quick_wins.md` | G1, G2, G3, G4, G5, G5b | — |
| 2 | `PHASE_2_manifest_verify.md` | G6, G7 | 1 |
| 3 | `PHASE_3_update_trigger.md` | G8 | 2 |
| 4 | `PHASE_4_bundle.md` | G9, G10, G11, G12, G13 | 2 (signing), 3 (seq) |
| 5 | `PHASE_5_ci_channels.md` | G14, G15 | 4 |
| 6 | `PHASE_6_correctness.md` | G16, G17, G18 | 1 |
| 7 | `PHASE_7_docs.md` (optional) | G-D1 | 5 |

Stop and run **section H of the review doc (in-Studio parity)** after Phase 5 (release) / and again
after Phase 4 if you install a bundle build.

## Ground rules for every phase
- Do **not** change in-game behavior (capture/live/write/project routes in `src/http.rs`,
  `plugin/StudioStud.plugin.lua`). Those are the proven core (review §F).
- Keep `serde_json` `preserve_order` **off** — the signing canonicalization (Phase 2) and golden tests
  depend on sorted-key output.
- Every phase must end with `cargo build --workspace` and `cargo test --workspace` green.
