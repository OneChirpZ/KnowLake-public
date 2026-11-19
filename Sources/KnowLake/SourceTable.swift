import AppKit
import ImageIO
import SwiftUI

final class SourceListScrollPositions {
  var positions: [String: NSPoint] = [:]
}

private final class SourceScrollView: NSScrollView {
  var onLayout: (() -> Void)?

  override func layout() {
    super.layout()
    onLayout?()
  }
}

/// Reusable fixed-height AppKit rows keep a large catalog independent of rich-text layout.
struct SourceTable: NSViewRepresentable {
  let sources: [SourceRecord]
  let selection: String?
  let select: (String) -> Void
  let action: (SourceRecord, String) -> Void
  var jobs: [Job] = []
  var pendingSelection: UUID? = nil
  var selectPending: (Job) -> Void = { _ in }
  var folders: [String] = []
  var move: (SourceRecord, String) -> Void = { _, _ in }
  var dragRoot: String? = nil
  var scrollPositions: SourceListScrollPositions? = nil
  var scrollScope: String = ""
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let table = SourceNSTableView()
    let column = NSTableColumn(identifier: .init("source"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 92
    table.intercellSpacing = NSSize(width: 0, height: 4)
    table.style = .inset
    table.selectionHighlightStyle = .none
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    table.setDraggingSourceOperationMask([], forLocal: false)
    table.rowMenu = { row in context.coordinator.menu(row: row) }
    let scroll = SourceScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = table
    context.coordinator.table = table
    scroll.onLayout = { [weak coordinator = context.coordinator] in
      coordinator?.restoreScrollIfReady()
    }
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) {
    let c = context.coordinator
    c.prepareScroll(scope: scrollScope, positions: scrollPositions)
    c.onSelect = select
    c.onAction = action
    c.onSelectPending = selectPending
    c.folders = folders
    c.onMove = move
    c.dragRoot = dragRoot
    c.updating = true
    c.selection = selection
    c.pendingSelection = pendingSelection
    let sourcesChanged = c.sources != sources
    if sourcesChanged {
      c.sources = sources
      c.sourceIDsByURL = SourceListItem.sourceIDsByURL(sources)
    }
    let rows = SourceListItem.rows(sources: sources, jobs: jobs, sourceIDsByURL: c.sourceIDsByURL)
    let structureChanged = rows.map(\.id) != c.rows.map(\.id)
    if sourcesChanged || structureChanged { c.preserveScrollForReload() }
    c.rows = rows
    if sourcesChanged || structureChanged {
      c.table?.reloadData()
    }
    if let index = c.rows.firstIndex(where: c.isSelected) {
      if c.table?.selectedRow != index {
        c.table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      }
    } else {
      c.table?.deselectAll(nil)
    }
    c.updateCurrentRows()
    c.updating = false
    c.restoreScrollIfReady()
  }
  static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
    coordinator.rememberScroll()
    (view as? SourceScrollView)?.onLayout = nil
  }
  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var sources: [SourceRecord] = []
    var rows: [SourceListItem] = []
    var sourceIDsByURL: [String: String] = [:]
    var selection: String?
    var pendingSelection: UUID?
    weak var table: NSTableView?
    var updating = false
    var onSelect: ((String) -> Void)?
    var onSelectPending: ((Job) -> Void)?
    var onAction: ((SourceRecord, String) -> Void)?
    var folders: [String] = []
    var onMove: ((SourceRecord, String) -> Void)?
    var dragRoot: String?
    private var scrollPositions: SourceListScrollPositions?
    private var scrollScope: String?
    private var pendingScroll: NSPoint?

