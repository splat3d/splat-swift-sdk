import SwiftUI
import ARKit
import AVFoundation
import Network
import Splat3D

// MARK: - Splat3D Integration: One capture, from scan to scene
//
//   idle ── Start ──> scanning ── Stop ──> running ──────────────> complete
//                                            │  ▲                    │
//                     SplatError.interrupted │  │ Resume             └─ Delete
//                     or the app was killed  ▼  │
//                                          paused
//                                            │
//                         an error no resume gets past ──> failed
//
// running is SplatClient.createAndProcess: create, upload, launch, wait. When
// it stops before the outcome is known it throws .interrupted, and Resume
// hands that to client.resume(_:), which never pays twice. The capture and
// scene ID are on disk (CaptureStore), so after the app is killed the run
// picks up by itself on the next launch, through
// client.resume(sceneID:preset:…). A run that had failed comes back failed.
//
// Leaving the app asks iOS for background time. When it runs out the run is
// cancelled, which the SDK reports as an interruption, and it resumes by
// itself when the app is back in front.

// MARK: - State

enum CaptureState {
    case idle
    case scanning
    case running(RunProgress)
    case paused(PausedRun)
    case failed(FailedRun)
    case complete(SplatScene)
}

/// How far a run has got.
struct RunProgress: Equatable {

    enum Step: Int, Comparable {
        /// SplatScanner is finishing the video file.
        case saving
        case uploading
        /// The video is up; the launch is on its way.
        case launching
        /// The API accepted the job and reports its stages.
        case processing

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var step: Step
    var sceneID: String?
    var status: SceneStatus?
    var percent: Double?
    var bytesSent: Int64 = 0
    var bytesTotal: Int64?
}

/// A run that stopped before its outcome was known, and can resume.
struct PausedRun {

    enum Cause: Equatable {
        /// The network dropped.
        case connection
        /// iOS ended the app's background time.
        case backgrounded
        /// Found on launch: the app was killed mid-run.
        case appClosed
        case insufficientCredits(String)
        /// The plan's limit on scenes processing at once.
        case queueFull(String)
        case quotaExceeded(String)
        case keyRejected
        /// SplatClient stopped waiting; the job may still finish.
        case timedOut
        case other(String)
    }

    /// `nil` when the scene was never created: Resume uploads the capture.
    let sceneID: String?
    /// Where it stopped, when this run of the app saw it stop.
    let phase: SplatError.Interruption.Phase?
    let cause: Cause
    /// What client.resume(_:) continues; `nil` after a relaunch.
    let interruption: SplatError.Interruption?
}

/// A run that ended for good. Codable: CaptureStore keeps it, so a relaunch
/// comes back to this screen, not to Resume.
struct FailedRun: Codable, Equatable {

    enum Retry: String, Codable {
        /// Nothing to retry with: scan again.
        case impossible
        /// The video never landed, so the scene was never launched: upload the
        /// saved capture to a new scene and delete the old one.
        case uploadAgain
        /// The scene failed or is gone: process the saved capture as a new scene.
        case processAgain
    }

    /// What becomes of the scene when the capture is dropped.
    enum LeftoverScene: String, Codable {
        /// It stays in Scenes.
        case keep
        /// The API refused it before launching or charging anything, so it
        /// would sit in Scenes as Uploading: delete it, as Upload again does.
        case delete
    }

    let title: String
    let detail: String
    /// What was charged, when that is known.
    let charges: String?
    let sceneID: String?
    let retry: Retry
    var leftoverScene = LeftoverScene.keep
}

/// A dismissible message on the start screen.
struct HomeNotice: Equatable {
    let title: String
    let detail: String
    /// `false` for an action that went through, such as a delete.
    var isError = true
}

/// ARKit's tracking quality, as a dot and text.
struct TrackingStatus: Equatable {
    let text: String
    let dot: DotState
}

// MARK: - CaptureModel

@MainActor
final class CaptureModel: ObservableObject {

    @Published private(set) var state: CaptureState
    @Published private(set) var cameraAccess: AVAuthorizationStatus
    @Published var notice: HomeNotice?

    /// The running or complete scene's thumbnail, once the API has one.
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var isDeleting = false
    /// Why the last delete failed, shown on the complete screen.
    @Published var deleteError: String?

    // Scanning
    @Published private(set) var poseCount = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var tracking: TrackingStatus?

    /// Capture needs LiDAR: SplatScanner records its mesh as points.
    let hasLiDAR: Bool
    let hasAPIKey: Bool

