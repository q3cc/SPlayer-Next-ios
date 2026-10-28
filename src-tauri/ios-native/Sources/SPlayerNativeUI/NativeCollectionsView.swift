import SwiftUI

/// 原版 Favorites：标题 + 数量，STabs bar（歌单 / 专辑 / 歌手），CoverList 横 20 上 8 下 20
@MainActor
struct NativeCollectionsView: View {
  @ObservedObject var player: NativePlayerStore
  /// 登录后按原版分为歌单 / 专辑 / 歌手三类，内容来自账号收藏
  @ObservedObject var account: NativeAccountStore
  let open: (NativeCover) -> Void
  let select: (NativePlaylist) -> Void
  @State private var creating = false
  @State private var name = ""
  @State private var deleting: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      NativePageHeader(title: "我的收藏", meta: meta) {
        HStack(spacing: 16) {
          if account.account != nil {
            NativeTabs(
              selection: $account.favoritesTab,
              items: [
                (value: "playlist", title: "歌单"), (value: "album", title: "专辑"),
                (value: "artist", title: "歌手"),
              ]
            ).accessibilityIdentifier("native.favorites.tabs")
            Spacer(minLength: 0)
          }
          NativeSButton(title: "新建歌单", icon: "plus", variant: .secondary, shape: .round) {
            creating = true
          }
        }
      }.padding(.horizontal, 20).padding(.bottom, 8)
      ScrollView {
        Group {
          if let user = account.account {
            switch account.favoritesTab {
            case "album": accountGrid(user.albums, round: false)
            case "artist": accountGrid(user.artists, round: true)
            default:
              VStack(alignment: .leading, spacing: 24) {
                accountGrid(user.subscribed, round: false)
                localSections(excluding: Set(user.subscribed.map(\.id)))
              }
            }
          } else {
            localSections(excluding: [])
          }
        }.id(account.favoritesTab).transition(.opacity).nativePagePadding()
      }
    }.alert("新建本地歌单", isPresented: $creating) {
      TextField("歌单名称", text: $name)
      Button("取消", role: .cancel) {}
      Button("创建") {
        player.createPlaylist(name)
        name = ""
        if let playlist = player.playlists.first(where: { $0.id == player.selectedPlaylistID }) {
          select(playlist)
        }
      }
    }.confirmationDialog(
      "删除歌单？音乐文件不会被删除",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("删除歌单", role: .destructive) {
        if let deleting { player.deletePlaylist(deleting) }
        deleting = nil
      }
    }
  }

  /// 标题旁的数量：登录后随分类切换，未登录时原版不显示
  private var meta: [(icon: String, text: String)] {
    guard let user = account.account else { return [] }
    switch account.favoritesTab {
    case "album": return [(icon: "opticaldisc", text: "共 \(user.albums.count) 张专辑")]
    case "artist": return [(icon: "person", text: "共 \(user.artists.count) 位歌手")]
    default: return [(icon: "music.note.list", text: "共 \(user.subscribed.count) 个歌单")]
    }
  }

  /// 账号收藏的歌单、专辑或歌手网格，歌手为圆形封面、最小列宽 120
  @ViewBuilder
  private func accountGrid(_ items: [NativeCover], round: Bool) -> some View {
    if items.isEmpty {
      NativeEmptyState(icon: "heart", text: "这里还空空如也，去发现一些喜欢的内容吧")
    } else {
      NativeCoverGrid(minimum: round ? 120 : 140) {
        ForEach(items) { cover in
          NativeCoverCard(
            cover: cover.cover, title: cover.title, subtitle: cover.subtitle, round: round,
            anchor: "cover." + cover.id
          ) { open(cover) }.accessibilityIdentifier("native.favorites." + cover.id)
        }
      }
    }
  }

  /// 本地歌单与应用内收藏的推荐歌单；原版放在侧栏“我的歌单”，竖屏无侧栏时只能从这里进入
  /// @param excluding - 已在账号收藏中出现的歌单，避免重复的封面锚点
  @ViewBuilder
  private func localSections(excluding: Set<String>) -> some View {
    let bookmarks = player.bookmarks.filter { !excluding.contains($0.id) }
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 12) {
        NativeSectionTitle(title: "本地歌单", subtitle: "共 \(player.playlists.count) 个歌单")
        if player.playlists.isEmpty {
          NativeEmptyState(icon: "music.note.list", text: "还没有本地歌单")
        } else {
          NativeCoverGrid {
            ForEach(player.playlists) { playlist in
              NativeCoverCard(
                cover: playlist.tracks.first?.cover, title: playlist.name,
                subtitle: "共 \(playlist.tracks.count) 首", anchor: "cover.local." + playlist.id
              ) { select(playlist) }.contextMenu {
                Button("删除歌单", role: .destructive) { deleting = playlist.id }
              }
            }
          }
        }
      }
      if account.account == nil || !bookmarks.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          NativeSectionTitle(
            title: "收藏的歌单",
            subtitle: bookmarks.isEmpty ? "长按首页推荐歌单，选择“收藏歌单”" : "共 \(bookmarks.count) 个歌单")
          NativeCoverGrid {
            ForEach(bookmarks) { cover in
              NativeCoverCard(
                cover: cover.cover, title: cover.title, subtitle: cover.subtitle,
                anchor: "cover." + cover.id
              ) { open(cover) }.contextMenu {
                Button("取消收藏") { player.toggleBookmark(cover) }
              }
            }
          }
        }
      }
    }
  }
}

