import Foundation

enum RecognitionCaptureExport {
  /// 不再次重采样或增益处理；浮点版保留送入指纹计算的 Float32 样本。
  static func wav(_ samples: [Float], floatingPoint: Bool) -> Data {
    let bytesPerSample = floatingPoint ? 4 : 2
    let byteCount = samples.count * bytesPerSample
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func integer(_ value: UInt32, bytes: Int = 4) {
      for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
    text("RIFF"); integer(UInt32(byteCount + (floatingPoint ? 48 : 36))); text("WAVE")
    text("fmt "); integer(16); integer(floatingPoint ? 3 : 1, bytes: 2)
    integer(1, bytes: 2); integer(8000); integer(UInt32(8000 * bytesPerSample))
    integer(UInt32(bytesPerSample), bytes: 2); integer(UInt32(bytesPerSample * 8), bytes: 2)
    if floatingPoint { text("fact"); integer(4); integer(UInt32(samples.count)) }
    text("data"); integer(UInt32(byteCount))
    for sample in samples {
      if floatingPoint {
        integer(sample.bitPattern)
      } else {
        let bounded = sample.isFinite ? max(-1, min(1, sample)) : 0
        let pcm = Int16((bounded * (bounded < 0 ? 32768 : 32767)).rounded())
        integer(UInt32(UInt16(bitPattern: pcm)), bytes: 2)
      }
    }
    return data
  }

  /// 固定文件名只保留最近一次成功导出，JSON 时间戳用于核对采集时间。
  static func save(_ pcm: [Double], source: [String: Any]?) throws {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("听歌识曲采样", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let samples = pcm.map { Float($0) }
    let finite = samples.filter(\.isFinite)
    let energy = finite.reduce(0.0) { $0 + Double($1) * Double($1) }
    let stats: [String: Any] = [
      "capturedAt": ISO8601DateFormatter().string(from: Date()),
      "sampleRate": 8000, "channels": 1, "sampleCount": samples.count,
      "durationSeconds": Double(samples.count) / 8000,
      "rms": sqrt(energy / Double(max(1, finite.count))),
      "peak": finite.map { abs($0) }.max() ?? 0,
      "nonFiniteSamples": samples.count - finite.count,
      "clippedSamples": finite.filter { abs($0) >= 1 }.count,
      "nearSilentSamples": finite.filter { abs($0) < 0.0001 }.count,
      "source": source ?? [:],
      "note": "原始浮点.wav 与指纹输入为同一份 Float32 样本；试听.wav 仅量化为 16 位，未改变采样率、速度或增益。每次成功采集覆盖此目录中的同名文件。",
    ]
    try wav(samples, floatingPoint: true).write(to: directory.appendingPathComponent("原始浮点.wav"), options: .atomic)
    try wav(samples, floatingPoint: false).write(to: directory.appendingPathComponent("试听.wav"), options: .atomic)
    try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("采样信息.json"), options: .atomic)
  }
}
