import Darwin
import Foundation

struct ConfigurationStore {
  let fileURL: URL

  init(root: String) {
    fileURL = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("config.json")
  }

  func credential(_ account: String) throws -> String {
    let document = try load()
    return (document["credentials"] as? [String: String])?[account] ?? ""
  }

  func saveCredential(_ value: String, account: String) throws {
    var document = try load()
    var credentials = document["credentials"] as? [String: String] ?? [:]
    credentials[account] = value
    document["credentials"] = credentials
    try save(document)
  }

  func preferences() throws -> [String: Any] {
    try load()["preferences"] as? [String: Any] ?? [:]
  }

  func initialize() throws -> [String: Any] {
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      try save(Self.template, ifMissing: true)
    }
    return try preferences()
  }

  private static let template: [String: Any] = [
    "version": 1, "preferencesSchemaVersion": 1,
    "preferences": [String: Any](), "credentials": [String: String](),
  ]

  func savePreference(_ value: Any, forKey key: String) throws {
    var document = try load()
    var preferences = document["preferences"] as? [String: Any] ?? [:]
    if let old = preferences[key] as? NSObject, let new = value as? NSObject, old == new { return }
    preferences[key] = value
    document["preferences"] = preferences
    document["preferencesSchemaVersion"] = 1
    try save(document)
  }

  private func save(_ document: [String: Any], ifMissing: Bool = false) throws {
    let data = try JSONSerialization.data(
      withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let directory = fileURL.deletingLastPathComponent()
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      let status = ifMissing
        ? renamex_np(temporary.path, fileURL.path, UInt32(RENAME_EXCL))
        : rename(temporary.path, fileURL.path)
      if status != 0 {
        let code = errno
        if ifMissing && code == EEXIST {
          try manager.trashItem(at: temporary, resultingItemURL: nil)
          return
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
    } catch {
      try? handle.close()
      try? manager.trashItem(at: temporary, resultingItemURL: nil)
      throw error
    }
  }

  private func load() throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return Self.template
    }
    let data = try Data(contentsOf: fileURL)
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LakeError.message("config.json 必须是 JSON 对象")
    }
    if let version = document["version"], (version as? Int) != 1 {
      throw LakeError.message("config.json 的版本不受支持，请使用兼容的应用版本")
    }
    if let credentials = document["credentials"], !(credentials is [String: String]) {
      throw LakeError.message("config.json 中的 credentials 格式无效")
    }
    if let preferences = document["preferences"], !(preferences is [String: Any]) {
      throw LakeError.message("config.json 中的 preferences 格式无效")
    }
    if let version = document["preferencesSchemaVersion"], (version as? Int) != 1 {
      throw LakeError.message("config.json 中的设置版本不受支持，请使用兼容的应用版本")
    }
    return document
  }
}
