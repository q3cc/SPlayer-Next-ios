import SwiftUI

/// 下载管理页：待下载 / 下载出错 / 已完成三栏，对应原版 pages/Download.vue 与 list/DownloadList.vue
@MainActor
struct NativeDownloadsView: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var downloads: NativeDownloadStore
  @State private var tab = "active"
  @State private var confirmClear = false
  @State private var deleting: NativeDownloadTask?

  /// 原版 sm 断点：窄于 640 时隐藏封面、大小、时长列，状态列收窄到 64
  private static let narrowWidth: CGFloat = 640
  /// 无损级别标签与标签写入警告的 amber-500
  private static let amber = Color(light: 0xF59E0B, dark: 0xF59E0B)

  private var current: [NativeDownloadTask] {
    switch tab {
    case "error": return downloads.historyTasks.filter { $0.status.isError }
    case "done": return downloads.historyTasks.filter { $0.status == .done }
    default: return downloads.activeTasks
    }
  }
  private var playable: [NativeTrack] { current.compactMap(downloads.localTrack) }

  var body: some View {
    GeometryReader { geometry in
      let narrow = geometry.size.width < Self.narrowWidth
      VStack(alignment: .leading, spacing: 0) {
        NativePageHeader(title: "下载管理", meta: [(icon: "music.note", text: "共 \(current.count) 首")]) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
              tabs
              Spacer(minLength: 0)
              headerActions
            }
            VStack(alignment: .leading, spacing: 16) {
              tabs
              headerActions
            }
          }
        }.padding(.horizontal, 20).padding(.bottom, 8)
        #if os(iOS)
          Text("文件 → 我的 iPhone / iPad → SPlayer Native → \(NativeDownloadStore.exportFolder)")
            .font(.system(size: 12)).foregroundStyle(Color.nativeOnSurfaceVariant)
            .padding(.horizontal, 20).padding(.bottom, 8)
        #endif
        if current.isEmpty {
          NativeEmptyState(
            icon: "arrow.down.to.line", text: tab == "done" ? "还没有下载完成的歌曲" : "暂无下载任务"
          ).frame(maxHeight: .infinity)
        } else {
          ScrollView {
            VStack(spacing: 0) {
              columnHeader(narrow: narrow)
              LazyVStack(spacing: 12) {
                ForEach(Array(current.enumerated()), id: \.element.id) { index, task in
                  row(task, index: index, narrow: narrow)
                }
              }.padding(.horizontal, 12)
            }.padding(.bottom, 80)
          }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityIdentifier("native.downloads.page")
      .confirmationDialog(
        "清空已完成任务", isPresented: $confirmClear, titleVisibility: .visible
      ) {
        Button("清空", role: .destructive) { downloads.clearFinished() }
      } message: {
        Text("将从列表移除所有已完成和出错的任务记录，已下载的本地文件不会被删除。确认清空？")
      }
      .confirmationDialog(
        "删除下载文件",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible
      ) {
        Button("删除文件", role: .destructive) {
          if let deleting { Task { await downloads.deleteFile(deleting.id) } }
          deleting = nil
        }
      } message: {
        Text("将删除应用曲库中的歌曲和「文件」中的副本，此操作不可恢复。确认删除？")
      }
  }

  /// STabs bar large
  private var tabs: some View {
    NativeTabs(
      selection: $tab,
      items: [(value: "active", title: "待下载"), (value: "error", title: "下载出错"), (value: "done", title: "已完成")],
      style: .bar, large: true
    ).accessibilityElement(children: .contain).accessibilityIdentifier("native.downloads.tabs")
  }

  /// 已完成页的播放全部（primary secondary round）与清空已完成（secondary round）
  private var headerActions: some View {
    HStack(spacing: 12) {
      if tab == "done" {
        NativeSButton(
          title: "播放全部", icon: "play.fill", variant: .secondary, tint: .primary, shape: .round
        ) {
          if let first = playable.first { player.play(first, in: playable, context: "下载管理") }
        }.disabled(playable.isEmpty)
      }
      NativeSButton(title: "清空已完成", icon: "trash", variant: .secondary, shape: .round) {
        confirmClear = true
      }.disabled(downloads.historyTasks.isEmpty)
    }.fixedSize()
  }

  /// 列表表头：# · 标题 · 状态 · 大小 · 时长 · 操作
  private func columnHeader(narrow: Bool) -> some View {
    HStack(spacing: narrow ? 8 : 12) {
      Text("#").frame(width: 32)
      Text("标题").padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
      Text("状态").frame(width: narrow ? 64 : 128, alignment: .leading)
      if !narrow {
        Text("大小").frame(width: 80)
        Text("时长").frame(width: 64)
        Text("操作").frame(width: 80)
      }
    }.font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6))
      .lineLimit(1).padding(.leading, narrow ? 8 : 12).padding(.trailing, narrow ? 8 : 24)
      .frame(height: 40).padding(.horizontal, 12 + 2)
      .accessibilityHidden(true)
  }

  /// 原版下载行：同舒适歌曲行 76 高、圆角 12、2px 边框；只有已完成且文件仍在的行可点击播放
  @ViewBuilder private func row(_ task: NativeDownloadTask, index: Int, narrow: Bool) -> some View {
    let local = downloads.localTrack(task)
    let playing = local != nil && player.current?.id == local?.id
    let content = rowContent(task, local: local, index: index, playing: playing, narrow: narrow)
      .padding(.leading, narrow ? 8 : 12).padding(.trailing, narrow ? 8 : 24)
      .frame(height: 76).contentShape(Rectangle())
    Group {
      if let local {
        Button {
          player.play(local, in: playable, context: "下载管理")
        } label: {
          content
        }.buttonStyle(NativeSongRowStyle(playing: playing, compact: false))
      } else {
        let shape = RoundedRectangle(cornerRadius: 12)
        content.background(Color.nativeSurfacePanel, in: shape)
          .overlay(shape.strokeBorder(Color.nativePrimary.opacity(0.12), lineWidth: 2))
          .accessibilityElement(children: .contain)
      }
    }.accessibilityIdentifier("native.download." + task.track.id)
      .contextMenu { menu(task) }
  }

  private func rowContent(
    _ task: NativeDownloadTask, local: NativeTrack?, index: Int, playing: Bool, narrow: Bool
  ) -> some View {
    HStack(spacing: narrow ? 8 : 12) {
      indexCell(task, local: local, index: index, playing: playing)
      HStack(spacing: 12) {
        if !narrow {
          NativeArtwork(cover: task.track.cover, radius: 8).frame(width: 48, height: 48)
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(task.track.title).font(.system(size: 16, weight: .medium))
              .foregroundStyle(playing ? Color.nativePrimary : Color.nativeOnSurface).lineLimit(1)
            if task.tagWarning == true {
              Image(systemName: "exclamationmark.triangle").font(.system(size: 14))
                .foregroundStyle(Self.amber).help("标签写入失败，文件已保存")
                .accessibilityLabel("标签写入失败，文件已保存")
            }
          }
          HStack(spacing: 4) {
            qualityTag(task.quality)
            Text(task.track.artist.replacingOccurrences(of: "/", with: " / ")).lineLimit(1)
          }.font(.system(size: 14)).foregroundStyle(
            playing ? Color.nativePrimary.opacity(0.7) : Color.nativeOnSurfaceVariant)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      status(task, local: local).frame(width: narrow ? 64 : 128, alignment: .leading)
      if !narrow {
        Text(sizeText(task)).font(.system(size: 14).monospacedDigit())
          .foregroundStyle(Color.nativeOnSurfaceVariant).lineLimit(1).frame(width: 80)
        Text(task.track.durationMs > 0 ? NativeNowPlayingView.time(task.track.durationMs) : "—")
          .font(.system(size: 14).monospacedDigit())
          .foregroundStyle(playing ? Color.nativePrimary.opacity(0.6) : Color.nativeOnSurfaceVariant)
          .frame(width: 64)
      }
      actions(task, local: local).frame(width: 80)
    }
  }

  /// 序号列：已完成显示序号（播放中为音符），点击切换播放；未完成显示下载中转圈或下载图标
  @ViewBuilder private func indexCell(
    _ task: NativeDownloadTask, local: NativeTrack?, index: Int, playing: Bool
  ) -> some View {
    if let local {
      Button {
        if playing {
          player.togglePlayback()
        } else {
          player.play(local, in: playable, context: "下载管理")
        }
      } label: {
        Group {
          if playing {
            Image(systemName: player.isPlaying ? "music.note" : "play.fill")
              .font(.system(size: 17, weight: .medium))
          } else {
            Text(String(index + 1)).font(.system(size: 14, weight: .bold).monospacedDigit())
          }
        }.foregroundStyle(playing ? Color.nativePrimary : Color.nativeOnSurfaceVariant)
          .frame(width: 32, height: 52).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(playing && player.isPlaying ? "暂停" : "播放 " + task.track.title)
    } else {
      Group {
        if task.status == .downloading {
          ProgressView().controlSize(.small).tint(Color.nativeOnSurfaceVariant)
            .scaleEffect(0.8)
        } else {
          Image(systemName: "arrow.down.to.line").font(.system(size: 14))
        }
      }.foregroundStyle(Color.nativeOnSurfaceVariant).frame(width: 32)
    }
  }

  /// STag tiny outline：无损级别为 amber，其余为 on-surface-variant
  private func qualityTag(_ quality: String) -> some View {
    let lossless = quality == "hi-res" || quality == "lossless"
    let color = lossless ? Self.amber : Color.nativeOnSurfaceVariant
    let label = ["hi-res": "Hi-Res", "lossless": "Lossless"][quality] ?? quality.uppercased()
    return Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
      .padding(.horizontal, 4).frame(height: 18)
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.4), lineWidth: 1))
      .fixedSize()
  }

  /// 状态列：下载中为 6 高进度条加百分比（总大小未知时显示已接收大小），其余为状态文字
  @ViewBuilder private func status(_ task: NativeDownloadTask, local: NativeTrack?) -> some View {
    if task.status == .downloading {
      VStack(alignment: .leading, spacing: 6) {
        Capsule().fill(Color.nativeOnSurface.opacity(0.1)).frame(height: 6).overlay(alignment: .leading) {
          GeometryReader { geometry in
            Capsule().fill(Color.nativePrimary)
              .frame(width: geometry.size.width * CGFloat(percent(task)) / 100)
              .animation(.easeOut(duration: 0.2), value: percent(task))
          }
        }.clipShape(Capsule())
        Text(task.total > 0 ? "\(percent(task))%" : size(task.received))
          .font(.system(size: 12).monospacedDigit())
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6)).lineLimit(1)
      }
    } else {
      Text(task.status == .done && local == nil ? "曲库中的文件已删除" : task.status.label)
        .font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6))
        .lineLimit(2).help(task.error ?? "")
        .accessibilityHint(task.error ?? "")
    }
  }

  /// 操作列：ghost 圆形 small 按钮，按状态显示取消 / 重试与移除 / 在「文件」中查看与删除文件
  @ViewBuilder private func actions(_ task: NativeDownloadTask, local: NativeTrack?) -> some View {
    HStack(spacing: 4) {
      if task.status.isActive {
        actionButton("xmark", label: "取消") { downloads.cancel(task.id) }
      } else if task.status.isError {
        actionButton("arrow.counterclockwise", label: "重试") { downloads.retry(task.id) }
        actionButton("trash", label: "移除") { downloads.remove(task.id) }
      } else if task.status == .done {
        #if os(iOS)
          if let path = task.exportPath {
            actionButton("folder", label: "在「文件」中查看") { openInFiles(path) }
          }
        #endif
        actionButton("trash", label: "删除文件") { deleting = task }
      }
    }
  }

  private func actionButton(_ icon: String, label: String, action: @escaping () -> Void)
    -> some View
  {
    NativeSButton(icon: icon, variant: .ghost, size: .small, shape: .circle, action: action)
      .accessibilityLabel(label)
  }

  /// 长按菜单保留全部任务操作，包括已完成任务的“仅移除记录”
  @ViewBuilder private func menu(_ task: NativeDownloadTask) -> some View {
    if task.status.isActive {
      Button("取消", systemImage: "xmark") { downloads.cancel(task.id) }
    } else {
      if task.status.isError {
        Button("重试", systemImage: "arrow.counterclockwise") { downloads.retry(task.id) }
      }
      #if os(iOS)
        if let path = task.exportPath {
          Button("在「文件」中查看", systemImage: "folder") { openInFiles(path) }
        }
      #endif
      Button("移除", systemImage: "minus.circle") { downloads.remove(task.id) }
      if task.status == .done {
        Button("删除文件", systemImage: "trash", role: .destructive) { deleting = task }
      }
    }
  }

  private func percent(_ task: NativeDownloadTask) -> Int {
    task.total > 0 ? min(100, Int((Double(task.received) / Double(task.total) * 100).rounded())) : 0
  }

  /// 文件大小：已知字节才显示
  private func sizeText(_ task: NativeDownloadTask) -> String {
    let bytes = task.total > 0 ? task.total : task.received
    return bytes > 0 ? size(bytes) : "—"
  }

  private func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  #if os(iOS)
    /// 「文件」App 的 shareddocuments 链接直接打开导出所在文件夹
    private func openInFiles(_ path: String) {
      let folder = NativeLibrary.defaultRoot().deletingLastPathComponent()
        .appendingPathComponent(NativeDownloadStore.exportFolder)
        .appendingPathComponent(path).deletingLastPathComponent()
      if let url = URL(string: "shareddocuments://" + folder.path.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed)!)
      {
        UIApplication.shared.open(url)
      }
    }
  #endif
}

