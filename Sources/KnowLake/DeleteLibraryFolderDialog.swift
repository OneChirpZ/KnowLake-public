import SwiftUI

struct DeleteLibraryFolderDialog: ViewModifier {
  let model: AppModel
  @Binding var folder: String?

  func body(content: Content) -> some View {
    content.alert(
      "删除文件夹？", isPresented: Binding(
        get: { folder != nil }, set: { if !$0 { folder = nil } }), presenting: folder
    ) { path in
      let parent = LibraryFolder.parent(of: path)
      Button(parent.isEmpty ? "删除并移到资料库根目录" : "删除并移到上层文件夹", role: .destructive) {
        delete(path, moveToRoot: false)
      }.keyboardShortcut(.defaultAction)
      if !parent.isEmpty {
        Button("删除并移到资料库根目录", role: .destructive) { delete(path, moveToRoot: true) }
      }
      Button("取消", role: .cancel) {}
    } message: { path in
      let title = LibraryFolder.displayPath(path)
      if model.collections.contains(where: { $0.hasPrefix(path + "/") }) {
        Text("“\(title)”及其子文件夹将被移除，所有资料会移到你选择的位置。")
      } else {
        Text("“\(title)”中的资料会移到你选择的位置。")
      }
    }
  }

  private func delete(_ path: String, moveToRoot: Bool) {
    Task {
      do { try await model.deleteFolder(path, moveToRoot: moveToRoot) }
      catch { model.error = error.localizedDescription }
    }
  }
}
