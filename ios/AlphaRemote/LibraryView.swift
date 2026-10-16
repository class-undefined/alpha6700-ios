import SwiftUI

struct LibraryView: View {
  @Environment(CameraModel.self) private var camera
  @State private var selected: CameraMedia?
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 20) {
              ForEach(filtered) { item in
                Button {
                  selected = item
                } label: {
                  VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                      RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06))
                      if let image = camera.thumbnails[item.id] {
                        Image(uiImage: image).resizable().scaledToFit()
                      } else {
                        Image(systemName: item.files.first?.video == true ? "video" : "photo").font(
                          .title
                        ).foregroundStyle(.secondary)
                      }
                    }.aspectRatio(3 / 2, contentMode: .fit).clipShape(.rect(cornerRadius: 16))
                    Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
                    HStack {
                      Text("\(item.files.count) 个文件")
                      if item.protected { Image(systemName: "lock.fill") }
                      Spacer()
                      Text(item.files.first?.sizeLabel ?? "")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                  }
                }.buttonStyle(.plain).task { await camera.thumbnail(item) }
              }
            }.padding()
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
      .sheet(item: $selected) { MediaDetail(item: $0) }
  }
}
struct MediaDetail: View {
  @Environment(CameraModel.self) private var camera
  @Environment(\.dismiss) private var dismiss
  let item: CameraMedia
  @State private var confirmDelete = false
  var body: some View {
    NavigationStack {
      List {
        Section {
          if let image = camera.thumbnails[item.id] {
            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
          }
          LabeledContent("拍摄时间", value: item.created)
          LabeledContent("评级", value: "\(item.rating) ★")
          if item.protected { Label("相机已保护此影像", systemImage: "lock") }
        }
        Section("原文件") {
          ForEach(item.files) { file in
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text(file.name).font(.subheadline)
                Spacer()
                Text(file.sizeLabel).font(.caption).foregroundStyle(.secondary)
              }
              Button {
                Task { await camera.importFile(item.id, file.id) }
              } label: {
                Label("导入 iPhone", systemImage: "arrow.down.circle")
              }.buttonStyle(.glass).disabled(!camera.ready)
            }
          }
        }
        if camera.importing {
          Section {
            ProgressView()
            Text(camera.message).font(.footnote)
            Button("暂停导入") { camera.pauseImport() }
          }
        }
        if let url = camera.importedFile {
          Section { ShareLink(item: url) { Label("分享最近导入文件", systemImage: "square.and.arrow.up") } }
        }
        Section {
          Button("从相机删除这一组影像", role: .destructive) { confirmDelete = true }.disabled(
            !camera.ready || item.protected)
        } footer: {
          Text("同一组中的 JPEG、RAW 和视频文件会一起删除。")
        }
      }.navigationTitle(item.title).navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
    }.confirmationDialog(
      "永久删除 \(item.title) 及关联文件？", isPresented: $confirmDelete, titleVisibility: .visible
    ) {
      Button("删除相机原文件", role: .destructive) {
        Task {
          await camera.perform(
            "delete",
            values: ["id": item.id, "fileID": item.files.first?.id ?? 0, "confirm": true],
            success: "相机已确认删除")
          await camera.loadMedia()
          if camera.error == nil { dismiss() }
        }
      }
    } message: {
      Text("此操作无法撤销。已导入 iPhone 的副本会保留。")
    }
  }
}
