import Foundation
import ShuttleKit

actor GhosttyCheckpointWriter {
    struct PendingCheckpoint {
        var title: String?
        var cwd: String?
        var scrollback: String?
        var hasScrollbackUpdate = false
    }

    static let shared = GhosttyCheckpointWriter()

    private var store: WorkspaceStore?
    private var pending: [Int64: PendingCheckpoint] = [:]
    private var tasks: [Int64: Task<Void, Never>] = [:]

    func configure(store: WorkspaceStore) {
        self.store = store
    }

    func schedule(tabRawID: Int64, title: String? = nil, cwd: String? = nil) {
        var checkpoint = pending[tabRawID] ?? PendingCheckpoint()
        if let normalizedTitle = normalizedValue(title) {
            checkpoint.title = normalizedTitle
        }
        if let normalizedCwd = normalizedValue(cwd) {
            checkpoint.cwd = normalizedCwd
        }
        pending[tabRawID] = checkpoint
        scheduleFlush(for: tabRawID)
    }

    func scheduleScrollback(tabRawID: Int64, scrollback: String) {
        var checkpoint = pending[tabRawID] ?? PendingCheckpoint()
        checkpoint.scrollback = scrollback
        checkpoint.hasScrollbackUpdate = true
        pending[tabRawID] = checkpoint
        scheduleFlush(for: tabRawID)
    }

    func flushAll() async {
        let tabIDs = Array(pending.keys)
        for tabRawID in tabIDs {
            await flush(tabRawID: tabRawID)
        }
    }

    func discard(tabRawIDs: [Int64]) {
        for tabRawID in tabRawIDs {
            tasks[tabRawID]?.cancel()
            tasks[tabRawID] = nil
            pending[tabRawID] = nil
        }
    }

    private func flush(tabRawID: Int64) async {
        tasks[tabRawID] = nil
        guard let checkpoint = pending.removeValue(forKey: tabRawID) else { return }
        guard let store else { return }
        try? await store.checkpointTab(
            rawID: tabRawID,
            title: checkpoint.title,
            cwd: checkpoint.cwd,
            scrollback: checkpoint.scrollback,
            updateScrollback: checkpoint.hasScrollbackUpdate
        )
    }

    private func scheduleFlush(for tabRawID: Int64) {
        tasks[tabRawID]?.cancel()
        tasks[tabRawID] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            await self.flush(tabRawID: tabRawID)
        }
    }

    private func normalizedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
