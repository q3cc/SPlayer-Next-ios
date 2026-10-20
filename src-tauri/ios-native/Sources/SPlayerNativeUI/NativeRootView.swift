import SwiftUI
import UniformTypeIdentifiers

private enum NativePresentation: String, Identifiable {
  case music, queue
  var id: String { rawValue }
}

@MainActor
public struct NativeRootView: View {
  @StateObject private var player: NativePlayerStore
  @State private var page: NativePage = .home
  @State private var previous: NativePage?
  @State private var presentation: NativePresentation?
  @State private var expanded = false
  @State private var settings = false
  @State private var account = false
  @State private var importAfterSettings = false
  @State private var macImporter = false
  @AppStorage("native.appearance") private var appearance = "system"
  @Environment(\.scenePhase) private var scenePhase

  /// 为原生入口创建或注入唯一播放器实例
  public init() { _player = StateObject(wrappedValue: NativePlayerStore()) }
  /// 为原生入口创建或注入唯一播放器实例
  public init(player: NativePlayerStore) { _player = StateObject(wrappedValue: player) }

  public var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 1000
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          if wide {
            NativeSidebar(page: $page, player: player).frame(width: 240)
            Divider()
          }
          VStack(spacing: 0) {
            NativeTopbar(
              catalog: player.catalog, wide: wide, canBack: previous != nil,
              back: {
                if let previous {
                  page = previous
                  self.previous = nil
                }
              },
              search: {
                navigate(.search)
                player.catalog.search()
              },
              settings: { settings = true }, account: { account = true })
            NativePageContent(
              page: page, player: player, catalog: player.catalog,
              appearance: $appearance, importMusic: startImport,
              openPlaylist: {
                player.catalog.open($0)
                navigate(.playlist)
              },
              navigate: navigate)
          }
        }
        if player.current != nil || player.loadingTrack != nil {
          NativePlaybackBar(
            player: player, wide: wide, showPlayer: { expanded = true },
            showQueue: { presentation = .queue })
        }
        if !wide {
          #if os(iOS)
            NativeBottomTabs(selection: $page).frame(height: 64)
          #else
            HStack { ForEach(NativePage.tabs) { item in Button(item.rawValue) { page = item } } }
              .padding()
          #endif
        }
      }.background(Color.nativeCanvas)
    }
    .tint(.primary)
    .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    .task {
      await player.loadLibrary()
      await player.catalog.loadHome()
    }
    .onChange(of: scenePhase) { player.setInterfaceActive($0 == .active) }
    .sheet(item: $presentation) { item in
      switch item {
      case .music:
        #if os(iOS)
          NativeDocumentPicker { urls in
            presentation = nil
            if !urls.isEmpty { Task { await player.importFiles(urls) } }
          }
        #else
          EmptyView()
        #endif
      case .queue: NativeQueueView(player: player)
      }
    }
    .sheet(isPresented: $account) {
      NavigationStack {
        NativeAccountsView(service: player.service).toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("完成") { account = false } }
        }
      }
    }
    .sheet(
      isPresented: $settings,
      onDismiss: {
        if importAfterSettings {
          importAfterSettings = false
          startImport()
        }
      }
    ) {
      NativeSettingsView(
        player: player, appearance: $appearance,
        importMusic: {
          importAfterSettings = true
          settings = false
        })
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $expanded) { NativeNowPlayingView(player: player) }
    #else
      .sheet(isPresented: $expanded) { NativeNowPlayingView(player: player) }
      .fileImporter(
        isPresented: $macImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true
      ) { result in
        if case .success(let urls) = result { Task { await player.importFiles(urls) } }
      }
    #endif
    .overlay(alignment: .top) { NativePluginNotice(plugins: player.plugins) }
    .overlay {
      if player.importing {
        ProgressView("正在导入音乐…").padding(24).background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .alert(
      "操作失败",
      isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })
    ) {
      Button("好") { player.error = nil }
    } message: {
      Text(player.error ?? "")
    }
  }

  /// 保留返回位置，页面切换不重建播放器
  private func navigate(_ target: NativePage) {
    if page != target {
      previous = page
      page = target
    }
  }
  /// 从原生文件选择器导入，不暴露应用沙盒路径
  private func startImport() {
    guard !player.importing else { return }
    #if os(iOS)
      presentation = .music
    #else
      macImporter = true
    #endif
  }
}

