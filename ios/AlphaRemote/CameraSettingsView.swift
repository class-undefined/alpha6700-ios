import SwiftUI
import UniformTypeIdentifiers

struct CameraSettingsView: View {
  @Environment(CameraModel.self) private var camera
  @State private var importingFile = false
  @State private var uploadKind = "restore"
  @State private var pendingURL: URL?
  @State private var confirmUpload = false
  @State private var lutSlot = 1
  @State private var forget = false
  var body: some View {
    List {
      Section {
        HStack(spacing: 18) {
          Image(systemName: "camera.aperture").font(.system(size: 42, weight: .ultraLight))
            .foregroundStyle(Theme.accent)
          VStack(alignment: .leading, spacing: 5) {
            Text("Sony α6700").font(.title2.weight(.light))
            Text(camera.status).font(.footnote).foregroundStyle(.secondary)
          }
          Spacer()
        }.padding(.vertical, 12)
        Button {
          camera.showConnection = true
        } label: {
          Label(camera.connected ? "连接信息" : "连接相机", systemImage: "wifi")
        }
        if let snapshot = camera.snapshot {
          LabeledContent("固件", value: snapshot.firmware)
          LabeledContent(
            "参数 / 控制项", value: "\(snapshot.properties.count) / \(snapshot.controls.count)")
        }
      }
      Section("拍摄与控制") {
        NavigationLink {
          RemoteControlsView()
        } label: {
          Label("机身按键与拨轮", systemImage: "dial.low")
        }
        Button {
          Task { await camera.fetchCapture() }
        } label: {
          Label("接收新拍摄照片", systemImage: "camera.badge.ellipsis")
        }.disabled(!camera.ready)
        Text("回传需要将相机的照片保存位置设为主机或主机 + 存储卡。原文件和缩小尺寸可在参数页调整。").font(.caption).foregroundStyle(
          .secondary)
      }
      Section("相机设置") {
        Button {
          Task { await camera.backup() }
        } label: {
          Label("备份相机设置", systemImage: "externaldrive.badge.plus")
        }.disabled(!camera.ready)
        Button {
          uploadKind = "restore"
          importingFile = true
        } label: {
          Label("从备份恢复设置", systemImage: "arrow.counterclockwise")
        }.disabled(!camera.ready)
        Button {
          Task { await camera.syncClock() }
        } label: {
          Label("同步 iPhone 时间", systemImage: "clock.arrow.circlepath")
        }.disabled(!camera.ready)
      }
      Section("LUT") {
        Picker("用户槽位", selection: $lutSlot) {
          ForEach(1...16, id: \.self) { Text("User \($0)").tag($0) }
        }
        Button {
          uploadKind = "lut"
          importingFile = true
        } label: {
          Label("导入 .cube 文件", systemImage: "square.3.layers.3d")
        }.disabled(!camera.ready)
        Text("将机身模式拨盘切换到视频。上传会覆盖所选槽位，请查看相机返回的完成事件。").font(.caption).foregroundStyle(.secondary)
      }
      if let url = camera.importedFile {
        Section("最近生成的文件") {
          ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
        }
      }
      Section("能力与状态") {
        NavigationLink("协议能力与验证范围") { CapabilityView() }
        ForEach(
          [
            ("clock", "相机时间"), ("strings", "机身显示文本"), ("ftpNames", "FTP 配置名称"),
            ("operationResults", "操作结果能力"), ("description", "设备描述"),
          ], id: \.0
        ) { op, label in
          Button(label) { Task { await camera.diagnose(op) } }.disabled(!camera.ready)
        }
        if let events = camera.snapshot?.events, !events.isEmpty {
          NavigationLink("近期相机事件（\(events.count)）") {
            List(Array(events.reversed().enumerated()), id: \.offset) { _, ev in
              Text(ev.summary).font(.system(.footnote, design: .monospaced))
            }.navigationTitle("相机事件")
          }
        }
      }
      Section("本机") {
        LabeledContent(
          "版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
        LabeledContent("运行方式", value: "iPhone 直接连接相机")
        NavigationLink("安装与 7 天续签") { InstallHelpView() }
        NavigationLink("开源许可") { LicenseView() }
        Button("清除此 iPhone 的认证信息", role: .destructive) { forget = true }
      }
    }.navigationTitle("相机")
      .fileImporter(
        isPresented: $importingFile, allowedContentTypes: [.data], allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          pendingURL = urls.first
          confirmUpload = pendingURL != nil
        case .failure(let error): camera.error = error.localizedDescription
        }
      }
      .confirmationDialog(
        uploadKind == "lut" ? "覆盖 User \(lutSlot) 的 LUT？" : "用文件替换当前相机设置？",
        isPresented: $confirmUpload, titleVisibility: .visible
      ) {
        Button("确认上传", role: .destructive) {
          if let url = pendingURL {
            Task { await camera.upload(url, op: uploadKind, slot: lutSlot) }
          }
        }
      } message: {
        Text(pendingURL?.lastPathComponent ?? "")
      }
      .confirmationDialog("清除已保存的相机认证信息？", isPresented: $forget, titleVisibility: .visible) {
        Button("清除", role: .destructive) {
          camera.disconnect()
          do {
            try KeychainStore.erase()
            camera.access = CameraAccess()
          } catch { camera.error = error.localizedDescription }
        }
      }
  }
}
struct RemoteControlsView: View {
  @Environment(CameraModel.self) private var camera
  let labels = [
    1: "上", 2: "下", 3: "左", 4: "右", 5: "确认", 6: "菜单", 16: "Fn", 17: "回放", 20: "C1", 21: "C2",
    22: "C3", 26: "录像按键", 28: "AF-ON",
  ]
  private func ids(_ code: Int) -> [Int] {
    camera.properties.first { $0.code == code }?.choices.compactMap { Int($0.value) } ?? []
  }
  var body: some View {
    List {
      Section("机身当前开放的按键") {
        if ids(0xD208).isEmpty { Text("连接相机并保持机身空闲后读取可用按键。").foregroundStyle(.secondary) }
        ForEach(ids(0xD208), id: \.self) { id in
          Button(labels[id] ?? String(format: "按键 0x%04X", id)) {
            Task { await camera.perform("button", values: ["code": id]) }
          }.disabled(!camera.ready)
        }
      }
      Section("拨轮") {
        ForEach(ids(0xD20A), id: \.self) { id in
          HStack {
            Text([0x4001: "控制轮", 0x4002: "前拨轮", 0x4003: "后拨轮"][id] ?? String(format: "0x%04X", id))
            Spacer()
            Button {
              Task { await camera.perform("dial", values: ["code": id, "steps": -1]) }
            } label: {
              Image(systemName: "minus")
            }
            Button {
              Task { await camera.perform("dial", values: ["code": id, "steps": 1]) }
            } label: {
              Image(systemName: "plus")
            }
          }.buttonStyle(.glass).disabled(!camera.ready)
        }
      }
      Section { Text("每次操作前重新检查可用按键。机身菜单状态可能影响拨轮含义。").font(.footnote).foregroundStyle(.secondary) }
    }.navigationTitle("机身控制")
  }
}
struct CapabilityView: View {
  @Environment(CameraModel.self) private var camera
  var body: some View {
    List {
      Section("已实现的接口") {
        Text(
          "SSH 认证与指纹校验、PTP/IP 会话、取景与对焦框、快门、自动对焦、录像切换、触控追踪、按键与拨轮、动态属性读写、媒体分页、缩略图、原文件导入与续传、拍摄回传、OSD、备份与恢复、时间同步和 LUT 上传。"
        ).font(.subheadline)
      }
      Section("验证范围") {
        Text(
          "核心协议已有本项目 Mac 实机验证。手机端结果与未验证项记录在公开仓库 docs/PROGRESS.md。录像、删除、恢复设置及 LUT 上传需逐项验收；按钮请求被相机接受不等于动作已经完成。"
        ).font(.footnote)
      }
      Section("当前边界") {
        Text(
          "相机菜单不全部开放远程调用。此版本使用局域网连接；蓝牙唤醒与自动切换热点尚未实现。镜头信息、视频回放、FTP 设置列表等接口被 α6700 固件 2.00 拒绝。大于 4 GiB 的偏移逻辑有测试，实机大视频仍待验收。"
        ).font(.footnote)
      }
      if let s = camera.snapshot {
        Section("机身声明的控制项（\(s.controls.count)）") {
          Text(s.controls.map { String(format: "0x%04X", $0) }.joined(separator: "  ")).font(
            .system(.caption, design: .monospaced)
          ).textSelection(.enabled)
        }
        Section("机身声明的操作（\(s.operations.count)）") {
          Text(s.operations.map { String(format: "0x%04X", $0) }.joined(separator: "  ")).font(
            .system(.caption, design: .monospaced)
          ).textSelection(.enabled)
        }
      }
    }.navigationTitle("能力与边界")
  }
}
struct InstallHelpView: View {
  var body: some View {
    List {
      Section("7 天开发签名") {
        Text(
          "使用免费 Apple Account 的 Personal Team 安装。描述文件自签发起 7 天有效。到期后，用同一 Apple Account 和 Bundle ID 重新构建并覆盖安装，保留本机设置与导入文件。"
        )
        Text(
          "在 Mac 项目目录执行 scripts/install-device.sh。首次构建先在 Xcode 的 Signing & Capabilities 选择 Personal Team。"
        )
      }
      Section("后台行为") { Text("进入后台时保存导入分段进度并断开网络。返回前台后尝试重连；正在导入的文件核对身份后继续。快门、录像切换和相机设置修改不会自动重放。") }
    }.font(.subheadline).navigationTitle("安装与续签")
  }
}
struct LicenseView: View {
  var body: some View {
    ScrollView {
      Text(
        (try? String(
          contentsOf: Bundle.main.url(forResource: "ThirdParty", withExtension: "txt")!,
          encoding: .utf8)) ?? "许可文件不可用"
      ).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
    }.navigationTitle("开源许可")
  }
}
