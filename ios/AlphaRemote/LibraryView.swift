import SwiftUI

struct LibraryView: View {
  @Environment(CameraModel.self) private var camera
  @State private var browser: PhotoBrowserSelection?
  @State private var mode = 0
  @State private var query = ""
  @State private var selecting = false
  @State private var selectedIDs = Set<Int>()
  @State private var showExportSettings = false
  private var filtered: [CameraMedia] {
    camera.media.filter {
      query.isEmpty || $0.files.contains { $0.name.localizedCaseInsensitiveContains(query) }
        || $0.created.contains(query)
    }
  }
  private var selectedItems: [CameraMedia] { camera.media.filter { selectedIDs.contains($0.id) } }
  private var plan: ExportPlan { ExportPlanner.plan(selectedItems, format: camera.exports.format) }
  var body: some View {
    VStack(spacing: 0) {
      Picker("素材位置", selection: $mode) {
        Text("存储卡").tag(0)
        Text("已导出 / 队列").tag(1)
      }.pickerStyle(.segmented).padding()
      if mode == 0 {
        if !camera.media.isEmpty {
          HStack {
            Text(
              selecting
                ? "已选 \(selectedIDs.count) 组"
                : "\(camera.media.count) 组影像 · 当前显示 \(filtered.count) 组"
            )
            .accessibilityIdentifier("mediaSelectionCount")
            Spacer()
            if selecting { Text(camera.exports.format.shortTitle) }
          }.font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
        }
        if camera.media.isEmpty {
          ContentUnavailableView {
            Label("相机里的故事", systemImage: "photo.on.rectangle.angled")
          } description: {
            Text(camera.connected ? "读取存储卡，长按照片进入多选。" : "连接 α6700 后浏览存储卡。")
          } actions: {
            Button(camera.connected ? "读取存储卡" : "连接相机") {
              if camera.connected {
                Task { await camera.loadMedia() }
              } else {
                camera.showConnection = true
              }
            }.buttonStyle(.glassProminent).disabled(camera.busy || camera.exporting)
          }
        } else {
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 2)], spacing: 2) {
              ForEach(filtered) { item in
                SelectableMediaCell(
                  item: item, selecting: selecting, selected: selectedIDs.contains(item.id)
                ) {
                  if selecting {
                    toggle(item.id)
                  } else {
                    browser = PhotoBrowserSelection(id: item.id, items: filtered)
                  }
                } onLongPress: {
                  selecting = true
                  selectedIDs.insert(item.id)
                }
              }
            }.padding(.horizontal, 2)
          }.refreshable {
            selectedIDs = []
            selecting = false
            await camera.loadMedia()
          }
        }
      } else {
        ExportQueueView()
      }
    }.navigationTitle("素材")
      .searchable(text: $query, prompt: "搜索文件名或拍摄日期")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if selecting && mode == 0 {
            Button(selectedIDs.isSuperset(of: Set(filtered.map(\.id))) ? "取消全选" : "全选") {
              let ids = Set(filtered.map(\.id))
              if selectedIDs.isSuperset(of: ids) {
                selectedIDs.subtract(ids)
              } else {
                selectedIDs.formUnion(ids)
              }
            }.disabled(filtered.isEmpty).accessibilityIdentifier("selectAllMedia")
          }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          if mode == 0 && !camera.media.isEmpty {
            Button(selecting ? "取消" : "选择") {
              selecting.toggle()
              if !selecting { selectedIDs = [] }
            }
            .accessibilityIdentifier("selectMedia")
          }
          if camera.busy {
            ProgressView()
          } else {
            Button {
              Task {
                if mode == 0 {
                  selectedIDs = []
                  selecting = false
                  await camera.loadMedia()
                } else {
                  await camera.refreshQueue()
                }
              }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .disabled(camera.exporting || (mode == 0 && !camera.connected)).accessibilityLabel(
              "刷新素材")
          }
        }
      }
      .safeAreaInset(edge: .bottom) { if selecting && mode == 0 { selectionTray } }
      .onChange(of: mode) { _, value in
        if value != 0 {
          selecting = false
          selectedIDs = []
        }
      }
      .fullScreenCover(item: $browser) { PhotoBrowser(selection: $0) }
      .sheet(isPresented: $showExportSettings) {
        NavigationStack {
          ExportSettingsView().toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("完成") { showExportSettings = false }
            }
          }
        }
      }
  }
  private func toggle(_ id: Int) {
    if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
  }
  private var selectionTray: some View {
    let summary = plan
    return VStack(spacing: 10) {
      HStack {
        Button {
          showExportSettings = true
        } label: {
          Label(camera.exports.format.title, systemImage: "slider.horizontal.3")
        }.font(.caption).accessibilityIdentifier("selectionExportSettings")
        Spacer()
        Text(
          "\(summary.jobs.count) 个文件 · \(ByteCountFormatter.string(fromByteCount:summary.sourceBytes,countStyle:.file)) 源数据"
        ).font(.caption2).foregroundStyle(.secondary)
      }
      if !summary.skipped.isEmpty {
        Text("\(summary.skipped.count) 组没有目标格式，将跳过").font(.caption2).foregroundStyle(.orange).frame(
          maxWidth: .infinity, alignment: .leading
        ).accessibilityIdentifier("exportSkippedSummary")
      }
      if summary.conversionCount > 0 {
        Text("\(summary.conversionCount) 张将在 iPhone 转为全尺寸 JPEG").font(.caption2).foregroundStyle(
          .secondary
        ).frame(maxWidth: .infinity, alignment: .leading)
      }
      Button {
        let items = selectedItems
        selectedIDs = []
        selecting = false
        mode = 1
        Task { await camera.exportSelected(items) }
      } label: {
        Text("导出 \(summary.jobs.count) 个文件").frame(maxWidth: .infinity).padding(.vertical, 7)
      }
      .buttonStyle(.glassProminent).disabled(
        summary.jobs.isEmpty || camera.busy || camera.importing || camera.exporting
      )
      .accessibilityIdentifier("exportSelectedMedia")
    }.padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial)
  }
}
private struct SelectableMediaCell: View {
  @Environment(CameraModel.self) private var camera
  let item: CameraMedia
  let selecting: Bool
  let selected: Bool
  let onTap: () -> Void
  let onLongPress: () -> Void
  var body: some View {
    Button(action: onTap) {
      ZStack(alignment: .bottomTrailing) {
        Color.white.opacity(0.07)
        if let image = camera.thumbnailImage(item) {
          GeometryReader { g in
            Image(uiImage: image).resizable().scaledToFill().frame(
              width: g.size.width, height: g.size.height
            ).clipped().accessibilityHidden(true)
          }
        } else {
          Image(systemName: item.previewFile?.video == true ? "video" : "photo").foregroundStyle(
            .secondary
          ).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if selecting {
          if selected { Color.blue.opacity(0.15) }
          Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(
            .system(size: 23, weight: .medium)
          )
          .symbolRenderingMode(.palette).foregroundStyle(
            .white, selected ? .blue : .black.opacity(0.4)
          ).shadow(radius: 2).padding(7)
        } else {
          if item.previewFile?.video == true {
            Image(systemName: "video.fill").font(.caption2).padding(6).shadow(radius: 2)
          }
          if item.protected {
            Image(systemName: "lock.fill").font(.caption2).padding(6).shadow(radius: 2)
          }
        }
      }.aspectRatio(1, contentMode: .fit).clipped().contentShape(Rectangle())
        .overlay { if selected { Rectangle().strokeBorder(.blue, lineWidth: 2) } }
    }.buttonStyle(.plain)
      .highPriorityGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in onLongPress() })
      .accessibilityElement(children: .ignore).accessibilityLabel(item.title)
      .accessibilityValue(selecting ? (selected ? "已选择" : "未选择") : "")
      .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { onTap() }
      .accessibilityHint(selecting ? "轻点切换选择" : "轻点查看，长按进入多选")
      .accessibilityIdentifier("media-\(item.id)")
      .task(id: camera.importing || camera.exporting) {
        if !camera.importing && !camera.exporting { await camera.thumbnail(item) }
      }
  }
}
