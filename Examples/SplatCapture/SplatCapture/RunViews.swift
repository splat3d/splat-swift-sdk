import SwiftUI
import Splat3D

// MARK: - Run screens
//
// One screen per CaptureState after the scan: running, paused, failed and
// complete.

/// Where to add credits: the billing page of the Splat3D dashboard.
let billingURL = URL(string: "https://splat-3d.com/dashboard/settings/billing")!

/// A screen as an inset grouped list, so its margins and corners are the
/// system's: a navigation title, an optional headline in Hanken, a lead, the
/// scene's ID once it has one, then its sections. Its actions are pinned at
/// the foot, over the list, which scrolls under them.
struct Screen<Content: View, Actions: View>: View {
    /// The navigation bar's title: what the screen is for, or where the run
    /// is, such as "Paused".
    let title: String
    var titleDisplay = NavigationBarItem.TitleDisplayMode.inline
    /// A dot before the scene's ID, for a screen that is a status: Failed.
    var status: DotState?
    var sceneID: String?
    /// Beside a large title, none: the lead follows the title.
    var headline: String?
    let lead: String?
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            // A screen with nothing to do, such as Running, has no bar.
            if Actions.self == EmptyView.self {
                list
            } else {
                list.actionBar { actions }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(titleDisplay)
    }

