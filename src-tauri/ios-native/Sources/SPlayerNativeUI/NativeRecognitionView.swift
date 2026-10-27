import SwiftUI

/// 听歌识曲弹窗，阶段文案与操作沿用 main 的 RecognitionDialog
@MainActor
struct NativeRecognitionView: View {
  @StateObject private var session: NativeRecognitionSession
  let search: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  init(player: NativePlayerStore, search: @escaping (String) -> Void) {
    _session = StateObject(wrappedValue: NativeRecognitionSession(player: player))
    self.search = search
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if session.phase == .done {
          results
        } else {
          listening
        }
        footer.padding(20)
      }
      .navigationTitle("听歌识曲")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
    }
    .presentationDetents([.medium, .large])
    .onDisappear { session.reset() }
  }

  private var listening: some View {
    VStack(spacing: 14) {
      Spacer()
      ZStack {
        Circle().fill(Color.accentColor.opacity(0.1)).overlay {
          Image(systemName: "waveform").font(.system(size: 34, weight: .medium))
        }
        .scaleEffect(session.busy ? 0.25 : 1).opacity(session.busy ? 0 : 1)
        bars.scaleEffect(session.busy ? 1 : 0.25).opacity(session.busy ? 1 : 0)
      }
      .frame(width: 80, height: 80).animation(.easeOut(duration: 0.24), value: session.busy)
      .accessibilityHidden(true)
      Text(title).font(.subheadline.weight(.medium))
        .accessibilityIdentifier("native.recognition.phase")
      Text(session.busy ? "麦克风" : "靠近声源并保持环境安静，识别效果会更好").font(.caption)
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let message = session.message, !session.busy {
        Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
          .accessibilityIdentifier("native.recognition.message")
      }
      Spacer()
    }.padding(.horizontal, 24).frame(maxWidth: .infinity)
  }

  private var title: String {
    switch session.phase {
    case .capturing: return "正在收听…"
    case .fingerprinting: return "正在生成指纹…"
    case .matching: return "正在匹配曲库…"
    case .idle, .done: return "识别正在播放的音乐"
    }
  }

  /// 与 main 相同的 14 根音量条，弱信号也保持可见起伏
  private var bars: some View {
    let boosted = min(1, pow(session.level, 0.35) * 1.6)
    return HStack(spacing: 4) {
      ForEach(0..<14, id: \.self) { index in
        let distance = abs(Double(index) - 6.5) / 7
        Capsule().fill(Color.accentColor).frame(width: 4, height: 40)
          .scaleEffect(y: max(0.14, min(1, boosted * (1 - distance * 0.55))))
          .animation(.easeOut(duration: 0.15), value: session.level)
      }
    }
  }

  private var results: some View {
    List(session.candidates) { candidate in
      HStack(spacing: 12) {
        NativeArtwork(cover: candidate.cover.map { $0 + "?param=300y300" }, radius: 6)
          .frame(width: 48, height: 48)
        VStack(alignment: .leading, spacing: 3) {
          Text(candidate.title).font(.subheadline.weight(.medium)).lineLimit(1)
          Text(candidate.artists.joined(separator: " / ")).font(.caption)
            .foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        Button {
          search(([candidate.title] + candidate.artists).joined(separator: " "))
        } label: {
          Image(systemName: "magnifyingglass").frame(width: 36, height: 36)
        }.buttonStyle(.borderless).accessibilityLabel("搜索此歌曲")
        Button {
          Task { await session.play(candidate) }
        } label: {
          Group {
            if session.playingID == candidate.songId {
              ProgressView()
            } else {
              Image(systemName: "play.fill")
            }
          }.frame(width: 36, height: 36)
        }.buttonStyle(.borderless).accessibilityLabel("播放")
      }.accessibilityIdentifier("native.recognition.candidate")
    }.listStyle(.plain)
  }

  @ViewBuilder
  private var footer: some View {
    switch session.phase {
    case .idle:
      Button(action: session.start) {
        Label("开始识别", systemImage: "waveform").frame(maxWidth: .infinity)
      }.buttonStyle(.borderedProminent).controlSize(.large)
        .accessibilityIdentifier("native.recognition.start")
    case .done:
      Button(action: session.reset) {
        Label("返回", systemImage: "arrow.left").frame(maxWidth: .infinity)
      }.buttonStyle(.bordered).controlSize(.large)
    case .capturing, .fingerprinting, .matching:
      Button(action: session.cancel) {
        Text("取消").frame(maxWidth: .infinity)
      }.buttonStyle(.bordered).controlSize(.large)
        .accessibilityIdentifier("native.recognition.cancel")
    }
  }
}
