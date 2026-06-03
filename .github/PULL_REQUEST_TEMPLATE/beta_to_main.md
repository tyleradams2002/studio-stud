## beta → main (release) promotion

## Changes
- 

## Beta sign-off
- [ ] Beta testers confirmed no blocking issues
- [ ] All CI checks pass on `beta`

## Release checklist
- [ ] Version bumped in `Cargo.toml` and plugin
- [ ] `site/latest.json` updated with new version + URLs
- [ ] CHANGELOG updated
- [ ] Tag will be pushed after merge to trigger GitHub Release (`git tag v0.x.x && git push origin v0.x.x`)

## Rollback plan
<!-- How to revert if something is wrong after deploy -->

