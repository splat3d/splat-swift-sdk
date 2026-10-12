import SwiftUI
import UIKit
import Splat3D

// MARK: - Splat3D Integration: Scenes
//
// SplatClient.listScenePage lists the account's scenes, newest first, each
// with its status. A complete scene opens in SplatKit's viewer; any scene can
// be deleted with SplatClient.deleteScene. Each row's thumbnail comes from
// SplatClient.getSceneThumbnail, which sends the API key.

/// The account's latest scenes: view, open on the web, delete.
struct RecentScenesView: View {

    @StateObject private var model: RecentScenesModel
    @State private var pendingDelete: SplatScene?

    init() {
        _model = StateObject(wrappedValue: RecentScenesModel())
    }

    #if DEBUG
    init(previewing model: RecentScenesModel) {
        _model = StateObject(wrappedValue: model)
    }
    #endif

    var body: some View {
        content
            .background(Palette.paper)
            .navigationTitle("Scenes")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .refreshable { await model.load() }
            .confirmationDialog(
                "Delete \(pendingDelete?.displayTitle ?? "this scene")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { scene in
                Button("Delete scene", role: .destructive) {
                    Task { await model.delete(scene) }
                }
            } message: { _ in
                Text("Its model, video and thumbnail are deleted for good.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Palette.accent)
                MonoLabel("Loading scenes")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ScrollView {
                NoticeBox(tone: .alarm, title: "Couldn't load scenes", detail: message) {
                    Button("Try again") {
                        Task { await model.load() }
                    }
                    .buttonStyle(.ghost)
                }
                .padding(Hairline.margin)
            }

        case .loaded(let scenes) where scenes.isEmpty:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NoticeBox(tone: .neutral, title: "No scenes yet", detail: "Capture one, or create one at splat-3d.com, and it shows here.")
                    APICallBlock(code: Self.listCall)
                }
                .padding(Hairline.margin)
            }

        case .loaded(let scenes):
            List {
                if let deleteError = model.deleteError {
                    NoticeBox(tone: .alarm, title: "Couldn't delete", detail: deleteError)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Palette.paper)
                }

                // Column heads over an ink rule, as tables are on splat-3d.com.
                HStack {
                    MonoLabel("Scene")
                    Spacer()
                    MonoLabel("Status")
                }
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) { Rule(color: Palette.ink) }
                .listRowSeparator(.hidden)
                .listRowBackground(Palette.paper)

                ForEach(scenes) { scene in
                    row(scene)
                }

                APICallBlock(code: Self.listCall)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Palette.paper)
                    .padding(.top, 12)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ scene: SplatScene) -> some View {
        SceneRow(scene: scene, thumbnails: model.thumbnails)
            .background {
                // Only a complete scene has a model to open.
                if scene.isComplete {
                    NavigationLink(value: Route.viewer(sceneID: scene.id, title: scene.displayTitle)) {
                        EmptyView()
                    }
                    .opacity(0)
                }
            }
            .listRowBackground(Palette.paper)
            .listRowSeparatorTint(Palette.rule)
            .swipeActions {
                Button("Delete", role: .destructive) {
                    pendingDelete = scene
                }
            }
            .contextMenu {
                if scene.isComplete, let viewerURL = scene.viewerURL {
                    Link(destination: viewerURL) {
                        Label("Open on splat-3d.com", systemImage: "safari")
                    }
                }
                Button(role: .destructive) {
                    pendingDelete = scene
                } label: {
                    Label("Delete scene", systemImage: "trash")
                }
            }
    }

    private static let listCall = """
        let page = try await client.listScenePage(limit: 100)
        try await client.deleteScene(id: scene.id)
        """
}

/// One scene: thumbnail, title, id and age, and its status.
private struct SceneRow: View {
    let scene: SplatScene
    let thumbnails: ThumbnailStore

    private static let thumbnailSize: CGFloat = 52
    private static let idPrefix = 8

