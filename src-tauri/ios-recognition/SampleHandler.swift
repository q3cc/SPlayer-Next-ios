import ReplayKit
import AVFoundation

final class SampleHandler: RPBroadcastSampleHandler {
  private let queue = DispatchQueue(label: "splayer.recognition.broadcast")
  private let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.top.imsyy.splayer-next.ios.recognition")
  private var session: String?
  private var deadline = Date.distantPast
  private var samples = [Float]()
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var timer: DispatchSourceTimer?
  private var finished = false

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    queue.async {
      guard let directory = self.directory,
            let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = request["id"] as? String,
            let expires = request["expires"] as? Double,
            Date().timeIntervalSince1970 < expires else {
        self.end("请先在 SPlayer 中开始听歌识曲")
        return
      }
      self.session = id
      self.deadline = Date().addingTimeInterval(20)
      self.samples.reserveCapacity(64000)
      self.write(["status": "capturing"])
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now() + 1, repeating: 1)
      timer.setEventHandler { [weak self] in self?.checkSession() }
      self.timer = timer
      timer.resume()
    }
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    // 不处理画面和麦克风，仅保留短时 App 音频。
    guard sampleBufferType == .audioApp else { return }
    queue.sync {
      guard !finished, session != nil else { return }
      checkSession()
      guard !finished, CMSampleBufferDataIsReady(sampleBuffer),
            let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
      let format = AVAudioFormat(cmAudioFormatDescription: description)
      let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
      guard frames > 0, frames <= 192000,
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false) else { return }
      input.frameLength = frames
      let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
      guard status == noErr else { fail("无法读取系统音频"); return }
      if inputFormat != format {
        converter = AVAudioConverter(from: format, to: outputFormat)
        inputFormat = format
      }
      guard let converter = converter,
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 8000 / format.sampleRate)) + 32) else {
        fail("无法转换系统音频"); return
      }
      var supplied = false
      var error: NSError?
      let result = converter.convert(to: output, error: &error) { _, state in
        if supplied { state.pointee = .noDataNow; return nil }
        supplied = true
        state.pointee = .haveData
        return input
      }
      guard result != .error, error == nil, let channel = output.floatChannelData?[0] else {
        fail("无法转换系统音频"); return
      }
      let count = min(Int(output.frameLength), 64000 - samples.count)
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count).map { $0.isFinite ? $0 : 0 })
      if samples.count == 64000 {
        write(["status": "done", "pcm": samples])
        end("声音采集完成，请返回 SPlayer 查看识别结果")
      }
    }
  }

  override func broadcastPaused() {
    queue.async { self.fail("屏幕广播已暂停，请重新识别") }
  }

  override func broadcastFinished() {
    queue.async {
      if !self.finished { self.write(["status": "error", "message": "屏幕广播已停止"]) }
      self.finished = true
      self.timer?.cancel()
      self.timer = nil
      self.samples.removeAll()
    }
  }

  private func checkSession() {
    guard !finished, let directory = directory else { return }
    let data = try? Data(contentsOf: directory.appendingPathComponent("request.json"))
    let request = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    if request?["id"] as? String != session { end("识别已取消"); return }
    if Date() >= deadline { fail("未采集到足够的声音，请播放音乐后重试") }
  }

  private func write(_ value: [String: Any]) {
    guard let directory = directory, let session = session,
          let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    try? data.write(to: directory.appendingPathComponent("\(session).json"), options: .atomic)
  }

  private func fail(_ message: String) {
    guard !finished else { return }
    write(["status": "error", "message": message])
    end(message)
  }

  private func end(_ message: String) {
    guard !finished else { return }
    finished = true
    timer?.cancel()
    timer = nil
    samples.removeAll()
    converter = nil
    // ReplayKit 扩展只能通过此接口主动结束广播；不继续后台监听。
    finishBroadcastWithError(NSError(domain: "SPlayerRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
  }
}
