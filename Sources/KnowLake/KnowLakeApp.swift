import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main struct KnowLakeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = AppModel()
  var body: some Scene {
    WindowGroup {
      WorkspaceView(model: model)
        .frame(minWidth: 1000, minHeight: 650)
        .task {
          delegate.model = model
          model.start()
        }
    }
    .defaultSize(width: 1320, height: 860)
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      CommandGroup(after: .newItem) {
        Button("添加内容") {
          NotificationCenter.default.post(name: .init("KnowLakeImport"), object: nil)
        }.keyboardShortcut("n")
      }
    }
    Settings {
      SettingsView(model: model, preferences: model.preferences).frame(width: 640, height: 510)
    }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await model?.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
enum WorkspacePopover: String, Identifiable {
  case addContent, generate, organize
  var id: String { rawValue }
}

struct WorkspaceView: View {
  @ObservedObject var model: AppModel
  @StateObject private var reader = ReaderController()
  @State private var activePopover: WorkspacePopover?
  @State private var find = ""
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @Environment(\.colorScheme) private var colorScheme
  var sidebarSelection: Binding<String> {
    Binding(
      get: { model.showTasks ? "tasks" : model.filter },
      set: { filter in
        if filter == "tasks" {
          model.showTasks = true
        } else if filter == "all" {
          model.openFolder("")
        } else {
          model.showTasks = false
          model.filter = filter
          model.collection = ""
          model.tag = ""
          model.reload()
        }
      })
  }
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      VStack(spacing: 0) {
        SidebarNavigationBar(queue: model.queue, selection: sidebarSelection)
          .padding(.horizontal, 12).padding(.top, 6)
        if model.showTasks {
          QueuePanel(model: model, queue: model.queue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          if model.filter == "all" {
            LibraryFoldersView(model: model)
          }
          HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索资料", text: $model.query).textFieldStyle(.plain)
            if model.loading { ProgressView().controlSize(.small) }
            Menu {
              Button("全部平台") {
                model.platform = ""
                model.reload()
              }
              ForEach(AppModules.sources, id: \.id) { source in
                Button(source.title) {
                  model.platform = source.id
                  model.reload()
                }
              }
              if !model.tags.isEmpty {
                Menu("标签") {
                  Button("全部标签") {
                    model.tag = ""
                    model.reload()
                  }
                  ForEach(model.tags, id: \.self) { value in
                    Button {
                      model.tag = model.tag == value ? "" : value
                      model.reload()
                    } label: {
                      Label(value, systemImage: model.tag == value ? "checkmark" : "tag")
                    }
                  }
                }
              }
              if !model.tag.isEmpty || !model.platform.isEmpty {
                Divider()
                Button("清除筛选") {
                  model.tag = ""
                  model.platform = ""
                  model.reload()
                }
              }
            } label: {
              Image(systemName: "line.3.horizontal.decrease").modifier(DarkReadableAction())
                .frame(width: 28, height: 28).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
              .help("筛选").accessibilityLabel("筛选")
              .tint(
                colorScheme == .dark ? Color.primary : Color(red: 0.25, green: 0.57, blue: 0.51))
          }.padding(.horizontal, 12).padding(.vertical, 6)
          Divider()
          LibrarySourceList(model: model, queue: model.queue)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle("KnowLake")
      .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 450)
      .onChange(of: model.query) { model.reload(debounce: true) }
    } detail: {
      Group {
        if let detail = model.detail {
          FloatingReaderArea(model: model, detail: detail) {
            if let mode = model.selectedGenerationMode {
              PendingContentView(model: model, queue: model.queue, sourceID: detail.source.id, mode: mode)
            } else {
              ReaderView(
                detail: detail, artifact: model.selectedArtifact,
                root: model.preferences.root, theme: colorScheme == .dark ? "dark" : "light",
                controller: reader
              ) { sourceID, anchor in
                if model.selectedID == sourceID && model.selectedArtifact == nil {
                  reader.anchor(anchor)
                } else {
                  reader.pendingAnchor = anchor
                  reader.pendingSourceID = sourceID
                  if model.selectedID == sourceID {
                    model.selectedArtifact = nil
                    model.selectedGenerationMode = nil
                  } else {
                    model.select(sourceID, preferOriginal: true)
                  }
                }
              }
            }
          }
        } else if let jobID = model.selectedAcquisitionID {
          PendingContentView(model: model, queue: model.queue, acquisitionID: jobID)
        } else if model.detailLoading {
          ProgressView()
        } else {
          ContentUnavailableView {
            Label("留住所见，慢慢成知", systemImage: "water.waves")
          } description: {
            Text("添加一段视频或一篇文章，开始整理。")
          } actions: {
            Button("添加链接") { activePopover = .addContent }.buttonStyle(.borderedProminent)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .topTrailing) {
        if !reader.returnPoints.isEmpty {
          Button {
            guard let point = reader.popReturn(), point.location.root == model.preferences.root else { return }
            if model.selectedID == point.location.sourceID, model.detail != nil {
              model.selectedArtifact = model.detail?.artifacts.first { $0.id == point.location.artifactID }
              model.selectedGenerationMode = nil
              if reader.location == point.location { reader.applyPendingReturn() }
            } else {
              model.select(point.location.sourceID, preferOriginal: true, artifactID: point.location.artifactID)
            }
          } label: {
            Label("返回引用处", systemImage: "arrow.uturn.backward")
              .padding(.horizontal, 12).padding(.vertical, 8)
              .background(.regularMaterial, in: Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("return-to-citation")
          .help("返回跳转前的阅读位置")
          .padding(12)
        }
      }
    }
    .toolbar(removing: .sidebarToggle)
    .toolbar {
      ToolbarItem(id: WorkspaceToolbarPolicy.sidebarID, placement: .navigation) {
        Button {
          withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
          }
        } label: {
          Image(systemName: "sidebar.left")
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
            .frame(width: 28, height: 28)
        }.buttonStyle(.plain).help("显示或隐藏侧栏").accessibilityLabel("显示或隐藏侧栏")
      }
      ToolbarItem(placement: .principal) {
        HStack(spacing: 16) {
          Button {
            activePopover = .addContent
          } label: {
            Label("添加内容", systemImage: "plus.circle").modifier(DarkReadableAction())
          }.help("添加内容 ⌘N").accessibilityLabel("添加内容")
          Button {
            activePopover = .generate
          } label: {
            Label("生成笔记", systemImage: "sparkles").modifier(DarkReadableAction())
          }.help("选择要补充或重新生成的内容")
            .accessibilityLabel("生成笔记").disabled(model.detail == nil)
          Divider().frame(height: 20)
          Button {
            if let url = model.detail?.source.webURL {
              NSWorkspace.shared.open(url)
            }
          } label: {
            Label("打开原文", systemImage: "arrow.up.right.square").modifier(DarkReadableAction())
          }.accessibilityLabel("打开原文").disabled(model.detail?.source.webURL == nil)
          Button {
            if let source = model.detail?.source {
              Task { await model.update(id: source.id, values: ["read": !source.read]) }
            }
          } label: {
            Label(
              model.detail?.source.read == true ? "标为未读" : "标为已读",
              systemImage: model.detail?.source.read == true ? "circle" : "checkmark.circle"
            ).modifier(DarkReadableAction())
          }.accessibilityLabel(model.detail?.source.read == true ? "标为未读" : "标为已读")
            .accessibilityIdentifier("toggle-read-status").disabled(model.detail == nil)
          Button {
            activePopover = .organize
          } label: {
            Label("整理", systemImage: "folder.badge.plus").modifier(DarkReadableAction())
          }.accessibilityLabel("整理").disabled(model.detail == nil)
          Menu {
            ForEach(["html", "md", "png"], id: \.self) { format in
              Button(format == "png" ? "PNG 预览" : format.uppercased()) {
                if let detail = model.detail {
                  Task {
                    await reader.export(
                      format, detail: detail, artifact: model.selectedArtifact,
                      root: model.preferences.root)
                  }
                }
              }
            }
          } label: {
            Label("导出", systemImage: "square.and.arrow.up").modifier(DarkReadableAction())
          }.disabled(model.detail == nil)
            .tint(colorScheme == .dark ? Color.primary : Color(red: 0.25, green: 0.57, blue: 0.51))
        }.labelStyle(.titleAndIcon).buttonStyle(.borderless).accessibilityElement(
          children: .contain)
          .popover(item: $activePopover, arrowEdge: .bottom) { destination in
            switch destination {
            case .addContent:
              ImportPanel(model: model).buttonStyle(.bordered)
            case .generate:
              GeneratePanel(model: model, sourceDetail: model.detail)
                .buttonStyle(.bordered).padding(22).frame(width: 460)
            case .organize:
              if let detail = model.detail {
                OrganizePanel(model: model, source: detail.source).padding(20).frame(width: 300)
              }
            }
          }
      }
      ToolbarItem(id: WorkspaceToolbarPolicy.settingsID, placement: .primaryAction) {
        SettingsLink {
          Image(systemName: "gearshape").modifier(DarkReadableAction())
        }.help("设置").accessibilityLabel("设置")
      }
    }
    .background(WorkspaceToolbarPolicy().frame(width: 0, height: 0))
    .tint(Color(red: 0.25, green: 0.57, blue: 0.51))

    .onReceive(NotificationCenter.default.publisher(for: .init("KnowLakeImport"))) { _ in
      activePopover = .addContent
    }
    .alert(
      "KnowLake",
      isPresented: Binding(
        get: { model.error != nil || reader.error != nil },
        set: {
          if !$0 {
            model.error = nil
            reader.error = nil
          }
        })
    ) {
      Button("好") {
        model.error = nil
        reader.error = nil
      }
    } message: {
      Text(model.error ?? reader.error ?? "")
    }
    .overlay(alignment: .bottom) {
      if let notice = model.notice {
        HStack {
          Text(notice).lineLimit(2)
          Button {
            model.notice = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain)
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(
          18)
      }
    }
  }

}
struct ImportPanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var queue: QueueState
  @ObservedObject private var preferences: Preferences
  @Environment(\.dismiss) private var dismiss
  @State private var links = ""
  @State private var inputType = "link"
  @State private var markdown = ""
  @State private var markdownTitle = ""
  @State private var importingMarkdown = false
  @State private var markdownError: String?
  @State private var autoGenerate = true
  @State private var collection: String
  @State private var showNewFolder = false
  @State private var duplicateCheck: (query: DuplicateQuery, urls: Set<String>)?
  @FocusState private var linksFocused: Bool

  private struct DuplicateQuery: Equatable {
    let root: String
    let urls: [String]
    let pending: [String]
  }
  private struct DuplicateResult: Decodable {
    let duplicates: [String]
  }

  init(model: AppModel) {
    self.model = model
    self.queue = model.queue
    self.preferences = model.preferences
    self._collection = State(initialValue: Self.defaultCollection(in: model))
  }
  static func defaultCollection(in model: AppModel) -> String {
    if model.filter == "all" { return model.collection }
    if let detail = model.detail, detail.source.id == model.selectedID {
      return detail.source.collection
    }
    return model.sources.first { $0.id == model.selectedID }?.collection ?? model.collection
  }
  private var candidates: [LinkCandidate] { LinkCandidate.parse(links) }
  var body: some View {
    let candidates = self.candidates
    let query = DuplicateQuery(
      root: preferences.root, urls: candidates.filter { $0.platform != nil }.map(\.url),
      pending: queue.jobs.filter { !$0.isFinished && !$0.isGeneration }.map(\.input))
    let duplicateURLs = duplicateCheck?.query == query ? duplicateCheck?.urls ?? [] : []
    let importable = query.urls.filter { !duplicateURLs.contains($0) }
    let showsVisualStyle = autoGenerate && preferences.generationModes.contains(where: GenerationVisualStyle.applies(to:))
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("添加内容").font(.headline)
          Spacer()
          Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        Picker("来源类型", selection: $inputType) {
          Text("链接").tag("link")
          Text(AppModules.markdown.title).tag("markdown")
        }.pickerStyle(.segmented).labelsHidden()
        if inputType == "link" {
          TextEditor(text: $links).focused($linksFocused).font(.body).padding(8).frame(height: 76).background(
            .quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10)
          )
          .overlay(alignment: .topLeading) {
            if links.isEmpty {
              Text("粘贴链接或包含链接的文字…").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
            }
          }
          .accessibilityLabel("内容链接")
          if !candidates.isEmpty {
            ScrollView {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(candidates) { item in
                  HStack {
                    let module = AppModules.sources.first { $0.id == item.platform }
                    Image(systemName: module?.symbol ?? "exclamationmark.circle")
                    Text(module?.title ?? "暂不支持").font(.callout)
                    Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if duplicateURLs.contains(item.url) {
                      Text("重复链接").font(.caption).foregroundStyle(.orange).fixedSize()
                    }
                  }
                }
              }
            }.frame(maxHeight: 72)
          }
        } else {
          HStack {
            TextField("标题（可选）", text: $markdownTitle)
            Button("选择文件…") { chooseMarkdown() }.disabled(importingMarkdown)
          }
          TextEditor(text: $markdown)
            .font(.body).padding(8).frame(height: 100)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Markdown 正文")
            .disabled(importingMarkdown)
          if let markdownError {
            Text(markdownError).font(.caption).foregroundStyle(.red)
          }
        }
        HStack(spacing: 8) {
          FolderDestinationPicker(
            title: "存入文件夹", folders: model.collections + [collection], selection: $collection)
          Button {
            showNewFolder = true
          } label: {
            Image(systemName: "folder.badge.plus").modifier(DarkReadableAction())
          }.buttonStyle(.borderless).help("新建文件夹").accessibilityLabel("新建文件夹")
            .popover(isPresented: $showNewFolder) {
              NewFolderPanel(model: model, parent: collection) { collection = $0 }
            }
        }
        Toggle("添加后生成", isOn: $autoGenerate)
        if autoGenerate { GenerationFields(model: model, preferences: model.preferences) }
        Button {
          if inputType == "markdown" {
            importingMarkdown = true
            markdownError = nil
            Task {
              let imported = await model.importMarkdown(
                markdown, title: markdownTitle, collection: collection, autoGenerate: autoGenerate)
              importingMarkdown = false
              if imported { dismiss() }
              else { markdownError = model.error ?? "资料库目前无法导入。" }
            }
          } else {
            model.enqueue(
              importable.joined(separator: "\n"), autoGenerate: autoGenerate,
              collection: collection, skipExisting: true)
            dismiss()
          }
        } label: {
          Text(autoGenerate ? "添加并生成" : "添加资料").frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
          .disabled(
            importingMarkdown || (autoGenerate && preferences.generationModes.isEmpty)
              || (inputType == "markdown"
                ? markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : importable.isEmpty || candidates.contains { $0.platform == nil }))
      }.padding(20)
    }.frame(
      width: 460,
      height: (autoGenerate ? 530 : 300) + (inputType == "markdown" ? 60 : (candidates.isEmpty ? 0 : 60))
        + (showsVisualStyle ? 36 : 0)
    )
    .onAppear { autoGenerate = model.preferences.autoGenerate }
    .task(id: query) {
      guard !query.urls.isEmpty else { return }
      do {
        try await Task.sleep(for: .milliseconds(200))
        let result: DuplicateResult = try await model.engine.request(
          action: "check_imports", root: query.root,
          params: ["urls": query.urls, "pending": query.pending])
        try Task.checkCancellation()
        duplicateCheck = (query, Set(result.duplicates))
      } catch {
        // The engine also checks again during import.
      }
    }
    .task(id: showNewFolder) {
      linksFocused = false
      guard !showNewFolder else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      linksFocused = true
    }
  }

