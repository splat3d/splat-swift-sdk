import Foundation

// MARK: - SceneStatus

/// Processing status of a scene, as the API reports it.
///
/// A scene moves through these statuses while it processes:
///
/// ```
/// uploading -> extracting_frames -> estimating_poses -> training -> exporting -> compressing
///           -> complete | failed | cancelled
/// ```
///
/// Older scenes may hold a status no new scene reaches: ``runningSfm``, or one
/// of the retired preview stages, which scenes passed through before the
/// stages above.
///
/// The set is open. The API adds pipeline stages over time, and a status this
/// SDK doesn't name still decodes with its raw value. Anything other than
/// ``complete``, ``failed`` and ``cancelled`` is still in progress, so match the
/// statuses you care about and handle the rest with `default`.
public struct SceneStatus: RawRepresentable, Hashable, Codable, Sendable, CaseIterable, CustomStringConvertible {

    /// The status as the API sends it, e.g. `"estimating_poses"`.
    public let rawValue: String

    /// A status from its API value. Values this SDK doesn't name are kept as they are.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: Before processing

    /// The scene exists and waits for its source. No processing job has started.
    public static let uploading = SceneStatus(rawValue: "uploading")

    // MARK: Preview (legacy)

    /// Legacy: frames were being extracted for the fast preview. The pipeline
    /// no longer makes a preview, so only older scenes hold this stage.
    public static let previewExtracting = SceneStatus(rawValue: "preview_extracting")

    /// Legacy: the fast preview was being generated. Only older scenes hold
    /// this stage.
    public static let previewGenerating = SceneStatus(rawValue: "preview_generating")

    /// Legacy: the fast preview was being compressed. Only older scenes hold
    /// this stage.
    public static let previewCompressing = SceneStatus(rawValue: "preview_compressing")

    /// Legacy: a fast preview was viewable while full processing ran. APIs
    /// before 1.1.0 reported it; the API no longer sends it.
    public static let previewReady = SceneStatus(rawValue: "preview_ready")

    // MARK: Full processing

    /// Frames are being extracted from the uploaded source.
    public static let extractingFrames = SceneStatus(rawValue: "extracting_frames")

    /// Camera poses are being estimated, by Structure from Motion or from ARKit poses.
    public static let estimatingPoses = SceneStatus(rawValue: "estimating_poses")

    /// Older name for ``estimatingPoses``, still stored for some scenes.
    public static let runningSfm = SceneStatus(rawValue: "running_sfm")

    /// The Gaussian splat model is being trained.
    public static let training = SceneStatus(rawValue: "training")

    /// The trained model is being exported.
    public static let exporting = SceneStatus(rawValue: "exporting")

    /// The model is being compressed to SOG.
    public static let compressing = SceneStatus(rawValue: "compressing")

    /// The status a launch reports in ``SceneLaunch/status``. A scene reports
    /// its pipeline stage instead; APIs before 1.1.0 also reported
    /// `processing` for a scene while they read its live progress.
    public static let processing = SceneStatus(rawValue: "processing")

    // MARK: Terminal

    /// Processing completed successfully.
    public static let complete = SceneStatus(rawValue: "complete")

    /// Processing failed. Check ``SplatScene/processingError`` for details.
    public static let failed = SceneStatus(rawValue: "failed")

    /// Processing was cancelled.
    public static let cancelled = SceneStatus(rawValue: "cancelled")

    /// Every status this SDK names, in pipeline order. It grows when the SDK
    /// names a new stage, so don't use it as a fixed-size or indexed list.
    public static let allCases: [SceneStatus] = [
        .uploading,
        .previewExtracting,
        .previewGenerating,
        .previewCompressing,
        .previewReady,
        .extractingFrames,
        .runningSfm,
        .estimatingPoses,
        .training,
        .exporting,
        .compressing,
        .processing,
        .complete,
        .failed,
        .cancelled,
    ]

    /// Statuses a scene never leaves on its own.
    private static let terminal: Set<SceneStatus> = [.complete, .failed, .cancelled]

    /// Whether processing has stopped: ``complete``, ``failed`` or ``cancelled``.
    public var isTerminal: Bool {
        Self.terminal.contains(self)
    }

    public var description: String {
        rawValue
    }
}

// MARK: - SplatScene

