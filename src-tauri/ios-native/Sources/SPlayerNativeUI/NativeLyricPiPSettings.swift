import SwiftUI

/// 桌面歌词（系统画中画）设置，选项与默认值对应 iOS 版 settings/schema.ts 的 mobileExternalLyric
@MainActor
struct NativeLyricPiPSettings: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var pip: NativeLyricPiP
  @AppStorage("native.pip.frameRate") private var frameRate = 20.0
  @AppStorage("native.pip.doubleLine") private var doubleLine = false
  @AppStorage("native.pip.showTranslation") private var showTranslation = true
  @AppStorage("native.pip.fontSize") private var fontSize = 24.0
  @AppStorage("native.pip.playedColor") private var playedColor = "#FE7971FF"
  @AppStorage("native.pip.unplayedColor") private var unplayedColor = "#FFFFFFFF"

  var body: some View {
    NativeSettingsList {
      NativeSettingSection(
        "桌面歌词", footer: NativeLyricPiP.supported ? nil : "此设备不支持画中画"
      ) {
        VStack(alignment: .leading, spacing: 8) {
          preview
          Text("效果预览，随当前歌曲更新。").font(.system(size: 12))
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
        }
        Toggle(
          isOn: Binding(get: { pip.active || pip.starting }, set: { _ in pip.toggle() })
        ) {
          NativeSettingLabel(title: "开启桌面歌词", detail: "先播放歌曲。小窗可拖动、缩放，关闭不影响播放。")
        }.disabled(!NativeLyricPiP.supported).accessibilityIdentifier("native.settings.pip.enabled")
        NativeSettingPicker(
          title: "歌词帧率", detail: "控制小窗歌词和唱片动画的帧率。越高越流畅，也更耗电；默认 20 FPS。",
          selection: $frameRate
        ) {
          ForEach(NativePiPOptions.frameRates, id: \.self) { Text("\(Int($0)) FPS").tag($0) }
        }
        Toggle(isOn: $doubleLine) {
          NativeSettingLabel(title: "双行歌词", detail: "上下交替，预告下一句。关闭为单行；有音译或翻译时显示附加歌词。")
        }
        Toggle(isOn: $showTranslation) {
          NativeSettingLabel(title: "显示音译和翻译", detail: "显示在当前句下方。")
        }
        NativeSettingPicker(title: "字号", detail: "长句随歌词时间横向滚动。", selection: $fontSize) {
          ForEach(16...40, id: \.self) { Text("\($0)").tag(Double($0)) }
        }
        ColorPicker(selection: color($playedColor), supportsOpacity: true) {
          NativeSettingLabel(title: "高亮颜色", detail: "当前句或已唱部分。")
        }
        ColorPicker(selection: color($unplayedColor), supportsOpacity: true) {
          NativeSettingLabel(title: "普通颜色", detail: "未唱部分和附加歌词。")
        }
      }
    }.navigationTitle("桌面歌词")
  }

  /// 与小窗共用绘制代码；预览按所选帧率刷新
  @ViewBuilder private var preview: some View {
    #if os(iOS)
      TimelineView(.periodic(from: .now, by: 1 / max(5, frameRate))) { _ in
        if let image = pip.preview() {
          Image(uiImage: image).resizable().aspectRatio(4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("native.settings.pip.preview")
        } else {
          unavailable
        }
      }
    #else
      unavailable
    #endif
  }

  private var unavailable: some View {
    Text("预览暂不可用").font(.system(size: 14))
      .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7)).frame(maxWidth: .infinity)
  }

  /// 颜色以 #RRGGBBAA 保存，与小窗绘制共用解析
  private func color(_ hex: Binding<String>) -> Binding<Color> {
    Binding(
      get: {
        Color(cgColor: (NativePiPColor(hex: hex.wrappedValue) ?? NativePiPColor(r: 255, g: 255, b: 255)).cgColor)
      },
      set: { value in
        guard let components = value.cgColor?.converted(
          to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
          .components, components.count >= 3
        else { return }
        hex.wrappedValue =
          NativePiPColor(
            r: (components[0] * 255).rounded(), g: (components[1] * 255).rounded(),
            b: (components[2] * 255).rounded(), a: components.count > 3 ? components[3] : 1
          ).hex
      })
  }
}

/// 播放器菜单中的歌词小窗开关，单独观察小窗状态
@MainActor
struct NativePiPMenuButton: View {
  @ObservedObject var pip: NativeLyricPiP
  var body: some View {
    Button(pip.active || pip.starting ? "关闭歌词小窗" : "开启歌词小窗") { pip.toggle() }
  }
}
