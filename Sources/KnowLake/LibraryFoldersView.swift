import SwiftUI

struct LibraryFoldersView: View {
  @ObservedObject var model: AppModel
  @State private var showNewFolder = false
  @State private var folderToDelete: String?
  @State private var expandedFolders: Set<String> = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var mode: FolderBrowsingMode { model.preferences.folderBrowsingMode }
  private var parent: String { LibraryFolder.parent(of: model.collection) }
  private var backLabel: String {
    parent.isEmpty ? "返回资料库" : "返回 \(LibraryFolder.displayPath(parent))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if mode == .tree {
        let rows = LibraryFolder.tree(in: model.collections, expanded: expandedFolders)
        if !rows.isEmpty {
          folderList(count: rows.count) {
            ForEach(rows) { row in
              folderRow(row.path, depth: row.depth, hasChildren: row.hasChildren)
            }
          }
        }
      } else {
        let children = LibraryFolder.children(of: model.collection, in: model.collections)
        if !children.isEmpty {
          folderList(count: children.count) {
            ForEach(children, id: \.self) { folderRow($0) }
          }
          .id(model.collection)
          .transition(reduceMotion ? .identity : .asymmetric(
            insertion: .move(edge: model.folderNavigationDirection > 0 ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity))
        }
      }
    }
    .animation(mode == .levels && !reduceMotion ? .easeOut(duration: 0.18) : nil, value: model.collection)
    .clipped()
    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    .modifier(DeleteLibraryFolderDialog(model: model, folder: $folderToDelete))
    .onChange(of: model.collection, initial: true) { revealCurrentFolder() }
    .onChange(of: mode) { revealCurrentFolder() }
    .onChange(of: model.preferences.root) {
      expandedFolders.removeAll()
      revealCurrentFolder()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if model.collection.isEmpty {
        Text("资料库").font(.headline)
        Spacer(minLength: 0)
      } else {
        Button {
          model.openFolder(parent)
        } label: {
          Image(systemName: "chevron.left").modifier(DarkReadableAction())
            .frame(width: 24, height: 24)
        }.buttonStyle(.plain).help(backLabel).accessibilityLabel(backLabel)
          .keyboardShortcut("[", modifiers: .command)
        Image(systemName: "folder").foregroundStyle(.secondary)
        breadcrumb
      }
      Button {
        showNewFolder = true
      } label: {
        Label("新建", systemImage: "folder.badge.plus").modifier(DarkReadableAction())
      }.buttonStyle(.borderless).font(.caption).help("新建文件夹")
        .accessibilityLabel("新建文件夹")
        .popover(isPresented: $showNewFolder) {
          NewFolderPanel(model: model, parent: model.collection) { model.openFolder($0) }
        }
    }
  }

  private var breadcrumb: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          breadcrumbLink("资料库", path: "")
          ForEach(LibraryFolder.ancestors(of: model.collection), id: \.self) { path in
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
              .accessibilityHidden(true)
            if path == model.collection {
              Text(LibraryFolder.name(of: path)).font(.headline)
                .help(LibraryFolder.displayPath(path))
                .contextMenu { deleteAction(path) }
                .id(path)
            } else {
              breadcrumbLink(LibraryFolder.name(of: path), path: path)
            }
          }
        }.fixedSize(horizontal: true, vertical: false).frame(height: 24)
      }.scrollIndicators(.hidden)
        .onChange(of: model.collection, initial: true) {
          proxy.scrollTo(model.collection, anchor: .trailing)
        }
    }.frame(height: 24)
  }

  private func breadcrumbLink(_ title: String, path: String) -> some View {
    Button {
      model.openFolder(path)
    } label: {
      Text(title).font(.callout.weight(.medium)).foregroundStyle(.tint)
        .padding(.vertical, 3).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .help(path.isEmpty ? "返回资料库" : LibraryFolder.displayPath(path))
  }

  private func folderList<Rows: View>(count: Int, @ViewBuilder rows: () -> Rows) -> some View {
    ScrollView {
      LazyVStack(spacing: 4, content: rows)
    }.frame(height: min(CGFloat(count) * 36 - 4, 176))
  }

  private func folderRow(_ path: String, depth: Int? = nil, hasChildren: Bool = false) -> some View {
    LibraryFolderRow(
      path: path, depth: depth, hasChildren: hasChildren,
      expanded: expandedFolders.contains(path), selected: path == model.collection,
      open: { if model.collection != path { model.openFolder(path) } },
      toggle: {
        if expandedFolders.remove(path) == nil { expandedFolders.insert(path) }
      }, move: { move($0, into: path) }
    ).contextMenu { deleteAction(path) }
  }

  private func deleteAction(_ path: String) -> some View {
    Button(role: .destructive) { folderToDelete = path } label: {
      Label("删除文件夹…", systemImage: "trash")
    }.disabled(model.maintenance)
  }

  private func revealCurrentFolder() {
    guard mode == .tree else { return }
    expandedFolders.formUnion(LibraryFolder.ancestors(of: model.collection))
  }

  private func move(_ drag: LibrarySourceDrag, into folder: String) {
    guard !model.maintenance, drag.root == model.preferences.root, model.collections.contains(folder),
      let source = model.sources.first(where: { $0.id == drag.sourceID }), source.collection != folder
    else { return }
    Task { await model.update(id: source.id, values: ["collection": folder]) }
  }
}

