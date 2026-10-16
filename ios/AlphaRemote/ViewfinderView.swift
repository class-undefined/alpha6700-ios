import SwiftUI

// Camera-LCD chrome: flat black, small white numerals, thin rules. The 44 pt
// hit areas are deliberately larger than the visible glyphs.
struct CameraLCDButtonStyle: ButtonStyle {
  var selected = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(selected ? Theme.accent : Color.white)
      .background(configuration.isPressed ? Color.white.opacity(0.16) : Color.clear)
      .contentShape(Rectangle())
  }
}
@MainActor private enum CameraOrientation {
  static var scene: UIWindowScene? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
      $0.activationState == .foregroundActive
    }
  }
  static func request(_ mask: UIInterfaceOrientationMask) {
    guard let scene else { return }
    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) {
      _ in /* Manual rotation remains available. */
    }
  }
  static var current: UIInterfaceOrientationMask {
    switch scene?.effectiveGeometry.interfaceOrientation {
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    case .portraitUpsideDown: return .portraitUpsideDown
    default: return .portrait
    }
  }
}
struct ViewfinderView: View {
  @Environment(CameraModel.self) private var camera
  @State private var grid = true
  @State private var track = false
  @State private var information = true
  @State private var functions = false
  @State private var fullscreen = false
  @State private var previousOrientation: UIInterfaceOrientationMask = .portrait
  @State private var property: CameraProperty?
  @State private var movieConfirm = false
  var body: some View {
    GeometryReader { geometry in
      let landscape = geometry.size.width > geometry.size.height
      VStack(spacing: 0) {
        if !fullscreen { header }
        if landscape {
          HStack(spacing: 0) {
            stage
            VStack(spacing: 4) {
              if fullscreen { fullscreenButton }
              Spacer(minLength: 0)
              focusButton
              shutter
              recordButton
              lcdButton("FN", id: "cameraFunctions", selected: functions) { functions.toggle() }
              lcdButton("DISP", id: "displayInfo", selected: information) { information.toggle() }
              Spacer(minLength: 0)
            }.frame(width: 64).padding(.vertical, 4).background(Color(white: 0.055))
          }
          if functions { functionRow }
        } else {
          stage
          if functions { functionRow }
          HStack(spacing: 0) {
            Button {
              camera.selectedTab = 1
            } label: {
              Image(systemName: "play.rectangle").font(.system(size: 18)).frame(
                width: 48, height: 52)
            }.accessibilityLabel("打开相册")
            Spacer(minLength: 0)
            focusButton
            Spacer(minLength: 0)
            shutter
            Spacer(minLength: 0)
            recordButton
            Spacer(minLength: 0)
            lcdButton("FN", id: "cameraFunctions", selected: functions) { functions.toggle() }
            if fullscreen { fullscreenButton }
          }.padding(.horizontal, 10).frame(height: 70).background(Color(white: 0.055))
        }
        if !fullscreen {
          Text(camera.message).font(.system(size: 10, design: .monospaced)).foregroundStyle(
            .secondary
          )
          .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
          .frame(height: 22)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        .buttonStyle(CameraLCDButtonStyle())
    }.background { Color.black.ignoresSafeArea() }
      .toolbar(.hidden, for: .navigationBar)
      .toolbar(fullscreen ? .hidden : .visible, for: .tabBar)
      .statusBarHidden(fullscreen)
      .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
      .sheet(item: $property) { p in
        if p.usesRuler {
          TactileParameterSheet(property: p, cameraStyle: true)
        } else {
          PropertyEditor(property: p)
        }
      }
      .confirmationDialog("切换相机录像状态", isPresented: $movieConfirm, titleVisibility: .visible) {
        Button("发送开始 / 停止录像请求") {
          Task { await camera.perform("movie", success: "录像切换已发送，请以机身 REC 状态为准") }
        }
      } message: {
        Text("此按键切换录像状态，请先查看相机是否正在录制。")
      }
      .onDisappear {
        if fullscreen {
          fullscreen = false
          CameraOrientation.request(previousOrientation)
        }
      }
  }
  private var header: some View {
    HStack(spacing: 8) {
      Text("α6700").font(.system(size: 16, weight: .semibold, design: .rounded))
      Spacer(minLength: 0)
      Button {
        camera.showConnection = true
      } label: {
        HStack(spacing: 5) {
          Circle().fill(camera.connected ? .green : Color.gray).frame(width: 5, height: 5)
          Text(camera.status).font(.system(size: 11, design: .monospaced))
        }.frame(height: 40)
      }.accessibilityIdentifier("connectionBadge")
      fullscreenButton
    }.padding(.leading, 10).frame(height: 40)
  }
  private var fullscreenButton: some View {
    Button {
      if fullscreen {
        fullscreen = false
        CameraOrientation.request(previousOrientation)
      } else {
        previousOrientation = CameraOrientation.current
        fullscreen = true
        DispatchQueue.main.async { CameraOrientation.request(.landscapeRight) }
      }
    } label: {
      Image(
        systemName: fullscreen
          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
      ).font(.system(size: 16)).frame(width: 44, height: 40)
    }
    .accessibilityLabel(fullscreen ? "退出全屏" : "全屏取景")
    .accessibilityIdentifier(fullscreen ? "exitFullScreen" : "enterFullScreen")
  }
  private var focusButton: some View {
    Button {
      Task { await camera.perform("focus", success: "自动对焦请求已发送") }
    } label: {
      VStack(spacing: 2) {
        Image(systemName: "scope").font(.system(size: 19))
        Text("AF").font(.system(size: 10, weight: .semibold, design: .monospaced))
      }.frame(width: 48, height: 48)
    }.disabled(!camera.ready).accessibilityLabel("自动对焦")
  }
  private var shutter: some View {
    Button {
      Task { await camera.perform("capture", success: "快门请求已发送") }
    } label: {
      ZStack {
        Circle().strokeBorder(.white, lineWidth: 2).frame(width: 54, height: 54)
        Circle().fill(.white).frame(width: 42, height: 42)
        if camera.busy { ProgressView().tint(.black) }
      }.frame(width: 62, height: 62)
    }.disabled(!camera.ready).opacity(camera.ready ? 1 : 0.35).accessibilityLabel("拍照")
      .accessibilityIdentifier("shutter")
  }
  private var recordButton: some View {
    Button {
      movieConfirm = true
    } label: {
      VStack(spacing: 5) {
        Circle().fill(.red).frame(width: 13, height: 13)
        Text("REC").font(.system(size: 10, weight: .semibold, design: .monospaced))
      }.frame(width: 48, height: 48)
    }.disabled(!camera.ready).accessibilityLabel("开始或停止录像")
  }
  private func lcdButton(
    _ label: String, id: String, selected: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(
        minWidth: 44, minHeight: 40)
    }
    .buttonStyle(CameraLCDButtonStyle(selected: selected)).accessibilityIdentifier(id)
  }
  private var functionRow: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        setting(0x500A, fallback: "AF", id: "focusMode")
        setting(0x5005, fallback: "WB", id: "whiteBalance")
        setting(0xD20F, fallback: "K", id: "colorTemperature")
        lcdButton("GRID", id: "viewfinderGrid", selected: grid) { grid.toggle() }
        lcdButton("TRACK", id: "trackingMode", selected: track) { track.toggle() }
        lcdButton("DISP", id: "displayInfo", selected: information) { information.toggle() }
        Button {
          Task { await camera.toggleOSD() }
        } label: {
          Text("OSD").font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(
            width: 44, height: 40)
        }.disabled(!camera.ready).accessibilityLabel("相机屏幕叠层")
        Button {
          Task {
            camera.preferLive = !camera.live
            if camera.live { await camera.stopLive() } else { await camera.startLive() }
          }
        } label: {
          Image(systemName: camera.live ? "pause" : "play").font(.system(size: 13)).frame(
            width: 44, height: 40)
        }.disabled(!camera.ready).accessibilityLabel("暂停或恢复取景")
        if track {
          Button("取消追踪") { Task { await camera.perform("cancelTracking") } }.font(.caption)
            .disabled(!camera.ready)
        }
      }.padding(.horizontal, 8)
    }.scrollIndicators(.hidden).frame(height: 42).background(Color(white: 0.08))
  }
  private func setting(_ code: Int, fallback: String, id: String? = nil) -> some View {
    let p = camera.properties.first { $0.code == code }
    return Button {
      property = p
    } label: {
      Text(p?.formatted ?? fallback).font(.system(size: 13, weight: .medium, design: .monospaced))
        .lineLimit(1).minimumScaleFactor(0.65)
        .frame(minWidth: 44, minHeight: 40).padding(.horizontal, 6)
    }.disabled(p == nil || !camera.connected || camera.importing || camera.exporting)
      .accessibilityIdentifier(id ?? "quick-\(code)")
  }
  private var stage: some View {
    GeometryReader { g in
      let rect = ViewfinderGeometry.fit(
        image: camera.frame?.size ?? CGSize(width: 16, height: 9),
        in: CGRect(origin: .zero, size: g.size))
      ZStack {
        Color.black
        if let image = camera.frame {
          Image(uiImage: image).resizable().frame(width: rect.width, height: rect.height).position(
            x: rect.midX, y: rect.midY
          )
          .accessibilityIdentifier("liveImage")
          if let osd = camera.osd {
            Image(uiImage: osd).resizable().scaledToFit().frame(
              width: rect.width, height: rect.height
            ).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
          }
          if grid { gridLines(in: rect) }
          focusFrames(in: rect)
          Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle())
            .onTapGesture { point in
              guard camera.ready,
                let p = ViewfinderGeometry.cameraPoint(
                  point, imageRect: CGRect(origin: .zero, size: rect.size))
              else { return }
              Task {
                await camera.perform(
                  track ? "touch" : "afPosition", values: ["X": p.x, "Y": p.y], success: "对焦位置已发送")
              }
            }.position(x: rect.midX, y: rect.midY).accessibilityHidden(true)
        } else {
          VStack(spacing: 12) {
            Image(systemName: "viewfinder").font(.system(size: 28, weight: .light)).foregroundStyle(
              .secondary)
            Text(
              camera.importing || camera.exporting
                ? "导出中 · 取景暂停" : camera.connected ? "等待相机画面" : "未连接 α6700"
            ).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            if !camera.connected {
              Button("连接相机") { camera.showConnection = true }.font(
                .system(size: 12, weight: .semibold)
              ).padding(.horizontal, 16).frame(height: 40).overlay {
                Rectangle().stroke(.white.opacity(0.5), lineWidth: 0.5)
              }
            }
          }
        }
        if information {
          VStack(spacing: 0) {
            HStack(spacing: 10) {
              Text(camera.live && camera.frame != nil ? "● LIVE" : "STBY").foregroundStyle(
                camera.live ? Color.green : .secondary)
              if let mode = camera.properties.first(where: { $0.code == 0x500E }) {
                Text(mode.formatted).fontWeight(.bold)
              }
              if let af = camera.properties.first(where: { $0.code == 0x500A }) {
                Text(af.formatted)
              }
              Spacer(minLength: 0)
              if let battery = camera.properties.first(where: {
                $0.code == 0xD218 || $0.code == 0x5001
              }), let n = Int(battery.value), (0...100).contains(n) {
                Label("\(n)%", systemImage: n > 20 ? "battery.75percent" : "battery.25percent")
              }
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).padding(.horizontal, 8)
              .frame(height: 28).background(.black.opacity(0.65))
            Spacer(minLength: 0)
            if camera.connected {
              HStack(spacing: 0) {
                setting(0xD20D, fallback: "1/—").frame(maxWidth: .infinity)
                setting(0x5007, fallback: "F—").frame(maxWidth: .infinity)
                setting(0x5010, fallback: "±0.0").frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                  Text("ISO").font(.system(size: 8, design: .monospaced))
                  setting(0xD21E, fallback: "—")
                }.frame(maxWidth: .infinity)
              }.frame(height: 46).background(.black.opacity(0.7))
            }
          }
        }
        if information, let level = camera.snapshot?.liveMeta.Level, level.State == 2,
          (-180...180).contains(level.X)
        {
          Text("\(level.X)°").font(.system(size: 10, design: .monospaced)).padding(4).background(
            .black.opacity(0.6)
          ).position(x: g.size.width - 20, y: g.size.height / 2)
        }
      }
    }
  }
  private func gridLines(in rect: CGRect) -> some View {
    Path { p in
      for i in 1...2 {
        let x = rect.minX + rect.width * CGFloat(i) / 3
        let y = rect.minY + rect.height * CGFloat(i) / 3
        p.move(to: CGPoint(x: x, y: rect.minY))
        p.addLine(to: CGPoint(x: x, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX, y: y))
        p.addLine(to: CGPoint(x: rect.maxX, y: y))
      }
    }.stroke(.white.opacity(0.28), lineWidth: 0.5).allowsHitTesting(false)
  }
  private func focusFrames(in rect: CGRect) -> some View {
    let frames = (camera.snapshot?.liveMeta.Focus ?? []) + (camera.snapshot?.liveMeta.Faces ?? [])
    return ZStack {
      ForEach(Array(frames.enumerated()), id: \.offset) { _, r in
        if r.XMax > 0, r.YMax > 0 {
          Rectangle().stroke(.green.opacity(0.8), lineWidth: 1).frame(
            width: r.W / r.XMax * rect.width, height: r.H / r.YMax * rect.height
          ).position(
            x: rect.minX + r.X / r.XMax * rect.width, y: rect.minY + r.Y / r.YMax * rect.height)
        }
      }
    }.allowsHitTesting(false)
  }
}
