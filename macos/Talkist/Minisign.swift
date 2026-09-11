import Foundation
import CryptoKit

/// minisign signature verification (Ed25519 direct mode, what the Linux
/// updater uses via minisign-verify) built on CryptoKit.
enum Minisign {
    static let publicKey = "RWTQDdQS8ZXehztOCrKTWpM0dKGPzAUzfLlMJ7lZNEhWS0VPSqNuf+UW"

    /// Verify `message` against a minisign signature file's text.
    /// Layouts (after base64 decode):
    /// - public key: "Ed" (2) | key id (8) | ed25519 pubkey (32) = 42 bytes
    /// - signature:  "Ed" (2) | key id (8) | ed25519 sig (64)    = 74 bytes
    static func verify(message: Data, signatureText: String) -> Bool {
        guard let keyBlob = base64Decode(publicKey), keyBlob.count == 42,
              keyBlob[0] == 0x45, keyBlob[1] == 0x64 else { return false }
let keyID = keyBlob[2..<10]
        guard let sigLine = signatureText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first(where: { !$0.lowercased().hasPrefix("untrusted comment") }),
            let sigBlob = base64Decode(String(sigLine)), sigBlob.count == 74,
            sigBlob[0] == 0x45, sigBlob[1] == 0x64 else { return false }
        guard sigBlob[2..<10].elementsEqual(keyID) else { return false }
        let sigBytes = Data(sigBlob[10..<74])
        let keyBytes = Data(keyBlob[10..<42])
        guard let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { return false }
        // Newer CryptoKit takes the 64-byte signature as raw Data directly.
        return pubKey.isValidSignature(sigBytes, for: message)
    }

    private static func base64Decode(_ s: String) -> Data? {
        Data(base64Encoded: s, options: [])
    }
}