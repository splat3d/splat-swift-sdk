import SwiftUI
import UIKit
import Splat3D

// MARK: - Splat3D Integration: Scene details
//
// A SplatScene carries what the API knows about how the scene was made:
//
//   preset, trainingTime, processing stamps, numGaussians ──> first, no header
//   psnrHoldout, ssimHoldout, psnr ─────────────────────────> Quality
//   modelSizes (spz, sog, ply) ─────────────────────────────> Files
//   id, createdAt, processingCompletedAt, isPublic ─────────> Scene
//
// The preset, times, sizes and training PSNR come from API 1.5.0 on, the
// holdout metrics from 1.3.0. An older API doesn't send them, so they read
// nil, and a row without a value isn't shown.

// MARK: - Facts in words

/// How the app writes a scene's numbers: in the user's locale, through
/// FormatStyle, so "24.3 dB" reads "24,3 dB" in German.
enum FactFormat {

    /// "4 min, 36 sec": the two largest units, rounded to the second.
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    /// "24.3 dB".
    static func psnr(_ decibels: Double) -> String {
        "\(decibels.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    /// "0.812".
    static func ssim(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }

    /// "1.94M", "820K".
    static func splats(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// "41 MB", as Files shows it.
    static func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file))
    }

    /// "Oct 13, 2026 at 9:41 AM".
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension SplatScene {

    /// The longest span between the processing stamps that is a run, as on
    /// splat-3d.com: the stale-job sweep fails a job after 150 min, so a
    /// longer one is a stale stamp (a retrain once read 72 h), not a run.
    private static let longestRun: TimeInterval = 6 * 60 * 60

    /// "Standard". `nil` when the API names no preset.
    var presetName: String? {
        preset?.rawValue.capitalized
    }

    /// Seconds from launch to complete, every stage and the queue included.
    /// `nil` when a stamp is missing, they are out of order, or they span
    /// more than 6 hours.
    var processingDuration: TimeInterval? {
        guard let start = processingStartedAt, let end = processingCompletedAt else {
            return nil
        }
        let seconds = end.timeIntervalSince(start)
        guard seconds >= 0, seconds <= Self.longestRun else {
            return nil
        }
        return seconds
    }

    /// Whether the API sent any quality metric.
    fileprivate var hasMetrics: Bool {
        psnrHoldout != nil || ssimHoldout != nil || psnr != nil
    }

    /// Whether the API sent a holdout metric.
    fileprivate var hasHoldout: Bool {
        psnrHoldout != nil || ssimHoldout != nil
    }
}

// MARK: - Info sheet

