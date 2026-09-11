import AVKit
import WebKit
import XCTest

@MainActor
final class AirPlayTests: XCTestCase {
  private func host() -> (UIWindow, WKWebView) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
    let owner = UIViewController()
    window.rootViewController = owner
    window.makeKeyAndVisible()
    let webview = WKWebView(frame: owner.view.bounds)
    owner.view.addSubview(webview)
    return (window, webview)
  }

  private func request(_ id: String = "test", show: Bool = true, remove: Bool = false,
                       x: Double = 100) throws -> AirPlayRouteRequest {
    let data = try JSONSerialization.data(withJSONObject: [
      "id": id, "show": show, "remove": remove, "x": x, "y": 200,
      "width": 44, "height": 44, "viewportWidth": 1024, "viewportHeight": 768,
      "label": "隔空播放", "tint": [0.5, 0.5, 0.5, 1]
    ])
    return try JSONDecoder().decode(AirPlayRouteRequest.self, from: data)
  }

  func testDirectTouchAndStableIdentity() throws {
    let (window, webview) = host()
    defer { window.isHidden = true }
    let routes = AirPlayRouteController()
    try routes.update(request(), in: webview)
    let hostView = try XCTUnwrap(window.rootViewController?.view)
    let picker = try XCTUnwrap(hostView.subviews.compactMap { $0 as? AVRoutePickerView }.first)
    XCTAssertFalse(picker.isHidden)
    XCTAssertTrue(picker.isUserInteractionEnabled)
    XCTAssertEqual(picker.layer.opacity, 1)
    XCTAssertTrue(hostView.hitTest(picker.center, with: nil)?.isDescendant(of: picker) == true)
    try routes.update(request(x: 300), in: webview)
    XCTAssertTrue(hostView.subviews.compactMap { $0 as? AVRoutePickerView }.first === picker)
    XCTAssertEqual(picker.frame.minX, 300, accuracy: 0.01)
  }

  func testPresentationSurvivesVisibilityAndUnmountUntilDismissal() throws {
    let (window, webview) = host()
    defer { window.isHidden = true }
    let routes = AirPlayRouteController()
    var phases: [String] = []
    routes.willPresent = { phases.append("presenting") }
    routes.didDismiss = { phases.append("dismissed") }
    try routes.update(request(), in: webview)
    let hostView = try XCTUnwrap(window.rootViewController?.view)
    let picker = try XCTUnwrap(hostView.subviews.compactMap { $0 as? AVRoutePickerView }.first)
    routes.routePickerViewWillBeginPresentingRoutes(picker)
    routes.setVisible(false)
    try routes.update(request(show: false), in: webview)
    try routes.update(request(show: false, remove: true), in: webview)
    XCTAssertNotNil(picker.superview)
    XCTAssertFalse(picker.isHidden)
    routes.routePickerViewDidEndPresentingRoutes(picker)
    XCTAssertNil(picker.superview)
    XCTAssertEqual(phases, ["presenting", "dismissed"])
    routes.setVisible(true)
    XCTAssertNil(picker.superview)
  }

  func testLayoutIsDeferredWhilePresentingAndAppliedAfterDismissal() throws {
    let (window, webview) = host()
    defer { window.isHidden = true }
    let routes = AirPlayRouteController()
    try routes.update(request(), in: webview)
    let hostView = try XCTUnwrap(window.rootViewController?.view)
    let picker = try XCTUnwrap(hostView.subviews.compactMap { $0 as? AVRoutePickerView }.first)
    routes.routePickerViewWillBeginPresentingRoutes(picker)
    try routes.update(request(x: 300), in: webview)
    XCTAssertEqual(picker.frame.minX, 100, accuracy: 0.01)
    routes.routePickerViewDidEndPresentingRoutes(picker)
    XCTAssertEqual(picker.frame.minX, 300, accuracy: 0.01)
  }

  func testIndependentButtonsAndHiddenState() throws {
    let (window, webview) = host()
    defer { window.isHidden = true }
    let routes = AirPlayRouteController()
    try routes.update(request("toolbar"), in: webview)
    try routes.update(request("full-player", x: 300), in: webview)
    let hostView = try XCTUnwrap(window.rootViewController?.view)
    XCTAssertEqual(hostView.subviews.compactMap { $0 as? AVRoutePickerView }.count, 2)
    try routes.update(request("toolbar", show: false, remove: true), in: webview)
    let remaining = hostView.subviews.compactMap { $0 as? AVRoutePickerView }
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(remaining.first?.accessibilityIdentifier, "splayer-airplay-full-player")
    routes.setVisible(false)
    XCTAssertEqual(remaining.first?.isHidden, true)
    try routes.update(request("full-player", show: false), in: webview)
    routes.setVisible(true)
    XCTAssertEqual(remaining.first?.isHidden, true)
  }
}
