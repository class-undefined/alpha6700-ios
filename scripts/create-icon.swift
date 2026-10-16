import AppKit
let size=NSSize(width:1024,height:1024)
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(calibratedRed:0.035,green:0.045,blue:0.052,alpha:1).setFill()
NSBezierPath(rect:NSRect(origin:.zero,size:size)).fill()
let center=NSPoint(x:512,y:512)
let accent=NSColor(calibratedRed:0.91,green:0.66,blue:0.39,alpha:1)
accent.setStroke()
let ring=NSBezierPath(ovalIn:NSRect(x:190,y:190,width:644,height:644));ring.lineWidth=12;ring.stroke()
for i in 0..<6 {
 let a=Double(i)*Double.pi/3
 let b=a+Double.pi/3
 let p=NSBezierPath()
 p.move(to:NSPoint(x:center.x+300*cos(a),y:center.y+300*sin(a)))
 p.line(to:NSPoint(x:center.x+140*cos(a+0.3),y:center.y+140*sin(a+0.3)))
 p.line(to:NSPoint(x:center.x+300*cos(b),y:center.y+300*sin(b)))
 p.lineWidth=24;p.lineCapStyle = .round;p.lineJoinStyle = .round;p.stroke()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
