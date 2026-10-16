import SwiftUI

struct LibraryView: View {
  @Environment(CameraModel.self) private var camera
  @State private var selected: PhotoBrowserSelection?
  @State private var mode = 0
  @State private var query = ""
  private var filtered: [CameraMedia] {
    camera.media.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        || $0.created.contains(query)
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      Picker("素材位置", selection: $mode) {
        Text("存储卡").tag(0)
        Text("已导入 / 队列").tag(1)
      }.pickerStyle(.segmented).padding()
      if mode == 0 {
        if !camera.media.isEmpty {
          Text("\(camera.media.count) 组影像 · 当前显示 \(filtered.count) 组").font(.caption)
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(
              .horizontal
            ).padding(.bottom, 8)
        }
        if camera.media.isEmpty {
          ContentUnavailableView {
            Label("相机里的故事", systemImage: "photo.on.rectangle.angled")
          } description: {
            Text(camera.connected ? "读取存储卡，选择照片、RAW 或视频原文件。" : "连接 α6700 后浏览存储卡。")
          } actions: {
            Button(camera.connected ? "读取存储卡" : "连接相机") {
              if camera.connected {
                Task { await camera.loadMedia() }
              } else {
                camera.showConnection = true
              }
            }.buttonStyle(.glassProminent).disabled(camera.busy)
          }
        } else {
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 2)], spacing: 2) {
              ForEach(filtered) { item in
                Button {
                  selected = PhotoBrowserSelection(id: item.id, items: filtered)
                } label: {
                  ZStack(alignment: .bottomTrailing) {
                    Color.white.opacity(0.07)
                    if let image = camera.thumbnailImage(item) {
                      GeometryReader { g in
                        Image(uiImage: image).resizable().scaledToFill().frame(
                          width: g.size.width, height: g.size.height
                        ).clipped()
                      }
                    } else {
                      Image(systemName: item.previewFile?.video == true ? "video" : "photo")
                        .foregroundStyle(.secondary).frame(
                          maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if item.previewFile?.video == true {
                      Image(systemName: "video.fill").font(.caption2).padding(6).shadow(radius: 2)
                    }
                    if item.protected {
                      Image(systemName: "lock.fill").font(.caption2).padding(6).shadow(radius: 2)
                    }
                  }.aspectRatio(1, contentMode: .fit).clipped().accessibilityLabel(item.title)
                    .accessibilityIdentifier("media-\(item.id)")
                }.buttonStyle(.plain).accessibilityIdentifier("media-\(item.id)").task {
                  await camera.thumbnail(item)
                }
              }
            }.padding(.horizontal, 2)
          }.refreshable { await camera.loadMedia() }
        }
      } else {
        List {
          if camera.transfers.isEmpty {
            ContentUnavailableView(
              "还没有导入", systemImage: "square.and.arrow.down",
              description: Text("导入进度按分段保存。你可以暂停，随后继续。"))
          }
          ForEach(camera.transfers) { t in
            Section {
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                  Image(systemName: t.complete ? "checkmark.circle" : "arrow.down.circle")
                    .foregroundStyle(Theme.accent)
                  Text(t.name).font(.subheadline)
                  Spacer()
                }
                if camera.importing && camera.importContentID == t.selection.contentID {
                  Text(camera.transferSpeedLabel).font(.caption.monospacedDigit()).foregroundStyle(
                    Theme.accent)
                }
                ProgressView(value: t.progress).tint(Theme.accent)
                Text(t.complete ? "已导入 · SHA256 已计算" : "\(Int(t.progress*100))% · 可继续导入").font(
                  .caption
                ).foregroundStyle(.secondary)
              }
              if t.complete {
                ShareLink(item: URL(fileURLWithPath: t.path)) {
                  Label("分享原文件", systemImage: "square.and.arrow.up")
                }
                Button {
                  Task { await camera.saveToPhotos(URL(fileURLWithPath: t.path)) }
                } label: {
                  Label("保存到系统照片", systemImage: "photo.badge.plus")
                }
              } else {
                if camera.importing {
                  Button("暂停导入") { camera.pauseImport() }
                } else {
                  Button("继续导入") {
                    Task {
                      await camera.importFile(
                        t.selection.contentID, t.selection.file.ID, expectedKey: t.key)
                    }
                  }.disabled(!camera.ready)
                }
              }
            }
          }
          if let url = camera.importedFile {
            Section("最近文件") {
              ShareLink(item: url) {
                Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
              }
              Button("保存到系统照片") { Task { await camera.saveToPhotos(url) } }
            }
          }
        }.refreshable { await camera.refreshQueue() }
      }
    }.navigationTitle("素材")
      .searchable(text: $query, prompt: "搜索文件名或拍摄日期")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if camera.busy {
            ProgressView()
          } else {
            Button {
              Task {
                if mode == 0 { await camera.loadMedia() } else { await camera.refreshQueue() }
              }
            } label: {
              Image(systemName: "arrow.clockwise")
            }.disabled(mode == 0 && !camera.connected).accessibilityLabel("刷新素材")
          }
        }
      }
      .fullScreenCover(item: $selected) { PhotoBrowser(selection: $0) }
  }
}
