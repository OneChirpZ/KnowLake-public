import CoreFoundation
import Foundation

@MainActor final class Preferences: ObservableObject {
  private static let defaultMaxConcurrentGenerations = 3

  @Published var root = "" {
    didSet {
      guard !isLoadingConfiguration, root != oldValue else { return }
      defaults.set(root, forKey: Self.libraryRootKey)
    }
  }
  @Published var model = AppModules.defaultCodexModel { didSet { persist(model, forKey: "model") } }
  @Published var codexPath = "" { didSet { persist(codexPath, forKey: "codexPath") } }
  @Published var provider = "codex" { didSet { persist(provider, forKey: "provider") } }
  #if KNOWLAKE_PRIVATE
  @Published var baseURL = APIModelCatalog.defaultBaseURL { didSet { persist(baseURL, forKey: "baseURL") } }
  @Published var apiModel = "" {
    didSet {
      persist(apiModel, forKey: "apiModel")
      if apiProfileID.isEmpty { persist(apiModel, forKey: "customAPIModel") }
    }
  }
  #endif
  @Published var backupDays = 1 { didSet { persist(backupDays, forKey: "backupDays") } }
  @Published var backupDirectory = "" { didSet { persist(backupDirectory, forKey: "backupDirectory") } }
  @Published var folderBrowsingMode = FolderBrowsingMode.levels {
    didSet { persist(folderBrowsingMode.rawValue, forKey: "folderBrowsingMode") }
  }
  @Published var autoGenerate = !AppModules.isPublic { didSet { persist(autoGenerate, forKey: "autoGenerate") } }
  @Published var maxConcurrentGenerations = defaultMaxConcurrentGenerations {
    didSet {
      if maxConcurrentGenerations < 1 { maxConcurrentGenerations = Self.defaultMaxConcurrentGenerations }
      persist(maxConcurrentGenerations, forKey: "maxConcurrentGenerations")
    }
  }
  @Published var generationModes = ["markdown"] {
    didSet {
      let modes = Self.normalizedGenerationModes(generationModes)
      if generationModes != modes { generationModes = modes }
      persist(modes, forKey: "generationModes")
    }
  }
  @Published var visualStyle = GenerationVisualStyle.dark {
    didSet { persist(visualStyle.rawValue, forKey: "visualStyle") }
  }
  @Published var reasoningEffort = AppModules.defaultCodexEffort { didSet { persist(reasoningEffort, forKey: "reasoningEffort") } }
  @Published var fastMode = false { didSet { persist(fastMode, forKey: "fastMode") } }
  @Published var depth = "标准" { didSet { persist(depth, forKey: "depth") } }
  @Published var style = "结构清晰，保留关键事实、方法和来源引用" {
    didSet { persist(style, forKey: "style") }
  }
  @Published var browserPath = "" { didSet { persist(browserPath, forKey: "browserPath") } }
  @Published var configurationError: String?
  @Published var customCodexModels: [String] = []
  #if KNOWLAKE_PRIVATE
  @Published var apiProfiles: [APIProfile] = []
  @Published var apiProfileID = "" { didSet { persist(apiProfileID, forKey: "apiProfileID") } }
  @Published var apiModelNames: [String] = []
  @Published var isLoadingModels = false
  @Published var modelCatalogError: String?
  @Published var asrProvider = "doubao-asr" { didSet { persist(asrProvider, forKey: "asrProvider") } }
  #endif
  let configuration: ConfigurationStore
  private let defaults: UserDefaults
  private(set) var settings: [String: Any] = [:]
  private var isLoadingConfiguration = true
  private let credentialReader: ((String) -> String)?
  private let credentialWriter: ((String, String) throws -> Void)?
  #if KNOWLAKE_PRIVATE
  var catalogRequest = UUID()
  var fetchedIdentity: String?
  var customModels: [String: [String]] = [:]
  var remoteModels: [String: [String]] = [:]
  var lastSelectedModels: [String: String] = [:]
  var catalog = APIModelCatalog()
  var customAPIBaseURL = APIModelCatalog.defaultBaseURL
  #endif
  var requiresCodexGeneration: Bool { generationModes.contains { $0 != "markdown" } }
  var generationProvider: String {
    requiresCodexGeneration || !AppModules.supports(provider: provider, mode: "markdown")
      ? "codex" : provider
  }

