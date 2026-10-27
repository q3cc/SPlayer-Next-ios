import CoreText
import SwiftUI

/// 复用 Next 的启动字形、标志尺寸、入场节奏及底部三点
struct NativeSplashView: View {
  @Environment(\.colorScheme) private var scheme
  @NativeReduceMotion private var reduceMotion
  @Environment(\.scenePhase) private var phase
  @State private var entered = false
  private static let registerFont: Void = {
    if let url = Bundle.module.url(forResource: "Logo", withExtension: "ttf") {
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }()
  var body: some View {
    let _ = Self.registerFont
    ZStack {
      (scheme == .dark
        ? Color(red: 16 / 255, green: 16 / 255, blue: 20 / 255) : Color(white: 246 / 255))
        .ignoresSafeArea()
      VStack(spacing: 24) {
        NativeLogo(branded: true).frame(width: 80, height: 80)
          .scaleEffect(entered || reduceMotion ? 1 : 0.97)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: entered)
        Text("SPlayer Next").font(.custom("Poppins-Medium", size: 36))
          .opacity(entered ? 1 : 0).offset(y: entered || reduceMotion ? 0 : 16)
          .scaleEffect(entered || reduceMotion ? 1 : 0.97)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(0.26), value: entered)
      }
      VStack {
        Spacer()
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || phase != .active))
        { context in
          HStack(spacing: 8) {
            ForEach(0..<3) { index in
              let wave = max(
                0,
                sin(
                  (context.date.timeIntervalSinceReferenceDate - Double(index) * 0.18) / 1.1 * 2
                    * .pi))
              Circle().fill(Color(red: 254 / 255, green: 121 / 255, blue: 113 / 255))
                .frame(width: 8, height: 8).opacity(reduceMotion ? 0.6 : 0.25 + wave * 0.75)
                .offset(y: reduceMotion ? 0 : -3 * wave)
            }
          }
        }.padding(.bottom, 25).opacity(entered ? 1 : 0)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(0.42), value: entered)
        Text("SPlayer Next · © 2026 imsyy").font(.system(size: 12)).opacity(entered ? 0.4 : 0)
          .offset(y: entered || reduceMotion ? 0 : 16)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(0.5), value: entered)
      }.padding(.bottom, 20)
    }.accessibilityIdentifier("native.splash")
      .onAppear { entered = true }
  }
}
