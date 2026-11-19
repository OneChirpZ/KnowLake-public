import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor final class ReaderController: ObservableObject {
  weak var webView: WKWebView?
  weak var assets: ReaderAssets?
  @Published var error: String?
  var pendingAnchor: String?
  var pendingSourceID: String?
  var pendingReturn: ReaderReturnPoint?
  @Published private(set) var returnPoints: [ReaderReturnPoint] = []
  private(set) var location: ReaderLocation?
  private var locationRevision = 0
  private var anchorRequest = 0
  static let navigationWorld = WKContentWorld.world(name: "KnowLakeNavigation")

  func setLocation(_ value: ReaderLocation) {
    if location?.root != value.root {
      if !returnPoints.isEmpty { returnPoints = [] }
      pendingReturn = nil
      if location != nil { pendingAnchor = nil; pendingSourceID = nil }
    }
    if let pendingSourceID, pendingSourceID != value.sourceID || value.artifactID != nil {
      pendingAnchor = nil
      self.pendingSourceID = nil
    }
    locationRevision += 1
    location = value
  }
  func remember(_ point: ReaderReturnPoint) { returnPoints.append(point) }
  func popReturn() -> ReaderReturnPoint? {
    guard let point = returnPoints.popLast() else { return nil }
    pendingAnchor = nil
    pendingSourceID = nil
    pendingReturn = point
    return point
  }
  func applyPendingReturn() {
    guard let point = pendingReturn, point.location == location, let view = webView else { return }
    pendingReturn = nil
    anchorRequest += 1
    let expected = locationRevision
    Task {
      guard locationRevision == expected else { return }
      _ = try? await view.callAsyncJavaScript(
        "window.KnowLakeReader?.cancelAnchor(); await window.KnowLakeReader?.ready()",
        arguments: [:], in: nil, contentWorld: .page)
      guard locationRevision == expected else { return }
      _ = try? await view.callAsyncJavaScript(
        "return await window.KnowLakeNavigation.restore(state)", arguments: ["state": point.position],
        in: nil, contentWorld: Self.navigationWorld)
    }
  }
  func applyPendingAnchor() {
    if let value = pendingAnchor, pendingSourceID == nil || pendingSourceID == location?.sourceID {
      pendingAnchor = nil
      pendingSourceID = nil
      anchor(value)
    }
  }
  func find(_ value: String) {
    Task {
      _ = try? await webView?.callAsyncJavaScript(
        "return await window.KnowLakeReader.find(query)", arguments: ["query": value], in: nil,
        contentWorld: .page)
    }
  }
  func anchor(_ value: String) {
    guard !value.isEmpty else { return }
    anchorRequest += 1
    let request = anchorRequest
    let expected = locationRevision
    Task {
      guard locationRevision == expected, anchorRequest == request else { return }
      let found = try? await webView?.callAsyncJavaScript(
        "return await window.KnowLakeReader.scrollToAnchor(anchor)", arguments: ["anchor": value],
        in: nil, contentWorld: .page)
      if locationRevision == expected, anchorRequest == request, found as? Bool == false { error = "原文中已找不到这处引用。" }
    }
  }
  func export(_ format: String, detail: SourceDetail, artifact: ArtifactRecord?, root: String) async
  {
    guard let view = webView else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (detail.source.title.prefix(70)) + "." + format
    panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
    guard panel.runModal() == .OK, let target = panel.url else { return }
    do {
      switch format {
      case "md":
        var params: [String: Any] = [
          "id": detail.source.id, "format": "markdown", "destination": target.path,
        ]
        if let artifact, artifact.kind != "image" { params["artifact_id"] = artifact.id }
        let _: PathResult = try await EngineClient().request(
          action: "export", root: root, params: params)
      case "png":
        let config = WKSnapshotConfiguration()
        let image = try await view.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
        else { throw LakeError.message("无法生成预览图片") }
        try png.write(to: target, options: .atomic)
      default:
        if artifact?.kind == "html", let artifact {
          let _: PathResult = try await EngineClient().request(
            action: "export", root: root,
            params: [
              "id": detail.source.id, "artifact_id": artifact.id, "format": "html",
              "destination": target.path,
            ])
        } else {
          let urls =
            try await view.evaluateJavaScript("window.KnowLakeReader.assetURLs()") as? [String]
            ?? []
          let localAssets = urls.compactMap { value -> (String, URL)? in
            guard let address = URL(string: value), let file = assets?.file(for: address) else { return nil }
            return (value, file)
          }
          let assetData = try await Task.detached(priority: .utility) { () -> [String: String] in
            var result: [String: String] = [:]
            for (value, url) in localAssets {
              let data = try Data(contentsOf: url)
              let mime =
                UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
              result[value] = "data:\(mime);base64," + data.base64EncodedString()
            }
            return result
          }.value
          guard
            let html = try await view.callAsyncJavaScript(
              "return await window.KnowLakeReader.exportHTML(assetData)",
              arguments: ["assetData": assetData], in: nil,
              contentWorld: .page) as? String
          else { throw LakeError.message("无法导出 HTML") }
          try html.write(to: target, atomically: true, encoding: .utf8)
        }
      }
    } catch { self.error = error.localizedDescription }
  }
}
struct ReaderView: NSViewRepresentable {
  let detail: SourceDetail
  let artifact: ArtifactRecord?
  let root: String
  let theme: String
  let controller: ReaderController
  let openSource: (String, String) -> Void
  func makeCoordinator() -> Coordinator {
    Coordinator(controller: controller, openSource: openSource)
  }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(context.coordinator.assets, forURLScheme: ReaderAssets.scheme)
    config.userContentController.add(context.coordinator, name: "knowlake")
    Self.installNavigationRuntime(in: config)
    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    controller.webView = view
    controller.assets = context.coordinator.assets
    return view
  }
  static func installNavigationRuntime(in config: WKWebViewConfiguration) {
    guard let url = KnowLakeResources.directory?.appendingPathComponent("Reader/navigation.js"),
      let script = try? String(contentsOf: url, encoding: .utf8) else { return }
    config.userContentController.addUserScript(WKUserScript(
      source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
      in: ReaderController.navigationWorld))
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    let key =
      "\(root):\(detail.source.id):\(detail.source.version):\(artifact?.id ?? "source"):\(theme)"
    guard context.coordinator.key != key else { return }
    context.coordinator.key = key
    context.coordinator.render(
      view, detail: detail, artifact: artifact, root: root, theme: theme)
  }
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.cancelRendering()
    view.evaluateJavaScript("window.KnowLakeReader?.dispose()")
    view.stopLoading()
    view.configuration.userContentController.removeScriptMessageHandler(forName: "knowlake")
    view.navigationDelegate = nil
  }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var key = "", payload: String?, allowedRoot: URL?
    let assets = ReaderAssets()
    var loadTask: Task<Void, Never>?
    private var renderRevision = 0
    private var navigation: WKNavigation?
    private var readyReaderURL: URL?
    let controller: ReaderController
    let openSource: (String, String) -> Void
    private var detail: SourceDetail?
    private var artifact: ArtifactRecord?
    private var citationTask: Task<Void, Never>?
    init(controller: ReaderController, openSource: @escaping (String, String) -> Void) {
      self.controller = controller
      self.openSource = openSource
    }
    func cancelRendering() {
      renderRevision += 1
      citationTask?.cancel()
      citationTask = nil
      loadTask?.cancel()
      loadTask = nil
      navigation = nil
      payload = nil
      assets.clear()
    }
    func render(
      _ view: WKWebView, detail: SourceDetail, artifact: ArtifactRecord?,
      root: String, theme: String
    ) {
      cancelRendering()
      self.detail = detail
      self.artifact = artifact
      controller.setLocation(ReaderLocation(root: root, sourceID: detail.source.id, artifactID: artifact?.id))
      let expected = renderRevision
      loadTask = Task {
        guard !Task.isCancelled, renderRevision == expected else { return }
        do {
          let dataRoot = URL(fileURLWithPath: root)
          let artifactURL = artifact.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() }
          if let artifactURL,
            ReaderAssets.archiveDirectory(artifactURL.deletingLastPathComponent(), in: dataRoot) == nil
          {
            throw LakeError.message("归档文件位于资料目录之外。")
          }
          if artifact?.kind == "html", let url = artifactURL {
            readyReaderURL = nil
            // Generated pages get no native message bridge.
            view.configuration.userContentController.removeScriptMessageHandler(forName: "knowlake")
            let directory = url.deletingLastPathComponent()
            allowedRoot = directory
            navigation = view.loadFileURL(url, allowingReadAccessTo: directory)
            return
          }
          guard let reader = KnowLakeResources.directory?.appendingPathComponent("Reader") else {
            throw LakeError.message("找不到应用内的阅读器资源。")
          }
          let content = try await Task.detached(priority: .userInitiated) { () -> String in
            if artifact?.kind == "markdown", let artifactURL {
              return try String(contentsOf: artifactURL, encoding: .utf8)
            }
            if artifact?.kind == "image" { return "" }
            return detail.content
          }.value
          guard !Task.isCancelled, renderRevision == expected else { return }
          let localURL = artifactURL ?? detail.content_path.map { URL(fileURLWithPath: $0) }
          let directory = localURL?.deletingLastPathComponent()
          let assetBase = assets.configure(archive: directory, library: dataRoot)
          let doc = ReaderDocument(
            sourceID: detail.source.id, id: key, title: detail.source.title,
            url: detail.source.webURL?.absoluteString ?? "",
            platform: detail.source.platform, content: content,
            segments: artifact?.kind == "image" ? [] : detail.segments, theme: theme,
            assetBase: assetBase?.absoluteString ?? "",
            imageURL: artifact?.kind == "image"
              ? artifactURL.flatMap { assetBase?.appendingPathComponent($0.lastPathComponent).absoluteString }
              : nil,
            imageTitle: artifact?.kind == "image" ? detail.source.title + " · 概览图" : nil)
          payload = String(data: try JSONEncoder().encode(doc), encoding: .utf8)
          allowedRoot = reader
          view.configuration.userContentController.removeScriptMessageHandler(forName: "knowlake")
          view.configuration.userContentController.add(self, name: "knowlake")
          let readerURL = reader.appendingPathComponent("index.html").standardizedFileURL
          if !view.isLoading, readyReaderURL == readerURL,
            view.url?.standardizedFileURL == readerURL, let payload
          {
            _ = try await view.evaluateJavaScript("window.KnowLakeReader.render(\(payload))")
            guard !Task.isCancelled, renderRevision == expected else { return }
            initializeNavigation(view)
          } else {
            readyReaderURL = nil
            navigation = view.loadFileURL(
              readerURL, allowingReadAccessTo: reader)
          }
        } catch {
          guard !Task.isCancelled, renderRevision == expected else { return }
          controller.error = error.localizedDescription
        }
      }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard let navigation, navigation === self.navigation else { return }
      if let payload {
        readyReaderURL = webView.url?.standardizedFileURL
        let expected = renderRevision
        webView.evaluateJavaScript("window.KnowLakeReader.render(\(payload))") {
          [weak self] _, error in
          guard let self, self.renderRevision == expected, self.navigation === navigation else {
            return
          }
          if let error {
            self.controller.error = error.localizedDescription
          } else {
            self.initializeNavigation(webView)
          }
        }
      } else {
        initializeNavigation(webView)
      }
    }
    private func initializeNavigation(_ view: WKWebView) {
      guard let detail else { return }
      let expected = renderRevision
      let isBoard = artifact?.kind == "html"
      Task {
        if !isBoard {
          _ = try? await view.callAsyncJavaScript("await window.KnowLakeReader?.ready()", arguments: [:], in: nil, contentWorld: .page)
        }
        guard renderRevision == expected else { return }
        _ = try? await view.callAsyncJavaScript(
          "window.KnowLakeNavigation?.initialize(options)",
          arguments: ["options": ["sourceID": detail.source.id, "board": isBoard]],
          in: nil, contentWorld: ReaderController.navigationWorld)
        guard renderRevision == expected else { return }
        if artifact == nil { controller.applyPendingAnchor() }
        controller.applyPendingReturn()
      }
    }
    func followCitation(_ citation: ReaderCitation, in view: WKWebView) {
      guard let detail, let location = controller.location, citationTask == nil else { return }
      if citation.sourceID == detail.source.id, !citation.anchor.isEmpty,
        !detail.content.contains("id=\"\(citation.anchor)\""),
        !detail.content.contains("id='\(citation.anchor)'"),
        !(detail.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && citation.segmentNumber <= detail.segments.count) {
        controller.error = "原文中已找不到这处引用。"
        return
      }
      let expected = renderRevision
      citationTask = Task {
        defer { if renderRevision == expected { citationTask = nil } }
        let state = (try? await view.callAsyncJavaScript(
          "return window.KnowLakeNavigation?.capture() ?? {x: scrollX, y: scrollY}",
          arguments: [:], in: nil, contentWorld: ReaderController.navigationWorld)) as? [String: Any] ?? [:]
        guard !Task.isCancelled, renderRevision == expected else { return }
        controller.remember(ReaderReturnPoint(location: location, position: state))
        openSource(citation.sourceID, citation.anchor)
      }
    }
    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard let data = message.body as? [String: Any], let type = data["type"] as? String else {
        return
      }
      if type == "openURL", let s = data["url"] as? String, let url = URL(string: s),
        ["https", "http"].contains(url.scheme ?? "")
      {
        NSWorkspace.shared.open(url)
      }
      if type == "openSource", message.frameInfo.isMainFrame,
        let id = data["sourceID"] as? String,
        let citation = ReaderCitation(sourceID: id, anchor: data["anchor"] as? String ?? ""),
        let view = message.webView {
        followCitation(citation, in: view)
      }
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if navigationAction.navigationType == .linkActivated {
        if ["http", "https"].contains(url.scheme ?? "") {
          NSWorkspace.shared.open(url)
          decisionHandler(.cancel)
          return
        }
        if url.scheme == "knowlake-source" {
          if navigationAction.sourceFrame.isMainFrame, let citation = ReaderCitation(url: url) {
            followCitation(citation, in: webView)
          }
          decisionHandler(.cancel)
          return
        }
      }
      if url.isFileURL, let root = allowedRoot,
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
      {
        decisionHandler(.allow)
      } else if url.absoluteString == "about:blank" {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }
  }
}
