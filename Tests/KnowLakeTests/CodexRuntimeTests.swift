import Darwin
import Foundation
import XCTest

@testable import KnowLake

private final class RecordedCodexProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [CodexProgress] = []
  func append(_ value: CodexProgress) {
    lock.lock()
    defer { lock.unlock() }
    values.append(value)
  }
  var events: [CodexProgress] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

final class CodexRuntimeTests: XCTestCase {
  private func fixture(_ scenario: String) throws -> (CodexRuntime, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowlake-rpc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("fake-codex")
    try "Fixture skill".write(
      to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let python = """
      #!/usr/bin/python3
      import json, os, sys, subprocess, base64, time, shutil
      scenario = '\(scenario)'
      skill_path = os.path.join(os.path.dirname(__file__), 'SKILL.md')
      def send(message):
          data = (json.dumps(message, ensure_ascii=False) + '\\n').encode('utf-8')
          # Split writes exercise framing, including Unicode content.
          middle = max(1, len(data) // 2)
          os.write(1, data[:middle])
          os.write(1, data[middle:])
      def checkpoint(stage, artifacts):
          if scenario == 'markerless': return
          path = os.path.join('checkpoints', stage + '.json')
          if os.path.exists(path): return
          subprocess.run([sys.executable, 'checkpoint.py', stage], check=True, stdout=subprocess.DEVNULL)
      for line in sys.stdin:
          message = json.loads(line)
          method = message.get('method')
          params = message.get('params', {})
          with open(os.path.join(os.path.dirname(__file__), 'rpc.jsonl'), 'a') as handle:
              handle.write(json.dumps({'method':method}) + '\\n')
          result = None
          if method == 'initialize': result = {'userAgent': 'fixture'}
          elif method == 'model/list': result = {'data': [{'id': 'test-model', 'displayName': '测试模型', 'supportedReasoningEfforts':[{'reasoningEffort':'low'},{'reasoningEffort':'high'}], 'defaultReasoningEffort':'high'}]}
          elif method == 'skills/list': result = {'data': [{'skills': [
              {'name':'lieflat-less-ai-tone','path':skill_path,'enabled':scenario != 'disabled-skill'},
              {'name':'imagegen','path':skill_path,'enabled':True}]}]}
          elif method == 'thread/start':
              profile = params['config']['permissions'][params['permissions']]
              writable = [path for path, access in profile['filesystem'].items() if access == 'write']
              assert params['permissions'] == 'knowlake-generation'
              assert profile['network']['enabled'] is False
              assert params['approvalPolicy'] == 'never'
              result = {'thread': {'id': 'thread-test'}, 'model': 'test-model'}
          elif method == 'turn/start':
              if scenario == 'effort': assert params['effort'] == 'high'
              expected_skill = 'imagegen' if scenario == 'image' else 'lieflat-less-ai-tone'
              skills = [item for item in params['input'] if item['type'] == 'skill']
              assert [item['name'] for item in skills] == [expected_skill]
              assert os.path.isfile(skills[0]['path'])
              assert '$' + expected_skill in params['input'][0]['text']
              open('turn-input.json', 'w').write(json.dumps(params['input']))
              assert [os.path.realpath(p) for p in writable] == [os.path.realpath(os.getcwd())]
              send({'id': message['id'], 'result': {'turn': {'id': 'turn-test', 'status': 'inProgress'}}})
              open('started', 'w').write(str(os.getpid()))
              if scenario == 'wait':
                  open('analysis.md', 'w').write('来源分析与证据')
                  checkpoint('analyze', ['analysis.md'])
                  child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
                  open('child', 'w').write(str(child.pid))
                  continue
              if scenario == 'approval':
                  send({'id': 77, 'method': 'item/commandExecution/requestApproval', 'params': {'command': 'outside operation'}})
                  continue
              if scenario == 'failed':
                  send({'method': 'thread/tokenUsage/updated', 'params': {'threadId': 'thread-test', 'tokenUsage': {'total': {'inputTokens': 42, 'outputTokens': 3}}}})
                  send({'method': 'turn/completed', 'params': {'threadId': 'thread-test', 'turn': {'id': 'turn-test', 'status': 'failed', 'error': {'message': 'fixture failure'}}}})
                  continue
              mode = json.load(open('checkpoints/context.json'))['mode']
              if not os.path.exists('checkpoints/analyze.json'):
                  open('analysis.md', 'w').write('来源分析与证据')
                  checkpoint('analyze', ['analysis.md'])
              if scenario in ['staged', 'tamper']: time.sleep(0.8)
              if not os.path.exists('checkpoints/draft.json'):
                  if mode == 'html':
                      open('draft.html', 'w').write('<html><body><h1>测试看板</h1></body></html>')
                      checkpoint('draft', ['draft.html'])
                  elif mode == 'image':
                      open('image-plan.md', 'w').write('构图与证据')
                      open('draft.png', 'wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII='))
                      checkpoint('draft', ['image-plan.md', 'draft.png'])
                  else:
                      open('draft.md', 'w').write('# 标题\\n\\n测试笔记。')
                      checkpoint('draft', ['draft.md'])
              if scenario == 'partial':
                  send({'method': 'turn/completed', 'params': {'threadId': 'thread-test', 'turn': {'id': 'turn-test', 'status': 'failed', 'error': {'message': 'partial failure'}}}})
                  continue
              if scenario != 'missing':
                  if mode == 'html': shutil.copyfile('draft.html', 'board.html')
                  elif mode == 'image': shutil.copyfile('draft.png', 'cover.png')
                  else: shutil.copyfile('draft.md', 'note.md')
                  checkpoint('review', [{'html':'board.html', 'image':'cover.png'}.get(mode, 'note.md')])
              if scenario == 'tamper':
                  open('analysis.md', 'w').write('已经改写但仍是有效文本')
                  time.sleep(0.8)
              send({'method': 'item/agentMessage/delta', 'params': {'threadId': 'thread-test', 'delta': '正在整理中文材料', 'itemId':'message-test'}})
              send({'method': 'thread/tokenUsage/updated', 'params': {'threadId': 'thread-test', 'tokenUsage': {'total': {'inputTokens': 42}}}})
              open('turn-finished', 'w').write('yes')
              send({'method': 'turn/completed', 'params': {'threadId': 'thread-test', 'turn': {'id': 'turn-test', 'status': 'completed'}}})
              continue
          if result is not None: send({'id': message['id'], 'result': result})
      """
    try python.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (CodexRuntime(executable: script.path), root)
  }

  private func request(_ root: URL, mode: String = "markdown") throws -> CodexRequest {
    let source = root.appendingPathComponent("source.md")
    try "原始正文".write(to: source, atomically: true, encoding: .utf8)
    return CodexRequest(
      sourceID: "source-1", title: "标题", sourceURL: "https://example.org/source",
      contentPath: source.path, outputDirectory: root.appendingPathComponent("output").path,
      mode: mode, model: "test-model", style: "清晰", depth: "适中")
  }

  func testHandshakeAndUnicodeModelList() async throws {
    let (runtime, _) = try fixture("normal")
    let models = try await runtime.models()
    XCTAssertEqual(models.map(\.id), ["test-model"])
    XCTAssertEqual(models.first?.name, "测试模型")
    XCTAssertEqual(models.first?.efforts, ["low", "high"])
    XCTAssertEqual(models.first?.defaultEffort, "high")
  }

  func testCompletionRequiresArtifactAndStoresUsage() async throws {
    let (runtime, root) = try fixture("normal")
    let output = try await runtime.generate(request(root), onEvent: { _ in })
    XCTAssertEqual(output.kind, "markdown")
    XCTAssertEqual(output.runID, "turn-test")
    XCTAssertTrue(try String(contentsOfFile: output.path, encoding: .utf8).contains("测试笔记"))
    let record = root.appendingPathComponent("output/codex-run.json")
    let data = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
    XCTAssertEqual(data["harness"] as? String, "codex")
    XCTAssertNotNil(data["usage"])
  }

  func testReasoningEffortIsSentAndRecorded() async throws {
    let (runtime, root) = try fixture("effort")
    var input = try request(root)
    input.reasoningEffort = "high"
    _ = try await runtime.generate(input, onEvent: { _ in })
    let data = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("output/codex-run.json")))
        as? [String: Any])
    XCTAssertEqual(data["reasoning_effort"] as? String, "high")
  }

  func testWritingModesReceiveExplicitCleanupSkillAndRecordIt() async throws {
    for mode in ["markdown", "html"] {
      let (runtime, root) = try fixture(mode)
      let output = try await runtime.generate(request(root, mode: mode), onEvent: { _ in })
      XCTAssertEqual(output.kind, mode)
      let inputs = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: root.appendingPathComponent("output/turn-input.json")))
          as? [[String: Any]])
      XCTAssertEqual(
        inputs.filter { $0["type"] as? String == "skill" }.first?["name"] as? String,
        "lieflat-less-ai-tone")
      let prompt = try XCTUnwrap(inputs.first?["text"] as? String)
      XCTAssertTrue(prompt.contains("knowlake-source://source-1#segment-N"))
      XCTAssertTrue(prompt.contains("copy an existing N exactly"))
      XCTAssertTrue(prompt.contains("KnowLake owns citation styling"))
      if mode == "html" {
        XCTAssertTrue(prompt.contains("Do not create a separate source/evidence section"))
        XCTAssertTrue(prompt.contains("<sup><a href=\"knowlake-source://source-1#segment-N\">[N]</a></sup>"))
      }
      let record = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: root.appendingPathComponent("output/codex-run.json")))
          as? [String: Any])
      XCTAssertEqual(record["skills"] as? [String], ["lieflat-less-ai-tone"])
    }
  }

  func testDisabledWritingSkillStopsBeforeGeneration() async throws {
    let (runtime, root) = try fixture("disabled-skill")
    do {
      _ = try await runtime.generate(request(root), onEvent: { _ in })
      XCTFail("Required writing review must not be skipped")
    } catch { XCTAssertTrue(error.localizedDescription.contains("lieflat-less-ai-tone")) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("output/started").path))
  }

  func testImageGenerationUsesCodexImageSkill() async throws {
    let (runtime, root) = try fixture("image")
    let output = try await runtime.generate(request(root, mode: "image"), onEvent: { _ in })
    XCTAssertEqual(output.kind, "image")
    let record = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("output/codex-run.json")))
        as? [String: Any])
    XCTAssertEqual(record["harness"] as? String, "codex")
    XCTAssertEqual(record["skills"] as? [String], ["imagegen"])
  }

  func testVisualModesUseTheSelectedPalette() async throws {
    for mode in ["html", "image"] {
      for style in [GenerationVisualStyle.dark, .light] {
        let (runtime, root) = try fixture(mode)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        var input = try request(root, mode: mode)
        if style == .light { input.visualStyle = .light }
        _ = try await runtime.generate(input, onEvent: { _ in })
        let inputs = try XCTUnwrap(
          JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("output/turn-input.json")))
            as? [[String: Any]])
        let prompt = try XCTUnwrap(inputs.first?["text"] as? String)
        XCTAssertEqual(prompt.contains("Use a dark visual theme"), style == .dark)
        XCTAssertEqual(prompt.contains("Use a light visual theme"), style == .light)
        if mode == "html" {
          XCTAssertTrue(prompt.contains("Set CSS color-scheme to \(style.rawValue)"))
          XCTAssertTrue(prompt.contains("Define a high-contrast --accent color"))
        } else {
          XCTAssertTrue(prompt.contains("selected palette and text-contrast requirements above, to $imagegen"))
          XCTAssertFalse(prompt.contains("the light neutral background, dark text"))
        }
        let record = try XCTUnwrap(
          JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("output/codex-run.json")))
            as? [String: Any])
        XCTAssertEqual(record["visual_style"] as? String, style.rawValue)
      }
    }
  }

  func testEveryOutputModeReceivesSourceImageReviewBeforeDrafting() async throws {
    for mode in ["markdown", "html", "image"] {
      let (runtime, root) = try fixture(mode)
      _ = try await runtime.generate(request(root, mode: mode), onEvent: { _ in })
      let inputs = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: root.appendingPathComponent("output/turn-input.json")))
          as? [[String: Any]])
      let prompt = try XCTUnwrap(inputs.first?["text"] as? String)
      if mode == "markdown" {
        XCTAssertFalse(prompt.contains("visual theme"))
      }
      XCTAssertTrue(prompt.contains("Make one focused final review"))
      XCTAssertTrue(prompt.contains("do not independently compute or compare hashes"))
      XCTAssertTrue(prompt.contains("A successful exit completes that checkpoint"))
      XCTAssertFalse(prompt.contains("computes every required artifact's SHA-256"))
      let analyze = try XCTUnwrap(prompt.range(of: "1. analyze:"))
      let viewImages = try XCTUnwrap(prompt.range(of: "open and visually inspect every distinct available source image with view_image"))
      let draft = try XCTUnwrap(prompt.range(of: "2. draft:"))
      XCTAssertLessThan(analyze.lowerBound, viewImages.lowerBound)
      XCTAssertLessThan(viewImages.lowerBound, draft.lowerBound)
      XCTAssertTrue(prompt.contains("In analysis.md, record each image's source path"))
      XCTAssertTrue(prompt.contains("use the combined text and visual evidence in analysis.md"))
      XCTAssertTrue(prompt.contains("Do not treat inspecting the generated draft.png as a substitute"))
    }
  }

  func testAgentMessageProgressCarriesStreamIdentity() async throws {
    let (runtime, root) = try fixture("normal")
    let update = expectation(description: "typed stream event")
    _ = try await runtime.generate(
      request(root),
      onProgress: { event in
        if event.streamID == "message-test" { update.fulfill() }
      }, onEvent: { _ in })
    await fulfillment(of: [update], timeout: 2)
  }

  func testMissingArtifactDoesNotCountAsSuccess() async throws {
    let (runtime, root) = try fixture("missing")
    do {
      _ = try await runtime.generate(request(root), onEvent: { _ in })
      XCTFail("Missing artifact must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("未生成")) }
  }

  func testFailedTurnDoesNotCountAsSuccess() async throws {
    let (runtime, root) = try fixture("failed")
    let progress = RecordedCodexProgress()
    do {
      _ = try await runtime.generate(request(root), onProgress: { progress.append($0) }, onEvent: { _ in })
      XCTFail("Failed turn must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("fixture failure")) }
    XCTAssertEqual(progress.events.compactMap(\.metrics).last?.tokenUsage?["thread-test"]?.total, 45)
    let record = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: root.appendingPathComponent("output/codex-run.json"))) as? [String: Any])
    let encoded = try JSONSerialization.data(withJSONObject: try XCTUnwrap(record["task_metrics"]))
    XCTAssertEqual(try JSONDecoder().decode(TaskMetrics.self, from: encoded).tokenUsage?["thread-test"]?.total, 45)
  }

  func testPermissionRequestDoesNotHang() async throws {
    let (runtime, root) = try fixture("approval")
    do {
      _ = try await runtime.generate(request(root), onEvent: { _ in })
      XCTFail("Unattended permission escalation must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("额外授权")) }
  }

  func testCancellationStopsActiveRuntime() async throws {
    let (runtime, root) = try fixture("wait")
    let input = try request(root)
    let generation = Task { try await runtime.generate(input, onEvent: { _ in }) }
    let marker = root.appendingPathComponent("output/child")
    for _ in 0..<250 {
      if FileManager.default.fileExists(atPath: marker.path) { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    await runtime.cancel()
    do {
      _ = try await generation.value
      XCTFail("Cancelled generation must not succeed")
    } catch { XCTAssertTrue(error is CancellationError) }
    let childPID = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
    for _ in 0..<25 {
      if kill(childPID, 0) != 0 { break }
      try await Task.sleep(nanoseconds: 40_000_000)
    }
    XCTAssertNotEqual(kill(childPID, 0), 0, "Cancellation must stop child processes too")
  }

  func testArtifactCannotEscapeOutputDirectoryThroughSymlink() throws {
    let (_, root) = try fixture("normal")
    let source = root.appendingPathComponent("source.md")
    try "正文".write(to: source, atomically: true, encoding: .utf8)
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let link = output.appendingPathComponent("note.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    XCTAssertThrowsError(try CodexRuntime.validateArtifact(link, root: output, mode: "markdown"))
  }

  func testTextFileIsNotAcceptedAsGeneratedImage() throws {
    let (_, root) = try fixture("normal")
    let image = root.appendingPathComponent("cover.png")
    try "图片生成失败".write(to: image, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try CodexRuntime.validateArtifact(image, root: root, mode: "image"))
    try Data([137, 80, 78, 71, 13, 10, 26, 10]).write(to: image, options: .atomic)
    XCTAssertThrowsError(try CodexRuntime.validateArtifact(image, root: root, mode: "image"))
  }

  private func retryRequest(_ input: CodexRequest, output: URL, from stage: String? = nil)
    -> CodexRequest
  {
    CodexRequest(
      sourceID: input.sourceID, title: input.title, sourceURL: input.sourceURL,
      contentPath: input.contentPath, outputDirectory: output.path, mode: input.mode,
      model: input.model, style: input.style, depth: input.depth,
      reasoningEffort: input.reasoningEffort, resumeDirectory: input.outputDirectory,
      retryFrom: stage, sourceDirectory: input.sourceDirectory)
  }

  func testStageProgressArrivesBeforeSingleTurnCompletes() async throws {
    let (runtime, root) = try fixture("staged")
    let input = try request(root)
    let early = expectation(description: "analysis checkpoint before turn completes")
    let log = RecordedCodexProgress()
    _ = try await runtime.generate(
      input,
      onProgress: { event in
        log.append(event)
        if event.stage == "analyze", event.stageStatus == "completed" {
          XCTAssertFalse(
            FileManager.default.fileExists(
              atPath: root.appendingPathComponent("output/turn-finished").path))
          early.fulfill()
        }
      }, onEvent: { _ in })
    await fulfillment(of: [early], timeout: 2)
    let methods = try String(contentsOf: root.appendingPathComponent("rpc.jsonl"), encoding: .utf8)
      .split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
      }
    XCTAssertEqual(methods.filter { $0["method"] == "turn/start" }.count, 1)
    XCTAssertEqual(
      log.events.filter { $0.stageStatus == "completed" }.compactMap(\.stage),
      ["prepare", "analyze", "draft", "review", "save"])
    XCTAssertEqual(
      log.events.first { $0.stage == "analyze" && $0.stageStatus == "completed" }?.artifacts,
      [root.appendingPathComponent("output/analysis.md").path])
  }

  func testFailedAttemptResumesReviewAndPreservesOriginalFiles() async throws {
    let (failing, root) = try fixture("partial")
    let input = try request(root)
    do {
      _ = try await failing.generate(input, onEvent: { _ in })
      XCTFail("Fixture must fail after draft")
    } catch { XCTAssertTrue(error.localizedDescription.contains("partial failure")) }
    let oldDraft = root.appendingPathComponent("output/draft.md")
    let oldAnalysis = root.appendingPathComponent("output/analysis.md")
    let draftBytes = try Data(contentsOf: oldDraft)
    let analysisBytes = try Data(contentsOf: oldAnalysis)
    let oldHistory = try Data(
      contentsOf: root.appendingPathComponent("output/checkpoints/history.json"))
    let (runtime, _) = try fixture("normal")
    let retry = retryRequest(input, output: root.appendingPathComponent("retry"), from: "review")
    let log = RecordedCodexProgress()
    let result = try await runtime.generate(
      retry, onProgress: { log.append($0) }, onEvent: { _ in })
    XCTAssertTrue(result.path.hasSuffix("retry/note.md"))
    XCTAssertEqual(
      log.events.filter { $0.stageStatus == "reused" }.compactMap(\.stage), ["analyze", "draft"])
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("retry/draft.md")), draftBytes)
    XCTAssertEqual(try Data(contentsOf: oldDraft), draftBytes)
    XCTAssertEqual(try Data(contentsOf: oldAnalysis), analysisBytes)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("output/checkpoints/history.json")),
      oldHistory)
    let inputText = try String(
      contentsOf: root.appendingPathComponent("retry/turn-input.json"), encoding: .utf8)
    XCTAssertTrue(inputText.contains("Resume at stage: review"))
    XCTAssertTrue(inputText.contains("ONE continuous agent turn"))
  }

  func testSaveOnlyRetryReusesIdentityWithoutStartingAppServer() async throws {
    let (runtime, root) = try fixture("normal")
    let input = try request(root)
    let original = try await runtime.generate(input, onEvent: { _ in })
    let originalRecord = try Data(contentsOf: root.appendingPathComponent("output/codex-run.json"))
    let retry = retryRequest(
      input, output: root.appendingPathComponent("saved-retry"), from: "save")
    let unavailableRuntime = CodexRuntime(executable: "/does-not-exist-codex")
    let log = RecordedCodexProgress()
    let result = try await unavailableRuntime.generate(
      retry, onProgress: { log.append($0) }, onEvent: { _ in })
    XCTAssertEqual(result.runID, original.runID)
    XCTAssertEqual(result.model, original.model)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: result.path)),
      try Data(contentsOf: URL(fileURLWithPath: original.path)))
    XCTAssertEqual(
      log.events.filter { $0.stageStatus == "reused" }.compactMap(\.stage),
      ["analyze", "draft", "review"])
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("output/codex-run.json")), originalRecord)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("saved-retry/checkpoints/save.json").path))
  }

  func testImageReviewRetryPreservesDraftAndSaveRetryNeedsNoRPC() async throws {
    let (runtime, root) = try fixture("image")
    let input = try request(root, mode: "image")
    _ = try await runtime.generate(input, onEvent: { _ in })
    let draftURL = root.appendingPathComponent("output/draft.png")
    let originalDraft = try Data(contentsOf: draftURL)
    // An interrupted/corrupt review must leave the completed draft reusable.
    let originalFinal = root.appendingPathComponent("output/cover.png")
    try "incomplete final image".write(to: originalFinal, atomically: true, encoding: .utf8)
    XCTAssertEqual(
      try GenerationCheckpoints.reusableStages(in: input.outputDirectory, for: input),
      ["analyze", "draft"])
    let retry = retryRequest(
      input, output: root.appendingPathComponent("image-review"), from: "review")
    let log = RecordedCodexProgress()
    let reviewed = try await runtime.generate(
      retry, onProgress: { log.append($0) }, onEvent: { _ in })
    XCTAssertEqual(
      log.events.filter { $0.stageStatus == "reused" }.compactMap(\.stage), ["analyze", "draft"])
    XCTAssertEqual(try Data(contentsOf: draftURL), originalDraft)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("image-review/draft.png")), originalDraft)
    XCTAssertEqual(try String(contentsOf: originalFinal, encoding: .utf8), "incomplete final image")
    XCTAssertNoThrow(
      try CodexRuntime.validateArtifact(
        URL(fileURLWithPath: reviewed.path),
        root: URL(fileURLWithPath: retry.outputDirectory), mode: "image"))
    let save = retryRequest(retry, output: root.appendingPathComponent("image-save"), from: "save")
    let unavailableRuntime = CodexRuntime(executable: "/does-not-exist-codex")
    let saved = try await unavailableRuntime.generate(save, onEvent: { _ in })
    XCTAssertEqual(saved.runID, reviewed.runID)
    XCTAssertEqual(saved.model, reviewed.model)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: saved.path)),
      try Data(contentsOf: URL(fileURLWithPath: reviewed.path)))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("image-save/draft.png")), originalDraft)
  }

  func testMissingMarkersCannotClaimCompletedStages() async throws {
    let (runtime, root) = try fixture("markerless")
    let log = RecordedCodexProgress()
    do {
      _ = try await runtime.generate(
        request(root), onProgress: { log.append($0) }, onEvent: { _ in })
      XCTFail("Artifacts alone cannot stand in for completed checkpoints")
    } catch { XCTAssertTrue(error.localizedDescription.contains("阶段检查点")) }
    XCTAssertFalse(log.events.contains { $0.stage == "review" && $0.stageStatus == "completed" })
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("output/checkpoints/save.json").path))
  }

  func testChangedCompletedArtifactReportsFirstInvalidStageAndCannotSave() async throws {
    let (runtime, root) = try fixture("tamper")
    let log = RecordedCodexProgress()
    let invalidated = expectation(
      description: "first invalid stage is reported before turn completion")
    do {
      _ = try await runtime.generate(
        request(root),
        onProgress: { event in
          log.append(event)
          if event.stage == "analyze", event.stageStatus == "failed" {
            XCTAssertFalse(
              FileManager.default.fileExists(
                atPath: root.appendingPathComponent("output/turn-finished").path))
            invalidated.fulfill()
          }
        }, onEvent: { _ in })
      XCTFail("A completed marker cannot validate later changed bytes")
    } catch { XCTAssertTrue(error.localizedDescription.contains("分析来源")) }
    await fulfillment(of: [invalidated], timeout: 2)
    XCTAssertTrue(log.events.contains { $0.stage == "analyze" && $0.stageStatus == "completed" })
    XCTAssertFalse(log.events.contains { $0.stage == "save" && $0.stageStatus == "completed" })
    XCTAssertEqual(log.events.last { $0.stage == "analyze" }?.stageStatus, "failed")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("output/checkpoints/save.json").path))
  }

  func testCancellationStopsCheckpointObserverAndPreservesSnapshot() async throws {
    let (runtime, root) = try fixture("wait")
    let input = try request(root)
    let log = RecordedCodexProgress()
    let analysis = expectation(description: "analysis persisted while turn still active")
    let generation = Task {
      try await runtime.generate(
        input,
        onProgress: { progress in
          log.append(progress)
          if progress.stage == "analyze" && progress.stageStatus == "completed" {
            analysis.fulfill()
          }
        }, onEvent: { _ in })
    }
    await fulfillment(of: [analysis], timeout: 5)
    generation.cancel()
    do {
      _ = try await generation.value
      XCTFail("Cancelled task must fail")
    } catch { XCTAssertTrue(error is CancellationError) }
    let count = log.events.count
    let context = try JSONDecoder().decode(
      GenerationCheckpoints.Context.self,
      from: Data(contentsOf: root.appendingPathComponent("output/checkpoints/context.json")))
    try "迟到的草稿".write(
      to: root.appendingPathComponent("output/draft.md"), atomically: true, encoding: .utf8)
    let marker = GenerationCheckpoints.Marker(
      version: GenerationCheckpoints.schemaVersion, stage: "draft", status: "completed",
      fingerprint: context.fingerprint, artifacts: ["draft.md"],
      sha256: [
        "draft.md": try GenerationCheckpoints.fileDigest(
          "draft.md", root: root.appendingPathComponent("output"))
      ])
    try GenerationCheckpoints.encode(marker).write(
      to: root.appendingPathComponent("output/checkpoints/draft.json"), options: .atomic)
    try await Task.sleep(nanoseconds: 650_000_000)
    XCTAssertEqual(
      log.events.count, count, "A cancelled attempt must have no surviving checkpoint poller")
    XCTAssertEqual(
      try String(
        contentsOf: root.appendingPathComponent("output/source-snapshot.md"), encoding: .utf8),
      "原始正文")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("output/checkpoints/history.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("output/codex-run.json").path))
  }
}
