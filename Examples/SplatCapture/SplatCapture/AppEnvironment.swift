import Foundation

// MARK: - Where the app talks to
//
//   Release   splat-3d.com            api.splat-3d.com
//   Debug     the same, unless launched with `-SplatEnvironment staging`:
//             splat-staging.zzulanas.workers.dev
//             splat-api-staging.zzulanas.workers.dev
//
// Debug saves the choice, so a relaunch from the Home Screen keeps it;
// `-SplatEnvironment prod` switches back. Release has no staging at all.
// Every link to the website in the app derives from `webURL`.

enum AppEnvironment {

    /// The website: sign-in, billing, account deletion and the privacy policy.
    static let webURL = environment.web

    /// The API the app signs in to and creates scenes on.
    static let apiURL = environment.api

    static let billingURL = webURL.appending(path: "dashboard/settings/billing")
    static let deleteAccountURL = webURL.appending(path: "dashboard/settings/account")
    static let privacyURL = webURL.appending(path: "privacy")

    private struct Hosts {
        let web: URL
        let api: URL
    }

    private static let production = Hosts(
        web: URL(string: "https://splat-3d.com")!,
        api: URL(string: "https://api.splat-3d.com")!
    )

    private static let environment: Hosts = {
        #if DEBUG
        let launchKey = "SplatEnvironment"
        let savedKey = "SplatEnvironmentSaved"
        let staging = "staging"
        let defaults = UserDefaults.standard

        // A launch argument lands in the defaults' argument domain; only the
        // saved copy outlives the launch.
        if let given = defaults.string(forKey: launchKey) {
            defaults.set(given, forKey: savedKey)
        }
        guard defaults.string(forKey: savedKey) == staging else {
            return production
        }
        return Hosts(
            web: URL(string: "https://splat-staging.zzulanas.workers.dev")!,
            api: URL(string: "https://splat-api-staging.zzulanas.workers.dev")!
        )
        #else
        return production
        #endif
    }()
}
