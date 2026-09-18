import XCTest
@testable import SPlayerNativeUI

@MainActor
final class NativeRootViewTests: XCTestCase {
    func testEmptyPlayerDoesNotPretendToPlay() {
        let store = NativePlayerStore()
        store.togglePlayback()
        XCTAssertNil(store.current)
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.progress, 0)
    }

    func testMissingFileDoesNotChangeCurrentTrack() {
        let store = NativePlayerStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let track = NativeTrack(id: UUID(), fileName: "missing.wav", title: "Missing", artist: "Test", durationMs: 1000)
        store.play(track)
        XCTAssertNil(store.current)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isPlaying)
    }

    func testLyricsUseMillisecondsAndMultipleTimestamps() {
        let lines = NativeLyricLine.parse("[00:02.50][01:01.001]第二句\n[00:00.1]第一句\n[ar:歌手]")
        XCTAssertEqual(lines.map(\.text), ["第一句", "第二句", "第二句"])
        XCTAssertEqual(lines.map(\.timeMs), [100, 2500, 61001])
    }

    func testLibraryImportPersistsAndPreservesOriginal() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("test.wav")
        var data = Data()
        func word(_ value: UInt32, bytes: Int) {
            for offset in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        data.append(Data("RIFF".utf8)); word(1636, bytes: 4)
        data.append(Data("WAVEfmt ".utf8)); word(16, bytes: 4)
        word(1, bytes: 2); word(1, bytes: 2); word(8000, bytes: 4)
        word(16000, bytes: 4); word(2, bytes: 2); word(16, bytes: 2)
        data.append(Data("data".utf8)); word(1600, bytes: 4)
        data.append(Data(repeating: 0, count: 1600))
        try data.write(to: source)
        let root = temporary.appendingPathComponent("library")
        let library = NativeLibrary(root: root)
        let track = try await library.importFile(source)
        let loaded = try await NativeLibrary(root: root).load()
        XCTAssertEqual(loaded, [track])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try await library.remove(track)
        let empty = try await library.load()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
