import AppKit
import XCTest
import WebKit

@testable import KnowLake

@MainActor final class ReaderArtifactModeTests: XCTestCase {
  @MainActor private struct Fixture {
    let root: URL
    let detail: SourceDetail
    let controller: ReaderController
    let coordinator: ReaderView.Coordinator
    let view: WKWebView

    func close() {
      ReaderView.dismantleNSView(view, coordinator: coordinator)
      try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowlake-reader-mode-\(UUID())")
    let sourceDirectory = root.appendingPathComponent("sources/source-fixture/fixture")
    let artifactDirectory = root.appendingPathComponent("artifacts/fixture")
    for directory in [sourceDirectory, artifactDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let source = SourceRecord(
      id: "source-fixture", title: "来源标题", url: "https://example.test/source",
      platform: "wechat", created_at: "2026-10-29", summary: "", read: false,
      starred: false, collection: "", tags: [], status: "ready", version: "fixture")
    let detail = SourceDetail(
      source: source, content: "# 原文节点\n\n## 原文独有内容\n\n来源正文。",
      segments: [], artifacts: [], content_path: sourceDirectory.appendingPathComponent("source.md").path)
    let controller = ReaderController()
    let coordinator = ReaderView.Coordinator(controller: controller, openSource: { _, _ in })
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(coordinator.assets, forURLScheme: ReaderAssets.scheme)
    config.userContentController.add(coordinator, name: "knowlake")
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
    view.navigationDelegate = coordinator
    controller.webView = view
    return Fixture(root: root, detail: detail, controller: controller, coordinator: coordinator, view: view)
  }

  private func artifact(_ kind: String, at url: URL) -> ArtifactRecord {
    ArtifactRecord(
      id: "artifact-\(kind)", source_id: "source-fixture", kind: kind, title: "产物标题",
      path: url.path, created_at: "2026-10-29")
  }

  private func render(_ fixture: Fixture, artifact: ArtifactRecord? = nil) async throws {
    fixture.coordinator.key = UUID().uuidString
    fixture.coordinator.render(
      fixture.view, detail: fixture.detail, artifact: artifact,
      root: fixture.root.path, theme: "light")
    await fixture.coordinator.loadTask?.value
    XCTAssertNil(fixture.controller.error)
  }

  private func waitUntil(_ expression: String, in view: WKWebView) async throws {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if (try? await view.evaluateJavaScript(expression)) as? Bool == true { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("Reader condition timed out: \(expression)")
  }

  func testHTMLKeepsItsPageAfterReadingSource() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    try await render(fixture)
    try await waitUntil("document.querySelector('#article')?.textContent.includes('原文独有内容') === true", in: fixture.view)

    let html = fixture.root.appendingPathComponent("artifacts/fixture/board.html")
    try """
      <!doctype html><html><head><meta charset="utf-8"></head><body><main id="board">HTML 产物独有内容</main>
      <script>window.boardScriptRan = true;</script></body></html>
      """.write(to: html, atomically: true, encoding: .utf8)
    try await render(fixture, artifact: artifact("html", at: html))
    try await waitUntil("window.boardScriptRan === true", in: fixture.view)

    XCTAssertEqual(fixture.view.url?.resolvingSymlinksInPath(), html.resolvingSymlinksInPath())
    let content = try await fixture.view.evaluateJavaScript("document.body.textContent") as? String
    XCTAssertTrue(content?.contains("HTML 产物独有内容") == true)
    XCTAssertFalse(content?.contains("原文独有内容") == true)
    XCTAssertNil(fixture.coordinator.payload)
    let bridge = try await fixture.view.evaluateJavaScript("Boolean(window.webkit?.messageHandlers?.knowlake)") as? Bool
    XCTAssertEqual(bridge, false)
  }

  func testImageShowsItsOwnContentAfterReadingSource() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    try await render(fixture)
    try await waitUntil("document.querySelector('#article')?.textContent.includes('原文独有内容') === true", in: fixture.view)
    let image = fixture.root.appendingPathComponent("artifacts/fixture/overview.png")
    let data = try XCTUnwrap(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a4e0AAAAASUVORK5CYII="))
    try data.write(to: image)
    try await render(fixture, artifact: artifact("image", at: image))
    try await waitUntil("document.querySelector('#image-viewer')?.hidden === false", in: fixture.view)

    let mode = try await fixture.view.evaluateJavaScript("window.KnowLakeReader.diagnostics().mode") as? String
    XCTAssertEqual(mode, "image")
    let articleHidden = try await fixture.view.evaluateJavaScript(
      "document.querySelector('#article').hidden") as? Bool
    XCTAssertEqual(articleHidden, true)
    let path = try await fixture.view.evaluateJavaScript("document.querySelector('#viewer-image').src") as? String
    let assetURL = try XCTUnwrap(path.flatMap { URL(string: $0) })
    XCTAssertEqual(assetURL.scheme, ReaderAssets.scheme)
    XCTAssertEqual(fixture.coordinator.assets.file(for: assetURL), image.resolvingSymlinksInPath())
    let isolated = try await fixture.view.evaluateJavaScript("""
      document.body.classList.contains('image-mode')
        && document.querySelector('#article').hidden
        && document.querySelector('#doc-header').hidden
        && document.querySelector('#outline').hidden
        && !document.querySelector('#article').textContent.includes('原文独有内容')
      """) as? Bool
    XCTAssertEqual(isolated, true)
    let payload = try XCTUnwrap(fixture.coordinator.payload?.data(using: .utf8))
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(document["content"] as? String, "")
    XCTAssertEqual(document["imageURL"] as? String, assetURL.absoluteString)
    XCTAssertEqual(document["segments"] as? [String], [])

    // Going back to the source restores its content and removes the image-only surface.
    try await render(fixture)
    try await waitUntil("document.querySelector('#article')?.textContent.includes('原文独有内容') === true", in: fixture.view)
    let restored = try await fixture.view.evaluateJavaScript("""
      !document.body.classList.contains('image-mode')
        && document.querySelector('#image-panel').hidden
        && document.querySelector('#image-viewer').hidden
      """) as? Bool
    XCTAssertEqual(restored, true)
  }

  func testSourceAndMarkdownArticlesUseTheirOwnContent() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    try await render(fixture)
    try await waitUntil("document.querySelector('#article')?.textContent.includes('原文独有内容') === true", in: fixture.view)

    let markdown = fixture.root.appendingPathComponent("artifacts/fixture/note.md")
    try "# 笔记节点\n\n## 笔记独有内容\n\n笔记正文。".write(to: markdown, atomically: true, encoding: .utf8)
    try await render(fixture, artifact: artifact("markdown", at: markdown))
    try await waitUntil("document.querySelector('#article')?.textContent.includes('笔记独有内容') === true", in: fixture.view)

    let article = try await fixture.view.evaluateJavaScript("document.querySelector('#article').textContent") as? String
    XCTAssertFalse(article?.contains("原文独有内容") == true)
    let mode = try await fixture.view.evaluateJavaScript("window.KnowLakeReader.diagnostics().mode") as? String
    XCTAssertEqual(mode, "article")
    XCTAssertNil(fixture.controller.error)
  }

