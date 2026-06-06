# Deployment flow (dev → main)

Two channels: **dev** (private, encrypted, auto-updates on every commit) and **release**
(public, shipped by PR). The `beta` channel is retired but `Channel::Beta` remains in code
so it can be revived.

## Day-to-day

- Commit to `development` freely. Each push republishes the dev channel and bumps
  `channelSequence`, so dev installs auto-update. **Do not change the version number for
  normal work.**

## Shipping a release

1. On `development`, bump the version (daemon + plugin together):
   `.\scripts\bump-version.ps1 <X.Y.Z>` — must be greater than the last `v*` tag.
2. Commit + push the bump to `development`.
3. Run the **Promote** workflow (Actions tab) to open the `development → main` PR, or open
   it manually.
4. CI runs `build-test` and `version-gate` (rejects a missing/mismatched/non-incremented
   bump). Approve and **merge with a merge commit** (not squash).
5. The merge triggers `deploy-release`: it creates the `v<X.Y.Z>` tag + GitHub Release +
   assets atomically, verifies the assets resolve, then publishes the release manifest.
   No manual tagging; 404s are impossible because the manifest publishes only after assets exist.

## One-time after the password-gap fix ships

Reinstall dev once so the channel key is stored:
`irm https://tyleradams2002.github.io/studio-stud/install-dev.ps1 | iex`
Then `studio-stud-setup update --check` should work without the "channel password not
stored" error. After that, dev auto-update is permanent.

## First cutover

The first release PR under this system ships `0.4.12` (where dev already sits); `v0.4.11`
is skipped — semver need not be contiguous.

## Reviving beta later

Restore the `deploy-beta` job and `github-release`/tag wiring in `deploy.yml`, re-add the
beta option to `promote.yml`, and recreate `site/install-beta.ps1`. `Channel::Beta` and its
`BETA_CHANNEL_PASSWORD` secret were never removed.
