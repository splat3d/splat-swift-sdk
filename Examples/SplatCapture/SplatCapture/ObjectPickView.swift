import SwiftUI
import AVFoundation
import Splat3D

// MARK: - Splat3D Integration: Object scan
//
// An object scan keeps one object instead of everything the camera saw. The
// API is told which by a SceneSubject: one moment in the video, and 1 to 5
// points on the object in that frame.
//
//   CapturedView ── Scan one object ──> ObjectPickView
//                                         │  scrub to a frame   ──> the time
//                                         │  tap the object     ──> the points
//                                         ▼
//                                       ObjectPick ──> SceneSubject ──> createAndProcess(subject:)
//
// The time is the player's own, AVPlayer.currentTime(), the timeline a
// browser's video.currentTime uses. The points are fractions of the frame as
// the player shows it: PickGeometry.swift turns a tap into one.
//
// Only shown when the SPLAT_OBJECT_SCAN build setting is YES: the production
// API answers 403 feature_disabled until object scans are switched on there.

/// The object picked for an object scan, as CaptureStore keeps it with the
/// run: Upload again and a resume after a relaunch send the same object.
struct ObjectPick: Codable, Equatable {

    /// Seconds into the video of the frame the points are on.
    let timeSeconds: TimeInterval
    /// Each a fraction of the frame as displayed, from its top-left corner.
    let points: [CGPoint]

    /// The pick as the SDK sends it.
    ///
    /// - Throws: `SceneSubject.Invalid` for a pick the API would refuse. The
    ///   picker can't make one: it takes 1 to 5 points, all inside the frame.
    func sceneSubject() throws -> SceneSubject {
        try SceneSubject(timeSeconds: timeSeconds, points: points)
    }
}

// MARK: - Captured

/// The capture is saved and nothing is sent yet: upload the whole scene, or
/// pick the one object to keep.
struct CapturedView: View {
    let videoURL: URL
    /// The last pick, when an object scan failed: the picker starts there.
    let previousPick: ObjectPick?
    /// `nil` uploads the whole scene.
    let onUpload: (ObjectPick?) -> Void
    let onDiscard: () -> Void

    @State private var isPicking = false
    @State private var confirmingDiscard = false

    var body: some View {
        Screen(
            title: "Captured",
            headline: "Capture saved",
            lead: "Nothing is sent or charged until you choose what to keep."
        ) {
            Section {
                FactRow(label: "Whole scene", layout: .stacked) {
                    Text("Everything the camera saw.")
                }
                if objectScanEnabled {
                    FactRow(label: "One object", layout: .stacked) {
                        Text("Tap the object in one frame of the video. Splat3D finds it in every frame and keeps only it, at the same price.")
                    }
                }
            }
        } actions: {
            Button("Upload whole scene") {
                onUpload(nil)
            }
            .actionStyle(.primary)

            // A build without object scans can still meet a capture that
            // waited here: it uploads whole.
            if objectScanEnabled {
                Button("Scan one object") {
                    isPicking = true
                }
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
            Text("The video and poses on this phone are deleted. Nothing was uploaded or charged.")
        }
        .fullScreenCover(isPresented: $isPicking) {
            ObjectPickView(
                videoURL: videoURL,
                initial: previousPick,
                onConfirm: { pick in
                    isPicking = false
                    onUpload(pick)
                },
                onCancel: { isPicking = false }
            )
        }
    }
}

// MARK: - Picker model

/// The recorded video, paused on one frame, and the points tapped on it.
@MainActor
final class ObjectPicker: ObservableObject {

    /// The API takes 1 to 5 points (SceneSubject).
    static let maxPoints = 5

    /// AVFoundation's usual timescale: whole frames at 24, 25, 30 and 60 fps.
    private static let timescale: CMTimeScale = 600

    /// How far before the end the scrubber stops, in seconds: at the very
    /// end there is no frame to show, and the API refuses a time past it.
    private static let endMargin: TimeInterval = 0.1

