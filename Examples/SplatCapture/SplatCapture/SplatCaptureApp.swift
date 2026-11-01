import SwiftUI

@main
struct SplatCaptureApp: App {

    @State private var session = AccountSession()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let preview = PreviewHarness.requested {
                PreviewHarness(state: preview)
            } else {
                AppRoot(session: session)
            }
            #else
            AppRoot(session: session)
            #endif
        }
    }
}

/// Sign-in until there is a key for this device, then the app.
struct AppRoot: View {

    let session: AccountSession

    var body: some View {
        Group {
            switch session.state {
            case .signedIn(let credentials):
                // A new key (signed out, then in) rebuilds the app's state.
                ContentView(credentials: credentials, session: session)
                    .id(credentials.apiKey)
            case .signedOut, .signingIn:
                // One case, so one view identity through the browser hop.
                SignInView(session: session, notice: session.notice)
            }
        }
        .task { await session.watchStorefront() }
    }
}
