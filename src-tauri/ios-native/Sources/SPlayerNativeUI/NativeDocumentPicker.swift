#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 与播放器共用单一弹层入口，避免 fileImporter 与 sheet 争用呈现状态。
struct NativeDocumentPicker: UIViewControllerRepresentable {
    let complete: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = [UTType.audio] + ["mp3", "m4a", "aac", "flac", "wav", "aiff", "alac", "ogg", "opus"]
            .compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        picker.view.accessibilityIdentifier = "native.audioPicker"
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let complete: ([URL]) -> Void
        init(complete: @escaping ([URL]) -> Void) { self.complete = complete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            complete(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete([]) }
    }
}
#endif
