import SwiftUI

@MainActor
struct NativeHomeView: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var catalog: NativeCatalogStore
  @ObservedObject var stats: NativePlayStats
  @ObservedObject var account: NativeAccountStore
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
  @State private var hero: NativeHomeHero?
  @Environment(\.nativeViewport) private var viewport
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .top, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            // 登录后与原版一致附上昵称：“晚上好，昵称”
            Text(account.account.map { greeting + "，" + $0.nickname } ?? greeting)
              .font(.system(size: 30, weight: .bold)).foregroundStyle(Color.nativeOnSurface)
              .lineLimit(1)
            Text(subtitle).font(.system(size: 14))
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
          }
          Spacer(minLength: 0)
          let summary = summary
          HStack(spacing: 24) {
            metric(String(format: "%.1f", summary.weekListenedMs / 3_600_000), "h", "本周时长")
            metric("\(summary.weekFavoriteAdds)", "首", "新增收藏")
            metric("\(summary.streakDays)", "天", "连续收听")
          }
        }
        if let hero { heroCard(hero).padding(.bottom, -12) }
        HStack(spacing: 12) {
          action("试试手气", "随机播放一首", "dice") {
            if let track = (player.tracks + player.history).randomElement() {
              player.play(track)
            } else {
              player.error = "曲库里还没有歌曲"
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
        continueSection
        let loggedIn = account.account != nil
        VStack(alignment: .leading, spacing: 12) {
          NativeSectionTitle(
            title: loggedIn ? "专属歌单" : "推荐歌单",
            subtitle: loggedIn ? "为你量身定制的歌单精选" : "大家都在听的热门歌单")
          if catalog.loadingHome && catalog.recommendations.isEmpty {
            ProgressView().tint(Color.nativePrimary).frame(maxWidth: .infinity).padding(40)
          }
          if let error = catalog.error, catalog.recommendations.isEmpty {
            NativeEmptyState(icon: "exclamationmark.triangle", text: error) {
              NativeSButton(title: "重试", variant: .secondary, tint: .primary, shape: .round) {
                Task { await catalog.loadHome(loggedIn: loggedIn, refresh: true) }
              }
            }
          }
          coverGrid(catalog.recommendations)
        }
        if loggedIn && !catalog.radar.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            NativeSectionTitle(title: "雷达歌单", subtitle: "持续推荐符合你的音乐口味")
            coverGrid(catalog.radar)
          }
        }
      }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 40)
        .frame(maxWidth: 1400).frame(maxWidth: .infinity)
    }.refreshable {
      await account.refresh()
      await catalog.loadHome(loggedIn: account.account != nil, refresh: true)
    }
    .task { subtitle = pickSubtitle() }
    // 登录或退出后首页切换为专属歌单 / 推荐歌单
    .task(id: account.account?.userId) {
      await catalog.loadHome(loggedIn: account.account != nil)
      await loadHero()
    }
  }

  /// 歌单卡片网格（间距 16）；长按可收藏到“我的收藏”
  private func coverGrid(_ covers: [NativeCover]) -> some View {
    NativeCoverGrid(spacing: 16) {
      ForEach(covers) { cover in
        NativeCoverCard(
          cover: cover.cover, title: cover.title, subtitle: cover.subtitle,
          anchor: "cover." + cover.id
        ) { openPlaylist(cover) }
          .accessibilityIdentifier("native.recommend." + cover.id)
          .contextMenu {
            Button(
              player.bookmarks.contains(where: { $0.id == cover.id }) ? "取消收藏歌单" : "收藏歌单"
            ) { player.toggleBookmark(cover) }
          }
      }
    }
  }

  /// 原版 hero：SCard xl，128 封面、标签、标题、副标题、播放与加入队列；宽屏右侧预览 4 首
  private func heroCard(_ hero: NativeHomeHero) -> some View {
    HStack(alignment: .center, spacing: 16) {
      NativeArtwork(cover: hero.featured.cover, radius: 8).frame(width: 128, height: 128)
      VStack(alignment: .leading, spacing: 6) {
        Text(hero.tag).font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.nativeOnSurface).padding(.horizontal, 6).frame(height: 20)
          .background(Color.nativeOnSurface.opacity(0.12), in: Capsule())
        Text(hero.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
          .foregroundStyle(Color.nativeOnSurface)
        Text(hero.subtitle).font(.system(size: 14)).lineLimit(1)
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
        HStack(spacing: 8) {
          NativeSButton(
            title: "立即播放", icon: "play.fill", variant: .filled, tint: .primary, size: .small,
            shape: .round
          ) { player.play(hero.featured, in: hero.tracks) }
          NativeSButton(
            title: "添加到队列", icon: "plus", variant: .secondary, size: .small, shape: .round
          ) {
            let added = player.insertNext(hero.tracks)
            player.notice = "已添加 \(added) 首到播放队列"
          }
        }.padding(.top, 2)
      }.frame(maxWidth: .infinity, alignment: .leading)
      // 原版窗口宽 ≥1200 才显示
      if viewport >= 1200 {
        VStack(spacing: 0) {
          ForEach(Array(hero.preview.enumerated()), id: \.element.id) { index, track in
            HStack(spacing: 10) {
              Text(String(format: "%02d", index + 1)).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.35)).frame(width: 20)
              Text(track.title).font(.system(size: 14)).foregroundStyle(Color.nativeOnSurface)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
              Text(track.artist).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.45)).frame(maxWidth: 96)
            }.frame(maxHeight: .infinity)
          }
        }.frame(width: 320).padding(.leading, 16)
          .overlay(alignment: .leading) {
            Rectangle().fill(Color.nativeOnSurface.opacity(0.08)).frame(width: 1)
          }
      }
    }.padding(16)
    .frame(minHeight: 160).nativeCard(radius: 12)
      .accessibilityElement(children: .contain).accessibilityIdentifier("native.home.hero")
  }

  /// hero 来源：本地随机 / 每日推荐（登录）/ 我喜欢，随机起点，无内容顺延
  private func loadHero() async {
    var kinds = ["local"]
    if account.account != nil { kinds.append("daily") }
    if !player.favoriteTracks.isEmpty { kinds.append("liked") }
    let start = Int.random(in: 0..<kinds.count)
    for offset in 0..<kinds.count {
      let kind = kinds[(start + offset) % kinds.count]
      var tracks: [NativeTrack] = []
      switch kind {
      case "local": tracks = Array(player.tracks.shuffled().prefix(50))
      case "liked": tracks = player.favoriteTracks
      default:
        let values = try? await player.service.call(["action": "daily"]) as? [[String: Any]]
        tracks = (values ?? []).compactMap(NativeTrack.online)
      }
      if let built = NativeHomeHero(kind: kind, tracks: tracks) {
        hero = built
        return
      }
    }
    hero = nil
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
  private var continueSection: some View {
    let items = continueItems
    let repeating = (items.first?.plays ?? 0) >= Self.repeatThreshold
    return VStack(alignment: .leading, spacing: 12) {
      NativeSectionTitle(
        title: repeating ? "反复聆听" : "继续聆听",
        subtitle: items.isEmpty
          ? nil : repeating ? "你最常听的 \(items.count) 首歌" : "你最近在听的 \(items.count) 首歌")
      if items.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "headphones").font(.system(size: 24))
          Text("还没有播放记录，去听点什么吧").font(.system(size: 14))
        }.foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4)).frame(maxWidth: .infinity)
          .padding(.vertical, 40)
          .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
              Color.nativeOnSurface.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
      } else {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12
        ) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button {
              player.playNow(item.track)
            } label: {
              HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1))
                  .font(.system(size: 14, weight: .semibold).monospacedDigit())
                  .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.3)).frame(width: 20)
                NativeArtwork(cover: item.track.cover, radius: 8).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 0) {
                  Text(item.track.title).font(.system(size: 14)).lineLimit(1)
                    .foregroundStyle(Color.nativeOnSurface)
                  Text(item.track.artist).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
                }.frame(maxWidth: .infinity, alignment: .leading)
                if viewport >= 1280 {
                  Text("播放 \(item.plays) 次").font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.45))
                }
              }.padding(.horizontal, 12).padding(.vertical, 8).nativeCard(radius: 12)
                .contentShape(Rectangle())
            }.buttonStyle(NativePressStyle(radius: 12))
              .accessibilityIdentifier("native.home.continue." + item.track.id)
          }
        }
      }
    }
  }
  /// 统计项：24 bold 数值 + 14 单位，12 号标签 /50
  private func metric(_ value: String, _ unit: String, _ label: String) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value).font(.system(size: 24, weight: .bold).monospacedDigit())
          .foregroundStyle(Color.nativeOnSurface)
        Text(unit).font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant)
      }
      Text(label).font(.system(size: 12)).foregroundStyle(
        Color.nativeOnSurfaceVariant.opacity(0.5))
    }
  }
  /// 快捷入口：SCard xl，36 图标块 primary/10，标题 14 medium，说明 12 /50
  private func action(
    _ title: String, _ subtitle: String, _ icon: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Color.nativePrimary)
          .frame(width: 36, height: 36)
          .background(Color.nativePrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 0) {
          Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            .foregroundStyle(Color.nativeOnSurface)
          Text(subtitle).font(.system(size: 12)).lineLimit(1)
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
        }
        Spacer(minLength: 0)
      }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity)
        .nativeCard(radius: 12).contentShape(Rectangle())
    }.buttonStyle(NativePressStyle(radius: 12))
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

/// 首页 hero 的来源与文案，对应原版 useDailyRecommend
struct NativeHomeHero {
  let tag: String
  let title: String
  let subtitle: String
  let tracks: [NativeTrack]
  let featured: NativeTrack
  /// 从代表曲目起的 4 首预览
  let preview: [NativeTrack]

  init?(kind: String, tracks: [NativeTrack]) {
    guard !tracks.isEmpty else { return nil }
    let index = Int.random(in: 0..<tracks.count)
    let featured = tracks[index]
    self.tracks = tracks
    self.featured = featured
    preview = (0..<min(4, tracks.count)).map { tracks[(index + $0) % tracks.count] }
    switch kind {
    case "daily":
      tag = "每日推荐"
      title = "从「\(featured.title)」听起"
      subtitle = "根据你的口味精选 · \(tracks.count) 首"
    case "liked":
      tag = "我的最爱"
      title = "听听你喜欢的音乐吧~"
      subtitle = "你收藏的全部音乐 · \(tracks.count) 首"
    default:
      tag = "本地曲库"
      title = "随机翻到了「\(featured.title)」"
      subtitle = "从本地曲库随机精选 · \(tracks.count) 首"
    }
  }
}