/// A 3D Gaussian Splat scene.
///
/// Scenes are created by uploading a video, then processed on GPU to produce
/// an interactive 3D model. Query the ``status`` property to track progress.
///
/// ```swift
/// let scene = try await client.getScene(id: "abc123")
/// if scene.isComplete {
///     print("View at: \(scene.viewerURL!)")
/// }
/// ```
///
/// The scene details, ``preset``, ``psnr``, ``trainingTime``,
/// ``processingStartedAt``, ``processingCompletedAt`` and ``modelSizes``,
/// come from API 1.5.0 on. Older APIs don't send them, so they read `nil`.
/// The quality metrics ``psnrHoldout``, ``ssimHoldout`` and ``ssim`` come
/// from API 1.3.0 too.
public struct SplatScene: Codable, Identifiable, Sendable, Equatable {

    /// Unique scene identifier.
    public let id: String

    /// User-provided scene title.
    public let title: String?

    /// Physical address or location (optional).
    public let address: String?

    /// Current processing status.
    public let status: SceneStatus

    /// Whether the scene is publicly viewable.
    public let isPublic: Bool

    /// Pipeline stage while processing, e.g. `"training"`; `nil` otherwise,
    /// including once complete.
    public let processingStage: String?

    /// Progress as a percentage (0-100) while processing, when known; `nil`
    /// otherwise, including once complete.
    public let processingPct: Double?

    /// Number of Gaussians in the trained model (available after training completes).
    public let numGaussians: Int?

    /// URL of the scene thumbnail image, or `nil` if not yet generated.
    ///
    /// A private scene's thumbnail needs your API key as a Bearer token, so
    /// `AsyncImage`, a web view or `URLSession.shared` can't load it: fetch
    /// the image with ``SplatClient/getSceneThumbnail(id:)``.
    public let thumbnailURL: URL?

    /// Error message when processing failed, or `nil` if no error.
    public let processingError: String?

    /// Viewer URL for the scene on splat-3d.com, as the server sends it:
    /// `nil` when it has no model to show, even for a complete scene.
    /// A response without the field (a list item from an API before 1.1.0,
    /// or an older server) gets the `/tour/` link for a complete scene.
    public let viewerURL: URL?

    /// API URL for the scene's 3D model, once processing is complete.
    ///
    /// Without `?format=` it serves the API's default format; add
    /// `?format=sog`, `?format=ply` or `?format=spz` to pick one. It requires
    /// your API key as a Bearer token, so a browser, web view or
    /// `URLSession.shared` gets a 401 from it: fetch the model with
    /// ``SplatClient/downloadScene(id:format:)``, which always names a format
    /// (`.sog` unless you pass another).
    public let downloadURL: URL?

    /// Format of the processed model, e.g. ``ModelFormat/sog``.
    public let format: ModelFormat?

    /// The preset the scene was created or retrained with, e.g.
    /// ``Preset/quality``. `nil` when the scene's stored parameters name
    /// none, as on some scenes from April 2026.
    public let preset: Preset?

    /// Mean PSNR in dB of the trained model over its training images, once
    /// the scene completes. Measured on the images it trained on, so it is
    /// usually higher than a holdout score.
    public let psnr: Double?

    /// PSNR in dB, higher is better, measured on photos kept out of training.
    ///
    /// `nil` unless the scene completed with photos held out, which every
    /// preset but ``Preset/fast`` does by default.
    public let psnrHoldout: Double?

    /// SSIM, up to 1 and higher is better, measured on photos kept out of
    /// training.
    ///
    /// `nil` unless the scene completed with photos held out, as for
    /// ``psnrHoldout``.
    public let ssimHoldout: Double?

    /// SSIM, up to 1 and higher is better, measured on the photos the model
    /// trained on, so it runs higher than ``ssimHoldout``.
    ///
    /// `nil` when the API has no value for the scene.
    public let ssim: Double?

    /// Seconds the GPU training stage took, once the scene completes.
    ///
    /// Frame extraction, pose estimation, compression and queueing are
    /// outside it: the whole job runs from ``processingStartedAt`` to
    /// ``processingCompletedAt``.
    public let trainingTime: TimeInterval?

    /// When processing was launched. `nil` until then, and kept after the
    /// scene finishes, fails or is cancelled.
    public let processingStartedAt: Date?

    /// When the scene was recorded complete, which can trail the job's end by
    /// minutes. `nil` unless the scene is complete.
    public let processingCompletedAt: Date?

    /// Sizes in bytes of the scene's model files. Each is `nil` unless the
    /// scene is complete and has that file.
    public let modelSizes: ModelSizes

