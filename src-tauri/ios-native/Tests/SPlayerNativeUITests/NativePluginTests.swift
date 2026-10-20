import XCTest

@testable import SPlayerNativeUI

@MainActor
final class NativePluginTests: XCTestCase {
  private let script = """
    /**
     * @name 原生测试源
     * @id native-test-source
     * @version 1.0.0
     * @grant network
     */
    splayer.register({sources:{wy:{name:'Test',actions:['musicUrl'],qualities:['hq']}}});
    splayer.on('musicUrl', async () => ({url:'https://example.com/test.mp3'}));
    """

  func testImportEnableAndResolveWithSharedRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePluginStore(root: root)
    try await store.importSource(script)
    let id = try XCTUnwrap(store.records.first?.id)
    XCTAssertFalse(store.records[0].enabled)
    store.setEnabled(id, true)
    try await waitReady(store, id)
    let result =
      try await store.call(
        id, action: "musicUrl",
        params: ["source": "wy", "quality": "hq", "musicInfo": ["songmid": "123"]])
      as? [String: Any]
    XCTAssertEqual(result?["url"] as? String, "https://example.com/test.mp3")
    store.setEnabled(id, false)
    XCTAssertFalse(store.allowed(id, "network"))
  }

  func testRevokedNetworkDoesNotReachHostRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePluginStore(root: root)
    let network = script.replacingOccurrences(
      of: "({url:'https://example.com/test.mp3'})", with: "splayer.request('https://example.com')")
    try await store.importSource(network)
    let id = try XCTUnwrap(store.records.first?.id)
    store.setPermission(id, "network", false)
    store.setEnabled(id, true)
    try await waitReady(store, id)
    do {
      _ = try await store.call(id, action: "musicUrl", params: [:])
      XCTFail("权限关闭时不得联网")
    } catch { XCTAssertTrue(error.localizedDescription.contains("权限"), error.localizedDescription) }
    store.setEnabled(id, false)
  }

  func testInfiniteScriptIsInterruptedWithoutBlockingMainThread() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePluginStore(root: root)
    try await store.importSource(script + "\nwhile(true){}")
    let id = try XCTUnwrap(store.records.first?.id)
    let start = Date()
    store.setEnabled(id, true)
    for _ in 0..<60 {
      try await Task.sleep(nanoseconds: 100_000_000)
      if let state = store.states[id], state != "正在加载" { break }
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    XCTAssertNotEqual(store.states[id], "可用")
    store.setEnabled(id, false)
  }

  func testEveryRevokedHostPermissionRejectsBeforeAccessingServices() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let player = NativePlayerStore(root: root)
    let store = player.plugins
    try await store.importSource(
      script.replacingOccurrences(
        of: "@grant network", with: "@grant network, control, library, api, ui"))
    let id = try XCTUnwrap(store.records.first?.id)
    for grant in ["network", "control", "library", "api", "ui"] {
      store.setPermission(id, grant, false)
    }
    store.setEnabled(id, true)
    try await waitReady(store, id)
    for method in [
      "request", "music.searchOnline", "music.searchLibrary", "api.call", "notify", "player.play",
      "player.getQueue",
    ] {
      do {
        _ = try await store.host(id, method: method, args: [])
        XCTFail("撤权后不得执行 " + method)
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("权限"), error.localizedDescription)
      }
    }
    XCTAssertNil(player.current)
    store.setEnabled(id, false)
  }

  /// 授权后使用同一共享校验入口，状态与队列结果来自真实原生播放器
  func testGrantedControlAndLibraryUseNativeState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let player = NativePlayerStore(root: root)
    let store = player.plugins
    try await store.importSource(
      script.replacingOccurrences(of: "@grant network", with: "@grant control, library, ui"))
    let id = try XCTUnwrap(store.records.first?.id)
    store.setEnabled(id, true)
    defer { store.setEnabled(id, false) }
    try await waitReady(store, id)
    let status = try await store.host(id, method: "player.getStatus", args: []) as? [String: Any]
    XCTAssertEqual(status?["state"] as? String, "stopped")
    let queue = try await store.host(id, method: "player.getQueue", args: []) as? [String: Any]
    XCTAssertEqual(queue?["total"] as? Int, 0)
    let library =
      try await store.host(id, method: "music.searchLibrary", args: ["测试", 20]) as? [String: Any]
    XCTAssertEqual(library?["total"] as? Int, 0)
    _ = try await store.host(
      id, method: "player.setPlayMode", args: [["repeat": "one", "shuffle": "on"]])
    XCTAssertTrue(player.repeatOne)
    XCTAssertTrue(player.shuffle)
    _ = try await store.host(id, method: "notify", args: ["已完成"])
    XCTAssertTrue(store.notification?.contains("已完成") == true)
  }

  /// 独立搜索经过 QuickJS 动作分发和共享结果归一化后保留源身份
  func testIndependentSearchThroughIsolatedRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let player = NativePlayerStore(root: root)
    let store = player.plugins
    let source =
      script.replacingOccurrences(
        of: "actions:['musicUrl']", with: "actions:['musicUrl','musicSearch']")
      + "\nsplayer.on('musicSearch', async ({keyword}) => ({list:[{id:'native-search-result',name:keyword,durationMs:120000}],total:1}));"
    try await store.importSource(source)
    let id = try XCTUnwrap(store.records.first?.id)
    store.setEnabled(id, true)
    defer { store.setEnabled(id, false) }
    try await waitReady(store, id)
    let result = try await store.search(id, source: "wy", keyword: "原生搜索")
    let items = try XCTUnwrap(result["items"] as? [[String: Any]])
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?["title"] as? String, "原生搜索")
    XCTAssertEqual(items.first?["source"] as? String, "plugin")
    XCTAssertEqual((items.first?["plugin"] as? [String: Any])?["pluginId"] as? String, id)
    XCTAssertEqual(result["hasMore"] as? Bool, false)
  }

  /// 宿主销毁后弱引用计时器不得留住解释器，底层资源仍在执行队列回收
  func testRuntimeReleasesWhenOwnerDisappears() async throws {
    var machine: NativePluginVM? = NativePluginVM()
    weak var reference = machine
    machine?.start()
    machine = nil
    for _ in 0..<40 {
      if reference == nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(reference)
  }

  /// 只声明低音质的源不得被强行请求 HQ，未声明音质的旧源仍沿用默认值
  func testResolveRespectsSourceQualityDeclaration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePluginStore(root: root)
    let source = script.replacingOccurrences(of: "qualities:['hq']", with: "qualities:['lq']")
      .replacingOccurrences(
        of: "async () => ({url:'https://example.com/test.mp3'})",
        with:
          "async ({quality}) => { if(quality !== 'lq') throw new Error('unsupported quality'); return {url:'https://example.com/test.mp3'}; }"
      )
    try await store.importSource(source)
    let id = try XCTUnwrap(store.records.first?.id)
    store.setEnabled(id, true)
    defer { store.setEnabled(id, false) }
    try await waitReady(store, id)
    let track = try XCTUnwrap(
      NativeTrack.online(["id": "1", "source": "netease", "title": "测试", "duration": 1000]))
    let result = try await store.resolve(track)
    XCTAssertEqual(result, "https://example.com/test.mp3")
  }

  func testRealCustomSourceWhenExplicitlyProvided() async throws {
    guard let path = ProcessInfo.processInfo.environment["NATIVE_REAL_PLUGIN_PATH"] else {
      throw XCTSkip("实时第三方源仅在人工验收时执行")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePluginStore(root: root)
    try await store.importSource(String(contentsOfFile: path, encoding: .utf8))
    let id = try XCTUnwrap(store.records.first?.id)
    store.setEnabled(id, true)
    defer { store.setEnabled(id, false) }
    try await waitReady(store, id)
    XCTAssertNotNil(store.sources[id]?["wy"])
    let value = try await store.call(
      id, action: "musicUrl",
      params: [
        "source": "wy", "quality": "lq",
        "musicInfo": [
          "songmid": "2684510360", "name": "英雄主义", "singer": "在虚无中永存", "duration": 127,
        ],
      ])
    let text = (value as? [String: Any])?["url"] as? String ?? value as? String
    let url = try XCTUnwrap(text.flatMap(URL.init(string:)))
    XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""))
  }

  private func waitReady(_ store: NativePluginStore, _ id: String) async throws {
    for _ in 0..<100 {
      if store.states[id] == "可用" { return }
      if let state = store.states[id], state != "正在加载" { throw SiriFailure(state) }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw SiriFailure("等待就绪超时：\(store.states[id] ?? "missing")")
  }
}