    func prepareScroll(scope: String, positions: SourceListScrollPositions?) {
      guard scrollScope != scope || scrollPositions !== positions else { return }
      rememberScroll()
      scrollPositions = positions
      scrollScope = scope
      pendingScroll = positions.map { $0.positions[scope] ?? .zero }
    }
    func rememberScroll() {
      guard pendingScroll == nil, !rows.isEmpty, let scrollScope,
        let scroll = table?.enclosingScrollView, scroll.contentSize.height > 0 else { return }
      scrollPositions?.positions[scrollScope] = scroll.contentView.bounds.origin
    }
    func preserveScrollForReload() {
      guard scrollPositions != nil, pendingScroll == nil, !rows.isEmpty,
        let scroll = table?.enclosingScrollView, scroll.contentSize.height > 0 else { return }
      pendingScroll = scroll.contentView.bounds.origin
    }
    func restoreScrollIfReady() {
      guard let target = pendingScroll, !rows.isEmpty, let table,
        let scroll = table.enclosingScrollView, scroll.contentSize.height > 0,
        table.frame.height > 0 else { return }
      pendingScroll = nil
      let clip = scroll.contentView
      let constrained = clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin
      if clip.bounds.origin != constrained {
        clip.scroll(to: constrained)
        scroll.reflectScrolledClipView(clip)
      }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
      guard let dragRoot, rows.indices.contains(row), case .source(let source, _) = rows[row] else { return nil }
      return LibrarySourceDrag(root: dragRoot, sourceID: source.id).pasteboardItem()
    }
    func isSelected(_ item: SourceListItem) -> Bool {
      switch item {
      case .source(let source, _): return pendingSelection == nil && source.id == selection
      case .pending(let job): return job.id == pendingSelection
      }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let id = NSUserInterfaceItemIdentifier("source-row")
      let view =
        (tableView.makeView(withIdentifier: id, owner: nil) as? SourceRowView) ?? SourceRowView()
      view.identifier = id
      view.isCurrentSource = isSelected(rows[row])
      return view
    }
    func updateCurrentRows() {
      table?.enumerateAvailableRowViews { view, row in
        guard self.rows.indices.contains(row) else { return }
        let item = self.rows[row]
        (view as? SourceRowView)?.isCurrentSource = self.isSelected(item)
        if let cell = self.table?.view(atColumn: 0, row: row, makeIfNecessary: false) as? SourceCell {
          switch item {
          case .source(_, let job): cell.updateProgress(job)
          case .pending(let job): cell.updatePending(job)
          }
        }
      }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      let id = NSUserInterfaceItemIdentifier("source")
      let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SourceCell) ?? SourceCell()
      cell.identifier = id
      switch rows[row] {
      case .source(let source, let job):
        cell.bind(source)
        cell.updateProgress(job)
      case .pending(let job): cell.bindPending(job)
      }
      return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let index = table?.selectedRow, rows.indices.contains(index) else {
        return
      }
      let item = rows[index]
      DispatchQueue.main.async {
        switch item {
        case .source(let source, _): self.onSelect?(source.id)
        case .pending(let job): self.onSelectPending?(job)
        }
      }
    }
    func menu(row: Int) -> NSMenu? {
      guard rows.indices.contains(row), case .source(let source, _) = rows[row] else { return nil }
      let menu = NSMenu()
      for (title, key) in [
        (source.starred ? "取消收藏" : "收藏", "star"), (source.read ? "标为未读" : "标为已读", "read"),
        ("整理", "organize"),
        ("打开原文", "open"),
      ] {
        if key == "open", source.webURL == nil { continue }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if key == "organize" {
          item.submenu = folderMenu(for: source)
        } else {
          item.action = #selector(menuAction(_:))
          item.target = self
          item.representedObject = ["id": source.id, "action": key]
        }
        menu.addItem(item)
      }
      return menu
    }
    private func folderMenu(for source: SourceRecord) -> NSMenu {
      let children = Dictionary(
        grouping: LibraryFolder.all(in: folders + [source.collection]),
        by: { LibraryFolder.parent(of: $0) })
      func destination(_ path: String, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(moveSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["id": source.id, "collection": path]
        item.state = path == source.collection ? .on : .off
        item.isEnabled = path != source.collection
        return item
      }
      func branch(_ path: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(destination(path, title: path.isEmpty ? "资料库根目录" : "移到此文件夹"))
        if let subfolders = children[path], !subfolders.isEmpty {
          menu.addItem(.separator())
          for folder in subfolders {
            let item: NSMenuItem
            if children[folder] != nil {
              item = NSMenuItem(title: LibraryFolder.name(of: folder), action: nil, keyEquivalent: "")
              item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
              item.submenu = branch(folder)
              item.state = folder == source.collection ? .on : .off
            } else {
              item = destination(folder, title: LibraryFolder.name(of: folder))
              item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            }
            menu.addItem(item)
          }
        }
        return menu
      }
      return branch("")
    }
    @objc func moveSource(_ item: NSMenuItem) {
      guard let info = item.representedObject as? [String: String],
        let source = sources.first(where: { $0.id == info["id"] }),
        let folder = info["collection"], folder != source.collection else { return }
      onMove?(source, folder)
    }
    @objc func menuAction(_ item: NSMenuItem) {
      guard let info = item.representedObject as? [String: String],
        let source = sources.first(where: { $0.id == info["id"] }), let action = info["action"]
      else { return }
      onAction?(source, action)
    }
  }
}

