import Foundation

/// Tracks per-thread snapshots. Forked children exclude the parent's inherited counters.
struct CodexUsageTracker {
  let rootID: String
  let requests: [CodexRequest]
  private(set) var children: Set<String> = []
  private var modes: [String: String] = [:]
  private var rawUsage: [String: TokenUsage] = [:]
  private var baselines: [String: TokenUsage] = [:]
  private var spawnBaselines: [String: TokenUsage] = [:]
  private var inheritedBaselines: [String: TokenUsage] = [:]
  private var periods: [String: TaskWorkPeriod] = [:]

  init(rootID: String, requests: [CodexRequest]) {
    self.rootID = rootID
    self.requests = requests
    baselines[rootID] = TokenUsage()
  }

  private func mode(in text: String) -> String? {
    let matches = requests.filter {
      text.contains("KNOWLAKE_OUTPUT_MODE=\($0.mode)") || text.contains($0.outputDirectory)
    }
    return matches.count == 1 ? matches[0].mode : nil
  }

  private mutating func register(_ id: String, mode: String?, baseline: TokenUsage?, at date: Date) {
    guard id != rootID else { return }
    children.insert(id)
    if let mode { modes[id] = mode }
    if inheritedBaselines[id] == nil { inheritedBaselines[id] = baseline ?? rawUsage[rootID] ?? TokenUsage() }
    if periods[id] == nil { periods[id] = TaskWorkPeriod(start: date) }
  }

  mutating func metadata(_ thread: [String: Any]) {
    guard let id = thread["id"] as? String, children.contains(id) else { return }
    if let parent = thread["forkedFromId"] as? String, parent == rootID {
      baselines[id] = inheritedBaselines[id]
    } else if thread["forkedFromId"] is NSNull {
      baselines[id] = TokenUsage()
    }
    if let source = thread["source"] as? [String: Any],
      let sub = source["subAgent"] as? [String: Any],
      let spawn = sub["thread_spawn"] as? [String: Any],
      let path = spawn["agent_path"] as? String,
      let name = path.split(separator: "/").last.map(String.init),
      requests.contains(where: { $0.mode == name }) {
      modes[id] = name
    }
  }

  mutating func consume(method: String, params: [String: Any], now: Date = Date()) -> Set<String> {
    let before = children
    let threadID = params["threadId"] as? String
    if method == "thread/started", let thread = params["thread"] as? [String: Any],
      thread["parentThreadId"] as? String == rootID, let id = thread["id"] as? String {
      register(id, mode: nil, baseline: nil, at: now)
      metadata(thread)
    }
    if threadID == rootID, method == "item/started" || method == "item/completed",
      let item = params["item"] as? [String: Any] {
      if item["type"] as? String == "collabAgentToolCall", item["tool"] as? String == "spawnAgent" {
        let callID = item["id"] as? String ?? ""
        if method == "item/started" { spawnBaselines[callID] = rawUsage[rootID] ?? TokenUsage() }
        if method == "item/completed", item["status"] as? String == "completed" {
          let mode = (item["prompt"] as? String).flatMap { self.mode(in: $0) }
          for child in item["receiverThreadIds"] as? [String] ?? [] {
            register(child, mode: mode, baseline: spawnBaselines[callID], at: now)
          }
        }
      } else if item["type"] as? String == "subAgentActivity", let id = item["agentThreadId"] as? String {
        let name = (item["agentPath"] as? String)?.split(separator: "/").last.map(String.init)
        let mode = requests.first { $0.mode == name }?.mode
        register(id, mode: mode, baseline: nil, at: now)
        if item["kind"] as? String == "completed" || item["kind"] as? String == "interrupted" {
          periods[id]?.end = now
        }
      }
    }
    if let threadID, threadID == rootID || children.contains(threadID) {
      if method == "thread/tokenUsage/updated", let value = params["tokenUsage"] as? [String: Any],
        let usage = TokenUsage.parse(value) {
        rawUsage[threadID] = usage
      }
      if children.contains(threadID), let turn = params["turn"] as? [String: Any] {
        if method == "turn/started" {
          let start = (turn["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
          periods[threadID] = TaskWorkPeriod(start: periods[threadID]?.start ?? start ?? now)
        } else if method == "turn/completed" {
          let ended = (turn["completedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
          periods[threadID]?.end = ended ?? now
        }
      }
    }
    return children.subtracting(before)
  }

  func metrics(for mode: String, endedAt: Date? = nil) -> TaskMetrics {
    var own: [String: TokenUsage] = [:]
    var shared: [String: TokenUsage] = [:]
    var ownPeriods: [String: TaskWorkPeriod] = [:]
    for (id, value) in rawUsage {
      guard let baseline = baselines[id] else { continue }
      let usage = value.subtracting(baseline)
      if modes[id] == mode { own[id] = usage }
      else if id == rootID || modes[id] == nil { shared[id] = usage }
    }
    for (id, period) in periods where modes[id] == mode {
      var period = period
      if period.end == nil, let endedAt { period.end = endedAt }
      ownPeriods[id] = period
    }
    return TaskMetrics(agentPeriods: ownPeriods, tokenUsage: own.isEmpty ? nil : own,
      sharedTokenUsage: shared)
  }
}
