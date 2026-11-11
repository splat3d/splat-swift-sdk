import CoreGraphics
import Foundation

// MARK: - SceneSubject

/// The one object a masked scan keeps: a moment in the video, and 1 to 5
/// points on the object in that frame. The pipeline finds the object in every
/// frame from them and trains only it.
///
/// ```swift
/// let subject = try SceneSubject(timeSeconds: 12.4, points: [CGPoint(x: 0.52, y: 0.61)])
/// let scene = try await client.createAndProcess(videoURL: video, subject: subject)
/// ```
///
/// Points are fractions of the frame as a player shows it: the track's
/// rotation applied, from the top-left corner, without any letterbox bars.
/// `(0.5, 0.5)` is the center.
///
/// Where masking is switched off, creating a scene with a subject throws
/// ``SplatError/requestFailed(_:)`` with status 403 and code `feature_disabled`.
public struct SceneSubject: Sendable, Equatable {

    /// Why a subject can't be made. Nothing was sent.
    public enum Invalid: Error, LocalizedError, Sendable, Equatable {
        /// The time is negative or not finite.
        case time(TimeInterval)
        /// There are no points, or more than five.
        case pointCount(Int)
        /// A point lies outside the frame.
        case coordinate(CGPoint)

        public var errorDescription: String? {
            switch self {
            case .time(let time):
                return "A subject's time is 0 seconds or more into the video, not \(time)."
            case .pointCount(let count):
                let range = SceneSubject.pointRange
                return "A subject takes \(range.lowerBound) to \(range.upperBound) points, not \(count)."
            case .coordinate(let point):
                return "A subject's points are fractions of the frame, from 0 to 1, not (\(Double(point.x)), \(Double(point.y)))."
            }
        }
    }

    /// The API's bounds: SUBJECT_MIN_POINTS, SUBJECT_MAX_POINTS,
    /// SUBJECT_COORD_MIN, SUBJECT_COORD_MAX and SUBJECT_TIME_MIN in the
    /// Splat3D repo's packages/core.
    static let pointRange = 1...5
    static let coordinateRange: ClosedRange<CGFloat> = 0...1
    static let minimumTime: TimeInterval = 0

    /// Seconds into the video of the frame the points are on, as a player's
    /// current time reports it.
    public let timeSeconds: TimeInterval

    /// 1 to 5 points on the object, each a fraction of the frame from 0 to 1.
    public let points: [CGPoint]

    /// Make a subject, checking it as the API would.
    ///
    /// - Parameters:
    ///   - timeSeconds: Seconds into the video, 0 or more.
    ///   - points: 1 to 5 points on one object, each coordinate from 0 to 1.
    /// - Throws: ``Invalid`` for a value the API would refuse.
    public init(timeSeconds: TimeInterval, points: [CGPoint]) throws {
        guard timeSeconds.isFinite, timeSeconds >= Self.minimumTime else {
            throw Invalid.time(timeSeconds)
        }
        guard Self.pointRange.contains(points.count) else {
            throw Invalid.pointCount(points.count)
        }
        // NaN is in no range, so it is refused here too.
        if let outside = points.first(where: { !Self.isInFrame($0) }) {
            throw Invalid.coordinate(outside)
        }

        self.timeSeconds = timeSeconds
        self.points = points
    }

    private static func isInFrame(_ point: CGPoint) -> Bool {
        coordinateRange.contains(point.x) && coordinateRange.contains(point.y)
    }
}

// MARK: - Subject Request Body (internal)

/// `subject` in the body of `POST /v1/scenes`:
/// `{"time_s": 12.4, "points": [[0.52, 0.61], [0.5, 0.7]]}`.
struct SubjectBody: Encodable {
    let timeSeconds: Double
    let points: [[Double]]

    enum CodingKeys: String, CodingKey {
        case timeSeconds = "time_s"
        case points
    }

    init(_ subject: SceneSubject) {
        timeSeconds = subject.timeSeconds
        points = subject.points.map { [Double($0.x), Double($0.y)] }
    }
}
