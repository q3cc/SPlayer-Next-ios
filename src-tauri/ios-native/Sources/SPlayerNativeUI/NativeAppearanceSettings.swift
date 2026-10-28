import SwiftUI

/// 外观设置，分区与选项对应 main 的 appearance 分类（主题与颜色 / 布局 / 过渡与动画 / 播放栏 / 播放页）
struct NativeAppearanceSettings: View {
  @Binding var appearance: String
  /// 当前曲目封面，用于播放器风格预览
  var cover: String? = nil
  @AppStorage("native.player.lyricInBar") private var lyricInBar = true
  @AppStorage("native.player.timeFormat") private var timeFormat = 0
  @AppStorage("native.player.style") private var playerStyle = "original"
  @AppStorage("native.player.background") private var playerBackground = "blur"
  @AppStorage("native.player.flowSpeed") private var flowSpeed = 4.0
  @AppStorage("native.player.renderScale") private var renderScale = 0.5
  @AppStorage("native.player.fps") private var fps = 30.0
  @AppStorage("native.player.freezeOnPause") private var freezeOnPause = false
  @AppStorage("native.player.beat") private var beat = false
  @AppStorage("native.player.coverLayout") private var coverLayout = "default"
  @AppStorage("native.player.coverRatio") private var coverRatio = 0.45
  @AppStorage("native.player.autoCenter") private var autoCenter = true
  @AppStorage("native.player.showPlaybackSource") private var showSource = false
  @AppStorage("native.player.followCoverColor") private var followColor = true
  @AppStorage("native.player.autoImmersive") private var autoImmersive = true
  @AppStorage("native.player.keepAwake") private var keepAwake = false
  @AppStorage(NativeSongListStyle.key) private var songListStyle = NativeSongListStyle.comfortable
  @AppStorage(NativeLayout.sidebarCollapsedKey) private var sidebarCollapsed = false
  @AppStorage(NativeMotion.reduceKey) private var reduceMotion = false
  @AppStorage(NativeMotion.routeKey) private var routeTransition = "fade"
  @AppStorage(NativeMotion.seamlessKey) private var seamlessTransition = false
  @State private var confirmFluid = false

