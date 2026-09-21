import Foundation

/// The Ed25519 public keys the app verifies license tokens against.
/// `productionBase64` matches the LICENSE_SIGNING_KEY secret held only by
/// the zumbo-api Worker (`npx wrangler secret put LICENSE_SIGNING_KEY
/// --env production`, from `node scripts/generate-signing-key.mjs` in that
/// repo). Rotating the key means generating a fresh pair, setting the new
/// private half as the Worker secret, and swapping this constant for the
/// new public half - every token signed with the old key stops verifying
/// at that point, so any cached token on a user's Mac is dropped at its
/// next /validate and they re-activate once.
enum LicensePublicKey {
    static let productionBase64 = "2pGxBlDR41im9ql0B1CNsHfxofFLDZxz+0065SGbw28="

    /// A throwaway keypair used only in Debug builds with
    /// `ZUMBO_LICENSE_MOCK=1` or `--license-mock` (see `LicenseMockMode` and
    /// `MockLicenseClient`). It is public on purpose: Release builds never
    /// trust it, and a Debug build is one you compiled yourself.
    #if DEBUG
    static let mockPublicKeyBase64 = "s8swls+YeW4pVFFwFsVd4knBcpsj+BWy806pxLMRxr0="
    static let mockPrivateKeyBase64 = "6dLfLF2VgDn1ITwaUn2FMgwrtQ0nWiOR17e+uDmelaQ="
    #endif
}
