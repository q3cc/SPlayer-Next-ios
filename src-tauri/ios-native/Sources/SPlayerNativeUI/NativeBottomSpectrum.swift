import SwiftUI

/// Next BottomSpectrum 的固定双声道缓冲、时间插值和攻放平滑
@MainActor
final class NativeSpectrumFrames {
  private var previous = [[Float]](repeating: [Float](repeating: 0, count: 128), count: 2)
  private var current = [[Float]](repeating: [Float](repeating: 0, count: 128), count: 2)
  private var display = [[Float]](repeating: [Float](repeating: 0, count: 128), count: 2)
  private var timestamp = Date.distantPast
  /// 新 PCM 帧只替换有限缓冲，保留上一帧用于 50ms 插值
  func push(_ frame: [[Float]]) {
    previous = current
    current = frame
    timestamp = Date()
  }
  /// 反向仅交换频谱排列，不交换真实声道
  func bars(at date: Date, width: Double, barWidth: Double, reverse: Bool) -> [Double] {
    let t = Float(min(1, max(0, date.timeIntervalSince(timestamp) * 1000 / 50)))
    for c in 0..<2 {
      for i in 0..<128 {
        let target = previous[c][i] + (current[c][i] - previous[c][i]) * t
        display[c][i] =
          target > display[c][i]
          ? display[c][i] + (target - display[c][i]) * 0.4 : display[c][i] * 0.88 + target * 0.12
      }
    }
    var stereo = [Float](repeating: 0, count: 240)
    for i in 0..<120 {
      stereo[(reverse ? 120 : 0) + i] = display[0][127 - i]
      stereo[(reverse ? 0 : 120) + i] = display[1][8 + i]
    }
    let count = max(0, Int(floor(min(1920, width) / (barWidth + 3))))
    return (0..<count).map { i in
      let start = Int(floor(Double(i * 240) / Double(count)))
      let end = Int(floor(Double((i + 1) * 240) / Double(count)))
      let lo = max(0, start - 1)
      let hi = min(240, max(end, start + 1) + 1)
      return Double(stereo[lo..<hi].reduce(0, +)) / Double(hi - lo)
    }
  }
}

/// 使用原生 Canvas 绘制真实频谱，隐藏应用和暂停播放时不刷新
struct NativeBottomSpectrum: View {
  let frames: NativeSpectrumFrames
  let playing: Bool
  let immersive: Bool
  let color: Color
  @AppStorage("native.player.spectrumWidth") private var barWidth = 4.0
  @AppStorage("native.player.reverseSpectrum") private var reverse = false
  @Environment(\.scenePhase) private var phase
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing || phase != .active)) {
      time in
      Canvas { context, size in
        let values = frames.bars(
          at: time.date, width: size.width, barWidth: barWidth, reverse: reverse)
        var path = Path()
        for (index, value) in values.enumerated() {
          let height = value * size.height
          if height > 0.5 {
            path.addRoundedRect(
              in: CGRect(
                x: Double(index) * (barWidth + 3), y: size.height - height, width: barWidth,
                height: height), cornerSize: CGSize(width: 2, height: 2))
          }
        }
        context.fill(path, with: .color(color))
      }
    }.frame(maxWidth: 1920).frame(height: 80)
      .mask(
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0), .init(color: .white.opacity(0.6), location: 0.05),
            .init(color: .white, location: 0.12), .init(color: .white, location: 0.88),
            .init(color: .white.opacity(0.6), location: 0.95), .init(color: .clear, location: 1),
          ], startPoint: .leading, endPoint: .trailing)
      )
      .opacity(immersive && playing ? 0.65 : 0.15).allowsHitTesting(false).accessibilityHidden(true)
  }
}
