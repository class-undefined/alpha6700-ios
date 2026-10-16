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
  let images = PhotoImageStore()
  let exports = ExportStore(testing: ProcessInfo.processInfo.arguments.contains("--ui-fixtures"))
  var currentExportID: String?
  var exportPauseRequested = false
  var exportNotice: String?
  private var resumeExportsOnForeground = false
  var isFixture = false
  var transferRate: Double = 0
  var transferElapsed: Double = 0
  var importContentID: Int?
  var importFileID: Int?
  var transferChunkMiB = 8
  var preferLive = true
  var dialRunning = false
  private var dialTask: Task<Void, Never>?
  private var dialPending: (Int, String)?
  var exporting = false
  var importing = false
  var importedFile: URL?
  var diagnostics = ""
  var showDiagnostics = false
  var selectedTab = 0
  private var monitor: Task<Void, Never>?
  private var video: Task<Void, Never>?
  var sessionID = UUID()
  private var disconnection: Task<Void, Never>?
  private var changingLive = false
  private var reconnectOnForeground = false
  private var resumeImport: (Int, Int, String?)?
  private var paused = false
  private var thumbnailRequests = Set<Int>()
  var properties: [CameraProperty] { snapshot?.properties ?? [] }
  var ready: Bool { transferReady && !exporting }
  var transferReady: Bool { connected && !busy && !connecting && !changingLive }
  var status: String { connecting ? "正在连接" : connected ? "相机已连接" : "尚未连接" }
  init() {
    do { try KeychainStore.consumeLocalImport() } catch { self.error = error.localizedDescription }
    access = KeychainStore.load() ?? CameraAccess()
  }
  func initialize() async {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") {
        loadFixtures()
        return
      }
    #endif
    await refreshQueue()
    #if DEBUG
      if (ProcessInfo.processInfo.arguments.contains("--connect")
        || ProcessInfo.processInfo.arguments.contains("--benchmark-transfers")) && access.complete
      {
        await connect()
        if ProcessInfo.processInfo.arguments.contains("--benchmark-transfers") {
          await measureTransferSpeed()
        }
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
      await disconnection?.value
      guard token == sessionID else { return }
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
      if selectedTab == 0 && preferLive { await startLive() }
    } catch {
      guard token == sessionID else { return }
      bridge.abort()
      connected = false
      snapshot = nil
      self.error = error.localizedDescription
      message = "连接未完成，请检查相机与局域网权限。"
    }
  }
  func disconnect(preserveImport: Bool = false) {
    if !preserveImport { resumeImport = nil }
    changingLive = false
    if exporting {
      exportPauseRequested = true
      try? exports.pauseActive()
      exporting = false
      currentExportID = nil
    }
    sessionID = UUID()
    dialTask?.cancel()
    dialTask = nil
    dialPending = nil
    dialRunning = false
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
    disconnection = Task { [bridge] in let _: Bool? = try? await bridge.call("disconnect") }
  }
  func sceneChanged(_ phase: ScenePhase) {
    if isFixture { return }
    if phase == .background {
      reconnectOnForeground = connected || connecting
      resumeExportsOnForeground = exporting
      if exporting { resumeImport = nil }
      disconnect(preserveImport: true)
    } else if phase == .active && reconnectOnForeground {
      reconnectOnForeground = false
      Task {
        await connect()
        if connected, resumeExportsOnForeground {
          resumeExportsOnForeground = false
          await runExports()
        } else if connected, let next = resumeImport {
          await importFile(next.0, next.1, expectedKey: next.2)
        }
      }
    }
  }
  func startLive() async {
    if isFixture {
      live = true
      return
    }
    guard connected, !changingLive, selectedTab == 0, !importing, !exporting else { return }
    let token = sessionID
    changingLive = true
    defer { if token == sessionID { changingLive = false } }
    do {
      let _: Bool = try await bridge.call("liveStart")
      guard connected, token == sessionID else { return }
      if selectedTab != 0 || importing || exporting {
        let _: Bool? = try? await bridge.call("liveStop")
        return
      }
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
      if token == sessionID {
        self.error = error.localizedDescription
        live = false
      }
    }
  }
  func stopLive() async {
    if isFixture {
      live = false
      return
    }
    guard !changingLive else { return }
    let token = sessionID
    changingLive = true
    defer { if token == sessionID { changingLive = false } }
    video?.cancel()
    live = false
    frame = nil
    osd = nil
    let _: Bool? = try? await bridge.call("liveStop")
  }
  private func startMonitor() {
    let token = sessionID
    monitor?.cancel()
    monitor = Task { [weak self] in
      while let self, !Task.isCancelled, self.connected {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, self.connected else { return }
        if self.busy || self.importing || self.exporting { continue }
        do {
          let s: CameraSnapshot = try await self.bridge.call("status")
          if self.connected, token == self.sessionID { self.snapshot = s }
        } catch {
          if !Task.isCancelled, token == self.sessionID {
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
    let token = sessionID
    if connected {
      do {
        let s: CameraSnapshot = try await bridge.call("status")
        if connected, token == sessionID { snapshot = s }
      } catch { self.error = error.localizedDescription }
    }
  }
  func set(_ property: CameraProperty, to value: String) async {
    #if DEBUG
      if isFixture {
        setFixture(property, value: value)
        return
      }
    #endif
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    do {
      let _: CameraProperty = try await bridge.call("set", ["code": property.code, "value": value])
      guard token == sessionID else { return }
      await refreshStatus()
      guard token == sessionID else { return }
      message = "\(property.title)已更新并读回确认"
    } catch { if token == sessionID { self.error = error.localizedDescription } }
  }
  func loadMedia() async {
    if isFixture { return }
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    do {
      let result: [CameraMedia] = try await bridge.call("list")
      guard token == sessionID else { return }
      media = result
      message = "已读取 \(media.count) 组影像"
      images.clear()
    } catch { if token == sessionID { self.error = error.localizedDescription } }
  }
  func thumbnail(_ item: CameraMedia) async {
    guard connected, !importing, !exporting, images.thumbnail(item.cacheKey) == nil,
      !thumbnailRequests.contains(item.id), let file = item.previewFile
    else { return }
    thumbnailRequests.insert(item.id)
    defer { thumbnailRequests.remove(item.id) }
    let token = sessionID
    do {
      #if DEBUG
        if isFixture {
          let photo = try await fixturePhoto(item, thumbnail: true)
          images.putThumbnail(photo.image, key: item.cacheKey)
          return
        }
      #endif
      let p: CameraPreview = try await bridge.call(
        "preview", ["id": item.id, "fileID": file.id, "quality": "thumbnail"], priority: .thumbnail)
      try Task.checkCancellation()
      let image = try await PhotoDecoder.decode(URL(fileURLWithPath: p.path), maxDimension: 360)
      try Task.checkCancellation()
      if token == sessionID { images.putThumbnail(image, key: item.cacheKey) }
    } catch { /* A cell keeps its explicit file-type placeholder; paging offers retry. */  }
  }
  func refreshQueue() async {
    do { transfers = try await bridge.call("queue") } catch {
      self.error = error.localizedDescription
    }
  }
  @discardableResult
  func importFile(_ id: Int, _ fileID: Int, expectedKey: String? = nil, forExport: Bool = false)
    async -> CameraTransfer?
  {
    #if DEBUG
      if isFixture {
        importFixture(id, fileID)
        return transfers.first { $0.selection.contentID == id && $0.selection.file.ID == fileID }
      }
    #endif
    guard forExport ? transferReady : ready, !importing else { return nil }
    let token = sessionID
    let initialOffset =
      transfers.first { t in
        expectedKey != nil
          ? t.key == expectedKey : t.selection.contentID == id && t.selection.file.ID == fileID
      }?.offset ?? 0
    importing = true
    busy = true
    importContentID = id
    importFileID = fileID
    transferRate = 0
    transferElapsed = 0
    let started = Date()
    bridge.cancelPendingPreviews()
    await stopLive()
    guard token == sessionID else { return nil }
    paused = false
    if !forExport { resumeImport = (id, fileID, expectedKey) }
    var currentKey = expectedKey
    var finished: CameraTransfer?
    defer {
      if token == sessionID {
        importing = false
        busy = false
      }
    }
    do {
      while !paused && token == sessionID {
        let t: CameraTransfer = try await bridge.call(
          "transfer",
          ["id": id, "fileID": fileID, "name": currentKey ?? "", "chunkMiB": transferChunkMiB],
          priority: .transfer)
        guard token == sessionID else { return nil }
        transferElapsed = Date().timeIntervalSince(started)
        transferRate = Double(max(0, t.offset - initialOffset)) / max(transferElapsed, 0.001)
        currentKey = t.key
        if !forExport { resumeImport = (id, fileID, currentKey) }
        if let i = transfers.firstIndex(where: { $0.id == t.id }) {
          transfers[i] = t
        } else {
          transfers.append(t)
        }
        message = "导入 \(t.name) · \(Int(t.progress*100))%"
        if t.complete {
          if !forExport { resumeImport = nil }
          finished = t
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
    if token == sessionID {
      importing = false
      busy = false
      if !forExport && selectedTab == 0 && preferLive { await startLive() }
    }
    return finished
  }
  func pauseImport() {
    if exporting { exportPauseRequested = true }
    paused = true
    resumeImport = nil
    message = "完成当前分段后暂停。"
  }
  func fetchCapture() async {
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    do {
      let path: String = try await bridge.call("fetchCapture")
      guard token == sessionID else { return }
      importedFile = URL(fileURLWithPath: path)
      message = "新照片已回传到 iPhone"
    } catch { if token == sessionID { self.error = error.localizedDescription } }
  }
  func backup() async {
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    do {
      let path: String = try await bridge.call("backup")
      guard token == sessionID else { return }
      importedFile = URL(fileURLWithPath: path)
      message = "相机设置已备份"
    } catch { if token == sessionID { self.error = error.localizedDescription } }
  }
  func upload(_ url: URL, op: String, slot: Int = 1) async {
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    do {
      let result = try await bridge.call(
        op, ["path": url.path, "name": url.lastPathComponent, "slot": slot, "confirm": true],
        as: String.self)
      guard token == sessionID else { return }
      message = result
      await refreshStatus()
    } catch { if token == sessionID { self.error = error.localizedDescription } }
  }
  func diagnose(_ op: String) async {
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    do {
      let result = try await bridge.text(op)
      guard token == sessionID else { return }
      diagnostics = result
      showDiagnostics = true
    } catch { if token == sessionID { self.error = error.localizedDescription } }
  }
  func toggleOSD() async {
    guard ready else { return }
    busy = true
    let token = sessionID
    defer { if token == sessionID { busy = false } }
    do {
      let b64: String? = try await bridge.call("osd", ["enabled": osd == nil])
      guard token == sessionID else { return }
      osd = b64.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
    } catch { if token == sessionID { self.error = error.localizedDescription } }
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

extension CameraModel {
  func tabChanged() async {
    if isFixture {
      live = selectedTab == 0
      return
    }
    if selectedTab != 0 {
      bridge.cancelPendingPreviews()
      await stopLive()
    } else if preferLive && connected && !importing && !exporting {
      await startLive()
    }
  }
  var transferSpeedLabel: String {
    guard transferRate > 0 else { return "正在连接存储卡…" }
    return String(format: "%.1f MB/s", transferRate / 1_000_000)
  }
}

extension CameraModel {
  // Coalesce detents while a write is in flight. Each write still revalidates
  // capability and reads back; intermediate gestures are never queued as commands.
  func scheduleDial(code: Int, value: String) {
    guard connected, !importing, !exporting,
      properties.first(where: { $0.code == code })?.writable == true
    else { return }
    dialPending = (code, value)
    guard dialTask == nil else { return }
    dialRunning = true
    let token = sessionID
    dialTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if token == sessionID {
          dialTask = nil
          dialRunning = false
        }
      }
      while !Task.isCancelled, token == sessionID, let pending = dialPending {
        if !ready {
          try? await Task.sleep(for: .milliseconds(60))
          continue
        }
        dialPending = nil
        guard let p = properties.first(where: { $0.code == pending.0 }), p.writable else {
          continue
        }
        if p.value == pending.1 { continue }
        await set(p, to: pending.1)
        if error != nil {
          dialPending = nil
          break
        }
      }
    }
  }
}
