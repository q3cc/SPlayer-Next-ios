import SwiftUI

/// 原生应用根视图，页面状态不依赖 WebView 或 JavaScript。
@MainActor
public struct NativeRootView: View {
    @StateObject private var player: NativePlayerStore
    @State private var selectedTab: Tab = .library

    public init(player: NativePlayerStore = NativePlayerStore()) {
        _player = StateObject(wrappedValue: player)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(player: player)
                .tabItem { Label("曲库", systemImage: "music.note.list") }
                .tag(Tab.library)
            QueueView(player: player)
                .tabItem { Label("队列", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tag(Tab.queue)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(.accentColor)
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView(player: player) }
    }
}

private enum Tab: Hashable { case library, queue, settings }

private struct LibraryView: View {
    @ObservedObject var player: NativePlayerStore
    var body: some View {
        NavigationStack {
            ContentUnavailableView("曲库为空", systemImage: "music.note.house", description: Text("导入本地音乐后，它们会显示在这里。"))
                .navigationTitle("曲库")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("导入", systemImage: "plus") {} } }
        }
    }
}

private struct QueueView: View {
    @ObservedObject var player: NativePlayerStore
    var body: some View {
        NavigationStack {
            ContentUnavailableView("播放队列为空", systemImage: "text.line.first.and.arrowtriangle.forward", description: Text("从曲库选择歌曲后，播放队列会显示在这里。"))
                .navigationTitle("队列")
        }
    }
}

private struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("播放") {
                    Label("音质与播放", systemImage: "waveform")
                    Label("歌词", systemImage: "quote.bubble")
                }
                Section("数据") {
                    Label("下载与离线缓存", systemImage: "arrow.down.circle")
                    Label("云盘", systemImage: "icloud")
                }
            }
            .navigationTitle("设置")
        }
    }
}

private struct MiniPlayerView: View {
    @ObservedObject var player: NativePlayerStore
    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: player.progress).progressViewStyle(.linear).tint(.accentColor)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 42, height: 42)
                    .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(player.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
        }
    }
}

#Preview { NativeRootView() }
