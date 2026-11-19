import Foundation
import XCTest

@testable import KnowLake

final class GenerationCheckpointsTests: XCTestCase {
  func testIdlePollingSkipsContentReadsAndStillDetectsChanges() throws {
    let (root, _, store) = try fixture()
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let observer = GenerationCheckpointObserver(store, callback: { _ in })
    observer.begin()
    XCTAssertTrue(observer.poll())
    XCTAssertFalse(observer.poll())
    try "Unfinished draft".write(
      to: store.root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
    XCTAssertFalse(observer.poll(), "Uncommitted drafts must not trigger full artifact validation")
    try complete("analyze", in: store)
    XCTAssertTrue(observer.poll())
    XCTAssertFalse(observer.poll())
    try "Modified analysis".write(
      to: store.root.appendingPathComponent("analysis.md"), atomically: true, encoding: .utf8)
    XCTAssertTrue(observer.poll())
    XCTAssertEqual(observer.completionFailure(), "analyze")
  }
  private func fixture() throws -> (URL, CodexRequest, GenerationCheckpoints) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowlake-checkpoints-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.md")
    try "来源正文与证据".write(to: source, atomically: true, encoding: .utf8)
    let request = CodexRequest(
      sourceID: "source-1", title: "标题", sourceURL: "https://example.org",
      contentPath: source.path, outputDirectory: root.appendingPathComponent("attempt").path,
      mode: "markdown", model: "test-model", style: "清晰", depth: "适中", reasoningEffort: "medium")
    return (root, request, try GenerationCheckpoints.prepare(request))
  }