enum SourceListItem {
  case source(SourceRecord, Job?)
  case pending(Job)

  var id: String {
    switch self {
    case .source(let source, _): return "source:" + source.id
    case .pending(let job): return "pending:" + job.id.uuidString
    }
  }

  static func sourceIDsByURL(_ sources: [SourceRecord]) -> [String: String] {
    Dictionary(sources.map { (urlIdentity($0.url), $0.id) }, uniquingKeysWith: { first, _ in first })
  }

  static func rows(
    sources: [SourceRecord], jobs: [Job], sourceIDsByURL: [String: String]? = nil
  ) -> [SourceListItem] {
    let unfinished = jobs.filter { !$0.isFinished }
    guard !unfinished.isEmpty else { return sources.map { .source($0, nil) } }
    let sourceIDs = Set(sources.map(\.id))
    let byURL = sourceIDsByURL ?? self.sourceIDsByURL(sources)
    var progress: [String: Job] = [:]
    var pending: [SourceListItem] = []
    for job in unfinished {
      let sourceID = job.sourceID.flatMap { sourceIDs.contains($0) ? $0 : nil }
        ?? (job.isGeneration ? nil : byURL[urlIdentity(job.input)])
      if let sourceID {
        if let previous = progress[sourceID], !previous.isWaiting || job.isWaiting { continue }
        progress[sourceID] = job
      } else if !job.isGeneration {
        pending.append(.pending(job))
      }
    }
    return sources.map { .source($0, progress[$0.id]) } + pending
  }