/// 原版 Cloud：标题旁带曲目数与容量条，操作行为播放全部、更多与搜索，下方 SongList
@MainActor
struct NativeCloudView: View {
  @ObservedObject var player: NativePlayerStore
  @State private var tracks: [NativeTrack] = []
  @State private var loading = false
  @State private var error: String?
  @State private var hasMore = false
  @State private var count = 0
  @State private var size: Double = 0
  @State private var maxSize: Double = 0
  @State private var query = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 20).padding(.bottom, 8)
      if tracks.isEmpty {
        Group {
          if let error {
            errorState(error)
          } else if loading {
            VStack(spacing: 16) {
              ProgressView().controlSize(.large).tint(Color.nativePrimary.opacity(0.7))
              Text("加载中").font(.system(size: 14))
                .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6))
            }
          } else {
            NativeEmptyState(icon: "cloud", text: "云盘里还没有歌曲")
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        NativeSongCollection(
          title: "我的云盘", tracks: visible, player: player, loading: loading, error: error,
          more: hasMore ? { Task { await load() } } : nil, hidesTitle: true)
      }
    }.task { await load() }
  }

  /// 标题区：30 bold 标题，同基线的曲目数与容量条（高 6 宽 80，轨道 on-surface/10，填充 primary）
  private var header: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text("我的云盘").font(.system(size: 30, weight: .bold))
          .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
          .accessibilityIdentifier("native.wide.pageTitle")
        if total > 0 {
          HStack(spacing: 16) {
            HStack(spacing: 4) {
              Image(systemName: "cloud").font(.system(size: 14))
              Text("共 \(total) 首")
            }
            if maxSize > 0 {
              HStack(spacing: 8) {
                Image(systemName: "internaldrive").font(.system(size: 14))
                Capsule().fill(Color.nativeOnSurface.opacity(0.1)).frame(width: 80, height: 6)
                  .overlay(alignment: .leading) {
                    Capsule().fill(Color.nativePrimary)
                      .frame(width: 80 * min(1, size / maxSize))
                  }.clipShape(Capsule())
                  .animation(.easeOut(duration: 0.3), value: size)
                Text("\(Self.fileSize(size)) / \(Self.fileSize(maxSize))")
                  .font(.system(size: 12))
              }
            }
          }.font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
            .lineLimit(1)
        }
      }
      HStack(spacing: 16) {
        HStack(spacing: 12) {
          NativeSButton(
            title: "播放全部", icon: "play.fill", variant: .secondary, tint: .primary, shape: .round
          ) {
            if let first = visible.first { player.play(first, in: visible, context: "我的云盘") }
          }.disabled(tracks.isEmpty)
          Menu {
            Button {
              Task { await refresh() }
            } label: {
              Label("刷新缓存", systemImage: "arrow.clockwise")
            }
          } label: {
            Image(systemName: "ellipsis").font(.system(size: 18))
              .frame(width: 36, height: 36)
              .background(Color.nativeOnSurface.opacity(0.12), in: Circle())
              .foregroundStyle(Color.nativeOnSurface)
          }.disabled(loading).accessibilityLabel("更多")
        }
        Spacer(minLength: 0)
        if !tracks.isEmpty { NativeSearchInput(text: $query) }
      }
    }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 原版错误态：56 警告图标 red-500/85 半透明，14 medium 标题，12 详情最宽 320，重试按钮
  private func errorState(_ message: String) -> some View {
    VStack(spacing: 0) {
      Image(systemName: "exclamationmark.triangle").font(.system(size: 45, weight: .light))
        .frame(width: 56, height: 56)
        .foregroundStyle(Color(light: 0xEF4444, dark: 0xEF4444).opacity(0.85)).opacity(0.5)
        .padding(.bottom, 12)
      Text("加载失败").font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.nativeOnSurface)
      Text(message).font(.system(size: 12))
        .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
        .frame(maxWidth: 320).padding(.top, 4)
      NativeSButton(
        title: "重试", icon: "arrow.clockwise", variant: .secondary, tint: .primary, shape: .round
      ) { Task { await load() } }.padding(.top, 16)
    }.multilineTextAlignment(.center)
  }

  /// 曲目总数优先取服务端计数
  private var total: Int { count > 0 ? count : tracks.count }

  /// 按标题、歌手、专辑过滤，与歌曲列表的搜索一致
  private var visible: [NativeTrack] {
    let keyword = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !keyword.isEmpty else { return tracks }
    return tracks.filter {
      $0.title.lowercased().contains(keyword) || $0.artist.lowercased().contains(keyword)
        || ($0.album ?? "").lowercased().contains(keyword)
    }
  }

  /// 清空后从第一页重新加载
  private func refresh() async {
    guard !loading else { return }
    tracks = []
    hasMore = false
    await load()
  }

  /// 按页加载当前账号云盘，不在界面保存登录凭据
  private func load() async {
    guard !loading else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let result =
        try await player.service.call(["action": "cloud", "offset": tracks.count]) as? [String: Any]
      try Task.checkCancellation()
      tracks += (result?["tracks"] as? [[String: Any]] ?? []).compactMap(NativeTrack.online)
      hasMore = result?["hasMore"] as? Bool ?? false
      count = result?["count"] as? Int ?? count
      size = result?["size"] as? Double ?? size
      maxSize = result?["maxSize"] as? Double ?? maxSize
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }

  /// 与原版 formatFileSize 一致：B / KB / MB / GB，保留一位小数
  /// @param bytes - 字节数
  /// @returns 可读的容量文本
  private static func fileSize(_ bytes: Double) -> String {
    let units: [(Double, String)] = [(1024 * 1024 * 1024, "GB"), (1024 * 1024, "MB"), (1024, "KB")]
    for (unit, name) in units where bytes >= unit {
      return String(format: "%.1f %@", bytes / unit, name)
    }
    return "\(Int(bytes)) B"
  }
}
