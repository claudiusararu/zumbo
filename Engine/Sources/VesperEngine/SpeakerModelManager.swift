import CoreML
import FluidAudio
import Foundation
import os

/// Speaker labeling's on-disk state, for the Settings > Models row and for
/// `MeetingSession` to decide whether it can diarize.
public enum SpeakerModelStatus: Sendable, Equatable {
    case notDownloaded
    case downloading(fraction: Double, receivedBytes: Int64, totalBytes: Int64)
    /// `sizeBytes` is measured on disk after install completes.
    case ready(sizeBytes: Int64)
    case cancelled
    case failed(String)
}

/// The speaker-labels add-on's identifier in the bucket catalog.
public let speakerLabelsAddOnID = "speaker-labels"

/// Owns the speaker-labels add-on (FluidAudio's streaming Sortformer
/// diarizer model) for the app: install state, download, and building ready-
/// to-use `SortformerDiarizer` instances. Downloads exclusively from our own
/// R2 bucket via `AddOnStore` - never Hugging Face at runtime. One shared
/// instance per app: the install is idempotent and safe to call more than
/// once (a second caller awaits the same in-flight task).
///
/// `@MainActor`, matching its two consumers (`MeetingSession` and the
/// Settings UI): `SortformerDiarizer` it hands out is a plain class, not
/// `Sendable` (FluidAudio documents it as not thread-safe), so building one
/// from a background actor and returning it across an actor boundary would
/// not typecheck under strict concurrency. The actual download/unzip work
/// still happens off the main thread inside `AddOnStore`; this class just
/// awaits it.
@MainActor
public final class SpeakerModelManager {
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "speaker-model")

    private let store: AddOnStore
    private var models: SortformerModels?
    private var installTask: Task<Void, Never>?

    public var status: SpeakerModelStatus { store.status }
    public nonisolated var statusUpdates: AsyncStream<SpeakerModelStatus> { store.statusUpdates }

    /// Pass a directory to load an already-unzipped add-on from (the CLI's
    /// `--addon-dir`) instead of the installed-by-the-app location. Nil (the
    /// default) uses `AddOnStore`'s normal install directory.
    private let overrideDirectory: URL?

    public init(addOnDirectory: URL? = nil) {
        self.store = AddOnStore(addOnID: speakerLabelsAddOnID)
        self.overrideDirectory = addOnDirectory
    }

    public var isReady: Bool {
        if overrideDirectory != nil {
            guard let root = addOnRootURL() else { return false }
            return FileManager.default.fileExists(atPath: root.path)
        }
        return store.isReady
    }

    /// Starts the install in the background if not already installed or
    /// installing; safe to call repeatedly. Returns immediately - observe
    /// `statusUpdates` (or poll `status`) for progress. Only ever called by
    /// an explicit user action (Settings > Models toggle, `zumbo-cli addon
    /// install`) - never automatically when a meeting starts.
    public func startDownloadIfNeeded() {
        guard installTask == nil else { return }
        if store.isReady { return }
        installTask = Task { [weak self] in
            await self?.store.install()
            self?.installTask = nil
        }
    }

    /// Awaits the current or a freshly started install, then returns whether
    /// the add-on is ready. Used by `zumbo-cli meeting`/`addon install`.
    @discardableResult
    public func ensureDownloaded() async -> Bool {
        startDownloadIfNeeded()
        await installTask?.value
        return isReady
    }

    public func cancelDownload() {
        store.cancel()
        installTask = nil
    }

    /// Deletes the installed files and returns to not-installed.
    public func remove() throws {
        try store.remove()
        models = nil
    }

    /// Builds a fresh `SortformerDiarizer`. The model is loaded into memory
    /// on first use: after a relaunch the files are on disk (status Ready
    /// from `AddOnStore`'s marker check) but not loaded, and loading a warm,
    /// already-compiled `.mlmodelc` reads it locally with no network call.
    /// Nil only when nothing is installed yet or the load fails.
    ///
    /// Note: this loads the already-compiled `.mlmodelc` FluidAudio's own
    /// `ModelHub` downloads directly with `MLModel(contentsOf:)`, the same
    /// way `ModelHub.loadModelsOnce` does for a warm cache. It does not go
    /// through `SortformerDiarizer.initialize(mainModelPath:)`, which calls
    /// `MLModel.compileModel(at:)` and expects an *uncompiled* `.mlpackage`;
    /// verified locally (2026-09-18) that passing our compiled `.mlmodelc`
    /// to `compileModel` throws ("A valid manifest does not exist... /
    /// Manifest.json"), while `MLModel(contentsOf:)` loads it straight away.
    public func makeDiarizer() async -> SortformerDiarizer? {
        if models == nil {
            guard let rootURL = addOnRootURL() else { return nil }
            do {
                let mlModel = try MLModel(contentsOf: rootURL)
                models = try SortformerModels(config: .default, main: mlModel)
            } catch {
                log.error("speaker model load failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let models else { return nil }
        let diarizer = SortformerDiarizer(config: .default)
        diarizer.initialize(models: models)
        return diarizer
    }

    private func addOnRootURL() -> URL? {
        if let overrideDirectory {
            // `--addon-dir` points at an unzipped install directory (an
            // `installed.json` next to `config.json`/`v3/...`, same layout
            // `AddOnStore` produces) - read its own rootPath rather than
            // assuming today's model layout.
            let markerURL = overrideDirectory.appendingPathComponent("installed.json")
            if let data = try? Data(contentsOf: markerURL),
                let marker = try? JSONDecoder().decode(AddOnInstalledMarker.self, from: data)
            {
                return overrideDirectory.appendingPathComponent(marker.rootPath)
            }
            return overrideDirectory.appendingPathComponent("v3/fp16/Sortformer_v2.1.mlmodelc")
        }
        return store.installedRootURL
    }
}
