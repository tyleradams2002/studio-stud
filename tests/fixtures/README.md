# Studio Stud test fixtures

`baseline_capture.json` is a minimal, deterministic capture snapshot for Stage 0 golden and bench
tests. Produced manually to match the plugin snapshot shape (`place`, `sync`, `instances[]`).

Fixed `sync.syncId` = `capture_fixture_stage0` so `capture_id` is stable across ingest runs.
