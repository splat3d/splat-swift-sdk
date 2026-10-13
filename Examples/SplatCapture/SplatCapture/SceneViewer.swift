import SwiftUI
import Splat3D
import SplatKit

// MARK: - Splat3D + SplatKit Integration: View in 3D
//
//   SplatClient.downloadScene(format: spz) ──> scene-<id>.spz in tmp/
//        │   (the session's delegate watches the bytes arrive)
//        └──> SplatWorldView ──> SplatKit's SplatMetalView
//
// Both modules import side by side: Splat3D was named SplatKit before 1.0 and
// was renamed so it wouldn't clash with this renderer.

/// Downloads a scene's SPZ and shows it with SplatKit.
struct SceneViewerScreen: View {

    let title: String
    /// The scene on splat-3d.com, offered when asking again can't help.
    let webURL: URL?

    @StateObject private var model: SceneViewerModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mode = NavigationMode.orbit
    // Splat3D scenes are +Y up. SplatKit reads SPZ as +Y down (World Labs'
    // convention) and flips it, so start with the picture turned back.
    @State private var flipped = true
    @State private var walkSpeed: Float = 0
    @State private var resetCount = 0

    /// Scene units per second while a move arrow is held.
    private static let walkingSpeed: Float = 0.6
    private static let actionWidth: CGFloat = 220

    init(sceneID: String, title: String, webURL: URL?) {
        self.title = title
        self.webURL = webURL
        _model = StateObject(wrappedValue: SceneViewerModel(sceneID: sceneID))
    }

    #if DEBUG
    init(title: String, webURL: URL?, previewing model: SceneViewerModel, mode: NavigationMode = .orbit) {
        self.title = title
        self.webURL = webURL
        _model = StateObject(wrappedValue: model)
        _mode = State(initialValue: mode)
    }
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .environment(\.colorScheme, .dark)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .task { await model.load() }
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .downloading(let received, let expected):
            DownloadProgress(received: received, expected: expected)

        case .showing(let file, let bytes):
            world(file)
                .overlay {
                    if !model.worldReady {
                        Notice(symbol: nil, title: "Loading into SplatKit…", detail: bytes.formatted(.byteCount(style: .file)))
                    }
                }

        case .undrawable(let bytes):
            scrollingIfNeeded {
                Notice(
                    symbol: "iphone.slash",
                    title: "Downloaded, but not drawn here",
                    detail: "Got \(bytes.formatted(.byteCount(style: .file))) of SPZ, but SplatKit couldn't start Metal. "
                        + "It needs a physical device with an A14 or M1 chip or newer (Apple GPU family 7), so the "
                        + "Simulator never draws; on such a device, its Metal setup failed."
                )
            }

