import Foundation

func be(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0 ..< count).reversed().map { index in UInt8(truncatingIfNeeded: value >> (index * 8)) }
}

func metadata(_ type: UInt8, _ data: [UInt8], last: Bool = false) -> [UInt8] {
    [type | (last ? 0x80 : 0)] + be(UInt64(data.count), 3) + data
}

func fixture(points: [(UInt64, UInt64)], padding: Int = 0) -> Data {
    var streamInfo = [UInt8](repeating: 0, count: 34)
    let packed = (UInt64(44100) << 44) | (1 << 41) | (15 << 36) | UInt64(44100 * 250)
    streamInfo.replaceSubrange(10 ..< 18, with: be(packed, 8))
    let seekTable = points.flatMap { point in be(point.0, 8) + be(point.1, 8) + be(4096, 2) }
    return Data([0x66, 0x4c, 0x61, 0x43] + metadata(0, streamInfo) +
                metadata(3, seekTable) + metadata(6, [UInt8](repeating: 0, count: padding), last: true))
}

let points: [(UInt64, UInt64)] = [(0, 0), (UInt64(44100) * 60, 5000000), (UInt64(44100) * 120, 12000000)]
let data = fixture(points: points)
for chunkSize in [1, 2, 3, 17, 18, 34, 4096] {
    var table = FlacSeekTable()
    for start in stride(from: 0, to: data.count, by: chunkSize) {
        table.consume(data.subdata(in: start ..< min(start + chunkSize, data.count)))
    }
    precondition(table.complete && table.duration == 250)
    let plan = table.plan(time: 65.26, outputSampleRate: 44100, fileLength: 28000000)!
    precondition(plan.byteOffset == Int64(data.count + 5000000))
    precondition(abs(plan.time - 65.26) < 0.00003)
    precondition(abs(plan.framesToDiscard - 231966) <= 1)
    let resampled = table.plan(time: 65, outputSampleRate: 48000, fileLength: 28000000)!
    precondition(resampled.framesToDiscard == 240000)
    precondition(table.plan(time: -3, outputSampleRate: 44100, fileLength: 28000000)!.time == 0)
    precondition(table.plan(time: 999, outputSampleRate: 44100, fileLength: 28000000)!.time == 250)
    precondition(table.plan(time: .nan, outputSampleRate: 44100, fileLength: 28000000) == nil)
    precondition(table.plan(time: .infinity, outputSampleRate: 44100, fileLength: 28000000) == nil)
    precondition(table.plan(time: 65, outputSampleRate: 0, fileLength: 28000000) == nil)
    let invalidOffset = table.plan(time: 125, outputSampleRate: 44100, fileLength: 6000000)!
    precondition(invalidOffset.byteOffset == Int64(data.count + 5000000))
}

var noTable = FlacSeekTable()
let noTableData = fixture(points: [], padding: 2 * 1024 * 1024)
for start in stride(from: 0, to: noTableData.count, by: 16384) {
    noTable.consume(noTableData.subdata(in: start ..< min(start + 16384, noTableData.count)))
}
let fromStart = noTable.plan(time: 65, outputSampleRate: 44100, fileLength: 28000000)!
precondition(fromStart.byteOffset == noTableData.count)
precondition(fromStart.framesToDiscard == 65 * 44100)

var placeholder = FlacSeekTable()
let placeholderPoints: [(UInt64, UInt64)] = [(.max, .max), (UInt64(44100) * 60, 5000000), (UInt64(44100) * 30, 2000000)]
let placeholders = fixture(points: placeholderPoints)
placeholder.consume(placeholders)
precondition(placeholder.plan(time: 65, outputSampleRate: 44100, fileLength: 28000000)!.byteOffset == placeholders.count + 5000000)

var truncated = FlacSeekTable()
truncated.consume(data.prefix(20))
precondition(!truncated.complete && truncated.duration == nil)
precondition(truncated.plan(time: 65, outputSampleRate: 44100, fileLength: 28000000) == nil)
var mp3 = FlacSeekTable()
mp3.consume(Data([0x49, 0x44, 0x33, 0x04]))
precondition(mp3.complete && mp3.duration == nil)

if CommandLine.arguments.count > 1 {
    let sample = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    var actual = FlacSeekTable()
    for start in stride(from: 0, to: sample.count, by: 4096) {
        actual.consume(sample.subdata(in: start ..< min(start + 4096, sample.count)))
        if actual.complete { break }
    }
    for time in [30.0, 65.26, 100.0, 150.0, 200.0] {
        let plan = actual.plan(time: time, outputSampleRate: 44100, fileLength: sample.count)!
        print("seek", time, "offset", plan.byteOffset, "discard", plan.framesToDiscard)
        precondition(abs(plan.time - time) < 0.00003)
    }
}
print("FLAC seek regression checks passed")