    /// Exposed so the scanning view can attach an ARSCNView to the session.
    var arSession: ARSession? { scanner.session }

    // MARK: - Splat3D Integration: Client & Scanner Setup
    private let client: SplatClient?
    private let scanner = SplatScanner()
    /// Watches the client's session, for the upload's bytes.
    private let transfers: TransferWatcher
    private let store: CaptureStore

    private var runTask: Task<Void, Never>?
    /// Bumped by every run and by discarding, so a cancelled run that ends
    /// after another started (or after a discard) changes nothing.
    private var runGeneration = 0
    private var uploadWatch: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var isLoadingThumbnail = false
    /// The status the last thumbnail attempt was made at.
    private var thumbnailTriedAt: SceneStatus?
    private var trackingTask: Task<Void, Never>?
    private var durationTimer: Timer?
    private var scanStart: Date?
    private var lastPoseTick = 0

    /// The run's scene, from the moment the API created it.
    private var sceneID: String?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// Who cancels the running task, if it is cancelled.
    private var canceller = RunOutcome.Canceller.app

    private let haptics = UIImpactFeedbackGenerator(style: .medium)

    #if DEBUG
    private var isPreview = false
    #endif

    private static let posesPerTick = 5
    private static let uploadPollInterval: Duration = .milliseconds(250)
    private static let trackingPollInterval: Duration = .milliseconds(500)
    /// createAndProcess reports .uploading at 0% before the upload and 100% after.
    private static let uploadStarted: Double = 0
    private static let uploadFinished: Double = 100

    convenience init() {
        let transfers = TransferWatcher()
        let session = URLSession(configuration: .default, delegate: transfers, delegateQueue: nil)
        let store = CaptureStore.live
        let run = store.loadRun()

        // A capture on disk means the app was killed mid-run: it resumes once
        // the app is active, unless the run had already failed, which shows
        // again as it was.
        let state: CaptureState = run.map { run -> CaptureState in
            guard let failure = run.failure else {
                return .paused(PausedRun(sceneID: run.sceneID, phase: nil, cause: .appClosed, interruption: nil))
            }
            return .failed(failure)
        } ?? .idle

        self.init(
            client: apiKey.map { SplatClient(apiKey: $0, session: session) },
            hasAPIKey: apiKey != nil,
            hasLiDAR: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            cameraAccess: AVCaptureDevice.authorizationStatus(for: .video),
            store: store,
            transfers: transfers,
            state: state
        )
    }

    private init(
        client: SplatClient?,
        hasAPIKey: Bool,
        hasLiDAR: Bool,
        cameraAccess: AVAuthorizationStatus,
        store: CaptureStore,
        transfers: TransferWatcher,
        state: CaptureState
    ) {
        self.client = client
        self.hasAPIKey = hasAPIKey
        self.hasLiDAR = hasLiDAR
        self.cameraAccess = cameraAccess
        self.store = store
        self.transfers = transfers
        self.state = state
        if case .paused(let paused) = state {
            sceneID = paused.sceneID
        }
    }

    // MARK: - App lifecycle

    /// The app is in front again: Settings may have changed camera access,
    /// and a run iOS stopped in the background, or the app was killed in,
    /// picks up.
    func appBecameActive() {
        #if DEBUG
        // A preview keeps the camera access it was given.
        guard !isPreview else {
            return
        }
        #endif
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        guard case .paused(let paused) = state, paused.cause == .backgrounded || paused.cause == .appClosed else {
            return
        }
        resume()
    }

    /// The device is online again: a run the network stopped picks up, as
    /// the paused screen promises.
    func networkReturned() {
        guard case .paused(let paused) = state, paused.cause == .connection else {
            return
        }
        resume()
    }

    // MARK: - Scanning

