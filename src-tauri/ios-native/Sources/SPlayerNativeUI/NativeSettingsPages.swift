import SwiftUI

/// 常规设置：备份与重置；重置只还原设置项，不触碰曲库、歌单与平台会话
@MainActor
struct NativeGeneralSettings: View {
  @ObservedObject var player: NativePlayerStore
  @Binding var appearance: String
  @State private var confirmReset = false
  @State private var resetDone = false
  /// 由 AppStorage 直接持有的设置键，重置时移除以回到各视图默认值
  private static let keys = [
    "native.player.background", "native.player.flowSpeed", "native.player.renderScale",
    "native.player.fps", "native.player.freezeOnPause", "native.player.beat",
    "native.player.autoPlay", "native.player.remember", "native.player.quality",
    "native.player.style", "native.player.spectrum", "native.player.spectrumWidth",
    "native.player.reverseSpectrum", "native.player.showPlaybackSource",
    "native.player.coverLayout", "native.player.followCoverColor", "native.player.coverRatio",
    "native.player.autoCenter", "native.player.keepAwake", "native.player.timeFormat",
    "native.player.lyricInBar", "native.player.autoImmersive", "native.lyric.fontSize",
    "native.lyric.adaptive", "native.lyric.weight", "native.lyric.translation",
    "native.lyric.translationFollow", "native.lyric.translationSize", "native.lyric.blur",
    "native.lyric.scale", "native.lyric.highlight", "native.lyric.float", "native.lyric.emphasize",
    "native.lyric.hidePassed", "native.lyric.romanization", "native.lyric.wordRomanization",
    "native.lyric.ruby", "native.lyric.alignment", "native.lyric.blend",
    "native.lyric.springPreset", "native.lyric.springMass", "native.lyric.springDamping",
    "native.lyric.springStiffness", "native.lyric.alignPosition", "native.lyric.inactiveAlpha",
  ]

  var body: some View {
    Form {
      Section("备份与重置") {
        HStack {
          NativeSettingLabel(title: "重置设置", detail: "将全部设置项还原为默认值，不影响歌单与本地音乐库")
          Spacer()
          Button("重置", role: .destructive) { confirmReset = true }
        }
      }
    }.navigationTitle("常规设置")
      .confirmationDialog("重置设置？", isPresented: $confirmReset, titleVisibility: .visible) {
        Button("重置", role: .destructive) { reset() }
      } message: {
        Text("全部设置项将还原为默认值，操作不可恢复")
      }
      .alert("设置已重置", isPresented: $resetDone) { Button("好") {} }
  }

  private func reset() {
    for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    appearance = "system"
    player.fadeEnabled = true
    player.fadeDuration = 200
    player.loudnessNormalization = false
    player.equalizer = NativeEqualizer()
    player.mediaControls = true
    player.dynamicLyrics = false
    resetDone = true
  }
}

/// 网络与服务：iOS 原生仅实现系统媒体控制与动态歌词
@MainActor
struct NativeServiceSettings: View {
  @ObservedObject var player: NativePlayerStore
  var body: some View {
    Form {
      Section("媒体控制") {
        Toggle(isOn: $player.mediaControls) {
          NativeSettingLabel(title: "系统媒体控制", detail: "在系统媒体控制中显示当前播放信息")
        }
        Toggle(isOn: $player.dynamicLyrics) {
          NativeSettingLabel(
            title: "动态歌词", detail: "在锁屏和控制中心以当前歌词作为标题，副标题显示“歌曲名 - 歌手”；歌词结束后 3 秒内无新歌词则恢复歌曲信息")
        }.disabled(!player.mediaControls)
      }
    }.navigationTitle("网络与服务")
  }
}

/// 本地与缓存：原生曲库导入；删除只影响应用内副本
@MainActor
struct NativeLocalSettings: View {
  @ObservedObject var player: NativePlayerStore
  let importMusic: () -> Void
  var body: some View {
    Form {
      Section("本地音乐") {
        LabeledContent("已导入歌曲", value: "\(player.tracks.count) 首")
        Button("导入音乐", action: importMusic).disabled(player.importing).accessibilityIdentifier(
          "native.import.settings")
        Text("删除歌曲只删除应用内副本，不影响原文件").font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle("本地与缓存")
  }
}

/// 其他设置：平台登录
@MainActor
struct NativeOtherSettings: View {
  @ObservedObject var player: NativePlayerStore
  @State private var clearSession = false
  var body: some View {
    Form {
      Section {
        NavigationLink("平台账号") {
          NativeAccountsView(service: player.service).nativeSettingsPage()
        }
        Text("搜索与音源解析复用更新后的平台接口；不提供试听片段替代完整歌曲").font(.footnote).foregroundStyle(.secondary)
        Button("清除平台会话", role: .destructive) { clearSession = true }
      } header: {
        NativeSettingHeader(title: "平台登录", tag: "Beta")
      }
    }.navigationTitle("其他设置")
      .confirmationDialog("清除平台登录状态？", isPresented: $clearSession) {
        Button("清除会话", role: .destructive) {
          do { try player.service.clearSession() } catch {
            player.error = error.localizedDescription
          }
        }
      }
  }
}

