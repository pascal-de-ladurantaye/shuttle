import Foundation
import Darwin

public enum ShuttleError: LocalizedError, CustomStringConvertible, Sendable {
    case invalidCommand(String)
    case invalidArguments(String)
    case configMissing(String)
    case configInvalid(String)
    case notFound(entity: String, token: String)
    case io(String)
    case database(String)
    case unsupported(String)

    public var code: String {
        switch self {
        case .invalidCommand: return "invalid_command"
        case .invalidArguments: return "invalid_arguments"
        case .configMissing: return "config_missing"
        case .configInvalid: return "config_invalid"
        case .notFound: return "not_found"
        case .io: return "io_error"
        case .database: return "database_error"
        case .unsupported: return "unsupported"
        }
    }

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidCommand(let message),
             .invalidArguments(let message),
             .configMissing(let message),
             .configInvalid(let message),
             .io(let message),
             .database(let message),
             .unsupported(let message):
            return message
        case .notFound(let entity, let token):
            return "\(entity) '\(token)' was not found"
        }
    }
}

public struct ShuttlePaths: Sendable {
    public let profile: ShuttleProfile
    public let configDirectoryURL: URL
    public let configURL: URL
    public let appSupportURL: URL
    public let databaseURL: URL
    public let controlSocketURL: URL

    public init(
        fileManager: FileManager = .default,
        profile: ShuttleProfile = .current
    ) {
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let configDirectoryURL = homeURL.appending(path: ".config/\(profile.configDirectoryName)", directoryHint: .isDirectory)
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? homeURL.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let appSupportURL = appSupportBase.appending(path: profile.appSupportDirectoryName, directoryHint: .isDirectory)
        self.init(profile: profile, configDirectoryURL: configDirectoryURL, appSupportURL: appSupportURL)
    }

    public init(
        profile: ShuttleProfile = .prod,
        configDirectoryURL: URL,
        appSupportURL: URL
    ) {
        self.profile = profile
        self.configDirectoryURL = configDirectoryURL
        self.configURL = configDirectoryURL.appending(path: "config.json")
        self.appSupportURL = appSupportURL
        self.databaseURL = appSupportURL.appending(path: "state.sqlite")
        self.controlSocketURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("shuttle-\(profile.rawValue)-\(getuid()).sock")
    }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    }
}

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }
}

private final class PipeDrainer: @unchecked Sendable {
    private let handle: FileHandle
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let drained = handle.readDataToEndOfFile()
            lock.lock()
            data = drained
            lock.unlock()
            completion.signal()
        }
    }

    func waitForData() -> Data {
        completion.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

@discardableResult
public func runProcess(
    _ launchPath: String,
    arguments: [String],
    currentDirectoryPath: String? = nil,
    environment: [String: String]? = nil
) throws -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    if let currentDirectoryPath {
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
    }

    var fullEnvironment = ProcessInfo.processInfo.environment
    environment?.forEach { fullEnvironment[$0.key] = $0.value }
    process.environment = fullEnvironment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutDrainer = PipeDrainer(handle: stdoutPipe.fileHandleForReading)
    let stderrDrainer = PipeDrainer(handle: stderrPipe.fileHandleForReading)
    stdoutDrainer.start()
    stderrDrainer.start()

    do {
        try process.run()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    } catch {
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        _ = stdoutDrainer.waitForData()
        _ = stderrDrainer.waitForData()
        throw ShuttleError.io("Failed to start \(launchPath): \(error.localizedDescription)")
    }

    process.waitUntilExit()

    let stdoutData = stdoutDrainer.waitForData()
    let stderrData = stderrDrainer.waitForData()
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)

    return ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

public func slugify(_ value: String) -> String {
    let lowercased = value.lowercased()
    let pieces = lowercased
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    return pieces.joined(separator: "-")
}

public func expandedPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

public func bestMatchingPathRoot(for path: String, roots: [String]) -> String? {
    let standardizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    var bestMatch: String?

    for root in roots {
        let standardizedRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        guard standardizedPath == standardizedRoot || standardizedPath.hasPrefix(standardizedRoot + "/") else {
            continue
        }
        if let bestMatch {
            guard standardizedRoot.count > bestMatch.count else { continue }
        }
        bestMatch = standardizedRoot
    }

    return bestMatch
}

public func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

public func parseDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? Date(timeIntervalSince1970: 0)
}

public func uniqueName(base: String, existing: Set<String>) -> String {
    guard existing.contains(base) else { return base }
    var index = 2
    while existing.contains("\(base)-\(index)") {
        index += 1
    }
    return "\(base)-\(index)"
}

public enum ShuttleProgrammaticTerminalInputChunk: Equatable, Sendable {
    case text(String)
    case submit
}

public func shuttleProgrammaticTerminalInputChunks(for text: String) -> [ShuttleProgrammaticTerminalInputChunk] {
    guard !text.isEmpty else { return [] }

    var chunks: [ShuttleProgrammaticTerminalInputChunk] = []
    var buffer = ""
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        if character.isNewline {
            if !buffer.isEmpty {
                chunks.append(.text(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
            chunks.append(.submit)
        } else {
            buffer.append(character)
        }
        index = text.index(after: index)
    }

    if !buffer.isEmpty {
        chunks.append(.text(buffer))
    }

    return chunks
}

public func shuttleIncrementalTerminalText(previous: String, current: String) -> String {
    guard !previous.isEmpty else { return current }
    guard !current.isEmpty else { return "" }

    if current == previous || previous.hasSuffix(current) {
        return ""
    }

    if current.hasPrefix(previous) {
        return String(current.dropFirst(previous.count))
    }

    let previousCharacters = Array(previous)
    let currentCharacters = Array(current)
    let maxOverlap = min(previousCharacters.count, currentCharacters.count)

    guard maxOverlap > 0 else { return current }

    for overlap in stride(from: maxOverlap, through: 1, by: -1) {
        if previousCharacters.suffix(overlap).elementsEqual(currentCharacters.prefix(overlap)) {
            return String(currentCharacters.dropFirst(overlap))
        }
    }

    return current
}

public func convertGlobToRegex(_ glob: String) -> String {
    var regex = ""
    var index = glob.startIndex

    while index < glob.endIndex {
        let character = glob[index]
        if character == "*" {
            let nextIndex = glob.index(after: index)
            if nextIndex < glob.endIndex, glob[nextIndex] == "*" {
                regex += ".*"
                index = glob.index(after: nextIndex)
                continue
            }
            regex += "[^/]*"
        } else {
            let scalar = String(character)
            if #"\.^$+?()[]{}|"#.contains(character) {
                regex += "\\\(scalar)"
            } else {
                regex += scalar
            }
        }
        index = glob.index(after: index)
    }

    return "^\(regex)$"
}

public func pathMatchesAnyGlob(path: String, patterns: [String]) -> Bool {
    for pattern in patterns {
        let regexPattern = convertGlobToRegex(pattern)
        guard let expression = try? NSRegularExpression(pattern: regexPattern) else {
            continue
        }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        if expression.firstMatch(in: path, options: [], range: range) != nil {
            return true
        }
    }
    return false
}
