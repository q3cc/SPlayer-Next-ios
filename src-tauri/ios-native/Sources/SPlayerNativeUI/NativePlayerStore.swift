import AVFoundation
import Combine
import Foundation
#if os(iOS)
import MediaPlayer
#endif

/// 播放状态来自 AVPlayer，不以按钮点击伪造播放成功。
@MainActor
public final class NativePlayerStore: ObservableObject {
    @Published public private(set) var tracks: [NativeTrack] = []
    @Published public private(set) var queue: [NativeTrack] = []
    @Published public private(set) var current: NativeTrack?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var positionMs = 0.0
    @Published public private(set) var durationMs = 0.0
    @Published public private(set) var importing = false
    @Published public private(set) var lyrics: [NativeLyricLine] = []
    @Published public var error: String?
    @Published public var repeatOne = false
    public var title: String { current?.title ?? "未在播放" }
    public var artist: String { current?.artist ?? "选择一首歌曲开始播放" }
    public var progress: Double { durationMs > 0 ? min(1, positionMs / durationMs) : 0 }
    private let library: NativeLibrary
    private let root: URL
    private let engine = AVPlayer()
    private var timeObserver: Any?
    private var stateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var resumeAfterInterruption = false
    #if os(iOS)
    private var commands: [(MPRemoteCommand, Any)] = []
    #endif

    public init(root: URL = NativeLibrary.defaultRoot()) {
        self.root = root
        library = NativeLibrary(root: root)
        stateObserver = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = self.engine.timeControlStatus == .playing
                self.publishNowPlaying()
            }
        }
        timeObserver = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.positionMs = time.seconds.isFinite ? max(0, time.seconds * 1000) : 0
                let duration = self.engine.currentItem?.duration.seconds ?? 0
                if duration.isFinite { self.durationMs = max(0, duration * 1000) }
            }
        }
        #if os(iOS)
        installRemoteCommands()
        #endif
    }

    deinit {
        if let timeObserver { engine.removeTimeObserver(timeObserver) }
        for observer in [endObserver, interruptionObserver, routeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        #if os(iOS)
        for (command, target) in commands { command.removeTarget(target) }
        #endif
    }

    public func loadLibrary() async {
        do { tracks = try await library.load() }
        catch { self.error = "无法读取曲库：" + error.localizedDescription }
    }

    public func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        var failures: [String] = []
        for url in urls {
            do { tracks.append(try await library.importFile(url)) }
            catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
        }
        if !failures.isEmpty { error = failures.prefix(5).joined(separator: "\n") }
    }

    public func remove(_ track: NativeTrack) async {
        do {
            try await library.remove(track)
            if current?.id == track.id { stop() }
            tracks.removeAll { $0.id == track.id }
            queue.removeAll { $0.id == track.id }
        } catch { self.error = "无法删除歌曲：" + error.localizedDescription }
    }

    public func play(_ track: NativeTrack, in tracks: [NativeTrack]? = nil) {
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let url = root.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            if let tracks { queue = tracks }
            if !queue.contains(where: { $0.id == track.id }) { queue.append(track) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let item = AVPlayerItem(url: url)
            itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.engine.currentItem === item, item.status == .failed else { return }
                    self.error = item.error?.localizedDescription ?? "无法播放此文件"
                    self.engine.pause()
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.repeatOne { self.seek(to: 0); self.engine.play() }
                    else { self.next() }
                }
            }
            current = track
            lyrics = []
            positionMs = 0
            durationMs = track.durationMs
            engine.replaceCurrentItem(with: item)
            engine.play()
            publishNowPlaying()
            Task {
                let raw = (try? await library.lyrics(for: track)) ?? ""
                if current?.id == track.id { lyrics = NativeLyricLine.parse(raw) }
            }
        } catch { self.error = "无法播放：" + error.localizedDescription }
    }

    public func togglePlayback() {
        guard current != nil else { return }
        if engine.timeControlStatus == .paused { engine.play() } else { engine.pause() }
    }

    public func seek(to milliseconds: Double) {
        guard milliseconds.isFinite else { return }
        let value = min(max(0, milliseconds), durationMs)
        engine.seek(to: CMTime(seconds: value / 1000, preferredTimescale: 600))
        positionMs = value
        publishNowPlaying()
    }

    public func next() {
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        if index + 1 < queue.count { play(queue[index + 1]) } else { engine.pause() }
    }

    public func previous() {
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        if positionMs > 3000 || index == 0 { seek(to: 0) } else { play(queue[index - 1]) }
    }

    public func moveQueue(from offsets: IndexSet, to destination: Int) {
        let selected = offsets.sorted().map { queue[$0] }
        for index in offsets.sorted(by: >) { queue.remove(at: index) }
        queue.insert(contentsOf: selected, at: destination - offsets.filter { $0 < destination }.count)
    }

    public func removeQueue(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { queue.remove(at: index) }
    }

    public func importLyrics(_ url: URL) async {
        guard let track = current else { return }
        do {
            let text = try await library.importLyrics(url, for: track)
            if current?.id == track.id { lyrics = NativeLyricLine.parse(text) }
        } catch { self.error = "无法导入歌词：" + error.localizedDescription }
    }

    private func stop() {
        engine.pause()
        engine.replaceCurrentItem(with: nil)
        current = nil
        lyrics = []
        positionMs = 0
        durationMs = 0
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        #if os(iOS)
        guard let current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: durationMs / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionMs / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        #endif
    }

    #if os(iOS)
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, @MainActor () -> Void)] = [
            (center.playCommand, { [weak self] in self?.engine.play() }),
            (center.pauseCommand, { [weak self] in self?.engine.pause() }),
            (center.nextTrackCommand, { [weak self] in self?.next() }),
            (center.previousTrackCommand, { [weak self] in self?.previous() })
        ]
        for (command, action) in actions {
            let target = command.addTarget { _ in Task { @MainActor in action() }; return .success }
            commands.append((command, target))
        }
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime * 1000) }
            return .success
        }
        commands.append((center.changePlaybackPositionCommand, target))
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.isPlaying
                    self.engine.pause()
                } else {
                    let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    if self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.engine.play() }
                    self.resumeAfterInterruption = false
                }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.engine.pause() }
        }
    }
    #endif
}
