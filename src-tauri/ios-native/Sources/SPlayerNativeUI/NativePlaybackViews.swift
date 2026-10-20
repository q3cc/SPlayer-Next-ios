import SwiftUI

@MainActor
struct NativePlaybackBar: View {
  @ObservedObject var player: NativePlayerStore
  let wide: Bool
  let showPlayer: () -> Void
  let showQueue: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        Rectangle().fill(Color.primary.opacity(0.12))
          .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.6)).frame(
              width: geometry.size.width * player.progress)
          }
      }.frame(height: 2)
      HStack(spacing: 16) {
        Button(action: showPlayer) {
          HStack(spacing: 12) {
            NativeArtwork(cover: player.current?.cover).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
              Text(player.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
              Text(player.loadingTrack == nil ? player.artist : "正在解析音源…").font(.system(size: 12))
                .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
          }.frame(maxWidth: wide ? 280 : .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("native.wide.nowPlaying")
        Spacer(minLength: 0)
        HStack(spacing: 4) {
          Button(action: showQueue) {
            Image(systemName: "list.bullet").frame(width: 40, height: 44)
          }.accessibilityLabel("播放队列")
          Button(action: player.previous) {
            Image(systemName: "backward.end").frame(width: 40, height: 44)
          }.accessibilityLabel("上一首")
          Button(action: player.togglePlayback) {
            Group {
              if player.loadingTrack != nil {
                ProgressView()
              } else {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(
                  .system(size: 21))
              }
            }
            .frame(width: 44, height: 44).background(Color.primary.opacity(0.10), in: Circle())
          }.accessibilityLabel(player.isPlaying ? "暂停" : "播放").accessibilityIdentifier(
            "native.wide.playPause")
          Button(action: player.next) {
            Image(systemName: "forward.end").frame(width: 40, height: 44)
          }.accessibilityLabel("下一首")
          if wide {
            Button {
              player.repeatOne.toggle()
            } label: {
              Image(systemName: player.repeatOne ? "repeat.1" : "repeat").frame(
                width: 40, height: 44)
            }.accessibilityLabel("单曲循环")
          }
        }.buttonStyle(.plain).font(.system(size: 18))
        if wide {
          Spacer(minLength: 0)
          VStack(spacing: 0) {
            Text(
              NativeNowPlayingView.time(player.positionMs) + " / "
                + NativeNowPlayingView.time(player.durationMs)
            ).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            NativeSeekSlider(player: player)
          }.frame(width: 150)
          #if os(iOS)
            NativeRoutePicker().frame(width: 40, height: 40)
          #endif
        }
      }.padding(.horizontal, 16).frame(height: wide ? 78 : 70)
    }.clipShape(RoundedRectangle(cornerRadius: 24))
      .nativeGlass(in: RoundedRectangle(cornerRadius: 24), interactive: false)
      .padding(.horizontal, 12).padding(.vertical, 6)
      .accessibilityElement(children: .contain).accessibilityIdentifier("native.wide.playerbar")
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