    func startScan() async {
        // The start screen explains each of these; the button is off for them.
        guard hasAPIKey, hasLiDAR else {
            return
        }
        if cameraAccess == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard cameraAccess == .authorized else {
            return
        }

        notice = nil
        haptics.prepare()
        lastPoseTick = 0
        scanner.onFrameCountUpdated = { [weak self] count in
            self?.posesCaptured(count)
        }

        do {
            // MARK: - Splat3D Integration: Start Capture
            // scanner.start() begins the ARKit session and video recording.
            // Access scanner.session to connect your own ARSCNView for preview.
            try await scanner.start()
        } catch {
            notice = HomeNotice(title: "Couldn't start scanning", detail: error.localizedDescription)
            return
        }

        state = .scanning
        scanStart = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        startTrackingMonitor()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Stop recording, keep the capture on disk, then upload and process it.
    func stopAndUpload(preset: ScenePreset) async {
        stopScanTimers()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        state = .running(RunProgress(step: .saving))

        let capture: CaptureResult
        do {
            // MARK: - Splat3D Integration: Stop
            // scanner.stop() finalizes the video and returns poses + video URL.
            capture = try await scanner.stop()
        } catch {
            fail(FailedRun(title: "Recording failed", detail: error.localizedDescription, charges: "Nothing was sent or charged.", sceneID: nil, retry: .impossible))
            return
        }

        let now = Date()
        let run = CaptureStore.Run(sceneID: nil, preset: preset, title: Self.title(for: now), createdAt: now)
        do {
            try store.save(video: capture.videoURL, launch: .init(poses: capture.poses, lidarPoints: capture.lidarPoints), run: run)
        } catch {
            fail(FailedRun(title: "Couldn't save the capture", detail: error.localizedDescription, charges: "Nothing was sent or charged.", sceneID: nil, retry: .impossible))
            return
        }
        uploadSavedCapture()
    }

    /// Stop recording and throw the scan away: nothing is saved or sent.
    func cancelScan() async {
        stopScanTimers()
        // SplatScanner has no cancel: stop() finishes the video, then it goes.
        if let capture = try? await scanner.stop() {
            try? FileManager.default.removeItem(at: capture.videoURL)
        }
        reset()
    }

    // MARK: - Running

    /// Create a scene for the saved capture and see it through.
    private func uploadSavedCapture() {
        guard let run = store.loadRun(), let launch = try? store.loadLaunch() else {
            fail(Self.captureUnreadable(sceneID: nil))
            return
        }
        sceneID = nil
        // A new run: no scene yet, and no failure to come back to.
        try? store.saveSceneID(nil)
        try? store.saveFailure(nil)

        perform(from: RunProgress(step: .uploading)) { [weak self] client in
            guard let self else {
                throw CancellationError()
            }
            return try await self.uploadAndProcess(run, launch, with: client)
        }
    }

    private func uploadAndProcess(_ run: CaptureStore.Run, _ launch: CaptureStore.Launch, with client: SplatClient) async throws -> SplatScene {
        // MARK: - Splat3D Integration: Upload and process
        // createAndProcess creates the scene, uploads the video, launches
        // processing and polls until it finishes. The poses and points
        // come back from disk, so a resume after a relaunch sends exactly
        // the same launch.
        try await client.createAndProcess(
            videoURL: store.videoURL,
            title: run.title,
            preset: run.preset.params,
            arkitPoses: launch.poses,
            lidarPoints: launch.lidarPoints,
            onProgress: { [weak self] status, percent in
                self?.report(status, percent)
            },
            onSceneCreated: { [weak self] id in
                self?.sceneCreated(id)
            }
        )
    }

    /// Continue a paused run without paying twice.
    func resume() {
        guard case .paused(let paused) = state else {
            return
        }

        // MARK: - Splat3D Integration: Resume
        // In this run of the app, the interruption carries the exact request,
        // upload URL included.
        if let interruption = paused.interruption {
            let progress = RunProgress(step: Self.step(resuming: interruption.phase), sceneID: interruption.sceneID)
            perform(from: progress) { [weak self] client in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.resumeOrUpload(interruption.sceneID, with: client) {
                    try await client.resume(interruption) { [weak self] status, percent in
                        self?.report(status, percent)
                    }
                }
            }
            return
        }

        // The scene was never created: start it from the saved capture.
        guard let sceneID = paused.sceneID else {
            uploadSavedCapture()
            return
        }

        // After a relaunch, rebuild the launch from disk. resume(sceneID:…)
        // replays a launch that went through, and can't upload: a video that
        // never landed ends in source_missing, before anything is charged.
        guard let run = store.loadRun(), let launch = try? store.loadLaunch() else {
            fail(Self.captureUnreadable(sceneID: sceneID))
            return
        }
        perform(from: RunProgress(step: .launching, sceneID: sceneID)) { [weak self] client in
            guard let self else {
                throw CancellationError()
            }
            return try await self.resumeOrUpload(sceneID, with: client) {
                try await client.resume(
                    sceneID: sceneID,
                    preset: run.preset.params,
                    arkitPoses: launch.poses,
                    lidarPoints: launch.lidarPoints
                ) { [weak self] status, percent in
                    self?.report(status, percent)
                }
            }
        }
    }

    /// Run a resume of `sceneID`. If it finds that the video never reached
    /// the scene, which the API says before charging anything, the scene is
    /// deleted and the saved capture goes up to a new one, as Upload again
    /// does. That happens after a relaunch: the upload URL is gone, so resume
    /// can't upload, even once the network is back.
    private func resumeOrUpload(_ sceneID: String, with client: SplatClient, _ resume: () async throws -> SplatScene) async throws -> SplatScene {
        do {
            return try await resume()
        } catch {
            // A cancelled run stops on the error itself: a discard ignores it,
            // and when background time ran out the failed screen offers
            // Upload again for this scene.
            guard !Task.isCancelled, Self.videoNeverLanded(error, sceneID: sceneID) else {
                throw error
            }
            guard let run = store.loadRun(), let launch = try? store.loadLaunch() else {
                throw error
            }
            deleteUnlaunched(sceneID)
            forgetScene()
            return try await uploadAndProcess(run, launch, with: client)
        }
    }

    /// Whether a run stopped because its video never reached the scene, so
    /// the launch was refused before anything was charged.
    private static func videoNeverLanded(_ error: Error, sceneID: String) -> Bool {
        guard case .failed(let failed) = RunOutcome(error, sceneID: sceneID, cancelledBy: .app) else {
            return false
        }
        return failed.retry == .uploadAgain
    }

    /// Drop the running scene, before its capture goes up to a new one.
    private func forgetScene() {
        sceneID = nil
        try? store.saveSceneID(nil)
        updateProgress { $0 = RunProgress(step: .uploading) }
    }

    /// The video never reached the scene: delete it, and upload the saved
    /// capture to a new one. Nothing was charged for the old scene.
    func uploadAgain() {
        if case .failed(let failed) = state, let oldScene = failed.sceneID {
            deleteUnlaunched(oldScene)
        }
        uploadSavedCapture()
    }

    /// Process the saved capture again, as a new scene that is charged.
    func processAgain() {
        uploadSavedCapture()
    }

    /// Forget the capture. A scene already created stays in Scenes, unless
    /// the API refused it before launching it.
    func discard() {
        if case .failed(let failed) = state, failed.leftoverScene == .delete, let scene = failed.sceneID {
            deleteUnlaunched(scene)
        }
        runGeneration += 1
        runTask?.cancel()
        endBackgroundTime()
        store.clear()
        reset()
    }

    /// Delete a scene the API never launched, so nothing was charged for it.
    /// Best effort: if it fails, the scene stays in Scenes as Uploading.
    private func deleteUnlaunched(_ sceneID: String) {
        guard let client else {
            return
        }
        Task {
            try? await client.deleteScene(id: sceneID)
        }
    }

    /// Back to the start screen.
    func reset() {
        runTask = nil
        uploadWatch?.cancel()
        thumbnailTask?.cancel()
        isLoadingThumbnail = false
        thumbnailTriedAt = nil
        sceneID = nil
        thumbnail = nil
        deleteError = nil
        poseCount = 0
        frameCount = 0
        elapsed = 0
        tracking = nil
        state = .idle
    }

    /// Run one SDK call to its outcome, with background time while it runs.
    private func perform(from progress: RunProgress, _ operation: @escaping @MainActor (SplatClient) async throws -> SplatScene) {
        guard let client else {
            reset()
            notice = HomeNotice(title: "No API key", detail: missingAPIKeyMessage)
            return
        }

        runGeneration += 1
        let generation = runGeneration
        runTask?.cancel()
        canceller = .app
        thumbnail = nil
        thumbnailTriedAt = nil
        state = .running(progress)
        beginBackgroundTime()
        watchUpload()

        runTask = Task { [weak self] in
            do {
                let scene = try await operation(client)
                guard let self, self.runGeneration == generation else {
                    return
                }
                self.finish(scene)
            } catch {
                guard let self, self.runGeneration == generation else {
                    return
                }
                self.stop(with: error)
            }
        }
    }

    private func sceneCreated(_ id: String) {
        sceneID = id
        try? store.saveSceneID(id)
        updateProgress { $0.sceneID = id }
    }

    /// A progress callback from the SDK.
    private func report(_ status: SceneStatus, _ percent: Double?) {
        updateProgress { progress in
            guard status == .uploading else {
                progress.step = .processing
                progress.status = status
                progress.percent = percent
                return
            }
            // createAndProcess and resume bracket an upload with 0% and 100%.
            // A poll can also read .uploading just after a launch: that
            // changes nothing.
            if percent == Self.uploadStarted {
                progress.step = .uploading
            } else if percent == Self.uploadFinished {
                progress.step = max(progress.step, .launching)
            }
        }
        loadThumbnail(after: status)
    }

    private func updateProgress(_ change: (inout RunProgress) -> Void) {
        guard case .running(var progress) = state else {
            return
        }
        change(&progress)
        state = .running(progress)
    }

    /// Copy the upload's bytes into the progress while it runs.
    private func watchUpload() {
        uploadWatch?.cancel()
        uploadWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, case .running(let progress) = self.state else {
                    return
                }
                if progress.step == .uploading, let bytes = self.transfers.bytes {
                    self.updateProgress {
                        $0.bytesSent = bytes.sent
                        $0.bytesTotal = bytes.expectedToSend
                    }
                }
                try? await Task.sleep(for: Self.uploadPollInterval)
            }
        }
    }