  var body: some View {
    NativeSettingsList {
      NativeSettingSection("主题与颜色", footer: "应用的颜色主题；播放器始终使用深色") {
        NativeChoiceCards(
          options: [("light", "浅色模式"), ("dark", "深色模式"), ("system", "跟随系统")],
          selection: $appearance, identifier: "native.settings.appearance", aspect: 1.25
        ) { NativeThemePreview(mode: $0) }
      }
      NativeSettingSection(
        "播放器主题",
        footer: playerStyle == "original"
          ? "原版：封面与歌词左右排布，闲置五秒后自动沉浸；切换不会中断音乐"
          : "Apple Music：渐隐大封面，竖屏歌词默认隐藏控制区；切换不会中断音乐"
      ) {
        NativeChoiceCards(
          options: [("original", "Next 原版"), ("am", "Apple Music")],
          selection: $playerStyle, identifier: "native.settings.playerStyle", aspect: 1.2
        ) { NativePlayerStylePreview(style: $0, cover: cover) }
      }
      NativeSettingSection("布局") {
        NativeSettingPicker(title: "歌曲列表样式", detail: "配置歌曲列表的展示密度", selection: $songListStyle) {
          Text("舒适").tag(NativeSongListStyle.comfortable)
          Text("紧凑").tag(NativeSongListStyle.compact)
        }.accessibilityIdentifier("native.settings.songListStyle")
        Toggle(isOn: $sidebarCollapsed) {
          NativeSettingLabel(title: "折叠侧边栏", detail: "将侧边栏折叠为图标模式")
        }.accessibilityIdentifier("native.settings.sidebarCollapsed")
      }
      NativeSettingSection("过渡与动画") {
        Toggle(isOn: $reduceMotion) {
          NativeSettingLabel(title: "减弱动画", detail: "减少界面动态效果，降低性能消耗")
        }.accessibilityIdentifier("native.settings.reduceMotion")
        NativeSettingPicker(title: "页面切换", detail: "切换页面时的过渡动画效果", selection: $routeTransition) {
          Text("无").tag("none")
          Text("淡入淡出").tag("fade")
          Text("滑动").tag("slide")
          Text("缩放").tag("zoom")
        }
        Toggle(isOn: $seamlessTransition) {
          NativeSettingLabel(title: "共享元素过渡", detail: "支持两个页面之间的元素无缝过渡")
        }.accessibilityIdentifier("native.settings.seamlessTransition")
      }
      NativeSettingSection("播放栏") {
        Toggle(isOn: $lyricInBar) {
          NativeSettingLabel(title: "播放时显示歌词", detail: "底部播放栏播放时将歌手名替换为当前歌词")
        }
        NativeSettingPicker(
          title: "时间显示格式", detail: "播放页面底部的时间如何显示（单击时间可以快速切换）", selection: $timeFormat
        ) {
          Text("播放时间 / 总时长").tag(0)
          Text("剩余时间 / 总时长").tag(1)
          Text("播放时间 / 剩余时间").tag(2)
        }
      }
      NativeSettingSection("播放页") {
        NativeSettingPicker(
          title: "播放器背景", detail: "全屏播放器的背景类型",
          selection: Binding(
            get: { playerBackground },
            set: { next in
              if next == "fluid" && playerBackground != "fluid" {
                confirmFluid = true
              } else {
                playerBackground = next
              }
            })
        ) {
          Text("模糊").tag("blur")
          Text("纯色").tag("solid")
          Text("流体").tag("fluid")
        }
        if playerBackground == "fluid" {
          NativeSettingSlider(
            title: "流动速度", detail: "流体背景的动画流动速度", value: $flowSpeed, range: 0.1...10,
            step: 0.1, format: { String(format: "%.1f", $0) })
          NativeSettingSlider(
            title: "渲染缩放", detail: "适当提高可减少分界线锯齿、画面更细腻，但会增加显卡压力", value: $renderScale,
            range: 0.5...2, step: 0.1, format: { String(format: "%.1f", $0) })
          NativeSettingSlider(
            title: "动画帧率", detail: "流体背景的渲染帧率，越高越流畅但更耗性能", value: $fps, range: 24...120,
            step: 2)
          Toggle(isOn: $freezeOnPause) {
            NativeSettingLabel(title: "暂停时冻结", detail: "暂停播放时同时停止流体背景动画")
          }
          Toggle(isOn: $beat) {
            NativeSettingLabel(title: "背景跳动", detail: "使流体背景随音乐低频节拍产生脉动效果")
          }
        }
        if playerStyle == "original" {
          NativeSettingPicker(
            title: "封面布局", detail: "全屏播放器封面的呈现方式", selection: $coverLayout
          ) {
            Text("默认").tag("default")
            Text("全屏封面").tag("fullscreen")
          }
          NativeSettingSlider(
            title: "封面/歌词占比", detail: "播放页封面与歌词区域的宽度比例", value: $coverRatio,
            range: 0.3...0.6, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })
          Toggle(isOn: $autoCenter) {
            NativeSettingLabel(title: "自动居中封面", detail: "无歌词时自动居中封面并隐藏歌词区域")
          }
          Toggle(isOn: $showSource) {
            NativeSettingLabel(title: "显示播放来源", detail: "在全屏播放器中显示当前歌曲的来源")
          }
          Toggle(isOn: $followColor) {
            NativeSettingLabel(title: "跟随封面颜色", detail: "歌词颜色跟随当前封面主色调")
          }
          Toggle(isOn: $autoImmersive) {
            NativeSettingLabel(title: "自动沉浸模式", detail: "触摸闲置 5 秒后，自动隐藏全屏播放器顶/底栏")
          }
        }
        Toggle(isOn: $keepAwake) {
          NativeSettingLabel(title: "保持屏幕常亮", detail: "播放页展开时阻止系统自动锁屏")
        }
      }
    }.navigationTitle("外观设置")
      .alert("高占用功能", isPresented: $confirmFluid) {
        Button("取消", role: .cancel) {}
        Button("确定") { playerBackground = "fluid" }
      } message: {
        Text("开启后可能明显增加内存与 CPU 占用，低配设备上或出现卡顿。确定开启吗？")
      }
  }
}