/// 下载配置，分区与默认值对应 Next 的 settings/categories/download.ts
struct NativeDownloadSettings: View {
  @AppStorage("native.download.enabled") private var enabled = false
  @AppStorage("native.download.exportToFiles") private var exportToFiles = true
  @AppStorage("native.download.quality") private var quality = "lossless"
  @AppStorage("native.download.fileTemplate") private var fileTemplate = "{artist} - {title}"
  @AppStorage("native.download.folderScheme") private var folderScheme = "none"
  @AppStorage("native.download.overwrite") private var overwrite = "rename"
  @AppStorage("native.download.lyricFormat") private var lyricFormat = "enhanced-lrc"
  @AppStorage("native.download.embedCover") private var embedCover = true
  @AppStorage("native.download.embedMeta") private var embedMeta = true
  @AppStorage("native.download.embedLyric") private var embedLyric = true
  @AppStorage("native.download.writeLrc") private var writeLrc = false
  @AppStorage("native.download.saveTtml") private var saveTtml = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $enabled) { Text("启用下载功能") }
          .accessibilityIdentifier("native.settings.download.enabled")
        Toggle(isOn: $exportToFiles) {
          NativeSettingLabel(
            title: "保存到「文件」App", detail: "下载的歌曲始终加入应用曲库；开启后另在「文件」中按命名规则保留一份")
        }
        LabeledContent("下载目录") {
          Text("文件 › SPlayer Native › \(NativeDownloadStore.exportFolder)")
            .foregroundStyle(Color.nativeOnSurfaceVariant)
        }
      }
      Section("常规") {
        NativeSettingPicker(
          title: "下载音质", detail: "下载时优先使用的音质，实际可用受平台与账号权限限制", selection: $quality
        ) {
          Text("Hi-Res").tag("hi-res")
          Text("Lossless").tag("lossless")
          Text("HQ").tag("hq")
          Text("SQ").tag("sq")
          Text("LQ").tag("lq")
        }
        NativeSettingPicker(title: "文件名格式", detail: "下载文件的命名方式", selection: $fileTemplate) {
          Text("歌曲名").tag("{title}")
          Text("歌手 - 歌曲名").tag("{artist} - {title}")
          Text("歌曲名 - 歌手").tag("{title} - {artist}")
        }.disabled(!exportToFiles)
        NativeSettingPicker(title: "文件智能分类", detail: "下载时按规则归入子文件夹", selection: $folderScheme) {
          Text("不分文件夹").tag("none")
          Text("按歌手分文件夹").tag("artist")
          Text("按歌手 / 专辑分文件夹").tag("artist-album")
        }.disabled(!exportToFiles)
        NativeSettingPicker(title: "重名处理", detail: "目标文件已存在时的处理方式", selection: $overwrite) {
          Text("保留两者（加序号）").tag("rename")
          Text("覆盖").tag("overwrite")
          Text("跳过").tag("skip")
        }.disabled(!exportToFiles)
      }
      Section("标签与歌词") {
        NativeSettingPicker(
          title: "歌词文件格式", detail: "保存及内嵌到标签的歌词格式", selection: $lyricFormat
        ) {
          Text("LRC（逐行）").tag("lrc")
          Text("增强 LRC（逐字）").tag("enhanced-lrc")
        }
        Toggle(isOn: $embedCover) {
          NativeSettingLabel(title: "内嵌封面", detail: "将封面写入下载的音频文件")
        }
        Toggle(isOn: $embedMeta) {
          NativeSettingLabel(title: "内嵌元信息", detail: "将标题、艺术家、专辑写入文件标签")
        }
        Toggle(isOn: $embedLyric) {
          NativeSettingLabel(title: "内嵌歌词", detail: "将歌词写入文件标签")
        }
        Toggle(isOn: $writeLrc) {
          NativeSettingLabel(title: "同时保存歌词文件", detail: "下载歌曲时在同目录额外保存一份歌词文件")
        }.disabled(!exportToFiles)
        Toggle(isOn: $saveTtml) {
          NativeSettingLabel(title: "同时保存为 TTML", detail: "额外导出一份 TTML，单文件含原文、翻译与音译")
        }.disabled(!exportToFiles)
      }
    }.navigationTitle("下载配置")
  }
}

