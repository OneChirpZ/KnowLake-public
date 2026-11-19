import SwiftUI

enum JobStage: String, CaseIterable {
  case queued, fetch, subtitles, download, transcribe, prepare, analyze, draft, review, generate, save

  static func detect(_ message: String, generation: Bool) -> JobStage? {
    if message.contains("已加入") || message.contains("重新加入") || message.contains("等待生成") {
      return .queued
    }
    if message.contains("正在保存") || message.contains("已归档") || message.contains("已保存")
      || message.contains("复用归档")
    {
      return .save
    }
    if generation {
      if message.contains("正在准备") || message.contains("正在启动 Codex") || message.contains("已连接")
        || message.contains("将使用") || message.contains("正在发送")
      {
        return .prepare
      }
      if message.contains("正在") || message.contains("生图工具") { return .generate }
    } else {
      if message.contains("下载音频") || message.contains("音频下载") { return .download }
      if message.contains("转写") || message.contains("火山引擎") || message.contains("录音")
        || message.contains("音频预处理")
      {
        return .transcribe
      }
      if message.contains("字幕") { return .subtitles }
      if message.contains("正在获取") || message.contains("网页") || message.contains("提取正文") {
        return .fetch
      }
    }
    return nil
  }
}

enum TimelineStatus { case pending, active, completed, reused, skipped, failed, cancelled }

extension Job {
  var isBilibili: Bool {
    guard let host = URL(string: input)?.host?.lowercased() else { return false }
    return host == "bilibili.com" || host.hasSuffix(".bilibili.com") || host == "b23.tv"
  }

  var usesCodexCheckpoints: Bool {
    guard isGeneration, let generation else { return false }
    return generation.provider != "api" || generation.mode != "markdown"
  }

  var hasExplicitStageStates: Bool {
    stageStates != nil || eventHistory.contains { $0.stageStatus != nil }
  }

  var recordedStageStates: [String: String] {
    var result: [String: String] = [:]
    for event in eventHistory {
      if let stage = event.stage, let status = event.stageStatus { result[stage] = status }
    }
    return result.merging(stageStates ?? [:]) { _, recorded in recorded }
  }
}

struct JobTimelineStep: Identifiable {
  let stage: JobStage
  let title: String
  let status: TimelineStatus
  let date: Date?
  let message: String?
  var id: String { stage.rawValue }

  static func plan(for job: Job) -> [(JobStage, String)] {
    if job.usesCodexCheckpoints {
      return [
        (.queued, "排队"), (.prepare, "准备材料"), (.analyze, "分析来源"), (.draft, "生成草稿"),
        (.review, "校对成稿"), (.save, "保存产物"),
      ]
    }
    if job.isGeneration {
      return [(.queued, "排队"), (.prepare, "准备模型"), (.generate, "生成内容"), (.save, "保存产物")]
    }
    if job.isBilibili {
      return [
        (.queued, "排队"), (.fetch, "视频信息"), (.subtitles, "读取字幕"), (.download, "下载音频"),
        (.transcribe, "语音转写"), (.save, "归档"),
      ]
    }
    return [(.queued, "排队"), (.fetch, "获取正文"), (.save, "归档")]
  }

  static func retryStages(for job: Job) -> [JobTimelineStep] {
    guard !job.isWaiting, job.isGeneration || job.isBilibili else { return [] }
    let steps = steps(for: job)
    // Stage retries need checkpoints from the current implementation. Older jobs
    // remain retryable from their first processing stage.
    guard job.hasExplicitStageStates else { return Array(steps.dropFirst().prefix(1)) }
    func completed(_ stage: JobStage) -> Bool {
      steps.contains { $0.stage == stage && ($0.status == .completed || $0.status == .reused) }
    }
    func skipped(_ stage: JobStage) -> Bool {
      steps.contains { $0.stage == stage && $0.status == .skipped }
    }
    return steps.filter { step in
      guard step.stage != .queued, step.status != .pending, step.status != .skipped else {
        return false
      }
      switch step.stage {
      case .prepare, .fetch: return true
      case .analyze: return completed(.prepare)
      case .draft: return completed(.prepare) && completed(.analyze)
      case .review: return completed(.prepare) && completed(.analyze) && completed(.draft)
      case .subtitles: return completed(.fetch)
      case .download: return completed(.fetch) && (completed(.subtitles) || skipped(.subtitles))
      case .transcribe: return completed(.fetch) && completed(.download)
      case .save:
        if job.usesCodexCheckpoints {
          return [.prepare, .analyze, .draft, .review].allSatisfy(completed)
        }
        if job.isGeneration { return false }
        return completed(.fetch) && (completed(.subtitles) || completed(.transcribe))
      case .generate: return completed(.prepare)
      case .queued: return false
      }
    }
  }