  private func complete(_ stage: String, in store: GenerationCheckpoints) throws {
    for name in GenerationCheckpoints.artifacts(for: stage, mode: store.context.mode) {
      try "# \(stage)\n\n有来源支持的内容".write(
        to: store.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let marker = try store.makeMarker(for: stage)
    try GenerationCheckpoints.encode(marker).write(
      to: store.root.appendingPathComponent("checkpoints/\(stage).json"), options: .atomic)
  }

  private func nextRequest(_ request: CodexRequest, in root: URL, stage: String? = nil)
    -> CodexRequest
  {
    CodexRequest(
      sourceID: request.sourceID, title: request.title, sourceURL: request.sourceURL,
      contentPath: request.contentPath,
      outputDirectory: root.appendingPathComponent(UUID().uuidString).path,
      mode: request.mode, model: request.model, style: request.style, depth: request.depth,
      reasoningEffort: request.reasoningEffort, fastMode: request.fastMode,
      resumeDirectory: request.outputDirectory,
      retryFrom: stage, sourceDirectory: request.sourceDirectory)
  }

  func testChangingSpeedKeepsValidatedContentCheckpointsReusable() throws {
    let (root, request, store) = try fixture()
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    try complete("analyze", in: store)
    var retry = nextRequest(request, in: root, stage: "draft")
    retry.fastMode = true
    let resumed = try GenerationCheckpoints.prepare(retry)
    XCTAssertEqual(resumed.reusedStages, ["analyze"])
    XCTAssertEqual(resumed.nextStage, "draft")
    XCTAssertEqual(resumed.context.fingerprint, store.context.fingerprint)
  }

  func testMalformedPartialAndUnknownArtifactMarkersAreIgnored() throws {
    let (_, _, store) = try fixture()
    try complete("analyze", in: store)
    let marker = store.root.appendingPathComponent("checkpoints/analyze.json")
    let valid = try Data(contentsOf: marker)
    for text in ["{", "{}", String(repeating: " ", count: 4097)] {
      try text.write(to: marker, atomically: true, encoding: .utf8)
      XCTAssertEqual(store.validStages(), [])
    }
    for artifacts in [
      ["../source.md"], [store.root.appendingPathComponent("analysis.md").path],
      ["analysis.md", "extra.md"],
    ] {
      let invalid = GenerationCheckpoints.Marker(
        version: GenerationCheckpoints.schemaVersion, stage: "analyze", status: "completed",
        fingerprint: store.context.fingerprint, artifacts: artifacts,
        sha256: Dictionary(
          uniqueKeysWithValues: artifacts.map { ($0, String(repeating: "0", count: 64)) }))
      try GenerationCheckpoints.encode(invalid).write(to: marker, options: .atomic)
      XCTAssertEqual(store.validStages(), [])
    }
    try valid.write(to: marker, options: .atomic)
    XCTAssertEqual(store.validStages(), ["analyze"])
  }

  func testRequiredFilesMustBeNonemptyAndStagesContiguous() throws {
    let (_, _, store) = try fixture()
    try complete("draft", in: store)
    XCTAssertEqual(store.validStages(), [])
    try complete("analyze", in: store)
    XCTAssertEqual(store.validStages(), ["analyze", "draft"])
    let draft = store.root.appendingPathComponent("draft.md")
    try " \n\t".write(to: draft, atomically: true, encoding: .utf8)
    XCTAssertEqual(store.validStages(), ["analyze"])
    try Data([0xFF, 0xFE]).write(to: draft, options: .atomic)
    XCTAssertEqual(store.validStages(), ["analyze"])
    try FileManager.default.moveItem(
      at: draft, to: store.root.appendingPathComponent("invalid-draft.bin"))
    XCTAssertEqual(store.validStages(), ["analyze"])
  }

  func testSymlinkArtifactsAndMarkersAreRejected() throws {
    let (root, _, store) = try fixture()
    try complete("analyze", in: store)
    let analysis = store.root.appendingPathComponent("analysis.md")
    try FileManager.default.moveItem(at: analysis, to: root.appendingPathComponent("outside.md"))
    try FileManager.default.createSymbolicLink(
      at: analysis, withDestinationURL: root.appendingPathComponent("outside.md"))
    XCTAssertEqual(store.validStages(), [])

    let (_, _, another) = try fixture()
    try complete("analyze", in: another)
    let marker = another.root.appendingPathComponent("checkpoints/analyze.json")
    let outsideMarker = root.appendingPathComponent("outside-marker.json")
    try FileManager.default.moveItem(at: marker, to: outsideMarker)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outsideMarker)
    XCTAssertEqual(another.validStages(), [])
  }

  func testRetryCopiesOnlyValidatedPredecessorsAndFallsBackToMissingStage() throws {
    let (root, request, store) = try fixture()
    for stage in GenerationCheckpoints.stages { try complete(stage, in: store) }
    let originalDraft = try Data(contentsOf: store.root.appendingPathComponent("draft.md"))
    let retryDraft = try GenerationCheckpoints.prepare(
      nextRequest(request, in: root, stage: "draft"))
    XCTAssertEqual(retryDraft.reusedStages, ["analyze"])
    XCTAssertEqual(retryDraft.nextStage, "draft")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: retryDraft.root.appendingPathComponent("draft.md").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: retryDraft.root.appendingPathComponent("note.md").path)
    )
    XCTAssertEqual(
      try Data(contentsOf: store.root.appendingPathComponent("draft.md")), originalDraft)

    try "".write(
      to: store.root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
    let retryReview = try GenerationCheckpoints.prepare(
      nextRequest(request, in: root, stage: "review"))
    XCTAssertEqual(retryReview.reusedStages, ["analyze"])
    XCTAssertEqual(retryReview.nextStage, "draft")
    XCTAssertTrue(retryReview.resumeMessage?.contains("前序检查点不完整") == true)
  }

