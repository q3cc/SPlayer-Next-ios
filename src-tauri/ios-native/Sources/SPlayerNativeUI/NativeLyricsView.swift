import SwiftUI

/// Apple Music 风格歌词舞台：当前句突出、逐字扫亮、点击跳转和手动浏览后恢复跟随
@MainActor
struct NativeLyricsView: View {
  @ObservedObject var player: NativePlayerStore
  let importLyrics: () -> Void
  var fontSize: CGFloat = 34
  var foreground: Color = .white
  @NativeReduceMotion private var reduceMotion
  @AppStorage("native.player.style") private var style = "original"
  @AppStorage("native.lyric.scale") private var enableScale = true
  @AppStorage("native.lyric.blur") private var enableBlur = false
  @AppStorage("native.lyric.hidePassed") private var hidePassed = false
  @AppStorage("native.lyric.springPreset") private var springPreset = "default"
  @AppStorage("native.lyric.springMass") private var springMass = 0.9
  @AppStorage("native.lyric.springDamping") private var springDamping = 15.0
  @AppStorage("native.lyric.springStiffness") private var springStiffness = 90.0
  @AppStorage("native.lyric.alignPosition") private var alignPosition = 0.35
  @AppStorage("native.lyric.inactiveAlpha") private var inactiveAlpha = 0.2
  @State private var browsing = false
  @State private var resumeTask: Task<Void, Never>?
  private var active: Int? { player.currentLyric?.id }
  private var interlude: NativeLyricInterlude? {
    NativeLyricInterlude.current(
      lines: player.lyrics, time: player.positionMs + player.lyricOffsetMs)
  }
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
              }.foregroundStyle(foreground.opacity(0.7)).frame(maxWidth: .infinity).padding(
                .top, geometry.size.height * 0.3)
            } else {
              LazyVStack(alignment: .leading, spacing: fontSize * 0.6) {
                ForEach(player.lyrics) { line in
                  if let gap = interlude, gap.nextID == line.id {
                    NativeInterludeDots(player: player, interval: gap)
                      .id("interlude").padding(.vertical, 12)
                  }
                  let selected = line.id == active
                  Button {
                    browsing = false
                    player.seek(to: max(0, line.timeMs - player.lyricOffsetMs))
                    if !player.isPlaying { player.togglePlayback() }
                  } label: {
                    NativeLyricText(
                      line: line, active: selected, player: player, fontSize: fontSize,
                      foreground: foreground
                    )
                    .scaleEffect(selected || !enableScale ? 1 : 0.97, anchor: .leading)
                    .opacity(
                      hidePassed && style == "original"
                        && line.timeMs < player.positionMs + player.lyricOffsetMs && !selected
                        ? 0 : selected ? 1 : style == "original" ? inactiveAlpha : 0.38
                    )
                    .blur(
                      radius: selected || browsing || reduceMotion
                        || (style == "original" && !enableBlur)
                        ? 0 : min(3, Double(abs(line.id - (active ?? 0))) * 0.65)
                    )
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: selected)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                  }.buttonStyle(.plain).id(line.id).accessibilityIdentifier(
                    "native.lyric.\(line.id)")
                }
              }.padding(.horizontal, 12).padding(.top, geometry.size.height * alignPosition)
                .padding(.bottom, geometry.size.height * (1 - alignPosition))
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
          .onChange(of: alignPosition) { _ in if !browsing { follow(proxy) } }
          .onChange(of: interlude?.nextID) { _ in if !browsing { follow(proxy) } }
          .onAppear { follow(proxy) }
          .onDisappear { resumeTask?.cancel() }
      }
    }.accessibilityIdentifier("native.lyrics.stage")
  }
  private var scrollAnimation: Animation {
    let preset = NativeLyricSpring.presets.first { $0.id == springPreset }
    return .interpolatingSpring(
      mass: preset?.mass ?? springMass, stiffness: preset?.stiffness ?? springStiffness,
      damping: preset?.damping ?? springDamping)
  }
  /// 系统减少动态效果时直接定位，否则用阻尼滚动而非逐帧强制对齐
  private func follow(_ proxy: ScrollViewProxy) {
    guard interlude != nil || active != nil else { return }
    withAnimation(reduceMotion ? nil : scrollAnimation) {
      if interlude != nil {
        proxy.scrollTo("interlude", anchor: UnitPoint(x: 0, y: alignPosition))
      } else if let active {
        proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: alignPosition))
      }
    }
  }
}