  static func steps(for job: Job) -> [JobTimelineStep] {
    let plan = plan(for: job)
    var first: [JobStage: JobEvent] = [:]
    var last: [JobStage: JobEvent] = [:]
    var current: JobStage = .queued
    for event in job.eventHistory {
      let stage =
        event.stage.flatMap(JobStage.init(rawValue:))
        ?? (event.streamID == nil
          ? JobStage.detect(event.message, generation: job.isGeneration) : nil)
        ?? current
      guard plan.contains(where: { $0.0 == stage }) else { continue }
      if first[stage] == nil { first[stage] = event }
      last[stage] = event
      current = stage
    }
    if let recorded = job.currentStage.flatMap(JobStage.init(rawValue:)) { current = recorded }
    if job.isWaiting { current = .queued }
    if !job.hasExplicitStageStates && job.isFinished && !job.failed && !job.cancelled {
      current = .save
    }
    let currentIndex = plan.firstIndex(where: { $0.0 == current }) ?? 0
    let explicit = job.recordedStageStates
    return plan.enumerated().map { index, item in
      let status: TimelineStatus
      if job.hasExplicitStageStates {
        switch explicit[item.0.rawValue] {
        case "completed": status = .completed
        case "reused": status = .reused
        case "skipped": status = .skipped
        case "failed": status = .failed
        case "cancelled": status = .cancelled
        case "started", "active":
          status = index == currentIndex && job.failed ? .failed
            : index == currentIndex && job.cancelled ? .cancelled : .active
        default:
          if item.0 == .queued {
            status = job.isWaiting ? .active : .completed
          } else if index == currentIndex && (job.failed || job.cancelled) {
            status = job.failed ? .failed : .cancelled
          } else {
            status = .pending
          }
        }
      } else if index == currentIndex {
        status =
          job.failed ? .failed : job.cancelled ? .cancelled : job.isFinished ? .completed : .active
      } else if (item.0 == .queued && currentIndex > 0)
        || first[item.0] != nil || job.stageStarts?[item.0.rawValue] != nil
      {
        status = .completed
      } else {
        status = index < currentIndex ? .skipped : .pending
      }
      return JobTimelineStep(
        stage: item.0, title: item.1, status: status,
        date: job.stageStarts?[item.0.rawValue] ?? first[item.0]?.date
          ?? (item.0 == .queued ? job.createdAt : nil),
        message: index == currentIndex
          ? (job.message.isEmpty ? last[item.0]?.message : job.message) : nil)
    }
  }
}

struct TaskSourceGroup: Identifiable {
  let id: String
  let title: String
  let jobs: [Job]
  var accountingJobs: [Job]? = nil
  var unfinishedCount: Int { jobs.filter { !$0.isFinished }.count }
  var hasUnfinishedJobs: Bool { jobs.contains { !$0.isFinished } }
  var statusSummary: String {
    let completed = jobs.filter { $0.isFinished && !$0.failed && !$0.cancelled }.count
    let failed = jobs.filter { $0.isFinished && $0.failed }.count
    let cancelled = jobs.filter { $0.isFinished && $0.cancelled }.count
    var parts: [String] = []
    if unfinishedCount > 0 { parts.append("进行中 \(unfinishedCount)") }
    parts.append("已完成 \(completed)/\(jobs.count)")
    if failed > 0 { parts.append("失败 \(failed)") }
    if cancelled > 0 { parts.append("已停止 \(cancelled)") }
    return parts.joined(separator: " · ")
  }

