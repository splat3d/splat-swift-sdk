import SwiftUI
import Splat3D

// MARK: - Account
//
// A sheet from the start screen: who is signed in, what the account holds,
// and the ways out. Deleting the account happens on the website, which
// takes the request and finishes it within 30 days.

struct AccountView: View {

    let session: AccountSession
    /// A capture is running or waiting to resume: signing out would drop it.
    let runIsActive: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var isSigningOut = false

    var body: some View {
        NavigationStack {
            List {
                details
                signOut
                Section {
                    Link(destination: AppEnvironment.deleteAccountURL) {
                        Label("Delete account", systemImage: "trash")
                    }
                } footer: {
                    Text("Opens splat-3d.com. Deletion takes up to 30 days.")
                }
                Section {
                    Link("Privacy policy", destination: AppEnvironment.privacyURL)
                    if session.showsPurchaseLinks {
                        Link("Manage on splat-3d.com", destination: AppEnvironment.billingURL)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CloseButton { dismiss() }
                }
            }
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    isSigningOut = true
                    Task {
                        await session.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text("Saved scans on this phone are discarded.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.ground)
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        Section {
            if let email = session.account?.email {
                FactRow(label: "Email") {
                    Text(email)
                }
            }
            if let account = session.account {
                FactRow(label: "Plan") {
                    Text(account.plan.capitalized)
                }
                FactRow(label: "Credits") {
                    Text(account.creditBalance.formatted())
                        .typeStyle(.data)
                }
            }
            if let usage = session.usage {
                FactRow(label: "Scenes this month") {
                    Text(Self.scenes(usage))
                        .typeStyle(.data)
                }
            }
            if session.account == nil && session.usage == nil {
                Text("Account details aren't loaded yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "3 of 10", or "3" on a plan with no limit.
    private static func scenes(_ usage: Usage) -> String {
        guard let limit = usage.limits.scenesCreated else {
            return usage.scenesCreated.formatted()
        }
        return "\(usage.scenesCreated.formatted()) of \(limit.formatted())"
    }

    // MARK: Sign out

    private var signOut: some View {
        Section {
            Button("Sign out", role: .destructive) {
                confirmingSignOut = true
            }
            .disabled(runIsActive || isSigningOut)
        } footer: {
            if runIsActive {
                Text("A capture is in progress. Sign out once it is done or discarded.")
            }
        }
    }
}