  func testSourceAndConfigurationChangesInvalidateReuse() throws {
    let (root, request, store) = try fixture()
    try complete("analyze", in: store)
    XCTAssertEqual(
      try GenerationCheckpoints.reusableStages(in: store.root.path, for: request), ["analyze"])
    let source = try Data(contentsOf: URL(fileURLWithPath: request.contentPath))
    func context(
      sourceID: String = "source-1", mode: String = "markdown", model: String = "test-model",
      style: String = "清晰", depth: String = "适中", reasoning: String = "medium",
      visualStyle: GenerationVisualStyle = .dark
    ) throws -> GenerationCheckpoints.Context {
      try GenerationCheckpoints.makeContext(
        CodexRequest(
          sourceID: sourceID, title: request.title,
          sourceURL: request.sourceURL, contentPath: request.contentPath,
          outputDirectory: request.outputDirectory,
          mode: mode, model: model, style: style, depth: depth, reasoningEffort: reasoning,
          visualStyle: visualStyle),
        source: source)
    }
    for changed in [
      try context(sourceID: "other"), try context(mode: "html"), try context(model: "other"),
      try context(style: "简洁"), try context(depth: "深入"), try context(reasoning: "high"),
    ] {
      XCTAssertNotEqual(changed.fingerprint, store.context.fingerprint)
      XCTAssertEqual(
        GenerationCheckpoints(
          root: store.root, context: changed, reusedStages: [], resumeMessage: nil
        ).validStages(), [])
    }
    for mode in ["html", "image"] {
      XCTAssertNotEqual(try context(mode: mode), try context(mode: mode, visualStyle: .light))
    }
    XCTAssertEqual(try context(visualStyle: .light), store.context)
    try "新的来源内容".write(toFile: request.contentPath, atomically: true, encoding: .utf8)
    let retry = try GenerationCheckpoints.prepare(nextRequest(request, in: root, stage: "review"))
    XCTAssertEqual(retry.reusedStages, [])
    XCTAssertEqual(retry.nextStage, "analyze")
    XCTAssertTrue(retry.resumeMessage?.contains("已变化") == true)
    XCTAssertEqual(try String(contentsOf: store.sourceURL, encoding: .utf8), "来源正文与证据")
  }

