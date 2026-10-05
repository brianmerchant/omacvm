# Release keys

For maintainers. Every release signs three kinds of document with OmacVM's
own Ed25519 release key:

| Document | Made by | Read by |
|---|---|---|
| `OmacVM-appcast.json` (`"kind": "app-feed"`) | `app/scripts/appcast.sh` (run by `package-release.sh`) | OmacVM.app's own updates; `omacvm build --vm-type app` and `omacvm update` when they download the app |
| `omacvm-manifest.json` (`"kind": "control-manifest"`) | `src/release/manifest.py build --out FILE` | the Bridge (control centre updates) |
| `omacvm-prebuilt-<version>-<route>.json` (`"kind": "prebuilt-manifest"`) | `src/prebuilt/make-image.sh` (package stage) | `omacvm build --prebuilt`, the app's prebuilt VMs |

Each one has a `.sig` next to it (base64 Ed25519 over the exact bytes). Nothing
in a document is used before its signature checks out. Each lists
`"devid_teams"`: the Apple Developer ID teams the release is signed with.
OmacVM.app and the command line only install an app signed by one of them.
A missing or empty list is refused. No team is written into the code.

## Where the keys live

There are two keys, and the public halves of both ship in every copy:
`src/lib/release-key.pub` (main) and `src/lib/release-key-spare.pub` (spare).
A document signed by either one is valid.

- **Main private key:** in the Keychain of the Mac that makes releases (generic
  password, service `org.omacvm.release-key`, account `omacvm`), and in
  1Password. The release scripts read it from the Keychain and pipe it into
  `src/release/sign.swift`. It is never written to a file.
- **Spare private key:** only in 1Password, plus an offline copy. It is not
  on any Mac.

Never commit a private key, never put one in a GitHub secret or a workflow,
and never paste one into a terminal that keeps history.

## Signing a release

`src/release/release-key.sh sign FILE` signs with the Keychain key, then checks
`FILE.sig` against the two public keys in `src/lib`. If the signature does not
match, it keeps no `.sig`. `appcast.sh`, `manifest.py build --out` and
`make-image.sh` call it, and then read the document back the way the apps do.
The Developer ID team comes from the release app (`app/dist/OmacVM.app`), or
from `OMACVM_SIGN_ID` when there is no app.

## When the main key is lost (or may have leaked)

1. Get the spare from 1Password into a file that only you can read
   (`chmod 600`), on the release Mac.
2. Make a new key pair: `swift src/release/sign.swift keygen NEWKEY` prints the
   new public key. Store `NEWKEY` in 1Password and offline. This is the new
   spare.
3. Sign the next release with the spare and name the new spare in it:
   `OMACVM_RELEASE_KEY_FILE=SPAREFILE OMACVM_NEXT_SPARE_KEY="<new public key>" app/scripts/package-release.sh`
   (do the same for `manifest.py build --out`). Installed copies trust the
   new key from then on. They keep that signed document in
   `~/Library/Application Support/omacvm/release-keys`. They keep the whole
   document, not a bare key, so another program cannot add a key there.
4. In the same release, commit the new public keys: the old spare becomes
   `release-key.pub` (main), the new key becomes `release-key-spare.pub`. Put
   the old spare's private half in the Keychain as the main key
   (`security add-generic-password -U -s org.omacvm.release-key -a omacvm -w`,
   which asks for the value), then delete `SPAREFILE`.
5. If the old main key may have leaked: copies from before this release still
   trust it until they update. Ship the release quickly and say so in the
   release notes.

If both private keys are lost, installed copies cannot be updated
automatically any more. Everyone has to download the app by hand once.

## When a named spare leaks

A spare that a signed document named (`next_spare_key`) is not in `src/lib`
of the installed copies: they trust it because they kept that document. A
release that ships other keys drops it, but copies that have not updated yet
would trust it for good. So a document can revoke it:

1. Make a new spare (step 2 above) if the leaked one was the current spare.
2. Sign the next release with the main key (or the spare that `src/lib`
   ships, never with a named one) and list the leaked key:
   `OMACVM_REVOKED_KEYS="<leaked public key>" app/scripts/package-release.sh`
   (and `manifest.py build --out`, so copies that only run the Bridge get it
   too). Add `OMACVM_NEXT_SPARE_KEY` in the same run to name the new spare.
   The feed then has `"revoked_keys": ["<key>"]` (1 to 8 keys).
3. Each copy that reads it keeps it (like a naming document) in
   `~/Library/Application Support/omacvm/release-keys`. From then on the
   revoked key signs nothing it accepts, and keys that the revoked key named
   are dropped too. OmacVM.app, the Bridge and the command line share that
   folder, so one of them reading the feed is enough.
4. Keep the key in `OMACVM_REVOKED_KEYS` for a few releases, for copies that
   skip one. Copies that never read such a feed trust the key until they
   update to a release that does not ship the key that named it; say so in
   the release notes.
5. A revocation counts only while a key that signed it still ships. So when
   the main key is lost later (see above), list the revoked keys again in
   the first release signed with the spare: copies keep that copy too, and
   the key stays revoked after they update to the release without the old
   main key.

The rules that keep this safe:

- Only a document signed by a key in `src/lib` (shipped) can revoke. A
  leaked named spare can sign a document that lists the main key, but the
  apps ignore it.
- A shipped key cannot be revoked by a document. To drop one, ship a
  release without it (see "When the main key is lost").
- A key once revoked stays revoked, even when a later document names it
  again.

## The kept folder

`~/Library/Application Support/omacvm/release-keys` holds signed documents
only (`<16 hex>.json` and `.json.sig`). A bare key file, a changed document
or any other junk there adds nothing: only documents whose signature checks
out (against a shipped key, or a key a checked document named) count, and
at most 8 of them. Junk does not count toward the 8, so it cannot crowd
out the real ones. At most 256 files there are looked at.

## Which Developer ID the fast network trusts

The fast network's root service (`src/net/mac/install.sh`) takes the
Developer ID team of the app's QEMU only when OmacVM's release key vouches
for it: the signed update feed of that app's release lists the team, or the
script is the app's own copy (its Fast Network button). Otherwise, for
example an app that is not a published release, or a fake app signed with
someone else's Developer ID, it trusts only that exact build of the QEMU
(its cdhash), as for an app built from source. `install.sh --trust` shows
what an install would trust.

## When the Developer ID team changes

The release key, not the Apple team, decides what gets installed. So a new
Developer ID is announced in a feed that is signed with our key:

1. Build the first release with the new identity (`OMACVM_SIGN_ID`). Run
   `package-release.sh` with `OMACVM_EXTRA_TEAMS="<old team>"`. Its feed and
   manifests then list both teams, and installed apps accept the new
   signature.
2. Later releases list only the new team (leave `OMACVM_EXTRA_TEAMS` unset).
3. Say this in the release notes: macOS ties the permissions of the Mac
   helpers (Input Monitoring, Accessibility, Location for the Bridge and
   Gestures) to the signature, so it asks for them again once. The fast
   network service shows "old" and asks for the password once. Apps that are
   already installed keep working.
