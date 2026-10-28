import SwiftUI

@MainActor
struct NativePageContent: View {
  let page: NativePage
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var catalog: NativeCatalogStore
  @Binding var appearance: String
  let importMusic: () -> Void
  let openPlaylist: (NativeCover) -> Void
  let openLocalPlaylist: (NativePlaylist) -> Void
  let navigate: (NativePage) -> Void
  @State private var localQuery = ""
  @State private var selectedGroup: String?
  @AppStorage("native.download.enabled") private var downloadEnabled = false
  @Environment(\.nativeWide) private var wide

  var body: some View {
    Group {
      switch page {
      case .home:
        NativeHomeView(
          player: player, catalog: catalog, stats: player.playStats, account: player.account,
          openPlaylist: openPlaylist,
          importMusic: importMusic)
      case .settings:
        NativeSettingsView(
          player: player, appearance: $appearance, importMusic: importMusic, presented: false)
      case .search: searchPage
      case .cloud: NativeCloudView(player: player)
      case .downloads: NativeDownloadsView(player: player, downloads: player.downloads)
      case .collections:
        NativeCollectionsView(
            player: player, account: player.account, open: openPlaylist, select: openLocalPlaylist)
      case .localPlaylist:
        if let playlist = player.playlists.first(where: { $0.id == player.selectedPlaylistID }) {
          NativeSongCollection(
            title: playlist.name, tracks: playlist.tracks, player: player, playlistID: playlist.id,
            header: NativeCollectionHeader(cover: playlist.tracks.first?.cover, local: true))
        } else {
          NativeCollectionsView(
            player: player, account: player.account, open: openPlaylist, select: openLocalPlaylist)
        }
      case .playlist:
        NativeSongCollection(
          title: catalog.playlistTitle, tracks: catalog.playlist, player: player,
          loading: catalog.loadingPlaylist, error: catalog.error,
          header: NativeCollectionHeader(
            cover: catalog.playlistCover?.cover, subtitle: catalog.playlistCover?.subtitle,
            local: false, kind: catalog.playlistCover?.kind))
      case .liked: NativeLikedView(player: player, account: player.account)
      case .library, .history, .folders:
        NativeSongCollection(
          title: page.rawValue,
          tracks: page == .history ? player.history : player.tracks,
          player: player, importMusic: page == .library || page == .folders ? importMusic : nil,
          links: page == .library
            ? (downloadEnabled ? [NativeCollectionLink(title: "下载管理") { navigate(.downloads) }] : [])
              + [
                NativeCollectionLink(title: "统计") { navigate(.stats) },
                NativeCollectionLink(title: "我的歌单") { navigate(.collections) },
              ] : [])
      case .artists, .albums: groupedLibrary
      case .stats: NativeStatsView(player: player, stats: player.playStats, navigate: navigate)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: page) { _ in selectedGroup = nil }
  }

  /// 原版搜索页：关键词 + “的搜索结果”标题、平台分段；宽屏关键词只在顶栏输入，紧凑布局保留页内输入框
  private var searchPage: some View {
    let keyword = catalog.query.trimmingCharacters(in: .whitespaces)
    return VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .bottom, spacing: 12) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(keyword.isEmpty ? "搜索" : keyword).font(.system(size: 30, weight: .bold))
              .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
            if !keyword.isEmpty {
              Text("的搜索结果").font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6)).fixedSize()
            }
          }
          Spacer(minLength: 0)
          NativeTabs(
            selection: $catalog.source,
            items: [(value: "netease", title: "NCM"), ("qqmusic", "QM"), ("kugou", "KG")],
            style: .segment, round: true
          ).frame(width: 160)
            .onChange(of: catalog.source) { _ in catalog.search() }
        }.padding(.top, 8).padding(.bottom, wide ? 4 : 0)
        if !wide {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15))
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
            TextField("搜索歌曲、歌手或专辑", text: $catalog.query).textFieldStyle(.plain)
              .font(.system(size: 16)).onSubmit { catalog.search() }
              .accessibilityIdentifier("native.search.keyword")
          }.padding(.horizontal, 16).frame(height: 40)
            .background(Color.nativeOnSurface.opacity(0.03), in: Capsule())
            .overlay(Capsule().stroke(Color.nativeOnSurface.opacity(0.15)))
            .padding(.bottom, 4)
        }
      }.padding(.horizontal, 20).padding(.bottom, 8)
      if keyword.isEmpty {
        NativeEmptyState(icon: "magnifyingglass", text: "请输入关键词开始搜索", iconSize: 56)
          .frame(maxHeight: .infinity)
      } else {
        NativeSongCollection(
          title: "", tracks: catalog.results, player: player,
          loading: catalog.searching, error: catalog.error,
          more: catalog.hasMore ? { catalog.search(more: true) } : nil, search: true)
      }
    }.accessibilityElement(children: .contain).accessibilityIdentifier("native.search.page")
  }

  /// 本地艺术家 / 专辑：原版 LocalList 网格（艺术家最小 120 圆形，专辑 140），点进为详情列表
  @ViewBuilder private var groupedLibrary: some View {
    let artists = page == .artists
    let grouped = Dictionary(grouping: player.tracks) {
      artists ? $0.artist : ($0.album ?? "未知专辑")
    }
    if let selectedGroup {
      VStack(alignment: .leading, spacing: 0) {
        NativeSButton(title: page.rawValue, icon: "chevron.left", variant: .ghost, size: .small) {
          self.selectedGroup = nil
        }.padding(.horizontal, 14).padding(.top, 4)
        NativeSongCollection(
          title: selectedGroup, tracks: grouped[selectedGroup] ?? [], player: player,
          header: NativeCollectionHeader(
            cover: grouped[selectedGroup]?.first?.cover, local: true,
            kind: artists ? "artist" : "album"))
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          NativePageHeader(
            title: page.rawValue,
            meta: [(icon: artists ? "person" : "opticaldisc", text: "\(grouped.count) 个")]
          ).padding(.horizontal, 20).padding(.bottom, 8)
          if grouped.isEmpty {
            NativeEmptyState(icon: artists ? "person" : "opticaldisc", text: "暂无内容") {
              NativeSButton(
                title: "导入音乐", icon: "plus", variant: .secondary, tint: .primary, shape: .round,
                action: importMusic)
            }
          } else {
            NativeCoverGrid(minimum: artists ? 120 : 140) {
              ForEach(grouped.keys.sorted(), id: \.self) { key in
                NativeCoverCard(
                  cover: grouped[key]?.first?.cover, title: key,
                  subtitle: "\(grouped[key]?.count ?? 0) 首歌曲", round: artists
                ) { selectedGroup = key }
              }
            }.padding(.horizontal, 20).padding(.bottom, 24)
          }
        }
      }
    }
  }
}

