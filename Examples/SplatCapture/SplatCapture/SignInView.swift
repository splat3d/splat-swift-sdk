import ARKit
import AuthenticationServices
import SwiftUI

// MARK: - Sign in
//
// The first screen of a fresh install. One button opens splat-3d.com in the
// system browser, where the user signs in or makes an account; the app gets a
// key for this device back (see AccountSession.swift).

struct SignInView: View {

    let session: AccountSession
    /// A reason the user is here again, such as a key that was revoked.
    let notice: String?
    var hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let markSize: CGFloat = 96

    private var isSigningIn: Bool {
        session.state == .signingIn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Mark()
                    .frame(width: Self.markSize, height: Self.markSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Splat Capture")
                        .typeStyle(.display)
                    Text("Scan a space with your iPhone and Splat3D turns it into a 3D scene you can explore and share.")
                        .font(.body)
                }

                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Palette.alarm)
                }

                if !hasLiDAR {
                    Label("Capture needs an iPhone with LiDAR (12 Pro or a later Pro model).", systemImage: "info.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.margin)
        }
        .background(Palette.ground)
        .actionBar {
            Button {
                Task { await session.signIn(using: webAuth) }
            } label: {
                if isSigningIn {
                    ProgressView()
                } else {
                    Text("Sign in or create account")
                }
            }
            .actionStyle(.primary)
            .disabled(isSigningIn)

            ActionNote("New accounts get 100 free credits.")

            Link("Privacy policy", destination: AppEnvironment.privacyURL)
                .font(.footnote)
        }
    }
}
