// Git credential helper for Pierre Code Storage (https://code.storage).
//
// Mints a short-lived ES256 JWT per git operation, scoped to the repository in
// the URL. The org private key lives in the macOS login keychain as a
// non-extractable key; signing happens inside Security.framework.

import CryptoKit
import Foundation
import Security

let usage = "usage: git-credential-code-storage get|store|erase|import <org>|delete <org>"

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("code.storage: \(message)\n".utf8))
  exit(1)
}

func errorText(_ status: OSStatus) -> String {
  "\(SecCopyErrorMessageString(status, nil) as String? ?? "error") (\(status))"
}

func label(_ org: String) -> String { "code.storage:\(org)" }

// MARK: - JWT

func b64url(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

// Minimal JSON string encoding. JSON is built by hand to keep a stable key
// order.
func json(_ string: String) -> String {
  var out = "\""
  for scalar in string.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
    default: out.unicodeScalars.append(scalar)
    }
  }
  return out + "\""
}

// ES256 signature: SHA-256 + ECDSA P-256 inside Security.framework, converted
// from DER (X9.62) to the raw 64-byte r||s form JWS requires.
func sign(_ key: SecKey, _ data: Data) -> Data {
  var error: Unmanaged<CFError>?
  guard let der = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data? else {
    fail("signing failed: \(error!.takeRetainedValue())")
  }
  guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else {
    fail("unexpected signature encoding")
  }
  return signature.rawRepresentation
}

func jwt(_ key: SecKey, org: String, repo: String) -> String {
  let now = Int(Date().timeIntervalSince1970)
  let user = ProcessInfo.processInfo.environment["USER"] ?? "local"
  let header = #"{"alg":"ES256","typ":"JWT"}"#
  let claims = #"{"iss":\#(json(org)),"sub":\#(json("git-\(user)")),"repo":\#(json(repo)),"#
    + #""scopes":["git:read","git:write"],"iat":\#(now),"exp":\#(now + 3600)}"#
  let input = b64url(Data(header.utf8)) + "." + b64url(Data(claims.utf8))
  return input + "." + b64url(sign(key, Data(input.utf8)))
}

// MARK: - Non-extractable keychain key

func findKey(_ org: String) -> SecKey? {
  let query: [CFString: Any] = [
    kSecClass: kSecClassKey,
    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
    kSecAttrLabel: label(org),
    kSecReturnRef: true,
  ]
  var item: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &item)
  if status == errSecItemNotFound { return nil }
  guard status == errSecSuccess else { fail("Keychain lookup failed: \(errorText(status))") }
  return (item as! SecKey)
}

func deleteKey(_ org: String) -> Bool {
  let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrLabel: label(org)]
  let status = SecItemDelete(query as CFDictionary)
  guard status == errSecSuccess || status == errSecItemNotFound else {
    fail("Keychain delete failed: \(errorText(status))")
  }
  return status == errSecSuccess
}

