import SwiftUI
import Splat3D

// MARK: - Run screens
//
// One screen per CaptureState after the scan: running, paused, failed and
// complete. Each ends with the SDK call behind it.

/// Where to add credits: the billing page of the Splat3D dashboard.
let billingURL = URL(string: "https://splat-3d.com/dashboard/settings/billing")!

/// A screen: eyebrow (with the scene's ID once it has one), headline, lead,
/// then its content, on paper.
struct Screen<Content: View>: View {
    let eyebrow: String
    /// A dot before the eyebrow, for a screen that is a status: Failed.
    var status: DotState?
    var sceneID: String?
    let title: String
    let lead: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let status {
                            StatusDot(state: status)
                        }
                        MonoLabel(sceneID == nil ? eyebrow : "\(eyebrow) · scene")
                        // IDs are case sensitive: not in the label's capitals.
                        if let sceneID {
                            Text(sceneID)
                                .typeStyle(.code)
                                .foregroundStyle(Palette.graphite)
                                .textSelection(.enabled)
                        }
                    }
                    Text(title)
                        .typeStyle(.display)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lead {
                        Text(lead)
                            .typeStyle(.body)
                            .foregroundStyle(Palette.graphite)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(Hairline.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.paper)
    }
}

/// A thin accent bar over a rule, for progress that is moving.
struct HairlineProgress: View {
    /// What is moving, for VoiceOver: "Upload".
    let label: String
    /// 0...1.
    let fraction: Double

    private static let height: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Palette.rule
                Palette.accent
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: Self.height)
        .animation(.easeOut, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}

// Snippets keep to about 40 columns, the width of a phone in portrait.

/// The catch ladder of a reference integration.
private let recoveryCall = """
    do {
        scene = try await client
            .createAndProcess(videoURL: url)
    } catch SplatError.interrupted(let stop) {
        // Never pays twice.
        scene = try await client.resume(stop)
    } catch SplatError.processingFailed {
        // Final. The server refunds it.
    }
    """

/// The call that starts a run, with the run's preset, as CaptureModel makes it.
private func createCall(_ preset: ScenePreset) -> String {
    """
    let scene = try await client
        .createAndProcess(
            videoURL: capture.videoURL,
            preset: .\(preset.rawValue),
            arkitPoses: capture.poses,
            lidarPoints: capture.lidarPoints
        ) { status, percent in
            print(status, percent ?? 0)
        }
    """
}

// MARK: - Running

struct RunningView: View {
    let progress: RunProgress
    let preset: ScenePreset
    let thumbnail: UIImage?
    let isOnline: Bool

    private static let percent: Double = 100
    private static let previewHeight: CGFloat = 200

    var body: some View {
        Screen(eyebrow: "Running", sceneID: progress.sceneID, title: title, lead: lead) {
            Panel {
                StepRow(name: "Save capture", state: state(of: .saving), detail: progress.step > .saving ? "Done" : "")
                Rule()
                StepRow(name: "Upload", state: state(of: .uploading), detail: uploadDetail)
                Rule()
                StepRow(name: "Launch", state: state(of: .launching), detail: launchDetail)
                Rule()
                StepRow(name: "Process", note: processNote, state: state(of: .processing), detail: processDetail)
                Rule()
                StepRow(name: "Ready", state: .waiting, detail: "")
            }

            if let fraction {
                HairlineProgress(label: progress.step == .uploading ? "Upload" : "Processing", fraction: fraction)
            }

            if !isOnline {
                NoticeBox(
                    tone: .neutral,
                    title: "You're offline",
                    detail: "A job that started keeps running on the server. SplatCapture catches up when you're back online."
                )
            }

            if let thumbnail {
                Panel {
                    MonoLabel("Preview")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    Rule()
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: Self.previewHeight)
                        .padding(10)
                }
            }

            APICallBlock(code: createCall(preset))
        }
    }

    private var title: String {
        switch progress.step {
        case .saving:
            return "Saving the capture"
        case .uploading:
            return "Uploading"
        case .launching:
            return "Starting processing"
        case .processing:
            return "Processing"
        }
    }

    private var lead: String {
        switch progress.step {
        case .saving, .uploading:
            return "Keep SplatCapture open until the upload is done. If you leave, it pauses, and picks up when you're back."
        case .launching:
            return "Splat3D checks the upload and starts a GPU job. A launch sent twice is still charged once."
        case .processing:
            return "This runs on Splat3D's GPUs. You can leave the app: it checks in again when you come back."
        }
    }

    private func state(of step: RunProgress.Step) -> DotState {
        if progress.step > step {
            return .done
        }
        guard progress.step == step else {
            return .waiting
        }
        switch step {
        case .uploading:
            return .running(uploadFraction ?? 0)
        case .processing:
            return .running((progress.percent ?? 0) / Self.percent)
        default:
            return .running(0)
        }
    }

    private var uploadFraction: Double? {
        guard let total = progress.bytesTotal, total > 0 else {
            return nil
        }
        return Double(progress.bytesSent) / Double(total)
    }

    private var fraction: Double? {
        switch progress.step {
        case .uploading:
            return uploadFraction
        case .processing:
            return progress.percent.map { $0 / Self.percent }
        default:
            return nil
        }
    }

    private var uploadDetail: String {
        if progress.step > .uploading {
            return "Done"
        }
        guard progress.step == .uploading else {
            return ""
        }
        let sent = progress.bytesSent.formatted(.byteCount(style: .file))
        guard let total = progress.bytesTotal else {
            return progress.bytesSent > 0 ? sent : "Starting"
        }
        return "\(sent) of \(total.formatted(.byteCount(style: .file)))"
    }

    private var launchDetail: String {
        if progress.step > .launching {
            return "Accepted"
        }
        return progress.step == .launching ? "Sending" : ""
    }

    /// The status in words; any status the app doesn't know reads "Working".
    private var processNote: String? {
        progress.step == .processing ? progress.status?.displayName : nil
    }

    /// The raw status and percent, e.g. "training · 42%".
    private var processDetail: String {
        guard progress.step == .processing, let status = progress.status else {
            return ""
        }
        guard let percent = progress.percent else {
            return status.rawValue
        }
        return "\(status.rawValue) · \(Int(percent))%"
    }
}

