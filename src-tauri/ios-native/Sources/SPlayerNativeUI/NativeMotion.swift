import SwiftUI

/// 过渡与动画设置，对应原版外观设置的“过渡与动画”分组
enum NativeMotion {
  static let reduceKey = "native.appearance.reduceMotion"
  static let routeKey = "native.appearance.routeTransition"
  static let seamlessKey = "native.appearance.seamlessTransition"

  /// 页面切换过渡；减弱动画时只保留 150ms 透明度，与原版 reduced-motion.css 一致
  static func route(_ style: String, reduce: Bool) -> AnyTransition {
    if reduce || style == "fade" {
      return .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
    let enter = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.15).delay(0.1)
    let leave = Animation.easeIn(duration: 0.1)
    switch style {
    case "slide":
      return .asymmetric(
        insertion: .offset(x: 6).combined(with: .opacity).animation(enter),
        removal: .offset(x: -6).combined(with: .opacity).animation(leave))
    case "zoom":
      return .asymmetric(
        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(enter),
        removal: .scale(scale: 1.02).combined(with: .opacity).animation(leave))
    default:
      return .identity
    }
  }
}

/// 系统“减弱动态效果”或应用内“减弱动画”任一开启即生效
@propertyWrapper
struct NativeReduceMotion: DynamicProperty {
  @Environment(\.accessibilityReduceMotion) private var system
  @AppStorage(NativeMotion.reduceKey) private var app = false
  var wrappedValue: Bool { system || app }
}

/// 参与共享过渡的封面位置；只在开启共享元素过渡时上报
struct NativeCoverAnchor {
  let bounds: Anchor<CGRect>
  let radius: CGFloat
}

struct NativeCoverAnchorKey: PreferenceKey {
  static let defaultValue: [String: NativeCoverAnchor] = [:]
  static func reduce(
    value: inout [String: NativeCoverAnchor], nextValue: () -> [String: NativeCoverAnchor]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

private struct NativeHiddenCoversKey: EnvironmentKey {
  static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
  /// 飞行中的封面由覆盖层绘制，源与目标暂时隐藏
  var nativeHiddenCovers: Set<String> {
    get { self[NativeHiddenCoversKey.self] }
    set { self[NativeHiddenCoversKey.self] = newValue }
  }
}

private struct NativeCoverAnchorModifier: ViewModifier {
  let id: String
  let radius: CGFloat
  @Environment(\.nativeHiddenCovers) private var hidden
  @AppStorage(NativeMotion.seamlessKey) private var seamless = false
  @NativeReduceMotion private var reduceMotion

  func body(content: Content) -> some View {
    if seamless && !reduceMotion {
      content.opacity(hidden.contains(id) ? 0 : 1)
        .anchorPreference(key: NativeCoverAnchorKey.self, value: .bounds) {
          [id: NativeCoverAnchor(bounds: $0, radius: radius)]
        }
    } else {
      content
    }
  }
}

extension View {
  /// 标记可共享过渡的封面
  /// @param id - 跨页面一致的封面标识
  /// @param radius - 封面圆角，飞行时在两端之间插值
  func nativeCoverAnchor(_ id: String, radius: CGFloat) -> some View {
    modifier(NativeCoverAnchorModifier(id: id, radius: radius))
  }
}

/// 一次封面飞行；起点在发起时记录，终点在目标封面挂载后实时解析
struct NativeCoverFlight: Equatable {
  let token: Int
  let from: String
  let to: String
  let cover: String?
  let start: CGRect
  let startRadius: CGFloat
  let duration: Double
  let curve: [Double]
  var arrived = false
}

/// 共享元素过渡控制器：用覆盖层绘制一张缩略图，从源封面位置移动到目标封面位置
@MainActor
final class NativeCoverFlights: ObservableObject {
  @Published private(set) var flight: NativeCoverFlight?
  /// 最近一次渲染解析出的封面位置；收起播放器时目标已移除，起点只能取这里
  private var rects: [String: (CGRect, CGFloat)] = [:]
  private var bounds = CGRect.zero
  private var token = 0
  private var arrivalScheduled = false

  var hidden: Set<String> { flight.map { [$0.from, $0.to] } ?? [] }

  /// 发起飞行并执行界面切换；源封面不可见时只执行切换
  /// @param from - 源封面标识
  /// @param to - 目标封面标识
  /// @param cover - 飞行中绘制的封面地址
  /// @param duration - 飞行时长（秒）
  /// @param curve - 三次贝塞尔控制点
  /// @param change - 引起目标封面挂载或源封面移除的状态变更
  /// @returns 是否发起了飞行
  @discardableResult
  func fly(
    from: String, to: String, cover: String?, duration: Double,
    curve: [Double] = [0.25, 1, 0.35, 1], change: () -> Void
  ) -> Bool {
    guard canFly(from: from), let (rect, radius) = rects[from] else {
      change()
      return false
    }
    token += 1
    let current = token
    arrivalScheduled = false
    flight = NativeCoverFlight(
      token: current, from: from, to: to, cover: cover, start: rect, startRadius: radius,
      duration: duration, curve: curve)
    change()
    // 目标长时间未挂载（例如全屏封面布局没有封面）时放弃飞行，直接显示目标页面
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.flight?.token == current, self.flight?.arrived == false else { return }
      self.flight = nil
    }
    return true
  }

  /// 源封面当前是否可见，决定是否走共享过渡
  /// @param id - 源封面标识
  /// @returns 是否可以发起飞行
  func canFly(from id: String) -> Bool {
    rects[id].map { bounds.intersects($0.0) } ?? false
  }

  /// 在覆盖层渲染时同步封面位置，目标出现后在下一帧开始移动
  /// @param anchors - 当前界面上报的封面锚点
  /// @param proxy - 覆盖层几何信息
  func sync(_ anchors: [String: NativeCoverAnchor], in proxy: GeometryProxy) {
    bounds = CGRect(origin: .zero, size: proxy.size)
    rects = anchors.mapValues { (proxy[$0.bounds], $0.radius) }
    guard let flight, !flight.arrived, !arrivalScheduled else { return }
    // 切换后的首次渲染就应出现目标；不存在或不在可视区（例如懒加载列表未渲染该卡片）时放弃
    arrivalScheduled = true
    let visible = rects[flight.to].map { bounds.intersects($0.0) } ?? false
    DispatchQueue.main.async { [weak self] in
      guard let self, self.flight?.token == flight.token else { return }
      guard visible else {
        self.flight = nil
        return
      }
      let c = flight.curve
      withAnimation(.timingCurve(c[0], c[1], c[2], c[3], duration: flight.duration)) {
        self.flight?.arrived = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + flight.duration) {
        if self.flight?.token == flight.token { self.flight = nil }
      }
    }
  }
}

/// 覆盖层：绘制飞行中的封面
struct NativeCoverFlightLayer: View {
  @ObservedObject var flights: NativeCoverFlights
  let anchors: [String: NativeCoverAnchor]

  var body: some View {
    GeometryReader { proxy in
      let _ = flights.sync(anchors, in: proxy)
      if let flight = flights.flight {
        let target = flight.arrived ? anchors[flight.to] : nil
        let rect = target.map { proxy[$0.bounds] } ?? flight.start
        // 飞行期间使用与列表相同的 300px 缩略图，命中内存缓存，避免等待高清图
        NativeArtwork(cover: flight.cover, radius: target?.radius ?? flight.startRadius)
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }
}
