import Darwin
import Foundation

struct EngineProgress: Sendable {
  let message: String
  let stage: String?
  let status: String?
  let artifacts: [String]?
  var usage: TokenUsage? = nil
  var usageID: String? = nil
}

/// One request per process. Blocking pipe reads never run on the main actor.
final class EngineClient: @unchecked Sendable {
  private let lock = NSLock()
  private var processes: [UUID: EngineProcessRecord] = [:]
  private var scheduled: Set<UUID> = []
  private var cancelled: Set<UUID> = []
  private var isShuttingDown = false
  private let runtime: EngineRuntime
  var python: URL { runtime.python }

  init(directory overrideDirectory: URL? = nil, python overridePython: URL? = nil, bundle: Bundle = .main) {
    let resources = bundle.resourceURL!
    #if DEBUG
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    #else
    let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    #endif
    runtime = EngineRuntime.resolve(
      resources: resources,
      sourceEngine: source.appendingPathComponent("engine"),
      applicationSupport: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0],
      runtimeID: bundle.object(forInfoDictionaryKey: "KnowLakeRuntimeID") as? String,
      directoryOverride: overrideDirectory,
      pythonOverride: overridePython)
  }

  func request<T: Decodable>(
    action: String, root: String, params: [String: Any] = [:], id: UUID = UUID(),
    onProgress: (@Sendable (EngineProgress) -> Void)? = nil,
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> T {
    let input =
      try JSONSerialization.data(withJSONObject: ["action": action, "root": root, "params": params])
      + Data([10])
    let data: Data = try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          lock.lock()
          if isShuttingDown {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
          }
          scheduled.insert(id)
          lock.unlock()
          DispatchQueue.global(qos: .utility).async { [self] in
            defer {
              lock.lock()
              scheduled.remove(id)
              cancelled.remove(id)
              lock.unlock()
            }
            do {
              continuation.resume(
                returning: try execute(input, id: id, onProgress: onProgress, progress: progress))
            } catch { continuation.resume(throwing: error) }
          }
        }
      }, onCancel: { self.cancel(id) })
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func execute(
    _ input: Data, id: UUID,
    onProgress: (@Sendable (EngineProgress) -> Void)?,
    progress: @escaping @Sendable (String) -> Void
  )
    throws -> Data
  {
    try runtime.validatePython()
    let process = Process()
    process.executableURL = runtime.python
    process.arguments = ["-m", "knowlake_engine"]
    process.currentDirectoryURL = runtime.directory
    process.environment = runtime.environment(inheriting: ProcessInfo.processInfo.environment)
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let errors = ErrorBuffer()
    stderr.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData)
    }
    lock.lock()
    if isShuttingDown || cancelled.contains(id) {
      lock.unlock()
      stderr.fileHandleForReading.readabilityHandler = nil
      throw CancellationError()
    }
    do { try process.run() } catch {
      lock.unlock()
      stderr.fileHandleForReading.readabilityHandler = nil
      throw error
    }
    let record = EngineProcessRecord(process: process)
    processes[id] = record
    lock.unlock()
    defer {
      stderr.fileHandleForReading.readabilityHandler = nil
      lock.lock()
      processes.removeValue(forKey: id)
      lock.unlock()
      if let group = record.group { kill(-group, SIGTERM) }
    }
    try stdin.fileHandleForWriting.write(contentsOf: input)
    try stdin.fileHandleForWriting.close()
    var buffer = Data()
    var result: Data?
    var failure: String?
    while true {
      let chunk = stdout.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      buffer.append(chunk)
      while let end = buffer.firstIndex(of: 10) {
        let line = buffer.prefix(upTo: end)
        buffer.removeSubrange(...end)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let event = object["event"] as? String
        else { continue }
        let data = object["data"]
        if event == "result", let data {
          result = try JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed])
        } else if event == "error" {
          failure = (data as? String) ?? (data as? [String: Any])?["message"] as? String ?? "处理失败"
        } else if event == "progress" {
          let fields = data as? [String: Any]
          let message = (data as? String) ?? fields?["message"] as? String ?? "处理中"
          progress(message)
          onProgress?(
            EngineProgress(
              message: message, stage: fields?["stage"] as? String,
              status: fields?["status"] as? String,
              artifacts: fields?["artifacts"] as? [String],
              usage: (fields?["usage"] as? [String: Any]).flatMap(TokenUsage.parse),
              usageID: fields?["usage_run_id"] as? String))
        }
      }
    }
    process.waitUntilExit()
    lock.lock()
    let wasCancelled = cancelled.contains(id)
    lock.unlock()
    if wasCancelled { throw CancellationError() }
    if let failure { throw LakeError.message(failure) }
    guard process.terminationStatus == 0, let result else {
      throw LakeError.message(
        errors.text.isEmpty ? "处理进程意外结束（\(process.terminationStatus)）" : errors.text)
    }
    return result
  }
  func cancel(_ id: UUID) {
    lock.lock()
    cancelled.insert(id)
    let p = processes[id]
    lock.unlock()
    if let p { terminateSoon([p]) }
  }
  func cancelAll() {
    lock.lock()
    cancelled.formUnion(scheduled)
    let active = Array(processes.values)
    lock.unlock()
    terminateSoon(active)
  }

  /// Shutdown is permanent for this client. It includes requests queued on the
  /// dispatch pool, and waits for termination before AppKit exits the host.
  func shutdown() async {
    let active = beginShutdown()
    let targets = await Task.detached(priority: .userInitiated) {
      EngineTerminationTargets(active)
    }.value
    targets.signal(SIGTERM)
    for _ in 0..<25 {
      if !targets.hasLiveProcesses { return }
      try? await Task.sleep(nanoseconds: 40_000_000)
    }
    targets.signal(SIGKILL)
    for _ in 0..<10 {
      if !targets.hasLiveProcesses { return }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func beginShutdown() -> [EngineProcessRecord] {
    lock.lock()
    defer { lock.unlock() }
    isShuttingDown = true
    cancelled.formUnion(scheduled)
    return Array(processes.values)
  }

  private func terminateSoon(_ active: [EngineProcessRecord]) {
    guard !active.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let targets = EngineTerminationTargets(active)
      targets.signal(SIGTERM)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        if targets.hasLiveProcesses { targets.signal(SIGKILL) }
      }
    }
  }
}

