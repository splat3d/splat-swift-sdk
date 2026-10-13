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
    /// `-accessibility` is the same state at the largest text size (a
    /// message that scrolls starts at its middle; a list, at its top); one
    /// ending in `-bright` has a bright room behind the overlays instead of
    /// black, the hard case for glass. `viewer-info` opens the info sheet
    /// on a scene with every detail, and `viewer-info-legacy` on one from an
    /// API before 1.5.0; `viewer-info-full` is the sheet's whole list.
    static let states = [
        "home", "home-first-run", "home-no-lidar", "home-camera-off", "home-no-key", "home-deleted",
        "home-accessibility",
        "scanning", "scanning-limited", "scanning-bright",
        "saving", "uploading", "launching", "processing", "processing-unknown", "processing-offline",
        "processing-accessibility",
        "paused-connection", "paused-background", "paused-app-closed", "paused-not-created",
        "paused-credits", "paused-queue", "paused-quota", "paused-timeout",
        "failed-processing", "failed-upload-lost", "failed-cancelled", "failed-unusable",
        "complete", "complete-delete-error",
        "scenes", "scenes-empty", "scenes-error",
        "viewer-downloading", "viewer-undrawable", "viewer-no-spz", "viewer-orbit", "viewer-look",
        "viewer-orbit-accessibility", "viewer-orbit-bright",
        "viewer-info", "viewer-info-legacy", "viewer-info-full",
        "viewer-info-accessibility", "viewer-info-full-accessibility",
    ]

    let state: String

    private static let accessibilitySuffix = "-accessibility"
    private static let brightSuffix = "-bright"

    var body: some View {
        if state.hasSuffix(Self.accessibilitySuffix) {
            // A message that scrolls starts at its middle. Lists ignore the
            // anchor and start at the top.
            screen(String(state.dropLast(Self.accessibilitySuffix.count)))
                .dynamicTypeSize(.accessibility5)
                .defaultScrollAnchor(.center)
        } else if state.hasSuffix(Self.brightSuffix) {
            screen(String(state.dropLast(Self.brightSuffix.count)))
                .environment(\.previewBackdrop, .brightRoom)
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
        case "viewer-info-full":
            // The list alone, at full height, as the sheet's large detent
            // shows it: a screenshot can't drag the sheet up.
            SceneInfoSheet(scene: Self.scene, viewing: SceneViewerModel.format)
        case let state where state.hasPrefix("viewer"):
            NavigationStack {
                SceneViewerScreen(
                    scene: state == "viewer-info-legacy" ? Self.legacyScene : Self.scene,
                    previewing: Self.viewerModel(state),
                    mode: state == "viewer-look" ? .look : .orbit,
                    presenting: state.hasPrefix("viewer-info") ? .info : nil
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
    private static let minute: TimeInterval = 60
    private static let launched = created.addingTimeInterval(minute)

    /// A Standard scene with every detail API 1.5.0 sends: 4 min 36 s of
    /// training in a 9 min 46 s run.
    private static let scene = SplatScene(
        id: sceneID,
        title: "Desk, morning light",
        status: .complete,
        numGaussians: 1_940_000,
        viewerURL: URL(string: "https://splat-3d.com/tour/\(sceneID)"),
        createdAt: created,
        preset: .standard,
        psnr: 27.62,
        trainingTime: 276.4,
        processingStartedAt: launched,
        processingCompletedAt: launched.addingTimeInterval(586),
        modelSizes: SplatScene.ModelSizes(spz: 41_200_000, sog: 28_400_000, ply: 481_100_000),
        psnrHoldout: 24.31,
        ssimHoldout: 0.812,
        ssim: 0.874
    )

    /// The same scene as SDKs before the scene details decoded it, from an
    /// API before 1.5.0: no preset, times, sizes or quality metrics.
    private static let legacyScene = SplatScene(
        id: sceneID,
        title: scene.title,
        status: .complete,
        numGaussians: scene.numGaussians,
        viewerURL: scene.viewerURL,
        format: .sog,
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
                SplatScene(id: "f0e1d2c3b4a5", title: "Kitchen counter", status: .training, processingPct: 42, createdAt: Date(), preset: .fast),
                scene,
                SplatScene(id: "0a9b8c7d6e5f", title: "Stairwell", status: .failed, createdAt: Date().addingTimeInterval(-2 * day), preset: .ultra),
                SplatScene(id: "5e4d3c2b1a0f", title: "Plant", status: .complete, numGaussians: 820_000, createdAt: Date().addingTimeInterval(-6 * day), preset: .quality),
                SplatScene(id: "9f8e7d6c5b4a", title: nil, status: .uploading, createdAt: Date().addingTimeInterval(-9 * day), preset: .fast),
                // From an API before 1.5.0: no preset.
                SplatScene(id: "3c2b1a0f9e8d", title: "Bike", status: .cancelled, createdAt: Date().addingTimeInterval(-12 * day)),
            ])
        }
    }

    private static func viewerModel(_ state: String) -> SceneViewerModel {
        switch state {
        case "viewer-downloading":
            return SceneViewerModel(previewing: .downloading(received: 12 * megabyte, expected: 41 * megabyte))
        case "viewer-no-spz":
            return SceneViewerModel(previewing: .failed(ViewerFailure(SplatError.notFound(refusal(404, "not_found", "No SPZ file available for this scene.")))))
        case "viewer-orbit", "viewer-look", "viewer-info", "viewer-info-legacy":
            // The controls, over a world with no file: the Simulator can't
            // draw one anyway.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview.spz")
            return SceneViewerModel(previewing: .showing(file: file, bytes: 41 * megabyte), worldReady: true)
        default:
            return SceneViewerModel(previewing: .undrawable(bytes: 41 * megabyte))
        }
    }
}

// MARK: - Backdrop

/// What a preview shows where the camera or the scene would be.
enum PreviewBackdrop {
    /// What the Simulator shows: nothing.
    case black
    /// A white wall with a window, the light picture glass must stay
    /// legible over.
    case brightRoom
}

extension EnvironmentValues {
    @Entry var previewBackdrop = PreviewBackdrop.black
}

/// A bright room in shapes: a white wall, a window full of sky behind where
/// the buttons sit, and a pale floor.
struct BrightRoom: View {

    private static let wall = [Color(white: 0.98), Color(white: 0.9)]
    private static let sky = [Color.white, Color(red: 0.82, green: 0.91, blue: 1)]
    private static let floor = Color(red: 0.87, green: 0.84, blue: 0.8)
    private static let frame = Color(white: 0.75)
    private static let floorShare: CGFloat = 0.12
    private static let windowSize = CGSize(width: 0.7, height: 0.45)
    /// The window's centre, as a share of the height from the top.
    private static let windowCenter: CGFloat = 0.62

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .bottom) {
                LinearGradient(colors: Self.wall, startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: Self.sky, startPoint: .top, endPoint: .bottom)
                    .frame(width: size.width * Self.windowSize.width, height: size.height * Self.windowSize.height)
                    .border(Self.frame, width: 6)
                    .position(x: size.width / 2, y: size.height * Self.windowCenter)
                Self.floor
                    .frame(height: size.height * Self.floorShare)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#endif
