#if DEBUG
  import Foundation
  import UIKit

  // Opt-in UI-test data. No credentials, networking or camera writes are used.
  // The conspicuous TEST labels prevent these images being mistaken for camera evidence.
  extension CameraModel {
    private var fixtureDirectory: URL { bridge.directory.appendingPathComponent(".ui-fixtures") }
    func loadFixtures() {
      isFixture = true
      connected = true
      live = true
      try? FileManager.default.createDirectory(
        at: fixtureDirectory, withIntermediateDirectories: true)
      var items: [CameraMedia] = []
      for i in 1...3 {
        let url = fixtureDirectory.appendingPathComponent("TEST0\(i).JPG")
        if !FileManager.default.fileExists(atPath: url.path) {
          let format = UIGraphicsImageRendererFormat()
          format.scale = 1
          let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2400, height: 1600), format: format
          ).image { ctx in
            [UIColor.systemTeal, UIColor.systemOrange, UIColor.systemIndigo][i - 1].setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
            for x in stride(from: 0, to: 2400, by: 100) {
              UIColor.black.withAlphaComponent(0.12).setFill()
              ctx.fill(CGRect(x: x, y: 0, width: 40, height: 1600))
            }
            UIColor.white.withAlphaComponent(0.8).setStroke()
            ctx.cgContext.setLineWidth(12)
            ctx.cgContext.strokeEllipse(in: CGRect(x: 800, y: 400, width: 800, height: 800))
            ("UI TEST 0\(i)" as NSString).draw(
              at: CGPoint(x: 140, y: 170),
              withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 140, weight: .bold),
                .foregroundColor: UIColor.white,
              ])
            ("2400 × 1600" as NSString).draw(
              at: CGPoint(x: 140, y: 1300),
              withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 75, weight: .regular),
                .foregroundColor: UIColor.white,
              ])
          }
          try? image.jpegData(compressionQuality: 0.94)?.write(to: url)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let file = MediaFile(
          key: "fixture-\(i)", id: 1, name: url.lastPathComponent, size: size, video: false)
        items.append(
          CameraMedia(
            id: i, created: "2026-10-16 14:0\(i):00", rating: 0, protected: false, files: [file]))
      }
      media = items
      frame = UIImage(contentsOfFile: fixtureDirectory.appendingPathComponent("TEST01.JPG").path)
      let specs: [(Int, String, String, String, [String])] = [
        (
          0xD21E, "ISO", "Exposure", "250",
          [
            "16777215", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800",
            "1000", "1250", "1600", "3200", "6400",
          ]
        ),
        (
          0x5007, "Aperture", "Exposure", "280",
          ["180", "200", "280", "400", "560", "800", "1100", "1600"]
        ),
        (
          0xD20D, "Shutter", "Exposure", "65786",
          ["65566", "65596", "65661", "65786", "66036", "66536", "67536"]
        ),
        (
          0x5010, "Exposure compensation", "Exposure", "0",
          [
            "-2000", "-1667", "-1333", "-1000", "-667", "-333", "0", "333", "667", "1000", "1333",
            "1667", "2000",
          ]
        ),
        (0x500A, "Focus mode", "Focus", "32772", ["1", "2", "32772", "32773", "32774"]),
        (
          0x5005, "White balance", "White balance", "2",
          ["2", "4", "6", "7", "32784", "32785", "32786"]
        ),
        (
          0xD20F, "Temperature", "White balance", "5500",
          ["2500", "3200", "4000", "4800", "5500", "6500", "7500", "9000"]
        ),
      ]
      let props = specs.map { code, name, group, value, choices in
        CameraProperty(
          code: code, name: name, group: group, description: "UI 测试数据", value: value,
          display: value, writable: true, type: 6, form: 2,
          choices: choices.map { .init(value: $0, label: $0) }, min: "0", max: "0", step: "0",
          caution: "")
      }
      snapshot = CameraSnapshot(
        model: "ILCE-6700 · UI TEST", firmware: "TEST", properties: props, controls: [],
        operations: [], events: [],
        liveMeta: LiveMetadata(Focus: nil, Faces: nil, Tracking: nil, Level: nil), liveError: "")
      message = "UI TEST · 离线手势测试"
    }
    func fixturePhoto(_ item: CameraMedia, original: Bool = false, thumbnail: Bool = false)
      async throws -> RenderedPhoto
    {
      let url = fixtureDirectory.appendingPathComponent(item.previewFile!.name)
      return RenderedPhoto(
        image: try await PhotoDecoder.decode(
          url, maxDimension: thumbnail ? 360 : (original ? 4096 : 2400)),
        quality: original ? "原图 · UI TEST" : "清晰预览 · UI TEST")
    }
    func setFixture(_ property: CameraProperty, value: String) {
      guard let s = snapshot else { return }
      let props = s.properties.map { p in
        p.id == property.id
          ? CameraProperty(
            code: p.code, name: p.name, group: p.group, description: p.description, value: value,
            display: value, writable: p.writable, type: p.type, form: p.form, choices: p.choices,
            min: p.min, max: p.max, step: p.step, caution: p.caution) : p
      }
      snapshot = CameraSnapshot(
        model: s.model, firmware: s.firmware, properties: props, controls: s.controls,
        operations: s.operations, events: s.events, liveMeta: s.liveMeta, liveError: s.liveError)
      message = "UI TEST · 参数已更新"
    }
    func importFixture(_ id: Int, _ fileID: Int) {
      guard let item = media.first(where: { $0.id == id }),
        let file = item.files.first(where: { $0.id == fileID })
      else { return }
      let path = fixtureDirectory.appendingPathComponent(file.name).path
      if !transfers.contains(where: { $0.key == file.key }) {
        transfers.append(
          CameraTransfer(
            key: file.key!, name: file.name, path: path, status: "complete", offset: file.size,
            size: file.size, sha256: nil, selection: .init(contentID: id, file: .init(ID: fileID))))
      }
      importedFile = URL(fileURLWithPath: path)
    }
  }
#endif
