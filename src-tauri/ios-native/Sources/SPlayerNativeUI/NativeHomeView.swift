import SwiftUI

@MainActor
struct NativeHomeView: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var catalog: NativeCatalogStore
  let openPlaylist: (NativeCover) -> Void
  let importMusic: () -> Void
  private var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    return hour < 6 ? "凌晨好" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
  }
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
              Text(greeting).font(.system(size: 30, weight: .bold))
              Text(
                player.history.isEmpty
                  ? "今天想听点什么？发现属于你的音乐" : "今天想听点什么？继续上次的 \(player.history.count) 首最近播放吧"
              )
              .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if geometry.size.width > 600 {
              metric("\(player.tracks.count)", "首", "本地歌曲")
              metric("\(player.favoriteTracks.count)", "首", "喜欢的音乐")
              metric("\(player.history.count)", "首", "最近听过")
            }
          }
          LazyVGrid(
            columns: Array(
              repeating: GridItem(.flexible(), spacing: 12),
              count: geometry.size.width > 700 ? 4 : 2), spacing: 12
          ) {
            action("试试手气", "随机播放一首", "dice") {
              if let track = (player.tracks + player.history).randomElement() {
                player.play(track)
              } else {
                importMusic()
              }
            }
            action("每日推荐", "每天为你精选", "calendar") { loadSpecial("daily") }
            action("心动模式", "播放喜欢的音乐", "heart.circle") {
              if let track = player.favoriteTracks.randomElement() {
                player.play(track, in: player.favoriteTracks)
              } else {
                player.error = "先收藏喜欢的歌曲，再开启心动模式"
              }
            }
            action("私人 FM", "为你不停推荐", "dot.radiowaves.left.and.right") { loadSpecial("fm") }
          }
          VStack(alignment: .leading, spacing: 16) {
            Text("继续聆听").font(.system(size: 18, weight: .semibold))
            if player.history.isEmpty {
              VStack(spacing: 12) {
                Image(systemName: "headphones").font(.system(size: 28))
                Text("还没有播放记录，去听点什么吧").font(.system(size: 14))
              }.foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 136)
                .overlay(
                  RoundedRectangle(cornerRadius: 14).stroke(
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                  ).foregroundStyle(Color.primary.opacity(0.12)))
            } else {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach(Array(player.history.prefix(6))) { track in
                  Button {
                    player.play(track, in: player.history)
                  } label: {
                    NativeTrackRow(track: track, selected: player.current?.id == track.id).padding(
                      .horizontal, 12)
                  }
                  .buttonStyle(.plain).background(
                    Color.nativePanel, in: RoundedRectangle(cornerRadius: 12))
                }
              }
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Text("推荐歌单").font(.system(size: 18, weight: .semibold))
              Text("大家都在听的热门歌单").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if catalog.loadingHome {
              ProgressView("正在加载推荐…").frame(maxWidth: .infinity).padding(40)
            }
            if let error = catalog.error, catalog.recommendations.isEmpty {
              Text(error).font(.callout).foregroundStyle(.secondary)
              Button("重试") { Task { await catalog.loadHome() } }.buttonStyle(.bordered)
            }
            let columns = max(2, Int((geometry.size.width - 48 + 16) / 156))
            LazyVGrid(
              columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns),
              alignment: .leading, spacing: 24
            ) {
              ForEach(catalog.recommendations) { cover in
                Button {
                  openPlaylist(cover)
                } label: {
                  VStack(alignment: .leading, spacing: 10) {
                    NativeArtwork(cover: cover.cover, radius: 12).aspectRatio(1, contentMode: .fit)
                    Text(cover.title).font(.system(size: 14, weight: .medium)).lineLimit(2).frame(
                      height: 38, alignment: .topLeading)
                    if let subtitle = cover.subtitle {
                      Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("native.recommend." + cover.id)
                  .contextMenu {
                    Button(
                      player.bookmarks.contains(where: { $0.id == cover.id }) ? "取消收藏歌单" : "收藏歌单"
                    ) { player.toggleBookmark(cover) }
                  }
              }
            }
          }
          Button(action: importMusic) { Label("导入本地音乐", systemImage: "plus") }.buttonStyle(
            .bordered
          ).accessibilityIdentifier("native.import.home")
        }.padding(24).frame(maxWidth: 1400).frame(maxWidth: .infinity)
      }.refreshable { await catalog.loadHome(refresh: true) }
    }
  }
  /// 以数值、单位和标签保持统计项的视觉层级
  private func metric(_ value: String, _ unit: String, _ label: String) -> some View {
    VStack(alignment: .trailing, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value).font(.system(size: 24, weight: .bold))
        Text(unit).font(.system(size: 14)).foregroundStyle(.secondary)
      }
      Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }
  /// 生成首页快捷操作，保留图标、标题与辅助说明
  private func action(
    _ title: String, _ subtitle: String, _ icon: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 20)).frame(width: 36, height: 36).background(
          Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.system(size: 14, weight: .medium))
          Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }.padding(12).frame(maxWidth: .infinity).background(
        Color.nativePanel, in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }.buttonStyle(.plain)
  }
  /// 推荐操作使用平台真实结果，不用本地随机曲目伪装在线推荐
  private func loadSpecial(_ action: String) {
    Task {
      do {
        let values = try await player.service.call(["action": action]) as? [[String: Any]] ?? []
        let tracks = values.compactMap(NativeTrack.online)
        guard let first = tracks.first else { throw SiriFailure("请先在平台登录后使用此推荐功能") }
        player.play(first, in: tracks)
      } catch { player.error = error.localizedDescription }
    }
  }
}
