import Foundation
import SwiftUI

/// Next EqualizerDialog 的相同频段、预设和增益范围
struct NativeEqualizer: Codable, Equatable {
  var enabled = false
  var preamp = 0.0
  var bands = [Double](repeating: 0, count: 10)
  static let names = ["平直", "流行", "摇滚", "古典", "电子", "低音", "人声", "舞曲", "柔和"]
  static let presets: [[Double]] = [
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [-1, 2, 4, 5, 3, 1, -1, -1, 0, 1],
    [4, 3, -2, -3, -1, 2, 4, 5, 5, 5],
    [4, 3, 2, 1, -1, -1, 0, 2, 3, 4], [4, 3, 1, -2, -2, 1, 2, 3, 4, 5],
    [6, 5, 4, 2, 0, -1, -2, -3, -3, -3],
    [-2, -1, -1, 1, 3, 3, 2, 1, 0, -1], [4, 5, 3, 0, 1, 3, 4, 4, 3, 0],
    [3, 1, 0, 2, 3, 2, 1, 2, 3, 4],
  ]
  var preset: Int { Self.presets.firstIndex(of: bands) ?? -1 }
  /// 已保存设置必须满足引擎的十段范围约束
  static func load() -> Self {
    guard let data = UserDefaults.standard.data(forKey: "native.player.equalizer"),
      let value = try? JSONDecoder().decode(Self.self, from: data), value.bands.count == 10,
      value.bands.allSatisfy({ $0.isFinite && (-15...15).contains($0) }),
      value.preamp.isFinite && (-12...12).contains(value.preamp)
    else { return Self() }
    return value
  }
}

@MainActor
struct NativeEqualizerView: View {
  @ObservedObject var player: NativePlayerStore
  private static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $player.equalizer.enabled) {
          NativeSettingLabel(title: "启用均衡器", detail: "十段增益直接作用于播放引擎")
        }
        NativeSettingPicker(
          title: "预设",
          selection: Binding(
            get: { player.equalizer.preset },
            set: { if $0 >= 0 { player.equalizer.bands = NativeEqualizer.presets[$0] } })
        ) {
          ForEach(0..<NativeEqualizer.names.count, id: \.self) { index in
            Text(NativeEqualizer.names[index]).tag(index)
          }
          Text("自定义").tag(-1)
        }.disabled(!player.equalizer.enabled)
      }
      Section {
        VStack(spacing: 16) {
          NativeEqualizerCurve(bands: player.equalizer.bands, preamp: player.equalizer.preamp)
            .frame(height: 72)
          HStack(alignment: .top, spacing: 0) {
            gain("前级", value: $player.equalizer.preamp, range: -12...12)
            Divider().frame(height: 200).padding(.horizontal, 4)
            ForEach(Array(Self.labels.enumerated()), id: \.offset) { index, label in
              gain(label, value: $player.equalizer.bands[index], range: -15...15)
            }
          }
        }.padding(.vertical, 12).disabled(!player.equalizer.enabled)
          .opacity(player.equalizer.enabled ? 1 : 0.45)
      } header: {
        Text("增益（dB）")
      } footer: {
        Text("频段 ±15 dB，前级 ±12 dB；拖动任一频段后预设变为“自定义”")
      }
      Section {
        Button("重置均衡器", role: .destructive) {
          player.equalizer.bands = NativeEqualizer.presets[0]
          player.equalizer.preamp = 0
        }.disabled(!player.equalizer.enabled)
      }
    }.navigationTitle("均衡器")
  }

  /// 纵向增益滑块按可用宽度均分，数值与频率标签上下对齐
  private func gain(_ label: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    VStack(spacing: 10) {
      Text(value.wrappedValue > 0 ? "+\(Int(value.wrappedValue))" : "\(Int(value.wrappedValue))")
        .monospacedDigit().foregroundStyle(value.wrappedValue == 0 ? .secondary : .primary)
      Slider(value: value, in: range, step: 1).frame(width: 168).rotationEffect(.degrees(-90))
        .frame(width: 32, height: 168).accessibilityLabel(label + " 增益")
      Text(label).foregroundStyle(.secondary)
    }.font(.caption).frame(maxWidth: .infinity)
  }
}

/// 均衡器频响曲线：按各频段增益平滑连线，零线居中
struct NativeEqualizerCurve: View {
  let bands: [Double]
  let preamp: Double
  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let points = bands.enumerated().map { index, gain in
        CGPoint(
          x: size.width * (CGFloat(index) + 0.5) / CGFloat(max(1, bands.count)),
          y: size.height / 2 - CGFloat(max(-15, min(15, gain + preamp)) / 15) * size.height / 2)
      }
      ZStack {
        Path { path in
          path.move(to: CGPoint(x: 0, y: size.height / 2))
          path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        }.stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        curve(points, size: size, closed: true).fill(
          LinearGradient(
            colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)],
            startPoint: .top, endPoint: .bottom))
        curve(points, size: size, closed: false).stroke(
          Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
      }
    }.accessibilityHidden(true)
  }

  private func curve(_ points: [CGPoint], size: CGSize, closed: Bool) -> Path {
    Path { path in
      guard let first = points.first else { return }
      path.move(to: CGPoint(x: 0, y: first.y))
      path.addLine(to: first)
      for (previous, point) in zip(points, points.dropFirst()) {
        let mid = (previous.x + point.x) / 2
        path.addCurve(
          to: point, control1: CGPoint(x: mid, y: previous.y), control2: CGPoint(x: mid, y: point.y))
      }
      path.addLine(to: CGPoint(x: size.width, y: points.last!.y))
      if closed {
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
      }
    }
  }
}