private struct LibraryFolderRow: View {
  let path: String
  let depth: Int?
  let hasChildren: Bool
  let expanded: Bool
  let selected: Bool
  let open: () -> Void
  let toggle: () -> Void
  let move: @MainActor (LibrarySourceDrag) -> Void
  @State private var isTargeted = false

  var body: some View {
    HStack(spacing: 0) {
      if let depth {
        Color.clear.frame(width: CGFloat(min(depth, 8)) * 13)
        if hasChildren {
          Button(action: toggle) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
              .frame(width: 24, height: 32).contentShape(Rectangle())
          }.buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "折叠" : "展开") \(LibraryFolder.name(of: path))")
        } else {
          Color.clear.frame(width: 24)
        }
      }
      Button(action: open) {
        HStack(spacing: 9) {
          Image(systemName: selected ? "folder.fill" : "folder").foregroundStyle(.tint)
          Text(LibraryFolder.name(of: path)).font(.callout).lineLimit(1)
          Spacer(minLength: 0)
          if depth == nil {
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
          }
        }.padding(.horizontal, depth == nil ? 9 : 2)
          .frame(height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("打开文件夹 \(LibraryFolder.displayPath(path))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(LibraryFolder.displayPath(path))
    }.frame(height: 32)
      .background {
        RoundedRectangle(cornerRadius: 7)
          .fill(isTargeted || selected ? Color.accentColor.opacity(isTargeted ? 0.25 : 0.15) : Color.primary.opacity(0.035))
      }
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .onDrop(of: [LibrarySourceDrag.type], delegate: LibraryFolderDrop(isTargeted: $isTargeted, move: move))
  }
}

private struct LibraryFolderDrop: DropDelegate {
  @Binding var isTargeted: Bool
  let move: @MainActor (LibrarySourceDrag) -> Void

  func dropEntered(info: DropInfo) { isTargeted = true }
  func dropExited(info: DropInfo) { isTargeted = false }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    guard let provider = info.itemProviders(for: [LibrarySourceDrag.type]).first else { return false }
    _ = provider.loadDataRepresentation(forTypeIdentifier: LibrarySourceDrag.type.identifier) { data, _ in
      guard let data, let drag = try? JSONDecoder().decode(LibrarySourceDrag.self, from: data) else { return }
      Task { @MainActor in move(drag) }
    }
    return true
  }
}
