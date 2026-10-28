import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// 原版 `--s-*` 色板令牌，数值取自 `src/utils/color.ts` 的默认主题（种子 #fe7971，非全局着色）
extension Color {
  /// 应用背景 surface
  static let nativeSurface = Color(light: 0xF6F6F6, dark: 0x101014)
  /// 对话框 surface-alt
  static let nativeSurfaceAlt = Color(light: 0xFAFAFB, dark: 0x27272A)
  /// 卡片、歌曲行、设置项、侧栏 surface-panel
  static let nativeSurfacePanel = Color(light: 0xFFFFFF, dark: 0x18181C)
  /// 弹出层、菜单、Toast surface-bright
  static let nativeSurfaceBright = Color(light: 0xFFFFFF, dark: 0x48484E)
  static let nativeOnSurface = Color(light: 0x18181B, dark: 0xE4E4E7)
  static let nativeOnSurfaceVariant = Color(light: 0x71717A, dark: 0xA1A1AA)
  static let nativeOutlineVariant = Color(light: 0xE4E4E7, dark: 0x2E2E33)
  /// 主题主色：secondary 色调 T10 / T90
  static let nativePrimary = Color(light: 0x2C1513, dark: 0xFFDAD6)
  static let nativeOnPrimary = Color(light: 0xFFFFFF, dark: 0x2C1513)
  static let nativePrimaryContainer = Color(light: 0xFFDAD6, dark: 0x5D3F3D)

