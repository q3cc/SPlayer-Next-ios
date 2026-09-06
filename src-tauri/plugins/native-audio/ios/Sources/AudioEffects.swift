import AVFoundation

struct EffectRequest: Codable {
  let volume: Float
  let speed: Float
  let pitch: Float
  let pitchSync: Bool
  let enabled: Bool
  let bands: [Float]
  let preamp: Float
}

/** 播放器与离线音频测试共用同一组系统音效节点。 */
final class AudioEffects {
  let equalizer = AVAudioUnitEQ(numberOfBands: 10)
  let timePitch = AVAudioUnitTimePitch()

  func apply(_ effects: EffectRequest) {
    let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    for (index, band) in equalizer.bands.enumerated() {
      band.filterType = .parametric
      band.frequency = frequencies[index]
      band.bandwidth = 1
      band.gain = effects.bands[index]
      band.bypass = !effects.enabled
    }
    equalizer.globalGain = effects.enabled ? effects.preamp : 0
    // 流式库的 rate 节点保留音调；关闭保调时补回速度对应的半音变化。
    timePitch.pitch = effects.pitchSync ? effects.pitch * 100 : 1200 * log2(effects.speed)
    timePitch.bypass = timePitch.pitch == 0
  }
}
