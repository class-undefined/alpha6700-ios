import Foundation
import Observation
import Photos
import SwiftUI

@MainActor @Observable final class CameraModel {
  let bridge = CameraBridge()
  var access = CameraAccess()
  var snapshot: CameraSnapshot?
  var connected = false
  var busy = false
  var connecting = false
  var message = "连接相机，开始创作。"
  var error: String?
  var showConnection = false
  var frame: UIImage?
  var osd: UIImage?
  var live = false
  var media: [CameraMedia] = []
  var transfers: [CameraTransfer] = []
  var thumbnails: [Int: UIImage] = [:]
  var importing = false
  var importedFile: URL?
  var diagnostics = ""
  var showDiagnostics = false
  var selectedTab = 0
  private var monitor: Task<Void, Never>?
  private var video: Task<Void, Never>?
  private var sessionID = UUID()
  private var reconnectOnForeground = false
  private var resumeImport: (Int, Int)?
  private var paused = false
  private var thumbnailRequests = Set<Int>()
  var properties: [CameraProperty] { snapshot?.properties ?? [] }
  var ready: Bool { connected && !busy && !connecting }
  var status: String { connecting ? "正在连接" : connected ? "相机已连接" : "尚未连接" }
  init() {
    do { try KeychainStore.consumeLocalImport() } catch { self.error = error.localizedDescription }
    access = KeychainStore.load() ?? CameraAccess()
  }
  func initialize() async {
    await refreshQueue()
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--connect") && access.complete {
        await connect()
      }
    #endif
  }
  func connect() async {
    guard !busy && !connecting else { return }
    guard let fp = KeychainStore.normalizedFingerprint(access.fingerprint) else {
      error = "请填写相机屏幕上的 SHA256 指纹。"
      return
    }
    access.fingerprint = fp
    connecting = true
    busy = true
    message = "正在验证相机并建立连接…"
    let token = UUID()
    sessionID = token
    defer {
      if token == sessionID {
        connecting = false
        busy = false
      }
    }
    do {
      let data = try JSONEncoder().encode(access)
      let object = try JSONSerialization.jsonObject(with: data)
      let result: CameraSnapshot = try await bridge.call("connect", ["access": object])
      guard token == sessionID else { return }
      try KeychainStore.save(access)
      snapshot = result
      connected = true
      showConnection = false
      message = "\(result.model) · 固件 \(result.firmware)"
      startMonitor()
      await startLive()
    } catch {
      guard token == sessionID else { return }
      bridge.abort()
      connected = false
      snapshot = nil
      self.error = error.localizedDescription
      message = "连接未完成，请检查相机与局域网权限。"
    }
  }
  func disconnect() {
    sessionID = UUID()
    monitor?.cancel()
    video?.cancel()
    paused = true
    bridge.abort()
    connected = false
    busy = false
    connecting = false
    live = false
    frame = nil
    osd = nil
    importing = false
    snapshot = nil
    message = "连接已断开，导入进度已保存。"
    Task { let _: Bool? = try? await bridge.call("disconnect") }
  }
  func sceneChanged(_ phase: ScenePhase) {
    if phase == .background {
      reconnectOnForeground = connected
      disconnect()
    } else if phase == .active && reconnectOnForeground {
      reconnectOnForeground = false
      Task {
        await connect()
        if connected, let next = resumeImport { await importFile(next.0, next.1) }
      }
    }
  }
  func startLive() async {
    guard connected else { return }
    do {
      let _: Bool = try await bridge.call("liveStart")
      guard connected else { return }
      live = true
      video?.cancel()
      video = Task { [weak self] in
        while let self, !Task.isCancelled, self.connected, self.live {
          let data = self.bridge.frame()
          self.frame = data.flatMap(UIImage.init(data:))
          try? await Task.sleep(for: .milliseconds(66))
        }
      }
    } catch {
      self.error = error.localizedDescription
      live = false
    }
  }
  func stopLive() async {
    video?.cancel()
    live = false
    frame = nil
    osd = nil
    let _: Bool? = try? await bridge.call("liveStop")
  }
  private func startMonitor() {
    monitor?.cancel()
    monitor = Task { [weak self] in
      while let self, !Task.isCancelled, self.connected {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, self.connected else { return }
        if self.busy || self.importing { continue }
        do {
          let s: CameraSnapshot = try await self.bridge.call("status")
          if self.connected { self.snapshot = s }
        } catch {
          if !Task.isCancelled {
            self.error = error.localizedDescription
            self.disconnect()
          }
          return
        }
      }
    }
  }
  func perform(_ action: String, values: [String: Any] = [:], success: String = "已发送到相机") async {
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    do {
      let _: Bool = try await bridge.call(action, values)
      guard token == sessionID else { return }
      message = success
      await refreshStatus()
    } catch { if token == sessionID { self.error = error.localizedDescription } }
  }
  func refreshStatus() async {
    if connected {
      do {
        let s: CameraSnapshot = try await bridge.call("status")
        if connected { snapshot = s }
      } catch { self.error = error.localizedDescription }
    }
  }
  func set(_ property: CameraProperty, to value: String) async {
    guard ready else { return }
    busy = true
    defer { busy = false }
    do {
      let _: CameraProperty = try await bridge.call("set", ["code": property.code, "value": value])
      await refreshStatus()
      message = "\(property.title)已更新并读回确认"
    } catch { self.error = error.localizedDescription }
  }
  func loadMedia() async {
    guard ready else { return }
    busy = true
    defer { busy = false }
    do {
      media = try await bridge.call("list")
      message = "已读取 \(media.count) 组影像"
      thumbnails.removeAll()
    } catch { self.error = error.localizedDescription }
  }
  func thumbnail(_ item: CameraMedia) async {
    guard connected, !importing, thumbnails[item.id] == nil, !thumbnailRequests.contains(item.id),
      let file = item.files.first
    else { return }
    thumbnailRequests.insert(item.id)
    defer { thumbnailRequests.remove(item.id) }
    do {
      let b64: String = try await bridge.call("thumbnail", ["id": item.id, "fileID": file.id])
      if let d = Data(base64Encoded: b64), let img = UIImage(data: d) {
        if thumbnails.count > 120 { thumbnails.removeAll() }
        thumbnails[item.id] = img
      }
    } catch { /* Per-item failure leaves an explicit file-type placeholder. */  }
  }
  func refreshQueue() async {
    do { transfers = try await bridge.call("queue") } catch {
      self.error = error.localizedDescription
    }
  }
  func importFile(_ id: Int, _ fileID: Int) async {
    guard ready, !importing else { return }
    importing = true
    busy = true
    paused = false
    resumeImport = (id, fileID)
    let token = sessionID
    defer {
      if token == sessionID {
        importing = false
        busy = false
      }
    }
    do {
      while !paused && token == sessionID {
        let t: CameraTransfer = try await bridge.call("transfer", ["id": id, "fileID": fileID])
        guard token == sessionID else { return }
        if let i = transfers.firstIndex(where: { $0.id == t.id }) {
          transfers[i] = t
        } else {
          transfers.append(t)
        }
        message = "导入 \(t.name) · \(Int(t.progress*100))%"
        if t.complete {
          resumeImport = nil
          importedFile = URL(fileURLWithPath: t.path)
          message = "\(t.name)已导入"
          break
        }
        await Task.yield()
      }
    } catch {
      if token == sessionID {
        self.error = error.localizedDescription
        message = "导入已暂停，确认的分段已保存。"
      }
    }
    await refreshQueue()
  }
  func pauseImport() {
    paused = true
    resumeImport = nil
    message = "完成当前分段后暂停。"
  }
  func fetchCapture() async {
    guard ready else { return }
    busy = true
    defer { busy = false }
    do {
      let path: String = try await bridge.call("fetchCapture")
      importedFile = URL(fileURLWithPath: path)
      message = "新照片已回传到 iPhone"
    } catch { self.error = error.localizedDescription }
  }
  func backup() async {
    guard ready else { return }
    busy = true
    defer { busy = false }
    do {
      let path: String = try await bridge.call("backup")
      importedFile = URL(fileURLWithPath: path)
      message = "相机设置已备份"
    } catch { self.error = error.localizedDescription }
  }
  func upload(_ url: URL, op: String, slot: Int = 1) async {
    guard ready else { return }
    busy = true
    defer { busy = false }
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    do {
      message = try await bridge.call(
        op, ["path": url.path, "name": url.lastPathComponent, "slot": slot, "confirm": true],
        as: String.self)
      await refreshStatus()
    } catch { self.error = error.localizedDescription }
  }
  func diagnose(_ op: String) async {
    guard ready else { return }
    busy = true
    defer { busy = false }
    do {
      diagnostics = try await bridge.text(op)
      showDiagnostics = true
    } catch { self.error = error.localizedDescription }
  }
  func toggleOSD() async {
    guard ready else { return }
    busy = true
    defer { busy = false }
    do {
      let b64: String? = try await bridge.call("osd", ["enabled": osd == nil])
      osd = b64.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
    } catch { self.error = error.localizedDescription }
  }
  func syncClock() async {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd'T'HHmmss'.0'"
    let now = Date()
    let zone = TimeZone.current
    let dst = zone.isDaylightSavingTime(for: now)
    let offset = zone.secondsFromGMT(for: now) - (dst ? 3600 : 0)
    let area = String(
      format: "%@%02d%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
    await perform(
      "setClock", values: ["value": ["DateTime": f.string(from: now), "Area": area, "DST": dst]],
      success: "已同步 iPhone 时间与时区")
  }
  func saveToPhotos(_ url: URL) async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      error = "请在设置中允许添加照片，或通过分享菜单保存到文件。"
      return
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let video = ["mp4", "mov", "mxf"].contains(url.pathExtension.lowercased())
        request.addResource(with: video ? .video : .photo, fileURL: url, options: nil)
      }
      message = "已保存到系统照片"
    } catch { self.error = "照片图库无法导入此格式，原文件仍保存在 App 的 Imports 文件夹。\n" + error.localizedDescription }
  }
}