    private func finish(_ scene: SplatScene) {
        endBackgroundTime()
        uploadWatch?.cancel()
        store.clear()
        sceneID = scene.id
        state = .complete(scene)
        loadThumbnail(for: scene.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func stop(with error: Error) {
        endBackgroundTime()
        uploadWatch?.cancel()

        switch RunOutcome(error, sceneID: sceneID, cancelledBy: canceller) {
        case .paused(let paused):
            state = .paused(paused)
            // Background time ran out, and the app is already back in front.
            if paused.cause == .backgrounded, UIApplication.shared.applicationState == .active {
                resume()
                return
            }
        case .failed(let failed):
            fail(failed)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func fail(_ failed: FailedRun) {
        state = .failed(failed)
        // Kept with the capture, which Upload again and Process again still
        // need: a relaunch shows this screen, not "A capture is waiting".
        try? store.saveFailure(failed)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    // MARK: - Background time

    /// Ask iOS to keep the app running for a while after it leaves the screen.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else {
            return
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Splat3D capture") { [weak self] in
            // iOS calls this on the main thread, just before suspending.
            MainActor.assumeIsolated {
                self?.backgroundTimeExpired()
            }
        }
    }

    private func backgroundTimeExpired() {
        canceller = .backgroundTimeExpiry
        runTask?.cancel()
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Thumbnail

    /// Try for a thumbnail once processing is under way: the pipeline makes
    /// one early. A missing one answers 404, so each new status tries again,
    /// once.
    private func loadThumbnail(after status: SceneStatus) {
        guard thumbnail == nil, status != .uploading, status != thumbnailTriedAt, let sceneID else {
            return
        }
        thumbnailTriedAt = status
        loadThumbnail(for: sceneID)
    }

    /// One request at a time; a failed one leaves the next status to try.
    private func loadThumbnail(for sceneID: String) {
        guard let client, thumbnail == nil, !isLoadingThumbnail else {
            return
        }
        isLoadingThumbnail = true
        thumbnailTask = Task { [weak self] in
            // MARK: - Splat3D Integration: Thumbnail
            // getSceneThumbnail sends the API key, which a private scene needs.
            let data = try? await client.getSceneThumbnail(id: sceneID)
            guard let self else {
                return
            }
            self.isLoadingThumbnail = false
            // Only for the scene still on screen.
            guard self.sceneID == sceneID, let data, let image = UIImage(data: data) else {
                return
            }
            self.thumbnail = image
        }
    }

    // MARK: - Delete

    func deleteCompletedScene() async {
        guard case .complete(let scene) = state, let client else {
            return
        }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }

        do {
            // MARK: - Splat3D Integration: Delete
            try await client.deleteScene(id: scene.id)
        } catch {
            deleteError = error.localizedDescription
            return
        }
        reset()
        notice = HomeNotice(title: "Scene deleted", detail: "\(scene.displayTitle) and its files are gone.", isError: false)
    }

    // MARK: - Scanning helpers

    private func posesCaptured(_ count: Int) {
        poseCount = count
        frameCount = scanner.totalFrameCount
        // A haptic tick every few poses.
        if count > lastPoseTick, count % Self.posesPerTick == 0 {
            haptics.impactOccurred(intensity: 0.7)
            lastPoseTick = count
        }
    }

    private func tick() {
        guard let scanStart else {
            return
        }
        elapsed = Date().timeIntervalSince(scanStart)
        frameCount = scanner.totalFrameCount
    }

    private func stopScanTimers() {
        durationTimer?.invalidate()
        durationTimer = nil
        trackingTask?.cancel()
        trackingTask = nil
    }

    private func startTrackingMonitor() {
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, case .scanning = self.state else {
                    return
                }
                if let camera = self.scanner.session?.currentFrame?.camera {
                    self.tracking = self.status(of: camera.trackingState)
                }
                try? await Task.sleep(for: Self.trackingPollInterval)
            }
        }
    }

    private func status(of state: ARCamera.TrackingState) -> TrackingStatus {
        switch state {
        case .normal:
            return TrackingStatus(text: "Tracking well", dot: .done)
        case .notAvailable:
            return TrackingStatus(text: "Tracking lost", dot: .failed)
        case .limited(let reason):
            switch reason {
            case .initializing:
                return TrackingStatus(text: "Starting up…", dot: .waiting)
            case .excessiveMotion:
                haptics.impactOccurred(intensity: 0.8)
                return TrackingStatus(text: "Slow down", dot: .waiting)
            case .insufficientFeatures:
                return TrackingStatus(text: "Needs more detail", dot: .waiting)
            case .relocalizing:
                return TrackingStatus(text: "Relocalizing…", dot: .waiting)
            @unknown default:
                return TrackingStatus(text: "Limited tracking", dot: .waiting)
            }
        }
    }

    // MARK: - Helpers

    private static func title(for date: Date) -> String {
        "Capture " + date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Where an interrupted run picks up: resume launches first after an
    /// upload or launch stopped.
    private static func step(resuming phase: SplatError.Interruption.Phase) -> RunProgress.Step {
        phase == .wait ? .processing : .launching
    }

    private static func captureUnreadable(sceneID: String?) -> FailedRun {
        FailedRun(
            title: "The saved capture can't be read",
            detail: "Without it Splat Capture can't rebuild the launch exactly. A scene that was launched keeps processing, and shows in Scenes.",
            charges: nil,
            sceneID: sceneID,
            retry: .impossible
        )
    }
}

// MARK: - Splat3D Integration: Reading errors
//
// What an error from createAndProcess or resume means for the run. The SDK
// throws .interrupted only when resume can make progress, and the error
// itself when nothing can: a failed, cancelled or deleted scene, or a request
// the API refuses outright.

enum RunOutcome {
    case paused(PausedRun)
    case failed(FailedRun)

    /// Who cancelled a run that ended in CancellationError.
    enum Canceller {
        /// The app, e.g. a discarded run.
        case app
        /// iOS ended the app's background time.
        case backgroundTimeExpiry
    }

    /// The API's error codes (api/src/lib/scenes.ts in the Splat3D repo).
    private enum Code {
        static let insufficientCredits = "insufficient_credits"
        static let queueFull = "queue_full"
        static let quotaExceeded = "quota_exceeded"
        static let sourceMissing = "source_missing"
        static let sourceUnusable = "source_unusable"
        static let conflict = "conflict"
    }

    /// processScene's message when the video never landed, from servers that
    /// send it without the code.
    private static let sourceMissingMessage = "Source file not found"

    /// RFC 9110 §15.5.4: storage refusing an expired upload URL.
    private static let forbidden = 403
    private static let clientErrors = 400..<500

    /// Why an upload failed before sending: the file is missing or empty.
    private static let unsendableFile: Set<URLError.Code> = [.fileDoesNotExist, .noPermissionsToReadFile, .fileIsDirectory, .zeroByteResource]

    init(_ error: Error, sceneID: String?, cancelledBy canceller: Canceller) {
        if case SplatError.interrupted(let interruption) = error {
            self = Self.interrupted(interruption, cancelledBy: canceller)
            return
        }
        if let failed = Self.final(error, sceneID: sceneID) {
            self = .failed(failed)
            return
        }
        // No scene yet: creating it failed, or was cancelled. Resume starts over.
        let cause = Self.cause(of: error, cancelledBy: canceller)
        self = .paused(PausedRun(sceneID: nil, phase: nil, cause: cause, interruption: nil))
    }

    private static func interrupted(_ interruption: SplatError.Interruption, cancelledBy canceller: Canceller) -> RunOutcome {
        // Refusals a repeat of the same launch would meet again.
        if let refusal = (interruption.underlying as? SplatError)?.apiError {
            switch refusal.code {
            case Code.sourceUnusable:
                return .failed(FailedRun(
                    title: "The server can't use this capture",
                    detail: refusal.message,
                    charges: "Nothing was charged.",
                    sceneID: interruption.sceneID,
                    retry: .impossible,
                    leftoverScene: .delete
                ))
            case Code.conflict:
                return .failed(FailedRun(
                    title: "Launched with other settings",
                    detail: refusal.message,
                    charges: "The scene was charged at most once. Scenes shows how it went.",
                    sceneID: interruption.sceneID,
                    retry: .impossible
                ))
            default:
                break
            }
        }
        let cause = cause(of: interruption.underlying, cancelledBy: canceller)
        return .paused(PausedRun(sceneID: interruption.sceneID, phase: interruption.phase, cause: cause, interruption: interruption))
    }

    /// Errors that end the run, with what could come next.
    private static func final(_ error: Error, sceneID: String?) -> FailedRun? {
        switch error {
        case SplatError.processingFailed(let reason):
            return FailedRun(
                title: "Processing failed",
                detail: reason.isEmpty ? "The pipeline couldn't build this scene." : reason,
                charges: "The scene's credits are refunded.",
                sceneID: sceneID,
                retry: .processAgain
            )
        case SplatError.cancelled:
            return FailedRun(
                title: "Scene cancelled",
                detail: "It was cancelled on the server, for example from the dashboard.",
                charges: "A job that had already started isn't refunded.",
                sceneID: sceneID,
                retry: .processAgain
            )
        case SplatError.notFound:
            return FailedRun(title: "Scene deleted", detail: "The scene no longer exists.", charges: nil, sceneID: sceneID, retry: .processAgain)
        case SplatError.notStarted:
            return FailedRun(
                title: "Processing never started",
                detail: "The video didn't reach the server, so no job was launched.",
                charges: "Nothing was charged.",
                sceneID: sceneID,
                retry: .uploadAgain
            )
        case SplatError.uploadFailed(let cause as URLError) where unsendableFile.contains(cause.code):
            return FailedRun(
                title: "The capture file is gone",
                detail: "The saved video is missing or empty, so it can't be sent. Scan again.",
                charges: "Nothing was charged.",
                sceneID: sceneID,
                retry: .impossible
            )
        case let error as SplatError where isSourceMissing(error):
            return FailedRun(
                title: "The upload didn't finish",
                detail: "The app closed before the video finished uploading, and this scene can't take it now.",
                charges: "Nothing was charged.",
                sceneID: sceneID,
                retry: .uploadAgain
            )
        case SplatError.requestFailed(let refusal) where refusal.statusCode == forbidden && refusal.code == nil:
            return FailedRun(
                title: "The upload link expired",
                detail: "Storage refused the upload. Its link lasts about an hour.",
                charges: "Nothing was charged.",
                sceneID: sceneID,
                retry: .uploadAgain
            )
        case SplatError.requestFailed(let refusal) where clientErrors.contains(refusal.statusCode):
            return FailedRun(
                title: "The API refused the request",
                detail: refusal.message,
                charges: "Nothing was charged.",
                sceneID: sceneID,
                retry: .impossible
            )
        default:
            return nil
        }
    }

    private static func cause(of error: Error, cancelledBy canceller: Canceller) -> PausedRun.Cause {
        if error is CancellationError {
            return canceller == .backgroundTimeExpiry ? .backgrounded : .other("The run was stopped.")
        }
        if case SplatError.timeout = error {
            return .timedOut
        }
        if case SplatError.unauthorized = error {
            return .keyRejected
        }
        if let refusal = (error as? SplatError)?.apiError {
            switch refusal.code {
            case Code.insufficientCredits:
                return .insufficientCredits(refusal.message)
            case Code.queueFull:
                return .queueFull(refusal.message)
            case Code.quotaExceeded:
                return .quotaExceeded(refusal.message)
            default:
                return .other(refusal.message)
            }
        }
        if isConnection(error) {
            return .connection
        }
        return .other(error.localizedDescription)
    }

    /// A network failure, from the API or the upload.
    private static func isConnection(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        if case SplatError.uploadFailed(let cause) = error {
            return cause is URLError
        }
        return false
    }

    private static func isSourceMissing(_ error: SplatError) -> Bool {
        guard let refusal = error.apiError else {
            return false
        }
        return refusal.code == Code.sourceMissing || refusal.message.hasPrefix(sourceMissingMessage)
    }
}

// MARK: - What a pause means

extension PausedRun {

    var title: String {
        switch cause {
        case .connection:
            return "Connection lost"
        case .backgrounded:
            return "Paused in the background"
        case .appClosed:
            return "A capture is waiting"
        case .insufficientCredits:
            return "Not enough credits"
        case .queueFull:
            return "Too many scenes processing"
        case .quotaExceeded:
            return "Monthly limit reached"
        case .keyRejected:
            return "API key rejected"
        case .timedOut:
            return "Still processing"
        case .other:
            return "Stopped"
        }
    }

    var detail: String {
        switch cause {
        case .connection:
            return "The network dropped before Splat Capture heard back."
        case .backgrounded:
            return "iOS paused Splat Capture soon after you left it. It picks up when you come back, or tap Resume."
        case .appClosed:
            return "Splat Capture closed while this capture was on its way. Resume picks up where it stopped."
        case .insufficientCredits(let message):
            return "\(Self.droppingCreditsPreamble(message)) Add credits, then Resume."
        case .queueFull(let message):
            return message
        case .quotaExceeded(let message):
            return "\(message) Change your plan in billing, or Resume next month."
        case .keyRejected:
            return "The API didn't accept this build's key. Set SPLAT_API_KEY in Secrets.xcconfig and build again."
        case .timedOut:
            return "Splat Capture stopped waiting, but the job may still finish. Resume keeps watching."
        case .other(let message):
            return message
        }
    }

    /// What has been charged, and what Resume will charge.
    var charges: String {
        guard sceneID != nil else {
            return "The scene wasn't created. Nothing was charged."
        }
        if refusedBeforeCharging {
            return "Nothing was charged."
        }
        if phase == .upload {
            return "Nothing has been charged yet."
        }
        if phase == .launch {
            return "If the launch reached the server, Resume replays it: you're charged once."
        }
        if phase == .wait {
            return "Processing was charged once, and keeps running on the server."
        }
        return "A launch that went through is replayed, not charged again."
    }

    /// The API's refusal opens with what the title already says: "Not
    /// enough credits" over "Insufficient credits. Need 10 credits to
    /// process this scene."
    private static let creditsPreamble = "Insufficient credits. "

    private static func droppingCreditsPreamble(_ message: String) -> String {
        guard message.hasPrefix(creditsPreamble) else {
            return message
        }
        return String(message.dropFirst(creditsPreamble.count))
    }

    /// The API refuses these launches before charging anything.
    private var refusedBeforeCharging: Bool {
        switch cause {
        case .insufficientCredits, .queueFull, .quotaExceeded:
            return true
        default:
            return false
        }
    }
}

// MARK: - Connectivity

/// Whether the device has a network path, for the progress screen.
@MainActor
final class Connectivity: ObservableObject {

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "SplatCapture.connectivity"))
    }

    #if DEBUG
    /// A fixed answer, without watching the network, for PreviewHarness.
    init(previewOnline isOnline: Bool) {
        self.isOnline = isOnline
    }
    #endif

    deinit {
        monitor.cancel()
    }
}

