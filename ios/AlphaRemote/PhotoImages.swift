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
enum PhotoDecoder {
  static func decode(_ url: URL, maxDimension: Int) async throws -> UIImage {
    try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
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
      else {
        throw CameraFailure(message: "系统无法解码这份预览。可下载原文件后再查看或分享。")
      }
      return UIImage(cgImage: image)
    }.value
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
          && ($0.key == file.key
            || ($0.selection.contentID == item.id && $0.selection.file.ID == file.id))
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
    let quality: String
    if original, !file.video, let local = localOriginal(item) {
      url = local
      quality = "原图"
    } else {
      guard connected, !importing else { throw CameraFailure(message: "连接相机后载入清晰预览") }
      let preview: CameraPreview = try await bridge.call(
        "preview", ["id": item.id, "fileID": file.id, "quality": "screen"], priority: .preview)
      url = URL(fileURLWithPath: preview.path)
      quality = "清晰预览"
    }
    let image = try await PhotoDecoder.decode(url, maxDimension: original ? 4096 : 2400)
    try Task.checkCancellation()
    guard token == sessionID else { throw CancellationError() }
    let photo = RenderedPhoto(image: image, quality: quality)
    images.putPreview(photo, key: key)
    return photo
  }
}
