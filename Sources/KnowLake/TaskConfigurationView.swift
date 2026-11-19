import SwiftUI

struct TaskConfigurationField: Identifiable, Equatable {
  let title: String
  let value: String
  var id: String { title }
}

extension Job {
  var generationConfigurationFields: [TaskConfigurationField] {
    guard isGeneration, let generation else { return [] }
    let usesAPI = generation.provider == "api" && generation.mode == "markdown"
    let model = usesAPI ? generation.apiModel : generation.model
    var fields = [
      TaskConfigurationField(title: "生成形式", value: taskTypeTitle),
      TaskConfigurationField(title: "执行方式", value: usesAPI ? "模型 API" : "Codex Agent"),
      TaskConfigurationField(title: "模型", value: model.isEmpty ? "运行时默认" : model),
    ]
    if !usesAPI {
      fields += [
        TaskConfigurationField(
          title: "思考强度", value: ReasoningEffortSlider.label(generation.reasoningEffort ?? "")),
        TaskConfigurationField(title: "Fast mode", value: generation.fastMode == true ? "开启" : "关闭"),
      ]
    }
    fields += [
      TaskConfigurationField(title: "内容深度", value: generation.depth.isEmpty ? "未记录" : generation.depth),
      TaskConfigurationField(title: "生成方式", value: generationBatchID == nil ? "单独生成" : "联合生成"),
    ]
    if GenerationVisualStyle.applies(to: generation.mode), let style = generation.selectedVisualStyle {
      fields.append(TaskConfigurationField(title: "视觉风格", value: style.title))
    }
    if !generation.style.isEmpty {
      fields.append(TaskConfigurationField(title: "写作要求", value: generation.style))
    }
    if generation.contextStart.isEmpty && generation.contextEnd.isEmpty {
      fields.append(TaskConfigurationField(title: "材料范围", value: "全文"))
    } else {
      if !generation.contextStart.isEmpty {
        fields.append(TaskConfigurationField(title: "范围起点", value: generation.contextStart))
      }
      if !generation.contextEnd.isEmpty {
        fields.append(TaskConfigurationField(title: "范围终点", value: generation.contextEnd))
      }
    }
    return fields
  }
}

struct TaskConfigurationView: View {
  let job: Job
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("生成配置").font(.headline)
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").foregroundStyle(.secondary)
        }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
          .help("关闭").accessibilityLabel("关闭配置")
      }
      let fields = job.generationConfigurationFields
      if fields.isEmpty {
        Text("未记录生成配置").font(.callout).foregroundStyle(.secondary)
      } else {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
          ForEach(fields) { field in
            GridRow(alignment: .top) {
              Text(field.title).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
              Text(field.value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }.font(.callout)
      }
    }.padding(20).frame(width: 360)
      .accessibilityIdentifier("task-configuration-popover")
  }
}
