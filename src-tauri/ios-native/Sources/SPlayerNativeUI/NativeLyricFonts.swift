import CoreText
import SwiftUI

#if os(iOS)
  import UIKit
  typealias NativePlatformFont = UIFont
  typealias NativePlatformFontDescriptor = UIFontDescriptor
#else
  import AppKit
  typealias NativePlatformFont = NSFont
  typealias NativePlatformFontDescriptor = NSFontDescriptor
#endif

/// 歌词语言，取值与 lyric-kit 的 LyricLanguage 一致
enum NativeLyricLanguage: String, CaseIterable, Identifiable {
  case chinese = "zh-CN"
  case japanese = "ja"
  case korean = "ko"
  case latin = "und-Latn"

  var id: String { rawValue }
  /// 与原版字体配置的字段名称一致
  var title: String {
    switch self {
    case .chinese: return "中文歌词"
    case .japanese: return "日语歌词"
    case .korean: return "韩语歌词"
    case .latin: return "英语 / 拉丁文字歌词"
    }
  }
  var sample: String {
    switch self {
    case .chinese: return "春风十里不如你"
    case .japanese: return "夜に駆ける"
    case .korean: return "봄날의 노래"
    case .latin: return "Hello, World"
    }
  }
  /// 系统字体选择器按语言过滤可用字体
  var pickerLanguage: String {
    switch self {
    case .chinese: return "zh-Hans"
    case .japanese: return "ja"
    case .korean: return "ko"
    case .latin: return "en"
    }
  }
  var settingKey: String { NativeLyricFonts.lyricKey + "." + rawValue }

  /// 没有行语言时（翻译、音译、导入文本）按文字脚本识别；假名与谚文优先于汉字
  static func detect(_ text: String) -> NativeLyricLanguage? {
    var han = false
    var latin = false
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .japanese
      case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return .korean
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han = true
      case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin = true
      default: break
      }
    }
    return han ? .chinese : latin ? .latin : nil
  }
}

/// 歌词字体：语言专属字体 → 歌词字体 → 系统字体，与原版 CSS 字体回退顺序一致
enum NativeLyricFonts {
  static let lyricKey = "native.lyric.font"

  /// 读取设置中的字体族名称，空字符串视为未设置
  static func family(
    for language: NativeLyricLanguage?, lyric: String, specific: [NativeLyricLanguage: String]
  ) -> String? {
    if let language, let value = specific[language], !value.isEmpty { return value }
    return lyric.isEmpty ? nil : lyric
  }

  /// 非视图代码（海报、小窗）直接读取用户设置
  static func family(for language: NativeLyricLanguage?, defaults: UserDefaults = .standard)
    -> String?
  {
    var specific: [NativeLyricLanguage: String] = [:]
    for item in NativeLyricLanguage.allCases {
      specific[item] = defaults.string(forKey: item.settingKey) ?? ""
    }
    return family(
      for: language, lyric: defaults.string(forKey: lyricKey) ?? "", specific: specific)
  }

  /// SwiftUI 字体；自定义字体缺少对应字重时由系统合成
  static func font(family: String?, size: CGFloat, weight: Font.Weight) -> Font {
    guard let family else { return .system(size: size, weight: weight) }
    return .custom(family, size: size).weight(weight)
  }

  /// CoreText 绘制使用的字体，指定字体族不存在时回退系统字体
  static func platformFont(
    family: String?, size: CGFloat, weight: NativePlatformFont.Weight, italic: Bool = false
  ) -> NativePlatformFont {
    var font = NativePlatformFont.systemFont(ofSize: size, weight: weight)
    if let family {
      let descriptor = NativePlatformFontDescriptor(fontAttributes: [
        .family: family, .traits: [NativePlatformFontDescriptor.TraitKey.weight: weight],
      ])
      #if os(iOS)
        let candidate: UIFont? = UIFont(descriptor: descriptor, size: size)
      #else
        let candidate = NSFont(descriptor: descriptor, size: size)
      #endif
      if let candidate, candidate.familyName == family { font = candidate }
    }
    guard italic else { return font }
    #if os(iOS)
      if let descriptor = font.fontDescriptor.withSymbolicTraits(
        font.fontDescriptor.symbolicTraits.union(.traitItalic))
      {
        return UIFont(descriptor: descriptor, size: size)
      }
      return font
    #else
      let descriptor = font.fontDescriptor.withSymbolicTraits(
        font.fontDescriptor.symbolicTraits.union(.italic))
      return NSFont(descriptor: descriptor, size: size) ?? font
    #endif
  }
}