@MainActor
private struct NativeLyricText: View {
  let line: NativeLyricLine
  let active: Bool
  @ObservedObject var player: NativePlayerStore
  var fontSize: CGFloat
  var foreground: Color
  @AppStorage("native.player.style") private var style = "original"
  @AppStorage("native.lyric.weight") private var weight = 700.0
  @AppStorage("native.lyric.translation") private var translation = true
  @AppStorage("native.lyric.translationFollow") private var translationFollow = true
  @AppStorage("native.lyric.translationSize") private var translationSize = 24.0
  @AppStorage("native.lyric.highlight") private var highlight = true
  @AppStorage("native.lyric.float") private var float = false
  @AppStorage("native.lyric.emphasize") private var emphasize = false
  @AppStorage("native.lyric.romanization") private var romanization = true
  @AppStorage("native.lyric.wordRomanization") private var wordRomanization = true
  @AppStorage("native.lyric.ruby") private var ruby = true
  @AppStorage("native.lyric.alignment") private var alignment = "auto"
  @AppStorage("native.lyric.blend") private var blend = "normal"
  @AppStorage(NativeLyricFonts.lyricKey) private var lyricFont = ""
  @AppStorage(NativeLyricLanguage.chinese.settingKey) private var chineseFont = ""
  @AppStorage(NativeLyricLanguage.japanese.settingKey) private var japaneseFont = ""
  @AppStorage(NativeLyricLanguage.korean.settingKey) private var koreanFont = ""
  @AppStorage(NativeLyricLanguage.latin.settingKey) private var latinFont = ""
  /// 主行优先使用 lyric-kit 的整首歌语言，副行按自身文字识别
  private func family(_ text: String, language: String? = nil) -> String? {
    NativeLyricFonts.family(
      for: language.flatMap(NativeLyricLanguage.init(rawValue:)) ?? NativeLyricLanguage.detect(text),
      lyric: lyricFont,
      specific: [
        .chinese: chineseFont, .japanese: japaneseFont, .korean: koreanFont, .latin: latinFont,
      ])
  }
  private var fontWeight: Font.Weight {
    [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black][
      max(0, min(8, Int(weight / 100) - 1))]
  }
  /// 翻译与逐行音译共用副行字号
  private var secondarySize: CGFloat {
    translationFollow ? max(12, fontSize * 0.5) : translationSize
  }
  private var align: HorizontalAlignment {
    if alignment == "center" { return .center }
    if alignment == "right" || (alignment == "auto" && line.isDuet == true) { return .trailing }
    return .leading
  }
  @Environment(\.scenePhase) private var phase
  @NativeReduceMotion private var reduceMotion
  var body: some View {
    VStack(alignment: align, spacing: 12) {
      if active && line.words.count > 1 && (highlight || style == "am") {
        TimelineView(
          .animation(
            minimumInterval: 1.0 / 30, paused: !player.isPlaying || phase != .active || reduceMotion
          )
        ) { timeline in
          let elapsed =
            player.isPlaying
            ? max(0, timeline.date.timeIntervalSince(player.positionAnchor) * 1000 * player.speed)
            : 0
          let time = min(player.durationMs, player.positionMs + elapsed) + player.lyricOffsetMs
          NativeWordFlow(alignment: align) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
              let progress = min(
                1, max(0, (time - word.startMs) / max(1, word.endMs - word.startMs)))
              VStack(spacing: 2) {
                annotation(word)
                Text(word.text).foregroundStyle(foreground.opacity(0.30))
                  .overlay(alignment: .leading) {
                    Text(word.text).foregroundStyle(foreground)
                      .shadow(
                        color: foreground.opacity(
                          reduceMotion || (style == "original" && !emphasize)
                            ? 0 : sin(progress * .pi) * 0.6), radius: 6
                      )
                      .mask {
                        GeometryReader { geometry in
                          Rectangle().frame(width: geometry.size.width * progress)
                        }
                      }
                  }
                  .offset(
                    y: reduceMotion || (style == "original" && !float)
                      ? 0 : -3 * sin(progress * .pi))
              }
            }
          }
        }
      } else if line.words.contains(where: {
        (ruby && $0.ruby?.isEmpty == false)
          || (wordRomanization && $0.romanization?.isEmpty == false)
      }) {
        NativeWordFlow(alignment: align) {
          ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
            VStack(spacing: 2) {
              annotation(word)
              Text(word.text)
            }
          }
        }
      } else {
        Text(line.text.isEmpty ? "♪" : line.text).foregroundStyle(foreground)
      }
      if translation && !line.translation.isEmpty {
        Text(line.translation)
          .font(
            NativeLyricFonts.font(
              family: family(line.translation), size: secondarySize, weight: .medium)
          )
          .foregroundStyle(foreground.opacity(0.65))
      }
      if romanization, let roman = line.romanization, !roman.isEmpty {
        Text(roman)
          .font(NativeLyricFonts.font(family: family(roman), size: secondarySize, weight: .medium))
          .foregroundStyle(foreground.opacity(0.65))
      }
    }.multilineTextAlignment(align == .center ? .center : align == .trailing ? .trailing : .leading)
      .frame(
        maxWidth: .infinity,
        alignment: align == .center ? .center : align == .trailing ? .trailing : .leading
      )
      .blendMode(blend == "screen" ? .screen : blend == "plus-lighter" ? .plusLighter : .normal)
      .font(
        NativeLyricFonts.font(
          family: family(line.text, language: line.language), size: fontSize, weight: fontWeight)
      ).fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .ignore).accessibilityLabel(
        line.text + (line.translation.isEmpty ? "" : "，" + line.translation))
  }
  /// 保留源数据中的注音，不从主歌词猜测或生成读音
  @ViewBuilder private func annotation(_ word: NativeLyricWord) -> some View {
    if ruby, let spans = word.ruby, !spans.isEmpty {
      let text = spans.map(\.text).joined()
      Text(text).font(
        NativeLyricFonts.font(family: family(text), size: max(10, fontSize * 0.4), weight: .regular)
      ).foregroundStyle(
        foreground.opacity(0.7))
    } else if wordRomanization, let roman = word.romanization, !roman.isEmpty {
      Text(roman).font(
        NativeLyricFonts.font(family: family(roman), size: max(10, fontSize * 0.4), weight: .regular)
      ).foregroundStyle(
        foreground.opacity(0.7))
    }
  }

}

/// 逐字片段使用自然宽度换行，保留歌词原有空格
private struct NativeWordFlow: Layout {
  var alignment: HorizontalAlignment = .leading
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
    for row in Set(items.map { $0.minY }) {
      let indices = items.indices.filter { items[$0].minY == row }
      let rowWidth = indices.map { items[$0].maxX }.max() ?? 0
      let shift =
        alignment == .center
        ? (width - rowWidth) / 2 : alignment == .trailing ? width - rowWidth : 0
      for index in indices { items[index].origin.x += shift }
    }
    return (CGSize(width: width, height: y + height), items)
  }
}
