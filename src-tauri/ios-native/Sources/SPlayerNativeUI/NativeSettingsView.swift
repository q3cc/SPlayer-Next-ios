import SwiftUI

@MainActor
struct NativeSettingsView: View {
  @ObservedObject var player: NativePlayerStore
  @Binding var appearance: String
  let importMusic: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var clearSession = false
  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 16) {
            NativeLogo().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
              Text("SPlayer Next").font(.title2.bold())
              Text("原生界面 · SwiftUI / UIKit").font(.subheadline).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 8)
        }
        Section("外观设置") {
          Picker("主题模式", selection: $appearance) {
            Text("跟随系统").tag("system")
            Text("浅色模式").tag("light")
            Text("深色模式").tag("dark")
          }.accessibilityIdentifier("native.settings.appearance")
        }
        Section("播放设置") {
          Toggle("单曲循环", isOn: $player.repeatOne)
          #if os(iOS)
            HStack {
              Text("音频输出")
              Spacer()
              NativeRoutePicker().frame(width: 40, height: 36)
            }
            VStack(alignment: .leading, spacing: 8) {
              Text("系统音量")
              NativeVolumeSlider().frame(height: 40)
            }
          #endif
        }
        Section("本地音乐") {
          LabeledContent("已导入歌曲", value: "\(player.tracks.count) 首")
          Button("导入音乐", action: importMusic).disabled(player.importing).accessibilityIdentifier(
            "native.import.settings")
          Text("删除歌曲只删除应用内副本，不影响原文件").font(.footnote).foregroundStyle(.secondary)
        }
        Section("扩展") {
          NavigationLink {
            NativePluginsView(plugins: player.plugins)
          } label: {
            Label("插件管理", systemImage: "puzzlepiece.extension")
          }
          .accessibilityIdentifier("native.settings.plugins")
        }
        Section("平台服务") {
          NavigationLink("平台账号") { NativeAccountsView(service: player.service) }
          Text("搜索与音源解析复用更新后的平台接口；不提供试听片段替代完整歌曲").font(.footnote).foregroundStyle(.secondary)
          Button("清除平台会话", role: .destructive) { clearSession = true }
        }
        Section("关于") {
          LabeledContent("版本", value: "2.1.0 Native")
          NavigationLink("开源许可") {
            ScrollView {
              VStack(alignment: .leading, spacing: 24) {
                ForEach(["SPlayer-LICENSE", "QuickJS-LICENSE"], id: \.self) { name in
                  Text(name).font(.headline)
                  if let url = Bundle.module.url(forResource: name, withExtension: "txt"),
                    let text = try? String(contentsOf: url, encoding: .utf8)
                  {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                  }
                }
              }.padding(24)
            }.navigationTitle("开源许可")
          }
          Link("项目源码", destination: URL(string: "https://github.com/q3cc/SPlayer-Next-ios")!)
        }
      }.navigationTitle("全局设置")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        .confirmationDialog("清除平台登录状态？", isPresented: $clearSession) {
          Button("清除会话", role: .destructive) {
            do { try player.service.clearSession() } catch {
              player.error = error.localizedDescription
            }
          }
        }
    }.tint(.primary)
  }
}
