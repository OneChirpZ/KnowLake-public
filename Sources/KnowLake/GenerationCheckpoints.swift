import CryptoKit
import Darwin
import Foundation

/// On-disk handoff between one uninterrupted Codex turn and the application.
/// Agent-owned markers are tiny receipts, never progress parsed from source or stdout.
struct GenerationCheckpoints: Sendable {
  static let stages = ["analyze", "draft", "review"]
  static let allStages = ["prepare", "analyze", "draft", "review", "save"]
  static let sourceName = "source-snapshot.md"
  static let helperName = "checkpoint.py"
  // Version 3 requires source-image inspection before drafting in every output mode.
  static let schemaVersion = 3

  struct Context: Codable, Equatable, Sendable {
    let version: Int
    let sourceID: String
    let sourceSHA256: String
    let title: String
    let sourceURL: String
    let mode: String
    let model: String
    let style: String
    let depth: String
    let reasoningEffort: String
    let fingerprint: String
  }

  struct Marker: Codable, Sendable {
    let version: Int
    let stage: String
    let status: String
    let fingerprint: String
    let artifacts: [String]
    let sha256: [String: String]
  }

  let root: URL
  let context: Context
  let reusedStages: [String]
  let resumeMessage: String?

  var sourceURL: URL { root.appendingPathComponent(Self.sourceName) }
  var nextStage: String { Self.stages.dropFirst(reusedStages.count).first ?? "save" }
  var finalName: String { Self.finalName(mode: context.mode) }

  static func finalName(mode: String) -> String {
    switch mode {
    case "html": return "board.html"
    case "image": return "cover.png"
    default: return "note.md"
    }
  }

  static func artifacts(for stage: String, mode: String) -> [String] {
    switch stage {
    case "analyze": return ["analysis.md"]
    case "draft":
      switch mode {
      case "html": return ["draft.html"]
      case "image": return ["image-plan.md", "draft.png"]
      default: return ["draft.md"]
      }
    case "review": return [finalName(mode: mode)]
    case "save": return [finalName(mode: mode), "codex-run.json"]
    default: return []
    }
  }

  static func makeContext(_ request: CodexRequest, source: Data) throws -> Context {
    var inputs = [
      "source_id": request.sourceID, "source_sha256": digest(source), "title": request.title,
      "source_directory": request.sourceRoot.path,
      "source_url": request.sourceURL, "mode": request.mode, "model": request.model,
      "style": request.style, "depth": request.depth,
      "reasoning_effort": request.reasoningEffort?.isEmpty == false
        ? request.reasoningEffort! : "default",
      "protocol_version": String(schemaVersion),
    ]
    if GenerationVisualStyle.applies(to: request.mode) {
      inputs["visual_style"] = request.visualStyle.rawValue
    }
    let bytes = try JSONSerialization.data(withJSONObject: inputs, options: [.sortedKeys])
    return Context(
      version: schemaVersion, sourceID: request.sourceID, sourceSHA256: inputs["source_sha256"]!,
      title: request.title, sourceURL: request.sourceURL, mode: request.mode, model: request.model,
      style: request.style, depth: request.depth, reasoningEffort: inputs["reasoning_effort"]!,
      fingerprint: digest(bytes))
  }

