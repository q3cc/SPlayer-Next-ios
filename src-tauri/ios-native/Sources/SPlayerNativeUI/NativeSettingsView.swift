import SwiftUI

/// 设置大分类，顺序与名称沿用 main 的 settingsSchema；没有原生实现的分类不显示
enum NativeSettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case general, appearance, player, lyric, desktopLyric, services, download, localCache, plugins,
    other, about
  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: return "常规设置"
    case .appearance: return "外观设置"
    case .player: return "播放设置"
    case .lyric: return "歌词设置"
    case .desktopLyric: return "桌面歌词"
    case .services: return "网络与服务"
    case .download: return "下载配置"
    case .localCache: return "本地与缓存"
    case .plugins: return "插件管理"
    case .other: return "其他设置"
    case .about: return "关于软件"
    }
  }
  /// 侧栏图标底色，参照系统设置的分类配色
  var color: Color {
    switch self {
    case .general: return .gray
    case .appearance: return .blue
    case .player: return .pink
    case .lyric: return .purple
    case .desktopLyric: return .red
    case .services: return .teal
    case .download: return .cyan
    case .localCache: return .orange
    case .plugins: return .green
    case .other: return .indigo
    case .about: return .gray
    }
  }
  var icon: String {
    switch self {
    case .general: return "gearshape.fill"
    case .appearance: return "paintpalette.fill"
    case .player: return "play.fill"
    case .lyric: return "quote.bubble.fill"
    case .desktopLyric: return "pip.fill"
    case .services: return "globe"
    case .download: return "arrow.down.circle.fill"
    case .localCache: return "internaldrive.fill"
    case .plugins: return "puzzlepiece.extension.fill"
    case .other: return "slider.horizontal.3"
    case .about: return "info"
    }
  }
}

@MainActor
struct NativeSettingsView: View {
  @ObservedObject var player: NativePlayerStore
  @Binding var appearance: String
  let importMusic: () -> Void
  /// 弹层入口显示“完成”；标签页入口没有可关闭的层级
  var presented = true
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var sizeClass
  @AppStorage("native.settings.category") private var lastCategory = "general"
  @State private var selection: NativeSettingsCategory?
  @State private var width: CGFloat = 0

  var body: some View {
    Group {
      if presented { split } else { embedded }
    }
    // 设置页沿用系统设置配色：蓝色强调、绿色开关，不继承主界面的单色强调
    .tint(.blue)
    .toggleStyle(SwitchToggleStyle(tint: .green))
    .onChange(of: selection) { next in
      if let next { lastCategory = next.rawValue }
    }
  }

