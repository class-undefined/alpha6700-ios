import Foundation

final class CameraBridge: @unchecked Sendable {
  private let handle: Int64
  private let queue = DispatchQueue(label: "camera.protocol", qos: .userInitiated)
  let directory: URL
  init() {
    directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Imports", isDirectory: true)
    let guid = UserDefaults.standard.string(forKey: "initiatorGUID") ?? UUID().uuidString
    UserDefaults.standard.set(guid, forKey: "initiatorGUID")
    handle = directory.path.withCString { root in guid.withCString { CameraCreate(root, $0) } }
  }
  deinit { CameraDestroy(handle) }
  func abort() { CameraAbort(handle) }
  func frame() -> Data? {
    var length: Int64 = 0
    guard let p = CameraCopyFrame(handle, &length), length > 0 else { return nil }
    defer { CameraFree(p) }
    return Data(bytes: p, count: Int(length))
  }
  func call<T: Decodable>(_ op: String, _ values: [String: Any] = [:], as: T.Type = T.self)
    async throws -> T
  {
    var request = values
    request["op"] = op
    let data = try JSONSerialization.data(withJSONObject: request)
    guard let json = String(data: data, encoding: .utf8) else {
      throw CameraFailure(message: "无法编码请求")
    }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [handle] in
        do {
          guard let ptr = json.withCString({ CameraRequest(handle, $0) }) else {
            throw CameraFailure(message: "协议引擎未就绪")
          }
          defer { CameraFree(ptr) }
          let reply = Data(String(cString: ptr).utf8)
          let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
          guard object["ok"] as? Bool == true else {
            throw CameraFailure(message: object["error"] as? String ?? "相机请求失败")
          }
          let payload = try JSONSerialization.data(
            withJSONObject: object["data"] ?? NSNull(), options: [.fragmentsAllowed])
          let result = try JSONDecoder().decode(T.self, from: payload)
          continuation.resume(returning: result)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  func text(_ op: String, _ values: [String: Any] = [:]) async throws -> String {
    // Diagnostic replies may be structured arrays or objects.
    var request = values
    request["op"] = op
    let data = try JSONSerialization.data(withJSONObject: request)
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [handle] in
        let ptr = String(data: data, encoding: .utf8)!.withCString { CameraRequest(handle, $0) }
        guard let ptr else {
          continuation.resume(throwing: CameraFailure(message: "协议引擎未就绪"))
          return
        }
        defer { CameraFree(ptr) }
        do {
          let object =
            try JSONSerialization.jsonObject(with: Data(String(cString: ptr).utf8))
            as? [String: Any] ?? [:]
          guard object["ok"] as? Bool == true else {
            throw CameraFailure(message: object["error"] as? String ?? "请求失败")
          }
          if let s = object["data"] as? String {
            continuation.resume(returning: s)
          } else {
            let d = try JSONSerialization.data(
              withJSONObject: object["data"] ?? NSNull(),
              options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            continuation.resume(returning: String(decoding: d, as: UTF8.self))
          }
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
