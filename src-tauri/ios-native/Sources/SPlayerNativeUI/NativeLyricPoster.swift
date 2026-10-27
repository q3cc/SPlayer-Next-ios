import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 海报中的一行歌词
struct NativeLyricPosterLine: Equatable {
  var text: String
  /// 沿用播放器的行语言识别结果
  var language: NativeLyricLanguage?
  var translation: String?
  var romaji: String?
  /// 对唱行右对齐
  var duet = false
}

/// 歌词海报，尺寸、行高、模糊背景与水印对应 Next 的 utils/lyric/poster.ts
enum NativeLyricPoster {
  static let scale: CGFloat = 3
  static let maxPixels: CGFloat = 16000
  static let width: CGFloat = 720
  static let padX: CGFloat = 56
  static let padTop: CGFloat = 64
  static let padBottom: CGFloat = 30
  static let lyricLineHeight: CGFloat = 48
  static let translationLineHeight: CGFloat = 34
  static let romajiLineHeight: CGFloat = 32
  static let sublineGap: CGFloat = 8
  static let blockGap: CGFloat = 30
  static let thumb: CGFloat = 72
  static let thumbRadius: CGFloat = 16
  static let thumbTextGap: CGFloat = 18
  static let headerGap: CGFloat = 44
  static let watermarkGap: CGFloat = 26
  static let watermarkHeight: CGFloat = 16
  static var contentWidth: CGFloat { width - padX * 2 }

  /// 与原版导出文件名一致，去掉文件系统不允许的字符
  static func fileName(title: String, artist: String) -> String {
    let raw = [title, artist, "歌词分享"].filter { !$0.isEmpty }.joined(separator: " - ")
    let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
    return raw.components(separatedBy: invalid).joined(separator: "_") + ".png"
  }

  private struct Block {
    var main: [CTLine]
    var translation: [CTLine]
    var romaji: [CTLine]
    var duet: Bool
  }

  /// 海报逻辑高度；超长海报降采样以免超出位图上限
  static func height(for lines: [NativeLyricPosterLine]) -> CGFloat {
    let blocks = layout(lines)
    return totalHeight(blocks)
  }

