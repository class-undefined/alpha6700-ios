import CoreGraphics
import Foundation

@main enum ExportLogicTests {
  @MainActor static func main() throws {
    let raw = MediaFile(key: "raw-key", id: 1, name: "DSC001.ARW", size: 30_000_000, video: false)
    let jpeg = MediaFile(key: "jpeg-key", id: 2, name: "DSC001.JPG", size: 5_000_000, video: false)
    let heif = MediaFile(key: "heif-key", id: 3, name: "DSC002.HIF", size: 8_000_000, video: false)
    let video = MediaFile(
      key: "video-key", id: 4, name: "MOV003.MP4", size: 100_000_000, video: true)
    func item(_ id: Int, _ files: [MediaFile]) -> CameraMedia {
      CameraMedia(id: id, created: "2026-10-16", rating: 0, protected: false, files: files)
    }
    let pair = item(1, [raw, jpeg])
    let onlyRaw = item(2, [raw])
    let onlyHEIF = item(3, [heif])
    let movie = item(4, [video])
    let jpg = ExportPlanner.plan([pair], format: .jpeg)
    precondition(
      jpg.jobs.count == 1 && jpg.jobs[0].sourceKey == "jpeg-key" && !jpg.jobs[0].convertToJPEG,
      "Existing JPEG must win over a RAW conversion")
    let converted = ExportPlanner.plan([onlyRaw, onlyHEIF], format: .jpeg)
    precondition(
      converted.jobs.count == 2 && converted.conversionCount == 2
        && converted.jobs[0].outputName == "DSC001.JPG")
    let raws = ExportPlanner.plan([pair, onlyHEIF, movie], format: .raw)
    precondition(
      raws.jobs.count == 1 && raws.skipped.count == 2 && raws.jobs[0].sourceName.hasSuffix(".ARW"))
    let all = ExportPlanner.plan([pair, movie], format: .originals)
    precondition(all.jobs.count == 3 && all.sourceBytes == 135_000_000 && all.conversionCount == 0)
    precondition(
      ExportPlanner.plan([pair, pair], format: .originals).jobs.count == 2,
      "Duplicate selections cannot export twice")
    precondition(
      ExportPlanner.plan([movie], format: .jpeg).jobs.isEmpty,
      "A video cannot become a JPEG photo export")
    let restored = try JSONDecoder().decode(
      [ExportJob].self, from: JSONEncoder().encode(converted.jobs))
    precondition(
      restored == converted.jobs && restored[0].sourceKey == "raw-key",
      "A restored queue must retain file identity and format")
    let rect = ViewfinderGeometry.fit(
      image: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 428, height: 600))
    precondition(abs(rect.width - 428) < 0.01 && abs(rect.height - 240.75) < 0.01)
    precondition(
      ViewfinderGeometry.cameraPoint(CGPoint(x: 214, y: 20), imageRect: rect) == nil,
      "A letterbox tap must not focus")
    let center = ViewfinderGeometry.cameraPoint(
      CGPoint(x: rect.midX, y: rect.midY), imageRect: rect)!
    precondition(center.x == 320 && center.y == 240)
    let landscape = ViewfinderGeometry.fit(
      image: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 750, height: 360))
    precondition(landscape.width > rect.width && landscape.height == 360)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "alpha-export-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: temporary)
      defaults.removePersistentDomain(forName: suite)
    }
    let store = ExportStore(documentsURL: temporary, defaults: defaults)
    store.format = .jpeg
    try store.enqueue(converted)
    try store.update(converted.jobs[0].id, status: .downloading)
    let reopened = ExportStore(documentsURL: temporary, defaults: defaults)
    precondition(
      reopened.format == .jpeg && reopened.jobs[0].status == .paused,
      "Interrupted work must recover as paused")
    precondition(
      reopened.activeIDs == converted.jobs.map(\.id), "Queued files must survive restart")
    try reopened.enqueue(converted)
    precondition(reopened.jobs.count == 2, "Enqueuing the same selection must not duplicate jobs")
    do {
      try reopened.update(
        converted.jobs[0].id, status: .complete, output: URL(fileURLWithPath: "/tmp/outside.JPG"))
      preconditionFailure("escaped export path accepted")
    } catch {}
    print(
      "Export planning, persistence, format preferences and viewfinder geometry: 15 checks passed")
  }
}
