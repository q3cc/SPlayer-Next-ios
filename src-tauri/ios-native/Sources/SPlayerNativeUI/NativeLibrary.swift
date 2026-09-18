import AVFoundation
import Foundation

public struct NativeTrack: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileName: String
    public let title: String
    public let artist: String
    public let durationMs: Double
}

public struct NativeLyricLine: Identifiable, Equatable {
    public let id: Int
    public let timeMs: Double
    public let text: String

    public static func parse(_ text: String) -> [NativeLyricLine] {
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]"#)
        var values: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let source = raw as NSString
            let matches = pattern.matches(in: raw, range: NSRange(location: 0, length: source.length))
            guard let last = matches.last else { continue }
            let content = source.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(source.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(source.substring(with: match.range(at: 2))) ?? 0
                let fraction = match.range(at: 3).location == NSNotFound ? "" : source.substring(with: match.range(at: 3))
                values.append(((minutes * 60 + seconds + (Double("0." + fraction) ?? 0)) * 1000, content))
            }
        }
        return values.sorted { $0.0 < $1.0 }.enumerated().map {
            NativeLyricLine(id: $0.offset, timeMs: $0.element.0, text: $0.element.1)
        }
    }
}

/// 文件复制与索引持久化不占用主线程，索引仅保存沙盒内相对文件名。
public actor NativeLibrary {
    public let root: URL
    private let manager = FileManager.default

    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeMusic", isDirectory: true)
    }

    public func load() throws -> [NativeTrack] {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("library.json")
        guard manager.fileExists(atPath: index.path) else { return [] }
        let values = try JSONDecoder().decode([NativeTrack].self, from: Data(contentsOf: index))
        guard values.allSatisfy({ URL(fileURLWithPath: $0.fileName).lastPathComponent == $0.fileName && !$0.fileName.hasPrefix(".") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return values
    }

    public func importFile(_ source: URL) async throws -> NativeTrack {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = id.uuidString + "." + source.pathExtension.lowercased()
        let destination = root.appendingPathComponent(fileName)
        try manager.copyItem(at: source, to: destination)
        do {
            let asset = AVURLAsset(url: destination)
            guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadUnsupportedScheme) }
            let metadata = try await asset.load(.commonMetadata)
            var title = source.deletingPathExtension().lastPathComponent
            var artist = "未知歌手"
            for item in metadata {
                if item.commonKey == .commonKeyTitle, let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                if item.commonKey == .commonKeyArtist, let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
            }
            let seconds = try await asset.load(.duration).seconds
            let track = NativeTrack(id: id, fileName: fileName, title: title, artist: artist,
                                    durationMs: seconds.isFinite ? max(0, seconds * 1000) : 0)
            var tracks = try load()
            tracks.append(track)
            try save(tracks)
            return track
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    public func remove(_ track: NativeTrack) throws {
        let tracks = try load().filter { $0.id != track.id }
        let source = root.appendingPathComponent(track.fileName)
        let staged = root.appendingPathComponent(track.id.uuidString + ".deleted")
        let present = manager.fileExists(atPath: source.path)
        if present { try manager.moveItem(at: source, to: staged) }
        do { try save(tracks) }
        catch {
            if present { try? manager.moveItem(at: staged, to: source) }
            throw error
        }
        if present { try? manager.removeItem(at: staged) }
        try? manager.removeItem(at: root.appendingPathComponent(track.id.uuidString + ".lrc"))
    }

    public func lyrics(for track: NativeTrack) throws -> String {
        let url = root.appendingPathComponent(track.id.uuidString + ".lrc")
        return manager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
    }

    public func importLyrics(_ source: URL, for track: NativeTrack) throws -> String {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let text = try String(contentsOf: source, encoding: .utf8)
        try text.write(to: root.appendingPathComponent(track.id.uuidString + ".lrc"), atomically: true, encoding: .utf8)
        return text
    }

    private func save(_ tracks: [NativeTrack]) throws {
        try JSONEncoder().encode(tracks).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}
