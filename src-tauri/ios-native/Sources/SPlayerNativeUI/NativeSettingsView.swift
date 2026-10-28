import SwiftUI

/// 设置大分类，顺序与名称沿用 main 的 settingsSchema；没有原生实现的分类不显示
enum NativeSettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case general, appearance, player, lyric, desktopLyric, services, download, localCache, plugins,
    other, about
  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: return "常规设置"
    case .appearance: return "外观设置"
    case .player: return "播放设置"
    case .lyric: return "歌词设置"
    case .desktopLyric: return "桌面歌词"
    case .services: return "网络与服务"
    case .download: return "下载配置"
    case .localCache: return "本地与缓存"
    case .plugins: return "插件管理"
    case .other: return "其他设置"
    case .about: return "关于软件"
    }
  }
  /// 对应原版分类的 lucide 线性图标
  var icon: String {
    switch self {
    case .general: return "gearshape"
    case .appearance: return "paintpalette"
    case .player: return "play"
    case .lyric: return "music.mic"
    case .desktopLyric: return "display"
    case .services: return "globe"
    case .download: return "arrow.down.to.line"
    case .localCache: return "internaldrive"
    case .plugins: return "puzzlepiece.extension"
    case .other: return "gearshape.2"
    case .about: return "info.circle"
    }
  }
}

