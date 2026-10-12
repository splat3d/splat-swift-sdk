import Foundation

// MARK: - Usage

/// Usage for the current billing period, from ``SplatClient/getUsage()``.
public struct Usage: Decodable, Sendable, Equatable {

    /// Billing period as `YYYY-MM` (UTC), e.g. `"2026-09"`.
    public let period: String

    /// Scenes created this period.
    public let scenesCreated: Int

    /// Scenes processed this period.
    public let scenesProcessed: Int

    /// GPU seconds recorded this period. Always 0: nothing counts it, and the
    /// API deprecated the field in 1.2.0.
    public let gpuSecondsUsed: Int

    /// Storage bytes recorded this period. Always 0: nothing counts it, and
    /// the API deprecated the field in 1.2.0.
    public let storageBytes: Int64

    /// Your plan's limits for this period.
    public let limits: Limits

    /// Create usage, e.g. for a test double.
    public init(
        period: String,
        scenesCreated: Int,
        scenesProcessed: Int,
        gpuSecondsUsed: Int,
        storageBytes: Int64,
        limits: Limits
    ) {
        self.period = period
        self.scenesCreated = scenesCreated
        self.scenesProcessed = scenesProcessed
        self.gpuSecondsUsed = gpuSecondsUsed
        self.storageBytes = storageBytes
        self.limits = limits
    }

    enum CodingKeys: String, CodingKey {
        case period
        case scenesCreated = "scenes_created"
        case scenesProcessed = "scenes_processed"
        case gpuSecondsUsed = "gpu_seconds_used"
        case storageBytes = "storage_bytes"
        case limits
    }

    // The deprecated fields read 0 when absent, so getUsage() keeps working
    // once the API removes them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        period = try container.decode(String.self, forKey: .period)
        scenesCreated = try container.decode(Int.self, forKey: .scenesCreated)
        scenesProcessed = try container.decode(Int.self, forKey: .scenesProcessed)
        gpuSecondsUsed = try container.decodeIfPresent(Int.self, forKey: .gpuSecondsUsed) ?? 0
        storageBytes = try container.decodeIfPresent(Int64.self, forKey: .storageBytes) ?? 0
        limits = try container.decode(Limits.self, forKey: .limits)
    }

    // MARK: - Limits

    /// Plan limits that ``Usage`` counts against.
    public struct Limits: Decodable, Sendable, Equatable {

        /// Scenes you can create per period, or `nil` for unlimited.
        public let scenesCreated: Int?

        /// Scenes you can process per period, or `nil` for unlimited.
        public let scenesProcessed: Int?

        /// GPU seconds per period. Not enforced; the API deprecated the field
        /// in 1.2.0.
        public let gpuSeconds: Int

        /// Storage quota in bytes. Not enforced; the API deprecated the field
        /// in 1.2.0.
        public let storageBytes: Int64

        /// Create limits, e.g. for a test double. `nil` means unlimited.
        public init(scenesCreated: Int?, scenesProcessed: Int?, gpuSeconds: Int, storageBytes: Int64) {
            self.scenesCreated = scenesCreated
            self.scenesProcessed = scenesProcessed
            self.gpuSeconds = gpuSeconds
            self.storageBytes = storageBytes
        }

        enum CodingKeys: String, CodingKey {
            case scenesCreated = "scenes_created"
            case scenesProcessed = "scenes_processed"
            case gpuSeconds = "gpu_seconds"
            case storageBytes = "storage_bytes"
        }

        // As in Usage: the deprecated limits read 0 when absent.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scenesCreated = try container.decodeIfPresent(Int.self, forKey: .scenesCreated)
            scenesProcessed = try container.decodeIfPresent(Int.self, forKey: .scenesProcessed)
            gpuSeconds = try container.decodeIfPresent(Int.self, forKey: .gpuSeconds) ?? 0
            storageBytes = try container.decodeIfPresent(Int64.self, forKey: .storageBytes) ?? 0
        }
    }
}