  /// 按系统外观切换的十六进制颜色
  /// @param light - 浅色值
  /// @param dark - 深色值
  init(light: UInt, dark: UInt) {
    #if os(iOS)
      self.init(
        uiColor: UIColor { traits in
          Self.platformColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    #else
      self.init(
        nsColor: NSColor(name: nil) { appearance in
          Self.platformColor(
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    #endif
  }

  #if os(iOS)
    private static func platformColor(_ value: UInt) -> UIColor {
      UIColor(
        red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255,
        blue: Double(value & 255) / 255, alpha: 1)
    }
  #else
    private static func platformColor(_ value: UInt) -> NSColor {
      NSColor(
        red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255,
        blue: Double(value & 255) / 255, alpha: 1)
    }
  #endif
}

/// 原版唯一的布局断点：宽度不超过 900 为紧凑布局
enum NativeLayout {
  static let compactMaxWidth: CGFloat = 900
  /// 是否使用宽布局（侧栏、通栏播放栏）
  static func isWide(_ width: CGFloat) -> Bool { width > compactMaxWidth }
  /// “折叠侧边栏”设置，默认关闭；与上游不同，窄窗口不强制收起
  static let sidebarCollapsedKey = "native.appearance.sidebarCollapsed"
  /// 上游 dev 窄窗口：<1200 账号胶囊只留头像
  static func isNarrow(_ width: CGFloat) -> Bool { width < 1200 }
  /// 上游 dev 紧凑布局：<1024 播放栏改紧凑排布、顶栏搜索框收窄
  static func isCompact(_ width: CGFloat) -> Bool { width < 1024 }
  /// 侧栏宽度：展开 240，收起 64
  /// @param collapsed - 是否收为图标栏
  static func sidebarWidth(collapsed: Bool) -> CGFloat { collapsed ? 64 : 240 }
}

private struct NativeWideKey: EnvironmentKey {
  static let defaultValue = true
}

private struct NativeViewportKey: EnvironmentKey {
  static let defaultValue: CGFloat = 1180
}

extension EnvironmentValues {
  /// 外壳当前是否为宽布局（侧栏 + 通栏播放栏），页面据此决定页内元素
  var nativeWide: Bool {
    get { self[NativeWideKey.self] }
    set { self[NativeWideKey.self] = newValue }
  }
  /// 窗口宽度：原版页内断点按整个视口计算，与侧栏是否收起无关
  var nativeViewport: CGFloat {
    get { self[NativeViewportKey.self] }
    set { self[NativeViewportKey.self] = newValue }
  }
}

/// SButton 的变体
enum NativeButtonVariant {
  case filled, secondary, tertiary, ghost, text
}

/// SButton 的颜色类型；cover 用于全屏播放器内的封面色
enum NativeButtonTint {
  case neutral, primary, error
  case cover(Color)

  var color: Color {
    switch self {
    case .neutral: return .nativeOnSurface
    case .primary: return .nativePrimary
    case .error: return Color(light: 0xEF4444, dark: 0xEF4444)
    case .cover(let color): return color
    }
  }
}

/// SButton 的尺寸：高、横向内边距、文字与图标字号
enum NativeButtonSize {
  case tiny, small, medium, large
  case custom(CGFloat)

  var height: CGFloat {
    switch self {
    case .tiny: return 24
    case .small: return 32
    case .medium: return 36
    case .large: return 40
    case .custom(let value): return value
    }
  }
  var padding: CGFloat {
    switch self {
    case .tiny: return 6
    case .small: return 10
    case .medium: return 14
    case .large: return 18
    case .custom(let value): return value * 0.35
    }
  }
  var font: CGFloat {
    switch self {
    case .tiny: return 12
    case .large: return 16
    default: return 14
    }
  }
  var icon: CGFloat {
    switch self {
    case .tiny: return 14
    case .small: return 16
    case .medium: return 18
    case .large: return 20
    case .custom(let value): return (value * 0.5).rounded()
    }
  }
}

/// SButton 外形：普通圆角 6、胶囊、圆形
enum NativeButtonShape {
  case normal, round, circle
}

/// 原版 SButton：触控设备没有悬停，按下时使用原版 active 透明度并缩放到 0.96
struct NativeButtonStyle: ButtonStyle {
  var variant: NativeButtonVariant = .secondary
  var tint: NativeButtonTint = .neutral
  var size: NativeButtonSize = .medium
  var shape: NativeButtonShape = .normal

  func makeBody(configuration: Configuration) -> some View {
    NativeButtonBody(configuration: configuration, style: self)
  }

  /// 文字与背景色；按下时取 active 档
  fileprivate func colors(pressed: Bool) -> (foreground: Color, background: Color) {
    let base = tint.color
    var neutral = false
    var filledForeground = Color.white
    switch tint {
    case .neutral:
      neutral = true
      filledForeground = .nativeSurface
    case .primary: filledForeground = .nativeOnPrimary
    default: break
    }
    switch variant {
    case .filled:
      return (filledForeground, base.opacity(pressed ? 0.8 : 1))
    case .secondary:
      return (base, base.opacity(neutral ? (pressed ? 0.24 : 0.12) : (pressed ? 0.28 : 0.16)))
    case .tertiary:
      return (base, base.opacity(neutral ? (pressed ? 0.16 : 0.05) : (pressed ? 0.2 : 0.08)))
    case .ghost:
      return (base, base.opacity(pressed ? (neutral ? 0.14 : 0.16) : 0))
    case .text:
      return (base.opacity(pressed ? 0.7 : 1), .clear)
    }
  }
}

private struct NativeButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let style: NativeButtonStyle
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    let colors = style.colors(pressed: configuration.isPressed)
    let shape = RoundedRectangle(
      cornerRadius: style.shape == .normal ? 6 : style.size.height / 2)
    configuration.label
      .font(.system(size: style.size.font))
      .lineLimit(1)
      .padding(.horizontal, style.shape == .circle ? 0 : style.size.padding)
      .frame(width: style.shape == .circle ? style.size.height : nil, height: style.size.height)
      .foregroundStyle(colors.foreground)
      .background(colors.background, in: shape)
      .contentShape(shape)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .opacity(enabled ? 1 : 0.5)
      .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
  }
}

/// 列表、菜单项的按下态：触控没有悬停，按下时叠加原版 hover/active 的 on-surface 遮罩
struct NativePressStyle: ButtonStyle {
  var radius: CGFloat = 8
  var amount = 0.08

  func makeBody(configuration: Configuration) -> some View {
    configuration.label.overlay(
      RoundedRectangle(cornerRadius: radius).fill(
        Color.nativeOnSurface.opacity(configuration.isPressed ? amount : 0)
      ).allowsHitTesting(false))
  }
}

/// 图标加文字的 SButton，图标按尺寸取原版图标字号
struct NativeSButton: View {
  var title: String? = nil
  var icon: String? = nil
  var variant: NativeButtonVariant = .secondary
  var tint: NativeButtonTint = .neutral
  var size: NativeButtonSize = .medium
  var shape: NativeButtonShape = .normal
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let icon { Image(systemName: icon).font(.system(size: size.icon)) }
        if let title { Text(title) }
      }
    }
    .buttonStyle(NativeButtonStyle(variant: variant, tint: tint, size: size, shape: shape))
    .accessibilityLabel(title ?? "")
  }
}

