import Foundation
import CoreGraphics

enum PBType {
  static let string = "public.utf8-plain-text"
  static let rtf = "public.rtf"
  static let rtfd = "com.apple.flat-rtfd"
  static let html = "public.html"
  static let png = "public.png"
  static let tiff = "public.tiff"
  static let jpeg = "public.jpeg"
  static let heic = "public.heic"
  static let fileURL = "public.file-url"

  static let imageTypes = [png, tiff, jpeg, heic]
}

struct ClipContent: Equatable {
  let type: String
  let data: Data
}

enum ClipKind: Equatable {
  case text, image, files
}

/// One history entry. Only ever touched on the main thread.
final class ClipItem {
  let id = UUID()
  let contents: [ClipContent]
  let kind: ClipKind
  let application: String?
  /// Single-line display and search text (special symbols applied), at most `Limits.titleLength` characters.
  let title: String
  /// Multi-line text for the preview popover, at most `Limits.previewLength` characters.
  let previewText: String
  let byteCount: Int
  var firstCopiedAt: Date
  var lastCopiedAt: Date
  var numberOfCopies = 1
  var thumbnail: CGImage?

  init(contents: [ClipContent], kind: ClipKind, application: String?, title: String, previewText: String, now: Date) {
    self.contents = contents
    self.kind = kind
    self.application = application
    self.title = title
    self.previewText = previewText
    self.byteCount = contents.reduce(0) { $0 + $1.data.count }
    self.firstCopiedAt = now
    self.lastCopiedAt = now
  }

  var imageContent: ClipContent? {
    PBType.imageTypes.lazy.compactMap { t in self.contents.first { $0.type == t } }.first
  }

  /// Same rule as Maccy: the new copy carries every representation the old one had.
  func supersedes(_ other: ClipItem) -> Bool {
    other.contents.allSatisfy { contents.contains($0) }
  }
}

enum Limits {
  static let maxItems = 25
  static let maxItemBytes = 16 * 1024 * 1024
  static let maxTotalBytes = 96 * 1024 * 1024
  static let titleLength = 1_000
  static let previewLength = 10_000
}