  /// Match the engine's source identity without resolving short-link redirects.
  static func urlIdentity(_ value: String) -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var url = URLComponents(string: value.contains("://") ? value : "https://" + value),
      let host = url.host?.lowercased()
    else { return value }
    let query = Dictionary(
      (url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    let parts = url.path.split(separator: "/").map(String.init)
    if ["bilibili.com", "www.bilibili.com", "m.bilibili.com", "b23.tv"].contains(host) {
      let suffixPage = parts.last.flatMap { $0.hasPrefix("p") ? Int($0.dropFirst()) : nil }
      let page = Int(query["p"] ?? "") ?? suffixPage ?? 1
      if host == "b23.tv" { return "b23:" + url.path + ":\(page)" }
      let video = parts.first { $0.range(of: #"^(BV[0-9A-Za-z]+|av\d+)$"#, options: .regularExpression) != nil }
        ?? query["bvid"]
      if let video { return "bilibili:\(video):\(page)" }
    }
    if host == "mp.weixin.qq.com" {
      if url.path.hasPrefix("/s/") {
        return host + "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      }
      if url.path == "/s", let biz = query["__biz"], let mid = query["mid"] {
        return "wechat:\(biz):\(mid):\(query["idx"] ?? "1")"
      }
    }
    url.host = host
    url.fragment = nil
    url.queryItems = url.queryItems?.sorted {
      $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
    }
    if url.path.hasSuffix("/"), url.path.count > 1 { url.path.removeLast() }
    return url.string ?? value
  }
}

struct SourceCardProgress {
  let text: String
  let icon: String
  let detail: String

  init(_ job: Job) {
    let mode = ["markdown": "图文笔记", "html": "看板", "image": "概览图"][job.generation?.mode ?? job.mode ?? ""] ?? "内容"
    if job.isWaiting {
      text = job.isGeneration ? "等待生成 · " + mode : "等待获取原文"
      icon = "clock"
    } else {
      let phase: String
      if job.state == "停止中" {
        phase = "正在停止"
      } else if job.isGeneration {
        phase = ["prepare": "准备中", "analyze": "分析中", "draft": "生成中",
                 "review": "校对中", "save": "保存中"][job.currentStage ?? ""] ?? "生成中"
      } else {
        phase = ["subtitles": "正在获取字幕", "download": "正在下载音频",
                 "transcribe": "正在转写音频", "save": "正在保存原文"][job.currentStage ?? ""] ?? "正在获取原文"
      }
      text = job.isGeneration ? phase + " · " + mode : phase
      icon = "arrow.triangle.2.circlepath"
    }
    detail = job.message.isEmpty ? text : text + "\n" + job.message
  }
}

@MainActor final class SourceRowView: NSTableRowView {
  var isCurrentSource = false {
    didSet {
      if isCurrentSource != oldValue { needsDisplay = true }
    }
  }
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
  override func drawBackground(in dirtyRect: NSRect) {
    super.drawBackground(in: dirtyRect)
    guard isCurrentSource else { return }
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let accent =
      dark
      ? NSColor(srgbRed: 0.39, green: 0.74, blue: 0.66, alpha: 1)
      : NSColor(srgbRed: 0.21, green: 0.52, blue: 0.46, alpha: 1)
    let card = bounds.insetBy(dx: 1, dy: 2)
    accent.withAlphaComponent(dark ? 0.20 : 0.12).setFill()
    NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
    accent.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: card.minX + 1, y: card.minY + 10, width: 3, height: card.height - 20),
      xRadius: 1.5, yRadius: 1.5
    ).fill()
  }
}
final class SourceNSTableView: NSTableView {
  var rowMenu: ((Int) -> NSMenu?)?
  override func menu(for event: NSEvent) -> NSMenu? {
    rowMenu?(row(at: convert(event.locationInWindow, from: nil)))
  }
}
@MainActor struct SourceCardMetadata {
  let origin: String
  let result: String
  let icon: String
  let needsAttention: Bool

  init(_ source: SourceRecord) {
    let platform =
      source.platform == "bilibili" ? "B 站" : source.platform == "wechat" ? "公众号" : source.platform == "markdown" ? "Markdown" : source.platform
    let date =
      Self.timestamp.date(from: source.created_at)
      ?? Self.plainTimestamp.date(from: source.created_at)
    origin = platform + (date.map { " · " + Self.displayDate.string(from: $0) } ?? "")
    var outputs: [String] = []
    for (label, count) in [
      ("图文笔记", source.note_count ?? 0), ("看板", source.board_count ?? 0),
      ("概览图", source.image_count ?? 0),
    ] {
      if count > 0 { outputs.append(count == 1 ? label : "\(label) \(count)") }
    }
    let content =
      outputs.isEmpty
      ? (source.artifact_count == nil ? "已归档" : "仅原文") : outputs.joined(separator: " · ")
    switch source.status {
    case "partial":
      result = "图片未齐 · " + content
      icon = "exclamationmark.circle"
      needsAttention = true
    case "failed":
      result = "采集失败 · " + content
      icon = "exclamationmark.circle"
      needsAttention = true
    default:
      result = content
      icon = outputs.isEmpty ? "doc.text" : "checkmark.circle"
      needsAttention = false
    }
  }
  private static let timestamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let plainTimestamp = ISO8601DateFormatter()
  private static let displayDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter
  }()
}

@MainActor final class SourceCoverView: NSView {
  var image: NSImage? {
    didSet { needsDisplay = true }
  }
  var isPlaceholder = true {
    didSet { needsDisplay = true }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).addClip()
    NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
    bounds.fill()
    guard var image, image.size.width > 0, image.size.height > 0 else { return }
    let size: NSSize
    if isPlaceholder {
      image = image.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? image
      let scale = min(26 / image.size.width, 26 / image.size.height)
      size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    } else {
      let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
      size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    }
    image.draw(
      in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                 width: size.width, height: size.height),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
  }
}

