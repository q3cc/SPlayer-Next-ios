import SwiftUI

/// 底部播放栏：宽布局为原版 80 高通栏（左歌曲信息、中控制、右时间与工具），紧凑布局为 72 高迷你栏
@MainActor
struct NativePlaybackBar: View {
  @ObservedObject var player: NativePlayerStore
  let wide: Bool
  /// 上游 dev 窗口 <1024 时的紧凑排布：控制组在左，中间是歌曲信息与进度条
  let compact: Bool
  let showPlayer: () -> Void
  let showQueue: () -> Void
  @AppStorage("native.player.lyricInBar") private var lyricInBar = true
  @AppStorage("native.download.enabled") private var downloadEnabled = false
  @State private var fmModes = false
  @State private var tool: NativePlaybackTool?
  /// 加载中提示解析状态；播放时可按设置用当前歌词替换歌手名
  private var subtitle: String {
    if player.loadingTrack != nil { return "正在解析音源…" }
    if lyricInBar, player.isPlaying, let line = player.currentLyric, !line.text.isEmpty {
      return line.text
    }
    return player.artist
  }
  var body: some View {
    Group {
      if full {
        HStack(spacing: 12) {
          trackInfo.frame(maxWidth: .infinity, alignment: .leading)
          controls(compact: false).padding(.horizontal, 60)
          HStack(spacing: 8) {
            time
            toolbar
          }.frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 12).frame(height: 80)
      } else if wide {
        HStack(spacing: 16) {
          controls(compact: true)
          VStack(spacing: 4) {
            HStack(spacing: 8) {
              trackInfo.frame(maxWidth: .infinity, alignment: .leading)
              time
            }
            // 触控区保持 32，只占 12 的布局高度
            NativeBarProgress(player: player, thumb: 10).padding(.vertical, -10)
          }.padding(.top, 8).padding(.bottom, 4)
          toolbar
        }.padding(.horizontal, 16).frame(height: 80)
      } else {
        HStack(spacing: 8) {
          trackInfo
          controls(compact: true)
        }.padding(.horizontal, 12).frame(height: 72)
      }
    }
    .background {
      Rectangle().fill(.clear).nativeGlass(in: Rectangle(), interactive: false)
        .ignoresSafeArea(edges: .bottom)
    }
    .overlay(alignment: .top) {
      Rectangle().fill(Color.nativePrimary.opacity(0.1)).frame(height: 1)
    }
    // 进度条骑在上边线；紧凑排布的进度条在中间列
    .overlay(alignment: .top) {
      if !wide || full { NativeBarProgress(player: player, thumb: wide ? 12 : 10).offset(y: -16) }
    }
    .accessibilityElement(children: .contain).accessibilityIdentifier("native.wide.playerbar")
    .sheet(isPresented: $fmModes) { NativeFMModeView(player: player) }
    .sheet(item: $tool) { NativePlaybackTools(player: player, tool: $0) }
  }

  /// 默认通栏排布：宽布局且窗口不小于 1024
  private var full: Bool { wide && !compact }