/// 歌曲列表样式，对应原版外观设置 appearance.songListStyle
enum NativeSongListStyle {
  static let key = "native.appearance.songListStyle"
  static let comfortable = "comfortable"
  static let compact = "compact"
}

/// 列表点击播放的行为，对应原版 player.searchPlayBehavior / songListPlayBehavior
enum NativePlayBehavior {
  static let searchKey = "native.player.searchPlayBehavior"
  static let songListKey = "native.player.songListPlayBehavior"
  static let current = "current"
  static let all = "all"
}

/// 歌曲列表“更多”菜单中的页面入口
struct NativeCollectionLink {
  let title: String
  let action: () -> Void
}

/// 原版歌曲行状态：静止 surface-panel + primary/12 描边，按下 on-surface/12，播放中 primary/16 + /40
struct NativeSongRowStyle: ButtonStyle {
  let playing: Bool
  let compact: Bool

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let shape = RoundedRectangle(cornerRadius: compact ? 8 : 12)
    return configuration.label.background {
      if compact {
        shape.fill(
          playing
            ? Color.nativePrimary.opacity(0.14)
            : Color.nativeOnSurface.opacity(pressed ? 0.1 : 0))
      } else {
        shape.fill(
          playing
            ? Color.nativePrimary.opacity(0.16)
            : pressed ? Color.nativeOnSurface.opacity(0.12) : Color.nativeSurfacePanel
        ).overlay(
          shape.strokeBorder(
            Color.nativePrimary.opacity(playing ? 0.4 : pressed ? 0.3 : 0.12), lineWidth: 2))
      }
    }.animation(.easeOut(duration: 0.2), value: pressed)
  }
}