    var body: some View {
        HStack(spacing: 12) {
            SceneThumbnail(scene: scene, store: thumbnails)
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                .clipShape(Hairline.shape)
                .overlay(Hairline.shape.strokeBorder(Palette.rule, lineWidth: Hairline.rule))

            VStack(alignment: .leading, spacing: 4) {
                Text(scene.displayTitle)
                    .typeStyle(.bodyStrong)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(details)
                    .typeStyle(.code)
                    .foregroundStyle(Palette.graphite)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            StatusLabel(state: scene.status.dot(percent: scene.processingPct), text: scene.status.shortName)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(scene.isComplete ? "Opens the scene in 3D" : "")
    }

    /// "a1b2c3d4 · 2 days ago · 1.9M splats".
    private var details: String {
        var parts = [String(scene.id.prefix(Self.idPrefix)), scene.createdAt.formatted(.relative(presentation: .named))]
        if let count = scene.numGaussians {
            parts.append("\(count.formatted(.number.notation(.compactName))) splats")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - SceneThumbnail

/// A scene's thumbnail, loaded with the API key. A faint mark shows while it
/// loads, and stays when the scene has none or the load fails.
private struct SceneThumbnail: View {
    let scene: SplatScene
    let store: ThumbnailStore

    @State private var image: UIImage?

    init(scene: SplatScene, store: ThumbnailStore) {
        self.scene = scene
        self.store = store
        // A row scrolled back into view starts with its image, with no
        // flash of the placeholder.
        _image = State(initialValue: store.cached(scene.id))
    }

    var body: some View {
        ThumbnailPlaceholder()
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            // Runs while the row is on screen. SwiftUI cancels it when the row
            // goes away, and the cancellation stops the request.
            .task(id: scene.id) {
                image = await store.image(for: scene)
            }
    }
}

/// Mist ground with a faint mark, where a thumbnail will go.
struct ThumbnailPlaceholder: View {
    private static let markOpacity = 0.35
    private static let markInset: CGFloat = 0.28

    var body: some View {
        GeometryReader { geometry in
            Palette.mist
                .overlay {
                    Mark()
                        .padding(min(geometry.size.width, geometry.size.height) * Self.markInset)
                        .opacity(Self.markOpacity)
                }
        }
    }
}

// MARK: - RecentScenesModel

@MainActor
final class RecentScenesModel: ObservableObject {

    enum State {
        case loading
        case loaded([SplatScene])
        case failed(String)
    }

    @Published private(set) var state = State.loading
    @Published private(set) var deleteError: String?

    /// The API's largest page: recent enough, in one request.
    private static let pageSize = 100

    private let client: SplatClient?
    #if DEBUG
    private var isPreview = false
    #endif

    /// The rows' thumbnails, loaded through the same client, so with the same key.
    fileprivate let thumbnails: ThumbnailStore

    init() {
        let client = apiKey.map { SplatClient(apiKey: $0) }
        self.client = client
        thumbnails = ThumbnailStore(client: client)
    }

    func load() async {
        #if DEBUG
        guard !isPreview else {
            return
        }
        #endif
        guard let client else {
            state = .failed(missingAPIKeyMessage)
            return
        }

        do {
            let page = try await client.listScenePage(limit: Self.pageSize)
            state = .loaded(page.scenes)
        } catch is CancellationError {
            // The list went away, or a refresh replaced this load.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Delete a scene and drop its row. A scene still processing is
    /// cancelled first, by the API.
    func delete(_ scene: SplatScene) async {
        guard let client else {
            return
        }
        deleteError = nil
        do {
            try await client.deleteScene(id: scene.id)
        } catch {
            deleteError = error.localizedDescription
            return
        }
        if case .loaded(let scenes) = state {
            state = .loaded(scenes.filter { $0.id != scene.id })
        }
    }

    #if DEBUG
    /// A list in a fixed state, with no client, for PreviewHarness.
    init(previewing state: State) {
        client = nil
        thumbnails = ThumbnailStore(client: nil)
        self.state = state
        isPreview = true
    }
    #endif
}

// MARK: - ThumbnailStore

/// Loads scene thumbnails with the API key, and keeps the decoded images for
/// as long as the list lives, so scrolling back doesn't fetch them again.
///
/// AsyncImage can't send the key, which the API wants for a private scene's
/// thumbnail. NSCache is thread-safe and SplatClient is Sendable, so the
/// rows' tasks can share one store.
private final class ThumbnailStore: @unchecked Sendable {

    private let client: SplatClient?
    private let images = NSCache<NSString, UIImage>()

    init(client: SplatClient?) {
        self.client = client
    }

    /// The image of a scene loaded before, if memory still holds it.
    func cached(_ sceneID: String) -> UIImage? {
        images.object(forKey: sceneID as NSString)
    }

    /// The scene's thumbnail, from memory or from the API. `nil` when the
    /// scene has none, the request fails or the calling task is cancelled.
    /// Only a loaded image is kept, so a row that failed tries again the next
    /// time it appears.
    func image(for scene: SplatScene) async -> UIImage? {
        if let image = cached(scene.id) {
            return image
        }

        // No thumbnail yet: the request could only answer 404.
        guard scene.thumbnailURL != nil, let client else {
            return nil
        }

        do {
            let data = try await client.getSceneThumbnail(id: scene.id)
            guard let image = UIImage(data: data) else {
                return nil
            }
            images.setObject(image, forKey: scene.id as NSString)
            return image
        } catch {
            return nil
        }
    }
}

extension SplatScene {
    /// The title, or a stand-in for scenes without one.
    var displayTitle: String {
        guard let title, !title.isEmpty else {
            return "Untitled scene"
        }
        return title
    }
}

// MARK: - Statuses in words

extension SceneStatus {

    /// A plain name for the status. The set is open: a stage this app
    /// doesn't know shows as "Working".
    var displayName: String {
        switch self {
        case .uploading:
            return "Waiting for the video"
        case .previewExtracting, .previewGenerating, .previewCompressing:
            return "Making a preview"
        case .previewReady:
            return "Preview ready"
        case .extractingFrames:
            return "Extracting frames"
        case .estimatingPoses, .runningSfm:
            return "Placing the cameras"
        case .training:
            return "Training the splats"
        case .exporting:
            return "Exporting"
        case .compressing:
            return "Compressing"
        case .processing:
            return "Processing"
        case .complete:
            return "Ready"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        default:
            return "Working"
        }
    }

    /// For the Scenes list: in progress statuses are all "Processing".
    var shortName: String {
        switch self {
        case .complete, .failed, .cancelled:
            return displayName
        case .uploading:
            return "Uploading"
        default:
            return "Processing"
        }
    }

    private static let percent: Double = 100

    func dot(percent: Double?) -> DotState {
        switch self {
        case .complete:
            return .done
        case .failed:
            return .failed
        case .cancelled, .uploading:
            return .waiting
        default:
            return .running((percent ?? 0) / Self.percent)
        }
    }
}
