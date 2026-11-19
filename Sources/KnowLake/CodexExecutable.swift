import Foundation

enum CodexExecutable {
  static func directories(inheritedPath: String?, home: URL) -> [String] {
    let inherited = (inheritedPath ?? "").split(separator: ":").map(String.init)
      .filter { $0.hasPrefix("/") }
    let paths = inherited + [
      home.appendingPathComponent(".local/bin").path,
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ]
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  static func resolve(
    _ configured: String, directories: [String], files: FileManager = .default
  ) -> URL? {
    let value = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    let expanded = (value as NSString).expandingTildeInPath
    let candidates: [String]
    if expanded.contains("/") {
      guard expanded.hasPrefix("/") else { return nil }
      candidates = [expanded]
    } else {
      let name = expanded.isEmpty ? "codex" : expanded
      candidates = directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
    }
    for path in candidates {
      let url = URL(fileURLWithPath: path)
      let resolved = url.resolvingSymlinksInPath()
      if files.isExecutableFile(atPath: path),
        (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      {
        return url
      }
    }
    return nil
  }
}

enum BundledWritingSkill {
  static let name = "lieflat-less-ai-tone"
  static var root: URL? {
    KnowLakeResources.directory?.appendingPathComponent("Skills", isDirectory: true)
  }
  static var file: URL? {
    root?.appendingPathComponent(name, isDirectory: true).appendingPathComponent("SKILL.md")
  }
}
