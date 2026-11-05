import Foundation

/// Newest-first, in-memory only. Main thread only.
final class History {
  private(set) var items: [ClipItem] = []
  let maxItems: Int
  let maxTotalBytes: Int

  init(maxItems: Int = Limits.maxItems, maxTotalBytes: Int = Limits.maxTotalBytes) {
    self.maxItems = maxItems
    self.maxTotalBytes = maxTotalBytes
  }

  var totalBytes: Int { items.reduce(0) { $0 + $1.byteCount } }

  /// A repeat copy moves to the top instead of adding a duplicate. If an existing entry has every representation
  /// of the new copy plus more (formatted text re-copied as plain text), that richer entry is kept, as Maccy does.
  /// Otherwise the new copy replaces every entry it fully contains.
  func add(_ item: ClipItem) {
    if let richer = items.firstIndex(where: { $0.supersedes(item) && !item.supersedes($0) }) {
      let old = items.remove(at: richer)
      old.lastCopiedAt = item.lastCopiedAt
      old.numberOfCopies += 1
      items.insert(old, at: 0)
      return
    }
    let replaced = items.filter { item.supersedes($0) }
    if !replaced.isEmpty {
      item.firstCopiedAt = replaced.map(\.firstCopiedAt).min() ?? item.firstCopiedAt
      item.numberOfCopies = replaced.map(\.numberOfCopies).max()! + 1
      if item.thumbnail == nil {
        item.thumbnail = replaced.first { $0.thumbnail != nil && $0.imageContent == item.imageContent }?.thumbnail
      }
      items.removeAll { item.supersedes($0) }
    }
    items.insert(item, at: 0)
    var bytes = totalBytes
    while items.count > maxItems || (bytes > maxTotalBytes && items.count > 1) {
      bytes -= items.removeLast().byteCount
    }
  }

  /// Called after an entry is copied back to the pasteboard from the popup.
  func promote(_ id: UUID, now: Date) {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    let item = items.remove(at: i)
    item.lastCopiedAt = now
    item.numberOfCopies += 1
    items.insert(item, at: 0)
  }

  func remove(_ id: UUID) {
    items.removeAll { $0.id == id }
  }

  func clear() {
    items.removeAll()
  }

  /// Maccy's "Exact" search: case-insensitive substring over the title, returning every match range for highlighting.
  func search(_ query: String) -> [(item: ClipItem, ranges: [Range<String.Index>])] {
    guard !query.isEmpty else { return items.map { ($0, []) } }
    return items.compactMap { item in
      let ranges = Self.matchRanges(of: query, in: item.title)
      return ranges.isEmpty ? nil : (item, ranges)
    }
  }

  /// NSString search: Swift's case-insensitive `range(of:)` matches "ß" against "St" via case folding.
  static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
    let ns = text as NSString
    var ranges: [Range<String.Index>] = []
    var location = 0
    while location < ns.length {
      let found = ns.range(of: query, options: .caseInsensitive, range: NSRange(location: location, length: ns.length - location))
      guard found.location != NSNotFound, found.length > 0, let r = Range(found, in: text) else { break }
      ranges.append(r)
      location = found.location + found.length
    }
    return ranges
  }
}
