import Darwin
import Foundation

actor JobHistoryStore {
  private struct Document: Codable {
    let version: Int
    let jobs: [Job]
  }

  private var savedRevisions: [String: Int] = [:]

  func load(root: String) throws -> [Job] {
    var jobs = try document(at: fileURL(root: root))?.jobs ?? []
    for index in jobs.indices where jobs[index].metrics == nil {
      guard let runID = jobs[index].checkpointRunID else { continue }
      let path = URL(fileURLWithPath: root).appendingPathComponent("runs/\(runID.uuidString)/codex-run.json")
      guard let data = try? Data(contentsOf: path),
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      var metrics: TaskMetrics
      if record["reused_run_status"] != nil {
        metrics = TaskMetrics(tokenUsage: [:])
      } else if let value = record["task_metrics"],
        let data = try? JSONSerialization.data(withJSONObject: value),
        let saved = try? JSONDecoder().decode(TaskMetrics.self, from: data) {
        metrics = saved
      } else if let id = record["thread_id"] as? String,
        let value = record["usage"] as? [String: Any], let tokens = TokenUsage.parse(value) {
        metrics = record["usage_scope"] as? String == "shared_batch"
          ? TaskMetrics(sharedTokenUsage: [id: tokens]) : TaskMetrics(tokenUsage: [id: tokens])
      } else { continue }
      if let start = jobs[index].startedAt {
        metrics.workPeriods = [TaskWorkPeriod(start: start,
          end: jobs[index].finishedAt ?? jobs[index].eventHistory.last?.date ?? start)]
      }
      jobs[index].metrics = metrics
    }
    return jobs
  }

  func save(_ jobs: [Job], root: String, revision: Int) throws {
    let destination = fileURL(root: root)
    let key = destination.path
    if let saved = savedRevisions[key], revision < saved { return }
    // Validate before replacing so unreadable or newer history stays recoverable.
    _ = try document(at: destination)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(Document(version: 1, jobs: jobs))
    let directory = destination.deletingLastPathComponent()
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".tasks-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard rename(temporary.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      savedRevisions[key] = revision
    } catch {
      try? handle.close()
      try? manager.trashItem(at: temporary, resultingItemURL: nil)
      throw error
    }
  }

  private func fileURL(root: String) -> URL {
    URL(fileURLWithPath: root, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("tasks.json")
  }

  private func document(at url: URL) throws -> Document? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.version == 1 else {
      throw LakeError.message("tasks.json 的版本不受支持：\(document.version)")
    }
    return document
  }
}
