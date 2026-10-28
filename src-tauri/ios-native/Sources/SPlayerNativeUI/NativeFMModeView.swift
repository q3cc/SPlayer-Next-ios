import SwiftUI

/// 私人 FM 模式选择，模式、场景分组及提示文案对应 Next 的 FmModeDialog
@MainActor
struct NativeFMModeView: View {
  @ObservedObject var player: NativePlayerStore
  @Environment(\.dismiss) private var dismiss
  @State private var selectedMode = "DEFAULT"
  @State private var switching: String?
  @State private var notice: String?

  static let modes: [(id: String, title: String, detail: String)] = [
    ("DEFAULT", "默认模式", "沿着目前喜好继续聆听"),
    ("FAMILIAR", "熟悉模式", "喜欢过的歌曲与相似推荐"),
    ("EXPLORE", "探索模式", "偏好曲风与潜力好歌"),
    ("SCENE_RCMD", "场景模式", "根据特定场景与氛围推荐"),
  ]
  static let scenes: [(title: String, items: [(id: String, label: String)])] = [
    (
      "生活场景",
      [
        ("EXERCISE", "运动"), ("FOCUS", "专注"), ("SLEEP_HELP", "助眠"), ("COMMUTE", "出行"),
        ("COFFEE_SHOP", "咖啡馆"), ("TAKE_SHOWER", "洗澡"), ("GAMES", "游戏"),
      ]
    ),
    (
      "心情氛围",
      [
        ("RELAX", "放松"), ("CHEERFUL", "欢快"), ("NIGHT_EMO", "伤感"), ("CURE", "治愈"),
        ("LYRICAL", "抒情"), ("SWEET", "情歌"), ("INSPIRATIONAL", "励志"), ("RAINY", "雨天"),
      ]
    ),
    (
      "曲风流派",
      [
        ("GUOFENG", "国风"), ("CHINESE", "华语"), ("ENGLISH", "欧美"), ("YUEYU", "粤语"),
        ("JAPANESE", "日语"), ("K_POP", "K-Pop"), ("FRANCH", "法语"), ("GLOBAL", "全球"),
        ("ELECTRONIC", "电音"), ("RAP", "说唱"), ("ROCK", "摇滚"), ("FOLK", "民谣"),
        ("ACG", "二次元"), ("LIGHT", "轻音乐"), ("JAZZ", "爵士"), ("GUDIAN", "古典"),
        ("RHYTHM_BLUES", "R&B"), ("BLUE", "蓝调"), ("PUNK", "放克"), ("DANCE", "舞蹈"),
        ("LATIN", "拉丁"), ("COUNTRY", "乡村乐"), ("MANYAO", "慢摇DJ"), ("JINGDIAN", "经典"),
        ("ORIGINAL_MUSICIAL", "宝藏原创"), ("MUSICAL", "音乐剧"), ("YINGSHI", "影视"),
      ]
    ),
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("选择喜好的推荐模式与场景").font(.subheadline).foregroundStyle(.secondary)
          Text("推荐模式").font(.headline)
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(Self.modes, id: \.id) { mode in
              Button {
                selectedMode = mode.id
                guard mode.id != "SCENE_RCMD" else { return }
                apply(NativeFMOption(mode: mode.id), label: "已切换至 「\(mode.title)」", failure: "模式切换失败，请稍后重试")
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  HStack {
                    Text(mode.title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if switching == mode.id { ProgressView().controlSize(.small) }
                  }
                  Text(mode.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    selectedMode == mode.id ? Color.accentColor.opacity(0.14) : Color.nativeSurfacePanel,
                    in: RoundedRectangle(cornerRadius: 12)
                  )
                  .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(
                      selectedMode == mode.id ? Color.accentColor.opacity(0.5) : .primary.opacity(0.1)))
              }.buttonStyle(.plain).accessibilityIdentifier("native.fm.mode." + mode.id)
            }
          }
          Text("场景与风格").font(.headline)
          ForEach(Self.scenes, id: \.title) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(group.title).font(.system(size: 13)).foregroundStyle(.secondary)
              NativeTagFlow(spacing: 8) {
                ForEach(group.items, id: \.id) { item in
                  let active =
                    player.fmOption.mode == "SCENE_RCMD" && player.fmOption.submode == item.id
                  Button {
                    selectedMode = "SCENE_RCMD"
                    apply(
                      NativeFMOption(mode: "SCENE_RCMD", submode: item.id),
                      label: "已切换至 「\(item.label)」场景", failure: "场景切换失败，请稍后重试")
                  } label: {
                    Text(item.label).font(.system(size: 13, weight: active ? .semibold : .regular))
                      .padding(.horizontal, 12).padding(.vertical, 7)
                      .background(
                        active ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule()
                      )
                      .foregroundStyle(active ? Color.white : .primary)
                  }.buttonStyle(.plain).disabled(switching != nil)
                }
              }
            }
          }
        }.padding(20)
      }.navigationTitle("私人 FM 模式选择")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        .overlay(alignment: .bottom) {
          if let notice {
            Text(notice).font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
              .nativeGlass(in: Capsule()).padding(.bottom, 16).transition(.opacity)
          }
        }
    }.onAppear { selectedMode = player.fmOption.mode }
  }

  /// 切换成功后立即播放新模式的首曲，并关闭弹窗
  private func apply(_ option: NativeFMOption, label: String, failure: String) {
    guard switching == nil else { return }
    switching = option.submode ?? option.mode
    Task {
      let ok = await player.startFM(option)
      switching = nil
      withAnimation { notice = ok ? label : failure }
      if ok {
        try? await Task.sleep(nanoseconds: 700_000_000)
        dismiss()
      }
    }
  }
}

/// 标签按自然宽度换行
struct NativeTagFlow: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? 600).size
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (index, frame) in arrange(subviews, width: bounds.width).frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }
  private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    var frames: [CGRect] = []
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += row + spacing
        row = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      row = max(row, size.height)
    }
    return (CGSize(width: width, height: y + row), frames)
  }
}
