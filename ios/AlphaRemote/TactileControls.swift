import SwiftUI

extension CameraProperty {
  var usesRuler: Bool {
    [0xD21E, 0x5007, 0xD20D, 0x5010, 0xD20F].contains(code) && !dialChoices.isEmpty
  }
  var dialChoices: [Choice] {
    if form == 2 {
      var seen = Set<String>()
      return choices.filter { seen.insert($0.value).inserted }
    }
    if form == 1, let low = Int64(min), let high = Int64(max), let increment = Int64(step),
      increment > 0, high >= low, high - low <= increment * 2000
    {
      return stride(from: low, through: high, by: Int(increment)).map {
        Choice(value: String($0), label: String($0))
      }
    }
    return []
  }
}
struct TactileParameterControl: View {
  @Environment(CameraModel.self) private var camera
  let property: CameraProperty
  @State private var selection: String?
  @State private var interacting = false
  @State private var requested: String?
  private var current: CameraProperty {
    camera.properties.first { $0.id == property.id } ?? property
  }
  private var options: [CameraProperty.Choice] { current.dialChoices }
  private var selectedLabel: String {
    current.formattedValue(selection ?? current.value, fallback: selection ?? current.value)
  }
  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .lastTextBaseline) {
        VStack(alignment: .leading, spacing: 5) {
          Text(current.title.uppercased()).font(
            .system(size: 10, weight: .semibold, design: .monospaced)
          ).tracking(2).foregroundStyle(.secondary)
          Text(selectedLabel).font(.system(size: 30, weight: .light, design: .rounded))
            .monospacedDigit().contentTransition(.numericText()).accessibilityIdentifier(
              "dialValue-\(current.code)")
        }
        Spacer()
        if camera.dialRunning {
          ProgressView().tint(Theme.accent)
        } else {
          Image(systemName: current.writable ? "dial.medium" : "lock").foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 20)
      GeometryReader { geometry in
        ZStack {
          // A metal barrel with a fixed pointer; the engraved scale rolls beneath it.
          RoundedRectangle(cornerRadius: 20).fill(
            LinearGradient(
              colors: [Color(white: 0.18), Color(white: 0.08), Color(white: 0.13)],
              startPoint: .top, endPoint: .bottom))
          ScrollView(.horizontal) {
            HStack(spacing: 0) {
              ForEach(options, id: \.value) { option in
                Button {
                  withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                  commit(option.value)
                } label: {
                  VStack(spacing: 9) {
                    HStack(alignment: .top, spacing: 7) {
                      ForEach(0..<5, id: \.self) { tick in
                        Rectangle().fill(
                          tick == 2 ? Color.white.opacity(0.8) : Color.white.opacity(0.25)
                        ).frame(width: 1, height: tick == 2 ? 25 : 12)
                      }
                    }
                    Text(current.formattedValue(option.value, fallback: option.label)).font(
                      .system(size: 11, weight: .medium, design: .rounded)
                    ).lineLimit(1).minimumScaleFactor(0.6)
                      .foregroundStyle(selection == option.value ? Theme.accent : Color.secondary)
                  }.frame(width: 70, height: 74)
                }.buttonStyle(.plain).id(option.value).accessibilityLabel(
                  "\(current.title) \(current.formattedValue(option.value,fallback:option.label))")
              }
            }.scrollTargetLayout()
          }.safeAreaPadding(.horizontal, max(0, (geometry.size.width - 70) / 2))
            .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selection, anchor: .center)
            .onScrollPhaseChange { _, phase in
              if phase == .interacting || phase == .decelerating { interacting = true }
              if phase == .idle && interacting {
                interacting = false
                if let selection { commit(selection) }
              }
            }
            .mask(
              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0), .init(color: .white, location: 0.14),
                  .init(color: .white, location: 0.86), .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
          VStack {
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2, height: 29)
            Spacer()
          }.padding(.top, 2).allowsHitTesting(false)
        }.overlay {
          RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
      }.frame(height: 90).padding(.horizontal, 12)
        .accessibilityIdentifier("parameterRuler-\(current.code)")
        .accessibilityAdjustableAction { direction in
          guard let i = options.firstIndex(where: { $0.value == (selection ?? current.value) })
          else { return }
          let next = direction == .increment ? min(i + 1, options.count - 1) : max(i - 1, 0)
          selection = options[next].value
          commit(options[next].value)
        }
        .disabled(!current.writable || !camera.connected || camera.importing)
      HStack {
        Text(current.writable ? "滚动停稳后应用" : "机身当前不可调").foregroundStyle(.secondary)
        Spacer()
        Text("机身 · \(current.formatted)").foregroundStyle(Theme.accent).accessibilityIdentifier(
          "cameraValue-\(current.code)")
      }.font(.caption2).padding(.horizontal, 20)
    }.padding(.vertical, 18)
      .onAppear { selection = current.value }
      .onChange(of: current.value) { _, value in
        if !interacting && !camera.dialRunning { selection = value }
      }
      .onChange(of: camera.dialRunning) { _, running in
        if !running && !interacting {
          selection = current.value
          requested = nil
        }
      }
      .sensoryFeedback(.selection, trigger: selection)
  }
  private func commit(_ value: String) {
    guard current.writable, value != current.value, requested != value else { return }
    requested = value
    camera.scheduleDial(code: current.code, value: value)
  }
}
struct TactileParameterSheet: View {
  @Environment(CameraModel.self) private var camera
  @Environment(\.dismiss) private var dismiss
  let property: CameraProperty
  var cameraStyle = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        TactileParameterControl(property: property)
        if let automatic = property.dialChoices.first(where: { $0.value == "16777215" }) {
          if cameraStyle {
            Button("AUTO ISO") { camera.scheduleDial(code: property.code, value: automatic.value) }
              .buttonStyle(CameraLCDButtonStyle()).font(
                .system(size: 12, weight: .semibold, design: .monospaced)
              ).padding(10).overlay { Rectangle().stroke(.white.opacity(0.25), lineWidth: 0.5) }
          } else {
            Button("自动 ISO") { camera.scheduleDial(code: property.code, value: automatic.value) }
              .buttonStyle(.glass)
          }
        }
        Spacer(minLength: 0)
      }.navigationTitle(property.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            .sharedBackgroundVisibility(cameraStyle ? .hidden : .automatic)
        }
    }.presentationDetents([.height(300), .medium])
  }
}
struct TactileChoiceControl: View {
  @Environment(CameraModel.self) private var camera
  let property: CameraProperty
  private var current: CameraProperty {
    camera.properties.first { $0.id == property.id } ?? property
  }
  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
      ForEach(current.choices, id: \.value) { option in
        Button {
          camera.scheduleDial(code: current.code, value: option.value)
        } label: {
          VStack(spacing: 7) {
            Circle().fill(current.value == option.value ? Theme.accent : .gray.opacity(0.35)).frame(
              width: 5, height: 5)
            Text(current.formattedValue(option.value, fallback: option.label)).font(
              .subheadline.weight(.medium)
            ).lineLimit(2).minimumScaleFactor(0.7)
          }.frame(maxWidth: .infinity, minHeight: 58).padding(6)
        }.buttonStyle(.plain).background(
          current.value == option.value ? Color.white.opacity(0.12) : Color.white.opacity(0.04),
          in: .rect(cornerRadius: 14)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 14).strokeBorder(
            current.value == option.value ? Theme.accent.opacity(0.7) : Color.white.opacity(0.1),
            lineWidth: 1)
        }
        .disabled(!current.writable || camera.importing || !camera.connected)
      }
    }.padding(.vertical, 8)
  }
}
