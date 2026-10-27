import SwiftUI

/// 下载管理页：待下载 / 下载出错 / 已完成三栏，对应 Next 的 pages/Download.vue
@MainActor
struct NativeDownloadsView: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var downloads: NativeDownloadStore
  @State private var tab = "active"
  @State private var confirmClear = false
  @State private var deleting: NativeDownloadTask?

  private var current: [NativeDownloadTask] {
    switch tab {
    case "error": return downloads.historyTasks.filter { $0.status.isError }
    case "done": return downloads.historyTasks.filter { $0.status == .done }
    default: return downloads.activeTasks
    }
  }
  private var playable: [NativeTrack] { current.compactMap(downloads.localTrack) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text("下载管理").font(.system(size: 30, weight: .bold))
        Label("共 \(current.count) 首歌曲", systemImage: "music.note").font(.system(size: 13))
          .foregroundStyle(.secondary)
        Spacer()
      }
      HStack(spacing: 12) {
        Picker("下载状态", selection: $tab) {
          Text("待下载").tag("active")
          Text("下载出错").tag("error")
          Text("已完成").tag("done")
        }.pickerStyle(.segmented).frame(maxWidth: 360).accessibilityIdentifier("native.downloads.tabs")
        Spacer()
        if tab == "done" {
          Button {
            if let first = playable.first { player.play(first, in: playable, context: "下载管理") }
          } label: {
            Label("播放全部", systemImage: "play.fill")
          }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(playable.isEmpty)
        }
        Button {
          confirmClear = true
        } label: {
          Label("清空已完成", systemImage: "trash")
        }.buttonStyle(.bordered).buttonBorderShape(.capsule)
          .disabled(downloads.historyTasks.isEmpty)
      }
      if current.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "arrow.down.circle").font(.system(size: 46)).foregroundStyle(.tertiary)
          Text(tab == "done" ? "还没有下载完成的歌曲" : "暂无下载任务").font(.callout)
            .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(current.enumerated()), id: \.element.id) { index, task in
              row(task).padding(.horizontal, 8)
                .background(
                  index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear,
                  in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
      }
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

  private func row(_ task: NativeDownloadTask) -> some View {
    HStack(spacing: 12) {
      Button {
        if let local = downloads.localTrack(task) {
          player.play(local, in: playable, context: "下载管理")
        }
      } label: {
        HStack(spacing: 12) {
          NativeArtwork(cover: task.track.cover).frame(width: 44, height: 44)
          VStack(alignment: .leading, spacing: 5) {
            Text(task.track.title).font(.system(size: 14)).lineLimit(1)
            Text(task.track.artist).font(.system(size: 12)).foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          status(task).frame(width: 190, alignment: .trailing)
        }.padding(.vertical, 8).contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(downloads.localTrack(task) == nil)
        .accessibilityIdentifier("native.download." + task.track.id)
      Text(task.quality == "hi-res" ? "Hi-Res" : task.quality.uppercased())
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .overlay(Capsule().stroke(.secondary.opacity(0.4)))
      actions(task)
    }
  }

  @ViewBuilder private func status(_ task: NativeDownloadTask) -> some View {
    switch task.status {
    case .downloading:
      VStack(alignment: .trailing, spacing: 4) {
        if task.total > 0 {
          ProgressView(value: Double(task.received), total: Double(task.total))
        } else {
          ProgressView(value: 0).opacity(0.4)
        }
        Text(size(task.received) + (task.total > 0 ? " / " + size(task.total) : ""))
          .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
      }
    case .done:
      VStack(alignment: .trailing, spacing: 3) {
        Text(task.total > 0 ? size(task.total) : "已完成").font(.system(size: 12).monospacedDigit())
          .foregroundStyle(.secondary)
        if task.tagWarning == true {
          Text("标签写入失败，文件已保存").font(.system(size: 11)).foregroundStyle(.orange)
        } else if downloads.localTrack(task) == nil {
          Text("曲库中的文件已删除").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    default:
      VStack(alignment: .trailing, spacing: 3) {
        Text(task.status.label).font(.system(size: 12))
          .foregroundStyle(task.status == .failed ? .red : .secondary)
        if let error = task.error {
          Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
  }

  @ViewBuilder private func actions(_ task: NativeDownloadTask) -> some View {
    if task.status.isActive {
      Button {
        downloads.cancel(task.id)
      } label: {
        Image(systemName: "xmark.circle").frame(width: 36, height: 44)
      }.buttonStyle(.plain).accessibilityLabel("取消")
    } else {
      Menu {
        if task.status.isError { Button("重试") { downloads.retry(task.id) } }
        #if os(iOS)
          if let path = task.exportPath {
            Button("在「文件」中查看") { openInFiles(path) }
          }
        #endif
        Button("移除") { downloads.remove(task.id) }
        if task.status == .done {
          Button("删除文件", role: .destructive) { deleting = task }
        }
      } label: {
        Image(systemName: "ellipsis").frame(width: 36, height: 44)
      }
    }
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
            .foregroundStyle(.secondary)
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
      Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
        .frame(width: 14, height: 14).background(Color.primary.opacity(0.12), in: Circle())
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