/// 通用页面标题区：30 bold 标题与同基线的元信息，下方是操作行
struct NativePageHeader<Actions: View>: View {
  let title: String
  var meta: [(icon: String, text: String)] = []
  /// 只加在标题文字上的可访问性标识，不影响操作行里按钮的标识
  var titleID: String? = nil
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(Color.nativeOnSurface)
          .lineLimit(1).accessibilityIdentifier(titleID ?? "")
        ForEach(meta, id: \.text) { item in
          HStack(spacing: 4) {
            Image(systemName: item.icon).font(.system(size: 14))
            Text(item.text)
          }.font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
            .lineLimit(1)
        }
      }
      actions()
    }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension NativePageHeader where Actions == EmptyView {
  init(title: String, meta: [(icon: String, text: String)] = [], titleID: String? = nil) {
    self.init(title: title, meta: meta, titleID: titleID) { EmptyView() }
  }
}

/// 区块标题：18 semibold，可带 12 号副标题
struct NativeSectionTitle: View {
  let title: String
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.nativeOnSurface)
      if let subtitle {
        Text(subtitle).font(.system(size: 12))
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 空状态：48 图标 30% 透明度、14 号说明、可选提示与按钮
struct NativeEmptyState<Action: View>: View {
  let icon: String
  let text: String
  var hint: String? = nil
  var iconSize: CGFloat = 48
  @ViewBuilder var action: () -> Action

  var body: some View {
    VStack(spacing: 0) {
      Image(systemName: icon).font(.system(size: iconSize * 0.8, weight: .light))
        .frame(width: iconSize, height: iconSize).opacity(0.3).padding(.bottom, 12)
      Text(text).font(.system(size: 14)).foregroundStyle(
        Color.nativeOnSurfaceVariant.opacity(0.5))
      if let hint {
        Text(hint).font(.system(size: 12)).foregroundStyle(
          Color.nativeOnSurfaceVariant.opacity(0.35)
        ).padding(.top, 4)
      }
      action().padding(.top, 16)
    }.multilineTextAlignment(.center).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
      .frame(maxWidth: .infinity).padding(.vertical, 48)
  }
}

extension NativeEmptyState where Action == EmptyView {
  init(icon: String, text: String, hint: String? = nil, iconSize: CGFloat = 48) {
    self.init(icon: icon, text: text, hint: hint, iconSize: iconSize) { EmptyView() }
  }
}

/// STabs：bar 为下方 24×3 指示条，segment 为带底框的分段
struct NativeTabs<Value: Hashable>: View {
  enum Style { case bar, segment }
  @Binding var selection: Value
  let items: [(value: Value, title: String)]
  var style: Style = .bar
  var large = false
  /// segment 是否为胶囊外形
  var round = false
  @NativeReduceMotion private var reduceMotion
  @Namespace private var indicator

  var body: some View {
    if style == .bar {
      HStack(spacing: 12) {
        ForEach(items, id: \.value) { item in
          let active = item.value == selection
          Button {
            select(item.value)
          } label: {
            Text(item.title).font(.system(size: large ? 16 : 14, weight: active ? .medium : .regular))
              .foregroundStyle(active ? Color.nativePrimary : Color.nativeOnSurfaceVariant)
              .padding(.horizontal, large ? 14 : 12).frame(height: large ? 40 : 32)
              .overlay(alignment: .bottom) {
                if active {
                  Capsule().fill(Color.nativePrimary).frame(width: 24, height: 3)
                    .padding(.bottom, 2)
                    .matchedGeometryEffect(id: "indicator", in: indicator)
                }
              }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
        }
      }.padding(.bottom, 4)
    } else {
      let radius: CGFloat = round ? (large ? 20 : 16) : 8
      HStack(spacing: 4) {
        ForEach(items, id: \.value) { item in
          let active = item.value == selection
          Button {
            select(item.value)
          } label: {
            Text(item.title).font(.system(size: 14, weight: active ? .medium : .regular))
              .foregroundStyle(Color.nativeOnSurface)
              .frame(maxWidth: .infinity).frame(height: (large ? 40 : 32) - 4)
              .padding(.horizontal, 12)
              .background {
                if active {
                  RoundedRectangle(cornerRadius: round ? radius - 2 : 6)
                    .fill(Color.nativePrimary.opacity(0.12))
                    .matchedGeometryEffect(id: "indicator", in: indicator)
                }
              }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
        }
      }.padding(2)
        .background(Color.nativeOnSurface.opacity(0.03), in: RoundedRectangle(cornerRadius: radius))
        .overlay(
          RoundedRectangle(cornerRadius: radius).stroke(Color.nativeOnSurface.opacity(0.15)))
    }
  }

  private func select(_ value: Value) {
    withAnimation(reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.32)) {
      selection = value
    }
  }
}

extension View {
  /// SCard：实色面板 + 1px primary/20 边框
  /// @param radius - 圆角，默认 lg 8，首页与统计为 xl 12
  func nativeCard(radius: CGFloat = 8) -> some View {
    background(Color.nativeSurfacePanel, in: RoundedRectangle(cornerRadius: radius))
      .overlay(
        RoundedRectangle(cornerRadius: radius).stroke(Color.nativePrimary.opacity(0.2), lineWidth: 1))
  }

  /// 页面内容的标准外边距：横 20，上 8，下 20
  func nativePagePadding() -> some View {
    padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
  }
}

/// 原版 CoverCard：圆角 12 卡片，正方形封面（歌手为圆形），信息区 76 高
struct NativeCoverCard: View {
  let cover: String?
  let title: String
  var subtitle: String? = nil
  /// 歌手卡片：圆形封面、居中文字、按下无底色
  var round = false
  /// 共享封面过渡锚点
  var anchor: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: round ? .center : .leading, spacing: 0) {
        artwork.aspectRatio(1, contentMode: .fit)
        VStack(alignment: round ? .center : .leading, spacing: 2) {
          Text(title).font(.system(size: 14)).foregroundStyle(Color.nativeOnSurface)
            .lineLimit(2).lineSpacing(2.5).multilineTextAlignment(round ? .center : .leading)
          if let subtitle, !subtitle.isEmpty {
            Text(subtitle).font(.system(size: 12)).lineLimit(1)
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
          }
        }.padding(10).frame(
          maxWidth: .infinity, minHeight: 76, maxHeight: 76,
          alignment: round ? .top : .topLeading)
      }.contentShape(RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(NativeCoverCardStyle(round: round))
  }

  @ViewBuilder private var artwork: some View {
    let radius: CGFloat = round ? 1000 : 12
    if let anchor {
      NativeArtwork(cover: cover, radius: radius).nativeCoverAnchor(anchor, radius: radius)
    } else {
      NativeArtwork(cover: cover, radius: radius)
    }
  }
}

/// 封面卡片按下：底色 primary/10（歌手卡片无底色），封面亮度 0.8
private struct NativeCoverCardStyle: ButtonStyle {
  let round: Bool
  @NativeReduceMotion private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .brightness(configuration.isPressed && !reduceMotion ? -0.08 : 0)
      .background(
        Color.nativePrimary.opacity(configuration.isPressed && !round ? 0.1 : 0),
        in: RoundedRectangle(cornerRadius: 12)
      )
      .animation(.easeOut(duration: 0.3), value: configuration.isPressed)
  }
}

/// 原版 CoverList：列数 = floor((宽 + 间距) / (最小宽 + 间距))
struct NativeCoverGrid<Content: View>: View {
  /// 最小列宽：歌单/专辑 140，歌手 120
  var minimum: CGFloat = 140
  /// 列间距：默认 20，首页 16
  var spacing: CGFloat = 20
  @ViewBuilder let content: () -> Content

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: .top)],
      alignment: .leading, spacing: spacing, content: content)
  }
}

/// 页面标题区的 SInput round 搜索框：高 36，宽 160，聚焦或有内容时 224
struct NativeSearchInput: View {
  @Binding var text: String
  var placeholder = "搜索"
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 14))
        .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4))
      TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 14))
        .focused($focused)
    }.padding(.horizontal, 12).frame(width: focused || !text.isEmpty ? 224 : 160, height: 36)
      .background(Color.nativeOnSurface.opacity(focused ? 0.08 : 0.03), in: Capsule())
      .overlay(
        Capsule().stroke(
          focused ? Color.nativePrimary : Color.nativeOnSurface.opacity(0.15), lineWidth: 1)
      )
      .animation(.easeOut(duration: 0.25), value: focused)
  }
}