  /// 弹层：系统分栏，与 main 的设置弹窗一致
  private var split: some View {
    NavigationSplitView {
      List(selection: $selection) {
        ForEach(NativeSettingsCategory.allCases) { category in
          NavigationLink(value: category) {
            Label {
              Text(category.title)
            } icon: {
              NativeSettingIcon(symbol: category.icon, color: category.color)
            }
          }.accessibilityIdentifier("native.settings.category.\(category.rawValue)")
        }
      }.navigationTitle("全局设置")
        .toolbar {
          if presented {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
          }
        }
        .nativeFixedSidebar()
        // 与 main 的 SettingsContent 一致：640–900pt 宽度下侧栏收窄为 12rem，其余为 w-70
        .navigationSplitViewColumnWidth(width > 0 && width <= 900 ? 192 : 280)
    } detail: {
      NavigationStack {
        page(selection ?? NativeSettingsCategory(rawValue: lastCategory) ?? .general)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .background {
      GeometryReader { geometry in
        Color.clear.onAppear { width = geometry.size.width }
          .onChange(of: geometry.size.width) { width = $0 }
      }
    }
    .onAppear {
      // 与 main 一致记忆上次分类；窄屏折叠为列表时不自动跳入详情
      if sizeClass == .regular, selection == nil {
        selection = NativeSettingsCategory(rawValue: lastCategory) ?? .general
      }
    }
  }

  /// 标签页：嵌在主界面里，使用主界面的画布底色和侧栏行样式，不再叠一层系统分栏
  @ViewBuilder private var embedded: some View {
    let current = selection ?? NativeSettingsCategory(rawValue: lastCategory) ?? .general
    if sizeClass == .compact {
      NavigationStack {
        List(NativeSettingsCategory.allCases) { category in
          NavigationLink { page(category) } label: { categoryLabel(category) }
        }.navigationTitle("全局设置")
          .scrollContentBackground(.hidden).background(Color.nativeCanvas)
      }
    } else {
      HStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 2) {
            ForEach(NativeSettingsCategory.allCases) { category in
              categoryRow(category, selected: category == current)
            }
          }.padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 16)
        }.frame(width: width > 0 && width <= 900 ? 200 : 240)
        // 根页面隐藏导航栏，用与其他页面一致的 30pt 标题；二级页面仍有系统返回栏
        NavigationStack {
          VStack(alignment: .leading, spacing: 0) {
            Text(current.title).font(.system(size: 30, weight: .bold))
              .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 4)
            // 表单直接画在主界面画布上，分组卡片保持系统白色
            page(current).scrollContentBackground(.hidden)
          }
          .background(Color.nativeCanvas.ignoresSafeArea())
          #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
          #endif
        }
        .environment(\.nativeSettingsEmbedded, true)
        .id(current)
      }
      .background(Color.nativeCanvas)
      .background {
        GeometryReader { geometry in
          Color.clear.onAppear { width = geometry.size.width }
            .onChange(of: geometry.size.width) { width = $0 }
        }
      }
    }
  }

  private func categoryLabel(_ category: NativeSettingsCategory) -> some View {
    Label {
      Text(category.title)
    } icon: {
      NativeSettingIcon(symbol: category.icon, color: category.color)
    }
  }

  /// 与主界面侧栏一致：选中行浅色底和左侧指示条
  private func categoryRow(_ category: NativeSettingsCategory, selected: Bool) -> some View {
    Button {
      selection = category
    } label: {
      HStack(spacing: 12) {
        NativeSettingIcon(symbol: category.icon, color: category.color, size: 26)
        Text(category.title).font(.system(size: 15, weight: selected ? .semibold : .regular))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12).frame(height: 46).contentShape(Rectangle())
      .background(
        selected ? Color.primary.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 10))
      .overlay(alignment: .leading) {
        if selected { Capsule().fill(Color.primary).frame(width: 3, height: 20).padding(.leading, 2) }
      }
    }.buttonStyle(.plain)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityIdentifier("native.settings.category.\(category.rawValue)")
  }

  @ViewBuilder
  private func page(_ category: NativeSettingsCategory) -> some View {
    switch category {
    case .general: NativeGeneralSettings(player: player, appearance: $appearance)
    case .appearance:
      NativeAppearanceSettings(appearance: $appearance, cover: player.current?.cover)
    case .player: NativePlayerSettings(player: player)
    case .lyric: NativeLyricSettings()
    case .desktopLyric: NativeLyricPiPSettings(player: player, pip: player.lyricPiP)
    case .download: NativeDownloadSettings()
    case .services: NativeServiceSettings(player: player)
    case .localCache: NativeLocalSettings(player: player, importMusic: importMusic)
    case .plugins: NativePluginsView(plugins: player.plugins)
    case .other: NativeOtherSettings(player: player)
    case .about: NativeAboutSettings()
    }
  }
}

private struct NativeSettingsEmbeddedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// 设置嵌在主界面标签页中，二级页面需与主界面画布一致
  var nativeSettingsEmbedded: Bool {
    get { self[NativeSettingsEmbeddedKey.self] }
    set { self[NativeSettingsEmbeddedKey.self] = newValue }
  }
}

private struct NativeSettingsPageModifier: ViewModifier {
  @Environment(\.nativeSettingsEmbedded) private var embedded
  func body(content: Content) -> some View {
    if embedded {
      content.scrollContentBackground(.hidden)
        .background(Color.nativeCanvas.ignoresSafeArea())
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
    } else {
      content
    }
  }
}

extension View {
  /// 设置二级页面：标签页中画在主界面画布上并使用行内标题，弹层中保持系统样式
  func nativeSettingsPage() -> some View { modifier(NativeSettingsPageModifier()) }

  /// 与 main 一致侧栏常驻；窄侧栏不再挤占标题位置
  @ViewBuilder
  func nativeFixedSidebar() -> some View {
    if #available(iOS 17.0, macOS 14.0, *) {
      toolbar(removing: .sidebarToggle)
    } else {
      self
    }
  }

  /// iPad 上以页面尺寸展示设置，留出与 main 设置弹窗相同的左侧分类栏
  @ViewBuilder
  func nativeSettingsSizing() -> some View {
    if #available(iOS 18.0, macOS 15.0, *) {
      presentationSizing(.page)
    } else {
      self
    }
  }
}
