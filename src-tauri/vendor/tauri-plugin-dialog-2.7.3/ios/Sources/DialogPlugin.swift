// Copyright 2019-2023 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

import MobileCoreServices
import Photos
import PhotosUI
import SwiftRs
import Tauri
import UIKit
import UniformTypeIdentifiers
import WebKit
import DirectoryAccess

enum FilePickerEvent {
  case selected([URL])
  case cancelled
  case error(String)
}

struct MessageDialogOptions: Decodable {
  var title: String?
  let message: String
  var okButtonLabel: String?
  var noButtonLabel: String?
  var cancelButtonLabel: String?
}

struct Filter: Decodable {
  var extensions: [String]?
}

struct FilePickerOptions: Decodable {
  var diagnosticId: String?
  var directory: Bool?
  var multiple: Bool?
  var filters: [Filter]?
  var defaultPath: String?
  var pickerMode: PickerMode?
  var fileAccessMode: FileAccessMode?
}

struct SaveFileDialogOptions: Decodable {
  var fileName: String?
  var defaultPath: String?
}

struct DirectoryAccessOptions: Decodable {
  let directory: String?
}

enum FileAccessMode: String, Decodable {
  case copy
  case scoped
}

enum PickerMode: String, Decodable {
  case document
  case media
  case image
  case video
}

class DialogPlugin: Plugin {

  var filePickerController: FilePickerController!
  var onFilePickerResult: ((FilePickerEvent) -> Void)? = nil
  private var filePickerActive = false
  var pickerTrace: FolderPickerTrace?

  /** 选择和目录复制共用一个请求锁，不能让后来的调用覆盖正在等待的回调。 */
  func beginFilePicker() -> Bool {
    guard !filePickerActive else { return false }
    filePickerActive = true
    return true
  }

  func finishFilePicker() {
    pickerTrace?.log("request-finished")
    filePickerActive = false
    pickerTrace = nil
  }

  override init() {
    super.init()
    filePickerController = FilePickerController(self)

  }

  @objc public func showFilePicker(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(FilePickerOptions.self)

    let trace = args.diagnosticId.map { FolderPickerTrace(id: $0) }
    trace?.log("swift-enter", "os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    DispatchQueue.main.async {
      trace?.log("main-dispatch")
      guard self.beginFilePicker() else {
        trace?.log("busy-reject")
        invoke.reject("文件选择或导入正在进行中")
        return
      }
      self.pickerTrace = trace
      self.showFilePicker(invoke, args: args)
    }
  }

