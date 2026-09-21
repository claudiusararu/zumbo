#!/usr/bin/env swift
// Signs a fixture license token offline, for testing activation with no
// Cloudflare Worker deployed, and (with --generate-keys) mints a fresh
// Ed25519 keypair for scripts/license-keys.md.
//
// Usage:
//   swift scripts/sign-test-token.swift --generate-keys
//       Prints a new base64 private/public keypair. Use this once, for the
//       real production key (see scripts/license-keys.md), not for the
//       mock key already committed in Sources/App/LicensePublicKey.swift.
//
//   swift scripts/sign-test-token.swift [--tier single|three] [--days N]
//       Signs a token for key "ZUMB-TEST-TEST-TEST-TEST" using the mock
//       private key already in Sources/App/LicensePublicKey.swift, and
//       prints the JSON a fixture `/activate` response would contain:
//       { "token": { "payload": {...}, "signature": "..." } }. Paste that
//       into a fixture file to test `HTTPLicenseClient` against a local
//       server, or use `MockLicenseClient` directly, which does the same
//       signing in-process.

import CryptoKit
import Foundation

let arguments = CommandLine.arguments

func base64(_ data: Data) -> String { data.base64EncodedString() }

if arguments.contains("--generate-keys") {
    let privateKey = Curve25519.Signing.PrivateKey()
    print("private: \(base64(privateKey.rawRepresentation))")
    print("public:  \(base64(privateKey.publicKey.rawRepresentation))")
    exit(0)
}

// Mirrors Sources/App/LicensePublicKey.swift's mockPrivateKeyBase64 - kept
// as a literal here so this script has no dependency on the app target and
// can run standalone with `swift scripts/sign-test-token.swift`.
let mockPrivateKeyBase64 = "6dLfLF2VgDn1ITwaUn2FMgwrtQ0nWiOR17e+uDmelaQ="

func argumentValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let tier = argumentValue("--tier") ?? "single"
let days = Int(argumentValue("--days") ?? "365") ?? 365

guard let keyData = Data(base64Encoded: mockPrivateKeyBase64) else {
    FileHandle.standardError.write("Could not decode the mock private key.\n".data(using: .utf8)!)
    exit(1)
}
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)

let now = Date()
let payload: [String: Any] = [
    "key": "ZUMB-TEST-TEST-TEST-TEST",
    "machineId": "test-machine",
    "tier": tier,
    "issuedAt": now.timeIntervalSince1970,
    "expiresAt": now.addingTimeInterval(TimeInterval(days) * 86400).timeIntervalSince1970,
]

// Canonical encoding must match LicenseTokenVerifier.encoder exactly:
// sorted keys, no extra whitespace, numeric (not ISO8601) dates.
let sortedKeys = payload.keys.sorted()
var jsonParts: [String] = []
for key in sortedKeys {
    let value = payload[key]!
    if let string = value as? String {
        jsonParts.append("\"\(key)\":\"\(string)\"")
    } else if let number = value as? TimeInterval {
        jsonParts.append("\"\(key)\":\(number)")
    }
}
let canonicalJSON = "{" + jsonParts.joined(separator: ",") + "}"
let signature = try privateKey.signature(for: Data(canonicalJSON.utf8))

print("payload (canonical JSON, for reference): \(canonicalJSON)")
print("signature (base64): \(base64(signature))")
print("")
print("Note: this hand-rolled JSON is for eyeballing only. For a byte-exact")
print("fixture, prefer calling MockLicenseClient.activate(...) in-process or")
print("LicenseTokenVerifier.sign(_:privateKey:) from Swift, which use the")
print("same JSONEncoder as verification.")
