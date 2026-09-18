import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVKit
import MediaPlayer
#endif

@MainActor
struct NativeNowPlayingView: View {
    @ObservedObject var player: NativePlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var importLyrics = false
    @State private var seeking = false
    @State private var seekValue = 0.0

    static func time(_ milliseconds: Double) -> String {
        let seconds = milliseconds.isFinite ? Int(max(0, milliseconds / 1000)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var activeLine: Int? { player.lyrics.last(where: { $0.timeMs <= player.positionMs })?.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if showLyrics {
                        ScrollViewReader { proxy in
                            ScrollView {
                                if player.lyrics.isEmpty { Text("还没有歌词，可以导入 LRC 歌词文件。").foregroundStyle(.secondary).padding() }
                                LazyVStack(alignment: .leading, spacing: 20) {
                                    ForEach(player.lyrics) { line in
                                        Button { player.seek(to: line.timeMs) } label: {
                                            Text(line.text).font(.title2.bold())
                                                .foregroundStyle(line.id == activeLine ? Color.primary : .secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(.plain).id(line.id)
                                    }
                                }.padding()
                            }.frame(height: 280)
                                .onChange(of: activeLine) { id in
                                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                                }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 24).fill(.quaternary)
                            .overlay { Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary) }
                            .frame(height: 280)
                    }
                    VStack(spacing: 8) {
                        Text(player.title).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(player.artist).foregroundStyle(.secondary)
                    }
                    VStack {
                        Slider(value: Binding(get: { seeking ? seekValue : player.positionMs }, set: { seekValue = $0 }), in: 0...max(1, player.durationMs)) { editing in
                            if editing { seekValue = player.positionMs }
                            seeking = editing
                            if !editing { player.seek(to: seekValue) }
                        }.accessibilityLabel("播放进度")
                        HStack {
                            Text(Self.time(player.positionMs))
                            Spacer()
                            Text(Self.time(player.durationMs))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 40) {
                        Button(action: player.previous) { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("上一首")
                        Button(action: player.togglePlayback) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle).frame(width: 64, height: 64) }.accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                        Button(action: player.next) { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("下一首")
                    }.font(.title2).buttonStyle(.plain)
                    HStack {
                        Button { player.repeatOne.toggle() } label: { Image(systemName: player.repeatOne ? "repeat.1" : "repeat").frame(width: 44, height: 44) }
                            .accessibilityLabel(player.repeatOne ? "关闭单曲循环" : "开启单曲循环")
                        Spacer()
                        Button { showLyrics.toggle() } label: { Label("歌词", systemImage: "quote.bubble").frame(minHeight: 44) }
                        Spacer()
                        #if os(iOS)
                        NativeRoutePicker().frame(width: 44, height: 44)
                        #endif
                    }
                    #if os(iOS)
                    NativeVolumeSlider().frame(height: 44)
                    #endif
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .navigationTitle("正在播放")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("导入歌词") { importLyrics = true }.disabled(player.current == nil) }
            }
            .fileImporter(isPresented: $importLyrics, allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]) { result in
                switch result {
                case .success(let url): Task { await player.importLyrics(url) }
                case .failure(let error): player.error = error.localizedDescription
                }
            }
        }
    }
}

#if os(iOS)
private struct NativeRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
private struct NativeVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif
