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
  var formatted: String {
    if code == 0xD21E && value == "16777215" { return "AUTO" }
    if code == 0x5007, let n = Double(value) { return String(format: "ƒ/%.1f", n / 100) }
    return display.trimmingCharacters(in: .whitespaces)
  }
  static let groups = [
    "Exposure": "曝光", "Focus": "对焦", "Drive": "拍摄", "White balance": "白平衡", "Image": "影像",
    "Movie": "视频", "Display": "显示", "Transfer": "传输", "Buttons & dials": "按键与拨轮", "Device": "机身",
    "Undocumented": "其他参数",
  ]
  static let names = [
    0x5001: "电量", 0x5007: "光圈", 0x500A: "对焦模式", 0x500E: "曝光模式", 0x5010: "曝光补偿", 0xD21E: "ISO",
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