@MainActor
struct NativeSettingsView: View {
  @ObservedObject var player: NativePlayerStore
  @Binding var appearance: String
  let importMusic: () -> Void
  /// 弹层入口显示关闭按钮；标签页入口没有可关闭的层级
  var presented = true
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.openURL) private var openURL
  @AppStorage("native.settings.category") private var lastCategory = "general"
  @State private var selection: NativeSettingsCategory?
  @State private var width: CGFloat = 0
  @State private var query = ""
  @FocusState private var searchFocused: Bool

  var body: some View {
    Group {
      if sizeClass == .compact { compact } else { shell }
    }
    .tint(Color.nativePrimary)
    .toggleStyle(SwitchToggleStyle(tint: Color.nativePrimary.opacity(0.8)))
    .environment(\.nativeSettingsEmbedded, true)
    .onChange(of: selection) { next in
      if let next { lastCategory = next.rawValue }
    }
  }

  private var current: NativeSettingsCategory {
    selection ?? NativeSettingsCategory(rawValue: lastCategory) ?? .general
  }

  /// 原版 SettingsContent：左栏 surface-panel 分类菜单，右栏 surface 设置内容
  private var shell: some View {
    HStack(spacing: 0) {
      sidebar
      // 根页面隐藏导航栏；二级页面仍有系统返回栏
      NavigationStack {
        page(current)
          #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
          #endif
      }.id(current)
    }
    .background(Color.nativeSurface.ignoresSafeArea())
    .overlay(alignment: .topTrailing) {
      if presented {
        // 与 SDialog 关闭按钮一致：右上 12 处的 32 ghost 圆按钮
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(NativeButtonStyle(variant: .ghost, size: .small, shape: .circle))
          .accessibilityLabel("完成").padding(12)
      }
    }
    .background {
      GeometryReader { geometry in
        Color.clear.onAppear { width = geometry.size.width }
          .onChange(of: geometry.size.width) { width = $0 }
      }
    }
  }

  /// 左栏：w-70（窄宽 12rem）、p-5，标题、搜索、SMenu 与底部仓库信息
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("设置").font(.system(size: 24, weight: .bold)).foregroundStyle(Color.nativeOnSurface)
        .padding(.horizontal, 4).padding(.bottom, 4)
      Text("调整您的专属配置").font(.system(size: 14))
        .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.8))
        .padding(.horizontal, 4).padding(.bottom, 20)
      searchField.padding(.bottom, 16)
      // 列表单元会把行内文字暴露为独立的静态文本，界面测试按分类名查找
      List {
        Group {
          if trimmedQuery.isEmpty {
            ForEach(NativeSettingsCategory.allCases) { category in
              categoryRow(category, selected: category == current)
            }
          } else {
            searchResults
          }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
      }
      .listStyle(.plain).scrollContentBackground(.hidden).scrollIndicators(.hidden)
      .environment(\.defaultMinListRowHeight, 0)
      HStack(spacing: 4) {
        NativeSButton(
          title: "SPlayer-Next-ios", icon: "chevron.left.forwardslash.chevron.right",
          variant: .text, size: .tiny
        ) { openURL(NativeGitHub.repoURL) }
        NativeSettingTag(text: "v" + NativeBuildInfo.version, size: .tiny, primary: false)
      }.padding(.top, 16).padding(.horizontal, 4)
    }
    .padding(20)
    .frame(width: width > 0 && width <= NativeLayout.compactMaxWidth ? 192 : 280)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.nativeSurfacePanel.ignoresSafeArea())
  }

  /// SMenu medium：高 42、横 12、间距 12、字 14、图标 20；选中 primary/10 底与左侧 3px 指示条
  private func categoryRow(_ category: NativeSettingsCategory, selected: Bool) -> some View {
    Button {
      selection = category
    } label: {
      HStack(spacing: 12) {
        Image(systemName: category.icon).font(.system(size: 17)).frame(width: 20, height: 20)
          .accessibilityHidden(true)
        Text(category.title).font(.system(size: 14)).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12).frame(height: 42)
      .foregroundStyle(selected ? Color.nativePrimary : Color.nativeOnSurface.opacity(0.8))
      .background(
        selected ? Color.nativePrimary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay(alignment: .leading) {
        if selected {
          Capsule().fill(Color.nativePrimary).frame(width: 3).padding(.vertical, 8)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(NativePressStyle(radius: 8, amount: 0.05))
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityIdentifier("native.settings.category.\(category.rawValue)")
  }

  /// SInput medium：高 36、横 12、字 14、圆角 8；聚焦时 primary 边框与 2px primary/20 外环
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").font(.system(size: 14))
        .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
      TextField(
        "", text: $query,
        prompt: Text("搜索设置项...").foregroundColor(Color.nativeOnSurfaceVariant.opacity(0.4))
      )
      .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Color.nativeOnSurface)
      .focused($searchFocused).autocorrectionDisabled()
      .accessibilityIdentifier("native.settings.search")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 14))
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
        }.buttonStyle(.plain).accessibilityLabel("清除")
      }
    }
    .padding(.horizontal, 12).frame(height: 36)
    .background(
      Color.nativeOnSurface.opacity(searchFocused ? 0.08 : 0.03),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(
        searchFocused ? Color.nativePrimary : Color.nativeOnSurface.opacity(0.15))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.nativePrimary.opacity(searchFocused ? 0.2 : 0), lineWidth: 2)
        .padding(-2)
    )
  }

  private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

  /// 搜索结果：选中后切换到所在分类并清空输入
  private var searchResults: some View {
    let matches = Self.index.filter {
      "\($0.title) \($0.detail ?? "")".lowercased().contains(trimmedQuery)
    }
    return VStack(alignment: .leading, spacing: 0) {
      if matches.isEmpty {
        Text("暂无数据").font(.system(size: 14))
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
          .frame(maxWidth: .infinity).padding(.vertical, 16)
      } else {
        ForEach(matches, id: \.title) { match in
          Button {
            selection = match.category
            query = ""
            searchFocused = false
          } label: {
            VStack(alignment: .leading, spacing: 0) {
              Text(match.category.title).font(.system(size: 12))
                .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4))
              Text(match.title).font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.nativeOnSurface)
              if let detail = match.detail {
                Text(detail).font(.system(size: 12)).lineLimit(1)
                  .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
              }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(NativePressStyle(radius: 8))
        }
      }
    }
    .padding(4)
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(Color.nativeOutlineVariant.opacity(0.8)))
  }

  /// 窄宽：分类列表推入详情，分类行与设置项同为卡片
  private var compact: some View {
    NavigationStack {
      NativeSettingsList {
        ForEach(NativeSettingsCategory.allCases) { category in
          NavigationLink {
            page(category)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: category.icon).font(.system(size: 17))
                .foregroundStyle(Color.nativeOnSurface.opacity(0.8)).frame(width: 20, height: 20)
                .accessibilityHidden(true)
              Text(category.title)
            }
          }.accessibilityIdentifier("native.settings.category.\(category.rawValue)")
        }.nativeSettingCard(margin: 16)
      }
      .navigationTitle("全局设置")
      .toolbar {
        if presented {
          ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
        }
      }
    }
  }

  @ViewBuilder
  private func page(_ category: NativeSettingsCategory) -> some View {
    Group {
      switch category {
      case .general: NativeGeneralSettings(player: player, appearance: $appearance)
      case .appearance:
        NativeAppearanceSettings(appearance: $appearance, cover: player.current?.cover)
      case .player: NativePlayerSettings(player: player)
      case .lyric: NativeLyricSettings()
      case .desktopLyric: NativeLyricPiPSettings(player: player, pip: player.lyricPiP)
      case .download:
        // 下载页仍是系统 Form：行间距 10 让每项成为独立卡片
        NativeDownloadSettings()
          #if os(iOS)
            .listRowSpacing(10)
          #endif
      case .services: NativeServiceSettings(player: player)
      case .localCache: NativeLocalSettings(player: player, importMusic: importMusic)
      case .plugins: NativePluginsView(plugins: player.plugins)
      case .other: NativeOtherSettings(player: player)
      case .about: NativeAboutSettings()
      }
    }.nativeSettingsPage()
  }

  /// 搜索索引：标题与说明同各设置页的 NativeSettingLabel
  private static let index: [(category: NativeSettingsCategory, title: String, detail: String?)] = [
    (.general, "重置设置", "将全部设置项还原为默认值，不影响歌单与本地音乐库"),
    (.appearance, "主题模式", "应用的颜色主题；播放器始终使用深色"),
    (.appearance, "播放器主题", "Next 原版或 Apple Music 风格"),
    (.appearance, "歌曲列表样式", "配置歌曲列表的展示密度"),
    (.appearance, "折叠侧边栏", "将侧边栏折叠为图标模式"),
    (.appearance, "减弱动画", "减少界面动态效果，降低性能消耗"),
    (.appearance, "页面切换", "切换页面时的过渡动画效果"),
    (.appearance, "共享元素过渡", "支持两个页面之间的元素无缝过渡"),
    (.appearance, "播放时显示歌词", "底部播放栏播放时将歌手名替换为当前歌词"),
    (.appearance, "时间显示格式", "播放页面底部的时间如何显示（单击时间可以快速切换）"),
    (.appearance, "播放器背景", "全屏播放器的背景类型"),
    (.appearance, "流动速度", "流体背景的动画流动速度"),
    (.appearance, "渲染缩放", "适当提高可减少分界线锯齿、画面更细腻，但会增加显卡压力"),
    (.appearance, "动画帧率", "流体背景的渲染帧率，越高越流畅但更耗性能"),
    (.appearance, "暂停时冻结", "暂停播放时同时停止流体背景动画"),
    (.appearance, "背景跳动", "使流体背景随音乐低频节拍产生脉动效果"),
    (.appearance, "封面布局", "全屏播放器封面的呈现方式"),
    (.appearance, "封面/歌词占比", "播放页封面与歌词区域的宽度比例"),
    (.appearance, "自动居中封面", "无歌词时自动居中封面并隐藏歌词区域"),
    (.appearance, "显示播放来源", "在全屏播放器中显示当前歌曲的来源"),
    (.appearance, "跟随封面颜色", "歌词颜色跟随当前封面主色调"),
    (.appearance, "自动沉浸模式", "触摸闲置 5 秒后，自动隐藏全屏播放器顶/底栏"),
    (.appearance, "保持屏幕常亮", "播放页展开时阻止系统自动锁屏"),
    (.player, "自动播放", "启动恢复上次歌曲后自动开始播放"),
    (.player, "记忆播放进度", "启动时恢复上次歌曲的播放进度"),
    (.player, "渐入渐出", "播放和暂停时音频淡入淡出"),
    (.player, "渐变时长", "渐入渐出的持续时长（毫秒）"),
    (.player, "音量均衡", "自动调节不同歌曲之间的音量差异"),
    (.player, "搜索页播放", "配置搜索页面点击歌曲时的行为"),
    (.player, "歌曲播放按钮行为", "配置歌曲列表行首播放按钮的行为"),
    (.player, "在线歌曲音质", "在线歌曲的音质偏好，取决于账号实际可用级别"),
    (.player, "启用音乐频谱", "实时频谱分析会持续占用一定的 CPU，性能敏感设备建议关闭"),
    (.player, "频谱条宽度", "数值越小柱条越细越密"),
    (.player, "频谱反向", "启用后频率从中间向两侧递减，否则递增"),
    (.player, "音频输出", "选择 AirPlay、蓝牙或本机扬声器"),
    (.player, "系统音量", nil),
    (.player, "均衡器", nil),
    (.lyric, "歌词字体", "按歌词行识别的语言选择字体"),
    (.lyric, "自适应字号", "歌词字号根据窗口大小自动调整"),
    (.lyric, "歌词字号", "关闭自适应后生效"),
    (.lyric, "歌词字重", "歌词文字粗细"),
    (.lyric, "歌词混合模式", "控制歌词与背景的混合方式"),
    (.lyric, "显示翻译", "显示歌词的翻译文本"),
    (.lyric, "显示词内注音", "显示歌词中汉字词语的假名或拼音注音"),
    (.lyric, "显示逐行音译", "显示歌词行的音译文本"),
    (.lyric, "显示逐词音译", "在逐字歌词中，显示每个字词的音译文本"),
    (.lyric, "副行字号跟随主行", "副行字号为主行的一半"),
    (.lyric, "翻译/音译字号", nil),
    (.lyric, "歌词水平对齐", "自动按演唱声部分左右显示，也可统一靠左、居中或靠右"),
    (.lyric, "歌词缩放", "聚焦播放行，非激活行轻微缩小"),
    (.lyric, "逐字高亮", "逐字显示歌词高亮进度"),
    (.lyric, "逐字上浮", "播放到的文字向上微浮"),
    (.lyric, "强调效果", "长音节文字显示缩放和辉光动画"),
    (.lyric, "逐行模糊", "远离当前行的歌词逐渐模糊"),
    (.lyric, "隐藏已播放行", "播放过的歌词行自动隐藏"),
    (.lyric, "弹簧预设", "歌词滚动动画的弹簧物理参数预设"),
    (.lyric, "对齐位置", "当前行在歌词区域中的垂直位置（0 = 顶部，1 = 底部）"),
    (.lyric, "非激活行透明度", "非当前行的基础透明度"),
    (.desktopLyric, "开启桌面歌词", "先播放歌曲。小窗可拖动、缩放，关闭不影响播放。"),
    (.desktopLyric, "歌词帧率", "控制小窗歌词和唱片动画的帧率。越高越流畅，也更耗电；默认 20 FPS。"),
    (.desktopLyric, "双行歌词", "上下交替，预告下一句。关闭为单行；有音译或翻译时显示附加歌词。"),
    (.desktopLyric, "显示音译和翻译", "显示在当前句下方。"),
    (.desktopLyric, "高亮颜色", "当前句或已唱部分。"),
    (.desktopLyric, "普通颜色", "未唱部分和附加歌词。"),
    (.services, "系统媒体控制", "在系统媒体控制中显示当前播放信息"),
    (.services, "动态歌词", "在锁屏和控制中心以当前歌词作为标题"),
    (.download, "启用下载功能", nil),
    (.download, "保存到「文件」App", "下载的歌曲始终加入应用曲库；开启后另在「文件」中按命名规则保留一份"),
    (.download, "下载音质", "下载时优先使用的音质，实际可用受平台与账号权限限制"),
    (.download, "文件名格式", "下载文件的命名方式"),
    (.download, "文件智能分类", "下载时按规则归入子文件夹"),
    (.download, "重名处理", "目标文件已存在时的处理方式"),
    (.download, "歌词文件格式", "保存及内嵌到标签的歌词格式"),
    (.download, "内嵌封面", "将封面写入下载的音频文件"),
    (.download, "内嵌元信息", "将标题、艺术家、专辑写入文件标签"),
    (.download, "内嵌歌词", "将歌词写入文件标签"),
    (.download, "同时保存歌词文件", "下载歌曲时在同目录额外保存一份歌词文件"),
    (.download, "同时保存为 TTML", "额外导出一份 TTML，单文件含原文、翻译与音译"),
    (.localCache, "导入音乐", "删除歌曲只删除应用内副本，不影响原文件"),
    (.plugins, "插件管理", "在线导入或本地导入自定义源"),
    (.other, "平台账号", "搜索与音源解析复用更新后的平台接口"),
    (.other, "清除平台会话", nil),
    (.about, "检查更新", nil),
    (.about, "特别致谢", nil),
    (.about, "开源许可", nil),
    (.about, "环境信息", nil),
  ]
}

private struct NativeSettingsEmbeddedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// 位于设置页内：二级页面画在 surface 画布上
  var nativeSettingsEmbedded: Bool {
    get { self[NativeSettingsEmbeddedKey.self] }
    set { self[NativeSettingsEmbeddedKey.self] = newValue }
  }
}

private struct NativeSettingsPageModifier: ViewModifier {
  @Environment(\.nativeSettingsEmbedded) private var embedded
  func body(content: Content) -> some View {
    if embedded {
      content.scrollContentBackground(.hidden)
        .background(Color.nativeSurface.ignoresSafeArea())
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
    } else {
      content
    }
  }
}

extension View {
  /// 设置二级页面：画在 surface 画布上并使用行内标题
  func nativeSettingsPage() -> some View { modifier(NativeSettingsPageModifier()) }

  /// iPad 上以页面尺寸展示设置，留出与 main 设置弹窗相同的左侧分类栏
  @ViewBuilder
  func nativeSettingsSizing() -> some View {
    if #available(iOS 18.0, macOS 15.0, *) {
      presentationSizing(.page)
    } else {
      self
    }
  }
}
