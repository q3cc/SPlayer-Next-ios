import AVFoundation
import Accelerate

/// 与 Next 的 fft.rs 相同：2048 点 Hamming 窗，80–2000 Hz 的 128 个对数频段
final class NativeAudioSpectrum {
  private let lock = NSLock()
  private var left = [Float](repeating: 0, count: 2048)
  private var right = [Float](repeating: 0, count: 2048)
  private var cursor = 0
  private var count = 0
  private var revision = 0
  private var consumed = 0
  private var format = AudioStreamBasicDescription()
  private let window: [Float] = (0..<2048).map { 0.54 - 0.46 * cos(2 * .pi * Float($0) / 2047) }
  private let plan = vDSP_DFT_zop_CreateSetup(nil, 2048, .FORWARD)!
  private var input = [Float](repeating: 0, count: 2048)
  private var zero = [Float](repeating: 0, count: 2048)
  private var real = [Float](repeating: 0, count: 2048)
  private var imaginary = [Float](repeating: 0, count: 2048)
  deinit { vDSP_DFT_DestroySetup(plan) }

  /// 保存引擎提供的实际 PCM 格式
  func prepare(_ value: AudioStreamBasicDescription) {
    lock.lock()
    format = value
    lock.unlock()
  }
  /// 音频线程采用固定环形缓冲且不等待界面线程
  func push(
    _ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int,
    format incoming: AudioStreamBasicDescription? = nil
  ) {
    guard lock.try() else { return }
    defer { lock.unlock() }
    if let incoming { format = incoming }
    guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
      return
    }
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    guard let first = list.first, let data = first.mData else { return }
    let l = data.assumingMemoryBound(to: Float.self)
    let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let stride = planar ? 1 : Int(format.mChannelsPerFrame)
    let r = planar && list.count > 1 ? list[1].mData!.assumingMemoryBound(to: Float.self) : l
    for index in 0..<frames {
      left[cursor] = l[index * stride]
      right[cursor] = planar ? r[index] : l[index * stride + (stride > 1 ? 1 : 0)]
      cursor = (cursor + 1) % 2048
    }
    count = min(2048, count + frames)
    revision += 1
  }
  /// 只消费新的采样帧，按上游幅度平均和 dB 归一化
  func consume() -> [[Float]]? {
    lock.lock()
    guard count == 2048, revision != consumed else {
      lock.unlock()
      return nil
    }
    let channels = [left, right]
    let start = cursor
    let rate = Float(format.mSampleRate)
    consumed = revision
    lock.unlock()
    return channels.map { channel in
      for i in 0..<2048 { input[i] = channel[(start + i) % 2048] * window[i] }
      vDSP_DFT_Execute(plan, input, zero, &real, &imaginary)
      let interval = rate / 2048
      return (0..<128).map { i in
        let low = exp(log(Float(80)) + log(Float(25)) * Float(i) / 128)
        let high = exp(log(Float(80)) + log(Float(25)) * Float(i + 1) / 128)
        let a = max(Int(floor(80 / interval)), Int(floor(low / interval)))
        let b = min(1024, Int(ceil(2000 / interval)), Int(ceil(high / interval)))
        guard b > a else { return 0 }
        var sum: Float = 0
        for j in a..<b { sum += hypot(real[j], imaginary[j]) / 2048 }
        let db = 20 * log10(sum / Float(b - a) + 1e-10)
        return min(1, max(0, (db + 60) / 60))
      }
    }
  }
  /// 与 audioFeatures.ts 相同的 80–180 Hz 加权 RMS/峰值脉冲
  static func pulse(_ channels: [[Float]]) -> Double {
    let bins = (0..<128).filter { i in
      let lo = 80 * pow(25.0, Double(i) / 128)
      let hi = 80 * pow(25.0, Double(i + 1) / 128)
      return hi > 80 && lo < 180
    }
    var sum = 0.0
    var peak = 0.0
    var weights = 0.0
    for (position, i) in bins.enumerated() {
      let weight = 1 - Double(position) / Double(max(1, bins.count - 1)) * 0.35
      let value = Double(channels[0][i] + channels[1][i]) / 2
      sum += value * value * weight
      weights += weight
      peak = max(peak, value)
    }
    let energy = sqrt(sum / max(1, weights)) * 0.55 + peak * 0.45
    return min(1, max(0, pow(max(0, (energy - 0.16) / 0.84), 1.05) * 2.2))
  }
}
