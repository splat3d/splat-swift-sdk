#if DEBUG
import SwiftUI
import Splat3D

// MARK: - Preview harness (Debug builds only)
//
// Shows one screen in a fixed state, so every state can be checked on the
// Simulator, which can't run ARKit, and on a phone without making a scene:
//
//   xcrun simctl launch <device> com.splat3d.SplatCapture -SplatPreviewState paused-connection
//
// Paused and failed states come from RunOutcome reading a made-up SDK error,
// so they show exactly the copy a real error would. Nothing here has an API
// client: no state reaches the API, and Release builds don't contain it.

struct PreviewHarness: View {

    /// The `-SplatPreviewState` launch argument, if any.
    static var requested: String? {
        UserDefaults.standard.string(forKey: "SplatPreviewState")
    }

    /// Every state, in screenshot order. A state ending in
    /// `-accessibility` is the same state at the largest text size,
    /// scrolled to the middle.
    static let states = [
        "home", "home-first-run", "home-no-lidar", "home-camera-off", "home-no-key", "home-deleted",
        "home-accessibility",
        "scanning", "scanning-limited",
        "saving", "uploading", "launching", "processing", "processing-unknown", "processing-offline",
        "processing-accessibility",
        "paused-connection", "paused-background", "paused-app-closed", "paused-not-created",
        "paused-credits", "paused-queue", "paused-quota", "paused-timeout",
        "failed-processing", "failed-upload-lost", "failed-cancelled", "failed-unusable",
        "complete", "complete-delete-error",
        "scenes", "scenes-empty", "scenes-error",
        "viewer-downloading", "viewer-undrawable", "viewer-no-spz",
    ]

    let state: String

    private static let accessibilitySuffix = "-accessibility"

    var body: some View {
        if state.hasSuffix(Self.accessibilitySuffix) {
            // Scrolled to the middle: at this size the top is all headline,
            // and the preset tabs and run steps are further down.
            screen(String(state.dropLast(Self.accessibilitySuffix.count)))
                .dynamicTypeSize(.accessibility5)
                .defaultScrollAnchor(.center)
        } else {
            screen(state)
        }
    }

    @ViewBuilder
    private func screen(_ state: String) -> some View {
        switch state {
        case let state where state.hasPrefix("scenes"):
            NavigationStack {
                RecentScenesView(previewing: RecentScenesModel(previewing: Self.scenesState(state)))
            }
            .tint(Palette.accent)
        case let state where state.hasPrefix("viewer"):
            NavigationStack {
                SceneViewerScreen(
                    title: Self.scene.displayTitle,
                    webURL: Self.scene.viewerURL,
                    previewing: SceneViewerModel(previewing: Self.viewerPhase(state))
                )
            }
        default:
            CaptureRoot(model: Self.model(state), connectivity: Connectivity(previewOnline: !state.hasSuffix("offline") && state != "paused-connection"))
        }
    }

    // MARK: Made-up data

    private static let sceneID = "a1b2c3d4e5f6"
    private static let hour: TimeInterval = 60 * 60
    /// Relative to now, so ages read the same on any day.
    private static let created = Date().addingTimeInterval(-3 * hour)
    private static let megabyte: Int64 = 1_000_000

    private static let scene = SplatScene(
        id: sceneID,
        title: "Desk, morning light",
        status: .complete,
        numGaussians: 1_940_000,
        viewerURL: URL(string: "https://splat-3d.com/tour/\(sceneID)"),
        createdAt: created
    )

    private static func interruption(_ phase: SplatError.Interruption.Phase, _ underlying: Error) -> SplatError {
        .interrupted(SplatError.Interruption(sceneID: sceneID, phase: phase, idempotencyKey: "process-\(sceneID)", underlying: underlying))
    }

    private static func refusal(_ status: Int, _ code: String, _ message: String) -> SplatError.APIError {
        SplatError.APIError(statusCode: status, code: code, message: message)
    }

    /// The state RunOutcome gives a made-up error.
    private static func outcome(_ error: Error, sceneID: String? = sceneID, cancelledBy canceller: RunOutcome.Canceller = .app) -> CaptureState {
        switch RunOutcome(error, sceneID: sceneID, cancelledBy: canceller) {
        case .paused(let paused):
            return .paused(paused)
        case .failed(let failed):
            return .failed(failed)
        }
    }

