# Cutting a Zumbo release

Everything below happens on the owner's Mac. There is no CI: the Developer ID
certificate, the notarization credentials and the Sparkle private key all live
in that machine's keychains and nowhere else.

## The short version

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
   `CURRENT_PROJECT_VERSION` must increase on every release - it is what
   Sparkle compares to decide an update exists (`sparkle:version` in the
   appcast).
2. Commit. The release script refuses to run on a dirty tree.
3. `scripts/release.sh`
4. When it finishes it prints the tag command. Run it:
   `git tag v<version> && git push origin v<version>`
5. Keep `dist/appcast.xml`: it is gitignored, and the next release adds its
   `<item>` on top of it. The published copy is
   `https://updates.zumbo.app/appcast.xml`.

## What the script does

`scripts/release.sh`, in order, printing each step and stopping on the first
failure. No retries, no loops.

1. Reads the version and build from `project.yml`. Refuses if the working tree
   is dirty, if `v<version>` already exists, or if the Developer ID identity is
   missing from the keychain.
2. `xcodegen generate -q`, then a Release build through
   `../hooppaper/scripts/safe-run.sh` (memory cap - a plain `xcodebuild` has
   run this Mac out of its 24 GB before).
3. Copies the speech models out of the local FluidAudio cache into
   `Zumbo.app/Contents/Resources/Models`, so dictation works offline from the
   first launch:
   - `parakeet-tdt-0.6b-v3-coreml`, ~461 MB, the speech engine
   - `parakeet-ctc-110m-coreml`, ~98 MB, the vocabulary booster
   - `silero-vad` from the cache, copied in as `silero-vad-coreml`, ~1 MB
   The folder names on the right are FluidAudio 0.15.7's own
   `Repo.folderName` values, which is what
   `VesperEngine.BundledModels.installIfNeeded()` copies them back out to on
   first launch. Speaker labels (`sortformer`, ~230 MB) are deliberately NOT
   bundled - that stays an add-on download from `models.zumbo.app`.
   Result: a ~570 MB DMG. That was accepted deliberately; see
   dictation-spike/NOTES.md, "Distribution size".
4. Signs inside-out with `Developer ID Application`, hardened runtime and a
   secure timestamp everywhere: Sparkle's XPC services
   (`Downloader.xpc`, `Installer.xpc`), then `Updater.app` and `Autoupdate`,
   then `Sparkle.framework`, then any other embedded framework, then
   `Zumbo.app` itself with `Support/Zumbo.entitlements`. Then
   `codesign --verify --deep --strict`.
5. Builds `dist/Zumbo-<version>.dmg`: a writable UDRW image, a Finder pass to
   place the app and the `/Applications` symlink (no background art - Zumbo
   has none), then a UDZO conversion at `zlib-level=9`. The DMG container is
   signed too; without that, `spctl`'s primary-signature check on the image
   is rejected even when the app inside it is fine.
6. `xcrun notarytool submit --keychain-profile motificons-notary --wait`,
   `stapler staple`, then `spctl -a -vv -t open --context
   context:primary-signature` on the DMG and `spctl -a -vv` on the app inside
   it. Both must say "accepted".
7. `build/sparkle-tools/bin/sign_update` on the DMG for the EdDSA signature
   and byte length, then rewrites `dist/appcast.xml` with a new `<item>` at
   the top, keeping every older one.
8. Creates the R2 bucket and custom domain if they are not there yet (both
   idempotent), uploads the DMG and the appcast, then `curl -I`s both.

   **wrangler cannot upload the DMG.** It caps `r2 object put` at 300 MiB
   (one PUT, no multipart path) and a Zumbo DMG is ~550 MiB because the
   speech engine is bundled. So the DMG goes up through R2's S3 API with
   rclone, which needs an R2 API token - a one-time setup:

   - Cloudflare dashboard > R2 > API > Create API token, Object Read & Write,
     scoped to `zumbo-updates`.
   - `rclone config`: type `s3`, provider `Cloudflare`, endpoint
     `https://<account id>.r2.cloudflarestorage.com`,
     remote name **`zumbo-r2`** (the script looks for exactly that name).

   Without that remote the script stops before publishing the appcast, so the
   feed never advertises a DMG that is not there. The appcast itself is small
   and still goes up through wrangler.