  private static func normalizedGenerationModes(_ modes: [String]) -> [String] {
    ["markdown", "html", "image"].filter { modes.contains($0) }
  }

  nonisolated static let libraryRootKey = "knowlakeLibraryRoot"
  nonisolated static var defaultRoot: String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".KnowLake").path
  }

  init(
    defaults: UserDefaults = .standard, configurationRoot: String = Preferences.defaultRoot,
    credentialReader: ((String) -> String)? = nil,
    credentialWriter: ((String, String) throws -> Void)? = nil
  ) {
    self.defaults = defaults
    self.configuration = ConfigurationStore(root: configurationRoot)
    self.credentialReader = credentialReader
    self.credentialWriter = credentialWriter
    root = defaults.string(forKey: Self.libraryRootKey) ?? configurationRoot
    loadConfiguration()
  }

  func reloadImported() { loadConfiguration() }

  private func loadConfiguration() {
    isLoadingConfiguration = true
    do {
      settings = try configuration.initialize()
      configurationError = nil
    } catch {
      settings = [:]
      configurationError = "无法读取配置：" + error.localizedDescription
    }
    model = settings["model"] as? String ?? AppModules.defaultCodexModel
    codexPath = settings["codexPath"] as? String ?? ""
    provider = settings["provider"] as? String ?? "codex"
    backupDays = settings["backupDays"] as? Int ?? 1
    backupDirectory = settings["backupDirectory"] as? String ?? ""
    folderBrowsingMode = (settings["folderBrowsingMode"] as? String).flatMap(FolderBrowsingMode.init(rawValue:)) ?? .levels
    customCodexModels = settings["customCodexModels"] as? [String] ?? []
    browserPath = settings["browserPath"] as? String ?? ""
    autoGenerate = settings["autoGenerate"] as? Bool ?? !AppModules.isPublic
    let generationLimit = settings["maxConcurrentGenerations"] as? NSNumber
    if let generationLimit, CFGetTypeID(generationLimit) != CFBooleanGetTypeID() {
      maxConcurrentGenerations = generationLimit as? Int ?? Self.defaultMaxConcurrentGenerations
    } else {
      maxConcurrentGenerations = Self.defaultMaxConcurrentGenerations
    }
    generationModes = Self.normalizedGenerationModes(settings["generationModes"] as? [String] ?? ["markdown"])
    visualStyle = (settings["visualStyle"] as? String).flatMap(GenerationVisualStyle.init(rawValue:)) ?? .dark
    reasoningEffort = settings["reasoningEffort"] as? String ?? AppModules.defaultCodexEffort
    fastMode = settings["fastMode"] as? Bool ?? false
    depth = settings["depth"] as? String ?? "标准"
    style = settings["style"] as? String ?? "结构清晰，保留关键事实、方法和来源引用"
    #if KNOWLAKE_PRIVATE
    loadPrivateConfiguration()
    #endif
    isLoadingConfiguration = false
    #if KNOWLAKE_PRIVATE
    finishPrivateConfiguration()
    #endif
  }

  func persist(_ value: Any, forKey key: String) {
    guard !isLoadingConfiguration else { return }
    do {
      try configuration.savePreference(value, forKey: key)
      settings[key] = value
      configurationError = nil
    } catch {
      configurationError = "无法保存配置：" + error.localizedDescription
    }
  }
  func addCustomCodexModel(_ name: String) {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    customCodexModels = Array(Set(customCodexModels + [value])).sorted()
    persist(customCodexModels, forKey: "customCodexModels")
    model = value
  }
  var networkProxy: String { credential("network-proxy") }
  func credential(_ account: String) -> String {
    if let credentialReader { return credentialReader(account) }
    do { return try configuration.credential(account) }
    catch {
      let message = "无法读取配置：" + error.localizedDescription
      if configurationError != message {
        Task { @MainActor [weak self] in
          guard let self, self.configurationError != message else { return }
          self.configurationError = message
        }
      }
      return ""
    }
  }
  func writeCredential(_ value: String, account: String) throws {
    if let credentialWriter {
      try credentialWriter(account, value)
      return
    }
    try configuration.saveCredential(value, account: account)
  }
}
