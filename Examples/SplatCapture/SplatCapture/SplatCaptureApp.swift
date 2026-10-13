import SwiftUI

@main
struct SplatCaptureApp: App {

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
