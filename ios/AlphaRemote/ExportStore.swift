import Foundation
import Observation

@MainActor @Observable final class ExportStore {
  private struct State: Codable {
    var jobs: [ExportJob]
    var activeIDs: [String]
  }
  private(set) var jobs: [ExportJob] = []
  private(set) var activeIDs: [String] = []
  var loadError: String?
  @ObservationIgnored private let preferences: UserDefaults
  var format: ExportFormat {
    didSet { preferences.set(format.rawValue, forKey: "photoExportFormat") }
  }
  let documents: URL
  let directory: URL
  private let stateURL: URL
  init(testing: Bool = false, documentsURL: URL? = nil, defaults: UserDefaults = .standard) {
    preferences = defaults
    documents =
      documentsURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    directory = documents.appendingPathComponent(
      testing ? ".ui-test-exports" : "Exports", isDirectory: true)
    stateURL = directory.appendingPathComponent(".queue.json")
    if ProcessInfo.processInfo.arguments.contains("--reset-export-preferences") {
      defaults.removeObject(forKey: "photoExportFormat")
    }
    format =
      ExportFormat(rawValue: defaults.string(forKey: "photoExportFormat") ?? "")
      ?? .originals
    do {
      if testing, FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: stateURL.path) {
        var state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        for i in state.jobs.indices
        where state.jobs[i].status == .downloading || state.jobs[i].status == .converting {
          state.jobs[i].status = .paused
        }
        jobs = state.jobs
        activeIDs = state.activeIDs
      }
    } catch { loadError = "无法读取导出队列：\(error.localizedDescription)" }
  }
  var unfinished: [ExportJob] { jobs.filter { $0.status != .complete } }
  var completedURLs: [URL] { jobs.filter { $0.status == .complete }.compactMap { outputURL($0) } }
  var activeJobs: [ExportJob] { activeIDs.compactMap { id in jobs.first { $0.id == id } } }
  func enqueue(_ plan: ExportPlan) throws {
    var next = jobs
    for job in plan.jobs {
      if let i = next.firstIndex(where: { $0.id == job.id }) {
        if next[i].status != .complete || outputURL(next[i]) == nil {
          next[i].status = .pending
          next[i].error = nil
        }
      } else {
        next.append(job)
      }
    }
    try persist(next, active: plan.jobs.map(\.id))
  }
  func resumeAll() throws { try persist(jobs, active: unfinished.map(\.id)) }
  func update(_ id: String, status: ExportStatus, output: URL? = nil, error: String? = nil) throws {
    guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
    var next = jobs
    next[i].status = status
    next[i].error = error
    if let output {
      let prefix = documents.standardizedFileURL.path + "/"
      guard output.standardizedFileURL.path.hasPrefix(prefix) else {
        throw CameraFailure(message: "导出路径不在 App 文件目录内")
      }
      next[i].relativeOutput = String(output.standardizedFileURL.path.dropFirst(prefix.count))
    }
    try persist(next, active: activeIDs)
  }
  func pauseActive() throws {
    var next = jobs
    for i in next.indices
    where activeIDs.contains(next[i].id) && next[i].status != .complete && next[i].status != .failed
    { next[i].status = .paused }
    try persist(next, active: activeIDs)
  }
  func outputURL(_ job: ExportJob) -> URL? {
    guard let relative = job.relativeOutput, !relative.hasPrefix("/") else { return nil }
    let url = documents.appendingPathComponent(relative).standardizedFileURL
    guard url.path.hasPrefix(documents.standardizedFileURL.path + "/"),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return url
  }
  func jpegDestination(_ job: ExportJob) -> URL {
    directory.appendingPathComponent(job.id + "-" + job.outputName)
  }
  private func persist(_ next: [ExportJob], active: [String]) throws {
    let data = try JSONEncoder().encode(State(jobs: next, activeIDs: active))
    try data.write(to: stateURL, options: .atomic)
    jobs = next
    activeIDs = active
  }
}