    private static let noVideoMessage = "The capture has no video to show."

    let player: AVPlayer

    /// The video's size as shown, once its track is read.
    @Published private(set) var displaySize: CGSize?
    /// Where the scrubber is, in seconds.
    @Published private(set) var scrubTime: TimeInterval = 0
    /// Fractions of the displayed frame, in the order tapped.
    @Published private(set) var points: [CGPoint] = []
    /// The player is still moving to the scrubber's frame.
    @Published private(set) var isSeeking = false
    @Published private(set) var loadError: String?

    private let videoURL: URL
    private let initial: ObjectPick?
    private var duration: TimeInterval = 0
    /// Bumped by every seek, so only the last one ends the seeking.
    private var seekGeneration = 0

    init(videoURL: URL, initial: ObjectPick?) {
        self.videoURL = videoURL
        self.initial = initial
        player = AVPlayer(url: videoURL)
    }

    /// The times the scrubber covers, or `nil` until the video is read.
    var scrubRange: ClosedRange<TimeInterval>? {
        let end = duration - Self.endMargin
        guard end > 0 else {
            return nil
        }
        return 0...end
    }

    /// The pick as it stands, or `nil` with no points or mid-seek, when the
    /// frame on screen isn't yet the player's.
    var pick: ObjectPick? {
        guard !points.isEmpty, !isSeeking else {
            return nil
        }
        // The player's own time: the timeline a browser's currentTime uses.
        let seconds = player.currentTime().seconds
        return ObjectPick(timeSeconds: seconds.isFinite ? max(seconds, 0) : 0, points: points)
    }

    /// Read the video's shape and length, then show the first frame, or the
    /// frame of the last pick.
    func load() async {
        guard displaySize == nil else {
            return
        }

        let asset = AVURLAsset(url: videoURL)
        do {
            let length = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                loadError = Self.noVideoMessage
                return
            }
            // The track's turn makes the stored frame the displayed one.
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)

            displaySize = PickGeometry.displaySize(naturalSize: naturalSize, transform: transform)
            duration = length.isFinite ? length : 0
        } catch {
            loadError = error.localizedDescription
            return
        }

        seek(to: initial?.timeSeconds ?? 0)
        points = initial?.points ?? []
    }

    /// Show the frame at `seconds`, exactly: the player's time is what the
    /// pick reports. Points belong to one frame, so moving clears them.
    func seek(to seconds: TimeInterval) {
        scrubTime = seconds
        points = []
        seekGeneration += 1
        isSeeking = true

        let generation = seekGeneration
        let time = CMTime(seconds: seconds, preferredTimescale: Self.timescale)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.seekEnded(generation)
            }
        }
    }

    private func seekEnded(_ generation: Int) {
        // An earlier seek, overtaken while the scrubber kept moving.
        guard generation == seekGeneration else {
            return
        }
        isSeeking = false
    }

    /// Add a point, a fraction of the displayed frame. Ignored mid-seek and
    /// past the API's five.
    func add(_ point: CGPoint) {
        guard !isSeeking, points.count < Self.maxPoints else {
            return
        }
        points.append(point)
    }

    func undo() {
        guard !points.isEmpty else {
            return
        }
        points.removeLast()
    }

    func clear() {
        points = []
    }
}

// MARK: - Picker

/// The recorded video with a scrubber: tap the object in one frame, up to
/// five times, then confirm.
struct ObjectPickView: View {

    @StateObject private var picker: ObjectPicker
    private let onConfirm: (ObjectPick) -> Void
    private let onCancel: () -> Void

    private static let controlSpacing: CGFloat = 12
    private static let secondsPerMinute = 60

