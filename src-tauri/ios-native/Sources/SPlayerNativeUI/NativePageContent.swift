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

  var body: some View {
    Group {
      switch page {
      case .home:
        NativeHomeView(
          player: player, catalog: catalog, stats: player.playStats, openPlaylist: openPlaylist,
          importMusic: importMusic)
      case .settings:
        NativeSettingsView(
          player: player, appearance: $appearance, importMusic: importMusic, presented: false)
      case .search: searchPage
      case .cloud: NativeCloudView(player: player)
      case .downloads: NativeDownloadsView(player: player, downloads: player.downloads)
      case .collections:
        NativeCollectionsView(player: player, open: openPlaylist, select: openLocalPlaylist)
      case .localPlaylist:
        if let playlist = player.playlists.first(where: { $0.id == player.selectedPlaylistID }) {
          NativeSongCollection(
            title: playlist.name, tracks: playlist.tracks, player: player, playlistID: playlist.id,
            header: NativeCollectionHeader(cover: playlist.tracks.first?.cover, local: true))
        } else {
          NativeCollectionsView(player: player, open: openPlaylist, select: openLocalPlaylist)
        }
      case .playlist:
        NativeSongCollection(
          title: catalog.playlistTitle, tracks: catalog.playlist, player: player,
          loading: catalog.loadingPlaylist, error: catalog.error,
          header: NativeCollectionHeader(
            cover: catalog.playlistCover?.cover, subtitle: catalog.playlistCover?.subtitle,
            local: false))
      case .library, .liked, .history, .folders:
        VStack(spacing: 0) {
          if page == .library {
            HStack(spacing: 16) {
              Spacer()
              if downloadEnabled { Button("下载管理") { navigate(.downloads) } }
              Button("统计") { navigate(.stats) }
              Button("我的歌单") { navigate(.collections) }
            }.padding(.horizontal, 24).padding(.top, 12)
          }
          NativeSongCollection(
            title: page.rawValue,
            tracks: page == .liked
              ? player.favoriteTracks : page == .history ? player.history : player.tracks,
            player: player, importMusic: page == .library || page == .folders ? importMusic : nil)
        }
      case .artists, .albums: groupedLibrary
      case .stats: NativeStatsView(player: player, stats: player.playStats, navigate: navigate)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: page) { _ in selectedGroup = nil }
  }

  private var searchPage: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("搜索").font(.system(size: 30, weight: .bold))
        Spacer()
      }
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索歌曲、歌手", text: $catalog.query).textFieldStyle(.plain).onSubmit {
          catalog.search()
        }
        .accessibilityIdentifier("native.search.keyword")
        Button("搜索") { catalog.search() }.buttonStyle(.borderedProminent)
      }.padding(12).background(Color.nativePanel, in: RoundedRectangle(cornerRadius: 12))
      Picker("音乐平台", selection: $catalog.source) {
        Text("网易云").tag("netease")
        Text("QQ 音乐").tag("qqmusic")
        Text("酷狗").tag("kugou")
      }.pickerStyle(.segmented).frame(maxWidth: 400)
        .onChange(of: catalog.source) { _ in catalog.search() }
      if catalog.query.isEmpty {
        Spacer()
        VStack(spacing: 14) {
          Image(systemName: "magnifyingglass").font(.system(size: 42)).foregroundStyle(.tertiary)
          Text("请输入关键词开始搜索").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
        Spacer()
      } else {
        NativeSongCollection(
          title: "", tracks: catalog.results, player: player,
          loading: catalog.searching, error: catalog.error,
          more: catalog.hasMore ? { catalog.search(more: true) } : nil, search: true)
      }
    }.padding(24).accessibilityElement(children: .contain).accessibilityIdentifier(
      "native.search.page")
  }

  private var groupedLibrary: some View {
    let grouped = Dictionary(grouping: player.tracks) {
      page == .artists ? $0.artist : ($0.album ?? "未知专辑")
    }
    return ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(selectedGroup ?? page.rawValue).font(.system(size: 30, weight: .bold))
        if let selectedGroup {
          Button("返回\(page.rawValue)") { self.selectedGroup = nil }
          NativeSongCollection(title: "", tracks: grouped[selectedGroup] ?? [], player: player)
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 20)], spacing: 24) {
            ForEach(grouped.keys.sorted(), id: \.self) { key in
              Button {
                selectedGroup = key
              } label: {
                VStack(spacing: 12) {
                  NativeArtwork(
                    cover: grouped[key]?.first?.cover, radius: page == .artists ? 80 : 10
                  ).aspectRatio(1, contentMode: .fit)
                  Text(key).font(.system(size: 14, weight: .medium)).lineLimit(1)
                  Text("\(grouped[key]?.count ?? 0) 首歌曲").font(.system(size: 12)).foregroundStyle(
                    .secondary)
                }
              }.buttonStyle(.plain)
            }
          }
          if grouped.isEmpty { Button("导入音乐", action: importMusic).buttonStyle(.borderedProminent) }
        }
      }.padding(24)
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

