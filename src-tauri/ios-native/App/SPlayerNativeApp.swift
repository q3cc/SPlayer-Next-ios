import SPlayerNativeUI
import SwiftUI

@main
struct SPlayerNativeApp: App {
  init() {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--uitest-light") {
        UserDefaults.standard.set("light", forKey: "native.appearance")
      }
      if ProcessInfo.processInfo.arguments.contains("--uitest-player-am") {
        UserDefaults.standard.set("am", forKey: "native.player.style")
      }
      if ProcessInfo.processInfo.arguments.contains("--uitest-import") {
        NativeImportFixture.prepare()
        UserDefaults.standard.set("am", forKey: "native.player.style")
        UserDefaults.standard.set("fluid", forKey: "native.player.background")
        UserDefaults.standard.set(true, forKey: "native.player.freezeOnPause")
      }
    #endif
  }
  var body: some Scene {
    WindowGroup { NativeRootView() }
  }
}
