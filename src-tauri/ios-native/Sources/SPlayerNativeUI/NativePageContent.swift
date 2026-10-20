import SwiftUI

@MainActor
struct NativePageContent: View {
  let page: NativePage
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var catalog: NativeCatalogStore
  @Binding var appearance: String
  let importMusic: () -> Void
  let openPlaylist: (NativeCover) -> Void
  let navigate: (NativePage) -> Void
  @State private var localQuery = ""
  @State private var selectedGroup: String?

  var body: some View {
    Group {
      switch page {
      case .home:
        NativeHomeView(
          player: player, catalog: catalog, openPlaylist: openPlaylist, importMusic: importMusic)
      case .settings:
        NativeSettingsView(player: player, appearance: $appearance, importMusic: importMusic)
      case .search: searchPage
      case .cloud: NativeCloudView(player: player)
      case .collections:
        NativeCollectionsView(
          player: player, open: openPlaylist,
          select: {
            player.selectedPlaylistID = $0
            navigate(.localPlaylist)
          })
      case .localPlaylist:
        if let playlist = player.playlists.first(where: { $0.id == player.selectedPlaylistID }) {
          NativeSongCollection(
            title: playlist.name, tracks: playlist.tracks, player: player, playlistID: playlist.id)
        } else {
          NativeCollectionsView(
            player: player, open: openPlaylist,
            select: {
              player.selectedPlaylistID = $0
              navigate(.localPlaylist)
            })
        }
      case .playlist:
        NativeSongCollection(
          title: catalog.playlistTitle, tracks: catalog.playlist, player: player,
          loading: catalog.loadingPlaylist, error: catalog.error)
      case .library, .liked, .history, .folders:
        VStack(spacing: 0) {
          if page == .library {
            HStack {
              Spacer()
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
      case .stats:
        VStack(alignment: .leading, spacing: 24) {
          Text("统计").font(.system(size: 30, weight: .bold))
          HStack(spacing: 50) {
            metric("\(player.tracks.count)", "本地歌曲")
            metric("\(player.favoriteTracks.count)", "喜欢的音乐")
            metric("\(player.history.count)", "最近听过")
          }
          Text("播放历史保留最近 100 首歌曲").font(.footnote).foregroundStyle(.secondary)
          Spacer()
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
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
          more: catalog.hasMore ? { catalog.search(more: true) } : nil)
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
  /// 以数值、单位和标签保持统计项的视觉层级
  private func metric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(value).font(.largeTitle.bold())
      Text(label).foregroundStyle(.secondary)
    }
  }
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
  @State private var deleting: NativeTrack?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if !title.isEmpty {
          Text(title).font(.system(size: 30, weight: .bold)).accessibilityIdentifier(
            "native.wide.pageTitle")
        }
        HStack(spacing: 12) {
          Button {
            if let first = tracks.first { player.play(first, in: tracks) }
          } label: {
            Label("播放全部", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(tracks.isEmpty)
          if let importMusic {
            Button(action: importMusic) { Label("导入音乐", systemImage: "plus") }.buttonStyle(
              .bordered
            ).buttonBorderShape(.capsule).accessibilityIdentifier("native.import.library")
          }
          Spacer()
          Text("共 \(tracks.count) 首歌曲").font(.system(size: 12)).foregroundStyle(.secondary)
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
        LazyVStack(spacing: 0) {
          ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            HStack(spacing: 12) {
              Text(String(index + 1)).font(.system(size: 12).monospacedDigit()).foregroundStyle(
                .tertiary
              ).frame(width: 22)
              Button {
                player.play(track, in: tracks)
              } label: {
                NativeTrackRow(track: track, selected: player.current?.id == track.id)
              }
              .buttonStyle(.plain).accessibilityIdentifier("native.song." + track.id)
              if player.loadingTrack == track.id { ProgressView().frame(width: 32) }
              Button {
                player.toggleFavorite(track)
              } label: {
                Image(
                  systemName: player.favoriteTracks.contains(where: { $0.id == track.id })
                    ? "heart.fill" : "heart"
                ).frame(width: 40, height: 44)
              }.buttonStyle(.plain).accessibilityLabel("喜欢 " + track.title)
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
                if track.source == nil {
                  Button("删除应用内副本", role: .destructive) { deleting = track }
                }
              } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 44)
              }
            }.padding(.horizontal, 8).background(
              index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear,
              in: RoundedRectangle(cornerRadius: 8))
          }
        }
        if loading { ProgressView("正在加载…").frame(maxWidth: .infinity).padding() }
        if let more, !loading { Button("加载更多", action: more).frame(maxWidth: .infinity).padding() }
      }.padding(title.isEmpty ? 0 : 24)
    }.confirmationDialog(
      "删除这首歌曲？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("删除应用内副本", role: .destructive) {
        if let deleting { Task { await player.remove(deleting) } }
        deleting = nil
      }
    }
  }
}
