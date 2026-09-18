import SwiftUI
import UniformTypeIdentifiers

private enum NativeTab: Hashable { case home, search, library, liked, settings }
private enum NativePresentation: String, Identifiable {
    case music, player, queue
    var id: String { rawValue }
}

@MainActor
public struct NativeRootView: View {
    @StateObject private var player: NativePlayerStore
    @State private var tab: NativeTab = .home
    @State private var presentation: NativePresentation?
    @State private var showMacImporter = false
    @State private var search = ""
    @State private var pendingDelete: NativeTrack?
    @AppStorage("native.appearance") private var appearance = "system"
    @AppStorage("native.favoriteIDs") private var favoriteIDs = ""
    @Environment(\.scenePhase) private var scenePhase

    public init() { _player = StateObject(wrappedValue: NativePlayerStore()) }
    public init(player: NativePlayerStore) { _player = StateObject(wrappedValue: player) }

    private var favorites: Set<String> { Set(favoriteIDs.split(separator: ",").map(String.init)) }
    private var liked: [NativeTrack] { player.tracks.filter { favorites.contains($0.id.uuidString) } }
    private var filtered: [NativeTrack] {
        player.tracks.filter { search.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) }
    }

    public var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 12) {
                            NativeLogo().frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SPlayer").font(.title.bold())
                                Text("让音乐陪伴每一天").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Text("你的音乐，随时聆听").font(.title2.bold())
                            Text(player.tracks.isEmpty ? "导入本地音乐，开启今天的音乐时光。" : "已收录 \(player.tracks.count) 首歌曲，无需网络即可收听。")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(action: startImport) { Label("导入音乐", systemImage: "plus").padding(.horizontal, 8).frame(minHeight: 32) }
                                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                    .disabled(player.importing).accessibilityIdentifier("native.import.home")
                                if let first = player.tracks.first {
                                    Button { player.play(first, in: player.tracks); presentation = .player } label: { Label("播放全部", systemImage: "play.fill").frame(minHeight: 44) }
                                }
                            }
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.splayerAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                        HStack(spacing: 12) {
                            Button { tab = .library } label: { shortcut("本地音乐", count: player.tracks.count, icon: "music.note.list") }
                            Button { tab = .liked } label: { shortcut("我喜欢的音乐", count: liked.count, icon: "heart") }
                        }.buttonStyle(.plain)
                        if !player.tracks.isEmpty {
                            HStack {
                                Text("最近添加").font(.title2.bold())
                                Spacer()
                                Button("查看全部") { tab = .library }
                            }
                            LazyVStack(spacing: 12) {
                                ForEach(Array(player.tracks.suffix(8).reversed())) { track in
                                    Button { player.play(track, in: player.tracks); presentation = .player } label: {
                                        NativeTrackRow(track: track, selected: player.current?.id == track.id)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.padding(20).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                }.navigationTitle("首页")
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }.tabItem { Label("首页", systemImage: "house") }.tag(NativeTab.home)

            NavigationStack {
                songList(filtered, empty: search.isEmpty ? "搜索本地歌曲或歌手" : "没有找到匹配的歌曲")
                    .searchable(text: $search, prompt: "搜索歌曲或歌手")
                    .navigationTitle("搜索")
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(NativeTab.search)

            NavigationStack {
                songList(player.tracks, empty: "还没有本地音乐，点击右上角导入歌曲。")
                    .navigationTitle("音乐库")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: startImport) { Label("导入音乐", systemImage: "plus") }
                                .disabled(player.importing).accessibilityIdentifier("native.import.library")
                        }
                    }
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }.tabItem { Label("音乐库", systemImage: "books.vertical") }.tag(NativeTab.library)

            NavigationStack {
                songList(liked, empty: "在歌曲菜单中点亮爱心，将喜欢的音乐留在这里。")
                    .navigationTitle("我喜欢的音乐")
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }.tabItem { Label("喜欢", systemImage: "heart") }.tag(NativeTab.liked)

            NavigationStack {
                Form {
                    Section {
                        HStack(spacing: 16) {
                            NativeLogo().frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SPlayer").font(.title2.bold())
                                Text("音乐，触手可及").foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
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
                        Button("导入音乐", action: startImport).disabled(player.importing).accessibilityIdentifier("native.import.settings")
                        Text("删除歌曲只删除应用内副本，不影响原文件。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("关于") {
                        Text("原生预览版目前支持本地音乐，在线平台与云盘等功能仍在迁移中。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.navigationTitle("全局设置")
            }.tabItem { Label("设置", systemImage: "gearshape") }.tag(NativeTab.settings)
        }
        .tint(.splayerAccent)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task { await player.loadLibrary() }
        .onChange(of: scenePhase) { player.setInterfaceActive($0 == .active) }
        .overlay {
            if player.importing { ProgressView("正在导入音乐…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("native.import.progress") }
        }
        #if os(macOS)
        .fileImporter(isPresented: $showMacImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await player.importFiles(urls) }
            case .failure(let error): player.error = error.localizedDescription
            }
        }
        #endif
        .sheet(item: $presentation) { page in
            switch page {
            case .music:
                #if os(iOS)
                NativeDocumentPicker { urls in
                    presentation = nil
                    // 系统选择器会自行关闭；不能依赖 SwiftUI 的 onDismiss 才启动导入。
                    if !urls.isEmpty { Task { await player.importFiles(urls) } }
                }
                #else
                EmptyView()
                #endif
            case .player: NativeNowPlayingView(player: player)
            case .queue: queueView
            }
        }
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

    private func startImport() {
        guard !player.importing else { return }
        #if os(iOS)
        presentation = .music
        #else
        showMacImporter = true
        #endif
    }

    private func shortcut(_ title: String, count: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.splayerAccent)
            Text(title).font(.headline)
            Text("\(count) 首歌曲").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }

    private func songList(_ tracks: [NativeTrack], empty: String) -> some View {
        List {
            if tracks.isEmpty { Text(empty).foregroundStyle(.secondary).padding(.vertical, 32).listRowSeparator(.hidden) }
            ForEach(tracks) { track in
                Button { player.play(track, in: tracks); presentation = .player } label: {
                    NativeTrackRow(track: track, selected: player.current?.id == track.id)
                }.buttonStyle(.plain).listRowSeparator(.hidden)
                    .contextMenu {
                        Button {
                            var values = favorites
                            if values.contains(track.id.uuidString) { values.remove(track.id.uuidString) } else { values.insert(track.id.uuidString) }
                            favoriteIDs = values.sorted().joined(separator: ",")
                        } label: { Label(favorites.contains(track.id.uuidString) ? "取消喜欢" : "喜欢", systemImage: "heart") }
                        Button("删除", role: .destructive) { pendingDelete = track }
                    }
                    .swipeActions { Button("删除", role: .destructive) { pendingDelete = track } }
            }
        }.listStyle(.plain)
    }

    private var queueView: some View {
        NavigationStack {
            List {
                if player.queue.isEmpty { Text("播放队列为空") }
                ForEach(player.queue) { track in
                    Button { player.play(track) } label: { NativeTrackRow(track: track, selected: player.current?.id == track.id) }.buttonStyle(.plain)
                }.onMove(perform: player.moveQueue).onDelete(perform: player.removeQueue)
            }.navigationTitle("播放队列")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { presentation = nil } }
                    #if os(iOS)
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                    #endif
                }
        }
    }

    @ViewBuilder private var miniPlayer: some View {
        if player.current != nil {
            HStack(spacing: 8) {
                Button { presentation = .player } label: {
                    HStack(spacing: 12) {
                        NativeLogo().frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(player.title).font(.headline).lineLimit(1)
                            Text(player.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("native.miniplayer")
                Button(action: player.togglePlayback) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Button { presentation = .queue } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放队列")
            }.padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
    }
}

extension Color {
    static let splayerAccent = Color(red: 254 / 255, green: 121 / 255, blue: 113 / 255)
}

struct NativeLogo: View {
    var body: some View {
        Image("SPlayerLogo", bundle: .module).resizable().scaledToFit().accessibilityLabel("SPlayer 标志")
    }
}

struct NativeTrackRow: View {
    let track: NativeTrack
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            NativeLogo().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.body).foregroundStyle(selected ? Color.splayerAccent : .primary).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(NativeNowPlayingView.time(track.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}
