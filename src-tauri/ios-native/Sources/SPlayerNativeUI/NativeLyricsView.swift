import SwiftUI

/// Apple Music 风格歌词舞台：当前句突出、逐字扫亮、点击跳转和手动浏览后恢复跟随
@MainActor
struct NativeLyricsView: View {
  @ObservedObject var player: NativePlayerStore
  let importLyrics: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var browsing = false
  @State private var resumeTask: Task<Void, Never>?
  private var active: Int? { player.lyrics.last(where: { $0.timeMs <= player.positionMs })?.id }
  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ZStack(alignment: .bottom) {
          ScrollView {
            if player.lyrics.isEmpty {
              VStack(spacing: 18) {
                Image(systemName: "quote.bubble").font(.system(size: 42, weight: .light))
                Text("暂无歌词").font(.title2.bold())
                Button("导入歌词", action: importLyrics).buttonStyle(.bordered)
              }.foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity).padding(
                .top, geometry.size.height * 0.3)
            } else {
              LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(player.lyrics) { line in
                  let selected = line.id == active
                  Button {
                    browsing = false
                    player.seek(to: line.timeMs)
                  } label: {
                    NativeLyricText(line: line, active: selected, player: player)
                      .scaleEffect(selected ? 1 : 0.97, anchor: .leading)
                      .opacity(selected ? 1 : 0.38)
                      .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: selected)
                      .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                  }.buttonStyle(.plain).id(line.id).accessibilityIdentifier(
                    "native.lyric.\(line.id)")
                }
              }.padding(.horizontal, 12).padding(.vertical, geometry.size.height * 0.35)
            }
          }.scrollIndicators(.hidden)
            .mask(
              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0), .init(color: .white, location: 0.12),
                  .init(color: .white, location: 0.84), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .simultaneousGesture(
              DragGesture(minimumDistance: 8).onChanged { _ in
                browsing = true
                resumeTask?.cancel()
              }.onEnded { _ in
                resumeTask = Task {
                  try? await Task.sleep(nanoseconds: 6_000_000_000)
                  if !Task.isCancelled {
                    browsing = false
                    follow(proxy)
                  }
                }
              })
          if browsing {
            Button {
              resumeTask?.cancel()
              browsing = false
              follow(proxy)
            } label: {
              Label("回到当前歌词", systemImage: "arrow.uturn.backward").font(
                .system(size: 13, weight: .medium)
              ).padding(.horizontal, 16).padding(.vertical, 12)
            }.buttonStyle(.plain).nativeGlass(in: Capsule()).padding(.bottom, 12)
          }
        }.onChange(of: active) { _ in if !browsing { follow(proxy) } }
          .onAppear { follow(proxy) }
          .onDisappear { resumeTask?.cancel() }
      }
    }.accessibilityIdentifier("native.lyrics.stage")
  }
  /// 系统减少动态效果时直接定位，否则用阻尼滚动而非逐帧强制对齐
  private func follow(_ proxy: ScrollViewProxy) {
    guard let active else { return }
    withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.86)) {
      proxy.scrollTo(active, anchor: .center)
    }
  }
}

@MainActor
private struct NativeLyricText: View {
  let line: NativeLyricLine
  let active: Bool
  @ObservedObject var player: NativePlayerStore
  @Environment(\.scenePhase) private var phase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if active && line.words.count > 1 {
        TimelineView(
          .animation(
            minimumInterval: 1.0 / 30, paused: !player.isPlaying || phase != .active || reduceMotion
          )
        ) { timeline in
          let elapsed =
            player.isPlaying
            ? max(0, timeline.date.timeIntervalSince(player.positionAnchor) * 1000) : 0
          let time = min(player.durationMs, player.positionMs + elapsed)
          NativeWordFlow {
            ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
              let progress = min(
                1, max(0, (time - word.startMs) / max(1, word.endMs - word.startMs)))
              Text(word.text).foregroundStyle(.white.opacity(0.30))
                .overlay(alignment: .leading) {
                  Text(word.text).foregroundStyle(.white)
                    .mask {
                      GeometryReader { geometry in
                        Rectangle().frame(width: geometry.size.width * progress)
                      }
                    }
                }
            }
          }
        }
      } else {
        Text(line.text.isEmpty ? "♪" : line.text).foregroundStyle(.white)
      }
      if !line.translation.isEmpty {
        Text(line.translation).font(.system(size: 18, weight: .medium)).foregroundStyle(
          .white.opacity(0.65))
      }
    }.font(.system(size: 34, weight: .bold)).fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .ignore).accessibilityLabel(
        line.text + (line.translation.isEmpty ? "" : "，" + line.translation))
  }
}

/// 逐字片段使用自然宽度换行，保留歌词原有空格
private struct NativeWordFlow: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? 400).size
  }
  /// 按已计算的换行位置摆放逐字歌词片段
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrange(subviews, width: bounds.width)
    for (index, item) in result.items.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
        proposal: ProposedViewSize(item.size))
    }
  }
  /// 按可用宽度自然换行，不改变歌词原有空格
  private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, items: [CGRect]) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var height: CGFloat = 0
    var items: [CGRect] = []
    for view in subviews {
      var size = view.sizeThatFits(.unspecified)
      if size.width > width {
        size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
      }
      if x + size.width > width, x > 0 {
        x = 0
        y += height + 3
        height = 0
      }
      items.append(CGRect(x: x, y: y, width: size.width, height: size.height))
      x += size.width
      height = max(height, size.height)
    }
    return (CGSize(width: width, height: y + height), items)
  }
}