  static func groups(jobs: [Job], sources: [SourceRecord]) -> [TaskSourceGroup] {
    let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let jobsByID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var idsByURL: [String: Set<String>] = [:]
    for source in sources {
      idsByURL[SourceListItem.urlIdentity(source.url), default: []].insert(source.id)
    }
    for job in jobs where !job.isGeneration {
      if let sourceID = job.sourceID {
        idsByURL[SourceListItem.urlIdentity(job.input), default: []].insert(sourceID)
      }
    }
    func sourceID(_ job: Job) -> String? {
      if let id = job.sourceID { return id }
      guard !job.isGeneration,
        let ids = idsByURL[SourceListItem.urlIdentity(job.input)], ids.count == 1
      else { return nil }
      return ids.first
    }
    func groupID(_ job: Job) -> String {
      if let id = sourceID(job) { return "source:" + id }
      if !job.isGeneration { return "url:" + SourceListItem.urlIdentity(job.input) }
      var root = job
      var visited: Set<UUID> = [job.id]
      while let retryOf = root.retryOf, visited.insert(retryOf).inserted,
        let previous = jobsByID[retryOf], previous.isGeneration
      {
        if let id = previous.sourceID { return "source:" + id }
        root = previous
      }
      return "job:" + root.id.uuidString
    }
    var buckets: [String: [Job]] = [:]
    for job in jobs { buckets[groupID(job), default: []].append(job) }
    let result = buckets.map { id, items in
      let ordered = visibleJobs(items, jobsByID: jobsByID).sorted(by: jobComesFirst)
      let source = items.compactMap(sourceID).compactMap { sourcesByID[$0] }.first
      let title = source?.title ?? items.reversed().first(where: \.isGeneration)?.input ?? ordered[0].input
      return TaskSourceGroup(id: id, title: title, jobs: ordered, accountingJobs: items)
    }
    return result.sorted {
      let left = $0.jobs[0], right = $1.jobs[0]
      if rank(left) != rank(right) { return rank(left) < rank(right) }
      let lhs = activityDate(left), rhs = activityDate(right)
      if lhs == rhs { return $0.id < $1.id }
      return left.isFinished ? lhs > rhs : lhs < rhs
    }
  }

  private static func visibleJobs(_ jobs: [Job], jobsByID: [UUID: Job]) -> [Job] {
    let successes = jobs.enumerated().filter { _, job in
      job.isFinished && !job.failed && !job.cancelled
    }
    func sameTaskType(_ lhs: Job, _ rhs: Job) -> Bool {
      guard lhs.isGeneration == rhs.isGeneration else { return false }
      return !lhs.isGeneration
        || (lhs.generation?.mode ?? lhs.mode) == (rhs.generation?.mode ?? rhs.mode)
    }
    func retries(_ success: Job, failure: Job) -> Bool {
      var current = success
      var visited: Set<UUID> = [success.id]
      while let priorID = current.retryOf, visited.insert(priorID).inserted {
        if priorID == failure.id { return true }
        guard let prior = jobsByID[priorID] else { return false }
        current = prior
      }
      return false
    }
    return jobs.enumerated().compactMap { index, job in
      guard job.isFinished && job.failed else { return job }
      let superseded = successes.contains { successIndex, success in
        guard sameTaskType(job, success) else { return false }
        if retries(success, failure: job) { return true }
        if let created = job.createdAt, let succeeded = success.createdAt, created != succeeded {
          return succeeded > created
        }
        return successIndex > index
      }
      return superseded ? nil : job
    }
  }

  private static func rank(_ job: Job) -> Int { job.isFinished ? 2 : job.isWaiting ? 1 : 0 }
  private static func activityDate(_ job: Job) -> Date {
    job.finishedAt ?? job.startedAt ?? job.createdAt ?? .distantPast
  }
  private static func jobComesFirst(_ lhs: Job, _ rhs: Job) -> Bool {
    if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
    let left = activityDate(lhs), right = activityDate(rhs)
    if left == right { return lhs.id.uuidString < rhs.id.uuidString }
    return lhs.isFinished ? left > right : left < right
  }
}

extension Job {
  var taskTypeTitle: String {
    guard isGeneration else { return "采集原文" }
    return ["markdown": "图文笔记", "html": "看板", "image": "概览图"][generation?.mode ?? mode ?? ""] ?? "生成内容"
  }
  var taskTypeIcon: String {
    guard isGeneration else { return "arrow.down.doc" }
    return ["markdown": "doc.richtext", "html": "rectangle.3.group", "image": "photo"][generation?.mode ?? mode ?? ""] ?? "sparkles"
  }
}

struct TaskRetryOption: Identifiable, Equatable {
  let id: String
  let title: String
  let stage: JobStage?

