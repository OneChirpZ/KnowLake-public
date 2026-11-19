import SwiftUI

/// Neutral text for secondary actions in dark mode; the primary CTA keeps its tint.
struct DarkReadableAction: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isEnabled) private var isEnabled

  @ViewBuilder func body(content: Content) -> some View {
    if colorScheme == .dark {
      content.foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.35))
    } else {
      content
    }
  }
}

struct PillChoice: Identifiable {
  let id: String
  let title: String
  var icon: String? = nil
  var badge: Int? = nil
  var help: String? = nil
  var isLoading = false
  var isEnabled = true
}
struct PillSwitch: View {
  let choices: [PillChoice]
  @Binding var selection: String
  var compact = false
  var iconsOnly = false
  var showsBackground = true
  var nativeInteraction = false
  @Namespace private var slider
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    HStack(spacing: 3) {
      ForEach(choices) { choice in
        Group {
          if nativeInteraction {
            Toggle(isOn: Binding(
              get: { selection == choice.id },
              set: { _ in selection = choice.id })
            ) {
              pillLabel(choice)
            }
            .toggleStyle(.button).buttonStyle(.plain)
          } else {
            Button {
              withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = choice.id }
            } label: {
              pillLabel(choice)
            }.buttonStyle(.plain)
          }
        }.disabled(!choice.isEnabled).accessibilityLabel(choice.title)
          .accessibilityValue(
            [selection == choice.id ? "已选择" : nil, choice.isLoading ? "处理中" : nil,
             choice.badge.flatMap { $0 > 0 ? choice.help ?? String($0) : nil }]
              .compactMap { $0 }.joined(separator: "，"))
          .help(choice.help ?? choice.title)
      }
    }.padding(nativeInteraction && !showsBackground ? 0 : 3).background {
      if showsBackground { Capsule().fill(.quaternary.opacity(0.45)) }
    }
  }
  private func pillLabel(_ choice: PillChoice) -> some View {
    choiceLabel(choice)
      .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 4 : 7)
      .background {
        if selection == choice.id {
          Capsule().fill(
            colorScheme == .dark
              ? Color.primary.opacity(nativeInteraction ? 0.18 : 0.13)
              : Color.accentColor.opacity(0.20)
          ).matchedGeometryEffect(id: "selection", in: slider)
        }
      }
      .foregroundStyle(
        selection == choice.id
          ? (colorScheme == .dark ? Color.primary : Color.accentColor) : .secondary
      )
      .contentShape(Capsule())
  }
  private func choiceLabel(_ choice: PillChoice) -> some View {
    HStack(spacing: 5) {
      if let icon = choice.icon {
        Image(systemName: icon).overlay(alignment: .topTrailing) {
          if let count = choice.badge, count > 0 {
            let diameter = max(CGFloat(16), CGFloat(String(count).count) * 5.5 + 6)
            Text(String(count)).font(.system(size: 9, weight: .semibold, design: .rounded))
              .monospacedDigit().foregroundStyle(.white)
              .frame(width: diameter, height: diameter).background(.tint, in: Circle())
              .offset(x: 9, y: -7).accessibilityHidden(true)
          }
        }
      }
      if !iconsOnly {
        Text(choice.title).fontWeight(selection == choice.id ? .semibold : .regular)
      }
      if choice.isLoading {
        LoadingIndicator()
          .accessibilityHidden(true)
      }
    }.frame(maxWidth: iconsOnly ? .infinity : nil).font(.callout)
  }
}

struct ReasoningEffortSlider: View {
  let efforts: [String]
  @Binding var selection: String
  var isLoading = false

  private var options: [String] {
    let values = efforts.filter { !$0.isEmpty }
    return [""] + values + (selection.isEmpty || values.contains(selection) ? [] : [selection])
  }
  private var index: Int { options.firstIndex(of: selection) ?? 0 }
  private var selectedLabel: String { Self.label(options[index]) }

  static func label(_ value: String) -> String {
    [
      "": "模型默认", "none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium",
      "high": "High", "xhigh": "Extra High", "max": "Max", "ultra": "Ultra",
    ][value] ?? value
  }

