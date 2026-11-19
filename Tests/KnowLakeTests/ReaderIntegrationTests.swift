import XCTest
import WebKit
@testable import KnowLake

@MainActor final class ReaderIntegrationTests: XCTestCase, WKNavigationDelegate {
    var loaded: XCTestExpectation?
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {loaded?.fulfill()}
    func testBundledReaderInWebKit() async throws {
        let view=WKWebView(frame:CGRect(x:0,y:0,width:1000,height:800))
        view.navigationDelegate=self
        let root=Bundle.module.resourceURL!.appendingPathComponent("Resources/Reader")
        loaded=expectation(description:"reader loaded")
        view.loadFileURL(root.appendingPathComponent("index.html"),allowingReadAccessTo:root)
        await fulfillment(of:[loaded!],timeout:15)
        let doc:[String:Any] = ["id":"smoke","title":"原生阅读验证","url":"https://www.bilibili.com/video/BV1xx","platform":"bilibili","content":"# 标题\n\n正文证据\n\n| 列 | 值 |\n|---|---|\n| 示例 | 42 |","segments":[],"mode":"article","theme":"light"]
        _ = try await view.callAsyncJavaScript("window.KnowLakeReader.render(doc); await window.KnowLakeReader.ready(); return true",arguments:["doc":doc],in:nil,contentWorld:.page)
        let body=try await view.evaluateJavaScript("document.querySelector('#article').textContent") as? String
        XCTAssertTrue(body?.contains("正文证据") == true)
        let html=try await view.callAsyncJavaScript("return await window.KnowLakeReader.exportHTML()",arguments:[:],in:nil,contentWorld:.page) as? String
        XCTAssertTrue(html?.contains("正文证据") == true)
        XCTAssertTrue(html?.contains("<style") == true)
        view.stopLoading();view.navigationDelegate=nil
    }

    func testReaderLoadsOnlyAuthorizedArchiveImageInWebKit() async throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = library.appendingPathComponent("sources/item/version")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: library, resultingItemURL: nil) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+yZs8AAAAASUVORK5CYII="))
        try png.write(to: archive.appendingPathComponent("pixel.png"))
        let handler = ReaderAssets()
        let base = try XCTUnwrap(handler.configure(archive: archive, library: library))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderAssets.scheme)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        let root = try XCTUnwrap(KnowLakeResources.directory?.appendingPathComponent("Reader"))
        loaded = expectation(description: "reader loaded without a window")
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        await fulfillment(of: [loaded!], timeout: 15)
        defer { view.stopLoading(); view.navigationDelegate = nil }
        let width = try await view.callAsyncJavaScript("""
          const img = new Image();
          return await new Promise((resolve) => {
            img.onload = () => resolve(img.naturalWidth);
            img.onerror = () => resolve(0);
            img.src = url;
          });
          """, arguments: ["url": base.appendingPathComponent("pixel.png").absoluteString],
          in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(width, 1)
    }

}