/// 歌词与各语言字体设置；与原版字体配置的“歌词字体”分组对应
struct NativeLyricFontSettings: View {
  @AppStorage(NativeLyricFonts.lyricKey) private var lyric = ""
  @AppStorage(NativeLyricLanguage.chinese.settingKey) private var chinese = ""
  @AppStorage(NativeLyricLanguage.japanese.settingKey) private var japanese = ""
  @AppStorage(NativeLyricLanguage.korean.settingKey) private var korean = ""
  @AppStorage(NativeLyricLanguage.latin.settingKey) private var latin = ""

  var body: some View {
    Section {
      row(.lyric, value: $lyric)
      ForEach(NativeLyricLanguage.allCases) { language in
        row(.language(language), value: binding(language))
      }
    } header: {
      Text("歌词字体")
    } footer: {
      Text("按歌词行识别的语言选择字体；未设置时跟随歌词字体，歌词字体未设置时使用系统字体")
    }
  }

  private func binding(_ language: NativeLyricLanguage) -> Binding<String> {
    switch language {
    case .chinese: return $chinese
    case .japanese: return $japanese
    case .korean: return $korean
    case .latin: return $latin
    }
  }

  /// 预览文字直接使用所选字体，右侧可一键恢复默认
  private func row(_ target: NativeFontTarget, value: Binding<String>) -> some View {
    HStack(spacing: 12) {
      Button {
        #if os(iOS)
          NativeFontPicker.present(language: target.language?.pickerLanguage) { family in
            value.wrappedValue = family
          }
        #endif
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(target.title)
            Text(target.language?.sample ?? "歌词字体预览 Lyrics")
              .font(
                NativeLyricFonts.font(
                  family: value.wrappedValue.isEmpty
                    ? (target.language == nil || lyric.isEmpty ? nil : lyric)
                    : value.wrappedValue, size: 15, weight: .semibold)
              )
              .foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Text(
            value.wrappedValue.isEmpty
              ? (target.language == nil ? "系统默认" : "跟随歌词") : value.wrappedValue
          ).foregroundStyle(.secondary).lineLimit(1)
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("native.settings.font.\(target.id)")
      if !value.wrappedValue.isEmpty {
        Button {
          value.wrappedValue = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }.buttonStyle(.borderless).accessibilityLabel("恢复默认")
      }
    }
  }
}

private enum NativeFontTarget: Identifiable, Hashable {
  case lyric
  case language(NativeLyricLanguage)
  var id: String {
    switch self {
    case .lyric: return "lyric"
    case .language(let value): return value.rawValue
    }
  }
  var language: NativeLyricLanguage? {
    if case .language(let value) = self { return value }
    return nil
  }
  var title: String { language?.title ?? "歌词" }
}

#if os(iOS)
  /// 系统字体选择器，按语言只列出支持该文字的字体；从最上层控制器弹出，避免嵌套 sheet 关闭设置页
  enum NativeFontPicker {
    private static var coordinator: Coordinator?

    @MainActor static func present(language: String?, done: @escaping (String) -> Void) {
      guard
        var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
      else { return }
      while let presented = top.presentedViewController { top = presented }
      let configuration = UIFontPickerViewController.Configuration()
      configuration.includeFaces = false
      configuration.displayUsingSystemFont = false
      if let language {
        configuration.filteredLanguagesPredicate =
          UIFontPickerViewController.Configuration.filterPredicate(forFilteredLanguages: [
            language
          ])
      }
      let picker = UIFontPickerViewController(configuration: configuration)
      let coordinator = Coordinator(done: done)
      Self.coordinator = coordinator
      picker.delegate = coordinator
      picker.modalPresentationStyle = .formSheet
      top.present(picker, animated: true)
    }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
      let done: (String) -> Void
      init(done: @escaping (String) -> Void) { self.done = done }
      /// 选择器可能返回字体名，统一换算为字体族名保存
      func fontPickerViewControllerDidPickFont(_ controller: UIFontPickerViewController) {
        if let descriptor = controller.selectedFontDescriptor {
          done(UIFont(descriptor: descriptor, size: 17).familyName)
        }
        controller.dismiss(animated: true)
        NativeFontPicker.coordinator = nil
      }
      func fontPickerViewControllerDidCancel(_ controller: UIFontPickerViewController) {
        controller.dismiss(animated: true)
        NativeFontPicker.coordinator = nil
      }
    }
  }
#endif
