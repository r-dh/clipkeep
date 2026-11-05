// Renders Resources/AppIcon.icns: a white vector paperclip on a blue rounded square.
// Usage: xcrun swiftc Tools/make-icon.swift -o build/make-icon && build/make-icon Resources/AppIcon.icns
import AppKit

func paperclip(scale: CGFloat) -> NSBezierPath {
  // Unrotated clip, centred on the origin: inner loop, top bend, outer loop (same shape as Maccy's paperclip glyph).
  let p = NSBezierPath()
  p.move(to: NSPoint(x: -25, y: 150))
  p.line(to: NSPoint(x: -25, y: -200))
  p.appendArc(withCenter: NSPoint(x: 25, y: -200), radius: 50, startAngle: 180, endAngle: 360)
  p.line(to: NSPoint(x: 75, y: 300))
  p.appendArc(withCenter: NSPoint(x: -25, y: 300), radius: 100, startAngle: 0, endAngle: 180)
  p.line(to: NSPoint(x: -125, y: -300))
  p.appendArc(withCenter: NSPoint(x: 25, y: -300), radius: 150, startAngle: 180, endAngle: 360)
  p.line(to: NSPoint(x: 175, y: 200))
  var t = AffineTransform()
  t.translate(x: 512, y: 512)
  t.rotate(byDegrees: -45)
  t.scale(scale)
  t.translate(x: -25, y: 25) // the clip spans x -175...175, y -450...400
  p.transform(using: t)
  return p
}

func render(pixels: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: 1024, height: 1024)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  // macOS icon grid: 824pt body inset 100pt, with a soft drop shadow.
  let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
  shadow.shadowOffset = NSSize(width: 0, height: -12)
  shadow.shadowBlurRadius = 24
  shadow.set()
  NSColor(srgbRed: 0.18, green: 0.34, blue: 0.85, alpha: 1).setFill()
  body.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.58, blue: 1.0, alpha: 1),
             ending: NSColor(srgbRed: 0.15, green: 0.28, blue: 0.80, alpha: 1))!.draw(in: body, angle: -90)

  let clip = paperclip(scale: 0.8)
  clip.lineWidth = 50
  clip.lineCapStyle = .round
  clip.lineJoinStyle = .round
  NSGraphicsContext.saveGraphicsState()
  let clipShadow = NSShadow()
  clipShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
  clipShadow.shadowOffset = NSSize(width: 0, height: -8)
  clipShadow.shadowBlurRadius = 16
  clipShadow.set()
  NSColor.white.setStroke()
  clip.stroke()
  NSGraphicsContext.restoreGraphicsState()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
  try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
