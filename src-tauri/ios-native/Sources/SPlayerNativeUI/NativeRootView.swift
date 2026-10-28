import SwiftUI
import UniformTypeIdentifiers

private enum NativePresentation: String, Identifiable {
  case music, queue
  var id: String { rawValue }
}

/// 展开与收起播放器的动效：原版上滑、减弱动画淡入、共享封面过渡
private enum NativePlayerMotion {
  case slide, reduced, shared

  var transition: AnyTransition {
    switch self {
    case .slide: return .move(edge: .bottom)
    case .reduced: return .opacity.combined(with: .offset(y: 12))
    case .shared: return .opacity
    }
  }
}

@MainActor
public struct NativeRootView: View {
  @StateObject private var player: NativePlayerStore
  @State private var booting = true
  @State private var page: NativePage = .home
  @State private var previous: NativePage?
  @State private var presentation: NativePresentation?
  @State private var expanded = false
  @State private var coveredColorScheme: ColorScheme?
  @State private var playerCoversStatusBar = true
  @Environment(\.colorScheme) private var colorScheme
  @State private var settings = false
  @State private var account = false
  @State private var recognition = false
  @State private var importAfterSettings = false
  @State private var macImporter = false
  @AppStorage("native.appearance") private var appearance = "system"
  @AppStorage(NativeMotion.routeKey) private var routeTransition = "fade"
  @AppStorage(NativeMotion.seamlessKey) private var seamless = false
  @AppStorage(NativeLayout.sidebarCollapsedKey) private var sidebarCollapsed = false
  @NativeReduceMotion private var reduceMotion
  @StateObject private var flights = NativeCoverFlights()
  @State private var playerMotion = NativePlayerMotion.slide
  /// 从卡片进入详情时记录来源封面，返回时飞回原卡片
  @State private var detailSource: (id: String, cover: String?)?
  /// 共享封面过渡前一帧关闭页面切换动画，旧页面直接移除而不是淡出
  @State private var instantRoute = false
  @Environment(\.scenePhase) private var scenePhase

  /// 为原生入口创建或注入唯一播放器实例
  public init() { _player = StateObject(wrappedValue: NativePlayerStore()) }
  /// 为原生入口创建或注入唯一播放器实例
  public init(player: NativePlayerStore) { _player = StateObject(wrappedValue: player) }

