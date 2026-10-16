import AVKit
import SwiftUI

struct PhotoBrowserSelection: Identifiable {
  let id: Int
  let items: [CameraMedia]
}
struct PhotoBrowser: View {
  @Environment(CameraModel.self) private var camera
  @Environment(\.dismiss) private var dismiss
  let items: [CameraMedia]
  @State private var index: Int
  @State private var chrome = true
  @State private var loaded = "正在载入清晰预览…"
  @State private var revision = 0
  @State private var info = false
  @State private var confirmDelete = false
  @State private var playing = false
  init(selection: PhotoBrowserSelection) {
    items = selection.items
    _index = State(initialValue: selection.items.firstIndex { $0.id == selection.id } ?? 0)
  }
  private var current: CameraMedia { items[index] }
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      PhotoPager(
        items: items, index: $index, revision: revision, camera: camera,
        onTap: { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } },
        onLoaded: { loaded = $0 }
      )
      .ignoresSafeArea(edges: [.horizontal])
      if chrome {
        VStack {
          header
          Spacer()
          footer
        }.transition(.opacity)
      }
    }.statusBarHidden(!chrome)

      .sheet(isPresented: $info) { PhotoInformation(item: current) }
      .sheet(isPresented: $playing) {
        if let url = camera.localOriginal(current) {
          VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
        }
      }
      .confirmationDialog("永久删除这一组影像？", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("删除相机原文件", role: .destructive) {
          let item = current
          Task {
            await camera.perform(
              "delete",
              values: ["id": item.id, "fileID": item.files.first?.id ?? 0, "confirm": true],
              success: "相机已确认删除")
            if camera.error == nil {
              dismiss()
              await camera.loadMedia()
            }
          }
        }
      } message: {
        Text("\(current.title) 及关联的 RAW / JPEG 文件会一起删除。iPhone 上已导入的副本保留。")
      }
  }
  private var header: some View {
    HStack(spacing: 12) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.down").frame(width: 28, height: 30)
      }
      .buttonStyle(.glass).accessibilityIdentifier("closePhotoBrowser").accessibilityLabel("返回相册")
      VStack(spacing: 3) {
        Text(current.title).font(.subheadline.weight(.semibold)).lineLimit(1)
          .accessibilityIdentifier("photoTitle")
        Text("\(index+1) / \(items.count) · \(current.created.prefix(10))").font(.caption2)
          .foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity)
      Button {
        info = true
      } label: {
        Image(systemName: "info.circle").frame(width: 28, height: 30)
      }.buttonStyle(.glass).accessibilityLabel("照片信息")
    }.padding(.horizontal, 16).padding(.vertical, 10)
      .background(.black.opacity(0.65))
  }
  private var footer: some View {
    VStack(spacing: 14) {
      Text(loaded).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
        .accessibilityIdentifier("photoQuality")
      if camera.importing {
        HStack {
          ProgressView().tint(.white)
          Text(camera.transferSpeedLabel).font(.caption.monospacedDigit())
          Spacer()
          Button("暂停") { camera.pauseImport() }.buttonStyle(.glass)
        }.padding(.horizontal)
      }
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 3) {
            ForEach(max(0, index - 6)...min(items.count - 1, index + 6), id: \.self) { i in
              Button {
                index = i
              } label: {
                ZStack {
                  Color.white.opacity(0.12)
                  if let image = camera.thumbnailImage(items[i]) {
                    Image(uiImage: image).resizable().scaledToFill()
                  } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                  }
                }.frame(width: i == index ? 52 : 36, height: 48).clipped()
                  .clipShape(.rect(cornerRadius: 5))
                  .overlay {
                    RoundedRectangle(cornerRadius: 5).stroke(
                      i == index ? Theme.accent : .clear, lineWidth: 2)
                  }
              }.buttonStyle(.plain).id(i).accessibilityLabel("查看第 \(i+1) 张")
                .task(id: camera.importing) {
                  if !camera.importing { await camera.thumbnail(items[i]) }
                }
            }
          }.padding(.horizontal, 12).padding(.vertical, 4)
        }.scrollIndicators(.hidden)
          .onChange(of: index) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
          .onAppear { proxy.scrollTo(index, anchor: .center) }
      }.frame(height: 58)
      HStack(spacing: 18) {
        Button {
          if index > 0 { index -= 1 }
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(index == 0).accessibilityLabel("上一张")
        if let url = camera.localOriginal(current) {
          ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(
            "分享原图")
          if current.previewFile?.video == true {
            Button {
              playing = true
            } label: {
              Image(systemName: "play.fill")
            }
          } else {
            Button {
              Task { await camera.saveToPhotos(url) }
            } label: {
              Image(systemName: "square.and.arrow.down")
            }.accessibilityLabel("保存到照片")
          }
        } else {
          Button {
            downloadOriginal()
          } label: {
            Label("原图", systemImage: "arrow.down.circle")
          }
          .disabled(!camera.ready).accessibilityIdentifier("loadOriginal")
        }
        Spacer(minLength: 0)
        Button {
          confirmDelete = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(!camera.ready || current.protected).accessibilityLabel("删除相机照片")
        Button {
          if index + 1 < items.count { index += 1 }
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(index + 1 == items.count).accessibilityLabel("下一张")
      }.buttonStyle(.glass).controlSize(.regular).padding(.horizontal, 18)
    }.padding(.top, 16).padding(.bottom, 12).background(.black.opacity(0.72))
  }
  private func downloadOriginal() {
    guard let file = current.previewFile else { return }
    let item = current
    Task {
      await camera.importFile(item.id, file.id)
      if camera.localOriginal(item) != nil { revision += 1 }
    }
  }
}
struct PhotoInformation: View {
  @Environment(CameraModel.self) private var camera
  @Environment(\.dismiss) private var dismiss
  let item: CameraMedia
  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("拍摄时间", value: item.created)
          LabeledContent("评级", value: "\(item.rating) ★")
          if item.protected { Label("受保护", systemImage: "lock") }
        }
        Section("原文件") {
          ForEach(item.files) { file in
            VStack(alignment: .leading, spacing: 10) {
              Text(file.name).font(.subheadline)
              HStack {
                Text(file.sizeLabel).foregroundStyle(.secondary)
                Spacer()
                Button("导出原文件") { Task { await camera.importFile(item.id, file.id) } }.buttonStyle(
                  .glass
                ).disabled(!camera.ready)
              }
            }
          }
        }
        Section {
          Text("打开照片自动加载相机提供的清晰预览。原图下载保留原始字节，显示时最高解码至 4096 像素，避免大 RAW 占满手机内存。").font(.footnote)
            .foregroundStyle(.secondary)
        }
      }.navigationTitle("照片信息").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
    }.presentationDetents([.medium, .large])
  }
}
