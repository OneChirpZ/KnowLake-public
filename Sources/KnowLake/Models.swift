import Foundation

struct SourceRecord: Codable, Identifiable, Hashable {
  let id: String
  var title: String
  var url: String
  var platform: String
  var created_at: String
  var summary: String
  var read: Bool
  var starred: Bool
  var collection: String
  var tags: [String]
  var image_path: String?
  var status: String
  var version: String
  var artifact_count: Int? = nil
  var note_count: Int? = nil
  var board_count: Int? = nil
  var image_count: Int? = nil

  var webURL: URL? {
    guard let address = URL(string: url),
      ["https", "http"].contains(address.scheme ?? "") else { return nil }
    return address
  }
}
struct ArtifactRecord: Codable, Identifiable, Hashable {
  let id: String
  var source_id: String
  var kind: String
  var title: String
  var path: String
  var created_at: String
  var model: String?
  var run_id: String?
}
struct LibraryPage: Decodable {
  let items: [SourceRecord]
  let total: Int
  let collections: [String]
  let tags: [String]
}
struct SourceDetail: Decodable {
  let source: SourceRecord
  let content: String
  let segments: [Segment]
  var artifacts: [ArtifactRecord]
  let content_path: String?
}
struct Segment: Codable {
  let start: Double
  let end: Double
  let text: String
}
struct IngestResult: Decodable {
  let source: SourceRecord
  var reused: Bool? = nil
}
struct ArtifactResult: Decodable { let artifact: ArtifactRecord }
struct PathResult: Decodable {
  let path: String?
  let root: String?
}
struct Job: Identifiable, Codable, Sendable {
  var id = UUID()
  let input: String
  var sourceID: String?
  var mode: String?
  var generation: GenerationOptions?
  var importOptions: ImportOptions?
  var kind: String?
  var createdAt: Date? = Date()
  var startedAt: Date?
  var finishedAt: Date?
  var events: [JobEvent]?
  var stageStarts: [String: Date]? = nil
  var currentStage: String? = nil
  var retryFromStage: String? = nil
  var resumeFromRunID: UUID? = nil
  var checkpointRunID: UUID? = nil
  var stageStates: [String: String]? = nil
  var stageArtifacts: [String: [String]]? = nil
  var retryOf: UUID? = nil
  var generationBatchID: UUID? = nil
  var metrics: TaskMetrics? = nil
  var isGeneration: Bool { kind == "generate" || (kind == nil && sourceID != nil) }
  var isWaiting: Bool { !isFinished && state == "排队中" }
  var displayTitle: String { input }
  var eventHistory: [JobEvent] { events ?? [] }
  var state = "排队中"
  var message = ""
  var isFinished = false
  var failed = false
  var cancelled = false
}
struct ReaderDocument: Encodable {
  let sourceID: String
  let id: String
  let title: String
  let url: String
  let platform: String
  let content: String
  let segments: [Segment]
  let theme: String
  let assetBase: String
  let imageURL: String?
  let imageTitle: String?
}
enum LakeError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}

enum GenerationIntent: Equatable {
  case standard
  case supplement
  case regenerate
}

enum GenerationVisualStyle: String, CaseIterable, Codable, Sendable {
  case dark
  case light

  var title: String { self == .dark ? "深色" : "浅色" }

  static func applies(to mode: String) -> Bool { mode == "html" || mode == "image" }
}

struct GenerationOptions: Codable, Sendable {
  var mode: String
  var provider: String
  let model: String
  let apiModel: String
  let baseURL: String
  let style: String
  let depth: String
  let contextStart: String
  let contextEnd: String
  var reasoningEffort: String? = nil
  var apiProfileID: String? = nil
  var fastMode: Bool? = nil
  var selectedVisualStyle: GenerationVisualStyle? = nil
  var visualStyle: GenerationVisualStyle { selectedVisualStyle ?? .dark }

  func selectingMode(_ mode: String) -> GenerationOptions {
    var options = self
    options.mode = mode
    if mode != "markdown" { options.provider = "codex" }
    return options
  }

  func coordinatedGeneration(mode: String) -> GenerationOptions {
    var options = self
    options.mode = mode
    options.provider = "codex"
    return options
  }
}

struct ImportOptions: Codable, Sendable {
  let autoGenerate: Bool
  let collection: String
  let tags: [String]
  let browserPath: String
  var asrProvider: String? = nil
  var generationModes: [String]? = nil
  var assignsCollection: Bool? = nil
  var skipExisting: Bool? = nil
}
struct JobEvent: Codable, Identifiable, Sendable {
  var id = UUID()
  let date: Date
  let message: String
  var streamID: String? = nil
  var stage: String? = nil
  var stageStatus: String? = nil
  var artifacts: [String]? = nil
}

struct CacheInfo: Codable {
  let bytes: Int64
  let maxBytes: Int64
  let retentionDays: Int
  let entries: Int
  let activeEntries: Int
  let removedEntries: Int
  let removedBytes: Int64
  let overLimit: Bool
  let updatedAt: Double?

  enum CodingKeys: String, CodingKey {
    case bytes, entries
    case maxBytes = "max_bytes"
    case retentionDays = "retention_days"
    case activeEntries = "active_entries"
    case removedEntries = "removed_entries"
    case removedBytes = "removed_bytes"
    case overLimit = "over_limit"
    case updatedAt = "updated_at"
  }
}
