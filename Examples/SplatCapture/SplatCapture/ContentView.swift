import SwiftUI
import ARKit
import SceneKit
import Splat3D

// MARK: - Splat3D Integration: Configuration
//
// 1. Your API key is read at runtime from the SPLAT_API_KEY build setting.
//    Copy Secrets.example.xcconfig to Secrets.xcconfig (git ignores it) and set
//    it there. Never put a key in source: this repository is public.
// 2. The SDK entry points used in this app:
//    - SplatScanner  — captures video + ARKit poses (CaptureModel.swift)
//    - SplatClient   — uploads and processes via the Splat API, resumes an
//                      interrupted run without paying twice, fetches the
//                      thumbnail and deletes (CaptureModel.swift); lists and
//                      deletes scenes (RecentScenesView.swift) and downloads
//                      their SPZ (SceneViewer.swift)
//    - ARKitPose     — pose format sent to the API (handled internally by
//                      SplatScanner, and saved by CaptureStore.swift)
// 3. SplatKit (github.com/Xget7/splatkit-ios, MIT) draws the downloaded scene
//    natively: see SplatWorldView.swift.

/// Your Splat API key, from the `SplatAPIKey` Info.plist entry, which the build
/// fills from `SPLAT_API_KEY` in Secrets.xcconfig. `nil` until you set it.
let apiKey: String? = {
    guard let key = Bundle.main.object(forInfoDictionaryKey: "SplatAPIKey") as? String,
          key.hasPrefix("s3d_") else {
        return nil
    }
    return key
}()

/// Shown instead of scanning when no key is set.
let missingAPIKeyMessage = """
    No Splat API key. Copy Examples/SplatCapture/Secrets.example.xcconfig to \
    Secrets.xcconfig, set SPLAT_API_KEY to your key, and build again.
    """

// MARK: - Mesh Material

/// Opacity of the scanned surface overlay.
private let meshOpacity: CGFloat = 0.4

/// Shared material for the scanned surface overlay, in the dark theme's
/// accent: the camera view is always dark.
private let meshMaterial: SCNMaterial = {
    let mat = SCNMaterial()
    mat.diffuse.contents = Palette.UI.accent
        .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        .withAlphaComponent(meshOpacity)
    mat.isDoubleSided = true
    mat.fillMode = .fill
    mat.lightingModel = .constant
    mat.writesToDepthBuffer = true
    mat.readsFromDepthBuffer = true
    mat.blendMode = .alpha
    return mat
}()

private let meshWireframeMaterial: SCNMaterial = {
    let mat = SCNMaterial()
    mat.diffuse.contents = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)
    mat.isDoubleSided = true
    mat.fillMode = .lines
    mat.lightingModel = .constant
    mat.writesToDepthBuffer = false
    return mat
}()

// MARK: - ARMeshAnchor -> SCNGeometry

extension ARMeshGeometry {
    /// Convert ARKit mesh geometry to a SceneKit geometry for rendering.
    func toSCNGeometry() -> SCNGeometry {
        // Vertices
        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )

        // Triangle indices — ARKit uses uint32 per index, 3 per face
        let indexData = Data(
            bytesNoCopy: faces.buffer.contents(),
            count: faces.buffer.length,
            deallocator: .none
        )

        // Two elements sharing the same triangles: fill + wireframe edges
        let fillElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let wireElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(
            sources: [vertexSource],
            elements: [fillElement, wireElement]
        )
        // First material = filled surface, second = wireframe edges
        geometry.materials = [meshMaterial, meshWireframeMaterial]
        return geometry
    }
}

// MARK: - ARCameraView

/// Wraps an ARSCNView with live mesh overlay showing scanned surfaces.
struct ARCameraView: UIViewRepresentable {

    let session: ARSession

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {

        private let meshHaptic = UIImpactFeedbackGenerator(style: .medium)
        private var meshAnchorCount = 0

        func renderer(_ renderer: any SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }

            // Haptic pulse when a new mesh chunk is discovered
            meshAnchorCount += 1
            if meshAnchorCount % 2 == 0 {
                meshHaptic.impactOccurred(intensity: 0.7)
            }

            let node = SCNNode(geometry: meshAnchor.geometry.toSCNGeometry())
            return node
        }

        func renderer(_ renderer: any SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            node.geometry = meshAnchor.geometry.toSCNGeometry()
        }
    }
}

// MARK: - Navigation

/// Screens pushed on the main navigation stack.
enum Route: Hashable {
    case recentScenes
    /// `webURL` is the scene on splat-3d.com, for when the app can't show it.
    case viewer(sceneID: String, title: String, webURL: URL?)
}

// MARK: - ContentView

