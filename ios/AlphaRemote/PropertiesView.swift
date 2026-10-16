import SwiftUI

struct PropertiesView: View {
  @Environment(CameraModel.self) private var camera
  @State private var query = ""
  @State private var writableOnly = false
  @State private var selected: CameraProperty?
  private var filtered: [CameraProperty] {
    camera.properties.filter {
      (!writableOnly || $0.writable)
        && (query.isEmpty
          || "\($0.title) \($0.name) \($0.groupTitle) \(String(format:"%04X",$0.code))"
            .localizedCaseInsensitiveContains(query))
    }
  }
  var body: some View {
    List {
      if !camera.connected {
        ContentUnavailableView(
          "相机参数", systemImage: "slider.horizontal.3",
          description: Text("连接后显示机身开放的全部参数，包含当前值和可选范围。"))
        Button("连接相机") { camera.showConnection = true }
      } else {
        Section {
          Toggle("仅显示当前可调参数", isOn: $writableOnly)
          LabeledContent("机身返回", value: "\(camera.properties.count) 项")
        }
        ForEach(Array(Set(filtered.map(\.group))).sorted(), id: \.self) { group in
          Section(CameraProperty.groups[group] ?? group) {
            ForEach(filtered.filter { $0.group == group }) { p in
              Button {
                selected = p
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(p.title).foregroundStyle(.primary)
                    Text(String(format: "0x%04X", p.code)).font(
                      .system(.caption2, design: .monospaced)
                    ).foregroundStyle(.tertiary)
                  }
                  Spacer()
                  Text(p.code == 0xD278 ? "取景地址已隐藏" : p.formatted).font(
                    .subheadline.monospacedDigit()
                  ).foregroundStyle(p.writable ? Theme.accent : Color.secondary).lineLimit(1).frame(
                    maxWidth: 140, alignment: .trailing)
                  if !p.writable {
                    Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary)
                  }
                }
              }
            }
          }
        }
      }
    }.navigationTitle("参数").searchable(text: $query, prompt: "搜索名称或代码").refreshable {
      await camera.refreshStatus()
    }
    .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionBadge() } }
    .sheet(item: $selected) { PropertyEditor(property: $0) }
  }
}
struct PropertyEditor: View {
  @Environment(CameraModel.self) private var camera
  @Environment(\.dismiss) private var dismiss
  let property: CameraProperty
  @State private var value = ""
  @State private var confirm = false
  private var current: CameraProperty {
    camera.properties.first { $0.id == property.id } ?? property
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("当前值", value: current.code == 0xD278 ? "已隐藏" : current.formatted)
          Text(current.description).font(.footnote).foregroundStyle(.secondary)
        }
        if !current.caution.isEmpty {
          Section {
            Label(current.caution, systemImage: "exclamationmark.triangle").font(.footnote)
          }
        }
        if current.writable && current.code != 0xD278 {
          if current.form == 2 {
            Section("相机当前允许的值") {
              ForEach(current.choices, id: \.value) { choice in
                Button {
                  value = choice.value
                  confirm = true
                } label: {
                  HStack {
                    Text(current.formattedValue(choice.value, fallback: choice.label))
                    Spacer()
                    if current.value == choice.value { Image(systemName: "checkmark") }
                  }
                }
              }
            }
          } else {
            Section("新值") {
              TextField("值", text: $value, axis: .vertical).textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              if current.form == 1 {
                Text("\(current.min) 至 \(current.max)，步长 \(current.step)").font(.footnote)
                  .foregroundStyle(.secondary)
              }
              Button("应用并读回确认") { confirm = true }.disabled(value == current.value)
            }
          }
        } else {
          Section { Label("当前相机模式下只读", systemImage: "lock") }
        }
      }.disabled(camera.busy).navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }.onAppear { value = current.value }.presentationDetents([.medium, .large])
      .confirmationDialog("设置\(current.title)", isPresented: $confirm, titleVisibility: .visible) {
        Button("应用 \(current.formattedValue(value, fallback: value))") {
          Task { await camera.set(current, to: value) }
        }
      } message: {
        Text(current.caution.isEmpty ? "写入前会重新核对相机允许的范围。" : current.caution)
      }
  }
}