  /// Creates a fresh attempt. The old directory is only read, never changed.
  static func prepare(_ request: CodexRequest) throws -> Self {
    if let stage = request.retryFrom, !Self.stages.contains(stage) && stage != "save" {
      throw CodexRuntimeError.message("不支持的重试阶段：\(stage)")
    }
    let source = try Data(contentsOf: URL(fileURLWithPath: request.contentPath))
    guard let text = String(data: source, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw CodexRuntimeError.message("来源正文为空或不是 UTF-8 文本。") }
    let context = try makeContext(request, source: source)
    let root = URL(fileURLWithPath: request.outputDirectory).standardizedFileURL
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    guard try manager.contentsOfDirectory(atPath: root.path).isEmpty else {
      throw CodexRuntimeError.message("生成目录已有文件，请使用新的任务目录。")
    }
    try manager.createDirectory(
      at: root.appendingPathComponent("checkpoints"), withIntermediateDirectories: true)
    try source.write(to: root.appendingPathComponent(sourceName), options: .atomic)
    try encode(context).write(
      to: root.appendingPathComponent("checkpoints/context.json"), options: .atomic)
    try Data(helperScript.utf8).write(to: root.appendingPathComponent(helperName), options: .atomic)

    var reused: [String] = []
    var message: String?
    if let previous = request.resumeDirectory {
      let oldRoot = URL(fileURLWithPath: previous).standardizedFileURL
      guard oldRoot.resolvingSymlinksInPath() != root.resolvingSymlinksInPath() else {
        throw CodexRuntimeError.message("重试必须使用新的任务目录。")
      }
      let old = Self(root: oldRoot, context: context, reusedStages: [], resumeMessage: nil)
      let valid = old.validStages()
      let requestedCount =
        request.retryFrom.flatMap { (Self.stages + ["save"]).firstIndex(of: $0) } ?? valid.count
      var count = min(valid.count, requestedCount)
      // A completed review without trustworthy run identity must go through review again.
      if count == Self.stages.count,
        old.runRecord() == nil
          || (manager.fileExists(
            atPath: oldRoot.appendingPathComponent("checkpoints/save.json").path)
            && !old.validMarker("save"))
      {
        count -= 1
      }
      for stage in valid.prefix(count) {
        do {
          guard old.validMarker(stage) else { break }
          let name = "checkpoints/\(stage).json"
          let markerData = try old.readFile(name, maximumBytes: 4096)
          let marker = try JSONDecoder().decode(Marker.self, from: markerData)
          guard marker.version == schemaVersion, marker.stage == stage,
            marker.status == "completed", marker.fingerprint == context.fingerprint,
            marker.artifacts == Self.artifacts(for: stage, mode: context.mode),
            Set(marker.sha256.keys) == Set(marker.artifacts)
          else { break }
          let candidate = root.appendingPathComponent(
            "checkpoints/reuse-\(stage)-\(UUID().uuidString)")
          try manager.createDirectory(at: candidate, withIntermediateDirectories: true)
          for artifact in marker.artifacts {
            try manager.copyItem(
              at: old.validArtifact(artifact), to: candidate.appendingPathComponent(artifact))
          }
          // Validate the bytes actually copied, rather than assuming the source
          // stayed unchanged while a backup or generation was writing it.
          guard
            marker.artifacts.allSatisfy({
              (try? Self.fileDigest($0, root: candidate)) == marker.sha256[$0]
            })
          else { break }
          for artifact in marker.artifacts {
            try manager.moveItem(
              at: candidate.appendingPathComponent(artifact),
              to: root.appendingPathComponent(artifact))
          }
          try markerData.write(to: root.appendingPathComponent(name), options: .atomic)
          reused.append(stage)
        } catch {
          message = "复用检查点时文件发生变化，将从\(label(stage))重新开始。"
          break
        }
      }
      count = reused.count
      if count == Self.stages.count, let record = old.runRecord() {
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
          .write(to: root.appendingPathComponent("codex-run.json"), options: .atomic)
      }
      let storedContext = (try? old.readFile("checkpoints/context.json", maximumBytes: 65_536))
        .flatMap { try? JSONDecoder().decode(Context.self, from: $0) }
      if let storedContext, storedContext != context {
        message = "来源或生成设置已变化，将重新分析。"
      } else if !old.matchesContext() || count < requestedCount {
        let stage = Self.stages[count]
        message = "前序检查点不完整，将从\(label(stage))重新开始。"
      }
    } else if let stage = request.retryFrom, stage != "analyze" {
      message = "前序检查点不完整，将从分析来源重新开始。"
    }
    return Self(root: root, context: context, reusedStages: reused, resumeMessage: message)
  }

  /// Returns only the contiguous, verified prefix for this exact source/configuration.
  static func reusableStages(in directory: String, for request: CodexRequest) throws -> [String] {
    let source = try Data(contentsOf: URL(fileURLWithPath: request.contentPath))
    let value = Self(
      root: URL(fileURLWithPath: directory), context: try makeContext(request, source: source),
      reusedStages: [], resumeMessage: nil)
    return value.validStages()
  }

