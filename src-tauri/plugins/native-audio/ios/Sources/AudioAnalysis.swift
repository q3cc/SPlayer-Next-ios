import AVFoundation
import Accelerate

/** 固定大小 FFT 缓冲；音频线程仅保留一个待消费结果。 */
final class AudioAnalysis {
  private let lock = NSLock()
  private let setup = vDSP_DFT_zop_CreateSetup(nil, 1024, .FORWARD)!
  private var left = [Float](repeating: 0, count: 1024)
  private var right = [Float](repeating: 0, count: 1024)
  private var imaginary = [Float](repeating: 0, count: 1024)
  private var realOutput = [Float](repeating: 0, count: 1024)
  private var imaginaryOutput = [Float](repeating: 0, count: 1024)
  private var window = [Float](repeating: 0, count: 1024)
  private var cursor = 0
  private var energy: Double = 0
  private var samples = 0
  private var peak: Float = 0
  private var spectrum = false
  private var normalize = false
  private var gain: Float = 1
  private var pending: (left: [Float], right: [Float], gain: Float)?

  init() { vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM)) }
  deinit { vDSP_DFT_DestroySetup(setup) }

  func configure(spectrum: Bool, normalize: Bool) {
    lock.lock(); defer { lock.unlock() }
    self.spectrum = spectrum
    self.normalize = normalize
    if !normalize { gain = 1; energy = 0; samples = 0; peak = 0 }
    if !spectrum { pending = nil }
  }

  func consume() -> (left: [Float], right: [Float], gain: Float)? {
    lock.lock(); defer { lock.unlock() }
    let result = pending
    pending = nil
    return result
  }

  func process(_ buffer: AVAudioPCMBuffer) {
    guard lock.try() else { return }
    defer { lock.unlock() }
    guard spectrum || normalize, let channels = buffer.floatChannelData else { return }
    let count = Int(buffer.frameLength)
    let stereo = buffer.format.channelCount > 1
    for index in 0..<count {
      let l = channels[0][index]
      let r = channels[stereo ? 1 : 0][index]
      left[cursor] = l; right[cursor] = r
      cursor = (cursor + 1) % 1024
      if normalize {
        energy += Double(l * l + r * r)
        peak = max(peak, abs(l), abs(r))
        samples += 2
      }
    }
    if normalize && samples >= Int(buffer.format.sampleRate * 0.4) * 2 {
      let rms = Float(sqrt(energy / Double(samples)))
      if rms > 0.0001 {
        let target = min(3, max(0.1, 0.2 / rms), 0.95 / max(peak, 0.0001))
        gain += (target - gain) * (target < gain ? 0.4 : 0.08)
      }
      energy = 0; samples = 0; peak = 0
    }
    // 主线程阻塞时不排队，不持续分配频谱数组。
    guard pending == nil else { return }
    pending = (spectrum ? transform(left) : [], spectrum ? transform(right) : [], gain)
  }

  private func transform(_ input: [Float]) -> [Float] {
    var ordered = [Float](repeating: 0, count: 1024)
    for i in 0..<1024 { ordered[i] = input[(cursor + i) % 1024] * window[i] }
    vDSP_DFT_Execute(setup, ordered, imaginary, &realOutput, &imaginaryOutput)
    return (0..<64).map { band in
      let start = max(1, Int(pow(512.0, Double(band) / 64)))
      let end = max(start + 1, Int(pow(512.0, Double(band + 1) / 64)))
      var magnitude: Float = 0
      for i in start..<min(end, 512) {
        magnitude = max(magnitude, hypot(realOutput[i], imaginaryOutput[i]) / 512)
      }
      return min(1, max(0, (20 * log10(max(magnitude, 0.000001)) + 60) / 60))
    }
  }
}
