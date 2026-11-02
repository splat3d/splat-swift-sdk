import Foundation
import Splat3D

// MARK: - What the account allows before a capture
//
// The server enforces every rule, so these only say early what it would say
// late, after a scan is uploaded. Before the account loads, or when it failed
// to, nothing is known and nothing blocks.
//
//   not enough credits for the preset     blocks Start
//   monthly scene limit used up           blocks Start
//   scenes processing at the plan's cap   warns: a scan still starts, and
//                                         its launch waits for a free slot

struct CaptureRules: Equatable {

    enum Block: Equatable {
        case credits(preset: ScenePreset, needed: Int, have: Int)
        /// The plan's scenes per month, all used.
        case monthlyLimit(Int)
    }

    /// Why Start stays off, if it does.
    let block: Block?
    /// Said beside the preset: what it costs, once known.
    let cost: Int?
    /// Said when scenes already fill the plan's slots, with Start still on.
    let processing: Int?

    init(account: Account?, usage: Usage?, preset: ScenePreset) {
        cost = account?.presets.first { $0.preset == preset }?.credits

        if let usage, let limit = Self.exhaustedLimit(usage) {
            block = .monthlyLimit(limit)
        } else if let account, let cost, account.creditBalance < cost {
            block = .credits(preset: preset, needed: cost, have: account.creditBalance)
        } else {
            block = nil
        }

        if let account, account.running >= account.maxRunning {
            processing = account.running
        } else {
            processing = nil
        }
    }

    var blocksStart: Bool {
        block != nil
    }

    /// The limit that is used up: scenes created, else scenes processed.
    private static func exhaustedLimit(_ usage: Usage) -> Int? {
        if let limit = usage.limits.scenesCreated, usage.scenesCreated >= limit {
            return limit
        }
        if let limit = usage.limits.scenesProcessed, usage.scenesProcessed >= limit {
            return limit
        }
        return nil
    }
}

// MARK: - In words

extension CaptureRules.Block {

    var title: String {
        switch self {
        case .credits:
            return "Not enough credits"
        case .monthlyLimit:
            return "Monthly limit reached"
        }
    }

    var detail: String {
        switch self {
        case .credits(let preset, let needed, let have):
            return "\(preset.rawValue.capitalized) needs \(needed) credits. You have \(have)."
        case .monthlyLimit(let limit):
            return "You've used all \(limit) scenes this month."
        }
    }
}

extension CaptureRules {

    /// "2 scenes are processing. You can scan now; it starts when one
    /// finishes, or tap Resume."
    var warning: String? {
        guard let processing else {
            return nil
        }
        let count = processing == 1 ? "1 scene is" : "\(processing) scenes are"
        return "\(count) processing. You can scan now; it starts when one finishes, or tap Resume."
    }
}
