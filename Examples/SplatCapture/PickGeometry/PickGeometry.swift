import CoreGraphics

// MARK: - Splat3D Integration: From a tap to a subject point
//
// SceneSubject takes each point as a fraction of the frame as a player shows
// it: the track's preferredTransform applied, from the top-left corner, and
// inside the picture, not the letterbox bars around it.
//
//   stored frame ── preferredTransform ──> displayed frame ── aspect fit ──> video rect
//   1920 × 1440          a 90° turn          1440 × 1920                   in the box
//
//   ┌───────── box ─────────┐
//   │▒▒▒▒▒┌───────────┐▒▒▒▒▒│   ▒  letterbox bars: a tap there is no point
//   │▒▒▒▒▒│   video   │▒▒▒▒▒│
//   │▒▒▒▒▒│    rect   │▒▒▒▒▒│   a tap at (x, y) in the box is the point
//   │▒▒▒▒▒└───────────┘▒▒▒▒▒│   ((x − rect.minX) / rect.width, (y − rect.minY) / rect.height)
//   └───────────────────────┘
//
// Pure functions, so the package's tests run them without the app:
// PickGeometryTests.swift, beside this file.

enum PickGeometry {

    /// A fraction of the frame: both coordinates from 0 to 1.
    private static let unit: ClosedRange<CGFloat> = 0...1

    /// How far outside the picture, in points, a tap still counts as on its
    /// edge: rounding can put the edge a hair inside where it is drawn.
    private static let edgeTolerance: CGFloat = 0.5

    /// The size a player shows a track at: its stored size turned by its
    /// `preferredTransform`. SplatScanner stores 1920 × 1440 with a 90° turn,
    /// which shows as 1440 × 1920.
    static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        // The bounding box drops the transform's translation and sign.
        CGRect(origin: .zero, size: naturalSize).applying(transform).size
    }

    /// Where a video of `displaySize` sits in `box` when it is fitted whole
    /// and centered, as AVPlayerLayer's `.resizeAspect` draws it. Empty when
    /// either has no area.
    static func videoRect(displaySize: CGSize, in box: CGSize) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0, box.width > 0, box.height > 0 else {
            return .zero
        }

        let scale = min(box.width / displaySize.width, box.height / displaySize.height)
        let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)

        return CGRect(
            x: (box.width - size.width) / 2,
            y: (box.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The tap as a fraction of the video, from its top-left corner, or `nil`
    /// for a tap on the letterbox bars. A tap at the rect's center is
    /// (0.5, 0.5).
    static func fraction(of tap: CGPoint, in videoRect: CGRect) -> CGPoint? {
        guard videoRect.width > 0, videoRect.height > 0 else {
            return nil
        }

        let reach = videoRect.insetBy(dx: -edgeTolerance, dy: -edgeTolerance)
        guard (reach.minX...reach.maxX).contains(tap.x), (reach.minY...reach.maxY).contains(tap.y) else {
            return nil
        }

        // A tap on the edge is the edge: the API refuses anything past it.
        return CGPoint(
            x: clamped((tap.x - videoRect.minX) / videoRect.width),
            y: clamped((tap.y - videoRect.minY) / videoRect.height)
        )
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, unit.lowerBound), unit.upperBound)
    }

    /// Where a fraction of the video is in the box: the inverse of
    /// `fraction(of:in:)`, for drawing a point where it was tapped.
    static func position(of fraction: CGPoint, in videoRect: CGRect) -> CGPoint {
        CGPoint(
            x: videoRect.minX + fraction.x * videoRect.width,
            y: videoRect.minY + fraction.y * videoRect.height
        )
    }
}
