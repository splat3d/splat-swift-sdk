import SwiftUI

@main
struct SplatCaptureApp: App {

    init() {
        Hairline.applyNavigationBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let preview = PreviewHarness.requested {
                PreviewHarness(state: preview)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
