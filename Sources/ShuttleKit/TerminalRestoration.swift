import Foundation

public enum ShuttleTerminalRestorationPolicy {
    public static let maxScrollbackLinesPerTab = 4_000
    public static let maxScrollbackCharactersPerTab = 400_000

    public static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let lineLimited = tailLines(text, maxLines: maxScrollbackLinesPerTab)
        guard lineLimited.contains(where: { !$0.isWhitespace }) else { return nil }
        if lineLimited.count <= maxScrollbackCharactersPerTab {
            return lineLimited
        }
        let initialStart = lineLimited.index(
            lineLimited.endIndex,
            offsetBy: -maxScrollbackCharactersPerTab
        )
        let safeStart = ansiSafeTruncationStart(in: lineLimited, initialStart: initialStart)
        return String(lineLimited[safeStart...])
    }

    private static func tailLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        var trimmed = lines.suffix(maxLines).joined(separator: "\n")
        if text.hasSuffix("\n") {
            trimmed.append("\n")
        }
        return trimmed
    }

    private static func ansiSafeTruncationStart(
        in text: String,
        initialStart: String.Index
    ) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

public enum ShuttleScrollbackReplayStore {
    public static let environmentKey = "SHUTTLE_RESTORE_SCROLLBACK_FILE"

    private static let persistentDirectoryName = "terminal-restoration-scrollback"
    private static let temporaryDirectoryName = "shuttle-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    public static func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        guard let replayText = normalizedReplayText(scrollback) else { return [:] }
        guard let replayFileURL = writeReplayFile(contents: replayText, tempDirectory: tempDirectory) else {
            return [:]
        }
        return [environmentKey: replayFileURL.path]
    }

    public static func replayEnvironment(
        forTabRawID tabRawID: Int64,
        paths: ShuttlePaths = ShuttlePaths()
    ) -> [String: String] {
        let fileURL = snapshotFileURL(forTabRawID: tabRawID, paths: paths)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            return [:]
        }
        return [environmentKey: fileURL.path]
    }

    public static func persist(
        scrollback: String?,
        forTabRawID tabRawID: Int64,
        paths: ShuttlePaths = ShuttlePaths()
    ) throws {
        let fileManager = FileManager.default
        let fileURL = snapshotFileURL(forTabRawID: tabRawID, paths: paths)

        guard let normalized = ShuttleTerminalRestorationPolicy.truncatedScrollback(scrollback) else {
            try? fileManager.removeItem(at: fileURL)
            return
        }

        guard let data = normalized.data(using: .utf8) else { return }
        try paths.ensureDirectories(fileManager: fileManager)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public static func snapshotFileURL(
        forTabRawID tabRawID: Int64,
        paths: ShuttlePaths = ShuttlePaths()
    ) -> URL {
        paths.appSupportURL
            .appending(path: persistentDirectoryName, directoryHint: .isDirectory)
            .appending(path: "tab-\(tabRawID).txt")
    }

    private static func normalizedReplayText(_ scrollback: String?) -> String? {
        guard let truncated = ShuttleTerminalRestorationPolicy.truncatedScrollback(scrollback) else {
            return nil
        }
        return ansiSafeReplayText(truncated)
    }

    private static func ansiSafeReplayText(_ text: String) -> String {
        guard text.contains(ansiEscape) else { return text }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return output
    }

    private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let directory = tempDirectory.appendingPathComponent(temporaryDirectoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("txt")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}
