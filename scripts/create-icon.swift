import CoreGraphics
import Foundation
import ImageIO

let edge = 1024
let bitmap = CGContext(
  data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
bitmap.setFillColor(CGColor(red: 0.035, green: 0.045, blue: 0.052, alpha: 1))
bitmap.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
bitmap.setStrokeColor(CGColor(red: 0.91, green: 0.66, blue: 0.39, alpha: 1))
bitmap.setLineWidth(12)
bitmap.strokeEllipse(in: CGRect(x: 190, y: 190, width: 644, height: 644))
bitmap.setLineWidth(24)
bitmap.setLineCap(.round)
bitmap.setLineJoin(.round)
for i in 0..<6 {
  let a = Double(i) * .pi / 3
  let b = a + .pi / 3
  let x = 512 + 140 * cos(a)
  let y = 512 + 140 * sin(a)
  let nextX = 512 + 140 * cos(b)
  let nextY = 512 + 140 * sin(b)
  let length = (1 + sqrt(4 * pow(300.0 / 140, 2) - 3)) / 2
  bitmap.beginPath()
  bitmap.move(to: CGPoint(x: x, y: y))
  bitmap.addLine(to: CGPoint(x: x + length * (nextX - x), y: y + length * (nextY - y)))
  bitmap.strokePath()
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the app icon") }
