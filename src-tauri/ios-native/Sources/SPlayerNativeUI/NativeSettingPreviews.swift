import SwiftUI

/// 主题模式预览：缩略的侧栏、列表与播放栏，跟随系统显示左右分屏
struct NativeThemePreview: View {
  let mode: String
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        page(dark: mode == "dark")
        if mode == "system" {
          page(dark: true).mask(
            Path { path in
              path.move(to: CGPoint(x: geometry.size.width, y: 0))
              path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
              path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
              path.closeSubpath()
            })
        }
      }
    }
  }

  /// 用主题令牌绘制，并强制对应外观，使预览与真实界面配色一致
  private func page(dark: Bool) -> some View {
    let ink = Color.nativeOnSurface
    return GeometryReader { geometry in
      let unit = geometry.size.width / 24
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: unit * 0.9) {
          ForEach(0..<5) { index in
            Capsule().fill(ink.opacity(index == 0 ? 0.55 : 0.18))
              .frame(width: unit * (index == 0 ? 4.5 : 3.5), height: unit * 0.55)
          }
          Spacer()
        }.padding(unit).frame(width: unit * 7, alignment: .leading)
          .background(Color.nativeSurfacePanel)
        VStack(alignment: .leading, spacing: unit * 0.8) {
          Capsule().fill(ink.opacity(0.7)).frame(width: unit * 6, height: unit * 0.9)
          HStack(spacing: unit * 0.7) {
            ForEach(0..<3) { _ in
              RoundedRectangle(cornerRadius: unit * 0.6).fill(ink.opacity(0.1))
                .aspectRatio(1, contentMode: .fit)
            }
          }
          ForEach(0..<3) { _ in
            HStack(spacing: unit * 0.6) {
              RoundedRectangle(cornerRadius: unit * 0.3).fill(ink.opacity(0.12))
                .frame(width: unit * 1.6, height: unit * 1.6)
              Capsule().fill(ink.opacity(0.16)).frame(height: unit * 0.5)
            }
          }
          Spacer(minLength: 0)
          RoundedRectangle(cornerRadius: unit).fill(Color.nativeSurfacePanel)
            .frame(height: unit * 2.6)
        }.padding(unit)
      }.background(Color.nativeSurface)
    }.environment(\.colorScheme, dark ? .dark : .light)
  }
}

/// 播放器风格预览：按两套播放器的实际布局绘制缩略图，有当前曲目时使用其封面
struct NativePlayerStylePreview: View {
  let style: String
  let cover: String?
  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let unit = size.width / 24
      ZStack {
        NativeArtwork(cover: cover, radius: 0, pixels: 200).blur(radius: unit * 3).scaleEffect(1.4)
        Color.black.opacity(style == "am" ? 0.45 : 0.35)
        if style == "am" { apple(unit: unit) } else { original(unit: unit) }
      }.frame(width: size.width, height: size.height).clipped()
    }.environment(\.colorScheme, .dark)
  }

  /// 原版：左侧圆角封面与信息，右侧歌词，底部居中控制栏
  private func original(unit: CGFloat) -> some View {
    VStack(spacing: unit) {
      HStack(alignment: .center, spacing: unit * 1.5) {
        VStack(alignment: .leading, spacing: unit * 0.6) {
          NativeArtwork(cover: cover, radius: unit * 1.2, pixels: 200)
            .aspectRatio(1, contentMode: .fit).shadow(radius: unit * 0.6)
          Capsule().fill(.white.opacity(0.85)).frame(width: unit * 6, height: unit * 0.7)
          Capsule().fill(.white.opacity(0.4)).frame(width: unit * 4, height: unit * 0.5)
        }.frame(width: unit * 9)
        VStack(alignment: .leading, spacing: unit * 0.9) {
          ForEach(0..<6) { index in
            Capsule().fill(.white.opacity(index == 2 ? 0.95 : 0.22))
              .frame(width: unit * (index == 2 ? 9 : [7, 8, 0, 6, 8, 5][index]), height: unit * 0.75)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: .infinity)
      HStack(spacing: unit * 1.6) {
        ForEach(0..<5) { index in
          Circle().fill(.white.opacity(index == 2 ? 0.3 : 0.7))
            .frame(width: unit * (index == 2 ? 2 : 0.9))
        }
      }
      Capsule().fill(.white.opacity(0.25)).frame(height: unit * 0.3).overlay(alignment: .leading) {
        Capsule().fill(.white.opacity(0.85)).frame(width: unit * 7, height: unit * 0.3)
      }.padding(.horizontal, unit * 5)
    }.padding(unit * 1.5)
  }

  /// AM：顶部短横条、渐隐大封面、左对齐信息与进度、大号播放键
  private func apple(unit: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: unit * 0.8) {
      Capsule().fill(.white.opacity(0.5)).frame(width: unit * 2.5, height: unit * 0.35)
        .frame(maxWidth: .infinity)
      NativeArtwork(cover: cover, radius: 0, pixels: 200).frame(maxHeight: .infinity)
        .mask(
          LinearGradient(
            colors: [.white, .white, .clear], startPoint: .top, endPoint: .bottom))
      Capsule().fill(.white.opacity(0.9)).frame(width: unit * 8, height: unit * 0.8)
      Capsule().fill(.white.opacity(0.5)).frame(width: unit * 5, height: unit * 0.6)
      Capsule().fill(.white.opacity(0.25)).frame(height: unit * 0.3).overlay(alignment: .leading) {
        Capsule().fill(.white.opacity(0.85)).frame(width: unit * 8, height: unit * 0.3)
      }
      HStack {
        Spacer()
        Image(systemName: "backward.fill")
        Spacer()
        Image(systemName: "play.fill").font(.system(size: unit * 2.4))
        Spacer()
        Image(systemName: "forward.fill")
        Spacer()
      }.font(.system(size: unit * 1.5)).foregroundStyle(.white.opacity(0.9))
    }.padding(unit * 1.5)
  }
}
