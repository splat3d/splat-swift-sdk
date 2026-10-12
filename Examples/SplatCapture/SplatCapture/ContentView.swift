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
    case viewer(sceneID: String, title: String)
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
                    screen
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Logo()
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink("Scenes", value: Route.recentScenes)
                                    .typeStyle(.button)
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .recentScenes:
                                RecentScenesView()
                            case .viewer(let sceneID, let title):
                                SceneViewerScreen(sceneID: sceneID, title: title)
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
    }

    @ViewBuilder
    private var screen: some View {
        switch model.state {
        case .idle, .scanning:
            HomeView(model: model, preset: $preset)
        case .running(let progress):
            RunningView(progress: progress, thumbnail: model.thumbnail, isOnline: connectivity.isOnline)
        case .paused(let paused):
            PausedView(paused: paused, isOnline: connectivity.isOnline, onResume: { model.resume() }, onDiscard: { model.discard() })
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
            eyebrow: "Capture",
            title: "Scan a space in 3D",
            lead: "Walk slowly around what you want to keep, for 15 to 60 seconds. SplatCapture records video and ARKit camera poses, and Splat3D turns them into a Gaussian splat scene."
        ) {
            if let notice = model.notice {
                NoticeBox(tone: notice.isError ? .alarm : .neutral, title: notice.title, detail: notice.detail) {
                    Button("Dismiss") {
                        model.notice = nil
                    }
                    .buttonStyle(.ghost)
                }
            }

            blocker

            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    MonoLabel("Preset")
                    SquareTabs(options: ScenePreset.allCases, selection: $preset) { $0.rawValue }
                    Text(preset.summary)
                        .typeStyle(.data)
                        .foregroundStyle(Palette.ink)
                    Text(preset == .fast ? "The quickest and cheapest: good for trying things out." : "Higher presets take longer and cost more credits.")
                        .typeStyle(.footnote)
                        .foregroundStyle(Palette.graphite)
                }
                .padding(14)
            }

            Panel {
                FactRow(label: "LiDAR") {
                    StatusLabel(state: model.hasLiDAR ? .done : .failed, text: model.hasLiDAR ? "Ready" : "Not on this device")
                }
                Rule()
                FactRow(label: "Camera") {
                    StatusLabel(state: cameraDot, text: cameraText)
                }
                Rule()
                FactRow(label: "API key") {
                    StatusLabel(state: model.hasAPIKey ? .done : .failed, text: model.hasAPIKey ? "Set" : "Missing")
                }
            }

            VStack(spacing: 10) {
                Button("Start capture") {
                    Task { await model.startScan() }
                }
                .buttonStyle(.primary)
                .disabled(!canCapture)

                NavigationLink(value: Route.recentScenes) {
                    Text("Your scenes")
                }
                .buttonStyle(.ghost)
            }

            APICallBlock(code: """
                let scanner = SplatScanner()
                try await scanner.start()
                // … walk around the scene …
                let capture = try await scanner.stop()
                """)
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
            NoticeBox(tone: .alarm, title: "No API key", detail: missingAPIKeyMessage)
        } else if !model.hasLiDAR {
            NoticeBox(
                tone: .neutral,
                title: "This device has no LiDAR scanner",
                detail: "Capture needs one: an iPhone 12 Pro or newer, or an iPad Pro with LiDAR. Your scenes still open here, in 3D."
            )
        } else if cameraDenied {
            NoticeBox(
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
                .buttonStyle(.ghost)
            }
        }
    }
}

// MARK: - Scanning

/// The camera with the scanned mesh, and the capture's numbers over it.
struct ScanningView: View {

    @ObservedObject var model: CaptureModel
    let preset: ScenePreset

    /// The overlays sit on the camera image: mostly opaque, never glass.
    private static let overlayOpacity = 0.85

    var body: some View {
        ZStack {
            if let session = model.arSession {
                ARCameraView(session: session)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    overlay {
                        HStack(spacing: 8) {
                            // Recording: the accent, because it is moving.
                            StatusDot(state: .running(1))
                            Text(duration)
                                .typeStyle(.data)
                                .foregroundStyle(Palette.ink)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }

                    Spacer()

                    overlay {
                        VStack(alignment: .trailing, spacing: 4) {
                            counter("Poses", model.poseCount)
                            counter("Frames", model.frameCount)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }

                Spacer()

                if let tracking = model.tracking {
                    overlay {
                        StatusLabel(state: tracking.dot, text: tracking.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }

                Button("Stop and upload") {
                    Task { await model.stopAndUpload(preset: preset) }
                }
                .buttonStyle(.primary)

                MonoLabel("Preset \(preset.rawValue)")
            }
            .padding(Hairline.margin)
        }
        .environment(\.colorScheme, .dark)
    }

    /// "1:05".
    private var duration: String {
        let seconds = Int(model.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func counter(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 8) {
            MonoLabel(label)
            Text(value.formatted())
                .typeStyle(.data)
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
    }

    private func overlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(Palette.paper.opacity(Self.overlayOpacity), in: Hairline.shape)
            .overlay(Hairline.shape.strokeBorder(Palette.rule, lineWidth: Hairline.rule))
    }
}