  func matchesContext() -> Bool {
    guard let data = try? readFile("checkpoints/context.json", maximumBytes: 65_536),
      let stored = try? JSONDecoder().decode(Context.self, from: data), stored == context,
      let source = try? readFile(Self.sourceName, maximumBytes: nil)
    else { return false }
    return Self.digest(source) == context.sourceSHA256
  }

  func validStages() -> [String] {
    guard matchesContext() else { return [] }
    var result: [String] = []
    for stage in Self.stages {
      guard validMarker(stage) else { break }
      result.append(stage)
    }
    return result
  }

  func validMarker(_ stage: String) -> Bool {
    guard (Self.stages + ["save"]).contains(stage),
      let data = try? readFile("checkpoints/\(stage).json", maximumBytes: 4096),
      let marker = try? JSONDecoder().decode(Marker.self, from: data),
      marker.version == Self.schemaVersion,
      marker.stage == stage, marker.status == "completed",
      marker.fingerprint == context.fingerprint,
      marker.artifacts == Self.artifacts(for: stage, mode: context.mode),
      Set(marker.sha256.keys) == Set(marker.artifacts)
    else { return false }
    if stage == "save", runRecord()?["status"] as? String != "completed" { return false }
    return marker.artifacts.allSatisfy {
      (try? validArtifact($0)) != nil && (try? Self.fileDigest($0, root: root)) == marker.sha256[$0]
    }
  }

  func validArtifact(_ name: String) throws -> URL {
    let mode = name.hasSuffix(".png") ? "image" : (name.hasSuffix(".html") ? "html" : "markdown")
    let url = try Self.containedRegularFile(name, root: root)
    return try CodexRuntime.validateArtifact(url, root: root, mode: mode)
  }

  func runRecord() -> [String: Any]? {
    guard let data = try? readFile("codex-run.json", maximumBytes: 262_144),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      value["fingerprint"] as? String == context.fingerprint,
      value["source_id"] as? String == context.sourceID,
      value["mode"] as? String == context.mode,
      value["artifact"] as? String == finalName,
      let runID = value["run_id"] as? String, !runID.isEmpty,
      let model = value["model"] as? String, !model.isEmpty,
      let threadID = value["thread_id"] as? String, !threadID.isEmpty
    else { return nil }
    return value
  }

  func writeSaveMarker() throws {
    guard validStages().count == Self.stages.count,
      runRecord()?["status"] as? String == "completed"
    else {
      throw CodexRuntimeError.message("生成检查点或运行记录不完整，无法保存。")
    }
    let data = try Self.encode(makeMarker(for: "save"))
    try Self.writeOwnedFile(data, name: "checkpoints/save.json", root: root)
  }

  func makeMarker(for stage: String) throws -> Marker {
    let artifacts = Self.artifacts(for: stage, mode: context.mode)
    var hashes: [String: String] = [:]
    for name in artifacts {
      _ = try validArtifact(name)
      hashes[name] = try Self.fileDigest(name, root: root)
    }
    return Marker(
      version: Self.schemaVersion, stage: stage, status: "completed",
      fingerprint: context.fingerprint, artifacts: artifacts, sha256: hashes)
  }

  /// Hash one stable file descriptor and verify that its path still names the same file.
  /// A concurrent write/rename cannot silently produce a reusable partial checkpoint.
  static func fileDigest(_ name: String, root: URL) throws -> String {
    let url = try containedRegularFile(name, root: root)
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CodexRuntimeError.message("无法读取阶段产物。") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else { throw CodexRuntimeError.message("无法读取阶段产物信息。") }
    var hash = SHA256()
    var size: Int64 = 0
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hash.update(data: chunk)
      size += Int64(chunk.count)
    }
    var after = stat()
    var current = stat()
    guard fstat(descriptor, &after) == 0, lstat(url.path, &current) == 0,
      before.st_dev == current.st_dev, before.st_ino == current.st_ino,
      before.st_size == size, after.st_size == size, current.st_size == size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      after.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec,
      current.st_mode & S_IFMT == S_IFREG
    else { throw CodexRuntimeError.message("读取时阶段产物发生变化，请重新记录检查点。") }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Agent-created symlinks must not redirect application-owned writes.
  static func writeOwnedFile(_ data: Data, name: String, root: URL) throws {
    let destination = root.appendingPathComponent(name)
    let parent = destination.deletingLastPathComponent()
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else {
      throw CodexRuntimeError.message("检查点写入目录超出任务范围。")
    }
    try data.write(to: destination, options: .atomic)
  }

