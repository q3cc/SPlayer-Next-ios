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
      let wide = geometry.size.width >= 1000
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          if wide {
            NativeSidebar(page: rootPage, player: player).frame(width: 240)
            Divider()
          }
          VStack(spacing: 0) {
            // 设置标签页是根页面：返回、搜索、识曲和打开设置的按钮都不适用
            if page != .settings {
              NativeTopbar(
                catalog: player.catalog, wide: wide, canBack: previous != nil,
                // 竖屏底部标签已有搜索和设置，顶栏不再重复；搜索页自带输入框
                showSearch: wide && page != .search, showSettings: wide,
                back: goBack,
                search: {
                  navigate(.search)
                  player.catalog.search()
                },
                recognize: { recognition = true }, settings: { settings = true },
                account: { account = true })
            }
            ZStack {
              NativePageContent(
                page: page, player: player, catalog: player.catalog,
                appearance: $appearance, importMusic: startImport,
                openPlaylist: { cover in
                  player.catalog.open(cover)
                  openDetail(.playlist, source: "cover." + cover.id, cover: cover.cover)
                },
                openLocalPlaylist: { playlist in
                  player.selectedPlaylistID = playlist.id
                  openDetail(
                    .localPlaylist, source: "cover.local." + playlist.id,
                    cover: playlist.tracks.first?.cover)
                },
                navigate: navigate
              )
              // 不透明底色：移除中的旧页面不会透出到新页面下
              .background(Color.nativeCanvas)
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
            player: player, wide: wide,
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
      }.background(Color.nativeCanvas)
    }
    .environment(\.colorScheme, expanded ? coveredColorScheme ?? colorScheme : colorScheme)
    .overlay { if booting { NativeSplashView().transition(.opacity) } }
    .tint(.primary)
    .preferredColorScheme(presentationColorScheme)
    .task {
      async let entrance: Void = Task.sleep(nanoseconds: 1_100_000_000)
      await player.loadLibrary()
      _ = try? await entrance
      withAnimation(.easeOut(duration: 0.2)) { booting = false }
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
          ForEach(
            [NativePage.liked, .collections, .cloud, .history]
              + (downloadEnabled ? [.downloads] : [])
          ) { item in row(item) }
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
  let showSearch: Bool
  let showSettings: Bool
  let back: () -> Void
  let search: () -> Void
  let recognize: () -> Void
  let settings: () -> Void
  let account: () -> Void
  var body: some View {
    NativeGlassGroup {
      HStack(spacing: 12) {
        // 宽屏与原版桌面端一致常驻返回键；竖屏标签根页面没有可返回的页面时不显示
        if wide || canBack {
          NativeIconButton(icon: "chevron.left", title: "返回", action: back).disabled(!canBack)
        }
        if showSearch {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索歌曲、歌手", text: $catalog.query).textFieldStyle(.plain)
              .font(.system(size: 14)).onSubmit(search).accessibilityIdentifier(
                "native.search.input")
          }.padding(.horizontal, 14).frame(maxWidth: 280).frame(height: 40)
            .nativeGlass(in: Capsule())
        }
        NativeIconButton(icon: "waveform", title: "听歌识曲", action: recognize)
          .accessibilityIdentifier("native.recognition")
        Spacer(minLength: 8)
        NativeIconButton(icon: "person.crop.circle", title: "平台账号", action: account)
        if showSettings {
          NativeIconButton(icon: "gearshape", title: "全局设置", action: settings)
            .accessibilityIdentifier("native.wide.settings")
        }
      }.padding(.horizontal, 12).frame(height: wide ? 64 : 56)
    }
  }
}