    /// When the scene was created.
    public let createdAt: Date

    /// When the scene was last updated.
    public let updatedAt: Date

    /// Whether processing has completed successfully.
    public var isComplete: Bool { status == .complete }

    /// Whether processing has failed.
    public var isFailed: Bool { status == .failed }

    /// Whether the scene is still in progress: any status that isn't
    /// terminal, including ``SceneStatus/uploading`` and stages this SDK
    /// doesn't name.
    public var isProcessing: Bool {
        !status.isTerminal
    }

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case address
        case status
        case isPublic = "is_public"
        case processingStage = "processing_stage"
        case processingPct = "processing_pct"
        case numGaussians = "num_gaussians"
        case thumbnailR2Key = "thumbnail_r2_key"
        case thumbnailURLKey = "thumbnail_url"
        case processingError = "processing_error"
        case viewerURLKey = "viewer_url"
        case downloadURL = "download_url"
        case format
        case preset
        case psnr
        case trainingTime = "training_time_seconds"
        case processingStartedAt = "processing_started_at"
        case processingCompletedAt = "processing_completed_at"
        case spzSizeBytes = "spz_size_bytes"
        case sogSizeBytes = "sog_size_bytes"
        case plySizeBytes = "ply_size_bytes"
        case psnrHoldout = "psnr_holdout"
        case ssimHoldout = "ssim_holdout"
        case ssim
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // We need a custom initializer because thumbnailURL is derived from
    // thumbnail_url or thumbnail_r2_key
    private let thumbnailR2Key: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        status = try container.decode(SceneStatus.self, forKey: .status)
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        processingStage = try container.decodeIfPresent(String.self, forKey: .processingStage)
        processingPct = try container.decodeIfPresent(Double.self, forKey: .processingPct)
        numGaussians = try container.decodeIfPresent(Int.self, forKey: .numGaussians)
        thumbnailR2Key = try container.decodeIfPresent(String.self, forKey: .thumbnailR2Key)
        processingError = try container.decodeIfPresent(String.self, forKey: .processingError)
        downloadURL = try container.decodeIfPresent(URL.self, forKey: .downloadURL)
        format = try container.decodeIfPresent(ModelFormat.self, forKey: .format)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Scene details (API 1.5.0). A missing key, from an older API, reads
        // nil as null does; a preset this SDK doesn't name keeps its value.
        preset = try container.decodeIfPresent(Preset.self, forKey: .preset)
        psnr = try container.decodeIfPresent(Double.self, forKey: .psnr)
        trainingTime = try container.decodeIfPresent(TimeInterval.self, forKey: .trainingTime)
        processingStartedAt = try container.decodeIfPresent(Date.self, forKey: .processingStartedAt)
        processingCompletedAt = try container.decodeIfPresent(Date.self, forKey: .processingCompletedAt)
        modelSizes = try ModelSizes(
            spz: container.decodeIfPresent(Int.self, forKey: .spzSizeBytes),
            sog: container.decodeIfPresent(Int.self, forKey: .sogSizeBytes),
            ply: container.decodeIfPresent(Int.self, forKey: .plySizeBytes)
        )

        // Quality metrics (API 1.3.0 sends them; list items from older APIs
        // don't). A missing key reads nil as null does.
        psnrHoldout = try container.decodeIfPresent(Double.self, forKey: .psnrHoldout)
        ssimHoldout = try container.decodeIfPresent(Double.self, forKey: .ssimHoldout)
        ssim = try container.decodeIfPresent(Double.self, forKey: .ssim)