@MainActor final class SourceCell: NSTableCellView {
  let cover = SourceCoverView(), heading = NSTextField(wrappingLabelWithString: ""),
    origin = NSTextField(labelWithString: ""), result = NSTextField(labelWithString: ""),
    resultIcon = NSImageView(), star = NSImageView()
  let readStamp = SourceReadStampView()
  private let stampWidth: CGFloat = 34
  private var resultTrailing: NSLayoutConstraint!
  private var needsAttention = false
  private var processing = false
  private var metadata: SourceCardMetadata?
  private var statusIcon = ""
  var load: Task<Void, Never>?
  static let thumbnails: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 160
    return cache
  }()
  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { updateColors() }
  }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    for field in [heading, origin, result] {
      field.isEditable = false
      field.isSelectable = false
    }
    heading.maximumNumberOfLines = 2
    heading.lineBreakMode = .byWordWrapping
    heading.cell?.truncatesLastVisibleLine = true
    heading.setContentHuggingPriority(.required, for: .vertical)
    for field in [origin, result] {
      field.maximumNumberOfLines = 1
      field.lineBreakMode = .byTruncatingTail
      field.font = .systemFont(ofSize: 11)
    }
    origin.toolTip = "来源平台与收录时间"
    let textContent = NSView()
    for view in [cover, textContent] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    for view in [heading, origin, result, resultIcon, star, readStamp] {
      view.translatesAutoresizingMaskIntoConstraints = false
      textContent.addSubview(view)
    }
    readStamp.isHidden = true
    resultTrailing = result.trailingAnchor.constraint(equalTo: textContent.trailingAnchor)
    star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "收藏")
    star.contentTintColor = .systemOrange
    NSLayoutConstraint.activate([
      cover.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      cover.centerYAnchor.constraint(equalTo: centerYAnchor),
      cover.widthAnchor.constraint(equalToConstant: 72),
      cover.heightAnchor.constraint(equalToConstant: 72),
      textContent.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 10),
      textContent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      textContent.centerYAnchor.constraint(equalTo: centerYAnchor),
      heading.leadingAnchor.constraint(equalTo: textContent.leadingAnchor),
      heading.topAnchor.constraint(equalTo: textContent.topAnchor),
      heading.trailingAnchor.constraint(equalTo: textContent.trailingAnchor),
      heading.heightAnchor.constraint(lessThanOrEqualToConstant: 34),
      origin.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      origin.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
      origin.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -5),
      origin.heightAnchor.constraint(equalToConstant: 14),
      resultIcon.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      resultIcon.topAnchor.constraint(equalTo: origin.bottomAnchor, constant: 2),
      resultIcon.widthAnchor.constraint(equalToConstant: 12),
      resultIcon.heightAnchor.constraint(equalToConstant: 12),
      result.leadingAnchor.constraint(equalTo: resultIcon.trailingAnchor, constant: 5),
      result.centerYAnchor.constraint(equalTo: resultIcon.centerYAnchor),
      resultTrailing,
      result.heightAnchor.constraint(equalToConstant: 14),
      result.bottomAnchor.constraint(equalTo: textContent.bottomAnchor),
      star.widthAnchor.constraint(equalToConstant: 12),
      star.heightAnchor.constraint(equalToConstant: 12),
      star.trailingAnchor.constraint(equalTo: textContent.trailingAnchor),
      star.centerYAnchor.constraint(equalTo: origin.centerYAnchor),
      readStamp.trailingAnchor.constraint(equalTo: textContent.trailingAnchor),
      readStamp.centerYAnchor.constraint(equalTo: result.centerYAnchor),
      readStamp.widthAnchor.constraint(equalToConstant: stampWidth),
      readStamp.heightAnchor.constraint(equalToConstant: 22),
    ])
    updateColors()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  private func updateColors() {
    let highlighted = backgroundStyle == .emphasized
    heading.textColor = highlighted ? .alternateSelectedControlTextColor : .labelColor
    origin.textColor = highlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
    result.textColor = highlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
    resultIcon.contentTintColor =
      highlighted
      ? .alternateSelectedControlTextColor
      : needsAttention ? .systemOrange : processing ? .controlAccentColor : .secondaryLabelColor
  }
  func bind(_ source: SourceRecord) {
    load?.cancel()
    heading.stringValue = source.title
    heading.toolTip = source.title
    heading.font = .systemFont(ofSize: 13, weight: source.read ? .regular : .semibold)
    let metadata = SourceCardMetadata(source)
    self.metadata = metadata
    origin.stringValue = metadata.origin
    origin.toolTip = metadata.origin
    updateProgress(nil)
    star.isHidden = !source.starred
    setRead(source.read)
    cover.isPlaceholder = true
    cover.image = NSImage(
      systemSymbolName: source.platform == "bilibili" ? "play.rectangle" : "doc.text",
      accessibilityDescription: nil)
    guard let path = source.image_path else { return }
    if let cached = Self.thumbnails.object(forKey: path as NSString) {
      cover.isPlaceholder = false
      cover.image = cached
      return
    }
    load = Task { [weak self] in
      let image = await Task.detached(priority: .utility) { () -> CGImage? in
        guard let input = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
          input, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 288,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      }.value
      if !Task.isCancelled, let image {
        let thumbnail = NSImage(cgImage: image, size: .zero)
        Self.thumbnails.setObject(thumbnail, forKey: path as NSString)
        self?.cover.isPlaceholder = false
        self?.cover.image = thumbnail
      }
    }
  }

  func bindPending(_ job: Job) {
    load?.cancel()
    load = nil
    metadata = nil
    star.isHidden = true
    setRead(false)
    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    heading.toolTip = job.input
    cover.isPlaceholder = true
    cover.image = NSImage(systemSymbolName: job.isBilibili ? "play.rectangle" : "doc.text", accessibilityDescription: nil)
    updatePending(job)
  }

  private func setRead(_ read: Bool) {
    readStamp.isHidden = !read
    resultTrailing.constant = read ? -(stampWidth + 5) : 0
  }

  func updatePending(_ job: Job) {
    let platform = job.isBilibili ? "B 站视频" : "公众号文章"
    if heading.stringValue != platform { heading.stringValue = platform }
    origin.stringValue = job.input.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
    origin.toolTip = job.input
    updateProgress(job)
  }

  func updateProgress(_ job: Job?) {
    if let job, !job.isFinished {
      let progress = SourceCardProgress(job)
      processing = true
      needsAttention = false
      setStatus(progress.text, icon: progress.icon, detail: progress.detail)
    } else if let metadata {
      processing = false
      needsAttention = metadata.needsAttention
      setStatus(metadata.result, icon: metadata.icon, detail: metadata.result)
    }
  }

  private func setStatus(_ text: String, icon: String, detail: String) {
    if result.stringValue != text { result.stringValue = text }
    result.toolTip = detail
    if statusIcon != icon {
      resultIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
      statusIcon = icon
    }
    updateColors()
  }
}

@MainActor final class SourceReadStampView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("已读")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let transform = NSAffineTransform()
    transform.translateX(by: bounds.midX, yBy: bounds.midY)
    transform.rotate(byDegrees: 8)
    transform.concat()

    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let ink = dark ? NSColor(srgbRed: 0.52, green: 0.78, blue: 0.70, alpha: 1)
      : NSColor(srgbRed: 0.16, green: 0.43, blue: 0.37, alpha: 1)
    let mark = NSBezierPath(roundedRect: NSRect(x: -15, y: -7, width: 30, height: 14), xRadius: 2, yRadius: 2)
    mark.lineWidth = 1
    ink.withAlphaComponent(0.72).setStroke()
    mark.stroke()

    let text = NSAttributedString(string: "已读", attributes: [
      .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: ink, .kern: 0.7,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
  }
}
