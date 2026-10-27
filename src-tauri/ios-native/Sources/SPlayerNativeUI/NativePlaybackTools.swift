import SwiftUI

enum NativePlaybackTool: String, Identifiable {
  case speed = "变速 / 变调"
  case equalizer = "均衡器"
  case ab = "AB 循环"
  case sleep = "定时关闭"
  case copy = "复制歌词"
  case offset = "歌词时间偏移"
  var id: String { rawValue }
}

/// 播放器菜单中的原生控制面板；每个选项直接作用于音频引擎
@MainActor
struct NativePlaybackTools: View {
  @ObservedObject var player: NativePlayerStore
  var tool: NativePlaybackTool? = nil
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Group {
        if tool == .copy {
          NativeCopyLyricsView(player: player)
        } else if tool == .equalizer {
          NativeEqualizerView(player: player)
        } else {
          Form {
            if tool == nil || tool == .speed {
              Section("播放速度") {
                Text("\(player.speed, specifier: "%.2f")×").monospacedDigit()
                Slider(value: $player.speed, in: 0.5...2, step: 0.05)
                HStack {
                  ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button("\(rate, specifier: "%g")×") { player.speed = rate }
                      .buttonStyle(.bordered)
                  }
                }
                Toggle("保持音调", isOn: $player.pitchSync)
                Stepper("音调：\(Int(player.pitch)) 半音", value: $player.pitch, in: -12...12, step: 1)
                  .disabled(!player.pitchSync)
                Button("重置速度与音调") {
                  player.speed = 1
                  player.pitch = 0
                  player.pitchSync = true
                }
              }
            }
            if tool == nil {
              Section {
                NavigationLink("均衡器") { NativeEqualizerView(player: player).nativeSettingsPage() }
              }
            }
            if tool == nil || tool == .ab {
              Section("AB 循环") {
                Toggle("启用 AB 循环", isOn: $player.abEnabled).disabled(!player.validAB)
                point("A", value: $player.pointA)
                point("B", value: $player.pointB)
                if player.pointA != nil && player.pointB != nil && !player.validAB {
                  Text("B 点必须晚于 A 点").foregroundStyle(.red)
                }
                Button("清除 AB 点") {
                  player.abEnabled = false
                  player.pointA = nil
                  player.pointB = nil
                }
              }
            }
            if tool == nil || tool == .sleep {
              Section("定时停止播放") {
                if let deadline = player.sleepDeadline {
                  Text(deadline, style: .time)
                  Button("取消定时") { player.setSleepTimer(minutes: nil) }
                }
                if player.waitingForSongEnd { Text("等待本曲结束") }
                HStack {
                  ForEach([10, 20, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Button("\(minutes)") { player.sleepDuration = Double(minutes) }.buttonStyle(
                      .bordered)
                  }
                }
                Text("自定义时长：\(Int(player.sleepDuration)) 分钟")
                Slider(value: $player.sleepDuration, in: 1...180, step: 1)
                Toggle("等待整曲结束", isOn: $player.sleepWaitSongEnd)
                Button("启用定时") { player.setSleepTimer(minutes: Int(player.sleepDuration)) }
              }
            }
            if tool == nil || tool == .offset {
              Section("歌词时间偏移") {
                Stepper(
                  "\(Int(player.lyricOffsetMs)) 毫秒", value: $player.lyricOffsetMs,
                  in: -10000...10000,
                  step: 100)
                Button("重置偏移") { player.lyricOffsetMs = 0 }
              }
            }
          }
        }
      }.navigationTitle(tool?.rawValue ?? "播放控制")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
    }
  }
  /// AB 点支持当前位置设置和原版 0.1 秒微调
  private func point(_ title: String, value: Binding<Double?>) -> some View {
    VStack(alignment: .leading) {
      Text("\(title) 点：\(value.wrappedValue.map { String(format: "%.1f 秒", $0 / 1000) } ?? "未设置")")
      HStack {
        Button("设为当前位置") { value.wrappedValue = player.positionMs }
        Button("−0.1 秒") {
          if let old = value.wrappedValue { value.wrappedValue = max(0, old - 100) }
        }.disabled(value.wrappedValue == nil)
        Button("+0.1 秒") {
          if let old = value.wrappedValue { value.wrappedValue = min(player.durationMs, old + 100) }
        }.disabled(value.wrappedValue == nil)
      }.buttonStyle(.bordered)
    }
  }
}