  static func options(for job: Job, stages: [JobTimelineStep]) -> [TaskRetryOption] {
    var options: [TaskRetryOption] = []
    if job.isFinished && (job.failed || job.cancelled || stages.isEmpty) {
      options.append(TaskRetryOption(
        id: "continue", title: job.failed || job.cancelled ? "继续处理" : "重新处理", stage: nil))
    }
    options += stages.map { TaskRetryOption(id: $0.stage.rawValue, title: "从「\($0.title)」重新处理", stage: $0.stage) }
    return options
  }
}

struct TaskRetryConfirmationState {
  var isPresented = false
  var selection = ""

  mutating func request(options: [TaskRetryOption], stage: JobStage? = nil) {
    guard let first = options.first else { return }
    selection = stage.flatMap { value in options.first { $0.stage == value }?.id } ?? first.id
    isPresented = true
  }
  mutating func cancel() { isPresented = false }
  mutating func confirm(options: [TaskRetryOption], perform: (JobStage?) -> Void) {
    guard isPresented, let choice = options.first(where: { $0.id == selection }) else { return }
    isPresented = false
    perform(choice.stage)
  }
}

struct QueuePanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject var queue: QueueState
  private var groups: [TaskSourceGroup] { TaskSourceGroup.groups(jobs: queue.jobs, sources: model.sources) }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("任务").font(.headline)
        Spacer()
        if queue.running > 0 {
          Text("\(queue.running)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 16).padding(.vertical, 12)
      Divider()
      if queue.jobs.isEmpty {
        ContentUnavailableView("暂无任务", systemImage: "checklist")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
              TaskSourceGroupCard(group: group, model: model)
            }
          }.padding(12)
        }
      }
    }.accessibilityIdentifier("task-sidebar")
  }
}

struct TaskSourceGroupCard: View {
  let group: TaskSourceGroup
  let model: AppModel
  @State private var expanded: Bool

  init(group: TaskSourceGroup, model: AppModel) {
    self.group = group
    self.model = model
    _expanded = State(initialValue: group.hasUnfinishedJobs)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(spacing: 0) {
        ForEach(Array(group.jobs.enumerated()), id: \.element.id) { index, job in
          if index > 0 { Divider().padding(.horizontal, 8) }
          TaskTimelineCard(
            job: job, cancel: { model.cancelJob(job.id) }, retry: { model.retry(job) },
            retryFromStage: { model.retry(job, from: $0) }, grouped: true)
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(group.title).font(.callout.weight(.semibold)).lineLimit(2)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(group.statusSummary)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .help(group.statusSummary)
          TaskMetricsView(jobs: group.accountingJobs ?? group.jobs, grouped: true)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
    }.disclosureGroupStyle(TaskDisclosureStyle())
      .padding(8).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
      .accessibilityIdentifier("task-source-group")
      .onChange(of: group.hasUnfinishedJobs) { _, unfinished in expanded = unfinished }
  }
}

struct TaskMetricsView: View {
  let jobs: [Job]
  var grouped = false

  var body: some View {
    Group {
      if jobs.contains(where: { !$0.isFinished && !$0.isWaiting }) {
        TimelineView(.periodic(from: .now, by: 1)) { context in line(at: context.date) }
      } else {
        line(at: Date())
      }
    }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      .accessibilityIdentifier(grouped ? "task-group-metrics" : "task-metrics")
  }

  private func line(at date: Date) -> some View {
    let summary = grouped ? TaskMetricSummary.group(jobs, now: date)
      : jobs.first?.metricSummary(now: date) ?? TaskMetricSummary(seconds: nil, tokens: nil)
    return HStack(spacing: 6) {
      Label(summary.durationText, systemImage: "clock")
        .help(grouped ? "实际处理耗时，并行时段合并计算" : "实际执行耗时")
      Text(summary.tokenText)
        .accessibilityLabel("\(summary.tokenText) tokens")
        .help(summary.tokens == nil ? "尚无用量记录"
          : summary.partialTokens ? "已记录的用量，另有任务尚无完整记录"
          : "模型报告的输入与输出 token，按会话去重")
    }.accessibilityElement(children: .combine)
  }
}

struct TaskTimelineCard: View {
  let job: Job
  let cancel: () -> Void
  let retry: () -> Void
  var retryFromStage: ((JobStage) -> Void)? = nil
  var grouped = false
  @State private var detailsExpanded: Bool
  @State private var logsExpanded = false
  @State private var showConfiguration = false
  @State private var retryConfirmation = TaskRetryConfirmationState()

