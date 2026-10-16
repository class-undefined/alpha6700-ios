import Foundation

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
  case originals, raw, jpeg
  var id: String { rawValue }
  var title: String {
    switch self {
    case .originals: return "全部原文件"
    case .raw: return "RAW（ARW）"
    case .jpeg: return "JPEG（JPG）"
    }
  }
  var shortTitle: String {
    switch self {
    case .originals: return "原文件"
    case .raw: return "RAW"
    case .jpeg: return "JPEG"
    }
  }
  var explanation: String {
    switch self {
    case .originals: return "保留每组的全部原文件，包括 RAW、JPEG、HEIF 和视频。"
    case .raw: return "只导出机身已有的 ARW；没有 RAW 的影像会明确列为跳过。"
    case .jpeg:
      return "优先导出机身 JPEG。只有 RAW / HEIF 时下载原文件并在 iPhone 转为全尺寸 JPEG；本地显影颜色可能与机身 JPEG 不同。视频请选“全部原文件”。"
    }
  }
}
enum ExportStatus: String, Codable {
  case pending, downloading, converting, paused, complete, failed
  var title: String {
    switch self {
    case .pending: return "等待导出"
    case .downloading: return "下载原文件"
    case .converting: return "生成全尺寸 JPEG"
    case .paused: return "已暂停"
    case .complete: return "已导出"
    case .failed: return "导出失败"
    }
  }
}
struct ExportJob: Codable, Identifiable, Equatable {
  let id: String
  let contentID: Int
  let fileID: Int
  let sourceKey: String
  let sourceName: String
  let sourceBytes: Int64
  let format: ExportFormat
  let convertToJPEG: Bool
  var status: ExportStatus = .pending
  var relativeOutput: String?
  var error: String?
  var outputName: String {
    convertToJPEG ? (sourceName as NSString).deletingPathExtension + ".JPG" : sourceName
  }
}
struct ExportPlan {
  let jobs: [ExportJob]
  let skipped: [String]
  var sourceBytes: Int64 {
    jobs.reduce(0) { partial, job in
      let (total, overflow) = partial.addingReportingOverflow(job.sourceBytes)
      return overflow ? Int64.max : total
    }
  }
  var conversionCount: Int { jobs.filter(\.convertToJPEG).count }
}
enum ExportPlanner {
  static func plan(_ items: [CameraMedia], format: ExportFormat) -> ExportPlan {
    var jobs: [ExportJob] = []
    var skipped: [String] = []
    var seen = Set<String>()
    for item in items {
      let files = item.files.filter { $0.size > 0 && $0.key != nil }
      let chosen: [MediaFile]
      switch format {
      case .originals: chosen = files
      case .raw: chosen = files.filter { ext($0) == "arw" && !$0.video }
      case .jpeg:
        if let jpeg = files.first(where: { ["jpg", "jpeg"].contains(ext($0)) && !$0.video }) {
          chosen = [jpeg]
        } else if let source = files.first(where: {
          ["hif", "heif", "heic", "arw", "tif", "tiff", "png"].contains(ext($0)) && !$0.video
        }) {
          chosen = [source]
        } else {
          chosen = []
        }
      }
      if chosen.isEmpty { skipped.append(item.title) }
      for file in chosen {
        guard let key = file.key, !key.isEmpty else { continue }
        let id = key + "-" + format.rawValue
        guard seen.insert(id).inserted else { continue }
        jobs.append(
          ExportJob(
            id: id, contentID: item.id, fileID: file.id, sourceKey: key, sourceName: file.name,
            sourceBytes: file.size, format: format,
            convertToJPEG: format == .jpeg && !["jpg", "jpeg"].contains(ext(file))))
      }
    }
    return ExportPlan(jobs: jobs, skipped: skipped)
  }
  private static func ext(_ file: MediaFile) -> String {
    (file.name as NSString).pathExtension.lowercased()
  }
}