@MainActor
struct NativeSidebar: View {
  @State private var creating = false
  @State private var name = ""
  @State private var deleting: String?
  @Binding var page: NativePage
  @ObservedObject var player: NativePlayerStore
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        NativeLogo().frame(width: 30, height: 30)
        Text("SPlayer").font(.system(size: 22, weight: .semibold))
      }
      .frame(height: 64).frame(maxWidth: .infinity)
      ScrollView {
        VStack(spacing: 2) {
          ForEach([NativePage.home, .library, .artists, .albums, .folders, .stats]) { item in
            row(item)
          }
          Divider().padding(.vertical, 12)
          ForEach([NativePage.liked, .collections, .cloud, .history]) { item in row(item) }
          Divider().padding(.vertical, 12)
          HStack {
            Text("我的歌单")
            Image(systemName: "chevron.down")
            Spacer()
            Button {
              name = ""
              creating = true
            } label: {
              Image(systemName: "plus").frame(width: 32, height: 32)
            }.accessibilityLabel("新建歌单")
          }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 12)
          ForEach(player.playlists) { playlist in
            Button {
              player.selectedPlaylistID = playlist.id
              page = .localPlaylist
            } label: {
              HStack {
                Image(systemName: "music.note.list")
                Text(playlist.name).lineLimit(1)
                Spacer()
              }.font(.system(size: 14)).padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).contextMenu {
              Button("删除歌单", role: .destructive) { deleting = playlist.id }
            }
          }
        }.padding(.horizontal, 12)
      }
    }.background(.regularMaterial).accessibilityElement(children: .contain).accessibilityIdentifier(
      "native.wide.sidebar"
    )
    .alert("新建本地歌单", isPresented: $creating) {
      TextField("歌单名称", text: $name)
      Button("取消", role: .cancel) {}
      Button("创建") {
        player.createPlaylist(name)
        page = .localPlaylist
      }
    }
    .confirmationDialog(
      "删除此歌单？音乐文件不会被删除",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("删除歌单", role: .destructive) {
        if let deleting { player.deletePlaylist(deleting) }
        deleting = nil
      }
    }
  }
  /// 导航行使用完整可点击区域，支持 VoiceOver
  private func row(_ item: NativePage) -> some View {
    Button {
      page = item
    } label: {
      HStack(spacing: 12) {
        Image(systemName: item.icon).frame(width: 20)
        Text(item.rawValue).font(.system(size: 14))
        Spacer()
      }
      .padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
      .background(
        page == item ? Color.primary.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay(alignment: .leading) {
        if page == item { Capsule().frame(width: 3, height: 20).padding(.leading, 2) }
      }
    }.buttonStyle(.plain).accessibilityIdentifier("native.wide.nav." + item.rawValue)
  }
}

@MainActor
struct NativeTopbar: View {
  @ObservedObject var catalog: NativeCatalogStore
  let wide: Bool
  let canBack: Bool
  let back: () -> Void
  let search: () -> Void
  let settings: () -> Void
  let account: () -> Void
  @State private var searching = false
  var body: some View {
    NativeGlassGroup {
      HStack(spacing: 12) {
        NativeIconButton(icon: "chevron.left", title: "返回", action: back).disabled(!canBack)
        if wide || searching {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索歌曲、歌手", text: $catalog.query).textFieldStyle(.plain)
              .font(.system(size: 14)).onSubmit(search).accessibilityIdentifier(
                "native.search.input")
          }.padding(.horizontal, 14).frame(maxWidth: wide ? 280 : .infinity).frame(height: 40)
            .nativeGlass(in: Capsule())
        } else {
          NativeIconButton(icon: "magnifyingglass", title: "搜索") {
            searching = true
            search()
          }
        }
        Spacer(minLength: 8)
        NativeIconButton(icon: "person.crop.circle", title: "平台账号", action: account)
        NativeIconButton(icon: "gearshape", title: "全局设置", action: settings)
          .accessibilityIdentifier("native.wide.settings")
      }.padding(.horizontal, 12).frame(height: wide ? 64 : 56)
    }
  }
}