  func readFile(_ name: String, maximumBytes: Int?) throws -> Data {
    let url = try Self.containedRegularFile(name, root: root)
    if let maximumBytes {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
      guard data.count <= maximumBytes else {
        throw CodexRuntimeError.message("检查点文件过大。")
      }
      return data
    }
    return try Data(contentsOf: url)
  }

  static func containedRegularFile(_ name: String, root: URL) throws -> URL {
    let url = root.appendingPathComponent(name).standardizedFileURL
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let directory = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard resolved.path.hasPrefix(directory),
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) > 0
    else { throw CodexRuntimeError.message("检查点缺少有效的产物文件。") }
    return resolved
  }

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Kept beside the run so the agent records hashes with one local stdlib command.
  /// The application independently verifies every receipt; stdout is never progress.
  static let helperScript = #"""
    #!/usr/bin/env python3
    import hashlib
    import json
    import os
    from pathlib import Path
    import re
    import stat
    import sys
    import uuid

    ROOT = Path(__file__).resolve().parent
    STAGES = ['analyze', 'draft', 'review']
    VERSION = \#(schemaVersion)

    def regular_file(name):
        path = ROOT / name
        resolved = path.resolve()
        if not resolved.is_relative_to(ROOT) or path.is_symlink() or not path.is_file():
            raise ValueError('Invalid artifact path: ' + name)
        if path.stat().st_size <= 0:
            raise ValueError('Empty artifact: ' + name)
        return path

    def stable_read(name, limit=None, digest=False):
        path = regular_file(name)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'rb') as handle:
            before = os.fstat(handle.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise ValueError('Not a regular file: ' + name)
            if digest:
                value = hashlib.sha256()
                count = 0
                for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                    value.update(chunk)
                    count += len(chunk)
                result = value.hexdigest()
            else:
                result = handle.read(limit + 1 if limit is not None else -1)
                count = len(result)
                if limit is not None and count > limit:
                    raise ValueError('File exceeds size limit: ' + name)
            after = os.fstat(handle.fileno())
            current = path.lstat()
            identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            if identity(before) != identity(after) or identity(after) != identity(current) or count != after.st_size:
                raise ValueError('Artifact changed while reading: ' + name)
            return result

    def sha256(name):
        return stable_read(name, digest=True)

    def artifact_names(stage, mode):
        if stage == 'analyze': return ['analysis.md']
        if stage == 'draft':
            return {'markdown':['draft.md'], 'html':['draft.html'], 'image':['image-plan.md', 'draft.png']}[mode]
        return [{'markdown':'note.md', 'html':'board.html', 'image':'cover.png'}[mode]]

    def validate_format(name):
        if name.endswith('.png'):
            with regular_file(name).open('rb') as handle:
                if handle.read(8) != b'\x89PNG\r\n\x1a\n':
                    raise ValueError('Not a PNG: ' + name)
        else:
            text = stable_read(name, 32 * 1024 * 1024).decode('utf-8')
            if not text.strip(): raise ValueError('Empty text: ' + name)
            if name.endswith('.html') and not (re.search(r'<html(?:\s|>)', text, re.I) and re.search(r'</html\s*>', text, re.I)):
                raise ValueError('Incomplete HTML: ' + name)

    def validate_marker(stage, context):
        marker = json.loads(stable_read('checkpoints/' + stage + '.json', 4096))
        names = artifact_names(stage, context['mode'])
        if (marker.get('version') != VERSION or marker.get('stage') != stage
                or marker.get('status') != 'completed' or marker.get('fingerprint') != context['fingerprint']
                or marker.get('artifacts') != names or set(marker.get('sha256', {})) != set(names)):
            raise ValueError('Invalid predecessor checkpoint: ' + stage)
        for name in names:
            validate_format(name)
            if marker['sha256'][name] != sha256(name):
                raise ValueError('Predecessor artifact changed: ' + name)

    def write_checkpoint(stage):
        context = json.loads(stable_read('checkpoints/context.json', 65536))
        if context.get('version') != VERSION or context.get('mode') not in ['markdown', 'html', 'image']:
            raise ValueError('Unsupported checkpoint context')
        if sha256('source-snapshot.md') != context['sourceSHA256']:
            raise ValueError('The source snapshot changed')
        index = STAGES.index(stage)
        for previous in STAGES[:index]: validate_marker(previous, context)
        names = artifact_names(stage, context['mode'])
        hashes = {}
        for name in names:
            validate_format(name)
            hashes[name] = sha256(name)
        for previous in STAGES[:index]: validate_marker(previous, context)
        marker = {'version':VERSION, 'stage':stage, 'status':'completed',
                  'fingerprint':context['fingerprint'], 'artifacts':names, 'sha256':hashes}
        directory = ROOT / 'checkpoints'
        if directory.is_symlink() or not directory.resolve().is_relative_to(ROOT):
            raise ValueError('Invalid checkpoint directory')
        # Re-recording an earlier stage requires later work to be checked again.
        # Preserve superseded receipts instead of deleting them.
        for later in STAGES[index + 1:] + ['save']:
            previous = directory / (later + '.json')
            if previous.exists() or previous.is_symlink():
                archive = directory / 'superseded'
                if archive.is_symlink(): raise ValueError('Invalid receipt archive')
                archive.mkdir(exist_ok=True)
                os.replace(previous, archive / (later + '-' + uuid.uuid4().hex + '.json'))
        temporary = directory / ('.' + stage + '-' + uuid.uuid4().hex + '.tmp')
        with temporary.open('x', encoding='utf-8') as handle:
            json.dump(marker, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, directory / (stage + '.json'))
        print('Recorded ' + stage + ' checkpoint.')

    if __name__ == '__main__':
        try:
            if len(sys.argv) != 2 or sys.argv[1] not in STAGES:
                raise ValueError('Usage: python3 checkpoint.py analyze|draft|review')
            write_checkpoint(sys.argv[1])
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
    """#

  static func label(_ stage: String) -> String {
    ["prepare": "准备材料", "analyze": "分析来源", "draft": "生成草稿", "review": "校对成稿", "save": "保存产物"][stage]
      ?? stage
  }
}

/// A single observer owns stage ordering and a small durable history. stop/await
/// belongs to generate(), so no poller outlives its active attempt.
final class GenerationCheckpointObserver: @unchecked Sendable {
  private let checkpoints: GenerationCheckpoints
  private let callback: @Sendable (CodexProgress) -> Void
  private let lock = NSLock()
  private var completedCount: Int
  private var invalidatedStage: String?
  private var history: [[String: Any]] = []
  private var lastFiles: [String: String]?

  init(_ checkpoints: GenerationCheckpoints, callback: @escaping @Sendable (CodexProgress) -> Void)
  {
    self.checkpoints = checkpoints
    self.callback = callback
    completedCount = checkpoints.reusedStages.count
  }

  func begin() {
    lock.lock()
    defer { lock.unlock() }
    report("prepare", status: "started")
    report(
      "prepare", status: "completed",
      artifacts: [
        GenerationCheckpoints.sourceName, "checkpoints/context.json",
        GenerationCheckpoints.helperName,
      ])
    for stage in checkpoints.reusedStages {
      report(
        stage, status: "reused",
        artifacts: GenerationCheckpoints.artifacts(for: stage, mode: checkpoints.context.mode))
    }
  }

  func startWork() {
    lock.lock()
    defer { lock.unlock() }
    report(checkpoints.nextStage, status: "started")
  }

  @discardableResult func poll() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let files = fileSignatures()
    guard files != lastFiles else { return false }
    lastFiles = files
    let stages = checkpoints.validStages()
    if stages.count < completedCount {
      invalidate(from: stages.count)
      return true
    }
    while completedCount < stages.count {
      let stage = stages[completedCount]
      invalidatedStage = nil
      report(
        stage, status: "completed",
        artifacts: GenerationCheckpoints.artifacts(for: stage, mode: checkpoints.context.mode))
      completedCount += 1
      if completedCount < GenerationCheckpoints.stages.count {
        report(GenerationCheckpoints.stages[completedCount], status: "started")
      }
    }
    return true
  }

  /// Poll metadata only while receipts and their completed artifacts are unchanged.
  /// Drafts without a receipt are still being written and need no hash or decode.
  private func fileSignatures() -> [String: String] {
    var paths = [GenerationCheckpoints.sourceName, "checkpoints/context.json"]
    for stage in GenerationCheckpoints.stages {
      let marker = "checkpoints/\(stage).json"
      paths.append(marker)
      if FileManager.default.fileExists(
        atPath: checkpoints.root.appendingPathComponent(marker).path)
      {
        paths += GenerationCheckpoints.artifacts(for: stage, mode: checkpoints.context.mode)
      }
    }
    var result: [String: String] = [:]
    for path in Set(paths + [".", "checkpoints"]) {
      var info = stat()
      guard lstat(checkpoints.root.appendingPathComponent(path).path, &info) == 0 else {
        result[path] = "missing:\(errno)"
        continue
      }
      let identity = "\(info.st_dev):\(info.st_ino):\(info.st_mode)"
      result[path] =
        path == "." || path == "checkpoints"
        ? identity
        : identity
          + ":\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    return result
  }

  /// Used at the end of the turn even if a malformed receipt was never accepted.
  func completionFailure() -> String? {
    lock.lock()
    defer { lock.unlock() }
    let count = checkpoints.validStages().count
    guard count < GenerationCheckpoints.stages.count else { return nil }
    invalidate(from: count)
    return GenerationCheckpoints.stages[count]
  }

  private func invalidate(from index: Int) {
    completedCount = index
    let stage = GenerationCheckpoints.stages[index]
    guard invalidatedStage != stage else { return }
    invalidatedStage = stage
    for later in Array(GenerationCheckpoints.stages.dropFirst(index + 1)) + ["save"] {
      report(
        later, status: "pending", artifacts: [],
        message: "\(GenerationCheckpoints.label(later))等待前序检查点重新验证")
    }
    report(
      stage, status: "failed", artifacts: [],
      message: "\(GenerationCheckpoints.label(stage))检查点失效：产物缺失、内容变化或记录不完整")
  }

  func saveStarted() {
    lock.lock()
    defer { lock.unlock() }
    if checkpoints.nextStage != "save" { report("save", status: "started") }
  }

  func saveCompleted() {
    lock.lock()
    defer { lock.unlock() }
    report(
      "save", status: "completed",
      artifacts: GenerationCheckpoints.artifacts(for: "save", mode: checkpoints.context.mode))
  }

  private func report(
    _ stage: String, status: String, artifacts: [String]? = nil, message: String? = nil
  ) {
    let suffix = status == "reused" ? "已复用" : (status == "completed" ? "已完成" : "进行中")
    let message = message ?? "\(GenerationCheckpoints.label(stage))\(suffix)"
    var event: [String: Any] = [
      "stage": stage, "status": status, "message": message,
      "at": ISO8601DateFormatter().string(from: Date()),
    ]
    if let artifacts { event["artifacts"] = artifacts }
    history.append(event)
    history = Array(history.suffix(80))
    if let data = try? JSONSerialization.data(
      withJSONObject: history, options: [.prettyPrinted, .sortedKeys])
    {
      try? GenerationCheckpoints.writeOwnedFile(
        data, name: "checkpoints/history.json", root: checkpoints.root)
    }
    callback(
      CodexProgress(
        message: message, streamID: nil, stage: stage, stageStatus: status,
        artifacts: artifacts?.map { checkpoints.root.appendingPathComponent($0).path }))
  }
}
