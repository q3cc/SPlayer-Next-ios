import SwiftUI

@MainActor
struct NativeHomeView: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var catalog: NativeCatalogStore
  @ObservedObject var stats: NativePlayStats
  let openPlaylist: (NativeCover) -> Void
  let importMusic: () -> Void
  /// 每次进入首页随机挑一条副标题，与原版 useHomeHeader 一致
  @State private var subtitle = NativeHomeView.plainSubtitles[0]
  private static let plainSubtitles = ["愿今天有好音乐与你相伴", "戴上耳机，让世界安静一会儿", "音乐已就绪，挑一首开始吧"]
  /// 最高播放次数达到此值才呈现为“反复聆听”
  private static let repeatThreshold = 2

  private var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    return hour < 6
      ? "凌晨好" : hour < 12 ? "早上好" : hour < 14 ? "中午好" : hour < 18 ? "下午好" : "晚上好"
  }
  private var summary: NativePlayStatsSummary { stats.homeSnapshot().summary }
  private var continueItems: [NativeRankItem] { stats.homeSnapshot().top }
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
              Text(greeting).font(.system(size: 30, weight: .bold))
              Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if geometry.size.width > 600 {
              let summary = summary
              metric(String(format: "%.1f", summary.weekListenedMs / 3_600_000), "h", "本周时长")
              metric("\(summary.weekFavoriteAdds)", "首", "新增收藏")
              metric("\(summary.streakDays)", "天", "连续收听")
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
            action("心动模式", "根据喜好智能播放", "heart.circle") {
              Task { await player.startHeartMode() }
            }
            action("私人 FM", "为你不停推荐", "dot.radiowaves.left.and.right") {
              if player.fmMode {
                player.error = "已处于私人 FM"
              } else {
                Task {
                  if !(await player.startFM()), player.error == nil {
                    player.error = "私人 FM 开启失败，请稍后重试"
                  }
                }
              }
            }
          }
          continueSection(wide: geometry.size.width >= 1280)
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
                      .nativeCoverAnchor("cover." + cover.id, radius: 12)
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
    }.task { subtitle = pickSubtitle() }
  }

  /// 副标题候选池：数据不足的条目不入池，纯问候恒在
  private func pickSubtitle() -> String {
    let data = summary
    var pool = Self.plainSubtitles
    if data.streakDays >= 2 { pool.append("你已连续收听 \(data.streakDays) 天，继续保持") }
    if data.weekListenedMs > 0 {
      pool.append("本周已经听了 " + Self.duration(data.weekListenedMs))
      let diff = data.weekListenedMs - data.lastWeekListenedMs
      if data.lastWeekListenedMs > 0 && abs(diff) >= 60000 {
        pool.append("本周比上周\(diff > 0 ? "多" : "少")听了 " + Self.duration(abs(diff)))
      }
    }
    if data.weekFavoriteAdds > 0 { pool.append("本周新收藏了 \(data.weekFavoriteAdds) 首歌") }
    if !player.history.isEmpty {
      pool.append("今天想听点什么？继续上次的 \(player.history.count) 首最近播放吧")
    }
    return pool.randomElement() ?? Self.plainSubtitles[0]
  }

  /// 时长格式化：X 小时 Y 分钟
  static func duration(_ ms: Double) -> String {
    let minutes = Int((ms / 60000).rounded())
    if minutes >= 60 && minutes % 60 > 0 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
    if minutes >= 60 { return "\(minutes / 60) 小时" }
    return "\(minutes) 分钟"
  }

  /// 反复聆听 / 继续聆听：取最常播放曲目，次数都低时等价于最近在听
  private func continueSection(wide: Bool) -> some View {
    let items = continueItems
    let repeating = (items.first?.plays ?? 0) >= Self.repeatThreshold
    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(repeating ? "反复聆听" : "继续聆听").font(.system(size: 18, weight: .semibold))
        if !items.isEmpty {
          Text(repeating ? "你最常听的 \(items.count) 首歌" : "你最近在听的 \(items.count) 首歌")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
      if items.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "headphones").font(.system(size: 28))
          Text("还没有播放记录，去听点什么吧").font(.system(size: 14))
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
          .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
              .foregroundStyle(Color.primary.opacity(0.12)))
      } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button {
              player.playNow(item.track)
            } label: {
              HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                  .foregroundStyle(.tertiary).frame(width: 20)
                NativeArtwork(cover: item.track.cover).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.track.title).font(.system(size: 14)).lineLimit(1)
                  Text(item.track.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if wide {
                  Text("播放 \(item.plays) 次").font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }.padding(12).background(Color.nativePanel, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("native.home.continue." + item.track.id)
          }
        }
      }
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
