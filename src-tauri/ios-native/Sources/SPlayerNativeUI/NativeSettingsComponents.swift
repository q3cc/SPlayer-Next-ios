import SwiftUI

/// 设置右栏的横向内边距：原版 32，平板窄宽 16
private struct NativeSettingsMarginKey: EnvironmentKey {
  static let defaultValue: CGFloat = 32
}

extension EnvironmentValues {
  var nativeSettingsMargin: CGFloat {
    get { self[NativeSettingsMarginKey.self] }
    set { self[NativeSettingsMarginKey.self] = newValue }
  }
}

/// 原版 SettingsItem 之间 gap-2.5；间隔画在卡片下方，行插图同步加高
private let nativeSettingGap: CGFloat = 10

/// 设置页容器：原版右栏 bg-surface、py-6 px-8，每个设置项一张卡片。
/// 不用 Form：inset 分组会按系统圆角裁切首末行，画不出 12 圆角的独立卡片；分区标题画成普通行以免吸顶
struct NativeSettingsList<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    let margin: CGFloat = sizeClass == .compact ? 16 : 32
    List {
      // 首个分区标题自带 32 − 10 的上间距，补足原版顶部 24
      NativeSettingSpacer(height: 2)
      content()
      NativeSettingSpacer(height: 24 - nativeSettingGap)
    }
    .listStyle(.plain)
    .tint(Color.nativePrimary)
    .toggleStyle(SwitchToggleStyle(tint: Color.nativePrimary.opacity(0.8)))
    .scrollContentBackground(.hidden)
    .background(Color.nativeSurface.ignoresSafeArea())
    .environment(\.defaultMinListRowHeight, 0)
    .environment(\.nativeSettingsMargin, margin)
    #if os(iOS)
      .listRowSpacing(0)
    #endif
  }
}

/// 列表首尾的透明占位行
private struct NativeSettingSpacer: View {
  let height: CGFloat
  var body: some View {
    Color.clear.frame(height: height).listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear).listRowSeparator(.hidden).accessibilityHidden(true)
  }
}

/// 原版 SettingsSection：带竖条的 18 semibold 标题，其下每项一张卡片；footer 为原生补充说明
struct NativeSettingSection<Content: View, Trailing: View>: View {
  let title: String
  var tag: String? = nil
  var footer: String? = nil
  @ViewBuilder let content: () -> Content
  @ViewBuilder var trailing: () -> Trailing
  @Environment(\.nativeSettingsMargin) private var margin

  var body: some View {
    Group {
      NativeSettingHeader(title: title, tag: tag, trailing: trailing)
        .listRowInsets(
          EdgeInsets(
            top: 32 - nativeSettingGap, leading: margin + 4, bottom: 12, trailing: margin + 4)
        )
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
      Group { content() }.nativeSettingCard(margin: margin)
      if let footer {
        Text(footer).font(.system(size: 12))
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
          .listRowInsets(
            EdgeInsets(top: 0, leading: margin + 4, bottom: nativeSettingGap, trailing: margin + 4)
          )
          .listRowBackground(Color.clear).listRowSeparator(.hidden)
      }
    }
  }
}

extension NativeSettingSection where Trailing == EmptyView {
  init(
    _ title: String, tag: String? = nil, footer: String? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(title: title, tag: tag, footer: footer, content: content) { EmptyView() }
  }
}

extension View {
  /// 把列表行画成原版设置项卡片：圆角 12、surface-panel、outline-variant/15 边框、内边距 16×14
  /// @param margin - 右栏横向内边距
  func nativeSettingCard(margin: CGFloat) -> some View {
    font(.system(size: 16)).foregroundStyle(Color.nativeOnSurface)
      .listRowInsets(
        EdgeInsets(
          top: 14, leading: margin + 16, bottom: 14 + nativeSettingGap, trailing: margin + 16)
      )
      .listRowBackground(NativeSettingCardBackground(margin: margin))
      .listRowSeparator(.hidden)
  }
}

/// 设置项卡片底板，下方留出与下一项的间距
private struct NativeSettingCardBackground: View {
  let margin: CGFloat
  var body: some View {
    RoundedRectangle(cornerRadius: 12).fill(Color.nativeSurfacePanel)
      .overlay(
        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.nativeOutlineVariant.opacity(0.15))
      )
      .padding(.horizontal, margin).padding(.bottom, nativeSettingGap)
  }
}

/// 分区标题：3×16 primary 竖条、间距 8、18 semibold，可带 STag 与行尾操作
struct NativeSettingHeader<Trailing: View>: View {
  let title: String
  var tag: String? = nil
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 8) {
      Capsule().fill(Color.nativePrimary).frame(width: 3, height: 16)
      Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.nativeOnSurface)
      if let tag { NativeSettingTag(text: tag).padding(.leading, 4) }
      Spacer(minLength: 0)
      trailing()
    }.accessibilityElement(children: .contain)
  }
}

extension NativeSettingHeader where Trailing == EmptyView {
  init(title: String, tag: String? = nil) {
    self.init(title: title, tag: tag) { EmptyView() }
  }
}