        // The thumbnail link: thumbnail_url when the server sent an absolute
        // one, else the API route on the deployment the scene came from.
        let servedThumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnailURLKey)
        let apiBase = decoder.userInfo[.splatBaseURL] as? URL ?? SplatScene.productionAPI
        thumbnailURL = SplatScene.thumbnailLink(
            id: id,
            served: servedThumbnail,
            r2Key: thumbnailR2Key,
            apiBase: apiBase
        )

        // A viewer_url the response carries is the server's answer, null
        // included: there is no model to show. Only a response without the
        // key (list items from APIs before 1.1.0, and servers from before
        // viewer_url) gets a link built here.
        if container.contains(.viewerURLKey) {
            viewerURL = try container.decodeIfPresent(URL.self, forKey: .viewerURLKey)
        } else {
            viewerURL = SplatScene.fallbackViewerURL(id: id, status: status)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(status, forKey: .status)
        try container.encode(isPublic, forKey: .isPublic)
        try container.encodeIfPresent(processingStage, forKey: .processingStage)
        try container.encodeIfPresent(processingPct, forKey: .processingPct)
        try container.encodeIfPresent(numGaussians, forKey: .numGaussians)
        try container.encodeIfPresent(thumbnailR2Key, forKey: .thumbnailR2Key)
        // Written, as the string decoding reads, so decoding it again keeps
        // the link rather than building a production one.
        try container.encodeIfPresent(thumbnailURL?.absoluteString, forKey: .thumbnailURLKey)
        try container.encodeIfPresent(processingError, forKey: .processingError)
        // Written even when nil, so decoding it again doesn't build a link.
        try container.encode(viewerURL, forKey: .viewerURLKey)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)

        // Scene details, under the keys decoding reads.
        try container.encodeIfPresent(preset, forKey: .preset)
        try container.encodeIfPresent(psnr, forKey: .psnr)
        try container.encodeIfPresent(trainingTime, forKey: .trainingTime)
        try container.encodeIfPresent(processingStartedAt, forKey: .processingStartedAt)
        try container.encodeIfPresent(processingCompletedAt, forKey: .processingCompletedAt)
        try container.encodeIfPresent(modelSizes.spz, forKey: .spzSizeBytes)
        try container.encodeIfPresent(modelSizes.sog, forKey: .sogSizeBytes)
        try container.encodeIfPresent(modelSizes.ply, forKey: .plySizeBytes)

        // Quality metrics, under the keys decoding reads.
        try container.encodeIfPresent(psnrHoldout, forKey: .psnrHoldout)
        try container.encodeIfPresent(ssimHoldout, forKey: .ssimHoldout)
        try container.encodeIfPresent(ssim, forKey: .ssim)
    }

    /// Memberwise initializer for testing and internal use.
    public init(
        id: String,
        title: String? = nil,
        address: String? = nil,
        status: SceneStatus,
        isPublic: Bool = false,
        processingStage: String? = nil,
        processingPct: Double? = nil,
        numGaussians: Int? = nil,
        thumbnailURL: URL? = nil,
        processingError: String? = nil,
        viewerURL: URL? = nil,
        downloadURL: URL? = nil,
        format: ModelFormat? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        preset: Preset? = nil,
        psnr: Double? = nil,
        trainingTime: TimeInterval? = nil,
        processingStartedAt: Date? = nil,
        processingCompletedAt: Date? = nil,
        modelSizes: ModelSizes = ModelSizes(),
        psnrHoldout: Double? = nil,
        ssimHoldout: Double? = nil,
        ssim: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.address = address
        self.status = status
        self.isPublic = isPublic
        self.processingStage = processingStage
        self.processingPct = processingPct
        self.numGaussians = numGaussians
        self.thumbnailURL = thumbnailURL
        self.thumbnailR2Key = thumbnailURL != nil ? "scenes/\(id)/thumbnail.jpg" : nil
        self.processingError = processingError
        self.viewerURL = viewerURL ?? SplatScene.fallbackViewerURL(id: id, status: status)
        self.downloadURL = downloadURL
        self.format = format
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preset = preset
        self.psnr = psnr
        self.trainingTime = trainingTime
        self.processingStartedAt = processingStartedAt
        self.processingCompletedAt = processingCompletedAt
        self.modelSizes = modelSizes
        self.psnrHoldout = psnrHoldout
        self.ssimHoldout = ssimHoldout
        self.ssim = ssim
    }

    /// Equatable conformance (ignores derived thumbnailURL — compares all stored properties).
    public static func == (lhs: SplatScene, rhs: SplatScene) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.address == rhs.address
            && lhs.status == rhs.status
            && lhs.isPublic == rhs.isPublic
            && lhs.processingStage == rhs.processingStage
            && lhs.processingPct == rhs.processingPct
            && lhs.numGaussians == rhs.numGaussians
            && lhs.processingError == rhs.processingError
            && lhs.viewerURL == rhs.viewerURL
            && lhs.downloadURL == rhs.downloadURL
            && lhs.format == rhs.format
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.preset == rhs.preset
            && lhs.psnr == rhs.psnr
            && lhs.trainingTime == rhs.trainingTime
            && lhs.processingStartedAt == rhs.processingStartedAt
            && lhs.processingCompletedAt == rhs.processingCompletedAt
            && lhs.modelSizes == rhs.modelSizes
            && lhs.psnrHoldout == rhs.psnrHoldout
            && lhs.ssimHoldout == rhs.ssimHoldout
            && lhs.ssim == rhs.ssim
    }
}

