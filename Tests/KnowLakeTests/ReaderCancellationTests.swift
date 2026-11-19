import WebKit
import XCTest

@testable import KnowLake

@MainActor final class ReaderCancellationTests: XCTestCase {
  @MainActor private final class DelayedWebView: WKWebView {
    typealias Completion = @MainActor @Sendable (Any?, Error?) -> Void
    var delayNextRender = false
    var delayed: [(Completion?, Any?, Error?)] = []

    override func evaluateJavaScript(
      _ javaScriptString: String, completionHandler: Completion? = nil
    ) {
      if delayNextRender && javaScriptString.hasPrefix("window.KnowLakeReader.render(") {
        delayNextRender = false
        super.evaluateJavaScript(javaScriptString) { value, error in
          self.delayed.append((completionHandler, value, error))
        }
      } else {
        super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
      }
    }

    func completeRender(error: Error? = nil) {
      let (completion, value, originalError) = delayed.removeFirst()
      completion?(value, error ?? originalError)
    }
  }

  @MainActor private final class NavigationRelay: NSObject, WKNavigationDelegate {
    let coordinator: ReaderView.Coordinator
    var delayBoardPolicy = false
    var boardDecision: ((WKNavigationActionPolicy) -> Void)?
    var delayBoardFinish = false
    var boardFinish: (() -> Void)?

    init(_ coordinator: ReaderView.Coordinator) { self.coordinator = coordinator }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if delayBoardPolicy && navigationAction.request.url?.lastPathComponent == "board.html" {
        delayBoardPolicy = false
        boardDecision = decisionHandler
      } else {
        coordinator.webView(
          webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      if delayBoardFinish && webView.url?.lastPathComponent == "board.html" {
        delayBoardFinish = false
        boardFinish = { self.coordinator.webView(webView, didFinish: navigation) }
      } else {
        coordinator.webView(webView, didFinish: navigation)
      }
    }
  }

  @MainActor private struct Fixture {
    let root: URL
    let detail: SourceDetail
    let board: ArtifactRecord
    let controller: ReaderController
    let coordinator: ReaderView.Coordinator
    let relay: NavigationRelay
    let view: DelayedWebView

