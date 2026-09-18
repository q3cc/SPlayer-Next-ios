import XCTest
@testable import SPlayerNativeUI

@MainActor
final class NativeRootViewTests: XCTestCase {
    func testSelectingTrackStartsPlayback() {
        let store = NativePlayerStore()
        store.select(title: "晴天", artist: "周杰伦")
        XCTAssertEqual(store.title, "晴天")
        XCTAssertEqual(store.artist, "周杰伦")
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.progress, 0)
    }
}