// MARK: - Presets

extension ScenePreset {
    /// The SDK's parameters for this preset. Ultra also builds LOD.
    var params: SceneParams {
        switch self {
        case .fast:
            return .fast
        case .standard:
            return .standard
        case .quality:
            return .quality
        case .ultra:
            return .ultra
        }
    }

    /// Resolution, training length and typical time, from the SDK's
    /// ScenePreset documentation.
    var summary: String {
        switch self {
        case .fast:
            return "800 px · 3K iterations · about 3 min"
        case .standard:
            return "1600 px · 7K iterations · about 13 min"
        case .quality:
            return "1600 px · 15K iterations · about 25 min"
        case .ultra:
            return "Full resolution · 30K iterations · about 45 min"
        }
    }
}

// MARK: - Previews

#if DEBUG
extension CaptureModel {
    /// A model in a fixed state, for PreviewHarness. It has no client, so
    /// nothing it shows can reach the API.
    /// The device and capture a preview pretends to have.
    struct PreviewSetup {
        var hasLiDAR = true
        var hasAPIKey = true
        var cameraAccess = AVAuthorizationStatus.authorized
        var scanning: (poses: Int, frames: Int, elapsed: TimeInterval, tracking: TrackingStatus?)?
    }

    static func preview(_ state: CaptureState, _ setup: PreviewSetup = PreviewSetup()) -> CaptureModel {
        let model = CaptureModel(
            client: nil,
            hasAPIKey: setup.hasAPIKey,
            hasLiDAR: setup.hasLiDAR,
            cameraAccess: setup.cameraAccess,
            store: CaptureStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PreviewCapture")),
            transfers: TransferWatcher(),
            state: state
        )
        model.isPreview = true
        if let scanning = setup.scanning {
            model.poseCount = scanning.poses
            model.frameCount = scanning.frames
            model.elapsed = scanning.elapsed
            model.tracking = scanning.tracking
        }
        return model
    }
}
#endif
