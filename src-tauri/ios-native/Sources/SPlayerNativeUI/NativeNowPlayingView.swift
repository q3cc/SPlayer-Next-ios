import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import AVKit
  import MediaPlayer
#endif

@MainActor
struct NativeNowPlayingView: View {
  @ObservedObject var player: NativePlayerStore
  var close: (() -> Void)? = nil
  var onDragReveal: ((Bool) -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @NativeReduceMotion private var reduceMotion
  @AppStorage("native.player.style") private var style = "original"
  @AppStorage("native.player.coverRatio") private var coverRatio = 0.45
  @AppStorage("native.player.coverLayout") private var coverLayout = "default"
  @AppStorage("native.player.followCoverColor") private var followCoverColor = true
  @State private var coverColors = NativeCoverColors()
  @AppStorage("native.player.autoCenter") private var autoCenter = true
  @AppStorage("native.player.keepAwake") private var keepAwake = false
  @AppStorage("native.lyric.fontSize") private var lyricFontSize = 48.0
  @AppStorage("native.lyric.adaptive") private var adaptiveFont = true
  @AppStorage("native.player.timeFormat") private var timeFormat = 0
  @AppStorage("native.player.spectrum") private var spectrum = false
  @AppStorage("native.player.beat") private var beat = false
  @AppStorage("native.player.background") private var background = "blur"
  @Environment(\.scenePhase) private var phase
  @State private var amLyrics = false
  private var showLyrics: Bool {
    get { style == "original" ? player.showOriginalLyrics : amLyrics }
    nonmutating set {
      if style == "original" { player.showOriginalLyrics = newValue } else { amLyrics = newValue }
    }
  }
  @State private var controlsVisible = false
  @State private var queuePanel = false
  @State private var initializedPanel = false
  @AppStorage("native.player.showPlaybackSource") private var showPlaybackSource = false
  @AppStorage("native.player.autoImmersive") private var autoImmersive = true
  @State private var idleTask: Task<Void, Never>?
  @State private var originalImmersive = false
  @State private var dragStart: Date?
  @State private var dragRejected = false
  @State private var dragLocked = false
  @State private var dragOffset: CGFloat = 0
  @State private var importLyrics = false
  @State private var showQueue = false
  @State private var showVolume = false
  @State private var selectedTool: NativePlaybackTool?
  @AppStorage("native.download.enabled") private var downloadEnabled = false
  @State private var fmModes = false

  private var foreground: Color {
    style == "original" && followCoverColor ? coverColors.foreground : .white
  }

  /// 毫秒时间格式化为分秒
  static func time(_ milliseconds: Double) -> String {
    let seconds = milliseconds.isFinite ? Int(max(0, milliseconds / 1000)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 900
      let fullHeight =
        geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
      ZStack {
        NativeAmbientBackground(
          cover: player.current?.cover, playing: player.isPlaying,
          coverColors: followCoverColor ? coverColors : NativeCoverColors(),
          bassVolume: beat ? player.bassVolume : 0.1)
        if style == "am" {
          let dx = sin(160.0 * .pi / 180)
          let dy = -cos(160.0 * .pi / 180)
          let length = geometry.size.width * dx + fullHeight * dy
          LinearGradient(
            colors: [
              Color(red: 17 / 255, green: 19 / 255, blue: 27 / 255).opacity(56 / 255),
              Color(red: 10 / 255, green: 8 / 255, blue: 21 / 255).opacity(107 / 255),
            ],
            startPoint: UnitPoint(
              x: 0.5 - length * dx / (2 * geometry.size.width),
              y: 0.5 - length * dy / (2 * fullHeight)),
            endPoint: UnitPoint(
              x: 0.5 + length * dx / (2 * geometry.size.width),
              y: 0.5 + length * dy / (2 * fullHeight))
          ).ignoresSafeArea().allowsHitTesting(false)
        }
        if style == "original" && coverLayout == "fullscreen" {
          HStack(spacing: 0) {
            NativeArtwork(cover: player.current?.cover, radius: 0, pixels: 1000)
              .frame(width: geometry.size.width * 0.6).mask(
                LinearGradient(
                  stops: zip(
                    [0.0, 0.1, 0.22, 0.32, 0.42, 0.52, 0.62, 0.72, 0.82, 0.92, 1.0],
                    [1.0, 0.98, 0.92, 0.82, 0.68, 0.52, 0.36, 0.22, 0.1, 0.03, 0.0]
                  ).map { .init(color: .white.opacity($0.1), location: $0.0) },
                  startPoint: .leading, endPoint: .trailing))
            Spacer(minLength: 0)
          }.ignoresSafeArea().allowsHitTesting(false)
        }
        if style == "original" && spectrum {
          VStack {
            Spacer()
            NativeBottomSpectrum(
              frames: player.spectrumFrames, playing: player.isPlaying,
              immersive: originalImmersive, color: foreground)
          }.ignoresSafeArea()
        }
        VStack(spacing: 0) {
          header(wide: wide).opacity(style == "original" && originalImmersive ? 0 : 1)
            .allowsHitTesting(!(style == "original" && originalImmersive))
          if style == "original" {
            originalPlayer(size: geometry.size, fullHeight: fullHeight, wide: wide)
          } else {
            applePlayer(size: geometry.size, wide: wide)
          }
        }
        if style == "am" && showLyrics && !wide {
          VStack {
            if !controlsVisible { Spacer() }
            HStack {
              if controlsVisible { Spacer() }
              Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                  controlsVisible.toggle()
                }
              } label: {
                Image(systemName: controlsVisible ? "chevron.down" : "chevron.up")
                  .frame(width: 44, height: 44).background(.white.opacity(0.07), in: Circle())
              }.buttonStyle(.plain)
                .accessibilityLabel(controlsVisible ? "隐藏控制区" : "显示控制区")
                .accessibilityIdentifier("native.player.revealControls")
            }
            if controlsVisible { Spacer() }
          }.padding(.horizontal, 16).padding(.bottom, 12)
        }
      }.onAppear {
        if !initializedPanel {
          if style == "am" { showLyrics = wide }
          initializedPanel = true
        }
      }
    }.task(id: player.current?.cover) {
      let source = player.current?.cover ?? ""
      guard !source.isEmpty, let image = await NativeArtworkCache.shared.image(source, pixels: 300)
      else {
        coverColors = NativeCoverColors()
        return
      }
      do {
        let colors = try await Task.detached(priority: .utility) {
          try NativeCoverColors.extract(image)
        }.value
        if !Task.isCancelled { coverColors = colors }
      } catch { coverColors = NativeCoverColors() }
    }.foregroundStyle(style == "original" && followCoverColor ? coverColors.foreground : .white)
      .offset(y: dragOffset).environment(\.colorScheme, .dark).tint(foreground)
      .contentShape(Rectangle())
      .simultaneousGesture(
        DragGesture(minimumDistance: 0).onChanged { _ in
          idleTask?.cancel()
          withAnimation(.easeInOut(duration: 0.4)) { originalImmersive = false }
        }.onEnded { _ in armIdle() }
      )
      .onChange(of: dragOffset > 0) { onDragReveal?($0) }
      .onChange(of: style) { _ in
        armIdle()
        syncSpectrum()
      }
      .onAppear {
        armIdle()
        syncSpectrum()
        syncAwake()
      }
      .onChange(of: keepAwake) { _ in syncAwake() }
      .onChange(of: spectrum) { _ in syncSpectrum() }
      .onChange(of: beat) { _ in syncSpectrum() }
      .onChange(of: background) { _ in syncSpectrum() }
      .onChange(of: phase) { _ in
        syncSpectrum()
        syncAwake()
      }
      .onDisappear {
        idleTask?.cancel()
        player.setSpectrumActive(false)
        #if os(iOS)
          UIApplication.shared.isIdleTimerDisabled = false
        #endif
      }
      .alert(
        "播放失败",
        isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })
      ) {
        Button("好") { player.error = nil }
      } message: {
        Text(player.error ?? "")
      }
      .sheet(item: $selectedTool) { NativePlaybackTools(player: player, tool: $0) }
      .sheet(isPresented: $showQueue) { NativeQueueView(player: player) }
      .sheet(isPresented: $fmModes) { NativeFMModeView(player: player) }
      .fileImporter(
        isPresented: $importLyrics,
        allowedContentTypes: ["lrc", "ttml", "yrc", "qrc", "krc", "lys", "srt", "ass"].compactMap {
          UTType(filenameExtension: $0)
        } + [.plainText, .xml]
      ) { result in
        switch result {
        case .success(let url): Task { await player.importLyrics(url) }
        case .failure(let error): player.error = error.localizedDescription
        }
      }
  }

  /// 覆盖层由根页面收起，独立窗口仍使用系统关闭入口
  private func closePlayer() {
    if let close { close() } else { dismiss() }
  }

  /// 原版播放器按自动沉浸设置在五秒闲置后隐藏顶/底栏，AM 则使用独立的歌词面板规则
  private func armIdle() {
    idleTask?.cancel()
    withAnimation(.easeInOut(duration: 0.4)) { originalImmersive = false }
    guard style == "original", autoImmersive else { return }
    idleTask = Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.4)) { originalImmersive = true }
    }
  }

  /// 仅播放器可见时保持屏幕常亮，退出后恢复系统行为
  private func syncAwake() {
    #if os(iOS)
      UIApplication.shared.isIdleTimerDisabled = keepAwake && phase == .active
    #endif
  }
  /// 节拍采集与背景可见性一致，离开页面后释放
  private func syncSpectrum() {
    player.setSpectrumActive(
      ((beat && (background == "fluid" || background == "animation"))
        || (spectrum && style == "original")) && phase == .active
        && !reduceMotion)
  }
  /// 两套播放器分别采用 Next 的顶栏与 AM 拖动条
  private func header(wide: Bool) -> some View {
    HStack(spacing: 8) {
      if style == "original" {
        if !wide {
          Button {
            closePlayer()
          } label: {
            Image(systemName: "chevron.down").frame(width: 44, height: 44)
          }.accessibilityLabel("收起播放器")
        }
        lyricsToggle
        Spacer()
        options
      } else {
        Spacer()
        Capsule().fill(.white.opacity(0.44)).frame(width: 36, height: 5).frame(
          width: 72, height: 44
        ).contentShape(Rectangle())
          .onTapGesture { closePlayer() }
          .accessibilityLabel("收起播放器")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { closePlayer() }
        Spacer()
      }
    }.font(.system(size: 20)).buttonStyle(.plain).padding(.horizontal, 12)
      .frame(height: style == "original" ? 56 : 48)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard style == "am" else { return }
            if dragStart == nil { dragStart = value.time }
            guard !dragRejected else { return }
            if !dragLocked {
              guard max(abs(value.translation.width), abs(value.translation.height)) >= 8 else {
                return
              }
              guard value.translation.height > 0,
                abs(value.translation.width) <= value.translation.height
              else {
                dragRejected = true
                return
              }
              dragLocked = true
            }
            dragOffset = max(0, value.translation.height)
          }.onEnded { value in
            let duration = max(1, value.time.timeIntervalSince(dragStart ?? value.time) * 1000)
            if dragLocked
              && (dragOffset >= 80 || (dragOffset >= 24 && dragOffset / duration >= 0.6))
            {
              closePlayer()
            }
            dragStart = nil
            dragRejected = false
            dragLocked = false
            withAnimation(.easeOut(duration: 0.3)) { dragOffset = 0 }
          })
  }

  /// 按原版 45% 双栏、78vw/52vh 封面及垂直偏移计算布局
  private func originalPlayer(size: CGSize, fullHeight: CGFloat, wide: Bool) -> some View {
    let visibleLyrics = showLyrics && !player.lyrics.isEmpty
    return VStack(spacing: 0) {
      GeometryReader { stage in
        let panelWidth = wide ? size.width * coverRatio : size.width
        let coverSize =
          wide
          ? max(0, min(max(200, (panelWidth - 96) * 0.85), fullHeight * 0.5))
          : max(0, min(size.width * 0.78, fullHeight * 0.52))
        let centerX =
          wide && visibleLyrics && !(autoCenter && player.lyrics.isEmpty)
          ? panelWidth / 2 : size.width / 2
        let centerY = stage.size.height / 2 - fullHeight * (wide ? 0.11 : 0.04)
        ZStack(alignment: .topLeading) {
          if (wide && coverLayout != "fullscreen") || (!wide && !visibleLyrics) {
            artwork(radius: 32).frame(width: coverSize, height: coverSize)
              .overlay(alignment: .topLeading) {
                originalMetadata(fontSize: min(16, max(12, fullHeight * 14 / 1080)))
                  .frame(width: coverSize, alignment: .leading).fixedSize(
                    horizontal: false, vertical: true
                  )
                  .offset(y: coverSize + 24)
              }.position(x: centerX, y: centerY)
          }
          if visibleLyrics || (wide && coverLayout == "fullscreen") {
            VStack(alignment: .leading, spacing: 24) {
              if wide && coverLayout == "fullscreen" {
                originalMetadata(fontSize: min(16, max(12, fullHeight * 14 / 1080)))
              }
              lyrics(fontSize: adaptiveFont ? fullHeight * lyricFontSize / 1080 : lyricFontSize)
            }.frame(
              width: wide
                ? size.width - (coverLayout == "fullscreen" ? size.width * 0.5 : panelWidth) - 80
                : size.width - 40,
              height: stage.size.height
            )
            .offset(x: wide ? (coverLayout == "fullscreen" ? size.width * 0.5 : panelWidth) : 20)
          }
        }.frame(width: size.width, height: stage.size.height)
      }
      originalControls(wide: wide).opacity(originalImmersive ? 0 : 1).allowsHitTesting(
        !originalImmersive
      ).frame(height: wide ? 80 : 114)
        .padding(.horizontal, wide ? 16 : 20).padding(.bottom, wide ? 0 : 12)
    }
  }

  /// 原版元信息左对齐，保留真实来源、歌词格式及专辑
  private func originalMetadata(fontSize: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: fontSize * 0.5) {
      Text(player.title).font(.system(size: fontSize * 2, weight: .semibold)).lineLimit(1)
        .accessibilityIdentifier("native.player.title")
      HStack(spacing: 6) {
        Text((player.current?.source ?? "local").uppercased()).padding(.horizontal, 6).padding(
          .vertical, 4
        ).overlay(RoundedRectangle(cornerRadius: 6).stroke(foreground.opacity(0.3)))
        Text(
          player.lyrics.isEmpty
            ? "NO-LRC" : player.lyrics.contains(where: { !$0.words.isEmpty }) ? "逐字" : "LRC"
        ).padding(.horizontal, 6).padding(.vertical, 4).overlay(
          RoundedRectangle(cornerRadius: 6).stroke(foreground.opacity(0.3)))
      }.font(.system(size: fontSize)).foregroundStyle(foreground.opacity(0.6))
      Label(player.artist, systemImage: "mic").font(.system(size: fontSize * 1.2)).foregroundStyle(
        foreground.opacity(0.6)
      ).lineLimit(1)
      if let album = player.current?.album, !album.isEmpty {
        Label(album, systemImage: "opticaldisc").font(.system(size: fontSize * 1.2))
          .foregroundStyle(foreground.opacity(0.6)).lineLimit(1)
      }
      if showPlaybackSource, let context = player.playbackContext, !context.isEmpty {
        Label(context, systemImage: "list.bullet").font(.system(size: fontSize)).foregroundStyle(
          .secondary)
      }
    }.padding(.horizontal, 8)
  }

  /// AM 竖屏歌词默认沉浸；显示控制区后恢复原位，横屏不隐藏控制区
  private func applePlayer(size: CGSize, wide: Bool) -> some View {
    let immersive = !wide && showLyrics && !controlsVisible
    return VStack(spacing: 0) {
      if wide {
        HStack(spacing: max(48, size.width * 0.07)) {
          VStack(spacing: 16) {
            VStack(spacing: 24) {
              artwork(radius: 8).aspectRatio(1, contentMode: .fit)
              appleMetadata(compact: false)
            }.frame(maxHeight: .infinity)
            appleControls
          }.frame(width: min(400, size.width * 0.36))
          if queuePanel {
            inlineQueue.frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if showLyrics {
            lyrics(fontSize: min(42, max(26, size.width * 0.03))).frame(
              maxWidth: .infinity, maxHeight: .infinity)
          }
        }.padding(.horizontal, 64).padding(.top, 16).padding(.bottom, 12)
          .frame(maxWidth: 1440, maxHeight: .infinity)
      } else {
        VStack(spacing: 16) {
          GeometryReader { stage in
            if showLyrics || queuePanel {
              VStack(spacing: 8) {
                HStack(spacing: 16) {
                  NativeArtwork(cover: player.current?.cover, radius: 8, pixels: 120).frame(
                    width: 56, height: 56
                  ).nativeCoverAnchor("player.full", radius: 8)
                  appleMetadata(compact: true)
                }
                if queuePanel {
                  inlineQueue
                } else {
                  lyrics(fontSize: min(42, max(26, size.width * 0.03))).frame(maxHeight: .infinity)
                }
              }
            } else {
              VStack(spacing: 24) {
                NativeArtwork(cover: player.current?.cover, radius: 0, pixels: 1000, preview: 300)
                  .frame(width: stage.size.width + 56, height: max(0, stage.size.height - 76))
                  .nativeCoverAnchor("player.full", radius: 0)
                  .mask(
                    LinearGradient(
                      stops: [
                        .init(color: .white, location: 0), .init(color: .white, location: 0.8),
                        .init(color: .clear, location: 1),
                      ], startPoint: .top, endPoint: .bottom))
                appleMetadata(compact: false).frame(height: 52)
              }.frame(width: stage.size.width)
            }
          }
          if !immersive { appleControls }
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 16)
          .frame(maxWidth: 580).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !immersive {
        HStack {
          if wide {
            route.frame(maxWidth: .infinity, alignment: .leading)
            lyricsToggle
            queueButton
          } else {
            lyricsToggle.frame(maxWidth: .infinity)
            route.frame(maxWidth: .infinity)
            queueButton.frame(maxWidth: .infinity)
          }
        }.padding(.horizontal, 28).frame(height: 72).font(.system(size: 24)).buttonStyle(.plain)
      } else {
        Color.clear.frame(height: 48)
      }
    }
  }

  /// AM 歌曲头随歌词模式缩小，歌曲操作保留在标题右侧
  private func appleMetadata(compact: Bool) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(player.title).font(.system(size: compact ? 18 : 20, weight: .bold)).lineLimit(1)
            .accessibilityIdentifier("native.player.title")
          Text((player.current?.source ?? "local").uppercased()).font(
            .system(size: 9, weight: .medium)
          ).padding(.horizontal, 3).overlay(
            RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.3))
          ).foregroundStyle(.white.opacity(0.6))
        }
        Text(player.artist).font(.system(size: compact ? 15 : 17)).foregroundStyle(
          .white.opacity(0.74)
        ).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      options.background(.white.opacity(0.09), in: Circle())
    }
  }

  private var appleControls: some View {
    VStack(spacing: 0) {
      NativePlayerSeekSlider(player: player).frame(height: 32)
      HStack {
        Text(Self.time(player.positionMs)).accessibilityIdentifier("native.player.position")
        Spacer()
        Text("−" + Self.time(max(0, player.durationMs - player.positionMs)))
      }.font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.72))
      HStack(spacing: 8) {
        shuffleButton
        Spacer(minLength: 0)
        Button(action: player.previous) {
          Image(systemName: "backward.fill").font(.system(size: 32)).frame(width: 48, height: 48)
        }.accessibilityLabel("上一首").disabled(player.fmMode).opacity(player.fmMode ? 0.4 : 1)
        Spacer(minLength: 0)
        playButton(apple: true)
        Spacer(minLength: 0)
        Button(action: player.next) {
          Image(systemName: "forward.fill").font(.system(size: 32)).frame(width: 48, height: 48)
        }.accessibilityLabel("下一首")
        Spacer(minLength: 0)
        repeatButton
      }.padding(.vertical, 12)
      #if os(iOS)
        HStack(spacing: 12) {
          Image(systemName: "speaker.wave.1")
          NativeVolumeSlider().frame(height: 32)
          Image(systemName: "speaker.wave.3")
        }.font(.system(size: 20)).foregroundStyle(.white.opacity(0.72))
      #endif
    }.buttonStyle(.plain).frame(height: 190)
  }

  /// 原版竖屏进度在上、播放键在下；横屏工具区分列，不随歌词高度变化
  private func originalControls(wide: Bool) -> some View {
    ZStack {
      if wide {
        HStack {
          Button {
            closePlayer()
          } label: {
            Image(systemName: "chevron.down").frame(width: 44, height: 44)
          }.accessibilityLabel("收起播放器")
          Button {
            if let track = player.current { player.toggleFavorite(track) }
          } label: {
            Image(systemName: player.current.map(player.isFavorite) == true ? "heart.fill" : "heart")
              .frame(width: 44, height: 44)
          }.accessibilityLabel("喜欢")
          Spacer()
          volumeButton
          route
          queueButton
        }
      }
      VStack(spacing: wide ? 0 : 12) {
        if !wide { originalProgress }
        HStack(spacing: 12) {
          if wide { shuffleButton } else { volumeButton }
          Button(action: player.previous) {
            Image(systemName: "backward.end").frame(width: 44, height: 44)
          }.accessibilityLabel("上一首").disabled(player.fmMode).opacity(player.fmMode ? 0.4 : 1)
          playButton(apple: false)
          Button(action: player.next) {
            Image(systemName: "forward.end").frame(width: 44, height: 44)
          }.accessibilityLabel("下一首")
          if wide { repeatButton } else { route }
        }
        if wide { originalProgress }
      }.frame(maxWidth: wide ? 420 : .infinity)
    }.font(.system(size: 20)).buttonStyle(.plain)
  }

  private var originalProgress: some View {
    HStack(spacing: 8) {
      Text(
        timeFormat == 1
          ? "−" + Self.time(max(0, player.durationMs - player.positionMs))
          : Self.time(player.positionMs)
      ).frame(width: 40).onTapGesture { timeFormat = (timeFormat + 1) % 3 }.accessibilityIdentifier(
        "native.player.position")
      NativePlayerSeekSlider(player: player).frame(height: 32)
      Text(
        timeFormat == 2
          ? "−" + Self.time(max(0, player.durationMs - player.positionMs))
          : Self.time(player.durationMs)
      ).frame(width: 40).onTapGesture { timeFormat = (timeFormat + 1) % 3 }
    }.font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
  }

  /// 系统控件保留播放、加载及暂停状态，不用装饰动画代替真实状态
  private func playButton(apple: Bool) -> some View {
    Button(action: player.togglePlayback) {
      Group {
        if player.loadingTrack != nil {
          ProgressView()
        } else {
          Image(
            systemName: player.isPlaying
              ? (apple ? "pause.fill" : "pause") : (apple ? "play.fill" : "play")
          ).font(.system(size: apple ? 44 : 24))
        }
      }.frame(width: apple ? 72 : 48, height: apple ? 72 : 48)
        .background(apple ? Color.clear : .white.opacity(0.14), in: Circle())
    }.accessibilityLabel(player.isPlaying ? "暂停" : "播放").accessibilityIdentifier(
      "native.player.playPause")
  }

  private var lyricsToggle: some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
        showLyrics.toggle()
        queuePanel = false
      }
    } label: {
      Image(systemName: style == "original" ? "text.quote" : "quote.bubble").frame(
        width: 44, height: 44
      ).contentShape(Rectangle())
    }.disabled(style == "original" && (coverLayout == "fullscreen" || player.lyrics.isEmpty))
      .accessibilityLabel("歌词")
      .accessibilityIdentifier("native.player.lyricsToggle")
      .opacity(style == "original" && !showLyrics ? 0.4 : 1)
      .background(
        style == "am" && showLyrics ? Color.white.opacity(0.14) : .clear,
        in: RoundedRectangle(cornerRadius: 12))
  }
  /// 与原版同一槽位：FM 为不喜欢，心动模式为退出心动，其余为随机/顺序
  private var shuffleButton: some View {
    Button {
      if player.fmMode {
        player.dislikeFM()
      } else if player.heartMode {
        player.exitHeartMode()
      } else {
        player.shuffle.toggle()
      }
    } label: {
      Image(
        systemName: player.fmMode
          ? "heart.slash" : player.heartMode
            ? "heart.circle.fill" : player.shuffle ? "shuffle" : "arrow.right"
      ).frame(width: 44, height: 44)
    }.accessibilityLabel(player.fmMode ? "不喜欢" : player.heartMode ? "退出心动模式" : "随机播放")
      .accessibilityValue(player.shuffle ? "开启" : "关闭")
      .accessibilityIdentifier("native.player.shuffleSlot")
  }
  private var repeatButton: some View {
    Button {
      player.repeatOne.toggle()
    } label: {
      Image(systemName: player.fmMode ? "infinity" : player.repeatOne ? "repeat.1" : "repeat")
        .frame(width: 44, height: 44)
    }.accessibilityLabel("单曲循环").accessibilityValue(player.repeatOne ? "开启" : "关闭")
      .disabled(player.fmMode).opacity(player.fmMode ? 0.4 : 1)
  }
  private var queueButton: some View {
    Button {
      if player.fmMode {
        fmModes = true
      } else if style == "am" {
        withAnimation(.easeInOut(duration: 0.3)) {
          queuePanel.toggle()
          showLyrics = false
        }
      } else {
        showQueue = true
      }
    } label: {
      Image(systemName: player.fmMode ? "dot.radiowaves.left.and.right" : "list.bullet")
        .frame(width: 44, height: 44)
    }.accessibilityLabel(player.fmMode ? "FM 模式与场景" : "播放队列")
      .accessibilityIdentifier("native.player.queueButton")
  }
  /// AM 队列在同一详情舞台中展开，歌曲选择、移除和重排沿用真实队列
  private var inlineQueue: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("接下来播放").font(.title2.bold())
      List {
        ForEach(player.queue) { track in
          Button {
            player.play(track)
          } label: {
            NativeTrackRow(track: track, selected: player.current?.id == track.id)
          }.buttonStyle(.plain).listRowBackground(Color.clear)
        }.onMove(perform: player.moveQueue).onDelete(perform: player.removeQueue)
      }.listStyle(.plain).scrollContentBackground(.hidden)
    }.accessibilityIdentifier("native.player.queuePanel")
  }
  private var volumeButton: some View {
    Button {
      showVolume = true
    } label: {
      Image(systemName: "speaker.wave.2").frame(width: 44, height: 44)
    }.accessibilityLabel("播放器音量")
      .popover(isPresented: $showVolume) {
        #if os(iOS)
          NativeVolumeSlider().frame(width: 240, height: 44).padding(24)
        #endif
      }
  }
  private var route: some View {
    Group {
      #if os(iOS)
        NativeRoutePicker().frame(width: 44, height: 44)
      #else
        Color.clear.frame(width: 44, height: 44)
      #endif
    }
  }
  private var options: some View {
    Menu {
      ForEach([NativePlaybackTool.equalizer, .speed, .ab, .sleep, .offset]) { tool in
        Button(tool.rawValue) { selectedTool = tool }
      }
      Menu("添加到歌单") {
        ForEach(player.playlists) { playlist in
          Button(playlist.name) {
            if let track = player.current { player.addToPlaylist(playlist.id, track: track) }
          }
        }
      }.disabled(player.playlists.isEmpty || player.current == nil)
      Button("复制歌词") { selectedTool = .copy }.disabled(player.lyrics.isEmpty)
      if NativeLyricPiP.supported { NativePiPMenuButton(pip: player.lyricPiP) }
      Button("导入歌词") { importLyrics = true }
      Button("喜欢 / 取消喜欢") { if let track = player.current { player.toggleFavorite(track) } }
      if downloadEnabled, let track = player.current, track.source != nil,
        track.source != "plugin"
      {
        Button("下载歌曲") { player.download(track) }
      }
      Button("播放队列") { showQueue = true }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 22)).frame(width: 44, height: 44)
    }.accessibilityLabel("播放器选项")
  }

  /// 封面播放态缩放不改变布局占位
  private func artwork(radius: CGFloat) -> some View {
    NativeArtwork(cover: player.current?.cover, radius: radius, pixels: 1000, preview: 300)
      .nativeCoverAnchor("player.full", radius: radius)
      .shadow(color: .black.opacity(0.15), radius: 20)
      .scaleEffect(player.isPlaying ? 1 : 0.9)
      .animation(
        reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72), value: player.isPlaying)
  }
  /// 两种播放器分别使用原版的自适应歌词字号
  private func lyrics(fontSize: CGFloat) -> some View {
    NativeLyricsView(
      player: player, importLyrics: { importLyrics = true }, fontSize: fontSize,
      foreground: foreground)
  }
}

#if os(iOS)
  struct NativeRoutePicker: UIViewRepresentable {
    /// 创建系统原生控件并配置初始外观
    func makeUIView(context: Context) -> AVRoutePickerView {
      let view = AVRoutePickerView()
      view.tintColor = .label
      return view
    }
    /// 仅同步绑定状态，不重建系统控件
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
  }
  struct NativeVolumeSlider: UIViewRepresentable {
    /// 创建系统原生控件并配置初始外观
    func makeUIView(context: Context) -> MPVolumeView {
      let view = MPVolumeView()
      view.showsRouteButton = false
      return view
    }
    /// 仅同步绑定状态，不重建系统控件
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
  }
#endif
