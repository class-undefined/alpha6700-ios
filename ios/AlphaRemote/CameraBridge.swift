import Foundation

// One PTP command at a time, with explicit priority and cancellation before
// dispatch. Swiping past a photo never queues hundreds of obsolete downloads.
final class CameraBridge: @unchecked Sendable {
  enum Priority: Int {
    case transfer = 0
    case interactive = 1
    case preview = 2
    case thumbnail = 3
  }
  private final class Ticket: @unchecked Sendable {
    let priority: Priority
    let json: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false
    init(_ priority: Priority, _ json: String) {
      self.priority = priority
      self.json = json
    }
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
    func install(_ c: CheckedContinuation<Data, Error>) {
      lock.lock()
      if cancelled {
        lock.unlock()
        c.resume(throwing: CancellationError())
      } else {
        continuation = c
        lock.unlock()
      }
    }
    func cancel() {
      lock.lock()
      cancelled = true
      let c = continuation
      continuation = nil
      lock.unlock()
      c?.resume(throwing: CancellationError())
    }
    func finish(_ result: Result<Data, Error>) {
      lock.lock()
      let c = continuation
      continuation = nil
      lock.unlock()
      c?.resume(with: result)
    }
  }
  private let handle: Int64
  private let queue = DispatchQueue(label: "camera.protocol", qos: .userInitiated)
  private let lock = NSLock()
  private var pending: [Ticket] = []
  private var draining = false
  let directory: URL
  init() {
    directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Imports", isDirectory: true)
    let guid = UserDefaults.standard.string(forKey: "initiatorGUID") ?? UUID().uuidString
    UserDefaults.standard.set(guid, forKey: "initiatorGUID")
    handle = directory.path.withCString { root in guid.withCString { CameraCreate(root, $0) } }
  }
  deinit { CameraDestroy(handle) }
  func abort() {
    cancelPendingPreviews()
    CameraAbort(handle)
  }
  func cancelPendingPreviews() {
    lock.lock()
    let obsolete = pending.filter { $0.priority.rawValue >= Priority.preview.rawValue }
    pending.removeAll { $0.priority.rawValue >= Priority.preview.rawValue }
    lock.unlock()
    obsolete.forEach { $0.cancel() }
  }
  func frame() -> Data? {
    var length: Int64 = 0
    guard let p = CameraCopyFrame(handle, &length), length > 0 else { return nil }
    defer { CameraFree(p) }
    return Data(bytes: p, count: Int(length))
  }
  private func enqueue(_ ticket: Ticket) {
    lock.lock()
    pending.append(ticket)
    let start = !draining
    draining = true
    lock.unlock()
    if start { queue.async { [self] in drain() } }
  }
  private func drain() {
    while true {
      lock.lock()
      pending.removeAll { $0.isCancelled }
      guard
        let index = pending.indices.min(by: {
          pending[$0].priority.rawValue < pending[$1].priority.rawValue
        })
      else {
        draining = false
        lock.unlock()
        return
      }
      let ticket = pending.remove(at: index)
      lock.unlock()
      guard !ticket.isCancelled else { continue }
      guard let ptr = ticket.json.withCString({ CameraRequest(handle, $0) }) else {
        ticket.finish(.failure(CameraFailure(message: "协议引擎未就绪")))
        continue
      }
      let data = Data(String(cString: ptr).utf8)
      CameraFree(ptr)
      ticket.finish(.success(data))
    }
  }
  private func payload(_ op: String, _ values: [String: Any], priority: Priority) async throws
    -> Data
  {
    try Task.checkCancellation()
    var request = values
    request["op"] = op
    let encoded = try JSONSerialization.data(withJSONObject: request)
    let ticket = Ticket(priority, String(decoding: encoded, as: UTF8.self))
    let reply: Data = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        ticket.install(continuation)
        enqueue(ticket)
      }
    } onCancel: {
      ticket.cancel()
    }
    try Task.checkCancellation()
    let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
    guard object["ok"] as? Bool == true else {
      throw CameraFailure(message: object["error"] as? String ?? "相机请求失败")
    }
    return try JSONSerialization.data(
      withJSONObject: object["data"] ?? NSNull(), options: [.fragmentsAllowed])
  }
  func call<T: Decodable>(
    _ op: String, _ values: [String: Any] = [:], as: T.Type = T.self,
    priority: Priority = .interactive
  ) async throws -> T {
    try JSONDecoder().decode(T.self, from: await payload(op, values, priority: priority))
  }
  func text(_ op: String, _ values: [String: Any] = [:]) async throws -> String {
    let data = try await payload(op, values, priority: .interactive)
    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    if let string = value as? String { return string }
    return String(
      decoding: try JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
      as: UTF8.self)
  }
}