  func testSnapshotMutationAndMissingRunIdentityPreventSaveReuse() throws {
    let (root, request, store) = try fixture()
    for stage in GenerationCheckpoints.stages { try complete(stage, in: store) }
    let retry = try GenerationCheckpoints.prepare(nextRequest(request, in: root, stage: "save"))
    XCTAssertEqual(retry.reusedStages, ["analyze", "draft"])
    XCTAssertEqual(retry.nextStage, "review")
    try "篡改后的快照".write(to: store.sourceURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(store.validStages(), [])
  }

  func testExistingAttemptCannotBeOverwritten() throws {
    let (_, request, store) = try fixture()
    let snapshot = try Data(contentsOf: store.sourceURL)
    XCTAssertThrowsError(try GenerationCheckpoints.prepare(request))
    XCTAssertEqual(try Data(contentsOf: store.sourceURL), snapshot)
  }

  func testApplicationOwnedWritesCannotFollowCheckpointDirectoryOutsideRun() throws {
    let (root, _, store) = try fixture()
    let checkpoints = store.root.appendingPathComponent("checkpoints")
    let preserved = store.root.appendingPathComponent("original-checkpoints")
    try FileManager.default.moveItem(at: checkpoints, to: preserved)
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: checkpoints, withDestinationURL: outside)
    XCTAssertThrowsError(
      try GenerationCheckpoints.writeOwnedFile(
        Data("[]".utf8),
        name: "checkpoints/history.json", root: store.root))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("history.json").path))
  }

  func testAgentStagesKeepDistinctDeliverables() {
    let applicationFiles = Set([
      GenerationCheckpoints.sourceName, GenerationCheckpoints.helperName, "codex-run.json",
      "checkpoints/context.json", "checkpoints/history.json",
    ])
    for mode in ["markdown", "html", "image"] {
      let names = GenerationCheckpoints.stages.flatMap {
        GenerationCheckpoints.artifacts(for: $0, mode: mode)
      }
      XCTAssertEqual(
        Set(names).count, names.count, "Later stages must not overwrite a predecessor artifact")
      XCTAssertTrue(Set(names).isDisjoint(with: applicationFiles))
    }
  }

  func testContentHashesRejectModifiedAndPartiallyRestoredArtifacts() throws {
    let (root, request, store) = try fixture()
    for stage in GenerationCheckpoints.stages { try complete(stage, in: store) }
    let draft = store.root.appendingPathComponent("draft.md")
    try "仍是有效文本，但与已完成的草稿不同".write(to: draft, atomically: true, encoding: .utf8)
    XCTAssertNoThrow(try store.validArtifact("draft.md"))
    XCTAssertEqual(store.validStages(), ["analyze"])
    let retry = try GenerationCheckpoints.prepare(nextRequest(request, in: root, stage: "review"))
    XCTAssertEqual(retry.reusedStages, ["analyze"])
    XCTAssertEqual(retry.nextStage, "draft")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: retry.root.appendingPathComponent("draft.md").path))
    try "部".write(
      to: store.root.appendingPathComponent("analysis.md"), atomically: true, encoding: .utf8)
    XCTAssertNoThrow(try store.validArtifact("analysis.md"))
    XCTAssertEqual(store.validStages(), [])
  }

  func testRefreshedImageDirectoryInvalidatesAnalysisEvenWithIdenticalText() throws {
    let (root, request, store) = try fixture()
    try complete("analyze", in: store)
    var next = nextRequest(request, in: root, stage: "draft")
    next.sourceDirectory = root.appendingPathComponent("refreshed-source").path
    let retry = try GenerationCheckpoints.prepare(next)
    XCTAssertEqual(retry.context.sourceSHA256, store.context.sourceSHA256)
    XCTAssertNotEqual(retry.context.fingerprint, store.context.fingerprint)
    XCTAssertEqual(retry.reusedStages, [])
    XCTAssertEqual(retry.nextStage, "analyze")
  }

  func testPreImageReviewProtocolCannotReuseAnalysis() throws {
    let (root, request, store) = try fixture()
    try complete("analyze", in: store)
    let contextURL = store.root.appendingPathComponent("checkpoints/context.json")
    var context = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: contextURL)) as? [String: Any])
    context["version"] = 2
    try JSONSerialization.data(withJSONObject: context).write(to: contextURL, options: .atomic)
    let retry = try GenerationCheckpoints.prepare(nextRequest(request, in: root, stage: "draft"))
    XCTAssertEqual(retry.reusedStages, [])
    XCTAssertEqual(retry.nextStage, "analyze")
  }

  func testMarkersWithoutHashesCannotBeReused() throws {
    let (_, _, store) = try fixture()
    try complete("analyze", in: store)
    let markerURL = store.root.appendingPathComponent("checkpoints/analyze.json")
    let marker = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
    for version in [1, GenerationCheckpoints.schemaVersion] {
      var old = marker
      old["version"] = version
      old.removeValue(forKey: "sha256")
      try JSONSerialization.data(withJSONObject: old).write(to: markerURL, options: .atomic)
      XCTAssertEqual(store.validStages(), [])
    }
  }

  private func runHelper(_ stage: String, in store: GenerationCheckpoints) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      store.root.appendingPathComponent(GenerationCheckpoints.helperName).path, stage,
    ]
    process.currentDirectoryURL = store.root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  func testLocalHelperRecordsHashesAndInvalidatesDependentReceipts() throws {
    let (_, _, store) = try fixture()
    for stage in GenerationCheckpoints.stages {
      for name in GenerationCheckpoints.artifacts(for: stage, mode: "markdown") {
        try "\(stage) 的来源证据".write(
          to: store.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
      }
      XCTAssertEqual(try runHelper(stage, in: store), 0)
    }
    XCTAssertEqual(store.validStages(), GenerationCheckpoints.stages)
    let marker = try JSONDecoder().decode(
      GenerationCheckpoints.Marker.self,
      from: Data(contentsOf: store.root.appendingPathComponent("checkpoints/draft.json")))
    XCTAssertEqual(marker.version, GenerationCheckpoints.schemaVersion)
    XCTAssertEqual(
      marker.sha256,
      ["draft.md": try GenerationCheckpoints.fileDigest("draft.md", root: store.root)])
    let oldDraftMarker = try Data(
      contentsOf: store.root.appendingPathComponent("checkpoints/draft.json"))
    try "修正后的分析证据".write(
      to: store.root.appendingPathComponent("analysis.md"), atomically: true, encoding: .utf8)
    XCTAssertNotEqual(
      try runHelper("draft", in: store), 0, "A changed predecessor must be re-recorded first")
    XCTAssertEqual(try runHelper("analyze", in: store), 0)
    XCTAssertEqual(store.validStages(), ["analyze"])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.root.appendingPathComponent("checkpoints/draft.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.root.appendingPathComponent("checkpoints/review.json").path))
    let archived = try FileManager.default.contentsOfDirectory(
      at: store.root.appendingPathComponent("checkpoints/superseded"),
      includingPropertiesForKeys: nil)
    XCTAssertTrue(try archived.contains { try Data(contentsOf: $0) == oldDraftMarker })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: store.root.appendingPathComponent("draft.md").path))
  }
}
