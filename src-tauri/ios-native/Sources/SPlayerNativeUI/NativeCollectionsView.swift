import SwiftUI

@MainActor
struct NativeCollectionsView: View {
  @ObservedObject var player: NativePlayerStore
  let open: (NativeCover) -> Void
  let select: (String) -> Void
  @State private var creating = false
  @State private var name = ""
  @State private var deleting: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text("我的收藏").font(.system(size: 30, weight: .bold))
          Spacer()
          Button {
            creating = true
          } label: {
            Label("新建歌单", systemImage: "plus")
          }
        }
        Text("收藏的歌单").font(.headline)
        if player.bookmarks.isEmpty { Text("长按首页推荐歌单，选择“收藏歌单”").foregroundStyle(.secondary) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 24) {
          ForEach(player.bookmarks) { cover in
            Button {
              open(cover)
            } label: {
              VStack(alignment: .leading, spacing: 10) {
                NativeArtwork(cover: cover.cover).aspectRatio(1, contentMode: .fit)
                Text(cover.title).font(.system(size: 14)).lineLimit(2)
              }
            }.buttonStyle(.plain).contextMenu { Button("取消收藏") { player.toggleBookmark(cover) } }
          }
        }
        Text("本地歌单").font(.headline)
        ForEach(player.playlists) { playlist in
          Button {
            select(playlist.id)
          } label: {
            HStack(spacing: 16) {
              NativeArtwork(cover: playlist.tracks.first?.cover).frame(width: 52, height: 52)
              Text(playlist.name)
              Spacer()
              Text("\(playlist.tracks.count) 首").foregroundStyle(.secondary)
              Image(systemName: "chevron.right")
            }
            .padding(12).background(Color.nativePanel, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
          }.buttonStyle(.plain).contextMenu {
            Button("删除歌单", role: .destructive) { deleting = playlist.id }
          }
        }
      }.padding(24)
    }.alert("新建本地歌单", isPresented: $creating) {
      TextField("歌单名称", text: $name)
      Button("取消", role: .cancel) {}
      Button("创建") {
        player.createPlaylist(name)
        name = ""
        if let id = player.selectedPlaylistID { select(id) }
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
}

@MainActor
struct NativeCloudView: View {
  @ObservedObject var player: NativePlayerStore
  @State private var tracks: [NativeTrack] = []
  @State private var loading = false
  @State private var error: String?
  @State private var hasMore = false
  var body: some View {
    VStack {
      NativeSongCollection(
        title: "我的云盘", tracks: tracks, player: player, loading: loading, error: error,
        more: hasMore ? { Task { await load() } } : nil)
      if error != nil { Button("重试") { Task { await load() } }.padding() }
    }.task { await load() }
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
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}