    func close() {
      relay.boardDecision?(.cancel)
      relay.boardDecision = nil
      relay.boardFinish = nil
      ReaderView.dismantleNSView(view, coordinator: coordinator)
      try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowlake-reader-cancel-\(UUID())")
    let sourceDirectory = root.appendingPathComponent("sources/source-fixture/fixture")
    let artifactDirectory = root.appendingPathComponent("artifacts/fixture")
    for directory in [sourceDirectory, artifactDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let boardURL = artifactDirectory.appendingPathComponent("board.html")
    try "<!doctype html><html><body><main id='board'>Board fixture</main></body></html>"
      .write(to: boardURL, atomically: true, encoding: .utf8)
    let source = SourceRecord(
      id: "source-fixture", title: "Source fixture", url: "https://example.test/source",
      platform: "wechat", created_at: "2026-10-29", summary: "", read: false,
      starred: false, collection: "", tags: [], status: "ready", version: "fixture")
    let detail = SourceDetail(
      source: source, content: "# Source fixture\n\nOriginal source body.", segments: [],
      artifacts: [], content_path: sourceDirectory.appendingPathComponent("source.md").path)
    let board = ArtifactRecord(
      id: "board-fixture", source_id: source.id, kind: "html", title: "Board fixture",
      path: boardURL.path, created_at: "2026-10-29")
    let controller = ReaderController()
    let coordinator = ReaderView.Coordinator(controller: controller, openSource: { _, _ in })
    let relay = NavigationRelay(coordinator)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(coordinator.assets, forURLScheme: ReaderAssets.scheme)
    config.userContentController.add(coordinator, name: "knowlake")
    let view = DelayedWebView(
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
    view.navigationDelegate = relay
    controller.webView = view
    return Fixture(
      root: root, detail: detail, board: board, controller: controller,
      coordinator: coordinator, relay: relay, view: view)
  }

  @discardableResult private func render(
    _ fixture: Fixture, board: Bool = false, key: String? = nil
  ) -> Task<Void, Never>? {
    fixture.coordinator.key = key ?? UUID().uuidString
    fixture.coordinator.render(
      fixture.view, detail: fixture.detail, artifact: board ? fixture.board : nil,
      root: fixture.root.path, theme: "light")
    return fixture.coordinator.loadTask
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("Reader condition timed out")
  }

  private func waitForSource(_ fixture: Fixture) async throws {
    try await waitUntil {
      (try? await fixture.view.evaluateJavaScript(
        "document.querySelector('#article')?.textContent.includes('Original source body.') === true"
      )) as? Bool == true
    }
  }

  private func waitForBoard(_ fixture: Fixture) async throws {
    try await waitUntil {
      (try? await fixture.view.evaluateJavaScript("document.querySelector('#board') !== null"))
        as? Bool == true
    }
  }

  func testCancelledRenderCannotPublishErrorOrConsumeAnchor() async throws {
    for failure in [false, true] {
      let fixture = try fixture()
      defer { fixture.close() }
      await render(fixture)?.value
      try await waitForSource(fixture)

      fixture.view.delayNextRender = true
      let oldTask = render(fixture)
      try await waitUntil { fixture.view.delayed.count == 1 }
      await render(fixture)?.value
      fixture.controller.pendingAnchor = "next-source-anchor"
      fixture.view.completeRender(error: failure ? CancellationError() : nil)
      await oldTask?.value

      XCTAssertNil(fixture.controller.error)
      XCTAssertEqual(fixture.controller.pendingAnchor, "next-source-anchor")
      try await waitForSource(fixture)
    }
  }

  func testOldNavigationRenderCompletionCannotPublishErrorOrConsumeAnchor() async throws {
    for failure in [false, true] {
      let fixture = try fixture()
      defer { fixture.close() }
      fixture.view.delayNextRender = true
      await render(fixture)?.value
      try await waitUntil { fixture.view.delayed.count == 1 }
      await render(fixture, board: true)?.value
      try await waitForBoard(fixture)
      fixture.controller.pendingAnchor = "next-source-anchor"

      fixture.view.completeRender(error: failure ? CancellationError() : nil)

      XCTAssertNil(fixture.controller.error)
      XCTAssertEqual(fixture.controller.pendingAnchor, "next-source-anchor")
      try await waitForBoard(fixture)
    }
  }

  func testSourceBoardSourceWithSameKeyRejectsOldCompletion() async throws {
    for failure in [false, true] {
      let fixture = try fixture()
      defer { fixture.close() }
      await render(fixture)?.value
      try await waitForSource(fixture)
      let sourceKey = "\(fixture.root.path):source-fixture:fixture:source:article:light"

      fixture.view.delayNextRender = true
      let oldSourceTask = render(fixture, key: sourceKey)
      try await waitUntil { fixture.view.delayed.count == 1 }
      await render(fixture, board: true, key: "board-fixture")?.value
      try await waitForBoard(fixture)
      await render(fixture, key: sourceKey)?.value
      try await waitForSource(fixture)
      XCTAssertEqual(fixture.coordinator.key, sourceKey)
      fixture.controller.pendingAnchor = "new-source-anchor"

      fixture.view.completeRender(error: failure ? CancellationError() : nil)
      await oldSourceTask?.value

      XCTAssertNil(fixture.controller.error)
      XCTAssertEqual(fixture.controller.pendingAnchor, "new-source-anchor")
      XCTAssertEqual(fixture.view.url?.lastPathComponent, "index.html")
      try await waitForSource(fixture)
    }
  }

  func testLateBoardDidFinishCannotRenderNewPayloadOrConsumeAnchor() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    fixture.relay.delayBoardFinish = true
    await render(fixture, board: true)?.value
    try await waitUntil { fixture.relay.boardFinish != nil }
    await render(fixture)?.value
    try await waitForSource(fixture)
    fixture.controller.pendingAnchor = "next-source-anchor"

    fixture.relay.boardFinish?()
    fixture.relay.boardFinish = nil
    // Drain the actual WebKit callback queued by a stale didFinish.
    _ = try await fixture.view.evaluateJavaScript("true")
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertNil(fixture.controller.error)
    XCTAssertEqual(fixture.controller.pendingAnchor, "next-source-anchor")
  }

  func testReturningFromUncommittedBoardNavigationEndsOnSource() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    await render(fixture)?.value
    try await waitForSource(fixture)
    fixture.relay.delayBoardPolicy = true
    await render(fixture, board: true)?.value
    try await waitUntil { fixture.relay.boardDecision != nil }
    XCTAssertTrue(fixture.view.isLoading)

    await render(fixture)?.value
    fixture.relay.boardDecision?(.allow)
    fixture.relay.boardDecision = nil
    try await waitUntil { !fixture.view.isLoading }

    XCTAssertEqual(fixture.view.url?.lastPathComponent, "index.html")
    let body = try await fixture.view.evaluateJavaScript("document.body.textContent") as? String
    XCTAssertTrue(body?.contains("Original source body.") == true)
    XCTAssertNil(fixture.controller.error)
  }

  func testCurrentJavaScriptErrorIsStillVisible() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    await render(fixture)?.value
    try await waitForSource(fixture)
    _ = try await fixture.view.evaluateJavaScript(
      "window.KnowLakeReader.render = () => { throw new Error('CURRENT_READER_FAILURE'); }; true")

    await render(fixture)?.value

    XCTAssertNotNil(fixture.controller.error)
  }
}