struct ContentView: View {

    @StateObject private var model = CaptureModel()
    @StateObject private var connectivity = Connectivity()

    var body: some View {
        CaptureRoot(model: model, connectivity: connectivity)
    }
}

/// The app's screens for one capture model: scanning full screen, and every
/// other state on a navigation stack with Scenes and the viewer.
struct CaptureRoot: View {

    @ObservedObject var model: CaptureModel
    @ObservedObject var connectivity: Connectivity

    // Fast by default: the quickest and cheapest preset, for trying things out.
    @AppStorage("scenePreset") private var preset = ScenePreset.fast
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if case .scanning = model.state {
                ScanningView(model: model, preset: preset)
            } else {
                NavigationStack {
                    // Each screen sets its own title: large on the start
                    // screen, inline on the rest.
                    screen
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink(value: Route.recentScenes) {
                                    Label("Scenes", systemImage: "square.stack.3d.up")
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                        }
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .recentScenes:
                                RecentScenesView()
                            case .viewer(let sceneID, let title, let webURL):
                                SceneViewerScreen(sceneID: sceneID, title: title, webURL: webURL)
                            }
                        }
                }
            }
        }
        .tint(Palette.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.appBecameActive()
            }
        }
        .onChange(of: connectivity.isOnline) { _, online in
            if online {
                model.networkReturned()
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch model.state {
        case .idle, .scanning:
            HomeView(model: model, preset: $preset)
        case .running(let progress):
            RunningView(progress: progress, thumbnail: model.thumbnail, isOnline: connectivity.isOnline)
        case .paused(let paused):
            PausedView(
                paused: paused,
                isOnline: connectivity.isOnline,
                onResume: { model.resume() },
                onDiscard: { model.discard() }
            )
        case .failed(let failed):
            FailedView(
                failed: failed,
                onUploadAgain: { model.uploadAgain() },
                onProcessAgain: { model.processAgain() },
                onDiscard: { model.discard() }
            )
        case .complete(let scene):
            CompleteView(
                scene: scene,
                thumbnail: model.thumbnail,
                isDeleting: model.isDeleting,
                deleteError: model.deleteError,
                onDelete: { Task { await model.deleteCompletedScene() } },
                onNewCapture: { model.reset() }
            )
        }
    }
}

// MARK: - Home

/// The start screen: preset, readiness checks, and Start capture. Anything
/// that stops a capture says why and what to do, and Scenes stays open.
struct HomeView: View {

    @ObservedObject var model: CaptureModel
    @Binding var preset: ScenePreset

    var body: some View {
        Screen(
            title: "Splat Capture",
            titleDisplay: .large,
            headline: "Scan a space in 3D",
            lead: "Walk slowly around what you want to keep, for 15 to 60 seconds. SplatCapture records video and ARKit camera poses, and Splat3D turns them into a Gaussian splat scene."
        ) {
            if let notice = model.notice {
                NoticeCard(tone: notice.isError ? .alarm : .done, title: notice.title, detail: notice.detail) {
                    Button("Dismiss") {
                        model.notice = nil
                    }
                    .actionStyle(.secondary, width: .fitted)
                }
            }

            blocker

            CardSection(
                header: "Preset",
                footer: preset == .fast ? "The quickest and cheapest: good for trying things out." : "Higher presets take longer and cost more credits."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Choice(label: "Preset", options: ScenePreset.allCases, selection: $preset) { $0.title }
                    Text(preset.summary)
                        .typeStyle(.data)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.rowInset)
            }

            CardSection(header: "Requirements") {
                FactRow(label: "LiDAR") {
                    StatusLabel(state: model.hasLiDAR ? .done : .failed, text: model.hasLiDAR ? "Ready" : "Not on this device")
                }
                CardDivider()
                FactRow(label: "Camera") {
                    StatusLabel(state: cameraDot, text: cameraText)
                }
                CardDivider()
                FactRow(label: "API key") {
                    StatusLabel(state: model.hasAPIKey ? .done : .failed, text: model.hasAPIKey ? "Set" : "Missing")
                }
            }

            VStack(spacing: 12) {
                Button("Start capture") {
                    Task { await model.startScan() }
                }
                .actionStyle(.primary)
                .disabled(!canCapture)

                NavigationLink(value: Route.recentScenes) {
                    Text("Your scenes")
                }
                .actionStyle(.secondary)
            }
        }
    }

    private var cameraDenied: Bool {
        model.cameraAccess == .denied || model.cameraAccess == .restricted
    }

    private var canCapture: Bool {
        model.hasAPIKey && model.hasLiDAR && !cameraDenied
    }

    private var cameraDot: DotState {
        switch model.cameraAccess {
        case .authorized:
            return .done
        case .notDetermined:
            return .waiting
        default:
            return .failed
        }
    }

    private var cameraText: String {
        switch model.cameraAccess {
        case .authorized:
            return "Allowed"
        case .notDetermined:
            return "Asks on first scan"
        default:
            return "Off in Settings"
        }
    }

    /// What stops a capture on this device, worst first.
    @ViewBuilder
    private var blocker: some View {
        if !model.hasAPIKey {
            NoticeCard(tone: .alarm, title: "No API key", detail: missingAPIKeyMessage)
        } else if !model.hasLiDAR {
            NoticeCard(
                tone: .neutral,
                title: "This device has no LiDAR scanner",
                detail: "Capture needs one: an iPhone 12 Pro or newer, or an iPad Pro with LiDAR. Your scenes still open here, in 3D."
            )
        } else if cameraDenied {
            NoticeCard(
                tone: .alarm,
                title: "Camera access is off",
                detail: "SplatCapture records video to build the scene. Turn on Camera for SplatCapture in Settings."
            ) {
                Button("Open Settings") {
                    guard let settings = URL(string: UIApplication.openSettingsURLString) else {
                        return
                    }
                    UIApplication.shared.open(settings)
                }
                .actionStyle(.secondary, width: .fitted)
            }
        }
    }
}