  private func chooseMarkdown() {
    let panel = NSOpenPanel()
    let extensions = ["md", "markdown", "txt"]
    panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
    panel.prompt = "导入"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      markdown = try String(contentsOf: url, encoding: .utf8)
      markdownTitle = url.deletingPathExtension().lastPathComponent
      markdownError = nil
    } catch {
      markdownError = "无法读取 UTF-8 Markdown 文件。"
    }
  }

}
struct GeneratePanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: Preferences
  private let initialDetail: SourceDetail?
  private let intent: GenerationIntent
  @State private var selectedModes: [String]
  @Environment(\.dismiss) private var dismiss
  init(model: AppModel, sourceDetail: SourceDetail? = nil, intent: GenerationIntent = .standard) {
    self.model = model
    self.preferences = model.preferences
    self.intent = intent
    let detail = sourceDetail ?? model.detail
    self.initialDetail = detail
    let allModes = GenerationModePicker.choices.map(\.id)
    let existing = Set(detail?.artifacts.map(\.kind) ?? [])
    let initialModes: [String]
    switch intent {
    case .standard: initialModes = model.preferences.generationModes
    case .supplement: initialModes = allModes.filter { !existing.contains($0) }
    case .regenerate:
      initialModes = existing.isEmpty ? allModes : allModes.filter { existing.contains($0) }
    }
    self._selectedModes = State(initialValue: initialModes)
  }
  private var sourceDetail: SourceDetail? {
    if let current = model.detail, current.source.id == initialDetail?.source.id { return current }
    return initialDetail
  }
  private var existingModes: Set<String> { Set(sourceDetail?.artifacts.map(\.kind) ?? []) }
  private var availableModes: [String] {
    let existing = existingModes
    return GenerationModePicker.choices.map(\.id).filter { intent != .supplement || !existing.contains($0) }
  }
  private var selectedAvailableModes: [String] {
    selectedModes.filter(availableModes.contains)
  }
  private var actionTitle: String {
    if model.generating { return "加入队列" }
    let existing = existingModes
    let selected = Set(selectedAvailableModes)
    guard !selected.isEmpty && !existing.isEmpty else { return "开始生成" }
    if selected.isSubset(of: existing) { return "开始重新生成" }
    if selected.isDisjoint(with: existing) { return "开始补充生成" }
    return "重新生成并补充"
  }
  private var title: String {
    switch intent {
    case .standard: return "生成笔记"
    case .supplement: return "补充生成"
    case .regenerate: return "重新生成"
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let sourceDetail {
        Text(sourceDetail.source.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
      }
      GenerationFields(
        model: model, preferences: preferences,
        modes: Binding(get: { selectedAvailableModes }, set: { selectedModes = $0 }),
        allowedModes: availableModes, existingModes: existingModes, intent: intent)
      Button {
        guard let detail = sourceDetail else { return }
        let modes = selectedAvailableModes
        if intent == .standard { preferences.generationModes = modes }
        Task {
          await model.generate(sourceDetail: detail, modes: modes, intent: intent)
          dismiss()
        }
      } label: {
        Label(
          actionTitle,
          systemImage: model.generating ? "text.badge.plus" : "sparkles"
        ).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
      .disabled(sourceDetail == nil || model.maintenance || selectedAvailableModes.isEmpty)
    }
  }
}
struct OrganizePanel: View {
  @ObservedObject var model: AppModel
  let source: SourceRecord
  @Environment(\.dismiss) private var dismiss
  @State private var collection = ""
  @State private var tags: [String] = []
  @State private var tagInput = ""
  @State private var showNewFolder = false
  @FocusState private var tagInputFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("整理资料").font(.headline)
      HStack(spacing: 8) {
        FolderDestinationPicker(
          title: "文件夹", folders: model.collections + [source.collection], selection: $collection)
        Button {
          showNewFolder = true
        } label: {
          Image(systemName: "folder.badge.plus").modifier(DarkReadableAction())
        }.buttonStyle(.borderless).help("新建文件夹").accessibilityLabel("新建文件夹")
          .popover(isPresented: $showNewFolder) {
            NewFolderPanel(model: model, parent: collection) { collection = $0 }
          }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("标签").foregroundStyle(.secondary)
        if !tags.isEmpty {
          TagFlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
              HStack(spacing: 6) {
                Text(tag).lineLimit(1)
                Button {
                  tags.removeAll { $0 == tag }
                } label: {
                  Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.plain).help("移除标签").accessibilityLabel("移除标签 \(tag)")
              }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
          }
        }
        HStack(spacing: 8) {
          TextField("添加标签", text: $tagInput).textFieldStyle(.roundedBorder)
            .focused($tagInputFocused)
            .onSubmit { addTag() }
          Button {
            addTag()
          } label: {
            Image(systemName: "plus").modifier(DarkReadableAction())
          }
          .buttonStyle(.borderless).help("添加标签").accessibilityLabel("添加标签")
          .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("保存") {
          addTag()
          Task {
            if await model.update(id: source.id, values: ["collection": collection, "tags": tags]) {
              dismiss()
            }
          }
        }.buttonStyle(.borderedProminent)
      }
    }.onAppear {
      collection = source.collection
      tags = source.tags
    }
    .task(id: showNewFolder) {
      tagInputFocused = false
      guard !showNewFolder else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      tagInputFocused = true
    }
  }
  private func addTag() {
    let value = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty, !tags.contains(value) { tags.append(value) }
    tagInput = ""
  }
}

