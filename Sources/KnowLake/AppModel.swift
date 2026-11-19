import AppKit
import Combine
import Foundation

@MainActor final class QueueState: ObservableObject {
  @Published var jobs: [Job] = []
  var running: Int { jobs.filter { !$0.isFinished }.count }
  var pendingCount: Int { jobs.filter(\.isWaiting).count }
  var activeJob: Job? { jobs.first { !$0.isFinished && !$0.isWaiting } }
  func update(_ id: UUID, _ body: (inout Job) -> Void) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    body(&jobs[index])
  }
  func recordMetrics(_ id: UUID, _ metrics: TaskMetrics) {
    update(id) {
      if $0.metrics == nil { $0.metrics = TaskMetrics() }
      $0.metrics?.merge(metrics)
    }
  }
  func progress(
    _ id: UUID, _ message: String, state: String? = nil, streamID: String? = nil,
    stage: JobStage? = nil, stageStatus: String? = nil, artifacts: [String]? = nil
  ) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else {
      return
    }
    if let state { jobs[index].state = state }
    let message = String(message.trimmingCharacters(in: .whitespacesAndNewlines).suffix(900))
    guard !message.isEmpty else { return }
    var events = jobs[index].events ?? []
    let phase =
      stage
      ?? (jobs[index].stageStates == nil && streamID == nil
        ? JobStage.detect(message, generation: jobs[index].isGeneration) : nil)
      ?? jobs[index].currentStage.flatMap(JobStage.init(rawValue:))
      ?? events.last?.stage.flatMap(JobStage.init(rawValue:))
    let plan = JobTimelineStep.plan(for: jobs[index]).map(\.0)
    let previousIndex =
      jobs[index].currentStage.flatMap(JobStage.init(rawValue:)).flatMap { plan.firstIndex(of: $0) }
      ?? -1
    let incomingIndex = phase.flatMap { plan.firstIndex(of: $0) } ?? previousIndex
    let movesCurrent =
      stageStatus != "pending"
      && (stageStatus == "failed" || stageStatus == "cancelled" || incomingIndex >= previousIndex)
    if movesCurrent { jobs[index].message = message }
    if let phase {
      var starts = jobs[index].stageStarts ?? [:]
      if starts[phase.rawValue] == nil && stageStatus != "pending" {
        starts[phase.rawValue] = Date()
      }
      jobs[index].stageStarts = starts
      if movesCurrent { jobs[index].currentStage = phase.rawValue }
      if let stageStatus {
        var states = jobs[index].stageStates ?? [:]
        states[phase.rawValue] = stageStatus
        jobs[index].stageStates = states
      }
      if let artifacts {
        var values = jobs[index].stageArtifacts ?? [:]
        values[phase.rawValue] = artifacts
        jobs[index].stageArtifacts = values
      }
      if stageStatus == "pending" {
        jobs[index].stageArtifacts?.removeValue(forKey: phase.rawValue)
      }
    }
    if let streamID, let prior = events.lastIndex(where: { $0.streamID == streamID }) {
      let old = events[prior]
      events[prior] = JobEvent(
        id: old.id, date: old.date, message: message, streamID: streamID,
        stage: old.stage ?? phase?.rawValue, stageStatus: stageStatus ?? old.stageStatus,
        artifacts: artifacts ?? old.artifacts)
    } else if events.last?.message != message || events.last?.stageStatus != stageStatus {
      events.append(
        JobEvent(
          date: Date(), message: message, streamID: streamID, stage: phase?.rawValue,
          stageStatus: stageStatus, artifacts: artifacts))
    }
    jobs[index].events = Array(events.suffix(80))
  }
  func finish(
    _ id: UUID, state: String, message: String, failed: Bool = false, cancelled: Bool = false
  ) {
    let snapshot = jobs.first(where: { $0.id == id })
    let explicit = snapshot?.stageStates != nil
    let previous = snapshot?.currentStage.flatMap { snapshot?.stageStates?[$0] }
    let success =
      ["completed", "reused", "skipped"].contains(previous ?? "") ? previous! : "completed"
    progress(
      id, message, state: state,
      stageStatus: explicit ? (failed ? "failed" : cancelled ? "cancelled" : success) : nil)
    update(id) {
      $0.isFinished = true
      $0.failed = failed
      $0.cancelled = cancelled
      $0.finishedAt = Date()
      if let metrics = $0.metrics { $0.metrics = metrics.snapshot(at: $0.finishedAt!) }
    }
  }
}
@MainActor final class AppModel: ObservableObject {
  let preferences: Preferences
  let queue = QueueState()
  let engine = EngineClient()
  @Published var sources: [SourceRecord] = []
  @Published var collections: [String] = []
  @Published var tags: [String] = []
  @Published var total = 0
  @Published var selectedID: String?
  @Published var detail: SourceDetail?
  @Published var selectedArtifact: ArtifactRecord?
  @Published var selectedGenerationMode: String?
  @Published var selectedAcquisitionID: UUID?
  @Published var query = ""
  @Published var filter = "all"
  @Published var collection = ""
  @Published private(set) var folderNavigationDirection: CGFloat = 1
  @Published var platform = ""
  @Published var tag = ""
  @Published var loading = false
  @Published var detailLoading = false
  @Published var error: String?
  @Published var notice: String?
  @Published var models: [CodexModel] = []
  @Published var isLoadingCodexModels = false
  var selectedCodexModel: CodexModel? {
    preferences.model.isEmpty
      ? models.first { $0.isDefault == true }
      : models.first { $0.id == preferences.model }
  }
  @Published var maintenance = false
  var style: String {
    get { preferences.style }
    set { preferences.style = newValue }
  }
  var depth: String {
    get { preferences.depth }
    set { preferences.depth = newValue }
  }
  @Published var generationMode = "markdown"
  @Published var generating = false
  @Published var showTasks = false
  @Published var cacheInfo: CacheInfo?
  @Published var cacheMaintaining = false
  var reasoningEffort: String {
    get { preferences.reasoningEffort }
    set { preferences.reasoningEffort = newValue }
  }
  private var preferenceSubscriptions: Set<AnyCancellable> = []
  private var listTask: Task<Void, Never>?
  private var detailTask: Task<Void, Never>?
  private struct QueueExecution {
    let jobs: [Job]
    let task: Task<Void, Never>
    let mayRefreshSource: Bool
    var isGeneration: Bool { jobs[0].isGeneration }
    var sourceID: String? { jobs[0].sourceID }
  }
  private var activeExecutions: [UUID: QueueExecution] = [:]
  private var modelRuntime: CodexRuntime?

