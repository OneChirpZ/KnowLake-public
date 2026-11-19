import AppKit
import UniformTypeIdentifiers

struct LibrarySourceDrag: Codable, Equatable {
  static let type = UTType(exportedAs: "app.knowlake.library-source", conformingTo: .data)

  let root: String
  let sourceID: String

  func pasteboardItem() -> NSPasteboardItem? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    let item = NSPasteboardItem()
    item.setData(data, forType: .init(Self.type.identifier))
    return item
  }
}