  /// 绘制选中歌词海报，返回 PNG 数据
  static func render(
    title: String, artist: String, lines: [NativeLyricPosterLine], cover: CGImage?,
    fallback: CGColor = CGColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x1C / 255, alpha: 1)
  ) -> Data? {
    let blocks = layout(lines)
    let height = totalHeight(blocks)
    let factor = min(scale, maxPixels / height)
    let pixelWidth = Int((width * factor).rounded())
    let pixelHeight = Int((height * factor).rounded())
    guard
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // 统一为左上原点的逻辑坐标，与 Canvas 一致
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: factor, y: -factor)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setFillColor(fallback)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    if let cover {
      let margin: CGFloat = 80
      let area = CGRect(
        x: -margin, y: -margin, width: width + margin * 2, height: height + margin * 2)
      if let blurred = blur(cover, sigma: 70, drawnIn: area.size, saturation: 1.2) {
        drawCovered(context, blurred, in: area)
      }
      context.setFillColor(CGColor(gray: 0, alpha: 0.5))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    // 顶部歌曲信息
    var titleX = padX
    if let cover {
      context.saveGState()
      context.addPath(
        CGPath(
          roundedRect: CGRect(x: padX, y: padTop, width: thumb, height: thumb),
          cornerWidth: thumbRadius, cornerHeight: thumbRadius, transform: nil))
      context.clip()
      drawCovered(context, cover, in: CGRect(x: padX, y: padTop, width: thumb, height: thumb))
      context.restoreGState()
      titleX = padX + thumb + thumbTextGap
    }
    let headerWidth = width - padX - titleX
    draw(
      line(title, font: headerFont(size: 28, weight: .bold), alpha: 1, width: headerWidth),
      context: context, x: titleX, top: padTop + 10, alignRight: false)
    draw(
      line(artist, font: headerFont(size: 22, weight: .regular), alpha: 0.7, width: headerWidth),
      context: context, x: titleX, top: padTop + 44, alignRight: false)

    // 歌词
    var y = padTop + thumb + headerGap
    for (index, block) in blocks.enumerated() {
      if index > 0 { y += blockGap }
      let x = block.duet ? width - padX : padX
      for line in block.main {
        draw(line, context: context, x: x, top: y, alignRight: block.duet)
        y += lyricLineHeight
      }
      if block.main.isEmpty { y += lyricLineHeight }
      if !block.translation.isEmpty {
        y += sublineGap
        for line in block.translation {
          draw(line, context: context, x: x, top: y, alignRight: block.duet)
          y += translationLineHeight
        }
      }
      if !block.romaji.isEmpty {
        y += sublineGap
        for line in block.romaji {
          draw(line, context: context, x: x, top: y, alignRight: block.duet)
          y += romajiLineHeight
        }
      }
    }

    // 底部居中水印
    let watermark = line(
      "Made by SPlayer Next", font: headerFont(size: 15, weight: .semibold), alpha: 0.4,
      width: width)
    let watermarkWidth = CGFloat(CTLineGetTypographicBounds(watermark, nil, nil, nil))
    draw(
      watermark, context: context, x: (width - watermarkWidth) / 2,
      top: height - padBottom - watermarkHeight, alignRight: false)

    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  private static func totalHeight(_ blocks: [Block]) -> CGFloat {
    var lyrics: CGFloat = 0
    for (index, block) in blocks.enumerated() {
      if index > 0 { lyrics += blockGap }
      lyrics += CGFloat(max(1, block.main.count)) * lyricLineHeight
      if !block.translation.isEmpty {
        lyrics += sublineGap + CGFloat(block.translation.count) * translationLineHeight
      }
      if !block.romaji.isEmpty {
        lyrics += sublineGap + CGFloat(block.romaji.count) * romajiLineHeight
      }
    }
    return padTop + thumb + headerGap + lyrics + watermarkGap + watermarkHeight + padBottom
  }

  /// 预折行：主行 bold 34、翻译 24、音译 italic 22，各自按语言选择字体
  private static func layout(_ lines: [NativeLyricPosterLine]) -> [Block] {
    lines.map { item in
      let mainFont = lyricFont(
        item.language ?? NativeLyricLanguage.detect(item.text), size: 34, weight: .bold)
      let translation = item.translation ?? ""
      let romaji = item.romaji ?? ""
      return Block(
        main: wrap(item.text.isEmpty ? " " : item.text, font: mainFont, alpha: 1),
        translation: translation.isEmpty
          ? []
          : wrap(
            translation, font: lyricFont(NativeLyricLanguage.detect(translation), size: 24),
            alpha: 0.6),
        romaji: romaji.isEmpty
          ? []
          : wrap(
            romaji, font: lyricFont(NativeLyricLanguage.detect(romaji), size: 22, italic: true),
            alpha: 0.45),
        duet: item.duet)
    }
  }

  /// 歌曲信息与水印使用全局字体（原生端即系统字体）
  private static func headerFont(size: CGFloat, weight: NativePlatformFont.Weight) -> CTFont {
    NativeLyricFonts.platformFont(family: nil, size: size, weight: weight)
  }

  /// 歌词文本按语言字体 → 歌词字体 → 系统字体回退，测量与绘制共用同一字体
  private static func lyricFont(
    _ language: NativeLyricLanguage?, size: CGFloat,
    weight: NativePlatformFont.Weight = .regular, italic: Bool = false
  ) -> CTFont {
    NativeLyricFonts.platformFont(
      family: NativeLyricFonts.family(for: language), size: size, weight: weight, italic: italic)
  }

  private static func attributed(_ text: String, font: CTFont, alpha: CGFloat)
    -> NSAttributedString
  {
    NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
          gray: 1, alpha: alpha),
      ])
  }

  /// 英文按词、CJK 按字折行，去掉行尾空白，与原版 wrapText 结果一致
  private static func wrap(_ text: String, font: CTFont, alpha: CGFloat) -> [CTLine] {
    let string = attributed(text, font: font, alpha: alpha)
    let typesetter = CTTypesetterCreateWithAttributedString(string)
    let length = string.length
    var start = 0
    var lines: [CTLine] = []
    let source = string.string as NSString
    while start < length {
      let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(contentWidth)))
      let piece = source.substring(with: NSRange(location: start, length: count))
        .trimmingCharacters(in: .whitespaces)
      if !piece.isEmpty || lines.isEmpty {
        lines.append(CTLineCreateWithAttributedString(attributed(piece, font: font, alpha: alpha)))
      }
      start += count
    }
    return lines
  }

  /// 单行文本超出宽度时以省略号结尾
  private static func line(_ text: String, font: CTFont, alpha: CGFloat, width: CGFloat) -> CTLine
  {
    let line = CTLineCreateWithAttributedString(attributed(text, font: font, alpha: alpha))
    let ellipsis = CTLineCreateWithAttributedString(attributed("…", font: font, alpha: alpha))
    return CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
  }

  /// top 为文字 em 框顶部，对应 Canvas 的 textBaseline = "top"
  private static func draw(
    _ line: CTLine, context: CGContext, x: CGFloat, top: CGFloat, alignRight: Bool
  ) {
    var ascent: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
    context.textPosition = CGPoint(x: alignRight ? x - lineWidth : x, y: top + ascent)
    CTLineDraw(line, context)
  }

  /// object-fit: cover 方式绘制图片
  private static func drawCovered(_ context: CGContext, _ image: CGImage, in rect: CGRect) {
    let imageRatio = CGFloat(image.width) / CGFloat(image.height)
    let boxRatio = rect.width / rect.height
    var crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    if imageRatio > boxRatio {
      crop.size.width = CGFloat(image.height) * boxRatio
      crop.origin.x = (CGFloat(image.width) - crop.width) / 2
    } else {
      crop.size.height = CGFloat(image.width) / boxRatio
      crop.origin.y = (CGFloat(image.height) - crop.height) / 2
    }
    guard let cropped = image.cropping(to: crop.integral) else { return }
    // 逻辑坐标已翻转，图片需再翻转一次保持正向
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(cropped, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }

  /// 对应 Canvas filter: blur(70px) saturate(1.2)；sigma 为绘制后的逻辑像素
  private static func blur(
    _ image: CGImage, sigma: CGFloat, drawnIn size: CGSize, saturation: CGFloat
  ) -> CGImage? {
    // 先缩小再模糊，大半径模糊结果一致且耗时可控
    let input = CIImage(cgImage: image)
    let shrink = min(1, 256 / CGFloat(max(image.width, image.height)))
    let scaled = input.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
    // 按 cover 方式铺满时图片的放大倍数，换算模糊半径到图片像素
    let cover = max(size.width / scaled.extent.width, size.height / scaled.extent.height)
    let filtered =
      scaled.clampedToExtent()
      .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
      .applyingGaussianBlur(sigma: Double(sigma / cover))
      .cropped(to: scaled.extent)
    return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
      filtered, from: scaled.extent)
  }
}