/// 歌单详情头部；封面同时作为共享元素过渡的目标
struct NativeCollectionHeader {
  var cover: String?
  var subtitle: String?
  var local: Bool
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
  @State private var deleting: NativeTrack?
  @State private var confirmDownload = false
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
      VStack(alignment: .leading, spacing: 16) {
        if let header {
          headerView(header)
        } else {
          if !title.isEmpty {
            Text(title).font(.system(size: 30, weight: .bold)).accessibilityIdentifier(
              "native.wide.pageTitle")
          }
          HStack(spacing: 12) {
            actions
            Spacer()
            Text("共 \(tracks.count) 首歌曲").font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
        if let error {
          Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(
            .secondary)
        }
        if tracks.isEmpty && !loading && error == nil {
          VStack(spacing: 16) {
            Image(systemName: "music.note.list").font(.system(size: 38)).foregroundStyle(.tertiary)
            Text("暂无歌曲").foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity).padding(.vertical, 80)
        }
        LazyVStack(spacing: compact ? 0 : 12) {
          ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            row(track, index: index)
          }
        }
        if loading { ProgressView("正在加载…").frame(maxWidth: .infinity).padding() }
        if let more, !loading { Button("加载更多", action: more).frame(maxWidth: .infinity).padding() }
      }.padding(title.isEmpty && header == nil ? 0 : 24)
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

  /// 播放全部、导入与批量下载
  @ViewBuilder private var actions: some View {
    Button {
      if let first = tracks.first { player.play(first, in: tracks, context: title) }
    } label: {
      Label("播放全部", systemImage: "play.fill")
    }
    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(tracks.isEmpty)
    if let importMusic {
      Button(action: importMusic) { Label("导入音乐", systemImage: "plus") }.buttonStyle(
        .bordered
      ).buttonBorderShape(.capsule).accessibilityIdentifier("native.import.library")
    }
    if downloadEnabled && !downloadable.isEmpty {
      Button {
        confirmDownload = true
      } label: {
        Label("批量下载", systemImage: "arrow.down.circle")
      }.buttonStyle(.bordered).buttonBorderShape(.capsule)
        .accessibilityIdentifier("native.download.all")
    }
  }

  /// 与原版歌单详情一致：160pt 封面在左，标题、来源与操作在右
  private func headerView(_ header: NativeCollectionHeader) -> some View {
    HStack(alignment: .top, spacing: 20) {
      NativeArtwork(cover: header.cover, radius: 12, pixels: 1000, preview: 300)
        .frame(width: 160, height: 160)
        .nativeCoverAnchor("cover.hero", radius: 12)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          Text(title).font(.system(size: 30, weight: .bold)).lineLimit(1)
            .accessibilityIdentifier("native.wide.pageTitle")
          Spacer(minLength: 0)
          HStack(spacing: 8) {
            Image(systemName: header.local ? "internaldrive" : "globe")
              .accessibilityLabel(header.local ? "本地" : "在线")
            Divider().frame(height: 14)
            Image(systemName: "music.note.list").opacity(0.65).accessibilityLabel("歌单")
          }.font(.system(size: 15))
        }
        if let subtitle = header.subtitle, !subtitle.isEmpty {
          Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
        }
        Text("\(tracks.count) 首歌曲").font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        HStack(spacing: 12) { actions }
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

  /// 原版歌曲行：舒适为带描边卡片（76pt），紧凑为无边框窄行（56pt）
  private func row(_ track: NativeTrack, index: Int) -> some View {
    let playing = player.current?.id == track.id
    let shape = RoundedRectangle(cornerRadius: compact ? 8 : 12)
    return HStack(spacing: 12) {
      Button {
        playButton(track)
      } label: {
        Group {
          if playing {
            Image(systemName: "music.note").font(.system(size: 18, weight: .semibold))
          } else {
            Text(String(index + 1)).font(
              .system(size: compact ? 12 : 14, weight: .bold).monospacedDigit())
          }
        }.foregroundStyle(playing ? Color.primary : Color.secondary)
          .frame(width: 32, height: compact ? 40 : 52).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(playing && player.isPlaying ? "暂停" : "播放 " + track.title)
        .accessibilityIdentifier("native.songPlay." + track.id)
      Button {
        playRow(track)
      } label: {
        HStack(spacing: 12) {
          NativeArtwork(cover: track.cover, radius: compact ? 6 : 8)
            .frame(width: compact ? 36 : 48, height: compact ? 36 : 48)
          VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(track.title).font(.system(size: compact ? 14 : 16, weight: .medium))
              .lineLimit(1)
            HStack(spacing: 4) {
              NativeDownloadBadge(downloads: player.downloads, track: track)
              if let source = track.source {
                Text(NativeSongCollection.sourceLabel(source)).font(.system(size: 10))
                  .padding(.horizontal, 4).padding(.vertical, 1)
                  .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
              }
              Text(track.artist).lineLimit(1)
            }.font(.system(size: compact ? 12 : 14))
              .foregroundStyle(playing ? Color.primary.opacity(0.7) : Color.secondary)
          }
          Spacer(minLength: 0)
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityIdentifier("native.song." + track.id)
      if player.loadingTrack == track.id { ProgressView().frame(width: 32) }
      Button {
        player.toggleFavorite(track)
      } label: {
        Image(systemName: player.isFavorite(track) ? "heart.fill" : "heart")
          .font(.system(size: 18)).frame(width: 48, height: 44)
      }.buttonStyle(.plain).accessibilityLabel("喜欢 " + track.title)
      Text(NativeNowPlayingView.time(track.durationMs)).font(.system(size: 14).monospacedDigit())
        .foregroundStyle(playing ? Color.primary.opacity(0.6) : Color.secondary)
        .frame(width: 56)
      menu(track)
    }
    .padding(.leading, 12).padding(.trailing, 4)
    .frame(height: compact ? 56 : 76)
    .background {
      if compact {
        shape.fill(playing ? Color.primary.opacity(0.14) : .clear)
      } else {
        shape.fill(playing ? Color.primary.opacity(0.16) : Color.nativePanel)
          .overlay(shape.strokeBorder(Color.primary.opacity(playing ? 0.4 : 0.12), lineWidth: 2))
      }
    }
  }

  private func menu(_ track: NativeTrack) -> some View {
    Menu {
      Button("加入队列") { player.enqueue(track) }
      if !player.playlists.isEmpty {
        Menu("添加到歌单") {
          ForEach(player.playlists) { playlist in
            Button(playlist.name) { player.addToPlaylist(playlist.id, track: track) }
          }
        }
      }
      if let playlistID {
        Button("从歌单移除", role: .destructive) {
          player.removeFromPlaylist(playlistID, track: track)
        }
      }
      Button("喜欢 / 取消喜欢") { player.toggleFavorite(track) }
      if downloadEnabled && track.source != nil && track.source != "plugin" {
        Button("下载歌曲") { player.download(track) }
      }
      if track.source == nil {
        Button("删除应用内副本", role: .destructive) { deleting = track }
      }
    } label: {
      Image(systemName: "ellipsis").frame(width: 32, height: 44)
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
