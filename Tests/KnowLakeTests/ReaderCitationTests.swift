import WebKit
import XCTest

@testable import KnowLake

@MainActor final class ReaderCitationTests: XCTestCase {
  private final class NavigationLog {
    var opened: [ReaderCitation] = []
  }

  private final class NavigationRelay: NSObject, WKNavigationDelegate {
    let coordinator: ReaderView.Coordinator
    var citationDecisions = 0
    init(_ coordinator: ReaderView.Coordinator) { self.coordinator = coordinator }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      coordinator.webView(webView, didFinish: navigation)
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.request.url?.scheme == "knowlake-source" { citationDecisions += 1 }
      coordinator.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }
  }

  @MainActor private struct Fixture {
    let root: URL
    let detail: SourceDetail
    let board: ArtifactRecord
    let view: WKWebView
    let controller: ReaderController
    let coordinator: ReaderView.Coordinator
    let relay: NavigationRelay
    let log: NavigationLog

    func close() {
      ReaderView.dismantleNSView(view, coordinator: coordinator)
      try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowlake-citation-\(UUID())")
    let boardDirectory = root.appendingPathComponent("artifacts/board-fixture")
    let sourceDirectory = root.appendingPathComponent("sources/source-fixture/fixture")
    for directory in [boardDirectory, sourceDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let boardURL = boardDirectory.appendingPathComponent("board.html")
    try """
      <!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0">
      <main id="board" style="height:5000px;padding-top:100px">
      <details id="expanded"><summary>更多说明</summary><p style="height:180px">保留展开状态</p></details>
      <p>关键结论<sup><a id="citation" href="knowlake-source://source-fixture#segment-2">[2]</a></sup></p>
      <a id="missing" href="knowlake-source://source-fixture#segment-99">不存在的段落</a>
      <a id="invalid" href="knowlake-source://source-fixture?override=true#segment-2">无效引用</a>
      </main></body></html>
      """.write(to: boardURL, atomically: true, encoding: .utf8)
    let source = SourceRecord(
      id: "source-fixture", title: "引用测试", url: "https://example.test/source", platform: "wechat",
      created_at: "2026-11-05", summary: "", read: false, starred: false, collection: "",
      tags: [], status: "ready", version: "fixture")
    let content = "<a id=\"segment-1\"></a>\n\n"
      + Array(repeating: "原文前面的上下文。", count: 180).joined(separator: "\n\n")
      + "\n\n<a id=\"segment-2\"></a>\n\n这是引用对应的原文证据。\n\n"
      + Array(repeating: "原文后面的上下文。", count: 30).joined(separator: "\n\n")
    let detail = SourceDetail(source: source, content: content, segments: [], artifacts: [],
      content_path: sourceDirectory.appendingPathComponent("source.md").path)
    let board = ArtifactRecord(id: "board-fixture", source_id: source.id, kind: "html",
      title: "看板", path: boardURL.path, created_at: "2026-11-05")
    let log = NavigationLog()
    let controller = ReaderController()
    let coordinator = ReaderView.Coordinator(controller: controller) { id, anchor in
      if let citation = ReaderCitation(sourceID: id, anchor: anchor) { log.opened.append(citation) }
    }
    let relay = NavigationRelay(coordinator)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(coordinator.assets, forURLScheme: ReaderAssets.scheme)
    config.userContentController.add(coordinator, name: "knowlake")
    ReaderView.installNavigationRuntime(in: config)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
    view.navigationDelegate = relay
    controller.webView = view
    return Fixture(root: root, detail: detail, board: board, view: view, controller: controller,
      coordinator: coordinator, relay: relay, log: log)
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw LakeError.message("引用测试等待条件超时")
  }

  private func render(_ fixture: Fixture, board: Bool) async throws {
    fixture.coordinator.key = UUID().uuidString
    fixture.coordinator.render(fixture.view, detail: fixture.detail,
      artifact: board ? fixture.board : nil, root: fixture.root.path, theme: "light")
    await fixture.coordinator.loadTask?.value
    try await waitUntil {
      let expression = board
        ? "document.querySelector('#citation')?.classList.contains('knowlake-citation') === true"
        : "document.querySelector('#segment-2') !== null"
      return (try? await fixture.view.evaluateJavaScript(expression)) as? Bool == true
    }
  }

  func testLibraryChangeAndManualSelectionCancelPendingCitation() {
    let controller = ReaderController()
    let original = ReaderLocation(root: "/library-one", sourceID: "source-1", artifactID: nil)
    controller.setLocation(original)
    controller.remember(ReaderReturnPoint(location: original, position: ["y": 300]))
    controller.pendingAnchor = "segment-2"
    controller.pendingSourceID = "source-1"
    controller.setLocation(ReaderLocation(root: "/library-two", sourceID: "source-1", artifactID: nil))
    XCTAssertNil(controller.pendingAnchor)
    XCTAssertNil(controller.pendingSourceID)
    XCTAssertTrue(controller.returnPoints.isEmpty)

    controller.pendingAnchor = "segment-2"
    controller.pendingSourceID = "source-1"
    controller.setLocation(ReaderLocation(root: "/library-two", sourceID: "other", artifactID: nil))
    XCTAssertNil(controller.pendingAnchor)
    XCTAssertNil(controller.pendingSourceID)
  }

  func testCitationURLRequiresInternalSourceAndSegmentAddress() throws {
    let valid = try XCTUnwrap(ReaderCitation(url: URL(string: "knowlake-source://source_1#segment-12")!))
    XCTAssertEqual(valid.sourceID, "source_1")
    XCTAssertEqual(valid.segmentNumber, 12)
    XCTAssertNotNil(ReaderCitation(url: URL(string: "knowlake-source://source-1")!))
    for address in [
      "https://source-1#segment-1", "knowlake-source://user@source-1#segment-1",
      "knowlake-source://source-1:123#segment-1", "knowlake-source://source-1/file#segment-1",
      "knowlake-source://source-1?query=yes#segment-1", "knowlake-source://source-1#heading-1",
      "knowlake-source://source-1#segment-0", "knowlake-source://source-1#segment--1",
      "knowlake-source://source-1#segment-01", "knowlake-source://source-1#segment-1%2Fetc",
    ] {
      XCTAssertNil(ReaderCitation(url: try XCTUnwrap(URL(string: address))), address)
    }
    XCTAssertNil(ReaderCitation(sourceID: "../source", anchor: "segment-1"))
    XCTAssertNil(ReaderCitation(sourceID: "", anchor: "segment-1"))
  }

  func testBoardCitationCapturesPositionHighlightsSourceAndReturns() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    try await render(fixture, board: true)
    let exposed = try await fixture.view.evaluateJavaScript(
      "Boolean(window.webkit?.messageHandlers?.knowlake || window.KnowLakeNavigation)") as? Bool
    XCTAssertEqual(exposed, false, "Generated page scripts must not receive the native bridge or isolated API")
    _ = try await fixture.view.evaluateJavaScript("""
      document.querySelector('#expanded').open = true;
      window.scrollTo({top: 900, behavior: 'instant'});
      document.querySelector('#citation').click();
      """)
    try await waitUntil { fixture.log.opened.count == 1 }
    XCTAssertEqual(fixture.relay.citationDecisions, 1)
    XCTAssertEqual(fixture.log.opened[0].anchor, "segment-2")
    let point = try XCTUnwrap(fixture.controller.returnPoints.last)
    XCTAssertEqual(point.location.artifactID, fixture.board.id)
    XCTAssertEqual(try XCTUnwrap(point.position["y"] as? Double), 900, accuracy: 2)

    fixture.controller.pendingSourceID = fixture.log.opened[0].sourceID
    fixture.controller.pendingAnchor = fixture.log.opened[0].anchor
    try await render(fixture, board: false)
    try await waitUntil {
      (try? await fixture.view.evaluateJavaScript(
        "document.querySelector('.anchor-flash')?.textContent.includes('这是引用对应的原文证据') === true")) as? Bool == true
    }
    XCTAssertNil(fixture.controller.error)
    let targetVisible = try await fixture.view.evaluateJavaScript("""
      (() => { const rect = document.querySelector('.anchor-flash').getBoundingClientRect();
        return rect.bottom > 0 && rect.top < innerHeight; })()
      """) as? Bool
    XCTAssertEqual(targetVisible, true)

    XCTAssertNotNil(fixture.controller.popReturn())
    try await render(fixture, board: true)
    try await waitUntil {
      (try? await fixture.view.evaluateJavaScript(
        "Math.abs(scrollY - 900) <= 2 && document.querySelector('#expanded').open")) as? Bool == true
    }
    XCTAssertTrue(fixture.controller.returnPoints.isEmpty)
    XCTAssertNil(fixture.controller.pendingReturn)
    XCTAssertNil(fixture.controller.error)
  }

  func testInvalidAndMissingCitationTargetsDoNotLeaveBoard() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    try await render(fixture, board: true)
    _ = try await fixture.view.evaluateJavaScript("document.querySelector('#invalid').click()")
    try await waitUntil { fixture.relay.citationDecisions == 1 }
    XCTAssertTrue(fixture.log.opened.isEmpty)
    XCTAssertTrue(fixture.controller.returnPoints.isEmpty)
    _ = try await fixture.view.evaluateJavaScript("document.querySelector('#missing').click()")
    try await waitUntil { fixture.controller.error != nil }
    XCTAssertTrue(fixture.log.opened.isEmpty)
    XCTAssertTrue(fixture.controller.returnPoints.isEmpty)
    XCTAssertEqual(fixture.view.url?.lastPathComponent, "board.html")
    XCTAssertEqual(fixture.controller.error, "原文中已找不到这处引用。")
  }
}