9. Prints the DMG size and sha256 and the tag command.

Flags:

- `--no-upload` - everything through step 7, including real notarization.
  Nothing is published. Use this to rehearse a release.
- `--skip-notarize` - stops after step 5 with the DMG built but not notarized.
  A dry run only. Without notarization there is no legitimate appcast entry to
  write, so steps 6 to 8 are all skipped. Do not hand that DMG to anyone;
  Gatekeeper will refuse it.

## Where things live

| Thing | Where |
| --- | --- |
| Update feed + DMGs | R2 bucket `zumbo-updates`, served at `updates.zumbo.app` |
| Add-on models (speaker labels) | R2 bucket `vesper-models`, served at `models.zumbo.app` |
| Notarization credentials | keychain profile `motificons-notary` (same Apple Developer account) |
| Signing certificate | `Developer ID Application`, team `7ZGY25DL26` |
| Sparkle public key | `SUPublicEDKey` in `project.yml`, and every shipped bundle |
| Sparkle private key | login keychain only, item "Private key for signing Sparkle updates" |
| Sparkle CLI tools | `build/sparkle-tools/` (gitignored, re-downloadable) |
| Published appcast | `dist/appcast.xml`, local only (gitignored) |

Nothing in any R2 bucket is ever deleted. Old DMGs stay up: an appcast entry
that 404s is worse than a stale one.

Cloudflare account `0b5e453d4de0f4965eaf1b1b368b1bc2`, zone
`9f9a6a9860a445640b063d29c7134bdc`. The script uses the wrangler binary at
`../moonlisted/node_modules/.bin/wrangler`.

## Re-downloading the Sparkle tools

`build/sparkle-tools/` is gitignored, so a fresh clone does not have
`sign_update`. Get it back with:

```
mkdir -p build/sparkle-tools && cd build/sparkle-tools
curl -L -o Sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
tar xf Sparkle.tar.xz
```

Match the version to whatever `project.yml` resolves; a newer 2.x `sign_update`
is fine against an older framework, the signature format has not changed.

## Rotating the Sparkle EdDSA key

Read this before doing it: **rotating the key orphans the auto-updater on
every copy of Zumbo already out there.** Those installs only trust the public
key baked into their own Info.plist. An update signed with a new key fails
their signature check and they simply stop updating, silently, forever. They
have to be told to download a new DMG by hand.

So this is a last resort. Do it only if the private key is actually
compromised - not for tidiness, not for a key of a nicer shape.

If you have to:

1. `build/sparkle-tools/bin/generate_keys` generates a fresh pair into the
   login keychain and prints the new public key. To replace the existing one
   you must first delete the old keychain item (Keychain Access, search
   "Sparkle"), otherwise `generate_keys` just reprints the key it already has.
   Keep the old private key until you are certain you are done with it.
2. Put the new public key in `project.yml`'s `SUPublicEDKey`, regenerate,
   rebuild, release as normal. Everything from here on is signed with the new
   key.
3. The bridge, if you want one: cut one last release signed with the **old**
   key whose app bundle carries the **new** `SUPublicEDKey`. Existing installs
   accept it (old signature), and afterwards they trust the new key. That only
   rescues people who install that one bridge release, so leave it up for a
   good while and keep signing with the old key until then. If the old key is
   compromised you cannot do this at all, because an attacker can sign a
   bridge too - in that case announce a manual re-download and move on.

`generate_keys -x <file>` exports the private key and `-f <file>` imports one.
Only use those to move the key to a new Mac, over something you trust, and
delete the file afterwards. The private key never goes in this repo, in a
build log, in a CI secret or in a message.
