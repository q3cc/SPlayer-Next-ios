import SwiftUI
import SPlayerNativeUI

@main
struct SPlayerNativeApp: App {
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-import") {
            NativeImportFixture.prepare()
        }
        #endif
    }
    var body: some Scene {
        WindowGroup { NativeRootView() }
    }
}
