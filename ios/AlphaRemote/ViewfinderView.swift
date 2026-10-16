import SwiftUI

struct ViewfinderView: View {
  @Environment(CameraModel.self) private var camera
  @State private var grid = true
  @State private var track = false
  @State private var property: CameraProperty?
  @State private var movieConfirm = false
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 24) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
              Text("α6700").font(.system(size: 34, weight: .light, design: .rounded))
              Text("REMOTE STUDIO").font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(3).foregroundStyle(.secondary)
            }
            Spacer()
            ConnectionBadge()
          }.padding(.top, 12)
          viewfinder
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay(alignment: .topLeading) {
              HStack(spacing: 6) {
                Circle().fill(camera.live && camera.frame != nil ? .green : .gray).frame(
                  width: 5, height: 5)
                Text(camera.live && camera.frame != nil ? "LIVE" : "STANDBY").font(
                  .system(size: 10, weight: .semibold, design: .monospaced)
                ).tracking(1)
              }.padding(10).glassEffect(.regular, in: .capsule).padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
              if let level = camera.snapshot?.liveMeta.Level, level.State == 2,
                (-180...180).contains(level.X)
              {
                Text("\(level.X)°").font(.caption.monospacedDigit()).padding(8).glassEffect(
                  .regular, in: .capsule
                ).padding(12)
              }
            }
          GlassEffectContainer(spacing: 12) {
            HStack(spacing: 8) {
              quickSetting(0xD21E, label: "ISO", fallback: "—")
              quickSetting(0x5007, label: "光圈", fallback: "ƒ/—")
              quickSetting(0xD20D, label: "快门", fallback: "—")
              quickSetting(0x5010, label: "曝光", fallback: "±0")
            }
          }
          HStack(spacing: 26) {
            Button {
              Task { await camera.perform("focus", success: "已发送自动对焦") }
            } label: {
              VStack(spacing: 6) {
                Image(systemName: "scope").font(.title2)
                Text("AF").font(.caption.monospaced())
              }.frame(width: 54, height: 54)
            }.buttonStyle(.glass).disabled(!camera.ready).accessibilityLabel("自动对焦")
            Button {
              Task { await camera.perform("capture", success: "快门请求已发送；拍摄结果请查看机身或回传") }
            } label: {
              ZStack {
                Circle().strokeBorder(.white.opacity(0.8), lineWidth: 3).frame(
                  width: 82, height: 82)
                Circle().fill(.white).frame(width: 66, height: 66)
                if camera.busy { ProgressView().tint(.black) }
              }.frame(width: 88, height: 88)
            }.buttonStyle(.plain).disabled(!camera.ready).accessibilityLabel("拍照")
              .accessibilityIdentifier("shutter")
            Button {
              movieConfirm = true
            } label: {
              VStack(spacing: 7) {
                Circle().fill(Color(red: 0.95, green: 0.3, blue: 0.25)).frame(width: 20, height: 20)
                Text("录像").font(.caption2)
              }.frame(width: 54, height: 54)
            }.buttonStyle(.glass).disabled(!camera.ready).accessibilityLabel("开始或停止录像")
          }.padding(.vertical, 4)
          HStack(spacing: 16) {
            Button {
              grid.toggle()
            } label: {
              Image(systemName: "grid").foregroundStyle(grid ? Theme.accent : .white)
            }.accessibilityLabel("构图网格")
            Button {
              track.toggle()
            } label: {
              Image(systemName: track ? "person.crop.rectangle" : "viewfinder").foregroundStyle(
                track ? Theme.accent : .white)
            }.accessibilityLabel(track ? "点击追踪" : "点击移动对焦点")
            Button {
              Task { await camera.toggleOSD() }
            } label: {
              Image(systemName: "rectangle.on.rectangle")
            }.disabled(!camera.ready).accessibilityLabel("相机屏幕叠层")
            Button {
              Task { if camera.live { await camera.stopLive() } else { await camera.startLive() } }
            } label: {
              Image(systemName: camera.live ? "pause" : "play")
            }.disabled(!camera.ready).accessibilityLabel("暂停或恢复取景")
            if track {
              Button {
                Task { await camera.perform("cancelTracking") }
              } label: {
                Image(systemName: "xmark.circle")
              }.disabled(!camera.ready).accessibilityLabel("取消追踪")
            }
          }.font(.body).buttonStyle(.glass).controlSize(.regular)
          VStack(spacing: 6) {
            Text(camera.message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(
              .center)
            if camera.connected {
              Text(track ? "轻点画面追踪主体" : "轻点画面移动对焦点 · 需要区域或点对焦模式").font(.caption2).foregroundStyle(
                .tertiary)
            }
          }.frame(minHeight: 36)
        }.padding(.horizontal, 20).padding(.bottom, 24).frame(maxWidth: 700).frame(
          maxWidth: .infinity)
      }.background(Theme.background)
    }.toolbar(.hidden, for: .navigationBar)
      .sheet(item: $property) { PropertyEditor(property: $0) }
      .confirmationDialog("切换相机录像状态", isPresented: $movieConfirm, titleVisibility: .visible) {
        Button("发送开始 / 停止录像请求") {
          Task { await camera.perform("movie", success: "录像切换已发送，请以机身的 REC 状态为准") }
        }
      } message: {
        Text("该协议按键会切换录像状态。请先查看相机当前是否正在录制。")
      }
  }
  private func quickSetting(_ code: Int, label: String, fallback: String) -> some View {
    let p = camera.properties.first { $0.code == code }
    return Button {
      property = p
    } label: {
      VStack(spacing: 7) {
        Text(label).font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
        Text(p?.formatted ?? fallback).font(.system(size: 16, weight: .medium, design: .rounded))
          .lineLimit(1).minimumScaleFactor(0.6)
      }.frame(maxWidth: .infinity).padding(.vertical, 14)
    }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18)).disabled(
      p == nil || !camera.ready)
  }
  private var viewfinder: some View {
    GeometryReader { g in
      ZStack {
        RoundedRectangle(cornerRadius: 24).fill(Color(red: 0.07, green: 0.09, blue: 0.1))
        if let image = camera.frame {
          Image(uiImage: image).resizable().scaledToFit()
          if let osd = camera.osd {
            Image(uiImage: osd).resizable().scaledToFit().allowsHitTesting(false)
          }
          focusFrames(g.size)
        } else {
          VStack(spacing: 16) {
            Image(systemName: "camera.aperture").font(.system(size: 48, weight: .ultraLight))
              .foregroundStyle(Theme.accent.opacity(0.7))
            Text(camera.connected ? "等待相机画面" : "你的视角，即刻掌握。").font(.system(size: 17, weight: .light))
            if !camera.connected {
              Button("连接相机") { camera.showConnection = true }.buttonStyle(.glass).controlSize(
                .small)
            }
          }
        }
        if grid && camera.frame != nil {
          Path { p in
            for i in 1...2 {
              let x = g.size.width * CGFloat(i) / 3
              let y = g.size.height * CGFloat(i) / 3
              p.move(to: CGPoint(x: x, y: 0))
              p.addLine(to: CGPoint(x: x, y: g.size.height))
              p.move(to: CGPoint(x: 0, y: y))
              p.addLine(to: CGPoint(x: g.size.width, y: y))
            }
          }.stroke(.white.opacity(0.2), lineWidth: 0.5).allowsHitTesting(false)
        }
      }.clipShape(.rect(cornerRadius: 24)).overlay {
        RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1)
      }
      .contentShape(Rectangle())
      .onTapGesture { point in
        guard camera.ready, let image = camera.frame else { return }
        let scale = min(g.size.width / image.size.width, g.size.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        let x = (point.x - (g.size.width - w) / 2) / w
        let y = (point.y - (g.size.height - h) / 2) / h
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        Task {
          await camera.perform(
            track ? "touch" : "afPosition",
            values: ["X": min(639, Int(x * 640)), "Y": min(479, Int(y * 480))], success: "对焦位置已发送")
        }
      }
    }
  }
  private func focusFrames(_ size: CGSize) -> some View {
    let rects = (camera.snapshot?.liveMeta.Focus ?? []) + (camera.snapshot?.liveMeta.Faces ?? [])
    return ZStack {
      ForEach(Array(rects.enumerated()), id: \.offset) { _, r in
        if r.XMax > 0 && r.YMax > 0, let image = camera.frame {
          let scale = min(size.width / image.size.width, size.height / image.size.height)
          let w = image.size.width * scale
          let h = image.size.height * scale
          Rectangle().stroke(.green.opacity(0.8), lineWidth: 1).frame(
            width: r.W / r.XMax * w, height: r.H / r.YMax * h
          ).position(
            x: (size.width - w) / 2 + r.X / r.XMax * w, y: (size.height - h) / 2 + r.Y / r.YMax * h)
        }
      }
    }.allowsHitTesting(false)
  }
}