    init(
        videoURL: URL,
        initial: ObjectPick?,
        onConfirm: @escaping (ObjectPick) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _picker = StateObject(wrappedValue: ObjectPicker(videoURL: videoURL, initial: initial))
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                videoFrame
                controls
            }
            .background(Palette.ground)
            .navigationTitle("Pick the object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .actionBar {
                Button("Upload object scan") {
                    guard let pick = picker.pick else {
                        return
                    }
                    onConfirm(pick)
                }
                .actionStyle(.primary)
                .disabled(picker.pick == nil)

                ActionNote(note)
            }
        }
        .task {
            await picker.load()
        }
    }

    /// The video, fitted whole, with the points over it. A tap inside the
    /// picture adds a point; a tap on the bars around it does nothing.
    private var videoFrame: some View {
        GeometryReader { geometry in
            let videoRect = picker.displaySize.map { PickGeometry.videoRect(displaySize: $0, in: geometry.size) } ?? .zero

            ZStack {
                PlayerSurface(player: picker.player)

                ForEach(Array(picker.points.enumerated()), id: \.offset) { index, point in
                    PickMarker(number: index + 1)
                        .position(PickGeometry.position(of: point, in: videoRect))
                }

                if let loadError = picker.loadError {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(Theme.margin)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    guard let point = PickGeometry.fraction(of: tap.location, in: videoRect) else {
                        return
                    }
                    picker.add(point)
                }
            )
        }
        .background(Color.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video frame, \(pointsText)")
        .accessibilityHint("Tap the object to add a point")
    }

    /// The scrubber with its time, then the points with Undo and Clear.
    private var controls: some View {
        VStack(spacing: Self.controlSpacing) {
            if let range = picker.scrubRange {
                HStack(spacing: Self.controlSpacing) {
                    Slider(value: scrubbing, in: range)
                        .tint(Palette.accent)
                        .accessibilityLabel("Frame")
                        .accessibilityValue(clock)
                    Text(clock)
                        .typeStyle(.data)
                        .monospacedDigit()
                }
            }

            HStack(spacing: Self.controlSpacing) {
                Text(pointsText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Undo") {
                    picker.undo()
                }
                .actionStyle(.secondary, width: .fitted)
                .disabled(picker.points.isEmpty)

                Button("Clear") {
                    picker.clear()
                }
                .actionStyle(.secondary, width: .fitted)
                .disabled(picker.points.isEmpty)
            }
        }
        .padding(Theme.margin)
    }

    /// The scrubber's position. Moving it seeks, which clears the points.
    private var scrubbing: Binding<TimeInterval> {
        Binding(
            get: { picker.scrubTime },
            set: { picker.seek(to: $0) }
        )
    }

    /// "1:05.4" for 65.4 seconds.
    private var clock: String {
        let minutes = Int(picker.scrubTime) / Self.secondsPerMinute
        let seconds = picker.scrubTime - Double(minutes * Self.secondsPerMinute)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    /// "2 of 5 points".
    private var pointsText: String {
        "\(picker.points.count) of \(ObjectPicker.maxPoints) points"
    }

    private var note: String {
        guard !picker.points.isEmpty else {
            return "Scrub to a frame that shows the object, then tap it. Up to \(ObjectPicker.maxPoints) points, all on the same object."
        }
        return "Splat3D finds this object in every frame and keeps only it. Charged as a normal scene."
    }
}

// MARK: - Picker parts

/// A numbered dot where the object was tapped.
private struct PickMarker: View {
    let number: Int

    private static let size: CGFloat = 26
    private static let ringWidth: CGFloat = 2

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: Self.size, height: Self.size)
            .background(Palette.accent, in: Circle())
            .overlay {
                // White, to stand off any picture.
                Circle()
                    .stroke(.white, lineWidth: Self.ringWidth)
            }
            .accessibilityHidden(true)
    }
}

/// The player's picture, fitted whole and centered: `.resizeAspect`, which
/// PickGeometry.videoRect mirrors. It takes no touches: the taps are SwiftUI's.
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

/// A view whose layer is the player's, so the picture follows its bounds.
private final class PlayerLayerView: UIView {

    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        // layerClass makes this the layer's type.
        layer as! AVPlayerLayer
    }
}