  var body: some View {
    HStack(spacing: 10) {
      if efforts.isEmpty {
        Text(isLoading ? "正在读取档位…" : "暂无可用档位")
          .font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("reasoning-effort-status")
      } else {
        NativeReasoningSlider(
          index: Binding(
            get: { index },
            set: { selection = options[min(max($0, 0), options.count - 1)] }),
          count: options.count, accessibilityLabel: "思考强度", accessibilityValue: selectedLabel,
          accessibilityIdentifier: "reasoning-effort-slider"
        ).frame(maxWidth: .infinity)
      }
      Text(selectedLabel).font(.callout).frame(width: 76, alignment: .leading)
        .accessibilityIdentifier("reasoning-effort-value")
    }.frame(width: 240)
  }
}

struct ArtifactSwitcher: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var queue: QueueState
  let detail: SourceDetail
  let showsSurface: Bool
  let onPresentationChanged: (Bool) -> Void
  @State private var generationIntent: GenerationIntent?
  init(model: AppModel, detail: SourceDetail, showsSurface: Bool = true,
       onPresentationChanged: @escaping (Bool) -> Void = { _ in }) {
    self.model = model
    self.queue = model.queue
    self.detail = detail
    self.showsSurface = showsSurface
    self.onPresentationChanged = onPresentationChanged
  }
  private var kind: String { model.selectedGenerationMode ?? model.selectedArtifact?.kind ?? "source" }
  var choices: [PillChoice] {
    [PillChoice(id: "source", title: "原文", icon: "doc.text")]
      + [
        ("markdown", "图文笔记", "text.book.closed"), ("html", "看板", "rectangle.3.group"),
        ("image", "概览图", "photo"),
      ]
      .filter { item in
        detail.artifacts.contains { $0.kind == item.0 }
          || ReaderGenerationState.hasVisibleProgress(sourceID: detail.source.id, mode: item.0, jobs: queue.jobs)
      }
      .map { item in
        let available = detail.artifacts.contains { $0.kind == item.0 }
        let job = ReaderGenerationState.job(sourceID: detail.source.id, mode: item.0, jobs: queue.jobs)
        let processing = job.map { !$0.isFinished && !$0.failed && !$0.cancelled } ?? false
        return PillChoice(
          id: item.0, title: item.1, icon: available || processing ? item.2 : "clock",
          help: available && !processing ? nil : item.1 + " · " + (job?.state ?? "等待处理"),
          isLoading: processing)
      }
  }
  var body: some View {
    HStack(spacing: 4) {
      PillSwitch(
        choices: choices,
        selection: Binding(
          get: { kind },
          set: { value in
            model.selectReaderKind(value, in: detail)
          }), showsBackground: false, nativeInteraction: true)
      if detail.artifacts.filter({ $0.kind == kind }).count > 1
        || (model.selectedGenerationMode != nil && detail.artifacts.contains { $0.kind == kind })
      {
        Menu {
          ForEach(detail.artifacts.filter { $0.kind == kind }) { artifact in
            Button(
              String(artifact.created_at.prefix(16)).replacingOccurrences(of: "T", with: " ")
                + " · " + artifact.title
            ) {
              model.selectedArtifact = artifact
              model.selectedGenerationMode = nil
            }
          }
        } label: {
          Image(systemName: "clock.arrow.circlepath").modifier(DarkReadableAction())
            .frame(width: 30, height: 30).contentShape(Circle())
        }.menuStyle(.borderlessButton).buttonStyle(.plain)
          .menuIndicator(.hidden).tint(.primary)
          .help("历史结果").accessibilityLabel("历史结果")
      }
      Menu {
        Button("补充生成…") {
          generationIntent = .supplement
        }
        .disabled(GenerationModePicker.choices.allSatisfy { choice in
          detail.artifacts.contains { $0.kind == choice.id }
        })
        Button("重新生成…") {
          generationIntent = .regenerate
        }
      } label: {
        Image(systemName: "plus").modifier(DarkReadableAction())
          .frame(width: 30, height: 30).contentShape(Circle())
      }.menuStyle(.borderlessButton).buttonStyle(.plain)
        .menuIndicator(.hidden).tint(.primary)
        .help("补充生成").accessibilityLabel("补充生成")
        .accessibilityIdentifier("reader-generation-menu")
        .disabled(model.maintenance)
        .popover(isPresented: Binding(
          get: { generationIntent != nil },
          set: { if !$0 { generationIntent = nil } })
        ) {
          if let generationIntent {
            GeneratePanel(model: model, sourceDetail: detail, intent: generationIntent).buttonStyle(.bordered)
              .padding(22).frame(width: 460)
          }
        }
    }.padding(.horizontal, 8).frame(height: ReaderControlsPosition.diameter).fixedSize()
      .background {
        if showsSurface {
          Capsule().fill(.quaternary.opacity(0.45))
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
      }
      .contentShape(Capsule())
      .onChange(of: generationIntent != nil) { onPresentationChanged($0) }
      .onDisappear { onPresentationChanged(false) }
  }
}
struct GenerationModePicker: View {
  @ObservedObject var preferences: Preferences
  var modes: Binding<[String]>? = nil
  var allowedModes: [String]? = nil
  var existingModes: Set<String>? = nil
  @Environment(\.colorScheme) private var colorScheme
  static let choices = [
    PillChoice(id: "markdown", title: "图文笔记", icon: "doc.richtext"),
    PillChoice(id: "html", title: "自由看板", icon: "rectangle.3.group"),
    PillChoice(id: "image", title: "概览图", icon: "photo"),
  ]
  private var selection: Binding<[String]> {
    modes ?? Binding(get: { preferences.generationModes }, set: { preferences.generationModes = $0 })
  }
  private var regenerationColor: Color {
    colorScheme == .dark ? .orange : Color(red: 0.51, green: 0.30, blue: 0.06)
  }
  var body: some View {
    VStack(spacing: 7) {
      HStack(spacing: 3) {
        ForEach(Self.choices) { choice in
          let isEnabled = allowedModes?.contains(choice.id) ?? true
          let hasResult = existingModes?.contains(choice.id) == true
          let action = hasResult ? (isEnabled ? "重新生成" : "已有结果") : "补充生成"
          Toggle(isOn: Binding(
            get: { selection.wrappedValue.contains(choice.id) },
            set: { enabled in
              if enabled {
                selection.wrappedValue.append(choice.id)
              } else {
                selection.wrappedValue.removeAll { $0 == choice.id }
              }
            })
          ) {
            VStack(alignment: .leading, spacing: 2) {
              Text(choice.title)
              if existingModes != nil {
                Text(action).font(.caption)
                  .foregroundStyle(hasResult && isEnabled ? regenerationColor : Color.secondary)
              }
            }
          }.toggleStyle(.checkbox).font(.callout).fixedSize()
            .disabled(!isEnabled)
            .help(existingModes == nil ? "生成" + choice.title : "\(choice.title) · \(action)")
            .accessibilityLabel(existingModes == nil ? choice.title : "\(choice.title)，\(action)")
            .accessibilityIdentifier("generation-format-" + choice.id)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background {
              if selection.wrappedValue.contains(choice.id) {
                Capsule().fill(
                  colorScheme == .dark ? Color.primary.opacity(0.13) : Color.accentColor.opacity(0.20))
              }
            }
        }
      }.padding(3).background(.quaternary.opacity(0.45), in: Capsule())
      if existingModes?.contains(where: { allowedModes?.contains($0) ?? true }) == true {
        Text("重新生成会更新默认结果，旧版本可在「历史结果」查看。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct GenerationFields: View {
  @ObservedObject var model: AppModel
  @ObservedObject var preferences: Preferences
  var modes: Binding<[String]>? = nil
  var allowedModes: [String]? = nil
  var existingModes: Set<String>? = nil
  var intent: GenerationIntent = .standard
  private var requiresCodex: Bool {
    intent == .regenerate || (modes?.wrappedValue ?? preferences.generationModes).contains { $0 != "markdown" }
  }
  private var provider: String {
    requiresCodex || !AppModules.supports(provider: preferences.provider, mode: "markdown")
      ? "codex" : preferences.provider
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      GenerationModePicker(
        preferences: preferences, modes: modes, allowedModes: allowedModes, existingModes: existingModes)
        .frame(maxWidth: .infinity)
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        if (modes?.wrappedValue ?? preferences.generationModes).contains(where: GenerationVisualStyle.applies(to:)) {
          GridRow {
            fieldLabel("视觉风格")
            Picker("视觉风格", selection: $preferences.visualStyle) {
              ForEach(GenerationVisualStyle.allCases, id: \.self) { style in
                Text(style.title).tag(style)
              }
            }.pickerStyle(.segmented).labelsHidden()
              .frame(width: 240, height: 30, alignment: .leading)
              .accessibilityIdentifier("generation-visual-style")
          }
        }
        if AppModules.generators.count > 1 {
          GridRow {
            fieldLabel("执行方式")
            PillSwitch(
              choices: AppModules.generators.map { module in
                PillChoice(id: module.id, title: module.title,
                  isEnabled: !requiresCodex || module.id == AppModules.codex.id)
              },
              selection: Binding(get: { provider },
                                 set: { if intent != .regenerate { preferences.provider = $0 } }), compact: true
            ).frame(width: 240, height: 30, alignment: .leading)
          }
        }
        if provider == "codex" {
          GridRow {
            fieldLabel("模型")
            CodexModelSelector(model: model, preferences: preferences, width: 240)
              .frame(minHeight: 30)
          }
          GridRow {
            fieldLabel("思考强度")
            if intent == .regenerate && !AppModules.isPublic {
              Text("Ultra").font(.callout).frame(width: 240, height: 30, alignment: .leading)
                .accessibilityIdentifier("regeneration-reasoning-effort")
            } else {
              ReasoningEffortSlider(
                efforts: model.selectedCodexModel?.efforts ?? [],
                selection: $model.reasoningEffort, isLoading: model.isLoadingCodexModels
              ).frame(height: 30)
                .onAppear { selectReasoningDefault() }
                .onChange(of: preferences.model) { selectReasoningDefault() }
                .onChange(of: model.selectedCodexModel?.efforts) { selectReasoningDefault() }
            }
          }
          GridRow {
            fieldLabel("Fast mode")
            Toggle(isOn: $preferences.fastMode) {
              Text("更快，消耗更多额度").font(.caption).foregroundStyle(.secondary)
            }.toggleStyle(.switch).controlSize(.small)
              .frame(width: 240, height: 30, alignment: .leading)
              .accessibilityLabel("Fast mode")
              .accessibilityIdentifier("codex-fast-mode")
          }
        }
        #if KNOWLAKE_PRIVATE
        if provider == PrivateModules.api.id {
          GridRow {
            fieldLabel("API 配置")
            NativeMenuPicker(
              options: [.init(id: "", title: "自定义")]
                + preferences.apiProfiles.map { .init(id: $0.id, title: $0.name) },
              selection: Binding(
                get: { preferences.apiProfileID },
                set: { id in
                  do { try preferences.selectProfile(id) } catch {
                    model.error = error.localizedDescription
                  }
                }),
              accessibilityLabel: "API 配置"
            ).frame(width: 240, height: 26)
          }
          GridRow {
            fieldLabel("模型")
            APIModelSelector(preferences: preferences, width: 240).frame(minHeight: 30)
          }
        }
        #endif
        GridRow {
          fieldLabel("内容深度")
          PillSwitch(
            choices: ["简短", "标准", "深入"].map { PillChoice(id: $0, title: $0) },
            selection: $model.depth, compact: true
          ).frame(width: 240, height: 30, alignment: .leading)
        }
      }.frame(maxWidth: .infinity)
    }
  }
  private func selectReasoningDefault() {
    guard let selected = model.selectedCodexModel else { return }
    let effort = selected.preferredEffort(preserving: model.reasoningEffort)
    if effort != model.reasoningEffort { model.reasoningEffort = effort }
  }
  private func fieldLabel(_ value: String) -> some View {
    Text(value).font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
  }
}
struct LinkCandidate: Identifiable {
  var id: String { url }
  let url: String
  let platform: String?
  static func parse(_ text: String) -> [LinkCandidate] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return [] }
    let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
    var seen = Set<String>()
    return matches.compactMap { match in
      guard let url = match.url, ["https", "http"].contains(url.scheme ?? "") else { return nil }
      let type = AppModules.source(for: url)?.id
      var normalized = URLComponents(url: url, resolvingAgainstBaseURL: false)
      if type != nil { normalized?.scheme = "https" }
      let address = normalized?.url?.absoluteString ?? url.absoluteString
      guard seen.insert(address).inserted else { return nil }
      return .init(url: address, platform: type)
    }
  }
}
