import Foundation
import ShuttleKit

@MainActor
final class LayoutLibraryModel: ObservableObject {
    @Published private(set) var presets: [LayoutPreset] = []
    @Published var selectedPresetID: String?
    @Published var lastErrorMessage: String?

    private let store: LayoutPresetStore

    init(paths: ShuttlePaths = ShuttlePaths()) {
        self.store = LayoutPresetStore(paths: paths)
        reload()
    }

    var selectedPreset: LayoutPreset? {
        preset(id: selectedPresetID)
    }

    func preset(id: String?) -> LayoutPreset? {
        guard let id else { return nil }
        return presets.first(where: { $0.id == id })
    }

    func displayName(for id: String?) -> String {
        preset(id: id)?.name ?? "Single"
    }

    func summary(for id: String?) -> String {
        preset(id: id)?.summary ?? "1 pane • 1 tab template"
    }

    func resolvedPresetID(preferred id: String?) -> String {
        if let id, preset(id: id) != nil {
            return id
        }
        return presets.first?.id ?? LayoutPresetStore.defaultPresetID
    }

    func reload() {
        do {
            presets = try store.listPresets()
            ShuttlePreferences.sanitizeLayoutDefaults(validPresetIDs: Set(presets.map(\.id)))
            if selectedPresetID == nil || preset(id: selectedPresetID) == nil {
                selectedPresetID = presets.first?.id
            }
            lastErrorMessage = nil
        } catch {
            presets = LayoutPresetStore.builtInPresets
            selectedPresetID = presets.first?.id
            lastErrorMessage = error.localizedDescription
        }
    }

    func createPreset(from source: LayoutPreset? = nil) {
        let basePreset = (source ?? selectedPreset ?? presets.first ?? LayoutPresetStore.builtInPresets.first)
            ?? LayoutPreset(
                id: LayoutPresetStore.defaultPresetID,
                name: "Single",
                origin: .builtIn,
                root: LayoutPaneTemplate()
            )

        let existingNames = Set(presets.map(\.name))
        let existingIDs = Set(presets.map(\.id))
        let baseName = basePreset.isBuiltIn ? "\(basePreset.name) Copy" : "\(basePreset.name) Variant"
        let name = uniqueName(base: baseName, existing: existingNames)
        let id = uniqueName(base: slugify(name), existing: existingIDs)

        do {
            try store.saveCustomPreset(
                LayoutPreset(
                    id: id,
                    name: name,
                    description: basePreset.description,
                    origin: .custom,
                    root: basePreset.root
                )
            )
            reload()
            selectedPresetID = id
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func duplicateSelectedPreset() {
        createPreset(from: selectedPreset)
    }

    func deleteSelectedPreset() {
        guard let preset = selectedPreset, !preset.isBuiltIn else { return }
        do {
            try store.deleteCustomPreset(id: preset.id)
            reload()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func renameSelectedPreset(to newName: String) {
        guard let selectedPresetID,
              let index = presets.firstIndex(where: { $0.id == selectedPresetID }),
              !presets[index].isBuiltIn else {
            return
        }

        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastErrorMessage = "Layout name cannot be empty"
            return
        }

        var preset = presets[index]
        guard preset.name != trimmedName else {
            lastErrorMessage = nil
            return
        }

        let previousID = preset.id
        preset.name = trimmedName

        do {
            let renamed = try store.renameCustomPreset(preset, previousID: previousID)
            ShuttlePreferences.replaceLayoutReference(from: previousID, to: renamed.id)
            reload()
            self.selectedPresetID = renamed.id
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateSelectedPreset(_ update: (inout LayoutPreset) -> Void) {
        guard let selectedPresetID,
              let index = presets.firstIndex(where: { $0.id == selectedPresetID }),
              !presets[index].isBuiltIn else {
            return
        }

        var preset = presets[index]
        update(&preset)
        preset = preset.normalized()

        do {
            try store.saveCustomPreset(preset)
            presets[index] = preset
            self.selectedPresetID = preset.id
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
