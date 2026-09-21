# Licensing keypair

Zumbo verifies every license token with an embedded Ed25519 public key
(`Sources/App/LicensePublicKey.swift`, `productionBase64`). The private half
is a Cloudflare Worker secret and exists nowhere else.

## Generate the real keypair (owner, once, before shipping licensing)

Run on a machine you trust; the private key never goes in this repo, in the
app, or anywhere but the Cloudflare Worker's secret store.

```
swift scripts/sign-test-token.swift --generate-keys
```

This prints a private and a public key, each base64, 32 raw bytes (Ed25519).

## Wire them in

1. Public key: paste it into `Sources/App/LicensePublicKey.swift`,
   `productionBase64`. This ships in the app.
2. Private key: set it as a Cloudflare Worker secret, e.g.
   `wrangler secret put LICENSE_SIGNING_KEY`. It never appears in a repo,
   commit, log, or client response.
3. The Worker signs `LicenseTokenPayload` (see docs/LICENSING.md for the
   exact JSON shape and canonical encoding - sorted keys, dates as seconds
   since 1970) with that private key and returns the base64 signature as
   `SignedLicenseToken.signature`.

## Rotating the key later

If the private key is ever exposed: generate a new pair, ship an app update
with the new public key, and have the Worker sign with the new private key
for that release forward. Old cached tokens on machines still running the
old app version keep verifying against the old public key until they
update - there is no cross-version invalidation, which is acceptable for a
single-developer indie app with no enterprise SLA yet.

## Mock keypair (do not touch)

`LicensePublicKey.mockPublicKeyBase64` / `mockPrivateKeyBase64` are a
separate, already-generated throwaway pair used only in Debug builds with
`ZUMBO_LICENSE_MOCK=1` or `--license-mock` (see `LicenseMockMode`,
`MockLicenseClient` and `scripts/sign-test-token.swift`). Release builds
compile the mock out, so they never trust this pair; leaving it public is
fine.
