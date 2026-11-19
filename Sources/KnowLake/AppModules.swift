import Foundation

struct SourceModule {
  let id: String
  let title: String
  let symbol: String
  let hosts: Set<String>
  var usesMediaCache = false
  let parameters: @MainActor (Preferences, ImportOptions) -> [String: Any]
}

struct GenerationModule {
  let id: String
  let title: String
  let modes: Set<String>
}

enum AppModules {
  static let markdown = SourceModule(
    id: "markdown", title: "本地 Markdown", symbol: "doc.plaintext", hosts: [],
    parameters: { _, _ in [:] })
  static let wechat = SourceModule(
    id: "wechat", title: "微信公众号", symbol: "doc.text", hosts: ["mp.weixin.qq.com"],
    parameters: { _, options in
      options.browserPath.isEmpty ? [:] : ["browser_path": options.browserPath]
    })
  static let codex = GenerationModule(
    id: "codex", title: "Codex Agent", modes: ["markdown", "html", "image"])

  #if KNOWLAKE_PRIVATE
  static let isPublic = false
  static let defaultCodexModel = PrivateModules.defaultCodexModel
  static let defaultCodexEffort = PrivateModules.defaultCodexEffort
  static let sources = [PrivateModules.bilibili, wechat, markdown]
  static let generators = [codex, PrivateModules.api]
  #else
  static let isPublic = true
  static let defaultCodexModel = ""
  static let defaultCodexEffort = ""
  static let sources = [wechat, markdown]
  static let generators = [codex]
  #endif

  static var hasMediaCache: Bool { sources.contains(where: \.usesMediaCache) }

  static func source(for url: URL) -> SourceModule? {
    guard let host = url.host?.lowercased() else { return nil }
    return sources.first { $0.hosts.contains(host) }
  }

  static func source(for link: String) -> SourceModule? {
    let address = link.contains("://") ? link : "https://" + link
    return URL(string: address).flatMap(source(for:))
  }

  static func supports(provider: String, mode: String) -> Bool {
    generators.contains { $0.id == provider && $0.modes.contains(mode) }
  }
}