    private var list: some View {
        List {
            // A section's header, not a row: on iOS 26 a row clips its
            // corners, which cut into the first and last letters.
            Section {
            } header: {
                header
                    // From the cards' edge: in line with the large title,
                    // and with the margin the cards have.
                    .listRowInsets(EdgeInsets())
                    .textCase(nil)
            }
            content
        }
        .listStyle(.insetGrouped)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let headline {
                Text(headline)
                    .typeStyle(.display)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lead {
                // What the screen says: body text in the primary color, not
                // a section header's.
                Text(lead)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sceneID {
                sceneLine(sceneID)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
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

extension Screen where Actions == EmptyView {
    /// A screen with no actions.
    init(
        title: String,
        titleDisplay: NavigationBarItem.TitleDisplayMode = .inline,
        status: DotState? = nil,
        sceneID: String? = nil,
        headline: String? = nil,
        lead: String?,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            titleDisplay: titleDisplay,
            status: status,
            sceneID: sceneID,
            headline: headline,
            lead: lead,
            content: content,
            actions: { EmptyView() }
        )
    }
}

/// What a button in a screen's action bar does, under it.
struct ActionNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        Screen(title: "Running", sceneID: progress.sceneID, headline: title, lead: lead) {
            Section {
                StepRow(name: "Save capture", state: state(of: .saving), detail: progress.step > .saving ? .words("Done") : nil)
                StepRow(name: "Upload", state: state(of: .uploading), detail: uploadDetail)
                StepRow(name: "Launch", state: state(of: .launching), detail: launchDetail)
                StepRow(name: "Process", note: processNote, state: state(of: .processing), detail: processDetail)
                StepRow(name: "Ready", state: .waiting, detail: nil)
            } footer: {
                if let fraction {
                    RunProgressBar(label: progress.step == .uploading ? "Upload" : "Processing", fraction: fraction)
                        .padding(.top, 4)
                }
            }

            if !isOnline {
                NoticeCard(
                    tone: .neutral,
                    title: "You're offline",
                    detail: "A job that started keeps running on the server. Splat Capture catches up when you're back online."
                )
            }

            if let thumbnail {
                Section("Preview") {
                    // Edge to edge: the list rounds it with the section.
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.previewHeight)
                        .clipped()
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Preview of the scene")
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
            return "Keep Splat Capture open until the upload is done. If you leave, it pauses, and picks up when you're back."
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
        // A ring while there is a measure of how far, a spinner until then.
        switch step {
        case .uploading:
            return uploadFraction.map { .running($0) } ?? .busy
        case .processing:
            return progress.percent.map { .running($0 / Self.percent) } ?? .busy
        default:
            return .busy
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

    private var uploadDetail: StepDetail? {
        if progress.step > .uploading {
            return .words("Done")
        }
        guard progress.step == .uploading else {
            return nil
        }
        let sent = progress.bytesSent.formatted(.byteCount(style: .file))
        guard let total = progress.bytesTotal else {
            return progress.bytesSent > 0 ? .data(sent) : .words("Starting")
        }
        return .data("\(sent) of \(total.formatted(.byteCount(style: .file)))")
    }

    private var launchDetail: StepDetail? {
        if progress.step > .launching {
            return .words("Accepted")
        }
        return progress.step == .launching ? .words("Sending") : nil
    }

    /// The status in words; any status the app doesn't know reads "Working".
    private var processNote: String? {
        progress.step == .processing ? progress.status?.displayName : nil
    }

    /// The percent, "42%", once the API sends one. The status is in the
    /// note, in words: the API's own name for it is for code, not people.
    private var processDetail: StepDetail? {
        guard progress.step == .processing, let percent = progress.percent else {
            return nil
        }
        return .data("\(Int(percent))%")
    }
}

/// A step's detail, beside its name: words in the system font, numbers in
/// mono.
private enum StepDetail {
    /// "Done", "Sending".
    case words(String)
    /// "48 MB of 112 MB", "42%".
    case data(String)
}

/// One step of a run: dot, name, optional note, and a detail.
private struct StepRow: View {
    let name: String
    var note: String?
    let state: DotState
    let detail: StepDetail?

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
                if dynamicTypeSize.isAccessibilitySize, let detail {
                    detailText(detail)
                }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize, let detail {
                detailText(detail)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func detailText(_ detail: StepDetail) -> some View {
        switch detail {
        case .words(let words):
            Text(words)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .data(let data):
            Text(data)
                .typeStyle(.data)
                .foregroundStyle(.secondary)
        }
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
            Section {
                FactRow(label: "Stopped at") {
                    Text(stoppedAt)
                }
                FactRow(label: "Charges", layout: .stacked) {
                    Text(paused.charges)
                }
                FactRow(label: "Network") {
                    StatusLabel(state: isOnline ? .done : .failed, text: isOnline ? "Online" : "Offline")
                }
            }
        } actions: {
            if needsCredits {
                Link("Add credits", destination: billingURL)
                    .actionStyle(.primary)
            }
            Button("Resume", action: onResume)
                .actionStyle(needsCredits ? .secondary : .primary)
                .disabled(waitsForNetwork)
            if waitsForNetwork {
                ActionNote("Resumes by itself when you're back online.")
            }
            // The plan's monthly limit: billing is where the plan changes.
            if case .quotaExceeded = paused.cause {
                Link("Open billing", destination: billingURL)
                    .actionStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MoreMenu {
                    Button(role: .destructive) {
                        confirmingDiscard = true
                    } label: {
                        Label("Discard capture", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Discard this capture?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive, action: onDiscard)
        } message: {
            Text("The video and poses on this phone are deleted. A scene already created stays in Scenes.")
        }
    }

    /// The step that stopped. After a relaunch, Splat Capture doesn't know,
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
        // A phase this app doesn't know: its raw name is for code.
        return "Unknown"
    }
}

// MARK: - Failed

struct FailedView: View {
    let failed: FailedRun
    let onUploadAgain: () -> Void
    let onProcessAgain: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        Screen(title: "Failed", status: .failed, sceneID: failed.sceneID, headline: failed.title, lead: failed.detail) {
            if let charges = failed.charges {
                Section {
                    FactRow(label: "Charges", layout: .stacked) {
                        Text(charges)
                    }
                }
            }
        } actions: {
            switch failed.retry {
            case .uploadAgain:
                Button("Upload again", action: onUploadAgain)
                    .actionStyle(.primary)
                ActionNote("Sends the saved capture to a new scene and deletes this one. Nothing is charged until it launches.")
            case .processAgain:
                Button("Process again", action: onProcessAgain)
                    .actionStyle(.primary)
                ActionNote("Creates a new scene from the saved capture, and charges it.")
            case .impossible:
                EmptyView()
            }

            if failed.retry == .impossible {
                Button("New capture", action: onDiscard)
                    .actionStyle(.primary)
                // Say so, as Upload again does: the scene goes too.
                if failed.leftoverScene == .delete {
                    ActionNote("Also deletes this scene, which was never launched or charged.")
                }
            } else {
                Button("Discard capture", role: .destructive) {
                    confirmingDiscard = true
                }
                .actionStyle(.destructive)
            }
        }
        // As on Paused: the saved capture can't come back.
        .confirmationDialog("Discard this capture?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive, action: onDiscard)
        } message: {
            Text("The video and poses on this phone are deleted. A scene already created stays in Scenes.")
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
        Screen(title: "Ready", sceneID: scene.id, headline: "Your scene is ready", lead: scene.displayTitle) {
            // First, where it shows after a delete from the toolbar.
            if let deleteError {
                NoticeCard(tone: .alarm, title: "Couldn't delete", detail: deleteError)
            }

            Section {
                preview
                    .listRowInsets(EdgeInsets())
            }

            Section {
                if let preset = scene.presetName {
                    FactRow(label: "Preset") {
                        Text(preset)
                    }
                }
                FactRow(label: "Splats") {
                    Text(scene.numGaussians.map(FactFormat.splats) ?? "—")
                        .typeStyle(.data)
                }
                // API 1.5.0 on; older APIs send no training time.
                if let training = scene.trainingTime {
                    FactRow(label: "Training") {
                        Text(FactFormat.duration(training))
                    }
                }
                FactRow(label: "Created") {
                    Text(scene.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        } actions: {
            NavigationLink(value: Route.viewer(scene)) {
                Text("View in 3D")
            }
            .actionStyle(.primary)

            Button("New capture", action: onNewCapture)
                .actionStyle(.secondary)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isDeleting {
                    ProgressView()
                        .accessibilityLabel("Deleting the scene")
                } else {
                    MoreMenu {
                        if let viewerURL = scene.viewerURL {
                            Link(destination: viewerURL) {
                                Label("Open on splat-3d.com", systemImage: "safari")
                            }
                        }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete scene", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .confirmationDialog("Delete this scene?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete scene", role: .destructive, action: onDelete)
        } message: {
            Text("Its model, video and thumbnail are deleted for good.")
        }
    }

    /// Edge to edge in its section, which rounds it.
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
            .clipped()
    }
}