  public var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let wide = NativeLayout.isWide(width)
      let narrow = NativeLayout.isNarrow(width)
      let compact = NativeLayout.isCompact(width)
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          if wide {
            NativeSidebar(
              page: rootPage, player: player, account: player.account,
              collapsed: sidebarCollapsed, openPlaylist: openCover
            ).frame(width: NativeLayout.sidebarWidth(collapsed: sidebarCollapsed)).clipped()
              .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: sidebarCollapsed)
          }
          VStack(spacing: 0) {
            // 设置标签页是根页面：返回、搜索、识曲和打开设置的按钮都不适用
            if page != .settings {
              NativeTopbar(
                catalog: player.catalog, wide: wide, narrow: narrow, compact: compact,
                canBack: previous != nil,
                // 竖屏底部标签已有搜索和设置，顶栏不再重复；竖屏搜索页自带输入框
                showSearch: wide, showSettings: wide,
                back: goBack,
                search: {
                  navigate(.search)
                  player.catalog.search()
                },
                recognize: { recognition = true }, settings: { settings = true },
                accountStore: player.account, account: { account = true },
                favorites: { navigate(.collections) })
            }
            ZStack {
              NativePageContent(
                page: page, player: player, catalog: player.catalog,
                appearance: $appearance, importMusic: startImport,
                openPlaylist: openCover,
                openLocalPlaylist: { playlist in
                  player.selectedPlaylistID = playlist.id
                  openDetail(
                    .localPlaylist, source: "cover.local." + playlist.id,
                    cover: playlist.tracks.first?.cover)
                },
                navigate: navigate
              )
              // 不透明底色：移除中的旧页面不会透出到新页面下
              .background(Color.nativeSurface)
              .environment(\.nativeWide, wide)
              .environment(\.nativeViewport, width)
              .id(page)
              // 共享封面过渡期间页面直接切换，只让封面移动
              .transition(
                instantRoute || flights.flight != nil
                  ? .identity : NativeMotion.route(routeTransition, reduce: reduceMotion))
            }.animation(instantRoute ? nil : .easeOut(duration: 0.25), value: page)
          }
        }
        if player.current != nil || player.loadingTrack != nil {
          NativePlaybackBar(
            player: player, wide: wide, compact: compact,
            showPlayer: {
              coveredColorScheme = colorScheme
              playerCoversStatusBar = true
              setExpanded(true)
            },
            showQueue: { presentation = .queue })
        }
        if !wide {
          #if os(iOS)
            NativeBottomTabs(selection: rootPage).frame(height: 64)
          #else
            HStack { ForEach(NativePage.tabs) { item in Button(item.rawValue) { page = item } } }
              .padding()
          #endif
        }
      }.background(Color.nativeSurface)
    }
    .environment(\.colorScheme, expanded ? coveredColorScheme ?? colorScheme : colorScheme)
    .overlay { if booting { NativeSplashView().transition(.opacity) } }
    .tint(.nativePrimary)
    .preferredColorScheme(presentationColorScheme)
    .task {
      async let entrance: Void = Task.sleep(nanoseconds: 1_100_000_000)
      await player.loadLibrary()
      _ = try? await entrance
      withAnimation(.easeOut(duration: 0.2)) { booting = false }
      // 登录态决定首页是专属歌单还是推荐歌单，先确认账号再拉取
      await player.account.refresh()
      await player.catalog.loadHome(loggedIn: player.account.account != nil)
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
        NativeAccountsView(service: player.service, account: player.account).toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("完成") { account = false } }
        }
      }
    }
    .sheet(isPresented: $recognition) {
      NativeRecognitionView(player: player) { keyword in
        recognition = false
        player.catalog.query = keyword
        navigate(.search)
        player.catalog.search()
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
        }
      ).nativeSettingsSizing()
    }
    #if os(iOS)
      .allowsHitTesting(!expanded)
      .accessibilityHidden(expanded)
      .overlay {
        if expanded {
          NativeNowPlayingView(
            player: player,
            close: { setExpanded(false) },
            onDragReveal: { revealed in playerCoversStatusBar = !revealed }
          )
          .transition(playerMotion.transition)
        }
      }
    #else
      .sheet(isPresented: $expanded) { NativeNowPlayingView(player: player) }
      .fileImporter(
        isPresented: $macImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true
      ) { result in
        if case .success(let urls) = result { Task { await player.importFiles(urls) } }
      }
    #endif
    .environment(\.nativeHiddenCovers, flights.hidden)
    .overlayPreferenceValue(NativeCoverAnchorKey.self) { anchors in
      NativeCoverFlightLayer(flights: flights, anchors: anchors)
    }
    .overlay(alignment: .top) { NativePluginNotice(plugins: player.plugins) }
    .overlay(alignment: .top) { NativeNoticeBanner(player: player) }
    .animation(.easeOut(duration: 0.25), value: player.notice)
    .overlay {
      if player.importing {
        ProgressView("正在导入音乐…").padding(24).background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { player.error != nil && !expanded }, set: { if !$0 { player.error = nil } })
    ) {
      Button("好") { player.error = nil }
    } message: {
      Text(player.error ?? "")
    }
  }

  /// 播放器覆盖状态栏时使用浅色文字，原页面保持打开前的主题
  private var presentationColorScheme: ColorScheme? {
    #if os(iOS)
      if expanded && playerCoversStatusBar { return .dark }
    #endif
    return appearance == "dark" ? .dark : appearance == "light" ? .light : nil
  }

  /// 侧栏与底部标签切换的是根页面，不保留返回位置
  private var rootPage: Binding<NativePage> {
    Binding(
      get: { page },
      set: { next in
        previous = nil
        detailSource = nil
        page = next
      })
  }

  /// 保留返回位置，页面切换不重建播放器
  private func navigate(_ target: NativePage) {
    if page != target {
      previous = page
      page = target
      detailSource = nil
    }
  }

  private var sharedMotion: Bool { seamless && !reduceMotion }

  /// 打开歌单、专辑或歌手卡片
  /// @param cover - 卡片
  private func openCover(_ cover: NativeCover) {
    player.catalog.open(cover)
    openDetail(.playlist, source: "cover." + cover.id, cover: cover.cover)
  }

  /// 从卡片打开详情；开启共享元素过渡时封面从卡片移动到详情头部
  /// @param target - 详情页面
  /// @param source - 卡片封面标识
  /// @param cover - 封面地址
  private func openDetail(_ target: NativePage, source: String, cover: String?) {
    guard sharedMotion, flights.canFly(from: source) else { return navigate(target) }
    instantly {
      flights.fly(
        from: source, to: "cover.hero", cover: cover, duration: 0.26, curve: [0.16, 1, 0.3, 1]
      ) { navigate(target) }
      detailSource = (source, cover)
    }
  }

  /// 先渲染一帧无动画的页面容器，再执行切换；封面落地后恢复页面切换动画
  /// @param change - 页面切换
  private func instantly(_ change: @escaping () -> Void) {
    instantRoute = true
    // 主队列异步块可能在本轮渲染前执行，等待一帧确保旧页面已改为无过渡
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
      change()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { instantRoute = false }
    }
  }

  /// 返回上一页；从卡片进入的详情返回时封面飞回卡片
  private func goBack() {
    guard let previous else { return }
    let source = detailSource
    let change = {
      page = previous
      self.previous = nil
      detailSource = nil
    }
    if sharedMotion, let source, flights.canFly(from: "cover.hero") {
      instantly {
        flights.fly(
          from: "cover.hero", to: source.id, cover: source.cover, duration: 0.26,
          curve: [0.16, 1, 0.3, 1], change: change)
      }
    } else {
      change()
    }
  }

  /// 展开或收起全屏播放器，按设置选择上滑、淡入或共享封面过渡
  /// @param value - 是否展开
  private func setExpanded(_ value: Bool) {
    guard expanded != value else { return }
    let from = value ? "player.bar" : "player.full"
    if reduceMotion {
      playerMotion = .reduced
      withAnimation(.easeOut(duration: 0.24)) { expanded = value }
    } else if seamless, flights.canFly(from: from) {
      playerMotion = .shared
      let duration = value ? 0.36 : 0.34
      flights.fly(
        from: from, to: value ? "player.full" : "player.bar", cover: player.current?.cover,
        duration: duration, curve: value ? [0.25, 1, 0.35, 1] : [0.2, 0.9, 0.3, 1]
      ) {
        withAnimation(.easeOut(duration: duration)) { expanded = value }
      }
    } else {
      playerMotion = .slide
      withAnimation(.easeOut(duration: 0.3)) { expanded = value }
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
  @AppStorage("native.download.enabled") private var downloadEnabled = false
  @Binding var page: NativePage
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var account: NativeAccountStore
  /// 开启“折叠侧边栏”时收为 64 图标栏：只留图标，隐藏分组标题
  let collapsed: Bool
  let openPlaylist: (NativeCover) -> Void
  /// 与原版侧栏一致，“我的歌单”可在本地与在线之间切换
  @AppStorage("native.sidebar.playlistSource") private var playlistSource = "local"
  private var online: Bool { playlistSource == "online" && account.account != nil }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        NativeLogo().frame(width: 30, height: 30)
        if !collapsed {
          Text("SPlayer").font(.custom("Poppins-Medium", size: 22)).foregroundStyle(
            Color.nativePrimary
          ).fixedSize().transition(.opacity)
        }
      }
      .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 64)
      ScrollView {
        VStack(spacing: 4) {
          ForEach([NativePage.home, .library, .artists, .albums, .folders, .stats]) { item in
            row(item)
          }
          divider
          ForEach(
            [NativePage.liked, .collections, .cloud] + (downloadEnabled ? [.downloads] : [])
              + [.history]
          ) { item in row(item) }
          divider
          if !collapsed {
            playlistHeader
          }
          if online, let user = account.account {
            ForEach(user.created) { cover in onlineRow(cover) }
          } else {
            ForEach(player.playlists) { playlist in
              menuItem(
                icon: "music.note.list", title: playlist.name,
                selected: page == .localPlaylist && player.selectedPlaylistID == playlist.id
              ) {
                player.selectedPlaylistID = playlist.id
                page = .localPlaylist
              }.contextMenu {
                Button("删除歌单", role: .destructive) { deleting = playlist.id }
              }
            }
          }
          if let user = account.account, !user.subscribed.isEmpty {
            divider
            if !collapsed {
              HStack {
                Text("收藏的歌单")
                Spacer()
              }.font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
                .padding(.horizontal, 12).frame(minHeight: 40)
            }
            ForEach(user.subscribed) { cover in onlineRow(cover) }
          }
        }.padding(.horizontal, collapsed ? 8 : 12).padding(.bottom, 12)
      }.scrollIndicators(collapsed ? .hidden : .automatic)
    }
    // 原版侧栏是实色面板 + 右侧 primary/10 边线，不是毛玻璃
    .background(Color.nativeSurfacePanel)
    .overlay(alignment: .trailing) {
      Rectangle().fill(Color.nativePrimary.opacity(0.1)).frame(width: 1)
    }
    .accessibilityElement(children: .contain).accessibilityIdentifier("native.wide.sidebar")
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

  /// “我的歌单”分组标题：登录后可切换本地与在线，本地时带新建按钮
  private var playlistHeader: some View {
    HStack(spacing: 4) {
      if account.account != nil {
        Menu {
          Picker("我的歌单", selection: $playlistSource) {
            Text("本地歌单").tag("local")
            Text("在线歌单").tag("online")
          }
        } label: {
          HStack(spacing: 4) {
            Text("我的歌单")
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium))
          }
        }.accessibilityIdentifier("native.sidebar.playlistSource")
      } else {
        Text("我的歌单")
      }
      Spacer()
      if !online {
        NativeSButton(icon: "plus", variant: .tertiary, size: .custom(26), shape: .circle) {
          name = ""
          creating = true
        }.accessibilityLabel("新建歌单")
      }
    }.font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
      .padding(.leading, 12).padding(.trailing, 4).frame(minHeight: 40)
  }

  private var divider: some View {
    Rectangle().fill(Color.nativeOnSurface.opacity(0.1)).frame(height: 1)
      .padding(.horizontal, 4).padding(.vertical, 8)
  }

  /// 账号中的在线歌单行
  private func onlineRow(_ cover: NativeCover) -> some View {
    menuItem(icon: "music.note.list", title: cover.title, selected: false) {
      openPlaylist(cover)
    }.accessibilityIdentifier("native.sidebar.online." + cover.id)
  }

  /// 导航行使用完整可点击区域，支持 VoiceOver
  private func row(_ item: NativePage) -> some View {
    menuItem(icon: item.icon, title: item.rawValue, selected: page == item) { page = item }
      .accessibilityIdentifier("native.wide.nav." + item.rawValue)
  }

  /// SMenu medium 项：高 42，选中为 primary/10 底色、primary 文字和左侧 3px 指示条
  private func menuItem(
    icon: String, title: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: collapsed ? 0 : 12) {
        // 图标栏只留 22 图标，标题交给 VoiceOver 与指针悬停提示
        Image(systemName: icon).font(.system(size: collapsed ? 19 : 17))
          .frame(width: collapsed ? 22 : 20)
        if !collapsed { Text(title).font(.system(size: 14)).lineLimit(1) }
        Spacer(minLength: 0)
      }
      .foregroundStyle(selected ? Color.nativePrimary : Color.nativeOnSurface.opacity(0.8))
      .padding(.horizontal, 12).frame(height: 42).contentShape(Rectangle())
      .background(
        selected ? Color.nativePrimary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay(alignment: .leading) {
        if selected {
          Capsule().fill(Color.nativePrimary).frame(width: 3).padding(.vertical, 8)
        }
      }
    }.buttonStyle(NativePressStyle()).accessibilityLabel(title)
      .accessibilityAddTraits(selected ? .isSelected : []).help(collapsed ? title : "")
  }
}

