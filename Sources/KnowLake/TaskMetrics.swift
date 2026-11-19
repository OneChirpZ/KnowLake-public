import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
  var input: Int64 = 0
  var output: Int64 = 0
  var cachedInput: Int64 = 0
  var reasoningOutput: Int64 = 0
  var total: Int64 = 0

  static func parse(_ value: [String: Any]) -> TokenUsage? {
    let value = value["total"] as? [String: Any] ?? value
    func number(_ keys: String...) -> Int64? {
      keys.compactMap { (value[$0] as? NSNumber)?.int64Value }.first.map { max(0, $0) }
    }
    let input = number("inputTokens", "input_tokens", "prompt_tokens")
    let output = number("outputTokens", "output_tokens", "completion_tokens")
    let total = number("totalTokens", "total_tokens")
    guard input != nil || output != nil || total != nil else { return nil }
    return TokenUsage(
      input: input ?? 0, output: output ?? 0,
      cachedInput: number("cachedInputTokens", "cached_input_tokens") ?? 0,
      reasoningOutput: number("reasoningOutputTokens", "reasoning_output_tokens") ?? 0,
      total: total ?? ((input ?? 0) + (output ?? 0)))
  }

  func subtracting(_ baseline: TokenUsage) -> TokenUsage {
    TokenUsage(input: max(0, input - baseline.input), output: max(0, output - baseline.output),
      cachedInput: max(0, cachedInput - baseline.cachedInput),
      reasoningOutput: max(0, reasoningOutput - baseline.reasoningOutput),
      total: max(0, total - baseline.total))
  }

  func latest(_ other: TokenUsage) -> TokenUsage {
    TokenUsage(input: max(input, other.input), output: max(output, other.output),
      cachedInput: max(cachedInput, other.cachedInput),
      reasoningOutput: max(reasoningOutput, other.reasoningOutput), total: max(total, other.total))
  }
}

struct TaskWorkPeriod: Codable, Equatable, Sendable {
  var start: Date
  var end: Date?

  static func elapsed(_ periods: [TaskWorkPeriod], now: Date) -> TimeInterval {
    let sorted = periods.map { ($0.start, max($0.start, $0.end ?? now)) }.sorted { $0.0 < $1.0 }
    guard var current = sorted.first else { return 0 }
    var elapsed: TimeInterval = 0
    for period in sorted.dropFirst() {
      if period.0 <= current.1 {
        current.1 = max(current.1, period.1)
      } else {
        elapsed += current.1.timeIntervalSince(current.0)
        current = period
      }
    }
    return elapsed + current.1.timeIntervalSince(current.0)
  }
}

struct TaskMetrics: Codable, Equatable, Sendable {
  var workPeriods: [TaskWorkPeriod] = []
  var agentPeriods: [String: TaskWorkPeriod] = [:]
  // Each entry is a cumulative snapshot for one independent session, not an increment.
  // nil means unreported; an empty dictionary means no model call was needed.
  var tokenUsage: [String: TokenUsage]?
  var sharedTokenUsage: [String: TokenUsage] = [:]

  mutating func merge(_ update: TaskMetrics) {
    if let usage = update.tokenUsage {
      tokenUsage = (tokenUsage ?? [:]).merging(usage) { $0.latest($1) }
    }
    sharedTokenUsage.merge(update.sharedTokenUsage) { $0.latest($1) }
    agentPeriods.merge(update.agentPeriods) { _, latest in latest }
  }

  func snapshot(at date: Date) -> TaskMetrics {
    var result = self
    for index in result.workPeriods.indices where result.workPeriods[index].end == nil {
      result.workPeriods[index].end = date
    }
    for key in result.agentPeriods.keys where result.agentPeriods[key]?.end == nil {
      result.agentPeriods[key]?.end = date
    }
    return result
  }

  var json: [String: Any] {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any]) ?? [:]
  }
}

struct TaskMetricSummary {
  let seconds: TimeInterval?
  let tokens: Int64?
  var partialTokens = false

  var durationText: String {
    guard let seconds else { return "—" }
    let total = max(0, Int(seconds))
    if total >= 3600 { return "\(total / 3600)h\(total / 60 % 60)m\(total % 60)s" }
    return "\(total / 60)m\(total % 60)s"
  }
  var tokenText: String {
    guard let tokens else { return "—" }
    let value: String
    if tokens > 0 && tokens < 1_000 {
      value = "<0.001M"
    } else {
      value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(tokens) / 1_000_000)
        .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) + "M"
    }
    return partialTokens ? value + "+" : value
  }

  static func group(_ jobs: [Job], now: Date) -> TaskMetricSummary {
    var usage: [String: TokenUsage] = [:]
    var periods: [TaskWorkPeriod] = []
    var reported = false
    var incomplete = false
    for job in jobs {
      periods += job.workPeriods
      if !job.isGeneration { continue }
      if let own = job.metrics?.tokenUsage {
        reported = true
        usage.merge(own) { $0.latest($1) }
      } else if job.startedAt != nil || job.isFinished {
        incomplete = true
      }
      if let shared = job.metrics?.sharedTokenUsage, !shared.isEmpty {
        reported = true
        usage.merge(shared) { $0.latest($1) }
      }
    }
    return TaskMetricSummary(
      seconds: periods.isEmpty ? nil : TaskWorkPeriod.elapsed(periods, now: now),
      tokens: reported || !jobs.contains(where: \.isGeneration) ? usage.values.reduce(0) { $0 + $1.total } : nil,
      partialTokens: incomplete)
  }
}

extension Job {
  var workPeriods: [TaskWorkPeriod] {
    if let periods = metrics?.workPeriods, !periods.isEmpty { return periods }
    guard let startedAt else { return [] }
    // A legacy finished task without an end time has no trustworthy duration.
    guard !isFinished || finishedAt != nil else { return [] }
    return [TaskWorkPeriod(start: startedAt, end: finishedAt)]
  }

  func metricSummary(now: Date) -> TaskMetricSummary {
    let periods = metrics?.agentPeriods.isEmpty == false ? Array(metrics!.agentPeriods.values) : workPeriods
    return TaskMetricSummary(
      seconds: periods.isEmpty ? nil : TaskWorkPeriod.elapsed(periods, now: isFinished ? finishedAt ?? now : now),
      tokens: isGeneration ? metrics?.tokenUsage?.values.reduce(0) { $0 + $1.total } : 0)
  }
}
