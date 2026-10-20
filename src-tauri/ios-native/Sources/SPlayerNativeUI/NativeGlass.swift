import SwiftUI

/// 控制区使用系统液态玻璃；降低透明度时优先保证文字和图标对比度
private struct NativeGlassModifier<S: Shape>: ViewModifier {
  let shape: S
  let interactive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  /// 根据系统版本与辅助功能设置应用原生控制材质
  @ViewBuilder func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Color.nativePanel, in: shape)
    } else {
      #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
          content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
          content.background(.regularMaterial, in: shape)
        }
      #else
        content.background(.regularMaterial, in: shape)
      #endif
    }
  }
}

extension View {
  /// 只给导航和悬浮控制添加材质，不给滚动列表逐行增加合成层
  func nativeGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
    modifier(NativeGlassModifier(shape: shape, interactive: interactive))
  }
}

/// 相邻系统玻璃控件共享一个渲染容器，保持系统交互和材质衔接
struct NativeGlassGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @ViewBuilder var body: some View {
    #if compiler(>=6.2)
      if #available(iOS 26.0, macOS 26.0, *) {
        GlassEffectContainer(spacing: 8, content: content)
      } else {
        content()
      }
    #else
      content()
    #endif
  }
}