@MainActor
struct NativeTopbar: View {
  @ObservedObject var catalog: NativeCatalogStore
  let wide: Bool
  /// 窗口 <1200：账号胶囊只留头像
  let narrow: Bool
  /// 窗口 <1024：搜索框收窄到 160
  let compact: Bool
  let canBack: Bool
  let showSearch: Bool
  let showSettings: Bool
  let back: () -> Void
  let search: () -> Void
  let recognize: () -> Void
  let settings: () -> Void
  @ObservedObject var accountStore: NativeAccountStore
  let account: () -> Void
  let favorites: () -> Void
  var body: some View {
    NativeGlassGroup {
      HStack(spacing: 12) {
        // 宽屏与原版桌面端一致常驻返回键；竖屏标签根页面没有可返回的页面时不显示
        if wide || canBack {
          NativeIconButton(icon: "chevron.left", title: "返回", action: back).disabled(!canBack)
        }
        if showSearch {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15))
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
            TextField("搜索歌曲、歌手或专辑", text: $catalog.query).textFieldStyle(.plain)
              .font(.system(size: 16)).onSubmit(search).accessibilityIdentifier(
                "native.search.input")
          }.padding(.horizontal, 16).frame(width: compact ? 160 : 240, height: 40)
            .nativeGlass(in: Capsule())
        }
        NativeIconButton(icon: "waveform", title: "听歌识曲", action: recognize)
          .accessibilityIdentifier("native.recognition")
        Spacer(minLength: 8)
        NativeAccountButton(
          account: accountStore, avatarOnly: narrow, manage: account, favorites: favorites)
        if showSettings {
          NativeIconButton(icon: "gearshape", title: "全局设置", action: settings)
            .accessibilityIdentifier("native.wide.settings")
        }
      }.padding(.horizontal, 12).frame(height: wide ? 64 : 56)
    }
  }
}
