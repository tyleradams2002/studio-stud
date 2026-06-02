# Studio Stud

Default for live Studio world-state. Do not use syncback/rbxlx for routine research.

```powershell
.\studio-stud status
.\studio-stud capture
.\studio-stud analyze 100000000000001 --report context
.\studio-stud query 100000000000001 --find Trader --count-only
.\studio-stud query 100000000000001 --path Workspace/BoatSpawnPoints --limit 10
.\studio-stud query 100000000000001 --detail Workspace/Dock --props Position,Size
```

Places: ExamplePlaceA=`100000000000001`, ExamplePlaceB=`100000000000003`. Replace PlaceId from `status` or `analyze`.

`capture` needs `serve` in a separate terminal and the plugin loaded in Studio (polling is automatic). First-time setup: `doctor`.

Hard stops: no `--markdown` for AI work, no `raw.json.gz`, no bare `--detail`, no rbxlx for routine research.

Uncommon queries, audit IDs, bulk JSON, fallback rules: `.cursor/rules/studio-stud.mdc`