        case .failed(let failure):
            scrollingIfNeeded {
                VStack(spacing: 16) {
                    Notice(symbol: "exclamationmark.triangle", title: failure.title, detail: failure.detail)
                    failureAction(failure)
                        // At accessibility sizes the label needs the width.
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : Self.actionWidth)
                        .padding(.horizontal, Theme.margin)
                }
            }
        }
    }

    /// A message centred on screen, which scrolls when it doesn't fit, as at
    /// the largest text sizes, where it was cut off.
    private func scrollingIfNeeded<Message: View>(@ViewBuilder _ message: () -> Message) -> some View {
        let message = message()
        return ViewThatFits(in: .vertical) {
            message
            ScrollView {
                message
            }
        }
    }

    /// Try again when it can go differently. When the server would answer
    /// the same, the scene on splat-3d.com, whose viewer needs no SPZ.
    @ViewBuilder
    private func failureAction(_ failure: ViewerFailure) -> some View {
        if failure.canRetry {
            Button("Try again") {
                Task { await model.retry() }
            }
            .actionStyle(.primary)
        } else if let webURL {
            Link("Open on splat-3d.com", destination: webURL)
                .actionStyle(.primary)
        }
    }

    private func world(_ file: URL) -> some View {
        SplatWorldView(
            file: file,
            mode: mode,
            flipped: flipped,
            walkSpeed: walkSpeed,
            resetCount: resetCount,
            isActive: scenePhase == .active,
            onEvent: { model.handle($0) }
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            #if DEBUG
            if let stats = model.stats {
                StatsLine(stats: stats)
            }
            #endif
        }
        .overlay(alignment: .bottom) {
            if model.worldReady {
                controls
            }
        }
    }

    // MARK: Controls

    /// Glass over the scene: the move arrows in Look mode, then the mode,
    /// Flip and Reset. Neighbours blend on iOS 26.
    private var controls: some View {
        GlassGroup(spacing: Self.controlSpacing) {
            VStack(spacing: 12) {
                if mode == .look {
                    HStack(spacing: 24) {
                        holdToMove(symbol: "arrow.up", label: "Move forward", speed: Self.walkingSpeed)
                        holdToMove(symbol: "arrow.down", label: "Move back", speed: -Self.walkingSpeed)
                    }
                }

                HStack(spacing: Self.controlSpacing) {
                    Choice(label: "Navigation", options: NavigationMode.allCases, selection: modeSelection) { $0.rawValue.capitalized }
                        .padding(Self.choiceInset)
                        .frame(minHeight: Self.controlSize)
                        .glassSurface(in: Capsule())

                    iconButton("Flip", symbol: "arrow.up.arrow.down", isOn: flipped) {
                        flipped.toggle()
                    }
                    .accessibilityAddTraits(flipped ? .isSelected : [])

                    iconButton("Reset", symbol: "scope", isOn: false) {
                        resetCount += 1
                    }
                }
            }
        }
        .padding()
    }

    /// A round glass button, tinted with the accent while its setting is on.
    private func iconButton(_ label: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Palette.onAccent : .primary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                // The whole circle takes the tap, not just the icon.
                .contentShape(Circle())
                .glassSurface(in: Circle(), tint: isOn ? Palette.accent : nil, interaction: .interactive)
        }
        .buttonStyle(.plain)
    }

    /// Side of the round Flip and Reset buttons, and height of the mode
    /// control: a full touch target and a little more.
    private static let controlSize: CGFloat = 48
    private static let controlSpacing: CGFloat = 10
    /// Space between the mode control and its glass.
    private static let choiceInset: CGFloat = 6

    /// The mode picker's selection. A switch hides the move arrows, so one held
    /// through it never reports its release: stop walking in the same update.
    private var modeSelection: Binding<NavigationMode> {
        Binding(
            get: { mode },
            set: { newMode in
                walkSpeed = 0
                mode = newMode
            }
        )
    }

    /// Walks while held: SplatKit moves the camera along where it looks.
    private func holdToMove(symbol: String, label: String, speed: Float) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
        }
        .buttonStyle(HoldButtonStyle { held in
            walkSpeed = held ? speed : 0
        })
        .accessibilityLabel(label)
    }
}

// MARK: - SceneViewerModel

/// Downloads a scene's SPZ for SplatKit and follows it onto the screen.
@MainActor
final class SceneViewerModel: ObservableObject {

    enum Phase {
        /// Bytes so far, and the total when the server sent one.
        case downloading(received: Int64, expected: Int64?)
        /// The file is on disk, and SplatKit is loading or showing it.
        case showing(file: URL, bytes: Int64)
        /// The file is on disk, but SplatKit can't draw on this device.
        case undrawable(bytes: Int64)
        case failed(ViewerFailure)
    }

    @Published private(set) var phase = Phase.downloading(received: 0, expected: nil)
    /// The world's first frame is on screen.
    @Published private(set) var worldReady = false
    @Published private(set) var stats: SplatStats?

    private static let progressInterval: Duration = .milliseconds(250)

    private let sceneID: String
    private var file: URL?
    /// Bumped by every load and by the screen closing. A download that lands
    /// after a bump is stale, and is deleted at once.
    private var generation = 0

    init(sceneID: String) {
        self.sceneID = sceneID
    }

    #if DEBUG
    /// Shows `phase` and never downloads, for PreviewHarness. With
    /// `worldReady`, the controls show over the world, which ignores
    /// SplatKit's events: on the Simulator it draws nothing.
    init(previewing phase: Phase, worldReady: Bool = false) {
        sceneID = ""
        self.phase = phase
        self.worldReady = worldReady
        isPreview = true
    }

    private var isPreview = false
    #endif

