import Foundation

struct CameraAccess: Codable, Equatable {
  var host = ""
  var user = ""
  var password = ""
  var fingerprint = ""
  var complete: Bool { !host.isEmpty && !user.isEmpty && !password.isEmpty && !fingerprint.isEmpty }
}
struct CameraProperty: Decodable, Identifiable, Hashable {
  struct Choice: Decodable, Hashable {
    let value: String
    let label: String
  }
  let code: Int
  let name, group, description, value, display: String
  let writable: Bool
  let type, form: Int
  let choices: [Choice]
  let min, max, step, caution: String
  var id: Int { code }
  var title: String { Self.names[code] ?? name }
  var groupTitle: String { Self.groups[group] ?? group }
  var formatted: String { formattedValue(value, fallback: display) }
  func formattedValue(_ raw: String, fallback: String) -> String {
    if let n = Int(raw) {
      if code == 0x500A,
        let label = [1: "MF", 2: "AF-S", 0x8004: "AF-C", 0x8005: "AF-A", 0x8006: "DMF"][n]
      {
        return label
      }
      if code == 0x5005,
        let label = [
          2: "AWB", 4: "日光", 6: "钨丝灯", 7: "闪光灯", 0x8010: "阴天", 0x8011: "阴影", 0x8012: "色温",
          0x8020: "自定义 1", 0x8021: "自定义 2", 0x8022: "自定义 3",
        ][n]
      {
        return label
      }
      if code == 0x500E, let label = [1: "M", 2: "P", 3: "A", 4: "S"][n] { return label }
      if code == 0x5010 { return String(format: "%+.1f EV", Double(n) / 1000) }
      if code == 0xD20F { return "\(n) K" }
    }
    if code == 0xD21E, let n = UInt32(raw) {
      let iso = n & 0x00ff_ffff
      let label = iso == 0x00ff_ffff ? "AUTO" : String(iso)
      if n >> 24 == 0x10 { return label + " 扩展" }
      return n >> 24 == 0 ? label : label + String(format: " · 0x%02X", n >> 24)
    }
    if code == 0x5007, let n = Int(raw) {
      if n == 0 || n >= 65533 { return "ƒ/—" }
      return String(format: "ƒ/%.1f", Double(n) / 100)
    }
    if code == 0xD20D, let n = UInt32(raw) {
      if n == 0 { return "BULB" }
      if n == UInt32.max { return "—" }
      let numerator = n >> 16
      let denominator = n & 0xffff
      if denominator == 0 { return "—" }
      if numerator >= denominator {
        return String(format: "%g s", Double(numerator) / Double(denominator))
      }
      return "\(numerator)/\(denominator)"
    }
    return fallback.trimmingCharacters(in: .whitespaces)
  }
  static let groups = [
    "Exposure": "曝光", "Focus": "对焦", "Drive": "拍摄", "White balance": "白平衡", "Image": "影像",
    "Movie": "视频", "Display": "显示", "Transfer": "传输", "Buttons & dials": "按键与拨轮", "Device": "机身",
    "Undocumented": "其他参数",
  ]
  static let names = [
    0x5001: "电量", 0x5005: "白平衡", 0xD218: "电量", 0xD22C: "对焦区域", 0xD23F: "图片配置", 0x5013: "拍摄模式",
    0x5007: "光圈", 0x500A: "对焦模式", 0x500E: "曝光模式", 0x5010: "曝光补偿", 0xD21E: "ISO",
    0xD20D: "快门速度", 0xD20F: "色温", 0xD222: "照片保存位置", 0xD268: "回传尺寸", 0xD215: "待回传照片", 0xD208: "可用按键",
    0xD20A: "可用拨轮", 0xD278: "取景流", 0xD207: "相机屏幕叠层",
  ]
}
struct CameraEvent: Decodable, Identifiable {
  let Code: Int
  let TransactionID: Int
  let Params: [Int]?
  var id: String { "\(Code)-\(TransactionID)-\(Params ?? [])" }
  var summary: String {
    if Code == 0xC209 { return Params?.first == 1 ? "设置恢复完成" : "设置恢复结果：\(Params ?? [])" }
    if Code == 0xC214 { return Params?.first == 1 ? "LUT 导入完成" : "LUT 导入结果：\(Params ?? [])" }
    return String(format: "0x%04X", Code) + "  \(Params ?? [])"
  }
}
struct FrameRect: Decodable {
  let X, Y, W, H, XMax, YMax: Double
  let State: Int
}
struct FrameLevel: Decodable { let State, X, Y, Z: Int }
struct LiveMetadata: Decodable {
  let Focus, Faces, Tracking: [FrameRect]?
  let Level: FrameLevel?
}
struct CameraSnapshot: Decodable {
  let model, firmware: String
  let properties: [CameraProperty]
  let controls, operations: [Int]
  let events: [CameraEvent]
  let liveMeta: LiveMetadata
  let liveError: String
}
struct MediaFile: Decodable, Identifiable, Hashable {
  var key: String? = nil
  let id: Int
  let name: String
  let size: Int64
  let video: Bool
  var sizeLabel: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}
struct CameraMedia: Decodable, Identifiable, Hashable {
  let id: Int
  let created: String
  let rating: Int
  let `protected`: Bool
  let files: [MediaFile]
  var title: String { files.first?.name ?? "影像 \(id)" }
}
struct CameraTransfer: Decodable, Identifiable {
  struct Selection: Decodable {
    struct File: Decodable { let ID: Int }
    let contentID: Int
    let file: File
  }
  let key, name, path, status: String
  let offset, size: Int64
  let sha256: String?
  let selection: Selection
  var id: String { key }
  var complete: Bool { status == "complete" }
  var progress: Double { size > 0 ? Double(offset) / Double(size) : 0 }
}
struct CameraFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
