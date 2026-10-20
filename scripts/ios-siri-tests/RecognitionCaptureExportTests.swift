import Foundation

@main
struct RecognitionCaptureExportTests {
  static func main() {
    let samples: [Float] = [0, 0.5, -0.5, 1, -1]
    let pcm = RecognitionCaptureExport.wav(samples, floatingPoint: false)
    precondition(pcm.count == 44 + samples.count * 2)
    precondition(Array(pcm[44..<54]) == [0, 0, 0, 64, 0, 192, 255, 127, 0, 128])
    let floats = RecognitionCaptureExport.wav(samples, floatingPoint: true)
    precondition(floats.count == 56 + samples.count * 4)
    precondition(floats[20] == 3 && floats[22] == 1)
    precondition(Array(floats[24..<28]) == [64, 31, 0, 0])
    for (index, sample) in samples.enumerated() {
      let offset = 56 + index * 4
      let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(floats[offset + $1]) << ($1 * 8) }
      precondition(bits == sample.bitPattern)
    }
    print("PASS: WAV 时长、8 kHz 单声道头、16 位试听及原始浮点样本一致性")
  }
}
