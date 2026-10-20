import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import AVKit
  import MediaPlayer
#endif

@MainActor
struct NativeNowPlayingView: View {
  @ObservedObject var player: NativePlayerStore
  @Environment(\.dismiss) private var dismiss
  @State private var showLyrics = false
  @State private var importLyrics = false
  @State private var showQueue = false

  /// 时间统一以毫秒输入，界面显示分秒
  static func time(_ milliseconds: Double) -> String {
    let seconds = milliseconds.isFinite ? Int(max(0, milliseconds / 1000)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
  var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width > geometry.size.height
      ZStack {
        NativeAmbientBackground(cover: player.current?.cover, playing: player.isPlaying)
        VStack(spacing: 0) {
          HStack {
            Button {
              dismiss()
            } label: {
              Image(systemName: "chevron.down").font(.system(size: 22)).frame(width: 48, height: 48)
                .nativeGlass(in: Circle())
            }.accessibilityLabel("收起播放器")
            Spacer()
            Text("正在播放").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Menu {
              Button("导入歌词") { importLyrics = true }
              Button("喜欢 / 取消喜欢") {
                if let current = player.current { player.toggleFavorite(current) }
              }
              Button("播放队列") { showQueue = true }
            } label: {
              Image(systemName: "ellipsis").font(.system(size: 22)).frame(width: 48, height: 48)
                .nativeGlass(in: Circle())
            }
          }.padding(.horizontal, 20)
          if wide {
            HStack(spacing: 64) {
              albumControls(showArtwork: true).frame(maxWidth: 430)
              lyrics.frame(maxWidth: .infinity)
            }.padding(.horizontal, 64).padding(.vertical, 30).frame(maxWidth: 1400).frame(
              maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              VStack(spacing: 24) {
                if showLyrics { lyrics.frame(height: max(300, geometry.size.height * 0.55)) }
                albumControls(showArtwork: !showLyrics)
              }.padding(.horizontal, max(24, (geometry.size.width - 500) / 2)).padding(
                .vertical, 24)
            }
          }
        }
      }
    }.preferredColorScheme(.dark).tint(.white)
      .alert(
        "播放失败",
        isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })
      ) {
        Button("好") { player.error = nil }
      } message: {
        Text(player.error ?? "")
      }
      .sheet(isPresented: $showQueue) { NativeQueueView(player: player) }
      .fileImporter(
        isPresented: $importLyrics,
        allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
      ) { result in
        switch result {
        case .success(let url): Task { await player.importLyrics(url) }
        case .failure(let error): player.error = error.localizedDescription
        }
      }
  }

  /// 横屏固定保留封面，竖屏歌词模式给歌词让出空间
  private func albumControls(showArtwork: Bool) -> some View {
    VStack(spacing: 24) {
      if showArtwork {
        NativeArtwork(cover: player.current?.cover, radius: 16, pixels: 1000)
          .aspectRatio(1, contentMode: .fit).shadow(color: .black.opacity(0.25), radius: 24, y: 12)
      }
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text(player.title).font(.system(size: 24, weight: .bold)).lineLimit(2)
            .accessibilityIdentifier("native.player.title")
          Text(player.artist).font(.system(size: 16)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Button {
          if let current = player.current { player.toggleFavorite(current) }
        } label: {
          Image(
            systemName: player.favoriteTracks.contains(where: { $0.id == player.current?.id })
              ? "heart.fill" : "heart"
          ).font(.system(size: 22)).frame(width: 44, height: 44)
        }.accessibilityLabel("喜欢")
      }
      VStack(spacing: 0) {
        NativeSeekSlider(player: player)
        HStack {
          Text(Self.time(player.positionMs)).accessibilityIdentifier("native.player.position")
          Spacer()
          Text(Self.time(player.durationMs))
        }.font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
      }
      HStack(spacing: 40) {
        Button(action: player.previous) {
          Image(systemName: "backward.end.fill").frame(width: 48, height: 48)
        }.accessibilityLabel("上一首")
        Button(action: player.togglePlayback) {
          Group {
            if player.loadingTrack != nil {
              ProgressView()
            } else {
              Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(
                .system(size: 44))
            }
          }.frame(width: 72, height: 72)
        }.accessibilityLabel(player.isPlaying ? "暂停" : "播放").accessibilityIdentifier(
          "native.player.playPause")
        Button(action: player.next) {
          Image(systemName: "forward.end.fill").frame(width: 48, height: 48)
        }.accessibilityLabel("下一首")
      }.font(.system(size: 26)).buttonStyle(.plain)
      #if os(iOS)
        NativeVolumeSlider().frame(height: 32)
      #endif
      HStack {
        Button {
          showLyrics.toggle()
        } label: {
          Image(systemName: "quote.bubble").frame(width: 44, height: 44)
        }.accessibilityLabel("歌词")
        Spacer()
        #if os(iOS)
          NativeRoutePicker().frame(width: 44, height: 44)
        #endif
        Spacer()
        Button {
          showQueue = true
        } label: {
          Image(systemName: "list.bullet").frame(width: 44, height: 44)
        }.accessibilityLabel("播放队列")
      }.font(.system(size: 20)).buttonStyle(.plain)
    }
  }

  private var lyrics: some View {
    NativeLyricsView(player: player, importLyrics: { importLyrics = true })
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
