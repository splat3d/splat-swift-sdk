import SwiftUI
import ARKit
import SceneKit
import Splat3D

// MARK: - Splat3D Integration: Configuration
//
// 1. The app holds no API key. The user signs in on splat-3d.com and the app
//    gets a key made for this device, kept in the Keychain (AccountSession.swift).
//    Each screen's model builds its own SplatClient from those credentials.
// 2. The SDK entry points used in this app:
//    - SplatScanner  — captures video + ARKit poses (CaptureModel.swift)
//    - SplatClient   — uploads and processes via the Splat API, resumes an
//                      interrupted run without paying twice, fetches the
//                      thumbnail and deletes (CaptureModel.swift); lists and
//                      deletes scenes (RecentScenesView.swift) and downloads
//                      their SPZ (SceneViewer.swift); reads the month's usage
//                      (AccountSession.swift)
//    - ARKitPose     — pose format sent to the API (handled internally by
//                      SplatScanner, and saved by CaptureStore.swift)
// 3. SplatKit (github.com/Xget7/splatkit-ios, MIT) draws the downloaded scene
//    natively: see SplatWorldView.swift.

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
    /// A complete scene, for the viewer and its info sheet.
    case viewer(SplatScene)

    // SplatScene is Equatable but not Hashable. Equal scenes share an ID,
    // so hashing the ID keeps equal routes' hashes equal.
    func hash(into hasher: inout Hasher) {
        switch self {
        case .recentScenes:
            // No payload: every such route is equal.
            break
        case .viewer(let scene):
            hasher.combine(scene.id)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {

    let credentials: AccountSession.APICredentials
    let session: AccountSession

    @StateObject private var model: CaptureModel
    @StateObject private var connectivity = Connectivity()

    init(credentials: AccountSession.APICredentials, session: AccountSession) {
        self.credentials = credentials
        self.session = session
        _model = StateObject(wrappedValue: CaptureModel(
            credentials: credentials,
            onKeyRejected: { [weak session] in session?.keyRejected(credentials) }
        ))
    }

    var body: some View {
        CaptureRoot(model: model, connectivity: connectivity, session: session, credentials: credentials)
    }
}

/// The app's screens for one capture model: scanning full screen, and every
/// other state on a navigation stack with Scenes and the viewer.
struct CaptureRoot: View {

    @ObservedObject var model: CaptureModel
    @ObservedObject var connectivity: Connectivity
    let session: AccountSession
    /// `nil` in previews, which reach no API.
    let credentials: AccountSession.APICredentials?

    @State private var showsAccount = false

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
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    showsAccount = true
                                } label: {
                                    Label("Account", systemImage: ToolbarSymbol.named("person"))
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink(value: Route.recentScenes) {
                                    Label("Scenes", systemImage: "square.stack.3d.up")
                                }
                            }
                        }
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .recentScenes:
                                RecentScenesView(credentials: credentials, onKeyRejected: keyRejected)
                            case .viewer(let scene):
                                SceneViewerScreen(scene: scene, credentials: credentials, onKeyRejected: keyRejected)
                            }
                        }
                        .sheet(isPresented: $showsAccount) {
                            AccountView(session: session, runIsActive: model.isRunActive)
                        }
                }
            }
        }
        // initial: a launch that finds a run the app was killed in resumes it.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.appBecameActive()
                Task { await session.refresh() }
            }
        }
        // A run that ended may have spent credits or a scene of the month.
        .onChange(of: model.isRunActive) { _, active in
            if !active {
                Task { await session.refresh() }
            }
        }
        .onChange(of: connectivity.isOnline) { _, online in
            if online {
                model.networkReturned()
            }
        }
    }

    private func keyRejected() {
        guard let credentials else {
            return
        }
        session.keyRejected(credentials)
    }

    @ViewBuilder
    private var screen: some View {
        switch model.state {
        case .idle, .scanning:
            HomeView(model: model, session: session, preset: $preset)
        case .running(let progress):
            RunningView(progress: progress, thumbnail: model.thumbnail, isOnline: connectivity.isOnline)
        case .paused(let paused):
            PausedView(
                paused: paused,
                showsPurchaseLinks: session.showsPurchaseLinks,
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
    let session: AccountSession
    @Binding var preset: ScenePreset

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var rules: CaptureRules {
        CaptureRules(account: session.account, usage: session.usage, preset: preset)
    }

    var body: some View {
        // Titled by what it does: the app's name is on the Home Screen.
        Screen(
            title: "Capture",
            titleDisplay: .large,
            lead: "Walk slowly around what you want to keep, for at least \(CaptureLength.minimumText). Splat Capture records video and ARKit camera poses, and Splat3D turns them into a Gaussian splat scene."
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
            rulesNotices

            Section {
                presetRows
            } header: {
                Text("Preset")
            } footer: {
                Text(preset == .fast ? "The quickest and cheapest: good for trying things out." : "Higher presets take longer and cost more credits.")
            }

            Section("Requirements") {
                FactRow(label: "LiDAR") {
                    StatusLabel(state: model.hasLiDAR ? .done : .failed, text: model.hasLiDAR ? "Ready" : "Not on this device")
                }
                FactRow(label: "Camera") {
                    StatusLabel(state: cameraDot, text: cameraText)
                }
                FactRow(label: "Credits") {
                    Text(creditsText)
                }
            }
        } actions: {
            // Scenes is in the toolbar.
            Button("Start capture") {
                Task { await model.startScan() }
            }
            .actionStyle(.primary)
            .disabled(!canCapture)
        }
    }

    /// The preset control and what the preset means. At accessibility sizes
    /// the segments truncate, so each preset is a row, the chosen one
    /// checked, as in Settings.
    @ViewBuilder
    private var presetRows: some View {
        if dynamicTypeSize.isAccessibilitySize {
            presetPicker
                .pickerStyle(.inline)
                .labelsHidden()
            presetSummary
        } else {
            VStack(alignment: .leading, spacing: 12) {
                presetPicker
                    .pickerStyle(.segmented)
                presetSummary
            }
            .padding(.vertical, 4)
        }
    }

    private var presetPicker: some View {
        Picker("Preset", selection: $preset) {
            ForEach(ScenePreset.allCases, id: \.self) { option in
                Text(label(of: option))
                    .tag(option)
            }
        }
    }

    /// Rows have room for the cost; segments only for the title.
    private func label(of option: ScenePreset) -> String {
        guard dynamicTypeSize.isAccessibilitySize,
              let credits = session.account?.presets.first(where: { $0.preset == option })?.credits else {
            return option.title
        }
        return "\(option.title) · \(credits) credits"
    }

    /// "800 px · 3K iterations · about 3 min · 10 credits".
    private var presetSummary: some View {
        Text(rules.cost.map { "\(preset.summary) · \($0) credits" } ?? preset.summary)
            .typeStyle(.data)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cameraDenied: Bool {
        model.cameraAccess == .denied || model.cameraAccess == .restricted
    }

    private var canCapture: Bool {
        model.hasLiDAR && !cameraDenied && !rules.blocksStart
    }

    /// "120 credits", or a dash until the account has loaded.
    private var creditsText: String {
        guard let account = session.account else {
            return "—"
        }
        return "\(account.creditBalance.formatted()) credits"
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
        if !model.hasLiDAR {
            NoticeCard(
                tone: .neutral,
                title: "This device has no LiDAR scanner",
                detail: "Capture needs one: an iPhone 12 Pro or newer, or an iPad Pro with LiDAR. Your scenes still open here, in 3D."
            )
        } else if cameraDenied {
            NoticeCard(
                tone: .alarm,
                title: "Camera access is off",
                detail: "Splat Capture records video to build the scene. Turn on Camera for Splat Capture in Settings."
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

    /// What the account says about this capture: why Start is off, or a
    /// warning with Start on.
    @ViewBuilder
    private var rulesNotices: some View {
        if let block = rules.block {
            NoticeCard(tone: .alarm, title: block.title, detail: block.detail) {
                if case .credits = block, session.showsPurchaseLinks {
                    Link("Add credits", destination: AppEnvironment.billingURL)
                        .actionStyle(.secondary, width: .fitted)
                }
            }
        }
        if let warning = rules.warning {
            NoticeCard(tone: .neutral, title: "Scenes are processing", detail: warning)
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
    /// Set by Stop before CaptureLength.minimum: keep recording or discard.
    @State private var confirmingShortStop = false
    /// The scan's length when that Stop was tapped; recording goes on under the dialog.
    @State private var shortStopAt: TimeInterval = 0

    #if DEBUG
    @Environment(\.previewBackdrop) private var previewBackdrop
    #endif

    /// Space between glass surfaces; closer ones blend on iOS 26.
    private static let glassSpacing: CGFloat = 12
    private static let recordingDot: CGFloat = 10

    var body: some View {
        ZStack {
            if let session = model.arSession {
                ARCameraView(session: session)
                    .ignoresSafeArea()
            } else {
                cameraStandIn
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        // A capsule, as the timer beside it.
                        .glassSurface(in: Capsule())
                    }
                }

                Spacer()

                GlassGroup(spacing: Self.glassSpacing) {
                    VStack(spacing: Self.glassSpacing) {
                        readout

                        // Side by side, the same width; stacked when the
                        // text is too large. Style, not size, marks Stop
                        // and upload as the one to take.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Self.glassSpacing) {
                                cancelButton
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
            // Stop came before the API's minimum. Keep recording leaves the
            // scan running; Discard throws it away as Cancel does.
            .confirmationDialog("Keep recording?", isPresented: $confirmingShortStop, titleVisibility: .visible) {
                Button("Keep recording", role: .cancel) {}
                Button("Discard scan", role: .destructive) {
                    isStopping = true
                    Task { await model.cancelScan() }
                }
            } message: {
                Text("Still recording. You tapped Stop at \(clock(shortStopAt)). Splat3D needs at least \(CaptureLength.minimumText) of video to build a scene. Discarding deletes the video and poses: nothing is uploaded or charged.")
            }
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

    /// Black until ARKit's camera starts. Debug previews can put a bright
    /// room there instead, to check the glass over a light picture.
    @ViewBuilder
    private var cameraStandIn: some View {
        #if DEBUG
        if previewBackdrop == .brightRoom {
            BrightRoom()
        } else {
            Color.black
                .ignoresSafeArea()
        }
        #else
        Color.black
            .ignoresSafeArea()
        #endif
    }

    /// ARKit's tracking and the preset in one line, "● Tracking well · Fast",
    /// smaller than the buttons under it: something to read, not to tap.
    private var readout: some View {
        Group {
            if let tracking = model.tracking {
                StatusLabel(state: tracking.dot, text: "\(tracking.text) · \(preset.title)")
            } else {
                Text("\(preset.title) preset")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassSurface(in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var stopButton: some View {
        Button("Stop and upload") {
            // The timer on screen decides: under the minimum, the API would
            // refuse the video, so ask instead of uploading.
            switch CaptureLength.stopAction(after: model.elapsed) {
            case .ask:
                shortStopAt = model.elapsed
                confirmingShortStop = true
            case .upload:
                isStopping = true
                Task { await model.stopAndUpload(preset: preset) }
            }
        }
        .actionStyle(.primary)
        .disabled(isStopping)
    }

    /// A scan you don't want ends here, not as a scene.
    private var cancelButton: some View {
        Button("Cancel") {
            confirmingCancel = true
        }
        .actionStyle(.secondary)
        .disabled(isStopping)
    }

    /// "1:05".
    private var duration: String {
        clock(model.elapsed)
    }

    /// "1:05" for 65 seconds.
    private func clock(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
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