private struct EngineProcessRecord: @unchecked Sendable {
  let process: Process
  let group: pid_t?
  init(process: Process) {
    self.process = process
    let pid = process.processIdentifier
    group = getpgid(pid) == pid && pid != getpgrp() ? pid : nil
  }
}

/// Browsers may create a separate process group. Capture descendants before
/// stopping their parent, so cancellation also reaches those subprocesses.
private struct EngineTerminationTargets: @unchecked Sendable {
  let records: [EngineProcessRecord]
  let descendants: Set<pid_t>

  init(_ records: [EngineProcessRecord]) {
    self.records = records
    let roots = Set(records.filter { $0.process.isRunning }.map { $0.process.processIdentifier })
    guard !roots.isEmpty else {
      descendants = []
      return
    }
    let query = Process()
    query.executableURL = URL(fileURLWithPath: "/bin/ps")
    query.arguments = ["-axo", "pid=,ppid="]
    let output = Pipe()
    query.standardOutput = output
    query.standardError = FileHandle.nullDevice
    do {
      try query.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      query.waitUntilExit()
      let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        line -> (pid_t, pid_t)? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else {
          return nil
        }
        return (pid, parent)
      }
      var found = roots
      var previous = -1
      while found.count != previous {
        previous = found.count
        for (pid, parent) in rows where found.contains(parent) { found.insert(pid) }
      }
      descendants = found.subtracting(roots)
    } catch { descendants = [] }
  }

  func signal(_ value: Int32) {
    for record in records {
      if let group = record.group {
        kill(-group, value)
      } else if record.process.isRunning {
        kill(record.process.processIdentifier, value)
      }
    }
    for pid in descendants { kill(pid, value) }
  }

  var hasLiveProcesses: Bool {
    records.contains { $0.process.isRunning }
      || records.contains { $0.group.map { kill(-$0, 0) == 0 } ?? false }
      || descendants.contains { kill($0, 0) == 0 }
  }
}
private final class ErrorBuffer: @unchecked Sendable {
  let lock = NSLock()
  var buffer = Data()
  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    if buffer.count > 8192 { buffer = buffer.suffix(8192) }
  }
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: buffer, as: UTF8.self)
  }
}