    private static func model(_ state: String) -> CaptureModel {
        let processing = RunProgress(step: .processing, sceneID: sceneID, status: .training, percent: 42)

        switch state {
        case "home-first-run":
            return .preview(.idle, .init(cameraAccess: .notDetermined))
        case "home-no-lidar":
            return .preview(.idle, .init(hasLiDAR: false))
        case "home-camera-off":
            return .preview(.idle, .init(cameraAccess: .denied))
        case "home-no-key":
            return .preview(.idle, .init(hasAPIKey: false))
        case "home-deleted":
            let model = CaptureModel.preview(.idle)
            model.notice = HomeNotice(title: "Scene deleted", detail: "\(scene.displayTitle) and its files are gone.", isError: false)
            return model
        case "scanning":
            return .preview(.scanning, .init(scanning: (poses: 126, frames: 1_260, elapsed: 42, tracking: TrackingStatus(text: "Tracking well", dot: .done))))
        case "scanning-limited":
            return .preview(.scanning, .init(scanning: (poses: 31, frames: 310, elapsed: 11, tracking: TrackingStatus(text: "Slow down", dot: .waiting))))
        case "saving":
            return .preview(.running(RunProgress(step: .saving)))
        case "uploading":
            return .preview(.running(RunProgress(step: .uploading, sceneID: sceneID, bytesSent: 48 * megabyte, bytesTotal: 112 * megabyte)))
        case "launching":
            return .preview(.running(RunProgress(step: .launching, sceneID: sceneID)))
        case "processing", "processing-offline":
            return .preview(.running(processing))
        case "processing-unknown":
            return .preview(.running(RunProgress(step: .processing, sceneID: sceneID, status: SceneStatus(rawValue: "refining_mesh"))))
        case "paused-connection":
            return .preview(outcome(interruption(.upload, SplatError.uploadFailed(URLError(.networkConnectionLost)))))
        case "paused-background":
            return .preview(outcome(interruption(.wait, CancellationError()), cancelledBy: .backgroundTimeExpiry))
        case "paused-app-closed":
            return .preview(.paused(PausedRun(sceneID: sceneID, phase: nil, cause: .appClosed, interruption: nil)))
        case "paused-not-created":
            return .preview(outcome(URLError(.notConnectedToInternet), sceneID: nil))
        case "paused-credits":
            let credits = refusal(402, "insufficient_credits", "Insufficient credits. Need 10 credits to process this scene.")
            return .preview(outcome(interruption(.launch, SplatError.requestFailed(credits))))
        case "paused-queue":
            let queue = refusal(429, "queue_full", "You have 1 scene processing, and your plan allows 1 at once. Try again when one finishes.")
            return .preview(outcome(interruption(.launch, SplatError.rateLimited(queue))))
        case "paused-quota":
            let quota = refusal(429, "quota_exceeded", "Monthly scene processing limit reached.")
            return .preview(outcome(interruption(.launch, SplatError.rateLimited(quota))))
        case "paused-timeout":
            return .preview(outcome(interruption(.wait, SplatError.timeout)))
        case "failed-processing":
            return .preview(outcome(SplatError.processingFailed("")))
        case "failed-upload-lost":
            let missing = refusal(400, "source_missing", "Source file not found. Please try uploading again.")
            return .preview(outcome(SplatError.requestFailed(missing)))
        case "failed-cancelled":
            return .preview(outcome(SplatError.cancelled))
        case "failed-unusable":
            let unusable = refusal(422, "source_unusable", "The uploaded file is empty.")
            return .preview(outcome(interruption(.launch, SplatError.requestFailed(unusable))))
        case "complete":
            return .preview(.complete(scene))
        case "complete-delete-error":
            let model = CaptureModel.preview(.complete(scene))
            model.deleteError = "The Internet connection appears to be offline."
            return model
        default:
            return .preview(.idle)
        }
    }

    private static func scenesState(_ state: String) -> RecentScenesModel.State {
        switch state {
        case "scenes-empty":
            return .loaded([])
        case "scenes-error":
            return .failed("The Internet connection appears to be offline.")
        default:
            let day: TimeInterval = 24 * 60 * 60
            return .loaded([
                SplatScene(id: "f0e1d2c3b4a5", title: "Kitchen counter", status: .training, processingPct: 42, createdAt: Date()),
                scene,
                SplatScene(id: "0a9b8c7d6e5f", title: "Stairwell", status: .failed, createdAt: Date().addingTimeInterval(-2 * day)),
                SplatScene(id: "5e4d3c2b1a0f", title: "Plant", status: .complete, numGaussians: 820_000, createdAt: Date().addingTimeInterval(-6 * day)),
                SplatScene(id: "9f8e7d6c5b4a", title: nil, status: .uploading, createdAt: Date().addingTimeInterval(-9 * day)),
                SplatScene(id: "3c2b1a0f9e8d", title: "Bike", status: .cancelled, createdAt: Date().addingTimeInterval(-12 * day)),
            ])
        }
    }

    private static func viewerPhase(_ state: String) -> SceneViewerModel.Phase {
        switch state {
        case "viewer-downloading":
            return .downloading(received: 12 * megabyte, expected: 41 * megabyte)
        case "viewer-no-spz":
            return .failed(ViewerFailure(SplatError.notFound(refusal(404, "not_found", "No SPZ file available for this scene."))))
        default:
            return .undrawable(bytes: 41 * megabyte)
        }
    }
}

#endif
