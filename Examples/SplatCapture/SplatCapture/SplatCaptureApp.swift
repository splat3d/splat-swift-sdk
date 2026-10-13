import SwiftUI

@main
struct SplatCaptureApp: App {

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The window's first view. It styles navigation bars here, not in the
/// App's init: by now the app is running and knows the reader's text size,
/// and no bar has been made yet.
private struct RootView: View {

    init() {
        Hairline.applyNavigationBarAppearance()
    }

    var body: some View {
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
