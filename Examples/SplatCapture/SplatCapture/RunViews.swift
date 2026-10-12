import SwiftUI
import Splat3D

// MARK: - Run screens
//
// One screen per CaptureState after the scan: running, paused, failed and
// complete. Each ends with the SDK call behind it.

/// Where to add credits: the billing page of the Splat3D dashboard.
let billingURL = URL(string: "https://splat-3d.com/dashboard/settings/billing")!

/// A screen: eyebrow, headline, lead, then its content, on paper.
struct Screen<Content: View>: View {
    let eyebrow: String
    let title: String
    let lead: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel(eyebrow)
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
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}

/// "Scene a1b2c3d4e5f6", or a stand-in before the scene exists.
private func sceneLabel(_ prefix: String, _ sceneID: String?) -> String {
    guard let sceneID else {
        return prefix
    }
    return "\(prefix) · scene \(sceneID)"
}

/// The catch ladder of a reference integration.
private let recoveryCall = """
    do {
        scene = try await client.createAndProcess(videoURL: video, preset: .fast,
                                                  arkitPoses: poses, lidarPoints: points)
    } catch SplatError.interrupted(let interruption) {
        scene = try await client.resume(interruption)   // never pays twice
    } catch SplatError.processingFailed(let reason) {
        // Final: the server failed the scene and refunds it.
    }
    """

// MARK: - Running

struct RunningView: View {
    let progress: RunProgress
    let thumbnail: UIImage?
    let isOnline: Bool

    private static let percent: Double = 100
    private static let previewHeight: CGFloat = 200

    var body: some View {
        Screen(eyebrow: sceneLabel("Running", progress.sceneID), title: title, lead: lead) {
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
                HairlineProgress(fraction: fraction)
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

            APICallBlock(code: """
                let scene = try await client.createAndProcess(
                    videoURL: capture.videoURL, preset: .fast,
                    arkitPoses: capture.poses, lidarPoints: capture.lidarPoints
                ) { status, percent in
                    print(status.rawValue, percent ?? 0)
                }
                """)
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
            }
            Spacer(minLength: 8)
            Text(detail)
                .typeStyle(.data)
                .foregroundStyle(Palette.graphite)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Paused

struct PausedView: View {
    let paused: PausedRun
    let isOnline: Bool
    let onResume: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        Screen(eyebrow: sceneLabel("Paused", paused.sceneID), title: paused.title, lead: paused.detail) {
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
                Button("Resume", action: onResume)
                    .buttonStyle(.primary)
                if case .insufficientCredits = paused.cause {
                    Link("Add credits", destination: billingURL)
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

            APICallBlock(code: paused.interruption == nil ? Self.relaunchCall : recoveryCall)
        }
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

    private static let relaunchCall = """
        // After a relaunch, with the ID onSceneCreated passed and the saved capture:
        scene = try await client.resume(sceneID: savedID, preset: .fast,
                                        arkitPoses: saved.poses, lidarPoints: saved.points)
        """
}

// MARK: - Failed

struct FailedView: View {
    let failed: FailedRun
    let onUploadAgain: () -> Void
    let onProcessAgain: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        Screen(eyebrow: sceneLabel("Failed", failed.sceneID), title: failed.title, lead: failed.detail) {
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
        Screen(eyebrow: sceneLabel("Ready", scene.id), title: "Your scene is ready", lead: scene.displayTitle) {
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

            VStack(spacing: 10) {
                NavigationLink(value: Route.viewer(sceneID: scene.id, title: scene.displayTitle)) {
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

            if let deleteError {
                NoticeBox(tone: .alarm, title: "Couldn't delete", detail: deleteError)
            }

            APICallBlock(code: """
                let spz = try await client.downloadScene(id: scene.id, format: .spz)
                let jpeg = try await client.getSceneThumbnail(id: scene.id)
                try await client.deleteScene(id: scene.id)
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
