import SwiftUI

/// 播放设置，分区对应 main 的 player 分类；输出设备与音效为原生音频引擎提供的能力
@MainActor
struct NativePlayerSettings: View {
  @ObservedObject var player: NativePlayerStore
  @AppStorage("native.player.autoPlay") private var autoPlay = false
  @AppStorage("native.player.remember") private var remember = true
  @AppStorage("native.player.quality") private var quality = "hq"
  @AppStorage("native.player.spectrum") private var spectrum = false
  @AppStorage("native.player.spectrumWidth") private var spectrumWidth = 4.0
  @AppStorage("native.player.reverseSpectrum") private var reverseSpectrum = false
  @AppStorage(NativePlayBehavior.searchKey) private var searchPlay = NativePlayBehavior.current
  @AppStorage(NativePlayBehavior.songListKey) private var songListPlay = NativePlayBehavior.current

  var body: some View {
    Form {
      Section("播放控制") {
        Toggle(isOn: $autoPlay) {
          NativeSettingLabel(title: "自动播放", detail: "启动恢复上次歌曲后自动开始播放")
        }
        Toggle(isOn: $remember) {
          NativeSettingLabel(title: "记忆播放进度", detail: "启动时恢复上次歌曲的播放进度")
        }
        Toggle(isOn: $player.fadeEnabled) {
          NativeSettingLabel(title: "渐入渐出", detail: "播放和暂停时音频淡入淡出")
        }
        if player.fadeEnabled {
          NativeSettingSlider(
            title: "渐变时长", detail: "渐入渐出的持续时长（毫秒）", value: $player.fadeDuration,
            range: 100...600, step: 100)
        }
        Toggle(isOn: $player.loudnessNormalization) {
          NativeSettingLabel(title: "音量均衡", detail: "自动调节不同歌曲之间的音量差异", tag: "Beta")
        }
      }
      Section("播放行为") {
        NativeSettingPicker(title: "搜索页播放", detail: "配置搜索页面点击歌曲时的行为", selection: $searchPlay) {
          Text("仅播放当前").tag(NativePlayBehavior.current)
          Text("播放全部").tag(NativePlayBehavior.all)
        }
        NativeSettingPicker(
          title: "歌曲播放按钮行为", detail: "配置歌曲列表行首播放按钮的行为", selection: $songListPlay
        ) {
          Text("仅播放当前").tag(NativePlayBehavior.current)
          Text("播放全部").tag(NativePlayBehavior.all)
        }.accessibilityIdentifier("native.settings.songListPlay")
      }
      Section("播放音源") {
        NativeSettingPicker(
          title: "在线歌曲音质", detail: "在线歌曲的音质偏好，取决于账号实际可用级别", selection: $quality
        ) {
          Text("标准 (LQ)").tag("lq")
          Text("较高 (SQ)").tag("sq")
          Text("极高 (HQ)").tag("hq")
          Text("无损 (Lossless)").tag("lossless")
          Text("高解析度无损 (Hi-Res)").tag("hi-res")
        }
      }
      Section {
        Toggle(isOn: $spectrum) {
          NativeSettingLabel(title: "启用音乐频谱", detail: "实时频谱分析会持续占用一定的 CPU，性能敏感设备建议关闭")
        }
        if spectrum {
          NativeSettingSlider(
            title: "频谱条宽度", detail: "数值越小柱条越细越密", value: $spectrumWidth, range: 1...12, step: 1)
          Toggle(isOn: $reverseSpectrum) {
            NativeSettingLabel(title: "频谱反向", detail: "启用后频率从中间向两侧递减，否则递增")
          }
        }
      } header: {
        NativeSettingHeader(title: "音乐频谱", tag: "Beta")
      }
      #if os(iOS)
        Section("输出设备") {
          HStack {
            NativeSettingLabel(title: "音频输出", detail: "选择 AirPlay、蓝牙或本机扬声器")
            Spacer()
            NativeRoutePicker().frame(width: 40, height: 36)
          }
          VStack(alignment: .leading, spacing: 8) {
            Text("系统音量")
            NativeVolumeSlider().frame(height: 40)
          }
        }
      #endif
      Section("音效与工具") {
        NavigationLink("均衡器") { NativeEqualizerView(player: player).nativeSettingsPage() }
        NavigationLink("播放控制") { NativePlaybackTools(player: player).nativeSettingsPage() }
      }
    }.navigationTitle("播放设置")
  }
}
