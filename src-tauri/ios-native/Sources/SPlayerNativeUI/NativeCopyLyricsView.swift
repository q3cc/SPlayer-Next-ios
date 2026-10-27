import SwiftUI

#if os(iOS)
  import Photos
#endif

/// Next 复制歌词的筛选顺序、空行和署名格式
struct NativeCopyLyricsOptions {
  var translation = true
  var romanization = true
  var emptyLine = false
  var songName = true
  var artist = true

  /// 按原时间轴输出选中主行，背景人声不混入复制结果
  func text(lines: [NativeLyricLine], selected: Set<Int>, title: String, artistName: String)
    -> String
  {
    let separator = emptyLine ? "\n\n" : "\n"
    var text = lines.filter { $0.isBackground != true && selected.contains($0.id) }.map { line in
      var parts = [line.text]
      if translation { parts.append(line.translation) }
      if romanization { parts.append(line.romanization ?? "") }
      return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }.filter { !$0.isEmpty }.joined(separator: separator)
    let suffix =
      songName
      ? "——《\(title)》" + (artist ? " - \(artistName)" : "") : artist ? "—— \(artistName)" : ""
    if !suffix.isEmpty { text += separator + suffix }
    return text
  }
}

@MainActor
struct NativeCopyLyricsView: View {
  @ObservedObject var player: NativePlayerStore
  @State private var selected: Set<Int> = []
  @State private var options = NativeCopyLyricsOptions()
  @State private var copied = false
  @State private var poster: NativePosterFile?
  @State private var rendering = false
  private var lines: [NativeLyricLine] { player.lyrics.filter { $0.isBackground != true } }
  private var text: String {
    options.text(lines: lines, selected: selected, title: player.title, artistName: player.artist)
  }
  var body: some View {
    Form {
      Section {
        HStack {
          Button(selected.count == lines.count ? "取消全选" : "全选") {
            selected = selected.count == lines.count ? [] : Set(lines.map(\.id))
          }
          Spacer()
          Button("反选") { selected = Set(lines.map(\.id)).subtracting(selected) }
        }.buttonStyle(.borderless)
        ForEach(lines) { line in
          Toggle(
            isOn: Binding(
              get: { selected.contains(line.id) },
              set: { enabled in
                if enabled { selected.insert(line.id) } else { selected.remove(line.id) }
              })
          ) {
            VStack(alignment: .leading, spacing: 4) {
              Text(line.text)
              if options.translation && !line.translation.isEmpty {
                Text(line.translation).font(.caption).foregroundStyle(.secondary)
              }
              if options.romanization, let roman = line.romanization, !roman.isEmpty {
                Text(roman).font(.caption).italic().foregroundStyle(.secondary)
              }
            }
          }
        }
      } header: {
        Text("已选 \(selected.count) 行")
      }
      Section("复制内容") {
        Toggle("翻译", isOn: $options.translation)
        Toggle("罗马音", isOn: $options.romanization)
        Toggle("空行分隔", isOn: $options.emptyLine)
        Toggle("歌名", isOn: $options.songName)
        Toggle("歌手", isOn: $options.artist)
      }
      Section {
        Button(copied ? "已复制" : "复制选中歌词") { copy(text) }.disabled(text.isEmpty)
        Button("复制歌词原文") { if let raw = player.rawLyrics { copy(raw) } }.disabled(
          player.rawLyrics?.isEmpty != false)
        ShareLink("分享选中歌词", item: text).disabled(text.isEmpty)
        Button {
          makePoster()
        } label: {
          HStack {
            Text("生成歌词海报")
            Spacer()
            if rendering { ProgressView() }
          }
        }.disabled(selected.isEmpty || rendering).accessibilityIdentifier("native.lyrics.poster")
      }
    }.onAppear { selected = Set(lines.map(\.id)) }
      .sheet(item: $poster) { NativeLyricPosterPreview(poster: $0) }
  }

  /// 海报沿用复制选项：翻译、音译开关决定副行，对唱行右对齐
  private func makePoster() {
    let chosen = lines.filter { selected.contains($0.id) }.map { line in
      NativeLyricPosterLine(
        text: line.text, language: line.language.flatMap(NativeLyricLanguage.init(rawValue:)),
        translation: options.translation ? line.translation : nil,
        romaji: options.romanization ? line.romanization : nil, duet: line.isDuet == true)
    }
    guard !chosen.isEmpty else { return }
    rendering = true
    let title = player.title
    let artist = player.artist
    let cover = player.current?.cover
    Task {
      defer { rendering = false }
      var image: CGImage?
      if let cover { image = await NativeArtworkCache.shared.image(cover, pixels: 1000) }
      let artwork = image
      let data = await Task.detached(priority: .userInitiated) {
        NativeLyricPoster.render(title: title, artist: artist, lines: chosen, cover: artwork)
      }.value
      guard let data else {
        player.error = "导出图片失败"
        return
      }
      do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
          "LyricPoster-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(
          NativeLyricPoster.fileName(title: title, artist: artist))
        try data.write(to: url, options: .atomic)
        poster = NativePosterFile(url: url, data: data)
      } catch {
        player.error = "导出图片失败：" + error.localizedDescription
      }
    }
  }
  /// 只把用户选中的文本交给系统剪贴板
  private func copy(_ text: String) {
    #if os(iOS)
      UIPasteboard.general.string = text
    #endif
    copied = true
  }
}

struct NativePosterFile: Identifiable {
  let id = UUID()
  let url: URL
  let data: Data
}

/// 海报预览：系统分享（含“存储图像”）与保存到相册
@MainActor
struct NativeLyricPosterPreview: View {
  let poster: NativePosterFile
  @Environment(\.dismiss) private var dismiss
  @State private var status: String?
  var body: some View {
    NavigationStack {
      ScrollView {
        #if os(iOS)
          if let image = UIImage(data: poster.data) {
            Image(uiImage: image).resizable().scaledToFit()
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
              .padding(24).accessibilityIdentifier("native.poster.image")
          }
        #endif
      }.background(Color.nativeCanvas)
        .navigationTitle("歌词海报")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
          ToolbarItemGroup(placement: .primaryAction) {
            #if os(iOS)
              Button {
                save()
              } label: {
                Label("保存到相册", systemImage: "square.and.arrow.down")
              }.accessibilityIdentifier("native.poster.save")
            #endif
            ShareLink(item: poster.url) { Label("分享", systemImage: "square.and.arrow.up") }
          }
        }
        .overlay(alignment: .bottom) {
          if let status {
            Text(status).font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
              .nativeGlass(in: Capsule()).padding(.bottom, 24).transition(.opacity)
          }
        }
    }
  }

  #if os(iOS)
    /// 只申请“添加照片”权限，不读取用户相册
    private func save() {
      let data = poster.data
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { state in
        guard state == .authorized || state == .limited else {
          Task { @MainActor in withAnimation { status = "没有相册写入权限" } }
          return
        }
        PHPhotoLibrary.shared().performChanges {
          PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        } completionHandler: { ok, _ in
          Task { @MainActor in withAnimation { status = ok ? "已保存到相册" : "保存失败" } }
        }
      }
    }
  #endif
}