/// A scene's details, from the viewer's Info button: an inset grouped list
/// of label and value rows. A row shows only with a value, and a section
/// only with a row, so a scene from an older API shows what it has and no
/// empty rows.
struct SceneInfoSheet: View {
    let scene: SplatScene
    /// The file the viewer shows, marked in Files.
    let viewing: ModelFormat?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                summary
                quality
                files
                about
            }
            .listStyle(.insetGrouped)
            .navigationTitle(scene.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Opaque, as a list's ground: iOS 26's glass at the medium detent
        // takes the viewer's black behind it, and in light mode read grey,
        // with grey text on it at about 2:1.
        .presentationBackground(Palette.ground)
    }

    // MARK: Summary

    /// The Ready screen's facts, plus total processing, with no header:
    /// at the medium detent the sheet opens at, this is what fits.
    @ViewBuilder
    private var summary: some View {
        let total = scene.processingDuration
        if scene.preset != nil || scene.trainingTime != nil || total != nil || scene.numGaussians != nil {
            Section {
                if let preset = scene.presetName {
                    FactRow(label: "Preset") {
                        Text(preset)
                    }
                }
                if let training = scene.trainingTime {
                    FactRow(label: "Training") {
                        Text(FactFormat.duration(training))
                    }
                }
                if let total {
                    FactRow(label: "Total processing") {
                        Text(FactFormat.duration(total))
                    }
                }
                if let count = scene.numGaussians {
                    FactRow(label: "Splats") {
                        Text(FactFormat.splats(count))
                            .typeStyle(.data)
                    }
                }
            }
        }
    }

    // MARK: Quality

    @ViewBuilder
    private var quality: some View {
        if scene.hasMetrics {
            Section {
                if let psnr = scene.psnrHoldout {
                    FactRow(label: "Holdout PSNR") {
                        Text(FactFormat.psnr(psnr))
                            .typeStyle(.data)
                    }
                }
                if let ssim = scene.ssimHoldout {
                    FactRow(label: "Holdout SSIM") {
                        Text(FactFormat.ssim(ssim))
                            .typeStyle(.data)
                    }
                }
                if let psnr = scene.psnr {
                    FactRow(label: "Training PSNR") {
                        Text(FactFormat.psnr(psnr))
                            .typeStyle(.data)
                    }
                }
            } header: {
                Text("Quality")
            } footer: {
                Text(metricsNote)
            }
        }
    }

    /// What the metrics shown mean, in plain words.
    private var metricsNote: String {
        var sentences = [
            scene.ssimHoldout == nil
                ? "PSNR compares the model's renders with your photos, in dB."
                : "PSNR (in dB) and SSIM (up to 1) compare the model's renders with your photos.",
            "Higher is better.",
        ]
        if scene.hasHoldout {
            sentences.append("Holdout uses photos the model never trained on, so it's the fairer number.")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Files

    @ViewBuilder
    private var files: some View {
        let sizes = scene.modelSizes
        if sizes.spz != nil || sizes.sog != nil || sizes.ply != nil {
            Section("Files") {
                if let bytes = sizes.spz {
                    fileRow(.spz, bytes: bytes)
                }
                if let bytes = sizes.sog {
                    fileRow(.sog, bytes: bytes)
                }
                if let bytes = sizes.ply {
                    fileRow(.ply, bytes: bytes)
                }
            }
        }
    }

    /// "SPZ   Viewing · 41 MB": the size in mono, after "Viewing" for the
    /// file on screen.
    private func fileRow(_ format: ModelFormat, bytes: Int) -> some View {
        FactRow(label: format.rawValue.uppercased()) {
            let size = TypeStyle.data.text(FactFormat.bytes(bytes), at: dynamicTypeSize)
            if format == viewing {
                Text("\(Text("Viewing").foregroundStyle(Palette.accent)) · \(size)")
            } else {
                size
            }
        }
    }

    // MARK: Scene

    private var about: some View {
        Section("Scene") {
            FactRow(label: "ID") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(scene.id)
                        .typeStyle(.data)
                        .textSelection(.enabled)
                    CopyButton(text: scene.id, label: "Copy ID")
                }
            }
            FactRow(label: "Created") {
                Text(FactFormat.dateTime(scene.createdAt))
            }
            // No start: after a retrain it can be an earlier run's, which
            // processingDuration's 6 h guard keeps out of Total processing.
            if let finished = scene.processingCompletedAt {
                FactRow(label: "Finished") {
                    Text(FactFormat.dateTime(finished))
                }
            }
            FactRow(label: "Visibility") {
                Text(scene.isPublic ? "Public" : "Private")
            }
        }
    }
}

/// Copies text to the pasteboard. Its symbol turns to a check for a moment,
/// with a tap of haptics, so the copy shows.
private struct CopyButton: View {
    let text: String
    /// For VoiceOver: "Copy ID".
    let label: String

    /// Taps so far. Each one starts the check's moment again.
    @State private var copies = 0
    @State private var showsCheck = false

    private static let confirmation: Duration = .seconds(2)

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copies += 1
        } label: {
            Label(showsCheck ? "Copied" : label, systemImage: showsCheck ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.success, trigger: copies)
        .task(id: copies) {
            guard copies > 0 else {
                return
            }
            showsCheck = true
            do {
                try await Task.sleep(for: Self.confirmation)
            } catch {
                // A newer tap took over, and keeps the check.
                return
            }
            showsCheck = false
        }
    }
}
