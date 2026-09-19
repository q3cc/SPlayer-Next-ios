import Foundation

/** FLAC 时间定位使用采样数；压缩字节比例不能代表歌曲时间。 */
struct FlacSeekTable {
    struct Plan {
        let byteOffset: Int64
        let time: Double
        let framesToDiscard: Int64
    }

    private struct Point {
        let sample: UInt64
        let offset: UInt64
    }

    private var signatureRead = false
    private var partial: [UInt8] = []
    private var blockType: UInt8 = 0
    private var blockRemaining = 0
    private var lastBlock = false
    private var readingHeader = true
    private var consumed: Int64 = 0
    private var points: [Point] = []
    private var sampleRate: UInt64 = 0
    private var totalSamples: UInt64 = 0
    private var audioOffset: Int64 = 0
    private(set) var complete = false

    var duration: Double? {
        guard complete, sampleRate > 0, totalSamples > 0 else { return nil }
        return Double(totalSamples) / Double(sampleRate)
    }

    /**
     * 按网络分块读取元数据，封面和其他标签直接跳过，不缓存整首音频。
     * - Parameter data: 从文件开头连续收到的数据。
     */
    mutating func consume(_ data: Data) {
        var index = data.startIndex
        while index < data.endIndex, !complete {
            if !signatureRead || readingHeader {
                let count = min(4 - partial.count, data.endIndex - index)
                partial.append(contentsOf: data[index ..< index + count])
                index += count
                consumed += Int64(count)
                guard partial.count == 4 else { continue }
                if !signatureRead {
                    guard partial == [0x66, 0x4c, 0x61, 0x43] else {
                        complete = true
                        partial.removeAll()
                        return
                    }
                    signatureRead = true
                } else {
                    blockType = partial[0] & 0x7f
                    lastBlock = partial[0] & 0x80 != 0
                    blockRemaining = Int(partial[1]) << 16 | Int(partial[2]) << 8 | Int(partial[3])
                    readingHeader = false
                }
                partial.removeAll(keepingCapacity: true)
            } else if blockRemaining > 0 {
                // 最多保留 4096 个稀疏定位点；没有定位点时仍可从首帧精确解码。
                let recordSize = blockType == 0 && sampleRate == 0 ? 34 :
                    (blockType == 3 && points.count < 4096 ? 18 : 0)
                if recordSize > 0, blockRemaining + partial.count >= recordSize {
                    let count = min(recordSize - partial.count, data.endIndex - index)
                    partial.append(contentsOf: data[index ..< index + count])
                    index += count
                    consumed += Int64(count)
                    blockRemaining -= count
                    if partial.count == recordSize {
                        if blockType == 0 {
                            let value = partial[10 ..< 18].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                            sampleRate = value >> 44
                            totalSamples = value & 0x0f_ffff_ffff
                        } else {
                            let sample = partial[0 ..< 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                            let offset = partial[8 ..< 16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                            if sample < totalSamples, offset < UInt64(Int64.max),
                               points.last.map({ sample > $0.sample && offset > $0.offset }) ?? true {
                                points.append(Point(sample: sample, offset: offset))
                            }
                        }
                        partial.removeAll(keepingCapacity: true)
                    }
                } else {
                    let count = min(blockRemaining, data.endIndex - index)
                    index += count
                    consumed += Int64(count)
                    blockRemaining -= count
                }
            }
            if signatureRead, !readingHeader, blockRemaining == 0 {
                partial.removeAll(keepingCapacity: true)
                if lastBlock {
                    audioOffset = consumed
                    complete = true
                } else {
                    readingHeader = true
                }
            }
        }
    }

    /**
     * 从目标前的定位点解码，丢弃差额 PCM 后才交给播放缓冲。
     * - Parameters:
     *   time: 目标秒数。
     *   outputSampleRate: 播放缓冲的采样率。
     *   fileLength: 原始文件字节数，用于排除无效定位点。
     * - Returns: 精确跳转计划，非 FLAC 或元数据不完整时为 nil。
     */
    func plan(time: Double, outputSampleRate: Double, fileLength: Int) -> Plan? {
        guard let duration, time.isFinite, outputSampleRate.isFinite, outputSampleRate > 0,
              audioOffset < Int64(fileLength) else { return nil }
        let target = min(totalSamples, UInt64(max(0, min(time, duration)) * Double(sampleRate)))
        let point = points.last {
            $0.sample <= target && $0.offset < UInt64(Int64(fileLength) - audioOffset)
        } ?? Point(sample: 0, offset: 0)
        return Plan(
            byteOffset: audioOffset + Int64(point.offset),
            time: Double(target) / Double(sampleRate),
            framesToDiscard: Int64((Double(target - point.sample) * outputSampleRate / Double(sampleRate)).rounded())
        )
    }
}
