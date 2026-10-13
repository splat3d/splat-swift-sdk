import SwiftUI
import Splat3D

// MARK: - Run screens
//
// One screen per CaptureState after the scan: running, paused, failed and
// complete.

/// Where to add credits: the billing page of the Splat3D dashboard.
let billingURL = URL(string: "https://splat-3d.com/dashboard/settings/billing")!

/// A screen on the grouped ground: a navigation title, a headline in
/// Hanken, a lead, the scene's ID once it has one, then its content.
struct Screen<Content: View>: View {
    /// The navigation bar's title: where the run is, such as "Paused".
    let title: String
    var titleDisplay = NavigationBarItem.TitleDisplayMode.inline
    /// A dot before the scene's ID, for a screen that is a status: Failed.
    var status: DotState?
    var sceneID: String?
    let headline: String
    let lead: String?
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline)
                        .typeStyle(.display)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lead {
                        Text(lead)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let sceneID {
                        sceneLine(sceneID)
                    }
                }
                content
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.ground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(titleDisplay)
    }

    /// "Scene a1b2c3d4e5f6". At accessibility sizes the ID goes under the
    /// word: side by side, both broke mid-word.
    private func sceneLine(_ sceneID: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let status {
                    StatusDot(state: status)
                }
                Text("Scene")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(sceneID)
                .typeStyle(.smallData)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.top, 2)
    }
}

/// The system's progress bar in the accent, for progress that is moving.
struct RunProgressBar: View {
    /// What is moving, for VoiceOver: "Upload".
    let label: String
    /// 0...1.
    let fraction: Double

    var body: some View {
        ProgressView(value: min(max(fraction, 0), 1))
            .tint(Palette.accent)
            .animation(.easeOut, value: fraction)
            .accessibilityLabel(Text(label))
    }
}

// MARK: - Running

struct RunningView: View {
    let progress: RunProgress
    let thumbnail: UIImage?
    let isOnline: Bool

    private static let percent: Double = 100
    private static let previewHeight: CGFloat = 200
    private static let previewCorner: CGFloat = 14

