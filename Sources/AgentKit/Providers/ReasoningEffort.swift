import Foundation

/// The stable reasoning scale exposed to callers.
///
/// A model may support only a subset; `ModelCapabilityResolver` owns that
/// provider-specific capability and wire mapping.
public nonisolated enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, minimal, low, medium, high, xHigh, max

    public nonisolated var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: String(localized: "Off", bundle: .module)
        case .minimal: String(localized: "Minimal", bundle: .module)
        case .low: String(localized: "Low", bundle: .module)
        case .medium: String(localized: "Medium", bundle: .module)
        case .high: String(localized: "High", bundle: .module)
        case .xHigh: String(localized: "Extra High", bundle: .module)
        case .max: String(localized: "Max", bundle: .module)
        }
    }
}
