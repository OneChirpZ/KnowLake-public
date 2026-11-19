import Foundation

enum FolderBrowsingMode: String {
  case levels, tree
}

enum LibraryFolder {
  struct TreeRow: Identifiable, Equatable {
    let path: String
    let depth: Int
    let hasChildren: Bool
    var id: String { path }
  }

  static func parent(of path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
  }

  static func name(of path: String) -> String {
    let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    return name.isEmpty ? path : name
  }

  static func ancestors(of path: String) -> [String] {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return components.indices.map { components[...$0].joined(separator: "/") }.filter { !$0.isEmpty }
  }

  static func contains(_ path: String, in parent: String) -> Bool {
    path == parent
  }

  static func all(in paths: [String]) -> [String] {
    Array(Set(paths.flatMap { ancestors(of: $0) })).sorted()
  }

  static func children(of path: String, in paths: [String]) -> [String] {
    all(in: paths).filter { parent(of: $0) == path }
  }

  static func tree(in paths: [String], expanded: Set<String>) -> [TreeRow] {
    let children = Dictionary(grouping: all(in: paths), by: { parent(of: $0) })
    var rows: [TreeRow] = []
    func appendChildren(of parent: String, depth: Int) {
      for path in children[parent] ?? [] {
        let hasChildren = children[path] != nil
        rows.append(TreeRow(path: path, depth: depth, hasChildren: hasChildren))
        if hasChildren && expanded.contains(path) { appendChildren(of: path, depth: depth + 1) }
      }
    }
    appendChildren(of: "", depth: 0)
    return rows
  }

  static func displayPath(_ path: String) -> String {
    if path.split(separator: "/", omittingEmptySubsequences: false).contains("") { return path }
    return path.split(separator: "/").joined(separator: " › ")
  }
}
