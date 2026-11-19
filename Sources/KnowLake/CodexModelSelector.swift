import SwiftUI

struct CodexModelSelector: View {
  @ObservedObject var model: AppModel
  @ObservedObject var preferences: Preferences
  var width: CGFloat = 240
  @State private var custom = ""
  @State private var editing = false
  private var names: [String] {
    Array(
      Set(
        model.models.map(\.id) + preferences.customCodexModels
          + (preferences.model.isEmpty ? [] : [preferences.model]))
    ).sorted()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        NativeMenuPicker(
          options: [.init(id: "", title: "Codex 默认")] + names.map { id in
            .init(id: id, title: model.models.first(where: { $0.id == id })?.name ?? id)
          },
          selection: $preferences.model, accessibilityLabel: "Codex 模型",
          accessibilityIdentifier: "codex-model-picker"
        ).frame(width: width - 60, height: 26)
        Button {
          Task { await model.loadModels() }
        } label: {
          if model.isLoadingCodexModels {
            LoadingIndicator().environment(\.isEnabled, true)
          } else {
            Image(systemName: "arrow.clockwise").modifier(DarkReadableAction())
          }
        }.buttonStyle(.borderless).frame(width: 24, height: 24)
          .disabled(model.isLoadingCodexModels).help("刷新 Codex 模型")
        Button {
          custom = preferences.model
          editing.toggle()
        } label: {
          Image(systemName: "plus").modifier(DarkReadableAction())
        }.buttonStyle(.borderless).frame(width: 24, height: 24).help("自定义 Codex 模型名")
      }.fixedSize(horizontal: true, vertical: false)
      if editing {
        HStack {
          TextField("自定义 Codex 模型名", text: $custom).textFieldStyle(.roundedBorder).onSubmit {
            save()
          }
          Button("添加") { save() }.disabled(
            custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }.frame(width: width, alignment: .leading).onAppear {
      // A quick popover close/reopen must not cancel the shared catalog request.
      if model.models.isEmpty { Task { await model.loadModels() } }
    }
  }
  private func save() {
    preferences.addCustomCodexModel(custom)
    editing = false
  }
}
