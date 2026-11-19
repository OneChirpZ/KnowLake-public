import Foundation

enum KnowLakeResources {
  static var directory: URL? {
    let name = "KnowLake_KnowLake.bundle"
    if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent(name),
      let resources = Bundle(url: bundleURL)?.resourceURL
    {
      return resources.appendingPathComponent("Resources", isDirectory: true)
    }
    #if DEBUG
    return Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true)
    #else
    return nil
    #endif
  }
}
