import AVFoundation
import JavaScriptCore

struct NativeRecognitionCandidate: Identifiable, Equatable {
  let songId: String
  let title: String
  let artists: [String]
  let album: String?
  let cover: String?
  var id: String { songId }
}

enum NativeRecognitionPhase: Equatable {
  case idle, capturing, fingerprinting, matching, done
}

/// 与 main 的麦克风识曲一致：采集 8 秒 8 kHz 单声道，AFP 指纹后匹配 NCM 曲库
@MainActor
final class NativeRecognitionSession: ObservableObject {
  @Published private(set) var phase = NativeRecognitionPhase.idle
  @Published private(set) var level = 0.0
  @Published private(set) var candidates: [NativeRecognitionCandidate] = []
  @Published private(set) var playingID: String?
  @Published var message: String?
  private let player: NativePlayerStore
  private var task: Task<Void, Never>?
  private var capture: NativeMicrophoneCapture?
  private var resumePlayback = false
  private static let duration = 8.0

  init(player: NativePlayerStore) { self.player = player }

  var busy: Bool { [.capturing, .fingerprinting, .matching].contains(phase) }

  /// 开始一次识别，旧会话先完整释放
  func start() {
    cancel()
    message = nil
    task = Task { await run() }
  }

  /// 取消识别并释放麦克风，恢复识别前的播放状态
  func cancel() {
    task?.cancel()
    task = nil
    finishCapture()
    restorePlayback()
    phase = .idle
    level = 0
  }

  /// 回到初始界面，保留本次会话外的状态
  func reset() {
    cancel()
    candidates = []
    message = nil
  }

  /// 按歌曲 ID 获取完整曲目后交给播放器
  func play(_ candidate: NativeRecognitionCandidate) async {
    guard playingID == nil else { return }
    playingID = candidate.songId
    defer { playingID = nil }
    do {
      let raw = try await player.service.call(["action": "detail", "id": candidate.songId])
      guard let value = (raw as? [[String: Any]])?.first, let track = NativeTrack.online(value)
      else { throw SiriFailure("未找到这首歌曲") }
      player.play(track)
    } catch is CancellationError {} catch { message = error.localizedDescription }
  }

  private func run() async {
    do {
      guard await NativeMicrophoneCapture.requestPermission() else {
        throw SiriFailure("缺少麦克风权限，请在系统设置中授权")
      }
      try Task.checkCancellation()
      if player.isPlaying {
        player.togglePlayback()
        resumePlayback = true
      }
      phase = .capturing
      capture = try NativeMicrophoneCapture { [weak self] value in
        Task { @MainActor in if self?.phase == .capturing { self?.level = value } }
      }
      try await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
      let pcm = capture?.stop() ?? []
      finishCapture()
      level = 0
      let energy = pcm.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, pcm.count))
      guard !pcm.isEmpty, energy >= 0.000001 else { throw SiriFailure("没有采集到声音，请检查音频输出") }
      phase = .fingerprinting
      let fingerprint = try await NativeFingerprint.compute(pcm)
      try Task.checkCancellation()
      phase = .matching
      let raw: Any
      do {
        raw = try await player.service.call([
          "action": "recognize", "fingerprint": fingerprint, "duration": Double(pcm.count) / 8000,
        ])
      } catch is CancellationError { throw CancellationError() } catch {
        throw SiriFailure("匹配服务不可用，请稍后重试")
      }
      try Task.checkCancellation()
      candidates = (raw as? [[String: Any]] ?? []).compactMap { item in
        guard let id = item["songId"] as? String, let title = item["title"] as? String else {
          return nil
        }
        return NativeRecognitionCandidate(
          songId: id, title: title, artists: item["artists"] as? [String] ?? [],
          album: item["album"] as? String, cover: item["cover"] as? String)
      }
      phase = candidates.isEmpty ? .idle : .done
      if candidates.isEmpty { message = "没有识别到歌曲，请靠近声源重试" }
    } catch is CancellationError {
      return
    } catch {
      finishCapture()
      phase = .idle
      level = 0
      message = error.localizedDescription
    }
    restorePlayback()
  }

  /// 停止采集并把音频会话交还给播放器
  private func finishCapture() {
    guard let capture else { return }
    _ = capture.stop()
    self.capture = nil
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .default, policy: .longFormAudio)
    #endif
  }

  private func restorePlayback() {
    guard resumePlayback else { return }
    resumePlayback = false
    if !player.isPlaying { player.togglePlayback() }
  }
}

/// 麦克风输入重采样为 8 kHz 单声道 Float32，样本上限与 main 一致为 30 秒
final class NativeMicrophoneCapture {
  private let engine: AVAudioEngine
  private let lock = NSLock()
  private var samples: [Float] = []
  private var stopped = false
  private static let limit = 8000 * 30

  /// 申请麦克风权限；拒绝后不会开始采集
  static func requestPermission() async -> Bool {
    #if os(iOS)
      if #available(iOS 17.0, *) { return await AVAudioApplication.requestRecordPermission() }
      return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission {
          continuation.resume(returning: $0)
        }
      }
    #else
      return await AVCaptureDevice.requestAccess(for: .audio)
    #endif
  }

  /// 启动采集；音量以每 0.1 秒 RMS 回调
  init(onLevel: @escaping (Double) -> Void) throws {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
      try session.setActive(true)
    #endif
    // 必须在切换到录音会话后创建，否则输入节点沿用播放会话的空输入格式
    engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: format, to: target)
    else { throw SiriFailure("未找到可用的音频设备") }
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      self?.append(buffer, converter: converter, target: target, onLevel: onLevel)
    }
    engine.prepare()
    do { try engine.start() } catch {
      input.removeTap(onBus: 0)
      throw SiriFailure("音频采集失败")
    }
  }

  /// 结束采集并取出全部样本，重复调用返回空数组
  func stop() -> [Float] {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return []
    }
    stopped = true
    let result = samples
    samples = []
    lock.unlock()
    // 移除 tap 会等待在途回调结束，必须在锁外进行
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    return result
  }

  private func append(
    _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat,
    onLevel: (Double) -> Void
  ) {
    let capacity =
      AVAudioFrameCount(
        Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else {
      return
    }
    let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    samples.append(contentsOf: chunk.prefix(max(0, Self.limit - samples.count)))
    lock.unlock()
    onLevel(sqrt(Double(chunk.reduce(0) { $0 + $1 * $1 }) / Double(chunk.count)))
  }
}

/// AFP 指纹运行时；每次识别新建 JSContext 并在结束后释放，不常驻内存
enum NativeFingerprint {
  /// 计算 8 kHz 单声道样本的 Base64 指纹
  static func compute(_ pcm: [Float]) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      guard let url = Bundle.module.url(forResource: "afp-runtime", withExtension: "js"),
        let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext()
      else { throw SiriFailure("音频指纹库不可用") }
      context.evaluateScript("var console = {log:function(){},warn:function(){}};")
      context.evaluateScript(script)
      let value = context.objectForKeyedSubscript("recognitionFingerprint")?.call(
        withArguments: [pcm])
      guard context.exception == nil, let bytes = value?.toArray() as? [NSNumber], !bytes.isEmpty
      else { throw SiriFailure("音频指纹库不可用") }
      return Data(bytes.map(\.uint8Value)).base64EncodedString()
    }.value
  }
}