/// 设置项标题与说明：标题 16 regular，说明 14 on-surface-variant/70、上边距 2
struct NativeSettingLabel: View {
  let title: String
  var detail: String? = nil
  var tag: String? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 16)).foregroundStyle(Color.nativeOnSurface)
        if let tag { NativeSettingTag(text: tag) }
      }
      if let detail {
        Text(detail).font(.system(size: 14))
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
      }
    }
  }
}

/// 原版 STag（soft、字重 500、圆角 6）
struct NativeSettingTag: View {
  enum Size { case tiny, small, medium }
  let text: String
  var size: Size = .medium
  /// primary 软底；否则为 default 的 on-surface/12
  var primary = true
  var round = false

  var body: some View {
    let metrics: (height: CGFloat, padding: CGFloat, font: CGFloat) =
      switch size {
      case .tiny: (16, 4, 10)
      case .small: (20, 6, 12)
      case .medium: (24, 8, 14)
      }
    Text(text).font(.system(size: metrics.font, weight: .medium)).lineLimit(1)
      .padding(.horizontal, metrics.padding).frame(height: metrics.height)
      .foregroundStyle(primary ? Color.nativePrimary : Color.nativeOnSurface)
      .background(
        primary ? Color.nativePrimary.opacity(0.15) : Color.nativeOnSurface.opacity(0.12),
        in: RoundedRectangle(cornerRadius: round ? metrics.height / 2 : 6))
  }
}

/// 右侧控件列：原版 w-50、右对齐；窄宽时控件换到标题下方
private struct NativeSettingRow<Control: View>: View {
  let title: String
  var detail: String?
  var tag: String? = nil
  /// 控件是否需要占满整列（滑块）
  var fill = false
  @ViewBuilder let control: () -> Control
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    if fill && sizeClass == .compact {
      VStack(alignment: .leading, spacing: 10) {
        NativeSettingLabel(title: title, detail: detail, tag: tag)
        control()
      }
    } else {
      HStack(spacing: 16) {
        NativeSettingLabel(title: title, detail: detail, tag: tag)
          .frame(maxWidth: .infinity, alignment: .leading)
        if sizeClass == .compact {
          control().fixedSize()
        } else {
          control().frame(width: 200, alignment: .trailing)
        }
      }
    }
  }
}

/// 滑块项：滑块在右侧 200 宽控件列，当前值显示在滑块前；范围和步长对应 main 的 slider 配置
struct NativeSettingSlider: View {
  let title: String
  var detail: String? = nil
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  var format: (Double) -> String = { String(Int($0)) }
  var body: some View {
    NativeSettingRow(title: title, detail: detail, fill: true) {
      HStack(spacing: 8) {
        Text(format(min(max(value, range.lowerBound), range.upperBound)))
          .font(.system(size: 14)).monospacedDigit()
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
        Slider(value: $value, in: range, step: step).accessibilityLabel(title)
      }
    }
  }
}

/// 选择项：系统菜单 Picker 套原版 SSelect 外框（高 34、圆角 8、on-surface/20 边框），右对齐
struct NativeSettingPicker<Value: Hashable, Options: View>: View {
  let title: String
  var detail: String? = nil
  @Binding var selection: Value
  var identifier: String? = nil
  @ViewBuilder let options: () -> Options
  var body: some View {
    NativeSettingRow(title: title, detail: detail) {
      Picker(title, selection: $selection, content: options).labelsHidden().pickerStyle(.menu)
        .tint(Color.nativeOnSurface).font(.system(size: 14))
        .frame(minHeight: 34).padding(.horizontal, 4)
        .background(
          Color.nativeSurfaceBright.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8).strokeBorder(Color.nativeOnSurface.opacity(0.2))
        )
        .accessibilityIdentifier(identifier ?? "")
    }
  }
}

/// 自定义控件项：标题说明在左，任意控件放入右侧控件列
struct NativeSettingControl<Control: View>: View {
  let title: String
  var detail: String? = nil
  /// 控件占满控件列，窄宽时换到标题下方
  var fill = false
  @ViewBuilder let control: () -> Control
  var body: some View {
    NativeSettingRow(title: title, detail: detail, fill: fill, control: control)
  }
}

/// 带预览图的单选卡片，用于主题、播放器风格等需要直观对比的选项
struct NativeChoiceCards<Value: Hashable, Preview: View>: View {
  let options: [(value: Value, title: String)]
  @Binding var selection: Value
  var identifier: String = ""
  var aspect: CGFloat = 0.75
  @ViewBuilder let preview: (Value) -> Preview
  @NativeReduceMotion private var reduceMotion

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      ForEach(options, id: \.value) { option in
        let selected = option.value == selection
        Button {
          withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.2)) {
            selection = option.value
          }
        } label: {
          VStack(spacing: 10) {
            preview(option.value)
              .aspectRatio(aspect, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                  selected ? Color.nativePrimary : Color.nativeOnSurface.opacity(0.12),
                  lineWidth: selected ? 2 : 1)
              )
            Text(option.title).font(.system(size: 14, weight: selected ? .medium : .regular))
              .foregroundStyle(selected ? Color.nativePrimary : Color.nativeOnSurface)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 18)).foregroundStyle(
                selected ? Color.nativePrimary : Color.nativeOnSurfaceVariant.opacity(0.5))
          }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel(option.title)
          .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
          .accessibilityIdentifier(identifier.isEmpty ? "" : "\(identifier).\(option.value)")
      }
    }
  }
}