  /// 时间文字：12 号等宽数字，on-surface-variant
  private var time: some View {
    Text(
      NativeNowPlayingView.time(player.positionMs) + " / "
        + NativeNowPlayingView.time(player.durationMs)
    ).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.nativeOnSurfaceVariant)
      .padding(.horizontal, 6).padding(.vertical, 2)
  }

  /// 封面、标题与第二行；宽布局标题后带喜欢和更多（紧凑排布 24，默认 28）
  private var trackInfo: some View {
    HStack(spacing: full ? 12 : 8) {
      Button(action: showPlayer) {
        HStack(spacing: full ? 12 : 8) {
          NativeArtwork(cover: player.current?.cover, radius: 8)
            .frame(width: full ? 56 : 40, height: full ? 56 : 40)
            .shadow(color: .black.opacity(full ? 0 : 0.05), radius: 1, y: 1)
            .nativeCoverAnchor("player.bar", radius: 8)
          VStack(alignment: .leading, spacing: full ? 4 : 2) {
            Text(player.title)
              .font(.system(size: full ? 16 : 14, weight: full ? .bold : .medium)).lineLimit(1)
              .foregroundStyle(Color.nativeOnSurface)
            Text(subtitle).font(.system(size: full ? 14 : 12))
              .foregroundStyle(Color.nativeOnSurfaceVariant).lineLimit(1)
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("native.wide.nowPlaying")
      if wide, let track = player.current {
        HStack(spacing: 0) {
          NativeSButton(
            icon: player.isFavorite(track) ? "heart.fill" : "heart", variant: .text,
            tint: .primary, size: .custom(full ? 28 : 24), shape: .circle
          ) { player.toggleFavorite(track) }.accessibilityLabel("喜欢")
          Menu {
            Menu("添加到歌单") {
              ForEach(player.playlists) { playlist in
                Button(playlist.name) { player.addToPlaylist(playlist.id, track: track) }
              }
            }.disabled(player.playlists.isEmpty)
            if downloadEnabled, track.source != nil, track.source != "plugin" {
              Button("下载歌曲") { player.download(track) }
            }
            Button("复制歌词") { tool = .copy }.disabled(player.lyrics.isEmpty)
          } label: {
            Image(systemName: "ellipsis").font(.system(size: full ? 16 : 14))
              .frame(width: full ? 28 : 24, height: full ? 28 : 24)
              .foregroundStyle(Color.nativePrimary).contentShape(Circle())
          }.accessibilityLabel("更多")
        }
      }
      if !wide { Spacer(minLength: 0) }
    }
  }

  /// 原版控制组：宽 38/38/44/38/38 间距 10，紧凑 32/34/40/34/32 无间距；播放键为 primary secondary
  private func controls(compact: Bool) -> some View {
    let side: NativeButtonSize = .custom(compact ? 32 : 38)
    let skip: NativeButtonSize = .custom(compact ? 34 : 38)
    return HStack(spacing: compact ? 0 : 10) {
      if player.fmMode {
        NativeSButton(icon: "heart.slash", variant: .ghost, tint: .primary, size: side, shape: .circle) {
          player.dislikeFM()
        }.accessibilityLabel("不喜欢").accessibilityIdentifier("native.bar.fmTrash")
      } else if player.heartMode {
        NativeSButton(
          icon: "heart.circle.fill", variant: .ghost, tint: .primary, size: side, shape: .circle
        ) { player.exitHeartMode() }.accessibilityLabel("退出心动模式")
      } else {
        NativeSButton(
          icon: player.shuffle ? "shuffle" : "arrow.right", variant: .ghost, tint: .primary,
          size: side, shape: .circle
        ) { player.shuffle.toggle() }.accessibilityLabel("随机播放")
      }
      NativeSButton(
        icon: "backward.end.fill", variant: .ghost, tint: .primary, size: skip, shape: .circle,
        action: player.previous
      ).accessibilityLabel("上一首").disabled(player.fmMode)
      Button(action: player.togglePlayback) {
        Group {
          if player.loadingTrack != nil {
            ProgressView().tint(Color.nativePrimary)
          } else {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: compact ? 20 : 22))
          }
        }
      }.buttonStyle(
        NativeButtonStyle(
          variant: .secondary, tint: .primary, size: .custom(compact ? 40 : 44), shape: .circle)
      ).padding(.horizontal, compact ? 2 : 4)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
        .accessibilityIdentifier("native.wide.playPause")
      NativeSButton(
        icon: "forward.end.fill", variant: .ghost, tint: .primary, size: skip, shape: .circle,
        action: player.next
      ).accessibilityLabel("下一首")
      NativeSButton(
        icon: player.fmMode ? "infinity" : player.repeatOne ? "repeat.1" : "repeat",
        variant: .ghost, tint: .primary, size: side, shape: .circle
      ) { player.repeatOne.toggle() }.accessibilityLabel("单曲循环").disabled(player.fmMode)
    }
  }

  /// 右侧工具栏：40 ghost 圆形按钮，on-surface-variant 色
  private var toolbar: some View {
    HStack(spacing: 4) {
      #if os(iOS)
        NativeRoutePicker().frame(width: 40, height: 40)
      #endif
      if player.fmMode {
        NativeSButton(
          icon: "dot.radiowaves.left.and.right", variant: .ghost, size: .large, shape: .circle
        ) { fmModes = true }.accessibilityLabel("FM 模式与场景")
      } else {
        NativeSButton(icon: "list.bullet", variant: .ghost, size: .large, shape: .circle, action: showQueue)
          .accessibilityLabel("播放队列")
      }
      Menu {
        ForEach([NativePlaybackTool.equalizer, .speed, .ab, .sleep]) { item in
          Button(item.rawValue) { tool = item }
        }
      } label: {
        Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 20))
          .frame(width: 40, height: 40).contentShape(Circle())
      }.accessibilityLabel("更多")
    }.foregroundStyle(Color.nativeOnSurfaceVariant)
  }
}

/// 播放栏顶边进度：轨道 3，primary 填充，拖动时显示拇指并跳转
@MainActor
struct NativeBarProgress: View {
  @ObservedObject var player: NativePlayerStore
  var thumb: CGFloat = 12
  @State private var dragging: Double?

  var body: some View {
    GeometryReader { geometry in
      let value = dragging ?? player.progress
      ZStack(alignment: .leading) {
        Capsule().fill(Color.nativeOnSurface.opacity(0.12)).frame(height: 3)
        Capsule().fill(Color.nativePrimary).frame(width: geometry.size.width * value, height: 3)
        if dragging != nil {
          Circle().fill(Color.nativePrimary).frame(width: thumb, height: thumb)
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .offset(x: geometry.size.width * value - thumb / 2)
        }
      }.frame(height: 32).contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { drag in
            dragging = min(1, max(0, drag.location.x / max(1, geometry.size.width)))
          }.onEnded { _ in
            if let dragging { player.seek(to: dragging * player.durationMs) }
            dragging = nil
          })
    }.frame(height: 32).disabled(player.current == nil)
      .accessibilityElement().accessibilityLabel("播放进度")
      .accessibilityValue(NativeNowPlayingView.time(player.positionMs))
  }
}

@MainActor
struct NativeSeekSlider: View {
  @ObservedObject var player: NativePlayerStore
  @State private var editing = false
  @State private var value = 0.0
  var body: some View {
    Slider(
      value: Binding(
        get: { editing ? value : min(player.positionMs, max(1, player.durationMs)) },
        set: { value = $0 }), in: 0...max(1, player.durationMs)
    ) { active in
      if active { value = player.positionMs }
      editing = active
      if !active { player.seek(to: value) }
    }.disabled(player.current == nil).accessibilityLabel("播放进度")
  }
}

@MainActor
struct NativeQueueView: View {
  @ObservedObject var player: NativePlayerStore
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        if player.queue.isEmpty { Text("播放队列为空").foregroundStyle(.secondary) }
        ForEach(player.queue) { track in
          Button {
            player.play(track)
          } label: {
            NativeTrackRow(track: track, selected: player.current?.id == track.id)
          }.buttonStyle(.plain)
        }.onMove(perform: player.moveQueue).onDelete(perform: player.removeQueue)
      }.navigationTitle("播放队列 · \(player.queue.count)")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
          #if os(iOS)
            ToolbarItem(placement: .primaryAction) { EditButton() }
          #endif
        }
    }.tint(.primary)
  }
}
