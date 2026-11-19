import Darwin
import Foundation
import XCTest

@testable import KnowLake

private final class BatchProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [(String, CodexProgress)] = []
  func append(_ mode: String, _ progress: CodexProgress) {
    lock.lock()
    defer { lock.unlock() }
    entries.append((mode, progress))
  }
  func completedStages(for mode: String) -> Set<String> {
    lock.lock()
    defer { lock.unlock() }
    return Set(entries.filter { $0.0 == mode && $0.1.stageStatus == "completed" }
      .compactMap { $0.1.stage })
  }
}

final class CodexBatchRuntimeTests: XCTestCase {
  private func fixture(_ scenario: String = "success", modes: [String] = ["markdown", "html", "image"],
    model: String = "gpt-6-astra", effort: String? = "ultra", fastMode: Bool = false)
    throws -> (CodexRuntime, URL, [CodexRequest])
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowlake-batch-rpc-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.md")
    try "# 来源\n\n有出处的资料。".write(to: source, atomically: true, encoding: .utf8)
    try "Fixture skill".write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let script = root.appendingPathComponent("fake-codex")
    let python = #"""
      #!/usr/bin/python3
      import json, os, sys, subprocess, shutil, base64
      scenario = '\#(scenario)'
      root = os.path.dirname(__file__)
      with open(os.path.join(root, 'processes.txt'), 'a') as handle: handle.write(str(os.getpid()) + '\n')
      instance = len(open(os.path.join(root, 'processes.txt')).readlines())
      turn_id = 'batch-turn' if instance == 1 else 'batch-turn-' + str(instance)
      def send(value):
          print(json.dumps(value), flush=True)
      def event(method, **params):
          send({'method': method, 'params': {'threadId': 'parent', **params}})
      for line in sys.stdin:
          message = json.loads(line)
          method = message.get('method')
          params = message.get('params', {})
          with open(os.path.join(root, 'rpc.jsonl'), 'a') as handle:
              handle.write(json.dumps({'method':method, 'params':params}) + '\n')
          result = None
          if method == 'initialize': result = {}
          elif method == 'config/read':
              result = {'config': {'agents': {'default_subagent_model': 'other-child-model',
                        'default_subagent_reasoning_effort': 'low'}}}
              if scenario == 'configured-defaults':
                  result['config'].update(model='configured-model', model_reasoning_effort='high')
          elif method == 'model/list':
              result = {'data': [{'id':'catalog-model', 'isDefault':True, 'defaultReasoningEffort':'medium'}],
                        'nextCursor':None}
          elif method == 'skills/list': result = {'data':[{'skills':[
              {'name':name, 'path':os.path.join(root, 'SKILL.md'), 'enabled':True}
              for name in ['lieflat-less-ai-tone','imagegen']]}]}
          elif method == 'thread/start':
              profile = params['config']['permissions'][params['permissions']]
              writable = [path for path, access in profile['filesystem'].items() if access == 'write']
              result = {'thread':{'id':'parent'}, 'model':params.get('model', 'gpt-6-astra'), 'serviceTier':params.get('serviceTier')}
          elif method == 'thread/read': result = {'thread':{'id':params['threadId'], 'forkedFromId':None}}
          elif method == 'turn/start':
              send({'id':message['id'], 'result':{'turn':{'id':turn_id, 'status':'inProgress'}}})
              open(os.path.join(root, 'started'), 'w').write(str(os.getpid()))
              if scenario == 'wait': continue
              by_mode = {'markdown': 0, 'html': 1, 'image': 2}
              def sort_mode(path):
                  context_file = os.path.join(path, 'checkpoints/context.json')
                  return by_mode[json.load(open(context_file))['mode']]
              directories = sorted(writable, key=sort_mode)
              for index, directory in enumerate(directories):
                  os.chdir(directory)
                  mode = json.load(open('checkpoints/context.json'))['mode']
                  if scenario != 'no-delegation':
                      if scenario == 'activity':
                          item = {'type':'subAgentActivity', 'kind':'started', 'agentThreadId':'child-'+mode,
                                  'agentPath':'/root/'+mode}
                      else:
                          item = {'type':'collabAgentToolCall', 'tool':'spawnAgent', 'status':'completed',
                                  'receiverThreadIds':['child-'+mode], 'senderThreadId':'parent',
                                  'prompt':'KNOWLAKE_OUTPUT_MODE='+mode}
                      event('item/completed', item={'id':'spawn-'+mode, **item})
                      send({'method':'thread/tokenUsage/updated','params':{'threadId':'child-'+mode,
                            'tokenUsage':{'total':{'inputTokens':100000*(index+1),'outputTokens':1000}}}})
                  if mode == 'image' and scenario in ['missing-image', 'failed-turn']: continue
                  open('analysis.md','w').write('来源分析与证据')
                  subprocess.run([sys.executable,'checkpoint.py','analyze'],check=True,stdout=subprocess.DEVNULL)
                  if mode == 'markdown':
                      open('draft.md','w').write('# 笔记\n\n来源支持的结论。')
                      draft, final = 'draft.md', 'note.md'
                  elif mode == 'html':
                      open('draft.html','w').write('<html><body><h1>知识看板</h1></body></html>')
                      draft, final = 'draft.html', 'board.html'
                  else:
                      open('image-plan.md','w').write('构图及来源证据')
                      open('draft.png','wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII='))
                      draft, final = 'draft.png', 'cover.png'
                  subprocess.run([sys.executable,'checkpoint.py','draft'],check=True,stdout=subprocess.DEVNULL)
                  shutil.copyfile(draft,final)
                  subprocess.run([sys.executable,'checkpoint.py','review'],check=True,stdout=subprocess.DEVNULL)
              event('thread/tokenUsage/updated', tokenUsage={'total':{'inputTokens':123}})
              event('turn/completed', turn={'id':turn_id,
                    'status':'failed' if scenario == 'failed-turn' else 'completed',
                    'error':{'message':'coordinator failed'} if scenario == 'failed-turn' else None})
              continue
          if result is not None: send({'id':message['id'],'result':result})
      """#
    try python.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let requests = modes.map { mode in
      CodexRequest(sourceID: "source", title: "来源", sourceURL: "https://example.com/source",
        contentPath: source.path, outputDirectory: root.appendingPathComponent(mode).path,
        mode: mode, model: model, style: "清晰", depth: "标准", reasoningEffort: effort,
        fastMode: fastMode)
    }
    return (CodexRuntime(executable: script.path), root, requests)
  }

  private func rpc(_ root: URL) throws -> [[String: Any]] {
    try String(contentsOf: root.appendingPathComponent("rpc.jsonl"), encoding: .utf8)
      .split(separator: "\n").map {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
      }
  }

  func testThreeOutputsUseOneAstraUltraSessionWithDelegationAndSeparateCheckpoints() async throws {
    let (runtime, root, defaults) = try fixture()
    let requests = defaults.map { request in
      var request = request
      if request.mode == "image" { request.visualStyle = .light }
      return request
    }
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let progress = BatchProgressLog()
    let outputs = try await runtime.generateBatch(requests, onProgress: { progress.append($0, $1) })
    XCTAssertEqual(Set(outputs.keys), ["markdown", "html", "image"])
    for request in requests {
      let output = try XCTUnwrap(outputs[request.mode]).get()
      XCTAssertEqual(output.runID, "batch-turn")
      XCTAssertEqual(output.model, "gpt-6-astra")
      XCTAssertEqual(output.kind, request.mode)
      XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
      XCTAssertTrue(progress.completedStages(for: request.mode).isSuperset(of: ["prepare", "analyze", "draft", "review", "save"]))
      let checkpoint = try GenerationCheckpoints.makeContext(request, source: Data(contentsOf: root.appendingPathComponent("source.md")))
      let stored = GenerationCheckpoints(root: URL(fileURLWithPath: request.outputDirectory), context: checkpoint, reusedStages: [], resumeMessage: nil)
      XCTAssertTrue(stored.validMarker("save"))
      XCTAssertEqual(stored.runRecord()?["orchestration"] as? String, "subagents")
      XCTAssertEqual(stored.runRecord()?["visual_style"] as? String,
        ["html": "dark", "image": "light"][request.mode])
      XCTAssertEqual(stored.runRecord()?["subagent_thread_ids"] as? [String], ["child-html", "child-image", "child-markdown"])
      XCTAssertEqual(stored.runRecord()?["usage_scope"] as? String, "shared_batch")
      let savedMetrics = try XCTUnwrap(stored.runRecord()?["task_metrics"] as? [String: Any])
      let metrics = try JSONDecoder().decode(TaskMetrics.self,
        from: JSONSerialization.data(withJSONObject: savedMetrics))
      XCTAssertEqual(metrics.tokenUsage?["child-" + request.mode]?.total,
        Int64((requests.firstIndex { $0.mode == request.mode }! + 1) * 100_000 + 1_000))
      XCTAssertEqual(metrics.sharedTokenUsage["parent"]?.total, 123)
    }
    let calls = try rpc(root)
    for method in ["initialize", "thread/start", "turn/start"] {
      XCTAssertEqual(calls.filter { $0["method"] as? String == method }.count, 1)
    }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("processes.txt")).split(separator: "\n").count, 1)
    XCTAssertFalse(calls.contains { $0["method"] as? String == "config/read" })
    XCTAssertFalse(calls.contains { $0["method"] as? String == "model/list" })
    XCTAssertEqual(calls.filter { $0["method"] as? String == "thread/read" }.count, 3)
    XCTAssertFalse(calls.contains { $0["method"] as? String == "thread/resume" })
    let thread = try XCTUnwrap(calls.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
    XCTAssertEqual(thread["model"] as? String, "gpt-6-astra")
    XCTAssertEqual(thread["serviceTier"] as? String, "default")
    let config = try XCTUnwrap(thread["config"] as? [String: Any])
    XCTAssertEqual(config["features.multi_agent"] as? Bool, true)
    XCTAssertEqual(config["agents.enabled"] as? Bool, true)
    XCTAssertEqual(config["agents.max_concurrent_threads_per_session"] as? Int, 3)
    XCTAssertEqual(config["agents.default_subagent_model"] as? String, "gpt-6-astra")
    XCTAssertEqual(config["agents.default_subagent_reasoning_effort"] as? String, "ultra")
    XCTAssertEqual(config["service_tier"] as? String, "default")
    let turn = try XCTUnwrap(calls.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
    XCTAssertEqual(turn["effort"] as? String, "ultra")
    XCTAssertEqual(turn["serviceTier"] as? String, "default")
    let inputs = try XCTUnwrap(turn["input"] as? [[String: Any]])
    XCTAssertEqual(Set(inputs.filter { $0["type"] as? String == "skill" }.compactMap { $0["name"] as? String }), ["imagegen", "lieflat-less-ai-tone"])
    let prompt = try XCTUnwrap(inputs.first?["text"] as? String)
    XCTAssertTrue(prompt.contains("launch ALL children before waiting"))
    XCTAssertTrue(prompt.contains("Rely on each child's completed review"))
    XCTAssertFalse(prompt.contains("inspect each reported final artifact"))
    XCTAssertTrue((thread["developerInstructions"] as? String)?.contains("Do not repeat successful children's reviews") == true)
    let htmlAssignment = try XCTUnwrap(prompt.components(separatedBy: "BEGIN CHILD ASSIGNMENT: html").last)
      .components(separatedBy: "END CHILD ASSIGNMENT: html")[0]
    XCTAssertTrue(htmlAssignment.contains("knowlake-source://source#segment-N"))
    XCTAssertTrue(htmlAssignment.contains("Do not create a separate source/evidence section"))
    XCTAssertTrue(htmlAssignment.contains("KnowLake owns citation styling"))
    for request in requests {
      XCTAssertTrue(prompt.contains("BEGIN CHILD ASSIGNMENT: " + request.mode))
      XCTAssertTrue(prompt.contains(request.outputDirectory))
      let assignment = try XCTUnwrap(prompt.components(separatedBy: "BEGIN CHILD ASSIGNMENT: " + request.mode).last)
        .components(separatedBy: "END CHILD ASSIGNMENT: " + request.mode)[0]
      XCTAssertEqual(assignment.contains("Use a dark visual theme"), request.mode == "html")
      XCTAssertEqual(assignment.contains("Use a light visual theme"), request.mode == "image")
      XCTAssertTrue(assignment.contains("do not independently compute or compare hashes"))
    }
    await runtime.cancel()
  }

  func testBatchUsesSharedSelectedModelEffortAndFastMode() async throws {
    let (runtime, root, requests) = try fixture(modes: ["markdown", "html"],
      model: "selected-model", effort: "high", fastMode: true)
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let outputs = try await runtime.generateBatch(requests)
    for request in requests {
      XCTAssertEqual(try XCTUnwrap(outputs[request.mode]).get().model, "selected-model")
      let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
        URL(fileURLWithPath: request.outputDirectory).appendingPathComponent("codex-run.json"))) as? [String: Any])
      XCTAssertEqual(record["model"] as? String, "selected-model")
      XCTAssertEqual(record["reasoning_effort"] as? String, "high")
      XCTAssertEqual(record["service_tier"] as? String, "priority")
    }
    let calls = try rpc(root)
    let thread = try XCTUnwrap(calls.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
    XCTAssertEqual(thread["model"] as? String, "selected-model")
    XCTAssertEqual(thread["serviceTier"] as? String, "priority")
    let config = try XCTUnwrap(thread["config"] as? [String: Any])
    XCTAssertEqual(config["agents.default_subagent_model"] as? String, "selected-model")
    XCTAssertEqual(config["agents.default_subagent_reasoning_effort"] as? String, "high")
    XCTAssertEqual(config["model_reasoning_effort"] as? String, "high")
    XCTAssertEqual(config["service_tier"] as? String, "priority")
    let turn = try XCTUnwrap(calls.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
    XCTAssertEqual(turn["effort"] as? String, "high")
    XCTAssertEqual(turn["serviceTier"] as? String, "priority")
    let inputs = try XCTUnwrap(turn["input"] as? [[String: Any]])
    let prompt = try XCTUnwrap(inputs.first?["text"] as? String)
    XCTAssertFalse(prompt.contains("gpt-6-astra"))
    XCTAssertFalse(prompt.contains("ultra reasoning"))
    await runtime.cancel()
  }

  func testSingleOutputExplicitlySelectsFastAndStandardSpeed() async throws {
    for fastMode in [false, true] {
      let (runtime, root, requests) = try fixture(modes: ["markdown"], fastMode: fastMode)
      defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
      _ = try await runtime.generate(requests[0], onEvent: { _ in })
      let tier = fastMode ? "priority" : "default"
      let calls = try rpc(root)
      for method in ["thread/start", "turn/start"] {
        let params = try XCTUnwrap(calls.first { $0["method"] as? String == method }?["params"] as? [String: Any])
        XCTAssertEqual(params["serviceTier"] as? String, tier)
      }
      let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
        root.appendingPathComponent("markdown/codex-run.json"))) as? [String: Any])
      XCTAssertEqual(record["service_tier"] as? String, tier)
      await runtime.cancel()
    }
  }

  func testBatchResolvesCoordinatorDefaultsInsteadOfSeparateSubagentDefaults() async throws {
    for (scenario, expectedModel, expectedEffort) in [
      ("configured-defaults", "configured-model", "high"),
      ("catalog-defaults", "catalog-model", "medium"),
    ] {
      let (runtime, root, requests) = try fixture(scenario, modes: ["markdown", "html"],
        model: "", effort: nil)
      defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
      let outputs = try await runtime.generateBatch(requests)
      for request in requests {
        XCTAssertEqual(try XCTUnwrap(outputs[request.mode]).get().model, expectedModel)
      }
      let calls = try rpc(root)
      XCTAssertEqual(calls.filter { $0["method"] as? String == "thread/start" }.count, 1)
      let thread = try XCTUnwrap(calls.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
      XCTAssertEqual(thread["model"] as? String, expectedModel)
      let config = try XCTUnwrap(thread["config"] as? [String: Any])
      XCTAssertEqual(config["agents.default_subagent_model"] as? String, expectedModel)
      XCTAssertEqual(config["agents.default_subagent_reasoning_effort"] as? String, expectedEffort)
      XCTAssertEqual(config["model_reasoning_effort"] as? String, expectedEffort)
      let turn = try XCTUnwrap(calls.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
      XCTAssertEqual(turn["effort"] as? String, expectedEffort)
      await runtime.cancel()
    }
  }

  func testUnknownCustomModelCanKeepItsDefaultEffort() async throws {
    let (runtime, root, requests) = try fixture(modes: ["markdown", "html"],
      model: "custom-model", effort: nil)
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let outputs = try await runtime.generateBatch(requests)
    for request in requests {
      XCTAssertEqual(try XCTUnwrap(outputs[request.mode]).get().model, "custom-model")
    }
    let calls = try rpc(root)
    let thread = try XCTUnwrap(calls.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
    let config = try XCTUnwrap(thread["config"] as? [String: Any])
    XCTAssertEqual(config["agents.default_subagent_model"] as? String, "custom-model")
    XCTAssertNil(config["agents.default_subagent_reasoning_effort"])
    let turn = try XCTUnwrap(calls.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
    XCTAssertNil(turn["effort"])
    await runtime.cancel()
  }

  func testInconsistentBatchSpeedIsRejectedBeforeStartingProcess() async throws {
    let (runtime, root, requests) = try fixture()
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    var inconsistent = requests
    inconsistent[1].fastMode = true
    do {
      _ = try await runtime.generateBatch(inconsistent)
      XCTFail("Mixed speed settings must not silently use the first output's value")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("共用模型、思考强度和速度设置"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("processes.txt").path))
  }

  func testMissingOutputAndFailedParentPreserveValidSiblingOutputs() async throws {
    for scenario in ["missing-image", "failed-turn"] {
      let (runtime, root, requests) = try fixture(scenario)
      defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
      let outputs = try await runtime.generateBatch(requests)
      XCTAssertNoThrow(try XCTUnwrap(outputs["markdown"]).get())
      XCTAssertNoThrow(try XCTUnwrap(outputs["html"]).get())
      XCTAssertThrowsError(try XCTUnwrap(outputs["image"]).get())
      let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("image/codex-run.json"))) as? [String: Any])
      XCTAssertEqual(record["status"] as? String, "failed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("image/checkpoints/save.json").path))
      await runtime.cancel()
    }
  }

  func testTwoRemainingOutputsAndNewSubagentActivityEvents() async throws {
    let (runtime, root, requests) = try fixture("activity", modes: ["markdown", "html"])
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let outputs = try await runtime.generateBatch(requests)
    XCTAssertEqual(outputs.count, 2)
    for mode in ["markdown", "html"] { XCTAssertNoThrow(try XCTUnwrap(outputs[mode]).get()) }
    await runtime.cancel()
  }

  private func resuming(_ requests: [CodexRequest], cachedModes: Set<String>) -> [CodexRequest] {
    requests.map { request in
      CodexRequest(sourceID: request.sourceID, title: request.title, sourceURL: request.sourceURL,
        contentPath: request.contentPath, outputDirectory: request.outputDirectory + "-retry",
        mode: request.mode, model: request.model, style: request.style, depth: request.depth,
        reasoningEffort: request.reasoningEffort,
        fastMode: request.fastMode,
        resumeDirectory: cachedModes.contains(request.mode) ? request.outputDirectory : nil)
    }
  }

  func testFullyCompletedBatchResumesWithoutAnotherProcessAndPreservesRunIdentity() async throws {
    let (runtime, root, requests) = try fixture()
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    _ = try await runtime.generateBatch(requests)
    let resumed = try await runtime.generateBatch(resuming(requests, cachedModes: ["markdown", "html", "image"]))
    for request in requests {
      let output = try XCTUnwrap(resumed[request.mode]).get()
      XCTAssertEqual(output.runID, "batch-turn")
      XCTAssertTrue(output.path.contains(request.mode + "-retry/"))
    }
    let calls = try rpc(root)
    XCTAssertEqual(calls.filter { $0["method"] as? String == "turn/start" }.count, 1)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("processes.txt")).split(separator: "\n").count, 1)
    await runtime.cancel()
  }

  func testMixedResumeUsesSingleModeForRemainingOutputAndPreservesCachedIdentity() async throws {
    let (runtime, root, requests) = try fixture()
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    _ = try await runtime.generateBatch(requests)
    let resumed = try await runtime.generateBatch(resuming(requests, cachedModes: ["markdown", "html"]))
    XCTAssertEqual(try XCTUnwrap(resumed["markdown"]).get().runID, "batch-turn")
    XCTAssertEqual(try XCTUnwrap(resumed["html"]).get().runID, "batch-turn")
    XCTAssertEqual(try XCTUnwrap(resumed["image"]).get().runID, "batch-turn-2")
    let calls = try rpc(root)
    let turns = calls.filter { $0["method"] as? String == "turn/start" }
    XCTAssertEqual(turns.count, 2)
    let params = try XCTUnwrap(turns.last?["params"] as? [String: Any])
    let retryThread = try XCTUnwrap(
      calls.last { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
    let config = try XCTUnwrap(retryThread["config"] as? [String: Any])
    let profiles = try XCTUnwrap(config["permissions"] as? [String: [String: Any]])
    let profileID = try XCTUnwrap(retryThread["permissions"] as? String)
    let filesystem = try XCTUnwrap(profiles[profileID]?["filesystem"] as? [String: String])
    XCTAssertEqual(filesystem.filter { $0.value == "write" }.map(\.key),
                   [root.appendingPathComponent("image-retry").path])
    XCTAssertNotEqual(filesystem[root.path], "write")
    XCTAssertEqual((profiles[profileID]?["network"] as? [String: Bool])?["enabled"], false)
    let inputs = try XCTUnwrap(params["input"] as? [[String: Any]])
    XCTAssertFalse((inputs.first?["text"] as? String ?? "").contains("BEGIN CHILD ASSIGNMENT"))
    await runtime.cancel()
  }

  func testArtifactsWithoutSubagentDelegationDoNotReportBatchSuccess() async throws {
    let (runtime, root, requests) = try fixture("no-delegation")
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let outputs = try await runtime.generateBatch(requests)
    for mode in ["markdown", "html", "image"] {
      XCTAssertThrowsError(try XCTUnwrap(outputs[mode]).get())
    }
    await runtime.cancel()
  }

  func testCancellingBatchStopsSharedProcessAndMarksEveryRunCancelled() async throws {
    let (runtime, root, requests) = try fixture("wait")
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let task = Task { try await runtime.generateBatch(requests) }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: root.appendingPathComponent("image/codex-run.json").path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("started"))))
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancellation must throw") }
    catch { XCTAssertTrue(error is CancellationError) }
    await runtime.cancel()
    XCTAssertEqual(kill(pid, 0), -1)
    for mode in ["markdown", "html", "image"] {
      let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("\(mode)/codex-run.json"))) as? [String: Any])
      XCTAssertEqual(record["status"] as? String, "cancelled")
    }
  }
}
