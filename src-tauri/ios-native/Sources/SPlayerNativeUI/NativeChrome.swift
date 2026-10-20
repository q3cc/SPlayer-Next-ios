import SwiftUI

#if os(iOS)
  import UIKit
#endif

enum NativePage: String, CaseIterable, Identifiable {
  case home = "首页"
  case search = "搜索"
  case library = "音乐库"
  case artists = "艺术家"
  case albums = "专辑"
  case cloud = "我的云盘"
  case collections = "我的收藏"
  case localPlaylist = "本地歌单"
  case folders = "文件夹"
  case stats = "统计"
  case liked = "我喜欢的音乐"
  case history = "播放历史"
  case playlist = "歌单"
  case settings = "全局设置"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .cloud: return "cloud"
    case .collections: return "star"
    case .localPlaylist: return "music.note.list"
    case .home: return "house"
    case .search: return "magnifyingglass"
    case .library: return "books.vertical"
    case .artists: return "person"
    case .albums: return "opticaldisc"
    case .folders: return "folder"
    case .stats: return "chart.bar"
    case .liked: return "heart"
    case .history: return "clock.arrow.circlepath"
    case .playlist: return "music.note.list"
    case .settings: return "gearshape"
    }
  }
  static let tabs: [NativePage] = [.home, .search, .library, .liked, .settings]
}

extension Color {
  static let splayerAccent = Color.primary
  static let nativeCanvas = Color(light: 0xF6F6F6, dark: 0x101014)
  static let nativePanel = Color(light: 0xFFFFFF, dark: 0x18181C)
  /// 保存系统标签栏与 SwiftUI 页面之间的绑定
  private init(light: UInt, dark: UInt) {
    #if os(iOS)
      self.init(
        uiColor: UIColor { traits in
          let value = traits.userInterfaceStyle == .dark ? dark : light
          return UIColor(
            red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255,
            blue: Double(value & 255) / 255, alpha: 1)
        })
    #else
      self.init(white: 0.96)
    #endif
  }
}

struct NativeIconButton: View {
  let icon: String
  let title: String
  var highlighted = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: 19, weight: .regular))
        .frame(width: 40, height: 40)
        .nativeGlass(in: Circle())
        .contentShape(Circle())
    }.buttonStyle(.plain).accessibilityLabel(title)
  }
}

struct NativeTrackRow: View {
  let track: NativeTrack
  let selected: Bool
  var body: some View {
    HStack(spacing: 12) {
      NativeArtwork(cover: track.cover).frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 5) {
        Text(track.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
          .lineLimit(1)
        Text(track.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if let source = track.source {
        Text(
          source == "netease"
            ? "网易云" : source == "qqmusic" ? "QQ" : source == "plugin" ? "自定义源" : "酷狗"
        ).font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Text(NativeNowPlayingView.time(track.durationMs)).font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
    }.padding(.vertical, 8).contentShape(Rectangle())
  }
}

#if os(iOS)
  /// UIKit 底部标签栏固定在 iPad 竖屏底部，不被新版系统自动迁移到顶部
  struct NativeBottomTabs: UIViewRepresentable {
    @Binding var selection: NativePage
    /// 把系统文件选择结果转交给唯一导入入口
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    /// 创建系统原生控件并配置初始外观
    func makeUIView(context: Context) -> UITabBar {
      let bar = UITabBar()
      if #available(iOS 17.0, *) { bar.traitOverrides.horizontalSizeClass = .compact }
      bar.itemPositioning = .fill
      let appearance = UITabBarAppearance()
      appearance.configureWithDefaultBackground()
      bar.standardAppearance = appearance
      bar.scrollEdgeAppearance = appearance
      bar.tintColor = .label
      bar.unselectedItemTintColor = .secondaryLabel
      bar.items = NativePage.tabs.enumerated().map { index, page in
        UITabBarItem(
          title: page == .liked ? "喜欢" : page == .settings ? "设置" : page.rawValue,
          image: UIImage(systemName: page.icon), tag: index)
      }
      bar.delegate = context.coordinator
      bar.accessibilityIdentifier = "native.tabs"
      return bar
    }
    /// 仅同步绑定状态，不重建系统控件
    func updateUIView(_ bar: UITabBar, context: Context) {
      context.coordinator.parent = self
      let selected = bar.items?[NativePage.tabs.firstIndex(of: selection) ?? 0]
      if bar.selectedItem !== selected { bar.selectedItem = selected }
    }
    final class Coordinator: NSObject, UITabBarDelegate {
      var parent: NativeBottomTabs
      /// 保存系统标签栏与 SwiftUI 页面之间的绑定
      init(_ parent: NativeBottomTabs) { self.parent = parent }
      /// 把原生标签选中事件映射回应用页面
      func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        parent.selection = NativePage.tabs[item.tag]
      }
    }
  }
#endif