    /// Try Again. A file still on disk is one SplatKit refused: hand it over
    /// again, since a new download would bring the same bytes.
    func retry() async {
        guard let file else {
            await load()
            return
        }
        worldReady = false
        stats = nil
        phase = .showing(file: file, bytes: Self.size(of: file))
    }

    /// The screen went away. A retry's download may still land later.
    func close() {
        generation += 1
        discardFile()
    }

    func load() async {
        #if DEBUG
        guard !isPreview else {
            return
        }
        #endif
        generation += 1
        let current = generation
        discardFile()
        worldReady = false
        stats = nil
        phase = .downloading(received: 0, expected: nil)

        guard let apiKey else {
            phase = .failed(.noAPIKey)
            return
        }

        // The SDK takes any URLSession; this one's delegate sees the download task.
        let watcher = TransferWatcher()
        let session = URLSession(configuration: .default, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let client = SplatClient(apiKey: apiKey, session: session)

        let progress = Task { [weak self] in
            while !Task.isCancelled {
                if let bytes = watcher.bytes {
                    self?.showProgress(received: bytes.received, expected: bytes.expectedToReceive)
                }
                try? await Task.sleep(for: SceneViewerModel.progressInterval)
            }
        }
        defer { progress.cancel() }

        do {
            let downloaded = try await client.downloadScene(id: sceneID, format: .spz)

            // A retry outlives its screen: once it closed, or a newer load
            // began, nothing will show this file.
            guard current == generation else {
                try? FileManager.default.removeItem(at: downloaded)
                return
            }

            // The extension is the format the server actually sent.
            guard downloaded.pathExtension == ModelFormat.spz.rawValue else {
                try? FileManager.default.removeItem(at: downloaded)
                phase = .failed(.otherFormat(downloaded.pathExtension))
                return
            }

            file = downloaded
            phase = .showing(file: downloaded, bytes: Self.size(of: downloaded))
        } catch is CancellationError {
            // The screen went away mid-download.
        } catch {
            phase = .failed(ViewerFailure(error))
        }
    }

    func handle(_ event: WorldEvent) {
        #if DEBUG
        guard !isPreview else {
            return
        }
        #endif
        switch event {
        case .unavailable:
            guard case .showing(_, let bytes) = phase else {
                return
            }
            phase = .undrawable(bytes: bytes)
        case .ready:
            worldReady = true
        case .failed(let message):
            phase = .failed(.unreadable(message))
        case .stats(let latest):
            stats = latest
        }
    }

    /// Deletes the download. Safe while SplatKit still maps it: the mapping
    /// keeps the bytes until it lets go.
    private func discardFile() {
        guard let file else {
            return
        }
        try? FileManager.default.removeItem(at: file)
        self.file = nil
    }

    private func showProgress(received: Int64, expected: Int64?) {
        guard case .downloading = phase else {
            return
        }
        phase = .downloading(received: received, expected: expected)
    }

    private static func size(of file: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - TransferWatcher

/// A transfer's bytes so far, and the totals when the request or response
/// gave a length.
struct TransferBytes {
    let sent: Int64
    let expectedToSend: Int64?
    let received: Int64
    let expectedToReceive: Int64?
}

/// Remembers the newest task the SDK starts on its session, to read its bytes:
/// the viewer's download, and the capture's upload. Retries start new tasks,
/// so the newest one is the live one.
final class TransferWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    var bytes: TransferBytes? {
        lock.withLock {
            guard let task else {
                return nil
            }
            // -1 (NSURLSessionTransferSizeUnknown) until a length is known.
            let total = { (length: Int64) in length > 0 ? length : nil }
            return TransferBytes(
                sent: task.countOfBytesSent,
                expectedToSend: total(task.countOfBytesExpectedToSend),
                received: task.countOfBytesReceived,
                expectedToReceive: total(task.countOfBytesExpectedToReceive)
            )
        }
    }
}

// MARK: - ViewerFailure

/// Why a scene can't be shown, worded for whoever is testing.
struct ViewerFailure {

    /// What asking again would bring.
    enum Retry {
        /// Maybe something else: offer Try again.
        case mayHelp
        /// The same answer: offer the web viewer instead.
        case sameAnswer
    }

    let title: String
    let detail: String
    let retry: Retry

    var canRetry: Bool {
        retry == .mayHelp
    }

    /// RFC 9110 §15.5.1.
    private static let badRequest = 400

    static let noAPIKey = ViewerFailure(title: "No API key", detail: missingAPIKeyMessage)

    /// The server answered with another format, so this scene has no SPZ.
    static func otherFormat(_ served: String) -> ViewerFailure {
        ViewerFailure(
            title: "This scene has no SPZ",
            detail: "The server sent \(served.isEmpty ? "another format" : served.uppercased()) instead, which SplatKit can't read.",
            retry: .sameAnswer
        )
    }

    /// SplatKit refused the file it was given.
    static func unreadable(_ message: String) -> ViewerFailure {
        ViewerFailure(title: "SplatKit couldn't load this scene", detail: message)
    }

    init(title: String, detail: String, retry: Retry = .mayHelp) {
        self.title = title
        self.detail = detail
        self.retry = retry
    }

    init(_ error: Error) {
        switch error {
        case SplatError.requestFailed(let apiError) where Self.rejectsFormat(apiError):
            self.init(
                title: "SPZ download not available on this server yet",
                detail: "The API doesn't accept format=spz yet. It said: \(apiError.message)",
                retry: .sameAnswer
            )
        case SplatError.notFound(let apiError):
            self.init(
                title: "This scene has no SPZ",
                detail: "\(apiError.message) Scenes processed before SPZ export, or whose SPZ conversion failed, have none.",
                retry: .sameAnswer
            )
        case SplatError.unauthorized:
            self.init(title: "API key rejected", detail: "Check SPLAT_API_KEY in Secrets.xcconfig.")
        case let urlError as URLError:
            self.init(title: "Network error", detail: urlError.localizedDescription)
        default:
            self.init(title: "Download failed", detail: error.localizedDescription)
        }
    }

    /// The route's validator answers a format it doesn't know with a 400 that
    /// isn't an API error envelope, so it has no code, and names the field:
    /// "format: Invalid enum value. Expected 'sog' | 'ply', received 'spz'".
    private static func rejectsFormat(_ error: SplatError.APIError) -> Bool {
        error.statusCode == badRequest && error.code == nil && error.message.hasPrefix("format")
    }
}

// MARK: - Small views

/// Bytes downloaded so far, as a bar once the total is known.
private struct DownloadProgress: View {
    let received: Int64
    let expected: Int64?

    var body: some View {
        VStack(spacing: 12) {
            if let expected {
                RunProgressBar(label: "Download", fraction: Double(min(received, expected)) / Double(expected))
                    .frame(maxWidth: 240)
                Text("Downloading SPZ · \(Self.format(received)) of \(Self.format(expected))")
            } else {
                ProgressView()
                Text(received > 0 ? "Downloading SPZ · \(Self.format(received))" : "Requesting SPZ…")
            }
        }
        .typeStyle(.data)
        .tint(Palette.accent)
    }

    private static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

/// A centred message: optional symbol, title and detail.
private struct Notice: View {
    let symbol: String?
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(title)
                .typeStyle(.title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .tint(Palette.accent)
        .padding(32)
    }
}

#if DEBUG
/// Frame rate and splats drawn, as SplatKit measures them. Debug builds only.
private struct StatsLine: View {
    let stats: SplatStats

    var body: some View {
        Text("\(Int(stats.fps.rounded())) fps · \(Self.count(stats.drawnSplatCount)) of \(Self.count(stats.splatCount)) splats")
            .typeStyle(.smallData)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassSurface(in: Capsule())
            .padding(.top, 8)
    }

    private static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
#endif

/// Reports presses: `onHold(true)` while held, `onHold(false)` on release.
/// A glass circle, filled with the accent while held.
private struct HoldButtonStyle: ButtonStyle {
    let onHold: (Bool) -> Void

    private static let size: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Palette.onAccent : .primary)
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
            .glassSurface(in: Circle(), tint: configuration.isPressed ? Palette.accent : nil, interaction: .interactive)
            .onChange(of: configuration.isPressed) { _, pressed in
                onHold(pressed)
            }
    }
}