/// One step of a run: dot, name, optional note, and a mono detail.
private struct StepRow: View {
    let name: String
    var note: String?
    let state: DotState
    let detail: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .typeStyle(.body)
                    .foregroundStyle(state == .waiting ? Palette.graphite : Palette.ink)
                if let note {
                    Text(note)
                        .typeStyle(.footnote)
                        .foregroundStyle(Palette.graphite)
                }
                // At accessibility sizes there is no room beside the name:
                // the detail goes under it, whole.
                if dynamicTypeSize.isAccessibilitySize, !detail.isEmpty {
                    detailText
                }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize {
                detailText
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var detailText: some View {
        Text(detail)
            .typeStyle(.data)
            .foregroundStyle(Palette.graphite)
    }
}

// MARK: - Paused

struct PausedView: View {
    let paused: PausedRun
    let preset: ScenePreset
    let isOnline: Bool
    let onResume: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    /// A connection pause can't resume offline. CaptureRoot resumes it when
    /// the network is back.
    private var waitsForNetwork: Bool {
        paused.cause == .connection && !isOnline
    }

    /// Credits are what's missing, so adding them is the one action.
    private var needsCredits: Bool {
        if case .insufficientCredits = paused.cause {
            return true
        }
        return false
    }

    var body: some View {
        Screen(eyebrow: "Paused", sceneID: paused.sceneID, title: paused.title, lead: paused.detail) {
            Panel {
                FactRow(label: "Stopped at") {
                    Text(stoppedAt)
                        .typeStyle(.data)
                        .foregroundStyle(Palette.ink)
                }
                Rule()
                FactRow(label: "Charges") {
                    Text(paused.charges)
                        .typeStyle(.footnote)
                        .foregroundStyle(Palette.ink)
                }
                Rule()
                FactRow(label: "Network") {
                    StatusLabel(state: isOnline ? .done : .failed, text: isOnline ? "Online" : "Offline")
                }
            }

            VStack(spacing: 10) {
                if needsCredits {
                    Link("Add credits", destination: billingURL)
                        .buttonStyle(.primary)
                }
                Button("Resume", action: onResume)
                    .buttonStyle(HairlineButtonStyle(variant: needsCredits ? .ghost : .primary))
                    .disabled(waitsForNetwork)
                if waitsForNetwork {
                    Text("Resumes by itself when you're back online.")
                        .typeStyle(.footnote)
                        .foregroundStyle(Palette.graphite)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The plan's monthly limit: billing is where the plan changes.
                if case .quotaExceeded = paused.cause {
                    Link("Open billing", destination: billingURL)
                        .buttonStyle(.ghost)
                }
                Button("Discard capture") {
                    confirmingDiscard = true
                }
                .buttonStyle(.destructive)
            }
            .confirmationDialog("Discard this capture?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard capture", role: .destructive, action: onDiscard)
            } message: {
                Text("The video and poses on this phone are deleted. A scene already created stays in Scenes.")
            }

            APICallBlock(code: call)
        }
    }

    /// The call Resume makes (CaptureModel.resume).
    private var call: String {
        if paused.interruption != nil {
            return recoveryCall
        }
        // The scene was never created: Resume starts the run over.
        guard paused.sceneID != nil else {
            return createCall(preset)
        }
        return relaunchCall
    }

