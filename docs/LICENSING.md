# Licensing backend contract

This is what the Cloudflare Worker (NOTES.md "Licensing backend") must
implement so the app side, already built (`Sources/App/License*.swift`,
`Engine/Sources/VesperEngine/LicenseCore.swift`), works against it with no
app changes. The Worker does not exist yet; the app currently points at
`https://api.zumbo.app` (`LicenseEndpoints.production` in
`Sources/App/LicenseEndpoints.swift`) and talks to `MockLicenseClient`
instead whenever `ZUMBO_LICENSE_MOCK=1` or `--license-mock` is set (Debug builds only; Release builds compile the mock out).

## Key formats

Two shapes are valid, both handled by `LicenseKeyFormatter` in
`Engine/Sources/VesperEngine/LicenseCore.swift` (app side) and
`normalizeLicenseKey` in `src/license-key.ts` (Worker side):

1. **Dodo-issued key**: a bare UUID, 32 hex digits grouped 8-4-4-4-12
   (`db44b22c-fe9b-4a68-bf0d-b0e0d6c6c8c0`). Dodo generates these when a
   `payment.succeeded` mints a `license_key.created` event; the format is
   not configurable. Case-insensitive, normalized to **lowercase**.
2. **Manual key**: `ZUMB-XXXX-XXXX-XXXX-XXXX`, four groups of four
   alphanumerics after the `ZUMB` prefix, used for comps, refund reissues
   and the mock client's `ZUMB-TEST-TEST-TEST-TEST`. Case-insensitive,
   normalized to **uppercase**.

Keys are compared case-insensitively everywhere on both sides: `/activate`,
`/validate`, `/deactivate`, the Dodo webhook, and the `issue-key.mjs` /
`revoke-key.mjs` admin scripts all normalize before storing or looking up.
The app never reformats what someone types or pastes into the license key
field - no forced uppercasing, no hyphen insertion - it only normalizes
once, right before sending the key to `/activate`.

## Endpoints

All three are `POST`, JSON in, JSON out, under the app's base URL.

### `POST /activate`

Request:
```json
{ "key": "ZUMB-ABCD-1234-EFGH-5678", "machineId": "<sha256 hex>", "machineName": "Claudiu's MacBook Pro", "appVersion": "1.0.1" }
```
- `machineId`: SHA-256 of the Mac's `IOPlatformUUID`, hex-encoded (64 chars).
  Stable across reinstalls and reboots; the Worker never sees the raw UUID.
- `machineName`: for the Worker's own records / a future dashboard; the app
  does not require it echoed back.

Response (200):
```json
{ "token": { "payload": { "key": "...", "machineId": "...", "tier": "single", "issuedAt": 1758000000, "expiresAt": 1789536000 }, "signature": "<base64 Ed25519 signature>" } }
```
- `tier`: `"single"` (1 Mac), `"three"` (3 Macs), or `"team"` (10 Macs,
  $79), exactly as the Dodo product it came from.
- `issuedAt` / `expiresAt`: seconds since Unix epoch, not ISO 8601.
- `signature`: base64-encoded Ed25519 signature over the **canonical JSON
  encoding of `payload`** - `JSONEncoder` with `outputFormatting =
  [.sortedKeys]` and `dateEncodingStrategy = .secondsSince1970`. Concretely,
  the bytes signed are the UTF-8 JSON object with keys in alphabetical order
  (`expiresAt`, `issuedAt`, `key`, `machineId`, `tier`) and no extra
  whitespace. See `Engine/Sources/VesperEngine/LicenseCore.swift`,
  `LicenseTokenVerifier.canonicalData(for:)`, for the exact Swift encoder;
  match it byte for byte or every token fails verification.
- Signed with the private key generated per `scripts/license-keys.md`,
  which never leaves the Worker's secret store.

Error responses (any body, only the status matters to the app):
| Status | Meaning | App-side text |
|---|---|---|
| 404 or 422 | Key does not exist / is malformed | "That key was not recognised." |
| 409 | Key already activated on its tier's machine limit | "This key is already used on 3 Macs. Deactivate one first." |
| network failure / anything else | Unreachable, timeout, 5xx | "Could not reach the license server. Check your connection." |

### `POST /validate`

Request:
```json
{ "token": { "payload": { ... }, "signature": "..." } }
```
Called once a week in the background (`LicenseState.validateInBackground`),
silently, whether or not it succeeds.

Response (200): the same shape as `/activate`'s response - typically the
same payload with a refreshed `expiresAt`, so the offline grace window
(below) keeps resetting for an active subscriber... except Zumbo has no
subscription: for a one-time license this simply re-affirms the token isn't
revoked and can extend `expiresAt` far into the future (e.g. re-issue for
another year) so the app never has to special-case "license never expires."

Response (401): the key/machine pair has been revoked (refund, chargeback,
manual kill switch via the Worker's KV). The app deletes its cached token
immediately, drops to `.trialEnded` (or back to `.trial` if the trial window
is still running), and shows "Your license was deactivated" once.

### `POST /deactivate`

Request:
```json
{ "key": "ZUMB-ABCD-1234-EFGH-5678", "machineId": "<sha256 hex>" }
```
Response: any 2xx. The app deletes its local cached token unconditionally
after this call whether or not the request even reaches the Worker (so a
user who deactivates while offline still loses local access - this machine
slot is freed server-side the next time it can reach the Worker, or by the
Worker's own bookkeeping; out of scope for the app).

## Offline / grace behavior (app side, already built)

A cached, signature-valid token keeps the app licensed for
`payload.expiresAt + 30 days` (`LicenseGrace`, `Engine/Sources/VesperEngine/
LicenseCore.swift`) with **no network call at all** - this is what makes the
weekly `/validate` "silent": failure just means the grace window is what's
currently keeping things unlocked, logged, never shown to the user.

## Trial (no backend involvement)

3 calendar days from the moment onboarding's "Start my 3-day trial" is
clicked, ending 23:59:59 local time on the third calendar day
(`TrialWindow.endDate`, e.g. start Sep 20 -> ends end of Sep 22). Stored only
in the Keychain (service `com.claudiusararu.zumbo`, account `trial`), never
sent to the Worker - the trial has no server-side concept.

## Custom URL scheme

`zumbo://activate?key=<key>` (registered in `project.yml` under
`CFBundleURLTypes`) opens Settings > License with the key field pre-filled
and runs Activate immediately. The Dodo checkout success page should link
here with the purchased key.

## Mock mode for testing without a Worker

In a Debug build, set `ZUMBO_LICENSE_MOCK=1` or pass `--license-mock` (Release builds ignore both): `LicenseClient.make`
returns `MockLicenseClient` instead of hitting the network, and
`LicenseState` verifies tokens against `LicensePublicKey.mockPublicKeyBase64`
instead of the production key. The only key it accepts is
`ZUMB-TEST-TEST-TEST-TEST`, always tier `single`, expiring one year out.
Never wired into a Release build's default path - it only activates behind
that env var or launch argument.
