import ImageIO
import SwiftUI

/// 图片按展示尺寸解码，缓存有数量和内存上限
actor NativeArtworkCache {
  static let shared = NativeArtworkCache()
  private let cache = NSCache<NSString, NativeImageBox>()
  /// 建立有容量限制的封面缓存及图像所有权
  init() {
    cache.countLimit = 80
    cache.totalCostLimit = 24 * 1024 * 1024
  }
  /// 按目标像素尺寸解码封面，并使用有界内存缓存
  func image(_ value: String, pixels: Int) async -> CGImage? {
    let key = (value + "#\(pixels)") as NSString
    if let image = cache.object(forKey: key) { return image.image }
    let url: URL
    if value.hasPrefix("native-cover:") {
      let name = String(value.dropFirst(13))
      guard URL(fileURLWithPath: name).lastPathComponent == name, !name.hasPrefix(".") else {
        return nil
      }
      url = NativeLibrary.defaultRoot().appendingPathComponent(name)
    } else {
      guard let remote = URL(string: value), ["http", "https"].contains(remote.scheme ?? "") else {
        return nil
      }
      url = remote
    }
    let data: Data
    do {
      if url.isFileURL {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024
        else { return nil }
        data = try Data(contentsOf: url)
      } else {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var body = Data()
        for try await byte in bytes {
          guard body.count < 8 * 1024 * 1024 else { return nil }
          body.append(byte)
        }
        data = body
      }
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { return nil }
      cache.setObject(NativeImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
      return image
    } catch { return nil }
  }
}
private final class NativeImageBox {
  let image: CGImage
  /// 建立有容量限制的封面缓存及图像所有权
  init(_ image: CGImage) { self.image = image }
}

struct NativeArtwork: View {
  let cover: String?
  var radius: CGFloat = 8
  var pixels = 300
  @State private var image: CGImage?
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.primary.opacity(0.055)
        if let image {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        } else {
          NativeLogo().padding(geometry.size.width * 0.24).opacity(0.65)
        }
      }.clipShape(RoundedRectangle(cornerRadius: radius))
    }.task(id: cover) {
      image = nil
      if let cover, !cover.isEmpty {
        let loaded = await NativeArtworkCache.shared.image(cover, pixels: pixels)
        if !Task.isCancelled { image = loaded }
      }
    }.accessibilityHidden(true)
  }
}
