import SwiftUI

/// 歌词设置，分区、范围与默认值对应 main 的 lyric 分类；原生歌词舞台不含 AMLL 专属项
struct NativeLyricSettings: View {
  @AppStorage("native.player.style") private var style = "original"
  @AppStorage("native.lyric.adaptive") private var adaptive = true
  @AppStorage("native.lyric.fontSize") private var fontSize = 48.0
  @AppStorage("native.lyric.weight") private var weight = 700.0
  @AppStorage("native.lyric.blend") private var blend = "normal"
  @AppStorage("native.lyric.translation") private var translation = true
  @AppStorage("native.lyric.ruby") private var ruby = true
  @AppStorage("native.lyric.romanization") private var romanization = true
  @AppStorage("native.lyric.wordRomanization") private var wordRomanization = true
  @AppStorage("native.lyric.translationFollow") private var translationFollow = true
  @AppStorage("native.lyric.translationSize") private var translationSize = 24.0
  @AppStorage("native.lyric.alignment") private var alignment = "auto"
  @AppStorage("native.lyric.scale") private var scale = true
  @AppStorage("native.lyric.highlight") private var highlight = true
  @AppStorage("native.lyric.float") private var float = false
  @AppStorage("native.lyric.emphasize") private var emphasize = false
  @AppStorage("native.lyric.blur") private var blur = false
  @AppStorage("native.lyric.hidePassed") private var hidePassed = false
  @AppStorage("native.lyric.springPreset") private var springPreset = "default"
  @AppStorage("native.lyric.springMass") private var springMass = 0.9
  @AppStorage("native.lyric.springDamping") private var springDamping = 15.0
  @AppStorage("native.lyric.springStiffness") private var springStiffness = 90.0
  @AppStorage("native.lyric.alignPosition") private var alignPosition = 0.35
  @AppStorage("native.lyric.inactiveAlpha") private var inactiveAlpha = 0.2

  var body: some View {
    NativeSettingsList {
      NativeLyricFontSection()
      NativeSettingSection("内容样式") {
        Toggle(isOn: $adaptive) {
          NativeSettingLabel(title: "自适应字号", detail: "歌词字号根据窗口大小自动调整")
        }
        NativeSettingSlider(
          title: "歌词字号", detail: "关闭自适应后生效", value: $fontSize, range: 30...64, step: 1)
        NativeSettingSlider(
          title: "歌词字重", detail: "歌词文字粗细", value: $weight, range: 100...900, step: 100)
        NativeSettingPicker(
          title: "歌词混合模式", detail: "控制歌词与背景的混合方式", selection: $blend
        ) {
          Text("Normal").tag("normal")
          Text("Screen").tag("screen")
          Text("Plus Lighter").tag("plus-lighter")
        }
        Toggle(isOn: $translation) {
          NativeSettingLabel(title: "显示翻译", detail: "显示歌词的翻译文本")
        }
        Toggle(isOn: $ruby) {
          NativeSettingLabel(title: "显示词内注音", detail: "显示歌词中汉字词语的假名或拼音注音")
        }
        Toggle(isOn: $romanization) {
          NativeSettingLabel(title: "显示逐行音译", detail: "显示歌词行的音译文本")
        }
        Toggle(isOn: $wordRomanization) {
          NativeSettingLabel(title: "显示逐词音译", detail: "在逐字歌词中，显示每个字词的音译文本")
        }
        Toggle(isOn: $translationFollow) {
          NativeSettingLabel(title: "副行字号跟随主行", detail: "副行字号为主行的一半")
        }
        if !translationFollow {
          NativeSettingSlider(
            title: "翻译/音译字号", value: $translationSize, range: 12...48, step: 1)
        }
      }
      NativeSettingSection("显示效果") {
        NativeSettingPicker(
          title: "歌词水平对齐", detail: "自动按演唱声部分左右显示，也可统一靠左、居中或靠右", selection: $alignment
        ) {
          Text("自动").tag("auto")
          Text("靠左").tag("left")
          Text("居中").tag("center")
          Text("靠右").tag("right")
        }
        Toggle(isOn: $scale) {
          NativeSettingLabel(title: "歌词缩放", detail: "聚焦播放行，非激活行轻微缩小")
        }
        if style == "original" {
          Toggle(isOn: $highlight) {
            NativeSettingLabel(title: "逐字高亮", detail: "逐字显示歌词高亮进度")
          }
          Toggle(isOn: $float) {
            NativeSettingLabel(title: "逐字上浮", detail: "播放到的文字向上微浮")
          }
          Toggle(isOn: $emphasize) {
            NativeSettingLabel(title: "强调效果", detail: "长音节文字显示缩放和辉光动画")
          }
          Toggle(isOn: $blur) {
            NativeSettingLabel(title: "逐行模糊", detail: "远离当前行的歌词逐渐模糊")
          }
          Toggle(isOn: $hidePassed) {
            NativeSettingLabel(title: "隐藏已播放行", detail: "播放过的歌词行自动隐藏")
          }
        }
      }
      NativeSettingSection("弹簧动画") {
        NativeSettingPicker(
          title: "弹簧预设", detail: "歌词滚动动画的弹簧物理参数预设", selection: $springPreset
        ) {
          ForEach(NativeLyricSpring.presets) { preset in Text(preset.name).tag(preset.id) }
          Text("自定义").tag("custom")
        }
        if springPreset == "custom" {
          NativeSettingSlider(
            title: "质量", detail: "值越大运动越迟钝，惯性越大", value: $springMass, range: 0.1...5,
            step: 0.1, format: { String(format: "%.1f", $0) })
          NativeSettingSlider(
            title: "阻尼", detail: "值越大振荡衰减越快，运动越平滑", value: $springDamping, range: 1...50,
            step: 0.5, format: { String(format: "%.1f", $0) })
          NativeSettingSlider(
            title: "刚度", detail: "值越大弹簧回弹越快，频率越高", value: $springStiffness, range: 10...300,
            step: 5)
        }
      }
      NativeSettingSection("布局与透明度") {
        NativeSettingSlider(
          title: "对齐位置", detail: "当前行在歌词区域中的垂直位置（0 = 顶部，1 = 底部）", value: $alignPosition,
          range: 0.1...0.9, step: 0.05, format: { String(format: "%.2f", $0) })
        if style == "original" {
          NativeSettingSlider(
            title: "非激活行透明度", detail: "非当前行的基础透明度", value: $inactiveAlpha, range: 0...1,
            step: 0.05, format: { String(format: "%.2f", $0) })
        }
      }
    }.navigationTitle("歌词设置")
  }
}

/// 歌词字体分区由 NativeLyricFonts 提供系统 Section，这里把它的行画成设置卡片
private struct NativeLyricFontSection: View {
  @Environment(\.nativeSettingsMargin) private var margin
  var body: some View {
    NativeLyricFontSettings().nativeSettingCard(margin: margin).listSectionSeparator(.hidden)
  }
}
