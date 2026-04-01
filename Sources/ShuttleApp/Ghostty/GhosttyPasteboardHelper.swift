import Foundation
import AppKit
import UniformTypeIdentifiers
import ImageIO

enum GhosttyPasteboardHelper {
    struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
    private static let objectReplacementCharacter = Character(UnicodeScalar(0xFFFC)!)

    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.heif.identifier),
    ]

    static func terminalReadyText(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let value = pasteboard.string(forType: .string) {
            return value
        }

        if let value = pasteboard.string(forType: utf8PlainTextType) {
            return value
        }

        if let htmlText = attributedStringContents(from: pasteboard, type: .html, documentType: .html) {
            return htmlText
        }

        if let rtfText = attributedStringContents(from: pasteboard, type: .rtf, documentType: .rtf) {
            return rtfText
        }

        if let imagePath = saveClipboardImageIfNeeded(from: pasteboard) {
            return imagePath
        }

        return nil
    }

    static func escapeForShell(_ value: String) -> String {
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return shellSingleQuoted(value)
        }
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func attributedStringContents(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType,
        documentType: NSAttributedString.DocumentType
    ) -> String? {
        let data = pasteboard.data(forType: type) ?? pasteboard.string(forType: type)?.data(using: .utf8)
        guard let data else { return nil }

        let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: documentType,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )

        let sanitized = attributed?.string
            .split(separator: objectReplacementCharacter, omittingEmptySubsequences: false)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let sanitized, !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private static func hasImageData(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.tiff) || types.contains(.png) {
            return true
        }
        return types.contains { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image)
        }
    }

    static func saveClipboardImageIfNeeded(from pasteboard: NSPasteboard = .general) -> String? {
        if terminalReadyTextIgnoringImages(from: pasteboard) != nil { return nil }
        guard hasImageData(in: pasteboard) else { return nil }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let filename = "clipboard-\(timestamp)-\(UUID().uuidString.prefix(8)).png"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try pngData.write(to: fileURL)
            return escapeForShell(fileURL.path)
        } catch {
            return nil
        }
    }

    static func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let representations = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
            return PasteboardItemSnapshot(representations: representations)
        }
    }

    static func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        _ = pasteboard.clearContents()
        guard !snapshots.isEmpty else { return }

        let restoredItems = snapshots.compactMap { snapshot -> NSPasteboardItem? in
            guard !snapshot.representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        guard !restoredItems.isEmpty else { return }
        _ = pasteboard.writeObjects(restoredItems)
    }

    static func readGeneralPasteboardString(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let firstURL = urls.first,
           firstURL.isFileURL {
            return firstURL.path
        }
        if let value = pasteboard.string(forType: .string) {
            return value
        }
        return pasteboard.string(forType: utf8PlainTextType)
    }

    static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.isFileURL, !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    private static func terminalReadyTextIgnoringImages(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }
        if let value = pasteboard.string(forType: .string) {
            return value
        }
        if let value = pasteboard.string(forType: utf8PlainTextType) {
            return value
        }
        if let htmlText = attributedStringContents(from: pasteboard, type: .html, documentType: .html) {
            return htmlText
        }
        if let rtfText = attributedStringContents(from: pasteboard, type: .rtf, documentType: .rtf) {
            return rtfText
        }
        return nil
    }
}