    /// The step that stopped. After a relaunch, SplatCapture doesn't know,
    /// and resume works it out.
    private var stoppedAt: String {
        guard paused.sceneID != nil else {
            return "Creating the scene"
        }
        guard let phase = paused.phase else {
            return "Unknown: the app closed"
        }
        if phase == .upload {
            return "Upload"
        }
        if phase == .launch {
            return "Launch"
        }
        if phase == .wait {
            return "Processing"
        }
        return phase.rawValue
    }

    private var relaunchCall: String {
        """
        // After a relaunch, from what you saved:
        scene = try await client.resume(
            sceneID: savedID, preset: .\(preset.rawValue),
            arkitPoses: saved.poses,
            lidarPoints: saved.points)
        """
    }
}

// MARK: - Failed

struct FailedView: View {
    let failed: FailedRun
    let onUploadAgain: () -> Void
    let onProcessAgain: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        Screen(eyebrow: "Failed", status: .failed, sceneID: failed.sceneID, title: failed.title, lead: failed.detail) {
            if let charges = failed.charges {
                Panel {
                    FactRow(label: "Charges") {
                        Text(charges)
                            .typeStyle(.footnote)
                            .foregroundStyle(Palette.ink)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                switch failed.retry {
                case .uploadAgain:
                    Button("Upload again", action: onUploadAgain)
                        .buttonStyle(.primary)
                    Text("Sends the saved capture to a new scene and deletes this one. Nothing is charged until it launches.")
                        .typeStyle(.footnote)
                        .foregroundStyle(Palette.graphite)
                case .processAgain:
                    Button("Process again", action: onProcessAgain)
                        .buttonStyle(.primary)
                    Text("Creates a new scene from the saved capture, and charges it.")
                        .typeStyle(.footnote)
                        .foregroundStyle(Palette.graphite)
                case .impossible:
                    EmptyView()
                }

                if failed.retry == .impossible {
                    Button("New capture", action: onDiscard)
                        .buttonStyle(.primary)
                } else {
                    Button("Discard capture", action: onDiscard)
                        .buttonStyle(.destructive)
                }
            }

            APICallBlock(code: recoveryCall)
        }
    }
}

// MARK: - Complete

struct CompleteView: View {
    let scene: SplatScene
    let thumbnail: UIImage?
    let isDeleting: Bool
    let deleteError: String?
    let onDelete: () -> Void
    let onNewCapture: () -> Void

    @State private var confirmingDelete = false

    private static let thumbnailAspect: CGFloat = 4 / 3

    var body: some View {
        Screen(eyebrow: "Ready", sceneID: scene.id, title: "Your scene is ready", lead: scene.displayTitle) {
            preview

            Panel {
                FactRow(label: "Splats") {
                    Text(scene.numGaussians.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                        .typeStyle(.data)
                        .foregroundStyle(Palette.ink)
                }
                Rule()
                FactRow(label: "Status") {
                    StatusLabel(state: .done, text: scene.status.displayName)
                }
                Rule()
                FactRow(label: "Created") {
                    Text(scene.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .typeStyle(.data)
                        .foregroundStyle(Palette.ink)
                }
            }

            // Above the buttons, so a failed delete shows where you tapped.
            if let deleteError {
                NoticeBox(tone: .alarm, title: "Couldn't delete", detail: deleteError)
            }

            VStack(spacing: 10) {
                NavigationLink(value: Route.viewer(sceneID: scene.id, title: scene.displayTitle, webURL: scene.viewerURL)) {
                    Text("View in 3D")
                }
                .buttonStyle(.primary)

                if let viewerURL = scene.viewerURL {
                    Link("Open on splat-3d.com", destination: viewerURL)
                        .buttonStyle(.ghost)
                }

                Button("New capture", action: onNewCapture)
                    .buttonStyle(.ghost)

                Button(isDeleting ? "Deleting…" : "Delete scene") {
                    confirmingDelete = true
                }
                .buttonStyle(.destructive)
                .disabled(isDeleting)
            }
            .confirmationDialog("Delete this scene?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete scene", role: .destructive, action: onDelete)
            } message: {
                Text("Its model, video and thumbnail are deleted for good.")
            }

            APICallBlock(code: """
                let spz = try await client
                    .downloadScene(id: id, format: .spz)
                let image = try await client
                    .getSceneThumbnail(id: id)
                try await client.deleteScene(id: id)
                """)
        }
    }

    private var preview: some View {
        ThumbnailPlaceholder()
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .aspectRatio(Self.thumbnailAspect, contentMode: .fit)
            .clipShape(Hairline.shape)
            .overlay(Hairline.shape.strokeBorder(Palette.rule, lineWidth: Hairline.rule))
    }
}