    var body: some View {
        Screen(title: "Running", sceneID: progress.sceneID, headline: title, lead: lead) {
            VStack(spacing: 12) {
                Card {
                    StepRow(name: "Save capture", state: state(of: .saving), detail: progress.step > .saving ? "Done" : "")
                    CardDivider()
                    StepRow(name: "Upload", state: state(of: .uploading), detail: uploadDetail)
                    CardDivider()
                    StepRow(name: "Launch", state: state(of: .launching), detail: launchDetail)
                    CardDivider()
                    StepRow(name: "Process", note: processNote, state: state(of: .processing), detail: processDetail)
                    CardDivider()
                    StepRow(name: "Ready", state: .waiting, detail: "")
                }

                if let fraction {
                    RunProgressBar(label: progress.step == .uploading ? "Upload" : "Processing", fraction: fraction)
                        .padding(.horizontal, Theme.rowInset)
                }
            }

            if !isOnline {
                NoticeCard(
                    tone: .neutral,
                    title: "You're offline",
                    detail: "A job that started keeps running on the server. SplatCapture catches up when you're back online."
                )
            }

            if let thumbnail {
                CardSection(header: "Preview") {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Self.previewCorner, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: Self.previewHeight)
                        .padding(10)
                }
            }
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
        // At accessibility sizes the dot sits by the name: centred, it fell
        // beside whichever line of the stacked note and detail was midway.
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .firstTextBaseline : .center, spacing: 10) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(state == .waiting ? .secondary : .primary)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        .frame(minHeight: Theme.touchTarget)
        .padding(.horizontal, Theme.rowInset)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var detailText: some View {
        Text(detail)
            .typeStyle(.data)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Paused

struct PausedView: View {
    let paused: PausedRun
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
        Screen(title: "Paused", sceneID: paused.sceneID, headline: paused.title, lead: paused.detail) {
            Card {
                FactRow(label: "Stopped at") {
                    Text(stoppedAt)
                }
                CardDivider()
                FactRow(label: "Charges") {
                    Text(paused.charges)
                }
                CardDivider()
                FactRow(label: "Network") {
                    StatusLabel(state: isOnline ? .done : .failed, text: isOnline ? "Online" : "Offline")
                }
            }

            VStack(spacing: 12) {
                if needsCredits {
                    Link("Add credits", destination: billingURL)
                        .actionStyle(.primary)
                }
                Button("Resume", action: onResume)
                    .actionStyle(needsCredits ? .secondary : .primary)
                    .disabled(waitsForNetwork)
                if waitsForNetwork {
                    Text("Resumes by itself when you're back online.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                // The plan's monthly limit: billing is where the plan changes.
                if case .quotaExceeded = paused.cause {
                    Link("Open billing", destination: billingURL)
                        .actionStyle(.secondary)
                }
                Button("Discard capture", role: .destructive) {
                    confirmingDiscard = true
                }
                .actionStyle(.destructive)
            }
            .confirmationDialog("Discard this capture?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard capture", role: .destructive, action: onDiscard)
            } message: {
                Text("The video and poses on this phone are deleted. A scene already created stays in Scenes.")
            }
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
}

// MARK: - Failed

struct FailedView: View {
    let failed: FailedRun
    let onUploadAgain: () -> Void
    let onProcessAgain: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        Screen(title: "Failed", status: .failed, sceneID: failed.sceneID, headline: failed.title, lead: failed.detail) {
            if let charges = failed.charges {
                Card {
                    FactRow(label: "Charges") {
                        Text(charges)
                    }
                }
            }

            VStack(spacing: 12) {
                switch failed.retry {
                case .uploadAgain:
                    Button("Upload again", action: onUploadAgain)
                        .actionStyle(.primary)
                    note("Sends the saved capture to a new scene and deletes this one. Nothing is charged until it launches.")
                case .processAgain:
                    Button("Process again", action: onProcessAgain)
                        .actionStyle(.primary)
                    note("Creates a new scene from the saved capture, and charges it.")
                case .impossible:
                    EmptyView()
                }

                if failed.retry == .impossible {
                    Button("New capture", action: onDiscard)
                        .actionStyle(.primary)
                    // Say so, as Upload again does: the scene goes too.
                    if failed.leftoverScene == .delete {
                        note("Also deletes this scene, which was never launched or charged.")
                    }
                } else {
                    Button("Discard capture", role: .destructive, action: onDiscard)
                        .actionStyle(.destructive)
                }
            }
        }
    }

    /// What the button above does, under it.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
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
        Screen(title: "Ready", sceneID: scene.id, headline: "Your scene is ready", lead: scene.displayTitle) {
            preview

            Card {
                FactRow(label: "Splats") {
                    Text(scene.numGaussians.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                        .typeStyle(.data)
                }
                CardDivider()
                FactRow(label: "Status") {
                    StatusLabel(state: .done, text: scene.status.displayName)
                }
                CardDivider()
                FactRow(label: "Created") {
                    Text(scene.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            // Above the buttons, so a failed delete shows where you tapped.
            if let deleteError {
                NoticeCard(tone: .alarm, title: "Couldn't delete", detail: deleteError)
            }

            VStack(spacing: 12) {
                NavigationLink(value: Route.viewer(sceneID: scene.id, title: scene.displayTitle, webURL: scene.viewerURL)) {
                    Text("View in 3D")
                }
                .actionStyle(.primary)

                if let viewerURL = scene.viewerURL {
                    Link("Open on splat-3d.com", destination: viewerURL)
                        .actionStyle(.secondary)
                }

                Button("New capture", action: onNewCapture)
                    .actionStyle(.secondary)

                Button(isDeleting ? "Deleting…" : "Delete scene", role: .destructive) {
                    confirmingDelete = true
                }
                .actionStyle(.destructive)
                .disabled(isDeleting)
            }
            .confirmationDialog("Delete this scene?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete scene", role: .destructive, action: onDelete)
            } message: {
                Text("Its model, video and thumbnail are deleted for good.")
            }
        }
    }

    private var preview: some View {
        ThumbnailPlaceholder(style: .mark)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .aspectRatio(Self.thumbnailAspect, contentMode: .fit)
            .clipShape(Theme.cardShape)
    }
}
