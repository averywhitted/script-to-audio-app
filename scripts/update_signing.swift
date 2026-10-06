// Ed25519 signing for in-app update archives.
//
// The in-app updater only installs a TableRead.zip whose signature verifies
// against the public key compiled into the app (AppUpdater.updatePublicKey).
// The private key lives in this Mac's login Keychain and is never written to
// disk or printed.
//
// Usage:
//   xcrun swift scripts/update_signing.swift keygen        # once per developer machine
//   xcrun swift scripts/update_signing.swift public-key    # print the public key
//   xcrun swift scripts/update_signing.swift sign <file>   # print base64 signature
//
// Back up the private key (e.g. into a password manager) with:
//   security find-generic-password -s "TableRead Update Signing Key" -w
// If it is lost, installed copies can no longer update in-app and users must
// download the next release manually.

import CryptoKit
import Foundation
import Security

let service = "TableRead Update Signing Key"
let account = "update-signing"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let encoded = item as? Data,
          let raw = Data(base64Encoded: encoded)
    else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    if loadPrivateKey() != nil {
        fail("a signing key already exists in the Keychain; refusing to replace it")
    }
    let key = Curve25519.Signing.PrivateKey()
    let add: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: service,
        kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("could not save key to Keychain (OSStatus \(status))") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public-key":
    guard let key = loadPrivateKey() else { fail("no signing key in the Keychain; run keygen") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count == 2, let path = args.last else { fail("usage: sign <file>") }
    guard let key = loadPrivateKey() else { fail("no signing key in the Keychain; run keygen") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let signature = try key.signature(for: data)
    print(signature.base64EncodedString())

default:
    fail("usage: update_signing.swift keygen | public-key | sign <file>")
}
