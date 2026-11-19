import Foundation

struct EngineRuntime {
  let directory: URL
  let python: URL
  let missingRuntimeMessage: String

  static func resolve(
    resources: URL,
    sourceEngine: URL,
    applicationSupport: URL,
    runtimeID: String?,
    directoryOverride: URL? = nil,
    pythonOverride: URL? = nil,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> EngineRuntime {
    let packaged = resources.appendingPathComponent("engine")
    let directory = directoryOverride
      ?? (runtimeID != nil || fileExists(packaged.path) ? packaged : sourceEngine)
    let developmentMessage = "处理引擎尚未准备好。请先运行 scripts/setup.sh，再重新打开 KnowLake。"

    if let pythonOverride {
      return EngineRuntime(
        directory: directory, python: pythonOverride, missingRuntimeMessage: developmentMessage)
    }
    if let runtimeID {
      let runtime = applicationSupport.appendingPathComponent("KnowLake/Runtime")
        .appendingPathComponent(runtimeID)
      return EngineRuntime(
        directory: directory,
        python: runtime.appendingPathComponent("Python/bin/python3"),
        missingRuntimeMessage:
          "处理引擎运行环境缺失或不可执行。请退出 KnowLake，运行 scripts/package.sh 以准备运行环境。\n所需位置：\(runtime.path)")
    }

    let bundled = resources.appendingPathComponent("Python/bin/python3")
    return EngineRuntime(
      directory: directory,
      python: fileExists(bundled.path) ? bundled : directory.appendingPathComponent(".venv/bin/python3"),
      missingRuntimeMessage: developmentMessage)
  }

  func validatePython(
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) throws {
    guard isExecutable(python.path) else {
      throw LakeError.message(missingRuntimeMessage)
    }
  }

  func environment(inheriting inherited: [String: String]) -> [String: String] {
    var environment = inherited
    for key in ["PYTHONHOME", "VIRTUAL_ENV", "FPGEN_MODEL_URL", "FPGEN_NO_INIT"] {
      environment.removeValue(forKey: key)
    }
    environment["PYTHONNOUSERSITE"] = "1"
    environment["PYTHONPATH"] = directory.path
    environment["PYTHONUNBUFFERED"] = "1"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (inherited["PATH"] ?? "/usr/bin:/bin")
    return environment
  }
}