struct NewFolderPanel: View {
  @ObservedObject var model: AppModel
  let onCreated: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var parent: String
  @State private var saving = false
  @State private var error: String?
  @FocusState private var nameFocused: Bool
  init(model: AppModel, parent: String = "", onCreated: @escaping (String) -> Void) {
    self.model = model
    self.onCreated = onCreated
    self._parent = State(initialValue: parent)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("新建文件夹").font(.headline)
      FolderDestinationPicker(
        title: "上级文件夹", folders: model.collections, selection: $parent, rootTitle: "资料库")
      TextField("文件夹名称", text: $name).textFieldStyle(.roundedBorder)
        .focused($nameFocused)
        .onSubmit { create() }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("新建") { create() }.buttonStyle(.borderedProminent)
          .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(20).frame(width: 320)
      .task {
        await Task.yield()
        guard !Task.isCancelled else { return }
        nameFocused = true
      }
  }
  private func create() {
    guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        onCreated(try await model.createFolder(name, parent: parent))
        dismiss()
      } catch {
        self.error = error.localizedDescription
        nameFocused = true
      }
    }
  }
}

struct FolderDestinationPicker: View {
  let title: String
  let folders: [String]
  @Binding var selection: String
  var rootTitle = "未分类"

  var body: some View {
    HStack(spacing: 8) {
      Text(title).foregroundStyle(.secondary).fixedSize()
      NativeMenuPicker(
        options: [.init(id: "", title: rootTitle)] + LibraryFolder.all(in: folders + [selection]).map {
          .init(id: $0, title: LibraryFolder.displayPath($0))
        },
        selection: $selection, accessibilityLabel: title,
        accessibilityIdentifier: "folder-destination-picker"
      ).frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct TagFlowLayout: Layout {
  var spacing: CGFloat = 6
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrangement(width: proposal.width, subviews: subviews).size
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrangement(width: bounds.width, subviews: subviews)
    for (index, item) in result.items.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
        proposal: ProposedViewSize(item.size))
    }
  }
  private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
    let limit = width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    var items: [CGRect] = []
    for view in subviews {
      var size = view.sizeThatFits(.unspecified)
      size.width = min(size.width, limit)
      if x > 0, x + size.width > limit {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      items.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      usedWidth = max(usedWidth, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: width ?? usedWidth, height: y + rowHeight), items)
  }
}
