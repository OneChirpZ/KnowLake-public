import Foundation
import XCTest
@testable import KnowLake

final class EngineRuntimeTests: XCTestCase {
  private let resources = URL(fileURLWithPath: "/Applications/KnowLake.app/Contents/Resources")
  private let sourceEngine = URL(fileURLWithPath: "/development/KnowLake/engine")
  private let applicationSupport = URL(fileURLWithPath: "/users/example/Library/Application Support")
  private let runtimeID = "a12b34c56d78"

  func testPackagedRuntimeExecutesWorkerWithBundledBusinessCode() async throws {
    guard let path = ProcessInfo.processInfo.environment["KNOWLAKE_TEST_APP"] else {
      throw XCTSkip("Set KNOWLAKE_TEST_APP to verify a built or installed App without opening it")
    }
    let bundle = try XCTUnwrap(Bundle(path: path))
    XCTAssertNotNil(bundle.object(forInfoDictionaryKey: "KnowLakeRuntimeID") as? String)
    let resources = try XCTUnwrap(bundle.resourceURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent("Python").path))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowLakePackagedRuntime-\(UUID())")
    defer {
      if FileManager.default.fileExists(atPath: root.path) {
        _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
      }
    }
    let client = EngineClient(bundle: bundle)
    let page: LibraryPage = try await client.request(action: "list", root: root.path)
    XCTAssertEqual(page.total, 0)
    let backup: PathResult = try await client.request(action: "backup", root: root.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(backup.path)))
    await client.shutdown()
  }

  func testPackagedAppUsesVersionedExternalRuntimeAndBundledEngine() throws {
    let runtime = EngineRuntime.resolve(
      resources: resources, sourceEngine: sourceEngine,
      applicationSupport: applicationSupport, runtimeID: runtimeID,
      fileExists: { _ in true })

    XCTAssertEqual(runtime.directory, resources.appendingPathComponent("engine"))
    XCTAssertEqual(
      runtime.python.path,
      "/users/example/Library/Application Support/KnowLake/Runtime/a12b34c56d78/Python/bin/python3")
    XCTAssertNoThrow(try runtime.validatePython(isExecutable: { $0 == runtime.python.path }))
  }

  func testMissingProductionRuntimeDoesNotFallBackToEmbeddedOrDevelopmentPython() {
    let runtime = EngineRuntime.resolve(
      resources: resources, sourceEngine: sourceEngine,
      applicationSupport: applicationSupport, runtimeID: runtimeID,
      fileExists: { _ in true })
    var checkedPaths: [String] = []

    XCTAssertThrowsError(try runtime.validatePython(isExecutable: { path in
      checkedPaths.append(path)
      return path != runtime.python.path
    })) { error in
      XCTAssertTrue(error.localizedDescription.contains("scripts/package.sh"))
      XCTAssertTrue(error.localizedDescription.contains(self.runtimeID))
      XCTAssertFalse(error.localizedDescription.contains("setup.sh"))
    }
    XCTAssertEqual(checkedPaths, [runtime.python.path])
    XCTAssertEqual(runtime.directory, resources.appendingPathComponent("engine"))
  }

  func testDevelopmentBuildUsesProjectVirtualEnvironment() {
    let runtime = EngineRuntime.resolve(
      resources: resources, sourceEngine: sourceEngine,
      applicationSupport: applicationSupport, runtimeID: nil,
      fileExists: { _ in false })

    XCTAssertEqual(runtime.directory, sourceEngine)
    XCTAssertEqual(runtime.python, sourceEngine.appendingPathComponent(".venv/bin/python3"))
    XCTAssertThrowsError(try runtime.validatePython(isExecutable: { _ in false })) { error in
      XCTAssertTrue(error.localizedDescription.contains("scripts/setup.sh"))
    }
  }

  func testLegacyPackagedAppKeepsEmbeddedPython() {
    let runtime = EngineRuntime.resolve(
      resources: resources, sourceEngine: sourceEngine,
      applicationSupport: applicationSupport, runtimeID: nil,
      fileExists: { _ in true })

    XCTAssertEqual(runtime.directory, resources.appendingPathComponent("engine"))
    XCTAssertEqual(runtime.python, resources.appendingPathComponent("Python/bin/python3"))
  }

  func testExplicitFixturePathsRemainSupported() {
    let directory = URL(fileURLWithPath: "/fixtures/engine")
    let python = URL(fileURLWithPath: "/fixtures/python3")
    let runtime = EngineRuntime.resolve(
      resources: resources, sourceEngine: sourceEngine,
      applicationSupport: applicationSupport, runtimeID: nil,
      directoryOverride: directory, pythonOverride: python,
      fileExists: { _ in false })

    XCTAssertEqual(runtime.directory, directory)
    XCTAssertEqual(runtime.python, python)
  }

  func testWorkerEnvironmentUsesTheVerifiedRuntimeAndPinnedModel() {
    let runtime = EngineRuntime.resolve(
      resources: resources, sourceEngine: sourceEngine,
      applicationSupport: applicationSupport, runtimeID: runtimeID)
    let environment = runtime.environment(inheriting: [
      "PYTHONHOME": "/other/python",
      "VIRTUAL_ENV": "/other/venv",
      "FPGEN_MODEL_URL": "https://example.invalid/model.zip",
      "FPGEN_NO_INIT": "1",
      "PYTHONNOUSERSITE": "0",
      "PYTHONPATH": "/other/modules",
      "PYTHONUNBUFFERED": "0",
      "PYTHONDONTWRITEBYTECODE": "0",
      "PATH": "/custom/bin:/usr/bin",
      "HTTPS_PROXY": "http://127.0.0.1:8080",
      "CAMOUFOX_EXECUTABLE_PATH": "/custom/Camoufox",
    ])

    for key in ["PYTHONHOME", "VIRTUAL_ENV", "FPGEN_MODEL_URL", "FPGEN_NO_INIT"] {
      XCTAssertNil(environment[key], "Inherited \(key) must not override the verified runtime")
    }
    XCTAssertEqual(environment["PYTHONNOUSERSITE"], "1")
    XCTAssertEqual(environment["PYTHONPATH"], resources.appendingPathComponent("engine").path)
    XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
    XCTAssertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
    XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/custom/bin:/usr/bin")
    XCTAssertEqual(environment["HTTPS_PROXY"], "http://127.0.0.1:8080")
    XCTAssertEqual(environment["CAMOUFOX_EXECUTABLE_PATH"], "/custom/Camoufox")
  }

  func testWorkerEnvironmentKeepsTheDefaultExecutableSearchPath() {
    let runtime = EngineRuntime.resolve(
      resources: resources, sourceEngine: sourceEngine,
      applicationSupport: applicationSupport, runtimeID: nil,
      fileExists: { _ in false })

    XCTAssertEqual(
      runtime.environment(inheriting: [:])["PATH"],
      "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
  }
}
