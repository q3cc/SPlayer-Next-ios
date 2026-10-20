import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NativePluginsView: View {
  @ObservedObject var plugins: NativePluginStore
  @State private var address = ""
  @State private var showURL = false
  @State private var showFile = false
  @State private var removing: String?
  var body: some View {
    List {
      Section {
        HStack {
          Button {
            showURL = true
          } label: {
            Label("在线导入", systemImage: "link")
          }.accessibilityIdentifier("native.plugins.importURL")
          Spacer()
          Button {
            showFile = true
          } label: {
            Label("本地导入", systemImage: "square.and.arrow.down")
          }
        }.disabled(plugins.importing)
        if plugins.importing { ProgressView("正在导入…") }
      } footer: {
        Text("导入后默认关闭。启用前请确认作者及权限，只运行你信任的脚本。")
      }
      ForEach(plugins.records) { record in
        Section {
          Toggle(
            isOn: Binding(
              get: { plugins.records.first(where: { $0.id == record.id })?.enabled ?? false },
              set: { plugins.setEnabled(record.id, $0) })
          ) {
            VStack(alignment: .leading, spacing: 5) {
              Text(record.name).font(.headline)
              Text(record.version + " · " + (plugins.states[record.id] ?? "已禁用")).font(.caption)
                .foregroundStyle(.secondary)
            }
          }.accessibilityIdentifier("native.plugin." + record.id)
          if let description = record.description {
            Text(description).font(.footnote).foregroundStyle(.secondary)
          }
          ForEach((plugins.sources[record.id] ?? [:]).keys.sorted(), id: \.self) { source in
            if (plugins.sources[record.id]?[source]?["actions"] as? [String] ?? []).contains(
              "musicSearch")
            {
              NavigationLink("搜索 · " + source) {
                NativePluginSearchView(plugins: plugins, pluginID: record.id, source: source)
              }
            }
          }
          DisclosureGroup("权限") {
            ForEach(record.grant, id: \.self) { grant in
              Toggle(
                permissionName(grant),
                isOn: Binding(
                  get: {
                    plugins.records.first(where: { $0.id == record.id })?.permissions[grant]
                      != false
                  }, set: { plugins.setPermission(record.id, grant, $0) })
              )
              .accessibilityIdentifier("native.plugin.permission." + grant)
            }
          }
          Button("移除插件", role: .destructive) { removing = record.id }
        }
      }
      if plugins.records.isEmpty { Text("尚未安装自定义源").foregroundStyle(.secondary) }
    }.navigationTitle("插件管理")
      .alert("在线导入", isPresented: $showURL) {
        TextField("HTTPS 脚本地址", text: $address)
          #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          #endif
        Button("取消", role: .cancel) {}
        Button("导入") { Task { await plugins.importURL(address) } }
      } message: {
        Text("粘贴兼容 SPlayer / LX Music 的 JavaScript 源地址")
      }
      .alert(
        "插件操作失败",
        isPresented: Binding(get: { plugins.error != nil }, set: { if !$0 { plugins.error = nil } })
      ) {
        Button("好") { plugins.error = nil }
      } message: {
        Text(plugins.error ?? "")
      }
      .confirmationDialog(
        "移除这个插件？",
        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
      ) {
        Button("移除插件", role: .destructive) {
          if let removing { plugins.remove(removing) }
          removing = nil
        }
      }
      .fileImporter(isPresented: $showFile, allowedContentTypes: [.javaScript, .plainText]) {
        result in
        if case .success(let url) = result {
          Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
              guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 9_000_000
              else { throw SiriFailure("插件文件过大") }
              try await plugins.importSource(String(contentsOf: url, encoding: .utf8))
            } catch { plugins.error = error.localizedDescription }
          }
        }
      }
  }
  /// 将插件能力标识显示为中文权限名称
  private func permissionName(_ grant: String) -> String {
    ["network": "联网", "control": "播放控制", "library": "读取曲库", "api": "平台 API", "ui": "应用内提示"][grant]
      ?? grant
  }
}

/// 独立源搜索保留来源信息，选曲交给同一个原生播放器
@MainActor
struct NativePluginSearchView: View {
  @ObservedObject var plugins: NativePluginStore
  let pluginID: String
  let source: String
  @State private var query = ""
  @State private var tracks: [NativeTrack] = []
  @State private var loading = false
  @State private var error: String?
  @State private var page = 1
  @State private var hasMore = false
  @State private var generation = 0
  var body: some View {
    VStack {
      HStack {
        TextField("搜索歌曲", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
        Button("搜索") { search() }
      }.padding()
      if let player = plugins.player {
        NativeSongCollection(
          title: "", tracks: tracks, player: player, loading: loading, error: error,
          more: hasMore ? { search(more: true) } : nil)
      }
    }.navigationTitle("自定义源 · " + source)
      .alert(
        "播放失败",
        isPresented: Binding(
          get: { plugins.player?.error != nil }, set: { if !$0 { plugins.player?.error = nil } })
      ) {
        Button("好") { plugins.player?.error = nil }
      } message: {
        Text(plugins.player?.error ?? "")
      }
  }
  /// 新搜索以代次隔离迟到响应，分页只追加已校验曲目
  private func search(more: Bool = false) {
    let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty, keyword.count <= 200 else { return }
    generation += 1
    let token = generation
    page = more ? page + 1 : 1
    if !more { tracks = [] }
    loading = true
    error = nil
    Task {
      defer { if token == generation { loading = false } }
      do {
        let result = try await plugins.search(
          pluginID, source: source, keyword: keyword, page: page)
        guard token == generation else { return }
        let seen = Set(tracks.map(\.id))
        tracks += (result["items"] as? [[String: Any]] ?? []).compactMap(NativeTrack.online).filter
        { !seen.contains($0.id) }
        hasMore = result["hasMore"] as? Bool ?? false
      } catch {
        if token == generation {
          self.error = error.localizedDescription
          if more { page -= 1 }
        }
      }
    }
  }
}

/// 插件通知只显示应用内文本，不打开网页或执行任何内容
@MainActor
struct NativePluginNotice: View {
  @ObservedObject var plugins: NativePluginStore
  var body: some View {
    if let message = plugins.notification {
      HStack {
        Text(message).font(.callout).lineLimit(4)
        Button {
          plugins.notification = nil
        } label: {
          Image(systemName: "xmark")
        }.accessibilityLabel("关闭提示")
      }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
        .task(id: message) {
          try? await Task.sleep(nanoseconds: 5_000_000_000)
          if !Task.isCancelled, plugins.notification == message { plugins.notification = nil }
        }
    }
  }
}
