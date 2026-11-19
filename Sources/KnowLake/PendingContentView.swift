import SwiftUI

enum ReaderGenerationState {
  static func job(sourceID: String, mode: String, jobs: [Job]) -> Job? {
    let matching = jobs.filter {
      $0.isGeneration && $0.sourceID == sourceID && ($0.generation?.mode ?? $0.mode) == mode
    }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    return matching.last(where: { !$0.isFinished && !$0.isWaiting && !$0.cancelled })
      ?? matching.last(where: { !$0.isFinished && !$0.cancelled }) ?? matching.last
  }

  static func hasVisibleProgress(sourceID: String, mode: String, jobs: [Job]) -> Bool {
    guard let job = job(sourceID: sourceID, mode: mode, jobs: jobs) else { return false }
    return !job.isFinished || job.failed || job.cancelled
  }

  static func title(for mode: String) -> String {
    ["markdown": "图文笔记", "html": "看板", "image": "概览图"][mode] ?? "内容"
  }
}

struct PendingContentView: View {
  let model: AppModel
  @ObservedObject var queue: QueueState
  var sourceID: String? = nil
  var mode: String? = nil
  var acquisitionID: UUID? = nil

  private var job: Job? {
    if let sourceID, let mode {
      return ReaderGenerationState.job(sourceID: sourceID, mode: mode, jobs: queue.jobs)
    }
    return queue.jobs.first { $0.id == acquisitionID }
  }

  private func title(_ job: Job) -> String {
    let subject = mode.map(ReaderGenerationState.title) ?? "资料"
    if job.failed { return subject + "处理失败" }
    if job.cancelled { return job.isFinished ? subject + "已停止" : "正在停止" + subject + "处理" }
    if job.isFinished { return subject + "已完成" }
    if job.isWaiting { return subject + "等待处理" }
    return mode == nil ? "正在获取资料" : "正在生成" + subject
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let job {
          HStack(spacing: 10) {
            if !job.isFinished { ProgressView().controlSize(.small) }
            Text(title(job)).font(.title2.weight(.semibold))
          }
          TaskTimelineCard(
            job: job, cancel: { model.cancelJob(job.id) }, retry: { model.retry(job) },
            retryFromStage: { model.retry(job, from: $0) }, initiallyExpanded: true)
            .id(job.id)
        } else {
          ContentUnavailableView("暂无处理任务", systemImage: "clock")
        }
      }.frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 28).padding(.top, sourceID == nil ? 28 : 76).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }.background(Color(nsColor: .textBackgroundColor))
      .accessibilityIdentifier(mode == nil ? "acquisition-progress" : "generation-progress")
  }
}
