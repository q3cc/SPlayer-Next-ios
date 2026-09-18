import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct NativeRootView: View {
    @StateObject private var player: NativePlayerStore
    @State private var showPlayer = false
    @State private var showImporter = false
    @State private var search = ""
    @State private var pendingDelete: NativeTrack?
    @AppStorage("native.appearance") private var appearance = "system"

    public init() { _player = StateObject(wrappedValue: NativePlayerStore()) }
    public init(player: NativePlayerStore) { _player = StateObject(wrappedValue: player) }

    private var filtered: [NativeTrack] {
        player.tracks.filter { search.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) }
    }

    public var body: some View {
        TabView {
            NavigationStack {
                List {
                    if player.tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("将喜欢的音乐带在身边", systemImage: "music.note.house")
                                .font(.title2.bold())
                            Text("从文件导入音乐，无需网络即可收听。原文件会保留。")
                                .foregroundStyle(.secondary)
                            Button("导入音乐") { showImporter = true }
                                .buttonStyle(.borderedProminent)
                        }.padding(.vertical)
                    }
                    ForEach(filtered) { track in
                        Button { player.play(track, in: filtered); showPlayer = true } label: {
                            NativeTrackRow(track: track, selected: player.current?.id == track.id)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = track } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                .searchable(text: $search, prompt: "歌曲或歌手")
                .navigationTitle("曲库")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showImporter = true } label: { Label("导入音乐", systemImage: "plus") }
                            .disabled(player.importing)
                    }
                }
                .overlay { if player.importing { ProgressView("正在导入…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                .safeAreaInset(edge: .bottom) { miniPlayer }
            }.tabItem { Label("曲库", systemImage: "music.note.list") }

            NavigationStack {
                List {
                    if player.queue.isEmpty { Text("选择歌曲后，播放队列会显示在这里。") }
                    ForEach(player.queue) { track in
                        Button { player.play(track); showPlayer = true } label: {
                            NativeTrackRow(track: track, selected: player.current?.id == track.id)
                        }.buttonStyle(.plain)
                    }
                    .onMove(perform: player.moveQueue)
                    .onDelete(perform: player.removeQueue)
                }
                .navigationTitle("播放队列")
                #if os(iOS)
                .toolbar { EditButton() }
                #endif
                .safeAreaInset(edge: .bottom) { miniPlayer }
            }.tabItem { Label("队列", systemImage: "text.line.first.and.arrowtriangle.forward") }

            NavigationStack {
                Form {
                    Section("外观") {
                        Picker("主题", selection: $appearance) {
                            Text("跟随系统").tag("system")
                            Text("浅色").tag("light")
                            Text("深色").tag("dark")
                        }
                    }
                    Section("播放") { Toggle("单曲循环", isOn: $player.repeatOne) }
                    Section("本地音乐") {
                        LabeledContent("已导入歌曲", value: String(player.tracks.count))
                        Button("导入音乐") { showImporter = true }.disabled(player.importing)
                        Text("导入的音乐保存在本机。删除曲库中的歌曲只删除应用内的副本，不影响原文件。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("关于") {
                        Text("SPlayer Native")
                        Text("本版本支持本地音乐。在线播放、账户、云盘和下载功能尚未提供；原有 SPlayer 应用可继续使用。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.navigationTitle("设置")
            }.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task { await player.loadLibrary() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await player.importFiles(urls) }
            case .failure(let error): player.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showPlayer) { NativeNowPlayingView(player: player) }
        .alert("操作失败", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("好") { player.error = nil }
        } message: { Text(player.error ?? "") }
        .confirmationDialog("删除这首歌曲？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除应用内副本", role: .destructive) {
                if let track = pendingDelete { Task { await player.remove(track) } }
                pendingDelete = nil
            }
        }
    }

    @ViewBuilder private var miniPlayer: some View {
        if player.current != nil {
            HStack(spacing: 16) {
                Button { showPlayer = true } label: {
                    HStack {
                        Image(systemName: "music.note").frame(width: 44, height: 44).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(player.title).font(.headline).lineLimit(1)
                            Text(player.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            }.padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
    }
}

struct NativeTrackRow: View {
    let track: NativeTrack
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 36, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.body).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(NativeNowPlayingView.time(track.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