  private func showFilePicker(_ invoke: Invoke, args: FilePickerOptions) {
    let trace = pickerTrace
    onFilePickerResult = { (event: FilePickerEvent) -> Void in
      switch event {
      case .selected(let urls):
        if args.directory == true && args.fileAccessMode == .scoped {
          DispatchQueue.global(qos: .userInitiated).async {
            do {
              trace?.log("bookmark-save-begin", "count=\(urls.count)")
              let directories = try urls.map { try DirectoryAccess.shared.register($0) }
              trace?.log("bookmark-save-end")
              DispatchQueue.main.async {
                self.finishFilePicker()
                trace?.log("resolve")
                invoke.resolve(["files": directories])
              }
            } catch {
              DispatchQueue.main.async {
                self.finishFilePicker()
                trace?.log("bookmark-save-error")
                invoke.reject(error.localizedDescription)
              }
            }
          }
        } else if args.directory == true && args.fileAccessMode != .scoped {
          DispatchQueue.global(qos: .userInitiated).async {
            do {
              trace?.log("import-begin", "count=\(urls.count)")
              let imported = try urls.map { try self.importDirectory($0, trace: trace) }
              trace?.log("import-end")
              DispatchQueue.main.async {
                self.finishFilePicker()
                trace?.log("resolve")
                invoke.resolve(["files": imported])
              }
            } catch {
              DispatchQueue.main.async {
                self.finishFilePicker()
                let native = error as NSError
                trace?.log("import-error", "domain=\(native.domain) code=\(native.code)")
                invoke.reject(error.localizedDescription)
              }
            }
          }
        } else {
          self.finishFilePicker()
          invoke.resolve(["files": urls])
        }
      case .cancelled:
        trace?.log("cancel-resolve")
        self.finishFilePicker()
        invoke.resolve(["files": nil])
      case .error(let error):
        trace?.log("picker-reject")
        self.finishFilePicker()
        invoke.reject(error)
      }
    }

    if #available(iOS 14, *) {
      let parsedTypes = parseFiltersOption(args.filters ?? [])

      let mimeKinds = Set(
        parsedTypes.compactMap { $0.preferredMIMEType?.components(separatedBy: "/")[0] })
      let filtersIncludeImage = mimeKinds.contains("image")
      let filtersIncludeVideo = mimeKinds.contains("video")
      let filtersIncludeNonMedia = mimeKinds.contains(where: { $0 != "image" && $0 != "video" })

      // If the picker mode is media, images, or videos, we always want to show the media picker regardless of what's in the filters.
      // Otherwise, if the filters A) do not include non-media types and B) include either image or video, we want to show the media picker.
      if args.directory != true && (args.pickerMode == .media
        || args.pickerMode == .image
        || args.pickerMode == .video
        || (!filtersIncludeNonMedia && (filtersIncludeImage || filtersIncludeVideo)))
      {
        DispatchQueue.main.async {
          var configuration = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
          configuration.selectionLimit = (args.multiple ?? false) ? 0 : 1

          // If the filters include image or video, use the appropriate filter.
          // If both are true, don't define a filter, which means we will display all media.
          if args.pickerMode == .image || (filtersIncludeImage && !filtersIncludeVideo) {
            configuration.filter = .images
          } else if args.pickerMode == .video || (filtersIncludeVideo && !filtersIncludeImage) {
            configuration.filter = .videos
          }

          let picker = PHPickerViewController(configuration: configuration)
          picker.delegate = self.filePickerController
          picker.modalPresentationStyle = .fullScreen
          self.presentViewController(picker)
        }
      } else {
        DispatchQueue.main.async {
          // The UTType.item is the catch-all, allowing for any file type to be selected.
          let picker: UIDocumentPickerViewController
          if args.directory == true {
            // 目录选择需要使用现代初始化器，系统会返回安全范围 URL。
            picker = UIDocumentPickerViewController(
              forOpeningContentTypes: [.folder],
              asCopy: false)
            trace?.log("picker-mode", "directory=folder-open-in-place")
          } else {
            let contentTypes: [UTType] = parsedTypes.isEmpty ? [UTType.item] : parsedTypes
            picker = UIDocumentPickerViewController(
              forOpeningContentTypes: contentTypes,
              asCopy: args.fileAccessMode == .scoped ? false : true)
          }

          if let defaultPath = args.defaultPath {
            picker.directoryURL = URL(string: defaultPath)
          }

          trace?.log("picker-created", "directory=\(args.directory == true) asCopy=\(!(args.directory == true || args.fileAccessMode == .scoped))")
          picker.delegate = self.filePickerController
          picker.allowsMultipleSelection = args.multiple ?? false
          picker.modalPresentationStyle = .fullScreen
          self.presentViewController(picker)
        }
      }
    } else {
      showFilePickerLegacy(args: args)
    }
  }

  @objc public func directoryAccess(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(DirectoryAccessOptions.self)
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        if let directory = args.directory {
          try DirectoryAccess.shared.remove(directory)
          invoke.resolve(["directories": []])
        } else {
          let grants = try DirectoryAccess.shared.restore()
          let data = try JSONEncoder().encode(grants)
          let value = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
          invoke.resolve(["directories": value])
        }
      } catch { invoke.reject(error.localizedDescription) }
    }
  }

  /** 兼容调用方的副本模式；授权模式不会复制目录内容。 */
  private func importDirectory(_ source: URL, trace: FolderPickerTrace?) throws -> URL {
    trace?.log("access-begin", "fileURL=\(source.isFileURL)")
    let accessed = source.startAccessingSecurityScopedResource()
    trace?.log("access-result", "granted=\(accessed)")
    defer {
      trace?.log("access-end")
      if accessed { source.stopAccessingSecurityScopedResource() }
    }
    trace?.log("directory-check-begin")
    guard try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw NSError(domain: "SPlayerDirectoryImport", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "请选择文件夹，而不是音频文件"])
    }
    trace?.log("directory-check-end")
    let manager = FileManager.default
    let root = try manager.url(for: .documentDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)
      .appendingPathComponent("Imported Music", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    trace?.log("destination-create-begin")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    trace?.log("destination-create-end")
    let destination = root.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    var coordinationError: NSError?
    var copyError: Error?
    trace?.log("coordinate-begin")
    NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges,
                                   error: &coordinationError) { readable in
      trace?.log("coordinate-accessor")
      do {
        trace?.log("copy-begin")
        try manager.copyItem(at: readable, to: destination)
        trace?.log("copy-end")
      }
      catch { copyError = error }
    }
    trace?.log("coordinate-end", "failed=\(coordinationError != nil || copyError != nil)")
    if let error = (coordinationError as Error?) ?? copyError {
      try? manager.removeItem(at: root)
      throw error
    }
    return destination
  }

  @objc public func saveFileDialog(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(SaveFileDialogOptions.self)

    // The Tauri save dialog API prompts the user to select a path where a file must be saved
    // This behavior maps to the operating system interfaces on all platforms except iOS,
    // which only exposes a mechanism to "move file `srcPath` to a location defined by the user"
    //
    // so we have to work around it by creating an empty file matching the requested `args.fileName`,
    // and using it as `srcPath` for the operation - returning the path the user selected
    // so the app dev can write to it later - matching cross platform behavior as mentioned above
    let fileManager = FileManager.default
    let srcFolder = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    let srcPath = srcFolder.appendingPathComponent(args.fileName ?? "file")
    if !fileManager.fileExists(atPath: srcPath.path) {
      // the file contents must be actually provided by the tauri dev after the path is resolved by the save API
      try "".write(to: srcPath, atomically: true, encoding: .utf8)
    }

    DispatchQueue.main.async {
      guard self.beginFilePicker() else {
        invoke.reject("文件选择或导入正在进行中")
        return
      }
      self.saveFileDialog(invoke, args: args, srcPath: srcPath)
    }
  }

  private func saveFileDialog(_ invoke: Invoke, args: SaveFileDialogOptions, srcPath: URL) {
    onFilePickerResult = { (event: FilePickerEvent) -> Void in
      self.finishFilePicker()
      switch event {
      case .selected(let urls):
        invoke.resolve(["file": urls.first])
      case .cancelled:
        invoke.resolve(["file": nil])
      case .error(let error):
        invoke.reject(error)
      }
    }

    DispatchQueue.main.async {
      let picker = UIDocumentPickerViewController(url: srcPath, in: .exportToService)
      if let defaultPath = args.defaultPath {
        picker.directoryURL = URL(string: defaultPath)
      }
      picker.delegate = self.filePickerController
      picker.presentationController?.delegate = self.filePickerController
      picker.modalPresentationStyle = .fullScreen
      self.presentViewController(picker)
    }
  }

  private func presentViewController(_ viewControllerToPresent: UIViewController) {
    let trace = pickerTrace
    trace?.log("present-request")
    guard let presenter = self.manager.viewController,
          presenter.presentedViewController == nil else {
      trace?.log("present-rejected")
      onFilePickerEvent(.error("无法打开文件选择器，请关闭当前弹窗后重试"))
      return
    }
    trace?.log("present-state", "attached=\(presenter.viewIfLoaded?.window != nil) transitioning=\(presenter.transitionCoordinator != nil)")
    presenter.present(viewControllerToPresent, animated: true) {
      trace?.log("present-completed")
    }
    if trace != nil {
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak viewControllerToPresent] in
        guard let picker = viewControllerToPresent, picker.presentingViewController != nil else { return }
        trace?.log("panel-still-present", "interactive=\(picker.viewIfLoaded?.isUserInteractionEnabled == true) dismissing=\(picker.isBeingDismissed)")
      }
    }
  }

  @available(iOS 14, *)
  private func parseFiltersOption(_ filters: [Filter]) -> [UTType] {
    var parsedTypes: [UTType] = []
    for filter in filters {
      for ext in filter.extensions ?? [] {
        // We need to support extensions as well as MIME types.
        if let utType = UTType(mimeType: ext) {
          parsedTypes.append(utType)
        } else if let utType = UTType(filenameExtension: ext) {
          parsedTypes.append(utType)
        }
      }
    }

    return parsedTypes
  }

  /// This function is only used for iOS < 14, and should be removed if/when the deployment target is raised to 14.
  private func showFilePickerLegacy(args: FilePickerOptions) {
    let parsedTypes = parseFiltersOptionLegacy(args.filters ?? [])

    var filtersIncludeImage: Bool = false
    var filtersIncludeVideo: Bool = false
    var filtersIncludeNonMedia: Bool = false

    if !parsedTypes.isEmpty {
      let mimeKinds = Set(parsedTypes.map { $0.components(separatedBy: "/")[0] })
      filtersIncludeImage = mimeKinds.contains("image")
      filtersIncludeVideo = mimeKinds.contains("video")
      filtersIncludeNonMedia = mimeKinds.contains(where: { $0 != "image" && $0 != "video" })
    }

    if !filtersIncludeNonMedia && (filtersIncludeImage || filtersIncludeVideo) {
      DispatchQueue.main.async {
        let picker = UIImagePickerController()
        picker.delegate = self.filePickerController

        if filtersIncludeImage && !filtersIncludeVideo {
          picker.sourceType = .photoLibrary
        }

        picker.modalPresentationStyle = .fullScreen
        self.presentViewController(picker)
      }
    } else {
      let documentTypes = args.directory == true ? [kUTTypeFolder as String] :
        (parsedTypes.isEmpty ? ["public.data"] : parsedTypes)
      DispatchQueue.main.async {
        let mode: UIDocumentPickerMode = args.directory == true ? .open : .import
        let picker = UIDocumentPickerViewController(documentTypes: documentTypes, in: mode)
        if let defaultPath = args.defaultPath {
          picker.directoryURL = URL(string: defaultPath)
        }

        picker.delegate = self.filePickerController
        picker.allowsMultipleSelection = args.multiple ?? false
        picker.modalPresentationStyle = .fullScreen
        self.presentViewController(picker)
      }
    }
  }

  /// This function is only used for iOS < 14, and should be removed if/when the deployment target is raised to 14.
  private func parseFiltersOptionLegacy(_ filters: [Filter]) -> [String] {
    var parsedTypes: [String] = []
    for filter in filters {
      for ext in filter.extensions ?? [] {
        guard
          let utType: String = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassMIMEType, ext as CFString, nil)?.takeRetainedValue() as String?
        else {
          continue
        }
        parsedTypes.append(utType)
      }
    }

    return parsedTypes
  }

  public func onFilePickerEvent(_ event: FilePickerEvent) {
    // 先释放回调，重复选择或关闭通知不得再次复制目录、结算同一次请求。
    pickerTrace?.log("event-dispatch", "pending=\(onFilePickerResult != nil)")
    let result = onFilePickerResult
    onFilePickerResult = nil
    result?(event)
  }

  @objc public func showMessageDialog(_ invoke: Invoke) throws {
    let manager = self.manager
    let args = try invoke.parseArgs(MessageDialogOptions.self)

    DispatchQueue.main.async { [] in
      let alert = UIAlertController(
        title: args.title, message: args.message, preferredStyle: UIAlertController.Style.alert)

      if let cancelButtonLabel = args.cancelButtonLabel {
        alert.addAction(
          UIAlertAction(
            title: cancelButtonLabel, style: UIAlertAction.Style.default,
            handler: { (_) -> Void in
              invoke.resolve(["value": cancelButtonLabel])
            }
          )
        )
      }

      if let noButtonLabel = args.noButtonLabel {
        alert.addAction(
          UIAlertAction(
            title: noButtonLabel, style: UIAlertAction.Style.default,
            handler: { (_) -> Void in
              invoke.resolve(["value": noButtonLabel])
            }
          )
        )
      }

      let okButtonLabel = args.okButtonLabel ?? "Ok"
      alert.addAction(
        UIAlertAction(
          title: okButtonLabel, style: UIAlertAction.Style.default,
          handler: { (_) -> Void in
            invoke.resolve(["value": okButtonLabel])
          }
        )
      )

      manager.viewController?.present(alert, animated: true, completion: nil)
    }
  }

}

@_cdecl("init_plugin_dialog")
func initPlugin() -> Plugin {
  return DialogPlugin()
}