// MARK: - Scanning

/// The camera with the scanned mesh, and the capture's numbers and controls
/// floating over it on glass.
struct ScanningView: View {

    @ObservedObject var model: CaptureModel
    let preset: ScenePreset

    /// Set by Stop and upload or Cancel, so the other can't run after it.
    @State private var isStopping = false
    @State private var confirmingCancel = false

    /// Space between glass surfaces; closer ones blend on iOS 26.
    private static let glassSpacing: CGFloat = 12
    private static let readoutCorner: CGFloat = 20
    private static let recordingDot: CGFloat = 10

    var body: some View {
        ZStack {
            if let session = model.arSession {
                ARCameraView(session: session)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }

            VStack(spacing: Self.glassSpacing) {
                GlassGroup(spacing: Self.glassSpacing) {
                    HStack(alignment: .top) {
                        HStack(spacing: 8) {
                            // Recording.
                            Circle()
                                .fill(Palette.alarm)
                                .frame(width: Self.recordingDot, height: Self.recordingDot)
                                .accessibilityHidden(true)
                            Text(duration)
                                .typeStyle(.data)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassSurface(in: Capsule())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Recording, \(duration)")

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            counter("Poses", model.poseCount)
                            counter("Frames", model.frameCount)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassSurface(in: RoundedRectangle(cornerRadius: Self.readoutCorner, style: .continuous))
                    }
                }

                Spacer()

                GlassGroup(spacing: Self.glassSpacing) {
                    VStack(spacing: Self.glassSpacing) {
                        // Side by side; stacked when the text is too large.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                readouts
                            }
                            VStack(spacing: 8) {
                                readouts
                            }
                        }

                        // Side by side; stacked when the text is too large.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Self.glassSpacing) {
                                cancelButton
                                    .fixedSize()
                                stopButton
                            }
                            VStack(spacing: Self.glassSpacing) {
                                stopButton
                                cancelButton
                            }
                        }
                    }
                }
            }
            .padding(Theme.margin)
        }
        .environment(\.colorScheme, .dark)
        .confirmationDialog("Discard this scan?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Discard scan", role: .destructive) {
                isStopping = true
                Task { await model.cancelScan() }
            }
        } message: {
            Text("The video and poses are deleted. Nothing is uploaded or charged.")
        }
    }

    /// ARKit's tracking and the preset, above the buttons.
    @ViewBuilder
    private var readouts: some View {
        if let tracking = model.tracking {
            StatusLabel(state: tracking.dot, text: tracking.text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule())
        }
        Text("\(preset.title) preset")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassSurface(in: Capsule())
    }

    private var stopButton: some View {
        Button("Stop and upload") {
            isStopping = true
            Task { await model.stopAndUpload(preset: preset) }
        }
        .actionStyle(.primary)
        .disabled(isStopping)
    }

    /// A scan you don't want ends here, not as a scene.
    private var cancelButton: some View {
        Button("Cancel") {
            confirmingCancel = true
        }
        .actionStyle(.secondary, width: .fitted)
        .disabled(isStopping)
    }

    /// "1:05".
    private var duration: String {
        let seconds = Int(model.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func counter(_ label: String, _ value: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .typeStyle(.data)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preset names

private extension ScenePreset {
    /// "Fast", for the preset control and the scan screen.
    var title: String {
        rawValue.capitalized
    }
}
