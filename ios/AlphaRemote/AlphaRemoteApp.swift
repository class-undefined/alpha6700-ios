import SwiftUI

@main struct AlphaRemoteApp: App {
  @State private var camera = CameraModel()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      RootView().environment(camera).preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task { await camera.initialize() }
        .onChange(of: phase) { _, p in camera.sceneChanged(p) }
    }
  }
}
enum Theme {
  static let accent = Color(red: 0.91, green: 0.66, blue: 0.39)
  static let background = Color(red: 0.035, green: 0.045, blue: 0.052)
}
struct RootView: View {
  @Environment(CameraModel.self) private var camera
  var body: some View {
    @Bindable var camera = camera
    TabView(selection: $camera.selectedTab) {
      Tab("取景", systemImage: "viewfinder", value: 0) { NavigationStack { ViewfinderView() } }
      Tab("素材", systemImage: "photo.stack", value: 1) { NavigationStack { LibraryView() } }
      Tab("参数", systemImage: "slider.horizontal.3", value: 2) {
        NavigationStack { PropertiesView() }
      }
      Tab("相机", systemImage: "camera", value: 3) { NavigationStack { CameraSettingsView() } }
    }
    .sheet(isPresented: $camera.showConnection) { ConnectionView() }
    .sheet(isPresented: $camera.showDiagnostics) {
      NavigationStack {
        ScrollView {
          Text(camera.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(
            .enabled
          ).frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle("相机响应").toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { camera.showDiagnostics = false }
          }
        }
      }
    }
    .alert(
      "操作提示",
      isPresented: Binding(get: { camera.error != nil }, set: { if !$0 { camera.error = nil } })
    ) {
      Button("好", role: .cancel) { camera.error = nil }
    } message: {
      Text(camera.error ?? "")
    }
  }
}
struct ConnectionBadge: View {
  @Environment(CameraModel.self) private var camera
  var body: some View {
    Button {
      camera.showConnection = true
    } label: {
      HStack(spacing: 7) {
        Circle().fill(camera.connected ? Color.green : Theme.accent).frame(width: 6, height: 6)
        Text(camera.status).font(.caption.weight(.medium))
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
      }.padding(.horizontal, 13).padding(.vertical, 10)
    }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule).accessibilityIdentifier(
      "connectionBadge")
  }
}
struct ConnectionView: View {
  @Environment(CameraModel.self) private var camera
  @Environment(\.dismiss) private var dismiss
  @State private var discovering = false
  @State private var candidates: [String] = []
  var body: some View {
    @Bindable var camera = camera
    NavigationStack {
      Form {
        Section {
          Label("让 iPhone 与 α6700 加入同一 Wi-Fi，开启相机的电脑遥控。", systemImage: "wifi")
          Text("在相机中打开：网络 → 网络选项 → 访问认证信息。这里使用访问认证密码。填写后将保存到此 iPhone 的钥匙串。").font(.footnote)
            .foregroundStyle(.secondary)
        }
        Section("相机地址") {
          TextField("例如 192.168.1.100", text: $camera.access.host).keyboardType(
            .numbersAndPunctuation
          ).accessibilityIdentifier("cameraHost")
          Button {
            Task {
              discovering = true
              defer { discovering = false }
              do {
                candidates = try await camera.bridge.call("discover")
                if candidates.isEmpty { camera.message = "没有找到相机，请在机身网络页面查看 IP。" }
              } catch { camera.error = error.localizedDescription }
            }
          } label: {
            HStack {
              Label("查找局域网相机", systemImage: "antenna.radiowaves.left.and.right")
              Spacer()
              if discovering { ProgressView() }
            }
          }.disabled(discovering || camera.busy)
          ForEach(candidates, id: \.self) { host in Button(host) { camera.access.host = host } }
          if !discovering && candidates.isEmpty {
            Text("也可以手动输入机身显示的 IP 地址。").font(.caption).foregroundStyle(.secondary)
          }
        }
        Section {
          TextField("用户名", text: $camera.access.user).accessibilityIdentifier("cameraUser")
          SecureField("访问认证密码", text: $camera.access.password).accessibilityIdentifier(
            "cameraPassword")
          TextField("SHA256 指纹", text: $camera.access.fingerprint, axis: .vertical).font(
            .system(.footnote, design: .monospaced)
          ).accessibilityIdentifier("cameraFingerprint")
        } header: {
          Text("访问认证")
        } footer: {
          Text("请与相机屏幕的指纹核对。支持 SHA256 Base64 和十六进制格式。")
        }
        Section {
          Button {
            Task { await camera.connect() }
          } label: {
            HStack {
              Spacer()
              if camera.connecting { ProgressView() }
              Text(camera.connecting ? "正在连接…" : "连接 α6700")
              Spacer()
            }
          }.buttonStyle(.glassProminent).disabled(camera.busy || !camera.access.complete)
            .accessibilityIdentifier("connectCamera")
          if camera.connected || camera.connecting {
            Button("断开连接", role: .destructive) {
              camera.disconnect()
              dismiss()
            }
          }
        }.listRowBackground(Color.clear)
      }.textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("连接相机").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }.presentationDetents([.large])
  }
}
