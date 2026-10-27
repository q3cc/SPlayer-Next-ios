import SwiftUI

/// 设置项标题与说明，文案沿用 main 分支 settings.{key}.label / description
struct NativeSettingLabel: View {
  let title: String
  var detail: String? = nil
  var tag: String? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(title)
        if let tag { NativeSettingTag(text: tag) }
      }
      if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
    }
  }
}

/// 与 main 的 SettingTag 一致，用于 Beta 等实验性标记
struct NativeSettingTag: View {
  let text: String
  var body: some View {
    Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.15), in: Capsule())
  }
}

/// 分区标题，可附带 Beta 标记
struct NativeSettingHeader: View {
  let title: String
  var tag: String? = nil
  var body: some View {
    HStack(spacing: 6) {
      Text(title)
      if let tag { NativeSettingTag(text: tag) }
    }
  }
}

/// 滑块项：标题、说明、当前值与滑块同一行组，范围和步长对应 main 的 slider 配置
struct NativeSettingSlider: View {
  let title: String
  var detail: String? = nil
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  var format: (Double) -> String = { String(Int($0)) }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        NativeSettingLabel(title: title, detail: detail)
        Spacer()
        Text(format(min(max(value, range.lowerBound), range.upperBound))).monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: range, step: step)
    }
  }
}

/// 选择项：标题与说明在左侧换行，当前值固定靠右，窄屏下不被长说明挤到下一行
struct NativeSettingPicker<Value: Hashable, Options: View>: View {
  let title: String
  var detail: String? = nil
  @Binding var selection: Value
  var identifier: String? = nil
  @ViewBuilder let options: () -> Options
  var body: some View {
    HStack(spacing: 12) {
      NativeSettingLabel(title: title, detail: detail).frame(
        maxWidth: .infinity, alignment: .leading)
      Picker(title, selection: $selection, content: options).labelsHidden().fixedSize()
        .accessibilityIdentifier(identifier ?? "")
    }
  }
}

/// 系统设置风格的彩色圆角图标
struct NativeSettingIcon: View {
  let symbol: String
  let color: Color
  var size: CGFloat = 28
  var body: some View {
    Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold))
      .foregroundStyle(.white).frame(width: size, height: size)
      .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
      .accessibilityHidden(true)
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
          withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { selection = option.value }
        } label: {
          VStack(spacing: 10) {
            preview(option.value)
              .aspectRatio(aspect, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                  selected ? Color.accentColor : Color.primary.opacity(0.12),
                  lineWidth: selected ? 3 : 1)
              )
              .shadow(color: .black.opacity(selected ? 0.12 : 0.05), radius: selected ? 8 : 3, y: 2)
            Text(option.title).font(.subheadline.weight(selected ? .semibold : .regular))
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 20)).foregroundStyle(
                selected ? Color.accentColor : Color.secondary.opacity(0.5))
          }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel(option.title)
          .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
          .accessibilityIdentifier(identifier.isEmpty ? "" : "\(identifier).\(option.value)")
      }
    }.padding(.vertical, 8)
  }
}
