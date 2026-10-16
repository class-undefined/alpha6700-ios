import Foundation
import Security

struct KeychainStore {
  private static let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.classundefined.alpharemote",
    kSecAttrAccount as String: "camera",
  ]
  static func load() -> CameraAccess? {
    var q = query
    q[kSecReturnData as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(CameraAccess.self, from: data)
  }
  static func save(_ access: CameraAccess) throws {
    let data = try JSONEncoder().encode(access)
    let update =
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as [String: Any]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(update) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw CameraFailure(message: "钥匙串保存失败（\(status)）") }
  }
  static func erase() throws {
    let s = SecItemDelete(query as CFDictionary)
    guard s == errSecSuccess || s == errSecItemNotFound else {
      throw CameraFailure(message: "钥匙串删除失败（\(s)）")
    }
  }
  static func normalizedFingerprint(_ text: String) -> String? {
    var v = text.precomposedStringWithCompatibilityMapping.components(
      separatedBy: .whitespacesAndNewlines
    ).joined().replacingOccurrences(of: "\u{200B}", with: "")
    for prefix in ["SHA256:", "SHA-256:"] where v.uppercased().hasPrefix(prefix) {
      v = String(v.dropFirst(prefix.count))
    }
    let hex = v.replacingOccurrences(of: ":", with: "")
    var bytes: Data?
    if hex.count == 64 && hex.allSatisfy(\.isHexDigit) {
      let chars = Array(hex)
      var raw = [UInt8]()
      for i in stride(from: 0, to: 64, by: 2) {
        guard let n = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
        raw.append(n)
      }
      bytes = Data(raw)
    } else {
      v = v.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      while v.count % 4 != 0 { v += "=" }
      bytes = Data(base64Encoded: v)
    }
    guard let b = bytes, b.count == 32 else { return nil }
    return "SHA256:" + b.base64EncodedString().replacingOccurrences(of: "=", with: "")
  }
  // A paired Mac can transfer this one-time file directly into this app's
  // sandbox. It is removed immediately after Keychain persistence, never
  // shipped in the bundle or stored in UserDefaults.
  static func consumeLocalImport() throws {
    let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AccessImport.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return }
    let data = try Data(contentsOf: path)
    let access = try JSONDecoder().decode(CameraAccess.self, from: data)
    guard access.complete, normalizedFingerprint(access.fingerprint) != nil else {
      throw CameraFailure(message: "本地导入的认证信息格式无效")
    }
    try save(access)
    try FileManager.default.removeItem(at: path)
  }
}