/// 元信息行：14 号图标与文字间距 4
struct NativeMetaLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 13))
      configuration.title
    }
  }
}

/// 歌单详情头部；封面同时作为共享元素过渡的目标
struct NativeCollectionHeader {
  var cover: String?
  var subtitle: String?
  var local: Bool
  /// playlist / album / artist，决定类型图标
  var kind: String? = nil
}

@MainActor
struct NativeSongCollection: View {
  let title: String
  let tracks: [NativeTrack]
  @ObservedObject var player: NativePlayerStore
  var loading = false
  var error: String?
  var importMusic: (() -> Void)?
  var more: (() -> Void)?
  var playlistID: String? = nil
  /// 搜索页的行点击遵循“搜索页播放”设置
  var search = false
  var header: NativeCollectionHeader? = nil
  /// 外层页面自绘标题时隐藏列表标题，标题仍作为播放来源
  var hidesTitle = false
  /// “更多”菜单中的页面入口（音乐库的下载管理、统计等）
  var links: [NativeCollectionLink] = []
  /// 搜索框右侧的附加控件（我喜欢的本地/在线分段）
  var accessory: AnyView? = nil
  /// 空列表提示与图标
  var emptyText = "暂无歌曲"
  var emptyIcon = "music.note.list"
  @State private var deleting: NativeTrack?
  @State private var confirmDownload = false
  @State private var query = ""
  @AppStorage("native.download.enabled") private var downloadEnabled = false
  @AppStorage(NativeSongListStyle.key) private var listStyle = NativeSongListStyle.comfortable
  @AppStorage(NativePlayBehavior.searchKey) private var searchBehavior = NativePlayBehavior.current
  @AppStorage(NativePlayBehavior.songListKey) private var buttonBehavior = NativePlayBehavior.current
  /// 可下载的在线歌曲；本地与自定义音源不参与下载
  private var downloadable: [NativeTrack] {
    tracks.filter { $0.source != nil && $0.source != "plugin" }
  }
  private var compact: Bool { listStyle == NativeSongListStyle.compact }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Group {
          if let header {
            headerView(header)
          } else if !title.isEmpty && !hidesTitle {
            NativePageHeader(
              title: title,
              meta: tracks.isEmpty ? [] : [(icon: "music.note", text: "共 \(tracks.count) 首")],
              titleID: "native.wide.pageTitle"
            ) { actionRow }
          } else if !hidesTitle && !search {
            actionRow
          }
        }.padding(.horizontal, title.isEmpty && header == nil ? 0 : 20).padding(.bottom, 8)
        if let error {
          Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 14))
            .foregroundStyle(Color(light: 0xEF4444, dark: 0xF87171)).padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        if tracks.isEmpty && !loading && error == nil {
          NativeEmptyState(icon: emptyIcon, text: emptyText)
        } else if !tracks.isEmpty {
          columnHeader
          LazyVStack(spacing: compact ? 0 : 12) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
              row(track, index: index)
            }
          }.padding(.horizontal, 12)
        }
        if loading {
          ProgressView().tint(Color.nativePrimary).frame(maxWidth: .infinity).padding(24)
        }
        if let more, !loading {
          NativeSButton(title: "加载更多", variant: .secondary, shape: .round, action: more)
            .frame(maxWidth: .infinity).padding(24)
        }
      }.padding(.top, title.isEmpty && header == nil ? 0 : 8).padding(.bottom, 80)
    }.confirmationDialog(
      "下载 \(downloadable.count) 首在线歌曲？", isPresented: $confirmDownload,
      titleVisibility: .visible
    ) {
      Button("批量下载") { player.download(downloadable) }
    } message: {
      Text("已下载或已在队列中的歌曲会自动跳过")
    }
    .confirmationDialog(
      "删除这首歌曲？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("删除应用内副本", role: .destructive) {
        if let deleting { Task { await player.remove(deleting) } }
        deleting = nil
      }
    }
  }

  /// 本地筛选后的歌曲，对应原版标题区右侧的搜索框
  private var visible: [NativeTrack] {
    let keyword = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !keyword.isEmpty else { return tracks }
    return tracks.filter {
      $0.title.lowercased().contains(keyword) || $0.artist.lowercased().contains(keyword)
        || ($0.album ?? "").lowercased().contains(keyword)
    }
  }

  /// 操作行：播放全部（primary secondary round）、其余 secondary round、更多圆形；右侧搜索框
  private var actionRow: some View {
    HStack(spacing: 16) {
      HStack(spacing: 12) {
        NativeSButton(
          title: "播放全部", icon: "play.fill", variant: .secondary, tint: .primary, shape: .round
        ) {
          if let first = visible.first { player.play(first, in: visible, context: title) }
        }.disabled(tracks.isEmpty)
        if let importMusic {
          NativeSButton(title: "导入音乐", icon: "plus", variant: .secondary, shape: .round,
            action: importMusic
          ).accessibilityIdentifier("native.import.library")
        }
        if downloadEnabled && !downloadable.isEmpty {
          NativeSButton(
            title: "批量下载", icon: "arrow.down.circle", variant: .secondary, shape: .round
          ) { confirmDownload = true }.accessibilityIdentifier("native.download.all")
        }
        if !links.isEmpty {
          Menu {
            ForEach(links, id: \.title) { link in Button(link.title, action: link.action) }
          } label: {
            Image(systemName: "ellipsis").font(.system(size: 18))
              .frame(width: 36, height: 36)
              .background(Color.nativeOnSurface.opacity(0.12), in: Circle())
              .foregroundStyle(Color.nativeOnSurface)
          }.accessibilityLabel("更多")
        }
      }
      Spacer(minLength: 0)
      HStack(spacing: 12) {
        if !tracks.isEmpty { NativeSearchInput(text: $query) }
        accessory
      }
    }
  }

  /// 列表表头：# · 标题 · 专辑 · 操作 · 时长
  private var columnHeader: some View {
    HStack(spacing: 12) {
      Text("#").frame(width: 32)
      Text("标题").padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
      if !compact { Text("专辑").frame(maxWidth: .infinity, alignment: .leading) }
      Text("操作").frame(width: 48)
      Text("时长").frame(width: 64)
    }.font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6))
      .padding(.leading, 12).padding(.trailing, compact ? 16 : 24)
      .frame(height: compact ? 36 : 40).padding(.horizontal, 12)
      .accessibilityHidden(true)
  }

  /// 与原版歌单详情一致：160pt 封面在左，标题、来源、元信息与操作在右
  private func headerView(_ header: NativeCollectionHeader) -> some View {
    HStack(alignment: .top, spacing: 20) {
      NativeArtwork(cover: header.cover, radius: 12, pixels: 1000, preview: 300)
        .frame(width: 160, height: 160)
        .nativeCoverAnchor("cover.hero", radius: 12)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          Text(title).font(.system(size: 30, weight: .bold)).lineLimit(1)
            .foregroundStyle(Color.nativeOnSurface)
            .accessibilityIdentifier("native.wide.pageTitle")
          HStack(spacing: 4) {
            Image(systemName: header.local ? "internaldrive" : "globe")
              .frame(width: 24, height: 24).accessibilityLabel(header.local ? "本地" : "在线")
            Rectangle().fill(Color.nativeOnSurface.opacity(0.1)).frame(width: 1, height: 16)
            Image(
              systemName: header.kind == "album"
                ? "opticaldisc" : header.kind == "artist" ? "person" : "music.note.list"
            ).frame(width: 24, height: 24).opacity(0.65).accessibilityLabel(
              header.kind == "album" ? "专辑" : header.kind == "artist" ? "歌手" : "歌单")
          }.font(.system(size: 15)).foregroundStyle(Color.nativePrimary)
          Spacer(minLength: 0)
        }
        if let subtitle = header.subtitle, !subtitle.isEmpty {
          Text(subtitle).font(.system(size: 14)).lineLimit(1)
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
        }
        HStack(spacing: 12) {
          Label("\(tracks.count) 首歌曲", systemImage: "music.note.list")
          Label(
            NativeNowPlayingView.time(tracks.reduce(0) { $0 + $1.durationMs }),
            systemImage: "hourglass")
        }.labelStyle(NativeMetaLabelStyle()).font(.system(size: 14))
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
        Spacer(minLength: 0)
        actionRow
      }.frame(height: 160)
    }
  }

  /// 行点击对应原版双击：搜索页按设置只播当前，其余替换为整张列表
  private func playRow(_ track: NativeTrack) {
    if search && searchBehavior != NativePlayBehavior.all {
      player.playNow(track, context: title)
    } else {
      player.play(track, in: tracks, context: title)
    }
  }

  /// 行首播放按钮：当前曲目切换暂停，其余按“歌曲播放按钮行为”设置
  private func playButton(_ track: NativeTrack) {
    if player.current?.id == track.id {
      player.togglePlayback()
    } else if buttonBehavior == NativePlayBehavior.all {
      player.play(track, in: tracks, context: title)
    } else {
      player.playNow(track, context: title)
    }
  }

  /// 原版歌曲行：舒适为 76 高描边卡片，紧凑为 56 高无边框行；操作菜单为长按上下文菜单
  private func row(_ track: NativeTrack, index: Int) -> some View {
    let playing = player.current?.id == track.id
    return Button {
      playRow(track)
    } label: {
      HStack(spacing: 12) {
        Button {
          playButton(track)
        } label: {
          Group {
            if playing {
              Image(systemName: player.isPlaying ? "music.note" : "play.fill")
                .font(.system(size: 17, weight: .medium))
            } else {
              Text(String(index + 1)).font(
                .system(size: compact ? 12 : 14, weight: .bold).monospacedDigit())
            }
          }.foregroundStyle(playing ? Color.nativePrimary : Color.nativeOnSurfaceVariant)
            .frame(width: 32, height: compact ? 40 : 52).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel(playing && player.isPlaying ? "暂停" : "播放 " + track.title)
          .accessibilityIdentifier("native.songPlay." + track.id)
        HStack(spacing: 12) {
          NativeArtwork(cover: track.cover, radius: compact ? 6 : 8)
            .frame(width: compact ? 36 : 48, height: compact ? 36 : 48)
          VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(track.title).font(.system(size: compact ? 14 : 16, weight: .medium))
              .foregroundStyle(playing ? Color.nativePrimary : Color.nativeOnSurface).lineLimit(1)
            HStack(spacing: 4) {
              NativeDownloadBadge(downloads: player.downloads, track: track)
              Text(track.artist.replacingOccurrences(of: "/", with: " / ")).lineLimit(1)
            }.font(.system(size: compact ? 12 : 14))
              .foregroundStyle(
                playing ? Color.nativePrimary.opacity(0.7) : Color.nativeOnSurfaceVariant)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if !compact {
          Text(track.album ?? "未知专辑").font(.system(size: 14)).lineLimit(1)
            .foregroundStyle(playing ? Color.nativePrimary.opacity(0.7) : Color.nativeOnSurface)
            .opacity(track.album == nil ? 0.5 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Group {
          if player.loadingTrack == track.id {
            ProgressView().tint(Color.nativePrimary)
          } else {
            NativeSButton(
              icon: player.isFavorite(track) ? "heart.fill" : "heart", variant: .text,
              tint: .primary, size: .custom(28), shape: .circle
            ) { player.toggleFavorite(track) }.accessibilityLabel("喜欢 " + track.title)
          }
        }.frame(width: 48)
        Text(NativeNowPlayingView.time(track.durationMs)).font(.system(size: 14).monospacedDigit())
          .foregroundStyle(
            playing ? Color.nativePrimary.opacity(0.6) : Color.nativeOnSurfaceVariant
          )
          .frame(width: 64)
      }
      .padding(.leading, 12).padding(.trailing, compact ? 16 : 24)
      .frame(height: compact ? 56 : 76).contentShape(Rectangle())
    }
    .buttonStyle(NativeSongRowStyle(playing: playing, compact: compact))
    .accessibilityIdentifier("native.song." + track.id)
    .contextMenu { menu(track) }
  }

  @ViewBuilder private func menu(_ track: NativeTrack) -> some View {
    Button("播放", systemImage: "play") { player.playNow(track, context: title) }
    Button("下一首播放", systemImage: "text.insert") { player.insertNext([track]) }
    if !player.playlists.isEmpty {
      Menu("添加到歌单", systemImage: "text.badge.plus") {
        ForEach(player.playlists) { playlist in
          Button(playlist.name) { player.addToPlaylist(playlist.id, track: track) }
        }
      }
    }
    if downloadEnabled && track.source != nil && track.source != "plugin" {
      Button("下载", systemImage: "arrow.down.circle") { player.download(track) }
    }
    if let playlistID {
      Button("从歌单移除", systemImage: "minus.circle", role: .destructive) {
        player.removeFromPlaylist(playlistID, track: track)
      }
    }
    if track.source == nil {
      Button("删除文件", systemImage: "trash", role: .destructive) { deleting = track }
    }
  }

  /// 来源平台的简称
  static func sourceLabel(_ source: String) -> String {
    switch source {
    case "netease": return "网易云"
    case "qqmusic": return "QQ"
    case "plugin": return "自定义源"
    default: return "酷狗"
    }
  }
}

/// 我喜欢的音乐：登录后与原版一样分本地与在线两页，在线为账号的「我喜欢的音乐」歌单
@MainActor
struct NativeLikedView: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var account: NativeAccountStore
  @AppStorage("native.liked.tab") private var tab = "local"

  var body: some View {
    let online = tab == "online"
    let loggedIn = account.account != nil
    NativeSongCollection(
      title: NativePage.liked.rawValue,
      tracks: online ? (loggedIn ? account.likedTracks : []) : player.favoriteTracks,
      player: player, loading: online && account.loadingLiked,
      error: online && loggedIn ? account.likedError : nil,
      accessory: AnyView(
        NativeTabs(
          selection: $tab, items: [(value: "local", title: "本地"), ("online", "在线")],
          style: .segment, round: true
        ).frame(width: 192).accessibilityIdentifier("native.liked.tabs")),
      emptyText: online
        ? (loggedIn ? "还没有喜欢的在线音乐" : "登录后才能查看在线喜欢的音乐")
        : "还没有收藏的本地歌曲，点击歌曲右侧的红心试试",
      emptyIcon: "heart"
    )
    .task(id: online ? account.account?.liked?.id : nil) {
      if online && loggedIn { await account.loadLiked() }
    }
    .refreshable { if online { await account.loadLiked(refresh: true) } }
  }
}
