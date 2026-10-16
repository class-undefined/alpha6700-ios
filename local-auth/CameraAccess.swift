import AppKit
import Foundation
import Security

// The account password stays in the macOS login Keychain. --read is intended
// only for a local parent process that passes the value to the camera client.
struct Access: Codable {
    let host: String
    let user: String
    let password: String
    let fingerprint: String
}

let service = "com.classundefined.sony-camera-investigation"
let account = "ILCE-6700"
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func normalizeFingerprint(_ input: String) -> String? {
    var value = input.precomposedStringWithCompatibilityMapping
        .components(separatedBy: .whitespacesAndNewlines).joined()
        .replacingOccurrences(of: "\u{200B}", with: "")
    for prefix in ["SHA256:", "SHA-256:"] {
        if value.uppercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
    }
    let hex = value.replacingOccurrences(of: ":", with: "")
    var bytes: Data?
    if hex.count == 64 && hex.allSatisfy({ $0.isHexDigit }) {
        let chars = Array(hex)
        var decoded = [UInt8]()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            decoded.append(b)
        }
        bytes = Data(decoded)
    } else {
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        bytes = Data(base64Encoded: value)
    }
    guard let decoded = bytes, decoded.count == 32 else { return nil }
    return "SHA256:" + decoded.base64EncodedString().replacingOccurrences(of: "=", with: "")
}

if CommandLine.arguments.contains("--self-test") {
    let data = Data((0..<32).map { UInt8($0) })
    let encoded = data.base64EncodedString()
    let expected = "SHA256:" + encoded.replacingOccurrences(of: "=", with: "")
    let multiline = "SHA256： " + encoded.prefix(20) + "\n" + encoded.dropFirst(20)
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: ":")
    guard normalizeFingerprint(expected) == expected,
          normalizeFingerprint(multiline) == expected,
          normalizeFingerprint(hex) == expected,
          normalizeFingerprint("short") == nil else { fail("Fingerprint parsing self-test failed") }
    print("Fingerprint parsing: canonical, wrapped, full-width colon, hexadecimal, invalid input passed")
    exit(0)
}

if CommandLine.arguments.contains("--read") || CommandLine.arguments.contains("--status") {
    var readQuery = query
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
    if CommandLine.arguments.contains("--status") {
        print(status == errSecSuccess ? "credentials_available" : "credentials_unavailable")
        exit(status == errSecSuccess ? 0 : 1)
    }
    guard status == errSecSuccess, let data = result as? Data else {
        fail("Camera access information is not available in this task's Keychain item.")
    }
    FileHandle.standardOutput.write(data)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let alert = NSAlert()
alert.messageText = "连接你的 Sony α6700"
alert.informativeText = "先退出手机上的遥控或导入页面。在相机上开启电脑遥控，然后打开：网络 → 网络选项 → 访问认证信息。\n\n请填写相机 IP，并照相机屏幕输入用户名、密码和指纹。信息保存在此 Mac 的钥匙串中，不会写入聊天或项目文件。"
alert.addButton(withTitle: "保存并继续本地验证")
alert.addButton(withTitle: "取消")

let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 182))
let hostField = NSTextField(string: "")
let userField = NSTextField(string: "")
let passwordField = NSSecureTextField(string: "")
let fingerprintField = NSTextField(string: "")
let items: [(String, NSTextField)] = [
    ("相机 IP", hostField), ("用户名", userField),
    ("密码", passwordField), ("SHA256 指纹", fingerprintField)
]
for (index, pair) in items.enumerated() {
    let y = CGFloat(142 - 42 * index)
    let label = NSTextField(labelWithString: pair.0)
    label.frame = NSRect(x: 0, y: y + 3, width: 105, height: 22)
    pair.1.frame = NSRect(x: 110, y: y, width: 440, height: 27)
    pair.1.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    view.addSubview(label)
    view.addSubview(pair.1)
}
fingerprintField.placeholderString = "SHA256:…（照相机屏幕输入）"
alert.accessoryView = view
alert.window.initialFirstResponder = userField
app.activate(ignoringOtherApps: true)

while true {
    let result = alert.runModal()
    guard result == .alertFirstButtonReturn else { print("cancelled"); exit(2) }
    // Commit the active field editor before reading the final edited field.
    alert.window.makeFirstResponder(nil)
    let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let password = passwordField.stringValue
    let rawFP = fingerprintField.stringValue
    let normalizedFP = normalizeFingerprint(rawFP)
    var problems: [String] = []
    if host.isEmpty { problems.append("相机 IP 为空。") }
    if user.isEmpty { problems.append("用户名为空。") }
    if password.isEmpty { problems.append("密码为空。") }
    if normalizedFP == nil {
        let compact = rawFP.components(separatedBy: .whitespacesAndNewlines).joined()
        problems.append("指纹格式不匹配：当前有 \(compact.count) 个非空白字符。SHA256 指纹通常是 SHA256: 加 43 个字符，请把相机屏幕上的各行连起来输入；空格和换行会自动去除。")
    }
    if !problems.isEmpty {
        let error = NSAlert()
        error.messageText = "请检查以下字段"
        error.informativeText = problems.joined(separator: "\n\n")
        error.runModal()
        continue
    }
    let access = Access(host: host, user: user, password: password, fingerprint: normalizedFP!)
    guard let data = try? JSONEncoder().encode(access) else { fail("Could not encode local access information.") }
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrLabel as String] = "Sony α6700 本地协议验证"
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    var status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecDuplicateItem {
        status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }
    guard status == errSecSuccess else { fail("Keychain could not save camera access information (code \(status)).") }
    passwordField.stringValue = ""
    print("credentials_saved_to_keychain")
    exit(0)
}
