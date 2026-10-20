#if os(iOS)
  import SwiftUI
  import UniformTypeIdentifiers
  import UIKit

  /// 与播放器共用单一弹层入口，避免 fileImporter 与 sheet 争用呈现状态。
  struct NativeDocumentPicker: UIViewControllerRepresentable {
    let complete: ([URL]) -> Void

    /// 把系统文件选择结果转交给唯一导入入口
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    /// 创建支持音频类型和多选的系统文件选择器
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
      let types =
        [UTType.audio]
        + ["mp3", "m4a", "aac", "flac", "wav", "aiff", "alac", "ogg", "opus"]
        .compactMap { UTType(filenameExtension: $0) }
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
      picker.allowsMultipleSelection = true
      picker.delegate = context.coordinator
      picker.directoryURL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      picker.view.accessibilityIdentifier = "native.audioPicker"
      return picker
    }

    /// 选择器呈现期间保留系统管理的导航状态
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
      let complete: ([URL]) -> Void
      /// 保存文件选择完成回调
      init(complete: @escaping ([URL]) -> Void) { self.complete = complete }
      /// 提交系统选中的文件 URL，由导入层复制并解析
      func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
      ) {
        complete(urls)
      }
      /// 以空选择结束导入，允许用户再次打开选择器
      func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete([]) }
    }
  }
#endif
