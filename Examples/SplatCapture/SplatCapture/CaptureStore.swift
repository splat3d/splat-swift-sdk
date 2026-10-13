import Foundation
import Splat3D

// MARK: - Splat3D Integration: Surviving an app restart
//
// SplatClient.resume(sceneID:preset:arkitPoses:lidarPoints:) continues a
// scene from an earlier run of the app without paying twice, but only if it
// gets back exactly what createAndProcess was given: the API hashes the launch
// body. So the capture is written here before the scene is created, and the
// scene ID the moment onSceneCreated passes it.
//
//   Application Support/Capture/
//     capture.mp4   the video SplatScanner recorded (needed to upload again)
//     launch.json   ARKit poses and LiDAR points, what the launch resends
//     run.json      preset, title, the scene ID once it exists, and how
//                   the run failed if it did
//
// JSONEncoder writes every Float and Double so it reads back to the same
// value, so the rebuilt launch body matches the original byte for byte.

/// One capture on disk, kept until its scene is done or discarded.
struct CaptureStore {

    /// What the run was started with.
    struct Run: Codable, Equatable {
        /// `nil` until the API has created the scene.
        var sceneID: String?
        let preset: ScenePreset
        let title: String
        let createdAt: Date
        /// Set when the run ended for good: a relaunch shows it again.
        var failure: FailedRun?
    }

    /// What resume must resend exactly.
    struct Launch: Codable {
        let poses: [ARKitPose]
        let lidarPoints: [[Float]]?
    }

    private static let folderName = "Capture"
    private static let videoName = "capture.mp4"
    private static let launchName = "launch.json"
    private static let runName = "run.json"

    let directory: URL

    /// The live store, in Application Support.
    static let live = CaptureStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent(folderName, isDirectory: true)
    )

    var videoURL: URL {
        directory.appendingPathComponent(Self.videoName)
    }

    private var launchURL: URL {
        directory.appendingPathComponent(Self.launchName)
    }

    private var runURL: URL {
        directory.appendingPathComponent(Self.runName)
    }

    /// Keep a fresh capture: moves the recorded video in, and writes the
    /// launch and the run. Replaces any capture kept before.
    func save(video: URL, launch: Launch, run: Run) throws {
        clear()
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup()

        try files.moveItem(at: video, to: videoURL)
        try JSONEncoder().encode(launch).write(to: launchURL, options: .atomic)
        try write(run)
    }

    /// Record the scene ID, the moment the API has created the scene.
    func saveSceneID(_ sceneID: String?) throws {
        try update { $0.sceneID = sceneID }
    }

    /// Record how the run failed, or `nil` when a new run starts.
    func saveFailure(_ failure: FailedRun?) throws {
        try update { $0.failure = failure }
    }

    /// Change the kept run, if there is one.
    private func update(_ change: (inout Run) -> Void) throws {
        guard var run = loadRun() else {
            return
        }
        change(&run)
        try write(run)
    }

    /// The kept run, or `nil` when there is none (or it can't be read, in
    /// which case nothing can be resumed exactly anyway).
    func loadRun() -> Run? {
        guard let data = try? Data(contentsOf: runURL) else {
            return nil
        }
        return try? JSONDecoder().decode(Run.self, from: data)
    }

    func loadLaunch() throws -> Launch {
        try JSONDecoder().decode(Launch.self, from: Data(contentsOf: launchURL))
    }

    /// Forget the capture: video, launch and run.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ run: Run) throws {
        try JSONEncoder().encode(run).write(to: runURL, options: .atomic)
    }

    /// A capture is often hundreds of megabytes, and only useful until its
    /// scene is done: keep it out of iCloud backups.
    private func excludeFromBackup() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
    }
}