  func testImageViewerUsesAvailableSpaceZoomsAndRestoresFit() async throws {
    let fixture = try fixture()
    defer { fixture.close() }
    for (width, height) in [(1600, 900), (900, 1600)] {
      let bitmap = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      let image = fixture.root.appendingPathComponent("artifacts/fixture/overview-\(width).png")
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
      try await render(fixture, artifact: artifact("image", at: image))
      try await waitUntil("""
        document.querySelector('#image-viewer')?.hidden === false
          && document.querySelector('#viewer-image').naturalWidth === \(width)
        """, in: fixture.view)

      let fullWidth = try await fixture.view.evaluateJavaScript("""
        document.querySelector('#image-viewport').getBoundingClientRect().width > 900
          && document.querySelector('#image-viewport').getBoundingClientRect().height > 700
        """) as? Bool
      XCTAssertEqual(fullWidth, true, "Image mode should use the reading area, not the article column")
      let fitValue = try await fixture.view.evaluateJavaScript(
        "Number(document.querySelector('#image-viewer').dataset.scale)")
      let fit = try XCTUnwrap(fitValue as? Double)
      XCTAssertGreaterThan(fit, 0)
      XCTAssertLessThan(fit, 1)
      _ = try await fixture.view.evaluateJavaScript("document.querySelector('#image-zoom-in').click()")
      let enlargedValue = try await fixture.view.evaluateJavaScript(
        "Number(document.querySelector('#image-viewer').dataset.scale)")
      let enlarged = try XCTUnwrap(enlargedValue as? Double)
      XCTAssertGreaterThan(enlarged, fit)
      _ = try await fixture.view.evaluateJavaScript("document.querySelector('#image-fit').click()")
      let fittedValue = try await fixture.view.evaluateJavaScript(
        "Number(document.querySelector('#image-viewer').dataset.scale)")
      let fitted = try XCTUnwrap(fittedValue as? Double)
      XCTAssertEqual(fitted, fit, accuracy: 0.0001)
      _ = try await fixture.view.evaluateJavaScript("""
        document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
        """)
      let closed = try await fixture.view.evaluateJavaScript("""
        document.querySelector('#image-viewer').hidden
          && !document.querySelector('#app').inert
          && !document.documentElement.classList.contains('image-viewer-open')
        """) as? Bool
      XCTAssertEqual(closed, true)
      let exportValue = try await fixture.view.callAsyncJavaScript("""
        const assets = {}; assets[document.querySelector('#overview-image').src] = 'data:image/png;base64,fixture';
        return await window.KnowLakeReader.exportHTML(assets);
        """, arguments: [:], in: nil, contentWorld: .page)
      let exported = try XCTUnwrap(exportValue as? String)
      XCTAssertTrue(exported.contains("data:image/png;base64,fixture"))
      XCTAssertFalse(exported.contains("原文独有内容"))
      XCTAssertFalse(exported.contains("查看来源"))
    }
  }
}
