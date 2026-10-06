# 0032: Updates: one signed manifest per release, digests per part

Status: accepted; tooling and checks built (round 1). Branch
`control-centre`. Signed with the release keys the app's feed uses (main or
spare, [docs/release-keys.md](../release-keys.md)), live from 3.0.0.

## Context

The control centre shows which features an update changes and installs only
what changed. Today `omacvm update` pulls main and reapplies everything; no
release says what changed per feature, and nothing is signed.

## Options

1. A hand-kept version number per feature in `features.tsv`. Gets forgotten.
2. Content digests per part, computed at release time, in one signed
   manifest per release.
3. Separate packages per feature (pacman repo). Much more machinery than the
   project needs.

## Decision

Option 2. Each release `v<version>` carries `omacvm-manifest.json` and an
Ed25519 signature `omacvm-manifest.json.sig` (by the main or the spare
release key, `src/lib/release-key.pub` and `release-key-spare.pub`, checked
with CryptoKit on the Mac before any field is used). It lists the release's
Developer ID teams (`devid_teams`, required). `parts` maps each feature (plus `core` and `app`) to a sha256
digest over its paths (`src/release/parts.tsv`; CI fails on a file in no
part or in two) and the release where that digest last changed. The manifest
pins the release commit; the Mac checks out that commit.

`omacvm apply` records the installed digests in the VM
(`/etc/omacvm/installed.json`). A part has an update when the digests
differ. An update is still one version for everything (consistent Mac and
VM); only changed parts are reinstalled or restarted.

The Mac checks weekly (one fetch for the Mac and all VMs), never when update
checks are off; that one setting is shared with the app self-update and
settable from the control centre.

## Consequences

- No version bumps by hand; the per-feature "2.8.0 → 2.9.1" comes from the
  digests.
- Release scripts gain a manifest step and need the private key: the release
  Mac's Keychain (`manifest.py build --out` signs and reads it back).
- Tests use `OMACVM_FEED_URL` and `OMACVM_FEED_KEY` (test keys,
  space-separated) in the Bridge's environment.
- Round 1 installs an update as one `omacvm update` (Mac and that VM); the
  list shows only the changed parts, and parts that did not change are left
  as they are where the installers already keep stamps (the Mac apps,
  Omanotch). Restarting only what changed everywhere is a follow-up.
- Still to wire: the release step that runs `manifest.py build --out`
  against the previous release's manifest and attaches both files.