// Imports with the same mechanism as `security import -x -T <self>`: the key
// is marked sensitive and not extractable, and its ACL trusts only this
// binary for use (other apps trigger a Keychain prompt). Replaces any existing
// key for the org. SecItemImport plus SecAccess is the only public API that
// sets both on the login keychain; SecAccess is deprecated but still works.
func importKey(_ org: String, _ key: P256.Signing.PrivateKey) {
  _ = deleteKey(org)

  var keychain: SecKeychain?
  var status = SecKeychainCopyDomainDefault(.user, &keychain)
  guard status == errSecSuccess, let keychain else { fail("no login keychain: \(errorText(status))") }

  var me: SecTrustedApplication?
  status = SecTrustedApplicationCreateFromPath(nil, &me)
  guard status == errSecSuccess, let me else { fail("cannot identify this binary: \(errorText(status))") }
  var access: SecAccess?
  status = SecAccessCreate(label(org) as CFString, [me] as CFArray, &access)
  guard status == errSecSuccess, let access else { fail("cannot create access: \(errorText(status))") }

  // Listing attributes sets them; leaving out kSecAttrIsExtractable makes the
  // key non-extractable.
  let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
  let usage = [kSecAttrCanSign] as CFArray
  var params = SecItemImportExportKeyParameters(
    version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION), flags: [], passphrase: nil,
    alertTitle: nil, alertPrompt: nil, accessRef: Unmanaged.passUnretained(access),
    keyUsage: Unmanaged.passUnretained(usage), keyAttributes: Unmanaged.passUnretained(attributes))
  // SecItemImport doesn't understand unencrypted PKCS8 EC keys, but takes
  // the SEC1 ECPrivateKey ("OpenSSL") encoding.
  let x963 = key.x963Representation  // 04 || X || Y || D
  let sec1 =
    Data([0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20]) + x963.suffix(32)
    + Data([0xa0, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])  // prime256v1
    + Data([0xa1, 0x44, 0x03, 0x42, 0x00]) + x963.prefix(65)
  var format = SecExternalFormat.formatOpenSSL
  var type = SecExternalItemType.itemTypePrivateKey
  var items: CFArray?
  status = SecItemImport(sec1 as CFData, nil, &format, &type, [], &params, keychain, &items)
  guard status == errSecSuccess else {
    if status == errSecDuplicateItem { fail("this key is already in the Keychain (under another org?)") }
    fail("Keychain import failed: \(errorText(status))")
  }
  guard let imported = (items as? [Any])?.first, CFGetTypeID(imported as CFTypeRef) == SecKeyGetTypeID() else {
    fail("Keychain import returned no key")
  }
  let secKey = imported as! SecKey

  // The label is how `get` finds the key. (kSecAttrApplicationTag doesn't
  // round-trip on the file-based keychain.)
  let update = [kSecAttrLabel: label(org)] as CFDictionary
  status = SecItemUpdate([kSecValueRef: secKey] as CFDictionary, update)
  guard status == errSecSuccess else {
    SecItemDelete([kSecValueRef: secKey] as CFDictionary)
    fail("Keychain labelling failed: \(errorText(status))")
  }

  // Prove the stored key signs for the expected public key.
  let probe = Data("code.storage import check \(org) \(UUID())".utf8)
  guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sign(secKey, probe)),
    key.publicKey.isValidSignature(signature, for: probe)
  else {
    _ = deleteKey(org)
    fail("stored key for \(org) did not verify; removed it")
  }
}

func readKey(_ pem: String) -> P256.Signing.PrivateKey {
  guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
    fail("expected an ECDSA P-256 private key (PKCS8 PEM) on stdin")
  }
  return key
}

// MARK: - Commands

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "get":
  let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  var attrs: [String: String] = [:]
  for line in input.split(whereSeparator: \.isNewline) {
    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 { attrs[String(parts[0])] = String(parts[1]) }
  }
  let host = attrs["host"] ?? ""
  guard attrs["protocol"] == "https", host.hasSuffix(".code.storage") else { exit(0) }
  let org = String(host.dropLast(".code.storage".count))
  var repo = attrs["path"] ?? ""
  if repo.hasSuffix(".git") { repo.removeLast(4) }
  if repo.isEmpty { fail("no repository path; set credential.useHttpPath true") }
  guard let key = findKey(org) else { fail("no key in Keychain for \(org); run: git-credential-code-storage import \(org)") }
  print("username=t")
  print("password=\(jwt(key, org: org, repo: repo))")

case "import":
  guard arguments.count == 2, let org = arguments.last else { fail("\(usage) < key.pem") }
  let pem = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  importKey(org, readKey(pem))
  print("Stored non-extractable key for \(org) in Keychain")

case "delete":
  guard arguments.count == 2, let org = arguments.last else { fail(usage) }
  guard deleteKey(org) else { fail("no key in Keychain for \(org)") }
  print("Deleted key for \(org) from Keychain")

case "store", "erase":
  // Tokens are minted per request; nothing to store.
  break

default:
  fail(usage)
}
