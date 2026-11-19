import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor final class ReaderAssets: NSObject, WKURLSchemeHandler {
  static let scheme = "knowlake-asset"
  private var root: URL?
  private var base: URL?

  func configure(archive: URL?, library: URL) -> URL? {
    clear()
    guard let archive else { return nil }
    guard let path = Self.archiveDirectory(archive, in: library) else { return nil }
    root = path
    base = URL(string: "\(Self.scheme)://\(UUID().uuidString.lowercased())/")
    return base
  }

  static func archiveDirectory(_ directory: URL, in library: URL) -> URL? {
    let path = directory.resolvingSymlinksInPath().standardizedFileURL
    let libraryPath = library.resolvingSymlinksInPath().standardizedFileURL
    return ["sources", "artifacts"].contains {
      path.path.hasPrefix(libraryPath.appendingPathComponent($0).path + "/")
    } ? path : nil
  }

  func clear() {
    root = nil
    base = nil
  }

  static func image(at address: URL, within root: URL) -> URL? {
    let relative = String(address.path.dropFirst())
    guard !relative.isEmpty else { return nil }
    let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard candidate.path.hasPrefix(root.path + "/"),
      UTType(filenameExtension: candidate.pathExtension)?.conforms(to: .image) == true
    else { return nil }
    return candidate
  }

  func file(for url: URL) -> URL? {
    guard let root, url.scheme == Self.scheme, url.host == base?.host else { return nil }
    return Self.image(at: url, within: root)
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url, let file = file(for: url),
      let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
    else {
      task.didFailWithError(URLError(.noPermissionsToReadFile))
      return
    }
    do {
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": type, "Access-Control-Allow-Origin": "*"])!
      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch {
      task.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
