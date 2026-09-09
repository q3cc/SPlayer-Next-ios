import AVFoundation
import UIKit
import XCTest

final class ArtworkTests: XCTestCase {
  func testStillCoverProducesLocalSilentVideo() async throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    for size in [CGSize(width: 320, height: 320), CGSize(width: 240, height: 320)] {
      let artwork = StillArtworkAsset(image: image, size: size)
      XCTAssertEqual(artwork.preview.size, size)
      let result = await artwork.videoURL()
      let url = try XCTUnwrap(result)
      XCTAssertTrue(url.isFileURL)
      let repeated = await artwork.videoURL()
      XCTAssertEqual(repeated, url)
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration)
      XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
      let audio = try await asset.loadTracks(withMediaType: .audio)
      XCTAssertTrue(audio.isEmpty)
      let videos = try await asset.loadTracks(withMediaType: .video)
      let video = try XCTUnwrap(videos.first)
      let dimensions = try await video.load(.naturalSize)
      XCTAssertEqual(dimensions, size)
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
      reader.add(output)
      XCTAssertTrue(reader.startReading())
      var frames = 0
      while output.copyNextSampleBuffer() != nil { frames += 1 }
      XCTAssertEqual(reader.status, .completed)
      XCTAssertEqual(frames, 2)
    }
  }
}
