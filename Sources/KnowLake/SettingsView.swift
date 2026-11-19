import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var preferences: Preferences
  var body: some View {
    TabView {
      settingsPage {
        settingsCard {
          settingRow("资料目录") {
            Text(preferences.root).font(.callout).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          actionRow {
            Button("迁移资料…") { chooseDataDirectory() }
            Button("在 Finder 中打开") {
              NSWorkspace.shared.open(URL(fileURLWithPath: preferences.root))
            }
          }
          if model.maintenance { ProgressView("正在迁移") }
        }
        settingsCard {
          settingRow("文件夹浏览") {
            Picker("文件夹浏览", selection: $preferences.folderBrowsingMode) {
              Text("逐级浏览").tag(FolderBrowsingMode.levels)
              Text("树状浏览").tag(FolderBrowsingMode.tree)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 190, alignment: .leading)
          }
        }
        if AppModules.hasMediaCache {
          settingsCard {
            settingRow("媒体缓存") {
              VStack(alignment: .leading, spacing: 5) {
                if let cache = model.cacheInfo {
                  Text(
                    "\(ByteCountFormatter.string(fromByteCount: cache.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: cache.maxBytes, countStyle: .file))"
                  ).font(.callout.monospacedDigit())
                  Text("保留 \(cache.retentionDays) 天 · \(cache.entries) 项")
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                  Text("保留 30 天 · 上限 3 GB").font(.callout).foregroundStyle(.secondary)
                }
              }
            }
            actionRow {
              Button(model.cacheMaintaining ? "正在清理…" : "清理过期与超额缓存") {
                Task { await model.cleanupCache() }
              }.disabled(model.cacheMaintaining || model.maintenance)
              if model.cacheMaintaining { ProgressView().controlSize(.small) }
            }
          }
        }
      }.tabItem { Label("资料", systemImage: "folder") }
      settingsPage {
        settingsCard {
          settingRow("最大并发数") {
            Stepper(value: $preferences.maxConcurrentGenerations, in: 1...Int.max) {
              Text("\(preferences.maxConcurrentGenerations) 项").monospacedDigit()
            }
            .fixedSize().accessibilityLabel("最大并发数")
          }
          settingRow("Codex 路径") { TextField("自动查找", text: $preferences.codexPath) }
          settingRow("Codex 模型") {
            CodexModelSelector(model: model, preferences: preferences, width: 320)
          }
        }
        #if KNOWLAKE_PRIVATE
        PrivateGenerationSettings(model: model, preferences: preferences)
        #endif
      }.tabItem { Label("生成", systemImage: "sparkles") }
      settingsPage {
        #if KNOWLAKE_PRIVATE
        PrivateAcquisitionSettings(model: model, preferences: preferences)
        #endif
        settingsCard {
          settingRow("采集浏览器") { TextField("Camoufox 路径（可选）", text: $preferences.browserPath) }
          if !preferences.networkProxy.isEmpty {
            actionRow {
              Label("已使用导入的采集代理", systemImage: "network").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }.tabItem { Label("采集", systemImage: "link") }
      settingsPage {
        settingsCard {
          settingRow("备份频率") {
            NativeMenuPicker(
              options: [.init(id: 1, title: "每天"), .init(id: 7, title: "每周"),
                        .init(id: 0, title: "手动")],
              selection: $preferences.backupDays, accessibilityLabel: "备份频率"
            ).frame(width: 180, height: 26)
          }
          settingRow("备份目录") {
            Text(
              preferences.backupDirectory.isEmpty ? "资料目录内的 backups" : preferences.backupDirectory
            )
            .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
          actionRow {
            Button("选择目录…") { chooseBackupDirectory() }
            Button("立即备份") { Task { await model.backup() } }
          }
        }
        settingsCard {
          Button("从备份恢复…") { restoreBackup() }
        }
      }.tabItem { Label("备份", systemImage: "externaldrive.badge.timemachine") }
    }.padding(12).onAppear {
      Task { await model.refreshCacheInfo() }
    }
      .onChange(of: preferences.root) {
        Task { await model.refreshCacheInfo() }
      }
  }
  private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14, content: content)
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
    }.textFieldStyle(.roundedBorder)
  }
  private func chooseDataDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "选择目标目录"
    if panel.runModal() == .OK, let url = panel.url {
      Task { await model.relocate(destination: url.path) }
    }
  }
  private func chooseBackupDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url { preferences.backupDirectory = url.path }
  }
  private func restoreBackup() {
    let file = NSOpenPanel()
    file.allowedContentTypes = [.zip]
    file.prompt = "选择备份"
    guard file.runModal() == .OK, let archive = file.url else { return }
    let target = NSOpenPanel()
    target.canChooseFiles = false
    target.canChooseDirectories = true
    target.canCreateDirectories = true
    target.prompt = "选择恢复目录"
    if target.runModal() == .OK, let url = target.url {
      Task { await model.relocate(destination: url.path, archive: archive.path) }
    }
  }
}

func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
  VStack(alignment: .leading, spacing: 14, content: content)
    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
}
func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content)
  -> some View
{
  HStack(alignment: .firstTextBaseline, spacing: 16) {
    Text(label).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
    content().frame(maxWidth: .infinity, alignment: .leading)
  }
}
func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
  HStack(spacing: 10, content: content).padding(.leading, 104)
}
