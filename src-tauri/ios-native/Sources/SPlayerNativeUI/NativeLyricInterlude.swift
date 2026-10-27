import SwiftUI

/// 只使用歌词实际时间，LRC 未提供句尾时不猜测句间间奏
struct NativeLyricInterlude: Equatable {
  let startMs: Double
  let endMs: Double
  let nextID: Int

  /// 返回前奏或至少五秒的已知间奏，跳转后直接按目标时间重新计算
  static func current(lines: [NativeLyricLine], time: Double) -> Self? {
    let vocals = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard let next = vocals.first(where: { $0.timeMs > time }) else { return nil }
    let previous = vocals.last(where: { $0.timeMs <= time })
    let start: Double
    if let previous {
      guard previous.endMs > previous.timeMs else { return nil }
      start = previous.endMs
    } else {
      start = 0
    }
    guard next.timeMs - start >= 5000, time >= start else { return nil }
    return Self(startMs: start, endMs: next.timeMs, nextID: next.id)
  }
}

/// 三个引导点随真实播放时间依次亮起，暂停及后台停止刷新
@MainActor
struct NativeInterludeDots: View {
  @ObservedObject var player: NativePlayerStore
  let interval: NativeLyricInterlude
  @Environment(\.scenePhase) private var phase
  @NativeReduceMotion private var reduceMotion
  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 1.0 / 30,
        paused: !player.isPlaying || phase != .active || reduceMotion)
    ) { timeline in
      let elapsed =
        player.isPlaying
        ? max(0, timeline.date.timeIntervalSince(player.positionAnchor) * 1000 * player.speed) : 0
      let time = player.positionMs + elapsed + player.lyricOffsetMs
      let progress = min(1, max(0, (time - interval.startMs) / (interval.endMs - interval.startMs)))
      HStack(spacing: 12) {
        ForEach(0..<3) { index in
          let fill = min(1, max(0, progress * 3 - Double(index)))
          Circle().fill(.white.opacity(0.25 + fill * 0.75))
            .frame(width: 12, height: 12)
            .scaleEffect(reduceMotion ? 1 : 1 + sin(fill * .pi) * 0.25)
            .offset(y: reduceMotion ? 0 : -4 * sin(fill * .pi))
        }
      }.frame(height: 32).accessibilityElement(children: .ignore)
        .accessibilityLabel("即将开始演唱").accessibilityIdentifier("native.lyrics.interlude")
    }
  }
}
