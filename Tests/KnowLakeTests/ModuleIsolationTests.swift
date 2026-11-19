import Foundation
import XCTest

@testable import KnowLake

final class ModuleIsolationTests: XCTestCase {
  func testDistributionSelectsAvailableModules() {
    XCTAssertEqual(Set(AppModules.sources.map(\.id)),
      AppModules.isPublic ? ["wechat", "markdown"] : ["wechat", "markdown", "bilibili"])
    XCTAssertTrue(AppModules.supports(provider: "codex", mode: "html"))
    XCTAssertEqual(AppModules.supports(provider: "api", mode: "markdown"), !AppModules.isPublic)
    XCTAssertEqual(AppModules.source(for: "https://b23.tv/example")?.id,
                   AppModules.isPublic ? nil : "bilibili")
  }

  func testCodexDiscoveryUsesAbsoluteCandidatesInOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let local = root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let codex = local.appendingPathComponent("codex")
    try Data("#!/bin/sh\n".utf8).write(to: codex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
    let dirs = CodexExecutable.directories(inheritedPath: ":relative:/nonexistent:/nonexistent", home: root)
    XCTAssertEqual(Array(dirs.prefix(2)), ["/nonexistent", local.path])
    XCTAssertEqual(CodexExecutable.resolve("", directories: dirs), codex)
    XCTAssertEqual(CodexExecutable.resolve(codex.path, directories: []), codex)
    XCTAssertNil(CodexExecutable.resolve("relative/codex", directories: dirs))
    XCTAssertNil(CodexExecutable.resolve(local.path, directories: dirs))
  }

  @MainActor func testReaderAssetRootRejectsConfigurationAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archive = root.appendingPathComponent("sources/fixture/version")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let config = root.appendingPathComponent("config.json")
    try Data("{}".utf8).write(to: config)
    let image = archive.appendingPathComponent("preview.png")
    try Data().write(to: image)
    let symlink = archive.appendingPathComponent("false.png")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: config)

    let assets = ReaderAssets()
    XCTAssertNil(assets.configure(archive: root, library: root))
    let base = try XCTUnwrap(assets.configure(archive: archive, library: root))
    XCTAssertNotNil(ReaderAssets.image(at: base.appendingPathComponent("preview.png"), within: archive))
    XCTAssertNil(ReaderAssets.image(at: base.appendingPathComponent("false.png"), within: archive))
    XCTAssertNil(ReaderAssets.image(at: base.appendingPathComponent("config.json"), within: archive))
  }
}