  private var shuttingDown = false
  private var listRevision = 0
  private struct FolderPageKey: Hashable { let root: String; let path: String }
  private var folderPages: [FolderPageKey: LibraryPage] = [:]
  private var folderPageOrder: [FolderPageKey] = []
  private var backupsRunning = false
  private var markdownImportRunning = false
  private var scheduleTask: Task<Void, Never>?
  private var started = false
  private let historyStore = JobHistoryStore()
  private var historyRevision = 0
  private var historyWriteTask: Task<Void, Never>?
  private var historyLoadTask: Task<Void, Never>?
  private var historyReady = false
  private var historyFlushedOnShutdown = false
  private let jobOperation: (@MainActor (Job) async throws -> Void)?
  private let batchOperation: (@MainActor ([Job]) async throws -> Void)?
  private let queueDefaults: UserDefaults
  init(
    jobOperation: (@MainActor (Job) async throws -> Void)? = nil,
    batchOperation: (@MainActor ([Job]) async throws -> Void)? = nil,
    queueDefaults: UserDefaults = .standard,
    preferences: Preferences? = nil
  ) {
    self.jobOperation = jobOperation
    self.batchOperation = batchOperation
    self.queueDefaults = queueDefaults
    self.preferences = preferences ?? Preferences()
    generationMode = self.preferences.generationModes.first ?? "markdown"
    self.preferences.$configurationError.compactMap { $0 }.sink { [weak self] message in
      self?.error = message
    }.store(in: &preferenceSubscriptions)
    self.preferences.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &preferenceSubscriptions)
    self.preferences.$maxConcurrentGenerations.dropFirst().sink { [weak self] _ in
      Task { @MainActor in self?.runQueue() }
    }.store(in: &preferenceSubscriptions)
  }
  func start() {
    guard !started else { return }
    started = true
    reload()
    historyLoadTask = Task { await resumePending() }
    scheduleTask = Task {
      while !Task.isCancelled && !shuttingDown {
        await maintainCacheIfDue()
        await scheduledBackup()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  func reload(debounce: Bool = false, invalidateFolders: Bool = true) {
    guard !shuttingDown else { return }
    if invalidateFolders { folderPages.removeAll(); folderPageOrder.removeAll() }
    listTask?.cancel()
    listRevision += 1
    let revision = listRevision
    loading = true
    listTask = Task {
      if debounce { try? await Task.sleep(for: .milliseconds(220)) }
      guard !Task.isCancelled else { return }
      do {
        let page: LibraryPage = try await engine.request(
          action: "list", root: preferences.root, params: listParams(offset: 0))
        guard revision == listRevision, !Task.isCancelled else { return }
        sources = page.items
        total = page.total
        collections = page.collections
        tags = page.tags
        cacheCurrentFolder()
      } catch is CancellationError {} catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
      if revision == listRevision { loading = false }
    }
  }
  private func listParams(offset: Int) -> [String: Any] {
    var params: [String: Any] = [
      "query": query, "filter": filter, "platform": platform, "tag": tag,
      "limit": 60, "offset": offset,
    ]
    if filter == "all" { params["collection"] = collection }
    return params
  }
  private func cacheCurrentFolder() {
    guard filter == "all", query.isEmpty, tag.isEmpty, platform.isEmpty else { return }
    let key = FolderPageKey(root: preferences.root, path: collection)
    folderPages[key] = LibraryPage(items: sources, total: total, collections: collections, tags: tags)
    folderPageOrder.removeAll { $0 == key }
    folderPageOrder.append(key)
    if folderPageOrder.count > 12 { folderPages.removeValue(forKey: folderPageOrder.removeFirst()) }
  }
  func openFolder(_ name: String) {
    if !loading, folderPages[FolderPageKey(root: preferences.root, path: collection)] != nil {
      cacheCurrentFolder()
    }
    folderNavigationDirection = name.isEmpty || collection.hasPrefix(name + "/") ? -1 : 1
    showTasks = false
    filter = "all"
    collection = name
    query = ""
    tag = ""
    platform = ""
    let page = folderPages[FolderPageKey(root: preferences.root, path: name)]
    sources = page?.items ?? []
    total = page?.total ?? 0
    if page != nil {
      listTask?.cancel()
      listRevision += 1
      loading = false
    } else {
      reload(invalidateFolders: false)
    }
  }
  func createFolder(_ name: String, parent: String = "") async throws -> String {
    guard !maintenance, !shuttingDown else {
      throw LakeError.message("资料库正在维护，请稍后新建文件夹。")
    }
    struct Result: Decodable { let name: String }
    let result: Result = try await engine.request(
      action: "create_folder", root: preferences.root, params: ["name": name, "parent": parent])
    collections = LibraryFolder.all(in: collections + [result.name])
    reload()
    return result.name
  }
  func deleteFolder(_ name: String, moveToRoot: Bool = false) async throws {
    guard !maintenance, !shuttingDown else {
      throw LakeError.message("资料库正在维护，请稍后删除文件夹。")
    }
    func inFolder(_ path: String) -> Bool { path == name || path.hasPrefix(name + "/") }
    guard !queue.jobs.contains(where: {
      !$0.isGeneration && !$0.isFinished && inFolder($0.importOptions?.collection ?? "")
    }) else {
      throw LakeError.message("此文件夹中有待完成的采集任务，请在任务结束后删除。")
    }
    struct Result: Decodable { let destination: String; let moved: Int }
    let root = preferences.root
    let result: Result = try await engine.request(
      action: "delete_folder", root: root, params: ["name": name, "move_to_root": moveToRoot])
    guard root == preferences.root else { return }
    collections.removeAll(where: inFolder)
    for index in sources.indices where inFolder(sources[index].collection) {
      sources[index].collection = result.destination
    }
    if let current = detail, inFolder(current.source.collection) {
      var source = current.source
      source.collection = result.destination
      detail = SourceDetail(source: source, content: current.content, segments: current.segments,
                            artifacts: current.artifacts, content_path: current.content_path)
    }
    if filter == "all", inFolder(collection) {
      folderPages.removeAll()
      folderPageOrder.removeAll()
      openFolder(result.destination)
    } else {
      reload()
    }
    notice = result.moved == 0 ? "已删除文件夹" : "已删除文件夹，移出 \(result.moved) 条资料"
  }
  func more() async {
    guard !loading, sources.count < total else { return }
    let revision = listRevision
    loading = true
    defer { if revision == listRevision { loading = false } }
    do {
      let page: LibraryPage = try await engine.request(
        action: "list", root: preferences.root, params: listParams(offset: sources.count))
      guard revision == listRevision else { return }
      let existing = Set(sources.map(\.id))
      sources += page.items.filter { !existing.contains($0.id) }
      total = page.total
    } catch { self.error = error.localizedDescription }
  }
  func select(_ id: String?, preferOriginal: Bool = false, artifactID: String? = nil) {
    detailTask?.cancel()
    selectedID = id
    selectedArtifact = nil
    selectedGenerationMode = nil
    selectedAcquisitionID = nil
    detail = nil
    detailLoading = false
    guard let id else { return }
    detailLoading = true
    detailTask = Task {
      do {
        let result: SourceDetail = try await engine.request(
          action: "get", root: preferences.root, params: ["id": id])
        guard selectedID == id, !Task.isCancelled else { return }
        detail = result
        selectedArtifact = artifactID != nil
          ? result.artifacts.first(where: { $0.id == artifactID })
          : preferOriginal ? nil : result.artifacts.first(where: { $0.kind != "image" })
      } catch is CancellationError {} catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
      if selectedID == id { detailLoading = false }
    }
  }
  func selectAcquisition(_ job: Job) {
    let job = queue.jobs.first { $0.id == job.id } ?? job
    if let sourceID = job.sourceID {
      select(sourceID, preferOriginal: true)
      return
    }
    select(nil)
    detailLoading = false
    selectedAcquisitionID = job.id
  }
  func selectReaderKind(_ kind: String, in material: SourceDetail) {
    if kind != "source", let job = ReaderGenerationState.job(
      sourceID: material.source.id, mode: kind, jobs: queue.jobs), !job.isFinished
    {
      selectedArtifact = nil
      selectedGenerationMode = kind
      return
    }
    selectedArtifact = material.artifacts.first { $0.kind == kind }
    selectedGenerationMode = kind == "source" || selectedArtifact != nil ? nil : kind
  }
  @discardableResult
  func update(id: String, values: [String: Any], refreshDetail: Bool = false) async -> Bool {
    do {
      var p = values
      p["id"] = id
      let source: SourceRecord = try await engine.request(
        action: "update", root: preferences.root, params: p)
      if let index = sources.firstIndex(where: { $0.id == id }) {
        if filter == "all", source.collection != collection {
          sources.remove(at: index)
          total = max(0, total - 1)
        } else { sources[index] = source }
      }
      if let current = detail, current.source.id == id {
        detail = SourceDetail(
          source: source, content: current.content, segments: current.segments,
          artifacts: current.artifacts, content_path: current.content_path)
      }
      if refreshDetail { select(id) }
      reload()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func enqueue(
    _ input: String, options: GenerationOptions? = nil, autoGenerate: Bool? = nil,
    collection: String? = nil, tags: [String] = [], generationModes: [String]? = nil,
    skipExisting: Bool = false
  ) {
    guard !maintenance, !shuttingDown else {
      error = "当前正在维护资料库，请稍后添加。"
      return
    }
    let links = input.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    guard !links.isEmpty else { return }
    let generation = resolveProfile(options ?? generationOptions())
    let modes = generationModes ?? options.map { [$0.mode] } ?? preferences.generationModes
    let shouldGenerate = autoGenerate ?? preferences.autoGenerate
    guard !shouldGenerate || !modes.isEmpty else {
      error = "请选择至少一种生成形式。"
      return
    }
    var acquisition = ImportOptions(
      autoGenerate: shouldGenerate, collection: collection ?? self.collection,
      tags: tags, browserPath: preferences.browserPath, generationModes: modes,
      assignsCollection: collection != nil || !self.collection.isEmpty, skipExisting: skipExisting)
    #if KNOWLAKE_PRIVATE
    acquisition.asrProvider = preferences.asrProvider
    #endif
    for link in links {
      var job = Job(input: link)
      job.kind = "ingest"
      job.generation = generation
      job.importOptions = acquisition
      queue.jobs.append(job)
      queue.progress(job.id, "已加入采集队列")
    }
    showTasks = true
    rememberQueue()
    runQueue()
  }
  func importMarkdown(
    _ markdown: String, title: String, collection: String, autoGenerate: Bool
  ) async -> Bool {
    guard !maintenance, !shuttingDown, !markdownImportRunning else { return false }
    let modes = preferences.generationModes
    guard !autoGenerate || !modes.isEmpty else {
      error = "请选择至少一种生成形式。"
      return false
    }
    let options = generationOptions()
    markdownImportRunning = true
    defer { markdownImportRunning = false }
    do {
      let result: IngestResult = try await engine.request(
        action: "import_markdown", root: preferences.root,
        params: ["markdown": markdown, "title": title, "collection": collection])
      reload()
      select(result.source.id, preferOriginal: true)
      if autoGenerate {
        enqueueGenerations(
          for: result.source, options: options, modes: modes, message: "正文已就绪，等待生成")
        showTasks = true
        rememberQueue()
        runQueue()
      }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  private func unavailableModule(for job: Job) -> String? {
    guard jobOperation == nil else { return nil }
    if job.isGeneration {
      let options = job.generation ?? generationOptions()
      return AppModules.supports(provider: options.provider, mode: options.mode)
        ? nil : "此版本未提供任务所需的生成模块。"
    }
    return AppModules.source(for: job.input) == nil
      ? "此版本未提供任务所需的采集模块。" : nil
  }

  func resumePending(automatically: Bool = true) async {
    let root = preferences.root
    var history: [Job]
    do {
      if FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: root).appendingPathComponent("tasks.json").path)
      {
        history = try await historyStore.load(root: root)
      } else {
        let data =
          queueDefaults.data(forKey: "taskHistory:" + root)
          ?? queueDefaults.data(forKey: "pendingJobs:" + root)
        history = data.flatMap { try? JSONDecoder().decode([Job].self, from: $0) } ?? []
      }
    } catch {
      if !shuttingDown { self.error = "无法读取任务记录：" + error.localizedDescription }
      return
    }
    guard !Task.isCancelled, !shuttingDown, root == preferences.root else { return }
    historyReady = true
    let existing = Set(queue.jobs.map(\.id))
    history.removeAll { existing.contains($0.id) }
    var resumed = 0
    for i in history.indices where !history[i].isFinished {
      if let message = unavailableModule(for: history[i]) {
        history[i].state = "模块不可用"
        history[i].message = message
        history[i].isFinished = true
        continue
      }
      history[i].state = automatically ? "排队中" : "等待继续"
      history[i].isFinished = !automatically
      history[i].failed = false
      history[i].cancelled = !automatically
      history[i].startedAt = nil
      history[i].finishedAt = nil
      history[i].stageStarts = nil
      history[i].stageStates = nil
      history[i].stageArtifacts = nil
      history[i].currentStage = nil
      if let checkpoint = history[i].checkpointRunID {
        history[i].resumeFromRunID = checkpoint
        history[i].checkpointRunID = nil
        history[i].retryFromStage = nil
      }
      if automatically { resumed += 1 }
    }
    queue.jobs.append(contentsOf: history)
    rememberQueue()
    if resumed > 0 {
      notice = "已恢复 \(resumed) 个任务，将继续已保存的阶段"
      showTasks = true
      runQueue()
    }
  }
  private func rememberQueue() {
    guard !historyFlushedOnShutdown, !started || historyReady else { return }
    let completed = Set(queue.jobs.filter(\.isFinished).suffix(100).map(\.id))
    let history = queue.jobs.filter { !$0.isFinished || completed.contains($0.id) }.map { job in
      var value = job
      value.metrics = value.metrics?.snapshot(at: value.finishedAt ?? Date())
      if value.isFinished { value.events = Array(value.eventHistory.suffix(20)) }
      return value
    }
    historyRevision += 1
    let revision = historyRevision
    let root = preferences.root
    historyWriteTask = Task {
      do { try await historyStore.save(history, root: root, revision: revision) } catch {
        if !shuttingDown { self.error = "任务记录保存失败：" + error.localizedDescription }
      }
    }
    if let data = try? JSONEncoder().encode(queue.jobs.filter { !$0.isFinished }) {
      queueDefaults.set(data, forKey: "pendingJobs:" + preferences.root)
    }
  }
  private func runQueue() {
    guard !shuttingDown, !maintenance, !activeExecutions.values.contains(where: \.mayRefreshSource) else { return }
    let activeBefore = activeExecutions.count
    let activeGenerations = activeExecutions.values.filter(\.isGeneration)
    var generationCount = activeGenerations.count
    var activeSources = Set(activeGenerations.compactMap(\.sourceID))
    var acquiring = activeBefore > generationCount
    var scheduledIDs = Set<UUID>()
    let waiting = queue.jobs.filter(\.isWaiting)
    let batches = Dictionary(grouping: waiting.filter {
      $0.isGeneration && $0.generationBatchID != nil
    }) { $0.generationBatchID }
    for job in waiting where !scheduledIDs.contains(job.id) {
      // A refresh may replace the source version and assets a generation is using.
      let mayRefreshSource = !job.isGeneration
        && (job.retryFromStage != nil || job.importOptions?.skipExisting != true)
      if mayRefreshSource && (acquiring || generationCount > 0) { break }
      if job.isGeneration {
        guard generationCount < preferences.maxConcurrentGenerations else { continue }
        if let sourceID = job.sourceID, !activeSources.insert(sourceID).inserted { continue }
        generationCount += 1
      } else {
        guard !acquiring else { continue }
        acquiring = true
      }
      let jobs = job.isGeneration && job.generationBatchID != nil
        ? batches[job.generationBatchID] ?? [job] : [job]
      scheduledIDs.formUnion(jobs.map(\.id))
      for item in jobs {
        let now = Date()
        queue.update(item.id) {
          $0.startedAt = now
          if $0.metrics == nil { $0.metrics = TaskMetrics() }
          $0.metrics?.workPeriods.append(TaskWorkPeriod(start: now))
        }
        queue.progress(
          item.id, item.isGeneration ? "正在准备生成任务…" : "正在获取内容…",
          state: item.isGeneration ? "生成中" : "采集中",
          stage: item.isGeneration ? .prepare : .queued,
          stageStatus: item.isGeneration ? "started" : nil)
      }
      activeExecutions[job.id] = QueueExecution(
        jobs: jobs, task: Task { await executeJobs(jobs) }, mayRefreshSource: mayRefreshSource)
      if mayRefreshSource { break }
    }
    let hasActiveGeneration = generationCount > 0
    if generating != hasActiveGeneration { generating = hasActiveGeneration }
    if activeExecutions.count != activeBefore { rememberQueue() }
  }
  private func executeJobs(_ jobs: [Job]) async {
    let job = jobs[0]
    let failure: Error?
    do {
      try Task.checkCancellation()
      if jobs.count > 1 {
        if let batchOperation {
          try await batchOperation(jobs)
        } else {
          try await executeGenerationBatch(jobs)
        }
      } else if let jobOperation {
        try await jobOperation(job)
      } else if job.isGeneration {
        try await executeGeneration(job)
      } else {
        try await ingest(job)
      }
      failure = nil
    } catch { failure = error }
    for item in jobs {
      guard let current = queue.jobs.first(where: { $0.id == item.id }), !current.isFinished
      else { continue }
      // Shutdown interrupts execution so these jobs can resume on the next launch.
      if shuttingDown, Task.isCancelled, !current.cancelled, failure != nil { continue }
      if current.cancelled || (Task.isCancelled && !shuttingDown) || failure is CancellationError {
        queue.finish(item.id, state: "已停止", message: "任务已取消", cancelled: true)
      } else if let failure {
        queue.finish(item.id, state: "失败", message: failure.localizedDescription, failed: true)
      } else {
        queue.finish(item.id, state: "已完成", message: item.isGeneration ? "产物已保存" : "正文已保存")
      }
    }
    activeExecutions.removeValue(forKey: job.id)
    let hasActiveGeneration = activeExecutions.values.contains(where: \.isGeneration)
    if generating != hasActiveGeneration { generating = hasActiveGeneration }
    rememberQueue()
    runQueue()
  }
  private func ingest(_ job: Job) async throws {
    let acquisition =
      job.importOptions
      ?? ImportOptions(
        autoGenerate: preferences.autoGenerate, collection: "", tags: [],
        browserPath: preferences.browserPath)
    var params: [String: Any] = ["url": job.input]
    if acquisition.assignsCollection == true || !acquisition.collection.isEmpty {
      params["collection"] = acquisition.collection
    }
    guard let module = AppModules.source(for: job.input) else {
      throw LakeError.message("此版本未提供任务所需的采集模块。")
    }
    params.merge(module.parameters(preferences, acquisition)) { _, value in value }
    if !preferences.networkProxy.isEmpty { params["proxy"] = preferences.networkProxy }
    if let retry = job.retryFromStage { params["retry_from"] = retry }
    let skipExisting = acquisition.skipExisting == true && job.retryFromStage == nil
    if skipExisting { params["skip_existing"] = true }
    let result: IngestResult = try await engine.request(
      action: "ingest", root: preferences.root, params: params, id: job.id,
      onProgress: { [weak self] event in
        Task { @MainActor in
          if !module.usesMediaCache, event.stage == "save", event.status == "started" {
            self?.queue.progress(job.id, "正文获取完成", stage: .fetch, stageStatus: "completed")
          }
          self?.queue.progress(
            job.id, event.message, stage: event.stage.flatMap(JobStage.init(rawValue:)),
            stageStatus: event.status, artifacts: event.artifacts)
        }
      })
    try Task.checkCancellation()
    queue.update(job.id) { $0.sourceID = result.source.id }
    if result.reused == true {
      let stages: [JobStage] =
        module.usesMediaCache ? [.fetch, .subtitles, .download, .transcribe] : [.fetch]
      for stage in stages {
        queue.progress(job.id, "直接使用已归档来源", stage: stage, stageStatus: "skipped")
      }
      queue.progress(job.id, "已复用归档来源", stage: .save, stageStatus: "reused")
      if skipExisting {
        queue.finish(job.id, state: "已跳过", message: "资料已存在，已跳过添加")
        notice = "「\(result.source.title)」已在资料库中"
        if selectedAcquisitionID == job.id { select(result.source.id, preferOriginal: true) }
        return
      }
    } else {
      queue.progress(job.id, "正文已归档，可以阅读来源", stage: .save, stageStatus: "completed")
    }
    if !acquisition.tags.isEmpty {
      let _: SourceRecord = try await engine.request(
        action: "update", root: preferences.root,
        params: [
          "id": result.source.id, "tags": acquisition.tags,
        ])
    }
    try Task.checkCancellation()
    reload()
    if selectedAcquisitionID == job.id || (selectedID == nil && selectedAcquisitionID == nil) {
      select(result.source.id, preferOriginal: true)
    }
    if acquisition.autoGenerate {
      let options = job.generation ?? generationOptions(mode: "markdown")
      enqueueGenerations(
        for: result.source, options: options,
        modes: acquisition.generationModes ?? [options.mode], message: "正文已就绪，等待生成")
    }
  }
  func cancelJob(_ id: UUID) {
    guard let job = queue.jobs.first(where: { $0.id == id }), !job.isFinished else { return }
    if let execution = activeExecutions.values.first(where: { $0.jobs.contains { $0.id == id } }) {
      for item in execution.jobs where queue.jobs.first(where: { $0.id == item.id })?.isFinished == false {
        queue.update(item.id) { $0.cancelled = true }
        queue.progress(item.id, "正在停止执行…", state: "停止中")
      }
      execution.task.cancel()
    } else {
      queue.finish(id, state: "已停止", message: "已从队列取消", cancelled: true)
    }
    rememberQueue()
    runQueue()
  }
  func retry(_ job: Job, from stage: JobStage? = nil) {
    guard !maintenance, !shuttingDown else { return }
    if let message = unavailableModule(for: job) {
      error = message
      return
    }
    if !job.isFinished { cancelJob(job.id) }
    let job = queue.jobs.first(where: { $0.id == job.id }) ?? job
    var next = job
    next.id = UUID()
    next.state = "排队中"
    next.isFinished = false
    next.failed = false
    next.cancelled = false
    next.events = []
    next.createdAt = Date()
    next.startedAt = nil
    next.finishedAt = nil
    next.stageStarts = nil
    next.currentStage = nil
    next.stageStates = nil
    next.stageArtifacts = nil
    next.retryOf = job.id
    next.generationBatchID = nil
    next.metrics = nil
    next.retryFromStage = stage?.rawValue
    next.resumeFromRunID = stage == .prepare ? nil : (job.checkpointRunID ?? job.resumeFromRunID)
    next.checkpointRunID = nil
    queue.jobs.append(next)
    if selectedAcquisitionID == job.id { selectedAcquisitionID = next.id }
    queue.progress(next.id, "已重新加入队列")
    showTasks = true
    rememberQueue()
    runQueue()
  }

  func refreshCacheInfo() async {
    guard AppModules.hasMediaCache else { return }
    let root = preferences.root
    do {
      let info: CacheInfo = try await engine.request(action: "cache_info", root: root)
      if root == preferences.root { cacheInfo = info }
    } catch is CancellationError {} catch {
      if !shuttingDown && root == preferences.root { self.error = error.localizedDescription }
    }
  }
  func cleanupCache() async { await performCacheCleanup(announce: true) }
  private func performCacheCleanup(announce: Bool) async {
    guard AppModules.hasMediaCache, !cacheMaintaining, !shuttingDown else { return }
    cacheMaintaining = true
    defer { cacheMaintaining = false }
    let root = preferences.root
    do {
      let info: CacheInfo = try await engine.request(action: "cache_cleanup", root: root)
      queueDefaults.set(Date(), forKey: "cacheMaintenance:" + root)
      if root == preferences.root {
        cacheInfo = info
        if announce { notice = "已清理过期与超额缓存" }
      }
    } catch is CancellationError {} catch {
      if announce && root == preferences.root { self.error = error.localizedDescription }
    }
  }
  private func maintainCacheIfDue() async {
    let last =
      queueDefaults.object(forKey: "cacheMaintenance:" + preferences.root) as? Date ?? .distantPast
    if Date().timeIntervalSince(last) >= 86400 { await performCacheCleanup(announce: false) }
  }
  func loadModels() async {
    guard modelRuntime == nil, !shuttingDown else { return }
    isLoadingCodexModels = true
    defer { isLoadingCodexModels = false }
    do {
      let runtime = CodexRuntime(executable: preferences.codexPath)
      modelRuntime = runtime
      defer { modelRuntime = nil }
      models = try await runtime.models()
    } catch is CancellationError {
    } catch {
      if !Task.isCancelled && !shuttingDown { self.error = error.localizedDescription }
    }
  }
  func generationOptions(mode: String? = nil) -> GenerationOptions {
    #if KNOWLAKE_PRIVATE
    let api = preferences.apiSelection
    #else
    let api = (model: "", baseURL: "", profile: "")
    #endif
    return GenerationOptions(
      mode: mode ?? preferences.generationModes.first ?? generationMode,
      provider: preferences.generationProvider, model: preferences.model,
      apiModel: api.model, baseURL: api.baseURL, style: style, depth: depth,
      contextStart: "", contextEnd: "",
      reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort,
      apiProfileID: api.profile, fastMode: preferences.fastMode,
      selectedVisualStyle: preferences.visualStyle)
  }
  private func resolveProfile(_ options: GenerationOptions) -> GenerationOptions {
    #if KNOWLAKE_PRIVATE
    var resolved = options
    if resolved.apiProfileID == nil, options.baseURL == preferences.baseURL {
      resolved.apiProfileID = preferences.apiProfileID
    }
    return resolved
    #else
    return options
    #endif
  }
  /// Multiple formats share one coordinating Codex session.
  func generate(
    sourceDetail: SourceDetail? = nil, modes: [String]? = nil,
    intent: GenerationIntent = .standard, queuedJobID: UUID? = nil
  ) async {
    guard !maintenance, !shuttingDown else {
      error = "当前正在维护资料库，请稍后生成。"
      return
    }
    guard let detail = sourceDetail ?? self.detail else {
      error = "请先选择一份内容。"
      return
    }
    let requestedModes = modes ?? preferences.generationModes
    let existingKinds = Set(detail.artifacts.map(\.kind))
    let selectedModes = ["markdown", "html", "image"].filter {
      requestedModes.contains($0) && (intent != .supplement || !existingKinds.contains($0))
    }
    guard !selectedModes.isEmpty else {
      error = intent == .supplement && !requestedModes.isEmpty
        ? "所选形式已有生成结果，请选择重新生成。" : "请选择至少一种生成形式。"
      return
    }
    var options = generationOptions()
    options.provider = selectedModes.allSatisfy {
      AppModules.supports(provider: preferences.provider, mode: $0)
    } ? preferences.provider : "codex"
    if intent == .regenerate {
      options.provider = "codex"
      if !AppModules.isPublic { options.reasoningEffort = "ultra" }
    }
    enqueueGenerations(
      for: detail.source, options: options, modes: selectedModes,
      message: "已加入生成队列")
    showTasks = true
    rememberQueue()
    runQueue()
  }
  func enqueueGenerations(
    for source: SourceRecord, options: GenerationOptions, modes: [String], message: String
  ) {
    let selectedModes = ["markdown", "html", "image"].filter { modes.contains($0) }
    let batchID = selectedModes.count > 1 ? UUID() : nil
    for mode in selectedModes {
      var job = Job(input: source.title)
      job.kind = "generate"
      job.sourceID = source.id
      job.mode = mode
      job.generationBatchID = batchID
      job.generation = batchID == nil
        ? options.selectingMode(mode) : options.coordinatedGeneration(mode: mode)
      queue.jobs.append(job)
      queue.progress(job.id, message)
    }
  }
  private func prepareCodexRequest(_ job: Job, material: SourceDetail) async throws
    -> (request: CodexRequest, attemptID: UUID, temporaryInput: URL?)
  {
    let options = job.generation ?? generationOptions()
    let attemptID = UUID()
    let outputDir = URL(fileURLWithPath: preferences.root).appendingPathComponent(
      "runs/\(attemptID.uuidString)")
    let resumeID =
      job.retryFromStage == "prepare" ? nil : (job.resumeFromRunID ?? job.checkpointRunID)
    let resumeDirectory = resumeID.map {
      URL(fileURLWithPath: preferences.root).appendingPathComponent("runs/\($0.uuidString)").path
    }
    let sourceFile: URL
    var temporaryInput: URL?
    if options.contextStart.isEmpty && options.contextEnd.isEmpty,
      let path = material.content_path
    {
      sourceFile = URL(fileURLWithPath: path)
    } else {
      let scoped = try scopedContent(
        material.content, start: options.contextStart, end: options.contextEnd)
      let input = URL(fileURLWithPath: preferences.root).appendingPathComponent(
        "runs/inputs/\(attemptID.uuidString).md")
      try await Task.detached(priority: .utility) {
        try FileManager.default.createDirectory(
          at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try scoped.write(to: input, atomically: true, encoding: .utf8)
      }.value
      sourceFile = input
      temporaryInput = input
    }
    return (CodexRequest(
      sourceID: material.source.id, title: material.source.title, sourceURL: material.source.url,
      contentPath: sourceFile.path, outputDirectory: outputDir.path, mode: options.mode,
      model: options.model, style: options.style, depth: options.depth,
      writingSkillPath: BundledWritingSkill.file?.path,
      reasoningEffort: options.reasoningEffort, fastMode: options.fastMode ?? false,
      resumeDirectory: resumeDirectory,
      retryFrom: job.retryFromStage == "prepare" ? nil : job.retryFromStage,
      sourceDirectory: material.content_path.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent().path
      }, visualStyle: options.visualStyle, checkpointPython: engine.python.path), attemptID, temporaryInput)
  }

  private func recordPreparedRuns(_ attempts: [UUID: UUID]) async {
    for (id, attempt) in attempts {
      queue.update(id) { $0.checkpointRunID = attempt }
    }
    rememberQueue()
    await historyWriteTask?.value
  }

  private func generationProgress(_ progress: CodexProgress, jobID: UUID) {
    if let metrics = progress.metrics {
      queue.recordMetrics(jobID, metrics)
      rememberQueue()
    }
    // Runtime save means a durable local file; the library transaction is still pending.
    let savedLocally = progress.stage == "save" && progress.stageStatus == "completed"
    queue.progress(
      jobID, savedLocally ? "产物文件已就绪，正在归档" : progress.message,
      streamID: progress.streamID, stage: progress.stage.flatMap(JobStage.init(rawValue:)),
      stageStatus: savedLocally ? "started" : progress.stageStatus, artifacts: progress.artifacts)
  }

  private func registerGeneratedOutput(_ output: CodexOutput, job: Job, source: SourceRecord)
    async throws -> ArtifactResult
  {
    try Task.checkCancellation()
    queue.progress(job.id, "正在保存产物…", stage: .save, stageStatus: "started")
    return try await engine.request(
      action: "register_artifact", root: preferences.root,
      params: [
        "source_id": source.id, "kind": output.kind,
        "title": output.kind == "image" ? "概览图" : "\(source.title) · \(job.generation?.depth ?? depth)",
        "path": output.path, "model": output.model, "run_id": output.runID,
      ])
  }

  private func didGenerate(_ result: ArtifactResult, job: Job, sourceID: String) async {
    queue.progress(
      job.id, "产物已归档", stage: .save, stageStatus: "completed", artifacts: [result.artifact.path])
    guard !shuttingDown else { return }
    if selectedID == sourceID {
      do {
        let refreshed: SourceDetail = try await engine.request(
          action: "get", root: preferences.root, params: ["id": sourceID])
        applyGeneratedArtifact(result.artifact, detail: refreshed)
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    reload()
  }

  private func executeGenerationBatch(_ jobs: [Job]) async throws {
    guard let sourceID = jobs.first?.sourceID else { throw LakeError.message("生成任务缺少来源") }
    let material: SourceDetail = try await engine.request(
      action: "get", root: preferences.root, params: ["id": sourceID])
    var requests: [CodexRequest] = []
    var attempts: [UUID: UUID] = [:]
    var temporaryInputs: [URL] = []
    defer {
      for input in temporaryInputs { try? FileManager.default.trashItem(at: input, resultingItemURL: nil) }
    }
    for job in jobs {
      let prepared = try await prepareCodexRequest(job, material: material)
      requests.append(prepared.request)
      attempts[job.id] = prepared.attemptID
      if let input = prepared.temporaryInput { temporaryInputs.append(input) }
    }
    try Task.checkCancellation()
    let idsByMode = Dictionary(uniqueKeysWithValues: zip(requests.map(\.mode), jobs.map(\.id)))
    let runtime = CodexRuntime(executable: preferences.codexPath)
    let outputs = try await runtime.generateBatch(
      requests,
      onPrepared: { [weak self, attempts] in await self?.recordPreparedRuns(attempts) },
      onProgress: { [weak self] mode, progress in
        guard let id = idsByMode[mode] else { return }
        Task { @MainActor in self?.generationProgress(progress, jobID: id) }
      })
    for (job, request) in zip(jobs, requests) {
      try Task.checkCancellation()
      do {
        guard let output = outputs[request.mode] else { throw LakeError.message("未返回该形式的生成结果") }
        let result = try await registerGeneratedOutput(output.get(), job: job, source: material.source)
        await didGenerate(result, job: job, sourceID: sourceID)
        queue.finish(job.id, state: "已完成", message: "产物已保存")
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        queue.finish(job.id, state: "失败", message: error.localizedDescription, failed: true)
      }
      rememberQueue()
    }
  }

  private func executeGeneration(_ job: Job) async throws {
    guard let sourceID = job.sourceID else { throw LakeError.message("生成任务缺少来源") }
    let material: SourceDetail = try await engine.request(
      action: "get", root: preferences.root, params: ["id": sourceID])
    let source = material.source
    let options = job.generation ?? generationOptions()
    queue.update(job.id) {
      if $0.generation == nil { $0.generation = options }
    }
    guard AppModules.supports(provider: options.provider, mode: options.mode) else {
      throw LakeError.message("此版本未提供任务所需的生成模块。")
    }
    #if KNOWLAKE_PRIVATE
    if options.provider == PrivateModules.api.id {
      queue.progress(job.id, "材料已就绪", stage: .prepare, stageStatus: "completed")
      queue.progress(job.id, "正在调用模型 API…", stage: .generate, stageStatus: "started")
      let result = try await PrivateModules.generate(
        options, preferences: preferences, engine: engine, sourceID: source.id, jobID: job.id,
        onProgress: { [weak self] event in
          guard let usage = event.usage else { return }
          Task { @MainActor in
            self?.queue.recordMetrics(job.id, TaskMetrics(tokenUsage: ["api:" + (event.usageID ?? job.id.uuidString): usage]))
            self?.rememberQueue()
          }
        },
        progress: { [weak self] message in
          Task { @MainActor in self?.queue.progress(job.id, message) }
        })
      queue.progress(job.id, "模型生成已完成", stage: .generate, stageStatus: "completed")
      await didGenerate(result, job: job, sourceID: source.id)
      return
    }
    #endif
    let prepared = try await prepareCodexRequest(job, material: material)
    defer {
      if let temporaryInput = prepared.temporaryInput {
        try? FileManager.default.trashItem(at: temporaryInput, resultingItemURL: nil)
      }
    }
    try Task.checkCancellation()
    let runtime = CodexRuntime(executable: preferences.codexPath)
    let output = try await runtime.generate(
      prepared.request,
      onPrepared: { [weak self] in await self?.recordPreparedRuns([job.id: prepared.attemptID]) },
      onProgress: { [weak self] progress in
        Task { @MainActor in self?.generationProgress(progress, jobID: job.id) }
      }, onEvent: { _ in })
    let result = try await registerGeneratedOutput(output, job: job, source: source)
    await didGenerate(result, job: job, sourceID: source.id)
  }
  func applyGeneratedArtifact(_ artifact: ArtifactRecord, detail refreshed: SourceDetail) {
    guard selectedID == refreshed.source.id else { return }
    detail = refreshed
    if selectedGenerationMode == artifact.kind {
      selectedArtifact = artifact
      selectedGenerationMode = nil
    }
  }
  func scopedContent(_ text: String, start: String, end: String) throws -> String {
    var value = text[...]
    if !start.isEmpty {
      guard let range = value.range(of: start) else { throw LakeError.message("未找到材料范围的起始文字") }
      value = value[range.lowerBound...]
    }
    if !end.isEmpty {
      guard let range = value.range(of: end) else { throw LakeError.message("未找到材料范围的结束文字") }
      value = value[..<range.upperBound]
    }
    return String(value)
  }
  func backup() async {
    guard !maintenance, !backupsRunning else { return }
    backupsRunning = true
    defer { backupsRunning = false }
    do {
      var params: [String: Any] = [:]
      if !preferences.backupDirectory.isEmpty {
        params["destination"] = preferences.backupDirectory
      }
      await historyWriteTask?.value
      let result: PathResult = try await engine.request(
        action: "backup", root: preferences.root, params: params)
      UserDefaults.standard.set(Date(), forKey: "lastBackup:" + preferences.root)
      notice = "备份已保存：\(result.path ?? "")"
    } catch { self.error = error.localizedDescription }
  }
  func scheduledBackup() async {
    guard preferences.backupDays > 0 else { return }
    let last =
      UserDefaults.standard.object(forKey: "lastBackup:" + preferences.root) as? Date
      ?? .distantPast
    if Date().timeIntervalSince(last) >= Double(preferences.backupDays) * 86400 { await backup() }
  }
  func relocate(destination: String, archive: String? = nil) async {
    guard queue.running == 0, !maintenance, !markdownImportRunning, !backupsRunning else {
      error = "请先等待当前任务完成，或停止任务。"
      return
    }
    maintenance = true
    defer { maintenance = false }
    do {
      var params = ["destination": destination]
      if let archive { params["archive"] = archive }
      await historyWriteTask?.value
      let result: PathResult = try await engine.request(
        action: archive == nil ? "migrate" : "restore", root: preferences.root, params: params)
      guard let root = result.root else { throw LakeError.message("操作没有返回资料目录") }
      preferences.root = root
      cacheInfo = nil
      queue.jobs = []
      historyReady = false
      await resumePending(automatically: false)
      select(nil)
      reload()
      notice = "资料目录已切换"
    } catch { self.error = error.localizedDescription }
  }
  func shutdown() async {
    shuttingDown = true
    scheduleTask?.cancel()
    historyLoadTask?.cancel()
    let activeTasks = activeExecutions.values.map(\.task)
    for task in activeTasks { task.cancel() }
    listTask?.cancel()
    detailTask?.cancel()
    rememberQueue()
    await engine.shutdown()
    await modelRuntime?.cancel()
    for task in activeTasks { await task.value }
    rememberQueue()
    historyFlushedOnShutdown = true
    await historyWriteTask?.value
  }
}
