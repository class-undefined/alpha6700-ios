import SwiftUI

struct ExportSettingsView: View {
  @Environment(CameraModel.self) private var camera
  var body: some View {
    @Bindable var store = camera.exports
    Form {
      Section("照片导出格式") {
        Picker("格式", selection: $store.format) {
          ForEach(ExportFormat.allCases) { format in
            Text(format.title).tag(format).accessibilityIdentifier(
              "exportFormat-\(format.rawValue)")
          }
        }.pickerStyle(.inline)
      }
      Section { Text(store.format.explanation).font(.subheadline) }
      Section("保存与分享") {
        Text("导出结果保存在此 iPhone 的 App 文件目录。完成后在“素材 → 已导出 / 队列”分享文件，或保存到系统照片。")
        Text("格式设置只影响新建的导出任务。相册里的“原图”按钮始终下载原文件用于放大查看。")
      }.font(.footnote).foregroundStyle(.secondary)
      if store.format == .jpeg {
        Section("JPEG 转换") {
          Text(
            "在手机上串行转换为全尺寸、质量 95% 的 sRGB JPEG，保留可用的拍摄日期、曝光和 GPS 信息。RAW 不受系统支持时会报错并保留源文件，不使用低清预览替代。"
          ).font(.footnote)
        }
      }
    }.navigationTitle("导出设置").navigationBarTitleDisplayMode(.inline)
  }
}
struct ExportQueueView: View {
  @Environment(CameraModel.self) private var camera
  private var store: ExportStore { camera.exports }
  private var activeURLs: [URL] {
    store.activeJobs.filter { $0.status == .complete }.compactMap { store.outputURL($0) }
  }
  private var standaloneTransfers: [CameraTransfer] {
    let keys = Set(store.jobs.map(\.sourceKey))
    return camera.transfers.filter { !keys.contains($0.key) }
  }
  var body: some View {
    List {
      if let notice = camera.exportNotice {
        Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
      }
      if let failure = store.loadError { Section { Text(failure).foregroundStyle(.red) } }
      if !store.activeIDs.isEmpty {
        Section("本批次") {
          ProgressView(value: camera.batchProgress).accessibilityIdentifier("batchExportProgress")
          Text(
            "已导出 \(store.activeJobs.filter{$0.status == .complete}.count)/\(store.activeIDs.count) 个文件"
          ).font(.subheadline.monospacedDigit()).accessibilityIdentifier("batchExportSummary")
          if camera.exporting {
            if camera.importing {
              Text(camera.transferSpeedLabel).font(.caption.monospacedDigit()).foregroundStyle(
                Theme.accent)
            }
            Button("暂停批量导出") { camera.pauseExports() }.accessibilityIdentifier("pauseBatchExport")
          } else if !store.unfinished.isEmpty {
            Button("继续未完成的导出") { Task { await camera.resumeExports() } }.disabled(
              camera.busy || camera.importing
            ).accessibilityIdentifier("resumeBatchExport")
          }
          if !activeURLs.isEmpty {
            ShareLink(items: activeURLs) { Label("分享本批次已导出文件", systemImage: "square.and.arrow.up") }
          }
        }
      }
      if store.jobs.isEmpty && standaloneTransfers.isEmpty {
        ContentUnavailableView(
          "还没有导出", systemImage: "square.and.arrow.down",
          description: Text("在存储卡页面长按照片进入多选，勾选后批量导出。"))
      }
      ForEach(store.jobs.reversed()) { job in
        Section {
          HStack {
            Image(
              systemName: job.status == .complete
                ? "checkmark.circle.fill"
                : job.status == .failed ? "exclamationmark.circle" : "arrow.down.circle"
            ).foregroundStyle(job.status == .failed ? .red : Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
              Text(job.outputName).font(.subheadline).lineLimit(1)
              Text(
                "\(job.format.shortTitle) · \((!camera.exporting && (job.status == .converting || job.status == .downloading) ? ExportStatus.paused.title : job.status.title))"
              ).font(.caption).foregroundStyle(
                .secondary)
            }
            Spacer()
            if job.status == .converting && camera.exporting { ProgressView() }
          }.accessibilityIdentifier("exportJob-\(job.id)")
          if let error = job.error { Text(error).font(.footnote).foregroundStyle(.red) }
          if let url = store.outputURL(job), job.status == .complete {
            ShareLink(item: url) { Label("分享文件", systemImage: "square.and.arrow.up") }
            Button("保存到系统照片") { Task { await camera.saveToPhotos(url) } }
          }
        }
      }
      if !standaloneTransfers.isEmpty {
        Section("原文件下载记录") {
          ForEach(standaloneTransfers) { t in
            VStack(alignment: .leading, spacing: 10) {
              Text(t.name).font(.subheadline)
              ProgressView(value: t.progress)
              if t.complete {
                HStack {
                  ShareLink(item: URL(fileURLWithPath: t.path)) {
                    Label("分享", systemImage: "square.and.arrow.up")
                  }
                  Spacer()
                  Button("保存到照片") {
                    Task { await camera.saveToPhotos(URL(fileURLWithPath: t.path)) }
                  }
                }
              } else if camera.importing {
                Button("暂停导入") { camera.pauseImport() }
              } else {
                Button("继续导入") {
                  Task {
                    await camera.importFile(
                      t.selection.contentID, t.selection.file.ID, expectedKey: t.key)
                  }
                }.disabled(!camera.ready)
              }
            }.padding(.vertical, 5)
          }
        }
      }
    }.refreshable { await camera.refreshQueue() }
  }
}
