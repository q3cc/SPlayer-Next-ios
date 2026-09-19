// Copyright 2019-2023 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import tauri_plugin_dialog

@available(iOS 14.0, *)
private final class TestDocumentPicker: UIDocumentPickerViewController {
  var dismissCount = 0

  init() {
    super.init(forOpeningContentTypes: [.folder], asCopy: false)
  }

  required init?(coder: NSCoder) { fatalError("不支持从归档创建测试选择器") }

  override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
    dismissCount += 1
    completion?()
  }
}

@available(iOS 14.0, *)
final class DialogPluginTests: XCTestCase {
  func testSelectedDirectoryDismissesPickerBeforeImportAndIgnoresRepeatedSelection() {
    let plugin = DialogPlugin()
    let picker = TestDocumentPicker()
    let folder = URL(fileURLWithPath: "/tmp/Music", isDirectory: true)
    var selectedCount = 0
    plugin.onFilePickerResult = { event in
      guard case .selected(let urls) = event else { return XCTFail("应返回选中的目录") }
      XCTAssertEqual(picker.dismissCount, 1)
      XCTAssertEqual(urls, [folder])
      XCTAssertNil(plugin.onFilePickerResult)
      selectedCount += 1
    }

    plugin.filePickerController.documentPicker(picker, didPickDocumentsAt: [folder])
    plugin.filePickerController.documentPicker(picker, didPickDocumentsAt: [folder])
    plugin.filePickerController.documentPickerWasCancelled(picker)

    XCTAssertEqual(selectedCount, 1)
    XCTAssertEqual(picker.dismissCount, 3)
    XCTAssertFalse(picker.view.isUserInteractionEnabled)
  }

  func testCancellationDismissesPickerAndAllowsAnotherSelection() {
    let plugin = DialogPlugin()
    let picker = TestDocumentPicker()
    var cancelled = false
    plugin.onFilePickerResult = { event in
      guard case .cancelled = event else { return XCTFail("应返回取消结果") }
      cancelled = true
    }
    plugin.filePickerController.documentPickerWasCancelled(picker)
    XCTAssertTrue(cancelled)
    XCTAssertEqual(picker.dismissCount, 1)
    XCTAssertNil(plugin.onFilePickerResult)

    var selected = false
    plugin.onFilePickerResult = { event in
      guard case .selected = event else { return XCTFail("取消后应能重新选择") }
      selected = true
    }
    plugin.filePickerController.documentPicker(picker, didPickDocumentsAt: [])
    XCTAssertTrue(selected)
    XCTAssertEqual(picker.dismissCount, 2)
  }

  func testImportKeepsRequestLockedAfterPickerCallbackIsConsumed() {
    let plugin = DialogPlugin()
    XCTAssertTrue(plugin.beginFilePicker())
    plugin.onFilePickerResult = { _ in }
    plugin.onFilePickerEvent(.selected([]))
    XCTAssertNil(plugin.onFilePickerResult)
    XCTAssertFalse(plugin.beginFilePicker())
    plugin.finishFilePicker()
    XCTAssertTrue(plugin.beginFilePicker())
    plugin.finishFilePicker()
  }

  func testPickerWithoutPendingCallbackStillDismisses() {
    let plugin = DialogPlugin()
    let picker = TestDocumentPicker()
    plugin.filePickerController.documentPicker(picker, didPickDocumentsAt: [])
    XCTAssertEqual(picker.dismissCount, 1)
    XCTAssertFalse(picker.view.isUserInteractionEnabled)
  }

  func testErrorOnlyCompletesPendingRequestOnce() {
    let plugin = DialogPlugin()
    var count = 0
    plugin.onFilePickerResult = { event in
      guard case .error(let message) = event else { return XCTFail("应返回错误") }
      XCTAssertEqual(message, "无法读取文件夹")
      count += 1
    }
    plugin.onFilePickerEvent(.error("无法读取文件夹"))
    plugin.onFilePickerEvent(.cancelled)
    XCTAssertEqual(count, 1)
    XCTAssertNil(plugin.onFilePickerResult)
  }
}
