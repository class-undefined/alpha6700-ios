import CoreGraphics
import Foundation

// All overlays and touch points share this rect. Neither fullscreen nor a
// different stream aspect ratio may crop the scene or focus in a letterbox.
enum ViewfinderGeometry {
  static func fit(image: CGSize, in bounds: CGRect) -> CGRect {
    guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
      return .zero
    }
    let scale = min(bounds.width / image.width, bounds.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
      height: size.height)
  }
  static func cameraPoint(_ point: CGPoint, imageRect: CGRect) -> (x: Int, y: Int)? {
    guard imageRect.width > 0, imageRect.height > 0 else { return nil }
    let x = (point.x - imageRect.minX) / imageRect.width
    let y = (point.y - imageRect.minY) / imageRect.height
    guard (0...1).contains(x), (0...1).contains(y) else { return nil }
    return (min(639, Int(x * 640)), min(479, Int(y * 480)))
  }
}
