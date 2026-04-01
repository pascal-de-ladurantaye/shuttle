import Foundation

public enum ShuttleProfile: String, CaseIterable, Codable, Sendable {
    case prod
    case dev

    public static let environmentKey = "SHUTTLE_PROFILE"
    public static let infoPlistKey = "ShuttleProfile"

    public init(value: String?) {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dev", "development":
            self = .dev
        default:
            self = .prod
        }
    }

    public static var current: ShuttleProfile {
        current(environment: ProcessInfo.processInfo.environment, bundle: .main)
    }

    public static func current(
        environment: [String: String],
        bundle: Bundle = .main
    ) -> ShuttleProfile {
        if let value = environment[environmentKey], !value.isEmpty {
            return ShuttleProfile(value: value)
        }
        if let value = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String, !value.isEmpty {
            return ShuttleProfile(value: value)
        }
        return .prod
    }

    public var appDisplayName: String {
        switch self {
        case .prod:
            return "Shuttle"
        case .dev:
            return "Shuttle Dev"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .prod:
            return "com.pascaldeladurantaye.shuttle"
        case .dev:
            return "com.pascaldeladurantaye.shuttle.dev"
        }
    }

    public var configDirectoryName: String {
        switch self {
        case .prod:
            return "shuttle"
        case .dev:
            return "shuttle-dev"
        }
    }

    public var appSupportDirectoryName: String {
        switch self {
        case .prod:
            return "Shuttle"
        case .dev:
            return "Shuttle Dev"
        }
    }

    public var defaultSessionRoot: String {
        switch self {
        case .prod:
            return "~/Workspaces"
        case .dev:
            return "~/Workspaces-Dev"
        }
    }

    public var defaultTriesRoot: String {
        "~/src/tries"
    }

    public var userDefaultsSuiteName: String {
        bundleIdentifier
    }

    public var distDirectory: String {
        switch self {
        case .prod:
            return "dist/macos"
        case .dev:
            return "dist/macos-dev"
        }
    }
}