  init(
    job: Job, cancel: @escaping () -> Void, retry: @escaping () -> Void,
    retryFromStage: ((JobStage) -> Void)? = nil, initiallyExpanded: Bool = false, grouped: Bool = false
  ) {
    self.job = job
    self.cancel = cancel
    self.retry = retry
    self.retryFromStage = retryFromStage
    self.grouped = grouped
    _detailsExpanded = State(initialValue: initiallyExpanded)
  }

  private var steps: [JobTimelineStep] { JobTimelineStep.steps(for: job) }
  private var currentStep: JobTimelineStep? {
    if job.isWaiting { return steps.first }
    return steps.first { $0.stage.rawValue == job.currentStage }
      ?? steps.first { [.active, .failed, .cancelled].contains($0.status) }
      ?? steps.last { $0.status != .pending }
  }
  private var retryStages: [JobTimelineStep] {
    retryFromStage == nil ? [] : JobTimelineStep.retryStages(for: job)
  }
  private var retryOptions: [TaskRetryOption] { TaskRetryOption.options(for: job, stages: retryStages) }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Label(job.taskTypeTitle, systemImage: job.taskTypeIcon).font(.callout.weight(.medium))
        Text(job.state).font(.caption.weight(.semibold))
          .foregroundStyle(job.failed ? Color.orange : Color.secondary)
        Spacer()
        if !retryOptions.isEmpty {
          Button {
            retryConfirmation.request(options: retryOptions)
          } label: {
            Text("重新处理").font(.caption).modifier(DarkReadableAction())
              .padding(.horizontal, 6).frame(minHeight: 28).contentShape(Rectangle())
          }.buttonStyle(.plain).fixedSize()
            .help("选择重新处理的阶段").accessibilityIdentifier("task-retry-button")
        }
        if job.isGeneration {
          Button { showConfiguration = true } label: {
            Image(systemName: "info.circle").font(.system(size: 14))
              .modifier(DarkReadableAction()).frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }.buttonStyle(.plain)
            .help("查看生成配置").accessibilityLabel("查看生成配置")
            .accessibilityIdentifier("task-configuration-button")
            .popover(isPresented: $showConfiguration, arrowEdge: .trailing) {
              TaskConfigurationView(job: job)
            }
        }
        if !job.isFinished {
          Button(action: cancel) {
            Image(systemName: "stop.circle").font(.system(size: 14))
              .modifier(DarkReadableAction()).frame(width: 32, height: 32)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
            .help(job.generationBatchID != nil && !job.isWaiting ? "停止联合生成" : "停止任务")
            .accessibilityLabel(job.generationBatchID != nil && !job.isWaiting ? "停止联合生成" : "停止任务")
        }
      }
      if !grouped { Text(job.input).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled) }
      DisclosureGroup(isExpanded: $detailsExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          VStack(spacing: 0) {
            let visible = job.isWaiting ? Array(steps.prefix(1)) : steps
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, step in
              timelineRow(step, last: index == visible.count - 1)
                .contextMenu {
                  if retryStages.contains(where: { $0.stage == step.stage }) {
                    Button("从「\(step.title)」重新处理") {
                      retryConfirmation.request(options: retryOptions, stage: step.stage)
                    }
                  }
                }
            }
          }
          if !job.eventHistory.isEmpty {
            DisclosureGroup("执行日志", isExpanded: $logsExpanded) {
              LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(job.eventHistory) { event in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(event.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                      .foregroundStyle(.tertiary)
                    Text(event.message).textSelection(.enabled)
                  }.font(.caption)
                }
              }
            }.font(.caption).foregroundStyle(.secondary)
              .disclosureGroupStyle(TaskDisclosureStyle())
              .accessibilityIdentifier("task-log-disclosure")
          }
        }
      } label: {
        if detailsExpanded {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("处理详情").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TaskMetricsView(jobs: [job])
          }
        } else {
          summary
        }
      }.disclosureGroupStyle(TaskDisclosureStyle())
        .accessibilityIdentifier("task-details-disclosure")
    }.padding(grouped ? 8 : 10)
      .background(.quaternary.opacity(grouped ? 0 : 0.2), in: RoundedRectangle(cornerRadius: 12))
      .sheet(isPresented: $retryConfirmation.isPresented) {
        VStack(alignment: .leading, spacing: 16) {
          Text("重新处理\(job.taskTypeTitle)").font(.headline)
          Text(job.input).font(.callout).lineLimit(2)
          Picker("处理方式", selection: $retryConfirmation.selection) {
            ForEach(retryOptions) { option in Text(option.title).tag(option.id) }
          }.pickerStyle(.radioGroup)
          if !job.isFinished {
            Text(job.generationBatchID != nil && !job.isWaiting
              ? "确认后会停止本次联合生成，再单独重新处理\(job.taskTypeTitle)。"
              : "确认后会停止当前任务，并按所选阶段重新处理。")
              .font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Spacer()
            Button("取消") { retryConfirmation.cancel() }.keyboardShortcut(.cancelAction)
              .accessibilityIdentifier("task-retry-cancel")
            Button("确认重新处理") {
              retryConfirmation.confirm(options: retryOptions) { stage in
                if let stage { retryFromStage?(stage) } else { retry() }
              }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
              .disabled(!retryOptions.contains { $0.id == retryConfirmation.selection })
              .accessibilityIdentifier("task-retry-confirm")
          }
        }.padding(22).frame(width: 380)
          .accessibilityIdentifier("task-retry-confirmation")
      }
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: 8) {
      if let step = currentStep {
        Image(systemName: icon(step.status)).font(.system(size: 13, weight: .medium))
          .foregroundStyle(color(step.status)).frame(width: 16, height: 18)
      }
      VStack(alignment: .leading, spacing: 3) {
        let message = job.message.isEmpty ? currentStep?.message : job.message
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(currentStep?.title ?? job.state).font(.callout.weight(.medium))
          if message?.isEmpty != false { TaskMetricsView(jobs: [job]) }
        }
        if let message, !message.isEmpty {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message).font(.caption)
              .foregroundStyle(job.failed ? Color.orange : Color.secondary)
              .lineLimit(job.failed ? 3 : 1).help(message)
            TaskMetricsView(jobs: [job])
              .fixedSize(horizontal: true, vertical: false)
          }
        }
      }
    }
  }
  private func timelineRow(_ step: JobTimelineStep, last: Bool) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: icon(step.status)).font(.system(size: 13, weight: .medium))
        .foregroundStyle(color(step.status)).frame(width: 16, height: 18)
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(step.title).font(.callout.weight(step.status == .active ? .semibold : .regular))
          Spacer(minLength: 4)
          if step.status == .reused {
            Text("已复用").font(.caption2).foregroundStyle(.secondary)
          } else if step.status == .skipped {
            Text("已跳过").font(.caption2).foregroundStyle(.tertiary)
          } else if let date = step.date, step.status != .pending {
            Text(date, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
        }
        if let message = step.message, !message.isEmpty,
          [.active, .failed, .cancelled].contains(step.status)
        {
          Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(
            .enabled)
        }
      }.foregroundStyle(
        step.status == .pending || step.status == .skipped ? Color.secondary : Color.primary)
    }.padding(.bottom, last ? 0 : 14)
      .background(alignment: .topLeading) {
        if !last {
          Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 1)
            .padding(.top, 18).padding(.leading, 7.5)
        }
      }
  }
  private func icon(_ status: TimelineStatus) -> String {
    switch status {
    case .completed: "checkmark.circle.fill"
    case .reused: "arrow.triangle.2.circlepath.circle.fill"
    case .active: "circle.inset.filled"
    case .failed: "exclamationmark.circle.fill"
    case .cancelled: "stop.circle"
    case .skipped: "minus.circle"
    case .pending: "circle"
    }
  }
  private func color(_ status: TimelineStatus) -> Color {
    switch status {
    case .active: .accentColor
    case .completed, .reused: .secondary
    case .failed: .orange
    case .pending, .skipped, .cancelled: .secondary.opacity(0.6)
    }
  }
}

private struct TaskDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          configuration.label
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
            .foregroundStyle(.secondary).frame(width: 20, height: 20)
        }.padding(.horizontal, 4).padding(.vertical, 4)
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
          .contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
      if configuration.isExpanded { configuration.content }
    }
  }
}
