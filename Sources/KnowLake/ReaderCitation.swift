import Foundation

/// Internal citation addresses point to immutable source snapshot anchors.
struct ReaderCitation: Equatable {
  let sourceID: String
  let anchor: String
  var segmentNumber: Int { Int(anchor.dropFirst("segment-".count)) ?? 0 }

  init?(sourceID: String, anchor: String) {
    guard sourceID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
      anchor.isEmpty || anchor.range(of: "^segment-[1-9][0-9]*$", options: .regularExpression) != nil
    else { return nil }
    self.sourceID = sourceID
    self.anchor = anchor
  }
  init?(url: URL) {
    guard url.scheme == "knowlake-source", url.user == nil, url.password == nil,
      url.port == nil, url.query == nil, url.path.isEmpty || url.path == "/",
      let host = url.host else { return nil }
    self.init(sourceID: host, anchor: url.fragment?.removingPercentEncoding ?? url.fragment ?? "")
  }
}

struct ReaderLocation: Equatable {
  let root: String
  let sourceID: String
  let artifactID: String?
}

struct ReaderReturnPoint {
  let location: ReaderLocation
  let position: [String: Any]
}
