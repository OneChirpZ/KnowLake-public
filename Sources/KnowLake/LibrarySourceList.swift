import AppKit
import SwiftUI

struct LibrarySourceList: View {
  @ObservedObject var model: AppModel
  @ObservedObject var queue: QueueState
  @State private var scrollPositions = SourceListScrollPositions()
  @State private var folderOffset: CGFloat = 0
  @State private var folderOpacity = 1.0
  @State private var displayedFolder: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var scrollScope: String {
    [model.preferences.root, model.filter, model.collection, model.query, model.platform, model.tag].joined(separator: "\0")
  }

  private var visibleJobs: [Job] {
    queue.jobs.filter { job in
      if job.isGeneration { return true }
      if model.filter == "starred" { return false }
      if model.filter == "all", !LibraryFolder.contains(job.importOptions?.collection ?? "", in: model.collection) { return false }
      if !model.tag.isEmpty && job.importOptions?.tags.contains(model.tag) != true { return false }
      if !model.platform.isEmpty && model.platform != (job.isBilibili ? "bilibili" : "wechat") { return false }
      let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
      return query.isEmpty || job.input.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if model.sources.isEmpty && !model.loading && !visibleJobs.contains(where: { !$0.isFinished && !$0.isGeneration }) {
        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView.search(text: model.query)
        } else if model.filter == "all", model.tag.isEmpty, model.platform.isEmpty,
          !LibraryFolder.children(of: model.collection, in: model.collections).isEmpty {
          Color.clear
        } else if !model.collection.isEmpty {
          ContentUnavailableView("文件夹为空", systemImage: "folder")
        } else if model.filter == "unread" {
          ContentUnavailableView("暂无未读资料", systemImage: "checkmark.circle")
        } else if model.filter == "starred" {
          ContentUnavailableView("暂无收藏", systemImage: "star")
        } else {
          ContentUnavailableView("暂无资料", systemImage: "tray")
        }
      } else {
        SourceTable(
          sources: model.sources, selection: model.selectedID,
          select: { id in
            if model.selectedID != id { model.select(id) }
          }, action: { source, action in
            if action == "open" {
              if let url = source.webURL { NSWorkspace.shared.open(url) }
            } else {
              Task {
                await model.update(
                  id: source.id, values: action == "star" ? ["starred": !source.starred] : ["read": !source.read])
              }
            }
          }, jobs: visibleJobs, pendingSelection: model.selectedAcquisitionID,
          selectPending: { model.selectAcquisition($0) }, folders: model.collections,
          move: { source, folder in
            Task { await model.update(id: source.id, values: ["collection": folder]) }
          }, dragRoot: model.preferences.root, scrollPositions: scrollPositions, scrollScope: scrollScope)
        if model.sources.count < model.total {
          Button("加载更多") { Task { await model.more() } }.buttonStyle(.plain).padding(10)
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .offset(x: folderOffset).opacity(folderOpacity)
      .task(id: model.collection) {
        let wasDisplayed = displayedFolder != nil
        displayedFolder = model.collection
        guard wasDisplayed else { return }
        guard !reduceMotion else { folderOffset = 0; folderOpacity = 1; return }
        folderOffset = model.folderNavigationDirection * 16
        folderOpacity = 0.65
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.18)) { folderOffset = 0; folderOpacity = 1 }
      }
  }
}