/// 歌曲行的已下载标记，单独观察下载状态避免整页重绘
struct NativeDownloadBadge: View {
  @ObservedObject var downloads: NativeDownloadStore
  let track: NativeTrack
  var body: some View {
    // 与原版歌曲行的“已下载”圆形对勾标签一致
    if track.source != nil, downloads.isDownloaded(track) {
      Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
        .foregroundStyle(Color.nativePrimary)
        .frame(width: 16, height: 16).background(Color.nativePrimary.opacity(0.15), in: Circle())
        .accessibilityLabel("已下载")
    }
  }
}

extension NativePlayerStore {
  /// 加入下载并给出与原版一致的提示
  func download(_ track: NativeTrack) {
    switch downloads.enqueue(track) {
    case .ok: notice = "已加入下载：" + track.title
    case .queued: notice = "该歌曲已在下载队列"
    case .downloaded: notice = "该歌曲已下载"
    case .unsupported: notice = "本地或自定义音源歌曲无需下载"
    }
  }

  /// 批量下载只处理在线歌曲
  func download(_ tracks: [NativeTrack]) {
    let count = downloads.enqueue(tracks)
    notice = count > 0 ? "已加入 \(count) 首下载" : "所选歌曲已下载或已在队列中"
  }
}

/// 顶部轻提示，数秒后自动消失
struct NativeNoticeBanner: View {
  @ObservedObject var player: NativePlayerStore
  var body: some View {
    if let message = player.notice {
      Text(message).font(.callout).padding(.horizontal, 18).padding(.vertical, 12)
        .nativeGlass(in: Capsule()).padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("native.notice")
        .task(id: message) {
          try? await Task.sleep(nanoseconds: 2_500_000_000)
          if !Task.isCancelled, player.notice == message {
            withAnimation { player.notice = nil }
          }
        }
    }
  }
}
