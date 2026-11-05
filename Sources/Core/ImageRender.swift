import Foundation
import ImageIO
import CoreGraphics

enum ImageRender {
  /// Decodes a downscaled image straight from the encoded bytes, so the full bitmap is never held in memory.
  /// Refuses data whose real format differs from the declared pasteboard type, so only the PNG/TIFF/JPEG/HEIC
  /// decoders are reachable (a hint alone does not restrict ImageIO).
  static func downscaled(_ content: ClipContent, maxPixelWidth: CGFloat, maxPixelHeight: CGFloat) -> CGImage? {
    guard PBType.imageTypes.contains(content.type) else { return nil }
    let hint = [kCGImageSourceTypeIdentifierHint: content.type, kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(content.data as CFData, hint),
          CGImageSourceGetType(source) as String? == content.type,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, hint) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
          w > 0, h > 0, w * h <= 100_000_000 else { return nil } // decompression bombs
    let scale = min(1, maxPixelWidth / w, maxPixelHeight / h)
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, Int((max(w, h) * scale).rounded())),
    ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
  }
}