// MARK: - Preset

extension SplatScene {

    /// The preset a scene reports in ``SplatScene/preset``.
    ///
    /// It names what the API records, so it has ``custom``, which
    /// ``ScenePreset`` lacks: create and retrain take a ``ScenePreset``, and
    /// retrain refuses `custom`. `ScenePreset(rawValue: preset.rawValue)`
    /// converts one, and is `nil` for ``custom``.
    ///
    /// The set is open, like ``SceneStatus``: a preset the API adds later
    /// decodes with its raw value, so `switch` with a `default`.
    public struct Preset: RawRepresentable, Hashable, Codable, Sendable, CaseIterable, CustomStringConvertible {

        /// The preset as the API names it, e.g. `"quality"`.
        public let rawValue: String

        /// A preset from its API name. Names this SDK doesn't know are kept as they are.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Defaults of 800px and 3K iterations.
        public static let fast = Preset(rawValue: "fast")

        /// Defaults of 1600px and 7K iterations.
        public static let standard = Preset(rawValue: "standard")

        /// Defaults of 1600px and 15K iterations. Scenes recorded with the
        /// legacy `pro` or `hd` tier report it too.
        public static let quality = Preset(rawValue: "quality")

        /// Defaults of full resolution and 30K iterations.
        public static let ultra = Preset(rawValue: "ultra")

        /// Parameters set one by one at creation, starting from `standard`'s.
        public static let custom = Preset(rawValue: "custom")

        /// Every preset this SDK names.
        public static let allCases: [Preset] = [.fast, .standard, .quality, .ultra, .custom]

        public var description: String {
            rawValue
        }
    }
}

// MARK: - Model sizes

extension SplatScene {

    /// Sizes in bytes of a scene's model files, for ``SplatScene/modelSizes``.
    ///
    /// The API reports them for a complete scene, each when the scene has
    /// that file: older scenes, and scenes whose SPZ conversion failed, have
    /// no SPZ.
    public struct ModelSizes: Hashable, Sendable {

        /// The SPZ file, which ``ModelFormat/spz`` downloads.
        public let spz: Int?

        /// The SOG file, which ``ModelFormat/sog`` downloads.
        public let sog: Int?

        /// The PLY file, which ``ModelFormat/ply`` downloads.
        public let ply: Int?

        /// Sizes for test doubles; leave out a file the scene doesn't have.
        public init(spz: Int? = nil, sog: Int? = nil, ply: Int? = nil) {
            self.spz = spz
            self.sog = sog
            self.ply = ply
        }
    }
}

// MARK: - Thumbnail URL

extension CodingUserInfoKey {

    /// The API a response came from, so decoded URLs point back at it.
    static let splatBaseURL = CodingUserInfoKey(rawValue: "Splat3D.baseURL")!
}

extension SplatScene {

    /// Thumbnail host when a scene is decoded outside ``SplatClient``.
    fileprivate static let productionAPI = URL(string: "https://api.splat-3d.com")!

    /// The thumbnail link, or `nil` when neither key says there is one.
    ///
    /// An absolute `thumbnail_url` is used as sent, e.g.
    /// `https://api.splat-3d.com/v1/scenes/<id>/thumbnail` (the API builds it
    /// from its own base URL). Otherwise the same route on `apiBase`.
    fileprivate static func thumbnailLink(id: String, served: String?, r2Key: String?, apiBase: URL) -> URL? {
        if let served,
           let parts = URLComponents(string: served),
           parts.scheme != nil,
           parts.host?.isEmpty == false,
           let url = parts.url {
            return url
        }

        guard served != nil || r2Key != nil else {
            return nil
        }
        return apiBase.appendingPathComponent("v1/scenes/\(id)/thumbnail")
    }
}

// MARK: - Viewer URL

extension SplatScene {
    /// Public viewer route on splat-3d.com. The older `/s/{id}` route was
    /// retired and now returns 404.
    private static let viewerBase = "https://splat-3d.com/tour/"

    /// Viewer link for responses without `viewer_url`: list items from APIs
    /// before 1.1.0, and servers from before it.
    private static func fallbackViewerURL(id: String, status: SceneStatus) -> URL? {
        guard status == .complete else {
            return nil
        }
        return URL(string: viewerBase + id)
    }
}
