import Foundation

extension CameraModel {
  func exportSelected(_ items: [CameraMedia]) async {
    guard !exporting, !importing, !busy else { return }
    let plan = ExportPlanner.plan(items, format: exports.format)
    exportNotice = plan.skipped.isEmpty ? nil : "跳过 \(plan.skipped.count) 组没有目标格式的影像"
    guard !plan.jobs.isEmpty else {
      error = "所选影像没有可导出的 \(exports.format.shortTitle) 文件"
      return
    }
    do {
      try exports.enqueue(plan)
      await runExports()
    } catch { self.error = error.localizedDescription }
  }
  func resumeExports() async {
    guard !exporting, !importing, !busy else { return }
    do {
      try exports.resumeAll()
      await runExports()
    } catch { self.error = error.localizedDescription }
  }
  func pauseExports() {
    exportPauseRequested = true
    pauseImport()
    message = "当前分段完成后暂停批量导出"
  }
  func runExports() async {
    guard !exporting, !importing, !busy else { return }
    let jobs = exports.activeJobs.filter { $0.status != .complete || exports.outputURL($0) == nil }
    guard !jobs.isEmpty else {
      message = "所选文件已在导出列表中"
      return
    }
    guard connected || jobs.allSatisfy({ cachedSource($0) != nil }) else {
      error = "连接相机后继续导出"
      return
    }
    exporting = true
    exportPauseRequested = false
    error = nil
    let token = sessionID
    bridge.cancelPendingPreviews()
    await stopLive()
    for job in jobs {
      guard token == sessionID, !exportPauseRequested else { break }
      currentExportID = job.id
      do {
        try exports.update(job.id, status: .downloading)
        let source: URL
        if let cached = cachedSource(job) {
          source = cached
        } else {
          guard
            let transferred = await importFile(
              job.contentID, job.fileID, expectedKey: job.sourceKey, forExport: true)
          else {
            guard token == sessionID else { return }
            if exportPauseRequested || !connected {
              try exports.update(job.id, status: .paused)
            } else {
              try exports.update(job.id, status: .failed, error: error ?? "原文件下载未完成")
            }
            break
          }
          source = URL(fileURLWithPath: transferred.path)
        }
        guard token == sessionID else { return }
        if exportPauseRequested {
          try exports.update(job.id, status: .paused)
          break
        }
        let output: URL
        if job.convertToJPEG {
          try exports.update(job.id, status: .converting)
          message = "生成全尺寸 JPEG · \(job.outputName)"
          output = exports.jpegDestination(job)
          try await PhotoDecoder.exportJPEG(source, to: output)
        } else {
          output = source
        }
        guard token == sessionID else { return }
        try exports.update(job.id, status: .complete, output: output)
        message = "已导出 \(job.outputName)"
      } catch {
        guard token == sessionID else { return }
        try? exports.update(job.id, status: .failed, error: error.localizedDescription)
        self.error = error.localizedDescription
        break
      }
    }
    guard token == sessionID else { return }
    if exportPauseRequested { try? exports.pauseActive() }
    exporting = false
    currentExportID = nil
    let done = exports.activeJobs.filter { $0.status == .complete }.count
    message = exportPauseRequested ? "批量导出已暂停" : "本批次已导出 \(done)/\(exports.activeIDs.count) 个文件"
    if selectedTab == 0, preferLive, connected { await startLive() }
  }
  func cachedSource(_ job: ExportJob) -> URL? {
    guard let file = transfers.first(where: { $0.key == job.sourceKey && $0.complete }),
      FileManager.default.fileExists(atPath: file.path)
    else { return nil }
    return URL(fileURLWithPath: file.path)
  }
  var batchProgress: Double {
    let jobs = exports.activeJobs
    guard !jobs.isEmpty else { return 0 }
    var completed = Double(jobs.filter { $0.status == .complete }.count)
    if let active = jobs.first(where: { $0.id == currentExportID && $0.status != .complete }) {
      if active.status == .converting {
        completed += 0.95
      } else {
        completed +=
          (transfers.first { $0.key == active.sourceKey }?.progress ?? 0)
          * (active.convertToJPEG ? 0.9 : 1)
      }
    }
    return completed / Double(jobs.count)
  }
}
