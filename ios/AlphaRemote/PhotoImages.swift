import CoreImage
import Foundation
import ImageIO
import Observation
import UIKit

struct CameraPreview: Decodable {
  let path, quality: String
  let bytes: Int64
  let cached: Bool
}
struct RenderedPhoto {
  let image: UIImage
  let quality: String
  var dimensions: String { "\(image.cgImage?.width ?? 0) × \(image.cgImage?.height ?? 0)" }
}
private final class PhotoBox {
  let photo: RenderedPhoto
  init(_ p: RenderedPhoto) { photo = p }
}
@MainActor @Observable final class PhotoImageStore {
  private var revision = 0
  @ObservationIgnored private let thumbnails = NSCache<NSString, UIImage>()
  @ObservationIgnored private let previews = NSCache<NSString, PhotoBox>()
  init() {
    thumbnails.countLimit = 180
    thumbnails.totalCostLimit = 24 << 20
    previews.countLimit = 5
    previews.totalCostLimit = 96 << 20
  }
  func thumbnail(_ key: String) -> UIImage? {
    _ = revision
    return thumbnails.object(forKey: key as NSString)
  }
  func putThumbnail(_ image: UIImage, key: String) {
    thumbnails.setObject(image, forKey: key as NSString, cost: cost(image))
    revision += 1
  }
  func preview(_ key: String) -> RenderedPhoto? {
    _ = revision
    return previews.object(forKey: key as NSString)?.photo
  }
  func putPreview(_ photo: RenderedPhoto, key: String) {
    previews.setObject(PhotoBox(photo), forKey: key as NSString, cost: cost(photo.image))
    revision += 1
  }
  func clear() {
    thumbnails.removeAllObjects()
    previews.removeAllObjects()
    revision += 1
  }
  private func cost(_ image: UIImage) -> Int {
    (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
  }
}
private struct DecodedPhoto {
  let image: UIImage
  let nativeRaw: Bool
}
// Serialize demosaicing and bitmap decode so adjacent RAW pages cannot create
// several full-sensor working buffers simultaneously.
private actor PhotoDecodeWorker {
  static let shared = PhotoDecodeWorker()
  private let context = CIContext(options: [.cacheIntermediates: false])
  func exportJPEG(_ sourceURL: URL, to destinationURL: URL) throws {
    try Task.checkCancellation()
    try autoreleasepool {
      let raw = sourceURL.pathExtension.lowercased() == "arw"
      let image: CIImage
      if raw {
        guard let filter = CIRAWFilter(imageURL: sourceURL) else {
          throw CameraFailure(message: "系统不支持完整显影这份 RAW，请选择 RAW 或全部原文件")
        }
        filter.scaleFactor = 1
        filter.isDraftModeEnabled = false
        guard let output = filter.outputImage else {
          throw CameraFailure(message: "RAW 显影失败，原文件已保留")
        }
        image = output
      } else {
        guard
          let decoded = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true])
        else { throw CameraFailure(message: "无法读取待转换影像") }
        image = decoded
      }
      guard image.extent.width > 0, image.extent.height > 0, image.extent.width.isFinite,
        image.extent.height.isFinite
      else { throw CameraFailure(message: "影像尺寸无效") }
      try Task.checkCancellation()
      guard
        let cg = context.createCGImage(
          image, from: image.extent, format: .RGBA8,
          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
      else { throw CameraFailure(message: "无法生成全尺寸 JPEG") }
      var metadata: [String: Any] = [
        kCGImageDestinationLossyCompressionQuality as String: 0.95,
        kCGImagePropertyOrientation as String: 1,
      ]
      if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
      {
        var exif = original[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = cg.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cg.height
        exif[kCGImagePropertyExifColorSpace as String] = 1
        exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
        metadata[kCGImagePropertyExifDictionary as String] = exif
        metadata[kCGImagePropertyGPSDictionary as String] =
          original[kCGImagePropertyGPSDictionary as String]
        if let tiff = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
          let keys = [
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
            kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
          ]
          metadata[kCGImagePropertyTIFFDictionary as String] = tiff.filter { key, _ in
            keys.contains { ($0 as String) == key }
          }
        }
      }
      let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(
        ".jpeg-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: temporary) }
      guard
        let output = CGImageDestinationCreateWithURL(
          temporary as CFURL, "public.jpeg" as CFString, 1, nil)
      else { throw CameraFailure(message: "无法创建 JPEG 文件") }
      CGImageDestinationAddImage(output, cg, metadata as CFDictionary)
      guard CGImageDestinationFinalize(output) else { throw CameraFailure(message: "JPEG 编码失败") }
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destinationURL)
      }
    }
  }
  func decode(_ url: URL, maxDimension: Int, raw: Bool) throws -> DecodedPhoto {
    try Task.checkCancellation()
    return try autoreleasepool {
      if raw, let filter = CIRAWFilter(imageURL: url), filter.nativeSize.width > 0 {
        filter.isDraftModeEnabled = false
        filter.scaleFactor = Float(
          min(1, Double(maxDimension) / max(filter.nativeSize.width, filter.nativeSize.height)))
        if let output = filter.outputImage {
          try Task.checkCancellation()
          let scale = min(1, Double(maxDimension) / max(output.extent.width, output.extent.height))
          let image = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
          let rect = CGRect(
            x: image.extent.minX, y: image.extent.minY, width: floor(image.extent.width),
            height: floor(image.extent.height))
          if let cg = context.createCGImage(
            image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
          {
            return DecodedPhoto(image: UIImage(cgImage: cg), nativeRaw: true)
          }
        }
      }
      guard
        let source = CGImageSourceCreateWithURL(
          url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw CameraFailure(message: "系统无法解码这份预览。可下载原文件后再查看或分享。") }
      return DecodedPhoto(image: UIImage(cgImage: image), nativeRaw: false)
    }
  }
}
enum PhotoDecoder {
  static func exportJPEG(_ source: URL, to destination: URL) async throws {
    try await PhotoDecodeWorker.shared.exportJPEG(source, to: destination)
  }
  static func decode(_ url: URL, maxDimension: Int) async throws -> UIImage {
    try await PhotoDecodeWorker.shared.decode(url, maxDimension: maxDimension, raw: false).image
  }
  static func original(_ url: URL, maxDimension: Int) async throws -> (
    image: UIImage, embeddedRaw: Bool
  ) {
    let raw = url.pathExtension.lowercased() == "arw"
    let result = try await PhotoDecodeWorker.shared.decode(
      url, maxDimension: maxDimension, raw: raw)
    return (result.image, raw && !result.nativeRaw)
  }
}
extension MediaFile {
  var imageFile: Bool {
    ["jpg", "jpeg", "hif", "heif", "heic", "arw", "png", "tif", "tiff"].contains(
      (name as NSString).pathExtension.lowercased())
  }
}
extension CameraMedia {
  var previewFile: MediaFile? {
    files.first {
      ["jpg", "jpeg", "hif", "heif", "heic"].contains(
        ($0.name as NSString).pathExtension.lowercased())
    }
      ?? files.first(where: \.imageFile) ?? files.first
  }
  var cacheKey: String { previewFile?.key ?? "\(id)-\(previewFile?.id ?? 0)-\(created)" }
}
extension CameraModel {
  func thumbnailImage(_ item: CameraMedia) -> UIImage? { images.thumbnail(item.cacheKey) }
  func clearPhotoMemory() { images.clear() }
  func localOriginal(_ item: CameraMedia) -> URL? {
    guard let file = item.previewFile,
      let t = transfers.first(where: {
        $0.complete
          && (file.key != nil
            ? $0.key == file.key
            : ($0.selection.contentID == item.id && $0.selection.file.ID == file.id))
      }),
      FileManager.default.fileExists(atPath: t.path)
    else { return nil }
    return URL(fileURLWithPath: t.path)
  }
  func photo(_ item: CameraMedia, original: Bool = false) async throws -> RenderedPhoto {
    try Task.checkCancellation()
    let key = item.cacheKey + (original ? "-original" : "-screen")
    if let cached = images.preview(key) { return cached }
    #if DEBUG
      if isFixture { return try await fixturePhoto(item, original: original) }
    #endif
    let token = sessionID
    guard let file = item.previewFile else { throw CameraFailure(message: "这组影像没有文件") }
    let url: URL
    var quality: String
    if original, !file.video, let local = localOriginal(item) {
      url = local
      quality = "原图"
    } else {
      guard connected, !importing, !exporting else { throw CameraFailure(message: "连接相机后载入清晰预览") }
      let preview: CameraPreview = try await bridge.call(
        "preview", ["id": item.id, "fileID": file.id, "quality": "screen"], priority: .preview)
      url = URL(fileURLWithPath: preview.path)
      quality = "清晰预览"
    }
    let image: UIImage
    if original && !file.video {
      let result = try await PhotoDecoder.original(url, maxDimension: 4096)
      image = result.image
      if result.embeddedRaw { quality = "原文件内嵌预览" }
    } else {
      image = try await PhotoDecoder.decode(url, maxDimension: 2400)
    }
    try Task.checkCancellation()
    guard token == sessionID else { throw CancellationError() }
    let photo = RenderedPhoto(image: image, quality: quality)
    images.putPreview(photo, key: key)
    return photo
  }
}
